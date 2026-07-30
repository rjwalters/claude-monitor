#!/usr/bin/env bash
# test-check-duplicate.sh - Unit tests for check-duplicate.sh's --issue
# cross-reference probe (issue #4162) and its keyword-similarity scoring
# (issue #4409).
#
# check-duplicate.sh's existing keyword-similarity check answers "has this
# been reported before?" -- it is structurally blind to an OPEN issue that
# *critiques* the target's spec (a cross-reference in its body) without being
# textually similar. This mirrors a real incident (rjwalters/repo #32/#33):
# #33 named #32 three times in its body, arguing #32's acceptance criteria
# were wrong, but was never surfaced because it wasn't a *duplicate* -- it
# was a *related, spec-changing* piece of open work.
#
# `check-duplicate.sh --issue N` closes this gap by querying GitHub's
# timeline API for open issues/PRs that cross-reference N, emitting a
# RELATED_OPEN_WORK block distinct from DUPLICATE_FOUND. This is a
# black-box test: check-duplicate.sh is a full CLI script (main "$@" at
# EOF, not sourced functions), so we stub `gh` and `loom-daemon` on PATH and
# invoke the real script as a subprocess, asserting on stdout/exit code.
#
# Issue #4409 fixed two compounding bugs in calculate_similarity(): (1) `read
# -ra arr <<< "$multiline_str"` only ever consumes ONE line, so a multi-keyword
# (i.e. any realistically-worded) title/body collapsed to a single-element
# array -- comparisons became a coin flip on one token instead of a real set
# comparison; (2) even with arrays populated correctly, normalizing by the
# SMALLER set saturated near 100% whenever a large query keyword set was
# compared against a small candidate set. The tests below use small,
# hand-built keyword sets (plain English words, no stopwords) run through the
# real CLI against a stubbed candidate pool, so the resulting percentages are
# exact and checkable by hand (see comments at each candidate).
#
# Usage:
#   ./.loom/scripts/tests/test-check-duplicate.sh

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)"
CDS="$SCRIPTS_DIR/check-duplicate.sh"

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
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${NC}: $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${NC}: $msg"
        echo "    Expected substring: '$needle'"
        echo "    In: '$haystack'"
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" msg="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if ! printf '%s' "$haystack" | grep -qF -- "$needle"; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${GREEN}PASS${NC}: $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${RED}FAIL${NC}: $msg"
        echo "    Unexpected substring: '$needle'"
        echo "    In: '$haystack'"
    fi
}

if [[ ! -x "$CDS" ]]; then
    echo -e "${RED}FATAL${NC}: $CDS not found or not executable" >&2
    exit 2
fi

STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR" 2>/dev/null || true' EXIT

# --- Stub loom-daemon: present on PATH but deliberately non-functional, so
# check-duplicate.sh's `loom-daemon --version` probe fails and it falls back
# to the `gh` stub below (byte-for-byte the documented fallback path,
# defaults/scripts/check-duplicate.sh). Keeps this test independent of
# whether a real loom-daemon happens to be installed on the host. ---
cat > "$STUB_DIR/loom-daemon" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$STUB_DIR/loom-daemon"

# --- Stub gh on PATH ---
#   gh auth status                                     -> exit 0 (authenticated)
#   gh repo view --json nameWithOwner --jq ...          -> "owner/repo" (or fail
#                                                          if $STUB_DIR/repo-view-fail exists)
#   gh issue list --state=open|closed ...               -> cat $STUB_DIR/issues-<state>.json (or [])
#   gh pr list --state=merged ...                        -> cat $STUB_DIR/prs-merged.json (or [])
#   gh api repos/OWNER/REPO/issues/N/timeline --paginate -> cat $STUB_DIR/timeline-N.json (or [];
#                                                           fails if $STUB_DIR/timeline-fail exists)
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
STUB_DIR_FROM_ENV="${LOOM_TEST_STUB_DIR:?stub gh: LOOM_TEST_STUB_DIR not set}"

