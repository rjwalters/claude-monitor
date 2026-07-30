# Guardrail Parity: Codex

This is the **required guardrail-parity document** for the Codex runtime adapter
(`defaults/scripts/spawn-codex.sh`), per contract point 6 of
[`runtime-adapters.md`](runtime-adapters.md). No runtime is admitted to Loom
without one. It maps **Loom guard *intent* → Codex enforcement mechanism** and
then names, explicitly, every protection Loom has that a Codex worker does
**not** get.

Read this before dispatching a Codex worker at anything you care about.

> **Provenance.** The Codex adapter is a port of the Codex support built in the
> [gpeyton/loom](https://github.com/gpeyton/loom) fork by Graham Peyton (fork
> PRs #15/#16/#20/#40, including its `GUARDRAIL-PARITY.md`, the template for
> this document). Every claim below was **re-verified against codex-cli
> 0.146.0** on 2026-07-29 (epic #4167 Phase 2, issue #4468) and several of the
> fork's statements no longer hold on that version — those are called out
> inline. Do not carry a claim from the fork's doc into this one without
> re-checking the CLI.

> **Path convention.** This file lives at
> `defaults/docs/guardrail-parity-codex.md` in the Loom source repo and cites
> `defaults/` paths. A consumer install maps `defaults/docs/` → `.loom/docs/`,
> so the installed copy is `.loom/docs/guardrail-parity-codex.md`.

## Tier status

**Codex is tier-2: CI-gated, no operator dogfooding.** It passes a mocked spawn
+ classifier CI leg; it is not run against production workloads. Promotion to
tier-1 requires someone committing to tier-1 ownership of this adapter, this
document, and that CI leg — see the contract's tier policy. Nothing in this
document should be read as "Codex is safe to point at your repos".

## The enforcement mechanisms Codex actually has (0.146.0)

| Mechanism | What it controls | How the adapter drives it |
|---|---|---|
| `-s` / `--sandbox <mode>` | Filesystem + network confinement for model-run shell commands. Modes: `read-only`, `workspace-write`, `danger-full-access`. | The adapter's central knob — see the mapping table below. |
| `[sandbox_workspace_write] network_access` | Outbound network from inside a `workspace-write` sandbox. **Off by default.** | `LOOM_CODEX_NETWORK=1` → `-c sandbox_workspace_write.network_access=true`. Read only under `workspace-write`; inert otherwise. |
| `sandbox_permissions` / `writable_roots` / `--add-dir` | Widen a `workspace-write` sandbox to extra readable/writable roots. | **Not driven by the adapter.** Passes through if an operator supplies it. |
| `--skip-git-repo-check` | Waives Codex's refusal to run outside a git work tree. | Injected **only** when the cwd is genuinely not inside a work tree (see "Trusted-directory check" below). |
| `$CODEX_HOME/hooks.json` (`pre_tool_use`, `permission_request`, `post_tool_use`, `user_prompt_submit`, `session_start`, `session_end`, `pre_compact`, `post_compact`, `subagent_start`, `subagent_stop`) | Per-tool-call and per-prompt interception — the direct analogue of Claude Code's hook taxonomy. | **Not wired by Loom in this phase.** This is the single most consequential residual gap; see gap 1. |
| `approval_policy` / `-a` | When Codex pauses to ask a human. | **Irrelevant to Loom.** `codex exec` is non-interactive and exposes no `-a` at all; there is no human to answer, so approvals gate nothing. The sandbox is the only load-bearing guard. |
| `AGENTS.md` | Repository instructions, read natively by Codex via ancestor traversal. | Advisory context, not a boundary. Loom's `AGENTS.md` codegen is a separate issue (contract point 5). |

### Corrections to the fork's parity doc, verified on 0.146.0

1. **`--full-auto` does not exist on `codex exec`.** The fork maps its safe mode
   to `--full-auto`; that flag is absent from `codex exec --help` on 0.146.0.
   `-s workspace-write` is the replacement, and it is what this adapter emits.
2. **`-a` / `--ask-for-approval` is top-level only**, not an `exec` flag. Any
   parity claim that rests on `approval_policy = "on-request"` is inert for
   Loom's headless dispatch.
3. **Codex has a hook system now.** The fork states Codex has no hooks "as a
   concept". On 0.146.0 it has a `hooks.json` engine with a `pre_tool_use`
   event, a persisted hook-trust model, and a
   `--dangerously-bypass-hook-trust` escape hatch. The gap is therefore
   *unwired*, not *impossible* — a materially better position than the fork
   documented, and a concrete follow-up rather than an architectural dead end.
4. **A sandbox denial does not fail the run.** Verified with `-s read-only`: a
   blocked `touch` returns `Operation not permitted` to the model and the
   `codex exec` process still exits **0**. Denials are in-session tool
   failures, so they never reach error classification (see
   `defaults/scripts/lib/classify-error.sh`'s `codex` table for why no
   "sandbox denial" pattern is encoded there).

## Loom guard intent → Codex mechanism

Loom's guards are Claude Code `PreToolUse` / `Stop` hooks wired in
`.claude/settings.json` to scripts under `.loom/hooks/`. **None of them fire for
a Codex worker** — they are Claude Code hooks, and Loom does not currently
install anything into Codex's own `hooks.json`. The column below therefore
records what Codex's *sandbox* incidentally covers, not what runs.

| Loom guard (`defaults/hooks/`) | Claude matcher | Intent | Codex coverage | How / why |
|---|---|---|---|---|
| `guard-destructive.sh` → `guard-destructive-generic.sh` | `Bash` | Deny catastrophic Bash (`rm -rf /`, force-push to `main`, `gh repo delete`, fork bombs, `curl … \| sh`, cloud/SQL destruction); ask on borderline ops; scope `rm` to the repo; Bash-tool write-confinement (`>`, `tee`, `sed -i`, `cp`/`mv`, #4178) | **partial** | `read-only` blocks every write, so under the adapter's default the destructive-write half is fully covered — more strictly than the guard itself. `workspace-write` blocks writes and `rm` outside the workspace root, and (with network off) blocks `curl \| sh` and remote cloud destruction by making the network unreachable. **Not covered:** command-pattern semantics. Codex cannot recognize `DROP DATABASE`, `DELETE` without `WHERE`, `git push --force` to `main`, or a fork bomb *as such* — anything reachable without leaving the workspace or the network proceeds. With `LOOM_CODEX_NETWORK=1` (which a Builder needs to push) the network-derived coverage evaporates and a force-push to `main` becomes reachable with nothing to stop it. |
| `guard-worktree-paths.sh` | `Edit\|Write` | Confine Edit/Write to the builder's own `issue-N` worktree; deny escapes into the main checkout (#2441, #4007) | **partial** | `workspace-write` confines writes to the **workspace root** — a strictly coarser boundary. It blocks escaping the repo, but **not** the per-worktree boundary: a Codex builder can write into a sibling `issue-M` worktree, or into the main checkout, because all of those live under the same root. This is the exact class of escape #4178 documented. Mitigation: one Codex worker per workspace root, or narrow `writable_roots` by hand. |
| `guard-loom-workflow.sh` | `Bash` | `gh pr merge` → `merge-pr.sh` redirect; `pip install -e` worktree block (#2495 + #4079 — still live after #4557 retired Loom's own Python package: it protects orchestrated *Python* repos and stops new frozen `~/.local/bin` console scripts shadowing the `loom-daemon` binary); `loom-daemon workspace` registry-mutation ask (#4326) | **none** | Pure command-pattern convention with no OS analogue. A Codex worker learns these only from `AGENTS.md` / role prompts — advisory, never enforced. |
| `guard-background-subagents.sh` | `Stop` | Block one stop when the transcript shows dispatched-but-unresolved `Task` subagents, so ending a headless turn does not kill live background work (#4257) | **none** | Depends on Claude Code's `Stop` event and transcript shape. Codex has `session_end` and `subagent_stop` events that could host an equivalent, but nothing is wired (gap 1). Note the underlying hazard is *also* absent today: Loom does not dispatch Codex subagents at all. |
| `guard-readonly-dirs.sh.template` | `Edit\|Write` | Optional per-project read-only path protection | **partial** | Expressible as narrowed `writable_roots` under `workspace-write`, but the adapter does not generate it — an operator must configure it manually. |
| `skill-router.sh` | `UserPromptSubmit` | Inject an agent routing table / `AGENT_ROUTE` suggestion per prompt (opt-in) | **none** | Context injection, not a boundary. Codex has a `user_prompt_submit` hook event that could host it; unwired (gap 1). Static equivalent: `AGENTS.md`. |
| `methodology-inject.sh` | *(present, not wired here)* | Inject universal/role/topic context from `.loom/context/` | **none** | Same as above: not a boundary, and a `user_prompt_submit` equivalent exists but is unwired. |
| `post-worktree.sh` | *(invoked by `worktree.sh`)* | Copy the `loom-daemon` binary into a new worktree | **covered** | Runtime-neutral — `worktree.sh` runs it regardless of which runtime drives the work. Not a Claude hook. |

## Sandbox-mode mapping (what the adapter emits)

Precedence, highest first:

| # | Signal | Effective sandbox |
|---|---|---|
| 1 | An explicit `-s` / `--sandbox` (or `--dangerously-bypass-approvals-and-sandbox`) in the passthrough args | as given |
| 2 | `LOOM_CODEX_SANDBOX=read-only\|workspace-write\|danger-full-access` | as given (invalid value → exit 78) |
| 3 | Loom's runner-neutral `--dangerously-skip-permissions` convention | `workspace-write` |
| 4 | *(default)* | `read-only` |

### Why the default is `read-only`, and why skip-permissions is **not** full access

The fork maps Loom's skip-permissions convention to
`--dangerously-bypass-approvals-and-sandbox` — no sandbox at all — on the
argument that Loom's Claude workers already run unattended with full tool
access, so Codex should match: *"parity, not a new exposure."*

**Upstream declines that mapping**, for one reason: the premise is not parity.
Claude's unattended posture is backstopped by `PreToolUse` guards that fire on
every Bash/Edit/Write call *even under* `--dangerously-skip-permissions`. Those
guards do not exist for a Codex worker. Handing Codex the same flag therefore
produces a **strictly weaker** trust boundary than the Claude path it is
imitating — an agent with Claude's authority and none of Claude's backstops.

`workspace-write` is the closest honest analogue of what the Claude guards
actually enforce (`guard-worktree-paths.sh`'s write confinement, plus
`guard-destructive-generic.sh`'s out-of-repo `rm`/write scoping). It is
deliberately imperfect — see gap 2 — but it is a real boundary rather than an
assumed one.

`read-only` is the *default* because a tier-2 runtime with no wired guards
should not be able to write anything unless someone said so. It is also the
right mode for the read-only Loom roles (Judge, Curator, Guide, Champion
evaluation), which is where a Codex canary should start.

Operators who want the fork's posture opt in explicitly:

```bash
LOOM_CODEX_SANDBOX=danger-full-access .loom/scripts/spawn-codex.sh -p "…"
```

The adapter emits `-s danger-full-access` rather than
`--dangerously-bypass-approvals-and-sandbox` for that case: same sandbox
posture, without additionally waiving Codex's hook-trust prompt (which is a
separate protection, and one Loom will want intact once gap 1 is closed).

### The network coupling (read this before dispatching a Builder)

`workspace-write` blocks outbound network by default. A Loom **Builder** must
`git push` and call `gh` — so a Builder-equivalent Codex worker needs
`LOOM_CODEX_NETWORK=1`, which sets
`-c sandbox_workspace_write.network_access=true`.

That single flag removes most of what the sandbox was contributing to the
`guard-destructive.sh` row above: with the network reachable, force-push to
`main`, `gh repo delete`, cloud-CLI destruction, and `curl … | sh` all become
possible again, and Codex has no pattern matcher to stop any of them. **A
networked `workspace-write` Codex Builder is meaningfully less protected than a
Claude Builder.** Keep Codex on read-only roles until gap 1 is closed.

### Trusted-directory check

`codex exec` refuses to start outside a git work tree ("Not inside a trusted
directory and `--skip-git-repo-check` was not specified.", exit 1). That is a
real guardrail, so the adapter injects `--skip-git-repo-check` **only** when
`git rev-parse --is-inside-work-tree` says the cwd is not inside one — never
unconditionally. Worktree dispatch (`.loom/worktrees/issue-N`) is inside a work
tree and keeps the check enabled. Scratch-dir dispatch gets the waiver plus a
warning line. The refusal itself classifies as `FATAL` (not `RECOVERABLE`), so a
mis-set cwd fails fast instead of retrying forever.

## Residual gaps

Known, documented, and accepted for tier-2. None is silent.

1. **Loom's guard hooks do not run at all.** This is the headline gap. Every
   `PreToolUse` protection in `.loom/hooks/` is a Claude Code hook; a Codex
   worker executes with none of them. Codex 0.146.0 *does* expose a
   `$CODEX_HOME/hooks.json` engine with `pre_tool_use` / `user_prompt_submit` /
   `post_tool_use` events and a hook-trust model, so this is a **wiring gap,
   not an architectural one** — but it is unwired today, and no Loom guard
   intent is mechanically enforced for Codex beyond what the sandbox happens to
   cover. Closing it (translating `guard-destructive` / `guard-worktree-paths`
   into Codex `pre_tool_use` handlers, and deciding how hook trust is
   provisioned) is follow-up work, not part of this phase.
2. **No per-worktree write isolation.** `workspace-write` confines to the
   workspace root, not to one `issue-N` worktree. Parallel Codex builders under
   one root are not isolated from each other or from the main checkout — the
   #4178 escape class. Mitigation: one Codex worker per workspace root, or hand-
   narrowed `writable_roots`.
3. **No command-pattern blocking.** Codex cannot recognize a dangerous command
   as dangerous. `DROP DATABASE`, `DELETE` without `WHERE`, `git push --force
   origin main`, `systemctl stop`, a fork bomb — if it is reachable without
   leaving the sandbox, it runs.
4. **Loom's workflow nudges are advisory only.** The `gh pr merge` →
   `merge-pr.sh` redirect, the `pip install -e` worktree block, and the
   `loom-daemon workspace` ask are conventions Codex learns from `AGENTS.md` at
   best. Nothing enforces them. **A Codex worker can merge a PR with
   `gh pr merge`, bypassing `merge-pr.sh`'s worktree-cleanup and
   merge-ordering handling.**
5. **Label-mutation commands are ungated for every runtime.** Nothing in Loom —
   Claude or Codex — gates `gh issue edit --add-label` / `--remove-label`. A
   worker can move an issue anywhere in the state machine. This is *not* a
   Codex-specific regression, but it is worth stating in a trust-boundary
   document: Codex inherits it with no compensating guard, so a Codex worker
   that mishandles labels leaves no enforcement layer between it and the
   coordination state.
6. **No per-prompt context injection.** `skill-router` / `methodology-inject`
   have no wired Codex equivalent (a `user_prompt_submit` event exists —
   gap 1). Not a safety boundary; the static substitute is `AGENTS.md`.
7. **Approvals gate nothing.** `codex exec` is non-interactive and exposes no
   approval flag. Any parity argument resting on `approval_policy` is void for
   Loom dispatch. The sandbox is the only enforced guard.
8. **Cost/usage fidelity is aggregate, not per-turn.** The adapter reports the
   `tokens used` total and resolves the session JSONL path
   (`$CODEX_HOME/sessions/<Y>/<M>/<D>/rollout-<ts>-<session-id>.jsonl`), but
   nothing parses that transcript into per-message usage the way the Claude
   archiver does. Not a safety gap; a contract-point-4 fidelity gap.
9. **Native Codex agents are not a supported backend.** Codex exposes
   in-session collaboration primitives (`spawn_agent`, `wait_agent`,
   `interrupt_agent`, …). Per the fork's finding (fork PR #59), these are
   **prohibited** for Loom lifecycle dispatch: they are not a Loom
   orchestration backend, they bypass the label state machine and the worktree
   model entirely, and a supervisor holding them has been observed to kill live
   children and take over their work. This is enforced by documentation only —
   Codex has no policy hook that can block a session from calling them. Loom
   dispatch is one process per role via `spawn-worker.sh`, never native agents.

## Admission checklist (contract point 5/6)

- [x] Guard-intent → mechanism map (above)
- [x] Explicit residual-gap section (above)
- [x] Sandbox-mode mapping with stated precedence and rationale
- [x] Fork's native-agent prohibition recorded (gap 9)
- [x] Error-classification table for the runtime
      (`defaults/scripts/lib/classify-error.sh`, `codex` provider)
- [x] Mocked CI smoke leg (`defaults/scripts/tests/test-spawn-codex.sh`)
- [ ] Loom guard intent mechanically enforced under Codex — **open** (gap 1);
      not required for tier-2, required for tier-1

## CODEX_HOME profile layout, refresh, and security posture

The adapter selects a Codex account by pointing `CODEX_HOME` at a profile
directory. This section is the auth-surface documentation absorbed from the
companion provisioning issue #4469 so it has exactly one owner.

### Layout

```text
~/.loom/codex-profiles/            # profile root (LOOM_CODEX_PROFILE_ROOT)
└── <account>/                     # one CODEX_HOME per account, mode 0700
    ├── auth.json                  # OAuth/refresh-token bundle, mode 0600
    ├── sessions/<Y>/<M>/<D>/…      # per-session rollout JSONL transcripts
    └── …                          # Codex's own state (caches, logs, skills)
```

Provision a profile with `CODEX_HOME=~/.loom/codex-profiles/<account> codex
login`. Select it at spawn time by any of:

| Precedence | Env var | Meaning |
|---|---|---|
| 1 | `LOOM_CODEX_HOME` | Absolute profile directory |
| 2 | `CODEX_HOME` | Honored verbatim if pre-set |
| 3 | `LOOM_CODEX_PROFILE` | Bare account name under `LOOM_CODEX_PROFILE_ROOT` (default `~/.loom/codex-profiles`) |
| 4 | *(none)* | Codex's ambient `~/.codex` login state |

### Refresh

`auth.json` holds a refresh-token bundle; Codex refreshes the access token
itself and rewrites `auth.json` in place. Consequences:

- The profile directory must be **writable** by the spawned worker, not just
  readable.
- A profile is an **authoritative copy, not a cache**. `~/.codex/auth.json` and
  a `~/.loom/codex-profiles/<account>/auth.json` copied from it diverge the
  moment either refreshes. Copying a live profile produces two bundles racing
  to rotate the same credential; re-run `codex login` per profile instead.
- Refresh failure is a real runtime error mode, and it is what the `codex`
  classifier table's `TOKEN_EXPIRED` patterns are matching ("refresh token has
  expired", "Failed to refresh token", "Not signed in. Please run 'codex
  login'", `401 Unauthorized`).

### Security posture

- Profile dirs `0700`, `auth.json` `0600`. A profile is a live credential.
- The adapter **assigns** the directory to `CODEX_HOME` — it never copies
  `auth.json`. Nothing under `.loom/` ever holds a credential copy.
- Logging discipline: the adapter logs the profile **directory name** only
  (`spawn-codex: using Codex profile 'alice'`). Never the path's contents, never
  a byte of `auth.json`. Preserve this in any change to the adapter.
- An **explicitly requested** profile with no usable `auth.json` exits **78**
  (`EX_CONFIG`) rather than silently degrading to a different account — a silent
  fallback would attribute work and cost to the wrong account. Ambient auth
  (tier 4) is not a request and never fails here; Codex reports its own auth
  error, which classifies as `TOKEN_EXPIRED`.
- **No token-pool integration in this phase.** There is no rotation, no
  `.bad_tokens` marking, no provider-aware selection. One operator-provisioned
  profile per dispatch. Provider-aware pooling is epic #4167 Phase 4.

## References

- [`runtime-adapters.md`](runtime-adapters.md) — the seven-point contract and tier policy
- [ADR-0012](../../docs/adr/0012-runtime-adapter-contract.md) — runtime adapter contract
- [`guard-hooks.md`](guard-hooks.md) — the Loom guard catalog this maps against
- `defaults/scripts/spawn-codex.sh` — the adapter
- `defaults/scripts/lib/classify-error.sh` — the `codex` provider table
- Codex config reference: <https://developers.openai.com/codex/config-reference>
- Codex sandboxing concepts: <https://developers.openai.com/codex/concepts/sandboxing>
- Fork: <https://github.com/gpeyton/loom> — `defaults/.codex/GUARDRAIL-PARITY.md`
- Epic #4167 · Phase 2 issue #4468 · companion auth issue #4469 · canary #4470
