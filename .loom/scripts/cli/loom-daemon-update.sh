#!/usr/bin/env bash
# loom-daemon-update.sh - Self-update the RAW loom-daemon process (Issue #3968)
#
# Closes the "self-update gap" observed during the 2026-07-25/26 canary
# rollout: the daemon's self-repair loop filed AND fixed 16 of its own
# defects, but every merged fix only took effect after an operator manually
# rebuilt the Rust binary, reprovisioned it, and restarted the process. This
# script is the single operator command that does all three, in order,
# preserving the FLAGS-OFF/opt-in autonomy contract across the restart.
#
# Staleness detection strategy (primary, zero-network): compare the git
# commit BAKED INTO the currently-resolved `loom-daemon` binary (embedded at
# build time via build.rs -> LOOM_DAEMON_GIT_COMMIT, surfaced in
# `loom-daemon --version`) against the LOCAL source tree's current HEAD short
# commit. This answers the directly actionable question — "would rebuilding
# right now produce a different binary?" — without touching the network.
#
# Checkout freshness (default, ff-first — #4330): the whole point of running
# this script is to get the daemon onto the LATEST code, so before resolving
# the local HEAD used for the staleness comparison above, this script attempts
# a bounded, best-effort `git fetch` of origin/<default-branch> and, if local
# HEAD is behind, a `git merge --ff-only`. On success the rebuild below builds
# the freshly-synced HEAD. If the ff-merge cannot apply (diverged local
# commits, or a dirty tracked file conflicts with the incoming change) the
# script ABORTS (exit 1) rather than guessing or hard-resetting — a stale
# rebuild silently missing merged commits (the 2026-07-29 incident this issue
# closes) is worse than a loud abort asking the operator to resolve it by
# hand. A fetch failure/timeout (offline, network degraded) is NOT treated as
# "behind" — the script warns and proceeds with local HEAD as-is, so this
# check never makes the script hard-network-dependent. `--allow-stale`
# restores the pre-#4330 build-what's-here behavior (skips the fetch+merge
# entirely) for deliberate use (bisecting, testing a local patch) — see below.
#
# It:
#   - detects whether the resolved binary is stale vs. the local source tree,
#   - rebuilds (`cargo build --release`) in loom-daemon/ when stale (or
#     --force),
#   - provisions the fresh binary to wherever the resolved binary lives
#     (LOOM_DAEMON_BIN override, else the machine-level ~/.local/bin install
#     via scripts/install/provision-daemon.sh, matching #3922's convention),
#   - reads the flags loom-daemon-start.sh persisted at the last invocation
#     (.loom/.daemon.flags, #3968) and restarts with EXACTLY those flags —
#     never more, never fewer. A daemon that was NOT running is left
#     stopped (this script never widens FLAGS-OFF by starting autonomy that
#     wasn't already running).
#
# Launchd-managed daemons (#4042): on Darwin the daemon is commonly launchd-
# managed (default since #3972/#4054), in which case NEITHER .loom/.daemon.pid
# nor .loom/.daemon.flags reliably reflects "is it running" — the pid file goes
# stale after any KeepAlive:SuccessfulExit relaunch, and a hand-bootstrapped
# daemon has no state files at all. This script therefore checks the launchd job
# state (`launchctl print <domain>/<label>`, where <domain> is
# resolve_launchd_domain()'s gui/<uid> ↦ user/<uid> pick — #4130 — mirroring
# loom-daemon-stop.sh) AHEAD of the pid-file tier when resolving whether/how the
# daemon is running.
# When launchd-managed, it restarts via the `loom-daemon restart` primitive
# (#4077 — sends Request::RestartDaemon over the IPC socket; the supervised
# daemon exits 0 and launchd relaunches it onto the fresh binary with the
# plist's persisted ProgramArguments/EnvironmentVariables). .daemon.flags is NOT
# consulted in this mode (the plist's EnvironmentVariables IS the durable flag
# source), and no "restarting FLAGS-OFF" warning fires. If the running (old)
# binary predates #4077 and refuses the request, this script REFUSES LOUDLY
# (exit 6) and prints how to re-render the plist + relaunch under supervision
# (loom-daemon-update.sh --relaunch), rather than reporting a half-update — the
# exact #4011 silent-autonomy-loss class this closes. The old advice to bootstrap
# the EXISTING plist was itself a bug (#4118): it relaunched under the STALE plist
# (no KeepAlive:SuccessfulExit, no LOOM_DAEMON_SUPERVISOR), so every subsequent
# roll hit the same exit 6 forever, and its bootout killed in-flight sweeps
# (sweep children are direct children of the launchd job). --relaunch re-renders
# via loom-daemon-start.sh (installing the supervised keys) while preserving the
# live plist's LOOM_* autonomy env, and SIGTERMs the daemon so sweep children
# reparent instead of being torn down with the job.
#
# systemd --user-managed daemons (Linux, #4260 sub-issue C): the exact same
# ownership-tiering + supervised-restart contract, ported to the systemd --user
# service loom-daemon-start.sh installs (#4268). A `systemd --user` unit's pid
# also goes stale on every `Restart=on-success` relaunch, so it is checked at the
# SAME tier as launchd, ahead of the pid-file tier. The restart itself is driven
# by the identical `loom-daemon restart` IPC primitive (recognized daemon-side by
# `detect_supervisor()` since #4267/PR #4298 when `LOOM_DAEMON_SUPERVISOR=systemd`
# is present — baked into the rendered unit by loom-daemon-start.sh); a clean
# exit 0 lets systemd's `Restart=on-success` relaunch onto the fresh binary. On a
# refused restart (a pre-#4267 binary with no RestartDaemon handler, or a dead
# socket), the script refuses loudly (exit 6) exactly like launchd, and
# --relaunch (or LOOM_DAEMON_UPDATE_RELAUNCH=1) re-renders the unit and forces
# the relaunch: it harvests the live unit's `Environment=` LOOM_*/token lines,
# SIGTERMs the running daemon (so sweep children reparent instead of being torn
# down), then re-invokes loom-daemon-start.sh — which re-renders the unit
# (installing `LOOM_DAEMON_SUPERVISOR=systemd`), reloads, and `enable --now`s it
# onto a now-inactive unit, i.e. a genuine restart. `LOOM_DAEMON_SYSTEMD=0`
# disables ALL systemd interaction symmetrically with loom-daemon-start.sh
# --no-systemd / loom-daemon-stop.sh, so a --no-systemd install is never probed
# via systemctl and follows the PID-file/nohup restart path instead. Darwin
# behavior is entirely unaffected — this tier is inert unless
# `is_linux_systemd()` (lib/systemd-user.sh) resolves true.
#
# Usage:
#   ./.loom/scripts/cli/loom-daemon-update.sh              Detect, rebuild if stale, provision, restart (preserving flags)
#   ./.loom/scripts/cli/loom-daemon-update.sh --check       Detect only; exit 0 (up to date) or 3 (update available); no writes
#   ./.loom/scripts/cli/loom-daemon-update.sh --dry-run     Print the plan without building/provisioning/restarting
#   ./.loom/scripts/cli/loom-daemon-update.sh --force       Rebuild + provision + restart even if already up to date
#   ./.loom/scripts/cli/loom-daemon-update.sh --no-restart  Rebuild + provision only; leave the running daemon untouched
#   ./.loom/scripts/cli/loom-daemon-update.sh --relaunch    Launchd/systemd only: after a refused restart, re-render the plist/unit and relaunch under supervision (SIGTERMs the daemon so sweep children reparent; preserves the live LOOM_* env)
#   ./.loom/scripts/cli/loom-daemon-update.sh --allow-stale Skip the default ff-first sync with origin/<default-branch> and build the current (possibly stale) checkout as-is (#4330) — for deliberate use: bisecting, testing a local patch
#   ./.loom/scripts/cli/loom-daemon-update.sh --help
#
# Environment:
#   LOOM_DAEMON_BIN       Path to the loom-daemon binary (else auto-detected,
#                          same resolution as loom-daemon-start.sh). When set,
#                          the fresh binary is provisioned directly to this
#                          exact path instead of the machine-level default.
#   LOOM_DAEMON_BIN_DIR   Machine-level install dir (default ~/.local/bin),
#                          forwarded to provision-daemon.sh.
#   LOOM_DAEMON_LAUNCHD    macOS only: 0/false/no disables ALL launchd interaction
#                          (ownership detection + launchd restart), symmetric with
#                          loom-daemon-start.sh / loom-daemon-stop.sh. A daemon
#                          started with --no-launchd / LOOM_DAEMON_LAUNCHD=0 gets
#                          an update that never reads the machine-global launchd
#                          domain and follows the PID-file/nohup restart path.
#   LOOM_LAUNCHD_LABEL     macOS only: the LaunchAgent label to inspect/restart
#                          (default com.rjwalters.loom-daemon).
#   LOOM_LAUNCHD_DOMAIN    macOS only: pin the launchd domain (gui/<uid> or
#                          user/<uid>); else auto-resolved gui→user (#4130),
#                          matching loom-daemon-start.sh / -stop.sh.
#   LOOM_DAEMON_SYSTEMD    Linux only: 0/false/no disables ALL systemd interaction
#                          (ownership detection + systemd restart), symmetric with
#                          loom-daemon-start.sh --no-systemd / loom-daemon-stop.sh
#                          (#4268). A daemon started with --no-systemd /
#                          LOOM_DAEMON_SYSTEMD=0 gets an update that never invokes
#                          systemctl and follows the PID-file/nohup restart path.
#   LOOM_SYSTEMD_UNIT      Linux only: the systemd --user unit to inspect/restart
#                          (default loom-daemon.service); must match the start's.
#   LOOM_DAEMON_UPDATE_RELAUNCH  Launchd/systemd only: 1/true/yes is equivalent to
#                          passing --relaunch (opt in to the re-render + relaunch
#                          on a refused restart).
#   LOOM_MACHINE_CHECKOUT  Machine mode (Epic #3835 Phase 3b, #4229): set by the
#                          `scripts/loom` dispatcher to the resolved
#                          ~/.local/share/loom checkout before it execs this
#                          script. When set, THIS is the source tree rebuilt
#                          from (overriding the $PWD-based find_repo_root()
#                          below), so `loom update` works from any directory --
#                          a consumer repo, or no repo at all -- instead of
#                          requiring $PWD to already be inside a Loom source
#                          checkout. Direct invocation of this script (no
#                          dispatcher -- the existing dev workflow) never sets
#                          it and is unaffected.
#   LOOM_DAEMON_RESTART_POLL_SECS  macOS/launchd only: seconds to poll for a
#                          NEW, live pid after a `restart` ack before falling
#                          back to `launchctl kickstart` (default 30, #4232).
#   LOOM_DAEMON_RESTART_POLL_INTERVAL  Poll interval in seconds between pid
#                          checks (default 1; may be fractional, e.g. 0.5).
#   LOOM_DAEMON_RESTART_KICKSTART_POLL_SECS  macOS/launchd only: seconds to
#                          re-poll for a new, live pid after the `launchctl
#                          kickstart` fallback before giving up (default 15,
#                          #4232).
#
# Exit codes:
#   0  up to date (no-op) OR rebuild+provision+restart succeeded
#   1  usage error / not a source checkout / build or provision failure /
#      the default ff-first sync with origin/<default-branch> could not apply
#      (diverged local commits, a dirty tracked file conflicting with the
#      incoming change, or HEAD is not on <default-branch>) — the script
#      NEVER guesses or hard-resets; resolve manually or pass --allow-stale
#      (#4330)
#   3  (--check only) update available
#   4  build verification FAILED: the freshly-built binary's embedded commit
#      does not match the source HEAD it was built from. This is a BUILD-SYSTEM
#      defect (a stale baked-in commit — e.g. a build.rs watch-set bug), NOT a
#      compile failure, and retrying cannot fix it; the script refuses to
#      provision the mis-stamped binary (#4053).
#   5  post-provision verification FAILED: the destination binary after a
#      claimed-successful provision is not the expected build (a silent no-op
#      roll — "reports success while shipping nothing"). Distinct from both a
#      compile failure and a provisioning soft-failure (#4053).
#   6  supervised restart FAILED: the daemon is launchd- or systemd-managed but
#      the running (old) binary refused the `loom-daemon restart` IPC request (a
#      pre-#4077/#4267 binary with no RestartDaemon handler, or a dead socket).
#      The fresh binary IS provisioned but the OLD one is still running; the
#      script refuses to report success. Without --relaunch it prints how to
#      re-render the plist/unit and relaunch under supervision, then exits 6;
#      with --relaunch (or LOOM_DAEMON_UPDATE_RELAUNCH=1) it performs that
#      re-render+relaunch itself, propagating loom-daemon-start.sh's exit code
#      (#4042, #4118, #4260 sub-issue C).
#   7  launchd restart ACK'd but never took effect (#4232): the running (old)
#      binary accepted the `restart` IPC request (exit 0), but launchd never
#      relaunched the job onto a NEW, live pid within the poll window, AND the
#      `launchctl kickstart` fallback (plain, never -k) also failed to bring it
#      up within its own poll window. The fresh binary IS provisioned, but the
#      daemon's live status is NOT confirmed — this is the "restart scheduled
#      but launchd silently never relaunched" outage this issue closes; the
#      script refuses to report success on the ack alone.
#
# See also: loom-daemon-start.sh (writes .loom/.daemon.flags), loom-daemon-stop.sh
# (SIGTERM -> grace -> SIGKILL; in-flight sweeps survive by design — this
# script relies on that: stopping+restarting the dispatcher never kills
# dispatched work), scripts/install/provision-daemon.sh (machine-level
# provisioning, #3922).

