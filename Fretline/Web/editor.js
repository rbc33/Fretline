// Editor de tablatura de Fretline.
//
// Cómo funciona:
// - Un cursor (pista, compás, tiempo, cuerda) que se mueve con el ratón/dedo, las flechas o los
//   botones del panel. Escribir un número pone ese traste en la cuerda del cursor.
// - Cada edición cambia el modelo de alphaTab y luego se reconstruye la partitura
//   (JSON de ida y vuelta: alphaTab vuelve a calcular ligaduras, hammer-ons, tiempos…).
// - Deshacer/rehacer guarda la partitura entera en JSON antes de cada edición (≈ms).
// - Al guardar se exporta a Guitar Pro 7; el archivo original nunca se toca.

const NOTE_REFS = ['bendOrigin', 'hammerPullOrigin', 'hammerPullDestination', 'slurOrigin', 'slurDestination',
  'letRingDestination', 'palmMuteDestination', 'slideTarget', 'slideOrigin', 'tieOrigin', 'tieDestination',
  'effectSlurOrigin', 'effectSlurDestination'];
const SKIP_PROPS = new Set(['id', 'index', 'voice', 'beat', 'notes', 'previousBeat', 'nextBeat', 'minNote', 'maxNote',
  'maxStringNote', 'minStringNote', 'effectSlurOrigin', 'effectSlurDestination', ...NOTE_REFS]);
const DURATIONS = [1, 2, 4, 8, 16, 32];
const MAX_FRET = 24;
const MAX_UNDO = 100;
const TAB_LINE_SPACING = 13; // separación entre líneas de tab a escala 1 (medido en alphaTab 1.9)

export const TUNINGS = {
  'guitar-standard': { name: 'Guitar · Standard (E A D G B E)', tuning: [64, 59, 55, 50, 45, 40], program: 25 },
  'guitar-dropd': { name: 'Guitar · Drop D (D A D G B E)', tuning: [64, 59, 55, 50, 45, 38], program: 25 },
  'guitar-halfdown': { name: 'Guitar · Half step down (Eb)', tuning: [63, 58, 54, 49, 44, 39], program: 25 },
  'guitar-dadgad': { name: 'Guitar · DADGAD', tuning: [62, 57, 55, 50, 45, 38], program: 25 },
  'guitar-7': { name: '7-string guitar (B E A D G B E)', tuning: [64, 59, 55, 50, 45, 40, 35], program: 29 },
  'bass-4': { name: 'Bass · 4 strings (E A D G)', tuning: [43, 38, 33, 28], program: 33 },
  'bass-5': { name: 'Bass · 5 strings (B E A D G)', tuning: [43, 38, 33, 28, 23], program: 33 },
};

export class Editor {
  constructor({ alphaTab, getApi, post, el, scroller, onRebuild }) {
    this.at = alphaTab;
    this.m = alphaTab.model;
    this.getApi = getApi;
    this.post = post;
    this.el = el;
    this.scroller = scroller;
    this.onRebuild = onRebuild; // (score) => cargar la partitura reconstruida en alphaTab
    this.enabled = false;
    this.cursor = { track: 0, bar: 0, beat: 0, string: 1 };
    this.undoStack = [];
    this.redoStack = [];
    this.dirty = false;
    this.digitBuffer = null; // { value, at } para escribir trastes de dos cifras (1 → 12)

    this.cursorEl = document.createElement('div');
    this.cursorEl.id = 'edit-cursor';
    this.cursorEl.hidden = true;
    scroller.appendChild(this.cursorEl);

    el.addEventListener('pointerdown', (e) => this._onPointer(e), true);
    document.addEventListener('keydown', (e) => this._onKey(e));
  }

  // ---------- estado ----------
  get score() { return this.getApi()?.score ?? null; }