case "$1" in
  auth)
    exit 0
    ;;
  repo)
    if [[ -f "$STUB_DIR_FROM_ENV/repo-view-fail" ]]; then
      echo "stub gh: repo view failed" >&2
      exit 1
    fi
    echo "owner/repo"
    exit 0
    ;;
  issue)
    if [[ "$2" == "list" ]]; then
      state="open"
      shift 2
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --state=*) state="${1#--state=}" ;;
        esac
        shift
      done
      canned="$STUB_DIR_FROM_ENV/issues-$state.json"
      if [[ -f "$canned" ]]; then cat "$canned"; else echo "[]"; fi
      exit 0
    fi
    echo "stub gh: unhandled issue args: $*" >&2
    exit 3
    ;;
  pr)
    if [[ "$2" == "list" ]]; then
      canned="$STUB_DIR_FROM_ENV/prs-merged.json"
      if [[ -f "$canned" ]]; then cat "$canned"; else echo "[]"; fi
      exit 0
    fi
    echo "stub gh: unhandled pr args: $*" >&2
    exit 3
    ;;
  api)
    if [[ -f "$STUB_DIR_FROM_ENV/timeline-fail" ]]; then
      echo "stub gh: api call failed" >&2
      exit 1
    fi
    path="$2"
    num="${path%/timeline}"
    num="${num##*/}"
    canned="$STUB_DIR_FROM_ENV/timeline-$num.json"
    if [[ -f "$canned" ]]; then cat "$canned"; else echo "[]"; fi
    exit 0
    ;;
  *)
    echo "stub gh: unhandled args: $*" >&2
    exit 3
    ;;
esac
STUB
chmod +x "$STUB_DIR/gh"

export LOOM_TEST_STUB_DIR="$STUB_DIR"
export PATH="$STUB_DIR:$PATH"

reset_state() {
    rm -f "$STUB_DIR"/issues-*.json "$STUB_DIR"/prs-merged.json "$STUB_DIR"/timeline-*.json
    rm -f "$STUB_DIR/timeline-fail" "$STUB_DIR/repo-view-fail"
}

run_cds() {
    # Runs check-duplicate.sh, capturing stdout to $OUT, stderr to $ERR, exit to $RC.
    OUT="$("$CDS" "$@" 2>"$STUB_DIR/stderr.log")"
    RC=$?
    ERR="$(cat "$STUB_DIR/stderr.log" 2>/dev/null || true)"
}

echo "Testing check-duplicate.sh --issue cross-reference probe..."

# (a) Open cross-referencing issue -> RELATED_OPEN_WORK block, exit 1.
# Mirrors the rjwalters/repo #32/#33 incident: querying #32 surfaces open #33.
reset_state
cat > "$STUB_DIR/timeline-32.json" <<'EOF'
[
  {"event": "labeled", "source": {}},
  {"event": "cross-referenced", "source": {"type": "issue", "issue": {
      "number": 33, "title": "Rework #32's acceptance criteria", "state": "open",
      "repository": {"full_name": "owner/repo"}}}}
]
EOF
run_cds --issue 32 --title "Some issue title" --body "Some issue body"
assert_eq "1" "$RC" "(a) Open cross-reference present -> exit 1"
assert_contains "$OUT" "RELATED_OPEN_WORK" "(a) RELATED_OPEN_WORK header present"
assert_contains "$OUT" "#33: Rework #32's acceptance criteria (open issue, cross-references #32)" \
  "(a) Cross-referencing issue #33 listed with correct format"
assert_not_contains "$OUT" "DUPLICATE_FOUND" "(a) No keyword-similarity duplicates found separately"

