# Release policy — claude-monitor

The app version lives in a Swift source constant plus two plist strings in the
build script (see CLAUDE.md "Version Management"). The `bump:` command below
rewrites all three in one pass so they can never drift apart.

## version-source

- read: `sed -n 's/.*static let current = "\([0-9.]*\)".*/\1/p' menubar-app/ClaudeMonitor/Sources/UsageStore.swift`
- bump: `sed -i '' "s/static let current = \"[0-9.]*\"/static let current = \"$1\"/" menubar-app/ClaudeMonitor/Sources/UsageStore.swift && sed -i '' "s|<string>[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*</string>|<string>$1</string>|g" scripts/build-macos-app.sh`