  setEnabled(on) {
    this.enabled = on;
    this.digitBuffer = null;
    if (on) {
      const api = this.getApi();
      const first = api?.tracks?.find((t) => this._tabStaff(t));
      if (first) this.cursor.track = first.index;
      this.cursor.string = Math.min(this.cursor.string, this._stringCount() || 1);
      this._clampCursor();
    }
    this.updateCursor();
    this.postState();
  }

  /// Llamado cuando se carga una partitura nueva que NO viene del editor (abrir, descartar…)
  resetHistory() {
    this.undoStack = [];
    this.redoStack = [];
    this.dirty = false;
    // Si se activó antes de cargar la partitura (tab nueva), elegimos ahora la pista editable
    if (!this._staff()) {
      const first = this.getApi()?.tracks?.find((t) => this._tabStaff(t)) ?? this.score?.tracks?.find((t) => this._tabStaff(t));
      if (first) this.cursor.track = first.index;
    }
    this._clampCursor();
    this.postState();
  }

  _tabStaff(track) {
    return track?.staves?.find((s) => !s.isPercussion && (s.stringTuning?.tunings?.length ?? 0) > 0) ?? null;
  }
  _staff() { return this._tabStaff(this.score?.tracks?.[this.cursor.track]); }
  _stringCount() { return this._staff()?.stringTuning.tunings.length ?? 0; }
  _bar() { return this._staff()?.bars?.[this.cursor.bar] ?? null; }
  _voice() { return this._bar()?.voices?.[0] ?? null; }
  _beat() { return this._voice()?.beats?.[this.cursor.beat] ?? null; }
  _note() { return this._beat()?.notes?.find((n) => n.string === this.cursor.string) ?? null; }

  _clampCursor() {
    const staff = this._staff();
    if (!staff) return;
    this.cursor.bar = Math.max(0, Math.min(this.cursor.bar, staff.bars.length - 1));
    const beats = this._voice()?.beats.length ?? 1;
    this.cursor.beat = Math.max(0, Math.min(this.cursor.beat, beats - 1));
    this.cursor.string = Math.max(1, Math.min(this.cursor.string, this._stringCount()));
  }

  postState() {
    const beat = this._beat();
    const note = this._note();
    const count = this._stringCount();
    const D = this.m;
    this.post('editorState', {
      enabled: this.enabled,
      editable: !!this._staff(),
      bar: this.cursor.bar,
      beat: this.cursor.beat,
      beatCount: this._voice()?.beats.length ?? 0,
      barCount: this._staff()?.bars.length ?? 0,
      // numeración de guitarrista: 1 = la más aguda
      string: count ? count - this.cursor.string + 1 : 0,
      stringCount: count,
      fret: note ? note.fret : null,
      duration: beat?.duration ?? 4,
      dotted: (beat?.dots ?? 0) > 0,
      triplet: beat?.tupletNumerator === 3,
      isRest: beat ? beat.notes.length === 0 : true,
      techniques: note ? {
        hammer: !!note.isHammerPullOrigin,
        slide: note.slideOutType !== D.SlideOutType.None,
        bend: note.bendType !== D.BendType.None,
        palmMute: !!note.isPalmMute,
        letRing: !!note.isLetRing,
        vibrato: note.vibrato !== D.VibratoType.None,
        dead: !!note.isDead,
      } : null,
      dirty: this.dirty,
      canUndo: this.undoStack.length > 0,
      canRedo: this.redoStack.length > 0,
    });
  }

