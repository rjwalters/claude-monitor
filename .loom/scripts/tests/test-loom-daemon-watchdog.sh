#!/usr/bin/env bash
# test-loom-daemon-watchdog.sh — Tests for loom-daemon-watchdog.sh, the host-side
# autonomy-loss detector (issue #4011).
#
# The watchdog compares operator INTENT (the autonomy-desired marker) against
# REALITY (daemon liveness + heartbeat freshness + — since #4398 — a bounded
# in-band IPC round-trip) and reports on divergence. This suite drives it
# entirely from files it creates in a tempdir — a real daemon is never started,
# and no invocation ever touches ~/.loom or the operator's real launchd jobs
# (liveness is exercised through the pid-file path with LOOM_DAEMON_LAUNCHD=0,
# plus one stubbed-launchctl case; the #4398 probe always runs against a stub
# binary pinned via LOOM_DAEMON_BIN, never the installed loom-daemon).
#
# Style matches the other daemon lifecycle tests — plain bash, hand-rolled
# assertions. Bats is NOT used in this repository.
#
# Exit-code contract under test:
#   0  no divergence (healthy, or no daemon expected)
#   1  DIVERGENCE reported (expected-but-not-running, wedged/stale heartbeat, or
#      #4398: alive + heartbeat-fresh but the bounded IPC round-trip failed)

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
#
# LOOM_SOCKET_PATH is pinned into the tempdir so the resolved <loom_dir> is
# $WORKDIR — this matters for the marker-ABSENT reality probe (#4331), whose
# default pid file is `<loom_dir>/.daemon.pid`: without this the probe would look
# at the operator's real ~/.loom/.daemon.pid and a live host daemon could break
# the "nothing alive" cases.
#
# LOOM_WATCHDOG_IPC_PROBE=0 is the harness DEFAULT (#4398): the pre-#4398 cases
# below assert the pid + heartbeat contract, and must not become dependent on
# whether the host happens to have a `loom-daemon` on PATH or a live socket. It
# is listed BEFORE "$@" so a caller can re-enable the probe by passing
# LOOM_WATCHDOG_IPC_PROBE=1 (later `env` assignments win). The dedicated probe
# cases in section 12+ do exactly that.
run_watchdog() {
    : > "$OUT"
    env LOOM_WATCHDOG_IPC_PROBE=0 "$@" LOOM_AUTONOMY_MARKER="$MARKER" LOOM_WATCHDOG_LOG="$WDLOG" \
        LOOM_SOCKET_PATH="$WORKDIR/loom-daemon.sock" \
        LOOM_DAEMON_LAUNCHD=0 bash "$WATCHDOG" > "$OUT" 2>&1
    RC=$?
}

# As run_watchdog, but with --verbose so the OK/skip diagnostics (which the
# non-verbose report() deliberately suppresses on stderr but always writes to the
# log) are asserted from the same log the operator would read.
run_watchdog_verbose() {
    : > "$OUT"
    env LOOM_WATCHDOG_IPC_PROBE=0 "$@" LOOM_AUTONOMY_MARKER="$MARKER" LOOM_WATCHDOG_LOG="$WDLOG" \
        LOOM_SOCKET_PATH="$WORKDIR/loom-daemon.sock" \
        LOOM_DAEMON_LAUNCHD=0 bash "$WATCHDOG" --verbose > "$OUT" 2>&1
    RC=$?
}

log_has()  { grep -q "$1" "$WDLOG" 2>/dev/null; }
log_hasi() { grep -qi "$1" "$WDLOG" 2>/dev/null; }

# A live pid we own for the "daemon alive" cases. The sleeper's stdio is
# redirected to /dev/null so it does NOT hold open the `$(sleeper)` command
# substitution pipe (which would otherwise block the caller for the full sleep).
sleeper() { sleep 60 >/dev/null 2>&1 & echo $!; }

# A `ps` stub that always reports a fixed `-o etime=` value (used by the
# prior-boot heartbeat tests, #4368) — deterministic regardless of how long
# the real sleeper process has actually been alive by the time the watchdog
# runs. Prints the stub directory; add it to the FRONT of PATH via
# `run_watchdog PATH="$(make_ps_stub ...):$PATH"`.
make_ps_stub() { # <etime-value, e.g. "02:00:00">
    local dir
    dir="$(mktemp -d)"
    cat > "$dir/ps" <<EOF
#!/usr/bin/env bash
echo "$1"
EOF
    chmod +x "$dir/ps"
    echo "$dir"
}

