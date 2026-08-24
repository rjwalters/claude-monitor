#!/usr/bin/env bash
# test-check-promotion-landed.sh - Unit tests for check-promotion-landed.sh
# (#6862).
#
# check-promotion-landed.sh finds a single issue that carries a
# "Champion Review: APPROVED" verdict comment but is missing `loom:issue`
# (Step 3b's promotion write silently failing to land, as it did on issue
# #6464 for 6 days), and with --apply either completes the promotion by
# recovering the tier the original verdict named, or escalates to an
# operator when the tier cannot be safely recovered.
#
# This is a black-box test: the script is a full CLI (no functions to
# source), so `gh` is stubbed on PATH and the real script is invoked as a
# subprocess, asserting on stdout / exit code / the stub's recorded writes.
# Real `jq` is used unstubbed. Mirrors the stubbing pattern in
# test-verdict-staleness-guard.sh and test-check-evaluating-staleness.sh.
#
# Usage:
#   ./.loom/scripts/tests/test-check-promotion-landed.sh

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)"
SUT="$SCRIPTS_DIR/check-promotion-landed.sh"

# Two `..` reaches repo-root/.claude/commands/loom for an INSTALLED copy
# (SCRIPTS_DIR is .loom/scripts there); one `..` reaches defaults/.claude/
# commands/loom when running inside this source repo (SCRIPTS_DIR is
# defaults/scripts) -- the two layouts differ in depth, so probe both rather
# than hard-coding one (mirrors test-champion-critical-file-check.sh, #6725).
if [[ -d "$SCRIPTS_DIR/../../.claude/commands/loom" ]]; then
    PROMPT_DIR="$(cd "$SCRIPTS_DIR/../../.claude/commands/loom" && pwd)"
else
    PROMPT_DIR="$(cd "$SCRIPTS_DIR/../.claude/commands/loom" && pwd)"
fi
CHAMPION_MD="$PROMPT_DIR/champion-issue-promo.md"

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

if [[ ! -x "$SUT" ]]; then
    echo -e "${RED}FATAL${NC}: $SUT not found or not executable" >&2
    exit 2
fi

STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR" 2>/dev/null || true' EXIT

# --- Stub gh on PATH ---------------------------------------------------
#   gh issue view <N> --json state,labels,comments -> cat $STUB_DIR/issue-<N>.json
#                                                       (fails if issue-fail-<N> exists)
#   gh issue view <N> --json labels                -> cat $STUB_DIR/verify-<N>.json
#                                                       (post-edit read-back; fails
#                                                        if verify-fail-<N> exists;
#                                                        falls back to issue-<N>.json's
#                                                        labels when no verify- fixture
#                                                        was staged, so tests that don't
#                                                        care about the read-back need
#                                                        no second fixture)
#   gh issue comment <N> --body <b>                 -> append to $STUB_DIR/comment-writes.log
#                                                       (fails if comment-fail-<N> exists)
#   gh issue edit <N> ...                           -> append to $STUB_DIR/edit-writes.log
#                                                       (fails if edit-fail-<N> exists)
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
STUB_DIR_FROM_ENV="${LOOM_TEST_STUB_DIR:?stub gh: LOOM_TEST_STUB_DIR not set}"
case "$1" in
  issue)
    case "$2" in
      view)
        num="$3"
        # Distinguish the initial combined read from the post-edit
        # read-back by the requested --json fields.
        json_fields=""
        for a in "$@"; do
          if [[ "$prev" == "--json" ]]; then json_fields="$a"; fi
          prev="$a"
        done
        if [[ "$json_fields" == "labels" ]]; then
          if [[ -f "$STUB_DIR_FROM_ENV/verify-fail-$num" ]]; then
            echo "stub gh: issue view (verify) failed" >&2
            exit 1
          fi
          canned="$STUB_DIR_FROM_ENV/verify-$num.json"
          # Every test that reaches the completing edit's read-back stages
          # its own verify-<N>.json (via stage_verify) -- the read-back is
          # only ever reached on the --apply + tier-recovered path, which
          # this suite always pairs with an explicit fixture. Default to
          # "still missing" (mirrors #6464's silent-drop) if one is somehow
          # absent, rather than guessing loom:issue landed.
          if [[ -f "$canned" ]]; then cat "$canned"; else echo '{"labels":[]}'; fi
          exit 0
        fi
        if [[ -f "$STUB_DIR_FROM_ENV/issue-fail-$num" ]]; then
          echo "stub gh: issue view failed" >&2
          exit 1
        fi
        canned="$STUB_DIR_FROM_ENV/issue-$num.json"
        if [[ -f "$canned" ]]; then cat "$canned"; else echo '{"state":"OPEN","labels":[],"comments":[]}'; fi
        exit 0
        ;;
      comment)
        num="$3"
        if [[ -f "$STUB_DIR_FROM_ENV/comment-fail-$num" ]]; then
          echo "stub gh: issue comment failed" >&2
          exit 1
        fi
        printf 'COMMENT %s %s\n' "$num" "$*" >> "$STUB_DIR_FROM_ENV/comment-writes.log"
        exit 0
        ;;
      edit)
        num="$3"
        if [[ -f "$STUB_DIR_FROM_ENV/edit-fail-$num" ]]; then
          echo "stub gh: issue edit failed" >&2
          exit 1
        fi
        printf 'EDIT %s %s\n' "$num" "$*" >> "$STUB_DIR_FROM_ENV/edit-writes.log"
        # Whether this edit "landed" is decided entirely by whatever the test
        # staged in verify-<N>.json for the subsequent read-back (see
        # stage_verify) -- this stub does not infer landing from the edit's
        # own args, matching the real-world failure mode under test (an edit
        # can exit 0 while its effect silently does not land, #6862).
        exit 0
        ;;
    esac
    echo "stub gh: unhandled issue args: $*" >&2
    exit 3
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

