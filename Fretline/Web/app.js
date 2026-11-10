// Capa web de Fretline: alphaTab + puente con Swift.
// Swift -> JS: window.fretline.<comando>(...)
// JS -> Swift: window.webkit.messageHandlers.fretline.postMessage({ type, ... })

import * as alphaTab from './vendor/alphatab/alphaTab.min.mjs';
import { buildScore, videoPointsToSync, playOrder, chooseVideo } from './songsterr/convert.js';

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
  api.renderFinished.on(() => loading.classList.remove('on'));

  api.playerReady.on(() => {
    api.playbackSpeed = state.speed;
    api.isLooping = state.looping;
    api.metronomeVolume = state.metronome;
    api.countInVolume = state.countIn ? 1 : 0;
    if (state.mode === 'youtube') attachExternalHandler();
    post('playerReady', { mode: state.mode });
  });

  api.playerStateChanged.on((e) => post('playerState', { playing: e.state === alphaTab.synth.PlayerState.Playing }));

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

  api.error.on((e) => post('error', { message: String(e?.message || e) }));
  return api;
}

function reloadCurrent() {
  createApi();
  if (state.songUrl) state.api.load(state.songUrl);
}

// ---------- YouTube / medio externo ----------
// alphaTab nos pide play/pausa/seek/velocidad; nosotros lo reenviamos a Swift,
// que controla el reproductor de YouTube. Swift nos devuelve el tiempo del vídeo.
function attachExternalHandler() {
  const output = state.api.player?.output;
  if (!output) return post('error', { message: 'Salida de medio externo no disponible' });
  output.handler = {
    get backingTrackDuration() { return state.videoDuration || 0; },
    get playbackRate() { return state.speed; },
    set playbackRate(v) { post('externalRate', { rate: v }); },
    get masterVolume() { return 1; },
    set masterVolume(_v) {},
    seekTo(ms) { post('externalSeek', { ms }); },
    play() { post('externalPlay'); },
    pause() { post('externalPause'); },
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
  post('syncPoints', { points: state.syncPoints });
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
  // song: { url, syncPoints?: FlatSyncPoint[], mode?: 'synth'|'youtube' }
  loadSong(song) {
    state.songUrl = song.url;
    state.syncPoints = song.syncPoints || [];
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
    reloadCurrent();
  },

  play() { state.api?.play(); },
  pause() { state.api?.pause(); },
  playPause() { state.api?.playPause(); },
  stop() { state.api?.stop(); },

  setSpeed(v) {
    state.speed = v;
    if (state.api) state.api.playbackSpeed = v;
  },
  setLooping(on) {
    state.looping = on;
    if (state.api) state.api.isLooping = on;
  },
  clearSelection() {
    if (state.api) {
      state.api.playbackRange = null;
      state.api.clearPlaybackRangeHighlight?.();
    }
  },
  setMetronome(on) {
    state.metronome = on ? 1 : 0;
    if (state.api) state.api.metronomeVolume = state.metronome;
  },
  setCountIn(on) {
    state.countIn = on;
    if (state.api) state.api.countInVolume = on ? 1 : 0;
  },

  showTracks(indices) {
    state.visibleTracks = indices;
    const tracks = tracksByIndex(indices);
    if (tracks.length) state.api.renderTracks(tracks);
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
    const out = state.api?.player?.output;
    out?.updatePosition?.(ms);
  },
  externalDuration(ms) { state.videoDuration = ms; },
  // Cuando el usuario toca play/pausa directamente en el vídeo
  externalState(playing) {
    const api = state.api;
    if (!api) return;
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

createApi();
post('ready');
