#!/usr/bin/env bash
# test-run-ci-suites-failure-excerpt.sh — the failure-excerpt printer
# run-ci-suites.sh emits for every failing suite (issue #6662).
#
# #6662: the excerpt was a bare `tail -40` — a fixed trailing window with no
# relationship to where the failure is. `tests/install/test-provision-daemon.sh`
# failed on the self-hosted runner five runs in a row with
# `Total: 99  Passed: 96  Failed: 3`, and all three FAIL lines sat ~60 lines
# above the window, so every visible line of the "diagnostic" said PASS and
# the assertion could not be named from CI artifacts at all.
#
# The printer is exercised DIRECTLY against synthetic logs (it is sourced from
# defaults/scripts/lib/ci-suite-excerpt.sh), not by running a real CI suite —
# so this suite is hermetic, fast, and can pin the exact property that was
# missing: the FIRST failure line is always in the excerpt regardless of how
# far above the trailing window it is.
#
# Usage:
#   ./defaults/scripts/tests/test-run-ci-suites-failure-excerpt.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$SCRIPT_DIR/run-ci-suites.sh"
# Self-relative: resolves in both the source tree (defaults/scripts/…) and an
# installed consumer repo (.loom/scripts/…), since the printer ships in the
# sibling lib/ directory either way.
EXCERPT_LIB="$SCRIPT_DIR/../lib/ci-suite-excerpt.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() {
    TESTS_RUN=$((TESTS_RUN + 1)); TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓${NC} $1"
}
fail() {
    TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗${NC} $1"
    [[ -n "${2:-}" ]] && echo "$2" | sed 's/^/    /'
}
check() {
    local rc="$1" msg="$2" detail="${3:-}"
    if [[ "$rc" -eq 0 ]]; then pass "$msg"; else fail "$msg" "$detail"; fi
}
# Inverted form, for the assertions whose whole point is that something is
# NOT present (e.g. "the trailing window alone would not have shown this").
check_not() {
    local rc="$1" msg="$2" detail="${3:-}"
    if [[ "$rc" -ne 0 ]]; then pass "$msg"; else fail "$msg" "$detail"; fi
}

if [[ ! -r "$EXCERPT_LIB" ]]; then
    echo "FATAL: excerpt library not found at $EXCERPT_LIB" >&2
    exit 1
fi
# shellcheck source=../lib/ci-suite-excerpt.sh
source "$EXCERPT_LIB"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# A synthetic suite log shaped exactly like the #6662 incident: a long run
# whose failures are early and whose last 40 lines are all PASS.
#   line   3  -> FAIL (+ two diagnostic context lines)
#   line 100+ -> nothing but PASS, then the totals footer
make_incident_log() { # <path>
    local path="$1" i
    {
        echo "PASS: first assertion"
        echo "PASS: second assertion"
        echo "FAIL: gate rejects a script-based fake binary without the bypass"
        echo "  expected: '1'"
        echo "  actual:   '0'"
        for i in $(seq 1 120); do echo "PASS: later assertion $i"; done
        echo ""
        echo "-----------------------------------------"
        echo "Total: 99  Passed: 96  Failed: 3"
    } > "$path"
}

# Section splitters. The printer emits two labelled sections; assertions must
# target the failure-anchored one specifically, or a match in the trailing
# window would make "the first FAIL is included" unfalsifiable.
failure_section() { printf '%s\n' "$1" | sed -n '/^----- first /,/^----- last /p'; }
tail_section()    { printf '%s\n' "$1" | sed -n '/^----- last /,/^----- end /p'; }

# ---------- 1. the first failure line is included, however far above the tail ----------
LOG1="$WORKDIR/incident.log"
make_incident_log "$LOG1"
out1="$(print_suite_failure_excerpt "tests/install/test-provision-daemon.sh" "$LOG1" 2>&1)"
rc1=$?
check "$rc1" "printer returns 0 on a failing suite's log"

sec1="$(failure_section "$out1")"
grep -q "gate rejects a script-based fake binary without the bypass" <<<"$sec1"
check "$?" "first FAIL line is in the failure section (the #6662 regression)" "$sec1"

# The exact thing the old tail -40 could not do: this log's FAIL is ~125 lines
# from the end, so a trailing window alone provably never reaches it.
grep -q "FAIL" <<<"$(tail_section "$out1")"
check_not "$?" "trailing window alone would NOT have shown the failure (pins the premise)"

# ---------- 2. the assert helper's expected/actual context comes along ----------
grep -q "expected: '1'" <<<"$sec1" && grep -q "actual:   '0'" <<<"$sec1"
check "$?" "expected/actual diagnostic lines are carried with the FAIL line" "$sec1"

