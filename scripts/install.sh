#!/bin/bash
# Copy the built app to /Applications and start it. Use the menu bar item to enable Launch at login.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="build/Apple Home MCP.app"
[ -d "$SRC" ] || { echo "run scripts/build.sh first"; exit 1; }
pkill -x AppleHomeMCP 2>/dev/null || true
rm -rf "/Applications/Apple Home MCP.app"
cp -R "$SRC" /Applications/
mkdir -p "$HOME/.local/bin" && cp build/apple-home-mcp-bridge "$HOME/.local/bin/"
open "/Applications/Apple Home MCP.app"
echo "Started. Look for the house icon in the menu bar; approve the HomeKit prompt on first launch."
