import 'package:xml/xml.dart';

/// A key signature of a score at concert pitch: from bar [measure] (an index) on, [fifths];
/// [minor] as the parts say (`<mode>`; null: none says).
typedef ConcertKeySignature = ({int measure, int fifths, bool? minor});

/// The key signatures of [musicXML] at concert pitch, in order, each where it changes. Where
/// the parts differ (horns written without one, a part's own change), most of them win, a part
/// at concert pitch counting twice; unpitched percussion has no say.
List<ConcertKeySignature> concertKeySignatures(String musicXML) => _concertKeySignatures(XmlDocument.parse(musicXML).rootElement);

List<ConcertKeySignature> _concertKeySignatures(XmlElement root) {
  int? number(XmlElement? e) => int.tryParse(e?.innerText.trim() ?? '');
  // Each part's keys, as they change: (measure, concert fifths, mode) and whether it transposes.
  final parts = <List<(int, int, bool?, bool)>>[];
  for (final part in root.findElements('part')) {
    final keys = <(int, int, bool?, bool)>[];
    var chromatic = 0, percussion = false;
    for (final (m, measure) in part.findElements('measure').indexed) {
      for (final attributes in measure.findElements('attributes')) {
        if (attributes.getElement('transpose') case final t?) chromatic = number(t.getElement('chromatic')) ?? 0;
        if (attributes.findElements('clef').any((c) => c.getElement('sign')?.innerText.trim() == 'percussion')) percussion = true;
        final key = attributes.getElement('key');
        final fifths = number(key?.getElement('fifths'));
        if (fifths == null) continue;
        // A transposing part is written that many fifths from concert pitch (a B♭ part two sharper).
        var shift = (-chromatic * 7) % 12;
        if (shift > 6) shift -= 12;
        var concert = fifths - shift;
        if (concert > 7) concert -= 12;
        if (concert < -7) concert += 12;
        final mode = key!.getElement('mode')?.innerText.trim();
        keys.add((m, concert, mode == 'minor' ? true : (mode == 'major' ? false : null), chromatic % 12 != 0));
      }
    }
    if (!percussion && keys.isNotEmpty) parts.add(keys);
  }
  final changes = {for (final keys in parts) for (final k in keys) k.$1}.toList()..sort();
  final out = <ConcertKeySignature>[];
  for (final m in changes) {
    final votes = <int, double>{}, modes = <int, List<bool?>>{};
    for (final keys in parts) {
      final now = keys.lastWhere((k) => k.$1 <= m, orElse: () => (-1, 0, null, false));
      if (now.$1 < 0) continue;
      votes[now.$2] = (votes[now.$2] ?? 0) + (now.$4 ? 1 : 2);
      (modes[now.$2] ??= []).add(now.$3);
    }
    if (votes.isEmpty) continue;
    final fifths = votes.entries.reduce((a, b) => b.value > a.value || (b.value == a.value && b.key.abs() < a.key.abs()) ? b : a).key;
    final said = modes[fifths]!.nonNulls;
    final minors = said.where((v) => v).length;
    final bool? minor = said.isEmpty || minors * 2 == said.length ? null : minors * 2 > said.length;
    if (out.lastOrNull case final last? when last.fifths == fifths && last.minor == minor) continue;
    out.add((measure: m, fifths: fifths, minor: minor));
  }
  return out;
}
