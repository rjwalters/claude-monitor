#!/usr/bin/env bash
# test-champion-held-pr-health-pass.sh - Regression tests for the merge-risk
# hold "one-way door" defect (#6720).
#
# Champion's 6 safety criteria (`champion-pr-merge.md`) are prose an LLM
# instance reads and executes, not a standalone script (same situation as
# test-champion-critical-file-check.sh and test-dependency-parse.sh) — so this
# file mirrors the documented control flow in local functions and pins the
# shipped markdown's exact commands with `assert_doc_contains` /
# `assert_doc_lacks`, catching drift between the two.
#
# Incident recap (#6720): criterion #2's sticky-hold precheck bailed out with
# "HOLD, silently. Skip the PR for this pass" BEFORE criteria #4 (merge
# conflict), #5 (recency) and #6 (CI status) were ever evaluated. Because
# criterion #5's stale route is the ONLY automated path from `loom:pr` to
# `loom:changes-requested` — i.e. the only way a `loom:pr` PR reaches Doctor —
# a held PR could never be reported as conflicting nor routed for a rebase.
# Measured on rjwalters/loom 2026-08-22: 21 open PRs carried `loom:pr` +
# `loom:operator`, 20 of the 21 were CONFLICTING (two untouched for 63h), and
# Doctor's `loom:changes-requested` queue was empty.
#
# The fix decouples MERGE PERMISSION from HEALTH REPORTING:
#   1. A hold (sticky OR fresh) sets MERGE_BLOCKED_BY_HOLD=true and blocks the
#      merge + criterion #3 + Steps 2-3 — but the PR is NOT dropped from the
#      pass. Criteria #4/#5/#6 still run ("Held-PR Health Pass").
#   2. A held PR that turns CONFLICTING gets one idempotent
#      `champion:held-pr-conflict-notice` comment.
#   3. A held PR that goes stale is routed to Doctor exactly like an unheld one
#      (`loom:pr` -> `loom:changes-requested`), with the
#      `champion:merge-risk-hold` marker PRESERVED so the hold re-binds and the
#      mandatory reversal comment stays mandatory (#4742). A rebase must not
#      launder a held PR into an unheld one.
#   4. `loom:operator` is KEPT on the held-and-stale route (narrowing #5802,
#      which clears it on the unheld route) — the human merge decision is still
#      outstanding, and Doctor's `loom:changes-requested` queue filters
#      `loom:blocked` / `loom:operator-only`, not `loom:operator`.
#
# This file asserts:
#   1. THE HEADLINE REGRESSION SHAPE: hold a PR, let `main` move until it
#      conflicts, advance past 24h -> it reaches Doctor
#      (`loom:changes-requested`) instead of sitting silently.
#   2. Criteria #4/#5/#6 are evaluated under a hold; #3 and the merge are not.
#   3. The conflict notice and the stale notice are each posted exactly once
#      across repeated ticks (10-minute cron anti-spam).
#   4. The hold marker survives the route to Doctor on every held path.
#   5. `loom:operator` is kept on the held route and still cleared on the
#      unheld route (#5802 not regressed).
#   6. A FRESH hold (red axis this tick) gets the same health pass as a sticky
#      one — the defect is not sticky-specific.
#   7. The never-held green path is byte-for-byte unchanged (still merges).
#   8. The held-PR census jq pipeline computes count / conflicting / at-Doctor.
#   9. The shipped markdown carries the new literals and no longer carries the
#      short-circuiting ones.
#
# Usage:
#   ./.loom/scripts/tests/test-champion-held-pr-health-pass.sh

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)"

# Two `..` reaches repo-root/.claude/commands/loom for an INSTALLED copy
# (SCRIPTS_DIR is .loom/scripts there); one `..` reaches defaults/.claude/
# commands/loom when running inside this source repo (SCRIPTS_DIR is
# defaults/scripts) -- the two layouts differ in depth, so probe both rather
# than hard-coding one (#6725).
if [[ -d "$SCRIPTS_DIR/../../.claude/commands/loom" ]]; then
    PROMPT_DIR="$(cd "$SCRIPTS_DIR/../../.claude/commands/loom" && pwd)"
