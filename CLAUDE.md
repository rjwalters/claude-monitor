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
  - `Sources/UsagePopoverView.swift` - All SwiftUI views (popover, account cards, summary table)
  - `Sources/UsageStore.swift` - SQLite-backed data store, account/usage models
- `scripts/build-macos-app.sh` - Build script that compiles and creates the .app bundle
- `build/` - Build output (ClaudeMonitor.app and .zip)

## Version Management

- App version: `AppVersion.current` in `UsageStore.swift` + `CFBundleVersion`/`CFBundleShortVersionString` in `build-macos-app.sh`
- User-Agent version: `claudeCodeUserAgent` constant in `AnthropicAPI.swift` (auto-updated at build time)

<!-- BEGIN LOOM ORCHESTRATION -->
This repository uses [Loom](https://github.com/rjwalters/loom) for AI-powered development orchestration — see the Loom repository for the full guide (roles, labels, worktrees, configuration). When installed, Loom also writes a locally-substituted copy of that guide to `.loom/CLAUDE.md`.
<!-- END LOOM ORCHESTRATION -->