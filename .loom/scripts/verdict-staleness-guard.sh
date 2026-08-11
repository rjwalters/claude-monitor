#!/usr/bin/env bash
# verdict-staleness-guard.sh — bind a PR's review verdict to the tree it was
# rendered against, and invalidate it when the head SHA moves (issue #5686).
#
# Problem this closes: a review verdict (`loom:changes-requested`, or the more
# dangerous approving `loom:pr`) is a statement about a SPECIFIC TREE. Before
# this guard, the label outlived the tree — a force-push/rebase could replace
# every commit the verdict was written about and the label would sit there
# unchanged. Observed live on rjwalters/repo#192 (2026-08-08): Judge correctly
# requested changes for a genuinely-failing test at 02:22, the branch was
# rebased and force-pushed at 02:55 making CI green, and the PR then sat with
# `loom:changes-requested` and no Judge re-queue until an operator cleared the
# label by hand. The inverse direction is worse: a `loom:pr` approval that
# survives a force-push lets Champion auto-merge a tree nobody approved.
#
# The fix is a marker, not a new label. Every terminal verdict comment carries
#
#     <!-- loom:verdict-sha sha=<head-sha> verdict=approved|changes-requested -->
#
# (the same HTML-comment marker convention as `<!-- loom:standdown claim=... -->`
# and `<!-- loom:fallback-evaluated sha=... -->`), so the verdict records which
# tree it covers. This script compares that recorded SHA against the PR's
# CURRENT head SHA and reports FRESH / STALE, optionally performing the
# clear+re-queue transition itself.
#
# Decision, in priority order (first match wins):
#   1. NO_VERDICT   — the PR carries neither `loom:pr` nor
#                     `loom:changes-requested`. Nothing to invalidate.
#   2. UNVERIFIABLE — a verdict label is present, but no marker comment exists
#                     for THAT verdict kind. Fail safe: the verdict is kept.
#                     This is the pre-migration/rollout case (verdicts written
#                     before this guard shipped carry no marker) and the
#                     mixed-fleet case (a host still running the older prompt).
#                     Never force-clear on missing evidence.
#   3. FRESH        — the newest matching marker's SHA equals the current head
#                     SHA. The verdict still describes the tree in front of it.
#   4. STALE        — the newest matching marker's SHA differs from the current
#                     head SHA. The verdict describes a tree that no longer
#                     exists; it must not be trusted.
#
# Marker selection deliberately filters on `verdict=` (not just "the newest
# marker of any kind"): a PR that was rejected at SHA A and later approved at
# SHA B has markers for both, and only the one matching the CURRENTLY-HELD
# label says anything about the current verdict. A verdict label with no
# marker of its own kind is UNVERIFIABLE, not STALE — see #2 above.
#
# Any head-SHA change invalidates the verdict — there is deliberately NO
# force-push-vs-fast-forward detector here. For a statement about a tree, an
# appended commit is just as much "not the tree I reviewed" as a rebase is,
# and the extra machinery would not change a single answer (#5686 explicitly
# scopes it out).
#
# Usage:
#   verdict-staleness-guard.sh <pr-number>            # report only
#   verdict-staleness-guard.sh <pr-number> --clear     # report + act on STALE
#
# With --clear, a STALE verdict is cleared in one transition:
#   - remove the stale verdict label (`loom:pr` / `loom:changes-requested`)
#   - remove its per-tree companions (`loom:ci-failure`, `loom:merge-conflict`)
#     when present — those are findings about the OLD tree too
#   - add `loom:review-requested` so a Judge picks the PR up again
#   - post an auditable comment naming the old and new SHAs
#
# --clear is suppressed (DECISION stays STALE, CLEARED=0) when the PR carries
# an explicit hold label — `loom:blocked`, `loom:operator`, or
# `loom:operator-only`. Those mark a PR a human (or Champion's capped-PR
# recovery pass) deliberately took out of automated flow; silently re-queueing
# it for review would undo that decision. Callers must still treat the verdict
# as untrustworthy: STALE is STALE whether or not it was cleared.
#
# Output (stdout — one KEY=VALUE per line, machine-parseable):
#   DECISION=NO_VERDICT|UNVERIFIABLE|FRESH|STALE
#   REASON=<short human-readable reason>
#   HEAD_SHA=<current head sha>
#   VERDICT_LABEL=<loom:pr|loom:changes-requested|"">
#   MARKER_SHA=<sha the verdict was recorded against, or "">
#   CLEARED=0|1
#
# Exit codes:
#   0  = FRESH (verdict is valid for the current head — safe to act on)
#   10 = NO_VERDICT (no terminal verdict label on this PR)
#   11 = UNVERIFIABLE (verdict present, no marker — fail safe, verdict kept)
#   12 = STALE (verdict invalidated by a head-SHA move)
#   1  = usage or environment error (bad args, `gh` call failed). Callers must
#        treat this like any other `gh` failure — NOT as "the verdict is fine".
#
# This script decides about ONE given PR number. Finding the candidate set
# (open PRs carrying a verdict label) stays with the caller — judge.md's
# stale-verdict sweep, champion-pr-merge.md's Verdict-State Janitor, and
# loom-daemon's `reconcile_pr_verdicts` backstop each walk their own queue.

