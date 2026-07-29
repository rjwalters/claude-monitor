# Runtime Adapter Contract

Loom's worker runtime is the CLI agent tool that actually executes a role
prompt — reads the instructions, drives the tools, edits the code, and exits.
Historically that runtime was hardwired to Claude Code at every layer. This
document is the **normative contract** a new runtime adapter implements against
so that Loom can drive Claude Code, OpenAI Codex CLI, Amp, oh-my-pi (omp), and
future tools through **one** interface instead of a growing pile of per-runtime
special cases.

It is the reference for the multi-runtime effort tracked by epic **#4167**
(first-class multi-runtime worker support) and the fork-harvest triage in
**#4165**. The collaboration model is upstream PRs from the gpeyton/loom fork
(see the [fork mapping table](#fork-mapping-table)), not one-way cherry-picks.

> **Path convention.** This doc lives at `defaults/docs/runtime-adapters.md` in
> the Loom source repo and cites `defaults/` paths throughout. A consumer
> install maps `defaults/docs/` → `.loom/docs/` (NOT `defaults/.loom/docs/`), so
> the installed copy is `.loom/docs/runtime-adapters.md`. When you follow a code
> reference below, read the `defaults/` copy in the Loom source tree — the
> installed `.loom/docs/*.md` are per-file symlinks whose line anchors do not
> resolve via `git show`.

## Tier policy (read this first)

The contract exists to *generalize* Loom, not to demote Claude Code.

- **Claude Code is adapter #1, the default, and tier-1.** Every existing install
  keeps running Claude Code with **zero regression**. When no runtime is
  selected, Loom dispatches Claude Code exactly as it does today.
- **Non-Claude runtimes are tier-2 by default: CI-gated, no operator
  dogfooding.** A tier-2 adapter must pass its CI leg (spawn smoke test, error
  classification, guardrail-parity doc) but is not run against production
  workloads by the operator. It is admitted as "works in CI", not "trusted on
  the operator's own repos".
- **A runtime is promoted to tier-1 only when someone commits to tier-1
  ownership** — ongoing maintenance of its adapter, its parity doc, and its CI
  leg. Tier is a *maintainership* statement, not a capability statement: a
  perfectly capable runtime stays tier-2 until an owner signs up.

These are operator policy statements recorded on #4167; the contract encodes
them but does not decide them.

## The seven contract points

Every runtime adapter implements the same seven-point contract. Each point below
is grounded in the concrete Claude Code implementation that serves as the
reference shape — a new `spawn-<runtime>.sh` / adapter must satisfy the same
interface, not necessarily the same internals.

### 1. Spawn

**Contract:** headless prompt execution → exit code + transcript path. Given a
prompt and a set of passthrough CLI args, the adapter launches the runtime in
non-interactive ("headless") mode, lets it run to completion, and reports the
process exit code. The exit code is the primary success/failure signal (see
[error classification](#3-error-classification)); the transcript is the durable
per-session record of what the runtime did and what it cost.

**Reference implementation:** `defaults/scripts/spawn-claude.sh`. It is a thin
token-rotating launcher that:

1. Resolves the canonical repo root (worktree-aware, via
   `git rev-parse --git-common-dir`).
2. Selects a Claude Code OAuth token from the effective `.loom/tokens/` pool
   (per-repo pool, else the shared machine-level pool) via the native
   `loom-daemon tokens select` CLI (issue #4228), exports
   `CLAUDE_CODE_OAUTH_TOKEN`, and exports `LOOM_TOKEN_NAME` so a downstream
   wrapper can mark exactly the right account bad on a usage fault.
3. `exec`s the underlying CLI — `claude` by default, or
   `.loom/scripts/claude-wrapper.sh` when `--use-wrapper` is passed for
   retry/backoff/auth-cache behavior.

The **interface** every `spawn-<runtime>.sh` must satisfy (the shape, not the
Claude-specific internals):

| Facet | Claude Code reference behavior | Adapter obligation |
|-------|--------------------------------|--------------------|
| **Args passthrough** | Unknown args accumulate into `PASSTHROUGH_ARGS` and are forwarded verbatim to the CLI; `--` forwards the remainder. | Forward Loom-supplied and operator-supplied args to the runtime without reinterpreting them. |
| **Prompt delivery** | `-p "…"` / `--prompt` is passed through to `claude -p`. | Deliver the prompt to the runtime's own headless/print-mode flag. |
| **Model tier env** | `LOOM_MODEL` → `claude --model <v>` unless an explicit `--model` is already present (explicit arg wins). See [model mapping](#2-model-mapping). | Map the logical model tier to the runtime's own model-selection flag with the same precedence. |
| **Effort tier env** | `LOOM_EFFORT` → `claude --effort <v>` unless an explicit `--effort` is present. This is a **session-default** effort; the in-session Task tool exposes no per-rung effort knob. | Map to the runtime's reasoning-effort knob if it has one; otherwise omit (no error). |
| **Missing-pool failure** | Exits **78** (`EX_CONFIG`) when neither token pool exists / all tokens are bad, with a message pointing at `loom-tokens bootstrap`. It never silently falls back to keychain. | Fail with a distinct, non-generic exit code on a missing/exhausted credential source rather than silently degrading. |
| **Runtime-missing failure** | Exits `127` when the `claude` CLI is not on `PATH`. | Fail cleanly when the runtime binary is absent. |
| **Observability** | Emits exactly one structured `spawn-claude: model=<v>` line (and an effort line when resolved) to stderr on every spawn, changing no behavior. | Emit an equivalent single structured line so log scrapers can attribute the dispatch. |

The daemon dispatch path (`loom-daemon`'s `spawn_child`) sets
`LOOM_SWEEP_CLAIM_OWNED` and per-sweep log redirection around this script; an
adapter's spawn entry point is invoked the same way, so it must tolerate that
env var being present (Claude's script logs `LOOM_SWEEP_CLAIM_OWNED` on every
spawn for dispatch diagnosability). `LOOM_PACKAGE_PATH` forwarding — the
bridge that let a dispatched `spawn-claude.sh` locate the Python `loom_tools`
package — was retired end-to-end in #4228 once token selection went native.

The runtime-neutral **dispatch seam** that realizes this contract point today —
`spawn-worker.sh` plus the `runtimes` config block — is specified in
[Phase 1: the `spawn-worker.sh` runtime-dispatch seam](#phase-1-the-spawn-workersh-runtime-dispatch-seam)
below.

### 2. Model mapping

**Contract:** map Loom's **logical model tiers** (`opus`, `sonnet`,
`sonnet@xhigh`, `fable`, …) to the **runtime-specific model IDs** the runtime
dispatches on the wire. Loom's roles, the sweep escalation ladder, and the
model-cost experiment all keep naming *logical* tiers; each adapter owns the
single indirection from logical tier to its own concrete IDs.

**Reference implementation:** `defaults/scripts/resolve-model.sh` (a thin stub
delegating to `loom_tools.model_tiers`). It is the single indirection point that
resolves a logical alias to the concrete ID *before* dispatch. It exists because
a bare alias is not always current on the wire — the CLI's own `opus` alias
still resolves to a previous-generation model, so the shipped map pins the stale
tier (e.g. `opus → claude-opus-5`) while `sonnet`/`fable` and pinned IDs pass
through unchanged. The mapping is repointable per-repo via `.loom/config.json` →
`sweep.modelAliases` with no code change. In `spawn-claude.sh` the resolved tier
arrives as `LOOM_MODEL` and becomes `claude --model <id>` (explicit `--model`
arg wins).

A new adapter provides the equivalent tier→ID table for its runtime (e.g. Codex
logical `opus` → an OpenAI reasoning-model ID). The fork's "cost of being wrong"
tiering is the seed for how a non-Claude runtime should choose which concrete
model a tier maps to.

**Complexity tier map (`sweep.tierModels`, issue #4238).** The higher-level
`sweep.tierModels[<runtime>][<tier>]` map (Curator marker → logical tier →
model, `mechanical`/`routine`/`complex`) is exactly this per-runtime table. It is
resolved **entirely orchestrator-side** — the `/loom:sweep` skill runs
`./.loom/scripts/resolve-tier-model.sh <issue> <runtime>`, which delegates the
config lookup to `loom_tools.model_tiers` (`resolve_tier_model`, `--tier` mode)
and then the alias→ID step to `resolve-model.sh`. **The Rust daemon does not
participate**: it never reads the complexity marker — it dispatches with an
explicit/inherited `--model` and forwards nothing else — so there is no daemon
counterpart to keep in lockstep for the tier map, and its `sweep.modelAliases`
resolution (`read_model_aliases` / `resolve_dispatch_model`) is untouched by
#4238. The two-language divergence flagged below is therefore **not widened** by
the tier map; when the adapter contract unifies the alias resolvers, the tier
map layers cleanly on top of whichever single-source resolver wins.

**Optimization profile (`sweep.optimization`, issue #4238 Phase B).** The
`cost`/`speed`/`balanced` policy switch that selects a preset over the tier map
above (see `model-selection.md` "Optimization profile switch") is, for the same
reason, **also orchestrator-side only**: `resolve_optimization_profile` /
`optimization_preset` live in `loom_tools.model_tiers` alongside
`resolve_tier_model`, reached through the same `resolve-tier-model.sh` call —
there is no separate dispatch path to keep in lockstep. It does not touch
`sweep_registry.rs` for the same reason the tier map does not: the Rust daemon's
`resolve_dispatch_model` only ever resolves `sweep.modelAliases` for its own
`--model` forwarding and has no participation in the Builder-only tier-2.5
resolution chain the profile extends. Verified against `loom-daemon/src/sweep_registry.rs` —
no `tierModels`/`optimization` schema validation exists there to keep in lockstep.

> **Open reconciliation item — do not resolve here.** `sweep.modelAliases` has a
> known **Rust/Python divergence**: the Rust dispatch resolver and the Python
> `model_tiers` resolver do not treat the alias map identically (the Rust side is
> tiered; the Python side is not). A unified model-mapping layer for the adapter
> contract must reconcile these two resolvers — but that reconciliation is
> tracked separately (epic #4167, Phase 4 "pool + tiering integration") and is
> **out of scope for this contract doc**. An adapter author should be aware the
> single-source model map is not yet single-source across both runtimes.

### 3. Error classification

**Contract:** classify a `(output, exit_code)` pair into a small, stable set of
categories so the dispatcher knows whether to rotate the token, retry, escalate,
or fail. The categories drive account-pool health and the sweep's
refusal/rejection handling.

**Reference implementation:** `defaults/scripts/lib/classify-error.sh`. It is
**exit-code-first** (a clean `exit 0` is `SUCCESS` regardless of output content,
the #3233 fix) and only inspects output on a genuine non-zero exit. Its category
set:

| Category | Meaning | Dispatcher action |
|----------|---------|-------------------|
| `SUCCESS` | exit 0 | proceed |
| `TIMEOUT` | exit 124/137 | productive cycle, not a failure |
| `CWD_DELETED` | worktree removed mid-run | abandon cleanly |
| `TOKEN_EXPIRED` | 401 / OAuth expired | skip this token |
| `TOKEN_EXHAUSTED` | quota / weekly / usage limit | rotate to another account, mark bad |
| `SESSION_LIMIT` | concurrent-session cap (healthy account) | re-select, retry, do **not** mark bad |
| `MODEL_REFUSAL` | safety classifier refused the turn | drop one ladder rung, no Doctor cycle consumed |
| `RECOVERABLE` | rate limit / 5xx / network | retry with backoff |
| `FATAL` | reserved | non-recoverable |

Today this file is a single Claude-only `classify_error()` function — its regexes
match Claude Code's actual error wording (its 401 phrasing, its quota/weekly-limit
strings, its concurrent-session message) against the shared category set. It is
the **Claude reference implementation**, not yet a multi-provider structure.

The important design point for adapters is the **contract requirement** this file
must grow into: a **per-provider pattern-table** organization, where each category
is matched by a *provider-specific* regex over that runtime's error wording, all
mapping onto the **same** category set. Restructuring `classify-error.sh` into
per-provider tables is exactly what the fork's PR #6 targets — that is the future
shape this contract point specifies, not the current upstream state. Once
restructured, a new adapter contributes its runtime's pattern table (Codex's 401
wording, its quota-exhaustion phrasing, its concurrent-session message) without
touching the categories. The category *contract* is shared; the *patterns* are
per-runtime. Callers such as `claude-wrapper.sh` source this file rather than
duplicating the patterns, so the category set must stay stable across runtimes.

### 4. Usage accounting

**Contract:** feed the account pool the session cost/limit signals it needs to
rank and rotate accounts. The pool needs to know, per session: which account was
used, whether it hit a usage/session/weekly limit, and (for cost analysis) the
per-message token usage and model.

**Reference shape:** `spawn-claude.sh` exports `LOOM_TOKEN_NAME` so the failing
account is identified precisely (not guessed from file mtimes); the
`TOKEN_EXHAUSTED` / `SESSION_LIMIT` classifications above tell the pool whether
to mark an account bad or merely re-select. Durable cost recovery comes from the
runtime's per-session **transcript** (Claude Code writes per-message `usage` +
`model` to a JSONL transcript; the #3726 archiver and #3725 harvest read it).

An adapter must expose the equivalent for its runtime: a way to attribute a
session to an account, a limit/exhaustion signal (via the error categories
above), and — for tier-1 cost parity — a transcript or usage stream with
per-turn token counts and the model used. Where the runtime provides no
transcript, cost fidelity degrades to the aggregate log (Loom already tags this
as `token_fidelity: sweep-aggregate-log | none`). The provider-aware account pool
(a per-account `provider` field, provider-aware selection, `CODEX_HOME`-style
profile rotation) is the fork's shipped work (fork PRs #12/#17) and is the
consumer of these signals.

### 5. Instruction format

**Contract:** declare which instruction files the runtime reads, and generate
them from a single source so role/repo instructions never fork per-runtime.

- **`AGENTS.md`** is the cross-runtime single source — an Agentic AI Foundation
  (Linux Foundation) standard read natively by Codex, Amp, Cursor, Copilot, Zed,
  Jules, oh-my-pi, and others (see https://agents.md). It is the runtime-neutral
  instruction anchor.
- **`CLAUDE.md`** is Claude Code's richer native format. Claude Code also reads
  `AGENTS.md`, but `CLAUDE.md` carries the full operating surface.

Both are generated from one source (the fork's `AGENTS.md` codegen, fork PR #8,
is the seed) so a new runtime that reads `AGENTS.md` gets correct instructions
with no per-runtime prompt fork. An adapter declares its instruction-file set
(e.g. Codex reads `AGENTS.md` + `.codex/` config); it must **not** introduce a
per-runtime copy of the role prompts.

### 6. Permission / sandbox mapping

**Contract:** map Loom's guard-hook *intent* to the runtime's own sandbox
mechanism, and ship a guardrail-parity document with an explicit residual-gap
section. Loom's `PreToolUse` guards (`guard-destructive.sh`,
`guard-loom-workflow.sh`, `guard-worktree-paths.sh`) are Claude-Code-specific —
they are Claude Code hooks. Another runtime has its own sandbox model
(allow/deny command lists, filesystem confinement, network policy), which will
not match Loom's guards one-for-one.

**Adapter obligation:** every adapter MUST ship a `GUARDRAIL-PARITY.md`-style map
of *Loom guard intent → runtime sandbox mechanism* (e.g. "force-push-to-main
deny → Codex sandbox deny-rule X"), plus an **explicit residual-gap section**
naming the Loom protections the runtime's sandbox does **not** cover. **No
runtime is admitted without this parity doc.** This makes the trust boundary a
documented artifact rather than an assumption — the operator can see exactly what
is and is not enforced before promoting the runtime. The fork's
`GUARDRAIL-PARITY.md` (fork PRs #20/#40) is the seed; the fork's finding that
native Codex agents must be *prohibited* for Loom lifecycles (fork PR #59) is the
kind of hard constraint a parity doc records.

### 7. Capability declaration

**Contract:** each runtime declares the capabilities it supports — MCP,
subagents, hooks, skills, worktree isolation — as yes/no/partial. Dispatch
matches a role's *requirements* against a runtime's *declaration* and refuses a
mismatch up front instead of failing downstream.

This doc specifies only the **schema sketch**; the matcher implementation is a
separate issue (epic #4167, design pillar 2). Sketch:

```jsonc
// A runtime's capability declaration (illustrative shape only)
{
  "runtime": "codex",
  "capabilities": {
    "mcp": "partial",          // yes | no | partial
    "subagents": "no",
    "hooks": "no",
    "skills": "no",
    "worktreeIsolation": "yes"
  }
}
```

Roles declare requirements (e.g. Builder needs `worktreeIsolation` + `mcp`;
Judge needs read-only + forge access). Dispatch computes role → runtime
compatibility and refuses to dispatch a role onto a runtime that cannot meet its
requirements, rather than letting the session fail partway. The declaration is
per-runtime; the requirements are per-role; the match happens at dispatch time.

**Landed today (#4170):** the declaration and requirement sides of this contract
exist as data + a standalone checker, ahead of dispatch wiring:

- **Declaration** — `defaults/runtimes/<name>.json` (e.g.
  `defaults/runtimes/claude.json`), matching the sketch above exactly (tri-state
  `"yes" | "no" | "partial"` string values, capability set `mcp`, `subagents`,
  `hooks`, `skills`, `worktreeIsolation`).
- **Requirements** — an optional `"runtimeRequirements"` array on a role sidecar
  (`defaults/roles/<name>.json`), e.g. `"runtimeRequirements": ["worktreeIsolation",
  "mcp"]` on `builder.json`. A role with no `runtimeRequirements` key has no
  constraints (any runtime is compatible). This is a distinct field from the
  pre-existing `suggestedWorkerType` (a dispatch *preference* hint) — the checker
  reads only `runtimeRequirements`.
- **Matcher** — `defaults/scripts/check-runtime-capabilities.sh --role <name>
  --runtime <name>` loads both files and checks requirements ⊆ capabilities,
  where a requirement is satisfied only by a declared `"yes"` (`"partial"` fails
  closed). Exit 0 on match or no-requirements, exit 78 (`EX_CONFIG`) on mismatch
  naming each unmet capability, non-zero with a distinct message on an
  unknown/missing role or runtime file. It is intentionally **standalone** —
  not yet wired into `spawn-worker.sh` or any dispatch path; that wiring is a
  follow-up decision.

## Phase 1: the `spawn-worker.sh` runtime-dispatch seam

Contract point 1 ([Spawn](#1-spawn)) is realized today by a concrete
**runtime-dispatch seam** so the underlying runtime is a swappable adapter rather
than a hardwired path. Claude Code is adapter #1; a future Codex adapter
(`spawn-codex.sh`) slots in behind the same seam with no caller change. This is
**Phase 1** of epic **#4167** and is a **zero-behavior-change** extraction: with
nothing configured, the seam execs the same `spawn-claude.sh` Loom always ran.
(This upstreams the dispatch-seam shape the fork's PR #9 built — see the [fork
mapping table](#fork-mapping-table) — as Loom's own Phase 1 implementation.)

### The dispatcher: `spawn-worker.sh`

`defaults/scripts/spawn-worker.sh` (installed to `.loom/scripts/spawn-worker.sh`)
is a thin dispatcher that resolves a runtime name and execs the matching
`spawn-<runtime>.sh` runner in the same directory, forwarding every argument
verbatim. Because it uses `exec`, the runner's exit code is the dispatcher's exit
code — so the [error classification](#3-error-classification) contract is
unaffected by the extra hop.

```bash
.loom/scripts/spawn-worker.sh -p "your prompt"
LOOM_RUNTIME=claude .loom/scripts/spawn-worker.sh --use-wrapper -p "..."
```

Callers migrate from `spawn-claude.sh` to `spawn-worker.sh` to gain runtime
selection; until they do, `spawn-claude.sh` keeps working unchanged (existing
daemon/tooling callers are intentionally left on the direct path in Phase 1).

### Runtime resolution (precedence)

The runtime is resolved with the standard Loom precedence chain
(**env > config > default**):

| Precedence | Source | Notes |
|-----------|--------|-------|
| 1 (highest) | `LOOM_RUNTIME` env var | A non-empty value wins. An **empty** value is treated as unset and falls through. |
| 2 | `.loom/config.json` → `runtimes.default` | Read via the shared config-resolver (soft-fails silently). |
| 3 (default) | built-in `"claude"` | Applies when neither of the above resolves. |

The config read tolerates a missing config file, a missing `runtimes` block, and
a missing `jq` — all of these degrade silently to the built-in `claude` default,
so a bare install with no `runtimes` config sees no behavior change.

### The `runtimes` config block

Add to `.loom/config.json`:

```json
{
  "runtimes": {
    "default": "claude"
  }
}
```

`runtimes.default` names the runtime used when `LOOM_RUNTIME` is unset. The value
must have a matching `spawn-<value>.sh` runner on disk (e.g. `"claude"` →
`spawn-claude.sh`).

### Adding a runtime adapter

Drop a `spawn-<runtime>.sh` runner next to `spawn-claude.sh` (same directory,
executable). It must satisfy the [Spawn interface](#1-spawn) above — accept the
same passthrough-args contract and `exec` its underlying CLI. Then select it
per-run with `LOOM_RUNTIME=<runtime>` or repo-wide with `runtimes.default`.

### Unknown-runtime failure (exit 78)

If the resolved runtime has no matching `spawn-<runtime>.sh` runner, the
dispatcher exits **78** (`EX_CONFIG`) — the same distinct config-error code the
Spawn contract's *missing-pool* facet uses — with an actionable message naming:

- the resolved runtime,
- where it was resolved from (env vs config vs default), and
- the `spawn-*.sh` runners actually present on disk.

```text
ERROR Unknown runtime 'codex' (resolved from config (runtimes.default)):
ERROR no runner found at /…/.loom/scripts/spawn-codex.sh.
ERROR Available runtimes on disk: claude.
```

### Scope (Phase 1)

- No capability-matrix enforcement in the dispatcher
  ([contract point 7](#7-capability-declaration) is a separate issue) — the seam
  only routes; it does not validate a runtime's feature set.
- `spawn-claude.sh`, `claude-wrapper.sh`, the Rust `loom-daemon`, and the Python
  `loom-tools` callers are unchanged; migrating callers onto `spawn-worker.sh`
  is a follow-up once the seam has soaked.

## Fork mapping table

The gpeyton/loom fork already built much of this as parallel special-casing. The
adapter contract is the interface that work slots into as **upstream PRs from the
fork** (not cherry-picks). This is the "your work slots in here" map for the
collaboration:

| Fork PR | What it built | Contract slot |
|---------|---------------|---------------|
| #9 | `spawn-worker.sh` spawn dispatcher | **1. Spawn** — the runtime-neutral dispatch entry point |
| #6 | Restructured `classify-error.sh` into per-provider pattern tables | **3. Error classification** — the per-runtime pattern-table shape |
| #15 | Codex runner | **1. Spawn** — Codex's `spawn-<runtime>.sh` implementation |
| #16 | `.codex/` config | **5. Instruction format** — Codex's config/instruction file set |
| #20, #40 | `GUARDRAIL-PARITY.md` guardrail parity | **6. Permission / sandbox mapping** — the parity-doc requirement |
| #8 | `AGENTS.md` codegen | **5. Instruction format** — single-source instruction generation |
| #12, #17 | Provider-aware account pool (per-account provider, waterfall fill, `CODEX_HOME` rotation) | **4. Usage accounting** — provider-aware selection consuming the pool signals |
| #14 | Reusable CI role workflow (`loom-role.yml`) parameterized by runtime | Cross-cutting — the tier-2 CI gate every non-Claude adapter must pass |
| #59 | Finding: native Codex agents prohibited for Loom lifecycles | **6/7. Constraint** — encoded in the parity doc + capability matrix |

## Non-goals

- **No change to the forge/label state machine.** Runtime choice is invisible to
  the coordination layer — `loom:issue` → `loom:building` → `loom:pr` → merged is
  identical regardless of which runtime a worker uses.
- **No per-runtime role prompt forks.** Instruction content stays single-source
  (contract point 5).
- **No new labels.**

## Related

- Epic **#4167** — first-class multi-runtime worker support (the seven contract
  points' authoritative framing, the phasing, and the fork PR list).
- **#4165** — fork divergence triage (harvest tracking).
- [ADR-0012: Multi-Runtime Worker Support via a Runtime Adapter Contract](../../docs/adr/0012-runtime-adapter-contract.md).
- Fork: https://github.com/gpeyton/loom · `AGENTS.md` standard: https://agents.md
