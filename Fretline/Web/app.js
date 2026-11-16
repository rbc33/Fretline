// Capa web de Fretline: alphaTab + puente con Swift.
// Swift -> JS: window.fretline.<comando>(...)
// JS -> Swift: window.webkit.messageHandlers.fretline.postMessage({ type, ... })

import * as alphaTab from './vendor/alphatab/alphaTab.min.mjs';
import { buildScore, videoPointsToSync, playOrder, chooseVideo } from './songsterr/convert.js';
import { Editor, TUNINGS } from './editor.js';

const BASE = new URL('./', import.meta.url).href;
const el = document.getElementById('tab');
const scroller = document.getElementById('scroller');
const loading = document.getElementById('loading');

const post = (type, payload = {}) => {
  try {
    window.webkit?.messageHandlers?.fretline?.postMessage({ type, ...payload });
  } catch (e) {
    console.log('[bridge]', type, payload);
  }
};
window.addEventListener('error', (e) => post('error', { message: String(e.message || e) }));
window.addEventListener('unhandledrejection', (e) => post('error', { message: String(e.reason?.message || e.reason) }));

// ---------- estado ----------
const state = {
  api: null,
  mode: 'synth', // 'synth' | 'youtube'
  songUrl: null,
  syncPoints: [], // FlatSyncPoint[]
  visibleTracks: null, // índices
  layout: 'page',
  scale: 1.0,
  speed: 1.0,
  looping: false,
  metronome: 0,
  countIn: false,
  lastPositionPost: 0,
  resumeTick: null,
  pendingPlay: false,
  wantPlaying: false, // el usuario quiere que suene (hasta stop, pausa o fin)
  barSelectMode: false, // modo «Compases»: tocar compases para elegir el bucle
  barSel: null,         // { start, end } índices de compás (0-based)
  barAnchor: null,      // primer compás tocado, esperando el segundo
  savedRange: null,     // rango guardado mientras se cambia de modo
  latencyMs: null,      // compensación de latencia: null = automática
  edits: [],            // ediciones guardadas (mover compases de cuerda) a aplicar al cargar
  rebuilding: false,    // el editor está recargando su partitura reconstruida (no es una carga nueva)
  holdUntil: null,      // YouTube: el cursor espera quieto hasta este tiempo (pre-roll)
  lastAudioActivity: 0, // última vez que sonó algo (para saber si hay que «calentar» el audio)
  downBar: null,
  switching: false,
};

function settingsFor(mode) {
  return {
    core: {
      fontDirectory: BASE + 'vendor/alphatab/font/',
      useWorkers: true,
      engine: 'svg',
    },
    display: {
      layoutMode: state.layout === 'horizontal' ? alphaTab.LayoutMode.Horizontal : alphaTab.LayoutMode.Page,
      scale: state.scale,
      staveProfile: alphaTab.StaveProfile.Default,
    },
    player: {
      playerMode: mode === 'youtube' ? alphaTab.PlayerMode.EnabledExternalMedia : alphaTab.PlayerMode.EnabledSynthesizer,
      soundFont: BASE + 'vendor/alphatab/soundfont/sonivox.sf2',
      scrollElement: scroller,
      enableCursor: true,
      enableAnimatedBeatCursor: true,
      enableUserInteraction: true,
      // ScriptProcessor es más robusto que AudioWorklet en WKWebView
      outputMode: alphaTab.PlayerOutputMode.WebAudioScriptProcessor,
      scrollOffsetY: -40,
    },
  };
}