# ---------------------------------------------------------------------------
# #4398 IPC-probe fixtures.
#
# The watchdog shells out to the resolved `loom-daemon` binary for its bounded
# in-band probe, so the probe is driven entirely by a stub binary pinned via
# LOOM_DAEMON_BIN — no real daemon, no real socket, no `timeout` dependency on
# the outcome. Each mode reproduces one shape the classifier must handle:
#
#   ok          successful IPC round-trip (exit 0)
#   slow-ok     eventually-responsive round-trip (the #4279 under-load case):
#               sleeps, then succeeds — must NOT be called a hang
#   hang        never returns at all (#4381's `while true; sleep 1` stub) —
#               only the watchdog's own hard budget can end it
#   unreachable the CLI's own bounded round-trip failed and it said so (exit 1)
#   usage       this build's CLI does not know the probe subcommand (clap, exit 2)
#   daemon-err  the daemon ANSWERED with an application error (exit 1) — proof
#               that IPC works, so it must degrade to "skipped", not "hang"
make_daemon_stub() { # <mode> [sleep_secs]
    local mode="$1" secs="${2:-2}" dir
    dir="$(mktemp -d)"
    case "$mode" in
        ok)
            printf '#!/usr/bin/env bash\necho "no active quarantines"\nexit 0\n' > "$dir/loom-daemon" ;;
        slow-ok)
            printf '#!/usr/bin/env bash\nsleep %s\necho "no active quarantines"\nexit 0\n' "$secs" > "$dir/loom-daemon" ;;
        hang)
            printf '#!/usr/bin/env bash\nwhile true; do sleep 1; done\n' > "$dir/loom-daemon" ;;
        unreachable)
            printf '#!/usr/bin/env bash\necho "Could not reach loom-daemon at /tmp/x.sock: round-trip timed out after 5s" >&2\nexit 1\n' > "$dir/loom-daemon" ;;
        usage)
            printf '#!/usr/bin/env bash\necho "error: unrecognized subcommand" >&2\nexit 2\n' > "$dir/loom-daemon" ;;
        daemon-err)
            printf '#!/usr/bin/env bash\necho "Daemon error: workspace not registered" >&2\nexit 1\n' > "$dir/loom-daemon" ;;
        *) echo "unknown stub mode $mode" >&2; return 1 ;;
    esac
    chmod +x "$dir/loom-daemon"
    echo "$dir"
}

PROBE_STATE="$WORKDIR/.watchdog-probe-fail-count"

# Stand up "daemon alive (past the startup grace) + heartbeat FRESH" — the exact
# state in which pid-alive and heartbeat-fresh both pass and only the in-band
# probe can tell a healthy daemon from a wedged one.
#
# Sets two GLOBALS (and must therefore never be called in a command
# substitution, whose subshell would discard them):
#   LIVE_PID      the live pid the caller must kill afterwards
#   PS_STUB_DIR   a `ps` stub pinning the process age to 7200s — well past any
#                 grace window — which the caller must put at the FRONT of PATH
#                 and `rm -rf` afterwards. Without it the freshly spawned
#                 sleeper's real age is ~0s and every probe would be skipped by
#                 the startup-grace guard.
PS_STUB_DIR=""
LIVE_PID=""
start_alive_and_fresh() { # <pid_file_suffix>
    PS_STUB_DIR="$(make_ps_stub "02:00:00")"
    LIVE_PID=$(sleeper)
    echo "$LIVE_PID" > "$WORKDIR/pid$1"
    write_marker "$WORKDIR/pid$1" 60
    printf '%s pid=%s ts=now\n' "$(date +%s)" "$LIVE_PID" > "$HEARTBEAT"
    : > "$WDLOG"
    rm -f "$PROBE_STATE"
}

# ===================================================================
# 1. Marker ABSENT ⇒ no daemon expected ⇒ silent OK (exit 0).
# ===================================================================
rm -f "$MARKER" "$HEARTBEAT" "$WDLOG" "$WORKDIR/.daemon.pid"
run_watchdog
assert_rc 0 "$RC" "marker absent + nothing alive: exits 0 (no daemon expected)"
if log_has DIVERGENCE || log_hasi "mismatch"; then fail "marker absent + nothing alive: unexpected report"; else pass "marker absent + nothing alive: no DIVERGENCE/MISMATCH reported"; fi

