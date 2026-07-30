#!/bin/bash

# check-duplicate.sh - Check for potential duplicate issues before creating new ones
#
# This script searches existing open issues for potential duplicates based on
# keyword matching and similarity heuristics. Used by Architect, Hermit, and
# Auditor roles before creating new issues.
#
# With --include-merged-prs, also checks recently merged PRs and recently
# closed issues to catch near-duplicate issues that arrive right after their
# counterpart's PR merges.
#
# Usage:
#   check-duplicate.sh "Issue title" ["Issue body"]
#   check-duplicate.sh --title "Issue title" [--body "Issue body"]
#   check-duplicate.sh --include-merged-prs --title "Issue title"
#   check-duplicate.sh --help
#
# Exit codes:
#   0 - No duplicates found, safe to create issue
#   1 - Potential duplicates found (listed to stdout)
#   2 - Error (invalid arguments, gh command failed, etc.)
#
# Output format (when duplicates found):
#   DUPLICATE_FOUND
#   #<number>: <title> (similarity: <percent>%)
#   PR #<number>: <title> (similarity: <percent>%)
#   ...
#
# Degenerate-result self-detection (#4409): if more than half of the
# candidates scanned in a given search (open issues / merged PRs / closed
# issues) score at/above --threshold, that search's similarity scores aren't
# discriminating anything for this query. Its block prints NON_DISCRIMINATIVE
# instead of DUPLICATE_FOUND (still exit code 1, so existing
# `if ! check-duplicate.sh ...` callers still fall back to manual review --
# they just should NOT treat the (absent) match list as real duplicates).

set -euo pipefail

# Minimum number of scanned candidates before degenerate-result
# self-detection (#4409) kicks in. Below this, "more than half matched" is
# not a meaningful signal -- e.g. with only 1 candidate scanned, a single
# real match is trivially ">50%" even though nothing about the scorer is
# actually broken. 4 is a low floor chosen to still catch the reported
# failure mode (dozens of candidates ~all scoring at/above threshold) while
# not misfiring on small candidate pools.
readonly MIN_SCANNED_FOR_DEGENERATE=4

# Forge-agnostic issue/PR operations via the native `loom-daemon forge`
# subcommand (port of the retired `loom-forge`). On GitHub it is a byte-identical
# passthrough to `gh`; on Gitea it declines (exit 3) and the caller degrades to
# the `gh` fallback. Validate loom-daemon actually works (not just on PATH), then
# keep the `gh` fallback so a workspace with no loom-daemon still functions.
if command -v loom-daemon &>/dev/null && loom-daemon --version &>/dev/null; then
    FORGE="loom-daemon forge"
else
    if command -v loom-daemon &>/dev/null; then
        echo "WARNING: loom-daemon is on PATH but non-functional, falling back to gh" >&2
    fi
    FORGE="gh"
fi

