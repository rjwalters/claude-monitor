#!/usr/bin/env bash
# test-loom-daemon-start.sh — Tests for loom-daemon-start.sh autonomous-mode
# env resolution.
#
# Focus (#3911): a bare `loom-daemon-start.sh` must default FLAGS-OFF — it must
# NOT enable the autonomous work finder. Opt-in (--work-finder / --health-gate /
# --from-config) and explicit-off (--no-work-finder) must still behave.
#
# Style matches test-spawn-claude.sh — plain bash, hand-rolled assertions.
# Bats is NOT used in this repository.
#
# Strategy: drive the script in --foreground mode against a FAKE daemon binary
# that prints the LOOM_WORK_FINDER / LOOM_MAIN_HEALTH_GATE it inherited, then
# assert on that marker line. --foreground `exec`s the binary, so the exported
# env is exactly what a real daemon would see.
#
# Usage:
#   ./defaults/scripts/tests/test-loom-daemon-start.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
START_SCRIPT="$(cd "$SCRIPT_DIR/../cli" && pwd)/loom-daemon-start.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

assert_eq() {
    local expected="$1" actual="$2" msg="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$expected" == "$actual" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "${GREEN}✓${NC} $msg"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "${RED}✗${NC} $msg"
        echo -e "  expected: [$expected]"
        echo -e "  actual:   [$actual]"
    fi
}

# ---------- fixture ----------
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
mkdir -p "$WORKDIR/.loom/logs"

FAKE_BIN="$WORKDIR/fake-loom-daemon"
cat > "$FAKE_BIN" <<'EOF'
#!/usr/bin/env bash
# Prints the autonomous-mode env it inherited, then exits cleanly.
echo "FAKE_DAEMON WF=[${LOOM_WORK_FINDER:-}] HG=[${LOOM_MAIN_HEALTH_GATE:-}]"
EOF
chmod +x "$FAKE_BIN"

# ---------- tests ----------

# 1. Plain start = FLAGS-OFF: work finder off, health gate off.
out=$( ( cd "$WORKDIR" && env -u LOOM_WORK_FINDER -u LOOM_MAIN_HEALTH_GATE LOOM_DAEMON_BIN="$FAKE_BIN" bash "$START_SCRIPT" --foreground 2>/dev/null ) | grep '^FAKE_DAEMON' )
assert_eq "FAKE_DAEMON WF=[0] HG=[0]" "$out" "plain start defaults both loops OFF (#3911)"

# 2. --work-finder opts the finder on (gate stays off).
out=$( ( cd "$WORKDIR" && env -u LOOM_WORK_FINDER -u LOOM_MAIN_HEALTH_GATE LOOM_DAEMON_BIN="$FAKE_BIN" bash "$START_SCRIPT" --work-finder --foreground 2>/dev/null ) | grep '^FAKE_DAEMON' )
assert_eq "FAKE_DAEMON WF=[1] HG=[0]" "$out" "--work-finder enables finder only"

# 3. --health-gate opts the gate on (finder stays off).
out=$( ( cd "$WORKDIR" && env -u LOOM_WORK_FINDER -u LOOM_MAIN_HEALTH_GATE LOOM_DAEMON_BIN="$FAKE_BIN" bash "$START_SCRIPT" --health-gate --foreground 2>/dev/null ) | grep '^FAKE_DAEMON' )
assert_eq "FAKE_DAEMON WF=[0] HG=[1]" "$out" "--health-gate enables gate only"

# 4. Both flags → both on.
out=$( ( cd "$WORKDIR" && env -u LOOM_WORK_FINDER -u LOOM_MAIN_HEALTH_GATE LOOM_DAEMON_BIN="$FAKE_BIN" bash "$START_SCRIPT" --work-finder --health-gate --foreground 2>/dev/null ) | grep '^FAKE_DAEMON' )
assert_eq "FAKE_DAEMON WF=[1] HG=[1]" "$out" "--work-finder --health-gate enables both"

# 5. Already-exported env wins over the flags-off default.
out=$( ( cd "$WORKDIR" && env -u LOOM_MAIN_HEALTH_GATE LOOM_WORK_FINDER=1 LOOM_DAEMON_BIN="$FAKE_BIN" bash "$START_SCRIPT" --foreground 2>/dev/null ) | grep '^FAKE_DAEMON' )
assert_eq "FAKE_DAEMON WF=[1] HG=[0]" "$out" "exported LOOM_WORK_FINDER=1 wins on plain start"

