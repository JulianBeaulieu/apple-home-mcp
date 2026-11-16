#!/bin/bash
# Build and sign Apple Home MCP (Mac Catalyst) with YOUR Apple Developer team.
#   1. cp Config/Local.xcconfig.example Config/Local.xcconfig  (set DEVELOPMENT_TEAM, APP_BUNDLE_ID)
#   2. scripts/build.sh            -> build/Apple Home MCP.app (Development-signed, HomeKit entitled)
# Needs Xcode signed into your Apple ID (Settings > Accounts) and this Mac registered as a device.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f Config/Local.xcconfig ] || { echo "Create Config/Local.xcconfig first (see Config/Local.xcconfig.example)"; exit 1; }
command -v xcodegen >/dev/null || { echo "brew install xcodegen"; exit 1; }
CONFIG="${CONFIGURATION:-Release}"
mkdir -p build && xcodegen generate --quiet
( cd Packages/MCPKit && swift test --quiet )

build() {
  xcodebuild -project AppleHomeMCP.xcodeproj -scheme AppleHomeMCP -configuration "$CONFIG" \
    -destination "$1" -derivedDataPath build/dd -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
}
if ! build 'platform=macOS,variant=Mac Catalyst' > build/xcodebuild.log 2>&1; then
  if grep -q "provisioning profile\|No profiles" build/xcodebuild.log; then
    # First build of a new bundle id: an iOS build registers the App ID + HomeKit capability.
    echo "==> registering App ID with HomeKit via an iOS build, then retrying"
    build 'generic/platform=iOS' >> build/xcodebuild.log 2>&1 || true
    build 'platform=macOS,variant=Mac Catalyst' >> build/xcodebuild.log 2>&1 || { grep -E "error:" build/xcodebuild.log | sort -u; exit 1; }
  else
    grep -E "error:" build/xcodebuild.log | sort -u; exit 1
  fi
fi
APP="build/dd/Build/Products/$CONFIG-maccatalyst/Apple Home MCP.app"
rm -rf "build/Apple Home MCP.app" && cp -R "$APP" build/
codesign -d --entitlements - "build/Apple Home MCP.app" 2>/dev/null | grep -q com.apple.developer.homekit \
  || { echo "ERROR: built app lacks the HomeKit entitlement"; exit 1; }
( cd Packages/MCPKit && swift build -c release --product apple-home-mcp-bridge --quiet && cp .build/release/apple-home-mcp-bridge ../../build/ )
echo "Built: build/Apple Home MCP.app and build/apple-home-mcp-bridge"
