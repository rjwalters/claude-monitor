#!/bin/bash
# recover-orphaned-shepherds.sh - Detect and recover orphaned task state.
#
# Delegates to the native `loom-daemon recover-orphans` subcommand (issue
# #4272, epic #4081 Phase 3 family 2 — a byte-compatible Rust port of the
# historical Python `loom-recover-orphans` CLI). Falls back to the
# `run_loom_tool` Python fallback chain when the resolved daemon binary
# predates the `recover-orphans` subcommand (a host mid-roll), following the
# `probe-tokens.sh` precedent from Phase 2.
#
# The script name is preserved for back-compat with operator muscle memory
# and any CLAUDE.md / docs that link to it.
#
# Usage:
#   recover-orphaned-shepherds.sh              # Dry-run: show what would be recovered
#   recover-orphaned-shepherds.sh --recover    # Actually recover orphaned state
#   recover-orphaned-shepherds.sh --json       # Output JSON for programmatic use
#   recover-orphaned-shepherds.sh --verbose    # Show detailed progress
#   recover-orphaned-shepherds.sh --help       # Show help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/locate-daemon-bin.sh
source "$SCRIPT_DIR/lib/locate-daemon-bin.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DAEMON_BIN="$(loom_locate_daemon_bin "$REPO_ROOT")"

if [[ -n "$DAEMON_BIN" ]] && "$DAEMON_BIN" recover-orphans --help >/dev/null 2>&1; then
    exec "$DAEMON_BIN" recover-orphans "$@"
fi

if [[ -n "$DAEMON_BIN" ]]; then
    echo "WARNING recover-orphaned-shepherds.sh: $DAEMON_BIN does not support 'recover-orphans' (stale build); falling back to loom-recover-orphans" >&2
fi

# Source shared loom-tools helper (Python fallback chain).
source "$SCRIPT_DIR/lib/loom-tools.sh"
run_loom_tool "recover-orphans" "orphan_recovery" "$@"
