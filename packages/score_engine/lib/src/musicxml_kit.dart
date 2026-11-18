import 'dart:math' as math;

import 'package:xml/xml.dart';

// What reading and writing MusicXML takes again and again, for the engine's own readers.

/// [s] as MusicXML text or an attribute's value: `&`, `<`, `>` and `"` escaped.
String xmlEscaped(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

/// The whole number [e] holds; null: none, or it isn't one.
int? xmlInt(XmlElement? e) => int.tryParse(e?.innerText.trim() ?? '');

/// [e]'s `<duration>`, in divisions; 0 when it has none.
int durationOf(XmlElement e) => xmlInt(e.getElement('duration')) ?? 0;

/// An element written whole: [name], its [attributes], its [children] and then [text].
XmlElement xmlElement(String name, {Map<String, String> attributes = const {}, List<XmlNode> children = const [], String? text}) => XmlElement.tag(name,
    attributes: [for (final MapEntry(:key, :value) in attributes.entries) XmlAttribute(XmlName.qualified(key), value)],
    children: [...children, if (text != null) XmlText(text)]);

/// The fifths a written key is from the concert key for an instrument [chromatic] semitones
/// from written to sounding (B♭: −2 → +2).
int writtenFifthsOf(int chromatic) {
  final f = (-chromatic * 7) % 12;
  return f > 6 ? f - 12 : f;
}

/// A part's bars walked in time, as MusicXML times them: `<divisions>` kept from bar to bar,
/// `<backup>` and `<forward>` moving the cursor, a chord's notes at the time of the one they join.
class MeasureCursor {
  /// Divisions of a quarter, as the last `<attributes>` set them.
  int divisions = 1;

  /// Each child of [measure] with when it starts, in divisions from the bar's start: a note at
  /// its own start (grace and cue notes are passed over), anything else at the cursor (backup
  /// and forward are taken, not given).
  Iterable<(XmlElement, int)> walk(XmlElement measure) sync* {
    var cursor = 0, lastStart = 0;
    for (final e in measure.childElements) {
      switch (e.name.local) {
        case 'attributes':
          divisions = math.max(1, xmlInt(e.getElement('divisions')) ?? divisions);
          yield (e, cursor);
        case 'backup':
          cursor = math.max(0, cursor - durationOf(e));
        case 'forward':
          cursor += durationOf(e);
        case 'note':
          if (e.getElement('grace') != null || e.getElement('cue') != null) continue;
          if (e.getElement('chord') == null) {
            lastStart = cursor;
            cursor += durationOf(e);
          }
          yield (e, lastStart);
        default:
          yield (e, cursor);
      }
    }
  }
}
