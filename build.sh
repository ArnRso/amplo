#!/bin/zsh
# Compile Amplo avec xcodebuild (Release) et place l'app dans build/Amplo.app.
set -euo pipefail
cd "${0:A:h}"

# Utilise Xcode même si xcode-select pointe encore vers les Command Line Tools.
if ! xcodebuild -version &>/dev/null; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# Sans équipe choisie dans Xcode (Signing & Capabilities), on signe en ad hoc :
# macOS redemandera alors la permission audio après chaque compilation.
signing=()
if ! grep -q 'DEVELOPMENT_TEAM = [A-Z0-9]' Amplo.xcodeproj/project.pbxproj; then
  signing=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
fi

xcodebuild -project Amplo.xcodeproj -scheme Amplo -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build/DerivedData -allowProvisioningUpdates -quiet \
  "${signing[@]}" build

rm -rf build/Amplo.app
cp -R build/DerivedData/Build/Products/Release/Amplo.app build/
echo "OK : build/Amplo.app ($(codesign -dv build/Amplo.app 2>&1 | grep -E '^(Authority|Signature)=' | head -1))"