# 6. --from-config forces neither var (leaves both unset for config to drive).
out=$( ( cd "$WORKDIR" && env -u LOOM_WORK_FINDER -u LOOM_MAIN_HEALTH_GATE LOOM_DAEMON_BIN="$FAKE_BIN" bash "$START_SCRIPT" --from-config --foreground 2>/dev/null ) | grep '^FAKE_DAEMON' )
assert_eq "FAKE_DAEMON WF=[] HG=[]" "$out" "--from-config leaves both env vars unset"

# 7. --no-work-finder forces finder off (explicit; matches default).
out=$( ( cd "$WORKDIR" && env -u LOOM_WORK_FINDER -u LOOM_MAIN_HEALTH_GATE LOOM_DAEMON_BIN="$FAKE_BIN" bash "$START_SCRIPT" --no-work-finder --foreground 2>/dev/null ) | grep '^FAKE_DAEMON' )
assert_eq "FAKE_DAEMON WF=[0] HG=[0]" "$out" "--no-work-finder forces finder off"

# 8. --help mentions the FLAGS-OFF default and the opt-in flags.
help_out=$(bash "$START_SCRIPT" --help 2>/dev/null)
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$help_out" | grep -qi 'FLAGS-OFF' && echo "$help_out" | grep -q -- '--work-finder'; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓${NC} --help documents the FLAGS-OFF default and --work-finder"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗${NC} --help documents the FLAGS-OFF default and --work-finder"
fi

# 9. Regression (#3968 flag persistence): a BARE invocation with ZERO args in
#    background mode (the common real-world case — --foreground is not used
#    here on purpose) must not crash. Bash < 4.4 (still /bin/bash on stock
#    macOS) raises "unbound variable" on `"${arr[@]}"` for a zero-element
#    array under `set -u`; the persist-flags loop must guard against that.
#    Also asserts the persisted flags file exists and is empty for a bare start.
#    Needs a fake binary that stays alive (the shared $FAKE_BIN above prints
#    one line and exits immediately, which the start script's own liveness
#    check would correctly treat as a startup failure — not what this test
#    is exercising).
#    --no-launchd forces the legacy nohup path even on a Darwin test runner —
#    this test exercises the flags-persistence array guard, not launchd
#    (#3972), and must never mutate the real machine's LaunchAgents.
#    --no-systemd is the Linux-runner analog (#4268): it forces the nohup path so
#    running this suite on a real systemd host never installs/enables a real
#    `systemd --user` unit.
BG_FAKE_BIN="$WORKDIR/fake-loom-daemon-bg"
cat > "$BG_FAKE_BIN" <<'EOF'
#!/usr/bin/env bash
sleep 5
EOF
chmod +x "$BG_FAKE_BIN"
# LOOM_AUTONOMY_MARKER + LOOM_SOCKET_PATH pin the #4011 autonomy-desired marker
# and heartbeat path into WORKDIR so a real start never writes the operator's
# real ~/.loom/autonomy-desired. LOOM_WATCHDOG_LABEL is a scratch label so even
# if the watchdog script were resolvable here, provisioning could not touch the
# real com.rjwalters.loom-daemon-watchdog LaunchAgent.
( cd "$WORKDIR" && env -u LOOM_WORK_FINDER -u LOOM_MAIN_HEALTH_GATE \
    LOOM_DAEMON_BIN="$BG_FAKE_BIN" \
    LOOM_SOCKET_PATH="$WORKDIR/.loom/loom-daemon.sock" \
    LOOM_AUTONOMY_MARKER="$WORKDIR/.loom/autonomy-desired" \
    LOOM_WATCHDOG_LABEL="com.example.loom-sandbox-$$-watchdog" \
    bash "$START_SCRIPT" --no-launchd --no-systemd >/dev/null 2>&1 )
