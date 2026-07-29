#!/usr/bin/env bash
# guard-background-subagents.sh — Stop hook backstop for issue #4257
#
# Mechanical backstop for the hazard documented in
# defaults/.claude/commands/loom/sweep.md under "CRITICAL: Subagent dispatch is
# async-only — you MUST block explicitly (issue #3822)": in headless
# `claude -p` mode, ending the orchestrator's turn terminates the process,
# which kills every still-running background Task subagent. That section is a
# documentation-only guardrail; this hook is the mechanical backstop for when
# an orchestrator forgets it and tries to end its turn anyway.
#
# Contract (Stop hook):
#   Input (JSON on stdin): { "session_id": "...", "transcript_path": "...",
#     "stop_hook_active": true|false, "hook_event_name": "Stop", ... }
#   Output: to block the stop, print `{"decision":"block","reason":"..."}` to
#     stdout and exit 0. To allow the stop, exit 0 with no output.
#
# Detection heuristic: scan the transcript JSONL for assistant `tool_use`
# entries named "Task" (the harness's subagent-dispatch tool) whose id has no
# matching `tool_result` anywhere later in the transcript — i.e. a subagent
# was dispatched and the transcript never observed its completion before the
# orchestrator tried to end its turn. This is a HEURISTIC over the transcript
# file, not a live process check (no such live signal exists here), so it can
# have false positives (e.g. a slow transcript flush) — hence the single-block
# semantics below rather than a hard, repeatable deny.
#
# Loop guard: `stop_hook_active` is true when this hook itself caused an
# earlier block in the current stop sequence. Blocking unconditionally on that
# second pass would wedge the session in an infinite "you must continue" loop
# the orchestrator can never satisfy if the heuristic keeps re-firing (e.g. a
# tool_result that legitimately never lands in this transcript format). So:
# block AT MOST ONCE per stop sequence, then allow.
#
# Toggle: guards.backgroundSubagents (default true) / LOOM_GUARD_BACKGROUND_SUBAGENTS
# env override, same env > config > default precedence as every other guard
# category in this repo (see guard-worktree-paths.sh).
#
# Error handling: this script MUST NEVER exit non-zero, and any unexpected
# error (missing jq, unreadable/unparseable transcript, malformed input)
# fails OPEN (allow the stop) rather than wedging the session.

trap 'exit 0' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null || echo ".")"
MAIN_ROOT="$(cd "$(git -C "$SCRIPT_DIR" rev-parse --git-common-dir 2>/dev/null)/.." 2>/dev/null && pwd)" || \
MAIN_ROOT="$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd 2>/dev/null || echo ".")"

# =============================================================================
# Guard toggle — guards.backgroundSubagents / LOOM_GUARD_BACKGROUND_SUBAGENTS
# Default ON. Resolution order (highest precedence first):
#   1. LOOM_GUARD_BACKGROUND_SUBAGENTS env var (0/false/no disables, 1/true/yes forces on)
#   2. .loom/config.json -> guards.backgroundSubagents (default true when absent)
#   3. Default: true (guard on)
# =============================================================================
background_subagent_guard_enabled() {
    local enabled=true
    if [[ -n "$MAIN_ROOT" && -f "$MAIN_ROOT/.loom/config.json" ]] && command -v jq &>/dev/null; then
        enabled=$(jq -r 'if .guards.backgroundSubagents == false then "false" else "true" end' "$MAIN_ROOT/.loom/config.json" 2>/dev/null) || enabled=true
        [[ -n "$enabled" ]] || enabled=true
    fi
    case "${LOOM_GUARD_BACKGROUND_SUBAGENTS:-}" in
        0|false|no)  enabled=false ;;
        1|true|yes)  enabled=true ;;
    esac
    [[ "$enabled" == "true" ]]
}

if ! background_subagent_guard_enabled; then
    exit 0
fi

if ! command -v jq &>/dev/null; then
    exit 0
fi

INPUT=$(cat 2>/dev/null) || INPUT=""
[[ -n "$INPUT" ]] || exit 0

# Loop guard: never block twice in the same stop sequence.
STOP_HOOK_ACTIVE=$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null) || STOP_HOOK_ACTIVE="false"
if [[ "$STOP_HOOK_ACTIVE" == "true" ]]; then
    exit 0
fi

TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null) || TRANSCRIPT_PATH=""
[[ -n "$TRANSCRIPT_PATH" && -r "$TRANSCRIPT_PATH" ]] || exit 0

# Slurp the transcript JSONL as an array and diff Task tool_use ids against
# observed tool_result ids. Any left over are unresolved. Fails open (empty
# result, no block) on any parse error — the `// empty` / `?` guards below
# make a malformed line a no-op rather than a hard jq failure, and the
# surrounding `trap ERR -> exit 0` plus this command's own `|| ...` catch
# any jq invocation failure itself.
UNRESOLVED_IDS=$(jq -s -r '
  [ .[]? | select(.type=="assistant") | .message.content[]?
    | select(.type=="tool_use" and .name=="Task") | .id ] as $task_ids
  | [ .[]? | select(.type=="user") | .message.content[]?
    | select(.type=="tool_result") | .tool_use_id ] as $result_ids
  | ($task_ids - $result_ids) | .[]
' "$TRANSCRIPT_PATH" 2>/dev/null) || UNRESOLVED_IDS=""

[[ -n "$UNRESOLVED_IDS" ]] || exit 0

COUNT=$(printf '%s\n' "$UNRESOLVED_IDS" | grep -c . || true)

REASON="STOP BLOCKED (guard-background-subagents.sh, issue #4257): ${COUNT} dispatched Task subagent(s) have no observed completion in this transcript yet. In headless \`claude -p\` mode, ending this turn TERMINATES THE PROCESS and kills every still-running background child -- there is no 'it finishes after I stop talking'. Before writing a final message, you MUST explicitly await each dispatched subagent's completion (blocking TaskOutput / completion notification) -- see defaults/.claude/commands/loom/sweep.md, 'CRITICAL: Subagent dispatch is async-only' (#3822). If you are certain every subagent has actually finished (e.g. this is a false positive from a slow transcript flush), it is safe to stop again -- this guard blocks at most once per stop sequence."

jq -n --arg reason "$REASON" '{decision: "block", reason: $reason}' 2>/dev/null && exit 0

# jq construction failed for some reason -- fall back to a hand-built JSON
# literal so the block decision still lands even if jq -n misbehaves.
ESCAPED=$(printf '%s' "$REASON" | sed 's/\\/\\\\/g; s/"/\\"/g')
printf '{"decision":"block","reason":"%s"}\n' "$ESCAPED"
exit 0
