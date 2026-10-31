#!/bin/sh
# Builds a universal (Apple Silicon + Intel) Release Kodisle.app, ad-hoc signed, and zips it.
# Usage: scripts/build-release.sh [version]     → build/Kodisle.zip + build/Kodisle.zip.sha256
set -e
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "Install XcodeGen: brew install xcodegen"; exit 1; }
VERSION="${1:-}"
EXTRA=""
[ -n "$VERSION" ] && EXTRA="MARKETING_VERSION=$VERSION"
xcodegen generate --quiet
xcodebuild -project Kodisle.xcodeproj -scheme Kodisle -configuration Release -derivedDataPath build \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- $EXTRA build | tail -1
rm -f build/Kodisle.zip build/Kodisle.zip.sha256
ditto -c -k --keepParent build/Build/Products/Release/Kodisle.app build/Kodisle.zip
(cd build && shasum -a 256 Kodisle.zip > Kodisle.zip.sha256)
echo "✓ build/Kodisle.zip ($(lipo -archs build/Build/Products/Release/Kodisle.app/Contents/MacOS/Kodisle))"
cat build/Kodisle.zip.sha256
