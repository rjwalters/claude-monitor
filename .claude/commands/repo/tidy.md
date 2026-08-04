---
name: "tidy"
description: "Tidy up the repository — build artifacts, caches, temp files, empty dirs"
domain: repo
type: command
user-invocable: true
---

# /repo:tidy — Tidy Up

Sweep the working tree for clutter and clean it up. Inventory everything,
categorize by confidence, then by default delete the SAFE category (pure junk
that holds no unique work) and report what was freed. Regenerable **caches**
(compilation/tool/build output) are kept by default and only cleared when you
pass `--caches` — deleting them is harmless but forces a costly rebuild, so it
is opt-in. Items that could be real work (ASK) are always presented for a human
call, never auto-deleted.

## Usage

```
/repo:tidy                    # Inventory, delete SAFE junk (caches kept), report; ASK items presented
/repo:tidy --caches           # Also clear regenerable caches (__pycache__/, dist/, .mypy_cache/, …)
/repo:tidy --ask              # Walk every category interactively before deleting anything
/repo:tidy --sizes            # Also measure worktree root sizes (slow: du has no prune)
/repo:tidy packages/core      # Scope to one subtree
```

(`--apply` is accepted as a synonym for the default, for muscle memory. `--caches`
composes with `--ask`: `--ask` still walks every category, `--caches` just moves
the cache tier into the auto-delete set for the non-interactive default.
`--sizes` only adds the per-worktree size column described in step 1 — it never
changes what is deleted.)

## Steps

### 1. Inventory

Gather candidates without deleting anything:

```bash
# Ignored files that exist on disk (usually build output/caches)
git clean -ndX

# Untracked files (may include work-in-progress — treat carefully)
git clean -nd

# Empty directories
find . \( -path './.git' -o -name node_modules -o -name target \
          -o -name dist -o -name .venv \) -prune \
     -o -type d -empty -print

# Large files in the working tree (>10 MB, tracked or not)
find . \( -path './.git' -o -name node_modules -o -name target \
          -o -name dist -o -name .venv \) -prune \
     -o -type f -size +10M -print

# Git worktree roots — authoritative and tool-agnostic. RETAIN this output as a
# path set for step 2's denylist; do not just print it. `--porcelain` gives one
# `worktree <path>` line per entry, including worktrees that live outside this
# repo root (`../repo-wt-fix123`, `/private/tmp/…`, `/private/var/folders/…`),
# which `git clean` never sees.
git worktree list --porcelain

# The worktree paths alone, for step 3's WORKTREES block. Extract them with
# `sed`, not `awk '{print $2}'`: awk splits on whitespace and would truncate
# `/repos/my checkout/wt` to `/repos/my`. The `worktree ` prefix is fixed, so
# stripping it with sed and reading whole lines keeps paths with spaces intact
# (paths containing newlines need `git worktree list --porcelain -z`).
git worktree list --porcelain | sed -n 's/^worktree //p'

# Worktree SIZES ARE NOT COLLECTED BY DEFAULT — only when `--sizes` is passed.
# See below for why. When it is passed, bound each root so a slow one degrades
# the size column instead of stalling the step:
git worktree list --porcelain | sed -n 's/^worktree //p' \
  | while IFS= read -r wt; do
      timeout 20 du -sh "$wt" 2>/dev/null \
        || printf '%s\t%s\n' 'size unavailable' "$wt"
    done
```

Both `find` walks `-prune` the heavy trees rather than filtering them out with
`-not -path`. `-not -path` only suppresses *printing* — `find` still descends
into `.git/`, `node_modules/`, and every other excluded directory, which is why
the inventory stalls on a repo with a multi-GB build tree. Pruning is a
**traversal optimization only and must never change what is reported**: junk
outside the pruned trees (an empty `build/`, an 11 MB file under `src/`) is
still listed exactly as before, and `git clean -ndX`/`-nd` are unaffected since
git does its own traversal. When editing the prune list:

- **Keep both invocations' lists identical.** If they drift, one command
  silently reintroduces the stall.
- **Draw entries from the denylist and CACHE categories already named in step 2**
  (`node_modules/`, `.venv/`, `dist/`, plus `target/` for Rust builds) instead
  of growing a second, inconsistent list.
- **Match by `-name`, not `-path`** (except `./.git`, which is unambiguously at
  the root). `-name` prunes at any depth, so nested copies like
  `packages/foo/node_modules/` are covered — the old
  `-not -path './node_modules/*'` only ever matched the top-level one.
- **Coordination roots (`.loom/`, `.anvil/`, `.wrangler/`) are deliberately not
  pruned.** They are small, and step 2 needs to see their empty directories in
  order to route them to ASK.

