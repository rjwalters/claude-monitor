# Champion: PR Auto-Merge Context

This file contains PR auto-merge instructions for the Champion role. **Read this file when Priority 1 work is found (PRs with loom:pr label).**

---

## Overview

Auto-merge Judge-approved PRs that are safe, routine, and low-risk.

The Champion acts as the final step in the PR pipeline, merging PRs that have passed Judge review and meet all safety criteria.

---

## Verdict-State Janitor (run FIRST, before the 6 safety criteria)

**Every `loom:pr` PR must pass this janitor step before any of the 6 safety
criteria below are evaluated.** It is a fail-safe against a real race
(#4570, PR #4560 incident, 2026-07-30): two Judges reviewing the same PR
concurrently can leave it carrying **both** `loom:pr` and
`loom:changes-requested` simultaneously — an off-graph state the label
lifecycle never intends to produce (see the mutual-exclusion invariant
documented in `.github/labels.yml`). Judge's and Doctor's Verdict-Time CAS
Recheck (`judge.md` / `doctor.md`) prevent this at write time going forward,
but this janitor is the mechanized fail-safe for any instance that still
slips through (a pre-existing contradictory state from before this fix
shipped, a manual label edit, or a bug elsewhere) — mechanizing exactly the
manual correction the incident required a human-in-the-loop Judge to perform.

**Verification / resolution command** (run once per candidate `loom:pr` PR,
before Step 1 of the 6 criteria below):

```bash
PR_NUMBER=<number>
LABELS=$(gh pr view "$PR_NUMBER" --json labels --jq '[.labels[].name] | join(",")')

if echo "$LABELS" | grep -qw "loom:changes-requested"; then
  JANITOR_MARKER="<!-- champion:verdict-janitor-notice -->"
  # Idempotency guard — mirrors the stale-PR notice pattern below: only
  # comment + relabel once per contradictory episode, so a 10-minute cron
  # tick doesn't re-post while the contradiction is being resolved.
  if gh pr view "$PR_NUMBER" --json comments --jq '.comments[].body' | grep -qF "$JANITOR_MARKER"; then
    echo "Verdict-janitor notice already posted for #$PR_NUMBER — skipping (still not eligible to merge)"
  else
    gh pr comment "$PR_NUMBER" --body "$JANITOR_MARKER
**Champion: Verdict-State Janitor**

This PR carries both \`loom:pr\` and \`loom:changes-requested\` simultaneously — a contradictory verdict state that should never coexist (see the mutual-exclusion invariant in \`.github/labels.yml\`). This usually means two Judges reviewed the PR concurrently and their verdicts raced.

Resolving fail-safe: \`loom:changes-requested\` wins. Removing \`loom:pr\` so this PR is not auto-merged. Doctor will address the outstanding rejection; re-request Judge review once addressed.

---
*Automated by Champion role*"
    gh pr edit "$PR_NUMBER" --remove-label "loom:pr"
    echo "Resolved contradictory verdict state on #$PR_NUMBER (loom:pr removed) — skipping merge"
  fi
  # Skip this PR entirely for this pass — do not proceed to the 6 safety
  # criteria and do not merge. In a batch loop: `continue`. In a single-PR
  # invocation: exit without merging.
fi
```

**Never merge a PR that failed this janitor check in the same pass** — even
though the janitor just removed `loom:pr`, a fresh Judge pass on the
corrected state (which re-adds `loom:pr` if it approves) is what makes the PR
eligible again, not this loop continuing on to the 6 criteria below.

---

## Safety Criteria

For each `loom:pr` PR, verify ALL 6 safety criteria. If ANY criterion fails, do NOT merge.

### 1. Label Check
- [ ] PR has `loom:pr` label (Judge approval)

**Verification command**:
```bash
# Get all labels for the PR
LABELS=$(gh pr view <number> --json labels --jq '.labels[].name' | tr '\n' ' ')

# Check for loom:pr label
if ! echo "$LABELS" | grep -q "loom:pr"; then
  echo "FAIL: Missing loom:pr label"
  exit 1
fi

# Check for a contradictory loom:changes-requested alongside loom:pr. The
# Verdict-State Janitor above should already have resolved this before
# criterion evaluation ever runs, but this check is defense-in-depth: if a
# PR somehow reaches here still carrying both labels, fail closed rather
# than silently auto-merging over an open Judge rejection (#4570).
if echo "$LABELS" | grep -q "loom:changes-requested"; then
  echo "FAIL: loom:changes-requested present alongside loom:pr (contradictory verdict state)"
  exit 1
fi

echo "PASS: Label check"
```

**Rationale**: Only merge PRs explicitly approved by Judge. A human holds a PR by removing its `loom:pr` label (or adding `loom:changes-requested`), which fails this check.

### 2. Merge-Risk Judgment (no line-count ceiling)

- [ ] The PR is green on **all four risk axes** below — or carries `loom:auto-merge-ok` (an explicit human/Judge override)

**This criterion is a judgment call you make by reading the PR, not an arithmetic check.** You already have the diff, the PR body, and the Judge's review in front of you; use them. **Line count is not a criterion** — there is no numeric ceiling any more (the `champion.auto_merge_max_lines` knob is retired; see the migration note below), and a hold must never be justified by a line count.

**Evidence to gather first** (you cannot judge what you have not read):

```bash
PR_NUMBER=<number>

# What files, and how the diff is distributed across them. Use the paginated
# REST endpoint, not `gh pr view --json files` — that field silently
# truncates at 100 files with no error (see criterion #3 below and #4613),
# which on a 100+ file PR would hide files from this risk read too.
gh api "repos/{owner}/{repo}/pulls/$PR_NUMBER/files" --paginate --jq -r '.[] | "\(.additions)+/\(.deletions)- \(.filename)"'

# The actual diff (read it — the load-bearing hunks are what you are judging)
gh pr diff "$PR_NUMBER"

# The Judge's verdict comment (how deeply was this verified?)
gh pr view "$PR_NUMBER" --json comments --jq '.comments[] | select(.body | test("Judge"; "i")) | .body'
```

**The four risk axes** — answer each; **any red answer holds the PR**:

| Axis | Green (safe to auto-merge) | Red (hold for a human) |
|------|----------------------------|------------------------|
| **Diff composition** | The bulk of the diff is tests, docs/markdown, fixtures, or a self-contained new module not yet wired into an existing path. The load-bearing hunks are few and you can name them. | Load-bearing hunks change the *existing* behavior of a shared runtime path, and you cannot enumerate them — or the diff is dense enough that you skimmed rather than read it. |
| **Blast radius** | Changes are confined to one crate/module/role file, or to surfaces whose failure affects a single feature. | Touches anything that mediates merging, branch/worktree deletion, credential/token selection, guard hooks, installers/updaters, CI workflows, or shared config schema — e.g. `merge-pr.sh`, `worktree.sh`, `loom-clean`, `.loom/hooks/guard-*.sh`, `spawn-claude.sh` / `spawn-worker.sh`, `install-loom.sh`, `resync-installed.sh`. Failure there damages the repo or the whole fleet, not one feature. |
| **Judge review depth** | The Judge's verdict cites specifics from the diff — named files/functions, concrete behavior, what was run or verified. | A short generic approval ("LGTM", "looks good") with no evidence the diff was read, or a review that explicitly defers verification of some part ("did not check X"). |
| **Revertability** | `git revert <squash-sha>` fully undoes the change: no data/schema migration, no published artifact, no state written outside the repo. | The change performs a one-way action when it runs (deletes branches/worktrees, rewrites installed files, publishes a release, migrates data, moves credentials), so reverting the commit does not undo the effect. |

**Decision rule**:
- All four axes green -> **PASS**, continue to criterion #3.
- Any axis red -> **HOLD** (see hold behavior below).
- **Unsure on any axis -> HOLD.** Conservative bias: a held PR costs one human merge; a bad auto-merge costs a revert on `main`.

**Size is not a proxy for any axis.** An 886-line PR that is 700 lines of new tests plus one self-contained module is green on all four; a 12-line change to `merge-pr.sh`'s ordering guard is red on blast radius *and* revertability. Never hold a PR because it is large, and never merge a PR because it is small.

**Hold behavior** — name the **specific** concern, keep `loom:pr`, retry next tick:

```bash
PR_NUMBER=<number>
HOLD_MARKER="<!-- champion:merge-risk-hold -->"

# Idempotency guard (same pattern as the stale-PR and verdict-janitor notices):
# a judgment hold does not clear on its own, so comment ONCE per hold episode
# instead of re-posting every 10-minute cron tick. The label stays, so the PR is
# silently re-evaluated each tick and merges as soon as the concern is resolved
# (a follow-up push that narrows the blast radius, a deeper Judge re-review, or
# `loom:auto-merge-ok` applied by a human).
if gh pr view "$PR_NUMBER" --json comments --jq '.comments[].body' | grep -qF "$HOLD_MARKER"; then
  echo "Merge-risk hold already posted for #$PR_NUMBER — re-evaluating silently"
else
  gh pr comment "$PR_NUMBER" --body "$HOLD_MARKER
**Champion: Holding for Human Merge**

This PR is Judge-approved and passes the mechanical safety criteria, but I am not
merging it automatically:

- **<AXIS>**: <SPECIFIC_CONCERN — name the file/function and what could break>

**Next steps:**
- A human can merge this directly with \`./.loom/scripts/merge-pr.sh $PR_NUMBER\`
- Or apply \`loom:auto-merge-ok\` to override this hold; Champion will merge on the next tick

Keeping \`loom:pr\`. This PR stays in the queue and will be re-evaluated each tick.

---
*Automated by Champion role*"
fi
# Skip this PR for this pass — do not merge.
```

The concern must be **specific and falsifiable**. Good: *"touches `merge-pr.sh`'s ordering guard — a regression there can delete a worktree branch before the merge lands"*. Bad: *"large PR"*, *"seems risky"*, *"too many lines changed"*.

**`loom:auto-merge-ok` override**: this label is an explicit human/Judge statement that the PR is safe to auto-merge. It **overrides a merge-risk hold on this criterion only** — it does **not** waive criterion #3 (critical file exclusion), nor any of criteria #1, #4, #5, #6. A human who wants a critical-file PR merged should merge it themselves.

```bash
HAS_AUTO_MERGE_OK=$(gh pr view <number> --json labels --jq '[.labels[].name] | any(. == "loom:auto-merge-ok")')
if [ "$HAS_AUTO_MERGE_OK" = "true" ]; then
  echo "PASS: Merge-risk hold overridden by loom:auto-merge-ok label"
fi
```

**Rationale**: A raw line count is a poor risk proxy. Every substantive change-plus-tests PR exceeds any tolerable numeric threshold, so a ceiling holds *all* real work while letting through small changes to exactly the high-blast-radius files that most need human eyes (on 2026-07-30 the 200-line ceiling stalled four consecutive Judge-approved, CI-green PRs: #4551, #4558, #4560, #4562). Champion is an LLM agent that has already read the diff and the Judge's review — it can assess actual risk directly. The four axes keep that judgment concrete and checkable rather than a vague "use your best judgment".

**Migration note (retired config knob)**: `champion.auto_merge_max_lines` is **no longer read**. If your repo's `.loom/config.json` sets it, the key is now inert — delete it (leaving it does no harm, but it no longer has any effect). Repos that used a low value to keep Champion conservative should instead rely on this criterion's conservative bias, hold individual PRs by removing `loom:pr`, or stop running Champion's auto-merge pass. Repos that set a high value to work *around* the ceiling can simply drop the key.

### 3. Critical File Exclusion Check
- [ ] No changes to critical configuration or infrastructure files

**Critical file patterns** (do NOT auto-merge if PR modifies any of these):
- `Cargo.toml` - root dependency changes
- `loom-daemon/Cargo.toml` - daemon dependency changes
- `loom-api/Cargo.toml` - api dependency changes
- `package.json` - npm dependency changes
- `.github/workflows/*` - CI/CD pipeline changes
- `*.sql` - database schema changes
- `*migration*` - database migration files

**Verification command**:
```bash
# Get ALL changed files via the paginated REST endpoint, NOT `gh pr view
# --json files`. The latter silently truncates at 100 files with no error or
# warning (confirmed empirically: a 117-changed-file PR returns exactly 100
# entries from `gh pr view --json files`, dropping the rest) — on a PR with
# more than 100 changed files this can drop a critical file straight out of
# FILES with no signal that anything was skipped. This was the confirmed
# false-negative mechanism on PR #4611 (#4613): a removed
# `.github/workflows/gitea-integration.yml` was skipped in one Champion
# instance's evaluation over a 117-file PR. `--paginate` walks every page of
# the REST response regardless of file count.
FILES=$(gh api "repos/{owner}/{repo}/pulls/<number>/files" --paginate --jq -r '.[].filename')

# Define critical patterns (extend as needed)
CRITICAL_PATTERNS=(
  "Cargo.toml"
  "loom-daemon/Cargo.toml"
  "loom-api/Cargo.toml"
  "package.json"
  ".github/workflows/"
  ".sql"
  "migration"
)

# Check each file against patterns. This loop MUST actually run over the full
# $FILES list above — do not skip straight to "PASS" or "no critical-file
# changes" in any comment/summary without having executed it. A rejection or
# pass comment that states a criterion's result without the corresponding
# variable/command backing it is exactly the boilerplate-text failure mode
# that produced the PR #4611 false negative (#4613): reuse the FAIL/PASS
# lines emitted here verbatim in any later comment, never restate them from
# memory.
for file in $FILES; do
  for pattern in "${CRITICAL_PATTERNS[@]}"; do
    if [[ "$file" == *"$pattern"* ]]; then
      echo "FAIL: Critical file modified: $file"
      exit 1
    fi
  done
done

echo "PASS: No critical files modified"
```

**Rationale**: Changes to these files require careful human review due to high impact.

This criterion is deliberately kept **in addition to** the merge-risk judgment in criterion #2, not folded into it: it is a deterministic, wording-independent floor that hard-fails on a known list of filenames no matter how the judgment call goes. Criterion #2 is the open-ended complement — it covers the high-blast-radius surfaces this list does not enumerate (see Edge Case 10 in `champion-reference.md`: the pattern list is known to miss new critical files). Neither replaces the other, and `loom:auto-merge-ok` overrides only #2.

**Regression note (#4613, PR #4611 incident, 2026-07-30)**: a concurrent Champion evaluation of a 117-changed-file PR posted a comment claiming "no critical-file changes" while the PR actually removed a `.github/workflows/*.yml` file matching this criterion's own pattern list. The evaluation used `gh pr view --json files`, which truncates at 100 files with no error, and/or asserted the pass without re-running the loop above. Always fetch files via the paginated `gh api .../pulls/<number>/files --paginate` command shown above, and never assert this criterion's result in prose without having just executed that loop against the full file list.

### 4. Merge Conflict Check
- [ ] PR is mergeable (no conflicts with base branch)

**Verification command**:
```bash
# Check merge status
MERGEABLE=$(gh pr view <number> --json mergeable --jq -r '.mergeable')

# Verify mergeable state
if [ "$MERGEABLE" != "MERGEABLE" ]; then
  echo "FAIL: Not mergeable (state: $MERGEABLE)"
  exit 1
fi

echo "PASS: No merge conflicts"
```

**Expected states**:
- `MERGEABLE` - Safe to merge (PASS)
- `CONFLICTING` - Has merge conflicts (FAIL)
- `UNKNOWN` - GitHub still calculating, try again later (FAIL)

**Rationale**: Conflicting PRs require human resolution before merging

### 5. Recency Check
- [ ] PR updated within last 24 hours

**Verification command**:
```bash
# Get PR last update time
UPDATED_AT=$(gh pr view <number> --json updatedAt --jq -r '.updatedAt')

# Convert to Unix timestamp
UPDATED_TS=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$UPDATED_AT" +%s 2>/dev/null || \
             date -d "$UPDATED_AT" +%s 2>/dev/null)

# Get current time
NOW_TS=$(date +%s)

# Calculate hours since update
HOURS_AGO=$(( (NOW_TS - UPDATED_TS) / 3600 ))

RECENCY_LIMIT=24

# Check if within recency limit
if [ "$HOURS_AGO" -gt "$RECENCY_LIMIT" ]; then
  echo "FAIL: Stale PR (updated $HOURS_AGO hours ago, limit is ${RECENCY_LIMIT}h)"
  exit 1
fi

echo "PASS: Recently updated ($HOURS_AGO hours ago)"
```

**Rationale**: Ensures PR reflects recent state of main branch and hasn't gone stale.

**On failure**: a stale PR is handled by the dedicated stale-PR policy (see "PR Rejection Workflow → Stale PR"), not the transient-failure path — it is commented once (idempotently) and routed out of the queue via `loom:pr` → `loom:changes-requested` so it reaches Doctor rather than being re-commented every cron tick.

### 6. CI Status Check
- [ ] If CI checks exist, all checks must be passing
- [ ] If no CI checks exist, this criterion passes automatically

**Verification command**:
```bash
# Get all CI checks. `gh pr checks --json` exposes `bucket` (the rolled-up
# pass/fail/pending/skipping/cancel state) and `name` — there is NO `conclusion`
# or `status` field (those were invalid and made this gate silently vacuous).
# Capture stdout ONLY: when a PR has no checks, gh prints "no checks reported..."
# to STDERR and exits non-zero with EMPTY stdout, so an empty result is the
# robust no-checks signal (do not grep error text).
CHECKS=$(gh pr checks <number> --json bucket,name 2>/dev/null)

# Handle case where no checks exist (empty stdout, or an empty JSON array)
if [ -z "$CHECKS" ] || [ "$(echo "$CHECKS" | jq 'length')" = "0" ]; then
  echo "PASS: No CI checks required"
  exit 0
fi

# Parse checks by bucket. Buckets: pass, fail, pending, skipping, cancel.
# `fail`/`cancel` block the merge; `pending` defers; `pass`/`skipping` are OK.
FAILING_CHECKS=$(echo "$CHECKS" | jq -r '.[] | select(.bucket == "fail" or .bucket == "cancel") | .name')
PENDING_CHECKS=$(echo "$CHECKS" | jq -r '.[] | select(.bucket == "pending") | .name')

# Check for failing checks
if [ -n "$FAILING_CHECKS" ]; then
  echo "FAIL: CI checks failing:"
  echo "$FAILING_CHECKS"
  exit 1
fi

# Check for pending checks
if [ -n "$PENDING_CHECKS" ]; then
  echo "SKIP: CI checks still running:"
  echo "$PENDING_CHECKS"
  exit 1
fi

echo "PASS: All CI checks passing"
```

**Edge cases handled**:
- **No CI checks**: Passes (allows merge) — detected via empty stdout, not error text
- **Pending checks**: Skips (waits for completion) — `bucket == "pending"`
- **Failed checks**: Fails (blocks merge) — `bucket == "fail"` or `"cancel"`
- **Skipped checks**: Passes — `bucket == "skipping"` is not a failure

**Rationale**: Only merge when all automated checks pass or no checks are configured

---

## Auto-Merge Workflow

### Step 1: Verify Safety Criteria

For each candidate PR, check ALL 6 criteria in order. If any criterion fails, skip to rejection workflow.

### Step 2: Add Pre-Merge Comment

Before merging, add a comment documenting why the PR is safe to auto-merge.

**Every bullet below is a claim about a specific criterion's result, not
boilerplate praise — only write it if that criterion's check-loop actually ran
in Step 1 of *this* pass and produced that result.** In particular, "No
critical files modified" must only appear if criterion #3's `for file in
$FILES` loop (paginated file list) just executed to completion with zero
matches, and "No merge conflicts" only if criterion #4's `mergeable` check
just returned `MERGEABLE` — never restate either from memory, from a stale
prior pass, or as a template fill-in. This is a direct regression guard for
#4613 (PR #4611 incident): a Champion pass claimed "no critical-file changes"
in a comment without the check having actually run against the full file
list.

```bash
PR_NUMBER=$1

# Gather verification data
PR_DATA=$(gh pr view "$PR_NUMBER" --json additions,deletions,updatedAt)
ADDITIONS=$(echo "$PR_DATA" | jq -r '.additions')
DELETIONS=$(echo "$PR_DATA" | jq -r '.deletions')
TOTAL_LINES=$((ADDITIONS + DELETIONS))

UPDATED_AT=$(echo "$PR_DATA" | jq -r '.updatedAt')
UPDATED_TS=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$UPDATED_AT" +%s 2>/dev/null || \
             date -d "$UPDATED_AT" +%s 2>/dev/null)
NOW_TS=$(date +%s)
HOURS_AGO=$(( (NOW_TS - UPDATED_TS) / 3600 ))

# Check CI status (empty stdout = no checks; see criterion #6 above)
CHECKS=$(gh pr checks "$PR_NUMBER" --json bucket,name 2>/dev/null)
if [ -z "$CHECKS" ] || [ "$(echo "$CHECKS" | jq 'length')" = "0" ]; then
  CI_STATUS="No CI checks required"
else
  CI_STATUS="All CI checks passing"
fi

# Generate comment with actual data
gh pr comment "$PR_NUMBER" --body "$(cat <<EOF
**Champion Auto-Merge**

This PR meets all safety criteria for automatic merging:

- Judge approved (\`loom:pr\` label)
- Merge-risk judgment passed: <ONE_LINE_RATIONALE — e.g. "diff is tests plus one self-contained module; no high-blast-radius surface; fully revertable">
- Diff size: $TOTAL_LINES lines (+$ADDITIONS/-$DELETIONS) — informational, not a gate
- No critical files modified
- No merge conflicts
- Updated recently ($HOURS_AGO hours ago)
- $CI_STATUS

**Proceeding with squash merge...** If this was merged in error, you can revert with:
\`git revert <commit-sha>\`

---
*Automated by Champion role*
EOF
)"
```

### Step 3: Merge the PR

Execute the squash merge with comprehensive error handling.

```bash
PR_NUMBER=$1

echo "Attempting to merge PR #$PR_NUMBER..."

# Ensure we're on main so .loom/scripts exists (issue #2289)
# merge-pr.sh may not exist on PR branches checked out via gh pr checkout
git checkout main 2>/dev/null || true

# Use merge-pr.sh for worktree-safe merge via GitHub API
# --auto enables auto-merge if ruleset requires wait
./.loom/scripts/merge-pr.sh "$PR_NUMBER" --auto || {
  echo "Merge failed for PR #$PR_NUMBER"
  # Post failure comment (see Error Handling section)
}
```

**Merge strategy**:
- Uses `merge-pr.sh` which merges via GitHub API (worktree-safe)
- **Squash merge**: Combines all commits into single commit (clean history)
- **`--auto`**: Enables GitHub's auto-merge if ruleset requires wait
- Branch deleted automatically after merge

### Step 4: Verify Issue Auto-Close

After successful merge, verify that linked issues were automatically closed by GitHub.

```bash
PR_NUMBER=$1

# Extract linked issues using GitHub's own parser (closingIssuesReferences).
# This is the authoritative set of issues GitHub will auto-close on merge.
# It correctly ignores `Updates #N`, `See #N`, code-fenced text, and substring
# traps like `Discloses #N`. The previous regex-based approach silently
# misclassified `Updates #N` as a closing reference — see issue #3267.
source "$(git rev-parse --show-toplevel)/.loom/scripts/lib/forge-helpers.sh"
forge_detect
LINKED_ISSUES=$(forge_pr_close_targets "$PR_NUMBER")

if [ -z "$LINKED_ISSUES" ]; then
  echo "No linked issues found in PR body"
  exit 0
fi

# Check each linked issue
for issue in $LINKED_ISSUES; do
  ISSUE_STATE=$(gh issue view "$issue" --json state --jq -r '.state' 2>&1)

  if [ "$ISSUE_STATE" = "CLOSED" ]; then
    echo "Issue #$issue is closed (auto-closed by PR merge)"
  else
    echo "Issue #$issue is still $ISSUE_STATE - closing manually..."
    gh issue close "$issue" --comment "Closed by PR #$PR_NUMBER which was auto-merged by Champion."
  fi
done
```

### Step 5: Unblock Dependent Issues

After verifying issue closure, check for blocked issues that can now be unblocked.

```bash
PR_NUMBER=$1
CLOSED_ISSUE=$2

echo "Checking for issues blocked by #$CLOSED_ISSUE..."

# Find issues with loom:blocked that reference the closed issue.
# Tolerant of markdown emphasis/colon between the phrase and #N (e.g.
# "**Blocked by:** #1 (reason)") — #4508.
BLOCKED_ISSUES=$(gh issue list --label "loom:blocked" --state open --json number,body \
  --jq ".[] | select(.body | test(\"(Blocked by|Depends on|Requires)[*_:[:space:]]*#$CLOSED_ISSUE\"; \"i\")) | .number")

if [ -z "$BLOCKED_ISSUES" ]; then
  echo "No issues found blocked by #$CLOSED_ISSUE"
  exit 0
fi

for blocked in $BLOCKED_ISSUES; do
  echo "Checking if #$blocked can be unblocked..."

  # Get the issue body to check ALL dependencies
  BLOCKED_BODY=$(gh issue view "$blocked" --json body --jq -r '.body')

  # Extract all referenced dependencies. Two-stage (#4508): stage 1 selects
  # lines declaring a dependency phrase, tolerant of markdown emphasis/colon
  # between the phrase and the first #N (e.g. "**Blocked by:** #1 (x), #3
  # (y)"); stage 2 extracts every #N on those lines, not just the first — an
  # empty ALL_DEPS here would silently remove loom:blocked with no
  # confirmation gate, so under-parsing is the highest-severity failure mode.
  ALL_DEPS=$(echo "$BLOCKED_BODY" | grep -E "(Blocked by|Depends on|Requires)[*_:[:space:]]*#[0-9]+" | grep -Eo "#[0-9]+" | grep -Eo "[0-9]+" | sort -u)

  # Check if ALL dependencies are now closed
  ALL_RESOLVED=true
  for dep in $ALL_DEPS; do
    DEP_STATE=$(gh issue view "$dep" --json state --jq -r '.state' 2>/dev/null)
    if [ "$DEP_STATE" != "CLOSED" ]; then
      echo "  Still blocked: dependency #$dep is still open"
      ALL_RESOLVED=false
      break
    fi
  done

  if [ "$ALL_RESOLVED" = true ]; then
    echo "  All dependencies resolved - unblocking #$blocked"
    gh issue edit "$blocked" --remove-label "loom:blocked" --add-label "loom:issue"
    gh issue comment "$blocked" --body "**Unblocked** by merge of PR #$PR_NUMBER (resolved #$CLOSED_ISSUE)

All dependencies are now resolved. This issue is ready for implementation.

---
*Automated by Champion role*"
  fi
done
```

### Step 5.5: Create Follow-on Issues

After unblocking dependent issues, scan the merged PR for follow-on work indicators and create consolidated issues.

```bash
PR_NUMBER=$1
ORIGINAL_ISSUE=$2  # The issue this PR closed (may be empty)

echo "Scanning PR #$PR_NUMBER for follow-on work indicators..."

# ============================================
# Stage 1: Extract TODO/FIXME from Diff
# ============================================

# Get PR diff and extract added lines with TODO patterns
# Parse unified diff to get file:line attribution
TODOS_RAW=$(gh pr diff "$PR_NUMBER" 2>/dev/null | awk '
  /^diff --git/ {
    # Extract filename from diff header
    split($0, a, " b/")
    current_file = a[2]
  }
  /^@@/ {
    # Parse hunk header for line number: @@ -old,count +new,count @@
    # POSIX awk: 2-arg match() sets RSTART/RLENGTH (the gawk-only 3-arg
    # match($0, re, arr) form errors on BSD awk / macOS). Capture the "+<n>"
    # token, then strip the leading "+" with substr().
    if (match($0, /\+[0-9]+/)) {
      line_num = substr($0, RSTART + 1, RLENGTH - 1)
    }
    in_hunk = 1
  }
  in_hunk && /^\+[^+]/ {
    # Added line (not the +++ header)
    # POSIX-portable word boundary: BSD awk (macOS) does NOT support the gawk-only
    # \b escape, so `/\b(TODO...):/` silently matches nothing there. Anchor on
    # start-of-string-or-non-word-char instead so this fires on BSD awk too.
    if ($0 ~ /(^|[^A-Za-z0-9_])(TODO|FIXME|HACK|XXX|FUTURE):/) {
      # Extract the comment text after the pattern
      line = $0
      sub(/^\+/, "", line)
      gsub(/^[ \t]*/, "", line)
      # Truncate to 200 chars
      if (length(line) > 200) line = substr(line, 1, 197) "..."
      print current_file ":" line_num ":" line
    }
    line_num++
  }
  in_hunk && !/^[+ -@]/ { in_hunk = 0 }
