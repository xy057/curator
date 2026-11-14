import 'dart:ui' as ui;

import '../lua.dart';
import '../key_signatures.dart';
import '../sounding_notes.dart';

/// A colour as an extension's Lua gives one: "#rrggbb" (or "#rrggbbaa"), or a table of its
/// red, green and blue from 0 to 1 ({r = 1, g = 0.5, b = 0}, or {1, 0.5, 0}; `a` or a fourth
/// for how solid it is). Null: it is none.
ui.Color? luaColor(Object? value) {
  if (value is String) {
    final hex = value.startsWith('#') ? value.substring(1) : value;
    final n = hex.length == 6 || hex.length == 8 ? int.tryParse(hex, radix: 16) : null;
    if (n == null) return null;
    return hex.length == 6 ? ui.Color(0xFF000000 | n) : ui.Color((n & 0xFF) << 24 | n >> 8);
  }
  if (value is! LuaTable) return null;
  double? part(String name, int index) => switch (value[name] ?? (index < value.array.length ? value.array[index] : null)) {
        final num v when v.isFinite => v.toDouble().clamp(0.0, 1.0),
        _ => null,
      };
  final r = part('r', 0), g = part('g', 1), b = part('b', 2);
  if (r == null || g == null || b == null) return null;
  return ui.Color.from(alpha: part('a', 3) ?? 1, red: r, green: g, blue: b);
}

/// The music of a score as it sounds, for an extension that hears it (`score.music`): every
/// pitched note, the key signatures at concert pitch, and where each bar starts (the score's
/// end last).
typedef ScoreMusic = ({List<SoundingNote> notes, List<ConcertKeySignature> keys, List<double> bars});

/// Reads [musicXML]'s music; [measureStarts] puts its bars in score quarters. Slow for a long
/// score: for an isolate.
ScoreMusic readScoreMusic(String musicXML, List<double> measureStarts) =>
    (notes: soundingNotes(musicXML, measureStarts).toList(), keys: concertKeySignatures(musicXML), bars: measureStarts);

/// [music] as Lua takes it: `notes` ({from, to, pitch, tied, chord, part, staff, voice}, in the
/// order written, part by part), `keys` ({bar, fifths, minor}: from that bar on; minor only
/// when the score says which) and `bars` (where each starts, in quarters, then the score's end).
LuaTable scoreMusicTable(ScoreMusic music) => LuaTable.map({
      'notes': LuaTable.list([
        for (final n in music.notes)
          LuaTable.map({'from': n.start, 'to': n.end, 'pitch': n.midi, 'tied': n.tied, 'chord': n.chord, 'part': n.partId, 'staff': n.staff, 'voice': n.voice}),
      ]),
      'keys': LuaTable.list([
        for (final k in music.keys) LuaTable.map({'bar': k.measure + 1, 'fifths': k.fifths, 'minor': ?k.minor}),
      ]),
      'bars': LuaTable.list(music.bars),
    });
