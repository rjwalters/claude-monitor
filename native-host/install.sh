#!/bin/bash
# Install Native Messaging Host for Claude Monitor (Firefox & Chrome)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
HOST_NAME="claude_monitor"
BINARY_PATH="$PROJECT_DIR/dist/claude_monitor_host"

# Browser native messaging directories (macOS)
FIREFOX_DIR="$HOME/Library/Application Support/Mozilla/NativeMessagingHosts"
CHROME_DIR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"

# Chrome extension ID (derived from manifest key in extension-chrome/manifest.json)
CHROME_EXTENSION_ID="kajhnojloklkpboddbnnbobginheicnm"

# Determine which host executable to use
if [ -x "$BINARY_PATH" ]; then
  HOST_EXECUTABLE="$BINARY_PATH"
  echo "Using pre-built binary: $BINARY_PATH"
else
  # Fall back to Node.js script (requires node_modules)
  HOST_EXECUTABLE="$SCRIPT_DIR/claude_monitor_host.sh"
  echo "Binary not found, using Node.js script"

  # Ensure npm dependencies are installed for script mode
  if [ ! -d "$PROJECT_DIR/node_modules" ]; then
    echo "Installing npm dependencies..."
    (cd "$PROJECT_DIR" && npm install)
    echo ""
  fi
fi

# Create Firefox manifest
cat > "$SCRIPT_DIR/${HOST_NAME}_firefox.json" << EOF
{
  "name": "$HOST_NAME",
  "description": "Claude Usage Monitor Native Host",
  "path": "$HOST_EXECUTABLE",
  "type": "stdio",
  "allowed_extensions": ["claude-monitor@rjwalters.github.io", "claude-monitor@local"]
}
EOF

# Create Chrome manifest
cat > "$SCRIPT_DIR/${HOST_NAME}_chrome.json" << EOF
{
  "name": "$HOST_NAME",
  "description": "Claude Usage Monitor Native Host",
  "path": "$HOST_EXECUTABLE",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://${CHROME_EXTENSION_ID}/"]
}
EOF

# Install for Firefox
mkdir -p "$FIREFOX_DIR"
ln -sf "$SCRIPT_DIR/${HOST_NAME}_firefox.json" "$FIREFOX_DIR/$HOST_NAME.json"
echo "Firefox native host installed"
echo "  Manifest: $FIREFOX_DIR/$HOST_NAME.json"

# Install for Chrome
mkdir -p "$CHROME_DIR"
ln -sf "$SCRIPT_DIR/${HOST_NAME}_chrome.json" "$CHROME_DIR/$HOST_NAME.json"
echo "Chrome native host installed"
echo "  Manifest: $CHROME_DIR/$HOST_NAME.json"

echo ""
echo "Host executable: $HOST_EXECUTABLE"
echo ""
echo "Next steps:"
echo "  Firefox: about:debugging#/runtime/this-firefox -> Reload extension"
echo "  Chrome:  chrome://extensions -> Enable Developer mode -> Load unpacked"