# ===================================================================
# 1b. Marker ABSENT but a daemon IS running ⇒ STATE MISMATCH (#4331): crash
#     protection is disarmed, so the watchdog WARNs loudly + exits 1 instead of
#     the old silent `[OK] nothing to check`. Reproduces the observed bug — a
#     daemon rolled via the restart primitive / self-update, neither of which
#     re-writes the marker. Liveness is probed via the default pid file
#     (<loom_dir>/.daemon.pid) on the LOOM_DAEMON_LAUNCHD=0 path.
# ===================================================================
rm -f "$MARKER" "$HEARTBEAT" "$WDLOG"
live_pid=$(sleeper)
echo "$live_pid" > "$WORKDIR/.daemon.pid"
run_watchdog
kill "$live_pid" 2>/dev/null || true
assert_rc 1 "$RC" "marker absent + daemon alive: exits 1 (state mismatch, crash protection disarmed)"
if log_hasi "mismatch"; then
    pass "marker absent + daemon alive: WARN reports the state mismatch"
else
    fail "marker absent + daemon alive: missing the state-mismatch WARN"
fi
if log_has DIVERGENCE; then
    fail "marker absent + daemon alive: should be a WARN, not a DIVERGENCE"
else
    pass "marker absent + daemon alive: reported as WARN, not DIVERGENCE"
fi
rm -f "$WORKDIR/.daemon.pid"

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
# 3. Intent present, daemon ALIVE, heartbeat STALE (but written THIS boot,
#    i.e. younger than the process itself) ⇒ DIVERGENCE (wedged).
#    A `ps` stub pins the process age to 7200s — comfortably older than the
#    3600s-old heartbeat — so this exercises the genuine current-boot-stale
#    verdict deterministically, never the #4368 prior-boot path (which a
#    freshly-spawned real sleeper pid would otherwise always hit, since its
#    real age is far younger than any meaningfully back-dated heartbeat).
# ===================================================================
PS_STUB3="$(make_ps_stub "02:00:00")"
live_pid=$(sleeper)
echo "$live_pid" > "$WORKDIR/pidB"
write_marker "$WORKDIR/pidB" 60
printf 'old\n' > "$HEARTBEAT"
back_date_file "$HEARTBEAT" 3600   # 1h old, well past the 300s default threshold
: > "$WDLOG"
run_watchdog PATH="$PS_STUB3:$PATH"
kill "$live_pid" 2>/dev/null || true
assert_rc 1 "$RC" "alive + STALE heartbeat (current boot): exits 1 (divergence)"
if log_has STALE; then pass "alive + stale heartbeat: reports it as wedged/stale"; else fail "alive + stale heartbeat: no STALE report"; fi
rm -rf "$PS_STUB3"

# ===================================================================
# 3b. Intent present, daemon ALIVE, heartbeat OLDER than the process itself
#     ⇒ liveness-only OK, NEVER a DIVERGENCE/STALE report (#4368). A `ps`
#     stub pins the process age to 5s while the heartbeat is 3600s old —
#     exactly the shape of the reported incident (a migrated/leftover
#     heartbeat file from a previous boot outliving a fresh restart).
# ===================================================================
PS_STUB3B="$(make_ps_stub "00:00:05")"
live_pid=$(sleeper)
echo "$live_pid" > "$WORKDIR/pidB2"
write_marker "$WORKDIR/pidB2" 60
printf 'old\n' > "$HEARTBEAT"
back_date_file "$HEARTBEAT" 3600
: > "$WDLOG"
run_watchdog PATH="$PS_STUB3B:$PATH"
kill "$live_pid" 2>/dev/null || true
assert_rc 0 "$RC" "alive + heartbeat older than process (prior boot): exits 0, not flagged as wedged"
if log_hasi "previous boot"; then
    pass "prior-boot heartbeat: reports it as a previous-boot file, not a wedge"
else
    fail "prior-boot heartbeat: missing the previous-boot report"
fi
if log_has DIVERGENCE; then
    fail "prior-boot heartbeat: must NOT be reported as a DIVERGENCE"
else
    pass "prior-boot heartbeat: not reported as a DIVERGENCE"
fi
rm -rf "$PS_STUB3B"

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
# 7. LOOM_DAEMON_HEARTBEAT_STALE_SECS override is honored. A `ps` stub pins
#    the process age well past the 10s heartbeat age so this exercises the
#    current-boot-stale verdict, not the #4368 prior-boot path.
# ===================================================================
PS_STUB7="$(make_ps_stub "00:01:00")"
live_pid=$(sleeper)
echo "$live_pid" > "$WORKDIR/pidF"
write_marker "$WORKDIR/pidF" 60
printf 'x\n' > "$HEARTBEAT"
back_date_file "$HEARTBEAT" 10
: > "$WDLOG"
run_watchdog PATH="$PS_STUB7:$PATH" LOOM_DAEMON_HEARTBEAT_STALE_SECS=5
kill "$live_pid" 2>/dev/null || true
assert_rc 1 "$RC" "STALE_SECS override: 10s-old heartbeat with 5s threshold is flagged"
rm -rf "$PS_STUB7"

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
# 9. Bounded auto-remediation (#4232): job LOADED + NOT running + last exit
#    status 0 is EXACTLY the signature a restart-primitive exit that launchd
#    failed to honor can produce — the watchdog auto-`launchctl kickstart`s
#    (PLAIN, never -k) and, once that relaunches the job, exits 0 with an OK
#    "remediation succeeded" report instead of a bare DIVERGENCE.
# ===================================================================
if [[ "$(uname -s)" == "Darwin" ]]; then
    STUB9="$WORKDIR/stub9"
    mkdir -p "$STUB9"
    STATE9="$WORKDIR/state9"
    : > "$STATE9"   # empty -> "not running" at check time
    sleep 60 >/dev/null 2>&1 &
    NEW_PID9=$!
    LOG9="$WORKDIR/launchctl9.log"
    : > "$LOG9"
    cat > "$STUB9/launchctl" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$LOG9"
