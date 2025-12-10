#!/bin/bash
# Install Native Messaging Host for Claude Monitor

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST_NAME="claude_monitor"

# Firefox native messaging directory
FIREFOX_DIR="$HOME/Library/Application Support/Mozilla/NativeMessagingHosts"

# Create the manifest with correct absolute path
cat > "$SCRIPT_DIR/$HOST_NAME.json" << EOF
{
  "name": "$HOST_NAME",
  "description": "Claude Usage Monitor Native Host",
  "path": "$SCRIPT_DIR/claude_monitor_host.cjs",
  "type": "stdio",
  "allowed_extensions": ["claude-monitor@local"]
}
EOF

# Create Firefox directory if needed
mkdir -p "$FIREFOX_DIR"

# Create symlink for Firefox
ln -sf "$SCRIPT_DIR/$HOST_NAME.json" "$FIREFOX_DIR/$HOST_NAME.json"

echo "Native messaging host installed for Firefox"
echo "  Manifest: $FIREFOX_DIR/$HOST_NAME.json"
echo "  Host: $SCRIPT_DIR/claude_monitor_host.cjs"
echo ""
echo "Now reload the extension in Firefox:"
echo "  1. Go to about:debugging#/runtime/this-firefox"
echo "  2. Click 'Reload' on Claude Usage Monitor"
