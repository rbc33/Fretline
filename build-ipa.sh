#!/bin/sh
# Genera Fretline.ipa sin firmar (SideStore/AltStore lo firman al instalar).
# Uso: ./build-ipa.sh   (desde la carpeta Fretline, en el Mac con Xcode)
set -e
cd "$(dirname "$0")"

command -v xcodegen >/dev/null || { echo "Instala XcodeGen: brew install xcodegen"; exit 1; }
xcodegen

rm -rf build Payload Fretline.ipa
xcodebuild \
  -project Fretline.xcodeproj \
  -target Fretline \
  -configuration Release \
  -sdk iphoneos \
  SYMROOT="$PWD/build" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  -quiet \
  build

APP="build/Release-iphoneos/Fretline.app"
[ -d "$APP" ] || { echo "❌ No se generó $APP. Revisa el error de xcodebuild de arriba."; exit 1; }

mkdir Payload
cp -R "$APP" Payload/
zip -qry Fretline.ipa Payload
rm -rf Payload
echo "✅ Listo: $PWD/Fretline.ipa"
