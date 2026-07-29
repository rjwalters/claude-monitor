#!/usr/bin/env bash
# test-probe-tokens-fallback.sh - Regression guard for #4079, re-scoped in
# #4228 (epic #4081 Phase 2).
#
# probe-tokens.sh delegates to the native `loom-daemon tokens check`
# subcommand (issue #4080) and falls back to the `loom-tokens` console
# script on PATH only when the resolved daemon binary predates the `tokens`
# subcommand (a host mid-roll). The bare `python3 -m loom_tools.tokens.cli`
# fallback tier that #4079 originally regression-tested no longer exists at
# all — it was removed by #4080, well before this file's own cutover phase
# (#4228). This test now asserts:
#   1. probe-tokens.sh no longer references the stale module path (#4079).
#   2. probe-tokens.sh contains NO python3/loom_tools reference whatsoever —
#      the bare interpreter fallback tier is gone, not just fixed (#4228).
#   3. With no capable `loom-daemon` binary resolvable and no `loom-tokens`
#      on PATH, probe-tokens.sh fails loudly (exit 1, actionable message)
#      rather than silently degrading — there is nothing left to fall back
#      to.
#   4. With `loom-tokens` on PATH but no capable daemon binary, probe-tokens.sh
#      --json exits 0 and emits JSON via that fallback (exercises the real
#      fallback codepath end-to-end).
#
# Usage:
#   ./.loom/scripts/tests/test-probe-tokens-fallback.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROBE_SCRIPT="$SCRIPTS_DIR/probe-tokens.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() {
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "  ${GREEN}PASS${NC}: $1"
}

fail() {
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "  ${RED}FAIL${NC}: $1"
}

# -------- Test 1: script exists and is executable --------
echo "Test 1: script exists and is executable"
if [[ -x "$PROBE_SCRIPT" ]]; then
    pass "probe-tokens.sh is executable"
else
    fail "probe-tokens.sh is missing or not executable: $PROBE_SCRIPT"
    echo "FAILED: $TESTS_FAILED/$TESTS_RUN"
    exit 1
fi

# -------- Test 2: no reference to the stale never-existent module --------
echo "Test 2: no reference to the stale loom_tools.cli.loom_tokens module"
if grep -q "loom_tools\.cli\.loom_tokens" "$PROBE_SCRIPT"; then
    fail "probe-tokens.sh still references the never-existent loom_tools.cli.loom_tokens"
else
    pass "probe-tokens.sh does not reference loom_tools.cli.loom_tokens"
fi

# -------- Test 3: NO python3/loom_tools reference in CODE (issue #4228) --------
# The bare interpreted-language fallback tier #4079 regression-tested is gone
# entirely as of #4080 — the only remaining fallback is `loom-tokens` on PATH.
# Deliberate comments explaining the history (e.g. "the bare python3 -m
# fallback tier has been removed") are allowed — only non-comment lines count.
echo "Test 3: no python3/loom_tools reference in probe-tokens.sh's executable code"
code_hits="$(grep -vE '^\s*#' "$PROBE_SCRIPT" | grep -nE "python3|loom_tools" || true)"
if [[ -n "$code_hits" ]]; then
    fail "probe-tokens.sh's executable code still references python3/loom_tools: $code_hits"
else
    pass "probe-tokens.sh's executable code contains no python3/loom_tools reference"
fi

# A hermetic "nothing resolves" workspace: no .git/.loom markers (so
# probe-tokens.sh's own find_repo_root() falls back to $PWD) and no
# target/{release,debug}/loom-daemon build-output-relative candidate
# underneath it — required to truly defeat daemon-binary resolution rather
# than accidentally finding THIS checkout's own freshly-built binary.
NO_DAEMON_WS="$(mktemp -d)"
trap 'rm -rf "$NO_DAEMON_WS"' EXIT
STRIPPED_PATH="/usr/bin:/bin:/usr/sbin:/sbin"

# -------- Test 4: neither a capable daemon binary nor loom-tokens on PATH
#                   fails loudly (exit 1, actionable message) --------
echo "Test 4: no capable daemon binary and no loom-tokens on PATH -> exit 1"
out="$(cd "$NO_DAEMON_WS" && LOOM_DAEMON_BIN="/nonexistent/loom-daemon" \
    PATH="$STRIPPED_PATH" "$PROBE_SCRIPT" --json 2>&1)"
rc=$?
if [[ "$rc" -eq 1 ]]; then
    pass "no daemon binary + no loom-tokens on PATH exits 1"
else
    fail "expected exit 1 with no daemon binary + no loom-tokens on PATH, got $rc"
fi
if [[ "$out" == *"no loom-daemon binary"* ]]; then
    pass "failure message is actionable (names the missing daemon binary)"
else
    fail "failure message did not mention the missing daemon binary. Got: $out"
fi

# -------- Test 5: with loom-tokens on PATH (but no capable daemon binary),
#                   --json exits 0 and emits JSON via that fallback --------
echo "Test 5: --json fallback exits 0 and emits JSON via loom-tokens on PATH"
if command -v loom-tokens >/dev/null 2>&1; then
    loom_tokens_dir="$(dirname "$(command -v loom-tokens)")"
    json_out="$(cd "$NO_DAEMON_WS" && LOOM_DAEMON_BIN="/nonexistent/loom-daemon" \
        PATH="$loom_tokens_dir:$STRIPPED_PATH" "$PROBE_SCRIPT" --json 2>/dev/null)"
    rc=$?
    if [[ "$rc" -eq 0 ]]; then
        pass "fallback --json exit code is 0"
    else
        fail "fallback --json expected exit 0, got $rc"
    fi
    if printf '%s' "$json_out" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
        pass "fallback --json emits parseable JSON"
    else
        fail "fallback --json did not emit parseable JSON. Got: $json_out"
    fi
else
    echo "  (skipping: loom-tokens is not on PATH in this environment — cannot exercise the fallback codepath)"
    pass "skipped (loom-tokens absent; not a failure)"
fi

# -------- Summary --------
echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
    echo -e "${RED}FAILED${NC}: $TESTS_FAILED test(s) failed"
    exit 1
fi
echo -e "${GREEN}OK${NC}: all tests passed"
exit 0
