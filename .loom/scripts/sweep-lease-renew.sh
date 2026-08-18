#!/usr/bin/env bash
# sweep-lease-renew.sh - Sweep-owned lease renewal loop (Issue #6180, Phase 1
# of Epic #6165: "give the forge claim a liveness dimension").
#
# ## Why this exists
#
# Epic #6165 gives the `loom:building` claim a liveness dimension: a "lease"
# comment on the claimed issue whose forge-assigned `updated_at` is the
# freshness signal a later phase (Phase 2) will read to decide whether a
# claim is still alive. Phase 1 is split into two write-only halves:
#
#   - Issue #6179 (sibling): the daemon writes the lease record ONCE, at the
#     moment `loom:building` is acquired (`SweepRegistry::write_lease_comment`
#     in `loom-daemon/src/sweep_registry/guards.rs`).
#   - Issue #6180 (this script): the SWEEP renews that record for its own
#     full lifetime.
#
# **The sweep renews its own lease — never the daemon.** Role agents run as
# transient scopes parented to `systemd --user` and routinely outlive the
# daemon that spawned them (loom#6129), so supervisor liveness is NOT the
# same thing as work liveness. If the daemon owned renewal, a daemon restart
# would let a live sweep's lease expire, and a peer host could reclaim work
# that was never actually abandoned — reproducing the exact bug this epic
# exists to fix, from a different direction. Renewal must therefore be driven
# by the process actually doing the work: this script is invoked FROM WITHIN
# the sweep's own execution (`defaults/.claude/commands/loom/sweep.md`,
# "Step 1a — daemon self-claim check"), never from `loom-daemon`.
#
# ## Marker format (coordinated with #6179)
#
# At the time this script was written, #6179 had not yet merged. The format
# below is the exact shape documented in #6179's own issue body (and mirrored
# in its in-flight draft of `defaults/docs/lease-record.md`), reproduced here
# so this script has a single, precise, testable contract regardless of merge
# order:
#
#   <!-- loom:lease host=<host> sweep=<sweep-id> -->
#   <free-form prose>
#
# The marker is the comment body's LITERAL FIRST LINE. Everything after it is
# free-form prose that machine readers (this script included) must never
# depend on for anything except locating the comment via
# `startswith("<!-- loom:lease host=")`. **The liveness signal is the
# comment's own forge-assigned `updated_at` timestamp — never a value
# embedded in the marker text.** This script never parses a timestamp out of
# the marker; it exists purely to make `gh` re-touch the comment so the
# forge advances `updated_at` on its own clock.
#
# ## What "renewal" means here
#
# GitHub does not reliably advance a comment's `updated_at` on a byte-for-
# byte-identical PATCH, so a true no-op PATCH would not be a safe renewal
# mechanism. Instead, `renew-once` rewrites a single trailing HTML-comment
# line (its own sub-marker, `<!-- loom:lease-renewed at=... -->`) with a
# fresh timestamp on every call, guaranteeing the body actually changes and
# `updated_at` genuinely advances — while leaving the FIRST-LINE lease marker
# byte-identical, so a `startswith()` reader never sees it move. Like the
# primary marker, `loom:lease-renewed`'s `at=` value is for human debugging
# ONLY; no reader may treat it as authoritative (the forge's own
# `updated_at` always is).
#
# This is an idempotent PATCH of the EXISTING comment — never a new comment.
# One dispatch writes exactly one lease comment (#6179); this script only
# ever edits that same comment, however many times it is called, so no
# duplicate comments accumulate on a long-running sweep.
#
# ## Commands
#
#   sweep-lease-renew.sh start <issue> [--interval SECS] [--watch-pid PID]
#                                       [--host HOST] [--sweep-id ID]
#     Resolve a liveness PID (defaults to the same ancestor-walk
#     `resolve_liveness_pid` uses in sweep-run-registry.sh, i.e. the
#     long-lived `claude -p /loom:sweep ...` orchestrator process, NOT the
#     one-shot Bash-subshell PID of the tool call that invoked `start`), then
#     spawn ONE detached background loop that, every `--interval` seconds
#     (default 300 = 5 minutes; overridable via SWEEP_LEASE_RENEW_INTERVAL_SECS
#     too), best-effort renews the lease for <issue> as long as the watched
#     PID stays alive. Prints the loop's own PID to stdout. The loop is
#     self-terminating: once the watched PID is no longer alive, the loop
#     exits on its own next wake-up, so the lease record is never explicitly
#     deleted -- it simply ages out, exactly as the epic requires ("positive
#     evidence, not inference from a missing broadcast" applies to the
#     RECLAIM side; the renew side just stops broadcasting).
#
#   sweep-lease-renew.sh renew-once <issue> [--host HOST] [--sweep-id ID]
#     Perform exactly one renewal cycle synchronously (used internally by
#     `start`'s loop; also directly testable). Locates the newest comment on
#     <issue> whose body starts with the lease marker prefix; if --host AND
#     --sweep-id are BOTH given, requires an exact match on the full marker
#     line (`host=<HOST> sweep=<ID> -->`) instead of "newest wins" — useful
#     when precision matters (e.g. tests, or a future multi-lease scenario).
#     Note (Issue #6322): the daemon publishes an OPAQUE `host=` id by
#     default now, not a raw hostname — an explicit --host here is compared
#     verbatim against the marker, so a caller wanting exact-match precision
#     must pass whatever value was actually published (see
#     `sweep-lease-fence.sh`'s `opaque_host_id`/`resolve_published_host` for
#     the bash-side helper that derives it). The default "newest wins" mode
#     `start` actually uses never inspects `host=` at all, so it is
#     unaffected either way.
#     Exits 0 on a successful PATCH, 2 if no matching lease comment exists
#     (nothing to renew — not an error: a manually-launched sweep with no
#     daemon dispatch has no lease at all), 1 on a `gh`/network failure.
#
#   sweep-lease-renew.sh stop <PID>
#     Best-effort kill of a loop PID returned by `start`. NOT required for
#     correctness (the loop already self-terminates once its watched PID
#     dies) -- this only speeds up teardown for anyone who wants it.
#
# ## Scope
#
# Only issues that actually have a lease comment can be renewed. This script
# never CREATES a lease comment (that is exclusively #6179's write-on-dispatch
# path) -- `renew-once` finding nothing is a normal, silent no-op for any
# sweep not dispatched by `loom-daemon` (manual `/loom:sweep`, GH Actions
# cron, `--no-daemon`).
#
# Usage:
#   .loom/scripts/sweep-lease-renew.sh start 6180
#   .loom/scripts/sweep-lease-renew.sh renew-once 6180
#   .loom/scripts/sweep-lease-renew.sh stop 12345

