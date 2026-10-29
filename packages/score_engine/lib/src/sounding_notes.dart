import 'dart:math' as math;

import 'package:xml/xml.dart';

/// A note of the score as it sounds: [midi] (transposing parts at concert pitch) from score quarter
/// [start] to [end], in [voice] of [partId]'s [staff] (1 its first). A note of a chord after its first
/// is [chord]; one a tie carries on from the note before is [tied].
typedef SoundingNote = ({String partId, int staff, String voice, double start, double end, int midi, bool chord, bool tied});

/// Every pitched note of [musicXML] (no grace or cue notes, rests or unpitched percussion), part by
/// part, in the order written; [measureStarts] puts its bars in score quarters.
Iterable<SoundingNote> soundingNotes(String musicXML, List<double> measureStarts) sync* {
  final root = XmlDocument.parse(musicXML).rootElement;
  int? number(XmlElement? e) => int.tryParse(e?.innerText.trim() ?? '');
  for (final part in root.findElements('part')) {
    final id = part.getAttribute('id') ?? '';
    var divisions = 1, transpose = 0;
    for (final (m, measure) in part.findElements('measure').indexed) {
      if (m + 1 >= measureStarts.length) break;
      var cursor = 0, lastStart = 0;
      for (final e in measure.childElements) {
        switch (e.name.local) {
          case 'attributes':
            divisions = math.max(1, number(e.getElement('divisions')) ?? divisions);
            if (e.getElement('transpose') case final t?) {
              transpose = (number(t.getElement('chromatic')) ?? 0) + 12 * (number(t.getElement('octave-change')) ?? 0);
            }
          case 'backup':
            cursor = math.max(0, cursor - (number(e.getElement('duration')) ?? 0));
          case 'forward':
            cursor += number(e.getElement('duration')) ?? 0;
          case 'note':
            if (e.getElement('grace') != null || e.getElement('cue') != null) continue;
            final duration = number(e.getElement('duration')) ?? 0;
            final chord = e.getElement('chord') != null;
            final start = chord ? lastStart : cursor;
            if (!chord) {
              lastStart = cursor;
              cursor += duration;
            }
            final pitch = e.getElement('pitch');
            if (pitch == null) continue; // a rest, or unpitched percussion
            final step = 'CDEFGAB'.indexOf(pitch.getElement('step')?.innerText.trim() ?? '');
            final octave = number(pitch.getElement('octave'));
            if (step < 0 || octave == null) continue;
            final alter = (double.tryParse(pitch.getElement('alter')?.innerText.trim() ?? '') ?? 0).round();
            final from = measureStarts[m] + start / divisions;
            yield (
              partId: id,
              staff: number(e.getElement('staff')) ?? 1,
              voice: e.getElement('voice')?.innerText.trim() ?? '1',
              start: from,
              end: from + duration / divisions,
              midi: 12 * (octave + 1) + const [0, 2, 4, 5, 7, 9, 11][step] + alter + transpose,
              chord: chord,
              tied: e.findElements('tie').any((t) => t.getAttribute('type') == 'stop'),
            );
        }
      }
    }
  }
}