else
    PROMPT_DIR="$(cd "$SCRIPTS_DIR/../.claude/commands/loom" && pwd)"
fi
CHAMPION_MD="$PROMPT_DIR/champion-pr-merge.md"
CHAMPION_COMMON_MD="$PROMPT_DIR/champion-common.md"

# Same two-layout probe for the docs directory: `.loom/docs` when installed,
# `defaults/docs` in this source repo.
if [[ -d "$SCRIPTS_DIR/../docs" ]]; then
    DOCS_DIR="$(cd "$SCRIPTS_DIR/../docs" && pwd)"
else
    DOCS_DIR="$(cd "$SCRIPTS_DIR/../../docs" && pwd)"
fi
LABEL_SM_MD="$DOCS_DIR/label-state-machine.md"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

assert_eq() {
    local expected="$1" actual="$2" msg="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$expected" == "$actual" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${NC}: $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${NC}: $msg"
        echo "    Expected: '$expected'"
        echo "    Actual:   '$actual'"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" msg="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if grep -qF -- "$needle" <<<"$haystack"; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${NC}: $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${NC}: $msg"
        echo "    Missing '$needle' in:"
        sed 's/^/      /' <<<"$haystack"
    fi
}

assert_lacks() {
    local haystack="$1" needle="$2" msg="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if grep -qF -- "$needle" <<<"$haystack"; then
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${NC}: $msg"
        echo "    Unexpected '$needle' in:"
        sed 's/^/      /' <<<"$haystack"
    else
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${NC}: $msg"
    fi
}

# Pin a literal snippet as present verbatim in a doc file — catches drift
# between this test's mirrored control flow and the shipped markdown.
assert_doc_contains() {
    local file="$1" needle="$2" msg="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if grep -qF -- "$needle" "$file"; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${NC}: $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${NC}: $msg (missing literal in $file: $needle)"
    fi
}

# Pin a literal snippet's ABSENCE — catches a regression back to the
# short-circuiting bail-out.
assert_doc_lacks() {
    local file="$1" needle="$2" msg="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if grep -qF -- "$needle" "$file"; then
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${NC}: $msg (found short-circuiting literal in $file: $needle)"
    else
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${NC}: $msg"
    fi
}

# =====================================================================
# PR state fixture — a tiny stand-in for the forge state a Champion tick
# reads and writes: which idempotency markers are already posted, and which
# labels the PR carries. Persisted in a file so successive ticks in one test
# observe each other, exactly as successive cron ticks do.
# =====================================================================
state_new() {
    local f
    f=$(mktemp)
    printf 'label:loom:pr\n' >"$f"
    echo "$f"
}

state_has()    { grep -qxF -- "$1" "$2"; }
state_add()    { state_has "$1" "$2" || printf '%s\n' "$1" >>"$2"; }
state_remove() { local tmp; tmp=$(mktemp); grep -vxF -- "$1" "$2" >"$tmp" || true; mv "$tmp" "$2"; }

state_labels() {
    sed -n 's/^label://p' "$1" | sort | paste -sd, - 2>/dev/null || true
}