set -euo pipefail

LEASE_MARKER_PREFIX="<!-- loom:lease host="
RENEWED_MARKER_PREFIX="<!-- loom:lease-renewed "
DEFAULT_INTERVAL_SECS="${SWEEP_LEASE_RENEW_INTERVAL_SECS:-300}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

usage() {
    awk 'NR < 3 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    exit 1
}

# --- Repo-relative `gh` targeting (#6179's convention: LOOM_REPO override) --
gh_repo_args() {
    if [[ -n "${LOOM_REPO:-}" ]]; then
        printf -- '-R\n%s\n' "$LOOM_REPO"
    fi
}

# ---------------------------------------------------------------------------
# Liveness (mirrors sweep-run-registry.sh's #4691 "Liveness" section verbatim
# in spirit -- duplicated here, not sourced, because sweep-run-registry.sh
# unconditionally calls `main "$@"` at the bottom of the file with no
# BASH_SOURCE guard, so `source`-ing it would also execute its CLI dispatch).
# ---------------------------------------------------------------------------

is_oneshot_shell() {
    local pid="${1:-}" comm base args a0 a1
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    [[ -n "$comm" ]] || return 1
    base="${comm##*/}"
    base="${base#-}"
    case "$base" in
        sh | bash | zsh | dash | ksh | ksh93 | mksh) ;;
        *) return 1 ;;
    esac
    args=$(ps -o args= -p "$pid" 2>/dev/null) || return 1
    read -r a0 a1 _ <<< "$args"
    [[ -n "$a0" ]] || return 1
    [[ "${a1:-}" == -*c* ]]
}

resolve_liveness_pid() {
    local pid="${PPID:-$$}" parent depth=0
    while ((depth < 8)); do
        is_oneshot_shell "$pid" || break
        parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
        if ! [[ "$parent" =~ ^[0-9]+$ ]] || ((parent <= 1)); then
            break
        fi
        pid="$parent"
        depth=$((depth + 1))
    done
    echo "$pid"
}

