#!/usr/bin/env bash
# resolve-tier-model.sh - Print the model an issue's work must run on (#4238).
#
# Turns the Curator's runtime-neutral complexity tier into a concrete model id,
# so the dispatch path does a LOOKUP instead of a judgement call. Reading a
# document and "resolving" a model in your head is how model selection silently
# drifts; this makes the resolution a command whose output is either used or
# visibly absent.
#
#   resolve-tier-model.sh <issue> [runtime] [repo]   # runtime defaults to claude
#
# Resolution:
#   1. Read `<!-- loom:complexity=... -->` from the issue body. Missing or
#      unrecognised => routine (the safe middle).
#   2. Look up sweep.tierModels[<runtime>][<tier>] in .loom/config.json. If that
#      has no entry, fall back to the tier's entry (if any) in the
#      sweep.optimization preset (`cost` | `speed` | `balanced`, default
#      `balanced`; env override LOOM_SWEEP_OPTIMIZATION, issue #4238 Phase B).
#      Either way the resolved logical tier is passed through resolve-model.sh
#      (logical tier -> current-generation ID). All three steps live in
#      loom_tools.model_tiers (--tier mode), so they are covered by
#      test_model_tiers.py rather than duplicated here in inline python.
#   3. No entry from either source (or a mapping that would resolve to `fable`)
#      => print nothing, exit 3, so the caller falls through to its normal
#      precedence chain (the tier-3 role default) instead of guessing a model.
#      An unconfigured repo (or one with sweep.optimization unset/"balanced")
#      therefore dispatches byte-identically to today.
#
# Prints ONLY the model id on stdout; diagnostics go to stderr.
set -uo pipefail

ISSUE="${1:-}"
RUNTIME="${2:-claude}"
[[ -n "$ISSUE" ]] || { echo "usage: resolve-tier-model.sh <issue> [runtime] [repo]" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/loom-tools.sh"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not a git repo" >&2; exit 2; }
CONFIG="$ROOT/.loom/config.json"

# Resolve the repo explicitly. A bare `gh issue view` targets the default remote,
# which is wrong wherever `origin` is not where the issues live (a fork checkout,
# most obviously) — it would read the same-numbered issue in another repository
# and hand back a confident model choice for someone else's work item.
REPO="${3:-${LOOM_REPO:-}}"
if [[ -z "$REPO" ]]; then
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
  mechanical|routine|complex) ;;
  *) echo "$REPO#$ISSUE: no valid complexity marker -> routine" >&2; tier="routine" ;;
esac

# --tier mode returns "" + exit 3 when the runtime/tier has no mapping.
if model="$(run_loom_tool "resolve-model" "model_tiers" \
              --tier "$tier" --runtime "$RUNTIME" --config "$CONFIG" 2>/dev/null)" \
   && [[ -n "$model" ]]; then
  echo "resolve-tier-model: repo=$REPO issue=$ISSUE runtime=$RUNTIME tier=$tier model=$model" >&2
  printf '%s\n' "$model"
  exit 0
fi

echo "no tierModels/optimization-preset entry for runtime=$RUNTIME tier=$tier — falling through to tier 3" >&2
exit 3