**Worktree sizes are opt-in (`--sizes`); the default inventory reports count and
paths only.** `du` has no `-prune`: sizing a worktree root re-enters the very
`node_modules/`, `target/`, `dist/`, and `.venv/` trees the two `find` walks
above were rewritten to skip, once per root — and the reported case that
motivated all of this is 66 GB of worktrees inside a 94 GB tree, so sizing the
roots is most of a `du` over the whole repo. The cost is bounded by inode count
under those roots, not by the number of worktrees, so "there are only a handful
of them" is not a bound at all. That makes an eager `du` the same unbounded walk
that blew a 120-second timeout and stalled this step before.

Making it a flag is the same call the command already makes for `--caches`:
work whose *result* is useful but whose *cost* is high is presented, not
performed, until asked for. It also keeps the fix for the failure this block
exists to prevent — a report of "nothing to tidy" on a tree with tens of
gigabytes in worktrees — because the count and the paths are what carry that
signal, and they are free (`git worktree list` reads
`.git/worktrees/`, it does not walk the trees). The size column is the
refinement, not the point.

When `--sizes` is passed, the sizes are **best-effort**: wrap each root in
`timeout 20` and print `size unavailable` for any root that exceeds it rather
than letting one enormous worktree hang the inventory. (`timeout` is GNU
coreutils — on macOS it is `gtimeout` from `brew install coreutils`. If neither
is available, report sizes as unavailable rather than running the walk
unbounded.) Do not prune inside the `du`: an "excluding regenerable trees"
number would understate exactly the footprint the operator is looking for. The
honest choices are a bounded full number or none.

The **first** `worktree` entry is the **main** working tree — always, regardless
of where the command runs from. It is *not* necessarily
`git rev-parse --show-toplevel`: from inside a linked worktree (which is where
Loom agents run, e.g. `.loom/worktrees/issue-42`), `--show-toplevel` reports the
linked worktree's own root while the first porcelain entry is still the main
repo. Do not treat the two as the same path.

What to drop from the list is **the tree being tidied** — the entry whose path
equals `git rev-parse --show-toplevel` — since that is the repo this run is
sweeping, not a worktree it is protecting from itself. Every remaining entry,
including the main working tree when tidy is invoked from a linked worktree, is
a live checkout to report and protect.

`git worktree list --porcelain` is **authoritative**. A directory whose `.git`
is a **file** (not a directory) containing `gitdir: …/.git/worktrees/…` is also
a worktree root, and that check catches worktrees belonging to *other*
checkouts of the same project; but where the two disagree — e.g. a stale `.git`
pointer whose target is gone — trust `git worktree list --porcelain` and do not
let a speculative `.git`-file scan fail the step.

Also look for junk by pattern, wherever it lives:
- OS/editor droppings: `.DS_Store`, `Thumbs.db`, `*~`, `*.swp`, `.#*`
- Python: `__pycache__/`, `*.pyc`, `.pytest_cache/`, `.mypy_cache/`, `.ruff_cache/`
- JS: `node_modules/` outside package roots, stale `dist/`, `.turbo/`, coverage output
- Logs and temp files: `*.log`, `*.tmp`, `tmp/` contents older than a week
- Merge/patch leftovers: `*.orig`, `*.rej`, `*.BACKUP.*`

### 2. Categorize

**Gitignored ≠ safe to delete.** `git clean -ndX` lists *every* gitignored file
on disk — including secrets (`.env`) and expensive-to-rebuild trees (`.venv/`),
which are gitignored *precisely because* they're precious and local. Do not
treat "gitignored" as a synonym for "regenerable." SAFE and CACHE are
**allowlists** of recognized clutter (SAFE = pure junk, auto-deleted; CACHE =
regenerable build output, kept unless `--caches`); a **never-delete denylist**
overrides both; everything else gitignored falls through to ASK.

Apply these tests in order — **denylist first, then the SAFE and CACHE
allowlists, then fall through to ASK**:

**Never-delete denylist (always ASK, never SAFE or CACHE — checked first,
overrides everything below, regardless of gitignore status):**
- Secrets / credentials: `.env`, `.env.*` (but **not** `.env.example` /
  `.env.sample`, which are templates safe to keep), `*.pem`, `*.key`,
  `*.keystore`, `*.p12`, `*.pfx`, `id_rsa*`
- Expensive-to-rebuild environments: `.venv/`, `venv/`, `env/`, and
  `node_modules/` — reinstalling them costs time and network, so they are never
  auto-deleted and `--caches` does **not** reach them (they are environments, not
  caches). Surface them under ASK for an explicit human call.