set -uo pipefail

# ---------- output helpers ----------
if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; NC=''
fi
err()  { echo -e "${RED}$*${NC}" >&2; }
warn() { echo -e "${YELLOW}$*${NC}" >&2; }
ok()   { echo -e "${GREEN}$*${NC}"; }

show_help() {
    # Print the leading comment banner (line 2 through the last comment line
    # before `set -uo pipefail`), stripping the leading "# ".
    awk 'NR>=2 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- repo root ----------
find_repo_root() {
    local dir="$PWD"
    while [[ "$dir" != "/" ]]; do
        if [[ -d "$dir/.loom" ]]; then echo "$dir"; return 0; fi
        if [[ -f "$dir/.git" ]]; then
            local gitdir main_repo
            gitdir=$(sed 's/^gitdir: //' "$dir/.git")
            main_repo=$(dirname "$(dirname "$(dirname "$gitdir")")")
            if [[ -d "$main_repo/.loom" ]]; then echo "$main_repo"; return 0; fi
        fi
        dir="$(dirname "$dir")"
    done
    echo ""
}

# ---------- locate the daemon binary (mirrors loom-daemon-start.sh) ----------
locate_daemon_bin() {
    local root="$1"
    if [[ -n "${LOOM_DAEMON_BIN:-}" && -x "${LOOM_DAEMON_BIN}" ]]; then
        echo "${LOOM_DAEMON_BIN}"; return 0
    fi
    if command -v loom-daemon >/dev/null 2>&1; then
        command -v loom-daemon; return 0
    fi
    local candidate
    for candidate in \
        "$root/loom-daemon/target/release/loom-daemon" \
        "$root/loom-daemon/target/debug/loom-daemon" \
        "$root/target/release/loom-daemon" \
        "$root/target/debug/loom-daemon"; do
        if [[ -x "$candidate" ]]; then echo "$candidate"; return 0; fi
    done
    echo ""
}

# Extract the short commit from `loom-daemon --version` output, e.g.
# "loom-daemon 0.15.0 (commit ab12cd3, built 2026-07-26T12:00:00Z)" -> ab12cd3
extract_commit() {
    echo "$1" | grep -oE 'commit [0-9a-f]+' | head -n1 | awk '{print $2}'
}

# verify_destination_binary <dest_path> — assert the provisioned binary at
# <dest_path> embeds the expected source-HEAD commit (#4053). This is the
# direct answer to "reports success while shipping nothing": after a provision
# step returns success, the destination must actually be the freshly-built
# binary. Exits 5 on mismatch — distinguishable from a compile failure (exit 1)
# and from a provisioning soft-failure. Skipped only when the source HEAD is
# unknown (a tarball build with no .git), where there is nothing to compare
# against. Relies on $SOURCE_COMMIT being resolved (it is, before any build).
verify_destination_binary() {
    local dest="$1"
    if [[ "$SOURCE_COMMIT" == "unknown" ]]; then
        warn "Source HEAD is unknown (no .git?) — skipping post-provision verification."
        return 0
    fi
    if [[ -z "$dest" || ! -x "$dest" ]]; then
        err "Post-provision verification FAILED: provisioning reported success but no executable binary was found at the destination ('${dest:-<unknown>}')."
        exit 5
    fi
    local dest_version dest_commit
    dest_version=$("$dest" --version 2>/dev/null || true)
    dest_commit=$(extract_commit "$dest_version")
    if [[ "$dest_commit" != "$SOURCE_COMMIT" ]]; then
        err "Post-provision verification FAILED: destination binary at $dest embeds commit '${dest_commit:-<none>}' but the expected source HEAD is '$SOURCE_COMMIT'."
        err "Provisioning reported success yet the destination is NOT the freshly-built binary — a silent no-op roll. This is distinct from a compile failure and from a provisioning soft-failure; refusing to report success."
        exit 5
    fi
    ok "Post-provision verification: destination binary at $dest embeds source HEAD commit ($dest_commit)."
}

# ---------- args ----------
DRY_RUN=false
FORCE=false
CHECK_ONLY=false
NO_RESTART=false
RELAUNCH=false
ALLOW_STALE=false
[[ "${LOOM_DAEMON_UPDATE_RELAUNCH:-}" =~ ^(1|true|yes)$ ]] && RELAUNCH=true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h) show_help; exit 0 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --force) FORCE=true; shift ;;
        --check) CHECK_ONLY=true; shift ;;
        --no-restart) NO_RESTART=true; shift ;;
        --relaunch) RELAUNCH=true; shift ;;
        --allow-stale) ALLOW_STALE=true; shift ;;
        *) err "Unknown option '$1'"; echo "Use --help for usage" >&2; exit 1 ;;
    esac
done

REPO_ROOT=$(find_repo_root)