labels_json() {
    # labels_json [label ...] -> the `[{"name":...}, ...]` array body
    local labels="" l
    for l in "$@"; do
        [[ -n "$labels" ]] && labels="$labels,"
        labels="$labels{\"name\":\"$l\"}"
    done
    printf '[%s]' "$labels"
}

approved_comment() {
    # approved_comment <created_at> <goal-alignment-line>
    printf '{"createdAt":"%s","body":"**Champion Review: APPROVED**\\n\\nAll criteria passed.\\n\\n%s\\n\\n**Ready for Builder to claim.**"}' "$1" "$2"
}

plain_comment() {
    printf '{"createdAt":"%s","body":"%s"}' "$1" "$2"
}

issue_json() {
    # issue_json <state> <labels-json-array> <comments-json-array>
    printf '{"state":"%s","labels":%s,"comments":%s}' "$1" "$2" "$3"
}

# stage_verify <N> <labels-json-array> -- what the post-edit read-back sees.
stage_verify() {
    printf '{"labels":%s}' "$2" > "$STUB_DIR/verify-$1.json"
}

reset_state() {
    rm -f "$STUB_DIR"/issue-*.json "$STUB_DIR"/verify-*.json
    rm -f "$STUB_DIR"/issue-fail-* "$STUB_DIR"/verify-fail-*
    rm -f "$STUB_DIR"/comment-fail-* "$STUB_DIR"/edit-fail-*
    rm -f "$STUB_DIR"/comment-writes.log "$STUB_DIR"/edit-writes.log
}

run_sut() {
    OUT="$("$SUT" "$@" 2>"$STUB_DIR/stderr.log")"
    RC=$?
    ERR="$(cat "$STUB_DIR/stderr.log" 2>/dev/null || true)"
    EDITS="$(cat "$STUB_DIR/edit-writes.log" 2>/dev/null || true)"
    COMMENTS_POSTED="$(cat "$STUB_DIR/comment-writes.log" 2>/dev/null || true)"
}

get_field() {
    printf '%s\n' "$1" | grep "^$2=" | head -n1 | cut -d= -f2-
}

echo "Testing check-promotion-landed.sh..."

# (a) No APPROVED comment at all -> OK, exit 0, nothing written.
reset_state
issue_json "OPEN" "$(labels_json "loom:curated")" "[$(plain_comment "2026-08-20T00:00:00Z" "just a note")]" > "$STUB_DIR/issue-200.json"
run_sut --issue 200
assert_eq "0" "$RC" "(a) no APPROVED comment -> exit 0"
assert_eq "OK" "$(get_field "$OUT" DECISION)" "(a) DECISION=OK"
assert_eq "" "$EDITS" "(a) no label edit issued"
assert_eq "" "$COMMENTS_POSTED" "(a) no comment posted"