# =====================================================================
# champion-pr-merge.md's per-PR evaluation, mirrored from the shipped prose:
#   - criterion #2's sticky-hold precheck (STICKY_HOLD / MERGE_BLOCKED_BY_HOLD)
#   - criterion #2's "Hold behavior" fresh-hold branch
#   - the "Held-PR Health Pass" (#6720): criteria #4/#5/#6 under a hold
#   - "PR Rejection Workflow -> Stale PR", hold-aware
#
# Emits one ACTION line per observable effect so a test can assert on the
# whole tick. Deliberately does NOT model criterion #1 or #3's internals —
# those are covered by test-champion-critical-file-check.sh.
#
# Args: <state-file> <prior_hold> <release_reason> <axes_red> <mergeable>
#       <hours_ago> <ci>
# =====================================================================
champion_pr_pass() {
    local state="$1" prior_hold="$2" release_reason="$3" axes_red="$4"
    local mergeable="$5" hours_ago="$6" ci="$7"

    local MERGE_BLOCKED_BY_HOLD=false

    # ---- criterion #2: sticky-hold precheck -------------------------------
    # (The doc also sets STICKY_HOLD here for narration; the `HOLD:sticky`
    # action line below is this mirror's equivalent, so the flag itself is not
    # duplicated.)
    if [ "$prior_hold" = true ] && [ -z "$release_reason" ]; then
        MERGE_BLOCKED_BY_HOLD=true
        echo "HOLD:sticky"
        # #6720: NO `continue` here. Pre-fix, the pass ended on this line.
    else
        # Never held, or held-and-released: the four axes are judged normally.
        if [ "$axes_red" = true ]; then
            # "Hold behavior" — idempotent notice + loom:operator, no merge.
            if state_has "marker:champion:merge-risk-hold" "$state"; then
                echo "HOLD_NOTICE:suppressed"
            else
                state_add "marker:champion:merge-risk-hold" "$state"
                echo "COMMENT:champion:merge-risk-hold"
            fi
            state_add "label:loom:operator" "$state"
            MERGE_BLOCKED_BY_HOLD=true
            echo "HOLD:fresh"
        fi
    fi

    # ---- criterion #3: merge gate only; skipped under a hold --------------
    if [ "$MERGE_BLOCKED_BY_HOLD" = true ]; then
        echo "SKIP:criterion-3"
    else
        echo "EVAL:criterion-3"
    fi

    # ---- criterion #4: ALWAYS evaluated (the #6720 fix) ------------------
    echo "EVAL:criterion-4"
    if [ "$mergeable" = "CONFLICTING" ] && [ "$MERGE_BLOCKED_BY_HOLD" = true ]; then
        if state_has "marker:champion:held-pr-conflict-notice" "$state"; then
            echo "CONFLICT_NOTICE:suppressed"
        else
            state_add "marker:champion:held-pr-conflict-notice" "$state"
            echo "COMMENT:champion:held-pr-conflict-notice"
        fi
    fi

    # ---- criterion #5: ALWAYS evaluated; stale routes to Doctor ----------
    echo "EVAL:criterion-5"
    local stale=false
    [ "$hours_ago" -gt 24 ] && stale=true
    if [ "$stale" = true ]; then
        if state_has "marker:champion:stale-pr-notice" "$state"; then
            echo "STALE_NOTICE:suppressed"
        else
            state_add "marker:champion:stale-pr-notice" "$state"
            echo "COMMENT:champion:stale-pr-notice"
            state_remove "label:loom:pr" "$state"
            state_add "label:loom:changes-requested" "$state"
            echo "LABEL_REMOVE:loom:pr"
            echo "LABEL_ADD:loom:changes-requested"
            # loom:operator: conditional on whether a hold is still in force
            # (#6720 narrowing #5802).
            if [ "$MERGE_BLOCKED_BY_HOLD" = true ]; then
                echo "LABEL_KEEP:loom:operator"
            else
                state_remove "label:loom:operator" "$state"
                echo "LABEL_REMOVE:loom:operator"
            fi
            # The hold marker is NEVER touched on this path.
        fi
    fi

    # ---- criterion #6: ALWAYS evaluated ----------------------------------
    echo "EVAL:criterion-6"
    if [ "$ci" = "fail" ]; then
        echo "REPORT:ci-status"
    fi

    # ---- merge decision --------------------------------------------------
    if [ "$MERGE_BLOCKED_BY_HOLD" = true ]; then
        echo "NO_MERGE:hold"
        return 0
    fi
    if [ "$mergeable" != "MERGEABLE" ]; then echo "NO_MERGE:conflict"; return 0; fi
    if [ "$stale" = true ];             then echo "NO_MERGE:stale";    return 0; fi
    if [ "$ci" = "fail" ];              then echo "NO_MERGE:ci";       return 0; fi
    echo "MERGE"
}

