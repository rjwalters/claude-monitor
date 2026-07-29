#!/usr/bin/env bash
# test-loom-daemon-watchdog.sh — Tests for loom-daemon-watchdog.sh, the host-side
# autonomy-loss detector (issue #4011).
#
# The watchdog compares operator INTENT (the autonomy-desired marker) against
# REALITY (daemon liveness + heartbeat freshness) and reports on divergence. This
# suite drives it entirely from files it creates in a tempdir — a real daemon is
# never started, and no invocation ever touches ~/.loom or the operator's real
# launchd jobs (liveness is exercised through the pid-file path with
# LOOM_DAEMON_LAUNCHD=0, plus one stubbed-launchctl case).
#
# Style matches the other daemon lifecycle tests — plain bash, hand-rolled
# assertions. Bats is NOT used in this repository.
#
# Exit-code contract under test:
#   0  no divergence (healthy, or no daemon expected)
#   1  DIVERGENCE reported (expected-but-not-running, or wedged/stale heartbeat)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHDOG="$(cd "$SCRIPT_DIR/../cli" && pwd)/loom-daemon-watchdog.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_PASSED=$((TESTS_PASSED + 1)); echo -e "${GREEN}✓${NC} $1"; }
fail() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1)); echo -e "${RED}✗${NC} $1"; }

assert_rc() { # <expected> <actual> <msg>
    if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (expected rc=$1, got rc=$2)"; fi
}

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

MARKER="$WORKDIR/autonomy-desired"
HEARTBEAT="$WORKDIR/daemon.heartbeat"
WDLOG="$WORKDIR/watchdog.log"      # the watchdog's own report log (LOOM_WATCHDOG_LOG)
OUT="$WORKDIR/out.txt"             # captured stdout+stderr of each run (separate file)

# Write a marker describing a non-launchd (pid-file) daemon so liveness is probed
# via the pid file — deterministic and platform-independent.
write_marker() { # <pid_file> <heartbeat_interval_secs>
    cat > "$MARKER" <<EOF
started_at=2026-07-27T00:00:00Z
repo_root=$WORKDIR
pid_file=$1
heartbeat_file=$HEARTBEAT
heartbeat_interval_secs=$2
use_launchd=false
launchd_label=com.example.test
socket_path=$WORKDIR/loom-daemon.sock
EOF
}

# Portable mtime back-dating (macOS `date -v`, GNU `date -d`).
back_date_file() { # <file> <seconds_ago>
    local f="$1" secs="$2" ts
    ts=$(date -v-"${secs}"S '+%Y%m%d%H%M.%S' 2>/dev/null) \
        || ts=$(date -d "@$(( $(date +%s) - secs ))" '+%Y%m%d%H%M.%S' 2>/dev/null)
    [[ -n "$ts" ]] && touch -t "$ts" "$f" 2>/dev/null
}

# Run the watchdog on the pid-file path (LOOM_DAEMON_LAUNCHD=0). Extra env
# assignments may be passed as KEY=VAL positional args. Sets global RC.
run_watchdog() {
    : > "$OUT"
    env "$@" LOOM_AUTONOMY_MARKER="$MARKER" LOOM_WATCHDOG_LOG="$WDLOG" \
        LOOM_DAEMON_LAUNCHD=0 bash "$WATCHDOG" > "$OUT" 2>&1
    RC=$?
}

log_has()  { grep -q "$1" "$WDLOG" 2>/dev/null; }
log_hasi() { grep -qi "$1" "$WDLOG" 2>/dev/null; }

# A live pid we own for the "daemon alive" cases. The sleeper's stdio is
# redirected to /dev/null so it does NOT hold open the `$(sleeper)` command
# substitution pipe (which would otherwise block the caller for the full sleep).
sleeper() { sleep 60 >/dev/null 2>&1 & echo $!; }

# ===================================================================
# 1. Marker ABSENT ⇒ no daemon expected ⇒ silent OK (exit 0).
# ===================================================================
rm -f "$MARKER" "$HEARTBEAT" "$WDLOG"
run_watchdog
assert_rc 0 "$RC" "marker absent: exits 0 (no daemon expected)"
if log_has DIVERGENCE; then fail "marker absent: unexpected DIVERGENCE"; else pass "marker absent: no DIVERGENCE reported"; fi

# ===================================================================
# 2. Intent present, daemon ALIVE, heartbeat FRESH ⇒ silent OK.
# ===================================================================
live_pid=$(sleeper)
echo "$live_pid" > "$WORKDIR/pidA"
write_marker "$WORKDIR/pidA" 60
printf '%s pid=%s ts=now\n' "$(date +%s)" "$live_pid" > "$HEARTBEAT"
: > "$WDLOG"
run_watchdog
kill "$live_pid" 2>/dev/null || true
assert_rc 0 "$RC" "alive + fresh heartbeat: exits 0"

# ===================================================================
# 3. Intent present, daemon ALIVE, heartbeat STALE ⇒ DIVERGENCE (wedged).
# ===================================================================
live_pid=$(sleeper)
echo "$live_pid" > "$WORKDIR/pidB"
write_marker "$WORKDIR/pidB" 60
printf 'old\n' > "$HEARTBEAT"
back_date_file "$HEARTBEAT" 3600   # 1h old, well past the 300s default threshold
: > "$WDLOG"
run_watchdog
kill "$live_pid" 2>/dev/null || true
assert_rc 1 "$RC" "alive + STALE heartbeat: exits 1 (divergence)"
if log_has STALE; then pass "alive + stale heartbeat: reports it as wedged/stale"; else fail "alive + stale heartbeat: no STALE report"; fi