bg_rc=$?
assert_eq "0" "$bg_rc" "bare (zero-arg) background start exits 0 (no unbound-variable crash, #3968)"
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -f "$WORKDIR/.loom/.daemon.flags" && ! -s "$WORKDIR/.loom/.daemon.flags" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓${NC} bare start persists an EMPTY .loom/.daemon.flags (no autonomy flags to record)"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗${NC} bare start persists an EMPTY .loom/.daemon.flags (no autonomy flags to record)"
fi
# #4011: a successful start writes the durable autonomy-desired intent marker
# (into the isolated WORKDIR location pinned above — never the real ~/.loom).
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -f "$WORKDIR/.loom/autonomy-desired" ]] \
    && grep -q '^heartbeat_file=' "$WORKDIR/.loom/autonomy-desired" \
    && grep -q '^use_launchd=false' "$WORKDIR/.loom/autonomy-desired"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓${NC} bare start writes the autonomy-desired marker with heartbeat + liveness fields (#4011)"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗${NC} bare start writes the autonomy-desired marker with heartbeat + liveness fields (#4011)"
fi

# Clean up the background daemon this test started.
if [[ -f "$WORKDIR/.loom/.daemon.pid" ]]; then
    kill "$(cat "$WORKDIR/.loom/.daemon.pid" 2>/dev/null)" 2>/dev/null || true
fi

# ---------- machine mode (Epic #3835 Phase 3b, #4229) ----------
# LOOM_MACHINE_CHECKOUT (set by the `scripts/loom` dispatcher, never by a
# direct invocation) overrides BOTH the resolved workdir (the checkout, not
# $PWD) and the pid/flags/startup-log home ($HOME/.loom, not $REPO_ROOT/.loom)
# -- and must work from a directory that has NO .loom/ at all, unlike the
# dev-mode fallback below. Every write targets a SCRATCH $HOME, never the real
# operator ~/.loom.
MACHINE_HOME="$(mktemp -d)"
MACHINE_CHECKOUT="$(mktemp -d)"
NON_REPO_DIR="$(mktemp -d)"

out=$( ( cd "$NON_REPO_DIR" && env -u LOOM_WORK_FINDER -u LOOM_MAIN_HEALTH_GATE \
    HOME="$MACHINE_HOME" \
    LOOM_MACHINE_CHECKOUT="$MACHINE_CHECKOUT" \
    LOOM_DAEMON_BIN="$FAKE_BIN" \
    bash "$START_SCRIPT" --foreground 2>&1 ) )
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$out" | grep -q '^FAKE_DAEMON'; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓${NC} machine mode: start succeeds from a NON-REPO directory (no dev-mode '.loom directory not found' refusal)"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗${NC} machine mode: start succeeds from a NON-REPO directory"
    echo "  output: $out"
fi
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$out" | grep -q "Mode:.*machine (workdir: $MACHINE_CHECKOUT"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓${NC} machine mode: plist workdir resolves to the checkout, not \$PWD"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗${NC} machine mode: plist workdir resolves to the checkout, not \$PWD"
    echo "  output: $out"
fi
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -f "$MACHINE_HOME/.loom/.daemon.flags" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓${NC} machine mode: persisted flags land under \$HOME/.loom (existing machine-level state home)"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗${NC} machine mode: persisted flags land under \$HOME/.loom (existing machine-level state home)"
fi
TESTS_RUN=$((TESTS_RUN + 1))
if [[ ! -d "$NON_REPO_DIR/.loom" && ! -d "$MACHINE_CHECKOUT/.loom" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓${NC} machine mode: no runtime state leaks into \$PWD or the checkout"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗${NC} machine mode: no runtime state leaks into \$PWD or the checkout"
fi

# Dev-mode fallback (scope guard, filed AC5): direct invocation with NO
# LOOM_MACHINE_CHECKOUT from that SAME non-repo directory still refuses exactly
# as before #4229 -- machine mode is additive, not a replacement.
out_dev=$( cd "$NON_REPO_DIR" && LOOM_DAEMON_BIN="$FAKE_BIN" bash "$START_SCRIPT" --foreground 2>&1 )
rc_dev=$?
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$rc_dev" -ne 0 ]] && echo "$out_dev" | grep -qi "Not in a Loom workspace"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓${NC} dev-mode fallback unchanged: refuses from a non-repo dir with no dispatcher (#4229 scope guard)"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗${NC} dev-mode fallback unchanged: refuses from a non-repo dir with no dispatcher (#4229 scope guard)"
fi
rm -rf "$MACHINE_HOME" "$MACHINE_CHECKOUT" "$NON_REPO_DIR"

# ---------- systemd --user service path (#4268) ----------
# The Linux mirror of the launchd path. The suite runs on Darwin runners, so
# detection uses the test-only LOOM_SYSTEMD_FORCE=1 seam in lib/systemd-user.sh
# plus a stub `systemctl` on PATH (mirroring the stub `launchctl` below). Every
# invocation also passes --no-launchd so the systemd branch is reachable on a
# Darwin runner (launchd wins over systemd by platform) and never touches real
# launchd, and pins a scratch LOOM_SYSTEMD_UNIT so a stray real user manager is
# never enabled/disabled.
SD_UNIT="loom-daemon-test-$$.service"

# S1. --print-unit renders the unit with NO side effects (no systemctl, no file
#     write). Assert the four load-bearing fields from the issue's test plan:
#     Restart=on-success, WantedBy=default.target, the baked
#     Environment=LOOM_DAEMON_SUPERVISOR=systemd, and WorkingDirectory=<repo>.
unit_out=$( ( cd "$WORKDIR" && env -u LOOM_WORK_FINDER -u LOOM_MAIN_HEALTH_GATE \
    LOOM_DAEMON_BIN="$FAKE_BIN" bash "$START_SCRIPT" --print-unit 2>/dev/null ) )
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$unit_out" | grep -qx 'Restart=on-success' \
    && echo "$unit_out" | grep -qx 'WantedBy=default.target' \
    && echo "$unit_out" | grep -qx 'Environment=LOOM_DAEMON_SUPERVISOR=systemd' \
    && echo "$unit_out" | grep -qx "WorkingDirectory=$WORKDIR"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓${NC} --print-unit renders Restart=on-success, WantedBy=default.target, LOOM_DAEMON_SUPERVISOR=systemd, WorkingDirectory=<repo>"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗${NC} --print-unit renders the expected unit fields"
    echo "$unit_out" | sed 's/^/    /'
fi

# Shared stub systemctl: records every call, answers daemon-reload/enable as
# success and `show -p MainPID --value` with a live pid we control. Structurally
# unable to touch a real unit.
SD_BIN="$WORKDIR/sd-bin"; mkdir -p "$SD_BIN"
SD_MAIN_SLEEP_PID=""
make_sd_stub() {
    local log="$1" mainpid="$2"
    cat > "$SD_BIN/systemctl" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$log"
if [[ "\${1:-}" == "--user" ]]; then shift; fi
case "\${1:-}" in
  show) echo "${mainpid}" ;;
  *)    exit 0 ;;
esac
EOF
    chmod +x "$SD_BIN/systemctl"
}

# S2. Forced systemd path installs + enables the unit and writes the PID file
#     from `systemctl --user show -p MainPID`. A real sleeper stands in for the
#     daemon MainPID so the liveness check (kill -0) passes.
sleep 30 & SD_MAIN_SLEEP_PID=$!
SD_LOG="$WORKDIR/sd-enable.log"; : > "$SD_LOG"
make_sd_stub "$SD_LOG" "$SD_MAIN_SLEEP_PID"
SD_HOME="$(mktemp -d)"; mkdir -p "$SD_HOME/.loom/logs"
sd_out=$( cd "$WORKDIR" && env -u LOOM_WORK_FINDER -u LOOM_MAIN_HEALTH_GATE \
    PATH="$SD_BIN:$PATH" HOME="$SD_HOME" \
    LOOM_SYSTEMD_FORCE=1 LOOM_SYSTEMD_UNIT="$SD_UNIT" \
    LOOM_DAEMON_BIN="$FAKE_BIN" \
    LOOM_SOCKET_PATH="$SD_HOME/.loom/loom-daemon.sock" \
    LOOM_AUTONOMY_MARKER="$SD_HOME/.loom/autonomy-desired" \
    bash "$START_SCRIPT" --no-launchd 2>&1 )
sd_rc=$?
assert_eq "0" "$sd_rc" "systemd path: start exits 0"
TESTS_RUN=$((TESTS_RUN + 1))
if grep -q -- "--user enable --now $SD_UNIT" "$SD_LOG" && grep -q -- '--user daemon-reload' "$SD_LOG"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓${NC} systemd path: runs daemon-reload + enable --now on the unit"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗${NC} systemd path: runs daemon-reload + enable --now on the unit"
    echo "  systemctl calls: $(cat "$SD_LOG")"
fi
# The PID file lands under the repo-root state home ($WORKDIR/.loom in dev mode),
# not under the pinned scratch $HOME (which only relocates the socket/marker).
TESTS_RUN=$((TESTS_RUN + 1))
if [[ "$(cat "$WORKDIR/.loom/.daemon.pid" 2>/dev/null)" == "$SD_MAIN_SLEEP_PID" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓${NC} systemd path: PID file written from systemctl show -p MainPID"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗${NC} systemd path: PID file written from systemctl show -p MainPID"
    echo "  pid file: [$(cat "$WORKDIR/.loom/.daemon.pid" 2>/dev/null)] expected [$SD_MAIN_SLEEP_PID]"
fi
rm -f "$WORKDIR/.loom/.daemon.pid"
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -f "$SD_HOME/.config/systemd/user/$SD_UNIT" ]] \
    && grep -qx 'Restart=on-success' "$SD_HOME/.config/systemd/user/$SD_UNIT"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓${NC} systemd path: renders the unit file under ~/.config/systemd/user with Restart=on-success"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗${NC} systemd path: renders the unit file under ~/.config/systemd/user with Restart=on-success"
fi
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$sd_out" | grep -qi 'enable-linger'; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓${NC} systemd path: prints the loginctl enable-linger reboot-survival reminder"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗${NC} systemd path: prints the loginctl enable-linger reboot-survival reminder"
fi
# S2 uses $WORKDIR as REPO_ROOT, which has no loom-daemon-watchdog.sh fixture
# (a scratch tmpdir, not a real checkout) -- so the watchdog provisioning
# tier degrades to its missing-script skip. Confirm that degrade is a WARNING,
# never a failed start (parity with the launchd branch, #4260 sub-issue D AC).
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$sd_out" | grep -qi 'watchdog.*loom-daemon-watchdog.sh not found'; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓${NC} systemd path: missing watchdog script degrades to a warning (start already asserted exit 0 above)"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗${NC} systemd path: missing watchdog script degrades to a warning"
    echo "  output: $sd_out"
fi
kill "$SD_MAIN_SLEEP_PID" 2>/dev/null || true
rm -rf "$SD_HOME"

# ---------- systemd --user watchdog timer (#4260 sub-issue D) ----------
# A repo-like scratch checkout with the REAL loom-daemon-watchdog.sh installed
# (S2's $WORKDIR deliberately has none) so provision_watchdog_job_systemd's
# happy path is actually exercised, not just its missing-script skip above.
WD_REPO="$(mktemp -d)"
mkdir -p "$WD_REPO/.loom/scripts/cli" "$WD_REPO/.loom/logs"
cp "$SCRIPT_DIR/../cli/loom-daemon-watchdog.sh" "$WD_REPO/.loom/scripts/cli/loom-daemon-watchdog.sh"

make_sd_stub_wd() {
    local log="$1" mainpid="$2" fail_wd="$3"
    cat > "$SD_BIN/systemctl" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$log"
if [[ "\${1:-}" == "--user" ]]; then shift; fi
case "\${1:-}" in
  show) echo "${mainpid}" ;;
  enable)
    if [[ "$fail_wd" == "1" && "\$*" == *"-watchdog.timer"* ]]; then exit 1; fi
    exit 0 ;;
  *) exit 0 ;;
esac
EOF
    chmod +x "$SD_BIN/systemctl"
}