# =====================================================================
# "Held-PR Census" jq pipeline, mirrored from champion-pr-merge.md.
# Reads the `gh pr list --json number,title,createdAt,updatedAt,mergeable,
# labels` payload on stdin, prints "<count> <conflicting> <at-doctor>".
# =====================================================================
held_census() {
    local json
    json=$(cat)
    local count conflicting at_doctor
    count=$(printf '%s\n' "$json" | jq 'length')
    conflicting=$(printf '%s\n' "$json" | jq '[.[] | select(.mergeable == "CONFLICTING")] | length')
    at_doctor=$(printf '%s\n' "$json" | jq '[.[] | select([.labels[].name] | index("loom:changes-requested"))] | length')
    echo "$count $conflicting $at_doctor"
}

echo "=== test-champion-held-pr-health-pass.sh ==="
echo

# ---------------------------------------------------------------------
echo "Test 1: THE REGRESSION SHAPE — held + CONFLICTING + past 24h reaches Doctor"
# This is the exact failure #6720 documents: a held PR that main has moved past
# and that has aged out. Pre-fix, this tick produced nothing at all.
S=$(state_new)
state_add "marker:champion:merge-risk-hold" "$S"
state_add "label:loom:operator" "$S"
OUT=$(champion_pr_pass "$S" true "" false CONFLICTING 63 pass)

assert_contains "$OUT" "HOLD:sticky" "the sticky hold is still recognized and still binds"
assert_contains "$OUT" "NO_MERGE:hold" "the held PR is not merged"
assert_contains "$OUT" "COMMENT:champion:held-pr-conflict-notice" \
    "the conflict is surfaced with an idempotent marker comment (AC #2)"
assert_contains "$OUT" "LABEL_REMOVE:loom:pr" "loom:pr is removed by the stale route"
assert_contains "$OUT" "LABEL_ADD:loom:changes-requested" \
    "the held+stale PR REACHES DOCTOR via loom:changes-requested (AC #3)"
assert_eq "loom:changes-requested,loom:operator" "$(state_labels "$S")" \
    "final labels: loom:changes-requested + loom:operator (loom:pr gone)"
TESTS_RUN=$((TESTS_RUN + 1))
if state_has "marker:champion:merge-risk-hold" "$S"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "  ${GREEN}PASS${NC}: the champion:merge-risk-hold marker is PRESERVED across the route to Doctor (AC #3)"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "  ${RED}FAIL${NC}: the hold marker was cleared — a rebase would launder this into an unheld PR"
fi
rm -f "$S"
echo

# ---------------------------------------------------------------------
echo "Test 2: the mechanical criteria are evaluated under a hold; #3 and the merge are not"
S=$(state_new)
state_add "marker:champion:merge-risk-hold" "$S"
state_add "label:loom:operator" "$S"
OUT=$(champion_pr_pass "$S" true "" false MERGEABLE 1 pass)
assert_contains "$OUT" "EVAL:criterion-4" "criterion #4 (conflict) runs under a hold (AC #1)"
assert_contains "$OUT" "EVAL:criterion-5" "criterion #5 (recency) runs under a hold (AC #1)"
assert_contains "$OUT" "EVAL:criterion-6" "criterion #6 (CI) runs under a hold (AC #1)"
assert_contains "$OUT" "SKIP:criterion-3" "criterion #3 is skipped under a hold (pure merge gate, no remedy)"
assert_contains "$OUT" "NO_MERGE:hold" "the hold still blocks the merge — health reporting is not permission"
assert_lacks "$OUT" "COMMENT:" "a healthy held PR produces no comment at all (anti-spam)"
rm -f "$S"
echo

# ---------------------------------------------------------------------
echo "Test 3: held + CONFLICTING but NOT stale — surfaced, not routed"
# Doctor's Priority 1 queue (loom:pr + CONFLICTING) deliberately excludes
# loom:operator (#5978) so autonomous work never force-pushes a held PR.
# Conflict alone is therefore a report; conflict PLUS staleness is a route.
S=$(state_new)
state_add "marker:champion:merge-risk-hold" "$S"
state_add "label:loom:operator" "$S"
OUT=$(champion_pr_pass "$S" true "" false CONFLICTING 3 pass)
assert_contains "$OUT" "COMMENT:champion:held-pr-conflict-notice" "the conflict is reported"
assert_lacks "$OUT" "LABEL_ADD:loom:changes-requested" \
    "a merely-conflicting held PR is NOT routed to Doctor (respects #5978)"
