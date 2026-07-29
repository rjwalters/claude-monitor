#!/usr/bin/env bash
# require-complexity-marker.sh - Check that an issue carries a complexity tier
# before it is marked curated (#4238).
#
# The tier drives the downstream Builder model choice, so an unclassified issue
# silently costs either quality (cheap model on money/security work) or money
# (frontier model on a file split). This turns "please remember to classify"
# into a command the Curator can run that fails loudly.
#
#   require-complexity-marker.sh <issue> [repo]   # exit 0 = has a valid tier
#                                                 # exit 1 = missing/invalid
set -uo pipefail

ISSUE="${1:-}"
[[ -n "$ISSUE" ]] || { echo "usage: require-complexity-marker.sh <issue> [repo]" >&2; exit 2; }

# Resolve the repo explicitly. A bare `gh issue view` targets the default remote,
# which is wrong wherever `origin` is not where the issues live (a fork checkout,
# most obviously) — it looks up a same-numbered issue in another repository and
# reports whatever that one says.
REPO="${2:-${LOOM_REPO:-}}"
if [[ -z "$REPO" ]]; then
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not a git repo" >&2; exit 2; }
  # shellcheck source=/dev/null
  source "$ROOT/.loom/scripts/lib/forge-helpers.sh" 2>/dev/null || true
  if declare -F forge_get_repo_nwo >/dev/null; then
    REPO="$(forge_get_repo_nwo gh 2>/dev/null || true)"
  fi
fi
[[ -n "$REPO" ]] || { echo "could not determine repo; pass it explicitly or set LOOM_REPO" >&2; exit 2; }

body="$(gh issue view "$ISSUE" -R "$REPO" --json body -q .body 2>/dev/null || true)"
tier="$(printf '%s' "$body" | grep -o 'loom:complexity=[a-z]*' | head -1 | cut -d= -f2)"

case "$tier" in
  mechanical|routine|complex)
    echo "ok: $REPO#$ISSUE is tagged $tier"
    ;;
  "")
    cat >&2 <<'EOF'
BLOCKED: issue has no complexity marker.

Add exactly one of these to the issue body before applying loom:curated:

  <!-- loom:complexity=mechanical -->   a mistake is obvious on reading it
  <!-- loom:complexity=routine -->      mistake would surface in tests/review
  <!-- loom:complexity=complex -->      mistake could pass tests and review unseen

Torn between two? Take the higher one.
EOF
    exit 1
    ;;
  *)
    echo "BLOCKED: issue $ISSUE has an invalid tier '$tier' (expected mechanical|routine|complex)" >&2
    exit 1
    ;;
esac
