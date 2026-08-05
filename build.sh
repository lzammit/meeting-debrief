#!/bin/bash
# Builds MeetingDebrief.app into dist/. Launch with: open dist/MeetingDebrief.app
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="dist/MeetingDebrief.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MeetingDebrief "$APP/Contents/MacOS/MeetingDebrief"
cp Info.plist "$APP/Contents/Info.plist"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sign with a real identity when available — TCC permissions (calendar, mic,
# screen/system-audio recording) are tied to the code signature, and an ad-hoc
# signature changes every build, silently invalidating granted permissions.
# Prefer the Developer ID cert (same identity release.sh uses): a dev build
# and an installed release then share one signature, so privacy grants stick
# when switching between them instead of resetting on every swap.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Developer ID Application/ {print $2; exit}')
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')
fi
if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" "$APP"
  echo "Signed with: $IDENTITY"
else
  codesign --force --sign - "$APP"
  echo "Signed ad-hoc (permissions may reset on rebuild)"
fi

echo "Built $APP"
echo "Run it with: open $APP"