  // ---------- cursor en pantalla ----------
  _lineGeometry(barBounds, count) {
    // Línea de cada cuerda: se calibra con las notas dibujadas en el mismo sistema si las hay
    const scale = this.getApi()?.settings?.display?.scale ?? 1;
    let spacing = TAB_LINE_SPACING * scale;
    const mbb = barBounds.masterBarBounds;
    const staffIndex = mbb?.bars?.indexOf(barBounds) ?? 0;
    const samples = [];
    for (const other of mbb?.staffSystemBounds?.bars ?? [mbb]) {
      for (const beatB of other?.bars?.[staffIndex]?.beats ?? []) {
        for (const nb of beatB.notes ?? []) {
          samples.push({ s: nb.note.string, y: nb.noteHeadBounds.y + nb.noteHeadBounds.h / 2 });
          if (samples.length > 20) break;
        }
      }
    }
    const distinct = samples.filter((p, i, a) => a.findIndex((q) => q.s === p.s) === i);
    if (distinct.length >= 2) {
      const [a, b] = distinct;
      spacing = Math.abs((a.y - b.y) / (a.s - b.s));
    }
    let topY; // y de la cuerda más aguda (alphaTab string = count)
    if (samples.length) {
      topY = samples[0].y - (count - samples[0].s) * spacing;
    } else {
      const r = barBounds.realBounds;
      topY = r.y + r.h - (count - 1) * spacing;
    }
    return { topY, spacing };
  }

  updateCursor() {
    const api = this.getApi();
    const beat = this._beat();
    const bb = beat && api?.boundsLookup?.findBeat(beat);
    if (!this.enabled || !bb) { this.cursorEl.hidden = true; return; }
    const count = this._stringCount();
    const { topY, spacing } = this._lineGeometry(bb.barBounds, count);
    const size = Math.max(16, spacing * 1.3);
    const cx = bb.onNotesX || (bb.visualBounds.x + bb.visualBounds.w / 2);
    const cy = topY + (count - this.cursor.string) * spacing;
    Object.assign(this.cursorEl.style, {
      left: `${this.el.offsetLeft + cx - size / 2}px`,
      top: `${this.el.offsetTop + cy - size / 2}px`,
      width: `${size}px`,
      height: `${size}px`,
    });
    this.cursorEl.hidden = false;
  }

  _onPointer(e) {
    if (!this.enabled) return;
    const api = this.getApi();
    const bl = api?.boundsLookup;
    if (!bl) return;
    const rect = this.el.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;
    const beat = bl.getBeatAtPos(x, y);
    if (!beat) return;
    const staff = beat.voice.bar.staff;
    if (!this._tabStaff(staff.track) || staff.isPercussion) return;
    const bb = bl.findBeat(beat);
    const count = staff.stringTuning.tunings.length;
    const { topY, spacing } = this._lineGeometry(bb.barBounds, count);
    const fromTop = Math.round((y - topY) / spacing);
    this.cursor = {
      track: staff.track.index,
      bar: beat.voice.bar.index,
      beat: beat.index,
      string: Math.max(1, Math.min(count, count - fromTop)),
    };
    this.digitBuffer = null;
    this.updateCursor();
    this.postState();
  }

  // ---------- movimiento ----------
  moveBeat(delta) {
    const staff = this._staff();
    if (!staff) return;
    let { bar, beat } = this.cursor;
    beat += delta;
    while (beat < 0 && bar > 0) { bar--; beat += staff.bars[bar].voices[0].beats.length; }
    while (bar < staff.bars.length && beat >= staff.bars[bar].voices[0].beats.length) {
      if (bar === staff.bars.length - 1) { beat = staff.bars[bar].voices[0].beats.length - 1; break; }
      beat -= staff.bars[bar].voices[0].beats.length;
      bar++;
    }
    this.cursor.bar = bar;
    this.cursor.beat = Math.max(0, beat);
    this.digitBuffer = null;
    this.updateCursor();
    this.postState();
  }

  moveBar(delta) {
    this.cursor.bar += delta;
    this.cursor.beat = 0;
    this._clampCursor();
    this.updateCursor();
    this.postState();
  }

  /// +1 = una cuerda hacia arriba en pantalla (más aguda)
  moveString(delta) {
    this.cursor.string += delta;
    this._clampCursor();
    this.digitBuffer = null;
    this.updateCursor();
    this.postState();
  }

