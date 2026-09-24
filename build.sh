#!/bin/zsh
# Compile Amplo avec xcodebuild (Release) et place l'app dans build/Amplo.app.
# Avec --install, la copie aussi dans /Applications (emplacement stable pour l'ouverture à la connexion).
# Variables optionnelles (utilisées pour les releases) :
#   AMPLO_ADHOC=1        signature ad hoc même si une équipe est configurée
#   AMPLO_VERSION=1.2.0  version affichée (MARKETING_VERSION)
#   AMPLO_BUILD=42       numéro de build (CURRENT_PROJECT_VERSION)
set -euo pipefail
cd "${0:A:h}"

# Utilise Xcode même si xcode-select pointe encore vers les Command Line Tools.
if ! xcodebuild -version &>/dev/null; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# Sans équipe choisie dans Xcode (Signing & Capabilities), on signe en ad hoc :
# macOS redemandera alors la permission audio après chaque compilation.
settings=()
if [[ ${AMPLO_ADHOC:-} == 1 ]] || ! grep -q 'DEVELOPMENT_TEAM = [A-Z0-9]' Amplo.xcodeproj/project.pbxproj; then
  settings+=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
fi
[[ -n ${AMPLO_VERSION:-} ]] && settings+=(MARKETING_VERSION=$AMPLO_VERSION)
[[ -n ${AMPLO_BUILD:-} ]] && settings+=(CURRENT_PROJECT_VERSION=$AMPLO_BUILD)

xcodebuild -project Amplo.xcodeproj -scheme Amplo -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build/DerivedData -allowProvisioningUpdates -quiet \
  "${settings[@]}" build

# Quitte proprement l'instance remplacée (arrêt du tap, le son revient) : sinon `open`
# se contenterait de réactiver l'ancienne version. Une instance lancée ailleurs est laissée tranquille.
running=$(pgrep -x Amplo | head -1 || true)
if [[ -n $running ]] && { [[ ${1:-} == --install ]] || ps -o command= -p "$running" | grep -q "^$PWD/build/"; }; then
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
