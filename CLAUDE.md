# Claude Monitor - Development Notes

## Build & Install

- Build with: `./scripts/build-macos-app.sh`
- The build script auto-detects the installed `claude-code` version (via npm) and patches the User-Agent string in `AnthropicAPI.swift` before compiling.
- **Important:** When installing to `/Applications`, you must `rm -rf` the existing app bundle before copying. `cp -R` over a running macOS app does not replace the binary. The correct sequence is:
  ```
  osascript -e 'quit app "Claude Monitor"'
  sleep 2
  rm -rf /Applications/ClaudeMonitor.app
  cp -R build/ClaudeMonitor.app /Applications/ClaudeMonitor.app
  open /Applications/ClaudeMonitor.app
  ```

## Headless / Linux

- The same package builds on Linux (`swift build` with `libsqlite3-dev` installed) as a headless daemon for Loom hosts — no UI, same poll loop, same `usage.db`/`ranking.json` outputs. See README "Headless Mode / Linux".
- UI sources are fenced with `#if os(macOS)`; portable core must stay free of AppKit/SwiftUI/Combine/os.Logger. On Linux, `LinuxCompat.swift` shims `ObservableObject`/`@Published`, and `CSQLite/` maps the system libsqlite3 (macOS uses the SDK's `SQLite3` module).
- Entry points: `main.swift` (macOS, dispatches to `HeadlessRunner` on `--headless`) and `HeadlessMain.swift` (Linux, always headless). Flags: `--once`, `--interval <sec>`, `--version`. Subcommands: `accounts`, `selftest`.
- Run the test suite with `swift build && .build/debug/ClaudeMonitor selftest` (exits non-zero on failure). CI runs it on macOS and Linux.
- To verify a schema migration against real data, copy the live DB first — `cp ~/.claude-monitor/usage.db /tmp/ && .build/debug/ClaudeMonitor selftest --db /tmp/usage.db`. `--db` **writes** to the path it is given; never point it at `~/.claude-monitor/usage.db`.
- Parse response headers via `extractAnthropicHeaders` (lowercased map), never `allHeaderFields` subscripts — those are case-sensitive on Linux.
- Verify Linux builds from macOS with the `swift:6.1` Docker image (`apt-get install libsqlite3-dev`, then `swift build`).

## Project Structure

- `menubar-app/ClaudeMonitor/` - Swift Package Manager project
  - `Package.swift` - Package manifest (zero package dependencies)
  - `Sources/main.swift` - macOS entry point, AppDelegate, popover/window management
  - `Sources/HeadlessMain.swift` / `Sources/HeadlessRunner.swift` - Linux entry point + UI-less poll loop (also `--headless` on macOS)
  - `Sources/LinuxCompat.swift` - `ObservableObject`/`@Published` stand-ins for Linux (no Combine)
  - `CSQLite/` - System-library target mapping Linux libsqlite3
  - `Sources/RateLimitWindow.swift` - Provider-agnostic rate-limit model (`AccountProvider`, `RateLimitWindow`, `RateLimitSnapshot`). Window kind is **derived from the window's duration**, never its position in the provider response, and every window is optional — an account may legitimately report no session window.
  - `Sources/UsageProviderClient.swift` - `UsageProviderClient` protocol + `ProviderCredentials` / `ProviderUsageSnapshot` / `ProviderAPIError` (aliased as `AnthropicAPIError`)
  - `Sources/AnthropicAPI.swift` - API client (usage, profile, token refresh); conforms to `UsageProviderClient`
  - `Sources/OpenAIAPI.swift` - OpenAI/Codex client: `GET chatgpt.com/backend-api/wham/usage` (never `/backend-api/codex/usage` — Cloudflare-challenged), `POST auth.openai.com/oauth/token` refresh, and `CodexAuth` (reads `~/.codex/auth.json`, honoring `$CODEX_HOME`). Access tokens live ~10 days; expiry comes from the token's own `exp` claim. **Never log a token or a raw response body** — `OpenAIUsageResponse.flatten` redacts PII/credential keys at *every* nesting depth before anything is archived or logged.
  - `Sources/CodexCLI.swift` - `claude-monitor codex import` (one-shot CLI, no `--headless` needed, works on Linux)
  - `Sources/OAuthPoller.swift` - Per-provider usage polling (Anthropic ping / OpenAI usage GET), token add/import, proactive OpenAI token refresh, Fable probes (Anthropic only). Absent windows are stored as NULL, not 0, for non-Anthropic providers.
  - `Sources/SelfTest.swift` - `ClaudeMonitor selftest`: portable-core assertions (window model, schema migration, OpenAI wire mapping + PII redaction, `ranking.json` provider field) with no network/credentials. Run in CI on both macOS and Linux; there is no XCTest target because the package has zero dependencies. `--wire <path>` decodes a captured `/wham/usage` body offline (prints only derived numbers, never identity).
  - `Sources/RankingExporter.swift` - Emits `~/.claude-monitor/ranking.json`. Every account carries `provider`; `schema` stays **1** because the field is additive. A `provider: openai` account may omit `utilization["5h"]` — consumers must read a missing key as *unknown*, never 0.
  - `Sources/UsagePopoverView.swift` - Summary-table popover, sortable headers, add-account dialog
  - `Sources/UsageChartView.swift` - Per-account usage-history chart window
  - `Sources/RollTokenView.swift` / `Sources/TokenRoller.swift` - Roll Token wizard + revoke-script generator. The workflow depends on undocumented, web-session-cookie-authenticated `claude.ai/api/oauth` endpoints; if they change, `TokenRoller.revokeAllScript` is the single place to update (see README "Rolling a Token").
  - `Sources/UsageStore.swift` - SQLite-backed data store, account/usage models
  - `Sources/SQLiteDB.swift` - Minimal wrapper over system libsqlite3 (zero package deps)
  - `Sources/FileLogger.swift` - Debug log at `~/.claude-monitor/debug.log`
  - `Assets/` - App icon (`AppIcon.icns` + 1024px master PNG + `icon-master.source.json` generation recipe)
- `scripts/build-macos-app.sh` - Build script that compiles and creates the .app bundle (bundles the icon)
- `scripts/claude-monitor.service` - Sample systemd user unit for Linux headless mode
- `build/` - Build output (ClaudeMonitor.app and .zip)

## Version Management

- App version: `AppVersion.current` in `UsageStore.swift` + `CFBundleVersion`/`CFBundleShortVersionString` in `build-macos-app.sh`
- User-Agent version: `claudeCodeUserAgent` constant in `AnthropicAPI.swift` (auto-updated at build time)<!-- BEGIN LOOM ORCHESTRATION -->
This repository uses [Loom](https://github.com/rjwalters/loom) for AI-powered development orchestration — see the Loom repository for the full guide (roles, labels, worktrees, configuration). When installed, Loom also writes a locally-substituted copy of that guide to `.loom/CLAUDE.md`.
<!-- END LOOM ORCHESTRATION -->
<!-- BEGIN REPO-SKILLS -->
This repository has [Repo Skills](https://github.com/rjwalters/repo) v0.7.0 installed —
general repository hygiene and environment commands invoked as `/repo:<command>`. Run
`/repo:help` for the command list, or see `.claude/skills/repo/SKILL.md` for the full
guide. Hygiene commands apply safe, reversible fixes by default and report each
change; run with `--ask` to review first, and `--prune` to allow irreversible
removals. Managed by `install.sh` — edit outside the markers only.
<!-- END REPO-SKILLS -->
