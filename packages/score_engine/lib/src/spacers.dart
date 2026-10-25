import 'package:flutter/foundation.dart';
import 'package:xml/xml.dart';

/// The key a vertical spacer is written in: concert pitch, or an instrument's transposition
/// (a staff in B♭ shows the key a clarinet's does).
enum SpacerKey {
  c('C', 0),
  bFlat('B♭', 2),
  a('A', -3),
  f('F', 1),
  eFlat('E♭', 3),
  d('D', -2),
  g('G', -1);

  const SpacerKey(this.label, this.fifths);

  /// "B♭": the instrument's key, as a part name says it ("Clarinet in B♭").
  final String label;

  /// How many fifths its key signature is from the concert key (B♭: two sharps more).
  final int fifths;

  static SpacerKey named(String? name) => values.where((k) => k.name == name).firstOrNull ?? c;

  /// [concert] written for this key: within six accidentals either way (C♯ major is D♭ major).
  int keyOf(int concert) {
    var key = concert + fifths;
    while (key > 6) {
      key -= 12;
    }
    while (key < -6) {
      key += 12;
    }
    return key;
  }
}

/// A staff of nothing (the Attach Image extension): room in the stack for an image or for
/// what isn't written yet. It is an instrument like any other (a lane, a name, a place in the
/// order), engraved as a part of its own after the score's ([Spacers.write]): its bars are the
/// score's, empty, its key signatures the score's in [key]. What else it shows is drawn:
/// with [lines] its five staff lines and barlines, in the frozen zone ([frozen]) its name,
/// clef, key and time signature, and it is [height] staff spaces tall.
@immutable
class VerticalSpacer {
  const VerticalSpacer({
    required this.id,
    this.key = SpacerKey.c,
    this.frozen = false,
    this.lines = false,
    this.height = defaultHeight,
  });

  /// `spacer-1`, `spacer-2`…: its part's id.
  final String id;
  final SpacerKey key;

  /// Whether the frozen zone shows its name, clef, key and time signature.
  final bool frozen;

  /// Whether its staff lines (and barlines, clef and key changes) are drawn.
  final bool lines;

  /// How tall it is, staff spaces: at least a five-line staff's 4 with [lines].
  final double height;

  static const defaultHeight = 6.0, minHeight = 1.0, maxHeight = 40.0;

  /// [height] as drawn: never less than its lines take.
  double get shownHeight => lines ? height.clamp(4.0, maxHeight) : height.clamp(minHeight, maxHeight);

  /// What changes the engraving: the part and its key signatures.
  bool engravesLike(VerticalSpacer other) => other.id == id && other.key == key;

  VerticalSpacer copyWith({SpacerKey? key, bool? frozen, bool? lines, double? height}) => VerticalSpacer(
      id: id, key: key ?? this.key, frozen: frozen ?? this.frozen, lines: lines ?? this.lines, height: height ?? this.height);

  @override
  bool operator ==(Object other) =>
      other is VerticalSpacer &&
      other.id == id &&
      other.key == key &&
      other.frozen == frozen &&
      other.lines == lines &&
      other.height == height;
  @override
  int get hashCode => Object.hash(id, key, frozen, lines, height);
}

/// A blank of [width] staff spaces opened in every staff before what sounds at a beat
/// ([offset] quarters into bar [bar], counted from 0), as wide as asked whatever the spacing
/// around it: the engraving either side stays as it was (the patched Verovio's
/// `curatedSpacers`). A beat where nothing starts opens it before the next thing that does.
@immutable
class HorizontalSpacer {
  const HorizontalSpacer({required this.bar, required this.offset, this.width = defaultWidth});

  final int bar;
  final double offset;
  final double width;

  static const defaultWidth = 8.0, minWidth = 1.0, maxWidth = 80.0;

  HorizontalSpacer copyWith({int? bar, double? offset, double? width}) =>
      HorizontalSpacer(bar: bar ?? this.bar, offset: offset ?? this.offset, width: width ?? this.width);

  @override
  bool operator ==(Object other) =>
      other is HorizontalSpacer && other.bar == bar && other.offset == offset && other.width == width;
  @override
  int get hashCode => Object.hash(bar, offset, width);
}

abstract final class Spacers {
  /// Prefix of every vertical spacer's part id.
  static const idPrefix = 'spacer-';

  static bool isSpacer(String partId) => partId.startsWith(idPrefix);

  /// The id of a new vertical spacer: one more than the highest of [ids].
  static String nextId(Iterable<String> ids) {
    final taken = [for (final id in ids) if (isSpacer(id)) int.tryParse(id.substring(idPrefix.length)) ?? 0];
    return '$idPrefix${taken.fold(0, (a, b) => a > b ? a : b) + 1}';
  }

  /// Its name until the user names it: "Spacer 2" for `spacer-2`.
  static String nameOf(String id) => 'Spacer ${id.substring(idPrefix.length)}';

