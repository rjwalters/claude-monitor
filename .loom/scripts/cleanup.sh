#!/bin/bash
# cleanup.sh - Log archival for Loom
#
# Delegates to the native `loom-daemon cleanup logs` subcommand (issue
# #4272, epic #4081 Phase 3 family 2 — a byte-compatible Rust port of the
# historical Python `loom-cleanup` CLI). Falls back to the `run_loom_tool`
# Python fallback chain when the resolved daemon binary predates the
# `cleanup` subcommand (a host mid-roll), following the `probe-tokens.sh`
# precedent from Phase 2.
#
# History: this script was previously named daemon-cleanup.sh and dispatched
# event-driven cleanup for the Loom daemon (shepherd-complete, daemon-startup,
# daemon-shutdown, periodic, prune-sessions).  Those events were removed in
# #3396 (Phase 3.1.7 of #3372) -- session rotation goes away with the daemon
# brain in Phase 3.2.  Only log archival survives.
#
# Usage:
#   cleanup.sh logs                          # archive task outputs + prune
#   cleanup.sh logs --dry-run                # preview
#   cleanup.sh logs --prune-only             # skip archival, only prune
#   cleanup.sh logs --retention-days N       # override retention window
#   cleanup.sh --help                        # show help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/locate-daemon-bin.sh
source "$SCRIPT_DIR/lib/locate-daemon-bin.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DAEMON_BIN="$(loom_locate_daemon_bin "$REPO_ROOT")"

if [[ -n "$DAEMON_BIN" ]] && "$DAEMON_BIN" cleanup logs --help >/dev/null 2>&1; then
    exec "$DAEMON_BIN" cleanup "$@"
fi

if [[ -n "$DAEMON_BIN" ]]; then
    echo "WARNING cleanup.sh: $DAEMON_BIN does not support 'cleanup logs' (stale build); falling back to loom-cleanup" >&2
fi

# Source shared loom-tools helper (Python fallback chain).
source "$SCRIPT_DIR/lib/loom-tools.sh"
run_loom_tool "cleanup" "cleanup" "$@"
