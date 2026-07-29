#!/usr/bin/env bash
# loom-daemon-watchdog.sh - Host-side autonomy-loss detector for the RAW
# loom-daemon process (Issue #4011).
#
# THE PROBLEM IT SOLVES
#   On 2026-07-26 the loom-daemon launchd job took a SIGTERM two seconds after
#   starting and was left `bootout`-ed (unloaded) from launchd. Autonomous
#   dispatch (work finder, role runner) silently stopped. NOTHING surfaced it —
#   no log line, no forge signal, no notification. It was discovered hours later
#   only because someone happened to run `loom-daemon status` by hand. A pull
#   nobody performed for hours is not a detector.
#
# WHAT THIS IS
#   The payload of a SECOND launchd job (`<daemon-label>-watchdog`) that runs on
#   a `StartInterval` cadence, SEPARATE from the daemon job. It compares two
#   things:
#     (1) operator INTENT — the durable `autonomy-desired` marker that
#         loom-daemon-start.sh writes on a successful start and only an
#         operator-initiated loom-daemon-stop.sh removes; and
#     (2) REALITY — whether a daemon for the expected launchd label is actually
#         loaded and alive, and whether its declared-cadence heartbeat file
#         (written by the daemon, #4011) is fresh.
#   When intent says "a daemon should be running" but reality disagrees, it
#   REPORTS loudly (a timestamped line to the watchdog log + stderr, which
#   launchd captures) instead of staying silent.
#
# WHY A SECOND LAUNCHD JOB, NOT A RESIDENT PROCESS
#   The reporter must live OUTSIDE the daemon process: a dead daemon cannot
#   report its own death (which is why #3971's in-daemon watch loop is not
#   reusable here). And it must itself be supervised — but a long-lived resident
#   watchdog just moves the "who watches the watchdog" problem up one level (it
#   too can crash and stay dead). A `StartInterval` job owns NO long-lived
#   process: launchd re-runs it every interval regardless of how the last run
#   exited, so it structurally cannot crash-and-stay-dead. That is what resolves
#   the recursion.
#
# WHY THE MARKER, NOT "is the pid file / launchd job present"
#   loom-daemon-stop.sh boots out the job AND deletes the pid file, so after ANY
#   stop those would be gone — making a deliberately-stopped daemon and a
#   silently-dead one byte-identical. A detector built on them would page on
#   every intentional stop or never page at all. The marker's lifetime is
#   OPERATOR INTENT: present ⇒ a daemon is expected; absent ⇒ it was
#   deliberately stopped (or never started) ⇒ stay silent.
#
# BOUNDED AUTO-REMEDIATION (#4232)
#   The watchdog was deliberately report-only until #4232: on 2026-07-28 a
#   `loom-daemon restart` was ack'd (the running daemon exited 0, honoring its
#   #4054/#4077 restart contract) but launchd never relaunched it — the
#   watchdog could describe that outage but not fix it, which matters once
#   #4055's unattended self-update path can hit the same race with no operator
#   watching. This job now auto-runs `launchctl kickstart <label>` (PLAIN,
#   NEVER `-k`) for EXACTLY ONE divergence signature: the launchd job is
#   LOADED (launchctl still knows about it) + NOT running + its last exit
#   status was 0. That signature can ONLY arise from a restart-primitive exit
#   that launchd failed to honor — an operator SIGTERM stop exits 143/130
#   (loom-daemon-stop.sh), a crash exits non-zero, and a booted-out/never-
#   loaded job fails `launchctl print` outright. Every other divergence stays
#   report-only, exactly as before: no crash-loop revival, no reviving a
#   deliberate stop.
#
# EXIT CODES (a StartInterval job's exit code does not affect relaunch — these
# exist for testability and for a human running it by hand):
#   0  no divergence — daemon healthy, OR no daemon expected AND none running
#      (marker absent + nothing alive), OR the #4232 bounded auto-remediation
#      (see above) successfully relaunched it via 'launchctl kickstart'
#   1  DIVERGENCE / state mismatch reported — a daemon is expected but is not
#      running (and either the #4232 remediation gate did not apply, or it fired
#      but the daemon is still not confirmed running), or is running but its
#      heartbeat is stale (possibly wedged), OR (#4331) a daemon IS running while
#      the marker is ABSENT (crash protection disarmed — a WARN state mismatch)
#   2  usage error
#
# Usage:
#   ./.loom/scripts/cli/loom-daemon-watchdog.sh            Check once, report on divergence
#   ./.loom/scripts/cli/loom-daemon-watchdog.sh --verbose  Also log the healthy/idle no-op cases
#   ./.loom/scripts/cli/loom-daemon-watchdog.sh --help
#
# Environment:
#   LOOM_AUTONOMY_MARKER           Path to the intent marker (default: derived
#                                  from LOOM_SOCKET_PATH's dir, else ~/.loom/autonomy-desired)
#   LOOM_WATCHDOG_LOG              Report log path (default: <loom dir>/logs/daemon-watchdog.log)
#   LOOM_DAEMON_HEARTBEAT_STALE_SECS  Staleness threshold in seconds (default:
#                                  max(5 × heartbeat cadence, 300))
#   LOOM_SOCKET_PATH              Override the daemon socket (its dir is the loom dir)
#   LOOM_LAUNCHD_LABEL            macOS: the DAEMON label to probe (default com.rjwalters.loom-daemon)
#   LOOM_LAUNCHD_DOMAIN          macOS: pin the launchd domain (gui/<uid> or user/<uid>);
#                                else auto-resolved gui→user (#4130), matching the start
#   LOOM_DAEMON_LAUNCHD          0/false/no: treat as a non-launchd (nohup) daemon; check the pid file only
#   LOOM_WATCHDOG_KICKSTART_RECHECK_ATTEMPTS  #4232: how many times to re-check
#                                for a live pid after the auto-kickstart fallback
#                                (default 3).
#   LOOM_WATCHDOG_KICKSTART_RECHECK_INTERVAL  #4232: seconds between re-checks
#                                (default 1; may be fractional).

