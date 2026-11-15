import 'package:xml/xml.dart';

import 'musicxml_kit.dart';
import 'score_editing.dart' show Pitch;

/// A note of the score as it sounds: [midi] (transposing parts at concert pitch) from score quarter
/// [start] to [end], in [voice] of [partId]'s [staff] (1 its first). A note of a chord after its first
/// is [chord]; one a tie carries on from the note before is [tied].
typedef SoundingNote = ({String partId, int staff, String voice, double start, double end, int midi, bool chord, bool tied});

/// Every pitched note of [musicXML] (no grace or cue notes, rests or unpitched percussion), part by
/// part, in the order written; [measureStarts] puts its bars in score quarters. With [unpitched],
/// unpitched percussion too, at the pitch of the line or space it is written on.
Iterable<SoundingNote> soundingNotes(String musicXML, List<double> measureStarts, {bool unpitched = false}) sync* {
  final root = XmlDocument.parse(musicXML).rootElement;
  for (final part in root.findElements('part')) {
    final id = part.getAttribute('id') ?? '';
    final bars = MeasureCursor();
    var transpose = 0;
    for (final (m, measure) in part.findElements('measure').indexed) {
      if (m + 1 >= measureStarts.length) break;
      for (final (e, start) in bars.walk(measure)) {
        switch (e.name.local) {
          case 'attributes':
            if (e.getElement('transpose') case final t?) {
              transpose = (xmlInt(t.getElement('chromatic')) ?? 0) + 12 * (xmlInt(t.getElement('octave-change')) ?? 0);
            }
          case 'note':
            final duration = durationOf(e), divisions = bars.divisions;
            final chord = e.getElement('chord') != null;
            final pitch = e.getElement('pitch');
            final drum = pitch == null && unpitched ? e.getElement('unpitched') : null;
            if (pitch == null && drum == null) continue; // a rest, or unpitched percussion
            // An unpitched note may leave out where it is written: the middle line, then.
            final step = 'CDEFGAB'.indexOf((pitch?.getElement('step') ?? drum?.getElement('display-step'))?.innerText.trim() ?? (drum != null ? 'B' : ''));
            final octave = xmlInt(pitch?.getElement('octave') ?? drum?.getElement('display-octave')) ?? (drum != null ? 4 : null);
            if (step < 0 || octave == null) continue;
            final alter = (double.tryParse(pitch?.getElement('alter')?.innerText.trim() ?? '') ?? 0).round();
            final from = measureStarts[m] + start / divisions;
            yield (
              partId: id,
              staff: xmlInt(e.getElement('staff')) ?? 1,
              voice: e.getElement('voice')?.innerText.trim() ?? '1',
              start: from,
              end: from + duration / divisions,
              midi: Pitch(step, octave, alter).midi + (drum == null ? transpose : 0),
              chord: chord,
              tied: e.findElements('tie').any((t) => t.getAttribute('type') == 'stop'),
            );
        }
      }
    }
  }
}
