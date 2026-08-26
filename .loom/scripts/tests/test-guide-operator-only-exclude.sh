#!/usr/bin/env bash
# test-guide-operator-only-exclude.sh - Regression test for issue #6941
#
# guide.md's `loom:urgent` eligibility filters excluded `loom:building`, an
# open `loom:pr`-labeled linked PR, and `loom:blocked` — but not
# `loom:operator-only` (which `.github/labels.yml` documents as "sweep
# skips", i.e. a Builder can never act on it, exactly like `loom:blocked`,
# just via a different mechanism: a human must act or rule outside
# automation). #6245 was mispromoted to `loom:urgent` twice in under 24h
# because none of the four eligibility call sites excluded it:
#   1. the "Finding Work" ready-queue query / search terms,
#   2. the incumbency "Evict ineligible holders" step,
#   3. the "Fill free slots" / candidate-ranking step, and
#   4. the "Safety Check: Never Mark Building Issues Urgent" section.
#
# The fix adds a `has_operator_only()` helper (one label-membership check,
# mirroring `has_open_pr_labeled_loom_pr()`'s existing shape) and wires it
# into all four call sites.
#
# Verifies that:
#   1. guide.md defines `has_operator_only()` immediately after
#      `has_open_pr_labeled_loom_pr()`, in the same shape.
#   2. guide.md's ready-queue query excludes `loom:operator-only`.
#   3. The "Evict ineligible holders" step names `loom:operator-only` /
#      `has_operator_only()` as an ineligibility condition, and — like the
#      other ineligibility conditions in that step — does NOT route through
#      `urgent-flip-guard.sh` (eviction is "the one demotion you may make
#      without a challenger", so a newly-added `loom:operator-only` label
#      evicts the SAME tick it's noticed, with no flip-guard reversal wait).
#   4. The "Fill free slots" step excludes `has_operator_only()` candidates.
#   5. The "Safety Check" section calls `has_operator_only()` before writing
#      `loom:urgent`, mirroring the existing `loom:building` /
#      `has_open_pr_labeled_loom_pr()` checks there.
#   6. THE REGRESSION, executed rather than grepped: `has_operator_only()`
#      extracted VERBATIM from guide.md, run against fixture `gh issue view`
#      JSON:
#        a. an incumbent that gains `loom:operator-only` mid-cycle is
#           evicted by a reconstructed eviction filter the same tick,
#        b. a `loom:operator-only` + `loom:issue` candidate is never
#           selected by a reconstructed "Fill free slots" ranking loop,
#           even when it out-ranks the eligible candidate on tier alone.
#
# Hermetic: `gh` is stubbed with fixture JSON; only the real `jq` binary is
# invoked (skipped if unavailable) — no forge/network calls.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# guide.md is shipped (installed at .claude/commands/loom/guide.md), so
# resolve it the way each layout actually lays it out: the installed path
# first (consumer repos, and Loom's own dogfooded checkout), falling back
# to the defaults/ source-tree path (a bare source checkout with no
# .claude/commands/loom/ copy yet). See issue #6194 / #6241.
if [[ -f "$REPO_ROOT/.claude/commands/loom/guide.md" ]]; then
    GUIDE_MD="$REPO_ROOT/.claude/commands/loom/guide.md"
else
    GUIDE_MD="$REPO_ROOT/defaults/.claude/commands/loom/guide.md"
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_PASSED=$((TESTS_PASSED + 1)); echo -e "  ${GREEN}PASS${NC}: $1"; }
fail() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1)); echo -e "  ${RED}FAIL${NC}: $1"; }

assert_eq() {
    local actual="$1" expected="$2" msg="$3"
    if [[ "$actual" == "$expected" ]]; then pass "$msg"; else fail "$msg (got '$actual', expected '$expected')"; fi
}

assert_grep() {
    local pattern="$1" file="$2" msg="$3"
    if grep -qE "$pattern" "$file"; then pass "$msg"; else fail "$msg (missing pattern: $pattern)"; fi
}

if [[ ! -f "$GUIDE_MD" ]]; then
    echo -e "${RED}FATAL${NC}: guide.md not found at $GUIDE_MD"
    exit 1
fi

# ---------------------------------------------------------------------------
# Test 1: has_operator_only() is defined, mirroring has_open_pr_labeled_loom_pr()
# ---------------------------------------------------------------------------
echo "Test 1: guide.md defines has_operator_only()"

