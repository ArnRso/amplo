#!/bin/zsh
# Compile Amplo et assemble build/Amplo.app, sans Xcode (Command Line Tools suffisent).
set -euo pipefail
cd "${0:A:h}"

APP="build/Amplo.app"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' Support/Info.plist)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc \
  -swift-version 6 \
  -target arm64-apple-macos15.0 \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -O \
  -parse-as-library \
  -module-name Amplo \
  -o "$APP/Contents/MacOS/Amplo" \
  Amplo/**/*.swift

cp Support/Info.plist "$APP/Contents/Info.plist"

# Identité "Apple Development" si elle existe (permission audio conservée entre deux builds),
# sinon signature ad hoc (macOS redemandera la permission après chaque build).
IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')}
codesign --force --sign "${IDENTITY:--}" "$APP"

echo "OK : $APP ($BUNDLE_ID, signature : ${IDENTITY:-ad hoc})"
