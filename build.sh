#!/bin/zsh
# Compile Amplo avec xcodebuild (Release) et place l'app dans build/Amplo.app.
# Avec --install, la copie aussi dans /Applications (emplacement stable pour l'ouverture à la connexion).
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

# Quitte proprement l'instance en cours (arrêt du tap, le son revient) : sinon `open`
# se contenterait de réactiver l'ancienne version.
if pgrep -xq Amplo; then
  osascript -e 'quit app id "com.amplo.Amplo"'
  while pgrep -xq Amplo; do sleep 0.1; done
fi

rm -rf build/Amplo.app
cp -R build/DerivedData/Build/Products/Release/Amplo.app build/
app=build/Amplo.app
if [[ ${1:-} == --install ]]; then
  rm -rf /Applications/Amplo.app
  cp -R build/Amplo.app /Applications/
  app=/Applications/Amplo.app
fi

echo "OK : $app ($(codesign -dvv "$app" 2>&1 | grep -E '^(Authority|Signature)=' | head -1))"