assert_grep '^has_operator_only\(\) \{' "$GUIDE_MD" \
    "has_operator_only() is defined"
assert_grep 'loom:operator-only,\*\) echo "true"; return' "$GUIDE_MD" \
    "has_operator_only() matches the loom:operator-only label"

DEF_OPEN_PR="$(grep -n '^has_open_pr_labeled_loom_pr() {' "$GUIDE_MD" | head -1 | cut -d: -f1)"
DEF_OPERATOR_ONLY="$(grep -n '^has_operator_only() {' "$GUIDE_MD" | head -1 | cut -d: -f1)"
if [[ -n "$DEF_OPEN_PR" && -n "$DEF_OPERATOR_ONLY" && "$DEF_OPERATOR_ONLY" -gt "$DEF_OPEN_PR" ]]; then
    pass "has_operator_only() is defined after has_open_pr_labeled_loom_pr() (same neighborhood)"
else
    fail "expected has_operator_only() to follow has_open_pr_labeled_loom_pr() (open_pr=$DEF_OPEN_PR operator_only=$DEF_OPERATOR_ONLY)"
fi

# ---------------------------------------------------------------------------
# Test 2: the "Finding Work" ready-queue query excludes loom:operator-only
# ---------------------------------------------------------------------------
echo ""
echo "Test 2: the ready-queue query excludes loom:operator-only"

assert_grep '\-label:loom:building \-label:loom:operator-only' "$GUIDE_MD" \
    "the ready-queue search term excludes both loom:building and loom:operator-only"

# ---------------------------------------------------------------------------
# Test 3: "Evict ineligible holders" names loom:operator-only, without a
# flip-guard gate (eviction is unconditional, same tick, per the existing
# loom:building/loom:blocked/open-PR ineligibility conditions).
# ---------------------------------------------------------------------------
echo ""
echo "Test 3: the incumbency eviction step treats loom:operator-only as ineligible, ungated"

EVICT_BLOCK="$(awk '/\*\*Evict ineligible holders\.\*\*/{flag=1} flag{print} /\*\*Fill free slots\.\*\*/{exit}' "$GUIDE_MD")"
if [[ -z "$EVICT_BLOCK" ]]; then
    fail "could not extract the 'Evict ineligible holders' step from guide.md"
else
    pass "extracted the 'Evict ineligible holders' step"
fi

if grep -q 'loom:operator-only' <<<"$EVICT_BLOCK"; then
    pass "the eviction step names loom:operator-only as an ineligibility condition"
else
    fail "expected 'loom:operator-only' inside the 'Evict ineligible holders' step"
fi

if grep -q 'has_operator_only' <<<"$EVICT_BLOCK"; then
    pass "the eviction step references has_operator_only()"
else
    fail "expected 'has_operator_only' inside the 'Evict ineligible holders' step"
fi

if grep -q 'urgent-flip-guard' <<<"$EVICT_BLOCK"; then
    fail "eviction step must NOT route through urgent-flip-guard.sh (it is the one demotion made without a challenger)"
else
    pass "eviction step does not gate on urgent-flip-guard.sh (evicts the same tick it's noticed)"
fi

# ---------------------------------------------------------------------------
# Test 4: "Fill free slots" excludes has_operator_only() candidates
# ---------------------------------------------------------------------------
echo ""
echo "Test 4: the 'Fill free slots' step excludes has_operator_only() candidates"

FILL_BLOCK="$(awk '/\*\*Fill free slots\.\*\*/{flag=1} flag{print} /^4\. \*\*With 3 eligible holders/{exit}' "$GUIDE_MD")"
if [[ -z "$FILL_BLOCK" ]]; then
    fail "could not extract the 'Fill free slots' step from guide.md"
else
    pass "extracted the 'Fill free slots' step"
fi

if grep -q 'has_operator_only' <<<"$FILL_BLOCK"; then
    pass "the 'Fill free slots' step references has_operator_only()"
else
    fail "expected 'has_operator_only' inside the 'Fill free slots' step"
fi

# ---------------------------------------------------------------------------
# Test 5: the Safety Check section calls has_operator_only() before writing
# loom:urgent, mirroring the existing loom:building / open-PR checks there.
# ---------------------------------------------------------------------------
echo ""
echo "Test 5: the Safety Check section gates on has_operator_only()"

