#!/usr/bin/env bash
# classify-error.sh — Classify a (output, exit_code, [provider]) triple into
# an error category.
#
# Source this file (do not exec). Defines a single public function:
#
#   classify_error <output> <exit_code> [provider] -> echoes one of:
#       SUCCESS         — exit 0 (regardless of output content)
#       TIMEOUT         — exit 124/137 (productive cycle, not a failure)
#       CWD_DELETED     — working directory was removed
#       TOKEN_EXPIRED   — 401 / OAuth token expired (skip this token)
#       TOKEN_EXHAUSTED — quota/weekly limit hit (rotate)
#       SESSION_LIMIT   — concurrent-session-limit fault (issue #3947): the
#                         account is NOT out of quota, it just cannot start
#                         another *simultaneous* session right now (a capacity
#                         fault from per-token session stacking). Callers must
#                         re-select a different account and retry WITHOUT
#                         marking the token bad — poisoning .bad_tokens for a
#                         transient concurrency limit would wrongly shrink the
#                         healthy pool. Classified BEFORE TOKEN_EXHAUSTED so the
#                         "session limit" wording is not swallowed by the
#                         weekly/usage-limit regex.
#       MODEL_REFUSAL   — model safety classifier refused the turn
#                         (stop_reason "refusal" on a non-zero-exit run);
#                         a routing error, not a quality signal — the sweep
#                         orchestrator drops one ladder rung (e.g. fable→opus)
#                         WITHOUT consuming a Doctor cycle (see sweep.md).
#       RECOVERABLE     — transient (rate limit, 5xx, network, etc.)
#       FATAL           — non-recoverable (currently never returned;
#                         reserved for future explicit FATAL signals)
#
# Design — engine vs. provider pattern tables (issue #4190):
#   classify_error() is a two-layer design: a shared CLASSIFICATION ENGINE
#   (exit-code-first ordering, the category enum, and the generic-transient
#   fallthrough) plus provider-scoped PATTERN TABLES that hold the actual
#   failure-signature regexes. This keeps a future non-Claude runtime adapter
#   (Codex, Amp, ... — see #4167) additive: register a new provider table
#   instead of editing the shared engine. Today only the `claude` table is
#   populated; a `codex` stub exists for the future adapter to fill in.
#
#   Provider selector precedence (highest first): optional 3rd positional
#   arg > `$LOOM_RUNTIME` (the same env var `spawn-worker.sh` uses for
#   runtime dispatch, see `.loom/docs/runtime-adapters.md`) > default
#   `"claude"`. Two-arg calls (e.g. `claude-wrapper.sh`, which sources this
#   file and calls `classify_error "$1" "$2"`) are therefore unaffected and
#   classify bit-identically to before this split — this file intentionally
#   does NOT introduce a `LOOM_WORKER` selector (that name belongs to an
#   older fork design; upstream's convention is `LOOM_RUNTIME`).
#
#   An unrecognized provider (or no table for a recognized-but-unimplemented
#   provider, e.g. `codex` today) never errors — it simply has no
#   provider-specific matches and falls straight through to the shared
#   generic-transient table below. Provider tables are ordered case dispatch
#   (sequential pattern checks), NOT associative-array iteration, so match
#   order is always deterministic — bash does not guarantee iteration order
#   for associative arrays.
#
#   Within the `claude` table, match order is significant and preserved from
#   the pre-split implementation: CWD_DELETED -> MODEL_REFUSAL ->
#   TOKEN_EXPIRED -> SESSION_LIMIT -> TOKEN_EXHAUSTED -> the "No messages
#   returned" RECOVERABLE case. SESSION_LIMIT must precede TOKEN_EXHAUSTED
#   because "concurrent session limit" contains the substring "session limit"
#   that the exhaustion regex also matches (#3947). MODEL_REFUSAL is matched
#   only when exit_code != 0, preserving the #3233 exit-code-first guarantee
#   (a clean exit whose output merely mentions "refusal" stays SUCCESS).
#
#   Generic transients — rate-limit/429, 5xx, network errors, and the
#   catch-all RECOVERABLE — are provider-INDEPENDENT and apply to every
#   provider, including unknown ones. An unknown provider never produces an
#   error; it always resolves through the generic table.
#
# Design — exit-code-first ordering (issue #3233, preserved by the split
# above):
#   The original lean-genius implementation grepped output BEFORE checking
#   the exit code, which caused false positives on clean exits whose stdout
#   legitimately contained substrings like "500" or "rate limit" (issue
#   #3233). This rewrite checks the exit code first and only inspects output
#   for genuine failures (exit_code != 0). This ordering lives in the shared
#   engine and applies identically regardless of provider.
#
# Design source: this provider-table split is a re-implementation, not a
# cherry-pick, of the engine/table split pioneered in gpeyton/loom@fd5d1da8
# ("feat(errors): per-provider pattern tables in classify-error.sh"). That
# commit predates upstream's SESSION_LIMIT (#3947) and MODEL_REFUSAL
# categories, so it is used here only as a design reference for the
# selector/table shape — all six Claude-specific categories, in their
# current documented order, are carried into the `claude` table below.
#
# Test vectors live in `defaults/scripts/tests/test-spawn-claude.sh`.