# ---------- machine-mode source-tree override (Epic #3835 Phase 3b, #4229) --
# Gap 1: this script rebuilds FROM SOURCE and used to resolve that source tree
# by walking up from $PWD -- so from a consumer repo (find_repo_root() finds
# the consumer repo, which has no loom-daemon/Cargo.toml) or a non-repo
# directory (find_repo_root() finds nothing) it refused with "only works
# inside a Loom source checkout", even though the `scripts/loom` dispatcher
# had ALREADY resolved+validated the machine checkout before exec'ing here.
# LOOM_MACHINE_CHECKOUT overrides the $PWD-derived REPO_ROOT with that
# checkout, so `loom update` rebuilds it from any directory. Direct invocation
# of this script (no dispatcher) never sets it and is unaffected -- the
# pre-#4229 $PWD-based contract is the fallback below.
MACHINE_CHECKOUT="${LOOM_MACHINE_CHECKOUT:-}"
if [[ -n "$MACHINE_CHECKOUT" ]]; then
    if [[ ! -d "$MACHINE_CHECKOUT" ]]; then
        err "LOOM_MACHINE_CHECKOUT does not exist: $MACHINE_CHECKOUT"
        exit 1
    fi
    REPO_ROOT="$MACHINE_CHECKOUT"
    DAEMON_STATE_HOME="$HOME/.loom"
elif [[ -n "$REPO_ROOT" ]]; then
    DAEMON_STATE_HOME="$REPO_ROOT/.loom"
else
    err "Not in a Loom workspace (.loom directory not found)"
    exit 1
fi

DAEMON_DIR="$REPO_ROOT/loom-daemon"
if [[ ! -f "$DAEMON_DIR/Cargo.toml" ]]; then
    err "No loom-daemon/Cargo.toml found at $DAEMON_DIR."
    echo "loom-daemon-update.sh rebuilds FROM SOURCE and only works inside a Loom source checkout." >&2
    exit 1
fi

# Resolve a lifecycle script under REPO_ROOT: the INSTALLED copy first (a
# self-hosted checkout's own .loom/scripts/cli/, kept in sync by
# resync-installed.sh), falling back to defaults/scripts/cli/ -- the shipped
# source of truth every Loom source checkout has, including a fresh clone that
# has never been "installed" onto itself (machine mode may point at exactly
# that). Direct (non-machine) invocation almost always resolves the first
# candidate, matching pre-#4229 behavior byte-for-byte.
resolve_lifecycle_script() {
    local rel="$1" candidate
    for candidate in \
        "$REPO_ROOT/.loom/scripts/cli/$rel" \
        "$REPO_ROOT/defaults/scripts/cli/$rel"; do
        if [[ -x "$candidate" ]]; then echo "$candidate"; return 0; fi
    done
    echo ""
}

PID_FILE="$DAEMON_STATE_HOME/.daemon.pid"
FLAGS_FILE="$DAEMON_STATE_HOME/.daemon.flags"
START_SCRIPT="$(resolve_lifecycle_script loom-daemon-start.sh)"
STOP_SCRIPT="$(resolve_lifecycle_script loom-daemon-stop.sh)"
if [[ -z "$START_SCRIPT" || -z "$STOP_SCRIPT" ]]; then
    err "Could not resolve loom-daemon-start.sh / loom-daemon-stop.sh under $REPO_ROOT (.loom/scripts/cli or defaults/scripts/cli)."
    exit 1
fi

# ---------- sync with origin/<default-branch> (ff-first default, #4330) ----------
# Runs BEFORE the staleness detection below resolves SOURCE_COMMIT, so a
# successful ff-sync is reflected in the rebuild decision (rebuilding the
# freshly-synced HEAD, not the pre-merge one). Never touches the network or
# the tree in --check / --dry-run (both are documented "no writes" contracts)
# or under --allow-stale (today's build-what's-here behavior) — those paths
# fall through to the read-only advisory branch below instead.
#
# Globals set for downstream consumers (staleness echo + the final
# "installed" summary, AC4):
#   DEFAULT_BRANCH        resolved default branch name, or "" if unresolvable
#   ORIGIN_COMMIT         short commit of origin/<DEFAULT_BRANCH> at fetch
#                         time, or "unknown" if unreachable/unresolvable
#   ORIGIN_BEHIND_COUNT   commits local <DEFAULT_BRANCH> was behind origin
#                         BEFORE any sync (0 if unknown or already current)
#   FF_SYNCED             true if this run fast-forwarded local HEAD
DEFAULT_BRANCH=""
ORIGIN_COMMIT="unknown"
ORIGIN_BEHIND_COUNT=0
FF_SYNCED=false

sync_with_origin() {
    local repo_root="$1"
    # shellcheck disable=SC1091
    if [[ -r "$SCRIPT_DIR/../lib/default-branch.sh" ]]; then
        source "$SCRIPT_DIR/../lib/default-branch.sh" 2>/dev/null || return 0
    else
        return 0
    fi
    declare -F loom_default_branch >/dev/null 2>&1 || return 0
    DEFAULT_BRANCH="$(cd "$repo_root" && loom_default_branch origin 2>/dev/null)" || { DEFAULT_BRANCH=""; return 0; }
    [[ -z "$DEFAULT_BRANCH" ]] && return 0

    # Bounded, best-effort fetch — a fetch failure/timeout must NOT make this
    # script network-dependent: warn and proceed with local HEAD as-is (behind
    # count stays unknown, not "known stale").
    local fetch_ok=true
    if command -v timeout >/dev/null 2>&1; then
        (cd "$repo_root" && timeout 5 git fetch origin "$DEFAULT_BRANCH" --quiet >/dev/null 2>&1) || fetch_ok=false
    else
        (cd "$repo_root" && git fetch origin "$DEFAULT_BRANCH" --quiet >/dev/null 2>&1) || fetch_ok=false
    fi
    if [[ "$fetch_ok" == "false" ]]; then
        warn "note: could not reach origin to check ${DEFAULT_BRANCH} for updates (fetch failed or timed out) — proceeding with local HEAD as-is."
        return 0
    fi

    ORIGIN_COMMIT="$(cd "$repo_root" && git rev-parse --short "origin/${DEFAULT_BRANCH}" 2>/dev/null || echo "unknown")"

    local n
    n="$(cd "$repo_root" && git rev-list --count "${DEFAULT_BRANCH}..origin/${DEFAULT_BRANCH}" 2>/dev/null || echo 0)"
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    ORIGIN_BEHIND_COUNT="$n"
    [[ "$n" -eq 0 ]] && return 0

    # Read-only modes and --allow-stale never write — just advise, mirroring
    # the pre-#4330 advisory-only behavior.
    if [[ "$CHECK_ONLY" == "true" || "$DRY_RUN" == "true" ]]; then
        warn "note: local ${DEFAULT_BRANCH} is ${n} commit(s) behind origin/${DEFAULT_BRANCH}."
        return 0
    fi
    if [[ "$ALLOW_STALE" == "true" ]]; then
        warn "note: local ${DEFAULT_BRANCH} is ${n} commit(s) behind origin/${DEFAULT_BRANCH} — building the current (stale) checkout as-is per --allow-stale."
        return 0
    fi

    # Default: attempt the ff-sync. Only well-defined when HEAD IS the default
    # branch — on a feature branch or detached HEAD, `git merge --ff-only
    # origin/<default>` would merge into the WRONG ref, so refuse instead of
    # guessing (an operator deliberately elsewhere, e.g. bisecting, is exactly
    # the --allow-stale use case).
    local current_branch
    current_branch="$(cd "$repo_root" && git symbolic-ref --short HEAD 2>/dev/null || true)"
    if [[ "$current_branch" != "$DEFAULT_BRANCH" ]]; then
        err "Local ${DEFAULT_BRANCH} is ${n} commit(s) behind origin/${DEFAULT_BRANCH}, but the checkout HEAD is on '${current_branch:-<detached HEAD>}', not '${DEFAULT_BRANCH}' — refusing to guess which branch to sync."
        err "Check out ${DEFAULT_BRANCH} and re-run, or pass --allow-stale to build the current checkout as-is (e.g. bisecting, testing a local patch)."
        return 1
    fi

    echo "Local ${DEFAULT_BRANCH} is ${n} commit(s) behind origin/${DEFAULT_BRANCH} — fast-forwarding before building (default; pass --allow-stale to build the current checkout as-is)..."
    if ! (cd "$repo_root" && git merge --ff-only "origin/${DEFAULT_BRANCH}" --quiet); then
        err "Fast-forward merge from origin/${DEFAULT_BRANCH} did not apply — local commits have diverged, or a dirty tracked file conflicts with the incoming change."
        err "Refusing to guess or hard-reset: resolve manually (rebase/merge by hand), or pass --allow-stale to build the current (stale) checkout as-is."
        return 1
    fi
    ok "Fast-forwarded local ${DEFAULT_BRANCH} to origin/${DEFAULT_BRANCH} (${n} commit(s))."
    FF_SYNCED=true
    return 0
}
if ! sync_with_origin "$REPO_ROOT"; then
    exit 1
fi

# ---------- staleness detection ----------
DAEMON_BIN=$(locate_daemon_bin "$REPO_ROOT")

INSTALLED_COMMIT="unknown"
if [[ -n "$DAEMON_BIN" && -x "$DAEMON_BIN" ]]; then
    installed_version_output=$("$DAEMON_BIN" --version 2>/dev/null || true)
    extracted=$(extract_commit "$installed_version_output")
    [[ -n "$extracted" ]] && INSTALLED_COMMIT="$extracted"
