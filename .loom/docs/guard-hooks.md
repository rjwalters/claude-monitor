# Guard Hooks Reference

Loom's `PreToolUse` guard hooks and their per-repo toggles. Each toggle resolves
through the tiered config resolver with **env > tracked `.loom-project/project.json`
> legacy `.loom/config.json` > default** precedence (Epic #3835 Phase 2 / #4039;
see "Config tiers" below); the operating-core guides (`CLAUDE.md` and
`.loom/CLAUDE.md`, "Configuration → Guard hooks") point here for the full catalog.

## Machine-Level Execution (Epic #3835 Phase 5, #4262)

As of Phase 5, the hook **scripts** are no longer copied into each consumer repo's
`.loom/hooks/`. They execute from the **single machine-level checkout**
(`${LOOM_HOME:-~/.local/share/loom}/defaults/hooks/`), wired once into the
operator's **user-scope** `~/.claude/settings.json` by
`scripts/install/provision-hooks.sh` (a sibling of the Phase 4 skills provisioner).
A freshly-installed consumer repo therefore carries **no** hook-script copies and
they can never drift stale (the recurring `resync-installed.sh` pain). Hook
**policy** — the `guards.*` toggles and `buildGate` — still lives per-repo, read
from the tracked `.loom-project/project.json` (or legacy `.loom/config.json`)
through the tiered resolver. Implementation vs. policy are split: scripts machine-
level, config per-repo.

Each user-scope entry is a **fail-open, self-gating** command wrapper, because a
user-scope hook fires in *every* repo the operator opens:

1. **Workspace gate** — it resolves the main repo root worktree-aware
   (`git rev-parse --git-common-dir`/.., so guards still fire from inside
   `.loom/worktrees/*`) and **exits 0 silently** unless that root holds
   `.loom-project/project.json` or `.loom/config.json`. Non-Loom repos, and the
   case where the machine checkout is absent, no-op cleanly.
