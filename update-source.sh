#!/bin/sh
# Añade a la fuente de SideStore/AltStore (docs/apps.json) una versión YA publicada,
# descargando su .ipa de la release de GitHub. Útil para dar de alta la versión actual.
# Uso: ./update-source.sh 0.3.0
set -e
cd "$(dirname "$0")"
VERSION="$1"
[ -n "$VERSION" ] || { echo "Uso: ./update-source.sh <versión>"; exit 1; }
REPO="${FRETLINE_REPO:-rbc33/Fretline}"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
gh release download "v$VERSION" --repo "$REPO" --pattern "*.ipa" --dir "$TMP" || {
  echo "❌ La release v$VERSION no tiene .ipa. Publica una versión nueva con ./release.sh y se añadirá sola."
  exit 1
}
python3 tools/update-source.py --ipa "$(ls "$TMP"/*.ipa | head -1)" --json docs/apps.json --repo "$REPO"
