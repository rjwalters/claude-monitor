#!/bin/bash
# probe-tokens.sh - Probe each bootstrapped OAuth account and write .ranking.
#
# Usage:
#   ./.loom/scripts/probe-tokens.sh              # Probe + print human table
#   ./.loom/scripts/probe-tokens.sh --ranking    # Probe + write .loom/tokens/.ranking
#   ./.loom/scripts/probe-tokens.sh --json       # Probe + emit JSON to stdout
#
# Exit codes:
#   0 - At least one account was probed (results may be mixed)
#   1 - Every probe failed, or the tokens directory is missing, or no daemon
#       binary/loom-tokens fallback could be resolved
#
# Cron example (every 10 minutes):
#   */10 * * * * cd /path/to/repo && ./.loom/scripts/probe-tokens.sh --ranking >> .loom/logs/probe-tokens.log 2>&1
#
# Delegates to the native `loom-daemon tokens check` subcommand (issue #4080,
# epic #4081 Phase 2 — a byte-compatible Rust port of the historical Python
# `loom-tokens check` CLI). Falls back to `loom-tokens` on PATH when the
# resolved daemon binary predates the `tokens` subcommand (a host mid-roll —
# #4108 landed in commit 51389917). The bare `python3 -m` fallback tier has
# been removed entirely.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/locate-daemon-bin.sh
source "$SCRIPT_DIR/lib/locate-daemon-bin.sh"

# ---------- repo root (mirrors loom-daemon-start.sh's find_repo_root) ----------
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
    echo "$PWD"
}

REPO_ROOT="$(find_repo_root)"
DAEMON_BIN="$(loom_locate_daemon_bin "$REPO_ROOT")"

# Capability-probe before committing to the native path: a host mid-roll can
# have a `loom-daemon` binary predating commit 51389917 (#4108), which would
# fail with "unrecognized subcommand `tokens`". `tokens check --help` is a
# cheap, side-effect-free way to detect that ahead of time.
if [[ -n "$DAEMON_BIN" ]] && "$DAEMON_BIN" tokens check --help >/dev/null 2>&1; then
    exec "$DAEMON_BIN" tokens check "$@"
fi

if [[ -n "$DAEMON_BIN" ]]; then
    echo "WARNING probe-tokens.sh: $DAEMON_BIN does not support 'tokens check' (stale build); falling back to loom-tokens on PATH" >&2
fi

if command -v loom-tokens &>/dev/null; then
    loom-tokens check "$@"
    exit $?
fi

echo "ERROR probe-tokens.sh: no loom-daemon binary supporting 'tokens check' and no loom-tokens on PATH." >&2
echo "  Build or start a daemon binary, then retry:" >&2
echo "    ./.loom/scripts/cli/loom-daemon-start.sh" >&2
echo "    cargo build --release -p loom-daemon" >&2
exit 1
