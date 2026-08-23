#!/usr/bin/env bash
# label-preflight.sh — Shared "loud failure" helper for applying a label a
# role has already decided on (#6716).
#
# Problem this closes: a role (Curator/Builder/Judge/Champion/...) picks a
# label based on its own judgment (e.g. loom:operator-mechanical), calls `gh
# issue edit --add-label`, and that call can fail SILENTLY if the label
# simply doesn't exist in THIS repo's live label set -- gh reports the
# failure on stderr, but nothing structurally distinguishes "this label
# genuinely doesn't apply here" from "this label doesn't exist here at all".
# The kicad-tools#4507 incident was only recoverable because the agent
# happened to write a prose note about degrading to a different label --
# nothing else ever noticed, and a downstream operator census tool silently
# mis-bucketed every affected issue as a result (see #6716).
#
# Source this file (do not exec). Defines:
#
#   loom_label_exists <label> [-R OWNER/NAME]
#     Returns 0 if <label> exists in the target repo's live label set
#     (GitHub only -- see below), 1 otherwise. Best-effort: a `gh` failure
#     (auth, network, wrong repo) is treated the same as "does not exist"
#     (fails closed) -- a caller that proceeds anyway hits the same
#     underlying gh failure regardless, so failing closed here never masks
#     a real problem.
#
#   loom_apply_issue_label <issue-number> <label> [-R OWNER/NAME]
#   loom_apply_pr_label    <pr-number>    <label> [-R OWNER/NAME]
#     Applies <label> via `gh issue edit --add-label` / `gh pr edit
#     --add-label`. Silent on success (matches this codebase's existing
#     convention: success is the expected case and does not need
#     narration). On failure, prints ONE of two greppable, structured stderr
#     lines -- never a bare/ad-hoc prose note -- and returns non-zero:
#
#       LOOM-LABEL-MISSING: ...       the label does not exist in this repo
#                                     at all -- the #6716 failure mode.
#                                     Names the remediation
#                                     (sync-labels.sh / resync-installed.sh).
#       LOOM-LABEL-APPLY-FAILED: ...  the label exists but gh's edit call
#                                     still failed (permissions, rate limit,
#                                     wrong issue/PR number, ...).
#
#     Both markers are meant to be grep'd — by a human triaging a run's
#     output, or by future tooling (e.g. an Auditor pass) that wants to
#     detect this failure mode across every role's session log without
#     depending on any one agent having written a prose note about it.
#
#     GitHub only: `gh issue edit` / `gh pr edit --add-label` are GitHub-CLI
#     specific. A Gitea caller should use its own forge-helpers.sh path
#     instead and does not need to source this file.
#
# Adoption note: this lib is not wired into any role prompt by this same
# change (#6716) -- retrofitting every `--add-label` call site across
# .claude/commands/loom/*.md is a separate, larger follow-up. This file is
# the shared mechanism those call sites can converge on incrementally,
# matching the idempotent-preflight pattern already established ad hoc in
# epic.md's "Ensure Epic Labels Exist" section (which creates a label before
# using it, rather than failing loudly after the fact -- a role that wants
# create-then-apply semantics instead of loud-failure semantics should keep
# using that pattern directly).

[[ -n "${_LOOM_LABEL_PREFLIGHT_SOURCED:-}" ]] && return 0
_LOOM_LABEL_PREFLIGHT_SOURCED=1

# loom_label_exists <label> [-R OWNER/NAME]
loom_label_exists() {
    local label="$1"
    shift
    local -a repo_flag=()
    if [[ "${1:-}" == "-R" && -n "${2:-}" ]]; then
        repo_flag=(-R "$2")
    fi
    gh label list "${repo_flag[@]}" --json name --jq '.[].name' --limit 300 2>/dev/null \
        | grep -qxF "$label"
}

# _loom_apply_label <issue|pr> <ref> <label> [-R OWNER/NAME]
#   Shared implementation behind loom_apply_issue_label / loom_apply_pr_label.
_loom_apply_label() {
    local kind="$1" ref="$2" label="$3"
    shift 3
    local -a repo_flag=()
    if [[ "${1:-}" == "-R" && -n "${2:-}" ]]; then
        repo_flag=(-R "$2")
    fi

    local output
    if output=$(gh "$kind" edit "$ref" "${repo_flag[@]}" --add-label "$label" 2>&1); then
        return 0
    fi

    local repo_desc=""
    [[ -n "${repo_flag[1]:-}" ]] && repo_desc=" repo=\"${repo_flag[1]}\""

    if loom_label_exists "$label" "${repo_flag[@]}"; then
        echo "LOOM-LABEL-APPLY-FAILED: label=\"$label\" target=\"$kind #$ref\"$repo_desc -- $output" >&2
    else
        echo "LOOM-LABEL-MISSING: label=\"$label\" target=\"$kind #$ref\"$repo_desc -- label does not exist in this repo's live label set. Run .loom/scripts/sync-labels.sh (or wait for the next resync-installed.sh pass, #6716) to create the standard Loom label set, then retry." >&2
    fi
    return 1
}

# loom_apply_issue_label <issue-number> <label> [-R OWNER/NAME]
loom_apply_issue_label() { _loom_apply_label "issue" "$@"; }

# loom_apply_pr_label <pr-number> <label> [-R OWNER/NAME]
loom_apply_pr_label() { _loom_apply_label "pr" "$@"; }