# (a2) Same fixture, but the cross-reference source is itself a PR.
reset_state
cat > "$STUB_DIR/timeline-32.json" <<'EOF'
[
  {"event": "cross-referenced", "source": {"type": "issue", "issue": {
      "number": 40, "title": "Implement alternate approach", "state": "open",
      "pull_request": {"url": "https://example.invalid"},
      "repository": {"full_name": "owner/repo"}}}}
]
EOF
run_cds --issue 32 --title "Some issue title"
assert_eq "1" "$RC" "(a2) Open cross-referencing PR -> exit 1"
assert_contains "$OUT" "PR #40: Implement alternate approach (open PR, cross-references #32)" \
  "(a2) Cross-referencing PR #40 listed with PR-specific format"

# (b) Closed cross-reference and self-reference are excluded.
reset_state
cat > "$STUB_DIR/timeline-50.json" <<'EOF'
[
  {"event": "cross-referenced", "source": {"type": "issue", "issue": {
      "number": 51, "title": "Closed related work", "state": "closed",
      "repository": {"full_name": "owner/repo"}}}},
  {"event": "cross-referenced", "source": {"type": "issue", "issue": {
      "number": 50, "title": "Self reference", "state": "open",
      "repository": {"full_name": "owner/repo"}}}}
]
EOF
run_cds --issue 50 --title "Some issue title"
assert_eq "0" "$RC" "(b) Only closed/self cross-references -> exit 0 (nothing to surface)"
assert_not_contains "$OUT" "RELATED_OPEN_WORK" "(b) No RELATED_OPEN_WORK block emitted"
assert_not_contains "$OUT" "#51" "(b) Closed cross-reference #51 excluded"
assert_not_contains "$OUT" "#50" "(b) Self-reference #50 excluded"

# (c) No cross-references at all -> behavior identical to a plain run.
reset_state
run_cds --issue 60 --title "Some issue title"
assert_eq "0" "$RC" "(c) No cross-references -> exit 0"
assert_not_contains "$OUT" "RELATED_OPEN_WORK" "(c) No RELATED_OPEN_WORK block when timeline is empty"

# (d) Invocation WITHOUT --issue is byte-identical to a --issue run with no
# cross-references (Architect/Hermit/Auditor non-regression: they never pass
# --issue, so their behavior must be untouched by this feature).
reset_state
run_cds --title "Some issue title"
OUT_NO_ISSUE="$OUT"
RC_NO_ISSUE="$RC"
run_cds --issue 60 --title "Some issue title"
assert_eq "$OUT_NO_ISSUE" "$OUT" "(d) --issue with no cross-refs -> output byte-identical to no --issue at all"
assert_eq "$RC_NO_ISSUE" "$RC" "(d) --issue with no cross-refs -> exit code identical to no --issue at all"

# (e) Timeline API failure -> probe skipped with a stderr warning, base
# similarity check result (and its exit code) is unaffected by the failure.
reset_state
: > "$STUB_DIR/timeline-fail"
run_cds --issue 70 --title "Some issue title"
assert_eq "0" "$RC" "(e) Timeline API failure -> exit code driven by similarity check alone"
assert_not_contains "$OUT" "RELATED_OPEN_WORK" "(e) Timeline API failure -> probe result skipped, not surfaced"
assert_contains "$ERR" "Failed to fetch timeline" "(e) Timeline API failure -> stderr warning emitted"

# (f) --json output includes a "cross_reference" typed entry.
reset_state
cat > "$STUB_DIR/timeline-32.json" <<'EOF'
[
  {"event": "cross-referenced", "source": {"type": "issue", "issue": {
      "number": 33, "title": "Rework #32's acceptance criteria", "state": "open",
      "repository": {"full_name": "owner/repo"}}}}
]
EOF
run_cds --issue 32 --title "Some issue title" --json
assert_eq "1" "$RC" "(f) --json with a cross-reference -> exit 1"
assert_contains "$OUT" '"type": "cross_reference"' "(f) --json output tags the entry as type cross_reference"
duplicate_found="$(echo "$OUT" | jq -r '.duplicate_found')"
assert_eq "true" "$duplicate_found" "(f) --json duplicate_found is true when only related work is present"
cross_num="$(echo "$OUT" | jq -r '.matches[] | select(.type == "cross_reference") | .number')"
assert_eq "33" "$cross_num" "(f) --json cross_reference entry carries the correct issue number"