assert_eq "loom:operator,loom:pr" "$(state_labels "$S")" "labels are unchanged by a conflict report"
rm -f "$S"
echo

# ---------------------------------------------------------------------
echo "Test 4: idempotency across repeated cron ticks — one comment per episode"
S=$(state_new)
state_add "marker:champion:merge-risk-hold" "$S"
state_add "label:loom:operator" "$S"
TICK1=$(champion_pr_pass "$S" true "" false CONFLICTING 63 pass)
TICK2=$(champion_pr_pass "$S" true "" false CONFLICTING 64 pass)
TICK3=$(champion_pr_pass "$S" true "" false CONFLICTING 65 pass)
assert_contains "$TICK1" "COMMENT:champion:held-pr-conflict-notice" "tick 1 posts the conflict notice"
assert_contains "$TICK2" "CONFLICT_NOTICE:suppressed" "tick 2 suppresses the duplicate conflict notice"
assert_contains "$TICK3" "CONFLICT_NOTICE:suppressed" "tick 3 suppresses the duplicate conflict notice"
assert_contains "$TICK1" "COMMENT:champion:stale-pr-notice" "tick 1 posts the stale notice"
assert_contains "$TICK2" "STALE_NOTICE:suppressed" "tick 2 suppresses the duplicate stale notice"
assert_lacks "$TICK2" "LABEL_REMOVE:loom:pr" "tick 2 does not re-run the label swap"
rm -f "$S"
echo

# ---------------------------------------------------------------------
echo "Test 5: loom:operator — kept on the held route, still cleared on the unheld route (#5802)"
# Held: the human merge decision is still outstanding, so the label stays.
S=$(state_new)
state_add "marker:champion:merge-risk-hold" "$S"
state_add "label:loom:operator" "$S"
OUT=$(champion_pr_pass "$S" true "" false MERGEABLE 30 pass)
assert_contains "$OUT" "LABEL_KEEP:loom:operator" "held+stale keeps loom:operator (AC #4)"
assert_contains "$(state_labels "$S")" "loom:operator" "loom:operator survives in the final label set"
rm -f "$S"

# Unheld: #5802's original behavior, unchanged.
S=$(state_new)
OUT=$(champion_pr_pass "$S" false "" false MERGEABLE 30 pass)
assert_contains "$OUT" "LABEL_REMOVE:loom:operator" "unheld+stale still clears loom:operator (#5802 not regressed)"
assert_contains "$OUT" "LABEL_ADD:loom:changes-requested" "unheld+stale still routes to Doctor"
assert_eq "loom:changes-requested" "$(state_labels "$S")" "unheld+stale final labels are unchanged from #5802"
rm -f "$S"
echo

# ---------------------------------------------------------------------
echo "Test 6: a FRESH hold (red axis this tick) gets the same health pass"
# The defect is not sticky-specific: a first-tick hold on an already-stale,
# already-conflicting PR must not rot either.
S=$(state_new)
OUT=$(champion_pr_pass "$S" false "" true CONFLICTING 63 pass)
assert_contains "$OUT" "COMMENT:champion:merge-risk-hold" "the fresh hold notice is posted"
assert_contains "$OUT" "HOLD:fresh" "the fresh hold blocks the merge"
assert_contains "$OUT" "EVAL:criterion-5" "criterion #5 still runs behind a fresh hold"
assert_contains "$OUT" "COMMENT:champion:held-pr-conflict-notice" "a freshly-held conflicting PR is surfaced too"
assert_contains "$OUT" "LABEL_ADD:loom:changes-requested" "a freshly-held stale PR reaches Doctor too"
assert_contains "$OUT" "LABEL_KEEP:loom:operator" "the fresh hold's loom:operator is kept on the route"
TESTS_RUN=$((TESTS_RUN + 1))
if state_has "marker:champion:merge-risk-hold" "$S"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "  ${GREEN}PASS${NC}: the fresh hold's marker is preserved across the route to Doctor"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "  ${RED}FAIL${NC}: the fresh hold's marker was cleared"
fi
rm -f "$S"
echo