// ---------- ciclo de vida de alphaTab ----------
function createApi() {
  if (state.api) {
    try { state.api.destroy(); } catch {}
    el.innerHTML = '';
  }
  const api = new alphaTab.AlphaTabApi(el, settingsFor(state.mode));
  state.api = api;

  api.scoreLoaded.on((score) => {
    applySyncPointsToScore(score);
    if (state.rebuilding) {
      // Partitura reconstruida por el editor: ya lleva todos los cambios
      state.rebuilding = false;
    } else {
      // Carga nueva: las ediciones de cuerda se guardan aparte y se aplican aquí
      for (const op of state.edits) moveStrings(score, op);
      editor?.resetHistory();
    }
    post('scoreLoaded', {
      title: score.title,
      artist: score.artist,
      barCount: score.masterBars.length,
      tempo: score.tempo,
      tracks: score.tracks.map((t) => ({
        index: t.index,
        name: t.name,
        isPercussion: t.staves.some((s) => s.isPercussion),
      })),
      hasSyncPoints: state.syncPoints.length > 0,
    });
  });

  api.renderStarted.on(() => loading.classList.add('on'));
  api.renderFinished.on(() => {
    loading.classList.remove('on');
    editor?.updateCursor();
  });

  api.playerReady.on(() => {
    api.playbackSpeed = state.speed;
    api.isLooping = state.looping;
    api.metronomeVolume = state.mode === 'synth' ? state.metronome : 0;
    api.countInVolume = state.mode === 'synth' && state.countIn ? 1 : 0;
    if (state.mode === 'youtube') attachExternalHandler();
    patchSynthOutput();
    post('latency', { autoMs: autoLatency(), mode: state.mode });
    // Tras cambiar de modo, seguimos en el mismo compás
    if (state.resumeTick != null) {
      api.tickPosition = state.resumeTick;
      state.resumeTick = null;
    }
    // Recuperar la selección tras cambiar sintetizador <-> YouTube
    if (state.barSel) {
      selectBars(state.barSel.start, state.barSel.end);
    } else if (state.savedRange) {
      api.playbackRange = state.savedRange;
    }
    state.savedRange = null;
    api.isLooping = state.looping;
    state.switching = false;
    post('playerReady', { mode: state.mode });
  });

  api.soundFontLoadFailed?.on((e) => post('error', { message: 'Couldn’t load the SoundFont: ' + String(e?.message || e) }));
  api.midiLoadFailed?.on((e) => post('error', { message: 'Couldn’t prepare the score audio: ' + String(e?.message || e) }));

  api.playerStateChanged.on((e) => {
    const playing = e.state === alphaTab.synth.PlayerState.Playing;
    post('playerState', { playing });
    if (playing) return;
    if (e.stopped) {
      state.wantPlaying = false; // stop o fin de canción
    } else if (state.wantPlaying && state.mode === 'synth' && !state.switching) {
      // Pausa que no ha pedido nadie (audio interrumpido por iOS): reanudamos
      setTimeout(() => {
        if (state.wantPlaying && state.api?.playerState !== alphaTab.synth.PlayerState.Playing) recoverPlayback('unexpected pause');
      }, 300);
    }
  });
  api.playerFinished.on(() => { state.wantPlaying = false; });

  api.playerPositionChanged.on((e) => {
    const now = performance.now();
    if (now - state.lastPositionPost < 200) return;
    state.lastPositionPost = now;
    post('position', { currentTime: e.currentTime, endTime: e.endTime, currentTick: e.currentTick });
  });

  api.playedBeatChanged.on((beat) => {
    post('bar', { barIndex: beat.voice.bar.index });
  });

  api.playbackRangeChanged?.on((e) => post('selection', { hasSelection: !!e.playbackRange }));

  // Selección de compases: tocar inicio y fin, o arrastrar de un compás a otro
  api.beatMouseDown.on((beat) => {
    if (state.barSelectMode) state.downBar = beat.voice.bar.index;
  });
  api.beatMouseUp.on((beat) => {
    if (!state.barSelectMode || state.downBar == null) return;
    const down = state.downBar;
    const up = beat ? beat.voice.bar.index : down;
    state.downBar = null;
    // Después de que alphaTab aplique su propia selección, ponemos la nuestra (compases enteros)
    setTimeout(() => {
      if (down !== up) {
        state.barAnchor = null;
        selectBars(Math.min(down, up), Math.max(down, up));
      } else if (state.barAnchor == null) {
        state.barAnchor = up;
        selectBars(up, up);
      } else {
        const a = state.barAnchor;
        state.barAnchor = null;
        selectBars(Math.min(a, up), Math.max(a, up));
      }
    }, 0);
  });

  api.error.on((e) => post('error', { message: String(e?.message || e) }));
  return api;
}

// Cambia sintetizador <-> YouTube sin destruir alphaTab: se conserva la partitura,
// el scroll y la posición; alphaTab solo sustituye el reproductor interno.
function switchPlayerMode(mode) {
  const api = state.api;
  if (!api) return createApi();
  state.switching = true;
  state.wantPlaying = false;
  try { api.pause(); } catch {}
  // Al sustituir el reproductor se pierde el rango de reproducción: lo guardamos
  state.savedRange = api.playbackRange ? { ...api.playbackRange } : null;
  state.resumeTick = api.score ? api.tickPosition : null;
  api.settings.player.playerMode = mode === 'youtube'
    ? alphaTab.PlayerMode.EnabledExternalMedia
    : alphaTab.PlayerMode.EnabledSynthesizer;
  api.updateSettings();
}

