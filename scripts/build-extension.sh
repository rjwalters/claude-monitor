#!/bin/bash
# Build Firefox extension for signing at addons.mozilla.org
# Output: extension.zip ready for upload

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
EXTENSION_DIR="$PROJECT_ROOT/extension"
BUILD_DIR="$PROJECT_ROOT/build"
OUTPUT_FILE="$BUILD_DIR/claude-monitor-extension.zip"

echo "Building Firefox extension..."
echo "  Source: $EXTENSION_DIR"
echo "  Output: $OUTPUT_FILE"

# Create build directory
mkdir -p "$BUILD_DIR"

# Remove old build if exists
rm -f "$OUTPUT_FILE"

# Create zip with extension files
cd "$EXTENSION_DIR"
zip -r "$OUTPUT_FILE" \
    manifest.json \
    background.js \
    content.js \
    popup.html \
    popup.js \
    -x "*.DS_Store" -x "*.md"

echo ""
echo "Extension packaged successfully!"
echo "  File: $OUTPUT_FILE"
echo "  Size: $(du -h "$OUTPUT_FILE" | cut -f1)"
echo ""
echo "Next steps:"
echo "  1. Go to https://addons.mozilla.org/developers/"
echo "  2. Sign in or create a free account"
echo "  3. Click 'Submit a New Add-on'"
echo "  4. Choose 'On your own' for self-distribution"
echo "  5. Upload: $OUTPUT_FILE"
echo "  6. Download the signed .xpi file"
echo "  7. Add the .xpi to your GitHub release"
echo ""