case "\${1:-}" in
  print)
    pid="\$(cat "$STATE9" 2>/dev/null)"
    if [[ -n "\$pid" ]]; then
      echo "	state = running"
      echo "	pid = \$pid"
    else
      echo "	state = not running"
    fi
    echo "	last exit status = 0"
    exit 0
    ;;
  kickstart)
    echo "$NEW_PID9" > "$STATE9"
    exit 0
    ;;
  *) exit 0 ;;
esac
EOF
    chmod +x "$STUB9/launchctl"
    cat > "$MARKER" <<EOF
started_at=2026-07-27T00:00:00Z
heartbeat_file=$HEARTBEAT
heartbeat_interval_secs=60
use_launchd=true
launchd_label=com.example.loom-sandbox-remediate-$$
socket_path=$WORKDIR/loom-daemon.sock
EOF
    : > "$WDLOG" "$OUT"
    env PATH="$STUB9:$PATH" LOOM_AUTONOMY_MARKER="$MARKER" LOOM_WATCHDOG_LOG="$WDLOG" \
        LOOM_WATCHDOG_KICKSTART_RECHECK_ATTEMPTS=5 LOOM_WATCHDOG_KICKSTART_RECHECK_INTERVAL=0.2 \
        bash "$WATCHDOG" > "$OUT" 2>&1
    rc9=$?
    kill "$NEW_PID9" 2>/dev/null || true
    assert_rc 0 "$rc9" "exit-0-and-down: auto-kickstart relaunches the job -> exits 0"
    if grep -qE '^kickstart ' "$LOG9"; then
        pass "exit-0-and-down: auto-remediation invokes 'launchctl kickstart'"
    else
        fail "exit-0-and-down: auto-remediation invokes 'launchctl kickstart' (log: $(cat "$LOG9" 2>/dev/null))"
    fi
    if grep -q -- '-k' "$LOG9"; then
        fail "exit-0-and-down: kickstart is invoked PLAIN, never with -k"
    else
        pass "exit-0-and-down: kickstart is invoked PLAIN, never with -k"
    fi
    if log_hasi 'remediat'; then
        pass "exit-0-and-down: watchdog log records the remediation"
    else
        fail "exit-0-and-down: watchdog log records the remediation"
    fi
else
    pass "exit-0-and-down auto-remediation test skipped (non-Darwin host)"
fi

# ===================================================================
# 10. Every OTHER divergence stays report-only: job LOADED + NOT running but
#     last exit status 143 (a SIGTERM'd operator stop) must NEVER trigger the
#     auto-kickstart — narrow-gate proof that this is not a crash-loop reviver.
# ===================================================================
if [[ "$(uname -s)" == "Darwin" ]]; then
    STUB10="$WORKDIR/stub10"
    mkdir -p "$STUB10"
    STATE10="$WORKDIR/state10"
    : > "$STATE10"
    LOG10="$WORKDIR/launchctl10.log"
    : > "$LOG10"
    cat > "$STUB10/launchctl" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$LOG10"
case "\${1:-}" in
  print)
    pid="\$(cat "$STATE10" 2>/dev/null)"
    if [[ -n "\$pid" ]]; then
      echo "	state = running"
      echo "	pid = \$pid"
    else
      echo "	state = not running"
    fi
    echo "	last exit status = 143"
    exit 0
    ;;
  kickstart)
    # If this were ever wrongly invoked it WOULD bring the job "up" (proving a
    # false positive would be caught) — the assertion below is that it is
    # simply never called.
    echo "999999" > "$STATE10"
    exit 0
    ;;
  *) exit 0 ;;
esac
EOF
    chmod +x "$STUB10/launchctl"
    cat > "$MARKER" <<EOF