// ---------- selección de compases ----------
function firstBeat(bar) {
  for (const v of bar.voices) if (v.beats.length) return v.beats[0];
  return null;
}
function lastBeat(bar) {
  for (const v of bar.voices) if (v.beats.length) return v.beats[v.beats.length - 1];
  return null;
}

function selectBars(start, end) {
  const api = state.api;
  const staff = api?.tracks?.[0]?.staves?.[0];
  if (!staff) return;
  const count = staff.bars.length;
  start = Math.max(0, Math.min(start, count - 1));
  end = Math.max(start, Math.min(end, count - 1));
  const b0 = firstBeat(staff.bars[start]);
  const b1 = lastBeat(staff.bars[end]);
  if (!b0 || !b1) return;
  api.highlightPlaybackRange(b0, b1);
  api.applyPlaybackRangeFromHighlight();
  state.barSel = { start, end };
  // El cursor salta al inicio del bucle si estaba fuera
  const range = api.playbackRange;
  if (range && (api.tickPosition < range.startTick || api.tickPosition > range.endTick)) {
    api.tickPosition = range.startTick;
  }
  post('barSelection', { start, end, waitingForEnd: state.barAnchor != null });
}

// ---------- mover compases a otra cuerda ----------
// alphaTab numera las cuerdas desde la más grave (1 = 6ª de la guitarra).
// delta +1 = hacia el agudo (p. ej. de la 6ª a la 5ª), −1 = hacia el grave.
// El traste se recalcula para que cada nota suene exactamente igual.
const MAX_FRET = 24;

function stringPitch(staff, string) {
  const t = staff.stringTuning.tunings; // de aguda a grave
  return t[t.length - string];
}

// op: { tracks: [índices], start, end, delta }.
// Mueve las notas que caben; las que no (cuerda del borde, traste negativo o mayor que 24,
// armónico natural, o cuerda destino ocupada por una nota que se queda) se dejan donde están.
// Es determinista: aplicar la misma op al mismo estado da siempre el mismo resultado.
function moveStrings(score, op) {
  let moved = 0;
  let skipped = 0;
  const skippedBars = new Set();
  for (const ti of op.tracks) {
    const track = score.tracks[ti];
    if (!track) continue;
    for (const staff of track.staves) {
      const count = staff.stringTuning?.tunings?.length ?? 0;
      if (staff.isPercussion || count === 0) continue;
      for (let b = op.start; b <= op.end && b < staff.bars.length; b++) {
        for (const voice of staff.bars[b].voices) {
          for (const beat of voice.beats) {
            const notes = beat.notes.filter((n) => !n.isPercussion);
            if (!notes.length) continue;
            // 1. Destino de cada nota, o null si no puede moverse
            const plan = new Map();
            for (const note of notes) {
              const target = note.string + op.delta;
              const fret = target >= 1 && target <= count
                ? note.fret + stringPitch(staff, note.string) - stringPitch(staff, target)
                : -1;
              const ok = fret >= 0 && fret <= MAX_FRET && note.harmonicType !== alphaTab.model.HarmonicType.Natural;
              plan.set(note, ok ? { string: target, fret } : null);
            }
            // 2. Si una nota que se queda ocupa la cuerda destino de otra, esa también se queda
            let changed = true;
            while (changed) {
              changed = false;
              const occupied = new Set(notes.filter((n) => plan.get(n) === null).map((n) => n.string));
              for (const note of notes) {
                const p = plan.get(note);
                if (p && occupied.has(p.string)) { plan.set(note, null); changed = true; }
              }
            }
            // 3. Aplicar
            for (const note of notes) {
              const p = plan.get(note);
              if (p) { note.string = p.string; note.fret = p.fret; moved++; }
              else { skipped++; skippedBars.add(b + 1); }
            }
          }
        }
      }
    }
  }
  return { moved, skipped, skippedBars: [...skippedBars] };
}

function ordinal(n) {
  return n + (n === 1 ? 'st' : n === 2 ? 'nd' : n === 3 ? 'rd' : 'th');
}

// Vuelve a dibujar y a generar el audio tras editar, manteniendo selección y posición
function refreshAfterEdit() {
  const api = state.api;
  const sel = state.barSel;
  const tick = api.tickPosition;
  const off = api.renderFinished.on(() => {
    off();
    if (sel) selectBars(sel.start, sel.end);
    api.tickPosition = tick;
  });
  api.render();
  api.loadMidiForScore();
}

