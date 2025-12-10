#!/bin/bash
# Wrapper script for native host - ensures node is found
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
exec node "$(dirname "$0")/claude_monitor_host.cjs" "$@"
