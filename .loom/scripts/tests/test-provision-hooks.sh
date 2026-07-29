#!/usr/bin/env bash
# test-provision-hooks.sh — tests for user-scope Loom guard-hook wiring
# (Epic #3835 Phase 5, #4262).
#
# Covers scripts/install/provision-hooks.sh:
#   - fresh provision merges the Loom hook entries into a missing / empty /
#     populated ~/.claude/settings.json
#   - the verifiable-globals contract (PROVISIONED_HOOKS_SETTINGS /
#     PROVISIONED_HOOKS_BACKUP, mirroring provision-dispatcher.sh #4053)
#   - idempotent re-provision (no duplicates, including a requoted pre-existing
#     entry — the #4200 lesson)
#   - pre-existing non-Loom hooks + permissions are preserved
#   - invalid existing JSON -> soft-fail (return 1) with NO write
#   - a backup file is written before the first mutation
#   - the wired command WRAPPER behaves: no-ops outside a Loom workspace (AC3),
#     execs the machine-checkout hook inside one (AC1), and defers to a present
#     per-repo .loom/hooks/ copy (transition dedup, design decision 3)
#   - deprovision removes ONLY Loom-owned entries, preserving operator hooks
#
# Sandboxed $HOME per case via mktemp -d, matching test-provision-skills.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# defaults/scripts/tests -> defaults/scripts/tests/../../.. -> repo root
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

PROVISION_LIB="$REPO_ROOT/scripts/install/provision-hooks.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_PASSED=$((TESTS_PASSED + 1)); echo -e "  ${GREEN}PASS${NC}: $1"; }
fail() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1)); echo -e "  ${RED}FAIL${NC}: $1"; }

assert_eq() {
    if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (expected '$2', got '$1')"; fi
}
assert_contains() {
    if [[ "$1" == *"$2"* ]]; then pass "$3"; else fail "$3 (missing substring: '$2')"; fi
}

[[ -f "$PROVISION_LIB" ]] || { echo "provisioning lib not found at $PROVISION_LIB"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq required for these tests"; exit 1; }

# shellcheck source=/dev/null
source "$PROVISION_LIB"

# Count hook commands (across all types/matchers) whose command carries the
# machine-level marker for a given hook script name.
count_marker() {
    local file="$1" name="$2"
    jq --arg m "defaults/hooks/$name" '
        [ (.hooks // {}) | to_entries[] | .value[]? | .hooks[]? | .command // "" | select(contains($m)) ] | length
    ' "$file" 2>/dev/null
}

# ── Test 1: fresh provision into a MISSING settings.json ─────────────────────
echo "Test 1: fresh provision creates settings.json and wires all Loom hooks"
HOME1=$(mktemp -d)
OUT1=$(mktemp)
provision_loom_hooks "$HOME1/.claude" >"$OUT1" 2>&1
rc=$?
assert_eq "$rc" "0" "fresh provision returns 0"
SET1="$HOME1/.claude/settings.json"
[[ -f "$SET1" ]] && pass "settings.json was created" || fail "settings.json was not created"
jq empty "$SET1" 2>/dev/null && pass "settings.json is valid JSON" || fail "settings.json is not valid JSON"
assert_eq "$(count_marker "$SET1" guard-destructive.sh)" "1" "guard-destructive.sh wired once"
assert_eq "$(count_marker "$SET1" guard-worktree-paths.sh)" "1" "guard-worktree-paths.sh (Edit|Write) wired once"
assert_eq "$(count_marker "$SET1" guard-background-subagents.sh)" "1" "Stop hook wired once"
# The Edit|Write matcher exists (design decision 4 — consumers never had it).
assert_eq "$(jq -r '[.hooks.PreToolUse[]?.matcher] | index("Edit|Write") != null' "$SET1")" "true" "Edit|Write matcher is present"

# ── Test 2: verifiable-globals contract (#4053) ──────────────────────────────
echo "Test 2: provisioning exposes verifiable globals (#4053)"
assert_eq "$PROVISIONED_HOOKS_SETTINGS" "$SET1" "PROVISIONED_HOOKS_SETTINGS points at the settings file"
# No backup on a fresh (missing) file — nothing to preserve.
assert_eq "$PROVISIONED_HOOKS_BACKUP" "" "no backup written when there was no pre-existing file"

# ── Test 3: idempotent re-provision (no duplicates) ──────────────────────────
echo "Test 3: re-provision is idempotent (no duplicate entries)"
provision_loom_hooks "$HOME1/.claude" >/dev/null 2>&1
assert_eq "$(count_marker "$SET1" guard-destructive.sh)" "1" "guard-destructive.sh still wired exactly once after re-run"
assert_eq "$(count_marker "$SET1" skill-router.sh)" "1" "skill-router.sh still wired exactly once after re-run"

# ── Test 4: dedup against a REQUOTED pre-existing entry (#4200 lesson) ────────
echo "Test 4: dedup keys on the marker substring, so a requoted entry is not duplicated (#4200)"
HOME4=$(mktemp -d); mkdir -p "$HOME4/.claude"
# A pre-existing Loom entry with DIFFERENT quoting/wrapper but the SAME marker.
cat > "$HOME4/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [
        { "type": "command", "command": "sh -c \"exec ${LOOM_HOME}/defaults/hooks/guard-destructive.sh\"" }
      ] }
    ]
  }
}
EOF
provision_loom_hooks "$HOME4/.claude" >/dev/null 2>&1
assert_eq "$(count_marker "$HOME4/.claude/settings.json" guard-destructive.sh)" "1" "requoted guard-destructive.sh entry is not duplicated"