set -uo pipefail

# ---------- output helpers ----------
if [[ -t 2 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; NC=''
fi

show_help() {
    awk 'NR>=2 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
}

# Shared domain resolver (#4130): gui/<uid> ↦ user/<uid>, sourced verbatim so the
# watchdog probes the daemon in the same domain the start put it in.
_LOOM_LAUNCHD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" 2>/dev/null && pwd)"
if [[ -r "$_LOOM_LAUNCHD_LIB_DIR/launchd-domain.sh" ]]; then
    # shellcheck source=../lib/launchd-domain.sh
    source "$_LOOM_LAUNCHD_LIB_DIR/launchd-domain.sh"
fi

VERBOSE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h) show_help; exit 0 ;;
        --verbose|-v) VERBOSE=true; shift ;;
        *) echo "Unknown option '$1' (use --help)" >&2; exit 2 ;;
    esac
done

# ---------- path resolution (mirrors loom-daemon-start.sh / resolve_loom_dir) ----------
SOCKET_PATH="${LOOM_SOCKET_PATH:-$HOME/.loom/loom-daemon.sock}"
LOOM_DIR="$(dirname "$SOCKET_PATH")"
MARKER="${LOOM_AUTONOMY_MARKER:-$LOOM_DIR/autonomy-desired}"
WATCHDOG_LOG="${LOOM_WATCHDOG_LOG:-$LOOM_DIR/logs/daemon-watchdog.log}"

# Append a timestamped line to the watchdog log (best-effort) and echo to
# stderr, which launchd captures to the job's StandardErrorPath. This IS the
# report — the durable, operator-visible signal that a pull never surfaced.
report() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    mkdir -p "$(dirname "$WATCHDOG_LOG")" 2>/dev/null || true
    echo "$ts [$level] $msg" >> "$WATCHDOG_LOG" 2>/dev/null || true
    case "$level" in
        DIVERGENCE) echo -e "${RED}$ts [$level] $msg${NC}" >&2 ;;
        OK)         [[ "$VERBOSE" == "true" ]] && echo -e "${GREEN}$ts [$level] $msg${NC}" >&2 ;;
        *)          echo -e "${YELLOW}$ts [$level] $msg${NC}" >&2 ;;
    esac
}

