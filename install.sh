#!/bin/sh
# Kodisle installer — https://github.com/pablorod1/kodisle
#
#   curl -fsSL https://raw.githubusercontent.com/pablorod1/kodisle/main/install.sh | sh
#
# Downloads the latest release from GitHub, verifies its SHA-256 checksum, and installs
# Kodisle.app into /Applications (or ~/Applications if /Applications isn't writable).
# Options: KODISLE_VERSION=0.2.0 (specific version), KODISLE_DIR=~/Apps (install folder),
#          KODISLE_NO_OPEN=1 (don't launch after installing).
set -eu

REPO="pablorod1/kodisle"
if [ -n "${KODISLE_VERSION:-}" ]; then
  BASE="https://github.com/$REPO/releases/download/v${KODISLE_VERSION#v}"
else
  BASE="https://github.com/$REPO/releases/latest/download"
fi

say() { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "Kodisle is a macOS app."
MAJOR=$(sw_vers -productVersion | cut -d. -f1)
[ "$MAJOR" -ge 26 ] || fail "Kodisle needs macOS 26 (Tahoe) or later."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

say "Downloading Kodisle…"
curl -fsSL "$BASE/Kodisle.zip" -o "$TMP/Kodisle.zip" || fail "Download failed."
curl -fsSL "$BASE/Kodisle.zip.sha256" -o "$TMP/Kodisle.zip.sha256" || fail "Checksum download failed."

say "Verifying checksum…"
EXPECTED=$(cut -d' ' -f1 "$TMP/Kodisle.zip.sha256")
ACTUAL=$(shasum -a 256 "$TMP/Kodisle.zip" | cut -d' ' -f1)
[ -n "$EXPECTED" ] && [ "$EXPECTED" = "$ACTUAL" ] || fail "Checksum mismatch — aborting."

ditto -x -k "$TMP/Kodisle.zip" "$TMP/app"
[ -d "$TMP/app/Kodisle.app" ] || fail "Unexpected archive contents."

DEST="${KODISLE_DIR:-/Applications}"
mkdir -p "$DEST" 2>/dev/null || true
[ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }

# Quit a running copy first (it restores the macOS Dock on quit).
if [ -z "${KODISLE_NO_OPEN:-}" ] && pgrep -x Kodisle >/dev/null 2>&1; then
  osascript -e 'quit app "Kodisle"' >/dev/null 2>&1 || true
  sleep 2
fi

say "Installing to $DEST…"
rm -rf "$DEST/Kodisle.app"
mv "$TMP/app/Kodisle.app" "$DEST/Kodisle.app"
xattr -dr com.apple.quarantine "$DEST/Kodisle.app" 2>/dev/null || true

VERSION=$(defaults read "$DEST/Kodisle.app/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")
if [ -n "${KODISLE_NO_OPEN:-}" ]; then
  say "✓ Kodisle $VERSION installed in $DEST."
else
  say "✓ Kodisle $VERSION installed. Opening…"
  open "$DEST/Kodisle.app"
fi