- Tool scaffolding / coordination roots: runtime-state directories a tool
  expects to exist and manages itself — anything under `.loom/` (`locks/`,
  `worktrees/`, `sweep-run/`, `sweep-checkpoint/`, …), `.anvil/`, `.wrangler/`
  (e.g. `.wrangler/tmp/`), and the equivalent runtime dirs under any other
  tool's dot-directory. **Match by parent tool-directory prefix, not by an
  enumerated leaf list**, so coordination subdirectories added later are covered
  without editing this file. For these, **empty is the normal, healthy state** —
  an empty `.loom/locks/` means no lock is currently held, not that the
  directory is abandoned — so emptiness is never evidence of junk here (see the
  empty-directory rule under SAFE). (The cache dot-directories already named
  under CACHE — `.pytest_cache/`, `.mypy_cache/`, `.ruff_cache/`, `.turbo/`,
  `.astro/` — are **not** coordination roots: they are regenerable output and
  stay in CACHE, so `--caches` still clears them. The discriminator is that a
  coordination root is one where *empty is the normal state*; a cache directory
  is one whose entire contents can be rebuilt by re-running the tool.)
- Git worktree roots — **any** path listed by `git worktree list --porcelain`
  in step 1, **or** any directory whose `.git` is a **file** (not a directory)
  whose contents match `gitdir: .*/\.git/worktrees/.*`. A worktree root is a
  live checkout that can hold uncommitted, unpushed, one-of-a-kind work; it is
  never SAFE and never CACHE, regardless of gitignore status. This test is
  **tool-agnostic and independent of the tool-scaffolding prefixes above** — it
  is what covers `.claude/worktrees/`, `.codex/worktrees/`, and any other
  tool's worktree cache dir that is not named in the `.loom/` / `.anvil/` /
  `.wrangler/` list, as well as ad hoc worktrees under no dot-directory at all
  (`git worktree add ../repo-wt-fix123`, `/private/tmp/…`,
  `/private/var/folders/…`). Do not rely on the prefix match to reach these.
  Emptiness never promotes a worktree root to SAFE either (safety rule 8) — a
  checked-out worktree is not legitimately empty, and a parent directory that
  *contains* worktrees still routes through the existing empty-directory rule.
  A nested worktree shows up in `git clean -ndX` as `Would skip repository
  <path>` — plain `git clean -fdX` leaves it alone, but `-ffdX` (double force)
  deletes it outright, so never widen the force flag to make a listing "go
  away". Report these (with their size when `--sizes` is passed — see below);
  deciding which worktrees are *reclaimable* needs merge state and agent
  liveness that `/repo:tidy` does not have, so it stays a report, never a
  deletion.
- Anything else that looks credential-like or holds unique local state
  (local SQLite DBs, local-only config, sample-data caches)

A denylist match routes to **ASK** (never auto-deleted) — not KEEP, which is
reserved for tracked files.

