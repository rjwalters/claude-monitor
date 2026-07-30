# Semantic Search Over Sweep History (`loom-search`)

Local-only, **opt-in, off-by-default** search over past sweep summaries and
merged-PR history. Filed as the codecast-evaluation borrow-list item 2
(`docs/research/codecast-evaluation.md`, Question 4) — issue #4339. Tier B
(pluggable local vector embeddings) is a follow-up, #4370.

> **`loom-search` is the last Python in Loom.** Epic #4081 Phase 4 (#4557)
> retired the `loom-tools` Python package: the orchestration layer is the native
> Rust `loom-daemon` binary plus bash, and **a fresh machine provision installs
> no Python at all**. `loom-search` was deliberately carved out of that deletion
> rather than removed silently — it has no native port, and no epic phase ever
> decided whether to port or retire it. Consequences:
>
> - `loom-tools/` still exists, but now contains only `semantic_search.py`,
>   `embedders.py`, and the three `loom_tools/common/` helpers they import.
> - Using this feature requires **one opt-in Python install step** (below).
>   Nothing else in Loom does.
> - Whether to port `loom-search` to Rust or retire the feature is an open
>   product decision tracked in its own follow-up issue; see
>   [ADR-0013](../../docs/adr/0013-loom-tools-python-retirement.md).

## Install

`loom-search` is not installed by `loom install` / `loom update`. Install it
explicitly, from the Loom checkout:

```bash
cd loom-tools

# Tier A only (BM25 ranking via SQLite FTS5) — zero third-party dependencies.
pip install -e .

# Tier B as well (optional local vector embeddings via fastembed).
pip install -e '.[search]'
```

Both forms put a `loom-search` executable on `PATH`. Requires Python >= 3.10.

