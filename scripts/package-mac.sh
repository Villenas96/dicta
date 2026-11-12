#!/bin/zsh
# Genera los paquetes para repartir Dicta a otros Macs (alumnos):
#   dist/Dicta-<versión>.dmg      → arrastrar a Aplicaciones
#   dist/Dicta-mac.zip            → lo usa el instalador de una línea (install-mac.sh)
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)

UNIVERSAL=1 ./scripts/build-app.sh
lipo -info dist/Dicta.app/Contents/MacOS/Dicta

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R dist/Dicta.app "$STAGE/"
ln -s /Applications "$STAGE/Aplicaciones"
cp docs/LEEME-MAC.txt "$STAGE/LÉEME - Cómo instalar.txt"

DMG="dist/Dicta-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Dicta $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -f dist/Dicta-mac.zip
ditto -c -k --keepParent dist/Dicta.app dist/Dicta-mac.zip

shasum -a 256 "$DMG" dist/Dicta-mac.zip
echo "✔ Paquetes listos en dist/"
