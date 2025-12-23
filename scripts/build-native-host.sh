#!/bin/bash
# Build native host binary for macOS using pkg
# Requires nvm to be installed (to ensure Node 20 is used for the build)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
NODE_VERSION="20"

cd "$PROJECT_DIR"

# Load nvm
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

# Check if nvm is available
if ! command -v nvm &> /dev/null; then
  echo "Error: nvm is required but not installed."
  echo "Install nvm from https://github.com/nvm-sh/nvm"
  exit 1
fi

# Install Node 20 if not available
if ! nvm ls "$NODE_VERSION" &> /dev/null; then
  echo "Installing Node $NODE_VERSION..."
  nvm install "$NODE_VERSION"
fi

# Use Node 20 for this build
echo "Switching to Node $NODE_VERSION for build..."
nvm use "$NODE_VERSION"

# Verify we're using the right Node version
CURRENT_NODE=$(node --version)
echo "Using Node: $CURRENT_NODE"

# Clean and reinstall dependencies with Node 20
echo "Installing dependencies with Node $NODE_VERSION..."
rm -rf node_modules
npm install

# Rebuild better-sqlite3 explicitly for Node 20
# This is critical - the native module must be compiled for the same Node version pkg bundles
echo "Rebuilding better-sqlite3 for Node $NODE_VERSION..."
cd node_modules/better-sqlite3
rm -rf build
npx node-gyp rebuild --release
cd "$PROJECT_DIR"

# Clear pkg cache to ensure fresh native module is used
echo "Clearing pkg cache..."
rm -rf ~/.cache/pkg/

# Create dist directory if needed
mkdir -p dist

# Build for macOS ARM64 (Apple Silicon)
echo "Building native host binary..."
npx @yao-pkg/pkg native-host/claude_monitor_host.cjs \
  --targets node20-macos-arm64 \
  --output dist/claude_monitor_host \
  --config package.json

echo ""
echo "Built: dist/claude_monitor_host"
ls -lh dist/claude_monitor_host

# Test the binary
echo ""
echo "Testing binary..."
if timeout 2 ./dist/claude_monitor_host < /dev/null 2>&1; then
  echo "Binary test passed!"
fi
