---
name: "deps"
description: "Third-party dependency currency — verify/scaffold Dependabot (config and the repo-level security flag) and triage open Dependabot PRs, always confirmed first"
domain: repo
type: command
user-invocable: true
---

# /repo:deps — Third-Party Dependency Currency

Keep the repo's **third-party dependencies** current: npm / pip / cargo / Go
packages and GitHub Actions. Two halves, usually run together:

1. **Install / verify Dependabot** — the config file *and* the repo-level
   security-updates flag, which are two independent things.
2. **Triage open Dependabot PRs** — what each one is, whether it's risky, and
   whether to take it.

This is the companion to [[update-tools]], not a part of it. `update-tools`
compares *installer-managed tool packages* (Loom, Anvil, Repo Skills) against a
local source clone; there is no source clone to diff for Dependabot, and
"triage incoming bot PRs" is a different activity from "update an installed
package." Keeping them separate keeps `update-tools`' comparison model intact.

Everything here either writes repo config, flips a repository setting, or
merges a PR — so like `release`, `remote`, `followups`, and `update-tools`,
this command **always confirms first** and never auto-applies. `--check` is the
report-only form.

## Usage

```
/repo:deps                  # Report status + open Dependabot PRs, then offer actions
/repo:deps --check          # Report only — never writes, never merges
/repo:deps --install        # Only the install/verify half (config + security flag)
/repo:deps --review         # Only the PR-triage half
/repo:deps --review 123     # Triage one PR in depth
```

## Prerequisites

Dependabot is a GitHub feature. Confirm the repo is on GitHub before doing
anything else — if `origin` points at Gitea or another forge, say so and stop
rather than scaffolding config that will never run:

```bash
git config --get remote.origin.url    # → derive OWNER/REPO; must be a GitHub host
gh auth status
```

## Steps — install / verify

### 1. Report config and the security flag as two distinct items

Writing `.github/dependabot.yml` enables **version** updates only. Dependabot
**security** updates are a repository setting that is entirely independent — a
repo can have a perfectly good config file and still have CVE alerting off.
Check and report both:

```bash
git ls-files '.github/dependabot.yml' '.github/dependabot.yaml'   # version updates

# Security updates — repo-level flag, needs admin (see the UNKNOWN note below)
gh api repos/OWNER/REPO --jq '.security_and_analysis'
gh api repos/OWNER/REPO --jq '.security_and_analysis.dependabot_security_updates.status'

# Alerts — a dedicated endpoint, NOT a security_and_analysis key:
#   204 → enabled, 404 → disabled
gh api repos/OWNER/REPO/vulnerability-alerts -i 2>/dev/null | head -1
```

Read the alerts flag from `/vulnerability-alerts`, not from
`security_and_analysis.dependabot_alerts` — that key is simply **absent** on
many repos even when the object is otherwise fully populated, so a
`// "UNKNOWN"` fallback on it reports "can't tell" for a repo you can read
perfectly well. (Verified against `rjwalters/repo`: `security_and_analysis`
returns `dependabot_security_updates` and the `secret_scanning*` keys with no
`dependabot_alerts` among them.)

Report them on separate rows, never collapsed into one "Dependabot: on":

```
DEPENDABOT
==========
| Item                            | Status                                  |
|---------------------------------|-----------------------------------------|
| .github/dependabot.yml          | absent — no version updates configured  |
| vulnerability alerts (repo flag)| disabled (404)                          |
| dependabot_security_updates     | disabled — no automatic CVE fix PRs     |
| Open Dependabot PRs             | 0                                       |
```

If the whole `security_and_analysis` object is null or absent, the token lacks
admin on the repo — report that flag as **UNKNOWN (needs admin)**. Do **not**
report it as `disabled`; "can't see it" and "it's off" are different answers
and only one of them justifies a write. A `403` from `/vulnerability-alerts` is
the same UNKNOWN case; only a `404` means genuinely disabled.

### 2. Detect the ecosystems actually present

Scaffold from what the repo really contains, never from a fixed template. Look
for manifests at the root **and** in subdirectories (each distinct directory
needs its own `updates:` entry with the right `directory:` value):

| Ecosystem | Detect via |
|---|---|
| `github-actions` | `.github/workflows/*.yml`, `.github/actions/*/action.yml` |
| `npm` | `package.json` (`pnpm-lock.yaml` / `yarn.lock` / `package-lock.json`) |
| `cargo` | `Cargo.toml` |
| `pip` | `requirements*.txt`, `pyproject.toml`, `Pipfile` |
| `gomod` | `go.mod` |
| `bundler` | `Gemfile` |
| `composer` | `composer.json` |
| `docker` | `Dockerfile`, `docker-compose.yml` |
| `gitsubmodule` | `.gitmodules` |

