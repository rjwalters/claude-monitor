#!/bin/bash
# Build macOS menu bar app for distribution
# Output: ClaudeMonitor.app bundle

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
APP_DIR="$PROJECT_ROOT/menubar-app/ClaudeMonitor"
BUILD_DIR="$PROJECT_ROOT/build"

echo "Building macOS app..."

cd "$APP_DIR"

# Auto-detect installed claude-code version for User-Agent header.
# Primary source: the npm global install. This misses Homebrew/other installs
# (npm list finds nothing), so fall back to `claude --version` in that case.
CLAUDE_CODE_VERSION=$(npm list -g @anthropic-ai/claude-code --depth=0 2>/dev/null | grep claude-code | sed 's/.*@//')

if [ -z "$CLAUDE_CODE_VERSION" ] && command -v claude >/dev/null 2>&1; then
    # e.g. "2.1.220 (Claude Code)" -> "2.1.220"
    CLAUDE_CODE_VERSION=$(claude --version 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+')
fi

if [ -n "$CLAUDE_CODE_VERSION" ]; then
    echo "Detected claude-code version: $CLAUDE_CODE_VERSION"
    sed -i '' "s|claude-code/[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*|claude-code/${CLAUDE_CODE_VERSION}|g" \
        Sources/AnthropicAPI.swift
else
    # Shipping a stale User-Agent is a silent correctness bug (it already
    # happened once at v1.17.0), so this is a hard failure rather than a
    # warning that's easy to lose in build output. Set
    # ALLOW_STALE_USER_AGENT=1 to explicitly opt into building anyway with
    # whatever User-Agent is already committed in AnthropicAPI.swift.
    echo "ERROR: could not detect claude-code version via 'npm list -g @anthropic-ai/claude-code' or 'claude --version'." >&2
    echo "       Install claude-code (npm or Homebrew) so it's on PATH before building," >&2
    echo "       or set ALLOW_STALE_USER_AGENT=1 to build anyway with the existing User-Agent." >&2
    if [ "${ALLOW_STALE_USER_AGENT:-}" != "1" ]; then
        exit 1
    fi
    echo "ALLOW_STALE_USER_AGENT=1 set — proceeding with the existing (possibly stale) User-Agent." >&2
fi

# Build release version
swift build -c release

# Create app bundle structure
APP_BUNDLE="$BUILD_DIR/ClaudeMonitor.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy executable
cp ".build/release/ClaudeMonitor" "$APP_BUNDLE/Contents/MacOS/"

# Copy app icon
cp "$APP_DIR/Assets/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"

# Create Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ClaudeMonitor</string>
    <key>CFBundleIdentifier</key>
    <string>com.claude-monitor.app</string>
    <key>CFBundleName</key>
    <string>Claude Monitor</string>
    <key>CFBundleDisplayName</key>
    <string>Claude Monitor</string>
    <key>CFBundleVersion</key>
    <string>1.17.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.17.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo ""
echo "App bundle created successfully!"
echo "  Bundle: $APP_BUNDLE"
echo "  Size: $(du -sh "$APP_BUNDLE" | cut -f1)"
echo ""

# Create zip for distribution
cd "$BUILD_DIR"
rm -f "ClaudeMonitor.zip"
zip -r "ClaudeMonitor.zip" "ClaudeMonitor.app"

echo "Distribution archive:"
echo "  File: $BUILD_DIR/ClaudeMonitor.zip"
echo "  Size: $(du -h "ClaudeMonitor.zip" | cut -f1)"
echo ""
echo "Note: The app is not signed. Users will need to:"
echo "  1. Right-click and select 'Open' the first time"
echo "  2. Or: System Settings > Privacy & Security > Open Anyway"
echo ""
echo "For proper distribution, consider signing with an Apple Developer certificate."