# ===================================================================
# 4. Intent present, daemon DEAD ⇒ DIVERGENCE (expected but not running).
#    This IS the #4011 outage, reproduced.
# ===================================================================
dead_pid=$(sleeper); kill "$dead_pid" 2>/dev/null; wait "$dead_pid" 2>/dev/null
echo "$dead_pid" > "$WORKDIR/pidC"
write_marker "$WORKDIR/pidC" 60
printf 'x\n' > "$HEARTBEAT"
: > "$WDLOG"
run_watchdog
assert_rc 1 "$RC" "daemon DEAD but expected: exits 1 (the #4011 outage)"
if log_has EXPECTED && log_hasi "not"; then
    pass "daemon dead: reports 'expected but not running'"
else
    fail "daemon dead: missing the expected-but-not-running report"
fi

# ===================================================================
# 5. Intent present, daemon ALIVE, NO heartbeat file ⇒ liveness-only OK.
#    (heartbeat disabled or not yet written — do NOT false-report.)
# ===================================================================
live_pid=$(sleeper)
echo "$live_pid" > "$WORKDIR/pidD"
write_marker "$WORKDIR/pidD" 60
rm -f "$HEARTBEAT"
: > "$WDLOG"
run_watchdog
kill "$live_pid" 2>/dev/null || true
assert_rc 0 "$RC" "alive + no heartbeat file: exits 0 (liveness-only, no false page)"

# ===================================================================
# 6. Staleness threshold is a comfortable multiple of the cadence: a heartbeat
#    just under the default 300s threshold is NOT reported (no flapping).
# ===================================================================
live_pid=$(sleeper)
echo "$live_pid" > "$WORKDIR/pidE"
write_marker "$WORKDIR/pidE" 60
printf 'x\n' > "$HEARTBEAT"
back_date_file "$HEARTBEAT" 120   # 2min old < 300s threshold ⇒ still fresh
: > "$WDLOG"
run_watchdog
kill "$live_pid" 2>/dev/null || true
assert_rc 0 "$RC" "heartbeat 120s old < 300s threshold: not flagged (no flapping)"

# ===================================================================
# 7. LOOM_DAEMON_HEARTBEAT_STALE_SECS override is honored.
# ===================================================================
live_pid=$(sleeper)
echo "$live_pid" > "$WORKDIR/pidF"
write_marker "$WORKDIR/pidF" 60
printf 'x\n' > "$HEARTBEAT"
back_date_file "$HEARTBEAT" 10
: > "$WDLOG"
run_watchdog LOOM_DAEMON_HEARTBEAT_STALE_SECS=5
kill "$live_pid" 2>/dev/null || true
assert_rc 1 "$RC" "STALE_SECS override: 10s-old heartbeat with 5s threshold is flagged"

# ===================================================================
# 8. launchd path via a stubbed launchctl reporting the job is NOT loaded ⇒
#    DIVERGENCE (mirrors a booted-out daemon).
# ===================================================================
STUB_BIN="$WORKDIR/stubbin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/launchctl" <<'EOF'
#!/usr/bin/env bash
# Stub: `print` always reports the job is not loaded (exit 1); no real job touched.
case "${1:-}" in
  print) exit 1 ;;
  *)     exit 0 ;;
esac
EOF
chmod +x "$STUB_BIN/launchctl"
cat > "$MARKER" <<EOF
started_at=2026-07-27T00:00:00Z
heartbeat_file=$HEARTBEAT
heartbeat_interval_secs=60
use_launchd=true
launchd_label=com.example.loom-sandbox-$$
socket_path=$WORKDIR/loom-daemon.sock
EOF
: > "$WDLOG" "$OUT"
if [[ "$(uname -s)" == "Darwin" ]]; then
    env PATH="$STUB_BIN:$PATH" LOOM_AUTONOMY_MARKER="$MARKER" LOOM_WATCHDOG_LOG="$WDLOG" \
        bash "$WATCHDOG" > "$OUT" 2>&1
    assert_rc 1 "$?" "launchd path: booted-out job (stub print exit 1) ⇒ divergence"
else
    # On non-Darwin the watchdog forces the pid-file path; with no pid_file in the
    # marker that resolves to "no live pid" ⇒ divergence, which is still correct.
    env LOOM_AUTONOMY_MARKER="$MARKER" LOOM_WATCHDOG_LOG="$WDLOG" bash "$WATCHDOG" > "$OUT" 2>&1
    assert_rc 1 "$?" "non-Darwin: expected daemon with no live pid ⇒ divergence"
fi

# ===================================================================
# 9. --help works and documents the marker + StartInterval design.
# ===================================================================
help_out=$(bash "$WATCHDOG" --help 2>/dev/null)
if echo "$help_out" | grep -qi 'autonomy-desired' && echo "$help_out" | grep -qi 'StartInterval'; then
    pass "--help documents the marker + StartInterval rationale"
else
    fail "--help missing marker/StartInterval documentation"
fi

echo
echo "Ran $TESTS_RUN tests: $TESTS_PASSED passed, $TESTS_FAILED failed"
[[ "$TESTS_FAILED" -eq 0 ]]