fi

SOURCE_COMMIT=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")

echo "Installed binary: ${DAEMON_BIN:-<none found>} (commit ${INSTALLED_COMMIT})"
echo "Source tree HEAD:  ${SOURCE_COMMIT}"
if [[ -n "$MACHINE_CHECKOUT" ]]; then
    echo "Source tree:       $REPO_ROOT (machine checkout, LOOM_MACHINE_CHECKOUT)"
fi
if [[ "$FF_SYNCED" == "true" ]]; then
    echo "Source tree:       fast-forwarded to origin/${DEFAULT_BRANCH} before this run (#4330)."
fi

UPDATE_NEEDED=false
if [[ -z "$DAEMON_BIN" ]]; then
    echo "No loom-daemon binary currently resolvable (LOOM_DAEMON_BIN / PATH / loom-daemon/target/release) — a build is needed."
    UPDATE_NEEDED=true
elif [[ "$INSTALLED_COMMIT" == "unknown" || "$SOURCE_COMMIT" == "unknown" ]]; then
    warn "Could not determine one or both commits (installed=$INSTALLED_COMMIT, source=$SOURCE_COMMIT) — staleness unknown; treating as needing a rebuild to be safe."
    UPDATE_NEEDED=true
elif [[ "$INSTALLED_COMMIT" != "$SOURCE_COMMIT" ]]; then
    UPDATE_NEEDED=true
fi

# print_final_installed_line <commit> — the AC4 "final installed line": states
# the built/installed commit AND whether it matches origin/<default-branch> at
# build time. Uses ORIGIN_COMMIT resolved by sync_with_origin above (no
# re-fetch). Prints an honest "unknown" comparison when the default branch or
# origin commit could not be resolved (offline, no origin remote, etc.) rather
# than silently omitting the currency claim.
print_final_installed_line() {
    local commit="$1"
    if [[ -z "$DEFAULT_BRANCH" || "$ORIGIN_COMMIT" == "unknown" ]]; then
        echo "Installed: ${commit} (currency vs origin/<default-branch> unknown — unresolvable or unreachable)"
    elif [[ "$commit" == "$ORIGIN_COMMIT" ]]; then
        echo "Installed: ${commit} (matches origin/${DEFAULT_BRANCH})"
    else
        echo "Installed: ${commit} (origin/${DEFAULT_BRANCH} is at ${ORIGIN_COMMIT} — does NOT match; built from a checkout that was behind or diverged, e.g. --allow-stale)"
    fi
}

# ---------- launchd ownership detection (macOS, mirrors loom-daemon-stop.sh #4042) ----------
# launchd is checked AHEAD of the .loom/.daemon.pid tier because the plist's
# KeepAlive:SuccessfulExit assigns a FRESH pid on every supervised relaunch, so
# the pid file goes stale after the first relaunch even for a launchd job that
# loom-daemon-start.sh itself started; a hand-bootstrapped daemon has no state
# files at all. Honors LOOM_DAEMON_LAUNCHD symmetrically with start/stop.sh so a
# --no-launchd install never reaches into the machine-global launchd domain.
# Shared domain resolver (#4130): gui/<uid> ↦ user/<uid>, sourced verbatim so
# update agrees with the domain the start put the job in.
_LOOM_LAUNCHD_LIB_DIR="$(cd "$SCRIPT_DIR/../lib" 2>/dev/null && pwd)"
if [[ -r "$_LOOM_LAUNCHD_LIB_DIR/launchd-domain.sh" ]]; then
    # shellcheck source=../lib/launchd-domain.sh
    source "$_LOOM_LAUNCHD_LIB_DIR/launchd-domain.sh"
fi

IS_DARWIN=false
[[ "$(uname -s)" == "Darwin" ]] && IS_DARWIN=true
USE_LAUNCHD="$IS_DARWIN"
if [[ "${LOOM_DAEMON_LAUNCHD:-}" =~ ^(0|false|no)$ ]]; then
    USE_LAUNCHD=false
fi
DEFAULT_LAUNCHD_LABEL="com.rjwalters.loom-daemon"
LAUNCHD_LABEL="${LOOM_LAUNCHD_LABEL:-$DEFAULT_LAUNCHD_LABEL}"
# Resolve the domain ONLY when launchd interaction is on (#4130): probing
# `launchctl print gui/<uid>` when LOOM_DAEMON_LAUNCHD=0 would reach the
# machine-global launchd domain the disabled path must never touch (#4078). The
# placeholder is inert — launchd_job_loaded and the launchd restart path all
# short-circuit on USE_LAUNCHD, so it is never consumed when launchd is off.
if [[ "$USE_LAUNCHD" == "true" ]]; then
    LAUNCHD_SERVICE="$(resolve_launchd_domain)/${LAUNCHD_LABEL}"
else
    LAUNCHD_SERVICE="/${LAUNCHD_LABEL}"
fi
LAUNCHD_PLIST="$HOME/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"

launchd_job_loaded() {
    [[ "$USE_LAUNCHD" == "true" ]] || return 1
    command -v launchctl >/dev/null 2>&1 || return 1
    launchctl print "$LAUNCHD_SERVICE" >/dev/null 2>&1
}
launchd_job_pid() {
    launchctl print "$LAUNCHD_SERVICE" 2>/dev/null | awk -F'= ' '/^[[:space:]]*pid = /{gsub(/[^0-9]/, "", $2); print $2; exit}'
}

# ---------- systemd --user ownership detection (Linux, #4260 sub-issue C) ----------
# The Linux mirror of the launchd tier just above, checked at the SAME level
# (ahead of the pid-file tier): a `systemd --user` unit's pid also goes stale on
# every `Restart=on-success` relaunch (loom-daemon-start.sh #4268), so the pid
# file alone cannot answer "is it running, and how". Honors LOOM_DAEMON_SYSTEMD
# symmetrically with loom-daemon-start.sh --no-systemd / loom-daemon-stop.sh: a
# --no-systemd install must never invoke systemctl at all. Shared resolver
# (lib/systemd-user.sh, #4268) sourced verbatim so update agrees with the unit
# name start/stop resolve.
_LOOM_SYSTEMD_LIB_DIR="$(cd "$SCRIPT_DIR/../lib" 2>/dev/null && pwd)"
if [[ -r "$_LOOM_SYSTEMD_LIB_DIR/systemd-user.sh" ]]; then
    # shellcheck source=../lib/systemd-user.sh
    source "$_LOOM_SYSTEMD_LIB_DIR/systemd-user.sh"
fi

IS_LINUX_SYSTEMD=false
if ! [[ "${LOOM_DAEMON_SYSTEMD:-}" =~ ^(0|false|no)$ ]] \
    && declare -f is_linux_systemd >/dev/null 2>&1 && is_linux_systemd; then
    IS_LINUX_SYSTEMD=true
fi

# Resolved ONLY when systemd interaction is on -- mirrors the launchd guard just
# above; these calls are inert placeholders otherwise since every systemd
# function below short-circuits on IS_LINUX_SYSTEMD.
if [[ "$IS_LINUX_SYSTEMD" == "true" ]]; then
    SYSTEMD_UNIT="$(resolve_systemd_unit)"
    SYSTEMD_UNIT_PATH="$(resolve_systemd_unit_path)"
else
    SYSTEMD_UNIT="${LOOM_SYSTEMD_UNIT:-loom-daemon.service}"
    SYSTEMD_UNIT_PATH=""
fi

systemd_unit_loaded() {
    [[ "$IS_LINUX_SYSTEMD" == "true" ]] || return 1
    command -v systemctl >/dev/null 2>&1 || return 1
    systemctl --user is-active --quiet "$SYSTEMD_UNIT" 2>/dev/null \
        || systemctl --user is-enabled --quiet "$SYSTEMD_UNIT" 2>/dev/null
}
systemd_unit_pid() {
    systemctl --user show -p MainPID --value "$SYSTEMD_UNIT" 2>/dev/null
}

# ---------- verify a launchd restart actually relaunched the job (#4232) ----------
# THE PROBLEM: the launchd branch below used to treat a successful `restart`
# ack (the RUNNING binary accepting the IPC request, exit 0) as success and
# exit 0 immediately — fire-and-forget. On 2026-07-28 that ack was honest (the
# supervised daemon exited 0 per its #4054 contract) but launchd's own
# KeepAlive:SuccessfulExit relaunch never fired, so the script reported success
# while the daemon silently stayed down for ~4 minutes until an operator ran
# `launchctl kickstart` by hand. This closes that gap: verify a NEW pid before
# reporting success, and self-heal via `kickstart` when launchd doesn't.
#
# wait_for_new_launchd_pid <pre_pid> <timeout_secs> <interval_secs> — poll
# `launchd_job_pid` until it reports a pid that is BOTH different from
# <pre_pid> AND alive (`kill -0`), for up to <timeout_secs>. A pid that merely
# differs but is already dead (a race artifact) — or that still equals
# <pre_pid> (the old process lingering mid-teardown during the poll window) —
# must NEVER be mistaken for a successful relaunch. On success, echoes the new
# pid on stdout and returns 0; on timeout, returns 1 with no output.
# <interval_secs> may be fractional (e.g. 0.2), matching `sleep`'s own support.
wait_for_new_launchd_pid() {
    local pre_pid="$1" timeout_secs="$2" interval_secs="$3"
    local deadline cur_pid
    deadline=$(( $(date +%s) + timeout_secs ))
    while true; do
        cur_pid="$(launchd_job_pid)"
        if [[ -n "$cur_pid" && "$cur_pid" != "$pre_pid" ]] && kill -0 "$cur_pid" 2>/dev/null; then
            echo "$cur_pid"
            return 0
        fi
        if (( $(date +%s) >= deadline )); then
            return 1
        fi
        sleep "$interval_secs"
    done
}