# ---------- reality probe (shared) ----------
# Determine whether the expected daemon is actually alive. Reads the resolved
# USE_LAUNCHD / LABEL / PID_FILE and sets four globals the callers branch on:
#   daemon_alive     true|false
#   liveness_detail  human-readable string (mirrored into status/log messages)
#   job_loaded       true|false — launchd job in the table but with no live pid
#                    (feeds the #4232 bounded auto-remediation gate)
#   launchd_service  <domain>/<label> for the launchd path (else empty)
# Factored out (#4331) so the no-marker state-mismatch check below and the
# marker-present path below run the IDENTICAL liveness logic — they can never
# diverge on what "alive" means.
detect_daemon_liveness() {
    daemon_alive=false
    liveness_detail=""
    job_loaded=false
    launchd_service=""
    if [[ "$USE_LAUNCHD" == "true" ]] && command -v launchctl >/dev/null 2>&1; then
        # Resolve the domain (gui/<uid> ↦ user/<uid>, #4130) the same way the
        # start did, so a headless daemon in user/<uid> is probed correctly.
        launchd_service="$(resolve_launchd_domain)/${LABEL}"
        launchd_print_output="$(launchctl print "$launchd_service" 2>/dev/null)"
        launchd_print_rc=$?
        launchd_pid="$(printf '%s\n' "$launchd_print_output" | awk -F'= ' '/^[[:space:]]*pid = /{gsub(/[^0-9]/, "", $2); print $2; exit}')"
        if [[ -n "$launchd_pid" ]] && kill -0 "$launchd_pid" 2>/dev/null; then
            daemon_alive=true
            liveness_detail="launchd job $launchd_service alive (pid $launchd_pid)"
        elif [[ "$launchd_print_rc" -eq 0 ]]; then
            job_loaded=true
            liveness_detail="launchd job $launchd_service is LOADED but NOT running (no live pid)"
        else
            liveness_detail="launchd job $launchd_service is not loaded/alive"
        fi
    else
        # Non-launchd (nohup / Linux) path: the pid file is the only signal.
        if [[ -n "$PID_FILE" && -f "$PID_FILE" ]]; then
            pid="$(cat "$PID_FILE" 2>/dev/null || true)"
            if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                daemon_alive=true
                liveness_detail="pid $pid (from $PID_FILE) alive"
            else
                liveness_detail="pid file $PID_FILE present but pid not alive"
            fi
        else
            liveness_detail="no live pid file at ${PID_FILE:-<none>}"
        fi
    fi
}

# ---------- 1. intent: is a daemon expected at all? ----------
if [[ ! -f "$MARKER" ]]; then
    # A missing marker is SUPPOSED to mean "deliberately stopped (or never
    # started) — nothing to check". But the marker can go absent while a
    # supervised daemon is very much alive: an out-of-band delete, a failed
    # marker write, or a daemon rolled ONLY via `loom-daemon restart` / the
    # self-update loop (neither re-writes the marker — #4331). In that state the
    # daemon runs with crash protection DISARMED, and a bare `[OK] nothing to
    # check` hides exactly the gap the watchdog exists to surface. So before
    # staying quiet, cheaply probe reality with env-derived defaults.
    USE_LAUNCHD=true
    if [[ "${LOOM_DAEMON_LAUNCHD:-}" =~ ^(0|false|no)$ ]]; then
        USE_LAUNCHD=false
    fi
    [[ "$(uname -s)" == "Darwin" ]] || USE_LAUNCHD=false
    LABEL="${LOOM_LAUNCHD_LABEL:-com.rjwalters.loom-daemon}"
    PID_FILE="$LOOM_DIR/.daemon.pid"
    detect_daemon_liveness
    if [[ "$daemon_alive" == "true" ]]; then
        report WARN \
            "STATE MISMATCH: no autonomy-desired marker at $MARKER, but a daemon IS running (${liveness_detail}). Crash protection is DISARMED — if this daemon dies the watchdog will NOT revive it. Heal it by restarting the daemon (it self-heals the marker at startup, #4331) or re-running ./.loom/scripts/cli/loom-daemon-start.sh; if the daemon should NOT be running, stop it with ./.loom/scripts/cli/loom-daemon-stop.sh."
        exit 1
    fi
    # Nothing alive ⇒ the load-bearing quiet case: a deliberate stop (which also
    # boots out the daemon job, so nothing is found here) must never page.
    # Preserve the silent OK exactly as before.
    report OK "no autonomy-desired marker at $MARKER — no daemon expected; nothing to check."
    exit 0
fi