# ---------- 3. the tail is still printed (nothing that was visible is lost) ----------
grep -q "Total: 99  Passed: 96  Failed: 3" <<<"$(tail_section "$out1")"
check "$?" "suite totals footer is still printed in the trailing window"

grep -q -- "----- end tests/install/test-provision-daemon.sh -----" <<<"$out1"
check "$?" "excerpt is still terminated by the end marker"

# ---------- 4. line numbers locate the failure in the full artifact ----------
grep -qE "^3[:-]FAIL: gate rejects" <<<"$sec1"
check "$?" "failure lines carry their line number in the captured log" "$sec1"

# ---------- 5. the cap is honored ----------
LOG5="$WORKDIR/many-failures.log"
{
    for i in $(seq 1 8); do echo "FAIL: assertion number $i"; done
    echo "Total: 8  Passed: 0  Failed: 8"
} > "$LOG5"
out5="$( LOOM_CI_FAIL_EXCERPT_MAX=2 LOOM_CI_FAIL_CONTEXT_LINES=0 \
    print_suite_failure_excerpt "capped.sh" "$LOG5" 2>&1 )"
sec5="$(failure_section "$out5")"
n5="$(grep -c "FAIL: assertion number" <<<"$sec5")"
if [[ "$n5" -eq 2 ]]; then rc5=0; else rc5=1; fi
check "$rc5" "LOOM_CI_FAIL_EXCERPT_MAX caps the failure section (got $n5 of 8)" "$sec5"

grep -q "FAIL: assertion number 1" <<<"$sec5"
check "$?" "the capped excerpt keeps the FIRST failures, not the last"

# ---------- 6. the ✗ bullet convention is recognized too ----------
# check/pass/fail-style suites in this directory report failures as `✗ msg`
# with no FAIL token anywhere on the line.
LOG6="$WORKDIR/bullet.log"
{
    echo "✓ guard is not always-on"
    echo "✗ guard skips the daemon suites when a pid file exists"
    for i in $(seq 1 60); do echo "✓ later check $i"; done
} > "$LOG6"
out6="$(print_suite_failure_excerpt "bullet.sh" "$LOG6" 2>&1)"
grep -q "guard skips the daemon suites when a pid file exists" <<<"$(failure_section "$out6")"
check "$?" "bullet-style (U+2717) failure lines are matched as failures" "$(failure_section "$out6")"

# ---------- 7. a suite that failed with no recognizable failure line ----------
# A crash / timeout kill / non-zero exit before any assertion ran must produce
# an explicit note, never a silently empty failure section.
LOG7="$WORKDIR/crashed.log"
{
    echo "starting"
    for i in $(seq 1 50); do echo "step $i"; done
    echo "Segmentation fault"
} > "$LOG7"
out7="$(print_suite_failure_excerpt "crashed.sh" "$LOG7" 2>&1)"
rc7=$?
check "$rc7" "printer returns 0 when nothing matched the failure pattern"

grep -q "failed without emitting a recognizable" <<<"$out7"
check "$?" "an unmatched log gets an explicit note instead of an empty section" "$out7"

grep -q "Segmentation fault" <<<"$(tail_section "$out7")"
check "$?" "an unmatched log still shows its trailing window"

# ---------- 8. a missing log file is reported, not fatal ----------
out8="$(print_suite_failure_excerpt "vanished.sh" "$WORKDIR/does-not-exist.log" 2>&1)"
rc8=$?
check "$rc8" "printer returns 0 when the captured log is missing"
grep -q "no captured log for vanished.sh" <<<"$out8"
check "$?" "missing captured log is named explicitly" "$out8"

# ---------- 9. run-ci-suites.sh actually uses the printer ----------
# Structural drift guard: the properties above are worthless if the runner
# quietly goes back to its own trailing-window print.
if [[ -r "$RUNNER" ]]; then
    grep -qF 'print_suite_failure_excerpt "$suite"' "$RUNNER"
    check "$?" "run-ci-suites.sh prints failures via print_suite_failure_excerpt"

    grep -qE '^[[:space:]]*tail -n? ?[0-9]+ "/tmp/ci-suite-' "$RUNNER"
    check_not "$?" "run-ci-suites.sh no longer hardcodes its own tail window"

    grep -q 'ci-suite-excerpt.sh' "$RUNNER"
    check "$?" "run-ci-suites.sh sources the excerpt library"
else
    fail "run-ci-suites.sh is readable at $RUNNER"
fi

# ---------- summary ----------
echo ""
echo "-----------------------------------------"
echo "Total: $TESTS_RUN  Passed: $TESTS_PASSED  Failed: $TESTS_FAILED"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
    exit 1
fi
exit 0
