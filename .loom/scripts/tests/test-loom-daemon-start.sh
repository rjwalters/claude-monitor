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

# ---------- --from-config composition (#4353) ----------
# --from-config used to be a strict either/or: it never looked at
# --work-finder/--health-gate at all, so pairing it with an explicit flag
# silently dropped the flag. It must now COMPOSE: the named loop is forced,
# the other loop is left unset for config to drive.

# 7a. --from-config --work-finder forces the finder ON, leaves the gate unset
#     for config to drive.
out=$( ( cd "$WORKDIR" && env -u LOOM_WORK_FINDER -u LOOM_MAIN_HEALTH_GATE LOOM_DAEMON_BIN="$FAKE_BIN" bash "$START_SCRIPT" --from-config --work-finder --foreground 2>/dev/null ) | grep '^FAKE_DAEMON' )
assert_eq "FAKE_DAEMON WF=[1] HG=[]" "$out" "--from-config --work-finder forces finder ON, gate stays config-driven (#4353)"

# 7b. --from-config --no-work-finder forces the finder OFF, gate stays unset.
out=$( ( cd "$WORKDIR" && env -u LOOM_WORK_FINDER -u LOOM_MAIN_HEALTH_GATE LOOM_DAEMON_BIN="$FAKE_BIN" bash "$START_SCRIPT" --from-config --no-work-finder --foreground 2>/dev/null ) | grep '^FAKE_DAEMON' )
assert_eq "FAKE_DAEMON WF=[0] HG=[]" "$out" "--from-config --no-work-finder forces finder OFF, gate stays config-driven (#4353)"

# 7c. --from-config --health-gate forces the gate ON, finder stays unset.
out=$( ( cd "$WORKDIR" && env -u LOOM_WORK_FINDER -u LOOM_MAIN_HEALTH_GATE LOOM_DAEMON_BIN="$FAKE_BIN" bash "$START_SCRIPT" --from-config --health-gate --foreground 2>/dev/null ) | grep '^FAKE_DAEMON' )
assert_eq "FAKE_DAEMON WF=[] HG=[1]" "$out" "--from-config --health-gate forces gate ON, finder stays config-driven (#4353)"

# 7d. --from-config --no-health-gate forces the gate OFF, finder stays unset.
out=$( ( cd "$WORKDIR" && env -u LOOM_WORK_FINDER -u LOOM_MAIN_HEALTH_GATE LOOM_DAEMON_BIN="$FAKE_BIN" bash "$START_SCRIPT" --from-config --no-health-gate --foreground 2>/dev/null ) | grep '^FAKE_DAEMON' )
assert_eq "FAKE_DAEMON WF=[] HG=[0]" "$out" "--from-config --no-health-gate forces gate OFF, finder stays config-driven (#4353)"

# 7e. A pre-exported env var still wins over the forced flag under
#     --from-config (env > CLI flag, same precedence as the non-config path).
out=$( ( cd "$WORKDIR" && env -u LOOM_MAIN_HEALTH_GATE LOOM_WORK_FINDER=1 LOOM_DAEMON_BIN="$FAKE_BIN" bash "$START_SCRIPT" --from-config --no-work-finder --foreground 2>/dev/null ) | grep '^FAKE_DAEMON' )
assert_eq "FAKE_DAEMON WF=[1] HG=[]" "$out" "pre-exported LOOM_WORK_FINDER=1 wins over --from-config --no-work-finder (#4353)"