# ---------- parse the marker (key=value; ignore comments/blanks) ----------
marker_get() {
    local key="$1"
    # First matching `key=value` line; strip the key= prefix. Comments start '#'.
    grep -E "^${key}=" "$MARKER" 2>/dev/null | head -n1 | cut -d= -f2-
}

HEARTBEAT_FILE="$(marker_get heartbeat_file)"
HEARTBEAT_INTERVAL_SECS="$(marker_get heartbeat_interval_secs)"
MARKER_USE_LAUNCHD="$(marker_get use_launchd)"
MARKER_LABEL="$(marker_get launchd_label)"
PID_FILE="$(marker_get pid_file)"

# Fallbacks when the marker predates a field or the value is empty.
[[ -z "$HEARTBEAT_FILE" ]] && HEARTBEAT_FILE="$LOOM_DIR/daemon.heartbeat"
[[ "$HEARTBEAT_INTERVAL_SECS" =~ ^[0-9]+$ ]] || HEARTBEAT_INTERVAL_SECS=60
[[ -z "$PID_FILE" ]] && PID_FILE=""

# Env overrides win over the marker (a stop/start under a different label should
# be probed with the current env, not a stale marker value).
USE_LAUNCHD="${MARKER_USE_LAUNCHD:-true}"
if [[ "${LOOM_DAEMON_LAUNCHD:-}" =~ ^(0|false|no)$ ]]; then
    USE_LAUNCHD=false
fi
[[ "$(uname -s)" == "Darwin" ]] || USE_LAUNCHD=false
LABEL="${LOOM_LAUNCHD_LABEL:-${MARKER_LABEL:-com.rjwalters.loom-daemon}}"

# ---------- 2. reality: is the expected daemon actually alive? ----------
# Shared probe (#4331): sets daemon_alive / liveness_detail / job_loaded /
# launchd_service from the resolved USE_LAUNCHD / LABEL / PID_FILE. job_loaded /
# launchd_service feed the #4232 bounded auto-remediation gate below:
# job_loaded=true means `launchctl print` succeeded (the job IS in launchd's
# table) even though no live pid was found — distinct from "not loaded at all"
# (a booted-out job, or a non-launchd host), which stays report-only no matter
# what.
detect_daemon_liveness

if [[ "$daemon_alive" != "true" ]]; then
    # ---------- bounded auto-remediation (#4232) ----------
    # THE PROBLEM: the restart primitive's contract (#4054/#4077) is "the
    # supervised daemon exits 0 -> KeepAlive:SuccessfulExit relaunches it". On
    # 2026-07-28 that contract's exit-0 half held but launchd's relaunch half
    # silently didn't, and this watchdog (a report-only detector) could only
    # describe the outage, not fix it — exactly the unattended-#4055-rollout
    # risk this narrow gate closes.
    #
    # THE GATE IS NARROW BY CONSTRUCTION: auto-`kickstart` fires ONLY for the
    # exact signature "job LOADED (launchctl still knows about it) + NOT
    # running + last exit status 0". An operator-initiated SIGTERM stop exits
    # 143/130 (loom-daemon-stop.sh); a genuine crash exits non-zero; a booted-
    # out/never-loaded job fails `launchctl print` outright (job_loaded=false).
    # NONE of those can produce "loaded, down, exit 0" — only a restart-
    # primitive exit that launchd failed to honor can. So every OTHER
    # divergence (stop, crash, bootout) falls through to the report-only path
    # below unchanged: no crash-loop revival, no reviving a deliberate stop.
    if [[ "$job_loaded" == "true" && -n "$launchd_service" ]]; then
        last_exit_status="$(launchctl print "$launchd_service" 2>/dev/null \
            | grep -oE 'last exit (code|status)[[:space:]]*=[[:space:]]*[-0-9]+' \
            | head -n1 | grep -oE '[-0-9]+$')"
        if [[ "$last_exit_status" == "0" ]]; then
            report DIVERGENCE \
                "A daemon is EXPECTED (autonomy-desired marker present, started $(marker_get started_at)) but is NOT running: ${liveness_detail}. Last exit status was 0 — the restart-primitive's own exit-0 contract (#4054/#4077) — which launchd failed to honor. Auto-remediating with 'launchctl kickstart ${launchd_service}' (PLAIN, never -k, so a daemon that is mid-relaunch is never killed) (#4232)."
            launchctl kickstart "$launchd_service" >/dev/null 2>&1
            # Brief, bounded re-check — this is a StartInterval job (re-run
            # every cadence regardless), so a failure here is NOT the last
            # chance; it just means this pass still reports divergence and the
            # next pass tries again.
            RECHECK_ATTEMPTS="${LOOM_WATCHDOG_KICKSTART_RECHECK_ATTEMPTS:-3}"
            RECHECK_INTERVAL="${LOOM_WATCHDOG_KICKSTART_RECHECK_INTERVAL:-1}"
            recheck_pid=""
            for _ in $(seq 1 "$RECHECK_ATTEMPTS"); do
                recheck_pid="$(launchctl print "$launchd_service" 2>/dev/null | awk -F'= ' '/^[[:space:]]*pid = /{gsub(/[^0-9]/, "", $2); print $2; exit}')"
                if [[ -n "$recheck_pid" ]] && kill -0 "$recheck_pid" 2>/dev/null; then
                    break
                fi
                recheck_pid=""
                sleep "$RECHECK_INTERVAL"
            done
            if [[ -n "$recheck_pid" ]]; then
                report OK "auto-remediation succeeded: 'launchctl kickstart' relaunched ${launchd_service} (new pid ${recheck_pid})."
                exit 0
            fi
            report DIVERGENCE \
                "Auto-remediation attempted ('launchctl kickstart ${launchd_service}') but the daemon is STILL not confirmed running. Escalate manually: launchctl print ${launchd_service}  (or ./.loom/scripts/cli/loom-daemon-start.sh [flags])."
            exit 1
        fi
    fi

    report DIVERGENCE \
        "A daemon is EXPECTED (autonomy-desired marker present, started $(marker_get started_at)) but is NOT running: ${liveness_detail}. Autonomous dispatch has stopped. Recover with: ./.loom/scripts/cli/loom-daemon-start.sh [flags]  (or 'loom-daemon status' to inspect)."
    exit 1