# (g) Non-GitHub-forge-style failure (repo can't be resolved) degrades
# gracefully: probe skipped, similarity check unaffected, no hard failure.
reset_state
: > "$STUB_DIR/repo-view-fail"
run_cds --issue 80 --title "Some issue title"
assert_eq "0" "$RC" "(g) repo view failure -> exit code driven by similarity check alone"
assert_not_contains "$OUT" "RELATED_OPEN_WORK" "(g) repo view failure -> probe result skipped"
assert_contains "$ERR" "Failed to resolve repository" "(g) repo view failure -> stderr warning emitted"

echo ""
echo "Testing check-duplicate.sh keyword-similarity scoring (issue #4409)..."

# All fixtures below use NATO-alphabet words (alpha, bravo, ...) as keywords:
# real English words, none of them in extract_keywords' stopword list, all
# >= 3 chars, so every keyword survives extraction and the resulting Jaccard
# percentages (matches * 100 / (|A| + |B| - matches)) are exact and easy to
# verify by hand.

# (h) Identical keyword sets -> 100% similarity (union == intersection).
reset_state
cat > "$STUB_DIR/issues-open.json" <<'EOF'
[{"number": 501, "title": "Alpha Bravo Charlie Delta", "body": ""}]
EOF
run_cds --threshold 50 --title "Alpha Bravo Charlie Delta"
assert_eq "1" "$RC" "(h) Identical keyword sets -> exit 1 (duplicate found)"
assert_contains "$OUT" "#501: Alpha Bravo Charlie Delta (similarity: 100%)" \
  "(h) Identical keyword sets score exactly 100%"

# (i) Disjoint keyword sets -> 0% similarity, never flagged even at a
# near-zero threshold.
reset_state
cat > "$STUB_DIR/issues-open.json" <<'EOF'
[{"number": 502, "title": "Yankee Zulu Xray Whiskey", "body": ""}]
EOF
run_cds --threshold 1 --title "Alpha Bravo Charlie Delta"
assert_eq "0" "$RC" "(i) Disjoint keyword sets -> exit 0 (no duplicate)"
assert_not_contains "$OUT" "DUPLICATE_FOUND" "(i) Disjoint keyword sets never flagged"

# (j) Partial overlap -> exact Jaccard percentage, not the old
# matches/min(|A|,|B|) normalization. Query {alpha,bravo,charlie,delta} (4)
# vs candidate {alpha,bravo,echo,foxtrot,golf} (5): matches=2 (alpha,bravo),
# union=4+5-2=7, percent=2*100/7=28 (integer division). The pre-#4409
# min-set normalization would have scored this matches/min(4,5)=2/4=50% --
# a materially different (and saturating) number.
reset_state
cat > "$STUB_DIR/issues-open.json" <<'EOF'
[{"number": 503, "title": "Alpha Bravo Echo Foxtrot Golf", "body": ""}]
EOF
run_cds --threshold 28 --title "Alpha Bravo Charlie Delta"
assert_eq "1" "$RC" "(j) Partial overlap at threshold==percent -> exit 1"
assert_contains "$OUT" "#503: Alpha Bravo Echo Foxtrot Golf (similarity: 28%)" \
  "(j) Partial overlap scores exact true-Jaccard percentage (28%, not 50%)"
run_cds --threshold 29 --title "Alpha Bravo Charlie Delta"
assert_eq "0" "$RC" "(j) Partial overlap just below threshold -> exit 0"
assert_not_contains "$OUT" "DUPLICATE_FOUND" "(j) 28% does not clear a 29% threshold"