function clearBarSelection() {
  const api = state.api;
  state.barSel = null;
  state.barAnchor = null;
  if (api) {
    api.playbackRange = null;
    api.clearPlaybackRangeHighlight?.();
  }
  post('barSelection', { start: null, end: null });
}

// ---------- audio del sintetizador ----------
// En WKWebView el AudioContext puede quedar "suspended" o "interrupted" (p. ej. después de
// sonar el vídeo de YouTube). Los botones nativos no cuentan como gesto dentro de la web,
// así que lo reanudamos nosotros y, si WebKit no deja, avisamos para que el usuario toque la tab.
function audioContext() {
  const p = state.api?.player;
  return p?.instance?.output?.context || p?.output?.context || null;
}

async function ensureAudioRunning() {
  if (state.mode !== 'synth') return true;
  const ctx = audioContext();
  if (!ctx) return true; // aún no creado: alphaTab lo crea al reproducir
  if (ctx.state === 'running') return true;
  try { await Promise.race([ctx.resume(), new Promise((r) => setTimeout(r, 800))]); } catch {}
  return ctx.state === 'running';
}

function hookAudioContext() {
  const ctx = audioContext();
  if (!ctx || ctx.__fretlineHooked) return;
  ctx.__fretlineHooked = true;
  ctx.addEventListener('statechange', () => {
    console.log('[fretline] AudioContext ->', ctx.state);
    if (ctx.state !== 'running' && state.wantPlaying && state.mode === 'synth') recoverPlayback('audio ' + ctx.state);
  });
}

// ---------- latencia y arranque ----------
const WARM_UP_MS = 350;     // tiempo de silencio para despertar la salida de audio
const WARM_IDLE_MS = 4000;  // si llevaba más que esto sin sonar, se calienta antes de tocar

// Latencia de salida que informa el navegador (altavoz, Bluetooth…)
function autoLatency() {
  const ctx = audioContext();
  if (!ctx) return 0;
  return Math.round(((ctx.outputLatency || 0) + (ctx.baseLatency || 0)) * 1000);
}
function latency() {
  return state.latencyMs != null ? state.latencyMs : (state.mode === 'synth' ? autoLatency() : 0);
}

function warmUpOutput(ms) {
  const ctx = audioContext();
  if (!ctx || ctx.state !== 'running') return Promise.resolve();
  return new Promise((resolve) => {
    try {
      // Ruido a −100 dB: inaudible, pero cuenta como sonido y despierta la salida
      const buffer = ctx.createBuffer(1, Math.ceil(ctx.sampleRate * ms / 1000), ctx.sampleRate);
      const data = buffer.getChannelData(0);
      for (let i = 0; i < data.length; i++) data[i] = (Math.random() * 2 - 1) * 1e-5;
      const src = ctx.createBufferSource();
      src.buffer = buffer;
      src.connect(ctx.destination);
      src.onended = () => { try { src.disconnect(); } catch {} resolve(); };
      src.start();
    } catch {
      resolve();
    }
  });
}

// El cursor del sintetizador avanza con las muestras entregadas a la salida, no con las
// que ya se oyen. Retrasamos ese aviso lo que tarda el sonido en llegar al altavoz.
function patchSynthOutput() {
  const out = state.api?.player?.instance?.output || state.api?.player?.output;
  if (!out || out.__fretlinePatched || typeof out.onSamplesPlayed !== 'function') return;
  out.__fretlinePatched = true;
  let epoch = 0;
  const original = out.onSamplesPlayed.bind(out);
  out.onSamplesPlayed = (samples) => {
    if (state.mode === 'synth') state.lastAudioActivity = Date.now();
    const delay = state.mode === 'synth' ? latency() : 0;
    if (delay <= 0) return original(samples);
    const myEpoch = epoch;
    setTimeout(() => { if (myEpoch === epoch) original(samples); }, delay);
  };
  // Al buscar o parar, se descartan los avisos pendientes de la posición anterior
  for (const name of ['resetSamples', 'pause']) {
    if (typeof out[name] !== 'function') continue;
    const fn = out[name].bind(out);
    out[name] = (...args) => { epoch++; return fn(...args); };
  }
}

let recovering = false;
async function recoverPlayback(reason) {
  if (recovering || !state.wantPlaying || state.mode !== 'synth') return;
  recovering = true;
  console.log('[fretline] resuming audio:', reason);
  try {
    const ok = await ensureAudioRunning();
    const api = state.api;
    if (!state.wantPlaying || !api) return;
    if (ok) {
      if (api.playerState !== alphaTab.synth.PlayerState.Playing) api.play();
    } else {
      state.pendingPlay = true;
      post('audioBlocked', { state: audioContext()?.state || 'unknown' });
    }
  } finally {
    recovering = false;
  }
}

