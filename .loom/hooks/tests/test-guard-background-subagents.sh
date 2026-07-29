#!/usr/bin/env bash
# Test suite for defaults/hooks/guard-background-subagents.sh (issue #4257)
#
# Usage: ./defaults/hooks/tests/test-guard-background-subagents.sh
#
# Covers the Stop-hook mechanical backstop for the #3822/#4257 hazard: an
# orchestrator ending its turn in headless `claude -p` mode kills every
# still-running background Task subagent. This hook scans the transcript
# JSONL for `Task` tool_use entries with no matching tool_result and blocks
# the stop (once) when it finds any.
#
#   - unresolved Task tool_use (no matching tool_result) -> block
#   - all Task tool_use entries resolved -> allow (silent)
#   - no Task tool_use at all -> allow (silent)
#   - stop_hook_active=true -> allow unconditionally (loop guard), even with
#     an unresolved Task still in the transcript
#   - missing / unreadable transcript_path -> allow (fail-open)
#   - unparseable transcript content -> allow (fail-open)
#   - guards.backgroundSubagents / LOOM_GUARD_BACKGROUND_SUBAGENTS toggle
#     (env beats config; config beats default-on)
#   - jq absent -> allow (fail-open)
#   - contract: block output is valid JSON with decision=="block" and a
#     non-empty reason; exit code is always 0
#
# The hook under test is the canonical source at defaults/ (the version-
# controlled source of truth), copied into an isolated temp git tree so the
# hook's MAIN_ROOT (used only for the config-toggle lookup) resolves there.
# Exit 0 = all pass, 1 = fail.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SRC_HOOK="$REPO_ROOT/defaults/hooks/guard-background-subagents.sh"

PASS=0
FAIL=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
git init -q "$TMPROOT"
mkdir -p "$TMPROOT/.loom/hooks"
cp "$SRC_HOOK" "$TMPROOT/.loom/hooks/guard-background-subagents.sh"
chmod +x "$TMPROOT/.loom/hooks/guard-background-subagents.sh"
HOOK="$TMPROOT/.loom/hooks/guard-background-subagents.sh"

pass() { PASS=$((PASS + 1)); TOTAL=$((TOTAL + 1)); printf "${GREEN}PASS${NC} %s\n" "$1"; }
fail() { FAIL=$((FAIL + 1)); TOTAL=$((TOTAL + 1)); printf "${RED}FAIL${NC} %s\n" "$1"; }

# Write a transcript JSONL fixture. Args: <path> <line>...
write_transcript() {
    local path="$1"; shift
    : > "$path"
    for line in "$@"; do
        printf '%s\n' "$line" >> "$path"
    done
}

TASK_USE_UNRESOLVED='{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_01","name":"Task","input":{}}]}}'
TASK_USE_RESOLVED='{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_02","name":"Task","input":{}}]}}'
TASK_RESULT_02='{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_02","content":"done"}]}}'
NON_TASK_USE='{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_03","name":"Bash","input":{}}]}}'

# Build stdin JSON. Args: <transcript_path> <stop_hook_active>
make_input() {
    local transcript="$1" active="${2:-false}"
    jq -n --arg tp "$transcript" --argjson active "$active" \
        '{session_id: "test", transcript_path: $tp, stop_hook_active: $active, hook_event_name: "Stop"}'
}