pid_is_live() {
    local pid="${1:-}" state
    if ! [[ "$pid" =~ ^[0-9]+$ ]] || ((pid <= 0)); then
        return 1
    fi
    kill -0 "$pid" 2>/dev/null && return 0
    state=$(ps -o state= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    [[ -n "$state" ]] || return 1
    [[ "${state:0:1}" == "Z" ]] && return 1
    return 0
}

iso_now() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# --- renew-once --------------------------------------------------------

cmd_renew_once() {
    local issue="${1:-}"
    shift || true
    [[ "$issue" =~ ^[0-9]+$ ]] || {
        echo "ERROR: renew-once requires a positive integer issue number (got: '${issue:-}')" >&2
        exit 1
    }

    local host="" sweep_id=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --host)
                host="${2:-}"
                shift 2
                ;;
            --sweep-id)
                sweep_id="${2:-}"
                shift 2
                ;;
            *)
                echo "ERROR: renew-once: unknown flag '$1'" >&2
                exit 1
                ;;
        esac
    done

    local -a repo_args=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && repo_args+=("$line")
    done < <(gh_repo_args)

    local exact=""
    if [[ -n "$host" && -n "$sweep_id" ]]; then
        exact="${LEASE_MARKER_PREFIX}${host} sweep=${sweep_id} -->"
    elif [[ -n "$host" || -n "$sweep_id" ]]; then
        echo "ERROR: renew-once: --host and --sweep-id must both be given, or neither" >&2
        exit 1
    fi

    local comments_json
    if ! comments_json="$(gh api "${repo_args[@]}" "repos/{owner}/{repo}/issues/${issue}/comments" --paginate 2>&1)"; then
        echo "ERROR: 'gh api .../issues/${issue}/comments --paginate' failed: $comments_json" >&2
        exit 1
    fi

    local candidate_id
    candidate_id="$(jq -r --arg marker "$LEASE_MARKER_PREFIX" --arg exact "$exact" '
        [ .[] | select(.body != null and (.body | startswith($marker)))
              | select($exact == "" or (.body | startswith($exact))) ]
        | sort_by(.id) | reverse | .[0].id // empty
    ' <<< "$comments_json" 2>/dev/null || true)"

    if [[ -z "$candidate_id" ]]; then
        echo "no lease comment found for issue #${issue} (marker=${LEASE_MARKER_PREFIX}...${exact:+, exact=$exact}); nothing to renew (#6180)" >&2
        exit 2
    fi

    local old_body
    old_body="$(jq -r --arg id "$candidate_id" '.[] | select((.id | tostring) == $id) | .body' <<< "$comments_json")"

    local stripped_body now_iso new_body
    stripped_body="$(printf '%s\n' "$old_body" | grep -v "^${RENEWED_MARKER_PREFIX}" || true)"
    now_iso="$(iso_now)"
    new_body="$(printf '%s\n\n%sat=%s by=sweep-lease-renew.sh (#6180) -->\n' \
        "$stripped_body" "$RENEWED_MARKER_PREFIX" "$now_iso")"

    if ! printf '%s' "$new_body" \
        | gh api "${repo_args[@]}" --method PATCH "repos/{owner}/{repo}/issues/comments/${candidate_id}" -F body=@- \
        > /dev/null; then
        echo "ERROR: PATCH of lease comment ${candidate_id} on issue #${issue} failed" >&2
        exit 1
    fi

    echo "renewed lease comment ${candidate_id} for issue #${issue} at ${now_iso}" >&2
}

# --- start ---------------------------------------------------------------

cmd_start() {
    local issue="${1:-}"
    shift || true
    [[ "$issue" =~ ^[0-9]+$ ]] || {
        echo "ERROR: start requires a positive integer issue number (got: '${issue:-}')" >&2
        exit 1
    }

    local interval="$DEFAULT_INTERVAL_SECS" watch_pid="" host="" sweep_id=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --interval)
                interval="${2:-}"
                shift 2
                ;;
            --watch-pid)
                watch_pid="${2:-}"
                shift 2
                ;;
            --host)
                host="${2:-}"
                shift 2
                ;;
            --sweep-id)
                sweep_id="${2:-}"
                shift 2
                ;;
            *)
                echo "ERROR: start: unknown flag '$1'" >&2
                exit 1
                ;;
        esac
    done

    if ! [[ "$interval" =~ ^[0-9]+$ ]] || ! ((interval > 0)); then
        echo "ERROR: --interval must be a positive integer (got: '$interval')" >&2
        exit 1
    fi

    if [[ -z "$watch_pid" ]]; then
        watch_pid="$(resolve_liveness_pid)"
    fi
    [[ "$watch_pid" =~ ^[0-9]+$ ]] || {
        echo "ERROR: could not resolve a watch PID" >&2
        exit 1
    }

    local -a extra_args=()
    [[ -n "$host" ]] && extra_args+=(--host "$host")
    [[ -n "$sweep_id" ]] && extra_args+=(--sweep-id "$sweep_id")

    # Detached loop: sleeps first (dispatch already wrote a fresh lease right
    # before spawning this sweep, so the first renewal isn't due for a full
    # interval), then renews, then re-checks watch-PID liveness. Failures
    # from a single renew-once call are swallowed (`|| true`) -- exactly the
    # same best-effort contract #6179's write-on-dispatch path uses; a
    # transient `gh` hiccup must never kill the loop or the sweep.
    (
        while pid_is_live "$watch_pid"; do
            sleep "$interval"
            pid_is_live "$watch_pid" || break
            "$SELF" renew-once "$issue" "${extra_args[@]}" > /dev/null 2>&1 || true
        done
    ) < /dev/null > /dev/null 2>&1 &
    local loop_pid=$!
    disown "$loop_pid" 2> /dev/null || true
    echo "$loop_pid"
}

cmd_stop() {
    local pid="${1:-}"
    [[ "$pid" =~ ^[0-9]+$ ]] || {
        echo "ERROR: stop requires a PID argument" >&2
        exit 1
    }
    kill "$pid" 2> /dev/null || true
}

main() {
    local cmd="${1:-}"
    shift || true
    case "$cmd" in
        start) cmd_start "$@" ;;
        renew-once) cmd_renew_once "$@" ;;
        stop) cmd_stop "$@" ;;
        -h | --help | "") usage ;;
        *)
            echo "ERROR: unknown command '$cmd'" >&2
            usage
            ;;
    esac
}

main "$@"