> Do **not** run `pip install -e` from inside an issue worktree — a
> `PreToolUse` guard blocks it, because editable installs clobber the global
> `.pth` for parallel builders (#2495) and leave frozen console scripts on PATH
> that shadow later installs (incident #4079, the very failure that motivated
> epic #4081). Install from the main checkout.

## Why

Loom has no memory across past sweeps: `.loom/logs/sweep-issue-*.log` and
merged PRs are grep-able and browsable, but not aggregated or ranked.
"Did a past sweep already hit this failure?" is otherwise answered by manual
log archaeology. `loom-search` gives a single ranked query surface over both.

## Enablement

Disabled by default. Enable one of:

- `.loom/config.json`:

  ```json
  { "search": { "enabled": true } }
  ```

- Env override (wins over config in both directions):

  ```bash
  export LOOM_SEARCH_ENABLED=1   # or 0 to force-disable even if config says true
  ```

Resolution precedence is **env > config > default (off)** — the same
convention as `autonomous.*` and `transcriptArchive`.

Tier B (vector embeddings, #4370) is a **separate**, independently opt-in
knob layered on top of the above — see "Tier B" below. `search.enabled=false`
always fully disables `loom-search` regardless of the Tier B provider
setting.

## Usage

```bash
# Build/refresh the index (incremental — a second run with no new sweeps/PRs
# indexes 0 new rows).
loom-search index

# Query (top 10 results by default).
loom-search "token exhaustion"
loom-search --top-k 20 "auth token exhaustion"
```

When search is **disabled**, `loom-search index` is a no-op (no
`.loom/search-index/` directory is created) and `loom-search QUERY` degrades
to a plain, case-insensitive grep over `.loom/logs/sweep-issue-*.log`,
printing a note that the index is disabled and how to enable it.

## What is indexed (v1)

1. **Sweep final summaries** — the tail (~8 KB) of each
   `.loom/logs/sweep-issue-<N>.log`, keyed by the issue number in the
   filename. Full transcripts are **not** indexed (bounds cost; see
   "Out of scope" below).
2. **Merged PR titles/bodies** for the current repo, via
   `gh pr list --state merged --json number,title,body,mergedAt,url --limit
   500` (bounded to the 500 most recent).

Issue-closing-comment ingest is a stretch goal only and is **not** built in
v1 (doc note, not implemented).

## Storage and ranking

- SQLite database at `.loom/search-index/index.db` — repo-local, gitignored.
- Ranking is SQLite **FTS5 + BM25** via the stdlib `sqlite3` module only —
  zero new dependencies, no model download, fully local.
- Indexing is incremental: each sweep log is keyed by its mtime, each PR by
  its `mergedAt` timestamp; unchanged items are skipped on re-index.

### Tier B (vector embeddings, #4370)

A pluggable vector-similarity layer that fuses with (never replaces) the
Tier A BM25 ranking above, via reciprocal rank fusion (`score = Σ 1/(60 +
rank)` over the BM25 top-K and cosine-similarity top-K lists). Off by
default and independent of `search.enabled` — a repo that only wants Tier A
never triggers any of this code, including the import of the provider
module.

**Enablement** — `search.embeddings.provider` in `.loom/config.json` (env
override `LOOM_SEARCH_EMBEDDINGS_PROVIDER`), same **env > config > default**
precedence as `search.enabled`:

```json
{ "search": { "enabled": true, "embeddings": { "provider": "local" } } }
```

| Provider | Behavior |
|---|---|
| `"none"` (default) | No embeddings. Ranking is exactly the Tier A BM25 path — byte-identical to before #4370. |
| `"local"` | A small local ONNX model via the optional [`fastembed`](https://github.com/qdrant/fastembed) package, gated behind the `search` extra (`cd loom-tools && pip install -e '.[search]'` — see [Install](#install)). CPU-only; never a default/required dependency. |

A remote-API provider is **explicitly out of scope** for #4370 — file a
follow-up `loom:triage` issue if one is needed.

**How it works**:

- Embeddings are computed incrementally, piggybacking on the same
  per-document watermark Tier A already uses — an unchanged sweep log or PR
  is never re-embedded on re-index.
- Vectors are stored in the existing `embeddings` table as little-endian
  float32 blobs (`(source_type, source_id, model)` primary key), so
  switching models never collides with a prior model's vectors.
- Query-time similarity is brute-force cosine similarity in pure Python —
  sufficient at this corpus size; no vector-index dependency
  (`sqlite-vec`/`faiss`) is added.
- If `provider=local` is configured but `fastembed` isn't installed:
  **index time** hard-errors naming the install hint above; **query time**
  prints a loud warning to stderr and degrades to the unmodified Tier A
  BM25 ranking rather than failing the query.
- If a document has no stored embedding yet (e.g. indexed before Tier B was
  enabled, or a corrupt/short vector blob), it's skipped in the
  cosine-similarity ranking (with a warning for a corrupt blob) — RRF still
  runs with whatever BM25 and cosine data is available.

## Threat model

- **What is indexed**: sweep-log tails (may reference issue numbers, error
  messages, and file paths already local to this repo/host) and merged PR
  titles/bodies (already public/forge-hosted content for this repo).
- **Where it lives**: `.loom/search-index/index.db`, on this host only,
  under the repo working tree. It is gitignored — a runtime
  gitignore-or-refuse guard (mirroring
  `defaults/scripts/archive-transcripts.sh`) additionally refuses to write
  the index if that entry is ever removed from `.gitignore` and the
  destination is not otherwise ignored.
- **What leaves the host**: nothing, by default. The only network traffic is
  the `gh pr list` forge read during `loom-search index` — the same
  coordination-layer read every other Loom role already performs, not a sync
  of local data off-host.
- **Tier B (`search.embeddings.provider=local`, #4370)**: the **only**
  additional outbound call is the one-time `fastembed` ONNX model download,
  which happens on first construction of the local embedder (first `loom-search
  index` run with `provider=local` for a given model). It is an explicit,
  documented model-weights fetch — not telemetry and not a sync of indexed
  content. Every subsequent `embed()` call (indexing or querying) is fully
  offline: the model runs locally, and no indexed sweep-log/PR text is ever
  transmitted anywhere. A remote embeddings provider remains out of scope for
  #4370 and would need its own opt-in and its own documented network
  behavior here before it ships.

## Out of scope

- Remote-API embeddings provider (deferred from #4370 — file a follow-up
  `loom:triage` issue if needed).
- Raw-transcript indexing over the #3726 transcript archive.
- Issue-closing-comment ingest.
- Any daemon/MCP surface — `loom-search` is a plain CLI.
- Any networked storage backend.
- A vector-index dependency (`sqlite-vec`/`faiss`) — brute-force cosine
  similarity in pure Python is sufficient at this corpus size.
