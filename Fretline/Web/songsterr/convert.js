// Conversor: JSON de Songsterr -> alphaTab Score (y de ahí a .gp con Gp7Exporter).
//
// El formato de Songsterr NO es público. Este conversor cubre lo habitual
// (compases, compás/time signature, repeticiones, marcadores, tempo, duraciones,
// puntillos, tresillos, ligaduras, muteadas, ghost, hammer/pull, slides,
// armónicos, bends, palm mute, let ring, vibrato y batería). Si Songsterr cambia
// el formato, lo que se rompe está aislado aquí.
//
// Uso: buildScore(at, meta, parts) -> Score
//      videoPointsToSync(score, pointsSeconds) -> FlatSyncPoint[]

const DRUM_INSTRUMENT_ID = 1024;

function tupletDenominator(n) {
  let d = 1;
  while (d * 2 < n) d *= 2;
  return d;
}

function toDuration(at, beat) {
  // Songsterr usa "type" (1,2,4,8,16,32,64) y a veces "duration": [1, 4]
  let t = beat.type;
  if (!t && Array.isArray(beat.duration)) t = beat.duration[1] / (beat.duration[0] || 1);
  const allowed = [1, 2, 4, 8, 16, 32, 64];
  if (!allowed.includes(t)) t = 4;
  return t; // alphaTab.model.Duration usa los mismos valores numéricos
}

function applyNote(at, note, sn, stringCount, isDrums) {
  const m = at.model;
  if (isDrums) {
    note.percussionArticulation = sn.fret ?? 38;
    return;
  }
  note.string = stringCount - (sn.string ?? 0); // Songsterr: 0 = cuerda más aguda
  note.fret = sn.fret ?? 0;
  if (sn.tie) note.isTieDestination = true;
  if (sn.dead) note.isDead = true;
  if (sn.ghost) note.isGhost = true;
  if (sn.hp) note.isHammerPullOrigin = true;
  if (sn.vibrato) note.vibrato = m.VibratoType.Slight;
  if (sn.slide) {
    const map = {
      shift: m.SlideOutType.Shift,
      legato: m.SlideOutType.Legato,
      downwards: m.SlideOutType.OutDown,
      upwards: m.SlideOutType.OutUp,
    };
    if (map[sn.slide] !== undefined) note.slideOutType = map[sn.slide];
  }
  if (sn.harmonic) {
    const map = {
      natural: m.HarmonicType.Natural,
      artificial: m.HarmonicType.Artificial,
      pinch: m.HarmonicType.Pinch,
      tap: m.HarmonicType.Tap,
      semi: m.HarmonicType.Semi,
      feedback: m.HarmonicType.Feedback,
    };
    if (map[sn.harmonic] !== undefined) note.harmonicType = map[sn.harmonic];
  }
  if (sn.bend && Array.isArray(sn.bend.points) && sn.bend.points.length) {
    note.bendType = m.BendType.Custom;
    for (const p of sn.bend.points) {
      // Songsterr: tone 100 = 1 tono; alphaTab: valor en cuartos de tono
      note.addBendPoint(new m.BendPoint(Math.round(p.position ?? 0), Math.round((p.tone ?? 0) / 25)));
    }
  }
}

function buildBeat(at, sb, stringCount, isDrums) {
  const m = at.model;
  const beat = new m.Beat();
  beat.duration = toDuration(at, sb);
  if (sb.dots) beat.dots = sb.dots;
  if (sb.tuplet && sb.tuplet > 1) {
    beat.tupletNumerator = sb.tuplet;
    beat.tupletDenominator = tupletDenominator(sb.tuplet);
  }
  if (sb.text) beat.text = String(sb.text.text ?? sb.text);
  const notes = (sb.notes || []).filter((n) => !n.rest);
  if (sb.rest || notes.length === 0) {
    beat.isEmpty = false;
    return beat; // silencio
  }
  for (const sn of notes) {
    const note = new m.Note();
    applyNote(at, note, sn, stringCount, isDrums);
    if (sb.palmMute) note.isPalmMute = true;
    if (sb.letRing) note.isLetRing = true;
    beat.addNote(note);
  }
  return beat;
}

function alternateEndingBits(alt) {
  if (!alt) return 0;
  const list = Array.isArray(alt) ? alt : [alt];
  return list.reduce((acc, n) => acc | (1 << (Number(n) - 1)), 0);
}

