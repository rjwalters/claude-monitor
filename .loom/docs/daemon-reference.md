# Loom Daemon Reference

> **Status: ACTIVE (v0.10.0).** This page describes the Rust `loom-daemon`
> binary and its MCP-facing surface — the dispatch + pub/sub + monitoring
> tools delivered by epic #3449 (Phases A through C). The legacy Python
> `loom-daemon` brain (`loom_tools/daemon_v2/`) and the `/shepherd`
> orchestrator were deleted in the v0.10.0 deprecation epic (#3372). The
> shell-level `./.loom/scripts/daemon.sh` tmux session launcher (when
> rebuilt under epic #3449's later phases) wraps this same daemon binary.

## What the daemon is

`loom-daemon` is a Rust process that exposes a Unix-socket IPC surface
(framed JSON, line-delimited) and a paired `mcp-loom` MCP server which
maps each IPC request 1:1 to an MCP tool. The daemon is **the
coordination point** for:

- **Dispatching** `/loom:sweep` children with multi-account OAuth token
  rotation (via `defaults/scripts/spawn-claude.sh`).
- **Tracking** running sweeps in an in-memory registry (no on-disk state
  file — the forge is the source of truth for queue state).
- **Publishing** sweep-lifecycle events on an in-memory pub/sub bus, and
  **subscribing** external monitors to topic-filtered streams.
- **Cancelling** in-flight sweeps with SIGTERM → grace → SIGKILL.
- **Reaping** dead PIDs (every 30s) to maintain registry liveness and
  emit `sweep.issue.*.exited` / `sweep.issue.*.crashed` events.

**By default it is not a work generator.** With no autonomous config it
does not poll the forge for ready issues, it does not maintain a
`shepherd-N` pool, and it does not run support roles on cron — those
responsibilities live in `mcp__loom__dispatch_sweep` (operator-driven
enqueue) and the GitHub Actions cron workflows
(`.github/workflows/loom-*.yml`). Two **opt-in, default-off** surfaces
(epics #3809 and #3842) let the daemon generate and dispatch its own work
when explicitly enabled: the [autonomous work
finder](#autonomous-work-finder-3810) polls open `loom:issue` items and
auto-dispatches sweeps, and the [epic supervisor](#epic-supervisor-3842)
drives `loom:epic` fork-joins. See [Operability](#operability--config-startstop-e2e-phase-d-3813)
for enabling and tuning them.

## Architecture (Phases A-C)

```
┌────────────────────────────────────────────────────────────────┐
│                      MCP clients (Claude Code)                 │
│  - dispatch_sweep, list_sweeps                          (A)    │
│  - publish_event, subscribe_to_events                   (B)    │
│  - get_sweep_status, tail_sweep_log, cancel_sweep       (C)    │
│  - tail_event_bus                                       (C)    │
└────────────────────────────────────────────────────────────────┘
                              │ stdio JSON-RPC
                              ▼
┌────────────────────────────────────────────────────────────────┐
│                    mcp-loom (TypeScript)                       │
│  - Validates args, normalizes payloads, formats output         │
│  - One MCP tool per IPC Request variant                        │
└────────────────────────────────────────────────────────────────┘
                              │ Unix socket, line-delimited JSON
                              ▼
┌────────────────────────────────────────────────────────────────┐
│                    loom-daemon (Rust)                          │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────┐  │
│  │ SweepRegistry    │  │ EventBus         │  │ ReaperTask   │  │
│  │ (BTreeMap)       │  │ (broadcast chan) │  │ (30s tick)   │  │
│  └──────────────────┘  └──────────────────┘  └──────────────┘  │
│                              │                                  │
│                              ▼                                  │
│                    fork+exec /loom:sweep N                      │
│                    via spawn-claude.sh                          │
└────────────────────────────────────────────────────────────────┘
                              │ detached child
                              ▼
                       /loom:sweep <issue>
                       (Claude Code session)
```

## IPC surface (Request/Response variants)

The wire protocol is line-delimited JSON. Each `Request` is one line; the
daemon responds with one line per request — except `SubscribeEvents`,
which holds the connection open and streams one `EventStream` frame per
event. Connection framing matches the existing terminal-management IPC
surface; no new transport is introduced.

Source of truth: [`loom-daemon/src/types.rs`](https://github.com/rjwalters/loom/blob/main/loom-daemon/src/types.rs)
(upstream Loom repo — not shipped to consumer installs).

| Request | MCP tool | Response | Phase |
|---------|----------|----------|-------|
| `DispatchSweep`     | `dispatch_sweep`       | `SweepDispatched`   | A (#3452) |
| `ListSweeps`        | `list_sweeps`          | `SweepList`         | A (#3452) |
| `PublishEvent`      | `publish_event`        | `EventPublished`    | B (#3453) |
| `SubscribeEvents`   | `subscribe_to_events`, `tail_event_bus` | `EventStream` (stream) | B (#3453) |
| `GetSweepStatus`    | `get_sweep_status`     | `SweepStatus`       | C (#3455) |
| `TailSweepLog`      | `tail_sweep_log`       | `SweepLogTail`      | C (#3455) |
| `CancelSweep`       | `cancel_sweep`         | `SweepCancelled`    | C (#3455) |

## Event taxonomy (frozen for v0.10.0)

The bus accepts arbitrary topic strings, but the documented taxonomy is
the contract subscribers should rely on. **New topics require a follow-up
issue** — the v0.10.0 set is intentionally frozen.

| Topic | Publisher | Payload |
|-------|-----------|---------|
| `sweep.issue.{N}.phase`   | Sweep child via `publish_event` | `{phase, pr_number?, repo?}` |
| `sweep.issue.{N}.blocker` | Sweep child                     | `{reason, label_added, repo?}` |
| `sweep.issue.{N}.exited`  | Daemon reaper (or `cancel_sweep`) | `{exit_code, duration_sec, repo?}` |
| `sweep.issue.{N}.crashed` | Daemon reaper                   | `{checkpoint_phase, repo?}` |
| `sweep.global.dispatch`   | Daemon                          | `{sweep_id, kind}` |
| `sweep.global.completed`  | Daemon                          | `{sweep_id, outcome}` |
| `epic.issue.{N}.decompose` | Epic supervisor (#3842)        | `{epic, action, state}` |
| `epic.issue.{N}.expand`    | Epic supervisor (#3842)        | `{epic, action, state}` |
| `epic.issue.{N}.join`      | Epic supervisor (#3842)        | `{epic, action, state}` |
| `epic.issue.{N}.close`     | Epic supervisor (#3842)        | `{epic, action, state}` |
| `daemon.capacity.advisory` | Work finder (#3902)            | `{pressured, queued, healthy_accounts, exhausted_accounts, total_accounts, estimated_drain_minutes?, message}` |
| `daemon.drain.started`     | Drain supervisor (#4090)       | `{in_flight, timeout_secs, force_after_timeout, deadline}` |
| `daemon.drain.completed`   | Drain supervisor (#4090)       | `{in_flight}` (always `0`) |
| `daemon.drain.aborted`     | Daemon IPC (#4090)             | `{was_draining}` |
| `daemon.drain.timeout`     | Drain supervisor (#4090)       | `{in_flight, forced, cancelled?}` |

The four `epic.issue.{N}.*` topics were authorized by **#3873** (epic #3842
Phase 4) and are documented in full under [Epic supervisor](#epic-supervisor-3842)
below. The `daemon.capacity.advisory` topic was authorized by **#3902** (epic
#3809): the autonomous work finder publishes it on a token-capacity **pressure
state change** (entered/left the token-bound state), never every tick, so the
operator gets one add-capacity advisory on the way in and one recovery on the way
out. See [Token-capacity backpressure](#token-capacity-backpressure-3902) below.
The four `daemon.drain.*` topics were authorized by **#4090** for the scheduled
drain-and-restart primitive — `started` when a drain is accepted, `completed`
when the last in-flight sweep finishes (right before the supervised relaunch),
`aborted` when an operator cancels a drain, and `timeout` when the deadline is
reached (`forced` distinguishes a refusal from a force-cancel restart). See
[Supervised restart primitive](#supervised-restart-primitive-4054) below.
They ride the same in-memory bus as the sweep topics and are tailable via
`subscribe_to_events` / `tail_event_bus`.

The four `sweep.issue.{N}.*` payloads gained an additive **`repo`** field in
**#3929** (`(repo, issue)`-aware sweep visibility, phase c of #3926). The bus is
shared across every managed repo, and the topic string is issue-scoped only —
two managed repos can each dispatch a sweep for issue #42 onto the *identical*
`sweep.issue.42.phase` topic. `repo` carries the owning registry's
`workspace_root`, so a multi-repo-aware subscriber can disambiguate them after
matching the topic. **The topic strings are unchanged** — `repo` lives in the
payload only, so existing single-repo subscribers that filter on `sweep.issue`
or `sweep.issue.{N}` route byte-for-byte identically and simply ignore the new
field. The daemon stamps `repo` centrally when it emits each event; a sweep
child that already knows its repo (via `publish_event`) may supply it and will
not be overwritten. `sweep.global.*` events are unchanged — they already carry a
unique `sweep_id`.

In addition, the bus internally emits:

- `sweep.system.topic_lag` — synthetic event when a subscription falls
  behind the publisher past the bus capacity. Mirrors tokio's `Lagged`
  semantics; carries `{skipped: usize}`.

Topic matching is **segment-aligned prefix** (`sweep.issue` matches
`sweep.issue.123.phase` but not `sweep.issuetype.foo`). See
[`event_bus::topic_matches`](https://github.com/rjwalters/loom/blob/main/loom-daemon/src/event_bus.rs)
(upstream Loom repo — not shipped to consumer installs) for the
authoritative routing rule.

## MCP tool reference

All tools live in `mcp-loom/src/tools/sweeps.ts`. Each tool name maps
1:1 to an IPC `Request` variant.

### `dispatch_sweep` (Phase A)

Spawn a `/loom:sweep` child via the daemon's registry. The daemon shells
out to `defaults/scripts/spawn-claude.sh` for token rotation and detaches
the child. Returns the `sweep_id`, child PID, token-account name, and
per-sweep log path.

Inputs:
- `kind` (required) — `{"Issue": <N>}` or `{"PrSet": [<N>, ...]}`. Phase
  A only fully implements `Issue`; `PrSet` is rejected by the registry.
- `idempotency_key` (optional) — dedup key. Running sweeps with the same
  key return the existing `sweep_id` without spawning a new child.
- `model` (optional, issue #3477 Phase 1) — Claude model for the spawned
  child, as an alias (`sonnet`, `opus`, `haiku`) or a pinned ID
  (`claude-sonnet-4-6`). Forwarded as `--model <value>` on the
  `spawn-claude.sh` argv. When omitted (or empty), NO `--model` flag is
  emitted and the child inherits the session/CLI default. The field is
  `#[serde(default)]` on the wire, so pre-#3477 clients remain compatible.
- `depends_on` (optional, issue #3729 stacked-PR v1) — a **single** parent
  issue number this sweep is stacked on. Forwarded to the child as
  `--depends-on <N>` (mirroring the `--model`/`--effort` append-only,
  empty-means-unset contract), instructing `/loom:sweep` to branch the child
  worktree/PR off `feature/issue-<N>` instead of the default branch. When
  omitted, NO `--depends-on` flag is emitted (byte-for-byte unchanged). A
  single optional parent (not a list) makes diamonds / multi-parent stacks
  structurally unrepresentable — see "Stacked-PR dependency (v1)" below. The
  field is `#[serde(default)]` on the wire, so pre-#3729 clients remain
  compatible.
- `workspace_root` (optional, issue #3929) — target managed-workspace root.
  When set to a registered repo root, the daemon resolves that repo's sweep
  registry via the `WorkspacePool` and dispatches into its working tree — the
  way to dispatch into a managed repo other than the default when two repos
  share issue numbers. `#[serde(default)]` on the wire.

  **When omitted (issue #4299):** the daemon no longer blindly targets its own
  seeded default (cwd at startup / `LOOM_WORKSPACE`) — it consults the
  on-disk `~/.loom/workspaces.json` registry (`WorkspaceRegistry::resolve_dispatch_root`,
  `workspace_registry.rs`) in this order:
  1. **Registry empty** -> the seeded default (byte-for-byte pre-#4299 / pre-registry
     behavior).
  2. **Seeded default is itself registered** -> the seeded default. This is the
     back-compat floor: every existing multi-workspace host runs the daemon
     from a registered repo, so a bare dispatch with no `workspace_root` keeps
     working with no new flags.
  3. **Seeded default is NOT registered, exactly one workspace is registered**
     -> that workspace. This is the case a single-repo worker host (daemon cwd
     = the machine checkout, one product repo registered) needs: the sole
     registration is the only sane target.
  4. **Seeded default is NOT registered, multiple workspaces are registered**
     -> a structured `CONFIG_WORKSPACE_AMBIGUOUS` error naming every
     registered root. Issue numbers are per-repo, so guessing which repo
     "owns" issue N by probing the forge is ill-defined — an explicit
     `workspace_root`/`--workspace` is required instead. Never a silent cwd
     fallback.

  This resolution applies to the **dispatch path only**. `list_sweeps`,
  `get_sweep_status`, and quarantine requests keep their unconditional
  default-registry fallback for an absent `workspace_root` — read-path default
  behavior is unchanged (a deliberate scope limit; see the #4299 issue for the
  follow-up if that also needs to change).

#### `loom-daemon dispatch <issue>` — operator CLI (Issue #3952)

`loom-daemon dispatch <issue>` is the **non-MCP** operator entry point onto the
same `DispatchSweep` IPC request the `dispatch_sweep` MCP tool uses. It is a thin
client: connect to the daemon socket, send one `DispatchSweep` frame, print the
returned `sweep_id` + per-sweep log path, exit `0`. Because it flows through the
registry, the `loom:issue → loom:building` claim flip, in-flight tracking, the
reaper, and event publishing all come for free — exactly like the MCP path.

```bash
loom-daemon dispatch 3952                          # dispatch into the default workspace
loom-daemon dispatch 3952 --workspace /path/to/repo # target a registered managed repo (#3929)
loom-daemon dispatch 3952 --model sonnet --effort high
loom-daemon dispatch 3952 --depends-on 3945        # stacked-PR child (#3729)
```

| Flag | Maps to `DispatchSweep` field | Notes |
|------|-------------------------------|-------|
| `<issue>` (positional) | `kind = {"Issue": N}` | required |
| `--workspace <PATH>` | `workspace_root` | target a registered repo other than the default (#3929) |
| `--model <M>` | `model` | omit to let the daemon resolve `autonomous.model` / the shipped default (#3944) |
| `--effort <E>` | `effort` | reasoning-effort override (#3716) |
| `--depends-on <P>` | `depends_on` | single parent issue; child branches off `feature/issue-<P>` (#3729) |

**`--workspace` client-side cwd default (issue #4299).** When `--workspace` is
omitted, the CLI itself (not the daemon — it cannot see the client's cwd)
checks whether its own working directory falls under a registered workspace
root and, if so, populates `workspace_root` with that root before sending the
request (`resolve_cli_dispatch_workspace` in `main.rs`). This is what makes
`cd ~/GitHub/anvil && loom-daemon dispatch 758` target anvil even when the
daemon's own seeded default points elsewhere. A cwd outside every registered
root leaves `--workspace` unset, and the daemon-side resolution above applies.

**Bounded ack timeout (never hangs).** The CLI waits at most **30s** for the
daemon to ack the dispatch, then exits **nonzero** with a clear
`Daemon did not ack the dispatch within 30s (...) — is loom-daemon running?`
message rather than blocking. The 30s default mirrors the `mcp__loom__dispatch_sweep`
tool's own `DISPATCH_TIMEOUT_MS` for the identical IPC call, and exists because
`SweepRegistry::dispatch()` does real synchronous work *before* it acks — a
blocking `gh issue edit` label flip, up to a 2s dispatch stagger, and up to a 5s
token-name capture window — so a legitimate, successful dispatch can take several
seconds to ack. A tighter bound (the original 5s) would false-report those real
successes as `did not ack`. Operators on a slow forge or a heavily-loaded daemon
can *raise* the bound with `LOOM_DAEMON_IPC_TIMEOUT_MS=<ms>` (the same env var
`mcp-loom` honors); it only ever raises above the 30s floor, never lowers it (a
lower value would reintroduce the false negative). The timeout is always a
bounded, finite value: the MCP `dispatch_sweep` path once wedged for **1800s**
(#3945), and this command must never reproduce that hang.

**Replaces the hand-rolled pattern.** Before #3952 the only non-MCP alternative
was to reproduce the daemon's dispatch by hand — flip the label, export
`LOOM_SWEEP_CLAIM_OWNED=<N>` plus `LOOM_MODEL` and workaround envs, and invoke
`spawn-claude.sh -p "/loom:sweep N"` directly:

```bash
# DEPRECATED — do NOT do this. Bypasses the registry (no in-flight tracking,
# no reaper, no status visibility), and — even carrying both the correct env
# var AND the prompt-embedded `--claim-owned N` marker `SweepRegistry::dispatch`
# itself emits (#4111; embedded in the -p prompt text, NOT a sibling claude arg,
# which the real claude CLI would reject — #4120) — is fragile to reproduce by
# hand; a mismatched/missing claim marker on either channel makes the child skip
# its own issue.
gh issue edit 3952 --remove-label loom:issue --add-label loom:building
LOOM_SWEEP_CLAIM_OWNED=3952 LOOM_MODEL=sonnet \
  ./.loom/scripts/spawn-claude.sh -p "/loom:sweep 3952 --claim-owned 3952"
```

Use `loom-daemon dispatch 3952` instead — it performs the claim flip, registry
tracking, and event publishing for you, with the bounded timeout as a safety net.

### `list_sweeps` (Phase A)

Return all tracked sweeps, optionally filtered by lifecycle state.
Terminal entries are garbage-collected ~1h after the transition.

Inputs:
- `state_filter` (optional) — one of `Pending`, `Running`, `Exited`,
  `Crashed`.
- `workspace_root` (optional, issue #3929) — target managed-workspace root.
  Omit to list the default workspace's sweeps (unchanged). Set to a registered
  repo root to list the sweeps tracked by that repo's registry — the way to
  observe sweeps the daemon autonomously dispatched into a non-default managed
  repo. Each returned `SweepInfo` also carries a `repo` field naming its owner,
  so a response is self-describing even without filtering. Cross-repo
  aggregation in a single call is deferred to phase d (#3930). `#[serde(default)]`
  on the wire.

The same optional `workspace_root` input (default = default workspace, unchanged)
is accepted by `get_sweep_status`, `tail_sweep_log`, and `cancel_sweep` — so a
sweep the daemon dispatched into a non-default managed repo can be inspected,
tailed, and cancelled by naming its repo root (#3929).

### `publish_event` (Phase B)

Publish a JSON event onto the in-memory bus. Operator override / test
escape hatch — production publishes happen via the sweep skill, not this
tool.

Inputs:
- `topic` (required) — should follow the frozen taxonomy.
- `payload` (required) — opaque JSON.

### `subscribe_to_events` (Phase C)

Open a long-lived subscription to the event bus, filtered by topic
prefix. Frames arrive as line-delimited JSON matching
`Response::EventStream { events: [Event] }`. The MCP layer caps each
subscription with a `duration` window so a single tool call returns
deterministically.

Inputs:
- `topics` (optional) — array of topic prefixes; empty = all events.
- `duration` (optional, default `30s`) — `<N>s`/`<N>m`/`<N>h` window.
- `max_events` (optional) — upper bound on frames returned.

### `get_sweep_status` (Phase C)

Return the `SweepInfo` for a single sweep plus up to N recent events
observed on its topics (default 10). The bus is in-memory and transient
— recent-events collection is a best-effort short subscribe window
(~200ms), not a replay log.

Inputs:
- `sweep_id` (required).
- `recent_events` (optional, default 10) — set to 0 to skip the
  subscribe window.

### `tail_sweep_log` (Phase C)

Read the last N lines of a sweep's per-sweep log file
(`.loom/logs/sweep-issue-<N>.log`). The log path is resolved from the
registry entry.

Inputs:
- `sweep_id` (required).
- `lines` (optional, default 100).

### `cancel_sweep` (Phase C)

SIGTERM → wait `grace` seconds → SIGKILL the sweep's child PID.
Transitions the registry entry from `Running` to `Exited{code: None,
at: now}` and releases the per-issue lock. Idempotent: cancelling an
already-terminal sweep returns success with `was_running: false`.

Inputs:
- `sweep_id` (required).
- `grace` (optional, default 30) — seconds between SIGTERM and SIGKILL.

### `tail_event_bus` (Phase C)

Debug-oriented fire-hose subscription that streams ALL events on the bus
regardless of topic. Added per curator risk note D — multi-child
interactions are qualitatively harder to debug than hermetic children.

Inputs:
- `since` (optional, default `10m`) — `<N>s`/`<N>m`/`<N>h` streaming
  window. **Note**: the bus is transient — `since` is a streaming
  duration, not a backward-looking replay filter.
- `max_events` (optional) — upper bound on frames returned.

## In-memory registry layout

The sweep registry (`loom-daemon/src/sweep_registry.rs`) holds a
`BTreeMap<SweepId, SweepInfo>` keyed by stable IDs of the form
`sweep-issue-<N>-<unix-secs>` or `sweep-prs-<n1>-<n2>-...-<unix-secs>`.
`SweepInfo` carries:

- `sweep_id`, `kind` (`Issue(N)` or `PrSet(Vec<u32>)`), `pid`,
  `token_name`, `log_path`.
- `idempotency_key` (optional), `started_at`.
- `state` — one of `Pending`, `Running`, `Exited{code, at}`,
  `Crashed{at}`.
- `latest_phase` (optional) — most-recent phase advertised via
  checkpoint.
- `pr_number` (optional, reserved).
- `repo` (optional, issue #3929) — the owning managed-workspace root
  (`config.workspace_root`), stamped at dispatch/reconstruct time so a
  `list_sweeps` / `get_sweep_status` response disambiguates two managed repos'
  identically-numbered issues. `#[serde(default, skip_serializing_if = "Option::is_none")]`,
  so pre-#3929 wire data and clients remain compatible.

The wire shape is pinned by `sweep_info_schema_snapshot` in
`sweep_registry.rs` — a change to the JSON shape requires deliberate
test update.

## Per-workspace registry pool (`WorkspacePool`, #3928/#3929)

`loom-daemon/src/workspace_pool.rs` holds **one independent `SweepRegistry` per
registered repo root**, keyed by `PathBuf`, so every path a registry computes
(`.loom/locks/issue-<N>`, `.loom/logs/`, `.loom/sweep-checkpoint/`, and the
spawned child's `current_dir`) is namespaced per repo — two repos each with issue
#42 never collide. The default workspace's registry is **seeded** into the pool
(shared with the IPC `dispatch_sweep` path); the autonomous work-finder and epic
supervisor provision the other managed repos' registries on demand
(`get_or_provision`). The IPC handler resolves a request's target registry from
the pool when the request carries an explicit `workspace_root` (#3929), so all
per-repo registries are observable/addressable via `list_sweeps` /
`get_sweep_status` / `tail_sweep_log` / `cancel_sweep` / `dispatch_sweep`.

**Watchdog coverage for every provisioned workspace (#4124)**: `get_or_provision`
spawns the sweep watchdog (the startup-hang / mid-build-death / review-stall
self-healing backstops described above) alongside the reaper for **every**
pooled workspace, not just the default one — closing a gap where only the
default workspace's registry (wired up once in `main.rs`) had a watchdog and
every other managed repo got a reaper and nothing else, silently disabling the
startup-hang recovery from #3887 in any multi-repo deployment. Each pooled
workspace resolves its own watchdog config (enabled/timeout/interval/review-stall)
from its own `.loom/config.json`, mirroring the dispatch-stagger and quarantine
config already resolved per workspace — so the resolution is genuinely
per-workspace, not a copy of the default workspace's tuning. The seeded default
workspace is unaffected: `main.rs` still owns its one watchdog, and
`get_or_provision` returns the seeded entry without spawning a second one.

**Eviction on `workspace remove` (#3929)**: `DeregisterWorkspace` (the
`workspace remove` CLI) calls `WorkspacePool::evict`, which drops the pooled
registry and **aborts its background reaper and watchdog tasks** so neither
leaks. The **seeded default workspace is guarded** — it is owned by `main` and
keeps serving default-workspace IPC requests, so evicting it is a no-op. A live
sweep child in an evicted registry is **not** killed and its lock/log files are
untouched; only the in-memory tracking + reaper + watchdog go away, so the sweep
finishes normally but its terminal state becomes unobservable via IPC after the
deregister — an accepted consequence of an explicit operator `workspace remove`.

## Token pool provisioning for managed repos (#3938)

The multi-workspace work finder measures the token pool **once per tick from the
daemon's primary workspace** (`fallback_root`) and uses it as the single global
concurrency budget — token accounts are a *machine-level* resource, so the cap is
never replicated per repo. But each dispatched sweep runs `spawn-claude.sh` with
its `current_dir` set to **its own** repo root, and `spawn-claude.sh` resolves the
token pool from that repo. A freshly-installed **consumer repo has no
`.loom/tokens/` of its own** — only the primary workspace was bootstrapped — so
every cross-repo dispatch used to hard-fail instantly with `EX_CONFIG`
("Run `loom-tokens bootstrap` …"), burning a dispatch slot per tick on children
that died in ~2s.

**Fix — a shared machine-level pool with a per-repo fallback.** Token selection
and *all* pool-state bookkeeping resolve the effective pool directory as:

1. the **per-repo** pool `<repo>/.loom/tokens/` when it holds `*.token` files
   (unchanged for the primary workspace);
2. else the **shared** machine-level pool `~/.loom/tokens/` (override
   `LOOM_SHARED_TOKENS_DIR`; set it empty to disable the fallback);
3. else the per-repo path (so a truly-unbootstrapped repo still surfaces a clear
   "run bootstrap" error).

Crucially, the **state files** (`.bad_tokens`, `.failure_counts`, `.ranking`,
`.allowlist`) are read/written in *whichever pool directory was selected* — so a
consumer repo dispatching against the shared pool shares one `.bad_tokens` /
`.ranking` truth with every other repo. Pool state is **never forked per repo**,
which is what keeps the token-capacity backpressure accounting (#3907/#3930)
consistent. The Rust `token_pool_size` (the dynamic-cap input) applies the same
per-repo→shared resolution, so the daemon's concurrency ceiling matches what the
spawn path can actually pick.

**Provisioning a managed-repo pool.** Bootstrap the shared pool once per machine:

```bash
# Preferred on a host running claude-monitor — reads the live credential store
# (~/.claude-monitor/usage.db -> oauth_credentials, opened mode=ro), so no
# accounts.env is needed on this machine at all:
loom-tokens import-from-monitor --shared   # writes ~/.loom/tokens (override LOOM_SHARED_TOKENS_DIR)
loom-tokens check --ranking                # ranks the effective pool (shared when no per-repo pool)

# Without claude-monitor — materialize from the accounts.env snapshot instead:
loom-tokens bootstrap --shared      # writes ~/.loom/tokens (override LOOM_SHARED_TOKENS_DIR)
loom-tokens check --ranking         # ranks the effective pool (shared when no per-repo pool)
```

Every consumer repo the daemon dispatches into then falls back to that one pool —
no per-repo `loom-tokens bootstrap` required. A repo that *wants* its own isolated
pool can still `loom-tokens bootstrap` locally; the per-repo pool always wins.
Selection sources (`~/.claude-monitor/accounts.env`, repo-local `.env`) are
unchanged for `bootstrap` — `--shared` only redirects the *destination* of the
materialized pool. `import-from-monitor` bypasses `accounts.env` entirely and
takes claude-monitor as authoritative for pool membership (use `loom-tokens pin`
to restrict which accounts the selector may pick). If accounts later go
`blocked` on revoked tokens, `bootstrap --force` cannot recover — the
`accounts.env` snapshot is itself what went stale — run
`loom-tokens import-from-monitor --force && loom-tokens check --ranking`
instead; without `--force` a rolled token is reported as drift and left alone,
and the command exits `2`. See "Importing live tokens from claude-monitor" in
the root `CLAUDE.md` for the full behavior.

## Per-repo status breakdown + per-repo main-health gate (#3930 — phase d)

Phase d is the final phase of the multi-repo daemon (#3926/#3835). Phases b/c
already delivered the single global concurrency budget, per-workspace error
isolation, and `(repo, issue)`-aware IPC/events. Phase d closes the two remaining
gaps: making `loom-daemon status` see *every* managed repo, and making the
reactive main-health gate **per-repo** instead of one flag gating all repos.

### Per-repo status breakdown (AC1)

`build_daemon_status` (`ipc.rs`) enumerates
`WorkspaceRegistry::effective_roots(&fallback_root)` (an **empty** registry ⇒ the
single daemon workspace, byte-for-byte the pre-#3930 view) and reads each root's
own registry from the `WorkspacePool` (`get_or_provision`). It returns:

- `DaemonStatusReport.in_flight` — now the **union** of non-terminal sweeps across
  every registered repo, so a sweep the autonomous loops dispatched into a
  non-default managed repo is finally visible in `loom-daemon status`.
- `DaemonStatusReport.per_repo: Vec<RepoStatus>` — one entry per root with `root`,
  `in_flight_count`, and `health_gate_halted`. Additive + `#[serde(default)]`, so
  pre-#3930 JSON consumers round-trip unchanged (an absent `per_repo` deserializes
  to an empty vec).

`loom-daemon status` prints a **Managed repos** section (root, in-flight count,
gate state); `loom-daemon status --json` adds the `per_repo` array. The
dynamic-cap inputs (token pool, disk headroom, cpu/load headroom (#3978),
configured ceiling) remain computed once from the daemon's primary workspace —
they are *machine-level* resources, so
they stay a single global figure, not per-repo. `resolve_registry` (the
per-request `workspace_root` targeting used by `dispatch_sweep` / `list_sweeps` /
etc.) is unchanged: the cross-repo aggregation is a read-only snapshot for
`DaemonStatus` only. A merged `list_sweeps` across all repos without an explicit
`workspace_root` remains a deferred follow-up.

### Per-repo main-health gate (AC2)

The reactive gate was single-repo, single-flag: one `MainHealthState` driven by
one gate check against the daemon's own workspace, applied uniformly to every
registered repo's dispatch (a red `main` in one repo halted all repos; a red
`main` in any *other* registered repo was never even checked). Phase d replaces
the single flag with `WorkspaceHealthStates` — a `HashMap<PathBuf,
Arc<MainHealthState>>` keyed by normalized root (mirroring `WorkspacePool`'s
keying) — and adds `spawn_multi_main_health_gate_task`, which each cycle:

1. Re-reads `effective_roots(&fallback_root)` (hot-applies `workspace add|remove`).
2. Runs **one gate check per registered root**, resolving that root's own
   enablement (`autonomous.mainHealthGate.enabled`, env > config > default) and
   its own `buildGate` block — no new config schema. A root that is
   disabled / has no `buildGate` block is treated as **always-green** (its halt
   flag is cleared and no command runs). Gates run **sequentially** per tick, so
   several minutes-long per-repo builds firing together never contend (each
   `CommandGateRunner` already isolates its own `origin/main` sync + uuid temp
   file).
3. Applies each outcome to that root's own `MainHealthState`.

`work_finder::tick_multi` now takes a `halted: &[bool]` slice parallel to the
workspaces, so a **red repo skips only its own dispatch loop** (its backlog is
still counted in `seen` for logging, and its in-flight sweeps still seed the
shared global occupancy) while sibling repos keep dispatching. The epic supervisor
likewise attaches each cached per-repo supervisor to that root's own
`MainHealthState`. `DaemonStatusReport.main_health_gate_halted` keeps its pre-#3930
meaning (the daemon's own primary workspace); per-repo halt lives in
`per_repo[].health_gate_halted`.

**Empty-registry equivalence**: with a single workspace exactly one root is ever
keyed, so both the status view and the gate cadence/halt semantics reduce to the
pre-#3930 single-workspace behavior byte-for-byte. Enablement is still opt-in
(`LOOM_MAIN_HEALTH_GATE` / `autonomous.mainHealthGate`, precedence env > config >
default); the startup master switch reads the daemon's own workspace config, so
enabling the gate for a genuine multi-repo deployment is done with the machine-
global `LOOM_MAIN_HEALTH_GATE=1` env var (each repo's own `buildGate` block then
decides whether it actually gates).

## Gate verdicts: VERIFIED_RED vs UNEVALUATED (#3974)

A safety gate that fails closed on **its own** infrastructure failures converts
every environmental hiccup into a total dispatch outage — and, for the repo that
contains the gate's own source, into a bootstrap deadlock where the daemon cannot
dispatch the fix for the thing that is broken. Before #3974 *any* non-zero gate
exit (including a timeout, `sh` exit 127 because `cargo` was not on the daemon's
`PATH`, or a spawn failure) was recorded as "main is RED — HALTING".

Every gate run now resolves to exactly one of three outcomes
(`main_health_gate::GateOutcome`):

| Outcome | Meaning | Effect on dispatch |
|---------|---------|--------------------|
| `Green` | command ran to completion, exit 0 | clears any halt |
| `Red` (**VERIFIED_RED**) | command **ran to completion** and reported failure | **halts** this repo's dispatch |
| `Unevaluated` (**UNEVALUATED**) | the gate produced no verdict | **preserves** the previous verdict; logs loudly with the class |

`UnevaluatedClass` names why, and is surfaced in the daemon log and in
`loom-daemon status`:

| Class | Trigger |
|-------|---------|
| `dirty-tree` | non-ignorable local changes; the workspace was never synced |
| `not-on-main` | workspace is on another branch / detached HEAD |
| `local-ahead` | local `main` carries commits `origin/main` lacks (#3912) |
| `git-failure` | a `git` step failed (`rev-parse` / `status` / `fetch` / `rev-list` / `reset`) |
| `timeout` | the gate command exceeded `buildGate.timeoutSeconds` |
| `command-not-executable` | `sh` exit 127 (not found) or 126 (not executable) |
| `killed-by-signal` | terminated by a signal (e.g. an OOM kill) |
| `spawn-failure` | could not spawn the command, or an I/O error while capturing output |
| `contradicted-by-forge-ci` | ran and failed locally, but forge CI is green on the same commit (below) |

The discriminator is deliberately narrow so a genuinely failing build still halts:
**any other non-zero exit is trusted as VERIFIED_RED** — `cargo test`'s 101 for a
failing test still halts dispatch.

### Forge-CI corroboration of a local red

A local run can also fail *because of the host it runs on*: on the incident host
six `integration_basic` tests assert `tmux_session_exists(...)` and fail because
the tmux server is dead, while `.github/workflows/ci.yml` runs the identical
`cargo test --workspace` on the same commit and passes. The local gate measures
**this host**; forge CI measures **the commit**.

So a completed-and-failed run is cross-checked against the forge's CI conclusion
for the exact `origin/main` SHA the gate evaluated (post-sync `HEAD`), via
`gh run list --branch main --json headSha,status,conclusion,workflowName`
matched on `headSha`:

- CI **green** on that SHA → downgraded to `contradicted-by-forge-ci`
  (UNEVALUATED); logged loudly, **does not halt**.
- CI **red** on that SHA → corroborated; still VERIFIED_RED, still halts.
- CI **unknown** → fail safe: still VERIFIED_RED, still halts.

Only *positive* contrary evidence ever relaxes a halt, so "green" is the hardest
verdict to reach and everything short of an unambiguous all-clear degrades to
**unknown**:

| Runs for the evaluated SHA | Verdict |
|---|---|
| any `failure` / `timed_out` / `startup_failure` | red |
| any run not yet `completed` (`queued`, `in_progress`, …) | unknown — CI has not judged the commit yet |
| any `cancelled` / `action_required` / `stale` / unrecognized conclusion | unknown — the workflow reached no verdict about the code |
| at least one `success`, every other run `skipped` / `neutral` | **green** |
| no run for the SHA, unparseable output, `gh` missing/unauthenticated, probe timeout > 30s | unknown |

**Absence of failure is not success.** Requiring at least one genuine `success`
*and* no outstanding or indeterminate sibling run closes two ways a
"saw any completed run ⇒ green" reducer reads green on non-evidence: a
`cancel-in-progress: true` concurrency group leaves superseded runs at
`completed/cancelled` **forever** (a permanent false green for that commit), and a
fast bookkeeping workflow that finishes minutes before the real build would
otherwise vouch for the commit on its own. Neither case needs the probe to know
*which* workflow "counts", so no workflow name is hard-coded.

#### Optional named verification workflow (`LOOM_GATE_CI_WORKFLOW`, #3987)

The unanimity rule above reasons only over *runs that exist*. A workflow a
`paths` / `paths-ignore` filter excluded from a commit produces **no run at all**
(not a `skipped` run), so it is invisible to the reducer. In a **consumer repo**
whose real verification workflow is `paths`-filtered off a commit while only a
fast bookkeeping workflow (line counter, labeler) runs and succeeds, every run is
`completed`/`success` and the reducer above returns `green` for a commit the real
build never judged — relaxing a local red on non-evidence. (Not reachable in this
repo: `.github/workflows/ci.yml` has no `paths` filter, so a `CI` run exists for
every `main` commit.)

The optional `ciWorkflow` knob closes that gap by naming the workflow that
*counts*. It is **unset by default** — absent, behavior is byte-for-byte the
unanimity rule above, so no repo silently changes. Resolution mirrors
`LOOM_MAIN_HEALTH_GATE`, precedence **env > config > default(None)**:

1. `LOOM_GATE_CI_WORKFLOW` env var (empty / whitespace-only ⇒ falls through), or
2. `.loom/config.json` → `autonomous.mainHealthGate.ciWorkflow` (string; empty /
   whitespace ⇒ unset), or
3. absent ⇒ the unanimity rule, unchanged.

When a name **is** configured it layers **one additional requirement on top of**
— never a relaxation of — the unanimity rule: the named workflow must itself have
concluded `success` for the SHA. Matching is **exact and case-sensitive** on
`workflowName`.

| `ciWorkflow` set, runs for the evaluated SHA | Verdict |
|---|---|
| named workflow `completed`/`success`, unanimity otherwise satisfied | **green** |
| named workflow has **no run at all** | unknown — *the gap closure* |
| named workflow `skipped` / `neutral` | unknown (a required workflow that declined did not verify the commit — differs from the unnamed case, where `skipped` does not block green) |
| any run `failure` / `timed_out` / `startup_failure` | red (unchanged, still checked first) |

**Misconfiguration guardrail.** A typo'd name would otherwise pin the gate to
permanent `unknown` (silently recreating #3974 for that repo). When a configured
name appears for **no** SHA anywhere in the probe window, the probe emits a
`log::warn!` naming the configured value and the workflow names actually
observed, then still returns `unknown` (fail safe) — so the cause is visible in
`~/.loom/daemon.log`.

Corroboration is on by default and can be disabled with
`LOOM_GATE_CI_CORROBORATION=0` (for repos with no forge CI or no `gh`); it is only
probed on a local red, never on a green run.

### One shared halt state

`work_finder::tick_multi` derives `TickReport.halted` **directly** from the
`WorkspaceHealthStates` flags the gate writes, rather than accumulating it inside
the candidate-gathering loop. Previously a `list_ready_issues` error short-circuited
the loop *before* its halt check, so a repo whose forge query failed reported
`halted = false` — the incident's `work_finder: main-health gate cleared —
resuming dispatch` logged in the same window the gate logged `still RED`. The two
loops now read one source of truth and cannot disagree.

`loom-daemon status` reports the not-evaluated **cause** verbatim
(`main_health_gate.not_evaluated_reason`, `per_repo[].health_gate_not_evaluated_reason`)
instead of the pre-#3974 hard-coded "workspace tree is dirty", which misreported
timeouts, missing tools, and `git fetch` failures on a clean tree as a dirty tree.

### SHA memoization, `realChangeGlobs`, and indeterminate-run backoff (#3984)

`buildGate.realChangeGlobs` was declared in shipped config but never read
anywhere in `loom-daemon/src/` — the gate re-ran its (potentially
minutes-long) `buildGate.command` on **every** cadence tick regardless of
whether `origin/main` had moved at all. On a contended host that full
compile+test run could not finish inside `buildGate.timeoutSeconds`, the
timeout was correctly classified UNEVALUATED (#3974) and left the previous
halt verdict standing — but the very next tick fired again almost
immediately (the gate's own cadence is far shorter than a realistic build
timeout), so the run competed with itself and with in-flight sweeps for
cores in a self-sustaining doom loop, permanently HALTING dispatch for that
repo.

`spawn_multi_main_health_gate_task` now calls `run_gate_tick` per root per
tick instead of unconditionally constructing a `CommandGateRunner`:

1. **Backoff check** (`MainHealthState::gate_backoff_active`) — if the
   previous tick was UNEVALUATED, the tick is skipped outright while a
   backoff window is active. `record_gate_indeterminate_backoff` grows that
   window exponentially — `buildGate.timeoutSeconds * 2^(consecutive - 1)`,
   capped at `MAX_GATE_INDETERMINATE_BACKOFF` (1 hour) — so a gate stuck on
   a broken `PATH`/dead process tree/contended host waits at least a full
   timeout period (then longer) before retrying, rather than restarting
   immediately. Any determinate (Green/Red) evaluation clears the backoff.
2. **SHA memoization** — a cheap `git ls-remote origin main` (no fetch, no
   working-tree mutation) resolves the current `origin/main` SHA. If it
   equals `MainHealthState::gate_last_evaluated_sha` (the SHA of the last
   determinate Green/Red evaluation, or of a SHA previously reviewed and
   found to touch no `realChangeGlobs` path) the tick is skipped
   unconditionally — an unchanged SHA has no diff at all, so no glob could
   possibly match. This is the common case in the reported incident (`main`
   sat at one SHA with all forge CI green for hours) and is what actually
   ends the doom loop.
3. **`realChangeGlobs` filtering** (`decide_gate_run` /
   `diff_touches_globs`) — when the SHA *has* moved and `realChangeGlobs` is
   non-empty, `git diff --name-only <last>..<current>` is checked against
   the configured glob patterns (`glob_matches`: `*`/`?` wildcards; a
   pattern with no `/` matches by basename anywhere in the tree, e.g. `*.rs`
   matches `loom-daemon/src/main.rs`; a pattern containing `/` matches the
   full repo-relative path). A diff touching no matching path skips the run
   (the previous verdict stands) and still advances the SHA memo, so a
   docs-only merge doesn't retrigger a diff computation on every subsequent
   tick either. An empty `realChangeGlobs` (the default) means *any*
   movement of `main` counts as real — unchanged from pre-#3984 behavior
   once the SHA has actually changed. A diff that cannot be computed (e.g. a
   missing object) fails safe and runs the gate rather than risking a real
   change hiding behind an uncomputable diff.

None of this changes the VERIFIED_RED / UNEVALUATED discriminator (#3974) or
the forge-CI corroboration (above) — it only decides whether the (expensive)
command needs to run again at all before those checks ever see it.

## Per-workspace priority tiers (#3946)

By default the multi-repo work-finder and epic supervisor iterate
`effective_roots()` in **registration order**, so a deep product-repo backlog can
starve the tool repos whose fixes compound. Priority tiers add cross-repo dispatch
ordering:

- **Registry schema** — each `~/.loom/workspaces.json` entry gains an optional
  `priority` integer (`Workspace.priority`, `loom-daemon/src/workspace_registry.rs`):
  **lower = higher priority**, default `100`
  (`DEFAULT_WORKSPACE_PRIORITY`). Fully backward compatible — an entry with no
  `priority` (every pre-#3946 file) deserializes as `100` via `#[serde(default)]`,
  so an all-default registry orders exactly as before.

- **CLI** —
  - `loom-daemon workspace add <path> --priority N` registers a repo in tier `N`
    (default `100`).
  - `loom-daemon workspace set-priority <path> N` retiers an already-registered
    repo.
  - `loom-daemon workspace list` prints a `PRIO` column, sorted highest-priority
    first (mutation order on disk is preserved).

- **Work-finder ordering** — `work_finder::tick_multi` now takes a
  `priorities: &[u32]` slice parallel to the workspaces. Instead of dispatching
  each repo's backlog in registration order, it gathers **every** eligible
  candidate across all workspaces into one queue, sorts it by `candidate_cmp` —
  **(workspace priority asc, `loom:urgent` first, issue age asc/oldest-first,
  issue number asc)** — and fills the single shared concurrency budget in that
  global order. The cap/budget mechanics (#3811/#3930) are unchanged; this only
  orders the queue. `createdAt` is added to the `gh issue list --json` fields for
  the age key.

- **Epic supervisor** — `spawn_multi_supervisor_thread` reorders its cached
  per-repo supervisors by workspace priority each tick (stable within a tier) before
  `tick_multi`, so higher-tier epics advance/dispatch first.

- **Status** — `RepoStatus.priority` is surfaced in the `loom-daemon status`
  **Managed repos** table (a `PRIO` column) and the `--json` `per_repo[].priority`
  field, with the breakdown sorted highest-priority first.

**Starvation stance (v1):** strict priority is intentional — tool repos are small
queues that drain fast. A permanently-full higher tier **will** starve lower tiers;
fairness knobs (per-tier slot reservations) and cross-repo dependency awareness are
explicit follow-ups, deferred until observed to matter.

## Forge-side pipeline snapshot (`status --pipeline`, #3977)

`loom-daemon status` shows the *dispatch*-side picture (in-flight sweeps, the
dynamic cap, token health, per-repo priority/gate state — see the two sections
above), but none of that answers "how is the work actually progressing?" —
that requires forge queries the daemon's IPC handler deliberately does not
make (the `DaemonStatus` round-trip stays a fast, network-free read). The
`--pipeline` flag adds a client-side, opt-in forge-side pipeline snapshot per
managed repo, fetched *after* the IPC round-trip completes:

- **Counts** — for each root in `report.per_repo` (already priority-ordered):
  open `loom:issue` (queued), open `loom:building` (claimed), open PRs by
  `loom:review-requested` / `loom:changes-requested` / `loom:pr`, and PRs
  merged in the last 24h (`gh pr list --state merged --search
  "merged:>=<24h-ago RFC3339>"`).
- **Module** — `loom_daemon::pipeline_snapshot`: `PipelineSource` is the forge
  abstraction (mirrors `work_finder::WorkSource` / `GhWorkSource`),
  `GhPipelineSource` is the `gh`-backed implementation (six `gh` invocations
  per repo, `current_dir(root)` so `gh` auto-detects that repo's own remote —
  same convention as `GhWorkSource::for_root`), and
  `collect_pipeline_snapshots` fans the per-repo fetch out onto Tokio's
  blocking-thread pool so N managed repos cost roughly one repo's worth of
  wall-clock latency.
- **Resilience** — every count is fetched and allowed to fail independently;
  a failed metric renders as `?` (`RepoPipelineSnapshot::error` names the
  first failure) without blocking the other metrics for that repo or any
  sibling repo's snapshot — the same per-workspace error-isolation rule the
  work-finder's `tick_multi` already applies to dispatch.
- **Output** — `loom-daemon status --pipeline` adds a "Forge pipeline" table
  below the existing "Managed repos" table (same row order); `--json
  --pipeline` adds a `pipeline` array (`null` when `--pipeline` was not
  passed, so a consumer can distinguish "not requested" from "requested but
  empty"). Terminal-friendly and safe to `watch -n 60`.
- **Why opt-in** — six `gh` calls per managed repo is too slow to bundle into
  the default view (which is used for frequent, low-latency operator checks);
  `--pipeline` trades that latency for the queue-depth picture on demand.

## Reaper task

The reaper (`sweep_registry::spawn_reaper_task`) ticks every 30 seconds
(env-overridable via `LOOM_SWEEP_REAPER_INTERVAL_SECS`). Each tick:

1. Snapshots live `Running`/`Pending` entries.
2. Tests each PID via `kill(pid, 0)`.
3. On dead PID:
   - If a sweep checkpoint exists at
     `.loom/sweep-checkpoint/issue-<N>.json`, marks the entry `Crashed`
     and flips the forge label `loom:building` → `loom:issue` so the
     next dispatch resumes from the checkpointed phase.
   - Otherwise marks the entry `Exited{code: None}`.
   - Emits `sweep.issue.{N}.exited` or `sweep.issue.{N}.crashed`, plus
     a global `sweep.global.completed` event.
4. Garbage-collects terminal entries older than the retention window
   (default 1 hour).

## Stale-claim reconciliation & the sweep journal (#3953, fixed #3975)

Two independent surfaces reclaim abandoned `loom:building` claims when the
sweep that owned them has died, using the same evidence source and the same
decision rule:

| Surface | Where | When it runs |
|---------|-------|---------------|
| Rust startup reconciliation | `claim_reconciliation::forge::reconcile_workspace` (called from `main.rs` at daemon startup, guarded by `LOOM_STALE_CLAIM_RECONCILE`, default on) | Once, on every daemon start, across every `effective_roots()` workspace |
| Python `loom-recover-orphans` | `loom_tools.orphan_recovery.check_untracked_building` | On demand (operator/cron invocation of `loom-recover-orphans [--recover]`) |

Both read the same machine-level **sweep journal** (`~/.loom/sweeps.json`,
override `LOOM_SWEEPS_JOURNAL_PATH`, written by `sweep_journal::record_sweep`
on every `SweepRegistry::dispatch`) and apply the same three-way decision
rule per `loom:building` issue:

1. **Journal entry with a live recorded PID** → keep (genuinely in-flight).
2. **Journal entry with a dead recorded PID** → reclaim. This is the
   strongest possible evidence — a specific PID that provably no longer
   exists — so both surfaces treat it as authoritative.
3. **No journal entry at all** → reclaim only once the claim has been stale
   longer than `LOOM_STALE_BUILDING_HOURS` (default 4h; also drives the
   Rust-side default `DEFAULT_STALE_BUILDING_HOURS`). Absence of a record
   might mean a live manual `/loom:sweep` the journal was never told about
   (a pre-journal claim, or the journal file just doesn't exist on this
   machine), so a much wider grace window applies than for a claim the
   journal has proof about.

### The #3975 bug: pruning before deciding

The journal is deliberately self-pruning — `sweep_journal::upsert` (every new
dispatch) and the Rust reconciliation pass both call `prune_dead` to drop
dead-PID entries so the file never accumulates an unbounded graveyard
(mirrors `sweep-run-registry.sh`'s `prune_dead`/`peers`, #3768).

Before #3975, `reconcile_workspace` called `prune_dead` **before** calling
`plan()`/`decide()` — which deleted the exact dead-PID entry the `DeadPid`
branch above needs to fire its immediate, unconditional reclaim. With the
entry gone, every claim silently fell through to branch 3 (no record) and
its much longer `stale_hours` grace window, even for a sweep that had *just*
died. Two claims in a downstream workspace (issues #6170/#6173: SIGTERMed
during a daemon restart) sat un-reclaimed for hours because of this —
`loom-recover-orphans --recover` found and fixed only a third, unrelated
claim (#6172) whose label happened to already be older than the stale-hours
threshold. The fix: `reconcile_workspace` now decides against the raw,
unpruned journal first; pruning happens only afterward, via the normal
per-reclaimed-issue `remove_sweep` cleanup (leftover dead entries for
untouched issues are still pruned lazily by the next `upsert` elsewhere).

The Python side (`gather_liveness_evidence` / `check_untracked_building`)
never pruned the journal itself — it only reads whatever the file currently
contains — so it was not directly bugged the same way, but it inherited the
same *symptom*: by the time an operator ran `loom-recover-orphans` by hand,
a routine daemon dispatch (or the (now-fixed) Rust startup pass) had often
already pruned the dead-PID evidence out from under it, leaving only the
weaker "no record" signal to work with.

### Never-silent staleness-gate skips (#3975)

Separately, `check_untracked_building`'s staleness gate (branch 3 above, and
the short `label_grace_period` gate that also applies to branch 2) used to
log its "SKIPPED: #N ..." line **only** under `--verbose`, so a default
(non-verbose) `loom-recover-orphans` run gave no visible trace that a claim
had been seen and excluded — indistinguishable from the tool never having
looked at that issue at all. `OrphanRecoveryResult.watched` now records
every staleness-gated skip (issue, reason, label age, threshold) regardless
of `--verbose`, and both `format_result_human` and `--json` output always
include it. A watched entry is explicitly **not** an orphan — it may still
be alive — but it is never silently dropped.

### One intentional asymmetry: dead-PID grace period

Rust's `decide()` reclaims a `DeadPid` claim **unconditionally** — no
staleness check at all (see `decide_dead_pid_overrides_label_age`). Python's
`check_untracked_building` still applies the short `label_grace_period`
(default 600s) even to a `journal_pid_dead` reason. This is intentional, not
a bug to unify: the Rust pass runs once per daemon *start*, a rarer and more
deliberate event, while the Python tool can be invoked ad hoc (including
immediately after a claim is made, before its journal entry has even been
written) — the short grace period is defense-in-depth against a race the
once-per-restart Rust pass is much less exposed to.

## Stacked-PR dependency — #3729 (v1), #3747 (v2 item 1)

Stacked-PR mode pipelines a genuine dependency: when issue B consumes issue
A's output, B is built on `feature/issue-A` so B's Curator→Builder→Judge runs
concurrently with A's review instead of serializing behind A's merge. **The
dispatch surface is opt-in, daemon-`dispatch_sweep`-only, and
linear-chains-only.**

**Dispatch a chain** — N independent `dispatch_sweep` calls, each naming its
immediate predecessor via `depends_on` (there is no multi-node planner):

```text
dispatch_sweep  kind={"Issue": A}                    # parent (independent)
dispatch_sweep  kind={"Issue": B}  depends_on=A      # child stacked on A
dispatch_sweep  kind={"Issue": C}  depends_on=B      # A→B→C linear chain
```

The daemon forwards `depends_on` to the child as `--depends-on <parent>`; the
child's Builder branches its worktree off `feature/issue-<parent>` (via
`worktree.sh --base`) and opens its PR with `--base feature/issue-<parent>`.
`depends_on` is `Option<u32>` — a **single** optional parent — so diamonds /
multi-parent stacks are structurally unrepresentable (no runtime rejection
needed). It is recorded on the `SweepInfo` entry for observability.

**Block-the-subtree on parent failure (reaper).** When a parent sweep reaches
a terminal state and its issue carries `loom:blocked`, the reaper emits
`sweep.issue.{child}.blocker` on the existing frozen topic (#3453 — no new
topic) for every live child whose `depends_on` names that parent, so the stuck
stack surfaces to the operator and the child does not auto-progress. This is
implemented via `SweepRegistry::children_of` + `block_children_of`. Auto-detach
(rebasing an orphaned child onto the default branch) is **out of scope for v1**.

**Reconciliation is triggered automatically on parent merge (v2 item 1,
#3747).** Because the repo squash-merges, after the parent squash-merges the
child branch still carries the parent's pre-squash commits. `merge-pr.sh` now
fires reconciliation automatically at its post-merge choke point (alongside the
partial-increment label reset, before branch deletion): it discovers open child
PRs via a **live forge query** (`gh pr list --base feature/issue-<parent>` — not
the daemon registry, whose terminal entries are GC'd ~1h after transition and
which only exists when `loom-daemon` is running), then per child splits
safe/unsafe on the child **issue's** `loom:building` label (fresh, uncached `gh
api` read):

- **Safe** (child issue not `loom:building`): invokes
  `./.loom/scripts/reconcile-stack.sh <child-pr> feature/issue-<parent>`
  (`git rebase --onto <default> <parent-branch> <child-branch>` +
  `--force-with-lease` + `gh pr edit --base <default>`).
- **Unsafe** (child issue still `loom:building`): a live Builder likely holds
  the child branch checked out, so the auto-rebase is **skipped** and a comment
  is posted on the child PR flagging deferred reconciliation. A later
  parent-merge-triggered pass (once the issue is no longer `loom:building`), or
  a manual run, picks it up.

The whole step is **best-effort** — a reconciliation failure (rebase conflict,
rejected force-with-lease, retarget failure) is logged as a warning and never
changes `merge-pr.sh`'s exit code (the parent merge already happened). It is
idempotent by construction: once a child's base is retargeted away from the
parent branch, the `--base` query returns zero rows on any re-run.

`reconcile-stack.sh` remains available for **manual** invocation — for the
unsafe/deferred case once the Builder finishes, or for an operator who wants to
reconcile ahead of a merge (`--dry-run` previews the git surgery).

A **pre-merge merge-ordering guard** shipped as v2 item 2 (#3747): because
`delete_branch_on_merge:true` deletes `feature/issue-<parent>` synchronously
during the merge API call — before the post-merge reconcile pass above can run —
`merge-pr.sh` now runs a guard *before* both merge paths that discovers open
child PRs (same `gh pr list --base feature/issue-<parent> --state open` query)
and by default **hard-blocks the merge** (`exit 1`, naming the child PR(s) + the
`reconcile-stack.sh` unblock command) rather than let the parent merge race the
branch deletion. It keys purely on "does an open child PR still target this
branch" (not the child's `loom:building` label). `--allow-stacked-children`
bypasses it; `--dry-run` reports the would-be block without exiting 1.

**Rebase-on-parent-amend** shipped as v2 item 3 (#3747): the standalone
`./.loom/scripts/rebase-stacked-children.sh feature/issue-<parent>` handles the
*pre-merge* case where Doctor amends a still-open stacked parent branch and a
child that branched off its pre-amend tip goes stale. It discovers open child
PRs with the same `gh pr list --base feature/issue-<parent> --state open` query,
detects staleness via `git merge-base --is-ancestor`, and rebases safe stale
children onto the parent's current tip (`git rebase` + `push --force-with-lease`,
base **not** retargeted — the child stays stacked), deferring children whose
issue is still `loom:building` with a comment. Doctor invokes it as a documented
best-effort step after pushing to a `feature/issue-<N>` branch. **Dependency
auto-detection**, **diamonds / multi-parent**, and **auto-detach** remain **out
of scope** (deferred items of the v2 epic #3747).

## Epic supervisor (#3842)

The **epic supervisor** (epic #3842) drives every open `loom:epic` issue
through a fork-join lifecycle autonomously. It runs as an opt-in loop on a
**dedicated OS thread** with its own current-thread Tokio runtime (`#3872`) —
never `tokio::spawn` on the shared daemon runtime — because each transition can
block on a minutes-long role process (`Command::status()`) while holding the
#3707 issue-creation mutex. Keeping that blocking call off the shared runtime
preserves the responsiveness of the event bus, reaper, sweep registry, and IPC
listener.

Enable it with `LOOM_EPIC_SUPERVISOR=1` (unset/false-y = OFF). Tunables:
`LOOM_EPIC_SUPERVISOR_INTERVAL_SECS` (default 300) and
`LOOM_EPIC_INFLIGHT_TTL_SECS` (default 900).

### Derived-state model

Rather than mint new GitHub labels per phase, all five supervisor states ride
the single `loom:epic` label and are **derived** — computed each tick from two
already-visible facts: the number of `### Phase` sections in the epic body, and
the open/closed status of the epic's `loom:epic-phase` children. The five states
(implemented as `EpicState` in
[`loom-daemon/src/epic_state.rs`](https://github.com/rjwalters/loom/blob/main/loom-daemon/src/epic_state.rs)
(upstream Loom repo — not shipped to consumer installs)) mirror
the `derived=True` epic lane of the authoritative Python model
([`loom-tools/src/loom_tools/state_machine.py`](https://github.com/rjwalters/loom/blob/main/loom-tools/src/loom_tools/state_machine.py)
(upstream Loom repo — not shipped to consumer installs),
#3841):

| Derived state | Condition | Enabled transition |
|---------------|-----------|--------------------|
| `epic:needs_decomp` | body has `< 2` `### Phase` sections | **decompose** — Architect enriches the body in place (no PR) |
| `epic:designed` | `≥ 2` phases, no `epic-phase` children yet | **expand** — Champion materializes phase-1 children (under the #3707 mutex) |
| `epic:active` | a current-phase child is open | per-child `/loom:sweep` dispatch (`BuildChildren`) |
| `epic:phase_join` | current phase's children all closed, more phases remain | **join** — Champion materializes phase N+1 children (mutex + barrier-gated) |
| `epic:done` | all phases' children closed, no phases remain | **close** — Champion closes the epic (terminal) |

### Transition table + phase-join barrier

The five intra-lane edges among the derived states — the "epic transition
table" — are declared explicitly in `epic_state::epic_transition_table()`:

```text
epic:needs_decomp → epic:designed    (Champion, creates_issues)   [decompose]
epic:designed     → epic:active      (Champion)                   [expand]
epic:active       → epic:phase_join  (Supervisor, barrier)        [fork-join]
epic:phase_join   → epic:active      (Supervisor, barrier)        [join/advance]
epic:phase_join   → epic:done        (Supervisor, barrier)        [close]
```

Every edge touching `epic:phase_join` is a **phase-boundary edge** and declares
a non-empty fork-join barrier
([`loom-daemon/src/phase_join.rs`](https://github.com/rjwalters/loom/blob/main/loom-daemon/src/phase_join.rs)
(upstream Loom repo — not shipped to consumer installs)): the
barrier holds — degrading the plan to a no-op — until every child of the current
phase is closed, so phase N+1 (or epic close) never fires while a current-phase
child is still open.

The lane-*entry* edge `new → epic:needs_decomp` (an Architect filing a
`loom:epic` proposal) is **not** part of the supervisor's table — the supervisor
begins its lifecycle at `epic:needs_decomp`.

**Conformance.** The Rust transition table is asserted faithful to the Python
model by
[`loom-daemon/tests/epic_conformance.rs`](https://github.com/rjwalters/loom/blob/main/loom-daemon/tests/epic_conformance.rs)
(upstream Loom repo — not shipped to consumer installs),
which **derives** its expectation by invoking
`python3 -m loom_tools.state_machine --json` and comparing the emitted epic
sub-graph (states, edges, roles, barriers, `creates_issues`) against the Rust
table — rather than hardcoding a mirrored copy that would silently drift. The
test skips gracefully when `python3` is unavailable.

### #3707 issue-creation mutex

The two issue-creating expand bursts (`decompose`'s downstream and both
`expand`/`join` Champion dispatches that run `gh issue create`) are serialized
through the global **#3707 issue-creation mutex**
([`loom-daemon/src/issue_creation_mutex.rs`](https://github.com/rjwalters/loom/blob/main/loom-daemon/src/issue_creation_mutex.rs)
(upstream Loom repo — not shipped to consumer installs)).
The supervisor holds the async guard across the whole (spawn-and-wait) dispatch
so a burst never interleaves with any other issue-creating burst anywhere in the
daemon. All epic expands share the single `CHAMPION_EPIC_DECOMP` serialization
identity.

### Event topics

Each of the four singleton action-class transitions publishes an
`epic.issue.{N}.{action}` event on the shared event bus when it fires, so the
supervisor's decisions are tailable via `subscribe_to_events` /
`tail_event_bus`:

| Topic | Fires from | Payload |
|-------|-----------|---------|
| `epic.issue.{N}.decompose` | `epic:needs_decomp` | `{epic, action: "decompose", state: "epic:needs_decomp"}` |
| `epic.issue.{N}.expand`    | `epic:designed`     | `{epic, action: "expand", state: "epic:designed"}` |
| `epic.issue.{N}.join`      | `epic:phase_join`   | `{epic, action: "join", state: "epic:phase_join"}` |
| `epic.issue.{N}.close`     | `epic:done`         | `{epic, action: "close", state: "epic:done"}` |

The `BuildChildren` transition (per-child `/loom:sweep` dispatch) has **no**
epic-action topic — those dispatches already surface on the frozen
`sweep.global.dispatch` topic. Subscribe to `epic.issue` to receive every
epic-supervisor action across all epics, or `epic.issue.{N}` for one epic
(segment-aligned prefix match, same routing rule as the sweep topics).

## Autonomous work finder (#3810)

The **work finder** (Phase A of epic #3809,
[`loom-daemon/src/work_finder.rs`](https://github.com/rjwalters/loom/blob/main/loom-daemon/src/work_finder.rs)
(upstream Loom repo — not shipped to consumer installs)) is the
daemon-native poller that turns a human-approved `loom:issue` into a dispatched
build **without an operator** — restoring the one capability the deleted v0.10.0
shepherd brain had that the daemon rebuild never replaced. It is **opt-in and
off by default**: unset `LOOM_WORK_FINDER` and the daemon's behavior is
byte-for-byte unchanged (the only sweep entry point remains the explicit
`DispatchSweep` IPC request).

Unlike the epic supervisor, the work finder runs as a plain `tokio::spawn`
interval task on the **shared daemon runtime** (the same footing as the reaper),
not a dedicated OS thread. Every call into `SweepRegistry::dispatch()` returns
promptly (fire-and-forget child spawn), so the loop never parks a runtime worker
in a long blocking call — the OS-thread machinery the epic supervisor needs for
its minutes-long spawn-and-wait role dispatches is unnecessary here.

Each tick:

1. Queries the forge for ready work — `gh issue list --label loom:issue --state
   open --limit 200 --json number,labels` (honoring `LOOM_REPO` for `--repo`).
2. Filters out issues that are **already in flight** (a live `Running` /
   `Pending` entry in the sweep registry — the authoritative dedup, robust to
   `loom:issue → loom:building` label-flip lag) or that defensively carry any
   skip label (`loom:building` / `loom:blocked` / `loom:operator-only`).
3. Dispatches the remainder through the existing `SweepRegistry::dispatch()`
   path — up to a **work-driven dynamic cap** (Phase B, #3811) recomputed every
   tick and counted against the current live sweep occupancy. `dispatch()`
   already flips `loom:issue → loom:building`, acquires the per-issue
   `mkdir`-atomic claim lock, and spawns the rotated-token child, so the finder
   reimplements none of the race guard. Each dispatch uses a
   `workfinder-<issue>` idempotency key, making a re-dispatch of an
   already-running issue a no-op.

### Dynamic concurrency scaling (Phase B, #3811; CPU/load term #3978)

The concurrency cap is **not** a fixed value resolved once at startup. Every
tick the finder recomputes

```
dynamic_cap = min(healthy-token count × per-token concurrency, disk headroom, cpu/load headroom, configured ceiling)
```

from live inputs, so pool/disk/cpu/backlog changes are honored without a
daemon restart:

| Input | Source | Bound it enforces |
|-------|--------|-------------------|
| **healthy-token count** | `available` accounts in `{workspace}/.loom/tokens/.ranking` (`capacity::token_axis_limit`), falling back to the `*.token` count (`tokens::token_pool_size`) when no ranking exists | the count of accounts safe to dispatch to — never dispatch to an exhausted/blocked one (#3902) |
| **per-token concurrency** | `LOOM_PER_TOKEN_CONCURRENCY` / `autonomous.perTokenConcurrency`, default **2** (#3947) | how many concurrent sweeps to allow **per healthy account**. A plan limit is a utilization-window token bucket, not a session count, so one healthy account can run several concurrent sessions. Before #3947 the implicit factor was `1` (one sweep per account), which collapsed the whole fleet to cap 1 when 6/7 accounts were at their weekly ceiling even though the single healthy account had ample session-window headroom |
| **disk headroom** | `floor(free_gb / LOOM_PER_WORKTREE_GB)` on the worktree-root volume (`disk_headroom::disk_headroom_limit`, a Rust port of `disk-headroom.sh` that shells to `df -Pk`) | never provision more worktrees than the scratch volume can hold |
| **cpu headroom** (#3978, measured-idle signal #4031) | `max(1, floor((logical_cpus × LOOM_CPU_UTILIZATION_TARGET − consumed_cores) / LOOM_EST_CORES_PER_SWEEP))`, where `consumed_cores = logical_cpus × (1 − idle_fraction)` from the measured idle fraction (loadavg fallback) (`cpu_headroom::cpu_headroom_limit`) | never start more concurrent sweeps than the host's CPU headroom can currently absorb |
| **configured ceiling** | `LOOM_WORK_FINDER_MAX_CONCURRENT` (repurposed from Phase A's fixed target into an operator ceiling) | hard operator upper bound regardless of token/disk/cpu headroom |

**CPU headroom term (#3978, measured-idle signal #4031).** The token and disk
axes alone let a batch of token accounts resetting from `exhausted` to
`available` at once raise the cap regardless of how many concurrent `cargo
build`s were already saturating the host — the incident this term fixes: 2–3
concurrent Rust builds in sweep worktrees starved `build-gate.sh` of CPU badly
enough that it hit its own 600s timeout, which the (separately-fixed, #3974)
gate misreported as a verified-red `main`, halting all dispatch.
`cpu_headroom_limit()` combines a **static** capacity (`logical_cpus ×
utilization_target`, default target `0.75` — leaves headroom for the OS, the
daemon itself, and the gate's own `cargo` invocations) with the cores
**currently consumed**, subtracted from that capacity, divided by an estimated
per-sweep core cost (`LOOM_EST_CORES_PER_SWEEP`, default `2.0`).

*Consumed cores come from a measured idle fraction, not the load average
(#4031).* The original #3978 term used the 1-minute load average as a stand-in
for consumed cores. On macOS that overstated consumption by ~1.5× — an observed
idle-but-loaded host read `load1m ≈ 6–7` alongside 76–86% CPU idle on 28 cores
(only ~4–7 cores actually consumed). Load average counts threads in the
runnable **and** uninterruptible-sleep states, and this daemon's workload is
dominated by `claude` sessions **blocked on network I/O**, which inflate load
without consuming a core — pointing the feedback loop the wrong way (more
concurrent sweeps → more blocked `claude` → higher load → *lower* cap, while
CPU sat idle). The term now derives `consumed_cores = logical_cpus × (1 −
idle_fraction)` from a measured idle fraction, **per-platform**:

- **Linux** deltas two reads of the aggregate `cpu` line in `/proc/stat`
  (`idle + iowait` vs total), memoizing the previous cumulative sample and
  deltaing **across ticks** — nothing sleeps.
- **macOS** shells to `iostat -c 2 -w 1 -n 0` and reads the **second** data
  line (a genuine 1-second delta; the first is cumulative since boot). That
  1-second wait is moved to `spawn_blocking` at the async call sites and
  **memoized** behind a ~10s TTL (`CPU_UTIL_MEMO_TTL`) shared with the
  synchronous `ipc.rs` status path, so a runtime worker is never blocked and a
  status request + a work-finder tick never each pay the full second.

The signal chain is **fail-open**: `measured idle fraction → 1-minute load
average → static capacity`. An unreadable idle signal (missing `/proc/stat` or
`iostat`, unsupported platform, or no delta sampled yet) falls back to the load
average (#3978's behavior); an unreadable load average falls back to the static
capacity, unadjusted. Like the token axis's "one healthy account is the floor,
never a halt" policy (#3902), the CPU term is floored at `1` — a read failure or
a noisy reading must never by itself wedge the whole dynamic cap to zero; disk
headroom and the token axis remain the only terms allowed to floor to a genuine
`0`. Tunable with the standard precedence **env (`LOOM_CPU_UTILIZATION_TARGET`
/ `LOOM_EST_CORES_PER_SWEEP`) > config (`autonomous.cpuUtilizationTarget` /
`autonomous.estCoresPerSweep`) > default (`0.75` fraction / `2.0` cores)**
(#4032) — resolved single-root, at startup, from the same
`WorkFinderConfig`/`read_work_finder_config` that `perTokenConcurrency` uses
(not per-workspace: the dynamic cap is one global number per tick, computed
before the workspace registry is even loaded). An out-of-range or
wrong-JSON-type config value (`cpuUtilizationTarget` outside `(0, 1]`,
`estCoresPerSweep <= 0`, a string/bool/null where a number is expected) is
dropped to `None` at the config-read layer, not clamped, so it falls straight
through to env/default resolution.

**`LOOM_PER_WORKTREE_GB` deliberately stays env-only (#4032 decision).**
Unlike the CPU knobs, `disk_headroom`'s `LOOM_PER_WORKTREE_GB` was *not*
migrated to the same `autonomous.*` pattern. It has a second, independent
Bash-side reader (`defaults/scripts/lib/disk-headroom.sh`, consumed by
`/loom:sweep` Stage -1 wave sizing) alongside the Rust
`disk_headroom::per_worktree_gb`. Migrating only the Rust side would create a
live divergence where the same env var honors `.loom/config.json` on the
daemon path while silently ignoring it on the sweep path — worse than today's
consistent env-only behavior. Wiring the Bash `config-resolver.sh` into
`disk-headroom.sh` too is a separate, larger change; file a follow-up if that
cost is judged worth paying.

*Calibrating `LOOM_EST_CORES_PER_SWEEP`.* The host-side half of the term
(consumed cores) is now measured continuously and needs no tuning. The one
remaining constant — how many cores one concurrent sweep consumes during its
build/test step — is a per-repo/host property. Its default (`2.0`) is **not**
changed here absent a real multi-sweep measurement; a reproducible recipe lives
at [`docs/measure-est-cores-per-sweep.md`](https://github.com/rjwalters/loom/blob/main/docs/measure-est-cores-per-sweep.md)
(upstream Loom repo — not shipped to consumer installs)
so an operator can calibrate it on a live fleet without re-opening the code.

**The release-build fan-out footgun (#4234, decomposed from #4231).** `2.0` is
calibrated against `cargo check`/`clippy`/debug-build sweep phases (#4031), not
a **release** build: `cargo build --release` parallelizes codegen units across
essentially every logical core, so a release-build-heavy repo's real per-sweep
consumption can run much closer to `logical_cpus` than `2.0`. The #4231 host
meltdown (a 6-way sweep fan-out that drove load to 118 on a 28-core host) is
the concrete failure mode: at the shipped default, six concurrent
release-building sweeps look like `6 × 2 = 12` cores of demand to the cpu
headroom term when the real demand is far higher. Raise
`autonomous.estCoresPerSweep` well above `2.0` — plausibly toward
`logical_cpu_count()` itself — for a repo whose sweeps spend meaningful wall
clock in a release build. The knob is resolved **once at daemon startup**
(env > config > default, #4032), the same startup-capture as every other
dynamic-cap knob; a live re-tune takes effect on the next daemon restart, not
mid-run. #4234 adds a second, independent backstop for exactly this
under-estimate — see the next section.

#### Per-tick admission (ramp) cap (#4234)

`resolve_dynamic_max_concurrent` is a **live** ceiling, recomputed every tick,
so it can *jump* tick-to-tick — e.g. several exhausted token accounts resetting
at once raises the token axis from ~2 to ~14, or a miscalibrated
`estCoresPerSweep` (previous section) makes the cpu axis look larger than the
host can actually sustain. Before #4234, a jump like that let a **single tick**
admit every newly-eligible candidate up to the new, larger cap in one shot.
Load average / measured idle fraction is a **lagging** signal sampled at
wave-*start*: a burst admitted together all ramp their builds minutes later,
well after the tick that "safely" admitted them observed a still-quiet host.
This is the exact failure mode of the #4231 incident's second wave — the host
re-spiked at 01:41 after load had already dropped to 8, because the admission
decision had already been made by the time load caught up.

`autonomous.workFinder.maxAdmissionsPerTick` (`LOOM_WORK_FINDER_MAX_ADMISSIONS_PER_TICK`,
default **3**, mirroring `maxConcurrent`'s default) bounds how many **new**
sweeps a single tick may admit, **independent of** `max_concurrent` — the two
caps are separate and both apply (`tick_report.deferred_capacity` counts
candidates deferred by the concurrency ceiling, `tick_report.deferred_ramp_cap`
counts candidates deferred by this ramp cap; either alone can defer a
candidate, and both fire in the same tick when both bind). A large cap jump
therefore ramps up over several ticks instead of bursting in one — each
subsequent tick re-samples CPU/disk/token headroom fresh, so a ramp that turns
out to be too aggressive self-corrects within one interval (default 60s)
rather than in one uncontrolled burst. Resolved with the standard precedence
**env > config > default**, single-root, at daemon startup — the same
startup-capture pattern as `cpuUtilizationTarget`/`estCoresPerSweep`: the ramp
cap's whole purpose is to smooth admission *within* the live per-tick
re-computation of `max_concurrent`, so the knob itself does not need to be
live; retuning it takes effect on the next daemon restart.

#### `dispatch_sweep` headroom advisory (#4234)

Before #4234, the dynamic cap above only gated the autonomous work finder's
**own** dispatches — the `dispatch_sweep` IPC/MCP handler (the entry point for
`mcp__loom__dispatch_sweep`, `loom-daemon dispatch`, and any other
operator-driven fan-out) dispatched directly with **no** headroom consult at
all. Any operator- or MCP-driven `dispatch_sweep` call was completely ungated;
the #4231 6-way fan-out that triggered the host meltdown was dispatched through
exactly this handler.

The fix is **advisory-first**, matching `capacity.rs`'s token-backpressure
"never a halt" precedent (#3902) rather than adding a hard-defer/`force`
protocol change: `dispatch_sweep` **always dispatches** — an explicit
operator/MCP request is a deliberate act, and the work finder's own dynamic
cap remains the hard backstop for *its own* autonomous dispatches — but now
computes the same `resolve_dynamic_max_concurrent` headroom the work finder
uses (token/disk/cpu/configured-max, scoped to the target repo) and, on a
**state change** into/out of "occupancy at or over that headroom" for that
repo, logs a warning and publishes a `daemon.dispatch.headroom_advisory`
event-bus event (state-change-deduped — never a per-call stream, keyed
per-repo so a multi-workspace daemon's repos don't cross-suppress each
other's advisories). This required **zero protocol change**: no new
`Request::DispatchSweep` field, no new `Response` variant — the advisory is a
side channel exactly like the token-capacity advisory. Every `dispatch_sweep`
call's log line additionally always names the current occupancy/dynamic-cap
axes (not just on the deduped transition), so `RUST_LOG=loom_daemon=info`
shows the same headroom picture the work finder's own tick log shows, without
duplicating the `cpu_headroom_snapshot`/`disk_headroom_limit` plumbing
`loom-daemon status` (`build_daemon_status`) already exposes.

The handler never calls the **refreshing** CPU probe
(`cpu_headroom::cpu_headroom_limit`, which sleeps ~1s on macOS via `iostat`)
while holding the sweep-registry mutex — doing so would stall every other IPC
request scoped to the same registry for that second. It uses the
**non-refreshing** `cpu_headroom::cpu_headroom_snapshot` (the memoized idle
fraction; never blocks) instead, the same call `build_daemon_status` makes.

**Per-token concurrency factor (#3947).** The token axis is `healthy × factor`,
not `healthy × 1`. The factor is resolved with the standard precedence **env
(`LOOM_PER_TOKEN_CONCURRENCY`) > config (`autonomous.perTokenConcurrency`) >
default (2)**; a zero/unparseable value at any layer is ignored, and the cap
formula additionally clamps the factor to a floor of `1` so a mis-set `0` degrades
to the pre-#3947 one-sweep-per-account behavior rather than dispatching nothing.
Bounded **stacking**, not a 1:1 hard limit, is the correct response to a healthy
account with session-window headroom — the #3909 rotating selection spread still
fills **distinct** accounts first (via the persistent `.rotation_cursor`), only
stacking multiple sweeps on one account when concurrency demand exceeds the
healthy-account count. The `loom-daemon status` view spells the arithmetic out,
e.g. `= min(healthy 1 × per-token 2 = 2, disk headroom 120, cpu headroom 6,
configured max 3)`, and a separate line reports the live core-count detail
feeding the cpu headroom term — naming which signal actually fed it, e.g.
`cpu headroom: 8 concurrent-sweep slot(s) (28 logical cores, 85% idle measured
(≈4.2 cores consumed))`, or a `1m loadavg …` / `static capacity only` line when
falling back (#3978 AC4; measured-idle signal #4031).

**"Currently binding" vs "smallest ceiling" (#4031).** The dynamic cap is the
*minimum* of several ceilings, but a ceiling only *binds* once in-flight
occupancy reaches it. Below the cap the limiter is simply how much ready work
exists, not any resource term — so the status view gates its bottleneck
diagnosis on real occupancy (`in_flight.len() >= dynamic_cap`, surfaced as the
`capacity_bound` field, `#[serde(default)]`). With in-flight below the cap it
prints `not capacity-bound (N in flight, cap M — the limiter is work
availability, not tokens/disk/CPU)` and **suppresses** the `token-bound:`
diagnosis line; at or above the cap it names the binding term as before. The
`= min(…)` breakdown line is untouched — those genuinely are ceilings. The JSON
status carries the same `capacity_bound` boolean so scripted consumers aren't
misled at low occupancy either.

**Session-limit fault handling (#3947).** Stacking can occasionally trip a
**concurrent-session-limit** fault on a token (the account is healthy but cannot
start another *simultaneous* session right now). This is a **capacity** signal,
not quota exhaustion, so `classify-error.sh` classifies it distinctly as
`SESSION_LIMIT` (checked *before* `TOKEN_EXHAUSTED` so the "session limit" wording
is not swallowed by the exhaustion regex). `claude-wrapper.sh` responds by
re-selecting a **different** account and retrying **without** appending the
current token to `.bad_tokens` — a capacity fault must never poison the healthy
pool. Re-selection advances the rotation cursor so a healthy sibling is preferred,
which backs off stacking for the saturated account; a bounded
`LOOM_MAX_SESSION_LIMIT_RETRIES` (default 10) guards a fully-saturated pool from
spinning, after which it falls through to normal transient backoff (still without
marking the token bad).

The **effective** per-tick concurrency is then `min(dynamic_cap, backlog_depth)`:
`tick()` iterates the ready `loom:issue` rows and stops at the cap, so
concurrency **scales up** as the backlog grows and drains to **zero** dispatches
when the queue is empty (no capacity is pre-reserved and no idle workers are
spawned). A token pool of 0 (rotation not bootstrapped) yields a cap of 0 —
the finder dispatches nothing, matching `spawn-claude.sh`'s `EX_CONFIG`
hard-fail on a missing pool. The `df` probe runs once per tick and is negligible
on the 60s default interval. Bad-token-aware pool counting (subtracting
`.bad_tokens` entries) is a tracked follow-up; the first pass counts `*.token`
files.

The loop is **idempotent** (an issue already in the registry is never
re-dispatched) and **fail-safe**: a forge-query error aborts only that tick
(logged, retried next tick) and a single dispatch error is logged and counted,
never crashing the daemon. Dispatches surface on the frozen
`sweep.global.dispatch` topic (emitted inside `dispatch()`); the finder adds no
new event topics.

Enable it with `LOOM_WORK_FINDER=1` (unset/false-y = OFF) **or** from committed
config (`autonomous.workFinder.enabled`, see "Operability" below). Tunables:
`LOOM_WORK_FINDER_INTERVAL_SECS` (default 60 — tighter than the epic
supervisor's 300s so the `loom:issue` backlog drains promptly),
`LOOM_WORK_FINDER_MAX_CONCURRENT` (default 3 — the operator **ceiling** in the
dynamic policy above, not a fixed target), `LOOM_PER_TOKEN_CONCURRENCY` (default 2
— the per-healthy-token concurrency factor of the cap, #3947), and
`LOOM_PER_WORKTREE_GB` (default 2 — the per-worktree disk estimate the
disk-headroom bound divides by). A zero or
unparseable value for any of these falls back to its default.

> **Scope note**: the work finder dispatches **already-approved** `loom:issue`
> items; it does **not** generate new work. Architect/Hermit work-generation
> cadence remains out of scope (follow-up #3381). So "the daemon does not
> generate work" below still holds — the finder only closes the gap between an
> approved issue and its build.

**Occupancy: startup-proof grace, distinct from the startup watchdog (#4003).**
A dispatch slot is checked out (counted as occupied) the instant
`SweepRegistry::dispatch()` returns — i.e. at `fork/exec` success, before the
child has proven it reached the API, created a worktree, or wrote a
checkpoint. Before #4003 that slot stayed occupied for the sweep's entire
`Running`/`Pending` lifetime regardless of whether the child ever showed a
sign of life, so a child wedged at startup (e.g. a hung MCP-init) held its
slot for the full 300s startup-watchdog window
(`sweep_registry::DEFAULT_WATCHDOG_TIMEOUT_SECS`) before anything reclaimed
it.

`SweepRegistry::occupied_issues()` (consumed by `RegistryDispatcher::occupancy`,
which `tick`/`tick_multi` now use to seed occupancy instead of
`in_flight().len()`) narrows that: a sweep still counts while it is inside its
**startup-proof grace window** (`elapsed < grace` — a fresh dispatch legitimately
has produced nothing yet) *or* once it has proven startup progress. Progress
reuses the exact signal the startup watchdog already polls
(`sweep_made_progress` — a worktree at `.loom/worktrees/issue-<N>`, a checkpoint
at `.loom/sweep-checkpoint/issue-<N>.json`, or log output past the spawn header,
see `log_has_progress`) and latches through the SAME per-`SweepId`
`watchdog_progressed` set the watchdog itself maintains, so a signal observed by
either mechanism is remembered by both. A sweep older than `grace` with **zero**
proven signal is excluded from occupancy — freeing its slot for a healthy
queued sweep — while the sweep's own `SweepState` stays `Running` untouched:
this is occupancy accounting only, never a cancel/re-dispatch action. (De-dup
safety — never double-dispatching the SAME issue — still comes from
`in_flight()`, the registry's claim lock, and the forge `loom:building` label,
none of which this change touches.)

The grace window (default **90s**, `DEFAULT_STARTUP_PROOF_GRACE_SECS`) is
deliberately much shorter than the 300s watchdog timeout: the watchdog's 300s is
sized to the measured 110–150s dispatch→**worktree** latency under concurrency
(#4088), a late, heavy signal, while `log_has_progress` fires far earlier — the
instant Claude Code itself produces any output past the spawn header, typically
within seconds even under contention. Tunable per workspace with the standard
precedence **env (`LOOM_SWEEP_STARTUP_PROOF_GRACE_SECS`) > config
(`autonomous.watchdog.startupProofGraceSecs`) > default (90)**, resolved the same
way as `dispatch_stagger` (`SweepRegistry::set_startup_proof_grace`, set once per
workspace at provision time by `main.rs` / `WorkspacePool::get_or_provision`).
`SweepRegistry::unproven_startups()` is a read-only diagnostic (no latch
mutation from the read itself; observes the same latch) returning
`(issue, time_since_dispatch)` for every live sweep that has not yet proven
startup — for status/observability, not for gating.

### Token-capacity backpressure (#3902)

At scale, rotation accounts hit their 5h/7d rate limits and go `exhausted`.
Dispatching to an exhausted account produces startup hangs / mid-build deaths, so
the finder treats a genuine token limit as a **capacity signal** — slow down,
alert, recover — all automatic and non-blocking:

1. **Slow down (backpressure).** The token axis of the dynamic cap is the count
   of **healthy** (`available`) accounts read from `.loom/tokens/.ranking`
   (`capacity::token_axis_limit`), not the flat `*.token` count. When accounts go
   exhausted the cap backs off toward the healthy count; when *every* account is
   exhausted it drops to 0 and the finder **defers** the queue rather than
   hammering an exhausted account. A single healthy account is the throughput
   **floor**, never a halt. When no `.ranking` file exists (no probe has run) the
   axis falls back to the raw pool size — byte-for-byte the pre-#3902 behavior.
2. **Alert (add capacity).** When the token axis is the *binding* constraint
   (≤ disk and ≤ ceiling) and work is queued behind it, the finder is
   *token-bound*. On the **state change** into that state it emits an
   add-capacity advisory naming concrete levers — add accounts to
   `~/.claude-monitor/accounts.env` + `loom-tokens bootstrap`, or buy API
   credits, then re-probe with `loom-tokens check --ranking` — with the current
   numbers (queued count, healthy/total accounts, exhausted count, estimated
   drain time at current capacity). If accounts are `blocked` on revoked tokens,
   `bootstrap --force` cannot recover — the advisory also names
   `loom-tokens import-from-monitor --force && loom-tokens check --ranking` as
   the recovery lever for that case. The advisory surfaces on **three**
   channels: the daemon log (`warn`), the `daemon.capacity.advisory` event-bus
   topic, and the `capacity` section of `loom-daemon status`. It is
   **deduplicated** — one advisory on entry, one recovery on exit, never
   per-tick spam. Advisory only; it never blocks dispatch.
3. **Recover.** The finder re-reads the ranking every tick (bounded cadence = the
   tick interval), so as accounts reset to `available` the cap ramps back up and
   the queued `loom:issue` backlog drains automatically — no manual intervention.
   A symmetric recovery line/event fires on the way out of the pressured state.

The `estimated_drain_minutes` figure is a coarse `ceil(queued / healthy) ×
NOMINAL_SWEEP_MINUTES` (30 min nominal) aid, not a precise SLA — the daemon does
not track live per-sweep durations here. Near-ceiling granularity is limited to
the `.ranking` discrete status word (`exhausted` is already ≥ 0.95 utilization);
a finer sub-exhausted (≥ 0.90) bucket would read the richer `loom-tokens check
--json` utilization and is a tracked follow-up. Even rotation/staggering of
dispatches across the available account set (so 5h/7d windows reset in a
staggered pattern) lives in the spawn-time selector (native `loom-daemon tokens
select`, `loom-daemon/src/tokens_pool/select.rs` — cut over from
`loom_tools.tokens.select` in #4228), not the daemon's own dispatch loop, and is
a separate follow-up.

## Operability — config, start/stop, E2E (Phase D, #3813)

> **Machine-level `loom` dispatcher (Epic #3835 Phase 3a #4157, Phase 3b #4229).**
> A machine-level `loom` entry point at `~/.local/bin/loom` (sibling of
> `~/.local/bin/loom-daemon`) resolves the `~/.local/share/loom` checkout and
> exec's into it — `loom start|stop|restart|status|sweep|update`. It is distinct
> from the per-repo tmux agent-pool manager `./.loom/bin/loom`; the
> name-collision resolution, checkout layout, and the thin-`update` boundary
> are documented in [`machine-dispatcher.md`](machine-dispatcher.md). Every
> delegating verb hands its lifecycle-script delegate
> (`loom-daemon-start.sh`/`-stop.sh`/`-update.sh`) the resolved checkout via
> `LOOM_MACHINE_CHECKOUT`, so the plist `WorkingDirectory` and the
> `.daemon.pid`/`.daemon.flags`/startup-log home resolve consistently —
> `$HOME/.loom`, not a `$PWD`-derived repo — regardless of which directory
> `loom` was invoked from (#4229). Direct invocation of a lifecycle script (no
> dispatcher) is unaffected: the pre-#4229 `$PWD`-based `find_repo_root()`
> contract remains the fallback, unchanged.

Phases A–C built the autonomous *engine* (work finder, dynamic concurrency,
main-health gate) as env-var-only surfaces. Phase D (#3813) adds the
operator-facing layer: a committed config surface, safe start/stop wrappers for
the raw daemon process, and a documented end-to-end acceptance playbook.

### Config surface (`.loom/config.json → autonomous`)

Autonomous mode can be enabled and tuned entirely from committed config — no env
vars required — so a repo can declare "this workspace runs autonomous mode with
concurrency ceiling 5" and share it with the team:

```json
{
  "autonomous": {
    "model": "sonnet",
    "perTokenConcurrency": 2,
    "cpuUtilizationTarget": 0.75,
    "estCoresPerSweep": 2.0,
    "workFinder": {
      "enabled": true,
      "intervalSecs": 60,
      "maxConcurrent": 5,
      "maxAdmissionsPerTick": 3,
      "quarantine": {
        "enabled": true,
        "threshold": 3,
        "ttlSecs": 3600,
        "instaCrashSecs": 60
      }
    },
    "hostBreaker": {
      "enabled": true,
      "loadPerCoreTrip": 2.5,
      "sustainTicks": 3,
      "cooldownSecs": 300
    },
    "mainHealthGate": {
      "enabled": true
    },
    "roleRunner": {
      "enabled": true,
      "roles": ["champion", "curator", "judge", "auditor", "guide"],
      "intervalSecs": 300
    },
    "watchMonitor": {
      "enabled": true,
      "intervalSecs": 120,
      "expirySecs": 86400
    },
    "heartbeat": {
      "enabled": true,
      "intervalSecs": 60
    },
    "dispatchStaggerMs": 2000,
    "watchdog": {
      "enabled": true,
      "timeoutSecs": 300,
      "intervalSecs": 30,
      "reviewStall": true,
      "reviewStallTimeoutSecs": 2700
    }
  }
}
```

**Precedence is `env var > config value > built-in default` for every knob.** An
operator env var still overrides the committed config for a single run
(`LOOM_WORK_FINDER=0 loom-daemon` disables the loop even if config enables it).
An **absent `autonomous` block is byte-for-byte identical to the pre-#3813
env-only behavior** — the config read soft-fails (missing file / malformed JSON /
missing block all resolve to "no config value → fall through to env/default"),
exactly like `main_health_gate::read_build_gate_config`.

| Config key | Env override | Default | Notes |
|------------|--------------|---------|-------|
| `autonomous.model` | *(per-dispatch `dispatch_sweep` `model` param)* | `sonnet` | Model pinned on **every** daemon-dispatched child (work-finder, epic supervisor, and `dispatch_sweep` when its `model` param is absent). See below (#3944) |
| `autonomous.workFinder.enabled` | `LOOM_WORK_FINDER` | `false` | Master on/off for the finder loop |
| `autonomous.workFinder.intervalSecs` | `LOOM_WORK_FINDER_INTERVAL_SECS` | `60` | Zero/invalid → default |
| `autonomous.workFinder.maxConcurrent` | `LOOM_WORK_FINDER_MAX_CONCURRENT` | `3` | Operator **ceiling**, not a fixed target |
| `autonomous.workFinder.maxAdmissionsPerTick` | `LOOM_WORK_FINDER_MAX_ADMISSIONS_PER_TICK` | `3` | Per-tick **ramp** cap (#4234) — bounds how many *new* sweeps one tick may admit, independent of `maxConcurrent`/the live dynamic cap. Zero/invalid → default; resolved once at startup, mirroring `estCoresPerSweep`. See [Per-tick admission (ramp) cap](#per-tick-admission-ramp-cap-4234) below |
| `autonomous.workFinder.quarantine.enabled` | `LOOM_WORK_FINDER_QUARANTINE` | `true` | Insta-crash quarantine on/off (#3939). A safety backstop — defaults on |
| `autonomous.workFinder.quarantine.threshold` | `LOOM_WORK_FINDER_QUARANTINE_THRESHOLD` | `3` | Consecutive insta-crashes before an issue is quarantined. Zero/invalid → default |
| `autonomous.workFinder.quarantine.ttlSecs` | `LOOM_WORK_FINDER_QUARANTINE_TTL_SECS` | `3600` | How long a quarantine entry persists before auto-release. Zero/invalid → default |
| `autonomous.workFinder.quarantine.instaCrashSecs` | `LOOM_WORK_FINDER_QUARANTINE_INSTA_CRASH_SECS` | `60` | Checkpoint-less death within this window of dispatch counts as an insta-crash. Zero/invalid → default |
| `autonomous.hostBreaker.enabled` | `LOOM_HOST_BREAKER` | `true` | Host-distress circuit breaker on/off (#4235). A safety backstop — **defaults on**. Env truthy (`1`/`true`/`yes`/`on`) enables, any other value disables; wins over config. See [Host-distress circuit breaker](#host-distress-circuit-breaker-4235) below |
| `autonomous.hostBreaker.loadPerCoreTrip` | `LOOM_HOST_BREAKER_LOAD_PER_CORE` | `2.5` | Load-per-core at/over which a tick counts toward tripping. `<= 0`/invalid → default |
| `autonomous.hostBreaker.sustainTicks` | `LOOM_HOST_BREAKER_SUSTAIN_TICKS` | `3` | Consecutive over-threshold work-finder ticks required to trip (a single spike never trips). Zero/invalid → default |
| `autonomous.hostBreaker.cooldownSecs` | `LOOM_HOST_BREAKER_COOLDOWN_SECS` | `300` | Cool-down window held after distress subsides before dispatch resumes. Zero/invalid → default |
| `autonomous.perTokenConcurrency` | `LOOM_PER_TOKEN_CONCURRENCY` | `2` | Concurrent sweeps **per healthy token** in the cap (#3947). Zero/invalid → default; clamped to a floor of 1 |
| `autonomous.cpuUtilizationTarget` | `LOOM_CPU_UTILIZATION_TARGET` | `0.75` | Fraction of logical CPUs the CPU headroom term is willing to dedicate to sweep work (#3978, config surface #4032). Outside `(0, 1]` or wrong JSON type → default; single-root, resolved once at startup (not per-workspace) |
| `autonomous.estCoresPerSweep` | `LOOM_EST_CORES_PER_SWEEP` | `2.0` | Estimated CPU cores one concurrent sweep consumes while building/testing (#3978, config surface #4032). `<= 0` or wrong JSON type → default; integer JSON (`2`) and float JSON (`2.0`) both accepted; single-root, resolved once at startup |
| `autonomous.mainHealthGate.enabled` | `LOOM_MAIN_HEALTH_GATE` | `false` | Gate loop on/off |
| `autonomous.mainHealthGate.ciWorkflow` | `LOOM_GATE_CI_WORKFLOW` | *(unset)* | Forge workflow that must itself conclude `success` for forge-CI corroboration to vouch for a commit (#3987). Empty/whitespace → unset. Absent → today's unanimity rule, unchanged. See [Optional named verification workflow](#optional-named-verification-workflow-loom_gate_ci_workflow-3987) |
| `autonomous.mainHealthGate.suppressDispatchDuringGate` | `LOOM_MAIN_HEALTH_GATE_SUPPRESS_DISPATCH` | `true` | Hold new dispatch off a root while its build-gate run is in flight (#4084), per-root so a sibling with no gate in flight keeps dispatching. Env truthy (`1`/`true`/`yes`/`on`) enables, any other value disables; wins over config. Set `false` to recover the pre-#4084 `is_halted`-only behavior. See [build-gate.md → gate-in-flight dispatch suppressor](build-gate.md) |
| `autonomous.roleRunner.enabled` | `LOOM_ROLE_RUNNER` | `false` | Periodic standalone support-role runner on/off (#4015) |
| `autonomous.roleRunner.roles` | *(config only)* | all 5 roles | Subset of `champion`/`curator`/`judge`/`auditor`/`guide` to dispatch; explicit empty array runs none |
| `autonomous.roleRunner.intervalSecs` | `LOOM_ROLE_RUNNER_INTERVAL_SECS` | per-role built-in (5–15 min) | Uniform override applied to every enabled role's cadence |
| `autonomous.watchMonitor.enabled` | `LOOM_WATCH_MONITOR` | `true` | Durable operator-watch monitor loop (#3971). Default-on; no dispatch side effect, zero forge calls until a watch is registered |
| `autonomous.watchMonitor.intervalSecs` | `LOOM_WATCH_MONITOR_INTERVAL_SECS` | `120` | Watch poll cadence. Zero/invalid → default |
| `autonomous.watchMonitor.expirySecs` | `LOOM_WATCH_MONITOR_EXPIRY_SECS` | `86400` | Give-up window for an unresolved watch; `0` disables expiry |
| `autonomous.dispatchStaggerMs` | `LOOM_SWEEP_DISPATCH_STAGGER_MS` | `2000` | Min gap between consecutive child spawns (#3887). `0` disables |
| `autonomous.watchdog.enabled` | `LOOM_SWEEP_WATCHDOG` | `true` | Startup watchdog on/off (#3887). Also the master switch for the tick — mid-build-death (#3895) + review-stall (#3910) run in the same task |
| `autonomous.watchdog.timeoutSecs` | `LOOM_SWEEP_WATCHDOG_TIMEOUT_SECS` | `300` | No-progress window before auto-restart (raised from 120s in #4088 — the old default sat inside the observed 110–150s dispatch→worktree window and cancelled healthy sweeps) |
| `autonomous.watchdog.intervalSecs` | `LOOM_SWEEP_WATCHDOG_INTERVAL_SECS` | `30` | Watchdog probe cadence (shared by all three backstops) |
| `autonomous.watchdog.reviewStall` | `LOOM_SWEEP_REVIEW_STALL` | `true` | Review-phase stall watchdog on/off (#3910) |
| `autonomous.watchdog.reviewStallTimeoutSecs` | `LOOM_SWEEP_REVIEW_STALL_TIMEOUT_SECS` | `2700` | Log-silence window before a hung Judge/Doctor sweep is re-dispatched |
| `autonomous.collisionDetection.enabled` | `LOOM_DETECT_COLLISIONS` | `false` | Cross-host dispatch-collision baseline (#4085). Off by default — adds one extra `gh issue view --json labels` round-trip per dispatch. Detection only: a collision is logged/counted, never acted on |
| `safehouse.enabled` | `LOOM_SAFEHOUSE_ENABLED` | `false` | Enables safehouse fleet-comms (#3997) **and** cross-host soft-claim coordination (#4028). Off by default — a byte-for-byte no-op (no socket, no coordination task) when unset |
| `safehouse.peerClaimTtlSecs` | `LOOM_PEER_CLAIM_TTL_SECS` | `120` | Peer-claim TTL, in seconds (#4028) — how long a peer's soft claim suppresses local dispatch (measured against local receipt, not the advertiser's clock). Default = 2× the 60s work-finder tick |
| *(host identity)* | `LOOM_HOST_ID` | `$HOSTNAME` → `hostname` → `unknown-host` | This host's identity string, used in collision log records (#4085) **and** peer-claim self-recognition (#4028); set it where the daemon runs without `$HOSTNAME` exported |
| `autonomous.autoUpdate.enabled` | `LOOM_AUTO_UPDATE` | `false` | Autonomous self-update loop on/off (#4055). **Opt-in** (it rebuilds + restarts the daemon process). Exactly one loop per daemon, not a per-workspace fan-out. See [Autonomous self-update loop](#autonomous-self-update-loop-4055) below |
| `autonomous.autoUpdate.intervalSecs` | `LOOM_AUTO_UPDATE_INTERVAL_SECS` | `900` | Cadence between staleness checks. Zero/invalid → default |
| `autonomous.autoUpdate.settleSecs` | `LOOM_AUTO_UPDATE_SETTLE_SECS` | `600` | Settle window: wait this long after first observing a stale commit — resetting on every further commit — before rolling, so a burst of merges collapses into one roll. Zero/invalid → default |

### Daemon log path override (`LOOM_DAEMON_LOG`, #4010)

`setup_logging()` writes every daemon log line to `$HOME/.loom/daemon.log` by
default — this is the destination for `env_logger`-routed output (see the
launchd redirect note below), NOT the on-disk `LOOM_SOCKET_PATH` used by IPC.
Before #4010, this path was hardcoded with no override at all, so **any**
`loom-daemon` process — including one spawned by an integration test that
already isolates its IPC socket via `LOOM_SOCKET_PATH` — still wrote into the
operator's production log, polluting real operator history (worst-case: enough
test noise to rotate genuine history out of the 10MB × 10-file window).

Two env vars now cover both the log path and the socket path:

| Env var | Purpose | Default |
|---------|---------|---------|
| `LOOM_DAEMON_LOG` | Full override of the daemon log file path | `<loom dir>/daemon.log` |
| `LOOM_SOCKET_PATH` | Full override of the daemon's IPC socket path; also implicitly derives the log path (below) when `LOOM_DAEMON_LOG` is unset | `<loom dir>/loom-daemon.sock` |

Precedence is **env > default only** (no `autonomous.*` config tier) — `resolve_log_path()`
checks `LOOM_DAEMON_LOG` first, then falls back to `resolve_loom_dir().join("daemon.log")`,
where `resolve_loom_dir()` is the parent directory of `LOOM_SOCKET_PATH` when
that env var is set, else `$HOME/.loom`. Practically: setting `LOOM_SOCKET_PATH`
to a tempdir (as both `loom-daemon/tests/common/mod.rs` and
`loom-daemon/tests/integration_singleton_guard.rs` already do to isolate IPC)
isolates the log file for free, with zero test-file edits. A config tier was
considered and deliberately dropped: `setup_logging()` runs at daemon startup
*before* workspace/config resolution happens, so wiring config in would require
restructuring startup order (and `env_logger` cannot be re-targeted after
`.init()`) for marginal benefit over the env-only surface — file a follow-up if
a config tier is wanted later.

**The launchd `StandardOutPath`/`StandardErrorPath` redirect is a decoy, not a
second log.** `defaults/scripts/cli/loom-daemon-start.sh` points both launchd
redirects at a single file, `$REPO_ROOT/.loom/logs/daemon-start.log`
(`$START_LOG`), which only ever captures output emitted *before*
`setup_logging()` installs the `env_logger` pipe target (plus a crash's raw
stderr, if one occurs before logging is set up). In normal operation this file
stays **0 bytes** — all real daemon logging goes through `env_logger` straight
to `daemon.log` (or wherever `LOOM_DAEMON_LOG`/`LOOM_SOCKET_PATH` points it).
This has repeatedly misled operators into concluding a running daemon was
silent or dead when they tailed `daemon-start.log` instead of `daemon.log`.

**Autonomous dispatch model (`autonomous.model`, #3944).** A daemon-dispatched
child is a headless `claude -p "/loom:sweep N"` process. Without an explicit
`--model`, it inherits whatever model the operator last configured in their
**interactive** CLI — which on the v0.15.0 canary was a premium tier that meters
premium usage credits and hard-failed every spawn with "out of usage credits". To
stop an autonomous fleet from ever silently inheriting a premium interactive
default, the daemon now pins an explicit model on **every** auto-dispatch
(work-finder sweeps, epic-supervisor role/child dispatches) and on
`dispatch_sweep` when its `model` param is absent. The resolved model is chosen by
this precedence, highest first:

1. **`dispatch_sweep` `model` param** — an explicit per-dispatch request always
   wins (unchanged from #3477).
2. **`autonomous.model`** in `.loom/config.json` — the per-repo default for all
   autonomous dispatch.
3. **Shipped default `sonnet`** — a deliberately **non-premium** tier (fast +
   cost-appropriate for the bulk of build work). Never a premium tier.

Empty/whitespace values are treated as unset at every tier. The resolved model
and the tier that supplied it are named in the daemon dispatch log line
(`… model=<m> (source=param|config|default)`), and the model is forwarded to the
child via the existing `--model` plumbing (#3705). Set `autonomous.model` to
`opus` (or any valid model id) to raise the autonomous default per-repo.

**Startup-race mitigation (#3887).** Rapid back-to-back dispatch (the work
finder draining a backlog in one tick) could wedge some `claude` children at
startup in a 0-HTTPS MCP-init race: the sweep log showed only the spawn header,
no worktree was created, and the issue never left `loom:building`. Two layers
now guard against it: the **dispatch stagger** spaces consecutive child spawns
out of the simultaneous-startup window (prevention), and the **startup
watchdog** probes each running sweep for progress (worktree created / checkpoint
written / log output past the spawn header) and auto-cancels + re-dispatches —
**exactly once, bounded, never a loop** — any sweep hung with no progress past
`timeoutSecs`. Both the auto-cancel and the retry log loudly and reuse the
frozen `sweep.issue.{N}.exited` / `sweep.global.completed` / `sweep.global.dispatch`
topics (no new event topics). The watchdog defaults **on**; disable it with
`LOOM_SWEEP_WATCHDOG=0` or `autonomous.watchdog.enabled = false`.

**Progress is latched per sweep (#4088).** The progress probe reads only the
*current* filesystem state (worktree / checkpoint / log), and **all three signals
are torn down at successful completion** — `merge-pr.sh` removes the worktree,
`/loom:sweep` deletes the checkpoint, and the log never grows past the spawn
header. So a *finished* sweep is structurally indistinguishable from one that
*never started*, and because the decision function is memoryless (`elapsed` is
total runtime and only increases), a completed-then-cleaned-up sweep would be
re-dispatched against its own — now closed — issue. To fix this the watchdog
**latches progress per `SweepId`**: once a sweep is ever observed making progress
it is left alone for the rest of its life (later crashes are delegated to the
mid-build-death / review-stall backstops below). The latch is keyed by `SweepId`,
not issue number, so a *re-dispatched* sweep that then genuinely hangs at startup
is still rescued. Independently, **`dispatch` skips any issue that is closed on
the forge** (best-effort, fail-open on a `gh` error) — this covers all three
watchdogs, since each re-dispatches through the same method, so no self-heal path
can ever re-claim a closed/merged issue.

**Review-phase stall watchdog (#3910).** The startup watchdog rescues a sweep
that shows *no* progress, and the mid-build-death watchdog (#3895) rescues one
that made progress then *died*. Neither covers a sweep that is **still alive**
but wedged in a hung role subagent — the observed failure was a `/loom:sweep`'s
internal Judge or Doctor `Task` running **49–66 minutes (multi-hour in the worst
cases) emitting zero output until the very end**, silently blocking the sweep's
back half with no self-heal. The third backstop, running in the same watchdog
tick, closes that gap: for each still-running daemon-dispatched sweep that has
already made startup progress, it measures **log silence** (how long the
per-sweep log file's mtime has gone un-advanced — a live sweep flushes tool
output continuously, a hung one does not) and, past `reviewStallTimeoutSecs`
(default 45 min), auto-cancels the wedged child and re-dispatches the issue
**exactly once, bounded, never a loop**. The re-dispatch resumes from the sweep
checkpoint, so the hung review phase is re-run — not the whole build. A second
stall resolves to give-up and surfaces on the frozen `sweep.issue.{N}.crashed`
topic (no new event topics). Gated to sweeps past startup so it never
double-acts with the startup watchdog on the same tick. Defaults **on**; disable
with `LOOM_SWEEP_REVIEW_STALL=0` or `autonomous.watchdog.reviewStall = false`.

> **Root cause & scope (#3910).** The stall is a *harness-side* artifact — a
> role subagent (`loom-judge`/`loom-doctor`) dispatched via the Claude Code
> `Task` tool that hangs on an opaque long-running / wedged tool call, producing
> no output until it eventually returns (or the sweep is killed). The
> **subagent-path** orchestrator (in-session `/loom:sweep`) cannot bound this
> from outside: it blocks awaiting each subagent's `TaskOutput` and the harness
> exposes no per-`Task` timeout or kill (see the "async-only dispatch" note in
> `sweep.md`), so the only in-session mitigation is prompt-level time-budget
> discipline in the role prompts. This watchdog is the **daemon-path** backstop
> — it works precisely because a daemon-dispatched sweep is an isolated OS
> process whose log file is observable and whose PID is cancelable, which the
> in-session `Task` is not.

The **gate's behavior** (which command runs against `main`, its timeout) still
comes from the separate top-level `buildGate` block (#3749); `autonomous.mainHealthGate`
is purely the on/off surface, so Phase C's already-tested `buildGate` semantics
are untouched. `LOOM_MAIN_HEALTH_GATE` remains the master override; the config
key just lets a repo turn the gate on without exporting an env var.

**Insta-crash quarantine (#3939).** The startup watchdog (#3887) and mid-build-death
watchdog (#3895) both rescue a sweep that made *some* observable progress before
dying. Neither covers the **insta-crash**: a child that dies within seconds of
spawn — e.g. a missing token pool or a selector import failure (#3938) — is
reaped, its `loom:building` claim restored to `loom:issue`, and the issue simply
re-qualifies on the very next work-finder tick. Left unchecked this occupies a
global concurrency slot forever and starves healthy candidates in other repos.
The reaper now counts **consecutive** insta-crashes per issue — a terminal
transition that wrote no phase checkpoint (never reached real work) and landed
within `instaCrashSecs` of dispatch. A death *with* a checkpoint, or a clean/slow
exit, resets the tally, so a genuine one-off failure never accretes toward
quarantine. After `threshold` consecutive insta-crashes the issue is
**quarantined**: the work finder skips it in-memory (no forge round-trip needed
for the load-bearing behavior) and, best-effort, flips the forge labels
(`loom:issue` → `loom:blocked`) with an explanatory comment so the pause is also
visible to a human. Quarantine is visible per-repo in `loom-daemon status`
(`quarantined (insta-crash, #3939): #123, #456`) and auto-releases after `ttlSecs`
— a transient breakage (e.g. a re-provisioned token pool) recovers without
operator action. To release a quarantine **immediately** (rather than waiting for
the TTL), run `loom-daemon quarantine clear <issue>`: it clears the daemon's
in-memory quarantine + insta-crash tally over IPC AND restores `loom:issue` on
the forge, so the issue re-qualifies on the next tick. **Note:** the in-memory
quarantine is the load-bearing state — manually flipping `loom:blocked` →
`loom:issue` on the forge alone does **not** release it (the work finder skips
the issue until the CLI clear or the TTL fires). In `tick_multi`, a quarantined
candidate is dropped **before** the global slot-fill pass, so a workspace whose
only candidates are quarantined never reserves a shared dispatch slot — healthy
sibling work in other repos gets it instead. Defaults **on**; disable with
`LOOM_WORK_FINDER_QUARANTINE=0` or `autonomous.workFinder.quarantine.enabled = false`.

### Host-distress circuit breaker (#4235)

The insta-crash quarantine above protects the shared **queue** from one broken
issue; the host circuit breaker protects the **host itself** from a sustained
overload. It was added after the 2026-07-27→28 meltdown (#4231): a 6-way sweep
fan-out drove load to 118 on 28 cores, the window server was watchdog-killed five
times, and the daemon itself crashed — and then a *second* wave re-spiked the host
two hours later because nothing remembered the first incident. The point-in-time
admission checks (CPU headroom #3978, the per-tick load-admission ramp cap #4234)
each make a *fresh* decision every tick, so the instant load dipped they
re-admitted a full wave.

The breaker is the **stateful** layer those checks lack. It samples
**load-per-core** (`loadavg_1m / logical_cpus`) once per work-finder tick and runs
a three-phase state machine:

- **Closed** (normal) → **Open** once load-per-core has been at/over
  `loadPerCoreTrip` for `sustainTicks` *consecutive* ticks. A single spike resets
  the counter, so a transient burst never trips.
- **Open** (tripped) — new dispatch is **suppressed** in every repo while running
  sweeps **drain untouched** (the breaker never kills a running sweep). Stays Open
  while the host is still hot.
- **CoolDown** — once load drops back below the threshold, dispatch stays
  suppressed for a further `cooldownSecs` so a transient dip can't re-admit a full
  wave (exactly the #4231 01:41 re-spike). A re-spike over the threshold during
  cool-down sends it straight back to Open; otherwise the cool-down elapses and it
  returns to Closed.

The breaker's suppression composes with the existing dispatch suppressors at the
same choke point — it is OR'd onto the main-health-gate halt and the scheduled
drain, and works alongside (never bypassing) the `maxAdmissionsPerTick` ramp cap.

**Default-ON rationale.** Unlike the work-finder loop itself (opt-in,
default-off), the breaker **defaults on** — the same call the insta-crash
quarantine made. It only ever acts under genuinely severe *sustained* load, it
never aborts running work, and it is only ever *sampled* from inside the
work-finder loop, so a daemon that never enables the work-finder sees zero
behavior change. A backstop that defaulted off would not have prevented #4231's
second wave, which is the whole point.

**Explicit `dispatch_sweep` is hard-blocked by default (with a `force`
override).** This differs deliberately from the sibling headroom advisory (#4234),
which only *advises* an explicit dispatch that would exceed the point-in-time
dynamic cap and never blocks it. A *tripped* breaker represents **sustained,
already-observed** distress — a materially stronger signal than a single-tick
headroom reading — so `dispatch_sweep` (CLI `loom-daemon dispatch <N>` / the
`mcp__loom__dispatch_sweep` tool) is **refused** while the breaker is Open or
CoolDown. An operator who knows the host is distressed and wants to dispatch anyway
passes `--force` (CLI) / `force: true` (IPC / `mcp__loom__dispatch_sweep`).

**Observability.** The breaker is surfaced three ways: a log line on every phase
change; a state-change-deduped `daemon.host_breaker.state` event-bus event
(payload: `transition`, `state`, `reason`, `tripped_at`, `releases_at`); and
`loom-daemon status`, which prints `Host breaker: OK/OPEN/COOLING DOWN` with the
reason, the tripped-at time, and the cool-down release time (also in
`--json → host_breaker`).

**Clearing it manually.** The breaker auto-clears when the cool-down elapses on a
recovered host — no operator action is needed in the normal case. To clear it
sooner, either resolve the load (it releases on the next below-threshold tick plus
the cool-down) or restart the daemon (the state is in-memory, like the
quarantine). To disable it entirely, set `LOOM_HOST_BREAKER=0` or
`autonomous.hostBreaker.enabled = false`.

**Follow-ups deliberately deferred** (kept out of the first version to stay
minimal, per #4235): macOS-only trip signals (`.ips` crash reports, `syspolicyd`
CPU-ratio amplification, daemon self-restart detection) and durable trip/release
telemetry (coordinate with #4137 rather than building a parallel store).

### Cross-host dispatch-collision baseline (#4085, Phase 0 of #4028)

When two `loom-daemon` hosts share one repo backlog, both can dispatch the same
issue: the `mkdir` claim lock (`.loom/locks/issue-<N>/`) is filesystem-local, so
a peer host's lock is invisible, and the `loom:issue → loom:building` flip
succeeds whether or not the label was still there — the losing host is never
told it lost. This makes the cross-host collision rate **unobservable**, which is
the prerequisite gap #4028's coordination layer has to justify closing.

Collision detection makes that rate **measurable** (detection only — no
coordination, no backoff, behavior is otherwise unchanged). When enabled, just
before the label flip the registry reads the issue's **pre-flip** label state
(`gh issue view <N> --json labels`) and classifies it:

- `loom:issue` already gone **or** `loom:building` already present → **collision**
  (a peer host claimed it first). A diagnostic record is logged at `warn` — issue
  number, repo/workspace, this host's identity (`LOOM_HOST_ID` → `$HOSTNAME` →
  `hostname` → `unknown-host`), timestamp, and the observed pre-flip label set —
  and a per-registry cumulative counter is incremented.
- `loom:issue` present and `loom:building` absent → **clean** (this host is first).
- gh timeout / non-zero exit / unparseable JSON → **unknown**. **Fail-closed:**
  an unverifiable read is never counted as a collision, so the baseline is never
  inflated.

**How to read the count.** The running total is surfaced on the work-finder's
per-tick summary line as the trailing `N cross-host-collision(s)` field, e.g.:

```
work_finder: tick — cap 3 (...); 5 seen, 2 dispatched, 1 labeled-skip,
0 in-flight-skip, 0 quarantine-skip, 0 pr-open-skip, 0 deferred, 0 error(s), 3 cross-host-collision(s)
```

Unlike the other (per-tick) counters, this one is a **monotonic cumulative
total** read from the dispatcher(s) at tick end (summed across workspaces in the
multi-repo tick), so successive lines show the baseline accumulate. It is `0`
whenever detection is disabled. The existing fields (`labeled-skip` /
`in-flight-skip` / `quarantine-skip` / `pr-open-skip` …) keep their names and
semantics unchanged.

**`pr-open-skip` (open-PR dispatch guard, #4123).** A per-tick counter (like the
other `*-skip` fields, not cumulative) for issues the finder declined to dispatch
because they **already have an open linked PR**. The guard lives in
`SweepRegistry::dispatch()` (step 2.6, right after the #4088 closed-issue guard),
so it covers *every* dispatch caller — the work finder, the epic supervisor, the
IPC/CLI `dispatch_sweep`, and all three watchdogs — with one forge check. Every
in-memory dedup signal (idempotency key, in-flight set, `loom:building` label)
dies with the parent sweep, so without this guard an issue whose approved PR is
still open would be re-dispatched the moment its sweep exits, redoing finished
work against the token pool. `dispatch()` refuses these with a typed
`OpenPrDispatchError`; the finder attributes that refusal to `pr-open-skip`
(never to `error(s)`), and a tick whose only outcome is a `pr-open-skip` **still
logs** its summary line (the counter is part of the log gate). The guard keys on
PR *openness* only — never on review labels — and is **fail-open**: any forge
error, timeout, or unparseable output lets dispatch proceed, so a `gh` outage can
never wedge the daemon. It is GitHub-only (uses the `closedByPullRequestsReferences`
closes-graph, filtered to `state == "OPEN"`); a Gitea workspace fails open and
keeps today's behavior.

**Cost / default.** Enabling detection adds exactly one `gh issue view --json
labels` round-trip per dispatch (measured ~0.4s against GitHub), bounded by the
same `LOOM_REAP_GH_TIMEOUT_SECS` ceiling as the other best-effort `gh` calls.
Because that is a real per-dispatch API cost it is **off by default**; enable it
per the config/env row above (`LOOM_DETECT_COLLISIONS=1` or
`autonomous.collisionDetection.enabled = true`, precedence **env > config >
default**) on the hosts sharing a backlog while you take the measurement.

### Cross-host soft claim over safehouse (#4028, Phase 1 of #4028)

Where collision detection (above) only *measures* the race, the soft claim
*shrinks* it. When `safehouse.enabled` is true, each daemon advertises its
dispatch claims into the shared safehouse room and consumes peer advertisements,
so a peer daemon backs off before the non-atomic `loom:building` label flip would
let it race. This is Phase 1 of #4028 — see
[`.loom/docs/safehouse.md` → Peer-claim coordination](safehouse.md#peer-claim-coordination-cross-host-soft-claim-4028)
for the full design.

- **Advertise before the flip.** In `SweepRegistry::dispatch()`, right after the
  local claim lock and **before** `flip_label_to_building`, the daemon publishes a
  claim advertisement (issue, cross-host-stable repo slug, host identity, PID,
  timestamp) over the room. It rides a **`task`** envelope — the envelope `type`
  enum is closed and owned by the safehouse repo, so **no fifth type is invented**
  — with the bare issue number as `task_id` and the structured payload
  (`loom_claim`-marked JSON) in the `body`.
- **Dedicated inbound read task.** A coordination task on its own safehouse
  connection drains the socket continuously (`select!` over read + outbound), so
  an **idle** daemon that emits no narration still sees peer claims promptly — the
  narration sink only reads while it is emitting, so peer-claim consumption cannot
  piggyback on it. Inbound claims fold into a shared `PeerClaimView`
  (`loom-daemon/src/peer_claims.rs`, pure/socket-free).
- **Back off with a distinct counter.** The work-finder skips any issue with a
  live peer claim, counted as **`peer-claim-skip`** on the per-tick summary line —
  its **own** reason, never folded into `cross-host-collision(s)` (a post-hoc
  count) or the label/in-flight skips:

  ```
  work_finder: tick — cap 3 (...); 5 seen, 1 dispatched, 0 labeled-skip,
  0 in-flight-skip, 0 quarantine-skip, 0 pr-open-skip, 1 peer-claim-skip,
  0 deferred, 0 error(s), 0 cross-host-collision(s)
  ```

- **TTL + retraction.** Peer claims expire after **`safehouse.peerClaimTtlSecs`
  (env `LOOM_PEER_CLAIM_TTL_SECS`; default 120s = 2× the 60s work-finder tick)**,
  measured against **local receipt time** (never the advertiser's wall clock —
  clock skew is not comparable across hosts), so a crashed peer cannot
  permanently starve an issue. A peer also emits a `retract` ad from its reaper on
  a terminal sweep outcome, freeing the issue before the TTL.
- **Self-claim recognition.** A daemon never backs off on its own advertisement:
  the claim body carries the host identity (`host_identity()`:
  `LOOM_HOST_ID` > `$HOSTNAME` > `hostname` > `unknown-host` — loom's single,
  derived, restart-stable host concept), and the view ignores ads from this host.
  safehoused's socket `from` is stamped from the *persona* (all daemons share
  `loom_daemon`) and cannot distinguish hosts, hence the body-carried identity.
- **Fail-open, no-op when off.** An unreachable/refusing/timing-out socket, a
  malformed envelope, or a full outbound channel is logged once and **dispatch
  proceeds** — the outbound ad is a bounded non-blocking `try_send` off the
  dispatch path. `safehouse.enabled` false/absent is a **byte-for-byte no-op**: no
  view, no channel, no coordination task, no socket. No new event-bus topic is
  added (the frozen taxonomy is untouched — claims travel entirely over the room).

> **Soft claim, NOT a mutex.** A room broadcast is eventually consistent, so this
> is a fast backoff, not a lock — two hosts advertising near-simultaneously still
> race. The **atomic** cross-host claim authority (a real CAS, e.g. a `git push`
> to a claim ref) is **Phase 2 of #4028**, filed separately.

### Prerequisite: a fresh token ranking (#3894, self-refreshed by the daemon since #3969)

**When you run autonomous mode against a multi-account token pool, keep
`.loom/tokens/.ranking` fresh.** The spawn-time selector (native `loom-daemon
tokens select`, cut over from `loom_tools.tokens.select` in #4228) is 3-tier —
ranking → allowlist → random — and the ranking file is only
considered fresh for **10 minutes**. When it is absent or stale, tier-1 declines
and selection falls to the lower tiers. The work finder dispatches in bursts, so
a stale ranking means the daemon can steadily hand out accounts a recent probe
already flagged `exhausted`/`blocked`, whose sweeps then wedge at startup (spawn
header logged, no worktree, ~0% CPU) — the exact failure the startup watchdog
(#3887) then has to self-heal, one hang at a time.

As of #3969 the running `loom-daemon` **keeps this fresh itself** — see
[Token-ranking self-refresh](#token-ranking-self-refresh-3969) below. A
standalone operator cron (the historical requirement) is now an **optional
fallback** for setups that don't run the daemon at all (a bare `/loom:sweep`
subagent-dispatch install with no `loom-daemon` process); see that section for
the cron example. Two things keep a burst of issues from wedging on a stale
ranking regardless of which refresher is running:

- **A refresher running on a `<10`-min cadence** — the daemon's built-in loop
  (default 10 minutes, comfortably inside the freshness window) or an operator
  cron. One-shot before a run: `loom-tokens check --ranking`.

- **Stale-ranking fail-safe (selector-side, #3894).** Even without a fresh
  probe, a stale-but-present `.ranking` is no longer discarded. The selector
  treats its `exhausted`/`blocked` entries as an **advisory exclusion set** for
  the allowlist and random tiers, so it stops degrading to fully-random
  selection into known-exhausted accounts. If those exclusions would empty the
  pool (a stale "everything exhausted" ranking), selection retries ignoring them
  so a live pool never hard-fails on stale advice. This is a safety net, **not**
  a replacement for keeping the ranking fresh — a stale ranking still can't see
  an account that recovered.

### Token-ranking self-refresh (#3969)

The daemon runs its own periodic refresher for `.loom/tokens/.ranking` instead
of depending on an operator-managed cron for `probe-tokens.sh --ranking` — the
manual step documented above through #3894 is now automatic whenever
`loom-daemon` is running. It is the natural home for this loop: the daemon
already owns dispatch cadence and consumes the ranking (via `spawn-claude.sh`
selection) on every sweep it spawns.

**What it does.** On a configurable cadence (default 10 minutes) the loop
invokes **its own binary** (`std::env::current_exe()`) with `tokens check
--ranking --workspace <repo_root>` for each registered repo — as of #4080 this
is a direct daemon-to-daemon subcommand invocation rather than a shell out to
`probe-tokens.sh`, which sidesteps the "stale binary predates the `tokens`
subcommand" hazard entirely (the running daemon by construction supports its
own subcommands) and drops a process layer (daemon → bash → daemon). It probes
every bootstrapped account for its current rate-limit headers and atomically
rewrites `.ranking` in whichever pool [`tokens_pool::paths`] resolves for that
repo — the per-repo `.loom/tokens/`, or the shared machine-level pool (#3938)
when the per-repo pool is absent/empty.

**Default-on, unlike the work finder / main-health gate.** Those two loops are
opt-in because they have dispatch-affecting side effects (spawning sweeps,
halting dispatch). This loop only ever reads rate-limit headers and rewrites a
bookkeeping file nothing else consults synchronously, so it ships on by
default — an absent refresher would silently regress every install back to the
stale-ranking failure mode #3894/#3969 exist to fix. It still has a full opt-out
knob for a repo that wants it off (e.g. no tokens bootstrapped at all):

```json
{
  "autonomous": {
    "tokenRankingRefresh": { "enabled": true, "intervalSecs": 600 }
  }
}
```

| Env var | Config key | Precedence | Default |
|---------|-----------|------------|---------|
| `LOOM_TOKEN_RANKING_REFRESH` | `autonomous.tokenRankingRefresh.enabled` | env > config > default | `true` (on) |
| `LOOM_TOKEN_RANKING_REFRESH_INTERVAL_SECS` | `autonomous.tokenRankingRefresh.intervalSecs` | env > config > default | `600` (10 min) |

**Never fatal, never double-writes unsafely.** A probe failure (network hiccup,
`gh`/`python3` missing, every account exhausted, no tokens bootstrapped at all)
is logged and skipped — it never panics the loop or the daemon. Because
`loom-tokens check --ranking` writes `.ranking` atomically (temp file +
rename), an operator's cron running the identical script concurrently is
harmless: the two refreshers can race to *schedule* a write but never to a
*torn* file, so keeping an existing cron alongside the daemon costs nothing but
a redundant API call.

**Multi-workspace.** Like the work finder / main-health gate, the loop re-reads
the workspace registry each tick and refreshes every registered repo's own
pool, gated by that repo's own config (an empty registry reduces to the single
daemon workspace). See `loom-daemon/src/token_ranking_refresh.rs` for the
implementation.

### Autonomous periodic support-role runner (#4015)

Before this loop, the periodic **standalone** support roles — Champion,
Curator, Judge, Auditor, Guide — ran ONLY via GitHub Actions cron
(`.github/workflows/loom-*.yml`, Phase 2a of epic #3372/#3375), authenticating
with a single static `CLAUDE_API_KEY` secret with no rotation and no
health-awareness. Sweeps, by contrast, always ran host-side via
`sweep_registry`, drawing from the rotated, health-ranked token pool. That
split meant an operator provisioned *two* separate token systems for the same
underlying `claude -p "/role"` invocation, and a deployment with no
`CLAUDE_API_KEY` secret had its entire backlog-grooming pipeline silently dead
even while sweeps ran fine on the rotated pool.

**Scope.** This targets only the *standalone* periodic roles — the ones the
GitHub Actions cron table below lists. The *per-sweep* lifecycle roles
(Judge/Doctor/Champion-merge dispatched **inside** a `/loom:sweep`) already run
host-side on the rotated pool via `sweep_registry` and are unaffected.

**What it does.** Per enabled role, on its own cadence (defaults mirror the
commented-out `cron:` schedules in `.github/workflows/loom-*.yml`: champion
10m, curator 5m, judge 5m, auditor 10m, guide 15m), the daemon shells out to
`spawn-claude.sh -p "/<role>" --dangerously-skip-permissions` in the target
workspace — the identical launcher `sweep_registry` uses for sweep children —
so the role draws a token via the same 3-tier selection (ranking → allowlist →
random) and appears in the same `.loom/tokens/.bad_tokens` / `.ranking`
accounting as sweeps. Output is appended to
`.loom/logs/role-<role>.log`.

**Opt-in, unlike the token-ranking refresh above.** Each tick is a full
`claude -p` session that can mutate issues/PRs on the forge (dispatch-affecting
side effects, like the work finder / main-health gate), so an absent config
leaves the daemon's behavior byte-for-byte unchanged:

```json
{
  "autonomous": {
    "roleRunner": {
      "enabled": true,
      "roles": ["champion", "curator", "judge", "auditor", "guide"],
      "intervalSecs": 300
    }
  }
}
```

| Env var | Config key | Precedence | Default |
|---------|-----------|------------|---------|
| `LOOM_ROLE_RUNNER` | `autonomous.roleRunner.enabled` | env > config > default | `false` (off) |
| `LOOM_ROLE_RUNNER_INTERVAL_SECS` | `autonomous.roleRunner.intervalSecs` | env > config > default | per-role built-in (see above) |
| — | `autonomous.roleRunner.roles` | config only | all five roles |

`roles` restricts the dispatched subset (an explicit empty array runs none;
unknown names are ignored with a warning). `intervalSecs` — both the env var
and the config key — is a single override applied *uniformly* to every
enabled role's cadence; per-role cadence diversity otherwise comes from each
role's own built-in default.

**GitHub Actions workflows remain a supported fallback** for deployments with
no always-on daemon — this loop does not remove them, it gives an always-on
daemon host a better primary path. Running both simultaneously is harmless
(each is an independent `claude -p "/<role>"` invocation against the shared
forge state; the state machine's label-based coordination is what prevents
double-work, not a single dispatcher).

**Never fatal, first tick skipped.** A failed invocation (script missing,
non-zero exit, timeout — role invocations are killed via their process group
after a generous default 30-minute timeout, mirroring `sweep_registry`'s
group-signal cancel path) is logged and skipped; the next tick tries again.
Unlike the read-only token-ranking refresh, this loop skips its first tick
(mirrors the work finder / main-health gate) so several role loops starting at
daemon boot don't burst several `claude` sessions at once.

**Multi-workspace.** Like the other autonomous loops, each role's task
re-reads the workspace registry every tick and dispatches into every
registered repo that has that role enabled in its own config (an empty
registry reduces to the single daemon workspace). See
`loom-daemon/src/role_runner.rs` for the implementation.

### Durable operator watches (#3971)

**Problem it fixes.** An operator armed a 4-hour background poll watching two
items for terminal state, then their Claude Code session crashed and the watch
died with it — background tasks are children of the session process, so the
terminal-state report was silently lost. The root cause is harness behaviour,
but the durable fix belongs on the daemon: it is the long-lived process that
already outlives any one operator session.

**What it does.** An operator registers a watch on an issue or PR
(`register_watch` MCP tool, or `loom-daemon watch add`). The watch is persisted
machine-level to `~/.loom/watches.json` (override `LOOM_WATCHES_PATH`) so it
survives **both** the registering session's death **and** a daemon restart. A
default-on monitor loop polls each watch's terminal state on a cadence and, when
a watch reaches a terminal state or expires, **durably appends** a JSON line to
`~/.loom/logs/watch-results.log` (override `LOOM_WATCH_RESULTS_LOG`) — a file a
later session can trivially `tail` — then drops the watch from the active set.

**Terminal states** (forge-observable, read via `gh issue view` / `gh pr view
--json state,labels`):

| Outcome | Condition |
|---------|-----------|
| `closed` | issue/PR state `CLOSED` |
| `merged` | PR state `MERGED` |
| `blocked` | still-open item carrying the `loom:blocked` label |
| `expired` | monitor-generated — no terminal state within the expiry window (bounds the watches file + forge-call budget) |

**Why forge polling, not the event bus.** The in-memory event bus
(`sweep.issue.{N}.*`, `sweep.global.*`) only knows about sweeps *this daemon
dispatched*, and the motivating case is explicitly cross-repo (a `vibesql` issue
watched from the `loom` operator session) which the daemon may never have swept.
The v0.10.0 event taxonomy is also frozen. So the monitor **polls the forge
directly**, which works uniformly for any repo — sweep-backed or not — **without
minting a new event topic**. Address the target cross-repo with either `repo` (a
forge slug `owner/name`, preferred) or `workspace_root` (the `gh` query runs in
that repo's working dir — the same addressing pattern as `dispatch_sweep` /
`list_sweeps`).

**Default-on, like the token-ranking refresh.** It has no dispatch side effect
and makes **zero** forge calls until an operator registers a watch (an empty
registry short-circuits the tick to a single file read). Full opt-out knob:

```json
{
  "autonomous": {
    "watchMonitor": { "enabled": true, "intervalSecs": 120, "expirySecs": 86400 }
  }
}
```

| Env var | Config key | Precedence | Default |
|---------|-----------|------------|---------|
| `LOOM_WATCH_MONITOR` | `autonomous.watchMonitor.enabled` | env > config > default | `true` (on) |
| `LOOM_WATCH_MONITOR_INTERVAL_SECS` | `autonomous.watchMonitor.intervalSecs` | env > config > default | `120` (2 min) |
| `LOOM_WATCH_MONITOR_EXPIRY_SECS` | `autonomous.watchMonitor.expirySecs` | env > config > default | `86400` (24h; `0` disables expiry) |

**Never fatal.** A missing/corrupt watches file degrades to an empty registry; a
single failing probe (network, `gh` missing, transient forge error) is logged
and the watch retained for the next tick rather than aborting the whole tick.

**IPC / CLI surface.**

| IPC request | MCP tool | CLI | Purpose |
|-------------|----------|-----|---------|
| `RegisterWatch` | `register_watch` | `loom-daemon watch add <N> [--pr] [--repo O/N] [--note …]` | Register a durable watch (idempotent on `(target, kind, number)`) |
| `ListWatches` | `list_watches` | `loom-daemon watch list [--json]` | List active watches |
| `RemoveWatch` | `remove_watch` | `loom-daemon watch remove <id>` | Remove a watch by id |

See `loom-daemon/src/watch_registry.rs` for the implementation.

### Safe start / stop (raw daemon process)

`.loom/bin/loom start|stop` manage the **tmux Manual-Orchestration-Mode pool** —
a different process model from the `loom-daemon` binary that hosts the
work-finder / health-gate loops. Two dedicated wrappers manage the raw daemon
process:

```bash
# Plain start = FLAGS-OFF reliability daemon: BOTH autonomous loops OFF, no
# auto-dispatch. This is the safe default (#3911), consistent with the
# ecosystem-wide opt-in / default-off contract (LOOM_WORK_FINDER unset => off,
# LOOM_MAIN_HEALTH_GATE unset => off, precedence env > config > default):
./.loom/scripts/cli/loom-daemon-start.sh

# Opt in to autonomous loops explicitly:
./.loom/scripts/cli/loom-daemon-start.sh --work-finder   # work finder on
./.loom/scripts/cli/loom-daemon-start.sh --health-gate   # main-health gate on
./.loom/scripts/cli/loom-daemon-start.sh --work-finder --health-gate   # both on

# Enable strictly per .loom/config.json → autonomous (no env forcing):
./.loom/scripts/cli/loom-daemon-start.sh --from-config

# Explicit-off / foreground variants:
./.loom/scripts/cli/loom-daemon-start.sh --no-work-finder   # force finder off (explicit; same as default)
./.loom/scripts/cli/loom-daemon-start.sh --no-health-gate   # force gate off (explicit; same as default)
./.loom/scripts/cli/loom-daemon-start.sh --foreground       # run attached, no PID file

# Clean shutdown:
./.loom/scripts/cli/loom-daemon-stop.sh            # SIGTERM → grace → SIGKILL
./.loom/scripts/cli/loom-daemon-stop.sh --force    # immediate SIGKILL
```

`loom-daemon-start.sh`:
- **defaults FLAGS-OFF (#3911)**: a bare invocation exports `LOOM_WORK_FINDER=0`
  and `LOOM_MAIN_HEALTH_GATE=0`, so a plain start is a **reliability daemon** that
  does **not** auto-dispatch sweeps — consistent with the ecosystem-wide opt-in /
  default-off contract. An already-exported env var always wins; `--work-finder`
  / `--health-gate` force the respective loop on; `--from-config` leaves both
  unset so `.loom/config.json → autonomous` drives (precedence env > config >
  default),
- locates the `loom-daemon` binary (`LOOM_DAEMON_BIN` → `PATH` → `target/{release,debug}`),
- runs the **advisory** host-sleep check (`check-host-sleep.sh`, #3350) — never blocks the start,
- **on macOS, backgrounds the daemon as a launchd LaunchAgent** in the resolved
  per-user domain (`gui/<uid>` with an active GUI login, else the SSH-reachable
  `user/<uid>` background domain — #4130) instead of a plain `nohup … &` (#3972 —
  see "macOS session-bootstrap hazard" below); **on a systemd Linux host,
  installs + enables a `systemd --user` service** (#4268 — see "systemd user unit
  (Linux)" below) that mirrors the launchd supervision contract
  (`Restart=on-success`, disable-on-stop, `LOOM_DAEMON_SUPERVISOR=systemd`); on a
  non-systemd Linux host (or with `--no-systemd` / `LOOM_DAEMON_SYSTEMD=0`) it
  stays a plain nohup background job,
- backgrounds the daemon and writes a PID file at `.loom/.daemon.pid` (gitignored)
  — or, in **machine mode** (dispatcher-driven, `LOOM_MACHINE_CHECKOUT` set,
  #4229), at `$HOME/.loom/.daemon.pid` so the same machine-wide launchd
  singleton is tracked consistently no matter which repo `loom start` ran
  from; see [`machine-dispatcher.md`](machine-dispatcher.md#the-pidflags-relocation-decision),
- refuses a second start when the PID file points at a live process, and surfaces
  the daemon's own **singleton-guard** refusal (#3806) — if the backgrounded
  process exits immediately it prints the startup-log tail instead of leaving a
  silently-dead process.

`loom-daemon-stop.sh` sends **SIGTERM** (not just Ctrl-C/SIGINT — the daemon now
handles both, #3813), waits `LOOM_DAEMON_STOP_GRACE_SECS` (default 10s), then
escalates to SIGKILL. On macOS it additionally `launchctl bootout`s the
LaunchAgent job definition once the process is confirmed dead (see below). On a
systemd Linux host it detects the `systemd --user` ownership
(`systemctl --user is-active`/`is-enabled`) and instead stops + **disables** the
unit (`systemctl --user disable --now`), so a subsequent reboot does not
resurrect it (#4268 — see "systemd user unit (Linux)" below).

**Shutdown decision — sweeps survive, they are not drained.** A clean daemon stop
removes the Unix socket and exits, but **does not cancel in-flight `/loom:sweep`
children**. Those are independent detached processes that survive a daemon
restart by design — killing the dispatcher must not kill dispatched work — and
the registry reconciles their state on the next start (`SweepRegistry::reconstruct`
re-admits live-lock owners). To actively cancel a sweep, use
`mcp__loom__cancel_sweep` against a running daemon *before* stopping it.

> **Amended by #4090 (scheduled drain-and-restart).** The above describes the
> *plain* stop/restart: sweeps survive the process boundary but the relaunched
> daemon's in-memory registry starts empty, so a plain `RestartDaemon` leaves the
> surviving children as **orphans** — invisible to `list_sweeps`, the concurrency
> cap, the watchdog, and the reaper, and still holding `loom:building` for a
> `claim_reconciliation` pass to re-dispatch as duplicates. When you want "finish
> what you started, then roll" instead, use `loom-daemon restart --drain` (below):
> it stops admitting new work and waits for the registry to empty before exiting,
> so no sweep is killed and no orphan is left behind.

**Exit code carries shutdown intent (#4054).** The daemon encodes *why* it is
shutting down in its exit code, because the launchd `KeepAlive:{SuccessfulExit:true}`
plist (below) relaunches only on a clean exit `0`: the `RestartDaemon` primitive
exits `0` (relaunch), SIGTERM exits `143`, SIGINT exits `130`, an explicit IPC
`Shutdown` exits `143`, and a crash/panic exits non-zero — so only a deliberate
restart trips a relaunch, and "an operator stop stays stopped" holds without
depending on `bootout` timing. `loom-daemon-stop.sh` also re-verifies (scoped to
its launchd label) that no daemon is still alive after the stop and exits non-zero
if one is, closing the silent-success hole where a failed bootout could leave a
relaunched daemon dispatching.

### Autonomy-loss watchdog + heartbeat (#4011)

**The failure this closes.** On 2026-07-26 the `loom-daemon` launchd job took a
SIGTERM two seconds after starting and was left `bootout`-ed (unloaded) from
launchd. Autonomous dispatch silently stopped, and **nothing surfaced it** — no
log line, no forge signal, no notification. It was discovered hours later only
because someone happened to run `loom-daemon status` by hand. `loom-daemon
status` is a *pull*, and that pull is exactly the thing that didn't happen.

The fix is a *host-side* detector that lives **outside** the daemon process — a
dead daemon cannot report its own death (which is why #3971's in-daemon watch
loop is not reusable as the reporter). It has three cooperating parts:

1. **Durable autonomy-desired marker** (`<loom_dir>/autonomy-desired`).
   `loom-daemon-start.sh` writes it on a successful start; **only** an
   operator-initiated `loom-daemon-stop.sh` removes it. Its lifetime is
   **operator intent**, not process liveness — deliberately, because both of the
   "obvious" markers (the pid file, the loaded launchd job) are destroyed by the
   very stop path that causes an outage, so a detector built on them could not
   tell a deliberately-stopped daemon from a silently-dead one. The marker
   records the paths + label the watchdog needs (heartbeat file, cadence,
   pid file, launchd label, `use_launchd`).

2. **Declared-cadence heartbeat** (`<loom_dir>/daemon.heartbeat`, `loom-daemon/src/daemon_heartbeat.rs`).
   The running daemon rewrites it every `intervalSecs` (default 60s). This is an
   *explicit* liveness contract, chosen over piggybacking on the token-ranking
   `.ranking` mtime (#3969) — that is a config-disableable side effect, so a
   detector keyed to it would silently stop working when someone turned that loop
   off. Default-on (read-only, no dispatch side effect); opt out with
   `LOOM_DAEMON_HEARTBEAT=0` / `autonomous.heartbeat.enabled=false`.

3. **Host-side watchdog** (`loom-daemon-watchdog.sh`), the payload of a
   **second, separate scheduled job** from the daemon job/unit itself, that
   `loom-daemon-start.sh` provisions on a recurring cadence (default 300s):
   - **Darwin**: a second **launchd job** (`<daemon-label>-watchdog`) on a
     `StartInterval` cadence.
   - **systemd Linux** (#4260 sub-issue D): a `Type=oneshot`
     `<daemon-unit>-watchdog.service` driven by a paired
     `<daemon-unit>-watchdog.timer` (`OnUnitActiveSec` + `OnBootSec`,
     `Persistent=false`), `enable --now`'d on the **timer** (mirroring
     `loom-daemon.service` itself — #4268).

   Each run compares intent (marker present?) against reality (daemon loaded +
   alive? heartbeat fresh?) and, on divergence, appends a loud line to
   `<loom_dir>/logs/daemon-watchdog.log` and stderr (which launchd/systemd both
   capture into the same log via the rendered job/unit's stdout/stderr redirect).

| File | Env override | Config key | Default |
|------|--------------|-----------|---------|
| heartbeat cadence | `LOOM_DAEMON_HEARTBEAT_INTERVAL_SECS` | `autonomous.heartbeat.intervalSecs` | `60` |
| heartbeat on/off | `LOOM_DAEMON_HEARTBEAT` | `autonomous.heartbeat.enabled` | `true` (on) |
| watchdog interval | `LOOM_WATCHDOG_INTERVAL_SECS` | — | `300` (launchd `StartInterval` / systemd `OnUnitActiveSec`+`OnBootSec`) |
| watchdog job/unit basename override | `LOOM_WATCHDOG_LABEL` | — | `<daemon label/unit>-watchdog` |
| staleness threshold | `LOOM_DAEMON_HEARTBEAT_STALE_SECS` | — | `max(5 × cadence, 300)` |

**Why an interval timer, not a resident process or `KeepAlive`/`Restart=`.** The
reporter must itself be supervised, but a long-lived resident watchdog just moves
the who-watches-the-watchdog problem up a level (it too can crash and stay dead).
Both scheduling mechanisms own **no long-lived process**: launchd re-runs a
`StartInterval` job every interval regardless of how the last run exited, and
systemd's `.timer` re-fires its paired `Type=oneshot` service the same way — so
neither can crash-and-stay-dead. `KeepAlive`/`Restart=` are deliberately **not**
set on the watchdog job/service — that would busy-loop a short-lived job/oneshot
service instead of driving it off a fixed interval clock. The watchdog exit code
(`0` healthy / no daemon expected, `1` divergence) is for testability + a human
running it by hand; neither a `StartInterval` job's nor a timer-fired oneshot
service's exit code affects the next scheduled run.

**Decision matrix** (marker present ⇒ a daemon is expected):

| Reality | Watchdog |
|---------|----------|
| daemon alive, heartbeat fresh | silent (OK) |
| daemon alive, heartbeat **stale** | **report** — daemon may be wedged |
| daemon alive, no heartbeat file | silent (liveness-only; heartbeat disabled or not yet written) |
| daemon **not loaded/alive** | **report** — the #4011 outage |
| marker **absent** | silent — deliberate stop, no false page |

**Marker lifetime across a self-update.** `loom-daemon-update.sh` performs an
internal stop→start, which is a **restart**, not operator intent to stop — so it
passes `loom-daemon-stop.sh --restarting` (equivalently
`LOOM_DAEMON_STOP_KEEP_INTENT=1`), which **preserves** the marker + watchdog. This
is load-bearing: inferring restart-vs-stop would mean every self-update silently
disarms the detector — the exact bug class #4011 fixes — so it is an explicit
signal, never an inference. The subsequent start re-writes the marker and
re-provisions the watchdog.

**Platform + isolation.** Darwin and systemd Linux hosts both get a provisioned,
scheduled watchdog (see the two bullets above). Only the **nohup fallback tier**
— a non-systemd Linux host, or an explicit `--no-launchd`/`--no-systemd` /
`LOOM_DAEMON_LAUNCHD=0`/`LOOM_DAEMON_SYSTEMD=0` escape hatch — has no host-side
checker provisioned: the marker + heartbeat are still written, and
`loom-daemon-watchdog.sh` can be run by hand or wired to cron. `<loom_dir>` is the
parent of `LOOM_SOCKET_PATH` (else `~/.loom`), so pointing `LOOM_SOCKET_PATH` at a
tempdir isolates the marker + heartbeat there too — which is how the lifecycle
tests avoid ever touching the operator's real `~/.loom`. A forge-side reporting
channel is an explicit follow-up (out of scope for #4011).

**Third consumer: `loom-daemon status` (#4069).** The watchdog's marker +
heartbeat inputs have a second, on-demand consumer: `status`'s
unreachable-daemon error path (`main.rs`'s `handle_status_command`, via the
library module `daemon_install_state.rs`). Before #4069 every transport
failure collapsed into one generic *"Could not reach loom-daemon… Is the
daemon running?"* message, regardless of whether autonomy was ever expected.
`status` now runs the **same read-only, local probe** — same marker, same
per-field fallbacks, same env-wins-over-marker rule, same heartbeat staleness
formula — so `status` and `<loom_dir>/logs/daemon-watchdog.log` can never
disagree, and reports one of four states with a distinct exit code:

| State | Meaning | Exit code | Remediation printed |
|-------|---------|-----------|----------------------|
| `not-expected` | marker absent (deliberate stop, or never started) | `1` | suggest `loom-daemon-start.sh` |
| `expected-but-dead` | marker present, no live process — the #4011 divergence | `3` | suggest `loom-daemon-start.sh`; points at `daemon-watchdog.log` |
| `alive-starting` | marker present, process alive, IPC failed, **process age ≤ startup-grace window** — a normal `bootout`/`bootstrap` restart whose socket has not bound yet (#4213) | `4` | **none** — reports "still starting, not a fault"; NO stop/start remediation |
| `alive-but-unresponsive` | marker present, process alive, IPC failed, process **older** than the grace window (or age undeterminable) | `4` | does **not** suggest a start (singleton guard refuses); prints the live pid; heartbeat freshness qualifies fresh ⇒ IPC/socket fault, stale ⇒ likely wedged |

The startup-grace window defaults to `90s` (sized above the observed ~40–60s
socket-bind latency after a `launchctl bootout`/`bootstrap` cycle) and is
overridable via `LOOM_DAEMON_STARTUP_GRACE_SECS` (env > default, mirroring the
`LOOM_DAEMON_HEARTBEAT_STALE_SECS` precedence). Process age is read from
`ps -o etime= -p <pid>`; an unparseable age makes **no** grace claim and falls
through to `alive-but-unresponsive`, never a false "starting". The grace
discriminator is process age **alone** — never socket-file presence, since a
stale socket file from the prior run can legitimately still exist during
startup. `loom-daemon-watchdog.sh` never probes IPC, so it cannot emit the
fault verdict and needs no matching grace state.

`--json` gains a structured `install_state` object (`state` is the
machine-readable enum above, plus `started_at`, `pid`, `liveness_detail`, a
`heartbeat` sub-object, `process_age_secs`, `startup_grace_threshold_secs`, and
`watchdog_log`); the pre-#4069 `error` string key is retained for
compatibility. The probe never fails the command — an
unreadable/malformed marker, absent `launchctl`, a stale/unowned pid, or an
unreadable heartbeat mtime all degrade to a less-specific verdict (or, if no
loom dir can be resolved at all, `install_state` is simply omitted and the
generic pre-#4069 message is printed). The success path (a reachable, healthy
daemon) is untouched — this probe only runs after `query_daemon_status` has
already failed.

### macOS session-bootstrap hazard (#3972)

**Incident (2026-07-26).** The daemon was started at 21:48 via
`loom-daemon-start.sh` from inside a Claude Code session. That session crashed
at 02:49. From the very next work-finder tick (02:50:21), **every** `gh` call
in the daemon's process tree failed with `tls: failed to verify certificate:
x509: OSStatus -26276` and `git fetch` failed with `No user exists for uid 501`
— while the identical commands worked perfectly from any fresh shell. The
daemon ran blind for ~35 minutes: the work finder saw 0 issues (4 errors/tick),
the main-health gate went RED on purely environmental failures, and in-flight
sweep children couldn't reach the forge either.

**Root cause.** The pre-#3972 `loom-daemon-start.sh` detached the process with
a plain `nohup "$DAEMON_BIN" … &`. `nohup` makes the process immune to
`SIGHUP`, but it does **not** move the process out of the *launching session's*
Mach bootstrap namespace — the process stays registered under whichever
terminal/Claude-Code-session/SSH-connection Mach service happened to spawn it.
When that session's context is torn down, XPC lookups the daemon (and every
child it spawns) depend on start failing with no crash and no obvious log
signal:

- **`trustd`** (certificate verification) — the underlying cause of the `gh`
  TLS/OSStatus errors, since Go's Darwin certificate verifier round-trips
  through `trustd` via XPC.
- **`opendirectoryd`** (`getpwuid`) — the underlying cause of git's
  "No user exists for uid N", since `git` resolves the current user via
  `getpwuid()`, which is backed by `opendirectoryd` on macOS.

This is why **"start it from a terminal that might die" is unsafe on macOS**.
Linux does not have this failure mode — a systemd user session (or a plain
`nohup` under `init`) does not tie a background process's XPC-equivalent
identity to the shell that spawned it.

**Fix.** `loom-daemon-start.sh` now generates a `launchd` LaunchAgent plist and
loads it with `launchctl bootstrap <domain>` (the resolved per-user domain — see
"launchd domain resolution" below) instead of `nohup`-backgrounding in-process
(Darwin only — Linux is unaffected and keeps the plain nohup path). This was
validated during the incident itself: relaunching the identical binary as a
launchd agent immediately restored `gh`/`git` — the first tick after migration
reported `13 seen, 3 dispatched, 0 error(s)`.

**launchd domain resolution (#4130) — gui/<uid> ↦ user/<uid>.** The daemon was
originally loaded into the hardcoded `gui/<uid>` domain — the per-GUI-login
(Aqua) domain owned by `loginwindow`. Over SSH with **no active GUI login
session** that domain does not exist, so `launchctl bootstrap gui/<uid> …` fails
with `error 125: Domain does not support specified action`, and the daemon could
not be (re)started remotely on a headless Mac. The shared resolver
`resolve_launchd_domain()` (`defaults/scripts/lib/launchd-domain.sh`, consumed by
`loom-daemon-start.sh` / `-stop.sh` / `-update.sh` / `-watchdog.sh` so the whole
lifecycle agrees on one domain) resolves in this order:

1. an explicit `LOOM_LAUNCHD_DOMAIN` override, honored **verbatim** (a pinned
   domain that does not resolve fails loudly at `bootstrap`, never falls back
   further — the override is honored, not advisory);
2. `gui/<uid>` when `launchctl print gui/<uid>` resolves (a live GUI login) —
   **byte-for-byte the pre-#4130 default** on a host with an Aqua session;
3. `user/<uid>` — the **background per-user** domain that `sshd` itself
   instantiates: present over SSH with no GUI, running as the *user* (not root),
   and `gui/<uid>` already forwards to it (`endpoint destination =
   …domain.user.<uid>`).

**Rejected alternatives** (documented, deliberately not implemented):

| Mechanism | Runs as | Needs GUI session? | Needs sudo? | Why rejected |
|---|---|---|---|---|
| `gui/<uid>` (pre-#4130 default) | user | **yes** | no | Fails over SSH — the defect this fixes. Kept as the preferred domain **when it resolves**. |
| **`user/<uid>` (chosen fallback)** | user | no | no (own uid) | Background session ⇒ TCC prompts can't be answered interactively (see #3980) and the login keychain may be locked (see #4005). Smallest change, closest privilege match. |
| `launchctl asuser <uid>` | user | effectively yes (targets a session) | yes | Still needs a target session to impersonate. |
| system `LaunchDaemon` | **root** by default | no | yes | Wrong privilege model and **no login-keychain session** — re-opens the #4005 headless-credential problem in a new place instead of closing one. |

**Consequences of a non-Aqua (`user/<uid>`) domain.** A background domain cannot
surface an interactive TCC prompt, so any touch of a protected folder by the
daemon or a sweep child fails silently rather than prompting — see
`### macOS TCC hygiene under launchd (#3980)` below (the daemon's legitimate
working set never needs a protected folder, so this is a diagnostic signal, not a
blocker). The operator's **login keychain** may also be locked in a headless
session, so export a `GH_TOKEN` for forge auth rather than relying on the keychain
(the #4005 credential preflight reports this loudly). Both are inherent to running
without an Aqua session, not regressions introduced here.

- **Plist location & label**: `~/Library/LaunchAgents/com.rjwalters.loom-daemon.plist`
  (override the label with `LOOM_LAUNCHD_LABEL`; override the domain with
  `LOOM_LAUNCHD_DOMAIN`). Regenerated and reloaded (`bootout` the old definition,
  then a fresh `bootstrap` + `kickstart -k`) on **every** start, so a later
  invocation's flags/env always win over a stale loaded definition.
- **Environment forwarding**: the plist's `PATH` is the current `PATH` plus a
  fallback set (`~/.local/bin`, `~/.cargo/bin`, Homebrew, standard bin dirs) so
  `gh`, `git`, `cargo`, and `python3` resolve even inside launchd's minimal
  environment. Every already-exported `LOOM_*` / `GH_TOKEN` / `GITEA_TOKEN` /
  `FORGE_TOKEN` var is forwarded verbatim, so the FLAGS-OFF / `--work-finder` /
  `--health-gate` / `--from-config` semantics are preserved exactly — the
  launchd job never sees a wider or narrower autonomy configuration than a
  plain nohup start would have resolved.
- **Token hardening + startup credential preflight (#4005)**: because a
  forwarded `GH_TOKEN`/`GITEA_TOKEN`/`FORGE_TOKEN` is embedded verbatim in the
  plist, `loom-daemon-start.sh` writes the file mode `0600` whenever it
  carries one of those vars (otherwise it inherits the process umask —
  typically world-readable `0644`). Separately, the daemon resolves its own
  forge credential once at boot — before its first `gh` consumer — and logs
  the outcome loudly (`info!`/`error!`, never the token value); the result is
  also surfaced in `loom-daemon status` (`credential_preflight` in `--json`,
  a "Forge credential: OK/DEGRADED" line in the human view). See
  [`github-authentication.md` § Headless and SSH-only daemon operation](github-authentication.md#headless-and-ssh-only-daemon-operation-4005)
  for the operator-facing walkthrough — this is the fix for the
  keychain-unlock-dependency failure mode: a daemon started over SSH with no
  exported token used to boot clean and then 401 silently on every forge call.
- **`RunAtLoad=true` / `KeepAlive={SuccessfulExit:true}`** (#4054): `RunAtLoad=true`
  means the daemon survives a reboot/re-login, not just the death of one particular
  session — strictly *more* durable than the pre-#3972 nohup contract (which didn't
  survive a reboot either). `KeepAlive={SuccessfulExit:true}` (changed from the
  earlier bare `KeepAlive=false`) is the **supervised restart primitive**: launchd
  relaunches the job **only** when it exits with status `0`, and leaves it down on
  any non-zero exit. Because the daemon exits **non-zero** on a crash/panic, on a
  SIGTERM operator stop (143), and on a SIGINT/Ctrl-C (130), this **preserves** the
  old no-crash-loop semantics of `KeepAlive=false` — none of those respawn — while
  making the one deliberate clean-exit path (the `RestartDaemon` request, `loom-daemon
  restart`) the *only* thing that trips a relaunch. `loom-daemon-stop.sh` still
  `bootout`s the loaded definition after confirming the process is dead (so an
  explicit stop is honored at the next login too), but the bootout is now
  belt-and-braces: the non-zero SIGTERM exit already prevents launchd from relaunching
  during the stop window. See [Supervised restart primitive](#supervised-restart-primitive-4054)
  below and `docs/design/supervised-restart-primitive.md`.
- **Escape hatch**: `--no-launchd` (or `LOOM_DAEMON_LAUNCHD=0`) forces the
  legacy nohup path even on Darwin — e.g. for a sandboxed macOS runner where no
  launchd domain is usable at all. Note that a headless/SSH-only session **no
  longer requires** this escape hatch just to start: `resolve_launchd_domain()`
  falls back to `user/<uid>` (above), so the durable launchd path (and its #3972
  Mach-bootstrap-namespace protection) is available over SSH too — nohup remains
  only the last-resort opt-out, not the headless default.
- **Inspection without side effects**: `--print-plist` renders the exact plist
  XML this invocation would install and exits — no `launchctl` call, no file
  write to `~/Library/LaunchAgents`. Useful for auditing exactly what
  environment/flags a given invocation would forward.
- **Linux**: on a systemd host the daemon is supervised as a `systemd --user`
  service (#4268), not a bare `nohup` — see "systemd user unit (Linux)" directly
  below. On a non-systemd host (or with `--no-systemd` / `LOOM_DAEMON_SYSTEMD=0`)
  `nohup` remains the mechanism, which is safe on Linux because a background
  process's identity is not tied to the spawning shell the way macOS's Mach
  bootstrap is (so the #3972 failure mode does not reproduce there — the systemd
  path is about reboot survival + supervised restart, not that incident).

### systemd user unit (Linux, #4268)

On a systemd Linux host, `loom-daemon-start.sh` installs a `systemd --user`
service and `systemctl --user enable --now`s it, the Linux mirror of the launchd
LaunchAgent path above (sub-issue B of #4260). This replaces the pre-#4268 bare
`nohup … &`, which had no reboot survival, no supervised restart, and no
disable-on-stop. The contract mirrors launchd point-for-point:

| launchd (Darwin) | systemd `--user` (Linux) |
|---|---|
| `RunAtLoad=true` + `launchctl enable` (#3972) | `[Install] WantedBy=default.target` + `systemctl --user enable` |
| `KeepAlive:{SuccessfulExit:true}` — relaunch only on a clean exit `0` (#4054) | `Restart=on-success` — relaunch only on a clean exit `0` (exact analog; a crash / operator SIGTERM/SIGINT exits non-zero and stays down) |
| `launchctl bootout` on operator stop | `systemctl --user disable --now <unit>` |
| plist `EnvironmentVariables` (`LOOM_DAEMON_SUPERVISOR=launchd`, forwarded `LOOM_*`/tokens, deterministic PATH #4172) | `Environment=` lines (`LOOM_DAEMON_SUPERVISOR=systemd`, same forwarded env + PATH) |
| `WorkingDirectory` = checkout in machine mode (#4229), else repo root | `WorkingDirectory=` — same resolution |
| `--no-launchd` / `LOOM_DAEMON_LAUNCHD=0` escape hatch (#4078) | `--no-systemd` / `LOOM_DAEMON_SYSTEMD=0` escape hatch |
| `--print-plist` inspection (no side effects) | `--print-unit` inspection (no side effects) |

- **Unit location & name**: `~/.config/systemd/user/loom-daemon.service` (override
  the name with `LOOM_SYSTEMD_UNIT`). Regenerated and `daemon-reload`ed on every
  start, so a later invocation's flags/env always win over a stale unit. Written
  `0600` when it carries a forwarded `GH_TOKEN`/`GITEA_TOKEN`/`FORGE_TOKEN`.
- **`LOOM_DAEMON_SUPERVISOR=systemd`** is baked into the unit so the daemon can
  prove it is supervised before it exits for a supervised restart — recognized
  daemon-side by `detect_supervisor()` (PR #4298 / #4267). It is hardcoded into the
  rendered unit (never harvested from the caller's env), so it is present on every
  supervised start and absent from the nohup path.
- **Reboot survival requires lingering.** A `systemd --user` manager only runs
  while the user has a session; the service comes back after a reboot (or an SSH
  logout) **only** when the user has lingering enabled. Run **`loginctl
  enable-linger "$USER"`** once on a headless / SSH-only host. Without it the unit
  is still installed + supervised for the life of the login session, but does not
  survive a reboot; `loom-daemon-start.sh` prints this reminder on every systemd
  start.
- **User-manager reachability fallback.** If `systemctl` is present but the
  per-user manager is unreachable — a bare SSH login with no lingering and no
  active user session, so `XDG_RUNTIME_DIR` is unset / `systemctl --user
  is-system-running` reports `offline` — the start script warns clearly (with the
  `enable-linger` remedy) and falls back to the nohup path, rather than failing
  with a cryptic `Failed to connect to bus` error. Detection lives in
  `is_linux_systemd()` / `systemd_user_manager_reachable()`
  (`defaults/scripts/lib/systemd-user.sh`, the Linux counterpart to
  `lib/launchd-domain.sh`, shared by start + stop).
- **Stop disables the unit.** `loom-daemon-stop.sh` detects the `systemd --user`
  ownership and runs `systemctl --user disable --now`, then re-verifies the unit is
  inactive and exits non-zero if it is not (the systemd analog of the launchd
  bootout-did-not-stick check). `LOOM_DAEMON_SYSTEMD=0` disables all systemd
  interaction symmetrically, so a `--no-systemd` (nohup) start gets a stop that
  never touches the user manager.
- **Crash relaunch is out of scope.** `Restart=on-success` deliberately does
  **not** relaunch a crashed daemon (a non-zero exit) — that is watchdog territory.
  On a systemd host it is delivered by the `<unit>-watchdog.timer` +
  `Type=oneshot` `.service` pair (#4260 sub-issue D, "Autonomy-loss watchdog +
  heartbeat" above), mirroring the macOS `StartInterval` autonomy-loss watchdog
  (#4011) — the watchdog *reports* divergence, it does not restart the daemon.

### macOS TCC hygiene under launchd (#3980)

**Why launchd changed the TCC picture.** Under the pre-#3972 nohup model, the
daemon inherited whatever TCC (Transparency, Consent, and Control) grants the
launching terminal app already had — so folder-access prompts, if any, belonged
to Terminal.app/iTerm/Claude Code, not to `loom-daemon`. As a launchd LaunchAgent
(see above — `gui/<uid>` under a GUI login, else `user/<uid>` over SSH, #4130),
the daemon is its **own** TCC-responsible process:
any touch of a protected location (`~/Desktop`, `~/Documents`, `~/Downloads`,
`~/Pictures` (Photos), `~/Music` (Media & Apple Music),
`~/Library/Mobile Documents` (iCloud Drive), network/removable volumes, …) by
the daemon **or any sweep child it spawns** now prompts fresh, once per
protected category. One operator report saw ~10 prompts in a single session,
including Photos / Media & Apple Music / iCloud — evidence of something
enumerating the top level of `$HOME` itself rather than touching those folders
individually (macOS bundles the per-category checks into one burst when a
process lists `$HOME`'s immediate contents).

**Under the `user/<uid>` (headless/SSH) domain (#4130) there is no prompt at
all.** A background domain cannot surface an interactive TCC dialog, so the same
out-of-bounds access **fails silently** (permission-denied) instead of prompting.
That does not change the contract below — the daemon's and sweep children's
legitimate working set still contains no protected folder — it only changes the
symptom (a silent file-not-found rather than a popup). The remedy is identical:
fix the offending script/tool to stay within the working-set contract, never a
broad grant. This is one of the documented consequences of the non-Aqua fallback
domain (see "launchd domain resolution" under #3972 above).

**The daemon's legitimate working set never needs a protected folder.** Audited
surfaces — the daemon core (Rust) and `.loom/scripts/*` — only ever touch
`~/GitHub/*` (or wherever a workspace lives), `~/.loom`, `~/.claude*`, and
`/private/tmp`; disk-headroom checks use `df -Pk <workspace>`, not a directory
walk. `defaults/scripts/claude-wrapper.sh`'s crash-recovery path
(`recover_cwd()`, used when a worktree is deleted out from under a running
sweep child, e.g. by `loom-clean` or `merge-pr.sh`) previously fell back to
`cd "$HOME"` as a last resort before `/tmp` — landing a respawned `claude`
child in `$HOME` risked exactly the kind of out-of-bounds enumeration described
above. Fixed in #3980: both the last-resort `cd` and the script's initial
`WORKSPACE` fallback (when `pwd` fails at wrapper startup) now go straight to
`/tmp`, which is on the TCC-safe allowlist and serves the same "always exists,
always cd-able" purpose. `$HOME` is no longer a reachable recovery target
anywhere in the wrapper.

**Sweep children's working-set contract.** Every `/loom:sweep`-dispatched
child (Curator/Builder/Judge/Doctor/Champion subagents, and any test suite or
tool subprocess they invoke) is expected to stay within: the workspace root
it was dispatched into, `.loom/` (worktrees, logs, tokens, checkpoints),
`.claude*` config dirs, and `$TMPDIR`/`/private/tmp` scratch space. Recursive
scans that escape this contract — `find ~`, `du -sh ~`, `grep -r` rooted at
`$HOME`, a script that `cd`'d to the wrong place before globbing, a test suite
that writes fixtures to `~/Documents` instead of a tmpdir, or a tool that
resolves an iCloud-synced path — are **out-of-scope defects**, not ambient
behavior to route around with a broader macOS grant. If you write a role
prompt, hook, or test fixture, scope its filesystem footprint to this
contract explicitly rather than relying on `$HOME`-relative expansion.

**What to click when macOS prompts.** **Deny is always safe.** The daemon's
and sweep children's legitimate working set contains no protected folder, so a
genuine prompt means something reached outside the contract — denying it may
surface a sweep-child failure (a file-not-found / permission-denied on the
out-of-bounds path), which is the **diagnostic signal**, not a bug to route
around. Use that failure to identify and fix the offending script/tool per the
contract above, the same way any other out-of-scope access would be fixed.

**Why Full Disk Access is never the right answer.** FDA (or per-category
Allow) is not the fix even as a convenience, for two independent reasons: (1)
it papers over a real out-of-scope access instead of fixing it, and (2) it
doesn't survive the deployment model. TCC identity is keyed to the binary's
code signature (or, for an ad-hoc/unsigned binary, its cdhash), and
`loom-daemon` is rebuilt from source on every `loom-daemon-update.sh` self-update
roll (#3968) — each rebuild produces a **new** cdhash, so any grant attached to
the previous build silently evaporates. Chasing that with FDA produces a
recurring popup storm *and* a standing over-grant that provides no lasting
benefit. If a grant is ever clicked by mistake, walk it back at System
Settings → Privacy & Security → \<category\> (Photos / Media & Apple Music /
Files and Folders / …) → remove `loom-daemon` — the next self-update rebuild
would have revoked it anyway via the cdhash change, so removing it manually
just does that sooner.

**Ad-hoc code signing (#4016) — pins a legible identifier, does NOT fix TCC
durability.** `loom-daemon-update.sh` and `provision-daemon.sh` ad-hoc-sign the
provisioned binary with a stable `--identifier com.rjwalters.loom-daemon`
(`codesign -f -s - --identifier com.rjwalters.loom-daemon <bin>`, Darwin-only,
best-effort, never fatal). This was **originally proposed** as a way to let a
future, narrowly-scoped TCC grant survive a rebuild — that premise was tested
and found false, and the paragraph above previously repeated the same false
claim. Measured directly (`codesign -dv --verbose=4` / `codesign -d -r-`
before and after applying `--identifier`): TCC keys a grant to the binary's
**designated requirement** (DR), not to the identifier string. A
certificate-signed binary gets an identifier-anchored DR
(`identifier "X" and certificate leaf = H"…"`), which is what would survive a
rebuild — but an **ad-hoc** signature has no certificate chain to anchor to,
so `codesign` always falls back to a **cdhash-only DR**, regardless of what
`--identifier` is passed. Applying the stable identifier makes the identifier
itself constant across rebuilds, but the DR is still `cdhash H"…"`, and that
hash changes on every rebuild — including every self-update roll, since
`build.rs` embeds `LOOM_DAEMON_GIT_COMMIT` / `LOOM_DAEMON_BUILD_TIME` and a
roll by definition follows a `HEAD` move. So the general rule in the FDA
paragraph above — *any* grant on an ad-hoc/unsigned binary is orphaned by the
next rebuild — is unaffected by this change and remains the operative fact.
All this change actually buys is a **legible, stable identifier string**: the
`codesign -dv` / System Settings → Privacy & Security / crash-diagnostic
surfaces show `com.rjwalters.loom-daemon` instead of the rustc `-C metadata`
hash (`loom_daemon-<hash>`, which itself changes on every version bump). It is
also the necessary first step for real signing, which #4244 turns from
speculative into an opt-in capability: set `LOOM_CODESIGN_IDENTITY` (or the
`codesign.identity` config key, env > config > default) to a certificate
already in the keychain and `sign_daemon_binary` signs with that certificate
chain instead of ad-hoc — a certificate-anchored DR survives a rebuild, so a
TCC grant to the daemon identity does too. Unset (or an identity the keychain
doesn't have) falls back to the ad-hoc path above, unchanged, and no new TCC
grant is requested by default. One-time self-signed cert setup (Certificate
Assistant or openssl + `security import`, including the OpenSSL 3 PKCS12
`-legacy` quirk and the `-T /usr/bin/codesign` trust-anchor requirement for
unattended signing) and why grants should target the daemon identity, not
Terminal: [`macos-tcc-codesign.md`](macos-tcc-codesign.md).

### Supervised restart primitive (#4054)

Phase 2 of #4017 (auto-rebuild-and-restart-when-stale). It ships a
manually-triggerable way for the daemon to **end and reliably come back**, so
Phase 3 has a *proven* restart path to call. It deliberately ships **no**
automation — nothing fires it on its own.

```bash
loom-daemon restart          # send RestartDaemon over the IPC socket
```

- **Mechanism (macOS):** the plist uses `KeepAlive:{SuccessfulExit:true}` and the
  daemon exits `0` **only** for a `RestartDaemon` request, so launchd relaunches
  the job on that one clean exit and leaves it down on every other (SIGTERM 143,
  SIGINT 130, crash non-zero). The relaunched process re-reads the same plist, so
  it comes back with **exactly** its start flags/env — never wider. In-flight
  sweeps survive (they are independent detached processes the daemon never cancels
  on shutdown). Observable signature: a **new pid**.
- **Supervision proof:** `loom-daemon-start.sh` bakes `LOOM_DAEMON_SUPERVISOR=launchd`
  into the plist, and the daemon ends its process for a restart **only** when that
  var is present. On an unsupervised host (nohup / Linux / `--foreground`) it
  refuses: `loom-daemon restart` prints the refusal, exits non-zero, and the daemon
  keeps running — because nothing would bring it back if it exited (#4017's "log
  loudly, leave the daemon running, do not restart").
- **Why launchd, not `exec` self-replacement:** the design record — including why
  the `exec` (Option 2) and detached-helper (Option 3) alternatives were rejected,
  and the Curator's exit-code-race finding — is in
  `docs/design/supervised-restart-primitive.md`.

#### Scheduled drain-and-restart (`--drain`, #4090)

A plain `loom-daemon restart` exits immediately: in-flight sweeps survive the
process boundary but become **orphans** (absent from the relaunched daemon's
in-memory registry — see the "sweeps survive, they are not drained" amendment
above). `--drain` closes that gap by finishing in-flight work *before* rolling:

```bash
loom-daemon restart --drain                       # finish in-flight sweeps, then restart
loom-daemon restart --drain --timeout 600         # bound the wait (default 1800s)
loom-daemon restart --drain --force-after-timeout # at the deadline, cancel stragglers and restart anyway
loom-daemon restart --abort-drain                 # cancel an in-progress drain, resume dispatch (no restart)
```

- **What a drain does:** it sets a daemon-global drain flag that is OR'd into the
  same halt checks the main-health gate uses (#3812) — the work finder stops
  dispatching, the epic supervisor stops scheduling phases, and (newly, #4090) the
  role runner stops **starting** new role ticks. Already-running work is left
  alone. A supervisor task then polls the cross-root in-flight sweep count (every
  managed workspace, not just the primary) and exits `EXIT_RESTART` for the launchd
  relaunch only once it reaches **zero** — so `list_sweeps` after the relaunch is
  consistent with reality and there are **no orphans**.
- **Fail-safe timeout:** reaching `--timeout` without `--force-after-timeout`
  **refuses** the restart (clears the drain flag, resumes dispatch, stays up) and
  reports the reason via `loom-daemon status` — it never silently restarts or
  silently gives up. `--force-after-timeout` opts into cancelling the stragglers
  via the existing `cancel_sweep` path, then restarts.
- **Supervision proof is checked up front (AC5):** on an unsupervised host the
  request is refused **before** dispatch is paused (`accepted: false`), so a caller
  can detect nothing happened and no silent outage is introduced.
- **Residual (documented, bounded):** role ticks have no sweep-registry entry to
  poll, so a drain stops them *starting* but cannot *await* one already running —
  a drain can complete while a role tick is still mid-flight, bounded by the role
  timeout (`DEFAULT_ROLE_TIMEOUT`, 1800s). Awaiting role ticks is deliberately out
  of scope (it would require a role registry, #4090's stop-and-split boundary).
- **Observability:** `loom-daemon status` renders `DRAINING (n sweep(s) remaining,
  deadline …)` while active and the last transition (timeout refusal / abort)
  afterward; the four `daemon.drain.*` events (above) narrate the transitions on
  the event bus. **Cannot be used for its own first roll** — see the rollout note
  below.

### Self-update (rebuild + provision + restart, #3968)

The daemon's self-repair loop can file **and fix** its own defects — proven
during the 2026-07-25/26 canary rollout, which produced 16 self-filed daemon
fixes — but every merged fix historically only took effect after an operator
manually rebuilt the Rust binary, reprovisioned it, and restarted the process.
`loom-daemon-update.sh` is the single operator command that closes that gap:

```bash
./.loom/scripts/cli/loom-daemon-update.sh              # detect, rebuild if stale, provision, restart (preserving flags)
./.loom/scripts/cli/loom-daemon-update.sh --check       # detect only; exit 0 (up to date) / 3 (update available); no writes
./.loom/scripts/cli/loom-daemon-update.sh --dry-run     # print the plan without building/provisioning/restarting
./.loom/scripts/cli/loom-daemon-update.sh --force       # rebuild + provision + restart even if already up to date
./.loom/scripts/cli/loom-daemon-update.sh --no-restart  # rebuild + provision only; leave the running daemon untouched
./.loom/scripts/cli/loom-daemon-update.sh --relaunch    # launchd only: after a refused restart, re-render the plist + relaunch under supervision (preserves the live plist's LOOM_* env)
```

**Launchd refused-restart fallback (`--relaunch`, exit 6, #4118)**: on the
FIRST roll onto a #4077-capable binary the *running* (old) daemon has no
`RestartDaemon` handler and refuses the `loom-daemon restart` IPC, so the script
exits **6** rather than reporting a half-update. It does **not** tell you to
`launchctl bootstrap` the existing plist — that plist is stale by construction
(no `KeepAlive:{SuccessfulExit:true}`, no `LOOM_DAEMON_SUPERVISOR`), so
bootstrapping it relaunches *unsupervised* and every subsequent roll refuses
identically forever, and its `launchctl bootout` tears down the whole job tree
(in-flight sweep children are direct children of the launchd job, so they are
killed). Instead, `--relaunch` (or `LOOM_DAEMON_UPDATE_RELAUNCH=1`) re-renders
the plist via `loom-daemon-start.sh` — installing both supervised keys — while
**preserving the live plist's `LOOM_*`/token `EnvironmentVariables`** (read with
`plutil` + `jq`, `PATH`/`HOME`/`LOOM_DAEMON_SUPERVISOR` excluded so autonomy
flags never silently narrow to FLAGS-OFF, #4011), and stops the old daemon
**gracefully with `SIGTERM`** so sweep children reparent and keep working. The
default path stays exit-6 (no `--relaunch`) so the sweep-disrupting relaunch is
always a consented action.

**Staleness detection** is primary-local, zero-network: it compares the git
commit **baked into** the currently-resolved `loom-daemon` binary (embedded at
build time via `build.rs` → `LOOM_DAEMON_GIT_COMMIT`, the same value folded
into `loom-daemon --version`) against the **local source tree's** current
`HEAD` short commit — directly answering "would rebuilding right now produce a
different binary?". Separately, and purely **advisory** (it never gates the
rebuild decision), the script bounded-fetches `origin/<default-branch>` and
warns when local `HEAD` itself is behind, mirroring
`check-main-freshness.sh`'s pattern — so a cron-scheduled run distinguishes
"you're current with local HEAD" from "local HEAD is itself stale".

**Flag preservation (the FLAGS-OFF/opt-in contract, never widened)**:
`loom-daemon-start.sh` now persists its resolved invocation flags to
`.loom/.daemon.flags` (gitignored, one flag per line) on every start attempt —
`--foreground`/`--help` are filtered out (script-only, not autonomy state);
`--from-config`, `--work-finder`, `--health-gate`, `--no-work-finder`,
`--no-health-gate` are kept verbatim. `loom-daemon-update.sh` reads this file
and replays it **exactly** on restart — a daemon started bare (FLAGS-OFF)
restarts bare; a daemon started `--work-finder` restarts `--work-finder`,
never gaining `--health-gate` it didn't have. A missing flags file (a daemon
started before #3968, or manually) falls back to a bare FLAGS-OFF restart
rather than guessing, with a loud warning.

**A daemon that was NOT running is never started.** If `.loom/.daemon.pid`
has no live process at update time, the script rebuilds and provisions but
prints "was not running — nothing to restart" and stops — it never widens the
system state by starting autonomy (or anything) that wasn't already running.
Combined with the "in-flight sweeps survive a stop" shutdown decision above,
a rebuild-and-restart window never kills active dispatched work and never
silently upgrades a stopped daemon into a running one.

**Provisioning** targets wherever the resolved binary lives: an explicit
`LOOM_DAEMON_BIN` override is provisioned in place; otherwise the fresh binary
is installed to the machine-level location via
`scripts/install/provision-daemon.sh`'s `provision_machine_daemon` (default
`~/.local/bin/loom-daemon`, override `LOOM_DAEMON_BIN_DIR`) — the same
convention `loom-daemon-start.sh` already resolves through `command -v
loom-daemon`.

**Self-verifying rebuild → provision (a roll can never silently ship nothing,
#4053)**: the rebuild → provision path proves it produced what it claims, so a
successful-looking run can no longer install a stale binary:

- **Built-commit verification (before provisioning).** After `cargo build
  --release`, the script asserts the freshly-built binary's embedded commit
  (parsed from `--version`) equals the source `HEAD` it was built from. On
  mismatch it **fails loudly and does not provision** — a build that succeeds
  yet bakes in the wrong commit is a build-system defect (historically a
  `build.rs` `cargo:rerun-if-changed` watch-set bug that missed HEAD movement),
  not a compile failure, and retrying cannot fix it. **Exit code `4`**,
  distinguishable from a compile failure (`1`). The underlying `build.rs`
  watch set is now correct-by-construction via `git rev-parse --git-path`
  (resolving `HEAD`, the current branch's ref, and `packed-refs`), so it tracks
  HEAD movement in the main checkout, a **linked worktree** (`.git` is a file —
  every Builder's environment), a detached HEAD, and a packed-refs repo alike.
- **Post-provision verification (after provisioning).** The script then asserts
  the **destination** binary's `--version` is the expected build — for both the
  `LOOM_DAEMON_BIN` override path and the machine-level
  `provision_machine_daemon` path. This is the direct answer to "reports success
  while shipping nothing": the `--version`-equality short-circuit in
  `provision-daemon.sh` is retained (it is correct once the rebuild is correct)
  but can no longer produce a silent no-op on a real roll — `provision_machine_daemon`
  exports the destination it wrote to (`PROVISIONED_DAEMON_BIN`, set even on the
  short-circuit path) so the caller can verify it. A destination that is not the
  expected build, or a provisioning step that reports failure, now **exits
  non-zero** (`5` for a destination mismatch) instead of the pre-#4053 soft
  warn that left the exit code at `0`.

**Read-only "update available" surface (`loom-daemon status`)**: separately
from the update script, `loom-daemon status` / `loom-daemon status --json` now prints
a purely local, read-only self-update line — the same built-commit-vs-source-HEAD
comparison, computed in-process (`self_update::check()`) with at most one `git
rev-parse` subprocess and zero network calls. It never triggers a rebuild or
restart on its own; it is advisory-only, matching the required "no auto-restart
without opt-in" contract. Example:

```
Self-update: built from ab12cd3 — UPDATE AVAILABLE (source checkout HEAD is de45f67); run `./.loom/scripts/cli/loom-daemon-update.sh` to rebuild + provision + restart
```

`loom-daemon-update.sh` requires an actual Loom source checkout
(`loom-daemon/Cargo.toml` must exist) — it rebuilds from source and refuses to
run against a binary-only / release-tarball install.

### Autonomous self-update loop (#4055)

Phase 3 of #4017 closes the self-repair cycle end to end: when enabled, the
daemon **rebuilds and restarts itself** onto a fresher binary without operator
action, instead of only surfacing the read-only "update available" hint above.
It is the *deciding + sequencing* layer — it reuses `loom-daemon-update.sh`
(driven with `--no-restart`) for the rebuild/provision and the #4090 drain
primitive for the restart, reimplementing neither.

**Opt-in, default OFF** (it has side effects on the running process). Enable via
`autonomous.autoUpdate.enabled` / `LOOM_AUTO_UPDATE=1`; tune the cadence and
settle window with `intervalSecs` (default 900) / `settleSecs` (default 600).
All three knobs resolve **env > config > default** through `config_resolver`, so
the `.loom-project/` tier is honored like every other `autonomous.*` block.

**Exactly one loop per daemon process** — not a `spawn_multi_*` per-workspace
fan-out. Its subject is the daemon process itself (one binary, one source
checkout, one restart), so fanning it out across N registered workspaces would
race N `cargo build`s in one tree and N restarts of one process. Config is read
from the daemon's default workspace; the in-flight count (gate 4) is inherently
cross-root.

Each tick (surfaced in `loom-daemon status` — human and `--json` — as
`auto_update` last-check / last-roll / backoff / terminal fields, all
`#[serde(default)]` wire-compatible):

1. **Staleness** — `self_update::check()`. Only `update_available == Some(true)`
   is actionable; `Some(false)` (current) and `None` (tarball / no checkout /
   `BUILT_COMMIT == "unknown"`) **never** rebuild.
2. **Clean-tree gate** — refuses to build unless the source working tree is
   clean (`git status --porcelain` empty). `CARGO_MANIFEST_DIR` is the operator's
   live checkout, so building it dirty would compile uncommitted work into the
   daemon. It **never** runs `git pull`.
3. **Settle window** — waits `settleSecs` after first observing a stale commit,
   resetting on every further commit, so a burst of daemon merges collapses into
   a single roll.
4. **Build-stampede gate** — defers the rebuild while `ipc::count_in_flight_sweeps`
   reports any non-terminal sweep across every managed root (a `cargo build
   --release` competes with in-flight sweep builds for CPU).
5. **Roll via drain, not a bare restart** — on a clean rebuild it triggers
   `ipc::handle_drain_request` (#4090), so in-flight sweeps finish first and
   survive in the registry rather than being orphaned as bare processes. The
   restart exits into launchd `KeepAlive:SuccessfulExit`, which relaunches from
   the plist's persisted `ProgramArguments`/`EnvironmentVariables` — so the
   daemon comes back with **exactly its prior autonomy flags, never wider** (see
   [Scheduled drain-and-restart](#scheduled-drain-and-restart---drain-4090)).
6. **Backoff + terminal state** — a retryable build failure (script exit `1`,
   spawn/timeout) backs off exponentially (60s → … → 3600s ceiling); a
   commit-identity / build-verification mismatch (#4053 exit `4`/`5`) is
   **terminal** — surfaced in `loom-daemon status`, not retried until the source commit
   advances. A successful roll resets the counter.

### End-to-end acceptance playbook

The goal state — "file a `loom:triage` issue, watch it build" with zero operator
dispatch — is validated by the E2E playbook at
[`docs/autonomous-mode-e2e.md`](https://github.com/rjwalters/loom/blob/main/docs/autonomous-mode-e2e.md)
(upstream Loom repo — not shipped to consumer installs): it walks a
throwaway issue from `loom:triage` → Curator → `loom:issue` → work-finder
dispatch → PR → merge, with a scripted label-transition assertion, and confirms
the operator only ever created the issue.

## Locks and lifecycle

Each dispatched sweep acquires a directory lock under
`.loom/locks/issue-<N>/` via `mkdir` (POSIX-atomic). The lock dir
contains an `owner.json` with the dispatching daemon PID and the sweep
ID. The reaper releases the lock when a child dies; `cancel_sweep`
releases it explicitly. On daemon startup, `SweepRegistry::reconstruct`
admits live-lock owners back into the registry and drops stale locks
whose owner PID is dead.

## What this page does NOT describe

The legacy schema and tuning advice that historically lived here — the
Python `daemon-state.json` schema, `MAX_SHEPHERDS`/`ISSUE_THRESHOLD`
tunables, work-generation cooldowns, `shepherd-N` pool sizing — described
a Python brain that no longer exists. **None of that exists post-v0.10.0.**

- The daemon **does not** generate work. Architect and Hermit cadence
  is out of scope and tracked under follow-up #3381.
- The daemon **does not maintain a shepherd-N pool**. Each issue
  detaches its own `claude -p "/loom:sweep N"` child; concurrency is
  bounded by the daemon's dispatch handling and is operator-controlled
  via separate `dispatch_sweep` MCP calls.
- The daemon **does not track** `pipeline_state`, `warnings`,
  `completed_issues`, or `last_*_trigger`. The forge is the source of
  truth for pipeline state.
- Support roles run as **cron-driven GitHub Actions workflows**, not as
  long-running daemon-managed processes. There is no `JUDGE_INTERVAL`
  or `CHAMPION_INTERVAL` to tune from daemon config.

The decision to delete rather than re-implement the legacy state file
is documented in `docs/migration/daemon-state-consumers.md` §"Conclusion:
what Phase 3 deletes vs preserves".

## Related resources

- **Architecture epic**: [#3449](https://github.com/rjwalters/loom/issues/3449)
  (rebuild of the daemon backend).
- **Phase A** (dispatch surface): #3452 / PR #3459.
- **Phase B** (event bus): #3453 / PR #3460.
- **Phase C** (monitoring + subscription tools): #3455.
- **Migration guide**:
  [`docs/migration/v0.10.0-shepherd-deprecation.md`](https://github.com/rjwalters/loom/blob/main/docs/migration/v0.10.0-shepherd-deprecation.md)
  (upstream Loom repo — not shipped to consumer installs).
- **Config resolution layer** (#4039, Epic #3835 Phase 2): a single resolver
  over private defaults + tracked `.loom-project/project.json` + ignored
  `.loom-local/local.json` + legacy `.loom/config.json`, additive-only (no
  existing call site — including this doc's `.loom/config.json` references
  above — has been migrated onto it yet; see follow-up #4047). Schema,
  precedence, and how it composes with `env > config > default`:
  [`docs/design/config-resolution-tiers.md`](https://github.com/rjwalters/loom/blob/main/docs/design/config-resolution-tiers.md)
  (upstream Loom repo — not shipped to consumer installs).
- **Source** (upstream Loom repo — not shipped to consumer installs):
  - [`loom-daemon/src/types.rs`](https://github.com/rjwalters/loom/blob/main/loom-daemon/src/types.rs) — IPC types.
  - [`loom-daemon/src/sweep_registry.rs`](https://github.com/rjwalters/loom/blob/main/loom-daemon/src/sweep_registry.rs) — registry + reaper.
  - [`loom-daemon/src/event_bus.rs`](https://github.com/rjwalters/loom/blob/main/loom-daemon/src/event_bus.rs) — pub/sub bus.
  - [`loom-daemon/src/ipc.rs`](https://github.com/rjwalters/loom/blob/main/loom-daemon/src/ipc.rs) — request dispatcher.
  - [`mcp-loom/src/tools/sweeps.ts`](https://github.com/rjwalters/loom/blob/main/mcp-loom/src/tools/sweeps.ts) — MCP tool definitions.
