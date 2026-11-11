# Fretline

Lector de tablaturas para iPad y Mac al estilo Songsterr: abre Guitar Pro (.gp, .gp3–.gp5, .gpx) y MusicXML, importa tabs de Songsterr y sincroniza la partitura con un vídeo de YouTube.

SwiftUI + SwiftData por fuera, [alphaTab](https://alphatab.net) 1.9 (MPL-2.0) dentro de un `WKWebView` para renderizar y reproducir.

## Puesta en marcha

```sh
brew install xcodegen
cd Fretline
xcodegen            # genera Fretline.xcodeproj a partir de project.yml
open Fretline.xcodeproj
```

En Xcode: target **Fretline → Signing & Capabilities → Team**, elige tu iPad y Run. También vale exportar el .ipa e instalarlo con AltStore.

Requisitos: iPadOS 17+ / macOS 14+.

### Mac

```sh
./build-mac.sh                       # genera dist/Fretline.app (firma ad-hoc)
cp -R dist/Fretline.app /Applications/
```

También puedes abrirlo en Xcode con el esquema **FretlineMac** y darle a ▶. El target de Mac comparte todo el código con el iPad; lo propio de cada plataforma está en `Platform/Platform.swift` y en bloques `#if os(...)`. Va con sandbox, con permiso de red (YouTube y Songsterr) y de lectura de los archivos que elijas.

### DMG y Homebrew

```sh
./build-dmg.sh          # dist/Fretline-<versión>.dmg con acceso directo a Aplicaciones
./release.sh 0.2.0      # versión + DMG + release en GitHub + actualiza la cask del tap
```

Instalar con Homebrew (tap [rbc33/homebrew-fretline](https://github.com/rbc33/homebrew-fretline)):

```sh
brew install --cask rbc33/fretline/fretline
brew upgrade --cask fretline
```

La app va firmada ad-hoc (sin Developer ID), así que la cask le quita la cuarentena al instalarla para que abra sin avisos.

En el Mac, la barra espaciadora hace play/pausa (o marca compás en modo Sync) aunque el foco esté en la partitura. ⌘O abre el importador de archivos.

## Qué hace

- **Biblioteca** con búsqueda, favoritas y borrado. Para importar:
  - el botón «Importar» (Archivos);
  - AirDrop;
  - «Abrir con… Fretline» desde cualquier app.
- **Reproductor**:
  - play/pausa (espacio en teclado o pedal);
  - velocidad de 25 % a 150 %;
  - loop de la selección (arrastra sobre la tab para seleccionar);
  - metrónomo y cuenta atrás;
  - pistas: mostrar/ocultar, mute y solo;
  - vista página u horizontal, y zoom.
- **YouTube**:
  - el vídeo aparece flotante; puedes moverlo de esquina y minimizarlo;
  - en modo YouTube, el reloj lo marca el vídeo y alphaTab (`PlayerMode.EnabledExternalMedia`) mueve el cursor a partir de sus puntos de sync;
  - play, seek, loop y velocidad se aplican al vídeo.
- **Editor de sync** (botón «Sync» en modo YouTube):
  - *Marcar compás*: con el vídeo sonando, toca el botón, la barra espaciadora o un pedal en el primer tiempo de cada compás. Respeta repeticiones y finales alternativos.
  - *Compás 1 = ahora*: modo rápido. Solo marcas el inicio y el resto se calcula con el tempo; vale para canciones grabadas a click.
  - Ajuste de ±50 ms, deshacer y borrar.
  - Se guarda solo.
- **Songsterr**:
  - pega el enlace (`…-s12345`) o el número de la canción;
  - descarga todas las pistas, las convierte a `.gp` y, si existe, trae el vídeo con sus puntos de sync.

## Arquitectura

```
Fretline/
├── FretlineApp.swift          AVAudioSession .playback + SwiftData
├── Models/Song.swift          Song (@Model) + SyncPoint (= FlatSyncPoint de alphaTab)
├── Services/
│   ├── SongLibrary.swift      archivos en Documents/Songs, importación
│   └── SongsterrClient.swift  descarga de Songsterr (aislado) + SongsterrImporter
├── Engine/
│   ├── LocalSchemeHandler     fretline://app/… sirve Web/ y fretline://app/__songs/… la biblioteca
│   ├── TabEngine.swift        puente Swift ⇄ JS (comandos y eventos)
│   └── TabWebView.swift
├── YouTube/                   IFrame API en un WKWebView aparte (origen https://<bundle id>)
├── Views/                     Library, Player, SyncPanel, Tracks, VideoLink, SongsterrImport
└── Web/                       se copia tal cual al bundle
    ├── index.html, app.js     alphaTab + API window.fretline.*
    ├── songsterr/convert.js   JSON de Songsterr → Score de alphaTab → GP7
    └── vendor/alphatab/       alphaTab 1.9, fuente Bravura, SoundFont Sonivox
```

Así fluye el sync en modo YouTube:

```
YouTube (tick cada 40 ms) ──onTime──▶ TabEngine.externalTime(ms) ──▶ output.updatePosition(ms)
alphaTab (play/seek/loop/velocidad) ──handler──▶ externalPlay/Seek/Rate ──▶ YouTubePlayer
```

## Depuración

- Las dos webviews tienen `isInspectable = true`. Para inspeccionarlas: Safari en el Mac → Desarrollo → tu iPad → Fretline. Ahí ves la consola de alphaTab.
- `tools/`:
  - `npm install && npm test` prueba el conversor de Songsterr en Node con un fixture inventado;
  - `npm run update-alphatab` actualiza alphaTab en `Web/vendor`.

## Avisos

- **Songsterr** no tiene API pública. Los endpoints de `SongsterrClient.swift` son los que usa su visor web y pueden cambiar sin aviso. Además, descargar su contenido va contra sus términos, así que esto es solo para uso personal. Todo el código de Songsterr está en `SongsterrClient.swift` y `Web/songsterr/convert.js`, por si un día quieres quitarlo o publicar en App Store.
- El conversor cubre lo habitual:
  - duraciones, puntillos y tresillos;
  - ligaduras, hammer/pull, slides, bends, armónicos, vibrato;
  - palm mute, let ring, ghost y muteadas;
  - repeticiones, marcadores, tempo y batería.
  
  Si alguna tab sale rara, el sitio a tocar es `convert.js`.
- **YouTube**:
  - algunos vídeos tienen el embebido desactivado (errores 101/150) y la app lo avisa;
  - el reproductor se carga con origen `https://com.rbc33.fretline`, que es lo que YouTube pide a apps nativas. Si cambias el bundle id, cambia también ese origen.
- **Workers en WKWebView**: alphaTab usa web workers para renderizar y para el sintetizador. Se sirven desde `fretline://` con el MIME correcto, lo que debería bastar. Si en tu versión de iPadOS el render no arranca, prueba `core.useWorkers: false` en `Web/app.js`.