# log_launchd_diagnostics — dump `launchctl print`'s current state as a
# diagnostic breadcrumb (state / last exit status) when a relaunch cannot be
# verified, so an operator (or the PR/issue this failure is reported to) has
# the exact evidence needed to tell "launchd never relaunched" apart from "the
# daemon crashed immediately after relaunching" (#4232).
log_launchd_diagnostics() {
    warn "launchctl print $LAUNCHD_SERVICE diagnostic snapshot:"
    local line
    while IFS= read -r line; do
        warn "  $line"
    done < <(launchctl print "$LAUNCHD_SERVICE" 2>&1)
}

# ---------- re-render + relaunch on a refused restart (#4118) ----------
# The exit-6 fallback USED to tell the operator to `launchctl bootstrap` the
# EXISTING plist. That plist is stale by construction (it is the pre-#4077 file
# that caused the refused restart) — bootstrapping it relaunches WITHOUT
# KeepAlive:SuccessfulExit and WITHOUT LOOM_DAEMON_SUPERVISOR, so the next roll
# refuses identically, forever; and its `launchctl bootout` tears down the whole
# job tree, killing in-flight sweeps (they are direct children of the launchd
# job). The correct fix is to RE-RENDER the plist via loom-daemon-start.sh (which
# hardcodes the two supervised keys), preserving the live plist's autonomy/auth
# env, and to stop the old daemon gracefully so sweep children reparent.

# harvest_plist_env <plist> — echo the live plist's EnvironmentVariables,
# restricted to exactly the keys render_launchd_plist itself forwards (LOOM_*,
# GH_TOKEN, GITEA_TOKEN, FORGE_TOKEN) and EXCLUDING:
#   - PATH / HOME     (start.sh resolves PATH deterministically -- a pinned
#                      canonical minimal PATH by default, or an explicit
#                      LOOM_DAEMON_PATH / LOOM_DAEMON_PATH_EXTRA override,
#                      #4172; round-tripping the plist's PATH here would
#                      re-introduce the non-deterministic-render bug),
#   - LOOM_DAEMON_SUPERVISOR (start.sh hardcodes it; re-exporting is pointless).
# Emits one "<key>\t<base64(value)>" line per key so values containing spaces or
# newlines survive. Fails loudly (return 2) when the plist is absent or
# unparseable — it must NEVER silently return an empty set, which would let the
# re-render narrow the autonomy flags to FLAGS-OFF defaults (the #4011 class).
harvest_plist_env() {
    local plist="$1"
    if [[ ! -f "$plist" ]]; then
        err "Cannot harvest launchd env: plist not found at $plist"
        return 2
    fi
    if ! command -v plutil >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        err "Cannot harvest launchd env: plutil and jq are both required on the macOS launchd path."
        return 2
    fi
    local json
    json=$(plutil -convert json -o - "$plist" 2>/dev/null) || {
        err "Cannot harvest launchd env: plist at $plist is not parseable by plutil."
        return 2
    }
    printf '%s' "$json" | jq -r '
        .EnvironmentVariables // {}
        | to_entries[]
        | select(.key | test("^(LOOM_[A-Za-z0-9_]*|GH_TOKEN|GITEA_TOKEN|FORGE_TOKEN)$"))
        | select(.key != "LOOM_DAEMON_SUPERVISOR")
        | .key + "\t" + (.value | @base64)
    ' 2>/dev/null || {
        err "Cannot harvest launchd env: failed to extract EnvironmentVariables from $plist."
        return 2
    }
}

# perform_relaunch <plist> <service> — re-render the LaunchAgent and relaunch it
# under launchd supervision, preserving the live plist's autonomy/auth env.
# Invoked ONLY from the exit-6 fallback when the operator opted in (--relaunch /
# LOOM_DAEMON_UPDATE_RELAUNCH=1), so the sweep-disrupting relaunch is a consented
# action, never silent. Returns loom-daemon-start.sh's exit code (or 6 if the env
# harvest fails — refusing to relaunch into a silently-narrowed env).
perform_relaunch() {
    local plist="$1"
    echo "--relaunch: re-rendering the LaunchAgent and relaunching under launchd supervision."

    # 1. Preserve the live plist's autonomy/auth env across the re-render.
    local harvested
    if ! harvested=$(harvest_plist_env "$plist"); then
        err "Refusing to relaunch: could not read the live plist's EnvironmentVariables."
        err "Relaunching now would silently narrow the autonomy flags to FLAGS-OFF defaults (#4011) — aborting."
        return 6
    fi
    local k v64 count=0
    while IFS=$'\t' read -r k v64; do
        [[ -z "$k" ]] && continue
        export "$k=$(printf '%s' "$v64" | base64 --decode)"
        count=$((count + 1))
    done <<< "$harvested"
    echo "Preserved ${count} LOOM_*/token env var(s) from the live plist across the re-render (PATH/HOME/LOOM_DAEMON_SUPERVISOR excluded by design)."

    # 2. Stop the old daemon GRACEFULLY so its sweep children reparent and keep
    #    working, instead of `launchctl bootout` tearing down the whole job tree.
    #    kill -TERM makes the daemon exit non-zero, so the stale plist's
    #    KeepAlive=false does not relaunch it — start.sh below installs the fresh,
    #    supervised plist and bootstraps the new process.
    local daemon_pid
    daemon_pid=$(launchd_job_pid)
    if [[ -n "$daemon_pid" ]] && kill -0 "$daemon_pid" 2>/dev/null; then
        echo "Sending SIGTERM to the running daemon (pid ${daemon_pid}) — sweep children reparent and keep working (NOT bootout, which would kill them)."
        kill -TERM "$daemon_pid" 2>/dev/null || true
        local _waited
        for _waited in 1 2 3 4 5; do
            kill -0 "$daemon_pid" 2>/dev/null || break
            sleep 1
        done
    fi

    # 3. Re-render + bootstrap via loom-daemon-start.sh. It hardcodes
    #    KeepAlive:{SuccessfulExit:true} + LOOM_DAEMON_SUPERVISOR=launchd, and
    #    harvests the LOOM_* env we just re-exported. In launchd mode the plist's
    #    EnvironmentVariables — not .daemon.flags — is the durable config, so no
    #    flags are passed here.
    echo "Invoking ${START_SCRIPT} to re-render the supervised plist and relaunch."
    "$START_SCRIPT"
}

# harvest_unit_env <unit_path> — echo the live systemd unit's `Environment=`
# lines, restricted to exactly the keys render_systemd_unit itself forwards
# (LOOM_*, GH_TOKEN, GITEA_TOKEN, FORGE_TOKEN) and EXCLUDING:
#   - PATH / HOME     (start.sh resolves PATH deterministically, mirroring the
#                      launchd plist path — round-tripping the unit's PATH here
#                      would re-introduce the non-deterministic-render bug),
#   - LOOM_DAEMON_SUPERVISOR (start.sh hardcodes it; re-exporting is pointless).
# Emits one "<key>\t<value>" line per key (a systemd `Environment=KEY=VALUE`
# line is single-valued, unlike the plist's XML dict, so no base64 round-trip is
# needed here). Fails loudly (return 2) when the unit file is absent — it must
# NEVER silently return an empty set, which would let the re-render narrow the
# autonomy flags to FLAGS-OFF defaults (the #4011 class).
harvest_unit_env() {
    local unit_path="$1"
    if [[ ! -f "$unit_path" ]]; then
        err "Cannot harvest systemd unit env: unit file not found at $unit_path"
        return 2
    fi
    local line rest key value
    while IFS= read -r line; do
        [[ "$line" == Environment=* ]] || continue
        rest="${line#Environment=}"
        key="${rest%%=*}"
        value="${rest#*=}"
        case "$key" in
            LOOM_DAEMON_SUPERVISOR) continue ;;
            LOOM_*|GH_TOKEN|GITEA_TOKEN|FORGE_TOKEN) printf '%s\t%s\n' "$key" "$value" ;;
            *) continue ;;
        esac
    done < "$unit_path"
}

