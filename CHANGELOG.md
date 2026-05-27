# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
