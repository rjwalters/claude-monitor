# CI Observability: every build and CI run is captured in SigNoz

> Standing policy, issue [#8827](https://github.com/rjwalters/loom/issues/8827)
> (phase 4 of the build/CI-in-SigNoz set under epic
> [#8522](https://github.com/rjwalters/loom/issues/8522)). This page is the
> policy and an operating map — it states what must be captured and links the
> detail docs that say how. It is not a duplicate of them, and it should stay
> a map as they grow.

## The policy

**Every GitHub Actions run of every `2amlogic` repository — its runs, jobs,
durations, outcomes, and completed-job logs — is captured in SigNoz** by the
`loom-daemon ci-telemetry` poller. Capture is **org-scoped**: a new repo or a
new workflow is in scope on the day it appears, found by auto-discovery, with
no per-repo enrollment step to forget. **Run/job duration and outcome metrics
are never excludable** — not per repo, not per workflow, not temporarily. **Log
capture may be excluded for one repo only with a stated reason recorded in
that config entry itself**, reviewed like any other config change; an
exclusion without a reason is a policy violation, and there are no silent or
undocumented exclusions.

Why this is a standing rule rather than a one-off investigation: build and CI
time regressions are felt long before they are seen. The #7779 cancellation
storm (of the last 30 `main` runs, 22 cancelled) got a fix, but it was
weeks-invisible because nothing recorded CI time or outcome over time. This is the
observability face of the same family as
[`ci-principles.md`](ci-principles.md) — a check that cannot run must not look
like a check that passed, and a CI system nobody measures cannot be trusted to
be getting better.

## The pipeline, in one picture

```
GitHub Actions (every 2amlogic repo, auto-discovered)
        │  REST: org repos (ETag-cached) → runs (created_after watermark) → jobs
        │        → completed-job log zip (phase 2)
        ▼
loom-daemon ci-telemetry poller (per host; one poller is the normal case)
  durable dedup ledger  .loom/state/ci-telemetry/seen.jsonl  (exactly once per job)
  local journal         .loom/logs/ci-telemetry.jsonl        (written with no exporter)
        │  records: ci.run, ci.job, ci.job.log
        │  metrics: loom.ci.run.duration_ms, loom.ci.job.duration_ms
        │  traces:  one trace per run, one span per job
        ▼
observability OTLP exporter (the existing durable queue + drain loop)
        │
        ▼
neutral OTLP gateway — the REDACTION BOUNDARY
  ci.job.log scrub stage → shared transform/privacy allowlist (keep_keys)
        │
        ▼
SigNoz (trial deployment; managed cloud optional) — the named retro surface
```

Nothing new is invented for transport: the poller is a new **source** on the
pipeline [`observability.md`](observability.md) already documents. Where each
hop is specified:

| Hop | Detail doc |
|---|---|
| Record kinds, envelope, local-journal conventions | [`telemetry-schema.md`](telemetry-schema.md) |
| OTLP exporter, response classification, retry/drop policy | [`otlp-transport.md`](otlp-transport.md) |
| Exporter config, fan-out, "is it actually flowing" | [`observability.md`](observability.md) §1, §3, §3b |
| Gateway: allowlist, privacy stance, contract tests | [`defaults/observability/collector/README.md`](https://github.com/rjwalters/loom/blob/main/defaults/observability/collector/README.md) |
| SigNoz trial: deploy, saved views, retention mechanics | [`defaults/observability/signoz/README.md`](https://github.com/rjwalters/loom/blob/main/defaults/observability/signoz/README.md) |
| Why CI is measured at all | [`ci-principles.md`](ci-principles.md) |

## Phases

| Phase | Delivers | Issue | Status |
|---|---|---|---|
| 1 | `loom-daemon ci-telemetry` poller: `ci.run`/`ci.job` records, duration histograms, run→job traces, dedup ledger, local journal, `status` | [#8824](https://github.com/rjwalters/loom/issues/8824) | Landed — see [Phase 1 reference](#phase-1-reference-runs-and-jobs-8824) |
| 2 | Full completed-job logs as chunked `ci.job.log` records, with secret redaction enforced at the gateway | [#8825](https://github.com/rjwalters/loom/issues/8825) (blocked by #8824) | Open |
| 3 | SigNoz retro surfaces (`ci-queries.sql`, six saved views) and the metrics ≥30d retention split | [#8826](https://github.com/rjwalters/loom/issues/8826) (blocked by #8824/#8825) | Open |
| 4 | This policy doc and its wiring | [#8827](https://github.com/rjwalters/loom/issues/8827) | This doc |

Each phase adds its own reference section (config keys, dedup contract,
journal schema, chunking contract, standing queries) to this page when it
lands. Phase 1's poller ships **off by default** (FLAGS-OFF): the policy is
enforced only on a host where [Rollout](#rollout) has enabled it.

## Capture scope & exclusions

- **Scope is the org, not a repo list.** The `org` key of the
  `autonomous.ciTelemetry` config block (default `2amlogic`) names the captured org; repo
  discovery walks it on every poll. There is no allowlist of repos to keep in
  sync.
- **Metrics and run/job records are unconditional.** Durations, outcomes
  (success, failure, **cancelled** — a first-class outcome, never noise), and
  the `ci.run`/`ci.job` records are emitted for every repo in the org. A
  config surface that would suppress them for a repo does not satisfy this
  policy. Phase 1's repo-exclusion key (`excludedRepos`) therefore carries the
  same reason requirement and every entry is a **policy exception** reviewed
  here: an entry is admitted only as `{"repo": …, "reason": …}` in committed
  config. A bare name, a blank reason, or a value from `.loom-local` is
  refused by name and the repo **stays polled**, and there is no env override.
- **Log capture is the only excludable signal**, per repo, and each exclusion
  is a config entry **with a `reason` field** stating why (e.g. a repo whose
  logs cannot be adequately scrubbed yet). The exact key shape is defined by
  #8824 (`logCaptureEnabled` gate) and #8825 (log download); whatever shape
  lands, an entry without a reason is rejected in review.
- **Exclusions are reviewed like any other config change** — they live in the
  committed `.loom/config.json`, never in a host-local override tier, so they
  are visible in `git log` and to every host.

## Retention

| Signal | Retention | Why |
|---|---|---|
| Metrics (`loom.ci.*.duration_ms`, outcome counts) | **≥ 30 days** | Trends are the retro asset — "is CI getting slower" needs weeks of history, and metrics are cheap relative to logs |
| Logs (`ci.job.log`) and traces | **7 days** | Raw detail is for recent investigation; a regression is found by trend, then read in a recent run |

Trends outlive raw data by design. Implementation — the SigNoz retention
settings plus `retention.sql` for tables the pinned API misses, verified
against effective ClickHouse DDL rather than the API setting — is owned by
[#8826](https://github.com/rjwalters/loom/issues/8826); the signoz README's
"Retention and operation" section documents the current (pre-#8826) seven-day
trial setting.

## Redaction policy

**The gateway is the redaction boundary** (operator decision). The daemon
sends what GitHub sent, chunked and size-capped, with no pre-filtering; the
gateway's `ci.job.log`-specific transform stage scrubs secrets before the
shared `transform/privacy` allowlist, and both sinks receive only the scrubbed
output. The scrubber list lives in the repo, and a new secret family is added
to the list **and** the contract test in the same PR.

Scrub classes (each replaced with `[REDACTED:<class>]`), from #8825's design:

| Class | Matches |
|---|---|
| GitHub tokens | `ghp_`, `gho_`, `ghu_`, `ghs_`, `ghr_`, `github_pat_` prefixes |
| Anthropic keys | `sk-ant-` prefix |
| Other `sk-` bearer shapes | only when preceded by a key-ish context word (to avoid scrubbing prose) |
| AWS | `AKIA[0-9A-Z]{16}` access key IDs; `aws_secret_access_key` assignments |
| Auth headers | `Bearer <token>` and `Authorization:` header lines |
| Credential assignments | `password=…`, `secret=…`, `token=…` values |

`ci.job.log` is the **first and only** record kind whose body survives
`transform/privacy`; the exception is scoped to that kind and named
explicitly in the gateway's allowlist contract test. No other kind's handling
changes.

What this store is and is not: SigNoz here is a **trusted private operational
store**, not the public dashboard projection — the same framing as the
collector README's "Privacy and remote deployment" section. Nothing captured
under this policy flows to `/public/*` or any unauthenticated view.

## Rollout

Enabling capture is a per-host config operation, performed once #8824 (and,
for logs, #8825) has merged and the SigNoz trial is confirmed receiving:

1. The host already exports OTLP to the gateway — an `observability.exporters`
   entry `{ "kind": "otlp", "endpoint": "<gateway>" }` per
   [`observability.md`](observability.md) §3, confirmed healthy with
   `loom-daemon status --json | jq -e '.observability_exports.otlp.state == "healthy"'`.
2. Enable the poller with `autonomous.ciTelemetry.enabled = true` (FLAGS-OFF
   by default; `LOOM_CI_TELEMETRY_*` env overrides, **env > config >
   default**). Log capture is a separate gate (`logCaptureEnabled`, phase 2).
3. Confirm with `loom-daemon ci-telemetry status` — it distinguishes
   never-polled, last-ok + age, and failing + last error, so silence never
   reads as healthy.

**One poller is the normal case.** Records carry stable `run_id`/`job_id`
identities so a second poller on another host is deduplicable downstream, but
there is no per-repo lease protocol and none should be invented (one mechanism
per behaviour). Pick one fleet host to run capture.

**Destination.** The self-hosted SigNoz trial is the destination. SigNoz Cloud
remains optional — swapping only the gateway's exporter endpoint, per the
signoz README — and is not a prerequisite for this policy.

## Phase 1 reference: runs and jobs (#8824)

### What it is

A `loom-daemon ci-telemetry` poller. Each cycle it:

1. Lists the org's repositories (`GET /orgs/{org}/repos`, paginated). Each
   page is ETag-cached on disk, so an unchanged org costs `304 Not Modified`
   responses, which do not count against the rate limit. Archived repos and
   `excludedRepos` are skipped.
2. Per repo, lists workflow runs created since that repo's **watermark**
   (`GET /repos/{o}/{r}/actions/runs?created=>=<watermark>`, paginated).
3. For each **completed**, not-yet-recorded run attempt, lists its jobs
   (`GET …/runs/{id}/jobs?filter=all`, paginated). Every job it finds (all
   attempts) and the run itself are recorded **exactly once**.

Runs that are still in progress are not recorded yet. The watermark stays at
the oldest unfinished run so that a later poll lists it again once it
completes.

### Surfaces

| Command | Does |
|---|---|
| `loom-daemon ci-telemetry --once [--org ORG] [--workspace PATH]` | One poll cycle. Runs whether or not `enabled` is set. |
| `loom-daemon ci-telemetry status [--json]` | Health, ledger size, per-repo watermarks, records emitted/exported. |
| Daemon poller | Runs every `intervalSecs` when `autonomous.ciTelemetry.enabled=true`. |

`--once` exit codes:

- `0`: the cycle completed cleanly.
- `1`: the cycle failed. The printed reason is one of `discovery-failed`,
  `io-failed`, or `N repo(s) failed` with the first repo's reason.
- `75`: skipped, and the caller must wait. Either another cycle holds this
  host's lock (`busy`), or the org is in a rate-limit backoff (`rate-limited` /
  `backing-off`).

`status` reports one of four health states. A poller that has gone quiet
never shows as healthy:

| State | Meaning |
|---|---|
| `never-polled` | No cycle has run on this host. |
| `ok` | The last cycle succeeded. The output includes its age. |
| `stale` | The last cycle succeeded, but more than 3× `intervalSecs` ago. |
| `failing` | The last cycle failed. The output includes the last error, the consecutive failure count, and any active backoff. |

### Config reference

`.loom/config.json` → `autonomous.ciTelemetry`. Precedence is
**env > config > default**, the same as every other `autonomous.*` block.

| Key | Env override | Default |
|---|---|---|
| `enabled` | `LOOM_CI_TELEMETRY_ENABLED` | `false` (off by default) |
| `org` | `LOOM_CI_TELEMETRY_ORG` | `"2amlogic"` |
| `intervalSecs` | `LOOM_CI_TELEMETRY_INTERVAL_SECS` | `120` |
| `excludedRepos` | none (committed config only) | `[]`. Each entry is `{"repo": "<name or owner/name>", "reason": "<why>"}`, and `repo` matches case-insensitively. See [Capture scope & exclusions](#capture-scope--exclusions). |
| `logCaptureEnabled` | `LOOM_CI_TELEMETRY_LOG_CAPTURE_ENABLED` | `false` |

`logCaptureEnabled` is the switch for the phase-2 job-log download. **Phase 1
does not honour it.** This build contains no log-capture code, so if the key
is set, the poller logs a warning that the request was refused and `status`
reports `requested but refused: job-log capture is not implemented in phase 1`.

The first poll of a repo, before it has a watermark, looks back 24 hours.
Requests go through `gh api` (`$LOOM_GH_BIN` overrides the binary), with the
same credentials as every other forge call the daemon makes.

### Rate limits

Each interval makes about one discovery request per page, plus one runs
listing per repo, plus one jobs listing per newly completed run. A `403`
rate-limit response, a secondary limit, or a `429` **backs off the whole org**,
never a single repo:

- The backoff lasts until `Retry-After` if the response has one, otherwise
  until the `X-RateLimit-Reset` epoch, otherwise exponentially (60s doubling,
  capped at 1h).
- The failure is fed to the daemon's rate-limit breaker.
- Every cycle inside the window makes zero requests. This includes cycles
  while the daemon's global breaker is cooling down.

Any other failure in a repo is recorded, and the cycle moves on to the next
repo.

### Dedup contract: never record the same job twice

Everything below lives under `.loom/state/ci-telemetry/`, which is
gitignored.

- **`seen.jsonl` is the ledger.** It is append-only. Each `unit` line holds
  one run or job's key `(repo, run_id, job_id)` and its run attempt, a
  sequence number, and the exact envelopes it will emit. **Appending and
  fsyncing that line is the commit.** After that, no re-poll will build the
  unit again. A `watermark` line records a repo's newest observed
  `run.created_at`. An `emitted` line confirms that every unit up to a given
  sequence number has reached the journal.
- **Commit first, then emit.** For each run, the job units are committed
  first and the run unit last, all in a single fsynced append. Their
  envelopes are then appended (and fsynced) to the journal, and the batch is
  confirmed.
- **Crash between commit and emit.** At the start of every cycle, any
  committed unit that has not been confirmed is replayed. Envelopes the
  journal already holds are skipped, matched by stable identity. So a crash
  anywhere in the pipeline produces each record exactly once, and never
  twice.
- **Torn tail.** A crash in the middle of an append can leave a partial
  trailing line. The next cycle detects it and truncates the ledger or
  journal back to its last complete line, and the partial entry is never
  counted. Because the run unit is written last, a torn commit can only lose
  that run unit. The run therefore stays "unseen", and the next poll re-lists
  its jobs and commits only the missing ones.
- **Re-runs.** A new attempt of a run already recorded (within the watermark
  window) becomes a new `ci.run` for that attempt. Only its new jobs are
  recorded, because GitHub gives them new `job_id`s. A re-run of a run
  created before the watermark is not seen; the watermark is keyed on
  `created_at`.
- **Compaction.** When the ledger grows past 8 MiB and nothing is pending,
  it is rewritten atomically as key-only `seen` lines.
- **One poller per host.** A `flock` on `poll.lock` stops the CLI and the
  daemon poller from racing each other on one host.
- **Multiple hosts.** Running one poller per org is the normal case. There
  is deliberately no cross-host lease: coordination is out of scope, per the
  one-mechanism-per-behaviour rule. Every record has stable identities:
  `run_id`/`job_id`, plus trace and span ids derived from
  `(repo, run_id, attempt[, job_id])`. If a second host polls the same org,
  it produces identical keys that a backend can deduplicate on.

### Local journal schema

`.loom/logs/ci-telemetry.jsonl` is written **regardless of exporter
configuration**, following the `sweep-outcome-telemetry.jsonl` pattern, so the
poller is useful offline. Each line is a
[`TelemetryEnvelope`](telemetry-schema.md) with `schema_version: 8`. Each
completed job produces three lines, and so does each completed run:

| `record.kind` | Fields | OTLP signal |
|---|---|---|
| `ci.run` | `repo`, `visibility`, `run_id`, `run_attempt`, `workflow`, `ref`, `head_sha`, `event`, `status`, `conclusion`, `triggered_by`, `started_at`, `completed_at`, `duration_ms` | log record `ci.run`, timestamped at `completed_at` |
| `ci.job` | `repo`, `visibility`, `run_id`, `job_id`, `workflow`, `job`, `runner` (first runner label), `attempts` (the job's run attempt), `status`, `conclusion`, `timed_out`, `started_at`, `completed_at`, `duration_ms` | log record `ci.job` |
| `ci.duration` | `metric` (`run`\|`job`), `repo`, `visibility`, `run_id`, `run_attempt`, `job_id`, `workflow`, `job`, `runner`, `conclusion`, `started_at`, `completed_at`, `duration_ms` | one data point of the `loom.ci.run.duration_ms` / `loom.ci.job.duration_ms` delta histogram |
| `trace.span` | `loom.ci.run` (root) or `loom.ci.job` (child of its run span) | trace: one per run attempt, one span per job |

Why `ci.duration` is a separate record: each envelope maps to exactly one
OTLP signal, because the exporter acknowledges contiguous same-signal
batches. A `ci.run` log record therefore cannot also be a histogram data
point. The `ci.run`/`ci.job` log records carry the trace context of their
span, so logs and traces are correlated.

The daemon's observability backfill pass exports the journal. Each pass
offers every line past a byte cursor (`export-cursor.json`) to the configured
exporter queue(s), so records reach SigNoz whenever `observability` is
enabled. Only complete lines are read.

### Attribute allowlist

The attribute and label vocabulary is declared once, in
`loom-daemon/src/telemetry/ci.rs`:

- `CI_LOG_ATTRIBUTE_KEYS`: the `loom.ci.*` log attributes. Log records also
  carry the shared `loom.repo` and `loom.repo.visibility`.
- `CI_SPAN_ATTRIBUTE_KEYS`: the `loom.ci.*` span attributes.
- `CI_METRIC_LABEL_KEYS`: the metric labels, and **only** these:
  `repo`, `workflow`, `job`, `runner`, `conclusion`. Metric labels never
  include a sha, ref, run id or issue number.

The gateway's `transform/privacy` `keep_keys` lists in
`defaults/observability/collector/config.yaml` list exactly these keys.
Two tests fail if the config and the constants disagree:
`ci_telemetry::tests::collector_allowlist_matches_the_ci_vocabulary_exactly`
and `collector_fanout::gateway_forwards_exactly_the_ci_telemetry_vocabulary`.

### Non-goals (phase 1)

- No job-log download. `logCaptureEnabled` is refused by name.
- No per-step spans. The job is the unit.
- No re-hosting of GitHub's log UI.
- No cross-host lease.
- No changes to the `sweep.*` or `tokens.*` record kinds.