' | head -20)

# Categorize TODOs by severity
CRITICAL_TODOS=""
STANDARD_TODOS=""
CRITICAL_COUNT=0
STANDARD_COUNT=0

while IFS= read -r todo_line; do
  [ -z "$todo_line" ] && continue
  if echo "$todo_line" | grep -qE '\b(FIXME|HACK|XXX):'; then
    CRITICAL_TODOS="${CRITICAL_TODOS}${todo_line}"$'\n'
    CRITICAL_COUNT=$((CRITICAL_COUNT + 1))
  else
    STANDARD_TODOS="${STANDARD_TODOS}${todo_line}"$'\n'
    STANDARD_COUNT=$((STANDARD_COUNT + 1))
  fi
done <<< "$TODOS_RAW"

TOTAL_TODOS=$((CRITICAL_COUNT + STANDARD_COUNT))
echo "Found $TOTAL_TODOS TODOs ($CRITICAL_COUNT critical, $STANDARD_COUNT standard)"

# ============================================
# Stage 2: Parse PR Body Sections
# ============================================

PR_BODY=$(gh pr view "$PR_NUMBER" --json body --jq -r '.body // ""')

# Extract follow-on sections (case-insensitive matching)
FOLLOWON_SECTION=""
for section_name in "Follow-on Work" "Follow-on" "Out of Scope" "Future Work" "Deferred" "Phase 2" "Phase II"; do
  # Match section header and capture content until next ## or end
  extracted=$(echo "$PR_BODY" | sed -n "/^## *${section_name}/I,/^## /p" | sed '1d;$d' | head -20)
  if [ -n "$extracted" ]; then
    FOLLOWON_SECTION="${FOLLOWON_SECTION}### ${section_name}"$'\n'"${extracted}"$'\n\n'
  fi
