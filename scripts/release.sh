#!/bin/bash
# Build, sign (Developer ID), notarize and publish the apple-home-mcp-bridge CLI plus a source zip.
#   scripts/release.sh v0.1.0
# Needs: Developer ID Application identity in the keychain, notarytool profile (NOTARY_PROFILE,
# default "apple-home-mcp") created with `xcrun notarytool store-credentials`, and gh.
set -euo pipefail
cd "$(dirname "$0")/.."
TAG="${1:?usage: release.sh vX.Y.Z}"
PROFILE="${NOTARY_PROFILE:-apple-home-mcp}"
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')}"
[ -n "$IDENTITY" ] || { echo "no Developer ID Application identity found"; exit 1; }
scripts/scan.sh
OUT=dist/$TAG && rm -rf "$OUT" && mkdir -p "$OUT"
( cd Packages/MCPKit && swift test --quiet && swift build -c release --arch arm64 --arch x86_64 --product apple-home-mcp-bridge )
BIN=Packages/MCPKit/.build/apple/Products/Release/apple-home-mcp-bridge
cp "$BIN" "$OUT/"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$OUT/apple-home-mcp-bridge"
( cd "$OUT" && ditto -c -k --keepParent apple-home-mcp-bridge "apple-home-mcp-bridge-$TAG-macos.zip" )
xcrun notarytool submit "$OUT/apple-home-mcp-bridge-$TAG-macos.zip" --keychain-profile "$PROFILE" --wait
git archive --format=zip --prefix="apple-home-mcp-$TAG/" -o "$OUT/apple-home-mcp-$TAG-source.zip" HEAD
( cd "$OUT" && shasum -a 256 *.zip > SHA256SUMS )
gh release create "$TAG" "$OUT"/*.zip "$OUT/SHA256SUMS" --title "$TAG" --notes-file docs/RELEASE_NOTES.md