  // ---------- ediciones ----------
  /// Ejecuta un cambio con deshacer: mutate(score) devuelve false si no hubo cambio
  commit(mutate) {
    const api = this.getApi();
    const score = this.score;
    if (!api || !score) return false;
    const snapshot = this.m.JsonConverter.scoreToJson(score);
    if (mutate(score) === false) return false;
    this._sanitize(score);
    const rebuilt = this.m.JsonConverter.jsonToScore(this.m.JsonConverter.scoreToJson(score), api.settings);
    this.undoStack.push(snapshot);
    if (this.undoStack.length > MAX_UNDO) this.undoStack.shift();
    this.redoStack = [];
    this.dirty = true;
    this._load(rebuilt);
    return true;
  }

  _load(score) {
    this.onRebuild(score);
    this._clampCursor();
    this.postState();
  }

  undo() {
    const api = this.getApi();
    if (!api || !this.undoStack.length) return;
    this.redoStack.push(this.m.JsonConverter.scoreToJson(this.score));
    this._load(this.m.JsonConverter.jsonToScore(this.undoStack.pop(), api.settings));
    this.dirty = true;
    this.postState();
  }

  redo() {
    const api = this.getApi();
    if (!api || !this.redoStack.length) return;
    this.undoStack.push(this.m.JsonConverter.scoreToJson(this.score));
    this._load(this.m.JsonConverter.jsonToScore(this.redoStack.pop(), api.settings));
    this.dirty = true;
    this.postState();
  }

  _sanitize(score) {
    // Referencias a notas que ya no existen (p. ej. tras borrar) romperían la reconstrucción
    const live = new Set();
    for (const t of score.tracks) for (const st of t.staves) for (const b of st.bars)
      for (const v of b.voices) for (const bt of v.beats) for (const n of bt.notes) live.add(n);
    for (const n of live) for (const k of NOTE_REFS) if (n[k] && !live.has(n[k])) n[k] = null;
  }

  _copyProps(dst, src) {
    for (const k of Object.keys(src)) {
      if (SKIP_PROPS.has(k)) continue;
      const v = src[k];
      if (v === null || typeof v !== 'object') dst[k] = v;
      else if (Array.isArray(v)) dst[k] = v.slice();
      else if (v instanceof Map) dst[k] = new Map(v);
      else if (!(v instanceof this.m.Note || v instanceof this.m.Beat || v instanceof this.m.Voice || v instanceof this.m.Bar)) dst[k] = v;
    }
  }

  _cloneBeat(src) {
    const b = new this.m.Beat();
    this._copyProps(b, src);
    for (const n of src.notes) {
      const c = new this.m.Note();
      this._copyProps(c, n);
      b.addNote(c);
    }
    return b;
  }

  _restBeat(duration) {
    const b = new this.m.Beat();
    b.duration = duration;
    return b;
  }

  _emptyBarBeats(mb) {
    const den = DURATIONS.includes(mb.timeSignatureDenominator) ? mb.timeSignatureDenominator : 4;
    return Array.from({ length: Math.max(1, mb.timeSignatureNumerator) }, () => this._restBeat(den));
  }

  /// Escribe un dígito: dos dígitos seguidos (en menos de 0,8 s) forman trastes de 10 a 24
  typeDigit(d) {
    const now = Date.now();
    let value = d;
    if (this.digitBuffer && now - this.digitBuffer.at < 800 && this.digitBuffer.value * 10 + d <= MAX_FRET) {
      value = this.digitBuffer.value * 10 + d;
      this.digitBuffer = null;
    } else {
      this.digitBuffer = { value: d, at: now };
    }
    this.setFret(value);
  }

  setFret(fret) {
    if (fret < 0 || fret > MAX_FRET) return;
    const { bar, beat, string } = this.cursor;
    const t = this.cursor.track;
    this.commit((score) => {
      const b = this._tabStaff(score.tracks[t]).bars[bar].voices[0].beats[beat];
      let note = b.notes.find((n) => n.string === string);
      if (note && note.fret === fret) return false;
      if (!note) {
        note = new this.m.Note();
        note.string = string;
        b.addNote(note);
      }
      note.fret = fret;
    });
  }