started_at=2026-07-27T00:00:00Z
heartbeat_file=$HEARTBEAT
heartbeat_interval_secs=60
use_launchd=true
launchd_label=com.example.loom-sandbox-noremediate-$$
socket_path=$WORKDIR/loom-daemon.sock
EOF
    : > "$WDLOG" "$OUT"
    env PATH="$STUB10:$PATH" LOOM_AUTONOMY_MARKER="$MARKER" LOOM_WATCHDOG_LOG="$WDLOG" \
        bash "$WATCHDOG" > "$OUT" 2>&1
    rc10=$?
    assert_rc 1 "$rc10" "exit-143-and-down: stays report-only (no auto-kickstart) -> exits 1"
    if grep -q 'kickstart' "$LOG10"; then
        fail "exit-143-and-down: kickstart is NEVER invoked (no crash-loop revival of an operator stop)"
    else
        pass "exit-143-and-down: kickstart is NEVER invoked (no crash-loop revival of an operator stop)"
    fi
else
    pass "exit-143-and-down report-only test skipped (non-Darwin host)"
fi

# ===================================================================
# 11. --help works and documents the marker + StartInterval design.
# ===================================================================
help_out=$(bash "$WATCHDOG" --help 2>/dev/null)
if echo "$help_out" | grep -qi 'autonomy-desired' && echo "$help_out" | grep -qi 'StartInterval'; then
    pass "--help documents the marker + StartInterval rationale"
else
    fail "--help missing marker/StartInterval documentation"
fi
if echo "$help_out" | grep -q 'LOOM_WATCHDOG_STATUS_PROBE_TIMEOUT_SECS' \
    && echo "$help_out" | grep -q 'LOOM_WATCHDOG_IPC_PROBE_FAIL_THRESHOLD'; then
    pass "--help documents the #4398 IPC-probe knobs"
else
    fail "--help missing the #4398 IPC-probe knob documentation"
fi

# ===================================================================
# 12. IPC probe SUCCEEDS ⇒ unchanged healthy behavior (#4398). pid alive +
#     heartbeat fresh + a clean bounded socket round-trip ⇒ exit 0, no
#     DIVERGENCE, and no fail-count state left behind.
# ===================================================================
STUB12="$(make_daemon_stub ok)"
start_alive_and_fresh 12
run_watchdog PATH="$PS_STUB_DIR:$PATH" LOOM_WATCHDOG_IPC_PROBE=1 \
    LOOM_DAEMON_BIN="$STUB12/loom-daemon"
kill "$LIVE_PID" 2>/dev/null || true
assert_rc 0 "$RC" "probe succeeds: exits 0 (healthy, unchanged behavior)"
if log_has DIVERGENCE; then
    fail "probe succeeds: must not report a DIVERGENCE"
else
    pass "probe succeeds: no DIVERGENCE reported"
fi
if [[ -f "$PROBE_STATE" ]]; then
    fail "probe succeeds: no fail-count state file should exist"
else
    pass "probe succeeds: no fail-count state file left behind"
fi
rm -rf "$PS_STUB_DIR" "$STUB12"

# ===================================================================
# 13. Probe times out ONCE ⇒ DIVERGENCE reported, but explicitly NOT a
#     confirmed hang and NO remediation (#4398). Uses the #4381 stub shape (a
#     binary that never returns at all), so only the watchdog's own hard budget
#     can end the probe.
# ===================================================================
STUB13="$(make_daemon_stub hang)"
start_alive_and_fresh 13
t0=$(date +%s)
run_watchdog PATH="$PS_STUB_DIR:$PATH" LOOM_WATCHDOG_IPC_PROBE=1 \
    LOOM_DAEMON_BIN="$STUB13/loom-daemon" \
    LOOM_WATCHDOG_STATUS_PROBE_TIMEOUT_SECS=2 \
    LOOM_WATCHDOG_IPC_PROBE_FAIL_THRESHOLD=3
elapsed=$(( $(date +%s) - t0 ))
kill "$LIVE_PID" 2>/dev/null || true
assert_rc 1 "$RC" "probe times out once: exits 1 (DIVERGENCE reported)"
if log_has DIVERGENCE && log_hasi 'consecutive failure 1 of 3'; then
    pass "probe times out once: reported as failure 1 of 3, not yet confirmed"
else
    fail "probe times out once: missing the 'failure 1 of 3' DIVERGENCE ($(cat "$WDLOG" 2>/dev/null))"
fi
# Matched on the FULL escalation phrase, not a bare "CONFIRMED" — the
# below-threshold message legitimately contains the words "NOT yet a confirmed
# hang", which a looser pattern would false-match.
if log_hasi 'IPC UNRESPONSIVE (CONFIRMED)'; then
    fail "probe times out once: must NOT escalate to a CONFIRMED hang"
