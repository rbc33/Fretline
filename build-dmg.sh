#!/bin/sh
# Compila Fretline para macOS y la empaqueta en dist/Fretline-<versión>.dmg
# (con el acceso directo a Aplicaciones para arrastrarla).
# Uso: ./build-dmg.sh   (en el Mac, desde la carpeta Fretline)
set -e
cd "$(dirname "$0")"

./build-mac.sh

APP="dist/Fretline.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="dist/Fretline-$VERSION.dmg"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Fretline.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create \
  -volname "Fretline $VERSION" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  "$DMG" 2>&1 | grep -v -e "deprecated" -e "diskutil image" >&2 || true
[ -f "$DMG" ] || { echo "❌ No se pudo crear $DMG"; exit 1; }

SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
echo "✅ $PWD/$DMG"
echo "   sha256: $SHA"
