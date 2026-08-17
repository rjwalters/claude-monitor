# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.20.0] - 2026-08-17

### Summary

The Codex-identity ergonomics that 1.19.0 deferred. Standing up a Codex home is
now one command (`codex provision <label>`), `codex list` discovers homes on
disk that were never registered and reports a home that has been re-logged-in
as someone else, the poller adopts such a re-logged-in identity instead of
freezing on it, and a declared-but-unprovisioned identity is shown as
**absent** everywhere accounts appear — the popover, `codex list`, and
`ranking.json`. Underneath, a single poll-interval-derived staleness rule now
gates every surface, so neither a popover row nor the menubar badge can present
a frozen figure as current.

### Added

- **`codex provision <label>` collapses home-create, login, and register.**
  Standing up a Codex identity was three steps and a remembered path convention,
  repeated per host; it is now one command (#133, PR #139)
- **`codex list` reports a re-logged-in home as drift.** A home whose current
  identity no longer matches the account registered against it is shown as a
  distinct state naming the identity it now holds, rather than silently
  producing a stale-looking row (#134, PR #138)
- **`codex list` discovers unregistered `~/.codex*` homes on disk.** Previously
  it enumerated only accounts already in `usage.db`, so extra homes on a host
  gave no signal at all; each discovered home is now listed with its login state
  and the exact `codex add --home <path>` that registers it. Read-only
  throughout (#130, PR #140)
- **A re-logged-in Codex identity is adopted instead of frozen.** When a
  registered home's identity drifts (an operator ran `codex login` as a
  different account), the poller re-attributes: an existing row for the new
  identity is repointed at the home, or a fresh row is registered in the same
  shape `codex add --home` produces. The previous identity's row keeps its
  history and its drifted status. Adoption is keyed only by the identity the
  home itself reported, never by the polled credential, so it structurally
  cannot write one identity's usage onto another's row (#147, PR #158)
- **A declared-but-unprovisioned Codex identity is reported as "absent".** A
  host-local Codex home that was never stood up used to be indistinguishable
  from an identity that doesn't exist. The intended set now travels on the
  existing clipboard/env account transfer as identity-only entries (no token,
  no path — a home *label*, never a username-bearing path), and the gap
  surfaces everywhere accounts are shown: greyed popover rows, `codex list`
  printing the exact `codex provision <label>` that fills it, and
  `ranking.json` emitting `"absent": true` with `"status": "blocked"` so
  consumers exclude it from their pools (#135, PR #166)
- **Freshness thresholds derive from the poll interval, and stale rows are
  gated.** A cause-independent staleness backstop (`AccountFreshness`, 3× the
  configured poll interval) replaces hard-coded minute literals, so no account
  row presents a frozen figure as current — stale rows blank their percentages
  and show an explicit "as of <time>" (#148, PR #154)

### Fixed

- **Codex identity drift is a distinct account state, not a log line.** A
  registered home logged in as a different account used to be reported only by
  a deduped log line while the popover kept the row's last status and stale
  percentages. A `drifted` status is now set on every poll that still finds
  the conflict and cleared on the next clean one, shown as its own orange dot
  naming the identity and the remediation command, with percent/headroom cells
  rendered as "—" (#146, PR #152)
- **The menubar badge no longer shows a frozen percentage.** The status-item
  badge rendered the last-known figure even when the active account's data was
  stale or its Codex identity had drifted; it now falls back to "--" via the
  same gate the popover row already applied (#160, PR #161)
- **Legacy OpenAI rows count toward home-ambiguity bookkeeping.**
  `openAIAccountCount` excluded any tokenless, homeless OpenAI row — including
  pre-#123 rows that still carry usage history — which over-narrowed the
  ambient-home ambiguity guard; the SQL predicate is now exactly the negation
  of `isAbsentCodexIdentity` (PR #171)
- **An empty-string `access_token` no longer admits a row into the poll set.**
  `loadActiveCredentials` only tested `IS NOT NULL`, so a row with
  `access_token = ''` was polled as if credentialed (#173, PR #174)
- **The tier-2 poll log line no longer claims a stored-credential fallback**
  that #104 removed (PR #153)

### Changed

- **Internal refactors with no behavior change:** the absent-identity
  stored-token predicate is spelled once as SQL (`storedTokenCountSQL`, #169,
  PR #172); `--db`/`--help` parsing is shared across the subcommand CLIs
  (`CLIArgs`, #176, PR #177); the pointing-hand hover cursor is a View modifier
  (PR #163); unread `userId`/`idToken` fields dropped from the OpenAI response
  structs (PR #155); SelfTest temp-dir/stub boilerplate deduplicated (PR #144)

## [1.19.0] - 2026-08-15

### Summary

Claude Monitor no longer stores an OpenAI credential. Codex usage is read by
asking the Codex CLI itself over `codex app-server`, so the app holds no token
to expire, rotate, or leak — and each Codex account can be polled from its own
`CODEX_HOME`, which is the foundation for tracking more than one Codex identity.

Note that this release ships the *mechanism*, not yet the ergonomics: homes are
registered by hand with `codex add --home <path>`, and there is no discovery,
drift reporting, or cross-host view of which identities a machine actually has.
That tooling is tracked in #130 and lands in a following release.

### Added

- **Codex usage is read over `codex app-server`, with no stored credential.**
  Polling an OpenAI/ChatGPT account now spawns `codex -s read-only -a untrusted
  app-server` and speaks JSON-RPC over its stdio (`account/read`,
  `account/rateLimits/read`), so the Codex CLI owns the credential and this app
  reads only derived numbers. `pollOpenAI` is a three-tier ladder ordered by how
  little credential handling each rung needs — app-server, then a bearer read
  from `auth.json` at request time, then the legacy stored credential — and an
  unavailable tier falls through silently rather than reporting an account as
  unhealthy. Requires a recent Codex CLI; the method is absent in 0.46.0, which
  answers `-32600` and simply causes a fall-through (#102, PR #111)
- **Each Codex account polls from its own `CODEX_HOME`.** Accounts carry a
  nullable `codex_home`, registered with `claude-monitor codex add --home
  <path>` and inspectable with `codex list`. Because `codex login` writes one
  `auth.json` per home, a per-account home is what allows several Codex
  identities to coexist instead of each login clobbering the last. Homes are
  host-local by design and are never exported or synced (#103, PR #114)
- **Capped accounts sort by when they come back.** Accounts tied on headroom —
  in practice the block of exhausted accounts all reading 0% — now order by time
  until the reset that actually gates them: the weekly reset once the week is
  spent, the session reset otherwise. The same rule replaces the old
  session-reset-first tiebreak used for popover ordering and the auto-selected
  menubar account (#54)

### Changed

- **Stored OpenAI tokens are retired, and Codex accounts are excluded from
  account sync.** A migration nulls `access_token` / `refresh_token` on every
  OpenAI credential row, the proactive OpenAI refresh path is gone, and
  `accounts export` omits `provider: openai` accounts entirely — reporting how
  many it excluded rather than dropping them silently. This closes a real
  failure mode: OpenAI rotates the refresh token on every use, so a copy held by
  this app, a copy on a second host, and the Codex CLI's own `auth.json` were
  invalidating one another in turn, producing continuous
  `401 / refresh_token_invalidated` while the accounts themselves were healthy.
  An `auth.json` is single-machine per OpenAI's guidance; register a Codex
  account on each host instead of copying one between them (#104, PR #123)
- **Clipboard account transfer reports what it left behind.** With OpenAI tokens
  retired, Codex accounts no longer appear in a clipboard payload. "Copy
  Accounts" now names how many were excluded as host-local instead of quietly
  copying fewer, and a Codex-only host gets an explanatory message rather than
  "Nothing to copy" (#129, PR #137)
- **`npm test` runs the self-test.** The script still claimed there was no test
  target and exited 0 unconditionally, which predates `selftest` — orchestration
  gates that shell out to it now actually gate

### Fixed

- **Removing an account deletes its credential.** `clearAccountData` deleted
  usage history and the account row but never `oauth_credentials`,
  `probe_snapshots`, or `named_limits`, and the declared foreign key was inert
  because SQLite defaults `PRAGMA foreign_keys` to OFF. The function is now split
  into `clearAccountHistory` (time series only) and `deleteAccount` (everything),
  which also fixes "Clear History" having silently removed the account row too. A
  migration purges credential rows already stranded by the old behavior, guarding
  rows whose `account_id` is NULL (#106, PR #110) — and a follow-up extends the
  same purge to orphaned `probe_snapshots` / `named_limits` rows (#117, PR #126)
- **`accounts export` no longer fails on a cold WAL database.** Exports opened
  the database read-only, which cannot create the `-shm` file a WAL database
  needs, so a perfectly healthy database produced `SQLITE_CANTOPEN` whenever the
  app was not running — precisely when an export is most likely to be run. Opens
  now escalate read-only → read-write → `immutable=1`, the last gated on the
  absence of a non-empty `-wal` so a stale read can never be returned silently.
  `--db` also reports the path it was actually given (#105, PR #113)
- **Codex client robustness.** A decode failure is distinguished from a
  legitimately null account, so a protocol regression is no longer reported as a
  not-logged-in home; and process reaping suspends rather than blocking a
  cooperative-pool thread for the duration of its shutdown ladder (#118, PR #127)
- **`selftest` no longer writes to the real debug log.** Logging fired from a
  pure mapper, so an offline test run appended lines to
  `~/.claude-monitor/debug.log` (#116, PR #125)
- **`selftest --db` works on a host with a Codex account.** The
  provider-backfill assertion required every pre-existing account to be
  Anthropic, which no multi-provider host satisfies (#112, PR #121)
- **Accurate exported-account count when copying accounts** (#63, PR #64)
- **Guide's work-log scan excludes its own docs-maintenance PRs** (#60, PR #61)

### Security

- Example addresses in the natural-sort fixture and the token-filename
  documentation replaced with placeholders

### Build

- **Swift 6 language mode adopted package-wide**, with narrowest-correct
  concurrency annotations rather than a blanket suppression (#51, PR #53)
- Dependabot configured for GitHub Actions, and `actions/checkout` updated
  (PR #108, PR #109)

## [1.18.3] - 2026-08-02

### Summary

Summary-table polish: the premium column now counts up like its percentage
siblings and sits beside them.

### Changed

- **Premium column counts up and sits before "Wk Reset".** The summary
  table's premium column now shows allowance *used*, counting up to 100% to
  mirror Session % / Weekly % (titled "Fable %" for an Anthropic-only table,
  neutral "Premium %" otherwise; previously "Fable Left"/"Premium Left"
  counting down), and swaps places with the "Wk Reset" column so the three
  percentage columns read together.

## [1.18.2] - 2026-07-31

### Summary

Overnight fleet fixes: duplicate provider accounts self-heal at launch, macOS
`--version` no longer launches the GUI, and the premium/extra column titles
adapt to the providers actually present in the table.

### Fixed

- **Healing migration merges duplicate provider accounts sharing an email.**
  `10660f3` only stopped a *fresh* `codex import` from forking a second row for
  an OpenAI account whose original row predated the native-id era (keyed by a
  locally generated UUID); a database where the duplicate already existed kept
  both rows polling the same account independently. At launch, account pairs
  sharing `(email, provider)` are now merged automatically: history moves onto
  the surviving row (preferring the provider-native id), exactly one
  credential survives (the more recently renewed of the two), and the sibling
  row is removed. Idempotent, and covered by a selftest over a scratch DB
  (#45, PR #50)
- **macOS `--version` never launches the GUI.** The flag is dispatched at top
  level in `main.swift` (previously it worked only behind `--headless`, so the
  natural invocation started a second menubar instance), and bare
  `--once`/`--interval` fail fast with a stderr message pointing at
  `--headless` (#46, PR #48)
- **Premium/Extra column titles are provider-aware.** An all-Anthropic table
  keeps the specific "Fable Left" heading; a mixed or OpenAI-only table shows
  the neutral "Premium Left", with the per-provider meaning in the tooltip —
  an Anthropic-only concept no longer titles a column over OpenAI rows
  (#47, PR #49)

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