# WD1. Happy path: timer + service rendered with the correct fields, the timer
#      (not the service) is enable --now'd, and LOOM_WATCHDOG_INTERVAL_SECS
#      drives BOTH OnUnitActiveSec and OnBootSec.
sleep 30 & WD_MAIN_SLEEP_PID=$!
WD_LOG="$WORKDIR/sd-watchdog.log"; : > "$WD_LOG"
make_sd_stub_wd "$WD_LOG" "$WD_MAIN_SLEEP_PID" "0"
WD_HOME="$(mktemp -d)"; mkdir -p "$WD_HOME/.loom/logs"
WD_UNIT="loom-daemon-wd-test-$$.service"
wd_out=$( cd "$WD_REPO" && env -u LOOM_WORK_FINDER -u LOOM_MAIN_HEALTH_GATE \
    PATH="$SD_BIN:$PATH" HOME="$WD_HOME" \
    LOOM_SYSTEMD_FORCE=1 LOOM_SYSTEMD_UNIT="$WD_UNIT" LOOM_WATCHDOG_INTERVAL_SECS=42 \
    LOOM_DAEMON_BIN="$FAKE_BIN" \
    LOOM_SOCKET_PATH="$WD_HOME/.loom/loom-daemon.sock" \
    LOOM_AUTONOMY_MARKER="$WD_HOME/.loom/autonomy-desired" \
    bash "$START_SCRIPT" --no-launchd 2>&1 )