export function buildScore(at, meta, parts) {
  const m = at.model;
  const score = new m.Score();
  score.title = meta.title || '';
  score.artist = meta.artist || '';
  score.tab = 'Songsterr';

  const measureCount = Math.max(0, ...parts.map((p) => (p.measures || []).length));
  const reference = parts.find((p) => p.instrumentId !== DRUM_INSTRUMENT_ID) || parts[0];

  // MasterBars (estructura común a todas las pistas)
  for (let i = 0; i < measureCount; i++) {
    const mb = new m.MasterBar();
    const sm = reference?.measures?.[i] || {};
    const prev = score.masterBars[i - 1];
    const sig = sm.signature || (prev ? [prev.timeSignatureNumerator, prev.timeSignatureDenominator] : [4, 4]);
    mb.timeSignatureNumerator = sig[0];
    mb.timeSignatureDenominator = sig[1];
    if (sm.repeatStart) mb.isRepeatStart = true;
    if (sm.repeatClose) mb.repeatCount = sm.repeat || 2;
    const alt = alternateEndingBits(sm.alternateEnding);
    if (alt) mb.alternateEndings = alt;
    if (sm.marker?.text) {
      const s = new m.Section();
      s.text = sm.marker.text;
      mb.section = s;
    }
    score.addMasterBar(mb);
  }

  // Tempo
  // (score.tempo es solo lectura: se deriva de la primera automatización)
  const tempos = [...(reference?.automations?.tempo || [])];
  if (!tempos.some((t) => (t.measure ?? 0) === 0)) tempos.unshift({ measure: 0, position: 0, bpm: tempos[0]?.bpm || 120 });
  for (const ta of tempos) {
    const mb = score.masterBars[ta.measure ?? 0];
    if (!mb) continue;
    mb.tempoAutomations.push(m.Automation.buildTempoAutomation(!!ta.linear, ta.position ?? 0, ta.bpm, 2)); // 2 = referencia negra
  }

  // Pistas
  let nextChannel = 0;
  const takeChannel = () => {
    if (nextChannel === 9) nextChannel++;
    return Math.min(15, nextChannel++);
  };

  for (const part of parts) {
    const isDrums = part.instrumentId === DRUM_INSTRUMENT_ID;
    const track = new m.Track();
    track.name = part.name || part.instrument || 'Pista';
    track.playbackInfo.program = isDrums ? 0 : (part.instrumentId ?? 25);
    if (isDrums) {
      track.playbackInfo.primaryChannel = 9;
      track.playbackInfo.secondaryChannel = 9;
    } else {
      const ch = takeChannel();
      track.playbackInfo.primaryChannel = ch;
      track.playbackInfo.secondaryChannel = ch;
    }
    score.addTrack(track);

    const staff = new m.Staff();
    track.addStaff(staff);
    const tuning = part.tuning && part.tuning.length ? part.tuning : [64, 59, 55, 50, 45, 40];
    const stringCount = part.strings || tuning.length;
    if (isDrums) {
      staff.isPercussion = true;
      staff.showTablature = false;
      staff.showStandardNotation = true;
    } else {
      staff.stringTuning = new m.Tuning('', tuning, false);
      staff.showTablature = true;
      staff.showStandardNotation = false;
      if (part.capo) staff.capo = part.capo;
    }

    for (let i = 0; i < measureCount; i++) {
      const bar = new m.Bar();
      staff.addBar(bar);
      const sm = part.measures?.[i];
      const voices = sm?.voices?.length ? sm.voices : [{ beats: [] }];
      voices.forEach((sv, vi) => {
        const voice = new m.Voice();
        bar.addVoice(voice);
        const beats = sv.beats || [];
        if (beats.length === 0) {
          if (vi === 0) {
            const rest = new m.Beat();
            rest.duration = m.Duration.Whole;
            voice.addBeat(rest);
          }
          return;
        }
        for (const sb of beats) voice.addBeat(buildBeat(at, sb, stringCount, isDrums));
      });
    }
  }

  score.finish(new at.Settings());
  return score;
}

// Orden real de reproducción de los compases (con repeticiones y finales alternativos)
export function playOrder(score) {
  const order = [];
  const bars = score.masterBars;
  let repeatStart = 0;
  const passes = new Map(); // índice de cierre de repetición -> veces que ya se repitió
  let i = 0;
  let pass = 1;
  let guard = 0;
  while (i < bars.length && guard++ < 100000) {
    const mb = bars[i];
    if (mb.isRepeatStart && !passes.has(`start${i}`)) {
      repeatStart = i;
      passes.set(`start${i}`, true);
      pass = 1;
    }
    if (mb.alternateEndings && !(mb.alternateEndings & (1 << (pass - 1)))) {
      i++;
      continue;
    }
    order.push(i);
    if (mb.repeatCount > 0) {
      const done = passes.get(i) || 1;
      if (done < mb.repeatCount) {
        passes.set(i, done + 1);
        pass = done + 1;
        i = repeatStart;
        continue;
      }
      passes.delete(i);
      pass = 1;
    }
    i++;
  }
  return order;
}

// Songsterr da un tiempo (segundos) por compás tocado; lo pasamos a FlatSyncPoint de alphaTab
export function videoPointsToSync(score, pointsSeconds) {
  const order = playOrder(score);
  const occ = new Map();
  const out = [];
  for (let k = 0; k < order.length && k < pointsSeconds.length; k++) {
    const barIndex = order[k];
    const o = occ.get(barIndex) || 0;
    occ.set(barIndex, o + 1);
    out.push({ barIndex, barPosition: 0, barOccurence: o, millisecondOffset: Math.round(pointsSeconds[k] * 1000) });
  }
  return out;
}
