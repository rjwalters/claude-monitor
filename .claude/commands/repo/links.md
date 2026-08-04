---
name: "links"
description: "Validate internal cross-references — markdown links, CLAUDE.md paths, skill graph edges"
domain: repo
type: command
user-invocable: true
---

# /repo:links — Link Checker

Validate that internal cross-references across the repo actually resolve.
Catches broken links from reorganization, renames, and deletions.

This is the cross-reference layer of [[docs]]. Use it directly when that's all
you want to check; use [[docs]] for the full documentation sweep.

## Usage

```
/repo:links                    # Full repo — fix unambiguous links, report as you go
/repo:links CLAUDE.md          # Check one file
/repo:links .claude/           # Check skill/command files
/repo:links --ask              # Review findings and confirm before fixing
```

## What It Checks

### 1. Markdown Links
Scan all `.md` files for `[text](path)` links where `path` is a relative file
path (not a URL). Verify the target exists on disk.

Skip:
- External URLs (http://, https://)
- Anchor-only links (#section)
- Image URLs from external services

### 2. CLAUDE.md File References
CLAUDE.md files typically list key file paths (reference tables, "see X"
pointers). Verify every path mentioned resolves. This is **critical**
severity — these are the primary navigation paths for agents.

### 3. Skill/Command Cross-References
If the repo has `.claude/skills/` and `.claude/commands/`:
- Every `[[wikilink]]` in a SKILL.md has a corresponding command `.md` file
  in the same domain
- If a `.claude/skill-graph.json` exists: every node references a file that
  exists, and every edge connects two valid nodes

### 4. Nested CLAUDE.md References
Subdirectory CLAUDE.md files often list key files relative to their own
directory. Verify those paths resolve relative to that directory.

## Interaction

Group findings by source file:

```
## CLAUDE.md — 2 broken links

| Line | Target | Status |
|------|--------|--------|
| 42 | docs/setup.md | MISSING (removed?) |
| 87 | legacy/MIGRATION.md | MISSING (renamed?) |

## packages/core/CLAUDE.md — 1 broken link
...
```

For each broken link, find the most likely correct target (fuzzy match on
filename). When there's a single confident match, fix the link and report it;
when the match is ambiguous or no target exists, report it for a human call.
Under `--ask`, propose every fix and confirm before editing.

### Verify after write

Fixing a link is not proof the fix survived. A concurrent writer — another
agent working in the same clone, a background `git stash` or `git checkout --`,
a pre-commit hook, a Loom sweep quarantining the primary clone's working tree —
can revert a file between the moment you fix it and the moment you report it,
leaving this command claiming a fix that is no longer on disk.

So immediately after applying each fix, and **before counting it as applied**,
confirm the edit is still there: re-read the changed region of the file, or run
`git diff -- <path>` / `git status --porcelain -- <path>` and check the change
is still present.

This check is **unconditional** — run it whether or not you have any reason to
suspect a concurrent writer. Detecting a daemon first would be racy (one can
start right after the check), and in a repo with no concurrent writer the check
always finds the edit still applied, so nothing about the reported output
changes.

If a fix is gone on re-check, report it on its own line as **reverted after
apply — needs re-run**. Do not silently re-apply it, and do not count it in the
fixed total — that total must only ever include edits confirmed still on disk.