# (k) Empty keyword set on the CANDIDATE side (all stopwords) -> the existing
# early-return in calculate_similarity (arr2 has 0 elements) must still yield
# 0%, not a crash or division by zero.
reset_state
cat > "$STUB_DIR/issues-open.json" <<'EOF'
[{"number": 504, "title": "The Is Are", "body": ""}]
EOF
run_cds --threshold 1 --title "Alpha Bravo Charlie Delta"
assert_eq "0" "$RC" "(k) All-stopword candidate -> empty keyword set -> exit 0, no crash"
assert_not_contains "$OUT" "DUPLICATE_FOUND" "(k) Empty candidate keyword set never matches"

# (k2) Empty keyword set on the QUERY side (title is entirely stopwords) --
# search_similar_issues' own early return (before ever calling
# calculate_similarity), with a warning on stderr and no forge calls.
reset_state
run_cds --title "Is Are Was"
assert_eq "0" "$RC" "(k2) All-stopword query title -> exit 0, no crash"
assert_contains "$ERR" "No significant keywords" "(k2) All-stopword query title warns on stderr"

# (l) One-word title on both sides: identical single-keyword sets -> 100%,
# disjoint single-keyword sets -> 0%.
reset_state
cat > "$STUB_DIR/issues-open.json" <<'EOF'
[
  {"number": 505, "title": "Alpha", "body": ""},
  {"number": 506, "title": "Bravo", "body": ""}
]
EOF
run_cds --threshold 50 --title "Alpha"
assert_eq "1" "$RC" "(l) One-word query matches its identical one-word candidate"
assert_contains "$OUT" "#505: Alpha (similarity: 100%)" "(l) Identical one-word sets score 100%"
assert_not_contains "$OUT" "#506" "(l) Disjoint one-word candidate (Bravo) not matched"

# (m) Degenerate-result self-detection: when more than half of the scanned
# candidates score >= threshold, the search must self-announce
# NON_DISCRIMINATIVE instead of dumping a DUPLICATE_FOUND wall. Query has 7
# keywords; of 4 open-issue candidates, 3 share enough keywords to clear the
# default --threshold (18) and 1 is unrelated:
#   #601 "Quantum flux widget"              -> matches=2/union=8  -> 25%
#   #602 "Capacitor reactor system"         -> matches=2/union=8  -> 25%
#   #603 "Completely unrelated banana fruit basket" -> matches=0  ->  0%
#   #604 "Core module driver suite"         -> matches=3/union=8  -> 37%
# matched=3 of scanned=4 -> 3*2=6 > 4 -> degenerate.
reset_state
cat > "$STUB_DIR/issues-open.json" <<'EOF'
[
  {"number": 601, "title": "Quantum flux widget", "body": ""},
  {"number": 602, "title": "Capacitor reactor system", "body": ""},
  {"number": 603, "title": "Completely unrelated banana fruit basket", "body": ""},
  {"number": 604, "title": "Core module driver suite", "body": ""}
]
EOF
run_cds --title "Quantum Flux Capacitor Reactor Core Module Driver"
assert_eq "1" "$RC" "(m) Degenerate result set -> still exit 1 (caller should not treat as safe)"
assert_contains "$OUT" "NON_DISCRIMINATIVE" "(m) Degenerate result set -> NON_DISCRIMINATIVE warning emitted"
assert_contains "$OUT" "3 of 4 candidates" "(m) NON_DISCRIMINATIVE reports matched/scanned counts"
assert_not_contains "$OUT" "DUPLICATE_FOUND" "(m) Degenerate result set -> no DUPLICATE_FOUND wall"

# (m2) Same fixture, --json: degenerate flag set, duplicate_found false,
# empty matches (a degenerate result is noise, not a real match list).
run_cds --title "Quantum Flux Capacitor Reactor Core Module Driver" --json
assert_eq "1" "$RC" "(m2) --json degenerate result -> exit 1"
degenerate_flag="$(echo "$OUT" | jq -r '.degenerate')"
assert_eq "true" "$degenerate_flag" "(m2) --json degenerate flag is true"
duplicate_found_flag="$(echo "$OUT" | jq -r '.duplicate_found')"
assert_eq "false" "$duplicate_found_flag" "(m2) --json duplicate_found is false for a degenerate (noise) result"
matches_len="$(echo "$OUT" | jq -r '.matches | length')"
assert_eq "0" "$matches_len" "(m2) --json matches is empty for a degenerate result"

