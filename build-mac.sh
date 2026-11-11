#!/bin/sh
# Compila Fretline para macOS con firma ad-hoc y deja Fretline.app en dist/.
# Uso: ./build-mac.sh   (desde la carpeta Fretline, en el Mac con Xcode)
set -e
cd "$(dirname "$0")"

command -v xcodegen >/dev/null || { echo "Instala XcodeGen: brew install xcodegen"; exit 1; }
xcodegen

rm -rf build/mac dist/Fretline.app
xcodebuild \
  -project Fretline.xcodeproj \
  -target FretlineMac \
  -configuration Release \
  -sdk macosx \
  SYMROOT="$PWD/build/mac" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="" \
  -quiet \
  build

APP="build/mac/Release/Fretline.app"
[ -d "$APP" ] || { echo "❌ No se generó $APP. Revisa el error de xcodebuild de arriba."; exit 1; }

mkdir -p dist
ditto "$APP" dist/Fretline.app
echo "✅ Listo: $PWD/dist/Fretline.app"
echo "   Para instalarla: cp -R dist/Fretline.app /Applications/"
