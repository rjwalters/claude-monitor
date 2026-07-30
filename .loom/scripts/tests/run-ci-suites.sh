#!/usr/bin/env bash
# run-ci-suites.sh — run the CI-wired shell test suites for
# defaults/scripts/tests/ (issue #4455).
#
# Runs every suite listed in ci-wired.txt, one at a time, capturing pass/fail
# and per-suite wall-clock time. Prints a summary and exits non-zero if any
# wired suite fails. The wired/excluded partition invariant is enforced first
# via check-ci-suite-manifest.sh, so a fresh unlisted suite is a hard failure
# here (it cannot silently slip into an unwired pool).
#
# Usage:
#   run-ci-suites.sh                 # run the whole wired set
#   LOOM_CI_SUITE_TIMEOUT=180 …      # per-suite timeout in seconds (default 120)
#
# Exit 0 = all wired suites passed; 1 = one or more failed / manifest invalid.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WIRED_MANIFEST="$SCRIPT_DIR/ci-wired.txt"
PER_SUITE_TIMEOUT="${LOOM_CI_SUITE_TIMEOUT:-120}"

# 1) Fail fast if the manifest partition invariant is broken.
if ! bash "$SCRIPT_DIR/check-ci-suite-manifest.sh"; then
    echo "::error::CI-suite manifest invariant failed — fix ci-wired.txt / ci-excluded.txt" >&2
    exit 1
fi

# Resolve a GNU/BSD-agnostic timeout wrapper (optional — plain bash if absent).
timeout_cmd=""
if command -v timeout >/dev/null 2>&1; then
    timeout_cmd="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd="gtimeout"
fi

mapfile -t suites < <(sed -E 's/#.*$//' "$WIRED_MANIFEST" | awk 'NF { print $1 }')

passed=0
failed=0
failed_names=()
total_start=$(date +%s)

printf '\n=== Running %d CI-wired shell suites (timeout %ss each) ===\n\n' \
    "${#suites[@]}" "$PER_SUITE_TIMEOUT"

for suite in "${suites[@]}"; do
    path="$SCRIPT_DIR/$suite"
    if [[ ! -f "$path" ]]; then
        echo "FAIL  $suite (missing file)"
        failed=$((failed + 1)); failed_names+=("$suite"); continue
    fi
    start=$(date +%s)
    if [[ -n "$timeout_cmd" ]]; then
        "$timeout_cmd" "$PER_SUITE_TIMEOUT" bash "$path" >"/tmp/ci-suite-$suite.log" 2>&1
    else
        bash "$path" >"/tmp/ci-suite-$suite.log" 2>&1
    fi
    rc=$?
    dur=$(( $(date +%s) - start ))
    if [[ "$rc" -eq 0 ]]; then
        printf 'PASS  %-52s %3ss\n' "$suite" "$dur"
        passed=$((passed + 1))
    else
        printf 'FAIL  %-52s %3ss (exit %s)\n' "$suite" "$dur" "$rc"
        failed=$((failed + 1)); failed_names+=("$suite")
        echo "----- last 40 lines of $suite -----"
        tail -40 "/tmp/ci-suite-$suite.log"
        echo "----- end $suite -----"
    fi
done

total_dur=$(( $(date +%s) - total_start ))
printf '\n=== Summary: %d passed, %d failed of %d wired suites in %ss ===\n' \
    "$passed" "$failed" "${#suites[@]}" "$total_dur"

if [[ "$failed" -ne 0 ]]; then
    printf 'Failed suites: %s\n' "${failed_names[*]}" >&2
    exit 1
fi
exit 0