else
    pass "probe times out once: does not escalate to a CONFIRMED hang"
fi
if (( elapsed < 20 )); then
    pass "probe times out once: the watchdog itself stayed bounded (${elapsed}s with a never-returning binary)"
else
    fail "probe times out once: watchdog took ${elapsed}s — the probe budget did not bound it"
fi
rm -rf "$PS_STUB_DIR" "$STUB13"

# ===================================================================
# 14. Probe times out N times CONSECUTIVELY ⇒ escalation (#4398): distinct
#     "IPC UNRESPONSIVE (CONFIRMED)" text, an explicit recovery command, exit 1
#     — and still no automatic kill/restart.
# ===================================================================
STUB14="$(make_daemon_stub hang)"
start_alive_and_fresh 14
probe_env=(PATH="$PS_STUB_DIR:$PATH" LOOM_WATCHDOG_IPC_PROBE=1
    LOOM_DAEMON_BIN="$STUB14/loom-daemon"
    LOOM_WATCHDOG_STATUS_PROBE_TIMEOUT_SECS=2
    LOOM_WATCHDOG_IPC_PROBE_FAIL_THRESHOLD=2)
run_watchdog "${probe_env[@]}"            # tick 1 -> failure 1 of 2
rc14a=$RC
: > "$WDLOG"
run_watchdog "${probe_env[@]}"            # tick 2 -> CONFIRMED
rc14b=$RC
kill "$LIVE_PID" 2>/dev/null || true
assert_rc 1 "$rc14a" "consecutive timeouts (tick 1): exits 1"
assert_rc 1 "$rc14b" "consecutive timeouts (tick 2, at threshold): exits 1"
if log_hasi 'IPC UNRESPONSIVE (CONFIRMED)'; then
    pass "consecutive timeouts: escalates with distinct 'IPC UNRESPONSIVE (CONFIRMED)' text"
else
    fail "consecutive timeouts: missing the escalation text ($(cat "$WDLOG" 2>/dev/null))"
fi
if log_hasi 'loom-daemon-stop.sh' && log_hasi 'loom-daemon restart'; then
    pass "consecutive timeouts: escalation names explicit recovery commands"
else
    fail "consecutive timeouts: escalation missing explicit recovery commands"
fi
if log_hasi 'no automatic kill/restart'; then
    pass "consecutive timeouts: escalation states that no auto-remediation was attempted"
else
    fail "consecutive timeouts: escalation should state that no auto-remediation was attempted"
fi
rm -rf "$PS_STUB_DIR" "$STUB14"

# ===================================================================
# 15. Post-relaunch socket-bind window (#4331/#4213): a probe against a process
#     YOUNGER than the grace window is skipped outright — no DIVERGENCE, and it
#     may never count toward the confirmed-hang tally.
# ===================================================================
STUB15="$(make_daemon_stub hang)"
start_alive_and_fresh 15
rm -rf "$PS_STUB_DIR"
PS_STUB_DIR="$(make_ps_stub "00:00:10")"   # 10s old ⇒ inside the 90s default grace
run_watchdog_verbose PATH="$PS_STUB_DIR:$PATH" LOOM_WATCHDOG_IPC_PROBE=1 \
    LOOM_DAEMON_BIN="$STUB15/loom-daemon" \
    LOOM_WATCHDOG_STATUS_PROBE_TIMEOUT_SECS=2 \
    LOOM_WATCHDOG_IPC_PROBE_FAIL_THRESHOLD=2
kill "$LIVE_PID" 2>/dev/null || true
assert_rc 0 "$RC" "young process (inside startup grace): probe skipped, exits 0"
if log_has DIVERGENCE; then
    fail "young process: must NOT report a DIVERGENCE during the socket-bind window"
else
    pass "young process: no DIVERGENCE during the socket-bind window"
fi
if [[ -f "$PROBE_STATE" ]]; then
    fail "young process: must NOT count toward the confirmed-hang tally"
else
    pass "young process: does not count toward the confirmed-hang tally"
fi
if log_hasi 'startup grace'; then
    pass "young process: verbose log explains the grace-window skip"
else
    fail "young process: verbose log should explain the grace-window skip"
fi
rm -rf "$PS_STUB_DIR" "$STUB15"