# (b) APPROVED comment present AND loom:issue already present -> OK, exit 0.
reset_state
issue_json "OPEN" "$(labels_json "loom:issue" "tier:maintenance")" \
  "[$(approved_comment "2026-08-18T00:00:00Z" "**Goal Alignment**: Tier 3 (maintenance) - cleanup")]" \
  > "$STUB_DIR/issue-201.json"
run_sut --issue 201
assert_eq "0" "$RC" "(b) loom:issue already present -> exit 0"
assert_eq "OK" "$(get_field "$OUT" DECISION)" "(b) DECISION=OK"

# (c) Issue closed -> NOT_OPEN, exit 10, regardless of comment/label state.
reset_state
issue_json "CLOSED" "$(labels_json "loom:auditor")" \
  "[$(approved_comment "2026-08-18T00:00:00Z" "**Goal Alignment**: Tier 1")]" \
  > "$STUB_DIR/issue-202.json"
run_sut --issue 202
assert_eq "10" "$RC" "(c) closed issue -> exit 10"
assert_eq "NOT_OPEN" "$(get_field "$OUT" DECISION)" "(c) DECISION=NOT_OPEN"

# (d) The #6464 shape: APPROVED comment present, loom:issue missing, no --apply
#     -> MISMATCH, exit 11, report-only (no writes).
reset_state
issue_json "OPEN" "$(labels_json "loom:auditor")" \
  "[$(approved_comment "2026-08-18T00:00:00Z" "**Goal Alignment**: Tier 3 (maintenance) - cleanup")]" \
  > "$STUB_DIR/issue-6464.json"
run_sut --issue 6464
assert_eq "11" "$RC" "(d) APPROVED-without-loom:issue, no --apply -> exit 11"
assert_eq "MISMATCH" "$(get_field "$OUT" DECISION)" "(d) DECISION=MISMATCH"
assert_eq "" "$EDITS" "(d) report-only: no label edit issued"
assert_eq "" "$COMMENTS_POSTED" "(d) report-only: no comment posted"

# (e) Same shape, WITH --apply, and the completing edit's read-back confirms
#     loom:issue landed -> COMPLETED, exit 12, tier recovered from the verdict
#     comment's Goal Alignment line, comment posted.
reset_state
issue_json "OPEN" "$(labels_json "loom:auditor")" \
  "[$(approved_comment "2026-08-18T00:00:00Z" "**Goal Alignment**: Tier 3 (maintenance) - cleanup")]" \
  > "$STUB_DIR/issue-6464.json"
stage_verify 6464 "$(labels_json "loom:issue" "tier:maintenance")"
run_sut --issue 6464 --apply
assert_eq "12" "$RC" "(e) --apply completes when the read-back confirms the label landed -> exit 12"
assert_eq "COMPLETED" "$(get_field "$OUT" DECISION)" "(e) DECISION=COMPLETED"
assert_eq "tier:maintenance" "$(get_field "$OUT" TIER)" "(e) TIER recovered as tier:maintenance from 'Tier 3'"
assert_contains "$EDITS" "loom:issue" "(e) the completing edit adds loom:issue"
assert_contains "$EDITS" "tier:maintenance" "(e) the completing edit adds the recovered tier label"
assert_contains "$COMMENTS_POSTED" "6464" "(e) a reconciliation comment is posted on the issue"

# (f) Tier 1 -> tier:goal-advancing.
reset_state
issue_json "OPEN" "$(labels_json "loom:architect")" \
  "[$(approved_comment "2026-08-18T00:00:00Z" "**Goal Alignment**: Tier 1 - directly implements the milestone")]" \
  > "$STUB_DIR/issue-300.json"
stage_verify 300 "$(labels_json "loom:issue" "tier:goal-advancing")"
run_sut --issue 300 --apply
assert_eq "COMPLETED" "$(get_field "$OUT" DECISION)" "(f) DECISION=COMPLETED"
assert_eq "tier:goal-advancing" "$(get_field "$OUT" TIER)" "(f) TIER recovered as tier:goal-advancing from 'Tier 1'"

# (g) Tier 2 -> tier:goal-supporting.
reset_state
issue_json "OPEN" "$(labels_json "loom:hermit")" \
  "[$(approved_comment "2026-08-18T00:00:00Z" "**Goal Alignment**: Tier 2 - supports milestone infra")]" \
  > "$STUB_DIR/issue-301.json"
