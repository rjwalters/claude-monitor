#!/usr/bin/env bash
# guard-destructive.sh — PreToolUse guard DISPATCHER (Loom-specific glue, #4041)
#
# The generic destructive-command pattern list this file used to contain has its
# canonical home in Repo Skills (https://github.com/rjwalters/repo), installed
# into consumer repos at .claude/skills/repo/hooks/guard-destructive.sh. That
# canonical guard carries the rjwalters/repo#29 curl-pipe false-positive fix and
# is the general-by-design tool installed in many non-Loom repos, so Loom defers
# to it instead of shipping (and separately maintaining) a second generic guard.
#
# This dispatcher decides at RUNTIME which generic guard to run:
#   1. The canonical Repo Skills guard, IF it is present AND carries the
#      rjwalters/repo#29 fix (detected by the `repo#29` marker comment — a
#      presence/version probe, no semver arithmetic). This is the preferred
#      path in a repo that has Repo Skills installed.
#   2. Otherwise the vendored generic guard shipped alongside this file
#      (guard-destructive-generic.sh), so standalone-Loom repos WITHOUT Repo
#      Skills keep full destructive-command coverage.
#
# Exactly one generic guard runs; never zero. Because the choice is made here at
# runtime rather than by rewriting .claude/settings.json, this file stays the
# `${CLAUDE_PROJECT_DIR}/.loom/hooks/guard-destructive.sh` entry in settings —
# so Loom-ownership detection, the settings.json merge, and uninstall are all
# preserved, and there is never a window with zero generic guard wired even when
# Repo Skills' own coexistence-aware installer defers to Loom's entry.
#
# Loom-specific enforcement (the `gh pr merge` → merge-pr.sh redirect, the
# worktree pip-install block) lives in the separate guard-loom-workflow.sh hook;
# worktree path confinement lives in guard-worktree-paths.sh. Those stay
# Loom-owned and are unaffected by this dispatcher.
#
# Contract (same as any guard): reads the PreToolUse JSON on stdin, MUST never
# exit non-zero, and either `exec`s the resolved guard (which emits the
# deny/ask/allow decision from the same stdin) or exits 0 (allow) when no guard
# is available. Fail-open on any unexpected error.

# Fail-open: any unexpected error resolves to allow (exit 0), never breaks the
# tool call or wedges Claude Code in a retry loop.
trap 'exit 0' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null || echo ".")"

# Resolve the consuming repo's root, so CANONICAL_GUARD (below) points at the
# right `.claude/skills/repo/hooks/...` regardless of WHERE this dispatcher
# itself lives:
#
#   - Legacy/project-level wiring: SCRIPT_DIR is <repo>/.loom/hooks (the
#     settings entry resolves to the main worktree's copy even from a linked
#     worktree), so ../../ is the repo root. This is the historical behavior,
#     preserved byte-for-byte when LOOM_PROJECT_ROOT is unset.
#   - Machine-level wiring (Epic #3835 Phase 5, #4262): this file runs from
#     the shared checkout (SCRIPT_DIR is <checkout>/defaults/hooks), where
#     SCRIPT_DIR-relative resolution would point outside the consuming repo
#     entirely. The user-scope command wrapper (provision-hooks.sh) resolves
#     the worktree-aware repo root BEFORE exec'ing this dispatcher and passes
#     it via LOOM_PROJECT_ROOT, so that root is preferred when set.
#
# VENDORED_GUARD is always a SCRIPT_DIR-relative sibling — correct in both
# layouts, since guard-destructive-generic.sh ships alongside this dispatcher
# either way.
CANONICAL_ROOT="${LOOM_PROJECT_ROOT:-$SCRIPT_DIR/../..}"
CANONICAL_GUARD="$CANONICAL_ROOT/.claude/skills/repo/hooks/guard-destructive.sh"
# Vendored copy of the canonical guard, shipped by Loom for standalone repos.
VENDORED_GUARD="$SCRIPT_DIR/guard-destructive-generic.sh"

# Prefer the canonical guard ONLY when it carries the rjwalters/repo#29 fix.
# The cheap bash-builtin `[[ -r ]]` test (zero forks) guards the grep, so a repo
# without Repo Skills pays no extra process — preserving the guard's #3687
# read-only fast path in that common case. In a dual-install repo the marker
# grep costs one fork per command before the canonical guard's own fast path
# runs; grep -q short-circuits at the first match.
if [[ -r "$CANONICAL_GUARD" ]] && grep -q 'repo#29' "$CANONICAL_GUARD" 2>/dev/null; then
    exec bash "$CANONICAL_GUARD"
fi

# Fall back to the vendored generic guard (standalone-Loom repos, or a repo whose
# Repo Skills copy predates the repo#29 fix).
if [[ -r "$VENDORED_GUARD" ]]; then
    exec bash "$VENDORED_GUARD"
fi

# Neither guard is available — allow (fail-open).
exit 0
