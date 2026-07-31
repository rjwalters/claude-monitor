# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.18.1] - 2026-07-31

### Summary

Emergency patch: multi-host `accounts import` could destroy a Claude account's
credential when an OpenAI account shares its email address.

### Fixed

- **`accounts import` email matching is provider-scoped.** A Claude and a
  ChatGPT account legitimately share one address; the unscoped match landed an
  imported OpenAI account on the local Anthropic row, flipping its provider and
  overwriting its credential in place — destroying the Claude token. The match
  is now scoped to the incoming account's provider, mirroring the guard `codex
  import` gained in 1.18.0. Hosts that already lost an account this way can
  recover the history by reassigning non-wham-shaped `usage_history` rows (and
  `fable`/`haiku` `probe_snapshots`) back to the Anthropic org id and
  re-importing a valid token
- **Healing migration merges duplicate provider accounts sharing an email.**
  `10660f3` only stopped a *fresh* `codex import` from forking a second row for
  an OpenAI account whose original row predated the native-id era (keyed by a
  locally generated UUID); a database where the duplicate already existed kept
  both rows polling the same account independently. At launch, account pairs
  sharing `(email, provider)` are now merged automatically: history moves onto
  the surviving row (preferring the provider-native id), exactly one
  credential survives (the more recently renewed of the two), and the sibling
  row is removed. Idempotent, and covered by a selftest over a scratch DB (#45)

## [1.18.0] - 2026-07-30

### Summary

Multi-provider support: ChatGPT/Codex subscription accounts are now monitored
alongside Claude accounts, sharing the same table, headroom score, and
`ranking.json` export.

### Added

- **OpenAI/Codex account monitoring.** `claude-monitor codex import` registers a
  Codex CLI credential (`~/.codex/auth.json`, honoring `$CODEX_HOME`); usage is
  polled from `chatgpt.com/backend-api/wham/usage` and shown beside Anthropic
  accounts (#25, #29, PR #31)
- **Provider-agnostic rate-limit model.** A shared window type both providers
  populate, with window kind derived from its duration rather than its position
  in the response. `Account` gains `provider`, `refresh_token` and
  `token_expires_at`, migrated in place (#28, PR #30)
- **Proactive token refresh.** OpenAI access tokens live ~10 days (not ~1 year
  like Anthropic's), so they are renewed before expiry from the stored refresh
  token; a failing renewal surfaces a visible token-health state rather than
  silently stale data (#29, PR #31)
- **`ranking.json` carries `provider`.** Additive — `schema` stays 1. A
  `provider: openai` account may omit `utilization["5h"]`; consumers must read a
  missing key as *unknown*, never 0 (#29, PR #31)
- **Per-model sub-limits.** OpenAI's `additional_rate_limits[]` is persisted to a
  `named_limits` table and overlaid on the per-account history chart, hidden for
  accounts that have none (#32, PR #33)
- **Pixel-art provider badges.** Each row is tagged with its upstream's mark,
  drawn from bitmaps so the package still ships no image resources (#35, #36,
  #37, PRs #35/#36/#37)
- **`selftest` subcommand.** Portable-core assertions runnable on macOS and
  Linux with no network or credentials, wired into CI. `--wire <path>` decodes a
  captured usage body offline to re-check the OpenAI contract (PR #30)

### Fixed

- **`codex import` no longer duplicates an existing OpenAI account.** The
  import now matches an existing row by email within the provider before
  keying a new one by OpenAI's native account id — rows created before the
  native-id era are keyed by a locally generated UUID, and upserting on id
  alone created a second row for the same account on re-import
- **Account names sort naturally.** `agent-10` now follows `agent-9` instead of
  sorting between `agent-1` and `agent-2`; equal-usage accounts tie-break on
  display name rather than account id (#40, PRs #34/#43)
- **Build no longer ships a stale User-Agent silently.** Version detection
  prefers `claude --version` (the binary actually on PATH, current under the
  native installer's self-update) over the npm global listing — a vestigial npm
  install would otherwise patch the User-Agent backwards — and hard-fails when
  no version is detectable at all (#39, PR #44)

### Documentation

- The OpenAI wire contract is recorded in `docs/spikes/`, live-verified against a
  real account (#26, PR #27, corrected in 517c1f5)
- CI is documented as authoritative for Swift strict-concurrency diagnostics — a
  clean local `swift build` is not sufficient evidence, since toolchain versions
  disagree on that class (#41, PR #42)

## [1.17.0] - 2026-07-30

### Summary

Multi-host account sync. The headless binary gains `accounts export` /
`accounts import` subcommands for converging account records and credentials
across machines, alongside email-integrity fixes and a Linux CI job.

### Added

- **`accounts export` / `accounts import` CLI.** One-shot, headless-safe
  subcommands to sync account records + credentials between hosts:
  `claude-monitor accounts export --output accounts.json` on the source,
  `claude-monitor accounts import accounts.json` (or stdin) on the target.
  Exports carry plaintext OAuth tokens — `--output` files are written `0600`
  and a warning prints either way. Imports are idempotent, match by email,
  preserve local ids, respect newer local records, and support `--dry-run`
  and `--db <path>` (#16, #22)
- **Linux CI job.** `build-linux` builds the headless target in the
  `swift:6.1` container and smoke-runs `--once` with no credentials; the
  existing macOS job is renamed `build-macos` (#13, #24)

### Fixed

- **Accounts can no longer persist with `email=NULL`.** Email is backfilled
  from a well-formed `account_name` label on rename, and a one-time healing
  migration repairs already-broken rows at launch (#15, #23)
- **`icon-master.source.json` sha256** now matches the tracked master PNG —
  the recipe recorded the pre-squircle-mask hash; a `post_processing` note
  prevents future drift (#19, #20)
- **`claude-monitor.service`** drops the `network-online.target` ordering,
  which is a no-op in the systemd user manager (#14, #17)

### Changed

- **`package.json` check scripts are real.** `check:ci`/`test`/`check:all`
  now run `swift build`/`swift test`, so orchestration build gates actually
  gate (#18, #21)

## [1.16.0] - 2026-07-28

### Summary

Headless Linux support. The package now builds and runs on Linux hosts as a
UI-less daemon for Loom worker fleets — same poll loop, same `usage.db` and
`ranking.json` — plus a new app icon and a documentation catch-up.

### Added

- **Headless mode / Linux support.** The package now builds on Linux
  (`libsqlite3-dev` + Swift toolchain) as a UI-less daemon for Loom hosts: the
  same poll loop (account-file sync, 10-min usage pings, 20-min Fable probes)
  writing the same `~/.claude-monitor/usage.db` and `ranking.json`. On macOS
  the loop is reachable via `ClaudeMonitor --headless`. Flags: `--once`,
  `--interval <sec>`, `--version`; account list files are re-imported on
  change while running. Includes a sample systemd unit
  (`scripts/claude-monitor.service`). UI sources are fenced with
  `#if os(macOS)`; a new `CSQLite` system-library target maps Linux's
  libsqlite3, and rate-limit headers are now parsed from the lowercased
  captured map (Linux `allHeaderFields` lookups are case-sensitive).

