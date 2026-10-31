#!/bin/sh
# Builds a Release Kodisle.app (ad-hoc signed) and zips it into build/Kodisle.zip
set -e
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "Install XcodeGen: brew install xcodegen"; exit 1; }
xcodegen generate --quiet
xcodebuild -project Kodisle.xcodeproj -scheme Kodisle -configuration Release -derivedDataPath build build | tail -1
ditto -c -k --keepParent build/Build/Products/Release/Kodisle.app build/Kodisle.zip
echo "✓ build/Kodisle.zip"