# ── Test 5: pre-existing non-Loom hooks + permissions preserved ──────────────
echo "Test 5: operator's non-Loom hooks and permissions are preserved"
HOME5=$(mktemp -d); mkdir -p "$HOME5/.claude"
cat > "$HOME5/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [
        { "type": "command", "command": ".claude/hooks/my-own-guard.sh" }
      ] }
    ]
  },
  "permissions": { "allow": ["Bash(mytool:*)"] }
}
EOF
provision_loom_hooks "$HOME5/.claude" >/dev/null 2>&1
S5="$HOME5/.claude/settings.json"
assert_eq "$(jq -r '[.hooks.PreToolUse[] | .hooks[]? | .command | select(. == ".claude/hooks/my-own-guard.sh")] | length' "$S5")" "1" "operator's own hook preserved"
assert_eq "$(jq -r '.permissions.allow[0]' "$S5")" "Bash(mytool:*)" "operator's permissions preserved"
assert_eq "$(count_marker "$S5" guard-destructive.sh)" "1" "Loom hook added alongside the operator's Bash matcher"

# ── Test 6: invalid existing JSON -> soft-fail, NO write ─────────────────────
echo "Test 6: invalid existing JSON is left untouched (soft-fail)"
HOME6=$(mktemp -d); mkdir -p "$HOME6/.claude"
printf 'this is { not json' > "$HOME6/.claude/settings.json"
before6=$(cat "$HOME6/.claude/settings.json")
OUT6=$(mktemp)
provision_loom_hooks "$HOME6/.claude" >"$OUT6" 2>&1
rc=$?
assert_eq "$rc" "1" "invalid JSON returns 1"
assert_eq "$(cat "$HOME6/.claude/settings.json")" "$before6" "invalid JSON file left byte-identical (no write)"
assert_contains "$(cat "$OUT6")" "not valid JSON" "explains the refusal"

# ── Test 7: a backup is written before the first mutation ─────────────────────
echo "Test 7: a backup file is written before mutating an existing settings.json"
HOME7=$(mktemp -d); mkdir -p "$HOME7/.claude"
echo '{"permissions":{"allow":["Bash(x:*)"]}}' > "$HOME7/.claude/settings.json"
provision_loom_hooks "$HOME7/.claude" >/dev/null 2>&1
backups=$(find "$HOME7/.claude" -maxdepth 1 -name 'settings.json.loom-backup-*' | wc -l | tr -d ' ')
[[ "$backups" -ge 1 ]] && pass "a timestamped backup was written" || fail "no backup file found"
# The backup holds the ORIGINAL content (pre-mutation).
bfile=$(find "$HOME7/.claude" -maxdepth 1 -name 'settings.json.loom-backup-*' | head -1)
assert_eq "$(jq -r '.permissions.allow[0]' "$bfile")" "Bash(x:*)" "backup preserves the pre-mutation content"

# ── Test 8: the wired WRAPPER command behaves correctly ──────────────────────
echo "Test 8: the wired command wrapper — workspace gate, machine exec, transition dedup"
# Build a fake machine checkout whose guard-destructive.sh prints a sentinel.
CHK=$(mktemp -d)
mkdir -p "$CHK/defaults/hooks"
printf '#!/usr/bin/env bash\necho "MACHINE-RAN:$LOOM_PROJECT_ROOT"\nexit 0\n' > "$CHK/defaults/hooks/guard-destructive.sh"
chmod +x "$CHK/defaults/hooks/guard-destructive.sh"
# Extract the actual wired command for guard-destructive.sh from a fresh provision.
HOME8=$(mktemp -d)
provision_loom_hooks "$HOME8/.claude" >/dev/null 2>&1
CMD=$(jq -r '.hooks.PreToolUse[] | select(.matcher=="Bash") | .hooks[] | .command | select(contains("defaults/hooks/guard-destructive.sh"))' "$HOME8/.claude/settings.json" | head -1)
[[ -n "$CMD" ]] && pass "extracted the wired guard-destructive.sh command" || fail "could not extract the wired command"

