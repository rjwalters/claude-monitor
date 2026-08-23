#!/usr/bin/env bash
# test-record-noop-release.sh — regression test for #6740 ("Wire a first
# in-repo call site for `loom-daemon noop-cooldown record`", follow-up to
# #6670/PR #6739).
#
# Covers `defaults/scripts/record-noop-release.sh`, the shell helper
# `/loom:sweep`'s Builder phase invokes right before releasing a `loom:building`
# claim back to `loom:issue` on a genuine "no actionable delta this pass"
# conclusion (see sweep.md -> "Genuine no-op conclusion vs. builder failure").
#
# Mirrors `test-build-gate-timeout.sh`'s Section 2 (dispatch-backoff record
# call-shape assertion, #6192/#4485) for the sibling `noop-cooldown record`
# mechanism:
#   - A recording stub daemon binary (driven via $LOOM_DAEMON_BIN) proves the
#     EXACT call shape: `noop-cooldown record <ISSUE> --reason <TEXT>` — a
#     positional issue argument, NOT an `--issue` flag (the actual
#     `loom-daemon noop-cooldown record` CLI takes ISSUE positionally; the
#     `--issue` shape sometimes seen in prose/docs does not exist).
#   - A missing/unreachable/erroring daemon must never fail the caller: the
#     script always exits 0 in that case (best-effort, #6670).
#   - A genuine usage error (missing/non-numeric ISSUE) is NOT swallowed —
#     that is a caller bug, not a daemon-availability condition.
#
# Hermetic: stubs the daemon binary via $LOOM_DAEMON_BIN, never touches a
# forge, a socket, or a real toolchain.
#
# Usage:
#   bash defaults/scripts/tests/test-record-noop-release.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Resolve a shipped script by its path relative to the scripts root, preferring
# the installed location over the source-tree one — same precedent as
# test-build-gate-timeout.sh (#6194): every subject here is a *shipped*
# script (scripts/* -> .loom/scripts/* per scripts/install/manifest.sh), so
# this suite is meaningful in an installed consumer repo too.
resolve_shipped_script() {
    local rel="$1"
    if [[ -f "$REPO_ROOT/.loom/scripts/$rel" ]]; then
        printf '%s\n' "$REPO_ROOT/.loom/scripts/$rel"
    else
        printf '%s\n' "$REPO_ROOT/defaults/scripts/$rel"
    fi
}

RECORD_NOOP="$(resolve_shipped_script "record-noop-release.sh")"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

passed=0
failed=0
pass() { echo -e "${GREEN}\xe2\x9c\x93${NC} $1"; passed=$((passed + 1)); }
fail() { echo -e "${RED}\xe2\x9c\x97${NC} $1"; failed=$((failed + 1)); }

if [[ ! -f "$RECORD_NOOP" ]]; then
    echo "ERROR: record-noop-release.sh not found at $REPO_ROOT/.loom/scripts/record-noop-release.sh or $REPO_ROOT/defaults/scripts/record-noop-release.sh" >&2
    exit 1
fi

STUB_DIR="$(mktemp -d)"
cleanup() {
    rm -rf "$STUB_DIR" 2>/dev/null || true
}
trap cleanup EXIT
trap 'cleanup; exit 1' INT TERM

# ---------------------------------------------------------------------------
# Section 1: exact call-shape assertion via a recording stub daemon binary
# ---------------------------------------------------------------------------

CALL_LOG="$STUB_DIR/calls.log"
cat > "$STUB_DIR/loom-daemon" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CALL_LOG"
exit 0
EOF
chmod +x "$STUB_DIR/loom-daemon"

: > "$CALL_LOG"
output="$(cd "$REPO_ROOT" && LOOM_DAEMON_BIN="$STUB_DIR/loom-daemon" \
    bash "$RECORD_NOOP" 6740 --reason "no actionable delta this pass" 2>&1)"
rc=$?

if [[ "$rc" -eq 0 ]]; then
    pass "recording a no-op release exits 0"
else
    fail "expected exit 0, got $rc: $output"
fi