# (n) Mixed real-match + degenerate-result header regression test: when
# --include-merged-prs turns up a REAL match in one pool (merged PRs) and a
# DEGENERATE result in the other (closed issues), the real match must still
# get a "DUPLICATE_FOUND" header -- an earlier draft of this fix required
# BOTH pools to be non-degenerate before adding the header, which silently
# swallowed a real duplicate whenever the other pool happened to be noisy.
reset_state
echo "[]" > "$STUB_DIR/issues-open.json"
cat > "$STUB_DIR/prs-merged.json" <<'EOF'
[
  {"number": 701, "title": "Quantum flux widget", "body": ""},
  {"number": 702, "title": "Zulu Yankee Xray", "body": ""},
  {"number": 703, "title": "Whiskey Tango Foxtrot", "body": ""}
]
EOF
cat > "$STUB_DIR/issues-closed.json" <<'EOF'
[
  {"number": 601, "title": "Quantum flux widget", "body": ""},
  {"number": 602, "title": "Capacitor reactor system", "body": ""},
  {"number": 603, "title": "Completely unrelated banana fruit basket", "body": ""},
  {"number": 604, "title": "Core module driver suite", "body": ""}
]
EOF
run_cds --include-merged-prs --title "Quantum Flux Capacitor Reactor Core Module Driver"
assert_eq "1" "$RC" "(n) Mixed real+degenerate -> exit 1"
assert_contains "$OUT" "DUPLICATE_FOUND" \
  "(n) A real match in one pool still gets a DUPLICATE_FOUND header even when the other pool is degenerate"
assert_contains "$OUT" "PR #701: Quantum flux widget (similarity: 25%)" \
  "(n) Real merged-PR match is listed under the header"
assert_contains "$OUT" "NON_DISCRIMINATIVE (closed issues)" \
  "(n) Degenerate closed-issues pool still self-announces alongside the real match"

# (o) Real historical duplicate pair, threshold calibration (#4409): #3551
# ("guard-destructive.sh emits PreToolUse decisions without hookEventName ->
# guard is a silent no-op") was closed with "Closing as already fixed. This
# is a duplicate of #3550" -- an actual confirmed duplicate from this repo's
# history, not a synthetic fixture. Titles only (both are real, verbatim):
# keyword sets {decisions,destructive,emits,guard,hookeventname,pretooluse,
# silent,without} (8) vs {ask,decisions,deny,destructive,discarded,guard,
# hookeventname,hookspecificoutput,missing,required,silently} (11); 4 shared
# words (decisions, destructive, guard, hookeventname); union=8+11-4=15;
# true Jaccard = 4*100/15 = 26% -- clears the calibrated default threshold
# (18, no --threshold flag passed here) even though the two titles share no
# common phrasing beyond individual keywords.
reset_state
cat > "$STUB_DIR/issues-open.json" <<'EOF'
[{"number": 3550, "title": "guard-destructive.sh: hookSpecificOutput missing required hookEventName -- deny/ask decisions silently discarded", "body": ""}]
EOF
run_cds --title "guard-destructive.sh emits PreToolUse decisions without hookEventName -> guard is a silent no-op"
assert_eq "1" "$RC" "(o) Real historical duplicate pair (#3550/#3551) -> exit 1 at the calibrated default threshold"
assert_contains "$OUT" "#3550" "(o) Real historical duplicate pair (#3550/#3551) -> flagged as a candidate"
assert_contains "$OUT" "(similarity: 26%)" "(o) Real historical duplicate pair scores the expected 26% true-Jaccard"

# --- Summary ---
echo ""
echo "────────────────────────────────"
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
exit 0