WOUT=""; WRC=0
run_wrapper() { # $1=cwd -> assigns globals WOUT + WRC in the CURRENT shell
    WOUT=$(cd "$1" && LOOM_HOME="$CHK" bash -c "$CMD" </dev/null 2>/dev/null)
    WRC=$?
}

# 8a: non-Loom repo -> no-op (AC3)
NONLOOM=$(mktemp -d); git -C "$NONLOOM" init -q
run_wrapper "$NONLOOM"
[[ -z "$WOUT" && "$WRC" == "0" ]] && pass "AC3: non-Loom repo -> silent no-op (exit 0)" || fail "AC3: expected silent exit 0, got out='$WOUT' rc=$WRC"

# 8b: Loom workspace (legacy .loom/config.json), no per-repo copy -> machine exec (AC1)
LOOMREPO=$(mktemp -d); git -C "$LOOMREPO" init -q; mkdir -p "$LOOMREPO/.loom"; echo '{}' > "$LOOMREPO/.loom/config.json"
run_wrapper "$LOOMREPO"
assert_contains "$WOUT" "MACHINE-RAN:$LOOMREPO" "AC1: Loom workspace with no copy -> execs the machine hook, LOOM_PROJECT_ROOT set"

# 8c: Loom workspace WITH a per-repo .loom/hooks/ copy -> defers (transition dedup)
mkdir -p "$LOOMREPO/.loom/hooks"
printf '#!/usr/bin/env bash\necho SHOULD-NOT-RUN\n' > "$LOOMREPO/.loom/hooks/guard-destructive.sh"
chmod +x "$LOOMREPO/.loom/hooks/guard-destructive.sh"
run_wrapper "$LOOMREPO"
[[ -z "$WOUT" && "$WRC" == "0" ]] && pass "transition: defers to a present per-repo copy (machine hook does not run)" || fail "transition: expected silent defer, got out='$WOUT' rc=$WRC"

# 8d: Loom workspace but machine checkout absent -> no-op (fail-open)
out=$(cd "$LOOMREPO" && rm -rf "$LOOMREPO/.loom/hooks" && LOOM_HOME="/nonexistent/checkout" bash -c "$CMD" </dev/null 2>/dev/null); wrc=$?
[[ -z "$out" && "$wrc" == "0" ]] && pass "machine checkout absent -> silent no-op (exit 0)" || fail "expected silent exit 0 when checkout absent, got out='$out' rc=$wrc"

# ── Test 9: deprovision removes only Loom-owned entries ──────────────────────
echo "Test 9: deprovision strips Loom-owned entries, preserves operator hooks"
HOME9=$(mktemp -d); mkdir -p "$HOME9/.claude"
cat > "$HOME9/.claude/settings.json" <<'EOF'
{ "hooks": { "PreToolUse": [ { "matcher": "Bash", "hooks": [
  { "type": "command", "command": ".claude/hooks/my-own-guard.sh" }
] } ] }, "permissions": { "allow": ["Bash(x:*)"] } }
EOF
provision_loom_hooks "$HOME9/.claude" >/dev/null 2>&1
deprovision_loom_hooks "$HOME9/.claude" >/dev/null 2>&1
S9="$HOME9/.claude/settings.json"
assert_eq "$(count_marker "$S9" guard-destructive.sh)" "0" "deprovision removed the Loom hook entries"
assert_eq "$(jq -r '[.hooks.PreToolUse[]? | .hooks[]? | .command | select(. == ".claude/hooks/my-own-guard.sh")] | length' "$S9")" "1" "operator's own hook preserved after deprovision"
assert_eq "$(jq -r '.permissions.allow[0]' "$S9")" "Bash(x:*)" "operator's permissions preserved after deprovision"

echo ""
echo "======================================"
echo "test-provision-hooks.sh: $TESTS_PASSED/$TESTS_RUN passed, $TESTS_FAILED failed"
echo "======================================"
[[ "$TESTS_FAILED" -eq 0 ]]