  /// Adds a part to [doc] for each of [spacers], after the score's own (so no staff number
  /// changes): the bars of the first part with a key, empty (a rest that isn't drawn, so the
  /// spacing doesn't change), with its time signatures and barlines (repeats, endings) and its
  /// keys as heard, written in the spacer's [VerticalSpacer.key]; a treble clef.
  static void write(XmlDocument doc, List<VerticalSpacer> spacers) {
    final root = doc.rootElement;
    final partList = root.getElement('part-list');
    final parts = root.findElements('part').toList();
    if (spacers.isEmpty || partList == null || parts.isEmpty) return;
    final reference = parts.firstWhere((p) => p.findAllElements('key').isNotEmpty, orElse: () => parts.first);
    final bars = _barsOf(reference);
    for (final spacer in spacers) {
      if (root.findElements('part').any((p) => p.getAttribute('id') == spacer.id)) continue;
      partList.children.add(_element('score-part', attributes: {'id': spacer.id}, children: [
        _element('part-name', text: nameOf(spacer.id)),
      ]));
      root.children.add(_element('part', attributes: {'id': spacer.id}, children: [
        for (final (i, bar) in bars.indexed)
          XmlElement.tag('measure', attributes: [
            for (final a in bar.measure.attributes) if (a.name.local != 'width') a.copy(),
          ], children: [
            for (final b in bar.measure.findElements('barline')) if (b.getAttribute('location') == 'left') b.copy(),
            if (i == 0 || bar.divisions != bars[i - 1].divisions || bar.keys.isNotEmpty || bar.times.isNotEmpty)
              _element('attributes', children: [
                if (i == 0 || bar.divisions != bars[i - 1].divisions) _element('divisions', text: '${bar.divisions}'),
                for (final k in bar.keys) _key(k, spacer.key),
                for (final t in bar.times) t.copy(),
                if (i == 0) _element('clef', children: [_element('sign', text: 'G'), _element('line', text: '2')]),
              ]),
            _element('note', attributes: {'print-object': 'no'}, children: [
              _element('rest', attributes: {'measure': 'yes'}),
              _element('duration', text: '${bar.length}'),
              _element('voice', text: '1'),
            ]),
            for (final b in bar.measure.findElements('barline')) if (b.getAttribute('location') != 'left') b.copy(),
          ]),
      ]));
    }
  }

  /// [key] (as [reference] wrote it, its transposition [concertShift] taken off) for [to].
  static XmlElement _key((XmlElement key, int concertShift) key, SpacerKey to) {
    final copy = key.$1.copy();
    final fifths = copy.getElement('fifths');
    final written = int.tryParse(fifths?.innerText.trim() ?? '');
    if (fifths != null && written != null) {
      fifths.children
        ..clear()
        ..add(XmlText('${to.keyOf(written - key.$2)}'));
    }
    copy.attributes.removeWhere((a) => a.name.local == 'number');
    return copy;
  }

  /// Each bar of [part]: its element, the divisions it counts in, its length in them, and the
  /// key and time signatures it changes to (each key with the fifths its transposition adds).
  static List<
      ({
        XmlElement measure,
        int divisions,
        int length,
        List<(XmlElement, int)> keys,
        List<XmlElement> times,
      })> _barsOf(XmlElement part) {
    var divisions = 1, shift = 0;
    final out = <({XmlElement measure, int divisions, int length, List<(XmlElement, int)> keys, List<XmlElement> times})>[];
    for (final measure in part.findElements('measure')) {
      final keys = <(XmlElement, int)>[];
      final times = <XmlElement>[];
      var at = 0, length = 0;
      for (final e in measure.childElements) {
        switch (e.name.local) {
          case 'attributes':
            if (e.getElement('divisions') case final d?) {
              final n = int.tryParse(d.innerText.trim()) ?? 0;
              if (n > 0) divisions = n;
            }
            if (e.getElement('transpose') case final t?) shift = _fifthsOf(int.tryParse(t.getElement('chromatic')?.innerText.trim() ?? '') ?? 0);
            keys.addAll([for (final k in e.findElements('key')) if (k.getAttribute('number') case null || '1') (k, shift)]);
            times.addAll(e.findElements('time'));
          case 'note' when e.getElement('chord') == null && e.getElement('grace') == null:
            at += _duration(e);
          case 'forward':
            at += _duration(e);
          case 'backup':
            at -= _duration(e);
        }
        if (at > length) length = at;
      }
      out.add((measure: measure, divisions: divisions, length: length, keys: keys, times: times));
    }
    return out;
  }

  /// The fifths a written key is from the concert key for an instrument [chromatic] semitones
  /// from written to sounding (B♭: −2 → +2).
  static int _fifthsOf(int chromatic) {
    final f = (-chromatic * 7) % 12;
    return f > 6 ? f - 12 : f;
  }

  static XmlElement _element(String name,
          {Map<String, String> attributes = const {}, List<XmlNode> children = const [], String? text}) =>
      XmlElement.tag(name,
          attributes: [for (final MapEntry(:key, :value) in attributes.entries) XmlAttribute(XmlName.qualified(key), value)],
          children: [...children, if (text != null) XmlText(text)]);

  static int _duration(XmlElement e) => int.tryParse(e.getElement('duration')?.innerText.trim() ?? '') ?? 0;

  /// The patched Verovio's `curatedSpacers` for [spacers]; null for none.
  static String? verovioOption(List<HorizontalSpacer> spacers) => spacers.isEmpty
      ? null
      : [for (final s in spacers) '${s.bar}:${s.offset}:${s.width}'].join(',');
}
