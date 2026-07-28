# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