wd_rc=$?
assert_eq "0" "$wd_rc" "systemd watchdog: start exits 0 with a real watchdog script present"
[[ "$wd_rc" == "0" ]] || echo "  output: $wd_out"
WD_TIMER_UNIT="loom-daemon-wd-test-$$-watchdog.timer"
WD_SVC_UNIT="loom-daemon-wd-test-$$-watchdog.service"
TESTS_RUN=$((TESTS_RUN + 1))
if grep -q -- "--user enable --now $WD_TIMER_UNIT" "$WD_LOG" \
    && ! grep -q -- "--user enable --now $WD_SVC_UNIT" "$WD_LOG"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓${NC} systemd watchdog: enable --now targets the TIMER unit, not the service"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗${NC} systemd watchdog: enable --now targets the TIMER unit, not the service"
    echo "  systemctl calls: $(cat "$WD_LOG")"
fi
WD_TIMER_PATH="$WD_HOME/.config/systemd/user/$WD_TIMER_UNIT"
WD_SVC_PATH="$WD_HOME/.config/systemd/user/$WD_SVC_UNIT"
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -f "$WD_TIMER_PATH" ]] \
    && grep -qx 'OnUnitActiveSec=42' "$WD_TIMER_PATH" \
    && grep -qx 'OnBootSec=42' "$WD_TIMER_PATH" \
    && grep -qx "Unit=$WD_SVC_UNIT" "$WD_TIMER_PATH" \
    && grep -qx 'Persistent=false' "$WD_TIMER_PATH"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓${NC} systemd watchdog: timer renders OnUnitActiveSec/OnBootSec from LOOM_WATCHDOG_INTERVAL_SECS, Unit=<service>, Persistent=false"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗${NC} systemd watchdog: timer renders the expected fields"
    cat "$WD_TIMER_PATH" 2>/dev/null | sed 's/^/    /'