# ===================================================================
# 16. No resolvable `loom-daemon` binary ⇒ graceful degrade (#4398): the probe
#     is skipped, NOT reported. The watchdog must never page because its own
#     optional helper is missing. PATH is narrowed to the base system dirs so
#     the host's real installed loom-daemon is not picked up, and the marker's
#     repo_root ($WORKDIR) holds no cargo target either.
# ===================================================================
STUB16_PS="$(make_ps_stub "02:00:00")"
start_alive_and_fresh 16
rm -rf "$PS_STUB_DIR"
run_watchdog_verbose PATH="$STUB16_PS:/usr/bin:/bin" LOOM_WATCHDOG_IPC_PROBE=1 \
    LOOM_DAEMON_BIN="$WORKDIR/definitely-not-a-binary"
kill "$LIVE_PID" 2>/dev/null || true
assert_rc 0 "$RC" "no loom-daemon binary resolvable: exits 0 (graceful degrade)"
if log_has DIVERGENCE; then
    fail "no loom-daemon binary: must NOT report a DIVERGENCE"
else
    pass "no loom-daemon binary: no false DIVERGENCE"
fi
if log_hasi 'no loom-daemon binary resolvable'; then
    pass "no loom-daemon binary: verbose log explains the skip"
else
    fail "no loom-daemon binary: verbose log should explain the skip ($(cat "$WDLOG" 2>/dev/null))"
fi
rm -rf "$STUB16_PS"

# ===================================================================
# 17. No false positive under load (#4279): a slow-but-eventually-responsive
#     round-trip that completes INSIDE the probe budget is healthy, not a hang.
# ===================================================================
STUB17="$(make_daemon_stub slow-ok 2)"
start_alive_and_fresh 17
run_watchdog PATH="$PS_STUB_DIR:$PATH" LOOM_WATCHDOG_IPC_PROBE=1 \
    LOOM_DAEMON_BIN="$STUB17/loom-daemon" \
    LOOM_WATCHDOG_STATUS_PROBE_TIMEOUT_SECS=15
kill "$LIVE_PID" 2>/dev/null || true
assert_rc 0 "$RC" "slow-but-responsive probe (2s < 15s budget): exits 0, not flagged as hung"
if log_has DIVERGENCE; then
    fail "slow-but-responsive probe: must NOT be reported as a hang"
else
    pass "slow-but-responsive probe: not reported as a hang"
fi
rm -rf "$PS_STUB_DIR" "$STUB17"

# ===================================================================
# 18. A daemon-side APPLICATION error proves IPC works ⇒ degrade to skipped,
#     never a hang. Same for a CLI that does not know the probe subcommand
#     (an older installed build): exit 2 must not be read as a wedge.
# ===================================================================
STUB18="$(make_daemon_stub daemon-err)"
start_alive_and_fresh 18
run_watchdog PATH="$PS_STUB_DIR:$PATH" LOOM_WATCHDOG_IPC_PROBE=1 \
    LOOM_DAEMON_BIN="$STUB18/loom-daemon" LOOM_WATCHDOG_IPC_PROBE_FAIL_THRESHOLD=1
kill "$LIVE_PID" 2>/dev/null || true
assert_rc 0 "$RC" "daemon answered with an application error: exits 0 (IPC demonstrably works)"
if log_has DIVERGENCE; then
    fail "daemon application error: must NOT be reported as an IPC hang"
else
    pass "daemon application error: not reported as an IPC hang"
fi
rm -rf "$PS_STUB_DIR" "$STUB18"

STUB18B="$(make_daemon_stub usage)"
start_alive_and_fresh 18b
run_watchdog PATH="$PS_STUB_DIR:$PATH" LOOM_WATCHDOG_IPC_PROBE=1 \
    LOOM_DAEMON_BIN="$STUB18B/loom-daemon" LOOM_WATCHDOG_IPC_PROBE_FAIL_THRESHOLD=1
kill "$LIVE_PID" 2>/dev/null || true
assert_rc 0 "$RC" "probe subcommand unsupported by this build: exits 0 (graceful degrade)"
if log_has DIVERGENCE; then
    fail "unsupported probe subcommand: must NOT be reported as an IPC hang"
else
    pass "unsupported probe subcommand: not reported as an IPC hang"
fi
rm -rf "$PS_STUB_DIR" "$STUB18B"

# ===================================================================
# 19. The tally counts CONSECUTIVE failures only, and is keyed to the live pid.
#     19a: a successful probe clears a pre-existing streak.
#     19b: a streak recorded against a DIFFERENT pid is not inherited by a
#          freshly relaunched daemon (which would otherwise escalate on its
#          very first failed tick).
# ===================================================================
STUB19="$(make_daemon_stub ok)"
start_alive_and_fresh 19
printf '%s 5\n' "$LIVE_PID" > "$PROBE_STATE"
run_watchdog PATH="$PS_STUB_DIR:$PATH" LOOM_WATCHDOG_IPC_PROBE=1 \
    LOOM_DAEMON_BIN="$STUB19/loom-daemon"