- **App icon.** Custom gauge-dial icon (generated with
  [Imagine](https://github.com/rjwalters/imagine)); `Assets/AppIcon.icns` is
  now bundled by `build-macos-app.sh` and referenced via `CFBundleIconFile`.

### Changed

- **Docs.** README now documents the Roll Token workflow — wizard steps, the
  undocumented cookie-authenticated `claude.ai/api/oauth` endpoint dependency,
  upstream tracking issues, and the ping-based revocation verification (#11) —
  and gains an "Upgrading from pre-1.8" note in Uninstall about stale Node CLI
  artifacts (#10). Both README screenshots retaken against the 1.15 UI (#12).

## [1.15.0] - 2026-07-26

### Summary

Multi-account token management. Adds a guided workflow for rotating long-lived
OAuth tokens, cross-machine account transfer, and premium/Fable usage tracking.

### Added

- **Roll Token workflow.** A per-account "Roll Token…" context-menu action opens
  a guided wizard to rotate a Claude Code long-lived token: open the claude.ai
  token settings, run a generated revoke-all browser-console script, mint a fresh
  token with `claude setup-token`, and paste it back. The app imports the new
  token and independently verifies the old one is revoked via a ping check. This
  is a temporary workaround pending an official Anthropic token-management API
  (see issue #6).
- **Copy/Paste Accounts buttons.** Export the active account list (email + token
  pairs) to the clipboard and import it on another machine for cross-machine
  transfer.
- **Fable/premium usage tracking.** Probes the premium (Opus/Fable) tier and
  surfaces its weekly allocation and extra-usage (overage) columns, alongside a
  master account list.
- **Ranking export.** Emits `~/.claude-monitor/ranking.json` for external load
  balancers.

### Changed

- Token paste now strips all whitespace, so tokens copied line-wrapped from a
  terminal import correctly.
- Popover height auto-fits the number of accounts.
- Each account is polled once per 10 minutes instead of round-robin.

## [1.14.0] - 2026-07-11

### Summary

Zero-dependency build. The SQLite.swift package is replaced by a minimal
in-tree wrapper over the system SQLite that ships with macOS, eliminating the
app's only upstream dependency and producing real SQLite error messages in
the log.

### Changed

- **SQLite.swift dependency removed.** A new `SQLiteDB.swift` wraps the system
  `libsqlite3` C API, mirroring the subset the app used (raw SQL with `?`
  placeholders, index-subscriptable rows, busy timeout). The handful of typed
  `Table`/`Expression` query sites are rewritten as plain SQL.
- **Real SQLite error messages.** Database failures now log `sqlite3_errmsg()`
  text (e.g. `attempt to write a readonly database`) instead of opaque codes
  like `SQLite.Result error 0`.

### Removed

- `SQLite.swift` package dependency and `Package.resolved` — the package now
  builds with no external dependencies.

## [1.13.1] - 2026-07-11

### Summary

Reliability release. Hardens SQLite access against lock contention that could
stall the app at launch before the menu-bar icon appeared, and adds startup
phase logging so any future launch stall is diagnosable from `debug.log`.

### Changed

- **SQLite connections now use a 5-second busy timeout.** All database opens go
  through a shared `openDatabase()` helper, so concurrent access from other
  processes waits briefly for locks instead of failing immediately with
  `SQLite.Result error 0`.
- **Startup phases are logged.** `applicationDidFinishLaunching` logs database,
  status-item, and popover milestones, so a launch that stalls before the
  menu-bar icon appears shows exactly where it stopped.

### Fixed

- `ensureDatabase` failures are now written to `~/.claude-monitor/debug.log`
  via `FileLogger` instead of being lost on stdout.

## [1.13.0] - 2026-05-27

### Summary

Inline-edit account aliases directly from the summary table. Double-click an
account name to rename it, with a one-click restore-default button to clear
the alias and fall back to the email.

### Added

- **Double-click an account name to rename it.** The summary table's Account
  column is now an editable field on double-click — useful for aliasing
  accounts to something shorter or more meaningful than the email.
- **Restore-default button in rename mode.** A small counterclockwise-arrow
  button appears next to the save/cancel controls when a custom alias is set;
  click it to clear the alias and fall back to the email-based default name.

### Changed

- `UsageStore.updateAccountName` now accepts `String?` so callers can clear an
  alias by passing `nil`.

## [1.12.0] - 2026-05-25

### Summary

UX overhaul of the menu-bar popover. The vertical scroll-card dropdown is
replaced with a sortable summary table; users can now pin which account drives
the menu bar, sort by any column, see at-a-glance Headroom scores, and launch
multiple usage-history charts from a popover that stays open.

### Added

- **Summary table as the default popover view.** Click the menu-bar icon and
  the table opens directly.
- **Headroom score column.** A 0–100 score —
  `100 − max(sessionPct, weeklyPct)` — answering "which account should I be
  using". Color-coded and the default sort.
- **Clickable sortable column headers.** Sort by Account, Headroom,
  Session %, Sess Reset, Weekly %, Wk Reset, Fresh, or Token; chevron marks
  the active column; click again to flip direction. Rows without data always
  sort to the bottom.
- **Menu-bar source radio column.** Pin which account's percent appears in the
  menu bar. Click again to clear and revert to auto-pick. Persisted across
  launches in the `settings` table.
- **Per-row History column.** Launches the detailed usage-history chart for
  that account; the popover stays open so you can open several at once.
- **Right-click row context menu.** Open History / Rename / Remove on any row.

### Changed

- Popover behavior `.transient` → `.semitransient` — interacting with chart
  windows no longer dismisses the popover.
- Bulk import (and single-token add) now triggers a full `refreshAll`, so
  newly-imported accounts appear immediately with correct token-status
  indicators.
- Menu bar follows the user's pinned account if set; falls back to
  most-available otherwise.
- Popover width 320 → 690 to fit the table.
- Repository default branch renamed `master` → `main`.

### Removed

- Standalone Account Summary window (its contents are now the popover).
- Vertical scroll-card popover and the underlying `AccountCard`,
  `ClickableAccountCard`, `EditableAccountCard`, `CardButtonStyle`, and
  `UsageRow` view types.

## [1.11.0] - 2026-02-21

Placeholder entry — this release predates the CHANGELOG and its notes were not
recorded at the time. Reconstructed from git history:

### Added

- Account Summary shows separate session and weekly reset columns.
