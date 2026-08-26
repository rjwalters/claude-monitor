#!/usr/bin/env bash
# Loom Urgent Flip Guard - forge-backed hysteresis around every `loom:urgent`
# label write made by the Guide role (issue #5643).
#
# Usage:
#   ./.loom/scripts/urgent-flip-guard.sh check <issue-number> <add|remove>
#   ./.loom/scripts/urgent-flip-guard.sh status <issue-number>
#
# Why this exists
# ----------------
# The Guide's "Maximum Urgent: 3 Issues" triage runs every 15-30 minutes, and
# more than one Guide invocation can be in flight at once (this host's daemon
# role runner, another fleet host's daemon, a manual `/loom:guide` session).
# Each tick used to recompute "the top 3" from scratch, so two ticks that
# ranked a boundary-case issue differently would each overwrite the other's
# decision. Observed on #5643: `loom:urgent` flipped on #5565 seven times in
# ~2.5 hours at exactly Guide-tick cadence, and because the Guide's Document
# Maintenance phase regenerates WORK_PLAN.md's Urgent section from live label
# state, each flip manufactured a fresh `docs: Guide document maintenance
# update` PR (12 merged in ~8.5h, several differing only by this one bullet).
#
# guide.md's incumbency rule is the primary fix: it makes the selection
# DETERMINISTIC given forge state (ties resolve for the incumbent), so two
# ticks reading the same state reach the same answer. This script is the
# backstop for the residual window where they do not — a genuinely new
# candidate appearing mid-tick, a rank re-read landing differently, an
# operator flipping the label by hand between ticks.
#
# Why not a lock (`docs-guide-lock.sh`)
# --------------------------------------
# `docs-guide-lock.sh` is a local `mkdir` under this checkout's `.loom/locks/`
# and therefore SAME-HOST ONLY (#5615, documented in its own header). The
# #5643 flap is explicitly cross-host: independent daemons on independent
# hosts, each with their own filesystem. A local lock provides exactly zero
# mutual exclusion for it.
#
# The only state every fleet host demonstrably shares is the forge itself, so
# this guard is a CAS-style read of the forge's own `loom:urgent` label-event
# history for the issue — the durable, cross-host decision record the flap was
# missing. It answers one question before each write:
#
#   "Does this write REVERSE a loom:urgent decision that was made recently
#    enough that it was almost certainly another tick's, not a real priority
#    change?"
#
# Three suppression rules
# ------------------------
#   0. ALREADY-SATISFIED-BY-AN-OPEN-PR (`add` only, issue #6975/#5911). If the
#      issue's own `closedByPullRequestsReferences` links an OPEN pull request
#      that already carries `loom:pr`, the issue is fully implemented and
#      Judge-approved -- it is waiting on a human merge decision, not on more
#      urgency. guide.md documents this same lookup as
#      `has_open_pr_labeled_loom_pr()` and used to rely on every Guide tick
#      remembering to call it inline before promoting; that prose-only
#      invariant was skipped three separate times by three separate ticks
#      (#6975), so this script -- the one place every `loom:urgent add` write
#      is already required to pass through -- is now the authoritative,
#      mechanically-enforced copy of the check. guide.md's inline call stays
#      only as a cheap pre-filter for ranking, exactly as
#      `urgent-flip-guard.sh` already became the authority for cooldown/flap
#      over the two rules below (#5643).
#
#      Deliberately `add`-only, same shape as the flap-freeze below: an issue
#      already `loom:urgent` may still be legitimately demoted (e.g. by the
#      incumbency rule) once its PR lands, and demotion must never be blocked.
#
#      This rule's own PR-linkage lookup is FAIL-OPEN, not fail-closed like
#      the history read below -- a rate limit or forge hiccup on this one
#      probe must never block an otherwise-legitimate promotion, the same
#      posture guide.md's `has_open_pr_labeled_loom_pr()` /
#      `has_operator_only()` already document.
#
#   1. REVERSAL-WITHIN-COOLDOWN (both directions). If the most recent
#      `loom:urgent` labeled/unlabeled event on the issue is younger than
#      LOOM_URGENT_FLIP_COOLDOWN_SECS and the requested write reverses it,
#      suppress. The default (10800s / 3h) spans at least six consecutive
#      Guide ticks at the slowest documented 30-minute cadence, so a run of
#      disagreeing ticks structurally cannot undo each other; replayed against
#      #5565's real 2026-08-07 timeline it turns 7 flips in 2.5h into 1.
#
#      This is what keeps the "a real priority change must still displace a
#      current top-3 holder" criterion true: the cooldown gates RECENCY, not
#      merit, and only for the ONE issue whose decision is fresh. Promoting a
#      brand-new candidate is never delayed (it has no recent event), and a
#      swap is only delayed if EVERY current holder was promoted within the
#      last three hours -- in which case the honest answer is that the set was
#      just deliberately chosen. Use a comment to communicate urgency in the
#      meantime, and lower LOOM_URGENT_FLIP_COOLDOWN_SECS for a repo whose
#      triage genuinely moves faster than that.
#
#   2. FLAP-FREEZE (`add` only). If the issue already accumulated
#      LOOM_URGENT_FLAP_THRESHOLD or more `loom:urgent` events inside
#      LOOM_URGENT_FLAP_WINDOW_SECS, it is demonstrably flapping; freeze
#      further promotions until those events age out of the window (so the
#      freeze is self-healing, never permanent).
#
#      Deliberately asymmetric: freezing `add` breaks the oscillation (an
#      issue can leave the urgent set but not re-enter it) WITHOUT ever
#      stranding a 4th urgent label, which a symmetric freeze could do by
#      blocking the removal that restores the "max 3" cap. That invariant is
#      unchanged by this guard.
#
# Fail-closed (history), fail-open (PR linkage)
# -----------------------------------------------
# If the loom:urgent label history cannot be read at all (forge outage, wedged
# `gh`, auth failure), the answer is SUPPRESS, not ALLOW — the same "a probe
# that could not answer at all blocks the write" stance guide.md's #5511
# open-linked-PR gate already takes for label writes. Skipping one tick's
# urgency update is cheap; resuming an unbounded flap is not.
#
# Rule 0's separate PR-linkage lookup is the one deliberate exception: if IT
# cannot be completed, this script does NOT suppress on its account — see
# "0. ALREADY-SATISFIED-BY-AN-OPEN-PR" above for why.
#
# Exit codes:
#   0  ALLOW    - proceed with the label write
#   1  SUPPRESS - do NOT write the label this tick
#   2  usage / configuration error
#
# stdout carries one machine-readable verdict line (`ALLOW reason=... ` /
# `SUPPRESS reason=...`); human-readable detail goes to stderr.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_error() { echo -e "${RED}ERROR: $1${NC}" >&2; }
print_info() { echo -e "${BLUE}ℹ $1${NC}" >&2; }
print_warn() { echo -e "${YELLOW}⚠ $1${NC}" >&2; }
print_success() { echo -e "${GREEN}✓ $1${NC}" >&2; }