done

HAS_FOLLOWON_SECTION=false
[ -n "$FOLLOWON_SECTION" ] && HAS_FOLLOWON_SECTION=true
echo "Has explicit follow-on section: $HAS_FOLLOWON_SECTION"

# ============================================
# Stage 3: Parse Review Comments
# ============================================

# Get review comments containing deferred work indicators
REVIEW_NOTES=$(gh api "repos/{owner}/{repo}/pulls/$PR_NUMBER/comments" --jq '
  .[] |
  select(.body | test("not blocking|consider for future|technical debt|would be nice|future enhancement|could be improved"; "i")) |
  "- \(.body | split("\n")[0] | .[0:200])"
' 2>/dev/null | head -10)

HAS_REVIEW_NOTES=false
[ -n "$REVIEW_NOTES" ] && HAS_REVIEW_NOTES=true
echo "Has deferred review notes: $HAS_REVIEW_NOTES"

# ============================================
# Stage 4: Apply Threshold Logic
# ============================================

SHOULD_CREATE_ISSUE=false

# Always create if:
# - 1+ critical patterns (FIXME, HACK, XXX)
# - Explicit follow-on section in PR
# - 3+ TODOs total

if [ "$CRITICAL_COUNT" -gt 0 ]; then
  SHOULD_CREATE_ISSUE=true
  echo "Creating issue: found $CRITICAL_COUNT critical TODOs"
elif [ "$HAS_FOLLOWON_SECTION" = true ]; then
  SHOULD_CREATE_ISSUE=true
  echo "Creating issue: found explicit follow-on section"
elif [ "$TOTAL_TODOS" -ge 3 ]; then
  SHOULD_CREATE_ISSUE=true
  echo "Creating issue: found $TOTAL_TODOS TODOs (>= 3 threshold)"
fi

if [ "$SHOULD_CREATE_ISSUE" = false ]; then
  echo "No follow-on issue needed (below threshold)"
  exit 0
fi

# ============================================
# Stage 5: Duplicate Detection
# ============================================

# Search for existing follow-on issues from this PR
EXISTING_ISSUE=$(gh issue list --state open --search "Follow-on from PR #$PR_NUMBER" --json number --jq '.[0].number // empty')

if [ -n "$EXISTING_ISSUE" ]; then
  echo "Follow-on issue already exists: #$EXISTING_ISSUE - skipping creation"
  exit 0
fi

# ============================================
# Stage 6: Create Follow-on Issue
# ============================================

# Get original issue title if available
if [ -n "$ORIGINAL_ISSUE" ]; then
  ORIGINAL_TITLE=$(gh issue view "$ORIGINAL_ISSUE" --json title --jq -r '.title' 2>/dev/null || echo "")
  PARENT_REF="Follow-on from PR #$PR_NUMBER which closed #$ORIGINAL_ISSUE"
  CONTEXT_LINE="**$ORIGINAL_TITLE** was implemented in PR #$PR_NUMBER."
else
  PR_TITLE=$(gh pr view "$PR_NUMBER" --json title --jq -r '.title')
  PARENT_REF="Follow-on from PR #$PR_NUMBER"
  CONTEXT_LINE="**$PR_TITLE** was merged in PR #$PR_NUMBER."
fi

# Build issue body
ISSUE_BODY="## Parent PR

$PARENT_REF

## Context

$CONTEXT_LINE During implementation/review, the following follow-on work was identified:

"

# Add Code TODOs section if present
if [ -n "$TODOS_RAW" ]; then
  ISSUE_BODY="${ISSUE_BODY}## Code TODOs

"
  # Format each TODO as a checkbox item
  while IFS= read -r todo_line; do
    [ -z "$todo_line" ] && continue
    file_line=$(echo "$todo_line" | cut -d: -f1-2)
    comment=$(echo "$todo_line" | cut -d: -f3-)
    ISSUE_BODY="${ISSUE_BODY}- [ ] \`$file_line\` - $comment
"
  done <<< "$TODOS_RAW"
  ISSUE_BODY="${ISSUE_BODY}
"
fi

# Add Follow-on sections if present
if [ -n "$FOLLOWON_SECTION" ]; then
  ISSUE_BODY="${ISSUE_BODY}## Deferred Scope

$FOLLOWON_SECTION"
fi

# Add Review Notes if present
if [ -n "$REVIEW_NOTES" ]; then
  ISSUE_BODY="${ISSUE_BODY}## Review Notes

$REVIEW_NOTES

"
fi

# Add acceptance criteria
ISSUE_BODY="${ISSUE_BODY}## Acceptance Criteria

- [ ] All identified TODOs addressed or converted to separate issues
- [ ] Deferred scope items implemented or explicitly deferred again
- [ ] Review suggestions addressed

---
*Auto-generated by Champion from PR #$PR_NUMBER*"

# Follow-on issues go to the Champion evaluation queue.
ISSUE_LABEL="loom:curated"

# Create the issue.
# NOTE: `gh issue create` does NOT support --json/--jq (only `gh issue view`
# and `gh issue list` do). On success it prints the new issue's URL to stdout
# (e.g. https://github.com/<owner>/<repo>/issues/<N>); parse the trailing
# number from that URL.
ISSUE_TITLE="Follow-on: Work identified in PR #$PR_NUMBER"
NEW_ISSUE_URL=$(gh issue create \
  --title "$ISSUE_TITLE" \
  --body "$ISSUE_BODY" \
  --label "$ISSUE_LABEL")
NEW_ISSUE=$(echo "$NEW_ISSUE_URL" | grep -oE '[0-9]+$')

if [ -n "$NEW_ISSUE" ]; then
  echo "Created follow-on issue #$NEW_ISSUE with label $ISSUE_LABEL"

  # Add comment to original PR linking to the follow-on issue
  gh pr comment "$PR_NUMBER" --body "**Champion: Follow-on Issue Created**

Identified follow-on work during merge:
- **TODOs**: $TOTAL_TODOS ($CRITICAL_COUNT critical)
- **Deferred sections**: $HAS_FOLLOWON_SECTION
- **Review notes**: $HAS_REVIEW_NOTES

Created issue #$NEW_ISSUE to track this work.

---
*Automated by Champion role*"
else
  echo "Failed to create follow-on issue"
fi
```

**Threshold Logic Summary**:

| Indicator | Threshold | Action |
|-----------|-----------|--------|
| Critical patterns (FIXME, HACK, XXX) | 1+ | Always create |
| Explicit follow-on section | Any | Always create |
| Standard TODOs | 3+ | Create consolidated |
| TODOs with review notes | < 3 TODOs, has notes | Skip (too noisy) |
| Minimal indicators | < 3 TODOs, no sections | Skip |

**Follow-on Issue Labeling**: Follow-on issues are created with `loom:curated` (goes to the Champion evaluation queue).

---

## PR Rejection Workflow

If ANY safety criterion fails, do NOT merge. How the failure is handled depends on whether it is **transient** (clears on its own or on the next push — pending CI, conflicts being resolved, `UNKNOWN` mergeability), **terminal** (the PR has gone stale and cannot clear without a rebase), or a **merge-risk hold** (criterion #2 judged the PR to need a human merge).

**Merge-risk holds** keep `loom:pr` like a transient failure, but comment **once** behind the `<!-- champion:merge-risk-hold -->` idempotency marker because the condition does not clear on its own. The exact commands live with the criterion itself — see "Safety Criteria → 2. Merge-Risk Judgment → Hold behavior"; do not duplicate them here.

### Transient failures — keep `loom:pr`, retry next tick

Add a comment explaining why, and **keep the `loom:pr` label** so the PR is re-evaluated on the next Champion tick once the blocking condition clears.

**Idempotency guard (mirrors the stale-PR pattern above, #4586).** A static failing
criterion (e.g. a size check that cannot pass without a new push) is guaranteed to
fail identically on every re-evaluation, and closely-spaced Champion ticks (cron +
daemon role runner, or a busy period with multiple ticks in flight) can hit the same
PR several times before the condition changes — left unguarded, this reposts a
near-identical rejection comment on every single tick (8 duplicates in 5 minutes was
observed on PR #4540, all citing the identical static size-check failure). Key the
marker to the **specific failing criterion** (not the PR as a whole) so a PR that
starts failing a *different* criterion still gets a fresh comment, and compare the
new reason text against the most recently posted comment for that criterion so a
*changed* reason (the same criterion, but the specifics moved — e.g. CI now fails a
different check) still gets a fresh comment too:

```bash
PR_NUMBER=<number>
# Slug for the criterion that failed: label-check | size-check | critical-file |
# merge-conflict | ci-status. (Recency-check failures use the dedicated Stale PR
# path below, not this one.)
CRITERION_KEY="<CRITERION_SLUG>"
REJECT_MARKER="<!-- champion:reject:$CRITERION_KEY -->"
REASON="<SPECIFIC_REASON>"  # exact reason text that will go in the comment body

# Idempotency guard: find the most recent comment already posted for this
# criterion (if any) and compare its reason text against the current one.
# Skip re-commenting only when the reason is unchanged — a PR that still fails
# the same criterion but for a *different* specific reason (e.g. CI now fails a
# different check) still gets a fresh comment.
LAST_COMMENT=$(gh pr view "$PR_NUMBER" --json comments \
  --jq --arg marker "$REJECT_MARKER" \
  '[.comments[] | select(.body | contains($marker))] | last | .body // ""')

if [ -n "$LAST_COMMENT" ] && echo "$LAST_COMMENT" | grep -qF "$REASON"; then
  echo "Rejection reason for $CRITERION_KEY unchanged since last comment on #$PR_NUMBER — skipping duplicate comment"
else
  gh pr comment "$PR_NUMBER" --body "$REJECT_MARKER
**Champion: Cannot Auto-Merge**

This PR cannot be automatically merged due to the following:

- <CRITERION_NAME>: $REASON

**Next steps:**
- <SPECIFIC_ACTION_1>
- <SPECIFIC_ACTION_2>

Keeping \`loom:pr\` label. Champion will retry on the next tick once the blocking condition clears.

---
*Automated by Champion role*"
  echo "Posted rejection comment for $CRITERION_KEY on #$PR_NUMBER"
fi
```

**Do NOT remove the `loom:pr` label for transient failures** — the next tick retries automatically. This guard only gates the *comment*, never the retry itself — a still-failing PR is still re-evaluated (and, once the condition clears, still eligible to merge) on every tick; only the redundant comment is suppressed.

### Stale PR (recency check failed) — comment once, route to Doctor

A stale PR (>24h) will never clear on its own, and under the 10-minute cron a bare "keep the label + comment" loop would re-comment on the same PR **every tick forever**. Instead, **comment once (idempotently)** and **swap `loom:pr` → `loom:changes-requested`** so the PR leaves the auto-merge queue and is picked up by Doctor for a rebase/refresh. This is the single, authoritative stale-PR policy — `champion-reference.md` Edge Case 5 defers to it.

```bash
PR_NUMBER=<number>
STALE_MARKER="<!-- champion:stale-pr-notice -->"

# Idempotency guard: only comment + relabel once. If a prior tick already
# posted the stale notice, do nothing (prevents per-tick comment spam).
if gh pr view "$PR_NUMBER" --json comments --jq '.comments[].body' | grep -qF "$STALE_MARKER"; then
  echo "Stale-PR notice already posted for #$PR_NUMBER — skipping"
else
  gh pr comment "$PR_NUMBER" --body "$STALE_MARKER
**Champion: PR Is Stale**

This PR has not been updated within the recency window (24h), so it has been routed out of the auto-merge queue for a rebase/refresh.

**Next steps:**
- Rebase onto the latest \`main\` and resolve any drift
- Re-request Judge review to return it to the auto-merge queue

---
*Automated by Champion role*"
  # Route to Doctor: leave the auto-merge queue.
  gh pr edit "$PR_NUMBER" --remove-label "loom:pr" --add-label "loom:changes-requested"
  echo "Routed stale PR #$PR_NUMBER to Doctor (loom:pr → loom:changes-requested)"
fi
```

---

## Capped-PR Recovery Pass (`loom:blocked` + `loom:changes-requested`)

**Scope**: open PRs carrying **both** `loom:blocked` and `loom:changes-requested`. This is the parked state `/loom:sweep` writes when a PR exhausts `sweep.max_doctor_cycles` (`PR #P blocked: doctor cycle exhausted after <k> Doctor→Judge round(s); human attention required`). Without this pass that state is **terminal for automation** — the work-finder skips blocked items and Mode C pre-flight skips blocked PRs — so a PR whose Doctor was making real, distinct progress is never reconsidered (issue #4574, PR #4543 incident, 2026-07-30).

This pass **never merges anything and never closes anything**. For each parked PR it makes exactly one of three decisions, each with a mandatory rationale comment: **grant one more Doctor→Judge cycle**, **keep parked**, or **recommend closing** (routed to the operator). Run it after the auto-merge queue has been drained — it is the lowest-priority Champion work.

### Step 1: Find capped PRs

`gh pr list` ANDs repeated `--label` values, so this returns exactly the parked set:

```bash
gh pr list \
  --label "loom:blocked" \
  --label "loom:changes-requested" \
  --state open \
  --json number,title,updatedAt,labels \
  --jq '.[] | "#\(.number) \(.title)"'
```

**Skip any PR that also carries `loom:operator-only`** — a previous pass (or a human) already routed it out to the operator; do not re-decide it. Process the remaining PRs oldest first.

Two more entry guards, checked against the thread in Step 2 before any decision is made:

- **Only PRs parked by the Doctor-cycle cap are in scope.** The label pair alone is not proof. If the history shows no cap block (no `doctor cycle exhausted` block line or equivalent, or fewer than two Judge rejections), this PR was blocked for some other reason — keep it parked and say so.
- **A human hold is authoritative.** If a human comment holds the PR — instruction-shaped phrasing such as `hold until`, `wait until`, `defer`, `not before`, `do not start` (not a bare `hold`/`wait` substring, mirroring the sweep's explicit-hold convention) — never grant. Keep it parked, quoting the hold.

### Step 2: Read the full rejection history

```bash
PR_NUMBER=<number>
gh pr view "$PR_NUMBER" --comments
```

Read the **whole** thread — that complete post-mortem view is the entire reason this decision lives here rather than in the dying sweep that parked the PR. Identify:

- Every Judge rejection (Judge rejections start with `❌ **Changes Requested**`), in order.
- The Doctor work between them (fix comments, pushed commits) — evidence that a previous rejection's defects were actually addressed.
- Any prior grants from this pass, marked `<!-- champion:capped-pr-grant -->`:

```bash
# How many extra cycles this pass has already granted (0 for a first-time decision).
PRIOR_GRANTS=$(gh pr view "$PR_NUMBER" --json comments \
  --jq '[.comments[] | select(.body | contains("champion:capped-pr-grant"))] | length')
```

The two comments the decision turns on are the **latest** Judge rejection and the **immediately preceding** one.

### Step 3: Apply the forward-progress test

This is the **same test** as the sweep's in-sweep distinct-defect exception (`sweep.md` → "Doctor-cycle cap" → "Distinct-defect exception"), applied at a different decision point: periodic, post-mortem, with the full history instead of the dying sweep's local context.

**Grant only when ALL of these hold:**

1. There are **at least two** Judge rejections to compare (nothing to compare = no grant).
2. The latest rejection names defects **demonstrably distinct** from the previous rejection's defects: the previous defects are not re-raised, the Doctor's fix for them visibly landed, and the new findings were reachable only *because* that fix landed. Judge saying so explicitly ("the Doctor made real progress") is strong evidence.
3. The new defects look **fixable by one Doctor cycle** — a bounded code change, not a design disagreement or a scope renegotiation.
4. Read as a whole, the chain is **converging**: each earlier grant also produced fresh progress, and the defect list is not migrating around the same area with no end in sight.

**Never grant when:**

- The latest rejection **re-litigates** a defect already named in a prior rejection — the same underlying disagreement restated, even in different words. This is thrash, exactly what the cap exists to stop, and it stays parked no matter how many grants preceded it.
- The comparison is **ambiguous** — the rejections partly overlap, or the comments do not make clear whether the prior fix actually landed. **Ambiguity is not a grant**; fall through to keep-parked (or recommend-closing).
- The rejection is about the **approach** rather than the implementation — no number of Doctor cycles fixes a wrong design.
- The chain is long and each round buys less than the one before it, even if every individual step technically moved forward. Park it and say so.

**No hard grant cap.** Champion may grant repeatedly across ticks as long as *each* new rejection shows fresh forward progress. The anti-thrash guarantee comes from applying this test **every round**, not from a counter — so do not add one, and do not treat a high `PRIOR_GRANTS` as automatic grounds for either granting or parking. The `<!-- champion:capped-pr-grant -->` comments are the audit trail that makes a long chain reviewable at a glance.

**No double-grant with the sweep-side exception.** A PR only reaches `loom:blocked` *after* the sweep's single-use distinct-defect grace cycle was already consumed or was not applicable, so this pass can never stack on top of it. The two are the same mechanism at two decision points; neither imposes a numeric cap on the other.

**Checkpoints are not this pass's business.** Do not write or edit `.loom/sweep-checkpoint/` state. The terminal rejection deliberately left the last `doctor-done` checkpoint in place with its `attempt` value, so the next Doctor cycle increments from there and the escalation ladder (`ladder[min(attempt - 1, len - 1)]`, saturating at the top rung) keeps progressing across grants with no plumbing change.

### Step 4a: Outcome — grant another Doctor cycle

Remove **only** `loom:blocked`. `loom:changes-requested` stays, and it is what routes the PR back to Doctor via the normal flow (the fleet role runner, or the next `/loom:sweep --prs` at C1b). Do **not** add `loom:pr` or `loom:review-requested`, and do not dispatch anything yourself — there is no new dispatch surface here.

```bash
PR_NUMBER=<number>
GRANT_MARKER="<!-- champion:capped-pr-grant -->"
# PRIOR_GRANTS from Step 2 (0 on a first-time decision).

gh pr comment "$PR_NUMBER" --body "$GRANT_MARKER
**Champion: Extra Doctor Cycle Granted**

This PR was parked at the Doctor-cycle cap. Reviewing its full rejection history, the latest rejection shows forward progress, so it is being returned to the Doctor→Judge flow for one more bounded cycle.

- **Previous rejection**: <DEFECTS_NAMED_IN_PRIOR_REJECTION>
- **Latest rejection**: <DEFECTS_NAMED_IN_LATEST_REJECTION>
- **Why this is forward progress**: <WHY_THE_LATEST_DEFECTS_ARE_DISTINCT_AND_ONLY_REACHABLE_AFTER_THE_PRIOR_FIX_LANDED>
- **Grants so far on this PR (including this one)**: $((PRIOR_GRANTS + 1))

Removing \`loom:blocked\`; \`loom:changes-requested\` stays, so Doctor picks this up on the normal path. If the next rejection re-litigates a defect already raised here, this PR parks again regardless of history.

---
*Automated by Champion role*"

# Remove ONLY loom:blocked — never touch loom:changes-requested here.
gh pr edit "$PR_NUMBER" --remove-label "loom:blocked"
echo "Granted an extra Doctor cycle on #$PR_NUMBER (loom:blocked removed)"
```

A granted PR leaves the parked set immediately, so this outcome is self-idempotent — the next tick will not see it again unless a fresh rejection re-parks it.

### Step 4b: Outcome — keep parked

Comment the **specific** reason a human is still needed (not a generic "still blocked"), and change no labels. Because the parked PR stays in the query, guard the comment with a marker keyed to the rejection that is being ruled on, so the 10-minute cron does not re-post the same verdict every tick while a genuinely new rejection still gets a fresh decision:

```bash
PR_NUMBER=<number>

# Per-episode idempotency key: the newest Judge rejection comment. Champion's
# own capped-PR comments are excluded from the match so this pass's output can
# never become its own key (which would re-post forever).
LATEST_REJECTION_ID=$(gh pr view "$PR_NUMBER" --json comments \
  --jq '[.comments[]
         | select((.body | contains("champion:capped-pr")) | not)
         | select(.body | test("Changes Requested"; "i"))]
        | last | .id // "none"')
PARK_MARKER="<!-- champion:capped-pr-parked:$LATEST_REJECTION_ID -->"

if gh pr view "$PR_NUMBER" --json comments --jq '.comments[].body' | grep -qF "$PARK_MARKER"; then
  echo "Keep-parked verdict already posted for #$PR_NUMBER on this rejection — skipping"
else
  gh pr comment "$PR_NUMBER" --body "$PARK_MARKER
**Champion: Keeping This PR Parked**

Reviewed the full rejection history against the forward-progress test; this PR does not qualify for another Doctor cycle.

- **Reason**: <SAME_DEFECT_RE_LITIGATED | AMBIGUOUS_COMPARISON | ONLY_ONE_REJECTION | CHAIN_NOT_CONVERGING | APPROACH_DISAGREEMENT | NOT_CAP_PARKED | HUMAN_HOLD>
- **Specifics**: <WHICH_DEFECT_REPEATS_ACROSS_REJECTIONS_OR_WHAT_IS_UNCLEAR>
- **What a human needs to decide**: <THE_SPECIFIC_JUDGMENT_AUTOMATION_CANNOT_MAKE>

Labels unchanged (\`loom:blocked\` + \`loom:changes-requested\`). Champion will re-evaluate this PR if a new Judge rejection lands.

---
*Automated by Champion role*"
  echo "Kept #$PR_NUMBER parked (rationale posted)"
fi
```

### Step 4c: Outcome — recommend closing (route to the operator)

Use this when the history shows the **approach itself** is not viable — repeated rejections on the design, a superseded change, or a PR whose premise a merged change invalidated. **Champion is the router here, not the closer**: do not close the PR. Add `loom:operator-only` (keeping `loom:blocked` + `loom:changes-requested`) so the PR leaves the automation queue for good — Mode C pre-flight hard-skips `loom:operator-only` PRs — and state the recommendation plainly for the human.

```bash
PR_NUMBER=<number>
CLOSE_MARKER="<!-- champion:capped-pr-close-recommended -->"

if gh pr view "$PR_NUMBER" --json comments --jq '.comments[].body' | grep -qF "$CLOSE_MARKER"; then
  echo "Close recommendation already posted for #$PR_NUMBER — skipping"
else
  gh pr comment "$PR_NUMBER" --body "$CLOSE_MARKER
**Champion: Recommending Closure — Operator Decision Required**

This PR has been parked at the Doctor-cycle cap, and its rejection history indicates the approach is not viable rather than merely unfinished. Champion does not close PRs; routing this to the operator instead.

- **Rejection history**: <SHORT_SUMMARY_OF_THE_ROUNDS>
- **Why more Doctor cycles will not help**: <WHY_THE_APPROACH_NOT_THE_IMPLEMENTATION_IS_THE_PROBLEM>
- **Recommendation**: close this PR<AND_OPTIONALLY_WHAT_TO_FILE_INSTEAD>

Added \`loom:operator-only\` so automation stops re-evaluating this PR. A human should close it, or remove \`loom:operator-only\` to return it to the Champion recovery pass.

---
*Automated by Champion role*"
  gh pr edit "$PR_NUMBER" --add-label "loom:operator-only"
  echo "Routed #$PR_NUMBER to the operator with a close recommendation"
fi
```

**Never** `gh pr close` from this pass, and never close the PR's linked issue — a still-pending human decision is routed, not resolved.

---

## PR Auto-Merge Batch Processing

**Process all qualifying PRs in one iteration — drain the full queue.**

Evaluate and merge qualifying PRs sequentially (oldest first) until the queue is empty. Sequential processing is safe and prevents the bottleneck that occurs when PRs accumulate while the champion waits for the next interval.

If an individual merge fails, continue to the next PR rather than aborting the entire iteration.

The **Capped-PR Recovery Pass** drains the same way (oldest first, one decision per parked PR, continue past individual failures), but only after the `loom:pr` merge queue is empty — merging approved work always outranks reconsidering parked work.

---

## Error Handling

If the merge fails for any reason:

1. **Capture error message**
2. **Add comment to PR** with error details
3. **Do NOT remove `loom:pr` label**
4. **Report error in completion summary**
5. **Continue to next PR** (don't abort entire iteration)

Example error comment:

```bash
gh pr comment <number> --body "**Champion: Merge Failed**

Attempted to auto-merge this PR but encountered an error:

\`\`\`
<ERROR_MESSAGE>
\`\`\`

This PR met all safety criteria but the merge operation failed. A human will need to investigate and merge manually.

---
*Automated by Champion role*"
```

---

## Return to Main Champion File

After completing PR merge work, return to the main champion.md file for completion reporting.