fi

# ---------- 3. reality: is the heartbeat fresh? ----------
# The daemon writes HEARTBEAT_FILE on a declared cadence (#4011). A live daemon
# whose heartbeat has gone stale is likely wedged — still a process, but not
# doing its periodic work. The threshold is a comfortable multiple of the
# cadence so a single missed write never false-positives.
STALE_SECS="${LOOM_DAEMON_HEARTBEAT_STALE_SECS:-}"
if [[ ! "$STALE_SECS" =~ ^[0-9]+$ ]]; then
    STALE_SECS=$(( HEARTBEAT_INTERVAL_SECS * 5 ))
    (( STALE_SECS < 300 )) && STALE_SECS=300
fi

file_mtime() {
    # Portable mtime (epoch secs): GNU `stat -c` vs BSD/macOS `stat -f`.
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

if [[ -f "$HEARTBEAT_FILE" ]]; then
    mtime="$(file_mtime "$HEARTBEAT_FILE")"
    if [[ "$mtime" =~ ^[0-9]+$ ]]; then
        now="$(date -u +%s)"
        age=$(( now - mtime ))
        if (( age > STALE_SECS )); then
            report DIVERGENCE \
                "Daemon process is alive (${liveness_detail}) but its heartbeat ${HEARTBEAT_FILE} is STALE (${age}s old > ${STALE_SECS}s threshold) — the daemon may be wedged. Inspect with 'loom-daemon status'; consider ./.loom/scripts/cli/loom-daemon-stop.sh && ...start.sh."
            exit 1
        fi
        report OK "daemon healthy (${liveness_detail}); heartbeat fresh (${age}s ≤ ${STALE_SECS}s)."
        exit 0
    fi
    # Unreadable mtime — degrade to liveness-only rather than false-report.
    report OK "daemon alive (${liveness_detail}); heartbeat mtime unreadable — liveness-only OK."
    exit 0
fi

# No heartbeat file but the daemon is alive: either the heartbeat loop is
# disabled (LOOM_DAEMON_HEARTBEAT=0) or the daemon just started and has not
# written yet. Degrade to liveness-only — do NOT false-report, since the daemon
# clearly IS running.
report OK "daemon alive (${liveness_detail}); no heartbeat file at ${HEARTBEAT_FILE} (heartbeat disabled or not yet written) — liveness-only OK."
exit 0
