#!/bin/bash
# Makes "PDF Search <version>.dmg" on your Desktop, ready to give to someone else:
# a universal app (Apple Silicon + Intel), Read Me First, the guide PDF and the source code.
# Run:  cd /Applications/PDF\ Search\ Source && ./make-package.sh
set -e
cd "$(dirname "$0")"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
WORK="$(mktemp -d)"
STAGE="$WORK/PDF Search"
APP="$STAGE/PDF Search.app"
OUT="$HOME/Desktop/PDF Search $VERSION.dmg"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

FLAGS=(-O -parse-as-library -swift-version 5 -lsqlite3)
echo "Building for Apple Silicon…"
swiftc "${FLAGS[@]}" -target arm64-apple-macos13.0 PDFSearch.swift -o "$WORK/PDFSearch-arm64"
echo "Building for Intel…"
if swiftc "${FLAGS[@]}" -target x86_64-apple-macos13.0 PDFSearch.swift -o "$WORK/PDFSearch-x86_64"; then
  lipo -create "$WORK/PDFSearch-arm64" "$WORK/PDFSearch-x86_64" -output "$APP/Contents/MacOS/PDFSearch"
else
  echo "!! Intel build failed — this package will only run on Apple Silicon Macs."
  cp "$WORK/PDFSearch-arm64" "$APP/Contents/MacOS/PDFSearch"
fi
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force -s - "$APP"
echo "Architectures: $(lipo -archs "$APP/Contents/MacOS/PDFSearch")"

# What goes in the disk image
ln -s /Applications "$STAGE/Applications"
cp "dist/Read Me First.txt" "$STAGE/"
EXTRAS="$STAGE/Extras"
mkdir -p "$EXTRAS/Source Code"
cp "dist/PDF Search Guide.pdf" "$EXTRAS/"
cp PDFSearch.swift Info.plist AppIcon.icns build.sh "Build PDF Search.command" "$EXTRAS/Source Code/"
cp -R test-pdfs "$EXTRAS/Source Code/"
cp -R tools "$EXTRAS/Source Code/"
cp "dist/Developer Notes.md" "$EXTRAS/Source Code/"
chmod +x "$EXTRAS/Source Code/build.sh" "$EXTRAS/Source Code/Build PDF Search.command"

echo "Making the disk image…"
rm -f "$OUT"
hdiutil create -quiet -volname "PDF Search" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT"
rm -rf "$WORK"
echo "Done: $OUT ($(du -h "$OUT" | cut -f1))"
open -R "$OUT"
