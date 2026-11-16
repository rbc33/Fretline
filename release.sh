#!/bin/sh
# Publica una versión de Fretline para Mac:
#   1. fija la versión en project.yml
#   2. genera el .dmg (build-dmg.sh) y el .ipa sin firmar para iPad (build-ipa.sh)
#   3. crea la release vX.Y.Z en GitHub con el .dmg y el .ipa
#   4. actualiza la fuente de SideStore/AltStore (docs/apps.json)
#   5. actualiza la cask del tap de Homebrew (versión + sha256) y la sube
#   6. actualiza Fretline en este Mac con Homebrew (respondiendo «sí» a las preguntas)
#
# Uso: ./release.sh 0.2.0
#      ./release.sh 0.1.0 --replace   (rehace una versión ya publicada: borra su release y su etiqueta)
# Requisitos: Xcode, XcodeGen y GitHub CLI con sesión iniciada (gh auth login).
set -e
cd "$(dirname "$0")"

VERSION="$1"
REPLACE="$2"
[ -n "$VERSION" ] || { echo "Uso: ./release.sh <versión> [--replace]   (p. ej. ./release.sh 0.2.0)"; exit 1; }
command -v gh >/dev/null || { echo "Instala GitHub CLI: brew install gh"; exit 1; }

REPO="${FRETLINE_REPO:-rbc33/Fretline}"
TAP="${FRETLINE_TAP:-rbc33/homebrew-fretline}"
# Copia local del tap (si existe se actualiza ahí; si no, se clona en una carpeta temporal)
TAP_DIR="${FRETLINE_TAP_DIR:-../homebrew-fretline}"

# 0. Empezar limpio: fuera builds, DMG e IPA de versiones anteriores
./clean.sh

# 1. Versión (MARKETING_VERSION) y número de build (nº de commits)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
sed -i '' -E "s/MARKETING_VERSION: \"[^\"]*\"/MARKETING_VERSION: \"$VERSION\"/" project.yml
sed -i '' -E "s/CURRENT_PROJECT_VERSION: \"[^\"]*\"/CURRENT_PROJECT_VERSION: \"$BUILD\"/" project.yml

# 2. DMG
./build-dmg.sh
DMG="dist/Fretline-$VERSION.dmg"
[ -f "$DMG" ] || { echo "❌ No se encontró $DMG"; exit 1; }
SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')

# .ipa sin firmar para SideStore / AltStore
./build-ipa.sh
IPA="dist/Fretline-$VERSION.ipa"
mv Fretline.ipa "$IPA"

# 3. Release en GitHub
if gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
  if [ "$REPLACE" = "--replace" ]; then
    echo "↻ Sustituyendo la release v$VERSION existente…"
    gh release delete "v$VERSION" --repo "$REPO" --yes --cleanup-tag
    git tag -d "v$VERSION" >/dev/null 2>&1 || true
  else
    echo "❌ La release v$VERSION ya existe. Usa ./release.sh $VERSION --replace para rehacerla."
    exit 1
  fi
fi
gh release create "v$VERSION" "$DMG" "$IPA" \
  --repo "$REPO" \
  --title "Fretline $VERSION" \
  --generate-notes

# 4. Fuente de SideStore/AltStore (se publica en GitHub Pages al hacer push)
python3 tools/update-source.py --ipa "$IPA" --json docs/apps.json --repo "$REPO"

# 5. Cask del tap
if [ -d "$TAP_DIR/.git" ]; then
  git -C "$TAP_DIR" pull -q --rebase
else
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  gh repo clone "$TAP" "$TMP/tap" -- --depth 1 --quiet
  TAP_DIR="$TMP/tap"
fi
CASK="$TAP_DIR/Casks/fretline.rb"
sed -i '' -E "s/^  version \"[^\"]*\"/  version \"$VERSION\"/" "$CASK"
sed -i '' -E "s/^  sha256 .*/  sha256 \"$SHA\"/" "$CASK"
git -C "$TAP_DIR" commit -qam "fretline $VERSION"
git -C "$TAP_DIR" push -q

# Fuera archivos intermedios; en dist/ quedan solo el DMG, el IPA y la app de esta versión
rm -rf build Payload

# 6. Actualizar Fretline en este Mac con Homebrew, aceptando las preguntas automáticamente
#    (FRETLINE_NO_INSTALL=1 ./release.sh X.Y.Z para saltarlo)
if [ -z "$FRETLINE_NO_INSTALL" ] && command -v brew >/dev/null; then
  echo ""
  echo "🍺 Actualizando Fretline en este Mac…"
  brew update --quiet || true
  if brew list --cask fretline >/dev/null 2>&1; then
    if [ "$REPLACE" = "--replace" ]; then
      # Misma versión: upgrade no la detecta como nueva
      yes | brew reinstall --cask fretline || FRETLINE_BREW_FAILED=1
    else
      yes | brew upgrade --cask fretline || FRETLINE_BREW_FAILED=1
    fi
    # Si se borró /Applications/Fretline.app a mano, brew no puede desinstalar la anterior:
    # se olvida la instalación vieja y se instala de cero
    if [ -n "$FRETLINE_BREW_FAILED" ]; then
      echo "↻ Reinstalando Fretline desde cero…"
      brew uninstall --cask --force fretline || true
      yes | brew install --cask rbc33/fretline/fretline || echo "⚠️  No se pudo instalar con Homebrew. La release está publicada igualmente."
    fi
  else
    yes | brew install --cask rbc33/fretline/fretline || echo "⚠️  No se pudo instalar con Homebrew. La release está publicada igualmente."
  fi
fi

echo ""
echo "✅ Fretline $VERSION publicada"
echo "   Release: https://github.com/$REPO/releases/tag/v$VERSION"
echo "   Instalar: brew install --cask rbc33/fretline/fretline"
echo "   Actualizar: brew upgrade --cask fretline"
echo ""
echo "Recuerda hacer commit y push de project.yml y docs/apps.json (la fuente de SideStore/AltStore)."
