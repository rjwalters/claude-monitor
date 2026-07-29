#!/bin/bash
# clean.sh - Backwards-compatible wrapper for loom-clean
#
# Delegates to the native `loom-daemon clean` subcommand (issue #4272, epic
# #4081 Phase 3 family 2 — a byte-compatible Rust port of the historical
# Python `loom-clean` CLI). Falls back to the `run_loom_tool` Python fallback
# chain (source PYTHONPATH -> venv console script -> installed console
# script) when the resolved daemon binary predates the `clean` subcommand (a
# host mid-roll), following the `probe-tokens.sh` precedent from Phase 2.
#
# Usage:
#   clean.sh             # Interactive cleanup
#   clean.sh --force     # Non-interactive cleanup
#   clean.sh --dry-run   # Preview what would be cleaned
#   clean.sh --deep      # Also remove build artifacts
#   clean.sh --aggressive --dry-run   # Preview vestigial-worktree cleanup
#   clean.sh --help      # Show help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/locate-daemon-bin.sh
source "$SCRIPT_DIR/lib/locate-daemon-bin.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DAEMON_BIN="$(loom_locate_daemon_bin "$REPO_ROOT")"

# Capability-probe before committing to the native path: a host mid-roll can
# have a `loom-daemon` binary predating the `clean` subcommand, which would
# fail with "unrecognized subcommand `clean`".
if [[ -n "$DAEMON_BIN" ]] && "$DAEMON_BIN" clean --help >/dev/null 2>&1; then
    exec "$DAEMON_BIN" clean "$@"
fi

if [[ -n "$DAEMON_BIN" ]]; then
    echo "WARNING clean.sh: $DAEMON_BIN does not support 'clean' (stale build); falling back to loom-clean" >&2
fi

# Source shared loom-tools helper (Python fallback chain).
source "$SCRIPT_DIR/lib/loom-tools.sh"
run_loom_tool "clean" "clean" "$@"
