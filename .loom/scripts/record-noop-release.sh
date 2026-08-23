#!/usr/bin/env bash
# record-noop-release.sh — best-effort wrapper around
# `loom-daemon noop-cooldown record` for the "no actionable delta this pass,
# releasing the claim" conclusion (Issue #6670, follow-up #6740).
#
# The primary caller is `/loom:sweep`'s Builder phase (see
# defaults/.claude/commands/loom/sweep.md): when a builder investigates an
# issue and concludes no code changes are required this pass (see
# builder.md -> "Signaling No Changes Needed" and its `.no-changes-needed`
# marker), the orchestrator calls this script right BEFORE releasing the
# `loom:building` claim back to `loom:issue`, so the work finder does not
# immediately re-offer the same candidate (#6670's noop_cooldown mechanism).
#
# Shape mirrors `build-gate.sh`'s `_arm_dispatch_backoff_on_timeout` (#6192):
# resolve the daemon binary defensively via lib/locate-daemon-bin.sh, and
# treat a missing/unreachable/older `loom-daemon` as a SILENT no-op — this
# call must never fail the caller (a sweep, or an interactive builder
# session). Note the underlying CLI takes the issue number as a positional
# argument (`loom-daemon noop-cooldown record <ISSUE> --reason ...`), NOT a
# `--issue` flag.
#
# Usage:
#   record-noop-release.sh <ISSUE> [--reason TEXT] [--workspace-root PATH]
#
# Exit codes:
#   0 — recorded (or best-effort skipped: no daemon resolvable, or the daemon
#       call itself failed/errored/is unreachable). The daemon-side outcome
#       is never surfaced as a failure here.
#   2 — usage error (missing/non-numeric <ISSUE>). This is a caller bug, not
#       a daemon-availability condition, so it is NOT swallowed — a caller
#       that gets this wrong should see it, unlike a missing daemon.
set -uo pipefail

_usage() {
  echo "Usage: record-noop-release.sh <ISSUE> [--reason TEXT] [--workspace-root PATH]" >&2
}

ISSUE=""
REASON=""
WORKSPACE_ROOT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reason)
      REASON="${2:-}"; shift 2 ;;
    --workspace-root)
      WORKSPACE_ROOT="${2:-}"; shift 2 ;;
    -h|--help)
      _usage; exit 0 ;;
    --*)
      echo "record-noop-release.sh: unknown option: $1" >&2
      _usage
      exit 2 ;;
    *)
      if [[ -n "$ISSUE" ]]; then
        echo "record-noop-release.sh: unexpected extra argument: $1" >&2
        _usage
        exit 2
      fi
      ISSUE="$1"
      shift ;;
  esac
done

if [[ -z "$ISSUE" || ! "$ISSUE" =~ ^[0-9]+$ ]]; then
  echo "record-noop-release.sh: a numeric <ISSUE> argument is required" >&2
  _usage
  exit 2
fi

_locate_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/locate-daemon-bin.sh"
if [[ ! -f "$_locate_lib" ]]; then
  echo "[record-noop-release] note: lib/locate-daemon-bin.sh not found — skipping (no daemon resolution available)" >&2
  exit 0
fi
# shellcheck source=lib/locate-daemon-bin.sh
source "$_locate_lib"

_repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
_daemon_bin="$(loom_locate_daemon_bin "$_repo_root" 2>/dev/null || true)"
if [[ -z "$_daemon_bin" || ! -x "$_daemon_bin" ]]; then
  echo "[record-noop-release] note: no loom-daemon binary resolved — skipping noop-cooldown record for issue #${ISSUE} (best-effort, #6670)" >&2
  exit 0
fi

_args=(noop-cooldown record "$ISSUE")
if [[ -n "$REASON" ]]; then
  _args+=(--reason "$REASON")
fi
if [[ -n "$WORKSPACE_ROOT" ]]; then
  _args+=(--workspace-root "$WORKSPACE_ROOT")
fi

echo "[record-noop-release] recording no-op release for issue #${ISSUE} (#6670/#6740)" >&2
"$_daemon_bin" "${_args[@]}" >/dev/null 2>&1 || true

exit 0