// Vigilante: si "está sonando" pero la posición no avanza, el audio está parado por debajo
let lastWatchTime = -1;
let stuckTicks = 0;
setInterval(() => {
  const api = state.api;
  if (!api || !state.wantPlaying || state.mode !== 'synth' || state.switching) { stuckTicks = 0; return; }
  hookAudioContext();
  const t = api.timePosition;
  if (api.playerState === alphaTab.synth.PlayerState.Playing && t === lastWatchTime) {
    if (++stuckTicks >= 2) { stuckTicks = 0; recoverPlayback('position stuck'); }
  } else {
    stuckTicks = 0;
  }
  lastWatchTime = t;
}, 1000);

async function playChecked() {
  const api = state.api;
  if (!api) return;
  state.wantPlaying = true;
  const ok = await ensureAudioRunning();
  hookAudioContext();
  patchSynthOutput();
  // Si la salida llevaba un rato parada, iOS tarda en ponerla en marcha y se comería
  // las primeras notas mientras el cursor ya avanza: la «calentamos» en silencio antes.
  if (ok && state.mode === 'synth' && Date.now() - state.lastAudioActivity > WARM_IDLE_MS) {
    await warmUpOutput(WARM_UP_MS);
    if (!state.wantPlaying) return; // se pausó mientras calentaba
  }
  state.lastAudioActivity = Date.now();
  api.play();
  if (!ok) {
    state.pendingPlay = true;
    post('audioBlocked', { state: audioContext()?.state || 'unknown' });
  }
}

// Cualquier toque en la partitura es un gesto real: reanuda el audio y, si había un play pendiente, arranca
['touchend', 'pointerup', 'click'].forEach((type) =>
  document.addEventListener(type, () => {
    const ctx = audioContext();
    if (!ctx || (ctx.state === 'running' && !state.pendingPlay)) return;
    ctx.resume().catch(() => {}).finally(() => {
      if (ctx.state !== 'running') return;
      post('audioUnblocked');
      if (state.pendingPlay) {
        state.pendingPlay = false;
        const api = state.api;
        if (api && api.playerState !== alphaTab.synth.PlayerState.Playing) api.play();
      }
    });
  }, { passive: true, capture: true }));

// ---------- YouTube / medio externo ----------
// alphaTab nos pide play/pausa/seek/velocidad; nosotros lo reenviamos a Swift,
// que controla el reproductor de YouTube. Swift nos devuelve el tiempo del vídeo.
function attachExternalHandler() {
  const output = state.api.player?.output;
  if (!output) return post('error', { message: 'External media output not available' });
  output.handler = {
    get backingTrackDuration() { return state.videoDuration || 0; },
    get playbackRate() { return state.speed; },
    set playbackRate(v) { post('externalRate', { rate: v }); },
    get masterVolume() { return 1; },
    set masterVolume(_v) {},
    seekTo(ms) { state.holdUntil = null; post('externalSeek', { ms }); },
    play() { post('externalPlay'); },
    pause() { state.holdUntil = null; post('externalPause'); },
  };
}

function applySyncPointsToScore(score) {
  if (!score) return;
  for (const mb of score.masterBars) mb.syncPoints = undefined;
  if (state.syncPoints.length) score.applyFlatSyncPoints(state.syncPoints);
}

function refreshSync() {
  const api = state.api;
  if (!api?.score) return;
  applySyncPointsToScore(api.score);
  api.updateSyncPoints?.();
  // Mientras se edita, los sync points (desplazados por compases nuevos/borrados) se guardan con Keep
  if (!editor?.enabled) post('syncPoints', { points: state.syncPoints });
}

// ---------- utilidades ----------
function tracksByIndex(indices) {
  const all = state.api?.score?.tracks || [];
  return indices.map((i) => all[i]).filter(Boolean);
}

function b64ToBytes(b64) {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
function bytesToB64(bytes) {
  let s = '';
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) s += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
  return btoa(s);
}