- **SAFE** — pure junk, regenerable with certainty and holding no unique work,
  matched by an explicit **allowlist** (never "everything `git clean -ndX` lists
  minus a couple of exclusions"). Auto-deleted by default. A file is SAFE only if
  it does **not** match the denylist above **and** matches one of:
  - OS/editor droppings: `.DS_Store`, `Thumbs.db`, `*~`, `*.swp`, `.#*`
  - Merge/patch leftovers: `*.orig`, `*.rej`, `*.BACKUP.*`
  - Empty directories **whose path matches no never-delete denylist entry** —
    the denylist is checked first here exactly as it is for the file patterns
    above. An empty directory under a tool-scaffolding / coordination root
    (`.loom/`, `.anvil/`, `.wrangler/`, …) routes to **ASK**, not SAFE:
    emptiness is that tool's normal operating state, not evidence of junk. Every
    other empty directory (an empty `build/`, say) is SAFE. Note that the
    `find . -type d -empty` inventory in step 1 is a raw path scan — it consults
    neither gitignore nor the denylist — so this check must be applied to its
    output before anything is deleted.

  Nothing in this category may be tracked by git or match a source-code
  extension.
- **CACHE** — regenerable compilation/tool/build output. Same certainty as SAFE
  (definitely regenerable, no unique work), but deleting it forces a potentially
  slow rebuild, so it is **kept by default** and cleared **only** when `--caches`
  is passed (see Apply). A file is CACHE if it does **not** match the denylist
  and matches one of:
  - Python caches: `__pycache__/`, `*.pyc`, `.pytest_cache/`, `.mypy_cache/`,
    `.ruff_cache/`
  - Build output: stale `dist/`, `.turbo/`, `.astro/`, `htmlcov/`, `.coverage`,
    coverage output, `site/dist`

  Like SAFE, nothing here may be tracked by git or match a source-code extension.
  (`node_modules/` and virtualenvs are **not** CACHE — they are denylisted
  environments and stay in ASK even with `--caches`.)
- **ASK** — probably junk but needs a human call. This covers:
  - Untracked files that aren't gitignored (could be unsaved work!), large
    files, stale-looking logs, old `tmp/` contents.
  - **Any gitignored file that matches the never-delete denylist** (secrets,
    virtualenvs, tool-scaffolding roots) — surfaced here, never auto-deleted.
  - **Any empty directory whose path matches the denylist** (a `.loom/`,
    `.anvil/`, or `.wrangler/` coordination or runtime-state dir) — emptiness
    is that tool's normal state, so it lands here rather than in SAFE.
  - **Any git worktree root** detected in step 1 — surfaced on its own
    `worktree:` inventory line (see Report), never auto-deleted, whether or not
    it is gitignored and whether or not it sits under a recognized tool
    dot-directory.
  - **Any gitignored file that does not match the SAFE or CACHE allowlist** (a
    novel/unrecognized cache dir, unrecognized local state) — when in doubt, it
    lands here, not in SAFE or CACHE.

  Deciding which worktrees, branches, and stashes are *stale* remains
  [[reset]]'s job — point there instead of pruning them here. `/repo:tidy`'s
  job with worktrees is only **visibility and protection**: report every root
  (and its size under `--sizes`) so the operator can see the footprint, and
  never delete one.
- **KEEP** — flagged only as information: tracked files that look like they
  don't belong (build output that got committed — point to [[gitignore]]).

### 3. Report

```
## Repo Clean — inventory

SAFE (would free 32 MB — deleted by default):
  .DS_Store × 14
  3 *.orig merge leftovers
  6 empty directories

CACHE (would free 402 MB — kept by default; pass --caches to clear):
  __pycache__/ × 22 dirs
  .mypy_cache/ (gitignored, 22 MB)
  dist/ (gitignored, 380 MB)

ASK:
  .env                     gitignored, 1 KB  ← credentials, never auto-deleted
  .venv/                   gitignored, 240 MB  ← virtualenv, expensive to rebuild
  node_modules/            gitignored, 310 MB  ← environment, reinstall via npm; not a --caches target
  .loom/locks/             gitignored, empty  ← coordination root, empty is normal state
  .wrangler/tmp/           gitignored, empty  ← tool runtime dir, empty between builds
  notes-scratch.md         untracked, 3 KB, modified today  ← might be real work
  sim-output-old/          untracked, 1.2 GB, untouched 60 days

WORKTREES (4 roots — never auto-deleted, listed for visibility; --sizes to measure):
  worktree: .loom/worktrees/issue-42      ← live git worktree
  worktree: .claude/worktrees/scratch-wt  ← live git worktree
  worktree: ../repo-wt-fix123             ← live git worktree (outside repo root)
  worktree: /private/tmp/wt-bisect        ← live git worktree (outside repo root)
  Pruning stale worktrees is /repo:reset's call, not tidy's.

KEEP (informational):
  assets/build.min.js      tracked but looks generated — see /repo:gitignore
```

With `--sizes`, the same block gains a right-aligned size column and a total
(`size unavailable` for any root that hit the `timeout`):

```
WORKTREES (66 GB across 4 roots — never auto-deleted, listed for visibility):
  worktree: .loom/worktrees/issue-42       32 GB  ← live git worktree
  worktree: .claude/worktrees/scratch-wt  3.1 GB  ← live git worktree
  worktree: ../repo-wt-fix123              12 GB  ← live git worktree (outside repo root)
  worktree: /private/tmp/wt-bisect         19 GB  ← live git worktree (outside repo root)
  Pruning stale worktrees is /repo:reset's call, not tidy's.
```

The `WORKTREES` block is a **distinct inventory section**, not folded into the
generic denylist ASK lines, and under `--sizes` its bytes are summed
**separately** from the SAFE/CACHE/ASK totals (a worktree's contents are neither
freed nor freeable by this command); roots whose size is unavailable are
excluded from the total and the total is marked as a lower bound. Print the
block whenever at least one worktree root exists — including on an
otherwise-clean run and including without `--sizes`, so `/repo:tidy` never
reports "nothing to tidy" on a tree where tens of gigabytes are sitting in
worktrees with no hint of where the space went. The count and the paths are what
carry that signal; the sizes only quantify it.

If the repo documents its **own** worktree-management tooling — a script,
`package.json` command, `Makefile` target, or binary the repo's own docs point
at for this purpose — mention it after the block as a soft pointer (e.g.
`Reclaimable worktrees: try 'loom-daemon clean --safe --dry-run'.`). Only
whichever the repo actually documents; `/repo:tidy` has no reliable way to
discover arbitrary third-party tooling, so **omit the line entirely rather than
guessing** at a command that may not exist.

### 4. Apply

- Default: delete the SAFE category immediately, report the CACHE tier as kept
  (with the bytes `--caches` would free), then present ASK items for a decision.
  Never auto-delete anything in ASK, no matter the flags.
- With `--caches`: the CACHE tier joins the auto-delete set — delete SAFE **and**
  CACHE immediately, then present ASK. `--caches` never widens what counts as
  deletable beyond the CACHE allowlist; denylisted paths (secrets, virtualenvs,
  `node_modules/`) stay in ASK regardless.
- With `--ask`: walk through every category with the user, including SAFE and
  CACHE; delete only what they approve. (`--ask` already surfaces caches for a
  decision, so `--caches` is redundant with it — the flag only affects the
  non-interactive default.)

The default auto-delete is scoped to **SAFE-allowlisted paths only** (plus the
CACHE allowlist when `--caches` is passed). Never pass a denylisted path
(secrets, virtualenvs, `node_modules/`, tool-scaffolding roots, git worktree
roots — **including when it is empty**) or an unrecognized gitignored path to
`git clean -fdX` — those are ASK items and require an explicit human call. Build
the explicit `<paths>` list from the SAFE category (and CACHE under `--caches`)
and nothing else; do **not** run a blanket `git clean -fdX` that would sweep
whatever `git clean -ndX` lists.

Use `git clean -fdX -- <paths>` for gitignored artifacts and plain `rm` only
for pattern-matched junk you listed in the report. After deleting, re-run the
inventory to confirm and report bytes freed.

## Safety Rules

1. **Never delete tracked files** — that's a git operation the user does deliberately
2. **Never touch `.git/`** internals
3. **Untracked ≠ junk** — an untracked file modified recently is presumed to be
   unsaved work and always lands in ASK
4. **Everything deleted must have appeared in the report first**
5. When scoped to a subtree, do not delete anything outside it
6. **Gitignored ≠ safe to delete** — the never-delete denylist (secrets like
   `.env`/`*.pem`/`*.key`, environments like `.venv/`/`venv/`/`env/` and
   `node_modules/`, tool-scaffolding roots like `.loom/`/`.anvil/`/
   `.wrangler/`, and git worktree roots) always overrides SAFE and CACHE and
   routes to ASK, regardless of what `git clean -ndX` lists. Unrecognized
   gitignored files fall through to ASK, never SAFE or CACHE.
7. **Caches are opt-in** — the CACHE tier (`__pycache__/`, `dist/`, `.mypy_cache/`,
   and the other compilation/tool/build patterns) is never auto-deleted by
   default; it is cleared only when `--caches` is passed (or approved item-by-item
   under `--ask`). Deleting a cache is safe but forces a rebuild, so the default
   keeps it.
8. **Empty ≠ abandoned** — for lock, coordination, and runtime-state
   directories, empty is the *normal operating state*, not clutter: an empty
   `.loom/locks/` means nothing is currently held, and `.loom/worktrees/`,
   `.loom/sweep-run/`, `.loom/sweep-checkpoint/`, or `.wrangler/tmp/` are empty
   whenever no run is in flight. Deleting them reads a tool working correctly as
   evidence of junk. So the ordering in rule 6 applies to **directories exactly
   as it does to files**: check the denylist before the empty-directory rule in
   SAFE. Emptiness never promotes a denylisted path into SAFE, and never
   bypasses the fall-through to ASK for unrecognized gitignored paths.
9. **Never delete a git worktree root** — a worktree is a live checkout that
   may hold uncommitted, unpushed work, and it is denylisted on the strength of
   `git worktree list --porcelain` (or a `.git` **file** pointing at
   `…/.git/worktrees/…`), *not* on where it happens to live. Do not infer
   protection from a dot-directory prefix: `.claude/worktrees/`, a sibling
   `../repo-wt-fix123`, and a worktree under `/private/tmp/` are all protected
   by this rule and none of them are matched by rule 6's prefix list. Report
   every root (see Report) even when nothing is deleted — the one thing worse
   than deleting a worktree is telling the operator their 94 GB tree is clean.
   Sizing those roots is a `du` with no `-prune`, so it is opt-in behind
   `--sizes` and bounded per root; the report itself never is.