if grep -q "noop-cooldown record" "$CALL_LOG" 2>/dev/null; then
    pass "invokes 'loom-daemon noop-cooldown record' (#6670)"
else
    fail "expected a noop-cooldown record call, log was: $(cat "$CALL_LOG" 2>/dev/null)"
fi

# The issue number must be POSITIONAL (the real CLI has no --issue flag) —
# assert it appears as a bare token, not prefixed by --issue.
if grep -Eq '(^|[[:space:]])6740([[:space:]]|$)' "$CALL_LOG" 2>/dev/null; then
    pass "the issue number is passed positionally (matches the real CLI shape)"
else
    fail "expected a bare positional '6740' in the recorded call, log was: $(cat "$CALL_LOG" 2>/dev/null)"
fi

if grep -q -- "--issue" "$CALL_LOG" 2>/dev/null; then
    fail "recorded call used a non-existent '--issue' flag: $(cat "$CALL_LOG" 2>/dev/null)"
else
    pass "recorded call does not use the non-existent '--issue' flag"
fi

if grep -q -- "--reason no actionable delta this pass" "$CALL_LOG" 2>/dev/null; then
    pass "the reason text is forwarded verbatim"
else
    fail "expected the reason text in the recorded call, log was: $(cat "$CALL_LOG" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# Section 2: missing/unreachable/erroring daemon is a SILENT no-op (#6670)
# ---------------------------------------------------------------------------

# No claim to arm anything with a genuinely nonexistent binary path.
: > "$CALL_LOG"
noop_output="$(cd "$REPO_ROOT" && LOOM_DAEMON_BIN="$STUB_DIR/does-not-exist" \
    bash "$RECORD_NOOP" 6741 --reason "x" 2>&1)"
noop_rc=$?

if [[ "$noop_rc" -eq 0 ]]; then
    pass "a nonexistent \$LOOM_DAEMON_BIN path still exits 0 (falls through to other resolution, never fails)"
else
    fail "expected exit 0 even when \$LOOM_DAEMON_BIN does not resolve, got $noop_rc: $noop_output"
fi

# An erroring/unreachable daemon binary must never change the caller's own
# verdict — the daemon-side failure is swallowed.
cat > "$STUB_DIR/err-daemon" <<'EOF'
#!/usr/bin/env bash
echo "Could not reach loom-daemon" >&2
exit 1
EOF
chmod +x "$STUB_DIR/err-daemon"

err_output="$(cd "$REPO_ROOT" && LOOM_DAEMON_BIN="$STUB_DIR/err-daemon" \
    bash "$RECORD_NOOP" 6742 --reason "x" 2>&1)"
err_rc=$?

if [[ "$err_rc" -eq 0 ]]; then
    pass "an erroring/unreachable daemon still exits 0 (best-effort, never fails the caller)"
else
    fail "expected exit 0 despite a failing daemon, got $err_rc: $err_output"
fi

# ---------------------------------------------------------------------------
# Section 3: a genuine usage error is NOT swallowed (distinct from the
# daemon-availability cases above)
# ---------------------------------------------------------------------------

missing_output="$(cd "$REPO_ROOT" && bash "$RECORD_NOOP" 2>&1)"
missing_rc=$?

if [[ "$missing_rc" -ne 0 ]]; then
    pass "a missing <ISSUE> argument is a real usage error (non-zero exit)"
else
    fail "expected a non-zero exit for a missing <ISSUE> argument, got $missing_rc: $missing_output"
fi

nonnumeric_output="$(cd "$REPO_ROOT" && bash "$RECORD_NOOP" not-a-number 2>&1)"
nonnumeric_rc=$?

if [[ "$nonnumeric_rc" -ne 0 ]]; then
    pass "a non-numeric <ISSUE> argument is a real usage error (non-zero exit)"
else
    fail "expected a non-zero exit for a non-numeric <ISSUE> argument, got $nonnumeric_rc: $nonnumeric_output"
fi

echo ""
echo "=== Results: $passed passed, $failed failed ==="
if [[ "$failed" -gt 0 ]]; then
    exit 1
fi
exit 0