SAFETY_BLOCK="$(awk '/^## Safety Check: Never Mark Building Issues Urgent/{flag=1} flag{print} /^## When to Apply loom:urgent/{exit}' "$GUIDE_MD")"
if [[ -z "$SAFETY_BLOCK" ]]; then
    fail "could not extract the Safety Check section from guide.md"
else
    pass "extracted the Safety Check section"
fi

if grep -q 'has_operator_only <number>' <<<"$SAFETY_BLOCK"; then
    pass "the Safety Check section calls has_operator_only() before the urgent-flip-guard write"
else
    fail "expected a 'has_operator_only <number>' call inside the Safety Check section"
fi

HAS_BUILDING_LINE="$(grep -n 'grep -q "loom:building"' <<<"$SAFETY_BLOCK" | head -1 | cut -d: -f1)"
HAS_OPERATOR_ONLY_LINE="$(grep -n 'has_operator_only <number>' <<<"$SAFETY_BLOCK" | head -1 | cut -d: -f1)"
HAS_OPEN_PR_LINE="$(grep -n 'has_open_pr_labeled_loom_pr <number>' <<<"$SAFETY_BLOCK" | head -1 | cut -d: -f1)"
if [[ -n "$HAS_BUILDING_LINE" && -n "$HAS_OPERATOR_ONLY_LINE" && -n "$HAS_OPEN_PR_LINE" ]] \
    && (( HAS_BUILDING_LINE < HAS_OPERATOR_ONLY_LINE && HAS_OPERATOR_ONLY_LINE < HAS_OPEN_PR_LINE )); then
    pass "the checks run in order: loom:building, then has_operator_only(), then has_open_pr_labeled_loom_pr()"
else
    fail "expected loom:building < has_operator_only < has_open_pr_labeled_loom_pr (got building=$HAS_BUILDING_LINE operator_only=$HAS_OPERATOR_ONLY_LINE open_pr=$HAS_OPEN_PR_LINE)"
fi

# ---------------------------------------------------------------------------
# Extract has_operator_only() VERBATIM from guide.md so this suite can never
# silently drift from the actual prompt text.
# ---------------------------------------------------------------------------
FUNC_BODY="$(sed -n '/^has_operator_only() {/,/^}/p' "$GUIDE_MD")"

if [[ -z "$FUNC_BODY" ]]; then
    echo -e "${RED}FATAL${NC}: could not extract has_operator_only() from guide.md"
    echo "================================"
    echo "Tests run:    $TESTS_RUN"
    exit 1
fi
pass "extracted has_operator_only() verbatim from guide.md"

if ! command -v jq >/dev/null 2>&1; then
    echo ""
    echo "SKIP: jq not available, skipping the executable has_operator_only()/eviction/fill tests"
    echo "================================"
    echo "Tests run:    $TESTS_RUN"
    echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
    if [[ $TESTS_FAILED -gt 0 ]]; then
        echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
        exit 1
    fi
    echo "All tests passed"
    exit 0
fi

# Load the extracted function into THIS shell.
eval "$FUNC_BODY"