fi
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -f "$WD_SVC_PATH" ]] \
    && grep -qx 'Type=oneshot' "$WD_SVC_PATH" \
    && grep -q "^ExecStart=/bin/bash $WD_REPO/.loom/scripts/cli/loom-daemon-watchdog.sh$" "$WD_SVC_PATH"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓${NC} systemd watchdog: service renders Type=oneshot and ExecStart=<watchdog script path>"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗${NC} systemd watchdog: service renders Type=oneshot and ExecStart=<watchdog script path>"
    cat "$WD_SVC_PATH" 2>/dev/null | sed 's/^/    /'
fi
kill "$WD_MAIN_SLEEP_PID" 2>/dev/null || true
rm -rf "$WD_HOME"

# WD2. Provisioning failure (stub enable --now on the timer exits 1) is a
#      WARNING, never a failed daemon start.
sleep 30 & WD2_MAIN_SLEEP_PID=$!
WD2_LOG="$WORKDIR/sd-watchdog-fail.log"; : > "$WD2_LOG"
make_sd_stub_wd "$WD2_LOG" "$WD2_MAIN_SLEEP_PID" "1"
WD2_HOME="$(mktemp -d)"; mkdir -p "$WD2_HOME/.loom/logs"
WD2_UNIT="loom-daemon-wd2-test-$$.service"
wd2_out=$( cd "$WD_REPO" && env -u LOOM_WORK_FINDER -u LOOM_MAIN_HEALTH_GATE \
    PATH="$SD_BIN:$PATH" HOME="$WD2_HOME" \
    LOOM_SYSTEMD_FORCE=1 LOOM_SYSTEMD_UNIT="$WD2_UNIT" \
    LOOM_DAEMON_BIN="$FAKE_BIN" \
    LOOM_SOCKET_PATH="$WD2_HOME/.loom/loom-daemon.sock" \
    LOOM_AUTONOMY_MARKER="$WD2_HOME/.loom/autonomy-desired" \
    bash "$START_SCRIPT" --no-launchd 2>&1 )
