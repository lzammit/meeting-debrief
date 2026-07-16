#!/bin/bash
# Builds a distributable MeetingDebrief.app for a GitHub Release:
#  - universal binary (Apple Silicon + Intel)
#  - ad-hoc signed (no developer identity embedded — nothing personal)
#  - zipped with ditto so the bundle + signature survive the download
#
# Output: dist/MeetingDebrief.zip
#
# Note: the app is NOT notarized, so on first launch downloaders will see
# Gatekeeper's "unverified developer" prompt. The README's "Installing a
# downloaded build" section explains how to open it.
set -euo pipefail
cd "$(dirname "$0")"

echo "Building universal release binary…"
swift build -c release --arch arm64 --arch x86_64

APP="dist/MeetingDebrief.app"
rm -rf "$APP" dist/MeetingDebrief.zip
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/apple/Products/Release/MeetingDebrief "$APP/Contents/MacOS/MeetingDebrief"
cp Info.plist "$APP/Contents/Info.plist"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature: valid bundle, no author identity embedded.
codesign --force --deep --sign - "$APP"

echo "Architectures: $(lipo -archs "$APP/Contents/MacOS/MeetingDebrief")"
echo "Signature: $(codesign -dv "$APP" 2>&1 | grep -i 'Signature\|adhoc' || echo 'ad-hoc')"

# ditto preserves the .app structure and signature (plain zip corrupts them).
ditto -c -k --keepParent "$APP" dist/MeetingDebrief.zip
echo "Release artifact: dist/MeetingDebrief.zip ($(du -h dist/MeetingDebrief.zip | cut -f1))"
echo "Upload this to a GitHub Release."