# perform_systemd_relaunch <unit_path> <unit> — re-render the systemd --user
# unit and relaunch it under supervision, preserving the live unit's
# autonomy/auth env. The systemd mirror of perform_relaunch above. Invoked ONLY
# from the exit-6 fallback when the operator opted in (--relaunch /
# LOOM_DAEMON_UPDATE_RELAUNCH=1). Returns loom-daemon-start.sh's exit code (or 6
# if the env harvest fails — refusing to relaunch into a silently-narrowed env).
#
# Note on "systemctl --user restart": re-rendering the unit file alone does not
# make an ALREADY-ACTIVE unit pick up the new binary/env -- `enable --now` on an
# active unit is a no-op start, not a restart. So this SIGTERMs the running
# daemon first (Restart=on-success does not fire on a signal death, mirroring
# launchd's KeepAlive:SuccessfulExit), leaving the unit inactive, and THEN
# invokes loom-daemon-start.sh to re-render + `enable --now` it -- which, against
# an inactive unit, genuinely starts a fresh process. This achieves the same
# effect as `systemctl --user restart <unit>` while reusing render_systemd_unit
# rather than duplicating it here.
perform_systemd_relaunch() {
    local unit_path="$1" unit="$2"
    echo "--relaunch: re-rendering the systemd --user unit ${unit} and relaunching under supervision."

    # 1. Preserve the live unit's autonomy/auth env across the re-render.
    local harvested
    if ! harvested=$(harvest_unit_env "$unit_path"); then
        err "Refusing to relaunch: could not read the live unit's Environment= values."
        err "Relaunching now would silently narrow the autonomy flags to FLAGS-OFF defaults (#4011) — aborting."
        return 6
    fi
    local k v count=0
    while IFS=$'\t' read -r k v; do
        [[ -z "$k" ]] && continue
        export "$k=$v"
        count=$((count + 1))
    done <<< "$harvested"
    echo "Preserved ${count} LOOM_*/token env var(s) from the live unit across the re-render (PATH/HOME/LOOM_DAEMON_SUPERVISOR excluded by design)."

    # 2. Stop the old daemon GRACEFULLY so its sweep children reparent and keep
    #    working, instead of `systemctl stop` (which SIGKILLs the whole cgroup
    #    after TimeoutStopSec, tearing down sweep children the same way a
    #    launchd bootout would). kill -TERM makes the daemon exit by signal, so
    #    Restart=on-success does not relaunch it -- start.sh below installs the
    #    fresh, supervised unit and enables + starts the new process.
    local daemon_pid
    daemon_pid=$(systemd_unit_pid)
    if [[ -n "$daemon_pid" && "$daemon_pid" != "0" ]] && kill -0 "$daemon_pid" 2>/dev/null; then
        echo "Sending SIGTERM to the running daemon (pid ${daemon_pid}) — sweep children reparent and keep working (NOT 'systemctl stop', which tears down the whole cgroup)."
        kill -TERM "$daemon_pid" 2>/dev/null || true
        local _waited
        for _waited in 1 2 3 4 5; do
            kill -0 "$daemon_pid" 2>/dev/null || break
            sleep 1
        done
    fi

    # 3. Re-render + enable via loom-daemon-start.sh. It hardcodes
    #    Restart=on-success + LOOM_DAEMON_SUPERVISOR=systemd, and harvests the
    #    LOOM_* env we just re-exported. In systemd mode the unit's
    #    Environment= lines — not .daemon.flags — are the durable config, so no
    #    flags are passed here.
    echo "Invoking ${START_SCRIPT} to re-render the supervised unit and relaunch."
    "$START_SCRIPT"
}

# Resolve which manager owns the running daemon: launchd, then systemd (both
# checked ahead of the pid-file tier -- their pids go stale on every supervised
# relaunch), then the .loom/.daemon.pid file (nohup/script-managed), or none.
# WAS_RUNNING is derived from this — a launchd- or systemd-loaded job counts as
# running regardless of pid-file state.
DAEMON_MANAGER="none"
WAS_RUNNING=false
if launchd_job_loaded; then
    DAEMON_MANAGER="launchd"
    WAS_RUNNING=true
elif systemd_unit_loaded; then
    DAEMON_MANAGER="systemd"
    WAS_RUNNING=true
elif [[ -f "$PID_FILE" ]]; then
    existing_pid=$(cat "$PID_FILE" 2>/dev/null || true)
    if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
        DAEMON_MANAGER="pidfile"
        WAS_RUNNING=true
    fi
fi

describe_manager() {
    case "$DAEMON_MANAGER" in
        launchd) echo "Running daemon manager: launchd (label ${LAUNCHD_LABEL})." ;;
        systemd) echo "Running daemon manager: systemd --user (unit ${SYSTEMD_UNIT})." ;;
        pidfile) echo "Running daemon manager: PID-file/nohup (.loom/.daemon.pid)." ;;
        *)       echo "Running daemon manager: not running." ;;
    esac
}

# ---------- --check: report only, no writes ----------
if [[ "$CHECK_ONLY" == "true" ]]; then
    describe_manager
    if [[ "$UPDATE_NEEDED" == "true" ]]; then
        warn "Update available (installed=${INSTALLED_COMMIT}, source=${SOURCE_COMMIT})."
        exit 3
    fi
    ok "loom-daemon binary is already up to date with source HEAD (${SOURCE_COMMIT})."
    print_final_installed_line "$SOURCE_COMMIT"
    exit 0
fi

if [[ "$FORCE" == "true" && "$UPDATE_NEEDED" == "false" ]]; then
    echo "--force given: rebuilding even though the binary already matches source HEAD."
    UPDATE_NEEDED=true
fi

if [[ "$UPDATE_NEEDED" == "false" ]]; then
    ok "loom-daemon binary is already up to date with source HEAD (${SOURCE_COMMIT}). Nothing to do."
    print_final_installed_line "$SOURCE_COMMIT"
    exit 0
fi

# ---------- resolve the restart plan up front (read-only; safe for --dry-run) ----------
# WAS_RUNNING + DAEMON_MANAGER were resolved above (launchd checked ahead of the
# pid file). The flags below are only consulted for the pid-file/nohup restart
# path — a launchd-managed restart replays flags from the plist, not this file.
RESTART_ARGS=()
FLAGS_SOURCE="none (defaulting to FLAGS-OFF bare restart)"
if [[ -f "$FLAGS_FILE" ]]; then
    FLAGS_SOURCE="$FLAGS_FILE"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        RESTART_ARGS+=("$line")
    done < "$FLAGS_FILE"
fi

DEST_DIR="${LOOM_DAEMON_BIN_DIR:-$HOME/.local/bin}"
PROVISION_TARGET="${LOOM_DAEMON_BIN:-$DEST_DIR/loom-daemon}"

if [[ "$DRY_RUN" == "true" ]]; then
    echo
    if [[ "$ALLOW_STALE" == "true" ]]; then
        echo "[dry-run] --allow-stale given: would build the current checkout as-is (no fetch/ff-merge)."
    elif [[ -n "$DEFAULT_BRANCH" && "$ORIGIN_BEHIND_COUNT" -gt 0 ]]; then
        echo "[dry-run] Plan includes fast-forwarding local ${DEFAULT_BRANCH} to origin/${DEFAULT_BRANCH} (${ORIGIN_BEHIND_COUNT} commit(s) behind) before building; would abort instead of building stale if the ff-merge cannot apply."
    fi
    echo "[dry-run] Would run: (cd $DAEMON_DIR && cargo build --release)"
    echo "[dry-run] Would provision the fresh binary to: $PROVISION_TARGET"
    if [[ "$NO_RESTART" == "true" ]]; then
        echo "[dry-run] --no-restart given: would leave the running daemon (if any) untouched."
    elif [[ "$DAEMON_MANAGER" == "launchd" ]]; then
        echo "[dry-run] loom-daemon is launchd-managed (label ${LAUNCHD_LABEL}) — would restart via '$PROVISION_TARGET restart' (the #4077 supervised primitive); .daemon.flags is NOT consulted (the plist's EnvironmentVariables carries the equivalent config)."
    elif [[ "$DAEMON_MANAGER" == "systemd" ]]; then
        echo "[dry-run] loom-daemon is systemd-managed (unit ${SYSTEMD_UNIT}) — would restart via '$PROVISION_TARGET restart' (the #4267 supervised primitive); .daemon.flags is NOT consulted (the unit's Environment= lines carry the equivalent config)."
    elif [[ "$WAS_RUNNING" == "true" ]]; then
        echo "[dry-run] Would stop + restart loom-daemon with flags from ${FLAGS_SOURCE}: ${RESTART_ARGS[*]:-<none>}"
    else
        echo "[dry-run] loom-daemon is not currently running — would NOT start it (this script never widens FLAGS-OFF by starting autonomy that wasn't already running)."
    fi
    exit 0
fi

# ---------- rebuild ----------
if ! command -v cargo >/dev/null 2>&1; then
    err "cargo not found on PATH — cannot rebuild loom-daemon."
    exit 1
fi

echo
echo "Rebuilding loom-daemon (cargo build --release)..."
if ! (cd "$DAEMON_DIR" && cargo build --release); then
    err "cargo build --release failed — the running daemon (if any) was left untouched."
    exit 1
fi

NEW_BIN=""
for candidate in \
    "$DAEMON_DIR/target/release/loom-daemon" \
    "$REPO_ROOT/target/release/loom-daemon"; do
    # `cargo build --release` run from loom-daemon/ writes to that crate's own
    # target/ when loom-daemon is a standalone crate, but to the WORKSPACE
    # root's target/ when it is a member of a Cargo workspace (this repo's
    # actual layout: root Cargo.toml -> [workspace] members = [...,
    # "loom-daemon"]). Check both, matching locate_daemon_bin()'s candidate
    # order above.
    if [[ -x "$candidate" ]]; then
        NEW_BIN="$candidate"
        break
    fi