set -uo pipefail

PR=""
CLEAR=0

usage() {
  echo "Usage: $0 <pr-number> [--clear]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clear) CLEAR=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)
      echo "ERROR: unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      if [[ -n "$PR" ]]; then
        echo "ERROR: unexpected extra argument: $1" >&2
        usage
        exit 1
      fi
      PR="$1"
      shift
      ;;
  esac
done

if [[ -z "$PR" || ! "$PR" =~ ^[0-9]+$ ]]; then
  echo "ERROR: a numeric PR number is required" >&2
  usage
  exit 1
fi

for bin in gh jq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' not found on PATH" >&2; exit 1; }
done

# The two terminal verdict labels and the marker `verdict=` token each one is
# recorded under. Kept as parallel lookups rather than one map so this stays
# POSIX-ish bash 3.2 compatible (macOS ships bash 3.2 — no associative arrays).
verdict_token_for_label() { # <label> -> approved|changes-requested
  case "$1" in
    "loom:pr") echo "approved" ;;
    "loom:changes-requested") echo "changes-requested" ;;
    *) echo "" ;;
  esac
}

emit() {
  local decision="$1" reason="$2" head_sha="$3" verdict_label="$4" marker_sha="$5" cleared="$6"
  echo "DECISION=$decision"
  echo "REASON=$reason"
  echo "HEAD_SHA=$head_sha"
  echo "VERDICT_LABEL=$verdict_label"
  echo "MARKER_SHA=$marker_sha"
  echo "CLEARED=$cleared"
}

# Keep `gh`'s stdout (the JSON we parse) and stderr SEPARATE. `gh` writes
# incidental content to stderr even on a successful exit (update-notifier
# banners, rate-limit hints, proxy/TLS warnings); merging that into stdout
# with `2>&1` corrupts the JSON before `jq` sees it. Same lesson as #5455's
# Judge finding on judge-fallback-guard.sh, where merged streams silently
# zeroed a marker count and defeated the guard it was protecting.
GH_STDERR="$(mktemp)"
trap 'rm -f "$GH_STDERR" 2>/dev/null || true' EXIT

# --- Step 1: current head SHA + current labels ------------------------------
PR_JSON="$(gh pr view "$PR" --json headRefOid,labels 2>"$GH_STDERR")" || {
  echo "ERROR: 'gh pr view $PR --json headRefOid,labels' failed: $(cat "$GH_STDERR" 2>/dev/null)" >&2
  exit 1
}