# ---------------------------------------------------------------------
echo "Test 7: the never-held green path still merges (no collateral change)"
S=$(state_new)
OUT=$(champion_pr_pass "$S" false "" false MERGEABLE 2 pass)
assert_contains "$OUT" "EVAL:criterion-3" "criterion #3 runs on the unheld path"
assert_contains "$OUT" "MERGE" "a green, recent, mergeable, unheld PR still merges"
assert_lacks "$OUT" "COMMENT:" "the never-held merge path posts none of the new notices"
assert_eq "loom:pr" "$(state_labels "$S")" "labels untouched on the merge path"
rm -f "$S"

# A released hold is re-judged, not auto-held: green axes after a real release
# signal merge exactly as before #6720.
S=$(state_new)
state_add "marker:champion:merge-risk-hold" "$S"
state_add "label:loom:operator" "$S"
OUT=$(champion_pr_pass "$S" true "new head commit abc1234" false MERGEABLE 2 pass)
assert_contains "$OUT" "MERGE" "a genuinely-released hold with green axes still merges (#4742 semantics intact)"
rm -f "$S"

# A released hold whose axes are STILL red re-holds — silently, because the
# marker survived. This is the "rebase does not launder a held PR" property.
S=$(state_new)
state_add "marker:champion:merge-risk-hold" "$S"
state_add "label:loom:operator" "$S"
OUT=$(champion_pr_pass "$S" true "new head commit abc1234" true MERGEABLE 2 pass)
assert_contains "$OUT" "HOLD_NOTICE:suppressed" "the re-hold after a rebase is silent (idempotency guard)"
assert_contains "$OUT" "NO_MERGE:hold" "a rebased-but-still-red PR is re-held, not laundered into a merge"
rm -f "$S"
echo

# ---------------------------------------------------------------------
echo "Test 8: held-PR census counts the set, the conflicts, and the ones out at Doctor"
CENSUS_FIXTURE='[
  {"number":6445,"createdAt":"2026-08-10T00:00:00Z","updatedAt":"2026-08-19T14:59:00Z","mergeable":"CONFLICTING","labels":[{"name":"loom:pr"},{"name":"loom:operator"}]},
  {"number":6484,"createdAt":"2026-08-12T00:00:00Z","updatedAt":"2026-08-19T14:59:00Z","mergeable":"CONFLICTING","labels":[{"name":"loom:changes-requested"},{"name":"loom:operator"}]},
  {"number":6621,"createdAt":"2026-08-18T00:00:00Z","updatedAt":"2026-08-22T09:00:00Z","mergeable":"MERGEABLE","labels":[{"name":"loom:pr"},{"name":"loom:operator"}]}
]'
assert_eq "3 2 1" "$(printf '%s\n' "$CENSUS_FIXTURE" | held_census)" \
    "census: 3 held, 2 conflicting, 1 out at Doctor (AC #5)"
assert_eq "2026-08-10T00:00:00Z" \
    "$(printf '%s\n' "$CENSUS_FIXTURE" | jq -r 'min_by(.createdAt) | .createdAt')" \
    "census: the oldest held PR is identified for the age report"
assert_eq "0 0 0" "$(printf '%s\n' '[]' | held_census)" \
    "census: an empty held set reports zeros rather than erroring"
echo

# ---------------------------------------------------------------------
echo "Test 9: the shipped markdown matches this mirror (drift guard)"

assert_doc_contains "$CHAMPION_MD" \
    "## Held-PR Health Pass (#6720)" \
    "champion-pr-merge.md ships the Held-PR Health Pass section"

assert_doc_contains "$CHAMPION_MD" \
    "MERGE_BLOCKED_BY_HOLD=true" \
    "the sticky-hold precheck sets MERGE_BLOCKED_BY_HOLD instead of dropping the PR"