// ---------- API pública para Swift ----------
window.fretline = {
  // Para depurar desde la consola de Safari: fretline.debug().api / .ctx
  debug() { return { api: state.api, ctx: audioContext(), state }; },

  // song: { url, syncPoints?: FlatSyncPoint[], mode?: 'synth'|'youtube' }
  loadSong(song) {
    state.songUrl = song.url;
    state.syncPoints = song.syncPoints || [];
    state.edits = song.edits || [];
    state.visibleTracks = null;
    const mode = song.mode || 'synth';
    if (!state.api || mode !== state.mode) {
      state.mode = mode;
      createApi();
    }
    state.api.load(song.url);
  },

  setMode(mode) {
    if (mode === state.mode) return;
    state.mode = mode;
    state.pendingPlay = false;
    switchPlayerMode(mode);
  },

  play() { playChecked(); },
  pause() { state.wantPlaying = false; state.pendingPlay = false; state.holdUntil = null; state.api?.pause(); },
  playPause() {
    const api = state.api;
    if (!api) return;
    if (api.playerState === alphaTab.synth.PlayerState.Playing) this.pause();
    else playChecked();
  },
  stop() { state.wantPlaying = false; state.pendingPlay = false; state.api?.stop(); },

  setSpeed(v) {
    state.speed = v;
    if (state.api) state.api.playbackSpeed = v;
  },
  setLooping(on) {
    state.looping = on;
    if (state.api) state.api.isLooping = on;
  },
  clearSelection() { clearBarSelection(); },

  // --- Compases en bucle ---
  setBarSelectMode(on) {
    state.barSelectMode = on;
    state.barAnchor = null;
    state.downBar = null;
  },
  selectBars(start, end) { state.barAnchor = null; selectBars(start, end); },
  // edge: 'start' | 'end'; delta: +1 / -1
  adjustBarSelection(edge, delta) {
    const sel = state.barSel;
    if (!sel) return;
    state.barAnchor = null;
    let { start, end } = sel;
    if (edge === 'start') start = Math.min(end, start + delta);
    else end = Math.max(start, end + delta);
    selectBars(start, end);
  },
  // Mueve todo el bucle (p. ej. al siguiente grupo de compases)
  // Mueve los compases seleccionados de las pistas visibles a la cuerda vecina
  moveSelectionToString(delta) {
    const api = state.api;
    const sel = state.barSel;
    if (!api?.score || !sel) return post('notice', { message: 'Select one or more bars first.' });
    const op = { tracks: api.tracks.map((t) => t.index), start: sel.start, end: sel.end, delta };
    if (editor?.enabled) {
      // En modo edición es un cambio más del editor (con su deshacer), no una edición aparte
      let result = null;
      editor.commit((score) => { result = moveStrings(score, op); return result.moved > 0; });
      if (result && result.skipped) {
        post('notice', { message: result.moved
          ? `Moved ${result.moved} notes. ${result.skipped} didn’t fit on the new string and stayed where they were.`
          : `No notes fit on the ${delta > 0 ? 'higher' : 'lower'} string here, so they stayed where they were.` });
      }
      return;
    }
    const result = moveStrings(api.score, op);
    if (result.moved === 0) {
      // No es un error: las notas que no caben se quedan como están (aquí, todas)
      return post('notice', { message: result.skipped
        ? `No notes fit on the ${op.delta > 0 ? 'higher' : 'lower'} string here, so they stayed where they were.`
        : 'There are no notes to move in the selected bars.' });
    }
    state.edits.push(op);
    refreshAfterEdit();
    post('edited', { op, moved: result.moved, skipped: result.skipped, skippedBars: result.skippedBars });
  },
  // Deshacer: recarga la canción y vuelve a aplicar las ediciones que quedan.
  // Es exacto aunque el último cambio fuera parcial (algunas notas se quedaron en su sitio).
  reloadWithEdits(edits) {
    const api = state.api;
    if (!api || !state.songUrl) return;
    state.edits = edits || [];
    const sel = state.barSel;
    const tick = api.tickPosition;
    const off = api.renderFinished.on(() => {
      off();
      if (sel) selectBars(sel.start, sel.end);
      api.tickPosition = tick;
    });
    api.load(state.songUrl);
  },

  shiftBarSelection(delta) {
    const sel = state.barSel;
    if (!sel) return;
    const len = sel.end - sel.start;
    const count = state.api?.tracks?.[0]?.staves?.[0]?.bars.length ?? 0;
    let start = Math.max(0, Math.min(sel.start + delta * (len + 1), count - 1 - len));
    selectBars(start, start + len);
  },
  setMetronome(on) {
    state.metronome = on ? 1 : 0;
    if (state.api && state.mode === 'synth') state.api.metronomeVolume = state.metronome;
  },
  setCountIn(on) {
    state.countIn = on;
    if (state.api && state.mode === 'synth') state.api.countInVolume = on ? 1 : 0;
  },

  showTracks(indices) {
    state.visibleTracks = indices;
    const tracks = tracksByIndex(indices);
    if (!tracks.length) return;
    state.api.renderTracks(tracks);
    const sel = state.barSel;
    if (sel) {
      const off = state.api.renderFinished.on(() => { off(); selectBars(sel.start, sel.end); });
    }
  },
  setMute(index, on) { state.api?.changeTrackMute(tracksByIndex([index]), on); },
  setSolo(index, on) { state.api?.changeTrackSolo(tracksByIndex([index]), on); },
  setVolume(index, v) { state.api?.changeTrackVolume(tracksByIndex([index]), v); },

  setLayout(layout) {
    state.layout = layout;
    const api = state.api;
    if (!api) return;
    api.settings.display.layoutMode = layout === 'horizontal' ? alphaTab.LayoutMode.Horizontal : alphaTab.LayoutMode.Page;
    api.updateSettings();
    api.render();
  },
  setScale(scale) {
    state.scale = scale;
    const api = state.api;
    if (!api) return;
    api.settings.display.scale = scale;
    api.updateSettings();
    api.render();
  },

  // --- YouTube: Swift -> JS ---
  externalTime(ms) {
    if (state.mode !== 'youtube') return;
    const adjusted = Math.max(0, ms - latency());
    // Pre-roll: el vídeo arranca un poco antes y el cursor espera hasta el punto de inicio
    if (state.holdUntil != null) {
      if (adjusted < state.holdUntil) return;
      state.holdUntil = null;
    }
    const out = state.api?.player?.output;
    out?.updatePosition?.(adjusted);
  },
  // Swift avisa de que el vídeo arranca antes de `ms` para que suene ya al llegar al cursor
  holdExternal(ms) { state.holdUntil = ms; },
  // null = automática
  setLatency(ms) { state.latencyMs = ms == null || ms < 0 ? null : ms; },
  latencyInfo() { return { autoMs: autoLatency(), effectiveMs: latency() }; },
  externalDuration(ms) { state.videoDuration = ms; },
  // Cuando el usuario toca play/pausa directamente en el vídeo
  externalState(playing) {
    const api = state.api;
    if (!api || state.mode !== 'youtube') return;
    const isPlaying = api.playerState === alphaTab.synth.PlayerState.Playing;
    if (playing && !isPlaying) api.play();
    if (!playing && isPlaying) api.pause();
  },

  // --- Sincronización ---
  setSyncPoints(points) {
    state.syncPoints = points || [];
    refreshSync();
  },
  clearSync() {
    state.syncPoints = [];
    refreshSync();
  },
  // Modo rápido: el compás 1 empieza en `ms`, el resto lo calcula alphaTab con el tempo
  quickSync(ms) {
    state.syncPoints = [{ barIndex: 0, barPosition: 0, barOccurence: 0, millisecondOffset: Math.round(ms) }];
    refreshSync();
  },
  // Tap-along: cada toque marca el inicio del siguiente compás en orden de reproducción
  markNextBar(ms) {
    const score = state.api?.score;
    if (!score) return;
    const order = playOrder(score);
    const k = state.syncPoints.length;
    if (k >= order.length) return post('syncMarkDone', { total: order.length });
    const barIndex = order[k];
    const barOccurence = order.slice(0, k).filter((b) => b === barIndex).length;
    state.syncPoints.push({ barIndex, barPosition: 0, barOccurence, millisecondOffset: Math.round(ms) });
    refreshSync();
    post('syncMarked', { count: state.syncPoints.length, total: order.length, nextBar: order[k + 1] ?? null });
  },
  undoLastMark() {
    state.syncPoints.pop();
    refreshSync();
  },
  // Ajuste fino: desplaza todos los puntos (p. ej. +/- 50 ms)
  nudgeSync(deltaMs) {
    state.syncPoints = state.syncPoints.map((p) => ({ ...p, millisecondOffset: Math.max(0, p.millisecondOffset + deltaMs) }));
    refreshSync();
  },

  // --- Songsterr: Swift descarga el JSON (sin CORS) y aquí lo convertimos a .gp ---
  // payload: { requestId, meta: {title, artist}, parts: [...], videos?: [{videoId, points, feature}] }
  convertSongsterr(payload) {
    try {
      const score = buildScore(alphaTab, payload.meta || {}, payload.parts || []);
      const video = chooseVideo(score, payload.videos);
      const sync = video ? videoPointsToSync(score, video.points) : [];
      const bytes = new alphaTab.exporter.Gp7Exporter().export(score, new alphaTab.Settings());
      post('songsterrConverted', {
        requestId: payload.requestId,
        gpBase64: bytesToB64(bytes),
        title: score.title,
        artist: score.artist,
        videoId: video?.videoId ?? null,
        syncPoints: sync,
      });
    } catch (e) {
      post('songsterrConverted', { requestId: payload.requestId, error: String(e?.message || e) });
    }
  },

  // Carga directa desde bytes en base64 (por si un archivo no se puede servir por URL)
  loadBase64(b64, syncPoints) {
    state.songUrl = null;
    state.syncPoints = syncPoints || [];
    if (!state.api) createApi();
    state.api.load(b64ToBytes(b64));
  },
};