wd2_rc=$?
assert_eq "0" "$wd2_rc" "systemd watchdog: a failed 'enable --now' on the timer does not fail the daemon start"
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$wd2_out" | grep -qi 'watchdog.*enable --now failed'; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓${NC} systemd watchdog: install failure is reported as a warning"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗${NC} systemd watchdog: install failure is reported as a warning"
    echo "  output: $wd2_out"
fi
kill "$WD2_MAIN_SLEEP_PID" 2>/dev/null || true
rm -rf "$WD2_HOME"
rm -rf "$WD_REPO"

# S3. Escape hatch: --no-systemd falls back to the nohup path byte-compatibly —
#     the stub systemctl is on PATH and detection is FORCED, yet no systemctl
#     call is made (the whole systemd branch is skipped).
SD_LOG2="$WORKDIR/sd-nohatch.log"; : > "$SD_LOG2"
make_sd_stub "$SD_LOG2" "0"
SD_HOME2="$(mktemp -d)"; mkdir -p "$SD_HOME2/.loom/logs"
( cd "$WORKDIR" && env -u LOOM_WORK_FINDER -u LOOM_MAIN_HEALTH_GATE \
    PATH="$SD_BIN:$PATH" HOME="$SD_HOME2" \
    LOOM_SYSTEMD_FORCE=1 LOOM_SYSTEMD_UNIT="$SD_UNIT" \
    LOOM_DAEMON_BIN="$BG_FAKE_BIN" \
    LOOM_SOCKET_PATH="$SD_HOME2/.loom/loom-daemon.sock" \
    LOOM_AUTONOMY_MARKER="$SD_HOME2/.loom/autonomy-desired" \
    bash "$START_SCRIPT" --no-launchd --no-systemd >/dev/null 2>&1 )