run_hook() {
    local transcript="$1" active="${2:-false}"
    shift; [[ $# -gt 0 ]] && shift
    local exit_code=0 output
    output=$(cd "$TMPROOT" && env "$@" bash "$HOOK" < <(make_input "$transcript" "$active") 2>/dev/null) || exit_code=$?
    printf '%s|%s' "$exit_code" "$output"
}

assert_allow() {
    local desc="$1" result="$2"
    local code="${result%%|*}" out="${result#*|}"
    if [[ "$code" == "0" && -z "$out" ]]; then
        pass "$desc"
    else
        fail "$desc (expected exit 0 + empty output, got exit=$code output=$out)"
    fi
}

assert_block() {
    local desc="$1" result="$2"
    local code="${result%%|*}" out="${result#*|}"
    if [[ "$code" != "0" ]]; then
        fail "$desc (expected exit 0 with block JSON, got NONZERO exit=$code)"
        return
    fi
    local decision reason
    decision=$(echo "$out" | jq -r '.decision // empty' 2>/dev/null || true)
    reason=$(echo "$out" | jq -r '.reason // empty' 2>/dev/null || true)
    if [[ "$decision" == "block" && -n "$reason" ]]; then
        pass "$desc"
    else
        fail "$desc (expected decision=block + non-empty reason, got: $out)"
    fi
}

echo "=== guard-background-subagents.sh tests (#4257) ==="

# (a) unresolved Task tool_use -> block
T1="$TMPROOT/transcript-unresolved.jsonl"
write_transcript "$T1" "$TASK_USE_UNRESOLVED"
result=$(run_hook "$T1" false)
assert_block "(a) unresolved Task tool_use -> block" "$result"

# (b) all Task tool_use resolved -> allow
T2="$TMPROOT/transcript-resolved.jsonl"
write_transcript "$T2" "$TASK_USE_RESOLVED" "$TASK_RESULT_02"
result=$(run_hook "$T2" false)
assert_allow "(b) resolved Task tool_use -> allow" "$result"

# (c) no Task tool_use at all -> allow
T3="$TMPROOT/transcript-no-task.jsonl"
write_transcript "$T3" "$NON_TASK_USE"
result=$(run_hook "$T3" false)
assert_allow "(c) no Task tool_use -> allow" "$result"

# (d) stop_hook_active=true -> allow unconditionally (loop guard), even with
# an unresolved Task still present
result=$(run_hook "$T1" true)
assert_allow "(d) stop_hook_active=true -> allow (loop guard)" "$result"

# (e) missing transcript_path file -> allow (fail-open)
result=$(run_hook "$TMPROOT/does-not-exist.jsonl" false)
assert_allow "(e) missing transcript file -> allow (fail-open)" "$result"

# (f) unparseable transcript content -> allow (fail-open)
T4="$TMPROOT/transcript-garbage.jsonl"
printf 'not json at all\n{"also": "not", unterminated\n' > "$T4"
result=$(run_hook "$T4" false)
assert_allow "(f) unparseable transcript -> allow (fail-open)" "$result"

# (g) empty transcript_path in input -> allow
output=$(cd "$TMPROOT" && jq -n '{session_id:"t", transcript_path:"", stop_hook_active:false}' | bash "$HOOK" 2>/dev/null)
code=$?
if [[ "$code" == "0" && -z "$output" ]]; then
    pass "(g) empty transcript_path -> allow"
else
    fail "(g) empty transcript_path -> allow (got exit=$code output=$output)"
fi

# --- block reason mentions the #3822/#4257 hazard ---------------------------
raw=$(run_hook "$T1" false)
out="${raw#*|}"
reason=$(echo "$out" | jq -r '.reason // empty' 2>/dev/null || true)
if [[ "$reason" == *"claude -p"* && "$reason" == *"#3822"* ]]; then
    pass "block reason explains the headless -p kill-signal hazard"
else
    fail "block reason explains the headless -p kill-signal hazard (got: $reason)"
fi

# --- contract: block output is valid JSON -----------------------------------
if echo "$out" | jq empty 2>/dev/null; then
    pass "contract: block output is valid JSON"
else
    fail "contract: block output is valid JSON (got: $out)"
fi

# --- guards.backgroundSubagents config toggle -> disables the guard --------
mkdir -p "$TMPROOT/.loom"
cat > "$TMPROOT/.loom/config.json" <<'EOF'
{"guards": {"backgroundSubagents": false}}
EOF
result=$(run_hook "$T1" false)
assert_allow "guards.backgroundSubagents:false in config -> allow" "$result"
rm -f "$TMPROOT/.loom/config.json"

# --- LOOM_GUARD_BACKGROUND_SUBAGENTS=0 env override -> disables the guard --
result=$(run_hook "$T1" false LOOM_GUARD_BACKGROUND_SUBAGENTS=0)
assert_allow "LOOM_GUARD_BACKGROUND_SUBAGENTS=0 -> allow" "$result"

# --- env overrides config: env=1 forces guard on even if config says false -
cat > "$TMPROOT/.loom/config.json" <<'EOF'
{"guards": {"backgroundSubagents": false}}
EOF
result=$(run_hook "$T1" false LOOM_GUARD_BACKGROUND_SUBAGENTS=1)
assert_block "LOOM_GUARD_BACKGROUND_SUBAGENTS=1 overrides config:false -> block" "$result"
rm -f "$TMPROOT/.loom/config.json"

# --- jq absent -> allow (fail-open) -----------------------------------------
NOJQ_DIR="$(mktemp -d)"
for b in bash cat mkdir echo date sed dirname basename find python3 grep git env; do
    p=$(command -v "$b" 2>/dev/null) && ln -sf "$p" "$NOJQ_DIR/$b"
done
out=$(cd "$TMPROOT" && printf '{"transcript_path":"%s","stop_hook_active":false}' "$T1" | PATH="$NOJQ_DIR" bash "$HOOK" 2>/dev/null)
code=$?
if [[ "$code" == "0" && -z "$out" ]]; then
    pass "jq absent -> allow (fail-open)"
else
    fail "jq absent -> allow (fail-open) (got exit=$code output=$out)"
fi
rm -rf "$NOJQ_DIR"

echo "=== $PASS/$TOTAL passed ==="
[[ "$FAIL" -eq 0 ]]
