#!/bin/zsh
# Produit dist/Amplo-<version>.zip et dist/Amplo-<version>.dmg, signés ad hoc (non notarisés).
# Usage : scripts/package.sh <version> [numéro de build]
set -euo pipefail
cd "${0:A:h}/.."

version=${1:?Usage : scripts/package.sh <version> [numéro de build]}
AMPLO_ADHOC=1 AMPLO_VERSION=$version AMPLO_BUILD=${2:-1} ./build.sh

rm -rf dist
mkdir dist
ditto -c -k --norsrc --noextattr --keepParent build/Amplo.app "dist/Amplo-$version.zip"

# dmgbuild écrit la mise en page de la fenêtre (fond, position des icônes) sans piloter le Finder.
if [[ ! -x build/venv/bin/dmgbuild ]]; then
  /usr/bin/python3 -m venv build/venv
  build/venv/bin/pip install --quiet --disable-pip-version-check dmgbuild
fi
build/venv/bin/dmgbuild -s Support/dmg-settings.py \
  -D app=build/Amplo.app -D background=Support/dmg-background.tiff \
  Amplo "dist/Amplo-$version.dmg"

ls -lh dist