HEAD_SHA="$(jq -r '.headRefOid // empty' <<<"$PR_JSON" 2>/dev/null || true)"
if [[ -z "$HEAD_SHA" ]]; then
  echo "ERROR: could not resolve head SHA for PR #$PR from: $PR_JSON" >&2
  exit 1
fi

LABELS="$(jq -r '[.labels[].name] | join("\n")' <<<"$PR_JSON" 2>/dev/null || true)"
has_label() { printf '%s\n' "$LABELS" | grep -qx -- "$1"; }

# --- Step 2: which terminal verdict (if any) does this PR carry? ------------
# `loom:pr` is checked first: when both are somehow present (the contradictory
# state champion-pr-merge.md's Verdict-State Janitor exists to resolve, #4570),
# the approving label is the dangerous one and is what we must reason about.
VERDICT_LABEL=""
if has_label "loom:pr"; then
  VERDICT_LABEL="loom:pr"
elif has_label "loom:changes-requested"; then
  VERDICT_LABEL="loom:changes-requested"
fi

if [[ -z "$VERDICT_LABEL" ]]; then
  emit "NO_VERDICT" "PR carries no terminal verdict label (loom:pr / loom:changes-requested)" \
    "$HEAD_SHA" "" "" 0
  exit 10
fi

VERDICT_TOKEN="$(verdict_token_for_label "$VERDICT_LABEL")"

# --- Step 3: newest verdict marker for THIS verdict kind --------------------
# --paginate is REQUIRED: without it `gh api` returns only the first page
# (default per_page=30, oldest-first), so on a long-running PR the verdict
# marker — always among the NEWEST comments — would never be seen and every
# verdict would read as UNVERIFIABLE.
COMMENTS_JSON="$(gh api "repos/{owner}/{repo}/issues/$PR/comments" --paginate 2>"$GH_STDERR")" || {
  echo "ERROR: 'gh api .../issues/$PR/comments --paginate' failed: $(cat "$GH_STDERR" 2>/dev/null)" >&2
  exit 1
}

# One "<created_at>\t<sha>" line per matching marker, oldest first (matches
# --paginate's page order). `test(...)` guards `capture(...)` so a non-matching
# body is filtered out via `select` rather than raising a per-item jq error.
# A short (abbreviated) SHA is accepted defensively but never emitted by the
# roles, which always stamp the full `headRefOid`.
MARKER_TEST="<!-- loom:verdict-sha sha=[0-9a-f]{7,40} verdict=$VERDICT_TOKEN -->"
MARKER_CAPTURE="<!-- loom:verdict-sha sha=(?<sha>[0-9a-f]{7,40}) verdict=$VERDICT_TOKEN -->"
MARKER_LINES="$(jq -r --arg t "$MARKER_TEST" --arg c "$MARKER_CAPTURE" '
  .[]
  | select(.body != null and (.body | test($t)))
  | [.created_at, (.body | capture($c).sha)]
  | @tsv
' <<<"$COMMENTS_JSON" 2>/dev/null || true)"

MARKER_SHA=""
if [[ -n "$MARKER_LINES" ]]; then
  MARKER_SHA="$(tail -n 1 <<<"$MARKER_LINES" | cut -f2)"
fi

if [[ -z "$MARKER_SHA" ]]; then
  emit "UNVERIFIABLE" "verdict label $VERDICT_LABEL present but no <!-- loom:verdict-sha ... verdict=$VERDICT_TOKEN --> marker found (pre-marker verdict) — failing safe, verdict kept" \
    "$HEAD_SHA" "$VERDICT_LABEL" "" 0
  exit 11
fi

# --- Step 4: fresh or stale? ------------------------------------------------
# Compare on the marker's own length so a legitimately abbreviated marker SHA
# still matches the full head SHA it prefixes (the roles stamp full SHAs; this
# only guards a hand-written or truncated marker).
if [[ "${HEAD_SHA:0:${#MARKER_SHA}}" == "$MARKER_SHA" ]]; then
  emit "FRESH" "verdict $VERDICT_LABEL was rendered against the current head SHA" \
    "$HEAD_SHA" "$VERDICT_LABEL" "$MARKER_SHA" 0
  exit 0
