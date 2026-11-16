#!/bin/sh
# Actualiza ~/code/swift/Fretline con el zip más reciente (~/code/swift/Fretline.zip o «Fretline (n).zip»).
# Se puede ejecutar desde cualquier carpeta.
#
#   ./update-fretline.sh          copia y sobrescribe los archivos del zip (no borra nada más)
#   ./update-fretline.sh --clean  además borra lo que ya no esté en el zip
#                                 (nunca toca .git, dist, build, Fretline.xcodeproj ni node_modules)
set -e

NAME="Fretline"
BASE="${FRETLINE_BASE:-$HOME/code/swift}"
DEST="$BASE/$NAME"

# Solo «NAME.zip» y «NAME (n).zip»
ZIP=$(ls -t "$BASE/$NAME.zip" "$BASE/$NAME ("*").zip" 2>/dev/null | head -1)
[ -n "$ZIP" ] || { echo "❌ No hay ningún $NAME.zip en $BASE"; exit 1; }
[ -d "$DEST" ] || { echo "❌ No existe la carpeta $DEST"; exit 1; }

TMP=$(mktemp -d "$BASE/.$NAME-update.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
trap 'exit 1' INT TERM HUP PIPE

echo "📦 Descomprimiendo $(basename "$ZIP") en $DEST…"
ditto -x -k "$ZIP" "$TMP"
SRC="$TMP/$NAME"
[ -d "$SRC" ] || { echo "❌ El zip no contiene la carpeta $NAME/"; exit 1; }

if [ "$1" = "--clean" ]; then
  rsync -a --delete \
    --exclude '.git' --exclude 'dist/' --exclude 'build/' \
    --exclude 'Fretline.xcodeproj/' --exclude 'node_modules/' \
    --exclude 'DerivedData/' --exclude '.DS_Store' \
    "$SRC"/ "$DEST"/
else
  # Sobrescribe los archivos del zip y deja el resto (.git, dist, build…) intacto
  cp -Rp "$SRC"/. "$DEST"/
fi

echo "✅ $DEST actualizado (la carpeta temporal se borra sola)"
if [ -e "$DEST/.git" ]; then
  echo ""
  echo "Cambios respecto al último commit:"
  git -C "$DEST" status --short | head -30
fi
