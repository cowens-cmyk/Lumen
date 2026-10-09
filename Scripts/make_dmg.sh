#!/bin/zsh
# Builds a signed Release Lumen.app and wraps it in dist/Lumen-<version>.dmg (drag-to-Applications layout).
# Signs with the Hope Church Developer ID. If a notarytool keychain profile named "lumen-notary" exists,
# the DMG is notarized and stapled too, so it opens with no Gatekeeper warning:
#   xcrun notarytool store-credentials lumen-notary --apple-id <id> --team-id TCAQTA64TB --password <app-specific-password>
set -euo pipefail
cd "$(dirname "$0")/.."
TEAM="TCAQTA64TB"
IDENTITY="Developer ID Application: Hope Church JC ($TEAM)"
DD="${DERIVED_DATA:-build}"

command -v xcodegen >/dev/null || brew install xcodegen
xcodegen generate >/dev/null
xcodebuild -project Lumen.xcodeproj -scheme Lumen -configuration Release -derivedDataPath "$DD" \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_IDENTITY="$IDENTITY" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" build | tail -1

APP="$DD/Build/Products/Release/Lumen.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
codesign --verify --deep --strict "$APP"

mkdir -p dist
DMG="dist/Lumen-$VERSION.dmg"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Lumen $VERSION" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
rm -rf "${STAGE:?}"
codesign --sign "$IDENTITY" --timestamp "$DMG"

if xcrun notarytool history --keychain-profile lumen-notary >/dev/null 2>&1; then
  xcrun notarytool submit "$DMG" --keychain-profile lumen-notary --wait
  xcrun stapler staple "$DMG"
  echo "Notarized."
else
  echo "Not notarized (no 'lumen-notary' profile) — first launch needs right-click → Open."
fi
echo "Created $DMG ($(du -h "$DMG" | cut -f1))"