stage_verify 301 "$(labels_json "loom:issue" "tier:goal-supporting")"
run_sut --issue 301 --apply
assert_eq "COMPLETED" "$(get_field "$OUT" DECISION)" "(g) DECISION=COMPLETED"
assert_eq "tier:goal-supporting" "$(get_field "$OUT" TIER)" "(g) TIER recovered as tier:goal-supporting from 'Tier 2'"

# (h) --apply but the tier cannot be recovered from the comment text (no
#     "Goal Alignment" line at all) -> ESCALATED, exit 13, operator labels added.
reset_state
issue_json "OPEN" "$(labels_json "loom:curated")" \
  "[$(approved_comment "2026-08-18T00:00:00Z" "no tier info here")]" \
  > "$STUB_DIR/issue-302.json"
run_sut --issue 302 --apply
assert_eq "13" "$RC" "(h) tier unrecoverable -> exit 13"
assert_eq "ESCALATED" "$(get_field "$OUT" DECISION)" "(h) DECISION=ESCALATED"
assert_eq "" "$(get_field "$OUT" TIER)" "(h) TIER is empty when unrecoverable"
assert_contains "$EDITS" "loom:operator-only" "(h) escalates to loom:operator-only"
assert_contains "$EDITS" "loom:operator-mechanical" "(h) escalates with loom:operator-mechanical sub-kind"
assert_contains "$COMMENTS_POSTED" "302" "(h) an escalation comment is posted on the issue"

# (i) --apply, tier recoverable, but the completing edit's OWN read-back still
#     shows loom:issue missing (the exact #6464 failure mode recurring on the
#     reconciliation attempt itself) -> ESCALATED, exit 13, never silently
#     reports success it cannot verify.
reset_state
issue_json "OPEN" "$(labels_json "loom:auditor")" \
  "[$(approved_comment "2026-08-18T00:00:00Z" "**Goal Alignment**: Tier 3 (maintenance)")]" \
  > "$STUB_DIR/issue-303.json"
stage_verify 303 "$(labels_json "loom:auditor")"   # loom:issue still absent post-edit
run_sut --issue 303 --apply
assert_eq "13" "$RC" "(i) read-back still shows loom:issue missing after the completing edit -> exit 13"
assert_eq "ESCALATED" "$(get_field "$OUT" DECISION)" "(i) DECISION=ESCALATED"
assert_eq "tier:maintenance" "$(get_field "$OUT" TIER)" "(i) TIER is still reported even though the write did not verify"

# (j) gh issue view (initial read) failure -> exit 1, usage/environment error.
reset_state
touch "$STUB_DIR/issue-fail-304"
run_sut --issue 304
assert_eq "1" "$RC" "(j) initial gh issue view failure -> exit 1"
assert_contains "$ERR" "gh issue view" "(j) stderr names the failing gh call"

# (k) missing --issue -> exit 1, usage error.
reset_state
run_sut
assert_eq "1" "$RC" "(k) missing --issue -> exit 1"
assert_contains "$ERR" "required" "(k) stderr explains the usage error"

# (l) non-numeric --issue -> exit 1.
reset_state
run_sut --issue abc
assert_eq "1" "$RC" "(l) non-numeric --issue -> exit 1"

echo
echo "--- Doc pins: champion-issue-promo.md ships the reordered write-then-verify Step 3b and the Pass 0c reconciliation loop (#6862) ---"

assert_doc_contains "$CHAMPION_MD" \
    'LOOM_ISSUE_LANDED=$(gh issue view "$ISSUE_NUMBER" --json labels' \
    "Step 3b reads back loom:issue after the label edit before posting the verdict comment"

assert_doc_contains "$CHAMPION_MD" \
    'do NOT post the APPROVED comment' \
    "Step 3b explicitly refuses to post the APPROVED comment when the label read-back fails"

assert_doc_contains "$CHAMPION_MD" \
    './.loom/scripts/check-promotion-landed.sh --issue "$N" --apply' \
    "Pass 0c invokes check-promotion-landed.sh --apply in its reconciliation loop"

assert_doc_contains "$CHAMPION_MD" \
    'in:comments "Champion Review: APPROVED" -label:loom:issue' \
    "Pass 0c's candidate search shortlists APPROVED-comment-without-loom:issue issues"

assert_doc_contains "$CHAMPION_MD" \
    "#6862" \
    "champion-issue-promo.md documents the #6862 promotion-write-reliability fix"

echo
echo "Results: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
[[ $TESTS_FAILED -eq 0 ]] || exit 1