kill "$LIVE_PID" 2>/dev/null || true
assert_rc 0 "$RC" "successful probe after a streak: exits 0"
if [[ -f "$PROBE_STATE" ]]; then
    fail "successful probe: must clear the consecutive-failure streak"
else
    pass "successful probe: clears the consecutive-failure streak"
fi
rm -rf "$PS_STUB_DIR" "$STUB19"

STUB19B="$(make_daemon_stub unreachable)"
start_alive_and_fresh 19b
printf '999999 9\n' > "$PROBE_STATE"    # a streak owned by a DIFFERENT (dead) pid
run_watchdog PATH="$PS_STUB_DIR:$PATH" LOOM_WATCHDOG_IPC_PROBE=1 \
    LOOM_DAEMON_BIN="$STUB19B/loom-daemon" LOOM_WATCHDOG_IPC_PROBE_FAIL_THRESHOLD=2
kill "$LIVE_PID" 2>/dev/null || true
assert_rc 1 "$RC" "failed probe after a relaunch: exits 1 (reported)"
if log_hasi 'consecutive failure 1 of 2'; then
    pass "fail tally is pid-keyed: a relaunched daemon starts its own streak"
else
    fail "fail tally is pid-keyed: streak from a previous pid must not be inherited ($(cat "$WDLOG" 2>/dev/null))"
fi
if log_hasi 'IPC UNRESPONSIVE (CONFIRMED)'; then
    fail "fail tally is pid-keyed: must not escalate on the new pid's first failure"
else
    pass "fail tally is pid-keyed: no escalation on the new pid's first failure"
fi
rm -rf "$PS_STUB_DIR" "$STUB19B"

# ===================================================================
# 20. The probe is opt-out-able (LOOM_WATCHDOG_IPC_PROBE=0): a never-returning
#     binary is not even invoked, so behavior is byte-identical to pre-#4398.
# ===================================================================
STUB20="$(make_daemon_stub hang)"
start_alive_and_fresh 20
t0=$(date +%s)
run_watchdog PATH="$PS_STUB_DIR:$PATH" LOOM_WATCHDOG_IPC_PROBE=0 \
    LOOM_DAEMON_BIN="$STUB20/loom-daemon" \
    LOOM_WATCHDOG_STATUS_PROBE_TIMEOUT_SECS=2
elapsed=$(( $(date +%s) - t0 ))
kill "$LIVE_PID" 2>/dev/null || true
assert_rc 0 "$RC" "LOOM_WATCHDOG_IPC_PROBE=0: probe disabled, exits 0"
if (( elapsed < 2 )); then
    pass "LOOM_WATCHDOG_IPC_PROBE=0: the probe binary is never invoked (${elapsed}s)"
else
    fail "LOOM_WATCHDOG_IPC_PROBE=0: took ${elapsed}s — the probe appears to have run"
fi
rm -rf "$PS_STUB_DIR" "$STUB20"

# ===================================================================
# 21. The bound holds with NO `timeout(1)` on the host (the default macOS
#     shape): LOOM_WATCHDOG_FORCE_PORTABLE_TIMEOUT=1 exercises the built-in
#     bounded runner against a never-returning binary.
# ===================================================================
STUB21="$(make_daemon_stub hang)"
start_alive_and_fresh 21
t0=$(date +%s)
run_watchdog PATH="$PS_STUB_DIR:$PATH" LOOM_WATCHDOG_IPC_PROBE=1 \
    LOOM_WATCHDOG_FORCE_PORTABLE_TIMEOUT=1 \
    LOOM_DAEMON_BIN="$STUB21/loom-daemon" \
    LOOM_WATCHDOG_STATUS_PROBE_TIMEOUT_SECS=2 \
    LOOM_WATCHDOG_IPC_PROBE_FAIL_THRESHOLD=3
elapsed=$(( $(date +%s) - t0 ))
kill "$LIVE_PID" 2>/dev/null || true
assert_rc 1 "$RC" "no timeout(1) available: portable bounded runner still detects the hang (exit 1)"
if (( elapsed < 20 )); then
    pass "no timeout(1) available: the watchdog stayed bounded (${elapsed}s)"
else
    fail "no timeout(1) available: watchdog took ${elapsed}s — the portable bound did not hold"
fi
rm -rf "$PS_STUB_DIR" "$STUB21"

echo
echo "Ran $TESTS_RUN tests: $TESTS_PASSED passed, $TESTS_FAILED failed"
[[ "$TESTS_FAILED" -eq 0 ]]