2. **Transition precedence** — if the repo still carries a per-repo
   `.loom/hooks/<name>` copy (pre-Phase-6 / #4254), the wrapper **defers**: it
   exits 0 and lets the project-level `.claude/settings.json` entry run that copy.
   The project copy **wins** until Phase 6 strips it, so a transition repo runs
   each guard exactly **once** (no double-fire, no duplicated `guards.decisionLog`
   lines).
3. **Machine exec** — otherwise it exec's the machine-checkout hook, passing the
   resolved repo root through `LOOM_PROJECT_ROOT` so `guard-destructive.sh`'s
   dispatcher resolves the *consuming* repo's canonical Repo-Skills guard from a
   checkout-shaped `SCRIPT_DIR`.

Existing per-repo `.loom/hooks/` copies on an already-installed repo are left in
place by this phase; removing them is Phase 6 (#4254) migration territory. Daemon-
spawned workers inherit the user-scope wiring because `loom-daemon` copies
`~/.claude/settings.json` into each worker's isolated `CLAUDE_CONFIG_DIR`.

### Quick Install and the project-level fallback (#4401)

Step 2 above (transition precedence) means the user-scope wiring is **only half** an
execution path: while a repo still carries `.loom/hooks/` copies, the wrapper defers
to a **project-level** `.claude/settings.json` entry — so that entry has to exist.
`install.sh --quick` still writes those copies (`install_hooks_and_cli`), but the
0.16.0 `defaults/.claude/settings.json` deliberately carries no `hooks` block, and a
`--confirm-reinstall`'s chained `scripts/uninstall-loom.sh` strips every
`.loom/hooks/`-prefixed command out of the project file. Before #4401 that combination
left a `--quick`-installed repo with **zero** guards: copies present (so the wrapper
deferred) and no project entry to defer to.

Both Quick Install call sites now run `wire_quick_install_guard_hooks`, which calls:

- **`provision_loom_hooks`** — the user-scope wiring (previously reached only via the
  Full Install path). Note the quick path does not establish the machine checkout
  (`provision_loom_dispatcher` is Full-Install-only), so on a quick-only machine these
  entries stay a silent no-op until a Full Install / `loom update` creates
  `~/.local/share/loom` — or `LOOM_HOME` points at a checkout.
- **`ensure_project_hook_wiring`** — re-asserts the project-level
  `${CLAUDE_PROJECT_DIR}/.loom/hooks/<name>` entries for every hook copy actually
  present on disk. This is the layer that is guaranteed live on the quick path. It is a
  **no-op** on a post-Phase-6 (migrated, copy-free) repo, where the machine-level path
  is the one true path.

The two compose to **exactly one** firing path in either configuration — copies present
⇒ project entry runs, wrapper defers; copies absent ⇒ no project entry written, wrapper
execs the machine hook. It is re-asserted on every install rather than made
strip-proof: the uninstaller matches on the `.loom/hooks/` command prefix, not on
provenance, so no project-level entry can survive an uninstall by design.

If you want the machine-level end state (no per-repo copies at all), run
`loom migrate` (Phase 6 / #4254) — it untracks the legacy copies, after which
`ensure_project_hook_wiring` stops writing project entries on its own.

### Config tiers

The guard toggles below are documented against `.loom/config.json` for historical
continuity, but every `guards.*` / `worktree.*` read now flows through the tiered
resolver (`defaults/scripts/lib/config-resolver.sh` `loom_config_get`), so the same
key set in the tracked `.loom-project/project.json` takes precedence over the legacy
`.loom/config.json`, and an `LOOM_*` env override beats both. `buildGate` is read the
same way by the daemon's main-health gate (`main_health_gate.rs`, already tiered).
The `guard-worktree-paths.sh` toggle reads and the `guard-destructive-generic.sh`
read-only fast-path toggles both consult `.loom-project/project.json` first, then the
legacy file — the fast path stays a bounded, direct-`jq` read (never the full resolver
merge) to preserve the #3687 fork budget on the hottest guard invocation.

## Custom Guard Hooks

Loom ships with several built-in `PreToolUse` guard hooks, registered independently under the `Bash` or `Edit|Write` matcher as noted below:

- **`guard-destructive.sh`** (`Bash` matcher) — the generic repository-hygiene guard (catastrophic denies like `rm -rf /`, force-push to `main`, `gh repo delete`, fork bombs, curl-pipe-to-shell, cloud/SQL destruction; the segment-parsed lifecycle/cloud-CLI checks; and the `guards.sqlDdl` / `guards.cloudCli` / `guards.reversibleGh` / `guards.rmScope` / `guards.forceScope` toggle machinery documented below). Nothing about this guard is Loom-specific, so as of **#4041 its canonical home is [Repo Skills](https://github.com/rjwalters/repo)** (installed at `.claude/skills/repo/hooks/guard-destructive.sh`, carrying the rjwalters/repo#29 curl-pipe fix). In Loom, `guard-destructive.sh` is now a thin **dispatcher**: when the canonical Repo Skills guard is present it defers to it at runtime (and the installer does not install a second generic guard); otherwise it falls back to a clearly-marked **vendored copy** (`guard-destructive-generic.sh`) that Loom ships so standalone-Loom repos — those without Repo Skills — keep full coverage. Exactly one generic guard ever runs; the behavior and all the toggles below are unchanged either way. The pattern list itself is maintained upstream in Repo Skills, not forked in Loom. **Loom-specific exceptions:** the vendored copy also carries the Bash-tool **write-confinement** category (`>`/`>>` redirection, `tee`, `sed -i`, `cp`/`mv`, issue #4178) — see `guards.worktreeIsolation` below — and an **ungated hard deny on `gh pr comment`/`gh issue comment --body @path`** (issue #4523: this shape never expands the file — it posts the literal string `@path` as the comment body, which lost an entire Judge review on PR #4457). That rule deliberately scans the *raw* command rather than the `strip_literal_text()`-redacted copy the rest of the catastrophic scan uses, because redaction would erase the leading `@` inside a quoted `--body "@path"` value and silently defeat the check for exactly the shape most likely to occur in practice — see the comment above the check in `guard-destructive-generic.sh` for the full trap writeup. Both of these stay Loom-owned even though the rest of the file mirrors upstream, the same way `resolve_worktree_root()`/`guards.rmScope` already do.
- **`guard-loom-workflow.sh`** (`Bash` matcher) — the thin, Loom-workflow-specific guard (issue #3604): the `gh pr merge` → `merge-pr.sh` redirect, the `pip install -e` worktree block (keyed on `LOOM_WORKTREE_PATH`, issues #2495 + #4079), and the `loom-daemon workspace` registry-mutation ask (issue #4326, below). **On the `pip install -e` block:** Loom's own tree no longer contains a load-bearing Python package (epic #4081 Phase 4, #4557, retired `loom-tools` — see [ADR-0013](../../docs/adr/0013-loom-tools-python-retirement.md)), but this guard is deliberately retained and *strengthened*, for two reasons. It protects any **Python repo under Loom orchestration** from the original hazard (parallel builders clobbering the global `.pth`, #2495); and an editable install also drops **frozen console scripts** into `~/.local/bin` that outlive the package and shadow whatever is later installed under the same name — the incident (#4079) in which a stale `pip install -e loom-tools` kept shadowing the Rust `loom-daemon` binary on PATH, and the direct motivation for epic #4081. The deny message points at `.loom/scripts/run-tests.sh` (which sets `PYTHONPATH` for the worktree) as the supported alternative; `loom-daemon-update.sh` warns about survivors that predate the guard. This guard and `guard-worktree-paths.sh` below are specific to the Loom worktree/merge/daemon workflow and stay Loom-owned.
- **`guard-worktree-paths.sh`** (`Edit|Write` matcher, issue #2441 / #4007) — confines Edit/Write tool calls to a builder's issue worktree, denying writes that resolve into the main checkout. Two mechanisms: the `LOOM_WORKTREE_PATH` env fast path (tmux/manual sessions pinned to one worktree) and, when that env var is absent, a **path-derived fallback** — it walks up from the target path looking for the `.loom-managed` sentinel `worktree.sh` writes at every worktree root, and denies a write that lands in the main checkout while at least one managed worktree exists. The fallback exists because a daemon-dispatched sweep hosts multiple Task-subagent builders in one shared process env, so a single process-wide `LOOM_WORKTREE_PATH` cannot cover that path (#3719). Toggle: `guards.worktreeIsolation` / `LOOM_GUARD_WORKTREE_ISOLATION`, documented alongside the other guard toggles below. **This confines the Edit/Write tool matcher only** — a session denied here could historically fall back to a Bash-tool write (`>`, `tee`, `sed -i`, `cp`/`mv`) targeting the same path with nothing to stop it (the #4178 incident: sweep #4063 used exactly this to edit live guard hooks in the main checkout). `guard-destructive-generic.sh`'s write-confinement category (bullet above) now closes that gap under the identical toggle.
- **`guard-background-subagents.sh`** (`Stop` hook, issue #4257) — a mechanical backstop for the hazard documented in `defaults/.claude/commands/loom/sweep.md` under "Subagent dispatch is async-only" (#3822): in headless `claude -p` mode, ending the orchestrator's turn **terminates the process**, which kills every still-running background Task subagent (the #4195/#4243 incident this issue traces). This hook fires when the session is about to stop, scans the transcript JSONL for `Task` tool_use entries with no matching `tool_result`, and **blocks the stop once** with a loud reason explaining the hazard when it finds any unresolved dispatch. It uses `stop_hook_active` to block **at most once per stop sequence** — this is a heuristic over the transcript file (not a live process check), so a second consecutive block could wedge the session on a false positive (e.g. a slow transcript flush); after one block, the guard always allows. Toggle: `guards.backgroundSubagents` / `LOOM_GUARD_BACKGROUND_SUBAGENTS`, documented alongside the other guard toggles below.

You can also add project-specific guards to protect read-only directories from accidental edits (see below).

### Which generic guard is authoritative — and why the vendored copy stays (#4403, #4566)

**At runtime the canonical Repo Skills guard always wins** when it is present: `guard-destructive.sh` is a dispatcher, so the vendored `guard-destructive-generic.sh` is a *fallback*, never a second guard running alongside it.

Whether the vendored copy is **installed** is a separate, per-repo choice, and both answers are supported:

| Repo layout | Vendored `.loom/hooks/guard-destructive-generic.sh` | What `resync-installed.sh` does |
|---|---|---|
| `.loom/` gitignored (the usual consumer repo) | untracked, per-host | **removes** it once a canonical Repo Skills guard is detected locally — the dispatcher covers this host |
| `.loom/` committed (**Loom itself dogfoods this layout**) | **git-tracked on purpose** | **keeps** it, and reports an informational `unchanged … (git-tracked vendored fallback kept)` line |

The committed case is deliberate, not drift: a git-tracked vendored guard is repo-shared state, so contributors and CI runners **without** Repo Skills installed still get full generic-guard coverage. Resync must therefore never delete it on the strength of one host's local, typically-gitignored `.claude/skills/repo/` install (#4403) — and because that state is the expected steady state rather than an anomaly, it is reported as a `note` (suppressed under `--quiet`) instead of a `WARN` that would reprint on every resync forever (#4566).

If a repo genuinely wants to rely on Repo Skills provisioning instead, it drops the vendored copy **deliberately and repo-wide** with `git rm .loom/hooks/guard-destructive-generic.sh`; after that commit the branch above stops firing entirely and hosts without Repo Skills fall back to no generic guard, so make that trade consciously.

### SQL DDL/DML Guard Opt-Out (`guards.sqlDdl` / `LOOM_GUARD_SQL`)

`guard-destructive.sh` blocks SQL DDL/DML patterns — `DROP DATABASE`, `DROP TABLE`, `DROP SCHEMA`, `TRUNCATE TABLE`, and `DELETE FROM` without a `WHERE` clause. For most repos this is a useful safety net, but for a project that is **itself a database engine** (e.g. a SQLite-compatible engine running a SQL conformance suite) those statements are the product's own dev/test vocabulary and the guard is a category error — the match is a case-insensitive substring, so it even fires when the words appear in a comment or a `--description` label.

Such repos can opt out of the SQL guard while keeping every other guard (`rm -rf /`, force-push to `main`, `gh repo delete`, `aws s3 rb`, `aws cloudformation delete-stack`, etc.) fully active.

The SQL guard is **on by default**. It is resolved in this order (highest precedence first):

1. **`LOOM_GUARD_SQL` env var** — `0`/`false`/`no` disables the SQL guard; `1`/`true`/`yes` forces it on. Overrides the config value.
2. **`.loom/config.json`** — `guards.sqlDdl` (default `true` when absent). Set it to `false` to disable:
   ```json
   {
     "guards": {
       "sqlDdl": false
     }
   }
   ```
3. **Default** — `true` (guard on).

The config read is best-effort: a missing, empty, or malformed `.loom/config.json` falls through to guard-ON and never causes the hook to exit non-zero. Only the SQL DDL/DML blocks are affected — disabling the SQL guard does not weaken any other guard.

**Examples**:

```bash
# Disable the SQL guard for a single command (e.g. a one-off dev query)
LOOM_GUARD_SQL=0 vibesql -c "DROP TABLE t"

# Persist the opt-out for the whole repo
#   .loom/config.json  ->  { "guards": { "sqlDdl": false } }

# Force the SQL guard on for one command even when the repo opts out
LOOM_GUARD_SQL=1 psql -c "DROP TABLE users"
```

### Cloud CLI Guard Opt-Out (`guards.cloudCli` / `LOOM_GUARD_CLOUD`)

`guard-destructive.sh` asks for confirmation on **mutating** cloud/container CLI calls — `aws ec2 run-instances`/`create-*`/`stop-instances`/`start-instances`/`terminate-instances`, `aws s3 rm`/`rb`/`cp`/`mv`/`sync`, other mutating `aws <service> <verb>` forms, and `docker rm`/`rmi`/`stop`/`kill`/`restart`. Read-only calls (`aws ec2 describe-instances`, `aws s3 ls`, `aws lambda list-functions`, `docker ps`, `docker logs`, etc.) are **not** prompted. For a repo whose *purpose* is managing cloud infrastructure (launch/stop/terminate dev VMs, build/tear-down containers), even the mutating asks are workflow friction rather than a safety win.

Such repos can opt out of the cloud/docker ASK category while keeping every other guard active — including the genuinely catastrophic cloud denies (`aws s3 rm ... --recursive`, `aws s3 rb`, `aws cloudformation delete-stack`, `docker system prune`), which are **never** gated by this toggle and stay hard denies even with the cloud guard off.

Note (#4216): `aws iam delete-*` and `az`/`gcloud … delete` are **no longer** hard denies — they were retiered to the **ungated ask tier** (see below), because deleting a credential or a single cloud resource is a legitimate, often security-positive step (e.g. revoking an exposed key whose replacement is already active) that a hard block only left the undocumented script-file bypass to satisfy. Being **ungated** (not part of the `guards.cloudCli` ASK category) is deliberate: `guards.cloudCli:false` / `LOOM_GUARD_CLOUD=0` still **asks** on `aws iam delete-*` rather than silently allowing it, and a headless sweep still blocks it (an ASK with no human to answer denies — see the Autonomous section below). Only mass object/bucket deletion (`s3 rm --recursive`, `s3 rb`) and stack teardown (`cloudformation delete-stack`) stay hard denies.

The cloud guard is **on by default**. It is resolved in this order (highest precedence first):

1. **`LOOM_GUARD_CLOUD` env var** — `0`/`false`/`no` disables the cloud/docker ASK category; `1`/`true`/`yes` forces it on. Overrides the config value.
2. **`.loom/config.json`** — `guards.cloudCli` (default `true` when absent). Set it to `false` to disable:
   ```json
   {
     "guards": {
       "cloudCli": false
     }
   }
   ```
3. **Default** — `true` (guard on).

The config read is best-effort: a missing, empty, or malformed `.loom/config.json` falls through to guard-ON and never causes the hook to exit non-zero. Only the cloud/docker ASK patterns are affected — disabling the cloud guard does not weaken the catastrophic cloud denies or any other guard.

Note: `aws ec2 terminate-instances` is an **ask** (not a hard deny) so a legitimate VM-teardown workflow is possible; with `guards.cloudCli:false` / `LOOM_GUARD_CLOUD=0` it passes through without prompting.

**Examples**:

```bash
# Tear down a dev VM without a prompt for a single command
LOOM_GUARD_CLOUD=0 aws ec2 terminate-instances --instance-ids i-1234

# Persist the opt-out for a cloud-management repo
#   .loom/config.json  ->  { "guards": { "cloudCli": false } }

# Force the cloud guard on for one command even when the repo opts out
LOOM_GUARD_CLOUD=1 aws ec2 terminate-instances --instance-ids i-1234
```

### Reversible-GitHub Ask Opt-In (`guards.reversibleGh` / `LOOM_GUARD_REVERSIBLE_GH`)

`guard-destructive.sh` scopes its ask tier to **irreversibility** (#3757): a guard whose purpose is preventing catastrophic, hard-to-undo mistakes should not add confirmation friction to operations that are trivially reversed. The **reversible** GitHub state changes — `gh pr close` (undo: `gh pr reopen`), `gh issue close` (undo: `gh issue reopen`), and `gh label delete` (undo: recreate, or one `gh label sync` in a repo with `labels.yml`) — therefore **do not prompt by default**. An autonomous agent that closes its own issue/PR as part of a normal lifecycle no longer stalls on a confirmation prompt (or, in a headless run with no approver, blocks entirely).

The genuinely hard-to-reverse operations stay in the ungated ask tier and are **not** affected by this toggle: `gh release delete` (deletes published artifacts/tags), `git clean -fd` / `git checkout .` / `git restore .` (untracked / uncommitted loss), and — since #4216 — `aws iam delete-*` and `az`/`gcloud … delete` (cloud credential / resource deletion, retiered here from the catastrophic deny list; ungated on purpose so `guards.cloudCli:false` cannot silently bypass them). The full catastrophic deny suite (`rm -rf /`, force-push to `main`, `gh repo delete`, `aws s3 rb`, `aws cloudformation delete-stack`, …) is likewise unaffected.

A repo that *wants* the confirmation back on the reversible GitHub ops can **opt in**. Unlike `guards.sqlDdl` / `guards.cloudCli` (which default **on** and are opted **out**), this toggle has **inverse polarity**: it defaults **off** and is opted **in**, because enabling it *adds* friction rather than removing it.

The reversible-GitHub ask is **off by default**. It is resolved in this order (highest precedence first):

1. **`LOOM_GUARD_REVERSIBLE_GH` env var** — `1`/`true`/`yes` enables the ask on `gh pr close` / `gh issue close` / `gh label delete`; `0`/`false`/`no` forces it off. Overrides the config value.
2. **`.loom/config.json`** — `guards.reversibleGh` (default `false` when absent). Set it to `true` to opt in:
   ```json
   {
     "guards": {
       "reversibleGh": true
     }
   }
   ```
3. **Default** — `false` (no ask; the reversible GitHub ops pass through).

The config read is best-effort: a missing, empty, or malformed `.loom/config.json` falls through to guard-**off** (the default) and never causes the hook to exit non-zero. Only the three reversible GitHub ASK patterns are affected — opting in does not touch `gh release delete`, the `git clean`/`checkout`/`restore` asks, or any deny.

**Examples**:

```bash
# Default (off) — reversible GitHub ops pass through without a prompt:
gh pr close 42          # allowed (undo: gh pr reopen 42)
gh issue close 100      # allowed (undo: gh issue reopen 100)
gh label delete stale   # allowed (undo: recreate the label)
gh release delete v1.0  # STILL asks (not gated — deletes published artifacts)

# Opt in to the confirmation for a whole repo:
#   .loom/config.json  ->  { "guards": { "reversibleGh": true } }
gh issue close 100      # ASK

# Opt in for a single command:
LOOM_GUARD_REVERSIBLE_GH=1 gh pr close 42       # ASK

# Force off for one command even when the repo opts in:
LOOM_GUARD_REVERSIBLE_GH=0 gh issue close 100   # allowed
```

### Worktree Isolation Guard Opt-Out (`guards.worktreeIsolation` / `LOOM_GUARD_WORKTREE_ISOLATION`)

`guard-worktree-paths.sh` (issue #4007) denies Edit/Write tool calls whose target resolves into the **main** repository checkout while a Loom-managed worktree exists (path-derived — see the guard inventory bullet above for the mechanism). This is the mechanical enforcement behind "never work on main branch": a builder that used a repo-relative path after a cwd reset, or that otherwise escaped its issue worktree, is denied instead of silently corrupting the main checkout.

**Bash-tool write confinement (issue #4178).** The same toggle *also* gates a
second, independent check inside `guard-destructive-generic.sh` (the `Bash`
matcher): it denies the common Bash write idioms — `>`/`>>` redirection,
`tee`, `sed -i`, `cp`/`mv` — when their target resolves into the main checkout
while a managed worktree exists, using the identical path-derived logic
(`.loom-managed` sentinel walk-up). This closes the exact escape a real
incident used: sweep #4063 was denied repeatedly on the Edit/Write path
(logged in `.loom/logs/hook-errors.log`), then fell back to a Bash write for
the same target and landed uncaught — because nothing confined the Bash tool.
One toggle now governs both surfaces; there is no separate config key for the
Bash-side check. Like the Edit/Write guard, this is a best-effort heuristic,
not a full shell parser — it recognizes the common write idioms and resolves
ambiguity toward **allow**, never toward a spurious deny (see
`guard-destructive-generic.sh`'s `extract_write_targets()` for the exact
recognized forms and their documented limitations). It deliberately does not
attempt to catch every conceivable write vector (an interpreter one-liner like
`python -c` is unparseable from a shell hook) — the goal is removing the easy
fallback an agent reaches for after an Edit/Write denial, not building a full
security boundary.

The guard is **on by default**. It is resolved in this order (highest precedence first):

1. **`LOOM_GUARD_WORKTREE_ISOLATION` env var** — `0`/`false`/`no` disables the guard; `1`/`true`/`yes` forces it on. Overrides the config value.
2. **`.loom/config.json`** — `guards.worktreeIsolation` (default `true` when absent). Set it to `false` to disable:
   ```json
   {
     "guards": {
       "worktreeIsolation": false
     }
   }
   ```
3. **Default** — `true` (guard on).

The config read is best-effort: a missing, empty, or malformed `.loom/config.json` falls through to guard-ON and never causes the hook to exit non-zero. Disabling this guard does not weaken any other guard. The toggle governs the guard as a whole — disabling it skips **all three** mechanisms: the `LOOM_WORKTREE_PATH` fast path's own containment check, the Edit/Write path-derived fallback, and the Bash-tool write-confinement check.

**Operator escape hatch.** A human or `driver` session that needs to edit the
main checkout directly while worktrees exist (e.g. hand-fixing something
outside the normal Builder flow) should set `guards.worktreeIsolation: false`
in `.loom/config.json` for the session, or export
`LOOM_GUARD_WORKTREE_ISOLATION=0` for a single command — both mechanisms are
disabled together, so there is no need to separately silence the Bash-side
check. Restore the guard (remove the override, or `LOOM_GUARD_WORKTREE_ISOLATION=1`)
once the direct edit is done.

### Background Subagent Stop Guard (`guards.backgroundSubagents` / `LOOM_GUARD_BACKGROUND_SUBAGENTS`)

`guard-background-subagents.sh` (issue #4257, coverage extended by #4389 and #4462) is a `Stop` hook, not a `PreToolUse` guard — it does not gate a tool call, it gates the orchestrator **ending its turn**. The hazard it backstops: in headless `claude -p` mode there is no later turn to "check back in" on outstanding background work — ending the turn terminates the process, and process exit kills every still-running background child outright, whether that child is a dispatched Task subagent, a `run_in_background: true` Bash task, or an armed-but-unfired `Monitor`/`ScheduleWakeup` timer. `defaults/.claude/commands/loom/sweep.md`'s "Subagent dispatch is async-only" section (#3822) documents the discipline (always explicitly await a dispatched subagent's completion before advancing); this hook is the mechanical backstop for when an orchestrator forgets it anyway.

When the session is about to stop, the hook reads the transcript JSONL named in the Stop-hook payload and scans it for three independent dispatch-without-observed-completion patterns:

1. **Task subagents** — `Task` tool_use entries with no matching `tool_result` anywhere in the transcript, i.e. a subagent dispatch the orchestrator never observed completing.
2. **Background Bash tasks (#4389)** — Bash tool_use entries with `input.run_in_background == true` whose dispatch id has no matching `<task-notification>...<tool-use-id>ID</tool-use-id>...` completion event anywhere later in the transcript. This is deliberately a *different* completion signal than (1): a background Bash dispatch gets an **immediate** `tool_result` ack at dispatch time ("Command running in background with ID: ..."), which is NOT completion — the real completion arrives later as a task-notification message. Matching on `tool_result` alone (pattern 1's logic) would treat the dispatch-time ack as already-resolved and never catch this case, which is exactly the gap #4389 closes (a recurrence of #4257 that the prose-only guardrail in the sweep skill did not prevent). **Notification shapes (#4482)**: the completion `<task-notification>` is *not* a `type=="user"` message — the harness writes it as a top-level `type=="queue-operation"` entry (notification text in the `.content` string) and/or a `type=="attachment"` entry (`commandMode:"task-notification"`, text in `.attachment.prompt`). The matcher scans both real shapes (plus the legacy `type=="user"` string-content path, for compatibility) and extracts the `<tool-use-id>` from whichever the installed harness emitted; matching against only the `type=="user"` shape was the original #4482 bug, which unconditionally re-flagged every already-completed background Bash task on every later stop of the session.
3. **Armed `Monitor` / `ScheduleWakeup` timers (#4462)** — `Monitor` or `ScheduleWakeup` tool_use entries whose dispatch id has no matching `<task-notification>...<tool-use-id>ID</tool-use-id>...` *fired* event later in the transcript. This reuses pattern (2)'s notification-echo matching (not the dispatch-time ack) for the same reason: arming a timer returns an immediate "timer armed" ack that is NOT the fire event. The #4462 incident was a transport failure (529/Overloaded killing a Builder subagent) handled by arming `Monitor {command: "sleep 90 && …"}` and ending the turn — in `-p` mode the timer has no session to wake, the process exits **0** (so the wrapper logs "completed successfully" and the reaper sees a clean exit), and the issue is stranded in `loom:building` with no PR. The skill-level rule (`#3822` section) is: a transport-failure backoff must be a bounded **in-turn** sleep-and-retry loop, or the orchestrator must exit NONZERO — never an armed end-of-turn timer.

If it finds any of the three, it blocks the stop with a reason describing the hazard, pointing back at the `#3822` section. This is a **heuristic over the transcript file**, not a live process check (no such live signal exists inside a hook), so it can false-positive (e.g. a transcript write that hasn't flushed yet) — for that reason it uses the Stop-hook's `stop_hook_active` flag to block **at most once per stop sequence**: the second consecutive stop, in the same sequence, is always allowed regardless of what the heuristic finds, so a false positive cannot wedge a session in an unblockable loop.

**Wiring note**: this hook only fires if a `Stop` hook entry is actually wired for the repo. Fresh consumer installs get this from the user-scope `provision-hooks.sh` wiring; a repo that also carries a per-repo `.loom/hooks/` copy (this repo included) must additionally wire `Stop` in its own project-scope `.claude/settings.json` — the user-scope entry defers to a project copy when one exists, so it silently no-ops otherwise (the #4389 wiring gap).

The guard is **on by default**. It is resolved in this order (highest precedence first):

1. **`LOOM_GUARD_BACKGROUND_SUBAGENTS` env var** — `0`/`false`/`no` disables the guard; `1`/`true`/`yes` forces it on. Overrides the config value.
2. **`.loom/config.json`** — `guards.backgroundSubagents` (default `true` when absent). Set it to `false` to disable:
   ```json
   {
     "guards": {
       "backgroundSubagents": false
     }
   }
   ```
3. **Default** — `true` (guard on).

The config read is best-effort: a missing, empty, or malformed `.loom/config.json` falls through to guard-ON and never causes the hook to exit non-zero; a missing/unreadable/unparseable transcript, or a missing `jq`, also fails open (allow the stop) rather than wedging the session.

### Workspace Registry Guard (`guards.workspaceRegistry` / `LOOM_GUARD_WORKSPACE_REGISTRY`)

`guard-loom-workflow.sh` (issue #4326) ASKS for confirmation before a `loom-daemon workspace add|remove|set-priority` command runs — these mutate the machine-level workspace registry (Issue #3926), normally the operator's **real** `~/.loom/workspaces.json`, a file shared across every repo and session on the host. The hazard it backstops: an ad-hoc verification step (a builder/auditor sweep exercising registry behavior) that calls the real CLI directly leaves dangling or incorrect entries in the operator's actual registry. Issue #4326 found exactly this — a leaked `/private/tmp/mig-test` entry sat at explicit dispatch priority `3`, ahead of every real managed repo, for most of a day, because the scratch directory was deleted without a matching `workspace remove`. `loom-daemon workspace list` is read-only and is **never** matched by this guard.

`LOOM_WORKSPACES_PATH` (`loom-daemon/src/workspace_registry.rs`) already exists as the sanctioned scratch-registry seam — every daemon unit test points at it instead of the real file (see `defaults/docs/machine-dispatcher.md`'s "Testing against a scratch registry" section). The guard therefore allows the command through, with **no** ask, whenever `LOOM_WORKSPACES_PATH` is already set in the environment, or assigned inline on the same command line (e.g. `LOOM_WORKSPACES_PATH=/tmp/scratch.json loom-daemon workspace add /tmp/x`) — this check runs regardless of the toggle below, since it identifies a specific *safe* command, not a category opt-out.

The category guard itself is **on by default**, resolved in this order (highest precedence first), independently of the `LOOM_WORKSPACES_PATH` allowance above:

1. **`LOOM_GUARD_WORKSPACE_REGISTRY` env var** — `0`/`false`/`no` disables the guard; `1`/`true`/`yes` forces it on. Overrides the config value.
2. **`.loom/config.json`** — `guards.workspaceRegistry` (default `true` when absent). Set it to `false` to disable:
   ```json
   {
     "guards": {
       "workspaceRegistry": false
     }
   }
   ```
3. **Default** — `true` (guard on).

The config read is best-effort: a missing, empty, or malformed `.loom/config.json` falls through to guard-ON and never causes the hook to exit non-zero. This is an **ask**, never a hard deny — an operator legitimately managing their own real registry (e.g. permanently deregistering a decommissioned repo) can confirm and proceed.

### Repo-Scoped rm Guard (`guards.rmScope` / `LOOM_RM_SCOPE`)

By default (as of #3628), `guard-destructive.sh` runs in **`repo` mode**: it blocks the **catastrophic** `rm -rf` targets — root (`/`), the user's `$HOME`, and any bare top-level directory (`/tmp`, `/var`, `/etc`, …) — **and** additionally denies any `rm -rf` target that is neither inside the repo/worktree areas nor on a built-in **ephemeral allowlist**. So an outside-repo deep path like `rm -rf /Users/someone/important` is **denied** out of the box. This is the safe-by-default behaviour (ADR Option B); it is a **behaviour change** from the pre-#3628 permissive default.

Repos that need the old permissive behaviour — block only catastrophic targets and **allow** every deeper subpath, including subpaths outside the repository — can **opt out** to `off` (a.k.a. `permissive`) mode. The catastrophic top-level deny stays active in both modes, so bare `/tmp` and `/` are always blocked regardless.

The rm-scope guard is **repo (on) by default**. It is resolved in this order (highest precedence first):

1. **`LOOM_RM_SCOPE` env var** — `repo` forces repo mode; `off`/`0`/`no`/`permissive` forces the permissive opt-out; unset falls through to the config/default. Overrides the config value.
2. **`.loom/config.json`** — `guards.rmScope`. An explicit `"off"` (or its synonym `"permissive"`) opts out to permissive mode; an absent key, any other value, or malformed JSON resolves to `"repo"` (the safe default):
   ```json
   {
     "guards": {
       "rmScope": "off"
     }
   }
   ```
3. **Default** — repo (safe-by-default, outside-repo deep `rm` denied).

The config read is best-effort: a missing, empty, or malformed `.loom/config.json` falls through to **repo** (the safe default) and never causes the hook to exit non-zero. The permissive opt-out does not weaken any other guard — the catastrophic denies stay active.

**In-scope targets** (allowed under `repo` mode):

- Anything under the **repo root** (resolved from the command's `cwd`).
- Anything under the **worktree root** — resolved with the same precedence as `loom_worktree_root()`: `LOOM_WORKTREE_ROOT` env → `.loom/config.json → worktree.root` → the default `<repo>/.loom/worktrees`. This admits an external scratch volume (e.g. `worktree.root: "/Volumes/scratch/wt"`).
- The **ephemeral allowlist**: system temp roots and the Claude scratchpad.

**Ephemeral allowlist prefixes**. `normalize_abs_path()` is **lexical only** — it does **not** resolve symlinks — so on macOS each temp root is listed in **both** its symlink form and its `/private` target:

| Symlink form | `/private` target |
|--------------|-------------------|
| `/tmp/…` | `/private/tmp/…` |
| `/var/tmp/…` | `/private/var/tmp/…` |
| `/var/folders/…` (`$TMPDIR`) | `/private/var/folders/…` |

Plus the Claude scratchpad glob `*/claude-*/*/scratchpad/*`. A **bare** temp root (`/tmp`, `/private/tmp`, …) is never admitted here — bare `/tmp` is already caught by the catastrophic top-level deny, and prefix matches carry a trailing `/` so a name-prefix sibling like `/tmpfoo/x` is **not** admitted by the `/tmp/` entry.

**Examples**:

```bash
# Default (repo mode) — no config needed:
rm -rf /Users/someone/important   # DENIED (outside repo, safe default)
rm -rf /tmp/build-cache/x         # allowed (ephemeral allowlist)
rm -rf ./dist                     # allowed (under repo)

# Opt out to the old permissive behaviour for a whole repo:
#   .loom/config.json  ->  { "guards": { "rmScope": "off" } }        # or "permissive"

# One-off env opt-out — force permissive for a single command:
LOOM_RM_SCOPE=off rm -rf /Users/someone/scratch       # allowed (permissive)

# Force repo mode for one command even when the repo opts out:
LOOM_RM_SCOPE=repo rm -rf /Users/someone/important    # DENIED (outside repo)
```

### Force-Op Branch Scope Guard (`guards.forceScope` / `LOOM_FORCE_SCOPE`)

By default `guard-destructive.sh` **asks** for confirmation on every `git push
--force` / `-f` / `--force-with-lease` and `git reset --hard`, regardless of
which branch is targeted. For an autonomous/background agent that cannot answer
an interactive prompt, that stalls the agent on *routine* work — force-pushing or
hard-resetting its own single-owner working branch is a normal part of the
rebase/amend/reset workflow. The genuinely dangerous case is a force op against a
**protected/shared branch** (`main`/`master` or the repo's default branch).

`guards.forceScope` makes the ask branch-aware (symmetric to `guards.rmScope`):

| `guards.forceScope` | Behavior |
|---------------------|----------|
| `"all"` (**default**) | Ask on every force op regardless of branch — current behaviour, preserved byte-for-byte. |
| `"protected"` | Ask only when the resolved target is a **protected** branch (the repo default branch plus `main`/`master`), or the branch identity is ambiguous (detached HEAD). Force ops on the agent's own working branches pass through. Solves the autonomous-agent stall. |
| `"off"` | Never ask/deny on force ops. |

The shipped default is **`"all"`** — a zero-config install sees **no behaviour
change**. Consumers who want the autonomous-friendly behaviour opt in explicitly
(`guards.forceScope: "protected"` in `.loom/config.json`).

**Protected set & branch resolution**:
- Protected branches = the repo default branch (detected offline via
  `refs/remotes/origin/HEAD`, mirroring `loom_default_branch()`, with a
  `LOOM_DEFAULT_BRANCH` override) plus the literals `main` and `master`.
- The target branch is resolved from the push refspec — `<src>:<dst>` → `<dst>`,
  a bare ref → the ref with a leading `+` stripped, and `HEAD` / no refspec → the
  **checked-out branch**. `git reset --hard` always resolves to the checked-out
  branch. The checked-out branch is read at the command's effective cwd, honoring
  a `git -C <path>` prefix, else the hook's `cwd`.
- **Detached HEAD** (or any unresolved branch identity) is treated as ambiguous
  and **asks** — it is never silently allowed.

**Always-on hard denies are unaffected**. The unconditional force-push-to-main /
force-push-to-master denies (the `ALWAYS_BLOCK` patterns) fire **in every mode,
including `"off"`** — `forceScope` only ever downgrades the generic force-op
*ask*, it never weakens a hard deny.

The force-op guard is resolved in this order (highest precedence first):

1. **`LOOM_FORCE_SCOPE` env var** (`all`/`protected`/`off`). Overrides config.
2. **`.loom/config.json`** — `guards.forceScope`: `"protected"`/`"off"`; an
   absent key, any other value, or malformed JSON resolves to `"all"`:
   ```json
   {
     "guards": {
       "forceScope": "protected"
     }
   }
   ```
3. **Default** — `"all"` (preserve current behaviour).

The config read is best-effort: a missing, empty, or malformed `.loom/config.json`
falls through to `"all"` and never causes the hook to exit non-zero.

**Examples**:

```bash
# Default (all) — every force op asks, no config needed:
git reset --hard HEAD~1                       # ASK
git push --force origin feature/my-branch     # ASK

# Opt in to branch-aware force ops for a whole repo:
#   .loom/config.json  ->  { "guards": { "forceScope": "protected" } }
git reset --hard HEAD~1                        # allowed (own working branch)
git push --force origin feature/my-branch      # allowed (working branch)
git push --force origin main                   # DENIED (ALWAYS_BLOCK, unaffected)

# One-off env override — force branch-aware mode for a single command:
LOOM_FORCE_SCOPE=protected git push --force origin feature/x   # allowed

# Force the old always-ask behaviour even when the repo opts into protected:
LOOM_FORCE_SCOPE=all git reset --hard HEAD~1   # ASK
```

### Stash-Stack Scope Guard (`guards.stashScope` / `LOOM_GUARD_STASH_SCOPE`)

**The main checkout's stash stack is operator-owned, not scratch space.**
Preserved diagnostic state (e.g. contamination evidence intentionally
`git stash`-parked for later investigation) and in-progress operator WIP can
sit on the main checkout's stash stack indefinitely, with no marker
distinguishing "safe to pop" from "evidence, do not touch." A role subagent
doing an ad-hoc integration check (a throwaway test-merge branch, a conflict
inspection) has no way to tell the difference before running `git stash pop`.

The 2026-07-28 incident this guard exists for (#4281): a Judge, reviewing a
PR, ran a local test-merge **in the main checkout** and inadvertently
`git stash pop`'d a stash entry that had been deliberately preserved — "sweep
contamination, preserved for investigation." The pop happened to conflict, so
nothing was lost this time (the Judge ran `git reset --hard` to discard the
partial application and verified the stash stack was intact afterward) — but a
**clean** pop would have silently dropped the preserved entry with no recovery
path. See `defaults/roles/judge.md`'s "Rebase Check" section for the
prescribed alternative (merge `origin/main` into the PR branch inside an
isolated worktree, never a main-checkout test-merge).

`guard-destructive-generic.sh` asks for confirmation on `git stash pop`,
`git stash drop`, and `git stash clear` **only when the command's cwd resolves
to the main checkout** — never in a linked worktree, where a stash operation
cannot touch the main checkout's stack at all. `git stash push` / `git stash
apply` / `git stash list` (and the bare `git stash`, which defaults to `push`)
are **not** gated — none of them can remove an entry from the stack.

The main-checkout test compares `git rev-parse --show-toplevel` against
`git rev-parse --git-common-dir/..`, both resolved from the command's cwd: they
are equal only when cwd **is** the main checkout, and diverge when cwd is a
linked worktree. This is deliberately **not** a subdirectory-prefix comparison
against the main-checkout root, because Loom's own managed worktrees live
**nested inside** the main checkout's directory tree
(`<main>/.loom/worktrees/issue-N`) — a prefix test would ask inside a
builder's own worktree too, since that path is textually "under" the main
root even though it is a distinct working tree.

The guard is **on by default**. It is resolved in this order (highest precedence first):

1. **`LOOM_GUARD_STASH_SCOPE` env var** — `0`/`false`/`no` disables the guard; `1`/`true`/`yes` forces it on. Overrides the config value.
2. **`.loom/config.json`** — `guards.stashScope` (default `true` when absent). Set it to `false` to disable:
   ```json
   {
     "guards": {
       "stashScope": false
     }
   }
   ```
3. **Default** — `true` (guard on).

The config read is best-effort: a missing, empty, or malformed `.loom/config.json` falls through to guard-ON and never causes the hook to exit non-zero. Disabling this guard does not weaken any other guard.

**Known limitation.** Unlike the force-op guard's `parse_force_ops` (which
threads a `git -C <path>` argument through to resolve the real target), this
check does not parse `-C`: `git -C <main-checkout-path> stash pop` run from a
worktree cwd is **not** caught today. If this bypass shows up in practice,
extend the check to thread `-C` the same way `parse_force_ops` does.

**Examples**:

```bash
# In the main checkout — ASK (operator-owned stash stack):
git stash pop
git stash drop stash@{1}
git stash clear

# In a linked worktree (.loom/worktrees/issue-N) — allowed, no ask:
cd .loom/worktrees/issue-42 && git stash pop

# Never gated, in either location — these cannot remove a stash entry:
git stash push -m "wip"
git stash apply
git stash list

# Opt out for a whole repo:
#   .loom/config.json  ->  { "guards": { "stashScope": false } }

# One-off env opt-out for a single command:
LOOM_GUARD_STASH_SCOPE=0 git stash pop
```

### Read-Only Fast-Path Guard Toggle (`guards.readOnlyFastPath` / `LOOM_GUARD_READONLY_FASTPATH`)

`guard-destructive.sh` is a `PreToolUse`/`Bash` hook, so it fires before **every** Bash tool call. In Bash-dense sessions (remote ops, benchmark drivers) nearly every call is obviously read-only — `git status`, `ls`, `grep`, `aws … describe*`, `gh … list` — yet each one otherwise runs the full deny/ask gauntlet (~37 `grep`/`awk`/`sed` forks plus a `git rev-parse`, ~179ms measured) before falling through to `allow`.

The read-only fast path (issue #3687) short-circuits that overwhelmingly-common case to a **silent** `allow` (exit 0, zero stdout/stderr, no logging) using a single bash-builtin structural test — zero forks — plus, only when that test passes, one lazy `jq` config read. It runs first, before the `git rev-parse` repo-root resolution and before any deny/ask array.

The fast path is **on by default**. It is resolved in this order (highest precedence first):

1. **`LOOM_GUARD_READONLY_FASTPATH` env var** — `0`/`false`/`no` disables the fast path (every command takes the full deny/ask path, byte-for-byte as before); `1`/`true`/`yes` forces it on. Overrides the config value.
2. **`.loom/config.json`** — `guards.readOnlyFastPath` (default `true` when absent). Set it to `false` to disable:
   ```json
   {
     "guards": {
       "readOnlyFastPath": false
     }
   }
   ```
3. **Default** — `true` (fast path active).

**Security — the fast path is a guard bypass by construction**, so admission is purely **structural** and conservative, never content-sensitive. A command is fast-pathed only when **all** of these hold (otherwise it falls through to the full path unchanged):

- The raw command contains **none** of `;` `&` `|` `<` `>` backtick `$(` or a newline — this excludes all chaining, piping, redirection, and command substitution. So `git status && git push --force origin main`, `git status; rm -rf /`, and `git status $(rm -rf /)` all take the full path and are still denied.
- The **first token** is an exact allowlist match (never a wrapper — `bash -c`, `sh -c`, `eval`, `xargs`, `env … git status`, `sudo git status` are all excluded because their first token isn't allowlisted):

| First token | Admitted form |
|-------------|---------------|
| `git` | `git status` / `git log` / `git diff` / `git show` — **bare** subcommand only (so `git -C /path status` is not admitted) |
| `ls`, `grep`, `rg` | any arguments |
| `jq`, `wc`, `head`, `tail` | any arguments (pure read-only text/JSON filters — none has an in-place-mutation flag) |
| `test`, `[`, `[[` | any arguments (boolean file/string test builtins — no mutation surface) |
| `find` | any arguments **except** those containing a dangerous action-primary — `-delete`, `-exec`, `-execdir`, `-ok`, `-okdir`, `-fls`, `-fprint`, `-fprint0`, `-fprintf` — which structurally disqualify the command and route it to the full path |
| `gh` | `gh <noun> view` / `gh <noun> list` (never `delete`/`close`/`archive`/…) |
| `aws` | `aws <service> describe*` / `get*` / `list*`, and `aws s3 ls` |

**`cat` and `ssh` are deliberately EXCLUDED** from the built-in list, even though they are read-only in spirit:

- `cat` has a narrow existing `ASK` carve-out (`cat …/.ssh/…`, `cat …/.aws/credentials`); a blanket `cat` fast-path would silently skip it.
- `ssh <host> '<cmd>'` wraps an **opaque remote command string** that the raw `ALWAYS_BLOCK` catastrophic scan still covers today; fast-pathing any `ssh …` would drop that coverage.

**Optional extend-only escape hatch** — `guards.readOnlyFastPathExtra` is an array of **literal first-word commands** to add to the built-in list without hand-editing the Loom-managed `.claude/settings.json` (which the installer may overwrite). This directly answers "give operators a supported way to scope the matcher":

```json
{
  "guards": {
    "readOnlyFastPath": true,
    "readOnlyFastPathExtra": ["psql"]
  }
}
```

> **Note**: `jq` and `wc` used to be the canonical example entries here, but as of #3772 they are part of the **built-in default** allowlist above — adding them via `readOnlyFastPathExtra` is now redundant. Use this escape hatch only for a genuinely-custom bare read-only command word (e.g. a site-specific query tool).

> **Warning**: each word added here is a **guard bypass for that command word in full generality** (all arguments). Only add bare, argument-independent read-only utilities — never your own scripts or anything that could wrap a mutating call. Entries are matched as the literal first token only; no subcommand/verb parsing is applied to custom entries.

The config read is best-effort and lazy: it happens only after a command has already passed the structural test, and any missing/empty/malformed `.loom/config.json` falls through to fast-path-ON. Disabling the fast path never weakens any deny/ask rule — it only makes the guard do its full work on every command again.

**Examples**:

```bash
# Default: read-only commands are near-free and silent
git status                     # fast-pathed (silent allow)
aws ec2 describe-instances     # fast-pathed
gh pr list                     # fast-pathed
git status && git push --force origin main   # NOT fast-pathed → full path → DENIED

# Disable the fast path for one command (restore full-path checking)
LOOM_GUARD_READONLY_FASTPATH=0 git status

# Persist the opt-out for a whole repo
#   .loom/config.json  ->  { "guards": { "readOnlyFastPath": false } }

# Extend the allowlist with a bare read-only utility (jq/wc/head/tail/find/test
# are already built-in as of #3772 — use this for a genuinely-custom word):
#   .loom/config.json  ->  { "guards": { "readOnlyFastPathExtra": ["psql"] } }
```

### Decision Telemetry Log (`guards.decisionLog` / `LOOM_GUARD_DECISION_LOG`)

`guard-destructive.sh` **and** `guard-loom-workflow.sh` can record every **deny** and **ask** decision to a JSONL decision log (issue #3771, extended to the Loom-workflow guard in #3898), separate from `hook-errors.log`, so guard-hook friction becomes **measurable** — which patterns fire, how often, and whether a precision fix (#3755/#3756/#3757/#3898) actually cut the false-positive rate. Without it, "we keep hitting the hooks" is unquantifiable. Both guards share the **same log file, schema, and stable rule tags**, so a single reader aggregates fires across both (`guard-loom-workflow.sh`'s two denies carry the tags `loom:gh-pr-merge-redirect` and `loom:pip-install-editable-worktree`).

The log is **off by default** — enabling it writes a new persistent, cross-session artifact, so like the other opt-in data-collection features (transcript archival #3726, the model-cost experiment #3725) a zero-config install sees no new file and no behaviour change. It is resolved in this order (highest precedence first):

1. **`LOOM_GUARD_DECISION_LOG` env var** — `1`/`true`/`yes`/`on` enables; `0`/`false`/`no`/`off` disables. Overrides the config value.
2. **`.loom/config.json`** — `guards.decisionLog` (default `false` when absent). Set it to `true` to enable:
   ```json
   {
     "guards": {
       "decisionLog": true
     }
   }
   ```
3. **Default** — `false` (no decision log written).

When enabled, each deny/ask appends **one JSON object per line** to `.loom/logs/guard-decisions.log` (`SCRIPT_DIR`-relative, mirroring `hook-errors.log`; override the path with `LOOM_GUARD_DECISION_LOG_FILE`). **Stable schema** (the contract downstream reader tooling in #3772 depends on — field names are load-bearing):

```json
{"ts":"2026-07-22T23:17:13Z","decision":"deny","pattern":"sql-ddl","tier":"catastrophic","command":"<redacted>"}
```

| Field | Meaning |
|-------|---------|
| `ts` | UTC timestamp (`date -u '+%Y-%m-%dT%H:%M:%SZ'`, same as `hook-errors.log`) |
| `decision` | `deny` or `ask` |
| `pattern` | a short, stable rule tag (e.g. `sql-ddl`, `rm-protected-path`, `force-op:protected`, `cloud-cli:<pattern>`) — **not** the full free-text reason |
| `tier` | `catastrophic` for a deny, `ask` for an ask |
| `command` | the command string, **redacted** via `strip_literal_text()` so no raw `--body`/`-m`/`--title`/`--notes`/`--comment` secret value is persisted |

**`allow` decisions are never logged** — the #3687 read-only fast path's zero-overhead silent-allow stays silent, and allow-logging would swamp the log with the ~99% common case. Logging is **best-effort / fail-open**: the toggle is resolved lazily (only once a deny/ask is about to fire, so it never touches the fast path's hot path), and a log-write failure (permission denied, disk full, missing dir) never changes the deny/ask decision and never causes the hook to exit non-zero. `.loom/logs/` is gitignored.

Summarize fires by rule (a fuller reader/aggregation CLI is #3772's scope):

```bash
jq -r '.pattern' .loom/logs/guard-decisions.log | sort | uniq -c | sort -rn
```

**Examples**:

```bash
# Enable for a single command (e.g. to capture one session's fires)
LOOM_GUARD_DECISION_LOG=1 claude -p "/loom:builder" --dangerously-skip-permissions

# Persist for a whole repo
#   .loom/config.json  ->  { "guards": { "decisionLog": true } }

# Force off for one command even when the repo opts in
LOOM_GUARD_DECISION_LOG=0 <command>
```

### Autonomous Guard Defaults + Standing Per-Trigger Review Policy (#3898)

A headless sweep runs under `--dangerously-skip-permissions`, where the guard `PreToolUse` hooks **fire** but an **ASK decision has no human to answer it — so it blocks**, functionally a silent deny. Every guard ASK therefore stalls autonomous work. To converge the guard toward *dangerous-only* without ever weakening a genuine safety rule, autonomous mode combines two guard defaults with a standing feedback loop.

**Autonomous guard defaults** — set by `./.loom/scripts/cli/loom-daemon-start.sh` (each env-overridable; an already-exported value always wins), inherited by every dispatched `/loom:sweep` child:

| Env var | Autonomous default | Why |
|---------|--------------------|-----|
| `LOOM_GUARD_DECISION_LOG` | `1` (on) | Capture every DENY/ASK so the review loop below has data. |
| `LOOM_FORCE_SCOPE` | `protected` | Let an agent force-push / hard-reset its **own** working branch without a stall; force-push to `main`/`master`/default stays a **hard DENY** via `ALWAYS_BLOCK_PATTERNS`. |

`guards.forceScope: "protected"` is the **Loom-recommended default for autonomous repos** — set it in committed `.loom/config.json` for repos that run the daemon, or rely on the start-script env default. The shipped hook default remains `"all"` (byte-for-byte unchanged for non-autonomous installs).

**Standing per-trigger review policy** — a periodic support role (the **Auditor**, see `.loom/roles/auditor.md`) tails `.loom/logs/guard-decisions.log`, dedups by `pattern`, and files **one issue per distinct trigger** observed in autonomous runs, proposing to either (a) **allowlist / refine** the guard for the in-scope op or (b) **confirm it stays flagged**. Over time this converges the guard to dangerous-only. The dedup + summarize one-liner:

```bash
jq -r '.pattern' .loom/logs/guard-decisions.log | sort | uniq -c | sort -rn
```

New issues from this policy enter through normal intake (`loom:triage` → Curator → Champion/human approval); the review role never self-applies `loom:issue`.

**First refinement pass (#3898):**
- `guards.forceScope:"protected"` recommended for autonomous repos (above).
- The catastrophic scan no longer false-positives on **documentation text** — a dangerous command merely *mentioned* inside a multi-line `--body`/`-m`/`--title`/`--notes`/`--comment` value (e.g. `gh issue create --body "…"`) is redacted as a single span and does **not** deny, while a genuinely dangerous command, or a command-substitution `$(…)` smuggled inside such a value, still DENIES.
- `git checkout .` / `git restore .` / `git clean -fd` **stay ASK** (evaluated, kept flagged): they irreversibly discard uncommitted/untracked work, so the standing policy files a per-trigger issue rather than blanket-allowlisting them. A repo that wants them to pass headless can add the command word to an allowlist per its own risk decision.

**Second refinement pass (#4216):** `aws iam delete-*` and `az`/`gcloud … delete` were retiered from the catastrophic deny list to the **ungated ask tier**. A hard block on credential/resource deletion was over-broad — deleting an IAM key is often the *security-positive* step — and left only the undocumented script-file bypass as recourse. The deny→ask move is safe for autonomous mode by construction: a headless sweep's unanswered ASK still blocks (per the paragraph above), so nothing that was denied headless now silently runs; only a supervised interactive operator gains a confirm prompt. The patterns stay **ungated** (not folded into `guards.cloudCli`) so a repo disabling the cloud ASK category for EC2-churn convenience cannot silently bypass IAM deletion.

### When a Legitimate Operation Is Pattern-Blocked

When a guard blocks (or asks about) an operation you believe is legitimate, the sanctioned recourse depends on the session:

1. **Interactive session** — the **ask-tier prompt is the sanctioned path.** For a pattern in the ungated ask tier (`aws iam delete-*`, `az`/`gcloud … delete`, `gh release delete`, `git clean -fd`, …) the guard emits an ASK; confirm it in the session and the operation proceeds, with the decision recorded in the decision log (§ above). A pattern that is a **hard deny** (`rm -rf /`, force-push to `main`, `aws s3 rb`, `aws cloudformation delete-stack`, …) is not meant to be overridden ad hoc — if it is a genuine, recurring false positive, fix it with a pattern/tier-change PR (this doc + the guard + its tests), exactly as #4216 did for `aws iam delete`.
2. **Headless / autonomous session** — by design, an ASK with no human to answer **blocks** (see above), and a hard deny blocks outright. The sanctioned path is to **re-run the specific operation in a supervised interactive session** so a human can answer the ASK. Do **not** try to make the daemon answer prompts; the block is the intended safety behavior for unattended runs.
3. **The script-file workaround is UNSANCTIONED.** Writing the blocked command into a file and running `bash that-file` (or any equivalent that hides the command string from the `PreToolUse` scan) is a **generic guard bypass, not a policy** — it defeats *every* pattern, not just a false positive, and leaves no ask/deny record. (Note: #4178 / PR #4210 confines *where* the Bash tool may write, but does not close executing an already-written script inside a builder's own worktree — so this remains a real bypass, not a closed hole.) The honest fix for a recurring false positive is a pattern/tier-change PR like #4216, reviewed like any other change.

### Protecting Read-Only Directories

Many projects have directories that should never be modified by agents (vendor code, generated files, external SDKs, process design kits). Loom provides a template hook for this.

**Setup**:

1. Copy the template to your hooks directory:
   ```bash
   cp defaults/hooks/guard-readonly-dirs.sh.template .loom/hooks/guard-readonly-dirs.sh
   chmod +x .loom/hooks/guard-readonly-dirs.sh
   ```

2. Edit `.loom/hooks/guard-readonly-dirs.sh` and add your protected directories:
   ```bash
   PROTECTED_DIRS=(
       "vendor/"
       "third_party/"
       "generated/"
   )
   ```

3. Register the hook in `.claude/settings.json`:
   ```json
   {
     "hooks": {
       "PreToolUse": [
         {
           "matcher": "Edit|Write",
           "hooks": [{ "type": "command", "command": ".loom/hooks/guard-readonly-dirs.sh" }]
         }
       ]
     }
   }
   ```

**How it works**: The hook intercepts Edit and Write tool calls, resolves the target file path to an absolute path, and checks whether it falls within any of the listed directories (relative to the repository root). If it does, the edit is blocked with a clear error message. The hook follows the same error-handling patterns as `guard-destructive.sh` (ERR trap, jq fallback, never exits non-zero).

**Interaction with other hooks**: This hook uses the `Edit|Write` matcher, while `guard-destructive.sh` uses the `Bash` matcher, so they do not conflict. If `guard-worktree-paths.sh` is also active (same `Edit|Write` matcher), both hooks run in sequence -- if either denies, the action is blocked.

**Template location**: `defaults/hooks/guard-readonly-dirs.sh.template`
