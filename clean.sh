#!/bin/sh
# Borra los artefactos de compilación para no acumular DMG, IPA ni builds antiguos.
#   ./clean.sh         build/, dist/ y restos del .ipa (Payload/, Fretline.ipa)
#   ./clean.sh --all   además el Fretline.xcodeproj generado (xcodegen lo vuelve a crear)
set -e
cd "$(dirname "$0")"

before=""
if [ -e build ] || [ -e dist ]; then
  before=$(du -sch build dist 2>/dev/null | tail -1 | awk '{print $1}')
fi
rm -rf build dist Payload Fretline.ipa
if [ "$1" = "--all" ]; then
  rm -rf Fretline.xcodeproj
fi
echo "🧹 Limpio${before:+ (liberado: $before)}"