  fretStep(delta) {
    const note = this._note();
    if (!note) return;
    this.setFret(Math.max(0, Math.min(MAX_FRET, note.fret + delta)));
  }

  deleteNote() {
    const { bar, beat, string } = this.cursor;
    const t = this.cursor.track;
    this.commit((score) => {
      const b = this._tabStaff(score.tracks[t]).bars[bar].voices[0].beats[beat];
      const i = b.notes.findIndex((n) => n.string === string);
      if (i < 0) return false;
      b.removeNote ? b.removeNote(b.notes[i]) : b.notes.splice(i, 1);
    });
  }

  _withBeat(fn) {
    const { bar, beat } = this.cursor;
    const t = this.cursor.track;
    return this.commit((score) => fn(this._tabStaff(score.tracks[t]).bars[bar].voices[0].beats[beat], score));
  }

  setDuration(d) {
    if (!DURATIONS.includes(d)) return;
    this._withBeat((b) => { if (b.duration === d) return false; b.duration = d; });
  }

  /// +1 = más corta (negra → corchea), −1 = más larga
  durationStep(delta) {
    const cur = this._beat()?.duration ?? 4;
    const i = DURATIONS.indexOf(cur);
    const next = DURATIONS[Math.max(0, Math.min(DURATIONS.length - 1, i + delta))];
    this.setDuration(next);
  }

  toggleDot() { this._withBeat((b) => { b.dots = b.dots > 0 ? 0 : 1; }); }

  toggleTriplet() {
    this._withBeat((b) => {
      if (b.tupletNumerator === 3) { b.tupletNumerator = -1; b.tupletDenominator = -1; }
      else { b.tupletNumerator = 3; b.tupletDenominator = 2; }
    });
  }

  /// ¿Hay una nota en la misma cuerda en el tiempo siguiente? (hammer-on y slide la necesitan)
  _hasNextOnString() {
    const staff = this._staff();
    const { bar, beat, string } = this.cursor;
    const beats = staff?.bars[bar]?.voices[0]?.beats ?? [];
    const next = beat + 1 < beats.length ? beats[beat + 1] : staff?.bars[bar + 1]?.voices[0]?.beats[0];
    return !!next?.notes.some((n) => n.string === string);
  }

  toggleTechnique(name) {
    const { bar, beat, string } = this.cursor;
    const t = this.cursor.track;
    const D = this.m;
    const current = this._note();
    if (name === 'hammer' && current && !current.isHammerPullOrigin && !this._hasNextOnString()) {
      this.post('notice', { message: 'A hammer-on or pull-off needs a next note on the same string. Add that note first.' });
      return;
    }
    const slideTo = this._hasNextOnString() ? D.SlideOutType.Legato : D.SlideOutType.OutDown;
    this.commit((score) => {
      const b = this._tabStaff(score.tracks[t]).bars[bar].voices[0].beats[beat];
      const n = b.notes.find((x) => x.string === string);
      if (!n) return false;
      switch (name) {
        case 'hammer': n.isHammerPullOrigin = !n.isHammerPullOrigin; break;
        // Sin nota siguiente en la cuerda: «slide out» hacia abajo en vez de un slide a ninguna parte
        case 'slide': n.slideOutType = n.slideOutType === D.SlideOutType.None ? slideTo : D.SlideOutType.None; break;
        case 'bend':
          if (n.bendType !== D.BendType.None) {
            n.bendType = D.BendType.None;
            n.bendPoints = null;
          } else {
            // Bend de un tono completo (4 cuartos de tono)
            n.bendType = D.BendType.Bend;
            n.bendPoints = null;
            n.addBendPoint(new D.BendPoint(0, 0));
            n.addBendPoint(new D.BendPoint(15, 4));
            n.addBendPoint(new D.BendPoint(60, 4));
          }
          break;
        case 'palmMute': n.isPalmMute = !n.isPalmMute; break;
        case 'letRing': n.isLetRing = !n.isLetRing; break;
        case 'vibrato': n.vibrato = n.vibrato === D.VibratoType.None ? D.VibratoType.Slight : D.VibratoType.None; break;
        case 'dead': n.isDead = !n.isDead; break;
        default: return false;
      }
    });
  }

