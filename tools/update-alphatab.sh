#!/bin/sh
# Copia alphaTab (de node_modules) a la carpeta Web/vendor del proyecto
set -e
cd "$(dirname "$0")"
npm install
SRC=node_modules/@coderline/alphatab/dist
DST=../Fretline/Web/vendor/alphatab
mkdir -p "$DST/font" "$DST/soundfont"
cp $SRC/alphaTab.min.mjs $SRC/alphaTab.core.min.mjs $SRC/alphaTab.worker.min.mjs $SRC/alphaTab.worklet.min.mjs "$DST/"
cp $SRC/font/Bravura.woff2 $SRC/font/Bravura.otf $SRC/font/Bravura-OFL.txt "$DST/font/"
cp $SRC/soundfont/sonivox.sf2 $SRC/soundfont/LICENSE $SRC/soundfont/README.md "$DST/soundfont/"
echo "alphaTab actualizado en $DST"