assert_doc_contains "$CHAMPION_MD" \
    'HELD="${MERGE_BLOCKED_BY_HOLD:-false}"' \
    "the stale-PR block reads MERGE_BLOCKED_BY_HOLD to decide the loom:operator reversal"

assert_doc_contains "$CHAMPION_MD" \
    '<!-- champion:held-pr-conflict-notice -->' \
    "the held-PR conflict notice has its own idempotency marker (AC #2)"

assert_doc_contains "$CHAMPION_MD" \
    'any(startswith(\"$CONFLICT_MARKER\"))' \
    "the conflict notice uses the startswith idempotency guard (#5371), not a substring match"

assert_doc_contains "$CHAMPION_MD" \
    'Kept loom:operator on #$PR_NUMBER' \
    "the stale route keeps loom:operator when a hold is in force (AC #4)"

assert_doc_contains "$CHAMPION_MD" \
    "**Never delete or edit the \`champion:merge-risk-hold\` comment here**" \
    "the stale route forbids clearing the hold marker (AC #3)"

assert_doc_contains "$CHAMPION_MD" \
    "## Held-PR Census (report every pass, #6720)" \
    "champion-pr-merge.md ships the held-PR census (AC #5)"

assert_doc_contains "$CHAMPION_MD" \
    'HELD_CONFLICTING=$(printf '"'"'%s\n'"'"' "$HELD_JSON" | jq '"'"'[.[] | select(.mergeable == "CONFLICTING")] | length'"'" \
    "the census jq pipeline this test mirrors is the one shipped in the markdown"

assert_doc_contains "$CHAMPION_COMMON_MD" \
    "Merge-risk holds:" \
    "champion-common.md's Completion Report requires the merge-risk hold census line"

assert_doc_contains "$LABEL_SM_MD" \
    "The stale-PR route out of \`loom:pr\` (#5802, narrowed by #6720)" \
    "label-state-machine.md documents the loom:operator decision for the held route (AC #4)"

# --- absence pins: the short-circuiting behavior must not come back ---
assert_doc_lacks "$CHAMPION_MD" \
    "Skip the PR for this pass regardless of how the axes read this tick" \
    "the outcomes table no longer says a sticky hold skips the whole PR"

assert_doc_lacks "$CHAMPION_MD" \
    "# Skip this PR for this pass — do not merge." \
    "the Hold behavior block no longer ends by dropping the PR from the pass"

assert_doc_lacks "$CHAMPION_MD" \
    "# merge-risk hold — the PR leaves the auto-merge queue either way" \
    "the stale route no longer claims it unconditionally exits the hold (#5802's stale premise)"

# --- #6843: criterion #5 must not derive staleness from `updatedAt` ---
# `updatedAt` is bumped by ANY PR write, including the Held-PR Health Pass's
# OWN comments (conflict notices, loom:operator reasserts) — so a held PR
# nobody but Champion touches never accumulates real staleness and the stale
# route above (Test 1-6) never fires in practice, even though this file's
# mirror (which takes hours_ago as a plain input) cannot see that failure
# mode itself. These pins guard the actual verification-command literal.
assert_doc_lacks "$CHAMPION_MD" \
    "UPDATED_AT=\$(gh pr view <number> --json updatedAt --jq '.updatedAt')" \
    "criterion #5 no longer derives staleness from the bot-comment-bumped updatedAt field (#6843)"

assert_doc_contains "$CHAMPION_MD" \
    'PR_DATA=$(gh pr view <number> --json createdAt,commits,comments)' \
    "criterion #5 reads commits + comments (+ createdAt floor) instead of updatedAt (#6843)"

assert_doc_contains "$CHAMPION_MD" \
    'select((.body | test("champion:|Automated by Champion role")) | not) | .createdAt)' \
    "criterion #5's activity computation excludes Champion's own comments, mirroring the sticky-hold precheck's exclusion test (#6843)"

echo
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
[[ $TESTS_FAILED -eq 0 ]] || exit 1