nohatch_rc=$?
assert_eq "0" "$nohatch_rc" "--no-systemd: start exits 0 (nohup fallback)"
TESTS_RUN=$((TESTS_RUN + 1))
if [[ ! -s "$SD_LOG2" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓${NC} --no-systemd: performs no systemctl call at all (byte-compatible nohup path)"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗${NC} --no-systemd: performs no systemctl call at all"
    echo "  systemctl calls: $(cat "$SD_LOG2")"
fi
if [[ -f "$SD_HOME2/.loom/.daemon.pid" ]]; then
    kill "$(cat "$SD_HOME2/.loom/.daemon.pid" 2>/dev/null)" 2>/dev/null || true
fi
rm -rf "$SD_HOME2"

# S4. LOOM_DAEMON_SYSTEMD=0 is the env equivalent of --no-systemd (same skip).
SD_LOG3="$WORKDIR/sd-envoff.log"; : > "$SD_LOG3"
make_sd_stub "$SD_LOG3" "0"
SD_HOME3="$(mktemp -d)"; mkdir -p "$SD_HOME3/.loom/logs"
( cd "$WORKDIR" && env -u LOOM_WORK_FINDER -u LOOM_MAIN_HEALTH_GATE \
    PATH="$SD_BIN:$PATH" HOME="$SD_HOME3" \
    LOOM_SYSTEMD_FORCE=1 LOOM_SYSTEMD_UNIT="$SD_UNIT" LOOM_DAEMON_SYSTEMD=0 \
    LOOM_DAEMON_BIN="$BG_FAKE_BIN" \
    LOOM_SOCKET_PATH="$SD_HOME3/.loom/loom-daemon.sock" \
    LOOM_AUTONOMY_MARKER="$SD_HOME3/.loom/autonomy-desired" \
    bash "$START_SCRIPT" --no-launchd >/dev/null 2>&1 )
TESTS_RUN=$((TESTS_RUN + 1))
if [[ ! -s "$SD_LOG3" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓${NC} LOOM_DAEMON_SYSTEMD=0: performs no systemctl call (env escape hatch, symmetric with --no-systemd)"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗${NC} LOOM_DAEMON_SYSTEMD=0: performs no systemctl call"
    echo "  systemctl calls: $(cat "$SD_LOG3")"
fi
if [[ -f "$SD_HOME3/.loom/.daemon.pid" ]]; then
    kill "$(cat "$SD_HOME3/.loom/.daemon.pid" 2>/dev/null)" 2>/dev/null || true
fi
rm -rf "$SD_HOME3"

# S5. --help documents the systemd escape hatch + --print-unit.
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$help_out" | grep -q -- '--no-systemd' && echo "$help_out" | grep -q -- '--print-unit'; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓${NC} --help documents --no-systemd and --print-unit"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗${NC} --help documents --no-systemd and --print-unit"
fi

# ---------- launchd domain resolution (#4130) ----------
# resolve_launchd_domain() (lib/launchd-domain.sh) picks gui/<uid> when the GUI
# (Aqua) domain resolves — byte-for-byte the pre-#4130 default — else the
# SSH-reachable user/<uid> background domain, and honors an explicit
# LOOM_LAUNCHD_DOMAIN override verbatim. Driven through a stub launchctl so both
# the GUI-present and headless (SSH-only) cases are deterministic on any host.
LAUNCHD_DOMAIN_LIB="$(cd "$SCRIPT_DIR/../lib" && pwd)/launchd-domain.sh"
UID_NOW="$(id -u)"
DOMAIN_STUB_DIR="$WORKDIR/domain-stub"
mkdir -p "$DOMAIN_STUB_DIR/gui" "$DOMAIN_STUB_DIR/nogui"
# GUI-present: `launchctl print gui/<uid>` succeeds.
cat > "$DOMAIN_STUB_DIR/gui/launchctl" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "print" && "$2" == gui/* ]] && exit 0
exit 1
EOF
# Headless (no GUI login): every `launchctl print` fails (the gui/<uid> domain
# does not exist — the `error 125` this issue fixes).
cat > "$DOMAIN_STUB_DIR/nogui/launchctl" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "print" ]] && exit 1
exit 0
EOF
chmod +x "$DOMAIN_STUB_DIR"/*/launchctl

out=$( env -u LOOM_LAUNCHD_DOMAIN PATH="$DOMAIN_STUB_DIR/gui:$PATH" \
    bash -c "source '$LAUNCHD_DOMAIN_LIB'; resolve_launchd_domain" )
assert_eq "gui/${UID_NOW}" "$out" "resolver picks gui/<uid> when the GUI domain resolves (default path unchanged)"

out=$( env -u LOOM_LAUNCHD_DOMAIN PATH="$DOMAIN_STUB_DIR/nogui:$PATH" \
    bash -c "source '$LAUNCHD_DOMAIN_LIB'; resolve_launchd_domain" )
assert_eq "user/${UID_NOW}" "$out" "resolver falls back to user/<uid> when gui/<uid> does not resolve (headless/SSH)"

out=$( LOOM_LAUNCHD_DOMAIN="user/${UID_NOW}" PATH="$DOMAIN_STUB_DIR/gui:$PATH" \
    bash -c "source '$LAUNCHD_DOMAIN_LIB'; resolve_launchd_domain" )
assert_eq "user/${UID_NOW}" "$out" "LOOM_LAUNCHD_DOMAIN override is honored verbatim (wins over the gui probe)"

# A pinned domain that does NOT resolve is still honored verbatim — it must fail
# loudly downstream (at launchctl bootstrap), never silently fall back further.
out=$( LOOM_LAUNCHD_DOMAIN="gui/${UID_NOW}" PATH="$DOMAIN_STUB_DIR/nogui:$PATH" \
    bash -c "source '$LAUNCHD_DOMAIN_LIB'; resolve_launchd_domain" )
assert_eq "gui/${UID_NOW}" "$out" "override to a non-resolving domain is honored verbatim (no silent fallback)"

# ---------- summary ----------
echo
echo "Ran $TESTS_RUN tests: $TESTS_PASSED passed, $TESTS_FAILED failed"
[[ "$TESTS_FAILED" -eq 0 ]]
