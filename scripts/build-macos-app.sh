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

# Build release version
swift build -c release

# Create app bundle structure
APP_BUNDLE="$BUILD_DIR/ClaudeMonitor.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy executable
cp ".build/release/ClaudeMonitor" "$APP_BUNDLE/Contents/MacOS/"

# Copy native host files for bundling
cp "$PROJECT_ROOT/native-host/claude_monitor_host.cjs" "$APP_BUNDLE/Contents/Resources/"

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
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
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
