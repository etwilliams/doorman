#!/bin/bash
# Builds Doorman.app from the Swift package.
#   ./build.sh            release build into build/Doorman.app
#   ./build.sh --install  ...and copy it to /Applications
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

# Ad-hoc signed: enough for LaunchServices and login items on this Mac.
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/Doorman.app
  cp -R "$APP" /Applications/
  # Make sure LaunchServices sees the new bundle as the http/https handler.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Doorman.app
  # ...and that the Services menu picks up "Open Links with Doorman".
  /System/Library/CoreServices/pbs -update
  echo "Installed to /Applications/Doorman.app"
fi
