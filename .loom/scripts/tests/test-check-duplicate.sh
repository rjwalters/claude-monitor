#!/usr/bin/env bash
# test-check-duplicate.sh - Unit tests for check-duplicate.sh's --issue
# cross-reference probe (issue #4162).
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
# EOF, not sourced functions), so we stub `gh` and `loom-forge` on PATH and
# invoke the real script as a subprocess, asserting on stdout/exit code.
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

# --- Stub loom-forge: present on PATH but deliberately non-functional, so
# check-duplicate.sh's `loom-forge --version` probe fails and it falls back
# to the `gh` stub below (byte-for-byte the documented fallback path,
# defaults/scripts/check-duplicate.sh:35-42). Keeps this test independent of
# whether a real loom-forge happens to be installed on the host. ---
cat > "$STUB_DIR/loom-forge" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$STUB_DIR/loom-forge"

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

# --- Summary ---
echo ""
echo "────────────────────────────────"
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
exit 0
