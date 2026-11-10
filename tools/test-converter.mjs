import * as at from '@coderline/alphatab';
import { buildScore, videoPointsToSync, playOrder } from '../Fretline/Web/songsterr/convert.js';
// Fixture inventado (no es ninguna canción real)
const gtr = { name:'Guitarra', instrumentId:29, strings:6, tuning:[64,59,55,50,45,40],
  automations:{ tempo:[{measure:0,position:0,bpm:100},{measure:2,position:0,bpm:120}] },
  measures:[
    { signature:[4,4], marker:{text:'Intro'}, repeatStart:true, voices:[{beats:[
      {type:8, notes:[{fret:0,string:5}], palmMute:true},{type:8,notes:[{fret:3,string:5,hp:true}]},
      {type:4, dots:1, notes:[{fret:5,string:4,vibrato:true}]},{type:8,notes:[{rest:true}]},
      {type:4, notes:[{fret:7,string:3,bend:{points:[{position:0,tone:0},{position:30,tone:100}]}}]}]}]},
    { repeatClose:true, repeat:2, voices:[{beats:[
      {type:8,tuplet:3,notes:[{fret:2,string:2}]},{type:8,tuplet:3,notes:[{fret:3,string:2}]},{type:8,tuplet:3,notes:[{fret:5,string:2,slide:'shift'}]},
      {type:4,notes:[{fret:7,string:2,tie:true}]},{type:2,notes:[{fret:12,string:0,harmonic:'natural'},{fret:12,string:1,harmonic:'natural'}]}]}]},
    { signature:[3,4], marker:{text:'Verso'}, voices:[{beats:[{type:2,dots:1,rest:true,notes:[]}]}]},
    { voices:[] },
  ]};
const drums = { name:'Batería', instrumentId:1024, strings:6, measures:[
  { voices:[{beats:[{type:4,notes:[{fret:36}]},{type:4,notes:[{fret:38}]},{type:4,notes:[{fret:36},{fret:42}]},{type:4,notes:[{fret:38,dead:true}]}]}]},
  { voices:[{beats:[{type:1,notes:[{fret:49}]}]}]}, { voices:[{beats:[{type:2,dots:1,notes:[{fret:36}]}]}]}, {} ]};
const score = buildScore(at, {title:'Prueba', artist:'Fretline'}, [gtr, drums]);
console.log('bars', score.masterBars.length, 'tracks', score.tracks.map(t=>t.name), 'tempo', score.tempo);
console.log('order', playOrder(score));
const sync = videoPointsToSync(score, [1.5, 3.9, 6.3, 8.7, 10.7, 12.7]);
console.log('sync', JSON.stringify(sync));
score.applyFlatSyncPoints(sync);
const bytes = new at.exporter.Gp7Exporter().export(score, new at.Settings());
const s2 = at.importer.ScoreLoader.loadScoreFromBytes(bytes, new at.Settings());
console.log('roundtrip', s2.title, s2.tracks.length, s2.masterBars.length, 'first note realValue', s2.tracks[0].staves[0].bars[0].voices[0].beats[0].notes[0].realValue);
console.log('flat sync back', s2.exportFlatSyncPoints().length);
// MIDI
const midi = new at.midi.MidiFile(); const h = new at.midi.AlphaSynthMidiFileHandler(midi); new at.midi.MidiFileGenerator(s2, new at.Settings(), h).generate();
console.log('midi events', midi.tracks?.reduce?.((a,t)=>a+t.events.length,0) ?? midi.events?.length);