```bash
git ls-files '.github/workflows/*' '.github/actions/*' \
  '*package.json' '*Cargo.toml' '*go.mod' '*requirements*.txt' '*pyproject.toml' \
  '*Pipfile' '*Gemfile' '*composer.json' '.gitmodules' '*Dockerfile' \
  '*docker-compose.yml'
```

Use `git ls-files` for **every** probe — including the workflow directory — not
`ls` with a glob. Two reasons: vendored and ignored trees can't produce phantom
ecosystems, and under `zsh` an unmatched glob like `ls .github/workflows/*.yaml`
is a **hard error that aborts the whole command line**, so a repo with `.yml`
workflows can end up reporting no Actions ecosystem at all. `2>/dev/null` does
not save you — zsh fails before `ls` ever runs.

If **nothing** is detected, say there is nothing to scaffold and stop — do not
guess an ecosystem the repo doesn't have.

### 3. Validate every label the config would reference — by description

A scaffolded config can attach labels to bot PRs (`labels:` in the `updates:`
entry). Before referencing **any** label, read its description and confirm a
bot may apply it:

```bash
# Labels a bot may NOT apply — refuse every one of these
gh api repos/OWNER/REPO/labels --paginate \
  --jq '.[] | select(.description // "" | test("Applied by: humans")) | "REFUSE: \(.name) — \(.description)"'

# Remaining candidates
gh api repos/OWNER/REPO/labels --paginate \
  --jq '.[] | select((.description // "" | test("Applied by: humans")) | not) | .name'
```

Two details that matter in that jq: `.description // ""` is **required** — a
label with a null description makes a bare `.description | test(…)` abort with
`null (null) cannot be matched, as it is not a string`, which can drop the rest
of the label list mid-scan and silently shrink the set you validate against.
And prefer `gh api …/labels` over `gh label list --json` — the latter goes
through GraphQL, which shares a separate (and, on a busy agent host, routinely
exhausted) rate-limit bucket from REST.

Rules:

- The label must **exist**. Existence alone is not enough.
- **Refuse any label whose description reserves it for humans** — look for the
  literal substring `Applied by: humans` (Loom repos use exactly this
  convention, e.g. `external`: *"Non-collaborator submission; needs maintainer
  approval before curation. Applied by: humans only."*). Having Dependabot
  apply such a label violates the label's own contract.
- **Never create a label** to solve this. No `gh label create`, ever. If no
  suitable label exists, scaffold the config **without** a `labels:` key and
  say so in the report.
- A maintenance/chore-tier label (e.g. `tier:maintenance`, `dependencies`,
  `chore`) is the usual right answer when one is present and unrestricted.

Report the decision explicitly: which label was chosen, or which were rejected
and why.

### 4. Offer to scaffold the config (confirm first)

Grouping policy is **per-ecosystem**, not uniform. Reviewing every Actions bump
individually is noise; batching a breaking change into line 4 of a 12-package
PR is how a risk-bearing dependency slips through unreviewed.

| Ecosystem | Policy | Why |
|---|---|---|
| `github-actions` | group everything, majors included | low-risk, individually reviewing them is noise |
| package ecosystems (`npm`, `cargo`, `pip`, …) | group minor + patch; **majors ungrouped** | a breaking change deserves its own reviewable PR |

**Ask which dependencies are risk-bearing** rather than applying one policy to
everything — deps coupled to an external binary or service (e.g.
`playwright-core` and its browser binary, a database driver, a native
toolchain) should stay ungrouped even at minor/patch, via `exclude-patterns`.

Show the proposed file in full and get approval before writing:

```yaml
version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
    groups:
      github-actions:
        patterns: ["*"]
        update-types: ["major", "minor", "patch"]

  - package-ecosystem: "npm"
    directory: "/"
    schedule:
      interval: "weekly"
    groups:
      npm-minor-patch:
        patterns: ["*"]
        exclude-patterns: ["playwright-core"]   # risk-bearing → its own PR
        update-types: ["minor", "patch"]
    # majors are deliberately ungrouped: one reviewable PR each
```

Add `labels: ["<validated-label>"]` only if step 3 approved one. Write the file
only on explicit approval; under `--check`, stop here and show it as a proposal.

### 5. Offer to enable the repo-level flags (confirm first)

Independent of the file, and a separate confirmation. Alerts are a
**prerequisite** for automated security fixes — enable in this order:

```bash
gh api -X PUT repos/OWNER/REPO/vulnerability-alerts       # prerequisite
gh api -X PUT repos/OWNER/REPO/automated-security-fixes
```

Both need admin. On a 403, report that the flag needs a repo admin and move on
— never present a failed write as success. Re-read the flags afterward and show
the before/after.

### 6. Check for PRs immediately after the config lands

**Dependabot fires on config merge, not on schedule.** The first PRs typically
arrive within a couple of minutes of the config landing on the default branch,
regardless of `interval: weekly`. Never tell the user to "expect your first PR
Monday" — wait briefly, then run the PR review half below.

## Steps — review open Dependabot PRs

### 7. List the bot's open PRs

```bash
gh pr list --author "app/dependabot" --state open \
  --json number,title,headRefName,createdAt,statusCheckRollup,labels

# REST fallback when GraphQL's rate-limit bucket is exhausted. Note the author
# spelling differs: gh's --author filter wants "app/dependabot", the REST
# payload carries login "dependabot[bot]".
gh api repos/OWNER/REPO/pulls --paginate \
  --jq '.[] | select(.user.login == "dependabot[bot]") | "#\(.number) \(.title)"'
```

If there are none, say so — and if the config was just written, note that PRs
land within minutes rather than on the stated interval.

### 8. Classify each PR

For every PR report: **ecosystem**, **update type** (major vs minor/patch —
majors flagged), **CI status**, and what actually changed.

Update type comes from the title/branch (`bump X from 1.2.3 to 2.0.0` →
compare the leading version components) — confirm against the diff rather than
trusting the title alone:

```bash
gh pr view <N> --json title,body,files
gh pr diff <N>
gh pr checks <N>
```

For **GitHub Actions** bumps specifically, check whether the update **clears a
deprecation annotation** — often the actual reason to take a scary-looking
major. Compare annotations on the base branch against the PR head:

```bash
gh api "repos/OWNER/REPO/commits/$SHA/check-runs" --jq '.check_runs[].id' \
  | while read -r id; do
      gh api "repos/OWNER/REPO/check-runs/$id/annotations" --jq '.[].message'
    done
```

Run it for `main`'s head SHA and the PR's head SHA and diff the two sets. A
major bump that removes a *"Node.js 20 is deprecated"* annotation, with CI
green on every matrix leg, is a much easier yes than "a major bump, seems
risky."

```
OPEN DEPENDABOT PRs
===================
| PR  | Ecosystem      | Update                     | Type  | CI    | Note                          |
|-----|----------------|----------------------------|-------|-------|-------------------------------|
| #12 | github-actions | actions/checkout 4 → 5     | MAJOR | green | clears "Node.js 20 deprecated"|
| #13 | npm            | 6 packages (minor + patch) | minor | green | grouped                       |
| #14 | npm            | playwright-core 1.4 → 2.0  | MAJOR | red   | browser binary coupling       |
```

### 9. Offer to merge the safe ones (confirm first)

Propose a merge set and get explicit approval. **Never** merge a major without
its own separate confirmation, and never merge a PR whose CI is red or pending.

In a Loom-managed repo (`.loom/scripts/merge-pr.sh` present) use that script
rather than `gh pr merge` — `gh pr merge` attempts a local checkout that fails
when the branch is linked to a worktree:

```bash
./.loom/scripts/merge-pr.sh <N>      # Loom repos
gh pr merge <N> --squash             # otherwise
```

Under `--check`, stop at the report and merge nothing.

## Dependabot PRs are inert to Loom automation by default

State this in the report whenever a `.loom/` directory is present. It is the
natural wrong assumption, and it is safety-relevant:

- Dependabot PRs carry **no `loom:` label**, so `/loom:sweep` Mode C skips them
  ("no actionable label") and Champion will not auto-merge them without
  `loom:pr`.
- That is **safe by default and probably correct** — but it means nothing in
  the Loom pipeline is watching these PRs. They sit open until a human or
  `/repo:deps` triages them.
- Do **not** "fix" this by applying `loom:` labels to bot PRs. Routing bot PRs
  into an auto-merge pipeline is a policy decision for the repo's owner, not a
  side effect of a hygiene command — and any label used for it still has to
  pass the step 3 description check.

## Safety Rules

1. **Never write without confirmation** — the config file, the repo-level
   flags, and each merge are three separate approvals, not one.
2. **Config and security flag are reported independently** — a present
   `dependabot.yml` says nothing about whether CVE alerting is on. Report
   UNKNOWN (not `disabled`) when the token can't read the setting.
3. **Never create a label**, and never reference one whose description reserves
   it for humans (`Applied by: humans`). No suitable label → no `labels:` key.
4. **Scaffold only detected ecosystems** — no fixed template, no guessing. Zero
   detected means nothing to scaffold.
5. **Never auto-merge a major** — majors get their own confirmation, always.
   Red or pending CI is never merged.
6. **Never push or merge under `--check`** — report-only means report-only.