# shellcheck disable=SC2120  # OK that callers pass the args; we don't default.

# --- Provider pattern tables -------------------------------------------

# _classify_error_claude <output> -> echoes a category, or nothing if no
# Claude-specific pattern matched (caller falls through to the generic
# table). Only called when exit_code != 0.
_classify_error_claude() {
    local output="$1"

    # Working directory deleted (worktree cleaned up while CLI ran)
    if echo "$output" | grep -qi "current working directory was deleted"; then
        echo "CWD_DELETED"
        return
    fi

    # Model refusal (safety classifier declined the turn) — a `stop_reason`
    # of "refusal" on a non-zero-exit run. This is a routing error, not a
    # transport failure or a quality signal: the sweep orchestrator responds
    # by dropping one ladder rung (e.g. fable→opus) WITHOUT consuming a Doctor
    # cycle (see sweep.md, "Refusal-aware fallback"). Matched only on a genuine
    # failure (exit_code != 0, guaranteed by the caller) so the exit-code-first
    # #3233 guarantee holds — a clean exit whose output merely mentions
    # "refusal" stays SUCCESS in the shared engine above.
    if echo "$output" | grep -qiE '"?stop_reason"?[[:space:]]*[:=][[:space:]]*"?refusal'; then
        echo "MODEL_REFUSAL"
        return
    fi

    # Token expired (401 auth error) — this specific token is bad
    if echo "$output" | grep -qiE "401[^a-z]*authentication_error|OAuth token has expired|token has expired"; then
        echo "TOKEN_EXPIRED"
        return
    fi

    # Concurrent-session-limit fault (issue #3947) — the account is healthy but
    # cannot start another SIMULTANEOUS session right now. This is a capacity
    # signal from per-token session stacking, NOT quota exhaustion, so it is
    # classified distinctly and callers must NOT mark the token bad. Checked
    # BEFORE TOKEN_EXHAUSTED because "concurrent session limit" contains the
    # substring "session limit" that the exhaustion regex below also matches;
    # the concurrency-specific wording ("concurrent", "simultaneous", "already
    # running") disambiguates a capacity fault from a weekly/usage limit.
    if echo "$output" | grep -qiE "concurrent (session|sessions|request)|maximum number of concurrent|too many concurrent|simultaneous session|another session is (already )?(active|running)"; then
        echo "SESSION_LIMIT"
        return
    fi

    # Token exhausted (quota / session / weekly / usage limit) — rotate to a
    # different token. The phrase set is widened (issue #3738) to cover the
    # multi-word-gap variants the Claude CLI actually emits — "hit your
    # session limit", "hit your weekly limit", an org's "monthly usage limit",
    # and "out of extra usage". A naive `hit.your.limit` pattern misses the
    # "session"/multi-word forms (there is filler between "your" and "limit").
    # This regex is kept in lockstep with claude-wrapper.sh, which sources this
    # file rather than duplicating the pattern (issue #3738) — moving the
    # pattern into this table preserves that single-source property; the
    # wrapper still reaches it only via `classify_error`, never a copy.
    if echo "$output" | grep -qiE "hit your (limit|session limit|weekly limit)|hit\.your\.limit|monthly usage limit|out of extra usage"; then
        echo "TOKEN_EXHAUSTED"
        return
    fi

    # "No messages returned" — transient API issue specific to the Claude CLI's
    # own wording (only reached when exit_code != 0, per the caller contract)
    if echo "$output" | grep -q "No messages returned"; then
        echo "RECOVERABLE"
        return
    fi

    # No Claude-specific pattern matched — fall through to the generic table.
}