# ---------------------------------------------------------------------------
# Fixture: a stub `gh` returning canned `issue view --json labels` output for
# a handful of issue numbers. #100 is a plain urgent incumbent; #200 is an
# incumbent that has since GAINED loom:operator-only (+ its operator-blocked
# sub-kind, mirroring how the label always ships alongside a sub-kind, #5671);
# #300 is a plain ready loom:issue candidate (lower tier); #400 is a
# loom:operator-only + loom:issue candidate that outranks #300 on tier alone.
# ---------------------------------------------------------------------------
gh() {
    if [[ "$1" == "issue" && "$2" == "view" ]]; then
        local number="$3" labels_csv label_json jq_filter="" args=("$@") i
        case "$number" in
            100) labels_csv="loom:issue,loom:urgent" ;;
            200) labels_csv="loom:issue,loom:urgent,loom:operator-only,loom:operator-blocked" ;;
            300) labels_csv="loom:issue,tier:goal-supporting" ;;
            400) labels_csv="loom:issue,tier:goal-advancing,loom:operator-only,loom:operator-decision" ;;
            *) labels_csv="" ;;
        esac
        label_json="$(IFS=,; for n in $labels_csv; do printf '{"name":"%s"},' "$n"; done)"
        label_json="${label_json%,}"
        # Real `gh ... --json X --jq FILTER` applies FILTER server-side
        # before returning; emulate that here (rather than returning raw
        # JSON) so has_operator_only()'s own `--jq` filter is what's under
        # test, not this fixture's JSON shape.
        for ((i = 0; i < ${#args[@]}; i++)); do
            if [[ "${args[$i]}" == "--jq" ]]; then
                jq_filter="${args[$((i + 1))]}"
            fi
        done
        if [[ -n "$jq_filter" ]]; then
            printf '{"labels":[%s]}' "$label_json" | jq -r "$jq_filter"
        else
            printf '{"labels":[%s]}' "$label_json"
        fi
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Test 6: has_operator_only() itself, against the fixtures above
# ---------------------------------------------------------------------------
echo ""
echo "Test 6: has_operator_only() (executed, against fixture gh output)"

assert_eq "$(has_operator_only 100)" "false" "#100 (plain loom:urgent incumbent) is not operator-only"
assert_eq "$(has_operator_only 200)" "true" "#200 (gained loom:operator-only + operator-blocked) is operator-only"
assert_eq "$(has_operator_only 300)" "false" "#300 (plain loom:issue candidate) is not operator-only"
assert_eq "$(has_operator_only 400)" "true" "#400 (loom:issue + loom:operator-only + operator-decision) is operator-only"

# ---------------------------------------------------------------------------
# Test 7 (AC): an incumbent that gains loom:operator-only is evicted the
# SAME tick, with no flip-guard reversal needed — reconstructing the
# "Evict ineligible holders" filter exactly as guide.md specifies it.
# ---------------------------------------------------------------------------
echo ""
echo "Test 7: incumbent eviction — gaining loom:operator-only evicts immediately"

evict_ineligible() {
    # Mirrors "Evict ineligible holders": ineligible if closed / lost
    # loom:issue / gained loom:building or loom:blocked / has_operator_only.
    local number="$1"
    if [[ "$(has_operator_only "$number")" == "true" ]]; then
        echo "true"
        return
    fi
    echo "false"
}

INCUMBENTS=(100 200)
SURVIVORS=()
for n in "${INCUMBENTS[@]}"; do
    if [[ "$(evict_ineligible "$n")" == "false" ]]; then
        SURVIVORS+=("$n")
    fi
done

if [[ "${#SURVIVORS[@]}" -eq 1 && "${SURVIVORS[0]}" == "100" ]]; then
    pass "incumbent #200 (gained loom:operator-only) is evicted; #100 stays"
else
    fail "expected only #100 to survive eviction, got: ${SURVIVORS[*]:-<none>}"
fi

# No urgent-flip-guard.sh dependency in this reconstruction — the eviction
# path never calls it (Test 3 above already proves guide.md's prose agrees),
# so the eviction happens the same tick it's noticed, with no cooldown wait.

# ---------------------------------------------------------------------------
# Test 8 (AC): a loom:operator-only + loom:issue candidate is never selected
# to fill a free slot, even when it strictly outranks the only other
# eligible candidate on tier.
# ---------------------------------------------------------------------------
echo ""
echo "Test 8: 'Fill free slots' never selects a loom:operator-only candidate"

fill_free_slot() {
    # Mirrors "Fill free slots": walk ranked candidates, skip any for which
    # has_operator_only() is true, select the first eligible one.
    local candidates=("$@")
    for n in "${candidates[@]}"; do
        if [[ "$(has_operator_only "$n")" == "true" ]]; then
            continue
        fi
        echo "$n"
        return
    done
    echo ""
}

# #400 (tier:goal-advancing, rank 3) would out-rank #300 (tier:goal-supporting,
# rank 4) on urgency_rank() alone -- listed FIRST to prove has_operator_only()
# is what excludes it, not candidate ordering.
SELECTED="$(fill_free_slot 400 300)"
assert_eq "$SELECTED" "300" \
    "the loom:operator-only candidate (#400) is skipped even though it outranks #300 on tier"

# A slot with ONLY an operator-only candidate available stays unfilled rather
# than promoting it.
SELECTED_NONE="$(fill_free_slot 400)"
assert_eq "$SELECTED_NONE" "" \
    "a free slot with only a loom:operator-only candidate available is left unfilled"

# ---------------------------------------------------------------------------
echo ""
echo "================================"
echo "Tests run:    $TESTS_RUN"
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
if [[ $TESTS_FAILED -gt 0 ]]; then
    echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
    exit 1
fi
echo "All tests passed"
exit 0
