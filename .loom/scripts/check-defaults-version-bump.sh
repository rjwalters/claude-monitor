#!/usr/bin/env bash
# check-defaults-version-bump.sh - Fail a PR that changes defaults/ without
# either bumping VERSION or declaring an explicit no-surface-change marker
# (#5874).
#
# Why this exists: every file under defaults/ is copied into every
# consumer's installed .loom/{scripts,hooks,roles,docs,bin}/ +
# .claude/commands/loom/ surfaces at install time -- and is NOT refreshed by
# a `git pull` (that drift is what resync-installed.sh exists to remediate,
# per #3777). The only mechanical signal a consumer has that its installed
# copies are behind is a VERSION comparison: install.sh's own currency check,
# /repo:update-tools, and a fleet's `fleet-resync.sh --dry-run` all key off
# it. If a PR changes defaults/ without bumping VERSION, that signal silently
# lies -- exactly what happened when PR #5846 changed five role prompts plus
# a doc without touching VERSION: 23 fleet repos all reported
# "v0.18.0 -> v0.18.0" (current) while 59-85 installed surfaces per repo were
# actually stale.
#
# This is deliberately NOT trying to force semantic-version inflation on
# every doc typo or test-only edit under defaults/ -- an explicit marker lets
# an author declare "this change does not alter installed behavior" without a
# version bump.
#
# Usage:
#   check-defaults-version-bump.sh --base <ref> [--head <ref>]
#     --base <ref>   Git ref/sha to diff FROM (the PR's base commit, e.g. a
#                     fetched base sha, or origin/main for a local check).
#                     Required.
#     --head <ref>   Git ref/sha to diff TO. Defaults to HEAD.
#   check-defaults-version-bump.sh --help
#
# No-surface-change marker: a PR whose body OR whose HEAD-reachable commit
# messages (between --base and --head) contain the literal string
#     <!-- loom:no-surface-change -->
# is exempt even when defaults/ changed and VERSION did not. Pass the PR body
# via the PR_BODY environment variable (GitHub Actions:
# `env: PR_BODY: ${{ github.event.pull_request.body }}`); the commit-message
# path needs no extra plumbing beyond --base/--head.
#
# Exit codes:
#   0 - nothing under defaults/ changed in the diff, OR VERSION was also
#       changed, OR the no-surface-change marker is present.
#   1 - defaults/ changed, VERSION was not, and no marker is present.
#   2 - bad usage (missing/invalid --base or --head).

set -euo pipefail

MARKER='<!-- loom:no-surface-change -->'

BASE=""
HEAD="HEAD"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)
      BASE="${2:-}"
      shift 2
      ;;
    --head)
      HEAD="${2:-}"
      shift 2
      ;;
    --help|-h)
      sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "check-defaults-version-bump: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$BASE" ]]; then
  echo "check-defaults-version-bump: --base <ref> is required." >&2
  exit 2
fi

if ! git rev-parse --verify --quiet "${BASE}^{commit}" >/dev/null; then
  echo "check-defaults-version-bump: base ref '$BASE' not found (not fetched?)." >&2
  exit 2
fi

if ! git rev-parse --verify --quiet "${HEAD}^{commit}" >/dev/null; then
  echo "check-defaults-version-bump: head ref '$HEAD' not found." >&2
  exit 2
fi

# Deliberately a direct two-ref diff, not a merge-base-narrowed one -- this
# script is invoked from a shallow single-commit-fetch CI checkout where the
# base and head shallow histories may not share enough depth to resolve a
# merge-base. A direct diff answers the question this check actually cares
# about ("does applying head's changes touch defaults/ without touching
# VERSION") without requiring ancestry.
CHANGED_FILES="$(git diff --name-only "$BASE" "$HEAD" -- defaults/ 2>/dev/null || true)"

if [[ -z "$CHANGED_FILES" ]]; then
  echo "check-defaults-version-bump: OK — no defaults/ changes in this diff."
  exit 0
fi

VERSION_CHANGED="$(git diff --name-only "$BASE" "$HEAD" -- VERSION 2>/dev/null || true)"

if [[ -n "$VERSION_CHANGED" ]]; then
  echo "check-defaults-version-bump: OK — defaults/ changed and VERSION was bumped."
  exit 0
fi

# --- no-surface-change marker check -----------------------------------------

if [[ -n "${PR_BODY:-}" ]] && grep -qF "$MARKER" <<<"$PR_BODY"; then
  echo "check-defaults-version-bump: OK — no-surface-change marker found in the PR body."
  exit 0
fi

if git log --format=%B "${BASE}..${HEAD}" 2>/dev/null | grep -qF "$MARKER"; then
  echo "check-defaults-version-bump: OK — no-surface-change marker found in a commit message."
  exit 0
fi

echo "check-defaults-version-bump: FAIL — defaults/ changed without a VERSION bump:" >&2
echo "" >&2
echo "$CHANGED_FILES" | sed 's/^/  /' >&2
echo "" >&2
echo "Every file under defaults/ is copied into consumers' installed" >&2
echo ".loom/{scripts,hooks,roles,docs,bin}/ + .claude/commands/loom/ surfaces at" >&2
echo "install time -- NOT refreshed by a git pull (#3777). VERSION is the only" >&2
echo "mechanical signal consumers have that those copies are stale, so a" >&2
echo "defaults/ change must bump it (at minimum the patch component):" >&2
echo "    ./scripts/version.sh bump patch" >&2
echo "" >&2
echo "If this change genuinely does not alter installed behavior (e.g. a" >&2
echo "comment, a test-only edit, a typo fix), declare that explicitly instead" >&2
echo "of bumping VERSION -- add this exact marker to the PR body or to a commit" >&2
echo "message in this PR:" >&2
echo "    $MARKER" >&2
exit 1
