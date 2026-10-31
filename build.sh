#!/bin/bash
# Builds "PDF Search.app" into /Applications. Needs Apple's Command Line Tools (xcode-select --install).
set -e
cd "$(dirname "$0")"
pkill -x PDFSearch 2>/dev/null && sleep 1 || true   # quit the running copy first
# Install into the main /Applications folder (falls back to ~/Applications if that isn't writable)
if [ -w /Applications ]; then APP="/Applications/PDF Search.app"; rm -rf "$HOME/Applications/PDF Search.app"
else APP="$HOME/Applications/PDF Search.app"; fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos13.0" \
  PDFSearch.swift -o "$APP/Contents/MacOS/PDFSearch" -lsqlite3
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force -s - "$APP" >/dev/null 2>&1 || true
echo "Built: $APP"