done
if [[ -z "$NEW_BIN" ]]; then
    err "Build did not produce an executable at $DAEMON_DIR/target/release/loom-daemon or $REPO_ROOT/target/release/loom-daemon"
    exit 1
fi
ok "Build succeeded: $NEW_BIN"

# ---------- verify the freshly-built binary embeds the expected commit ----------
# A rebuild can succeed (exit 0) yet bake in a STALE LOOM_DAEMON_GIT_COMMIT — the
# exact hazard this script exists to close (a build.rs watch-set bug that lets
# `--version` report the old commit). Provisioning such a binary would "report
# success while shipping nothing" and, worse, turn any auto-update loop that
# trusts the baked commit into an infinite rebuild-still-stale retry. So assert
# the built commit == source HEAD BEFORE provisioning. On mismatch, fail loudly
# and do NOT provision: this is a build-system defect that retrying cannot fix,
# distinct from the compile failure handled above (#4053).
BUILT_VERSION_OUTPUT=$("$NEW_BIN" --version 2>/dev/null || true)
BUILT_COMMIT=$(extract_commit "$BUILT_VERSION_OUTPUT")
if [[ "$SOURCE_COMMIT" == "unknown" ]]; then
    warn "Source HEAD is unknown (no .git?) — skipping built-commit verification (tarball build)."
elif [[ -z "$BUILT_COMMIT" ]]; then
    err "Build verification FAILED: the freshly-built binary reports no commit in --version output ('${BUILT_VERSION_OUTPUT:-<empty>}')."
    err "Refusing to provision a binary that cannot prove what it was built from. This is a build-system defect, not a compile failure."
    exit 4
elif [[ "$BUILT_COMMIT" != "$SOURCE_COMMIT" ]]; then
    err "Build verification FAILED: the freshly-built binary embeds commit '$BUILT_COMMIT' but source HEAD is '$SOURCE_COMMIT'."
    err "A successful build produced a binary stamped with the WRONG commit (a stale baked-in commit — e.g. a build.rs watch-set bug). Retrying will not fix it; refusing to provision (#4053)."
    exit 4
else
    ok "Build verification: freshly-built binary embeds source HEAD commit ($BUILT_COMMIT)."
fi

# ---------- sign (Darwin-only, best-effort, non-fatal, #4016) ----------
# Ad-hoc-sign the freshly built binary with a stable identifier BEFORE
# provisioning, so both provisioning branches below (the LOOM_DAEMON_BIN
# override and provision_machine_daemon) copy an already-signed binary — the
# Mach-O signature survives `install`/`cp`. Signing does NOT make a TCC grant
# survive a rebuild (see sign_daemon_binary's own doc comment in
# scripts/install/provision-daemon.sh and .loom/docs/daemon-reference.md); it
# only pins a human-legible identifier in place of the rustc metadata hash.
# shellcheck disable=SC1091
if [[ -r "$REPO_ROOT/scripts/install/provision-daemon.sh" ]]; then
    source "$REPO_ROOT/scripts/install/provision-daemon.sh"
fi
if declare -F sign_daemon_binary >/dev/null 2>&1; then
    sign_daemon_binary "$NEW_BIN"
fi

# ---------- provision ----------
if [[ -n "${LOOM_DAEMON_BIN:-}" ]]; then
    # Explicit operator override — provision directly to that exact path
    # (the one loom-daemon-start.sh will resolve to next via LOOM_DAEMON_BIN),
    # rather than the machine-level default.
    dest="$LOOM_DAEMON_BIN"
    if install -m 755 "$NEW_BIN" "$dest" 2>/dev/null || { cp -f "$NEW_BIN" "$dest" 2>/dev/null && chmod 755 "$dest" 2>/dev/null; }; then
        ok "Provisioned loom-daemon -> $dest"
    else
        err "Failed to provision to LOOM_DAEMON_BIN=$dest"
        exit 1
    fi
    # This override path has the same "shipped nothing" hazard as the
    # machine-level path — verify the destination is the freshly-built binary.
    verify_destination_binary "$dest"
else
    if declare -F provision_machine_daemon >/dev/null 2>&1; then
        # Hard-fail on provisioning failure: a soft warn here (the pre-#4053
        # behavior) left the exit code at 0, which is exactly the "reports
        # success while shipping nothing" defect this issue closes.
        if ! provision_machine_daemon "$NEW_BIN"; then
            err "Machine-level provisioning FAILED (see above). Refusing to report success; the freshly-built binary is at $NEW_BIN — set LOOM_DAEMON_BIN=$NEW_BIN to use it directly."
            exit 1
        fi
        # provision_machine_daemon exports the destination it wrote to (even on
        # the version-equality short-circuit) — verify that destination is the
        # expected build so the short-circuit can no longer produce a silent
        # no-op on a real roll (#4053).
        verify_destination_binary "${PROVISIONED_DAEMON_BIN:-}"
    else
        warn "scripts/install/provision-daemon.sh not found/sourceable — skipping machine-level provisioning."
        warn "Freshly-built binary: $NEW_BIN (set LOOM_DAEMON_BIN=$NEW_BIN to use it directly)"
    fi
fi

# ---------- restart (preserve prior flags exactly — Issue #3968) ----------
if [[ "$NO_RESTART" == "true" ]]; then
    ok "Rebuilt + provisioned. Skipping restart (--no-restart)."
    if [[ "$WAS_RUNNING" == "true" ]]; then
        if [[ "$DAEMON_MANAGER" == "launchd" ]]; then
            echo "The running (launchd-managed) daemon is still the PRE-update binary. Restart it with:"
            echo "  $PROVISION_TARGET restart      (graceful: supervised in-place relaunch, in-flight sweeps preserved)"
            echo "If that binary predates #4077 and refuses the restart, re-render + relaunch under supervision:"
            echo "  loom-daemon-update.sh --relaunch   (preserves the live plist's LOOM_* env; SIGTERMs the daemon so sweep children reparent)"
            echo "Do NOT 'launchctl bootout $LAUNCHD_SERVICE' by hand — bootout tears down the whole job tree and KILLS in-flight sweeps (they are direct children of the launchd job)."
        elif [[ "$DAEMON_MANAGER" == "systemd" ]]; then
            echo "The running (systemd-managed) daemon is still the PRE-update binary. Restart it with:"
            echo "  $PROVISION_TARGET restart      (graceful: supervised in-place relaunch, in-flight sweeps preserved)"
            echo "If that binary predates #4267 and refuses the restart, re-render + relaunch under supervision:"
            echo "  loom-daemon-update.sh --relaunch   (preserves the live unit's LOOM_* env; SIGTERMs the daemon so sweep children reparent)"
            echo "Do NOT 'systemctl --user stop $SYSTEMD_UNIT' by hand — stop tears down the whole cgroup and KILLS in-flight sweeps (they are direct children of the unit)."
        else
            echo "The running daemon is still the PRE-update binary. Restart manually with:"
            echo "  $STOP_SCRIPT && $START_SCRIPT ${RESTART_ARGS[*]:-}"
        fi
    fi
    print_final_installed_line "$BUILT_COMMIT"
    exit 0
fi

if [[ "$WAS_RUNNING" != "true" ]]; then
    ok "Rebuilt + provisioned. loom-daemon was not running — nothing to restart."
    echo "Start it with: $START_SCRIPT [flags]"
    print_final_installed_line "$BUILT_COMMIT"
    exit 0
fi