// En el Mac (sin pantalla táctil) la partitura suele tener el foco del teclado y se
// comería la barra espaciadora: la mandamos a Swift, que decide (play/pausa o marcar compás).
if (navigator.maxTouchPoints === 0) {
  document.addEventListener('keydown', (e) => {
    if (e.code !== 'Space' || e.metaKey || e.ctrlKey || e.altKey) return;
    e.preventDefault();
    if (!e.repeat) post('key', { key: 'space' });
  });
}

// ---------- editor ----------
const editor = new Editor({
  alphaTab,
  getApi: () => state.api,
  post,
  el,
  scroller,
  onRebuild(score) {
    const api = state.api;
    const tick = api.tickPosition;
    const sel = state.barSel;
    const tracks = api.tracks.map((t) => t.index);
    state.rebuilding = true;
    const off = api.renderFinished.on(() => {
      off();
      if (sel && sel.end < score.masterBars.length) selectBars(sel.start, sel.end);
      api.tickPosition = tick;
      editor.updateCursor();
    });
    api.renderScore(score, tracks);
  },
});

// Compases insertados o borrados: los sync points posteriores se desplazan
function shiftSyncPoints(change) {
  if (!change || !state.syncPoints.length) return;
  const { kind, at, count } = change;
  state.syncPoints = state.syncPoints
    .filter((p) => kind !== 'delete' || p.barIndex < at || p.barIndex >= at + count)
    .map((p) => (p.barIndex >= at ? { ...p, barIndex: p.barIndex + (kind === 'insert' ? count : -count) } : p));
  refreshSync();
}