fi

# --- Step 5: STALE — optionally clear + re-queue -----------------------------
CLEARED=0
REASON="verdict $VERDICT_LABEL was rendered against $MARKER_SHA but head is now $HEAD_SHA"

if [[ "$CLEAR" -eq 1 ]]; then
  HOLD_LABEL=""
  for held in "loom:blocked" "loom:operator" "loom:operator-only"; do
    if has_label "$held"; then HOLD_LABEL="$held"; break; fi
  done

  if [[ -n "$HOLD_LABEL" ]]; then
    REASON="$REASON; clear suppressed — PR is on an explicit $HOLD_LABEL hold"
  else
    # Idempotency: if this exact old->new transition was already announced,
    # don't post a second comment (a Judge pass and the daemon backstop can
    # both notice the same move). The label writes below are idempotent on
    # their own, so this only guards comment spam on a partial-failure retry.
    STALE_MARKER="<!-- loom:verdict-stale from=$MARKER_SHA to=$HEAD_SHA -->"
    ALREADY_ANNOUNCED="$(jq -r --arg m "$STALE_MARKER" \
      '[.[] | select(.body != null and (.body | contains($m)))] | length' \
      <<<"$COMMENTS_JSON" 2>/dev/null || echo 0)"

    if [[ "${ALREADY_ANNOUNCED:-0}" -eq 0 ]]; then
      gh pr comment "$PR" --body "$STALE_MARKER
**Stale review verdict cleared — head SHA moved**

This PR's \`$VERDICT_LABEL\` verdict was rendered against \`$MARKER_SHA\`, but the current head is \`$HEAD_SHA\`. A review verdict is a statement about a specific tree, so it does not survive a rebase, a force-push, or new commits.

- Verdict cleared: \`$VERDICT_LABEL\` (recorded for \`$MARKER_SHA\`)
- Returned to the review queue: \`loom:review-requested\` (current head \`$HEAD_SHA\`)

Judge will re-evaluate the tree that is actually here now. No judgment about the new tree is implied either way — the old verdict simply no longer describes it.

---
*Automated by verdict-staleness-guard.sh (#5686)*" >/dev/null 2>"$GH_STDERR" || {
        echo "ERROR: failed to post stale-verdict comment on PR #$PR: $(cat "$GH_STDERR" 2>/dev/null)" >&2
        emit "STALE" "$REASON; comment failed, labels left untouched" \
          "$HEAD_SHA" "$VERDICT_LABEL" "$MARKER_SHA" 0
        exit 1
      }
    fi

    # Comment first, then labels — the same ordering the roles use for their
    # own verdict writes, so the audit trail can never show a label flip with
    # no explanation attached.
    EDIT_ARGS=(--remove-label "$VERDICT_LABEL" --add-label "loom:review-requested")
    for companion in "loom:ci-failure" "loom:merge-conflict"; do
      if has_label "$companion"; then
        EDIT_ARGS+=(--remove-label "$companion")
      fi
    done
    if gh pr edit "$PR" "${EDIT_ARGS[@]}" >/dev/null 2>"$GH_STDERR"; then
      CLEARED=1
      REASON="$REASON; cleared and re-queued as loom:review-requested"
    else
      echo "ERROR: failed to clear $VERDICT_LABEL on PR #$PR: $(cat "$GH_STDERR" 2>/dev/null)" >&2
      emit "STALE" "$REASON; label clear failed" \
        "$HEAD_SHA" "$VERDICT_LABEL" "$MARKER_SHA" 0
      exit 1
    fi
  fi
fi

emit "STALE" "$REASON" "$HEAD_SHA" "$VERDICT_LABEL" "$MARKER_SHA" "$CLEARED"
exit 12