# _classify_error_codex <output> -> stub for the future Codex runtime adapter
# (#4167). Intentionally empty: upstream has no Codex runner yet, so there are
# no real failure signatures to encode. Every input falls through to the
# shared generic table below (rate-limit/5xx/network/catch-all), which is
# already correct default behavior for an as-yet-unimplemented provider.
# TODO(#4167): populate with Codex-specific failure signatures (401/quota/
# rate-limit wording) when the Codex adapter ships. Do not guess at wording.
_classify_error_codex() {
    :
}

# _classify_error_provider <output> <provider> -> dispatches to the matching
# provider table via ordered case dispatch (deterministic; no associative-
# array iteration). Unknown providers intentionally match nothing here and
# fall through to the generic table in classify_error.
_classify_error_provider() {
    local output="$1"
    local provider="$2"

    case "$provider" in
        claude)
            _classify_error_claude "$output"
            ;;
        codex)
            _classify_error_codex "$output"
            ;;
        *)
            # Unknown provider: no provider-specific table, no error — the
            # generic fallback in classify_error covers it.
            ;;
    esac
}

# --- Generic (provider-independent) transient table ---------------------

# _classify_error_generic <output> -> always echoes a category (never empty).
# Applies to every provider, including unknown ones, so an unrecognized
# `provider` value never fails to classify.
_classify_error_generic() {
    local output="$1"

    # Rate limit (429) — transient, retry with backoff
    if echo "$output" | grep -qiE "rate.limit|too.many.requests|429"; then
        echo "RECOVERABLE"
        return
    fi

    # Server errors (5xx) — transient
    if echo "$output" | grep -qiE "500|502|503|504|internal.server.error|service.unavailable"; then
        echo "RECOVERABLE"
        return
    fi

    # Network errors — transient
    if echo "$output" | grep -qiE "ECONNREFUSED|ETIMEDOUT|network.error"; then
        echo "RECOVERABLE"
        return
    fi

    # Catch-all: unknown non-zero exit, treat as recoverable in daemon mode
    echo "RECOVERABLE"
}

# --- Shared classification engine ----------------------------------------

classify_error() {
    local output="$1"
    local exit_code="$2"
    # Provider selector precedence: explicit 3rd arg > $LOOM_RUNTIME > "claude".
    # Parameter-expansion defaults (not `${3:-}` followed by a separate check)
    # so a 2-arg call (e.g. claude-wrapper.sh) never trips `set -u`.
    local provider="${3:-${LOOM_RUNTIME:-claude}}"

    # 1. Timeout from the `timeout(1)` command — productive cycle, not error.
    #    Provider-independent: a timeout is a timeout regardless of runtime.
    if [[ "$exit_code" -eq 124 || "$exit_code" -eq 137 ]]; then
        echo "TIMEOUT"
        return
    fi

    # 2. Exit-code-first: a clean exit is SUCCESS regardless of output content
    #    or provider. This is the critical fix for #3233 — the previous
    #    implementation returned RECOVERABLE for clean exits whose stdout
    #    contained "500", "rate limit", or "No messages returned".
    if [[ "$exit_code" -eq 0 ]]; then
        echo "SUCCESS"
        return
    fi

    # --- Below here, exit_code != 0 (genuine failure). Inspect output. ---

    # 3. Provider-specific table first (e.g. the six Claude categories).
    local provider_result
    provider_result="$(_classify_error_provider "$output" "$provider")"
    if [[ -n "$provider_result" ]]; then
        echo "$provider_result"
        return
    fi

    # 4. Generic, provider-independent transients (always resolves).
    _classify_error_generic "$output"
}

# Convenience predicate matching legacy callers in claude-wrapper.sh.
is_recoverable_error() {
    local classification
    classification=$(classify_error "$1" "$2")
    [[ "$classification" != "FATAL" && "$classification" != "SUCCESS" ]]
}