# ---------- launchd-managed restart via the #4077 supervised primitive (#4042) ----------
# The daemon is launchd-supervised, so NEITHER stop.sh+start.sh NOR .daemon.flags
# apply: the plist's ProgramArguments + EnvironmentVariables are the durable
# source of truth. `loom-daemon restart` sends Request::RestartDaemon over the
# IPC socket; the supervised daemon exits 0 and KeepAlive:SuccessfulExit
# relaunches it onto the freshly-provisioned binary with the plist's config.
if [[ "$DAEMON_MANAGER" == "launchd" ]]; then
    echo "loom-daemon is launchd-managed (label ${LAUNCHD_LABEL})."
    echo "Restarting via the supervised restart primitive: $PROVISION_TARGET restart"
    echo "(.daemon.flags is NOT consulted — the plist's EnvironmentVariables carries the equivalent config.)"

    # Capture the pre-restart pid BEFORE the request so the poll below can tell
    # "launchd relaunched onto a new pid" apart from "the same job never moved".
    PRE_RESTART_PID="$(launchd_job_pid)"

    if "$PROVISION_TARGET" restart; then
        # The RUNNING (old) binary accepted the request — but that ack is the
        # daemon's promise, not proof launchd actually honored it (#4232: the
        # daemon can exit 0 and launchd can still fail to relaunch it). Verify
        # a NEW, live pid before reporting success; the success message below
        # is intentionally the ONLY "restart scheduled"-style success line in
        # this branch, and it is unreachable until verification passes.
        RESTART_POLL_SECS="${LOOM_DAEMON_RESTART_POLL_SECS:-30}"
        RESTART_POLL_INTERVAL="${LOOM_DAEMON_RESTART_POLL_INTERVAL:-1}"
        KICKSTART_POLL_SECS="${LOOM_DAEMON_RESTART_KICKSTART_POLL_SECS:-15}"
        echo "Restart request accepted (pre-restart pid: ${PRE_RESTART_PID:-<none>}). Verifying launchd relaunches onto a NEW, live pid within ${RESTART_POLL_SECS}s before reporting success (#4232)..."

        if NEW_PID="$(wait_for_new_launchd_pid "$PRE_RESTART_PID" "$RESTART_POLL_SECS" "$RESTART_POLL_INTERVAL")"; then
            ok "loom-daemon restart scheduled — launchd relaunched it onto the freshly-provisioned binary (new pid ${NEW_PID}, verified within ${RESTART_POLL_SECS}s)."
            print_final_installed_line "$BUILT_COMMIT"
            exit 0
        fi

        warn "launchd did NOT relaunch within ${RESTART_POLL_SECS}s of the restart ack — no new, live pid observed (pre-restart pid was ${PRE_RESTART_PID:-<none>})."
        log_launchd_diagnostics
        warn "Falling back to 'launchctl kickstart $LAUNCHD_SERVICE' (plain — NEVER -k — so a daemon that DID relaunch during the race window above is never killed)."
        launchctl kickstart "$LAUNCHD_SERVICE" >/dev/null 2>&1

        if NEW_PID="$(wait_for_new_launchd_pid "$PRE_RESTART_PID" "$KICKSTART_POLL_SECS" "$RESTART_POLL_INTERVAL")"; then
            ok "loom-daemon restart scheduled — launchd's own relaunch did not occur within ${RESTART_POLL_SECS}s, but the 'launchctl kickstart' fallback relaunched it (new pid ${NEW_PID}, verified within ${KICKSTART_POLL_SECS}s). Remediation note: the kickstart fallback was required (#4232) — investigate why launchd did not relaunch the job on its own."
            print_final_installed_line "$BUILT_COMMIT"
            exit 0
        fi

        err "loom-daemon restart FAILED: no new, live pid was observed even after the 'launchctl kickstart' fallback."
        log_launchd_diagnostics
        err "The freshly-built binary IS provisioned, but the daemon's live status is NOT confirmed (pre-restart pid was ${PRE_RESTART_PID:-<none>})."
        err "Investigate manually: launchctl print $LAUNCHD_SERVICE"
        exit 7
    fi
    # The restart request is served by the RUNNING (old) binary. A pre-#4077
    # daemon has no RestartDaemon handler (and an unsupervised/dead socket also
    # fails), so the request was refused. Refuse loudly rather than claim a
    # half-update success: the fresh binary is provisioned but the OLD one is
    # still running (the #4011 silent-autonomy-loss class this issue closes).
    err "loom-daemon restart FAILED: the running daemon did not accept the restart request."
    err "This is expected on the FIRST roll onto a #4077-capable binary — the currently-running binary predates the 'restart' IPC command (or its socket is dead)."
    err "The freshly-built binary IS provisioned, but the OLD (unsupervised) binary is still running."

    if [[ "$RELAUNCH" == "true" ]]; then
        perform_relaunch "$LAUNCHD_PLIST"
        exit $?
    fi

    daemon_pid_hint=$(launchd_job_pid)
    err ""
    err "To finish the roll, re-render the plist and relaunch under launchd supervision"
    err "(this installs KeepAlive:{SuccessfulExit:true} + LOOM_DAEMON_SUPERVISOR=launchd so"
    err "the NEXT roll can use the supervised path) while preserving the live plist's LOOM_*"
    err "autonomy env — run:"
    err "  loom-daemon-update.sh --relaunch      (or: LOOM_DAEMON_UPDATE_RELAUNCH=1 loom-daemon-update.sh)"
    err ""
    err "WARNING: do NOT 'launchctl bootout $LAUNCHD_SERVICE' by hand to force this."
    err "bootout tears down the whole job tree, and in-flight sweep children are DIRECT"
    err "children of the launchd job, so it TERMINATES every running sweep — stranding"
    err "loom:building labels and leaving worktrees behind. --relaunch above instead stops"
    err "the daemon gracefully (SIGTERM) so sweep children reparent and keep working."
    err "If you must relaunch by hand, prefer the graceful sequence over bootout+bootstrap:"
    err "  kill -TERM ${daemon_pid_hint:-<daemon-pid>}   # daemon exits non-zero; children reparent; not relaunched (stale plist KeepAlive=false)"
    err "  $START_SCRIPT                                  # re-render + bootstrap the supervised plist"
    exit 6
fi

# ---------- systemd-managed restart via the #4267 supervised primitive (#4260 sub-issue C) ----------
# The systemd mirror of the launchd block above. The daemon is systemd-
# supervised, so NEITHER stop.sh+start.sh NOR .daemon.flags apply: the unit's
# ExecStart + Environment= lines are the durable source of truth. `loom-daemon
# restart` sends Request::RestartDaemon over the IPC socket; the supervised
# daemon exits 0 and `Restart=on-success` relaunches it onto the freshly-
# provisioned binary with the unit's config.
if [[ "$DAEMON_MANAGER" == "systemd" ]]; then
    echo "loom-daemon is systemd-managed (unit ${SYSTEMD_UNIT})."
    echo "Restarting via the supervised restart primitive: $PROVISION_TARGET restart"
    echo "(.daemon.flags is NOT consulted — the unit's Environment= lines carry the equivalent config.)"
    if "$PROVISION_TARGET" restart; then
        ok "loom-daemon restart scheduled — systemd will relaunch it onto the freshly-provisioned binary."
        print_final_installed_line "$BUILT_COMMIT"
        exit 0
    fi
    # The restart request is served by the RUNNING (old) binary. A pre-#4267
    # daemon has no RestartDaemon handler recognizing LOOM_DAEMON_SUPERVISOR=systemd
    # (and an unsupervised/dead socket also fails), so the request was refused.
    # Refuse loudly rather than claim a half-update success: the fresh binary is
    # provisioned but the OLD one is still running (the #4011 silent-autonomy-
    # loss class this issue closes).
    err "loom-daemon restart FAILED: the running daemon did not accept the restart request."
    err "This is expected on the FIRST roll onto a #4267-capable binary — the currently-running binary predates the 'restart' IPC command (or its socket is dead)."
    err "The freshly-built binary IS provisioned, but the OLD (unsupervised) binary is still running."

    if [[ "$RELAUNCH" == "true" ]]; then
        perform_systemd_relaunch "$SYSTEMD_UNIT_PATH" "$SYSTEMD_UNIT"
        exit $?
    fi

    daemon_pid_hint=$(systemd_unit_pid)
    err ""
    err "To finish the roll, re-render the unit and relaunch under systemd supervision"
    err "(this installs Restart=on-success + LOOM_DAEMON_SUPERVISOR=systemd so"
    err "the NEXT roll can use the supervised path) while preserving the live unit's LOOM_*"
    err "autonomy env — run:"
    err "  loom-daemon-update.sh --relaunch      (or: LOOM_DAEMON_UPDATE_RELAUNCH=1 loom-daemon-update.sh)"
    err ""
    err "WARNING: do NOT 'systemctl --user stop $SYSTEMD_UNIT' by hand to force this."
    err "stop tears down the whole cgroup, and in-flight sweep children are DIRECT"
    err "children of the unit, so it TERMINATES every running sweep — stranding"
    err "loom:building labels and leaving worktrees behind. --relaunch above instead stops"
    err "the daemon gracefully (SIGTERM) so sweep children reparent and keep working."
    err "If you must relaunch by hand, prefer the graceful sequence over stop+enable:"
    err "  kill -TERM ${daemon_pid_hint:-<daemon-pid>}   # daemon exits by signal; children reparent; not relaunched (Restart=on-success does not fire)"
    err "  $START_SCRIPT                                  # re-render + enable --now the supervised unit"
    exit 6
fi

# ---------- PID-file/nohup-managed restart (preserve prior flags exactly) ----------
if [[ "$FLAGS_SOURCE" == "$FLAGS_FILE" ]]; then
    echo "Restarting with the flags persisted at the last start ($FLAGS_FILE): ${RESTART_ARGS[*]:-<none>}"
else
    warn "No $FLAGS_FILE found — restarting FLAGS-OFF (bare) rather than guessing the prior autonomy flags."
fi

echo "Stopping loom-daemon..."
# --restarting preserves the autonomy-desired marker + watchdog across this
# internal stop (#4011): a self-update is NOT operator intent to stop, so the
# detector must NOT be disarmed — otherwise every self-update would silently turn
# off the very autonomy-loss detection this issue adds (the exact bug class it
# fixes). The subsequent start re-writes the marker and re-provisions the watchdog.
if ! "$STOP_SCRIPT" --restarting; then
    err "loom-daemon-stop.sh failed — NOT starting the new binary on top of a still-running old one."
    exit 1
fi

echo "Starting loom-daemon with preserved flags: ${RESTART_ARGS[*]:-<none>}"
# Guard the array expansion: RESTART_ARGS is empty for a bare/FLAGS-OFF
# restart, and "${arr[@]}" on a zero-element array is an unbound variable
# error under `set -u` on bash < 4.4 (still the default /bin/bash on stock
# macOS).
if [[ "${#RESTART_ARGS[@]}" -gt 0 ]]; then
    "$START_SCRIPT" "${RESTART_ARGS[@]}"
else
    "$START_SCRIPT"
fi
START_RC=$?
if [[ "$START_RC" -eq 0 ]]; then
    print_final_installed_line "$BUILT_COMMIT"
fi
exit "$START_RC"
