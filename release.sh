#!/bin/bash
# Builds a distributable, notarized MeetingDebrief release:
#  - universal binary (Apple Silicon + Intel)
#  - Developer ID signed with the hardened runtime
#  - notarized by Apple and stapled, so it opens cleanly on any Mac
#  - packaged as a drag-to-Applications DMG (plus a zip for auto-update tools)
#
# Output: dist/MeetingDebrief-<version>.dmg and dist/MeetingDebrief-<version>.zip
#
# One-time setup (both require signing in to your Apple Developer account):
#  1. Developer ID Application certificate:
#     Xcode → Settings → Accounts → (your team) → Manage Certificates…
#     → + → "Developer ID Application"
#  2. Notarization credentials (uses an app-specific password from
#     account.apple.com → Sign-In and Security → App-Specific Passwords):
#     xcrun notarytool store-credentials notary \
#       --apple-id <your-apple-id> --team-id <TEAMID>
set -euo pipefail
cd "$(dirname "$0")"

NOTARY_PROFILE="${NOTARY_PROFILE:-notary}"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)

# --- Preflight: fail before the slow build if signing/notarization isn't set up.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Developer ID Application/ {print $2; exit}')
if [ -z "$IDENTITY" ]; then
  echo "error: no 'Developer ID Application' certificate in the keychain." >&2
  echo "Create one in Xcode → Settings → Accounts → Manage Certificates… → +" >&2
  exit 1
fi
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "error: no notarization credentials stored under profile '$NOTARY_PROFILE'." >&2
  echo "Run: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple-id> --team-id <TEAMID>" >&2
  exit 1
fi
TEAM_IN_CERT=$(echo "$IDENTITY" | sed -E 's/.*\(([A-Z0-9]+)\)$/\1/')
echo "Signing as: $IDENTITY"

echo "Building universal release binary…"
swift build -c release --arch arm64 --arch x86_64

APP="dist/MeetingDebrief.app"
DMG="dist/MeetingDebrief-$VERSION.dmg"
ZIP="dist/MeetingDebrief-$VERSION.zip"
rm -rf "$APP" "$DMG" "$ZIP" dist/dmg-staging
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/apple/Products/Release/MeetingDebrief "$APP/Contents/MacOS/MeetingDebrief"
cp Info.plist "$APP/Contents/Info.plist"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Hardened runtime + secure timestamp are both required for notarization.
codesign --force --options runtime --timestamp \
  --entitlements MeetingDebrief.entitlements \
  --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "Architectures: $(lipo -archs "$APP/Contents/MacOS/MeetingDebrief")"

echo "Notarizing (usually 1–5 minutes)…"
ditto -c -k --keepParent "$APP" dist/notarize-upload.zip
xcrun notarytool submit dist/notarize-upload.zip \
  --keychain-profile "$NOTARY_PROFILE" --team-id "$TEAM_IN_CERT" --wait
rm dist/notarize-upload.zip

# Staple the notarization ticket so Gatekeeper works offline too.
xcrun stapler staple "$APP"

echo "Packaging DMG…"
mkdir dist/dmg-staging
cp -R "$APP" dist/dmg-staging/
ln -s /Applications dist/dmg-staging/Applications
hdiutil create -volname "MeetingDebrief" -srcfolder dist/dmg-staging \
  -ov -format UDZO "$DMG" -quiet
rm -rf dist/dmg-staging
# The DMG itself gets signed and notarized too, so the download is trusted
# end-to-end (not just the app inside it).
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" \
  --keychain-profile "$NOTARY_PROFILE" --team-id "$TEAM_IN_CERT" --wait
xcrun stapler staple "$DMG"

# Zip artifact for people who prefer it (and for update tooling).
ditto -c -k --keepParent "$APP" "$ZIP"

echo
echo "Gatekeeper check:"
spctl --assess --type open --context context:primary-signature -v "$DMG"
spctl --assess --type execute -v "$APP"
echo
echo "Release artifacts:"
du -h "$DMG" "$ZIP" | awk '{print "  " $2 " (" $1 ")"}'
echo "Upload these to a GitHub Release."