  insertBeat() {
    const { bar, beat } = this.cursor;
    const t = this.cursor.track;
    const ok = this.commit((score) => {
      const v = this._tabStaff(score.tracks[t]).bars[bar].voices[0];
      v.beats.splice(beat + 1, 0, this._restBeat(v.beats[beat]?.duration ?? 4));
    });
    if (ok) this.moveBeat(1);
  }

  deleteBeat() {
    const { bar, beat } = this.cursor;
    const t = this.cursor.track;
    this.commit((score) => {
      const v = this._tabStaff(score.tracks[t]).bars[bar].voices[0];
      if (v.beats.length > 1) v.beats.splice(beat, 1);
      else if (v.beats[0].notes.length) v.beats[0] = this._restBeat(v.beats[0].duration);
      else return false;
    });
  }

  // --- compases (afectan a todas las pistas) ---
  _range(sel) {
    return sel ? { start: sel.start, end: sel.end } : { start: this.cursor.bar, end: this.cursor.bar };
  }

  /// Inserta un compás vacío (silencios) detrás del cursor; devuelve el cambio para ajustar sync points
  insertBar() {
    const at = this.cursor.bar + 1;
    const ok = this.commit((score) => {
      const prev = score.masterBars[at - 1];
      const mb = new this.m.MasterBar();
      mb.timeSignatureNumerator = prev.timeSignatureNumerator;
      mb.timeSignatureDenominator = prev.timeSignatureDenominator;
      score.masterBars.splice(at, 0, mb);
      for (const track of score.tracks) for (const staff of track.staves) {
        const bar = new this.m.Bar();
        const voice = new this.m.Voice();
        bar.addVoice(voice);
        for (const b of this._emptyBarBeats(mb)) voice.addBeat(b);
        staff.bars.splice(at, 0, bar);
      }
    });
    if (ok) { this.cursor.bar = at; this.cursor.beat = 0; this.updateCursor(); this.postState(); }
    return ok ? { kind: 'insert', at, count: 1 } : null;
  }

  duplicateBars(sel) {
    const { start, end } = this._range(sel);
    const count = end - start + 1;
    const ok = this.commit((score) => {
      const copies = [];
      for (let i = start; i <= end; i++) {
        const src = score.masterBars[i];
        const mb = new this.m.MasterBar();
        mb.timeSignatureNumerator = src.timeSignatureNumerator;
        mb.timeSignatureDenominator = src.timeSignatureDenominator;
        copies.push(mb);
      }
      score.masterBars.splice(end + 1, 0, ...copies);
      for (const track of score.tracks) for (const staff of track.staves) {
        const newBars = [];
        for (let i = start; i <= end; i++) {
          const bar = new this.m.Bar();
          for (const v of staff.bars[i].voices) {
            const voice = new this.m.Voice();
            bar.addVoice(voice);
            for (const b of v.beats) voice.addBeat(this._cloneBeat(b));
          }
          newBars.push(bar);
        }
        staff.bars.splice(end + 1, 0, ...newBars);
      }
    });
    return ok ? { kind: 'insert', at: end + 1, count } : null;
  }

  deleteBars(sel) {
    const { start, end } = this._range(sel);
    const total = this.score?.masterBars.length ?? 0;
    const count = end - start + 1;
    if (count >= total) {
      this.post('notice', { message: 'A tab needs at least one bar, so the last one can’t be deleted.' });
      return null;
    }
    const ok = this.commit((score) => {
      score.masterBars.splice(start, count);
      for (const track of score.tracks) for (const staff of track.staves) staff.bars.splice(start, count);
    });
    if (ok) { this.cursor.bar = Math.min(start, total - count - 1); this.cursor.beat = 0; this.updateCursor(); this.postState(); }
    return ok ? { kind: 'delete', at: start, count } : null;
  }

