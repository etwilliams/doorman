#!/bin/bash
# Builds Doorman.app from the Swift package.
#   ./build.sh            release build into build/Doorman.app
#   ./build.sh --install  ...and copy it to /Applications
#   ./build.sh --release  Developer ID signed, notarized and stapled, as
#                         build/Doorman.dmg. Notarization credentials come from
#                         .notarize.env (gitignored): APPLE_ID, APPLE_TEAM_ID and
#                         APPLE_APP_PASSWORD, an app-specific password from
#                         appleid.apple.com.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Doorman"

APP=build/Doorman.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Doorman"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [[ "${1:-}" == "--release" ]]; then
  IDENTITY="Developer ID Application: Dakuupa LLC (4FVK23Z2QJ)"
  [[ -f .notarize.env ]] || { echo "Missing .notarize.env" >&2; exit 1; }
  set -a; source .notarize.env; set +a
  NOTARY=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD")
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP"

  ZIP=build/Doorman-notarize.zip
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" "${NOTARY[@]}" --wait
  rm -f "$ZIP"
  xcrun stapler staple "$APP"

  DMG=build/Doorman.dmg
  STAGE=$(mktemp -d)
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  rm -f "$DMG"
  hdiutil create -volname "Link Doorman" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
  rm -rf "$STAGE"
  codesign --force --sign "$IDENTITY" --timestamp "$DMG"
  xcrun notarytool submit "$DMG" "${NOTARY[@]}" --wait
  xcrun stapler staple "$DMG"
  echo "Built $DMG"
  exit 0
fi

# Ad-hoc signed: enough for LaunchServices and login items on this Mac.
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/Doorman.app
  cp -R "$APP" /Applications/
  # Make sure LaunchServices sees the new bundle as the http/https handler.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Doorman.app
  # ...and that the Services menu picks up "Open Links with Link Doorman".
  /System/Library/CoreServices/pbs -update
  echo "Installed to /Applications/Doorman.app"
fi
