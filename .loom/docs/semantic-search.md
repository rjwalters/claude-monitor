# Semantic Search Over Sweep History (`loom-search`)

Local-only, **opt-in, off-by-default** search over past sweep summaries and
merged-PR history. Filed as the codecast-evaluation borrow-list item 2
(`docs/research/codecast-evaluation.md`, Question 4) — issue #4339.

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

### Tier B (vector embeddings) — not built in v1

The schema includes an `embeddings` table placeholder and an `Embedder`
protocol stub so a follow-up can add local (e.g. an ONNX model behind a
`loom-tools[search]` optional extra) or remote embeddings, each gated by its
own separate opt-in (a future `search.embeddings.provider` config key,
default none). **No heavyweight ML dependency ships in this v1.** See the
follow-up issue linked from PR #4339's implementation for the Tier B design
discussion.

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
  of local data off-host. If a future Tier B enables a remote embeddings
  provider, that call (and its own opt-in) will be documented here at that
  time; v1 makes no such call.

## Out of scope (v1)

- Vector embeddings / any model download (Tier B follow-up issue).
- Raw-transcript indexing over the #3726 transcript archive.
- Issue-closing-comment ingest.
- Any daemon/MCP surface — `loom-search` is a plain CLI.
- Any networked storage backend.
