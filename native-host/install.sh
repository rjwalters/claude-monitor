#!/bin/bash
# Install Native Messaging Host for Claude Monitor (Firefox & Chrome)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST_NAME="claude_monitor"

# Browser native messaging directories (macOS)
FIREFOX_DIR="$HOME/Library/Application Support/Mozilla/NativeMessagingHosts"
CHROME_DIR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"

# Chrome extension ID (derived from manifest key in extension-chrome/manifest.json)
# This ID is deterministic because we set the "key" field in the manifest
CHROME_EXTENSION_ID="kajhnojloklkpboddbnnbobginheicnm"

# Create Firefox manifest (uses shell wrapper to ensure node is in PATH)
cat > "$SCRIPT_DIR/${HOST_NAME}_firefox.json" << EOF
{
  "name": "$HOST_NAME",
  "description": "Claude Usage Monitor Native Host",
  "path": "$SCRIPT_DIR/claude_monitor_host.sh",
  "type": "stdio",
  "allowed_extensions": ["claude-monitor@local"]
}
EOF

# Create Chrome manifest
cat > "$SCRIPT_DIR/${HOST_NAME}_chrome.json" << EOF
{
  "name": "$HOST_NAME",
  "description": "Claude Usage Monitor Native Host",
  "path": "$SCRIPT_DIR/claude_monitor_host.cjs",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://${CHROME_EXTENSION_ID}/"]
}
EOF

# Install for Firefox
mkdir -p "$FIREFOX_DIR"
ln -sf "$SCRIPT_DIR/${HOST_NAME}_firefox.json" "$FIREFOX_DIR/$HOST_NAME.json"
echo "✓ Firefox native host installed"
echo "  Manifest: $FIREFOX_DIR/$HOST_NAME.json"

# Install for Chrome
mkdir -p "$CHROME_DIR"
ln -sf "$SCRIPT_DIR/${HOST_NAME}_chrome.json" "$CHROME_DIR/$HOST_NAME.json"
echo "✓ Chrome native host installed"
echo "  Manifest: $CHROME_DIR/$HOST_NAME.json"

echo ""
echo "Host script: $SCRIPT_DIR/claude_monitor_host.cjs"
echo ""
echo "Next steps:"
echo "  Firefox: about:debugging#/runtime/this-firefox → Reload extension"
echo "  Chrome:  chrome://extensions → Enable Developer mode → Load unpacked"