# 7f. The startup banner names the forced loop and never prints the
#     "env not forced" wording when something WAS forced.
banner_out=$( ( cd "$WORKDIR" && env -u LOOM_WORK_FINDER -u LOOM_MAIN_HEALTH_GATE LOOM_DAEMON_BIN="$FAKE_BIN" bash "$START_SCRIPT" --from-config --work-finder --foreground 2>&1 ) )
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$banner_out" | grep -q 'forced: work_finder=1' && ! echo "$banner_out" | grep -q 'env not forced'; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓${NC} startup banner names the forced loop, never prints 'env not forced' when something was forced (#4353)"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗${NC} startup banner names the forced loop, never prints 'env not forced' when something was forced (#4353)"
    echo "  output: $banner_out"
fi

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

# ---------- safehouse fleet-comms status surfacing (#4345) ----------
# One-line static visibility check at start time: `loom-daemon-start.sh` can
# only tell "configured" from "not configured" (a live connection needs the
# daemon's own socket -- `loom-daemon status` covers that, see
# .loom/docs/safehouse.md "New-host onboarding"). Uses the nohup fallback path
# (--no-launchd --no-systemd) so this never touches real launchd/systemd, and a
# background daemon fake bin that stays alive long enough for the "started"
# banner (which the safehouse line is printed alongside) to run.
SH_BG_FAKE_BIN="$WORKDIR/fake-loom-daemon-safehouse-bg"
cat > "$SH_BG_FAKE_BIN" <<'EOF'
#!/usr/bin/env bash
sleep 5
EOF
chmod +x "$SH_BG_FAKE_BIN"

# SH1. No `safehouse` block at all -> "not configured".
SH1_HOME="$(mktemp -d)"
mkdir -p "$SH1_HOME/.loom"
sh1_out=$( ( cd "$SH1_HOME" && env -u LOOM_WORK_FINDER -u LOOM_MAIN_HEALTH_GATE \
    -u LOOM_SAFEHOUSE_ENABLED -u LOOM_SAFEHOUSE_SOCKET -u SAFEHOUSED_SOCKET \
    LOOM_DAEMON_BIN="$SH_BG_FAKE_BIN" \
    LOOM_SOCKET_PATH="$SH1_HOME/.loom/loom-daemon.sock" \
    LOOM_AUTONOMY_MARKER="$SH1_HOME/.loom/autonomy-desired" \
    LOOM_WATCHDOG_LABEL="com.example.loom-sandbox-$$-sh1-watchdog" \
    bash "$START_SCRIPT" --no-launchd --no-systemd 2>&1 ) )
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$sh1_out" | grep -q '^Safehouse:.*not configured'; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓${NC} safehouse: no config block -> 'not configured' (#4345)"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗${NC} safehouse: no config block -> 'not configured' (#4345)"
    echo "  output: $sh1_out"
fi
if [[ -f "$SH1_HOME/.loom/.daemon.pid" ]]; then
    kill "$(cat "$SH1_HOME/.loom/.daemon.pid" 2>/dev/null)" 2>/dev/null || true
fi
rm -rf "$SH1_HOME"

# SH2. safehouse.enabled=true + socket configured but the path does not exist
#      -> "configured, unreachable" (stderr warn -- captured via 2>&1).
SH2_HOME="$(mktemp -d)"
mkdir -p "$SH2_HOME/.loom"
cat > "$SH2_HOME/.loom/config.json" <<EOF
{"safehouse": {"enabled": true, "socket": "$SH2_HOME/.loom/does-not-exist.sock"}}
EOF
sh2_out=$( ( cd "$SH2_HOME" && env -u LOOM_WORK_FINDER -u LOOM_MAIN_HEALTH_GATE \
    -u LOOM_SAFEHOUSE_ENABLED -u LOOM_SAFEHOUSE_SOCKET -u SAFEHOUSED_SOCKET \
    LOOM_DAEMON_BIN="$SH_BG_FAKE_BIN" \
    LOOM_SOCKET_PATH="$SH2_HOME/.loom/loom-daemon.sock" \
    LOOM_AUTONOMY_MARKER="$SH2_HOME/.loom/autonomy-desired" \
    LOOM_WATCHDOG_LABEL="com.example.loom-sandbox-$$-sh2-watchdog" \
    bash "$START_SCRIPT" --no-launchd --no-systemd 2>&1 ) )
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$sh2_out" | grep -q '^Safehouse:.*configured, unreachable' \
    && echo "$sh2_out" | grep -q 'does-not-exist.sock'; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓${NC} safehouse: enabled + missing socket -> 'configured, unreachable' with the resolved path (#4345)"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗${NC} safehouse: enabled + missing socket -> 'configured, unreachable' with the resolved path (#4345)"
    echo "  output: $sh2_out"
fi
if [[ -f "$SH2_HOME/.loom/.daemon.pid" ]]; then
    kill "$(cat "$SH2_HOME/.loom/.daemon.pid" 2>/dev/null)" 2>/dev/null || true
fi
rm -rf "$SH2_HOME"

# SH3. safehouse.enabled=true + socket path IS a real bound AF_UNIX socket file
#      -> "configured (socket present ...)". Only `bind()`s (no accept loop
#      needed -- the start wrapper only stat()s the path, it never connects).
SH3_HOME="$(mktemp -d)"
mkdir -p "$SH3_HOME/.loom"
SH3_SOCK="$SH3_HOME/.loom/safehoused.sock"
if command -v python3 >/dev/null 2>&1 \
    && python3 -c "
import socket
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind('$SH3_SOCK')
" 2>/dev/null; then
    cat > "$SH3_HOME/.loom/config.json" <<EOF
{"safehouse": {"enabled": true, "socket": "$SH3_SOCK"}}
EOF
    sh3_out=$( ( cd "$SH3_HOME" && env -u LOOM_WORK_FINDER -u LOOM_MAIN_HEALTH_GATE \
        -u LOOM_SAFEHOUSE_ENABLED -u LOOM_SAFEHOUSE_SOCKET -u SAFEHOUSED_SOCKET \
        -u LOOM_SAFEHOUSE_ROOM -u LOOM_SAFEHOUSE_ROOM_SIGNAL \
        LOOM_DAEMON_BIN="$SH_BG_FAKE_BIN" \
        LOOM_SOCKET_PATH="$SH3_HOME/.loom/loom-daemon.sock" \
        LOOM_AUTONOMY_MARKER="$SH3_HOME/.loom/autonomy-desired" \
        LOOM_WATCHDOG_LABEL="com.example.loom-sandbox-$$-sh3-watchdog" \
        bash "$START_SCRIPT" --no-launchd --no-systemd 2>&1 ) )
    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$sh3_out" | grep -q '^Safehouse:.*configured (socket present'; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "${GREEN}✓${NC} safehouse: enabled + socket file present -> 'configured (socket present ...)' (#4345)"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "${RED}✗${NC} safehouse: enabled + socket file present -> 'configured (socket present ...)' (#4345)"
        echo "  output: $sh3_out"
    fi
    # #4464: SH3's config has no `safehouse.room`, so the room-unset caveat MUST
    # be surfaced (omitting room is valid only for a single-room safehoused).
    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$sh3_out" | grep -q 'safehouse.room is unset'; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "${GREEN}✓${NC} safehouse: room unset -> room caveat surfaced (#4464)"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "${RED}✗${NC} safehouse: room unset -> room caveat surfaced (#4464)"
        echo "  output: $sh3_out"
    fi
    if [[ -f "$SH3_HOME/.loom/.daemon.pid" ]]; then
        kill "$(cat "$SH3_HOME/.loom/.daemon.pid" 2>/dev/null)" 2>/dev/null || true
    fi
else
    echo "  (skipping SH3: python3 AF_UNIX bind unavailable on this host)"
fi
rm -rf "$SH3_HOME"

# SH4. #4464: same as SH3 but WITH an explicit safehouse.room set -> the caveat
#      must NOT appear (the single-room contract is satisfied by an explicit room).
SH4_HOME="$(mktemp -d)"
mkdir -p "$SH4_HOME/.loom"
SH4_SOCK="$SH4_HOME/.loom/safehoused.sock"
if command -v python3 >/dev/null 2>&1 \
    && python3 -c "
import socket
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind('$SH4_SOCK')
" 2>/dev/null; then
    cat > "$SH4_HOME/.loom/config.json" <<EOF
{"safehouse": {"enabled": true, "socket": "$SH4_SOCK", "room": "loom-fleet"}}
EOF
    sh4_out=$( ( cd "$SH4_HOME" && env -u LOOM_WORK_FINDER -u LOOM_MAIN_HEALTH_GATE \
        -u LOOM_SAFEHOUSE_ENABLED -u LOOM_SAFEHOUSE_SOCKET -u SAFEHOUSED_SOCKET \
        -u LOOM_SAFEHOUSE_ROOM -u LOOM_SAFEHOUSE_ROOM_SIGNAL \
        LOOM_DAEMON_BIN="$SH_BG_FAKE_BIN" \
        LOOM_SOCKET_PATH="$SH4_HOME/.loom/loom-daemon.sock" \
        LOOM_AUTONOMY_MARKER="$SH4_HOME/.loom/autonomy-desired" \
        LOOM_WATCHDOG_LABEL="com.example.loom-sandbox-$$-sh4-watchdog" \
        bash "$START_SCRIPT" --no-launchd --no-systemd 2>&1 ) )
    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$sh4_out" | grep -q 'safehouse.room is unset'; then
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "${RED}✗${NC} safehouse: room set -> no room caveat (#4464)"
        echo "  output: $sh4_out"
    else
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "${GREEN}✓${NC} safehouse: room set -> no room caveat (#4464)"
    fi
    if [[ -f "$SH4_HOME/.loom/.daemon.pid" ]]; then
        kill "$(cat "$SH4_HOME/.loom/.daemon.pid" 2>/dev/null)" 2>/dev/null || true
    fi
else
    echo "  (skipping SH4: python3 AF_UNIX bind unavailable on this host)"
fi
rm -rf "$SH4_HOME"

# ---------- dropped-env-key detection on re-render (#4522) ----------
# Root cause under test: render_launchd_plist / render_systemd_unit render the
# EnvironmentVariables dict / Environment= lines strictly from whatever THIS
# invocation has exported -- so a re-render from a context missing the
# operator's exports (a watchdog, a bare re-run, another tool shelling out to
# this script) used to silently replace a richer installed plist/unit with a
# narrower one (every LOOM_SAFEHOUSE_* key + LOOM_WORK_FINDER gone, no trace).
# warn_dropped_env_keys() now diffs the KEY sets (not values) between the
# installed file and the freshly-rendered replacement and warns before the
# overwrite happens.

# ---------- launchd (plist) path -- exercised read-only via --print-plist,
# same technique as the #4172 PATH-drift tests above (the real launchd
# install branch is Darwin-gated with no test-force seam, matching every
# other launchd install test in this suite/repo).
DEK_HOME="$(mktemp -d)"
mkdir -p "$DEK_HOME/Library/LaunchAgents"
DEK_LABEL="com.rjwalters.loom-daemon-dek-test"
DEK_LIVE_PLIST="$DEK_HOME/Library/LaunchAgents/${DEK_LABEL}.plist"

# DEK1. First-ever install (no existing plist) must NOT warn.
dek1_out=$( env -u LOOM_WORK_FINDER -u LOOM_MAIN_HEALTH_GATE -u LOOM_SAFEHOUSE_ENABLED \
    HOME="$DEK_HOME" LOOM_LAUNCHD_LABEL="$DEK_LABEL" LOOM_DAEMON_BIN="$FAKE_BIN" \
    bash "$START_SCRIPT" --print-plist 2>&1 >/dev/null )
TESTS_RUN=$((TESTS_RUN + 1))
if ! echo "$dek1_out" | grep -qi 'drops.*env key'; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓${NC} dropped-env-key (plist): first-ever install (no existing plist) never warns (#4522)"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗${NC} dropped-env-key (plist): first-ever install (no existing plist) never warns"
    echo "  output: $dek1_out"
fi

# Install the "rich" plist (LOOM_SAFEHOUSE_ENABLED + LOOM_WORK_FINDER present).
env -u LOOM_WORK_FINDER -u LOOM_MAIN_HEALTH_GATE HOME="$DEK_HOME" LOOM_LAUNCHD_LABEL="$DEK_LABEL" \
    LOOM_SAFEHOUSE_ENABLED=1 LOOM_WORK_FINDER=1 LOOM_DAEMON_BIN="$FAKE_BIN" \
    bash "$START_SCRIPT" --print-plist > "$DEK_LIVE_PLIST" 2>/dev/null

# DEK2. Re-rendering with LOOM_SAFEHOUSE_ENABLED no longer exported warns and
#       names the dropped key, with the LOOM_SAFEHOUSE_* migration hint.
dek2_out=$( env -u LOOM_WORK_FINDER -u LOOM_MAIN_HEALTH_GATE -u LOOM_SAFEHOUSE_ENABLED \
    HOME="$DEK_HOME" LOOM_LAUNCHD_LABEL="$DEK_LABEL" LOOM_DAEMON_BIN="$FAKE_BIN" \
    bash "$START_SCRIPT" --print-plist 2>&1 >/dev/null )
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$dek2_out" | grep -qi 'drops 1 env key' && echo "$dek2_out" | grep -q 'LOOM_SAFEHOUSE_ENABLED'; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓${NC} dropped-env-key (plist): re-render missing an exported key warns and names it (#4522)"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗${NC} dropped-env-key (plist): re-render missing an exported key warns and names it"
    echo "  output: $dek2_out"
fi
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$dek2_out" | grep -q 'safehouse.*block.*--from-config'; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓${NC} dropped-env-key (plist): LOOM_SAFEHOUSE_* drop prints the config-tier migration hint (#4353)"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗${NC} dropped-env-key (plist): LOOM_SAFEHOUSE_* drop prints the config-tier migration hint"
    echo "  output: $dek2_out"
fi

# DEK3. Re-rendering with the SAME (or a superset of) keys does not warn.
dek3_out=$( env -u LOOM_WORK_FINDER -u LOOM_MAIN_HEALTH_GATE HOME="$DEK_HOME" LOOM_LAUNCHD_LABEL="$DEK_LABEL" \
    LOOM_SAFEHOUSE_ENABLED=1 LOOM_WORK_FINDER=1 LOOM_DAEMON_PATH_EXTRA=/extra/bin LOOM_DAEMON_BIN="$FAKE_BIN" \
    bash "$START_SCRIPT" --print-plist 2>&1 >/dev/null )
TESTS_RUN=$((TESTS_RUN + 1))
if ! echo "$dek3_out" | grep -qi 'drops.*env key'; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓${NC} dropped-env-key (plist): re-render with the same/superset keys never warns (#4522)"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗${NC} dropped-env-key (plist): re-render with the same/superset keys never warns"
    echo "  output: $dek3_out"
fi

# DEK4. --force-env suppresses the warning for an intentional narrowing.
dek4_out=$( env -u LOOM_WORK_FINDER -u LOOM_MAIN_HEALTH_GATE -u LOOM_SAFEHOUSE_ENABLED \
    HOME="$DEK_HOME" LOOM_LAUNCHD_LABEL="$DEK_LABEL" LOOM_DAEMON_BIN="$FAKE_BIN" \
    bash "$START_SCRIPT" --print-plist --force-env 2>&1 >/dev/null )
TESTS_RUN=$((TESTS_RUN + 1))
if ! echo "$dek4_out" | grep -qi 'drops.*env key'; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓${NC} dropped-env-key (plist): --force-env suppresses the warning (#4522)"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗${NC} dropped-env-key (plist): --force-env suppresses the warning"
    echo "  output: $dek4_out"
fi
rm -rf "$DEK_HOME"

# ---------- systemd (unit) path -- exercised through the REAL install site
# (mv over $SYSTEMD_UNIT_PATH), reusing the LOOM_SYSTEMD_FORCE + stub
# systemctl seam already established above (S1-S5) so this covers the actual
# overwrite code path, not just a read-only render.
DEK_SD_BIN="$WORKDIR/dek-sd-bin"; mkdir -p "$DEK_SD_BIN"
DEK_SD_LOG="$WORKDIR/dek-sd.log"; : > "$DEK_SD_LOG"
cat > "$DEK_SD_BIN/systemctl" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$DEK_SD_LOG"
if [[ "\${1:-}" == "--user" ]]; then shift; fi
case "\${1:-}" in
  show) echo "\$\$" ;;
  *)    exit 0 ;;
esac
EOF
chmod +x "$DEK_SD_BIN/systemctl"
DEK_SD_UNIT="loom-daemon-dek-test-$$.service"
DEK_SD_HOME="$(mktemp -d)"; mkdir -p "$DEK_SD_HOME/.loom/logs"
DEK_SD_UNIT_PATH="$DEK_SD_HOME/.config/systemd/user/$DEK_SD_UNIT"

# DEK5. First-ever install (no existing unit) must NOT warn.
dek5_out=$( cd "$WORKDIR" && env -u LOOM_WORK_FINDER -u LOOM_MAIN_HEALTH_GATE -u LOOM_SAFEHOUSE_ENABLED \
    PATH="$DEK_SD_BIN:$PATH" HOME="$DEK_SD_HOME" \
    LOOM_SYSTEMD_FORCE=1 LOOM_SYSTEMD_UNIT="$DEK_SD_UNIT" \
    LOOM_DAEMON_BIN="$FAKE_BIN" \
    LOOM_SOCKET_PATH="$DEK_SD_HOME/.loom/loom-daemon.sock" \
    LOOM_AUTONOMY_MARKER="$DEK_SD_HOME/.loom/autonomy-desired" \
    bash "$START_SCRIPT" --no-launchd 2>&1 )
TESTS_RUN=$((TESTS_RUN + 1))
if ! echo "$dek5_out" | grep -qi 'drops.*env key'; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓${NC} dropped-env-key (systemd): first-ever install (no existing unit) never warns (#4522)"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗${NC} dropped-env-key (systemd): first-ever install (no existing unit) never warns"
    echo "  output: $dek5_out"
fi
if [[ -f "$DEK_SD_HOME/.loom/.daemon.pid" ]]; then
    kill "$(cat "$DEK_SD_HOME/.loom/.daemon.pid" 2>/dev/null)" 2>/dev/null || true
    rm -f "$DEK_SD_HOME/.loom/.daemon.pid"
fi
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -f "$DEK_SD_UNIT_PATH" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓${NC} dropped-env-key (systemd): first-ever install still writes the unit file"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗${NC} dropped-env-key (systemd): first-ever install still writes the unit file"
fi

# DEK6. Re-render with fewer keys (LOOM_SAFEHOUSE_ENABLED dropped from the
#       invoking env) warns and names the dropped key, before the unit is
#       overwritten. Re-run with the rich env first so the installed unit
#       actually carries the key.
: > "$DEK_SD_LOG"
sleep 30 & DEK_SD_PID1=$!
( cd "$WORKDIR" && env -u LOOM_WORK_FINDER -u LOOM_MAIN_HEALTH_GATE \
    PATH="$DEK_SD_BIN:$PATH" HOME="$DEK_SD_HOME" \
    LOOM_SYSTEMD_FORCE=1 LOOM_SYSTEMD_UNIT="$DEK_SD_UNIT" \
    LOOM_SAFEHOUSE_ENABLED=1 LOOM_WORK_FINDER=1 \
    LOOM_DAEMON_BIN="$FAKE_BIN" \
    LOOM_SOCKET_PATH="$DEK_SD_HOME/.loom/loom-daemon.sock" \
    LOOM_AUTONOMY_MARKER="$DEK_SD_HOME/.loom/autonomy-desired" \
    bash "$START_SCRIPT" --no-launchd >/dev/null 2>&1 )
kill "$DEK_SD_PID1" 2>/dev/null || true
if [[ -f "$DEK_SD_HOME/.loom/.daemon.pid" ]]; then
    kill "$(cat "$DEK_SD_HOME/.loom/.daemon.pid" 2>/dev/null)" 2>/dev/null || true
    rm -f "$DEK_SD_HOME/.loom/.daemon.pid"
fi
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -f "$DEK_SD_UNIT_PATH" ]] && grep -q 'LOOM_SAFEHOUSE_ENABLED' "$DEK_SD_UNIT_PATH"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓${NC} dropped-env-key (systemd): fixture install carries LOOM_SAFEHOUSE_ENABLED (setup for DEK6b)"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗${NC} dropped-env-key (systemd): fixture install carries LOOM_SAFEHOUSE_ENABLED"
    cat "$DEK_SD_UNIT_PATH" 2>/dev/null | sed 's/^/    /'
fi

sleep 30 & DEK_SD_PID2=$!
dek6_out=$( cd "$WORKDIR" && env -u LOOM_WORK_FINDER -u LOOM_MAIN_HEALTH_GATE -u LOOM_SAFEHOUSE_ENABLED \
    PATH="$DEK_SD_BIN:$PATH" HOME="$DEK_SD_HOME" \
    LOOM_SYSTEMD_FORCE=1 LOOM_SYSTEMD_UNIT="$DEK_SD_UNIT" \
    LOOM_DAEMON_BIN="$FAKE_BIN" \
    LOOM_SOCKET_PATH="$DEK_SD_HOME/.loom/loom-daemon.sock" \
    LOOM_AUTONOMY_MARKER="$DEK_SD_HOME/.loom/autonomy-desired" \
    bash "$START_SCRIPT" --no-launchd 2>&1 )
kill "$DEK_SD_PID2" 2>/dev/null || true
if [[ -f "$DEK_SD_HOME/.loom/.daemon.pid" ]]; then
    kill "$(cat "$DEK_SD_HOME/.loom/.daemon.pid" 2>/dev/null)" 2>/dev/null || true
    rm -f "$DEK_SD_HOME/.loom/.daemon.pid"
fi
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$dek6_out" | grep -qi 'drops 1 env key' && echo "$dek6_out" | grep -q 'LOOM_SAFEHOUSE_ENABLED' \
    && echo "$dek6_out" | grep -q 'safehouse.*block.*--from-config'; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓${NC} dropped-env-key (systemd): real re-render missing a key warns, names it, and prints the migration hint (#4522)"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗${NC} dropped-env-key (systemd): real re-render missing a key warns, names it, and prints the migration hint"
    echo "  output: $dek6_out"
fi
TESTS_RUN=$((TESTS_RUN + 1))
if [[ -f "$DEK_SD_UNIT_PATH" ]] && ! grep -q 'LOOM_SAFEHOUSE_ENABLED' "$DEK_SD_UNIT_PATH"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓${NC} dropped-env-key (systemd): the WARNED narrowing still actually installs (warn, don't block)"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗${NC} dropped-env-key (systemd): the WARNED narrowing still actually installs"
fi

# DEK7. --force-env suppresses the warning on the real install path too.
sleep 30 & DEK_SD_PID3=$!
( cd "$WORKDIR" && env -u LOOM_WORK_FINDER -u LOOM_MAIN_HEALTH_GATE \
    PATH="$DEK_SD_BIN:$PATH" HOME="$DEK_SD_HOME" \
    LOOM_SYSTEMD_FORCE=1 LOOM_SYSTEMD_UNIT="$DEK_SD_UNIT" \
    LOOM_SAFEHOUSE_ENABLED=1 LOOM_WORK_FINDER=1 \
    LOOM_DAEMON_BIN="$FAKE_BIN" \
    LOOM_SOCKET_PATH="$DEK_SD_HOME/.loom/loom-daemon.sock" \
    LOOM_AUTONOMY_MARKER="$DEK_SD_HOME/.loom/autonomy-desired" \
    bash "$START_SCRIPT" --no-launchd >/dev/null 2>&1 )
kill "$DEK_SD_PID3" 2>/dev/null || true
if [[ -f "$DEK_SD_HOME/.loom/.daemon.pid" ]]; then
    kill "$(cat "$DEK_SD_HOME/.loom/.daemon.pid" 2>/dev/null)" 2>/dev/null || true
    rm -f "$DEK_SD_HOME/.loom/.daemon.pid"
fi
sleep 30 & DEK_SD_PID4=$!
dek7_out=$( cd "$WORKDIR" && env -u LOOM_WORK_FINDER -u LOOM_MAIN_HEALTH_GATE -u LOOM_SAFEHOUSE_ENABLED \
    PATH="$DEK_SD_BIN:$PATH" HOME="$DEK_SD_HOME" \
    LOOM_SYSTEMD_FORCE=1 LOOM_SYSTEMD_UNIT="$DEK_SD_UNIT" \
    LOOM_DAEMON_BIN="$FAKE_BIN" \
    LOOM_SOCKET_PATH="$DEK_SD_HOME/.loom/loom-daemon.sock" \
    LOOM_AUTONOMY_MARKER="$DEK_SD_HOME/.loom/autonomy-desired" \
    bash "$START_SCRIPT" --no-launchd --force-env 2>&1 )
kill "$DEK_SD_PID4" 2>/dev/null || true
if [[ -f "$DEK_SD_HOME/.loom/.daemon.pid" ]]; then
    kill "$(cat "$DEK_SD_HOME/.loom/.daemon.pid" 2>/dev/null)" 2>/dev/null || true
    rm -f "$DEK_SD_HOME/.loom/.daemon.pid"
fi
TESTS_RUN=$((TESTS_RUN + 1))
if ! echo "$dek7_out" | grep -qi 'drops.*env key'; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓${NC} dropped-env-key (systemd): --force-env suppresses the warning on the real install path (#4522)"
else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗${NC} dropped-env-key (systemd): --force-env suppresses the warning on the real install path"
    echo "  output: $dek7_out"
fi
TESTS_RUN=$((TESTS_RUN + 1))
if echo "$dek7_out" | grep -q -- '--force-env'; then
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗${NC} dropped-env-key (systemd): --force-env is excluded from the persisted .daemon.flags file"
elif [[ -f "$DEK_SD_HOME/.loom/.daemon.flags" ]] && grep -q -- '--force-env' "$DEK_SD_HOME/.loom/.daemon.flags"; then
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}✗${NC} dropped-env-key (systemd): --force-env is excluded from the persisted .daemon.flags file"
else
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}✓${NC} dropped-env-key (systemd): --force-env is excluded from the persisted .daemon.flags file"
fi
rm -rf "$DEK_SD_HOME"

# SH5. #4225: attention-class routing supplies the room via
#      safehouse.rooms.signal instead of the scalar safehouse.room -> the
#      room-unset caveat must NOT appear (the resolver falls back from
#      rooms.signal to room, so a host with either one is satisfied).
SH5_HOME="$(mktemp -d)"
mkdir -p "$SH5_HOME/.loom"
SH5_SOCK="$SH5_HOME/.loom/safehoused.sock"
if command -v python3 >/dev/null 2>&1 \
    && python3 -c "
import socket
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind('$SH5_SOCK')
" 2>/dev/null; then
    cat > "$SH5_HOME/.loom/config.json" <<EOF
{"safehouse": {"enabled": true, "socket": "$SH5_SOCK",
  "rooms": {"signal": "!signal:example.org", "byRepo": {"loom": "!fleet-loom:example.org"}}}}
EOF
    sh5_out=$( ( cd "$SH5_HOME" && env -u LOOM_WORK_FINDER -u LOOM_MAIN_HEALTH_GATE \
        -u LOOM_SAFEHOUSE_ENABLED -u LOOM_SAFEHOUSE_SOCKET -u SAFEHOUSED_SOCKET \
        -u LOOM_SAFEHOUSE_ROOM -u LOOM_SAFEHOUSE_ROOM_SIGNAL \
        LOOM_DAEMON_BIN="$SH_BG_FAKE_BIN" \
        LOOM_SOCKET_PATH="$SH5_HOME/.loom/loom-daemon.sock" \
        LOOM_AUTONOMY_MARKER="$SH5_HOME/.loom/autonomy-desired" \
        LOOM_WATCHDOG_LABEL="com.example.loom-sandbox-$$-sh5-watchdog" \
        bash "$START_SCRIPT" --no-launchd --no-systemd 2>&1 ) )
    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$sh5_out" | grep -q 'safehouse.room is unset'; then
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "${RED}✗${NC} safehouse: rooms.signal set -> no room caveat (#4225)"
        echo "  output: $sh5_out"
    else
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "${GREEN}✓${NC} safehouse: rooms.signal set -> no room caveat (#4225)"
    fi
    if [[ -f "$SH5_HOME/.loom/.daemon.pid" ]]; then
        kill "$(cat "$SH5_HOME/.loom/.daemon.pid" 2>/dev/null)" 2>/dev/null || true
    fi
else
    echo "  (skipping SH5: python3 AF_UNIX bind unavailable on this host)"
fi
rm -rf "$SH5_HOME"

# ---------- summary ----------
echo
echo "Ran $TESTS_RUN tests: $TESTS_PASSED passed, $TESTS_FAILED failed"
[[ "$TESTS_FAILED" -eq 0 ]]
