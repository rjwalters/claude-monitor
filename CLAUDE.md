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
- Entry points: `main.swift` (macOS, dispatches to `HeadlessRunner` on `--headless`) and `HeadlessMain.swift` (Linux, always headless). Flags: `--once`, `--interval <sec>`, `--version`.
- Parse response headers via `extractAnthropicHeaders` (lowercased map), never `allHeaderFields` subscripts — those are case-sensitive on Linux.
- Verify Linux builds from macOS with the `swift:6.1` Docker image (`apt-get install libsqlite3-dev`, then `swift build`).

## Project Structure

- `menubar-app/ClaudeMonitor/` - Swift Package Manager project
  - `Sources/main.swift` - macOS entry point, AppDelegate, popover/window management
  - `Sources/HeadlessMain.swift` / `Sources/HeadlessRunner.swift` - Linux entry point + UI-less poll loop (also `--headless` on macOS)
  - `Sources/LinuxCompat.swift` - `ObservableObject`/`@Published` stand-ins for Linux (no Combine)
  - `CSQLite/` - System-library target mapping Linux libsqlite3
  - `Sources/AnthropicAPI.swift` - API client (usage, profile, token refresh)
  - `Sources/OAuthPoller.swift` - Ping-based usage polling, token add/import, Fable probes
  - `Sources/UsagePopoverView.swift` - Summary-table popover, sortable headers, add-account dialog
  - `Sources/UsageChartView.swift` - Per-account usage-history chart window
  - `Sources/RollTokenView.swift` / `Sources/TokenRoller.swift` - Roll Token wizard + revoke-script generator. The workflow depends on undocumented, web-session-cookie-authenticated `claude.ai/api/oauth` endpoints; if they change, `TokenRoller.revokeAllScript` is the single place to update (see README "Rolling a Token").
  - `Sources/UsageStore.swift` - SQLite-backed data store, account/usage models
  - `Sources/SQLiteDB.swift` - Minimal wrapper over system libsqlite3 (zero package deps)
  - `Sources/RankingExporter.swift` - Emits `~/.claude-monitor/ranking.json`
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