#!/bin/sh
# Actualiza ~/code/swift/Fretline con el Fretline*.zip más reciente de ~/code/swift.
#
#   ./update-fretline.sh          copia y sobrescribe los archivos del zip (no borra nada más)
#   ./update-fretline.sh --clean  además borra los archivos del proyecto que ya no están en el zip
#                                 (nunca toca .git, dist, build, Fretline.xcodeproj ni node_modules)
#
# Si descargas el zip varias veces y el navegador lo llama «Fretline (1).zip», se usa el más reciente.
set -e

BASE="$HOME/code/swift"
DEST="$BASE/Fretline"

ZIP=$(ls -t "$BASE"/Fretline*.zip 2>/dev/null | head -1)
[ -n "$ZIP" ] || { echo "❌ No hay ningún Fretline*.zip en $BASE"; exit 1; }

TMP=$(mktemp -d "$BASE/.fretline-update.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
trap 'exit 1' INT TERM HUP PIPE

echo "📦 Descomprimiendo $(basename "$ZIP")…"
ditto -x -k "$ZIP" "$TMP"
SRC="$TMP/Fretline"
[ -d "$SRC" ] || { echo "❌ El zip no contiene la carpeta Fretline/"; exit 1; }

mkdir -p "$DEST"
if [ "$1" = "--clean" ]; then
  rsync -a --delete \
    --exclude '.git/' --exclude 'dist/' --exclude 'build/' \
    --exclude 'Fretline.xcodeproj/' --exclude 'node_modules/' \
    --exclude 'DerivedData/' --exclude '.DS_Store' --exclude 'update-fretline.sh' \
    "$SRC"/ "$DEST"/
else
  # Sobrescribe los archivos del zip y deja el resto (.git, dist, build…) intacto
  cp -Rp "$SRC"/. "$DEST"/
fi

echo "✅ $DEST actualizado (la carpeta temporal se borra sola)"
if [ -d "$DEST/.git" ]; then
  echo ""
  echo "Cambios respecto al último commit:"
  git -C "$DEST" status --short | head -30
fi