  // ---------- teclado (Mac / teclado del iPad) ----------
  _onKey(e) {
    if (!this.enabled || e.defaultPrevented) return;
    const t = e.target;
    if (t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA')) return;
    const cmd = e.metaKey || e.ctrlKey;
    const handled = () => { e.preventDefault(); e.stopPropagation(); };

    if (cmd && e.key.toLowerCase() === 'z') { handled(); return e.shiftKey ? this.redo() : this.undo(); }
    if (cmd) return;
    if (/^[0-9]$/.test(e.key)) { handled(); return this.typeDigit(Number(e.key)); }
    switch (e.key) {
      case 'ArrowLeft': handled(); return e.altKey ? this.moveBar(-1) : this.moveBeat(-1);
      case 'ArrowRight': handled(); return e.altKey ? this.moveBar(1) : this.moveBeat(1);
      case 'ArrowUp': handled(); return this.moveString(1);
      case 'ArrowDown': handled(); return this.moveString(-1);
      case 'Backspace':
      case 'Delete': handled(); return this.deleteNote();
      case '+': case '=': handled(); return this.durationStep(1);
      case '-': case '_': handled(); return this.durationStep(-1);
      case '.': handled(); return this.toggleDot();
      case 't': handled(); return this.toggleTriplet();
      case 'h': handled(); return this.toggleTechnique('hammer');
      case 's': handled(); return this.toggleTechnique('slide');
      case 'b': handled(); return this.toggleTechnique('bend');
      case 'p': handled(); return this.toggleTechnique('palmMute');
      case 'l': handled(); return this.toggleTechnique('letRing');
      case 'v': handled(); return this.toggleTechnique('vibrato');
      case 'x': handled(); return this.toggleTechnique('dead');
      case 'i': case 'Insert': handled(); return this.insertBeat();
      default: return;
    }
  }

  // ---------- exportar y crear ----------
  exportGp() {
    const bytes = new this.at.exporter.Gp7Exporter().export(this.score, this.getApi().settings);
    return bytes;
  }

  /// Partitura nueva vacía: opts { title, artist, tuningId, tempo, numerator, denominator, bars }
  createScore(opts) {
    const m = this.m;
    const preset = TUNINGS[opts.tuningId] ?? TUNINGS['guitar-standard'];
    const score = new m.Score();
    score.title = opts.title || 'Untitled';
    score.artist = opts.artist || '';
    const track = new m.Track();
    track.name = preset.name.startsWith('Bass') ? 'Bass' : 'Guitar';
    track.playbackInfo.program = preset.program;
    track.playbackInfo.primaryChannel = 0;
    track.playbackInfo.secondaryChannel = 1;
    score.addTrack(track);
    const staff = new m.Staff();
    track.addStaff(staff);
    staff.stringTuning = new m.Tuning('', preset.tuning, false);
    staff.showTablature = true;
    staff.showStandardNotation = false;
    const bars = Math.max(1, Math.min(256, opts.bars || 8));
    const num = Math.max(1, Math.min(16, opts.numerator || 4));
    const den = DURATIONS.includes(opts.denominator) ? opts.denominator : 4;
    for (let i = 0; i < bars; i++) {
      const mb = new m.MasterBar();
      mb.timeSignatureNumerator = num;
      mb.timeSignatureDenominator = den;
      if (i === 0) mb.tempoAutomations.push(m.Automation.buildTempoAutomation(false, 0, opts.tempo || 120, 2));
      score.addMasterBar(mb);
      const bar = new m.Bar();
      staff.addBar(bar);
      const voice = new m.Voice();
      bar.addVoice(voice);
      for (const b of this._emptyBarBeats(mb)) voice.addBeat(b);
    }
    score.finish(new this.at.Settings());
    return new this.at.exporter.Gp7Exporter().export(score, new this.at.Settings());
  }
}
