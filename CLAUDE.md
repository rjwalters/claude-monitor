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

## Project Structure

- `menubar-app/ClaudeMonitor/` - Swift Package Manager project
  - `Sources/main.swift` - App entry point, AppDelegate, popover/window management
  - `Sources/AnthropicAPI.swift` - API client (usage, profile, token refresh)
  - `Sources/OAuthPoller.swift` - Ping-based usage polling, token add/import, Fable probes
  - `Sources/UsagePopoverView.swift` - Summary-table popover, sortable headers, add-account dialog
  - `Sources/UsageChartView.swift` - Per-account usage-history chart window
  - `Sources/RollTokenView.swift` / `Sources/TokenRoller.swift` - Roll Token wizard + revoke-script generator
  - `Sources/UsageStore.swift` - SQLite-backed data store, account/usage models
  - `Sources/SQLiteDB.swift` - Minimal wrapper over system libsqlite3 (zero package deps)
  - `Sources/RankingExporter.swift` - Emits `~/.claude-monitor/ranking.json`
  - `Sources/FileLogger.swift` - Debug log at `~/.claude-monitor/debug.log`
  - `Assets/` - App icon (`AppIcon.icns` + 1024px master PNG)
- `scripts/build-macos-app.sh` - Build script that compiles and creates the .app bundle (bundles the icon)
- `build/` - Build output (ClaudeMonitor.app and .zip)

## Version Management

- App version: `AppVersion.current` in `UsageStore.swift` + `CFBundleVersion`/`CFBundleShortVersionString` in `build-macos-app.sh`
- User-Agent version: `claudeCodeUserAgent` constant in `AnthropicAPI.swift` (auto-updated at build time)

<!-- BEGIN LOOM ORCHESTRATION -->
This repository uses [Loom](https://github.com/rjwalters/loom) for AI-powered development orchestration — see the Loom repository for the full guide (roles, labels, worktrees, configuration). When installed, Loom also writes a locally-substituted copy of that guide to `.loom/CLAUDE.md`.
<!-- END LOOM ORCHESTRATION -->