# Colors for output (only when stderr is a terminal)
if [[ -t 2 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    NC=''
fi

print_error() {
    echo -e "${RED}ERROR: $1${NC}" >&2
}

print_warning() {
    echo -e "${YELLOW}WARNING: $1${NC}" >&2
}

print_success() {
    echo -e "${GREEN}$1${NC}" >&2
}

print_help() {
    cat << 'EOF'
check-duplicate.sh - Check for potential duplicate issues

USAGE:
    check-duplicate.sh "Issue title" ["Issue body"]
    check-duplicate.sh --title "Issue title" [--body "Issue body"]
    check-duplicate.sh --threshold 50 --title "Title"
    check-duplicate.sh --include-merged-prs --title "Title"
    check-duplicate.sh --issue 42 --title "Title"

OPTIONS:
    --title TEXT            The title of the issue to check
    --body TEXT             The body/description of the issue (optional)
    --threshold NUM         Similarity threshold percentage, on a true Jaccard
                             scale -- matches / |union| (default: 18). 60%+
                             Jaccard is rarely reachable on richly-worded
                             bodies; 18 is calibrated against real historical
                             pairs from this repo (#4409): a confirmed
                             duplicate (#3550/#3551) scored 19%, while
                             unrelated richly-worded issues scored 4-13%.
                             This is a noisy signal on long, jargon-heavy
                             bodies (a second real duplicate pair scored only
                             13%, indistinguishable from unrelated) -- treat
                             a miss as inconclusive, not proof of no overlap.
    --include-merged-prs    Also check recently merged PRs and closed issues
    --issue N               Also probe for OPEN issues/PRs that cross-reference
                             issue N (GitHub timeline API). Curator use --
                             surfaces "related open work" distinct from
                             duplicates: open items that may already argue for
                             a different spec for N. GitHub-only; a non-GitHub
                             forge or API failure skips the probe with a
                             warning rather than failing the whole check.
    --json                  Output results as JSON
    --help                  Show this help message

EXAMPLES:
    # Check if an issue about button styling might be a duplicate
    check-duplicate.sh "Fix button styling in dark mode"

    # Check with body content for better matching
    check-duplicate.sh --title "Fix crash on startup" --body "App crashes when..."

    # Use custom threshold (lower = more matches)
    check-duplicate.sh --threshold 40 "Refactor authentication module"

    # Also check recently merged PRs and closed issues
    check-duplicate.sh --include-merged-prs "Refactor authentication module"

    # Also surface open work that cross-references issue #42
    check-duplicate.sh --issue 42 --title "Refactor authentication module"

EXIT CODES:
    0  No duplicates (and, with --issue, no related open work) found
    1  Potential duplicates (or related open work) found (listed to stdout)
    2  Error (invalid arguments, gh command failed, etc.)

INTEGRATION:
    Use in Architect/Hermit/Auditor roles before gh issue create:

    if ./.loom/scripts/check-duplicate.sh "My issue title"; then
        gh issue create --title "My issue title" ...
    else
        echo "Potential duplicate detected, skipping creation"
    fi

    Use with --include-merged-prs in Curator/Guide roles:

    if ! ./.loom/scripts/check-duplicate.sh --include-merged-prs "$TITLE" "$BODY"; then
        echo "Potential overlap with merged PR or closed issue"
    fi

    Use with --issue N in the Curator role, before enriching issue N, to
    surface open cross-referencing work that may already argue for a
    different spec (issue #4162):

    if ! ./.loom/scripts/check-duplicate.sh --include-merged-prs --issue "$N" "$TITLE" "$BODY"; then
        echo "Read the DUPLICATE_FOUND / RELATED_OPEN_WORK output before curating"
    fi
EOF
}

# Extract keywords from text (removes common words, punctuation)
extract_keywords() {
    local text="$1"

    # Convert to lowercase, remove punctuation, split into words
    # Filter out common stop words and short words
    echo "$text" | \
        tr '[:upper:]' '[:lower:]' | \
        tr -cs '[:alnum:]' '\n' | \
        grep -v '^$' | \
        grep -v -E '^(the|a|an|is|are|was|were|be|been|being|have|has|had|do|does|did|will|would|could|should|may|might|must|shall|can|need|dare|ought|used|to|of|in|for|on|with|at|by|from|up|about|into|over|after|beneath|under|above|and|but|or|nor|so|yet|both|either|neither|not|only|own|same|than|too|very|just|also|now|here|there|when|where|why|how|all|each|every|both|few|more|most|other|some|such|no|any|this|that|these|those|what|which|who|whom|whose|it|its|i|me|my|we|our|you|your|he|him|his|she|her|they|them|their|add|fix|update|remove|change|make|get|set|new|use|work|file|code|test|error|bug|feature|issue|pr|pull|request)$' | \
        grep -E '.{3,}' | \
        sort -u
}

# Calculate word overlap percentage between two keyword sets
calculate_similarity() {
    local keywords1="$1"
    local keywords2="$2"

    # Convert the newline-delimited keyword lists (one keyword per line, from
    # extract_keywords' `sort -u`) into arrays. NOTE (#4409): `read -ra arr <<<
    # "$multiline_str"` looks like it splits on all IFS whitespace, but `read`
    # only ever consumes a SINGLE LINE of its input -- everything after the
    # first newline is silently discarded. Since each keyword already sits on
    # its own line, that made arr1/arr2 collapse to a ONE-ELEMENT array (just
    # the alphabetically-first keyword) for any multi-keyword input, turning
    # every comparison into a coin flip on that one token (0% or 100%) instead
    # of a real set comparison -- this is bash's `read` semantics in every
    # version, not a bash-3.2-only quirk. `mapfile`/`readarray` would fix it
    # but require bash 4+, which macOS's shipped `/bin/bash` (3.2) doesn't
    # have; splitting on IFS=$'\n' via an unquoted array assignment works on
    # both and keeps this script bash-3.2-safe.
    # The unquoted array assignments below are the intended word split (one
    # array element per keyword line) -- `set -f` around them neutralizes the
    # linter's other concern (accidental pathname/glob expansion) even though
    # extract_keywords' alnum-only filter already guarantees no keyword can
    # contain a glob metacharacter.
    local -a arr1
    local -a arr2
    local old_ifs="$IFS"
    IFS=$'\n'
    set -f
    # shellcheck disable=SC2206 # unquoted-intentionally, see comment above
    arr1=($keywords1)
    # shellcheck disable=SC2206 # unquoted-intentionally, see comment above
    arr2=($keywords2)
    set +f
    IFS="$old_ifs"

    # Handle empty arrays
    if [[ ${#arr1[@]} -eq 0 ]] || [[ ${#arr2[@]} -eq 0 ]]; then
        echo "0"
        return
    fi

    # Count matches
    local matches=0
    for word1 in "${arr1[@]}"; do
        for word2 in "${arr2[@]}"; do
            if [[ "$word1" == "$word2" ]]; then
                ((matches++)) || true
                break
            fi
        done
    done

    # True Jaccard similarity: matches / |union| = matches / (|A|+|B|-matches).
    # (Previously normalized by the SMALLER set: percent = matches*100/min(|A|,|B|).
    # That normalization saturates near 100% whenever one set is much larger
    # than the other -- e.g. a full issue body (hundreds of keywords) compared
    # against a short candidate title+body: matches approaches |B| regardless
    # of actual relatedness. True Jaccard is symmetric and bounded by the
    # union, so a large query set dilutes rather than saturates. See #4409.)
    local union=$(( ${#arr1[@]} + ${#arr2[@]} - matches ))
    if [[ $union -eq 0 ]]; then
        echo "0"
        return
    fi

    local percent=$((matches * 100 / union))
    echo "$percent"
}

# Search for similar issues
search_similar_issues() {
    local title="$1"
    local body="${2:-}"
    local threshold="${3:-18}"

    # Extract keywords from new issue
    local new_keywords
    new_keywords=$(extract_keywords "$title $body")

    if [[ -z "$new_keywords" ]]; then
        print_warning "No significant keywords extracted from title/body"
        return 0
    fi

    # Search open issues
    local issues
    if ! issues=$($FORGE issue list --state=open --limit=50 --json number,title,body 2>&1); then
        print_error "Failed to fetch issues: $issues"
        return 2
    fi

    # Process each issue for similarity
    local scanned=0
    local matched=0
    local duplicates=""

    while IFS= read -r issue; do
        local num title_text body_text
        num=$(echo "$issue" | jq -r '.number')
        title_text=$(echo "$issue" | jq -r '.title')
        body_text=$(echo "$issue" | jq -r '.body // ""')

        # Skip if no number
        [[ -z "$num" || "$num" == "null" ]] && continue
        scanned=$((scanned + 1))

        # Extract keywords from existing issue
        local existing_keywords
        existing_keywords=$(extract_keywords "$title_text $body_text")

        # Calculate similarity
        local similarity
        similarity=$(calculate_similarity "$new_keywords" "$existing_keywords")

        if [[ $similarity -ge $threshold ]]; then
            matched=$((matched + 1))
            duplicates+="#${num}: ${title_text} (similarity: ${similarity}%)"$'\n'
        fi
    done < <(echo "$issues" | jq -c '.[]')

    if [[ $matched -eq 0 ]]; then
        return 0
    fi

    # Degenerate-result self-detection (#4409): if more than half of the
    # scanned candidates exceed threshold, the similarity scores aren't
    # discriminating anything for this query -- warn instead of dumping a
    # wall of "duplicates" that's really just noise.
    if [[ $scanned -ge $MIN_SCANNED_FOR_DEGENERATE ]] && (( matched * 2 > scanned )); then
        echo "NON_DISCRIMINATIVE (open issues): ${matched} of ${scanned} candidates scored >= ${threshold}% similarity -- not discriminative, fall back to manual review (e.g. gh issue list --search)."
        return 1
    fi

    echo "DUPLICATE_FOUND"
    echo -n "$duplicates"
    return 1
}

# Search for similar recently merged PRs
search_merged_prs() {
    local title="$1"
    local body="${2:-}"
    local threshold="${3:-18}"

    # Extract keywords from new issue
    local new_keywords
    new_keywords=$(extract_keywords "$title $body")

    if [[ -z "$new_keywords" ]]; then
        return 0
    fi

    # Search recently merged PRs
    local prs
    if ! prs=$($FORGE pr list --state=merged --limit=20 --json number,title,body 2>&1); then
        print_warning "Failed to fetch merged PRs: $prs"
        return 0
    fi

    # Process each PR for similarity
    local scanned=0
    local matched=0
    local duplicates=""

    while IFS= read -r pr; do
        local num title_text body_text
        num=$(echo "$pr" | jq -r '.number')
        title_text=$(echo "$pr" | jq -r '.title')
        body_text=$(echo "$pr" | jq -r '.body // ""')

        # Skip if no number
        [[ -z "$num" || "$num" == "null" ]] && continue
        scanned=$((scanned + 1))

        # Extract keywords from existing PR
        local existing_keywords
        existing_keywords=$(extract_keywords "$title_text $body_text")

        # Calculate similarity
        local similarity
        similarity=$(calculate_similarity "$new_keywords" "$existing_keywords")

        if [[ $similarity -ge $threshold ]]; then
            matched=$((matched + 1))
            duplicates+="PR #${num}: ${title_text} (similarity: ${similarity}%)"$'\n'
        fi
    done < <(echo "$prs" | jq -c '.[]')

    if [[ $matched -eq 0 ]]; then
        return 0
    fi

    # Degenerate-result self-detection (#4409), same as search_similar_issues.
    if [[ $scanned -ge $MIN_SCANNED_FOR_DEGENERATE ]] && (( matched * 2 > scanned )); then
        echo "NON_DISCRIMINATIVE (merged PRs): ${matched} of ${scanned} candidates scored >= ${threshold}% similarity -- not discriminative, fall back to manual review."
        return 0
    fi

    echo -n "$duplicates"
}

# Search for similar recently closed issues
search_closed_issues() {
    local title="$1"
    local body="${2:-}"
    local threshold="${3:-18}"

    # Extract keywords from new issue
    local new_keywords
    new_keywords=$(extract_keywords "$title $body")

    if [[ -z "$new_keywords" ]]; then
        return 0
    fi

    # Search recently closed issues
    local issues
    if ! issues=$($FORGE issue list --state=closed --limit=20 --json number,title,body 2>&1); then
        print_warning "Failed to fetch closed issues: $issues"
        return 0
    fi

    # Process each issue for similarity
    local scanned=0
    local matched=0
    local duplicates=""

    while IFS= read -r issue; do
        local num title_text body_text
        num=$(echo "$issue" | jq -r '.number')
        title_text=$(echo "$issue" | jq -r '.title')
        body_text=$(echo "$issue" | jq -r '.body // ""')

        # Skip if no number
        [[ -z "$num" || "$num" == "null" ]] && continue
        scanned=$((scanned + 1))

        # Extract keywords from existing issue
        local existing_keywords
        existing_keywords=$(extract_keywords "$title_text $body_text")

        # Calculate similarity
        local similarity
        similarity=$(calculate_similarity "$new_keywords" "$existing_keywords")

        if [[ $similarity -ge $threshold ]]; then
            matched=$((matched + 1))
            duplicates+="Closed #${num}: ${title_text} (similarity: ${similarity}%)"$'\n'
        fi
    done < <(echo "$issues" | jq -c '.[]')

    if [[ $matched -eq 0 ]]; then
        return 0
    fi

    # Degenerate-result self-detection (#4409), same as search_similar_issues.
    if [[ $scanned -ge $MIN_SCANNED_FOR_DEGENERATE ]] && (( matched * 2 > scanned )); then
        echo "NON_DISCRIMINATIVE (closed issues): ${matched} of ${scanned} candidates scored >= ${threshold}% similarity -- not discriminative, fall back to manual review."
        return 0
    fi

    echo -n "$duplicates"
}

# Probe for OPEN issues/PRs whose bodies or comments cross-reference the given
# issue number (issue #4162). This answers a different question than
# duplicate detection above: not "is this the same issue" but "is there open
# work that already argues for a different/changed spec for this issue" --
# e.g. an open issue that critiques/rewrites #N's acceptance criteria via a
# cross-reference in its body. Uses GitHub's timeline API (the same
# `cross-referenced` event already used for PR detection in
# .claude/commands/loom/sweep.md's existing-PR probe), which surfaces every
# `#N` mention regardless of similarity -- no local text/keyword matching.
#
# GitHub-specific. Gracefully degrades (stderr warning, empty result, does
# NOT fail the whole duplicate check) when `gh` is missing, the repo can't be
# resolved (e.g. a Gitea remote `gh` doesn't recognize), or the API call
# fails -- same pattern as search_merged_prs() above.
#
# Outputs a JSON array of {number, title, is_pr} for OPEN, same-repo,
# non-self cross-references, deduped by number. Emits "[]" on any failure.
search_cross_references() {
    local issue_num="$1"

    if ! command -v gh &>/dev/null; then
        print_warning "gh CLI not found; skipping cross-reference probe for #${issue_num}"
        echo "[]"
        return 0
    fi

    local repo_nwo
    if ! repo_nwo=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>&1); then
        print_warning "Failed to resolve repository for cross-reference probe (non-GitHub forge?): $repo_nwo"
        echo "[]"
        return 0
    fi

    local timeline
    if ! timeline=$(gh api "repos/${repo_nwo}/issues/${issue_num}/timeline" --paginate 2>&1); then
        print_warning "Failed to fetch timeline for #${issue_num}: $timeline"
        echo "[]"
        return 0
    fi

    echo "$timeline" | jq -c --arg repo "$repo_nwo" --argjson self "$issue_num" '
        [.[] | select(.event == "cross-referenced"
                       and .source.issue != null
                       and (.source.issue.repository.full_name // "") == $repo
                       and .source.issue.number != $self
                       and .source.issue.state == "open")
         | {number: .source.issue.number,
            title: .source.issue.title,
            is_pr: (.source.issue.pull_request != null)}]
        | unique_by(.number)
    ' 2>/dev/null || echo "[]"
}

# Format a RELATED_OPEN_WORK JSON array (from search_cross_references) into
# the human-readable lines used by the text-output mode.
format_related_open_work() {
    local issue_num="$1"
    local json_array="$2"

    echo "$json_array" | jq -r --arg n "$issue_num" '
        .[] | (if .is_pr then "PR #" else "#" end) + (.number | tostring) + ": " + .title +
              (if .is_pr then " (open PR, cross-references #" else " (open issue, cross-references #" end) + $n + ")"
    '
}

# Main function
main() {
    local title=""
    local body=""
    local threshold=18
    local json_output=false
    local include_merged_prs=false
    local issue=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                print_help
                exit 0
                ;;
            --title)
                shift
                title="$1"
                ;;
            --body)
                shift
                body="$1"
                ;;
            --threshold)
                shift
                threshold="$1"
                ;;
            --include-merged-prs)
                include_merged_prs=true
                ;;
            --issue)
                shift
                issue="$1"
                ;;
            --json)
                json_output=true
                ;;
            -*)
                print_error "Unknown option: $1"
                print_help >&2
                exit 2
                ;;
            *)
                # Positional arguments: first is title, second is body
                if [[ -z "$title" ]]; then
                    title="$1"
                elif [[ -z "$body" ]]; then
                    body="$1"
                else
                    print_error "Too many arguments"
                    print_help >&2
                    exit 2
                fi
                ;;
        esac
        shift
    done

    # Validate required arguments
    if [[ -z "$title" ]]; then
        print_error "Issue title is required"
        print_help >&2
        exit 2
    fi

    # Validate threshold is a number
    if ! [[ "$threshold" =~ ^[0-9]+$ ]]; then
        print_error "Threshold must be a number"
        exit 2
    fi

    # Validate --issue is a number, when given
    if [[ -n "$issue" ]] && ! [[ "$issue" =~ ^[0-9]+$ ]]; then
        print_error "--issue must be a number"
        exit 2
    fi

    # Check for forge CLI. $FORGE may be two words ("loom-daemon forge"), so
    # probe only the binary name (its first word).
    if ! command -v "${FORGE%% *}" &> /dev/null; then
        print_error "$FORGE CLI not found. Please install loom-daemon or GitHub CLI."
        exit 2
    fi

    # Check forge authentication
    if ! $FORGE auth status &> /dev/null; then
        print_error "Not authenticated with forge. Run 'gh auth login' (GitHub) or set GITEA_TOKEN (Gitea)."
        exit 2
    fi

    # Search for similar issues
    local result
    local exit_code=0
    result=$(search_similar_issues "$title" "$body" "$threshold") || exit_code=$?

    # If --include-merged-prs, also search merged PRs and closed issues
    local merged_result=""
    local closed_result=""
    if $include_merged_prs; then
        merged_result=$(search_merged_prs "$title" "$body" "$threshold")
        closed_result=$(search_closed_issues "$title" "$body" "$threshold")

        # If we found matches in merged PRs or closed issues, flag as duplicate
        if [[ -n "$merged_result" || -n "$closed_result" ]]; then
            if [[ $exit_code -eq 0 ]]; then
                # No open issue duplicates found, but merged/closed matches
                # exist. Only synthesize a "DUPLICATE_FOUND" umbrella header
                # when at least one of merged/closed is a real match list --
                # a degenerate (#4409) result already self-announces with its
                # own "NON_DISCRIMINATIVE (...)" line, and prefixing THAT
                # with "DUPLICATE_FOUND" would be misleading. Check each side
                # independently (not "both must be non-degenerate") so a real
                # match on one side still gets its header even when the other
                # side is degenerate.
                if [[ ( -n "$merged_result" && "$merged_result" != NON_DISCRIMINATIVE* ) || \
                      ( -n "$closed_result" && "$closed_result" != NON_DISCRIMINATIVE* ) ]]; then
                    result="DUPLICATE_FOUND"$'\n'
                fi
                exit_code=1
            fi
            if [[ -n "$merged_result" ]]; then
                result+="$merged_result"$'\n'
            fi
            if [[ -n "$closed_result" ]]; then
                result+="$closed_result"$'\n'
            fi
        fi
    fi

    # Cross-reference probe (--issue N only, issue #4162). Distinct from
    # duplicate detection above: surfaces OPEN issues/PRs that already
    # cross-reference N, as "related open work" the Curator must read. Skip
    # entirely when the base similarity check already hard-failed (exit 2) --
    # no point probing on top of an already-broken forge call.
    local related_json="[]"
    local related_count=0
    if [[ -n "$issue" && $exit_code -ne 2 ]]; then
        related_json=$(search_cross_references "$issue")
        related_count=$(echo "$related_json" | jq 'length' 2>/dev/null || echo 0)
        if [[ "$related_count" -gt 0 ]]; then
            exit_code=1
        fi
    fi

    if $json_output; then
        if [[ $exit_code -eq 2 ]]; then
            echo '{"error": "Failed to check duplicates"}'
        else
            # Degenerate-result flag (#4409): true when any search's
            # candidate pool self-detected as non-discriminative (>50% of
            # scanned candidates over threshold). Surfaced separately from
            # `matches` so callers can distinguish a real duplicate list from
            # noise instead of silently misreading one as the other.
            local degenerate=false
            if echo "$result" | grep -q '^NON_DISCRIMINATIVE'; then
                degenerate=true
            fi

            # Parse duplicates into JSON (unconditional -- harmless no-op on
            # an empty $result, e.g. exit_code 0 or "related work only")
            local matches="[]"
            while IFS= read -r line; do
                [[ "$line" == "DUPLICATE_FOUND" ]] && continue
                [[ "$line" == NON_DISCRIMINATIVE* ]] && continue
                [[ -z "$line" ]] && continue

                # Parse "#123: Title (similarity: 75%)" or "PR #123: Title (similarity: 75%)"
                # or "Closed #123: Title (similarity: 75%)"
                local num title_part sim match_type
                if [[ "$line" == PR\ * ]]; then
                    match_type="pr"
                    num=$(echo "$line" | sed -n 's/^PR #\([0-9]*\):.*/\1/p')
                    title_part=$(echo "$line" | sed -n 's/^PR #[0-9]*: \(.*\) (similarity:.*/\1/p')
                elif [[ "$line" == Closed\ * ]]; then
                    match_type="closed_issue"
                    num=$(echo "$line" | sed -n 's/^Closed #\([0-9]*\):.*/\1/p')
                    title_part=$(echo "$line" | sed -n 's/^Closed #[0-9]*: \(.*\) (similarity:.*/\1/p')
                else
                    match_type="issue"
                    num=$(echo "$line" | sed -n 's/^#\([0-9]*\):.*/\1/p')
                    title_part=$(echo "$line" | sed -n 's/^#[0-9]*: \(.*\) (similarity:.*/\1/p')
                fi
                sim=$(echo "$line" | sed -n 's/.*(similarity: \([0-9]*\)%).*/\1/p')

                if [[ -n "$num" ]]; then
                    matches=$(echo "$matches" | jq --arg n "$num" --arg t "$title_part" --arg s "$sim" --arg type "$match_type" \
                        '. + [{"number": ($n | tonumber), "title": $t, "similarity": ($s | tonumber), "type": $type}]')
                fi
            done <<< "$result"

            if [[ "$related_count" -gt 0 ]]; then
                local cross_matches
                cross_matches=$(echo "$related_json" | jq '[.[] | {number, title, similarity: 0, type: "cross_reference"}]')
                matches=$(echo "$matches" | jq --argjson extra "$cross_matches" '. + $extra')
            fi

            if [[ "$matches" == "[]" ]]; then
                if $degenerate; then
                    echo "{\"duplicate_found\": false, \"degenerate\": true, \"matches\": []}"
                else
                    echo '{"duplicate_found": false, "degenerate": false, "matches": []}'
                fi
            else
                echo "{\"duplicate_found\": true, \"degenerate\": $degenerate, \"matches\": $matches}"
            fi
        fi
    else
        if [[ $exit_code -eq 0 ]]; then
            print_success "No duplicates found"
        else
            echo "$result"
            if [[ "$related_count" -gt 0 ]]; then
                echo "RELATED_OPEN_WORK"
                format_related_open_work "$issue" "$related_json"
            fi
        fi
    fi

    exit $exit_code
}

main "$@"