function bytesToBase64(bytes) { return bytesToB64(bytes); }

window.fretline.editor = {
  setEnabled: (on) => editor.setEnabled(on),
  moveBeat: (d) => editor.moveBeat(d),
  moveBar: (d) => editor.moveBar(d),
  moveString: (d) => editor.moveString(d),
  typeDigit: (n) => editor.typeDigit(n),
  setFret: (f) => editor.setFret(f),
  fretStep: (d) => editor.fretStep(d),
  deleteNote: () => editor.deleteNote(),
  setDuration: (d) => editor.setDuration(d),
  durationStep: (d) => editor.durationStep(d),
  toggleDot: () => editor.toggleDot(),
  toggleTriplet: () => editor.toggleTriplet(),
  toggleTechnique: (name) => editor.toggleTechnique(name),
  insertBeat: () => editor.insertBeat(),
  deleteBeat: () => editor.deleteBeat(),
  insertBar: () => shiftSyncPoints(editor.insertBar()),
  duplicateBars: () => shiftSyncPoints(editor.duplicateBars(state.barSel)),
  deleteBars: () => {
    const change = editor.deleteBars(state.barSel);
    if (change) { clearBarSelection(); shiftSyncPoints(change); }
  },
  undo: () => editor.undo(),
  redo: () => editor.redo(),
  // Keep: exporta a Guitar Pro 7 para que Swift lo guarde (con los sync points ya desplazados)
  export(requestId) {
    try {
      post('editorExported', { requestId, gpBase64: bytesToBase64(editor.exportGp()), syncPoints: state.syncPoints });
    } catch (e) {
      post('editorExported', { requestId, error: String(e?.message || e) });
    }
  },
  // Swift confirma que se guardó: los cambios de cuerda ya van dentro del archivo
  saved() {
    editor.dirty = false;
    state.edits = [];
    editor.postState();
  },
  // Tab nueva vacía → bytes GP7 para que Swift la añada a la biblioteca
  createScore(payload) {
    try {
      post('newTabCreated', { requestId: payload.requestId, gpBase64: bytesToBase64(editor.createScore(payload)) });
    } catch (e) {
      post('newTabCreated', { requestId: payload.requestId, error: String(e?.message || e) });
    }
  },
  tunings: () => Object.entries(TUNINGS).map(([id, t]) => ({ id, name: t.name, strings: t.tuning.length })),
};

createApi();
post('ready');