URGENT_LABEL="loom:urgent"

show_help() {
    cat <<'EOF'
Loom Urgent Flip Guard

Usage:
  ./.loom/scripts/urgent-flip-guard.sh check <issue-number> <add|remove>
  ./.loom/scripts/urgent-flip-guard.sh status <issue-number>

Cross-host hysteresis around the Guide role's `loom:urgent` label writes
(issue #5643). Reads the issue's own loom:urgent label-event history from the
forge -- the only decision record every fleet host shares -- and refuses a
write that would reverse a decision made too recently to be anything but
another Guide tick's.

Commands:
  check   Exit 0 to proceed with the write, 1 to skip it this tick.
  status  Print a JSON summary of the issue's loom:urgent history (exit 0),
          or exit 1 if the history could not be read.

Tunables (env vars):
  LOOM_URGENT_FLIP_COOLDOWN_SECS  Window in which a loom:urgent decision may
                                  not be reversed (default 10800 = 3h, at
                                  least six of the Guide's 15-30m ticks).
  LOOM_URGENT_FLAP_THRESHOLD      loom:urgent events inside the flap window
                                  that freeze further promotions (default 4).
  LOOM_URGENT_FLAP_WINDOW_SECS    Flap-detection window (default 86400 = 24h).

Test seams (unset in normal operation):
  LOOM_URGENT_GUARD_EVENTS_FILE     Read the event list from this JSON file
                                    (same shape as the GitHub issue-events API)
                                    instead of calling `gh api`.
  LOOM_URGENT_GUARD_NOW             Treat this epoch-seconds value as "now".
  LOOM_URGENT_GUARD_ISSUE_PRS_FILE  Read the issue's linked PR numbers from
                                    this JSON file (a bare array, e.g. `[456]`)
                                    instead of `gh issue view
                                    --json closedByPullRequestsReferences`.
  LOOM_URGENT_GUARD_PR_DETAILS_FILE Read linked-PR state/labels from this JSON
                                    file (an object keyed by PR number, e.g.
                                    `{"456": {"state": "OPEN", "labels":
                                    [{"name": "loom:pr"}]}}`) instead of `gh pr
                                    view --json state,labels`.

Exit codes: 0 = allow, 1 = suppress, 2 = usage/configuration error.
EOF
}

CMD="${1:-}"
if [[ "$CMD" == "--help" ]] || [[ "$CMD" == "-h" ]]; then
    show_help
    exit 0
fi
if [[ "$CMD" != "check" ]] && [[ "$CMD" != "status" ]]; then
    print_error "Unknown or missing command: '${CMD}'"
    show_help >&2
    exit 2
fi

ISSUE="${2:-}"
if ! [[ "$ISSUE" =~ ^[0-9]+$ ]]; then
    print_error "Expected an issue number, got: '${ISSUE}'"
    show_help >&2
    exit 2
fi

DIRECTION=""
if [[ "$CMD" == "check" ]]; then
    DIRECTION="${3:-}"
    if [[ "$DIRECTION" != "add" ]] && [[ "$DIRECTION" != "remove" ]]; then
        print_error "Expected direction 'add' or 'remove', got: '${DIRECTION}'"
        show_help >&2
        exit 2
    fi
fi

# --- Tunables ----------------------------------------------------------------
LOOM_URGENT_FLIP_COOLDOWN_SECS="${LOOM_URGENT_FLIP_COOLDOWN_SECS:-10800}"
LOOM_URGENT_FLAP_THRESHOLD="${LOOM_URGENT_FLAP_THRESHOLD:-4}"
LOOM_URGENT_FLAP_WINDOW_SECS="${LOOM_URGENT_FLAP_WINDOW_SECS:-86400}"

_require_uint() { # <name> <value>
    if ! [[ "$2" =~ ^[0-9]+$ ]]; then
        print_error "$1 must be a non-negative integer (got: '$2')"
        exit 2
    fi
}
_require_uint LOOM_URGENT_FLIP_COOLDOWN_SECS "$LOOM_URGENT_FLIP_COOLDOWN_SECS"
_require_uint LOOM_URGENT_FLAP_THRESHOLD "$LOOM_URGENT_FLAP_THRESHOLD"
_require_uint LOOM_URGENT_FLAP_WINDOW_SECS "$LOOM_URGENT_FLAP_WINDOW_SECS"

NOW="${LOOM_URGENT_GUARD_NOW:-$(date -u +%s)}"
_require_uint LOOM_URGENT_GUARD_NOW "$NOW"

# --- ISO-8601 -> epoch (portable across GNU date and BSD/macOS date) ---------
# Echoes nothing and returns 1 when the stamp cannot be parsed, so an
# unparseable event is dropped rather than silently treated as "now".
_iso_to_epoch() { # <YYYY-MM-DDTHH:MM:SSZ>
    local ts="$1" out
    out="$(date -u -d "$ts" +%s 2>/dev/null)" && [[ "$out" =~ ^[0-9]+$ ]] && { echo "$out"; return 0; }
    out="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null)" && [[ "$out" =~ ^[0-9]+$ ]] && { echo "$out"; return 0; }
    return 1
}

# --- Read the loom:urgent label-event history --------------------------------
# One line per event, oldest first: "<created_at> <labeled|unlabeled>".
#
# The forge is the shared, cross-host decision record; a local file would only
# ever describe this host (the #5615 lesson). LOOM_URGENT_GUARD_EVENTS_FILE
# exists solely so the regression suite can drive real timelines hermetically.
EVENTS_JQ=".[] | select(.event == \"labeled\" or .event == \"unlabeled\") | select(.label.name == \"$URGENT_LABEL\") | \"\\(.created_at) \\(.event)\""

read_events() {
    local raw rc=0
    if [[ -n "${LOOM_URGENT_GUARD_EVENTS_FILE:-}" ]]; then
        [[ -f "$LOOM_URGENT_GUARD_EVENTS_FILE" ]] || return 1
        raw="$(jq -r "$EVENTS_JQ" "$LOOM_URGENT_GUARD_EVENTS_FILE" 2>/dev/null)" || rc=$?
    else
        raw="$(gh api "repos/{owner}/{repo}/issues/${ISSUE}/events" --paginate \
            --jq "$EVENTS_JQ" 2>/dev/null)" || rc=$?
    fi
    [[ "$rc" -eq 0 ]] || return 1
    # ISO-8601 UTC stamps sort lexicographically, which is also chronological.
    printf '%s\n' "$raw" | grep -v '^$' | sort || true
    return 0
}

EVENTS=""
if ! EVENTS="$(read_events)"; then
    # Fail closed: an unanswerable probe blocks the write (see header).
    print_error "Could not read ${URGENT_LABEL} label history for #${ISSUE} (forge unreachable, auth failure, or wedged gh)."
    if [[ "$CMD" == "status" ]]; then
        exit 1
    fi
    echo "SUPPRESS reason=history-unreadable issue=${ISSUE} direction=${DIRECTION}"
    print_warn "Suppressing the ${URGENT_LABEL} ${DIRECTION} on #${ISSUE} — history could not be verified."
    exit 1
fi

EVENT_COUNT=0
LAST_EVENT=""
LAST_EVENT_AT=""
LAST_EVENT_EPOCH=""
FLAP_COUNT=0

while IFS=' ' read -r ts kind; do
    [[ -n "$ts" ]] || continue
    epoch="$(_iso_to_epoch "$ts")" || continue
    EVENT_COUNT=$((EVENT_COUNT + 1))
    LAST_EVENT="$kind"
    LAST_EVENT_AT="$ts"
    LAST_EVENT_EPOCH="$epoch"
    if (( NOW - epoch <= LOOM_URGENT_FLAP_WINDOW_SECS )); then
        FLAP_COUNT=$((FLAP_COUNT + 1))
    fi
done <<< "$EVENTS"

LAST_AGE=""
if [[ -n "$LAST_EVENT_EPOCH" ]]; then
    if (( NOW > LAST_EVENT_EPOCH )); then
        LAST_AGE=$(( NOW - LAST_EVENT_EPOCH ))
    else
        LAST_AGE=0
    fi
fi

# The label state implied by the history: the newest event wins.
CURRENT_STATE="absent"
if [[ "$LAST_EVENT" == "labeled" ]]; then
    CURRENT_STATE="present"
fi

if [[ "$CMD" == "status" ]]; then
    jq -n \
        --argjson issue "$ISSUE" \
        --arg state "$CURRENT_STATE" \
        --arg last_event "${LAST_EVENT:-}" \
        --arg last_event_at "${LAST_EVENT_AT:-}" \
        --argjson last_event_age_secs "${LAST_AGE:-null}" \
        --argjson total_events "$EVENT_COUNT" \
        --argjson events_in_flap_window "$FLAP_COUNT" \
        --argjson cooldown_secs "$LOOM_URGENT_FLIP_COOLDOWN_SECS" \
        --argjson flap_threshold "$LOOM_URGENT_FLAP_THRESHOLD" \
        --argjson flap_window_secs "$LOOM_URGENT_FLAP_WINDOW_SECS" \
        '{issue: $issue, urgent_state: $state, last_event: $last_event,
          last_event_at: $last_event_at, last_event_age_secs: $last_event_age_secs,
          total_events: $total_events, events_in_flap_window: $events_in_flap_window,
          cooldown_secs: $cooldown_secs, flap_threshold: $flap_threshold,
          flap_window_secs: $flap_window_secs,
          flapping: ($events_in_flap_window >= $flap_threshold)}'
    exit 0
fi

# --- Rule 0: already satisfied by an open loom:pr-labeled linked PR (add only)
# See "0. ALREADY-SATISFIED-BY-AN-OPEN-PR" in the header. Two lookups, mirroring
# guide.md's `has_open_pr_labeled_loom_pr()`: the issue's own closes-graph, then
# each linked PR's state/labels. FAIL-OPEN on either lookup -- a probe that
# could not answer must never block an otherwise-legitimate promotion.

# Issue -> newline-separated linked PR numbers. Empty output (rc 0) on a clean
# "no linked PRs"; non-zero rc means the lookup itself failed.
_read_issue_linked_prs() { # <issue-number>
    local number="$1" raw rc=0
    if [[ -n "${LOOM_URGENT_GUARD_ISSUE_PRS_FILE:-}" ]]; then
        [[ -f "$LOOM_URGENT_GUARD_ISSUE_PRS_FILE" ]] || return 1
        raw="$(jq -r '.[]' "$LOOM_URGENT_GUARD_ISSUE_PRS_FILE" 2>/dev/null)" || rc=$?
    else
        raw="$(gh issue view "$number" --json closedByPullRequestsReferences \
            --jq '.closedByPullRequestsReferences[].number' 2>/dev/null)" || rc=$?
    fi
    [[ "$rc" -eq 0 ]] || return 1
    printf '%s\n' "$raw"
    return 0
}

# PR number -> "true"/"false" (open AND labeled loom:pr). Non-zero rc means
# this one PR's lookup failed (skip it, don't treat as a match or a block).
_pr_is_open_loom_pr() { # <pr-number>
    local pr="$1" pr_json rc=0
    if [[ -n "${LOOM_URGENT_GUARD_PR_DETAILS_FILE:-}" ]]; then
        [[ -f "$LOOM_URGENT_GUARD_PR_DETAILS_FILE" ]] || return 1
        pr_json="$(jq -c --arg pr "$pr" '.[$pr] // empty' "$LOOM_URGENT_GUARD_PR_DETAILS_FILE" 2>/dev/null)" || rc=$?
        [[ "$rc" -eq 0 ]] && [[ -n "$pr_json" ]] || return 1
    else
        pr_json="$(gh pr view "$pr" --json state,labels 2>/dev/null)" || return 1
    fi
    # NOTE: `printf '%s\n' "$VAR" | jq`, never `echo "$VAR" | jq` -- zsh's
    # `echo` builtin reinterprets `\n`/`\t` escapes by default, which would
    # corrupt captured JSON before jq ever parses it (#5094).
    local pr_state pr_has_loom_pr
    pr_state="$(printf '%s\n' "$pr_json" | jq -r '.state' 2>/dev/null)" || return 1
    pr_has_loom_pr="$(printf '%s\n' "$pr_json" | jq -r '[.labels[].name] | any(. == "loom:pr")' 2>/dev/null)" || return 1
    if [[ "$pr_state" == "OPEN" ]] && [[ "$pr_has_loom_pr" == "true" ]]; then
        echo "true"
    else
        echo "false"
    fi
    return 0
}

# Issue -> the PR number of its first open loom:pr-labeled linked PR, or empty
# if none exists OR either lookup failed (fail open in both cases).
_find_open_loom_pr_link() { # <issue-number>
    local number="$1" prs pr verdict
    prs="$(_read_issue_linked_prs "$number")" || return 0
    for pr in $prs; do
        [[ -n "$pr" ]] || continue
        verdict="$(_pr_is_open_loom_pr "$pr")" || continue
        if [[ "$verdict" == "true" ]]; then
            echo "$pr"
            return 0
        fi
    done
    return 0
}

if [[ "$DIRECTION" == "add" ]]; then
    OPEN_LOOM_PR="$(_find_open_loom_pr_link "$ISSUE")"
    if [[ -n "$OPEN_LOOM_PR" ]]; then
        echo "SUPPRESS reason=open-loom-pr issue=${ISSUE} direction=add linked_pr=${OPEN_LOOM_PR}"
        print_warn "#${ISSUE} already has an open PR #${OPEN_LOOM_PR} labeled loom:pr — it is implemented and awaiting a human merge decision, not ready work (#5911/#6975)."
        print_info "Leaving the label alone. Reviewing/merging #${OPEN_LOOM_PR} is the next step here, not more urgency."
        exit 1
    fi
fi

# --- Rule 2: flap-freeze (promotions only) -----------------------------------
# Checked before the cooldown so a demonstrably flapping issue reports the
# more informative reason. `remove` is deliberately exempt: freezing it could
# strand a 4th loom:urgent label and break the "max 3" invariant this guard
# must leave untouched.
if [[ "$DIRECTION" == "add" ]] && (( FLAP_COUNT >= LOOM_URGENT_FLAP_THRESHOLD )); then
    echo "SUPPRESS reason=flapping issue=${ISSUE} direction=add events_in_window=${FLAP_COUNT} threshold=${LOOM_URGENT_FLAP_THRESHOLD} window_secs=${LOOM_URGENT_FLAP_WINDOW_SECS}"
    print_warn "#${ISSUE} has ${FLAP_COUNT} ${URGENT_LABEL} events in the last ${LOOM_URGENT_FLAP_WINDOW_SECS}s (threshold ${LOOM_URGENT_FLAP_THRESHOLD}) — it is flapping."
    print_info "Leave the label alone and post a comment instead if urgency genuinely needs communicating. Promotions unfreeze automatically as those events age out of the window."
    exit 1
fi

# --- Rule 1: reversal within the cooldown (both directions) ------------------
if [[ -n "$LAST_EVENT" ]] && (( LAST_AGE < LOOM_URGENT_FLIP_COOLDOWN_SECS )); then
    REVERSES=0
    if [[ "$DIRECTION" == "add" && "$LAST_EVENT" == "unlabeled" ]]; then
        REVERSES=1
    elif [[ "$DIRECTION" == "remove" && "$LAST_EVENT" == "labeled" ]]; then
        REVERSES=1
    fi
    if (( REVERSES == 1 )); then
        echo "SUPPRESS reason=reversal-within-cooldown issue=${ISSUE} direction=${DIRECTION} last_event=${LAST_EVENT} last_event_age_secs=${LAST_AGE} cooldown_secs=${LOOM_URGENT_FLIP_COOLDOWN_SECS}"
        print_warn "#${ISSUE} was ${LAST_EVENT} ${URGENT_LABEL} only ${LAST_AGE}s ago (cooldown ${LOOM_URGENT_FLIP_COOLDOWN_SECS}s) — this write would reverse another tick's decision."
        print_info "Leaving the label as-is. It becomes reversible again once the decision is older than the cooldown, so a real priority change is delayed at most one tick, never blocked."
        exit 1
    fi
fi

REASON="no-recent-conflict"
if [[ "$EVENT_COUNT" -eq 0 ]]; then
    REASON="no-history"
fi
echo "ALLOW reason=${REASON} issue=${ISSUE} direction=${DIRECTION} last_event=${LAST_EVENT:-none} last_event_age_secs=${LAST_AGE:-none} events_in_window=${FLAP_COUNT}"
print_success "${URGENT_LABEL} ${DIRECTION} on #${ISSUE} is clear to apply (${REASON})."
exit 0
