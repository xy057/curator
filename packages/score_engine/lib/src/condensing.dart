import 'package:flutter/foundation.dart';
import 'package:xml/xml.dart';

import 'score_metadata.dart';

/// Two players of one instrument (Flute 1 and Flute 2) sharing one staff, like Dorico's
/// condensing: the curated view shows the shared staff while both instruments are shown, and
/// each player's own staff while only one is.
///
/// The shared staff is a part of its own, added to the MusicXML before engraving (see
/// [Condenser]), so Verovio engraves it in the same system as every other staff: its notes
/// line up with theirs, and swapping staves never moves the music sideways.
@immutable
class CondensedGroup {
  const CondensedGroup({required this.id, required this.partIds, required this.staffNumber});

  /// The added part's id (`cond-P2-P3`); also what a project saves when the pair is condensed.
  final String id;

  /// The two players, in score order.
  final List<String> partIds;

  /// The shared staff's number (@n) in the engraving.
  final int staffNumber;

  /// The shared staff's name: "Flute 1" and "Flute 2" → "Flute 1.2" (the same for short
  /// names: "Fl. 1.2"). Names that aren't one instrument's numbered players are joined.
  static String nameFor(String first, String second) {
    final a = _numbered.firstMatch(first.trim()), b = _numbered.firstMatch(second.trim());
    if (a != null && b != null && a[1] == b[1]) return '${a[1]} ${a[2]}.${b[2]}';
    if (first.trim().isEmpty || second.trim().isEmpty) return first.trim() + second.trim();
    return '$first + $second';
  }

  /// "Horn in F 3" → ("Horn in F", "3").
  static final _numbered = RegExp(r'^(.*\S)\s+(\d+)$');

  /// Whether two part names read as players of one instrument ("Flute 1", "Flute 2").
  static bool arePlayers(String first, String second) {
    final a = _numbered.firstMatch(first.trim()), b = _numbered.firstMatch(second.trim());
    return a != null && b != null && a[1] == b[1] && a[2] != b[2];
  }

  @override
  bool operator ==(Object other) =>
      other is CondensedGroup && other.id == id && listEquals(other.partIds, partIds) && other.staffNumber == staffNumber;
  @override
  int get hashCode => Object.hash(id, partIds[0], partIds[1], staffNumber);
}

/// Two players who share a staff while condensed, in score order.
@immutable
class PlayerPair {
  const PlayerPair(this.first, this.second);
  final String first, second;

  List<String> get partIds => [first, second];

  /// The shared staff's part id (`cond-P2-P3`); also what a project saves when the pair is
  /// condensed.
  String get id => '${Condenser.idPrefix}$first-$second';

  bool contains(String partId) => partId == first || partId == second;

  @override
  bool operator ==(Object other) => other is PlayerPair && other.first == first && other.second == second;
  @override
  int get hashCode => Object.hash(first, second);
  @override
  String toString() => 'PlayerPair($first, $second)';
}

/// Who can share a staff with whom in a score, and the pairs made without asking.
@immutable
class CondensingOptions {
  const CondensingOptions({required this.order, required this.builtIn, required this.partners});

  /// Every part id, in score order.
  final List<String> order;

  /// Adjacent players of one instrument ("Flute 1", "Flute 2"), paired in score order.
  final List<PlayerPair> builtIn;

  /// For each player, those who could share a staff with them: any other single-staff part
  /// with the same clefs, transposition and time signatures throughout (unpitched percussion
  /// only with unpitched percussion). A flute and a violin can; a flute and a clarinet in B♭,
  /// a flute and a piccolo, or a violin and a viola can't.
  final Map<String, Set<String>> partners;

  /// [first] and [second] as a pair, in score order; null when they can't share a staff.
  PlayerPair? pair(String first, String second) {
    if (!(partners[first]?.contains(second) ?? false)) return null;
    return order.indexOf(first) < order.indexOf(second) ? PlayerPair(first, second) : PlayerPair(second, first);
  }

  /// The pairs a score has with the user's [custom] ones: those that can share a staff (each
  /// player in one pair, the first to ask), then every built-in pair whose players are both
  /// still free. In score order of their first players.
  List<PlayerPair> pairs(List<PlayerPair> custom) {
    final taken = <String>{};
    final out = <PlayerPair>[];
    for (final p in [...custom, ...builtIn]) {
      final pair = this.pair(p.first, p.second);
      if (pair == null || taken.contains(pair.first) || taken.contains(pair.second)) continue;
      taken.addAll(pair.partIds);
      out.add(pair);
    }
    return out..sort((a, b) => order.indexOf(a.first).compareTo(order.indexOf(b.first)));
  }
}

/// What the shared staff shows in one bar.
enum _Bar {
  /// Both rest: the first player's rests.
  rest,

  /// Only one plays: that player's notes, marked "1." / "2." where this starts.
  first,
  second,

  /// Both play the same notes: the first player's, marked "a2".
  unison,

  /// The same rhythm, the second player never above the first: one voice of chords.
  chords,

  /// Anything else: two voices, the first player's stems up, the second's down.
  voices,
}

/// Adds a shared staff for each pair of players that can condense.
///
/// Built in, players pair up in score order: adjacent single-staff parts named as one
/// instrument's numbered players ("Horn in F 1" … "4" make 1.2 and 3.4), with the same clefs,
/// keys, transposition and time signatures throughout, one voice each. Sections (Violin I /
/// II) are not numbered players and stay apart, as in Dorico. The user may pair any two
/// single-staff instruments with the same transposition (Horn 1 and 3, Flute and Oboe); a
/// player in such a pair leaves the built-in one.
///
/// The shared staff is written as the first player's: its clefs and keys. Where the second
/// player is written in another key, the accidentals of both are spelled again against the
/// first player's. Instruments that aren't one instrument's numbered players are labelled by
/// their short names ("Fl.", "Ob.") instead of "1." and "2.".
///
/// Each bar is written in the simplest way that shows both players (see [_Bar]).
abstract final class Condenser {
  /// Prefix of every id in the added parts (their own, and copied directions' ids), so the
  /// shared staff's texts lead back to the texts they copy (see [sourceTextId]).
  static const idPrefix = 'cond-';

  /// The id of the score text a drawn text copies: a shared staff's copy of "dolce" edits
  /// the player's own.
  static String sourceTextId(String id) => id.startsWith(idPrefix) ? id.substring(idPrefix.length) : id;

  /// Who can share a staff with whom in [doc] (before [condense] adds anything to it).
  static CondensingOptions options(XmlDocument doc, ScoreMetadata metadata) {
    final elements = {for (final p in doc.rootElement.findElements('part')) p.getAttribute('id') ?? '': p};
    final single = [
      for (final p in metadata.parts)
        if (p.staffNumbers.length == 1 && elements[p.id] != null) p,
    ];
    final written = {for (final p in single) p.id: '${p.isUnpitchedPercussion}\n${_writtenAs(elements[p.id]!)}'};
    final partners = {
      for (final MapEntry(key: id, value: w) in written.entries)
        id: {for (final e in written.entries) if (e.key != id && e.value == w) e.key},
    };
    // Built in: numbered players of one instrument, written alike (clefs, keys, transposition), one voice each.
    final profiles = {for (final p in single) if (!p.isUnpitchedPercussion) p.id: ?_profile(elements[p.id]!)};
    final builtIn = <PlayerPair>[];
    final parts = metadata.parts;
    for (var i = 0; i + 1 < parts.length; i++) {
      final a = parts[i], b = parts[i + 1];
      if (profiles[a.id] == null || profiles[a.id] != profiles[b.id] || !CondensedGroup.arePlayers(a.name, b.name)) continue;
      builtIn.add(PlayerPair(a.id, b.id));
      i++; // each player condenses once
    }
    return CondensingOptions(order: [for (final p in parts) p.id], builtIn: builtIn, partners: partners);
  }

  /// Adds the shared staves to [doc] (after every other part, so no staff number changes)
  /// and returns them: the built-in pairs and the user's [custom] ones (see
  /// [CondensingOptions.pairs]). [metadata] is what [doc] said before.
  static List<CondensedGroup> condense(XmlDocument doc, ScoreMetadata metadata,
      {List<PlayerPair> custom = const [], CondensingOptions? options}) {
    final root = doc.rootElement;
    final partList = root.getElement('part-list');
    if (partList == null) return const [];
    final elements = {for (final p in root.findElements('part')) p.getAttribute('id') ?? '': p};
    final byId = {for (final p in metadata.parts) p.id: p};
    final pairs = [
      for (final p in (options ?? Condenser.options(doc, metadata)).pairs(custom)) (byId[p.first]!, byId[p.second]!),
    ];
    if (pairs.isEmpty) return const [];

    final divisions = _commonDivisions([for (final (a, b) in pairs) ...[elements[a.id]!, elements[b.id]!]]);
    var staff = metadata.parts.fold(0, (n, p) => n + p.staffNumbers.length);
    final groups = <CondensedGroup>[];
    for (final (a, b) in pairs) {
      final id = PlayerPair(a.id, b.id).id;
      final numbered = CondensedGroup.arePlayers(a.name, b.name);
      String short(ScorePart p) => p.abbreviation.trim().isNotEmpty ? p.abbreviation.trim() : p.name.trim();
      final labels = numbered ? (first: '1.', second: '2.') : (first: short(a), second: short(b));
      partList.children.add(_element('score-part', attributes: {
        'id': id
      }, children: [
        _element('part-name', text: CondensedGroup.nameFor(a.name, b.name)),
        _element('part-abbreviation', text: CondensedGroup.nameFor(a.abbreviation, b.abbreviation)),
      ]));
      root.children.add(_merge(id, elements[a.id]!, elements[b.id]!, divisions, labels: labels));
      groups.add(CondensedGroup(id: id, partIds: [a.id, b.id], staffNumber: ++staff));
    }
    return groups;
  }

  /// What two parts must share to share a staff: the same bars, clefs, keys,
  /// transposition and meters, as one text. Null for a part in more than one voice.
  static String? _profile(XmlElement part) {
    if (_voices(part) > 1) return null;
    return [for (final m in part.findElements('measure')) _signatures(m).join()].join('\u0000|');
  }

  /// What two parts must share to share a staff, as one text: each change of clef,
  /// transposition and time signature, with the bar and the point in it (in quarters) where
  /// it takes effect. Values are read for what they mean, so the same thing written two ways
  /// is equal, and one restated (a courtesy clef) is no change.
  static String _writtenAs(XmlElement part) {
    final current = {'clef': _clef(null), 'transpose': _transposition(null), 'time': ''};
    final changes = <String>[];
    var divisions = 1;
    for (final (bar, measure) in part.findElements('measure').indexed) {
      var at = 0; // in divisions
      for (final e in measure.childElements) {
        switch (e.name.local) {
          case 'attributes':
            divisions = int.tryParse(e.getElement('divisions')?.innerText.trim() ?? '') ?? divisions;
            final values = {
              if (e.getElement('clef') case final clef?) 'clef': _clef(clef),
              if (e.getElement('transpose') case final transpose?) 'transpose': _transposition(transpose),
              if (e.getElement('time') case final time?) 'time': _plain(time),
            };
            for (final MapEntry(:key, :value) in values.entries) {
              if (current[key] == value) continue;
              current[key] = value;
              final g = _gcd(at, divisions); // at / divisions quarters, as the lowest fraction
              changes.add('$bar ${at ~/ g}/${divisions ~/ g} $key $value');
            }
          case 'note' when e.getElement('chord') == null && e.getElement('grace') == null:
            at += _BarReading._duration(e);
          case 'forward':
            at += _BarReading._duration(e);
          case 'backup':
            at -= _BarReading._duration(e);
        }
      }
    }
    return changes.join('\n');
  }

  /// A clef as what it is: sign, line (the sign's usual one when not given) and octaves up or
  /// down (treble clef with an 8 below: G2-1). No clef reads as a treble clef, as Verovio
  /// draws one.
  static String _clef(XmlElement? clef) {
    final sign = clef?.getElement('sign')?.innerText.trim() ?? 'G';
    final line = int.tryParse(clef?.getElement('line')?.innerText.trim() ?? '') ?? const {'G': 2, 'F': 4, 'C': 3}[sign] ?? 0;
    final octaves = int.tryParse(clef?.getElement('clef-octave-change')?.innerText.trim() ?? '') ?? 0;
    return '$sign$line$octaves';
  }

  /// A transposition as the interval from written to sounding, in steps and semitones
  /// (octave-change folded in, so "octave-change -1" and "diatonic -7, chromatic -12" are
  /// the same), and whether it is doubled an octave. None is 0 0.
  static String _transposition(XmlElement? transpose) {
    int n(String name) => int.tryParse(transpose?.getElement(name)?.innerText.trim() ?? '') ?? 0;
    final octaves = n('octave-change');
    final doubled = transpose?.getElement('double');
    return '${n('diatonic') + 7 * octaves} ${n('chromatic') + 12 * octaves}'
        '${doubled == null ? '' : ' doubled ${doubled.getAttribute('above') == 'yes' ? 'above' : 'below'}'}';
  }

  /// A bar's attributes as written, less what may differ between players (divisions, layout).
  static List<String> _signatures(XmlElement measure) => [
        for (final attributes in measure.findElements('attributes'))
          for (final child in attributes.childElements)
            if (child.name.local != 'divisions') _plain(child),
      ];

  static int _voices(XmlElement part) =>
      {for (final v in part.findAllElements('voice')) if (v.parentElement?.name.local == 'note') v.innerText.trim()}.length;

  /// An element's XML without layout attributes and ids: what it says, not where it was drawn.
  static String _plain(XmlElement element) {
    final copy = element.copy();
    for (final e in [copy, ...copy.descendantElements]) {
      e.attributes.removeWhere((a) => _layoutAttributes.contains(a.name.local));
    }
    return copy.toXmlString();
  }

  static const _layoutAttributes = {'default-x', 'default-y', 'relative-x', 'relative-y', 'id', 'color', 'print-object'};

  /// One divisions value (per quarter) that every duration in [parts] can be written in.
  static int _commonDivisions(List<XmlElement> parts) {
    var result = 1;
    for (final part in parts) {
      for (final d in part.findAllElements('divisions')) {
        final n = int.tryParse(d.innerText.trim()) ?? 1;
        if (n > 0) result = result ~/ _gcd(result, n) * n;
      }
    }
    return result;
  }

  static int _gcd(int a, int b) => b == 0 ? a : _gcd(b, a % b);

  // MARK: Merging

  static XmlElement _merge(String id, XmlElement a, XmlElement b, int divisions,
      {required ({String first, String second}) labels}) {
    final first = _PartReader(a, divisions, remapNumbers: false);
    final second = _PartReader(b, divisions, remapNumbers: true);
    final part = _element('part', attributes: {'id': id});
    _Bar? labelled; // what the last label said; reset by a bar where both rest
    for (final ma in a.findElements('measure')) {
      final x = first.next(ma), y = second.next(second.measures[x.index]);
      // The second player as the first's staff shows them: in its clef and key.
      y.dropSignatures();
      final respell = y.fifths != x.fifths;
      final bar = _classify(x, y);
      final label = switch (bar) {
        _Bar.first when labelled != _Bar.first => labels.first,
        _Bar.second when labelled != _Bar.second => labels.second,
        _Bar.unison when labelled != _Bar.unison => 'a2',
        _ => null,
      };
      if (bar == _Bar.rest) {
        labelled = null;
      } else if (bar != _Bar.chords && bar != _Bar.voices) {
        labelled = bar;
      } else {
        labelled = _Bar.voices; // a later solo or unison is labelled again
      }
      part.children.add(_writeBar(ma, x, y, bar, label, respellIn: respell ? x.fifths : null));
    }
    _dropUnpaired(part);
    return part;
  }

  /// Removes slurs, hairpins and lines whose other end was left out (a bar written without
  /// the second player's markings), which Verovio would otherwise pair with the wrong end or
  /// draw on to the end of the piece. Ends were paired in the players' own parts
  /// ([_PartReader.pairs]); a pair is kept only when both of its ends are here.
  static void _dropUnpaired(XmlElement part) {
    final ends = <String, List<XmlElement>>{};
    final unpaired = <XmlElement>[];
    for (final e in part.descendantElements) {
      if (!_spanners.contains(e.name.local) || e.getAttribute('type') == 'continue') continue;
      final pair = e.getAttribute(_pairAttribute);
      e.removeAttribute(_pairAttribute);
      if (pair == null) {
        unpaired.add(e);
      } else {
        (ends[pair] ??= []).add(e);
      }
    }
    for (final e in [...unpaired, for (final pair in ends.values) if (pair.length != 2) ...pair]) {
      var parent = e.parentElement;
      e.remove();
      // Take away what that leaves empty: notations, direction-type, direction.
      while (parent != null && const {'notations', 'direction-type', 'direction'}.contains(parent.name.local)) {
        if (parent.childElements.any((c) => !const {'voice', 'staff', 'offset'}.contains(c.name.local))) break;
        final up = parent.parentElement;
        parent.remove();
        parent = up;
      }
    }
  }

  static const _pairAttribute = 'cs-pair';
  static const _spanners = {'slur', 'wedge', 'dashes', 'bracket', 'octave-shift'};

  static _Bar _classify(_BarReading x, _BarReading y) {
    if (x.silent && y.silent) return _Bar.rest;
    if (y.silent) return _Bar.first;
    if (x.silent) return _Bar.second;
    if (x.voices.length > 1 || y.voices.length > 1) return _Bar.voices;
    if (!listEquals(x.rhythm, y.rhythm)) return _Bar.voices;
    if (listEquals(x.pitches, y.pitches)) return _Bar.unison;
    // Chords only while the second player stays at or below the first.
    for (var i = 0; i < x.groups.length; i++) {
      if (x.groups[i].rest) continue;
      if (y.groups[i].highest > x.groups[i].lowest) return _Bar.voices;
    }
    return _Bar.chords;
  }

  /// One bar of the shared staff. With [respellIn] (the key's fifths), the second player was
  /// written in another key: the accidentals are spelled again for both, as one staff.
  static XmlElement _writeBar(XmlElement source, _BarReading x, _BarReading y, _Bar bar, String? label, {int? respellIn}) {
    final measure = _element('measure', attributes: {
      for (final attribute in source.attributes)
        if (attribute.name.local != 'width') attribute.name.qualified: attribute.value,
    });
    final body = <XmlNode>[];
    switch (bar) {
      case _Bar.rest || _Bar.first || _Bar.unison:
        body.addAll(x.body);
      case _Bar.second:
        body.addAll(y.body);
      case _Bar.chords:
        _addChords(x, y);
        for (final note in x.notes) {
          note.getElement('stem')?.remove(); // Verovio chooses them for the chords
        }
        body.addAll(x.body);
      case _Bar.voices:
        _setVoice(x, 1, 'up', offset: 0);
        _setVoice(y, 2, 'down', offset: 4);
        body.addAll(x.body);
        if (x.finish > 0) body.add(_durationElement('backup', x.finish));
        body.addAll([
          for (final node in y.body)
            if (node is! XmlElement || node.name.local != 'direction' || !x.directions.contains(y.directionKeys[node]))
              node,
        ]);
        // Where the players' dynamics differ, the first player's go above the staff and the
        // second's below, as Dorico places them.
        final own = [
          for (final node in body.skip(x.body.length))
            if (node is XmlElement && node.name.local == 'direction') node,
        ];
        for (final direction in own) {
          direction.setAttribute('placement', 'below');
        }
        if (own.any(_isDynamic)) {
          for (final node in x.body) {
            if (node is XmlElement && node.name.local == 'direction' && _isDynamic(node)) {
              node.setAttribute('placement', 'above');
            }
          }
        }
    }
    if (respellIn != null && bar != _Bar.first && bar != _Bar.unison && bar != _Bar.rest) _respell(body, respellIn);
    if (label != null) _insertLabel(body, label);
    measure.children
      ..addAll(x.lead)
      ..addAll(body)
      ..addAll(x.tail);
    return measure;
  }

  static bool _isDynamic(XmlElement direction) => direction
      .findElements('direction-type')
      .any((t) => t.getElement('dynamics') != null || t.getElement('wedge') != null);

  /// The second player's notes join the first's as chord notes (the pitches the first doesn't
  /// already play), keeping their accidentals and ties.
  static void _addChords(_BarReading x, _BarReading y) {
    for (var i = 0; i < x.groups.length; i++) {
      final gx = x.groups[i], gy = y.groups[i];
      if (gx.rest) continue;
      final taken = {for (final n in gx.notes) _pitchKey(n)};
      final added = <XmlElement>[];
      for (final note in gy.notes) {
        if (!taken.add(_pitchKey(note))) continue;
        final chord = note.copy();
        for (final name in const ['stem', 'beam', 'lyric', 'voice', 'chord', 'dynamics']) {
          chord.findElements(name).toList().forEach((e) => e.remove());
        }
        for (final notations in chord.findElements('notations').toList()) {
          notations.children.removeWhere((c) => c is XmlElement && c.name.local != 'tied');
          if (notations.childElements.isEmpty) notations.remove();
        }
        final at = chord.children.indexWhere((c) => c is XmlElement && !const {'grace', 'cue'}.contains(c.name.local));
        chord.children.insert(at < 0 ? 0 : at, _element('chord'));
        added.add(chord);
      }
      final last = gx.notes.last;
      final index = x.body.indexOf(last);
      x.body.insertAll(index + 1, added);
    }
  }

  /// A player's notes as one voice with its stems one way, or (a player in several voices)
  /// their own voices, numbered after [offset], so they never meet the other player's.
  static void _setVoice(_BarReading reading, int voice, String stem, {required int offset}) {
    if (reading.voices.length > 1) {
      for (final node in reading.body.whereType<XmlElement>()) {
        final v = node.getElement('voice');
        if (v != null) v.innerText = '${(int.tryParse(v.innerText.trim()) ?? 1) + offset}';
      }
      return;
    }
    for (final note in reading.notes) {
      _setChild(note, 'voice', '$voice', after: const ['grace', 'cue', 'chord', 'pitch', 'rest', 'unpitched', 'duration', 'tie', 'instrument']);
      final rest = note.getElement('rest');
      if (rest != null) {
        rest.children.clear(); // placed by voice, not where the single part had it
      } else {
        _setChild(note, 'stem', stem,
            after: const ['duration', 'tie', 'instrument', 'voice', 'type', 'dot', 'accidental', 'time-modification']);
      }
    }
    for (final node in reading.body) {
      if (node is XmlElement && (node.name.local == 'forward' || node.name.local == 'direction')) {
        node.getElement('voice')?.innerText = '$voice';
      }
    }
  }

  /// Sets [name]'s text, adding it after the last of [after] present (MusicXML's order).
  static void _setChild(XmlElement parent, String name, String text, {required List<String> after}) {
    final existing = parent.getElement(name);
    if (existing != null) {
      existing.innerText = text;
      return;
    }
    var at = 0;
    for (final (i, child) in parent.children.indexed) {
      if (child is XmlElement && after.contains(child.name.local)) at = i + 1;
    }
    parent.children.insert(at, _element(name, text: text));
  }

  /// Spells the accidentals of a bar's notes against the key of [fifths], in the order they
  /// sound, as on one staff: shown where a note differs from the key or from the same note
  /// earlier in the bar (and on every notehead of it that starts then, in either voice), not
  /// where it doesn't; a note tied over keeps what it had.
  static void _respell(List<XmlNode> body, int fifths) {
    final notes = <(int, int, XmlElement)>[];
    var position = 0, last = 0;
    for (final node in body.whereType<XmlElement>()) {
      switch (node.name.local) {
        case 'note':
          final chord = node.getElement('chord') != null;
          final at = chord ? last : position;
          if (node.getElement('pitch') != null) notes.add((at, notes.length, node));
          if (!chord) {
            last = position;
            if (node.getElement('grace') == null) position += _BarReading._duration(node);
          }
        case 'backup':
          position -= _BarReading._duration(node);
        case 'forward':
          position += _BarReading._duration(node);
      }
    }
    notes.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
    final inKey = {
      for (final (i, step) in 'FCGDAEB'.split('').indexed)
        step: fifths > i ? 1 : (fifths < -(6 - i) ? -1 : 0),
    };
    final current = <String, double>{};
    final shownAt = <String, int>{}; // where each note's accidental was last shown
    for (final (at, _, note) in notes) {
      final pitch = note.getElement('pitch')!;
      final step = pitch.getElement('step')?.innerText.trim() ?? 'C';
      final alter = double.tryParse(pitch.getElement('alter')?.innerText.trim() ?? '') ?? 0;
      if (alter != alter.roundToDouble()) continue; // microtones: as written
      final key = '$step${pitch.getElement('octave')?.innerText.trim()}';
      final was = current[key] ?? (inKey[step] ?? 0).toDouble();
      current[key] = alter;
      final tiedOver = note.findElements('tie').any((t) => t.getAttribute('type') == 'stop');
      if (tiedOver || (alter == was && shownAt[key] != at)) {
        note.getElement('accidental')?.remove();
      } else {
        shownAt[key] = at;
        _setChild(note, 'accidental', const {-2: 'flat-flat', -1: 'flat', 0: 'natural', 1: 'sharp', 2: 'double-sharp'}[alter.round()] ?? 'natural',
            after: const ['duration', 'tie', 'instrument', 'voice', 'type', 'dot']);
      }
    }
  }

  /// "1.", "2." or "a2" above the first note played, where the music changes hands.
  static void _insertLabel(List<XmlNode> body, String label) {
    final at = body.indexWhere((n) =>
        n is XmlElement && n.name.local == 'note' && n.getElement('rest') == null && n.getElement('chord') == null);
    if (at < 0) return;
    body.insert(
        at,
        _element('direction', attributes: {
          'placement': 'above'
        }, children: [
          _element('direction-type', children: [_element('words', text: label)]),
        ]));
  }

  static XmlElement _durationElement(String name, int duration) =>
      _element(name, children: [_element('duration', text: '$duration')]);

  static XmlElement _element(String name,
          {Map<String, String> attributes = const {}, List<XmlNode> children = const [], String? text}) =>
      XmlElement.tag(name,
          attributes: [for (final MapEntry(:key, :value) in attributes.entries) XmlAttribute(XmlName.qualified(key), value)],
          children: [...children, if (text != null) XmlText(text)]);

  static String _pitchKey(XmlElement note) {
    final pitch = note.getElement('pitch');
    if (pitch == null) {
      final unpitched = note.getElement('unpitched');
      if (unpitched == null) return 'rest';
      return 'x${unpitched.getElement('display-step')?.innerText.trim()}${unpitched.getElement('display-octave')?.innerText.trim()}';
    }
    return '${pitch.getElement('step')?.innerText.trim()}${pitch.getElement('octave')?.innerText.trim()}'
        '/${double.tryParse(pitch.getElement('alter')?.innerText.trim() ?? '') ?? 0}';
  }
}

/// Reads a player's bars in order, each copied and rewritten in the shared divisions.
class _PartReader {
  _PartReader(XmlElement part, this.divisions, {required this.remapNumbers})
      : measures = part.findElements('measure').toList() {
    // Pair every start with its stop, by kind and number, in the order written.
    final open = <String, List<XmlElement>>{};
    for (final e in part.descendantElements) {
      if (!Condenser._spanners.contains(e.name.local)) continue;
      final key = '${e.name.local} ${e.getAttribute('number') ?? '1'}';
      switch (e.getAttribute('type')) {
        case 'stop':
          final starts = open[key];
          if (starts != null && starts.isNotEmpty) {
            pairs[starts.removeLast()] = pairs[e] = '${part.getAttribute('id')}-${pairs.length}';
          }
        case 'continue':
          break;
        default: // start, crescendo, diminuendo, up, down
          (open[key] ??= []).add(e);
      }
    }
  }

  /// The two ends of each slur, hairpin and line in the part share a key.
  final pairs = Map<XmlElement, String>.identity();

  final int divisions;
  final List<XmlElement> measures;

  /// The second player's slurs and hairpins are renumbered, so they never pair up with the
  /// first player's when both are on one staff.
  final bool remapNumbers;

  int _current = 1; // the part's own divisions so far
  int _index = 0;
  int _fifths = 0; // the key so far

  /// Follows the key an attributes element sets.
  void _follow(XmlElement attributes) {
    final fifths = attributes.getElement('key')?.getElement('fifths');
    if (fifths != null) _fifths = int.tryParse(fifths.innerText.trim()) ?? _fifths;
  }

  _BarReading next(XmlElement measure) {
    final index = _index++;
    final lead = <XmlElement>[], body = <XmlNode>[], tail = <XmlElement>[];
    var started = false;
    for (final child in measure.childElements) {
      final copy = child.copy();
      final originals = [child, ...child.descendantElements];
      for (final (i, e) in [copy, ...copy.descendantElements].indexed) {
        final id = e.getAttribute('id');
        if (id != null) e.setAttribute('id', '${Condenser.idPrefix}$id');
        final pair = pairs[originals[i]];
        if (pair != null) e.setAttribute(Condenser._pairAttribute, pair);
      }
      switch (copy.name.local) {
        case 'attributes':
          if (!started) _follow(copy);
          final d = copy.getElement('divisions');
          if (d != null) {
            _current = int.tryParse(d.innerText.trim()) ?? _current;
            d.innerText = '$divisions';
          }
          (started ? body : lead).add(copy);
          continue;
        case 'print' when !started:
          lead.add(copy);
          continue;
        case 'barline':
          (copy.getAttribute('location') == 'left' && !started ? lead : tail).add(copy);
          continue;
        case 'print':
          continue;
        case 'note' || 'backup' || 'forward':
          started = true;
      }
      _scale(copy);
      body.add(copy);
    }
    final reading = _BarReading(index, lead, body, tail, remapNumbers: remapNumbers)..fifths = _fifths;
    for (final a in body.whereType<XmlElement>()) {
      if (a.name.local == 'attributes') _follow(a); // for the bars after this one
    }
    return reading;
  }

  void _scale(XmlElement element) {
    if (_current == divisions) return;
    for (final e in element.descendantElements) {
      if (e.name.local != 'duration' && e.name.local != 'offset') continue;
      final value = double.tryParse(e.innerText.trim());
      if (value == null) continue;
      final scaled = value * divisions / _current;
      e.innerText = scaled == scaled.roundToDouble() ? '${scaled.round()}' : '$scaled';
    }
  }
}

/// One player's bar: its elements, and its notes grouped into chords with their rhythm.
class _BarReading {
  _BarReading(this.index, this.lead, this.body, this.tail, {required bool remapNumbers}) {
    var position = 0;
    for (final node in body) {
      if (node is! XmlElement) continue;
      switch (node.name.local) {
        case 'note':
          final chord = node.getElement('chord') != null;
          if (chord && groups.isNotEmpty) {
            groups.last.notes.add(node);
            continue;
          }
          final duration = node.getElement('grace') != null ? 0 : _duration(node);
          groups.add(_Group(node));
          position += duration;
        case 'backup':
          position -= _duration(node);
        case 'forward':
          position += _duration(node);
        case 'direction':
          final key = '$position ${[for (final t in node.findElements('direction-type')) Condenser._plain(t)].join()}';
          directionKeys[node] = key;
      }
      if (position > end) end = position;
    }
    finish = position;
    if (remapNumbers) {
      for (final node in body.whereType<XmlElement>()) {
        for (final e in node.descendantElements) {
          if (!const {'slur', 'wedge', 'dashes', 'bracket', 'octave-shift'}.contains(e.name.local)) continue;
          e.setAttribute('number', '${(int.tryParse(e.getAttribute('number') ?? '') ?? 1) + 8}');
        }
      }
    }
  }

  final int index;
  final List<XmlElement> lead, tail;
  final List<XmlNode> body;
  final groups = <_Group>[];

  /// Where each direction is and what it says, to leave out the second player's copies of
  /// the first player's dynamics.
  final directionKeys = <XmlElement, String>{};
  late final Set<String> directions = directionKeys.values.toSet();

  /// How far into the bar the player's music reaches (divisions), and where it is after the
  /// last element.
  int end = 0, finish = 0;

  /// The key in effect (as the bar starts).
  int fifths = 0;

  /// The voices the player's notes are in.
  late final Set<String> voices = {for (final n in notes) n.getElement('voice')?.innerText.trim() ?? '1'};

  /// Takes out what would change the shared staff's clef, key or meter (it follows the first
  /// player's).
  void dropSignatures() {
    for (final a in [...lead, ...body.whereType<XmlElement>()]) {
      if (a.name.local != 'attributes') continue;
      a.children.removeWhere(
          (c) => c is XmlElement && const {'key', 'time', 'clef', 'transpose', 'staves', 'staff-details'}.contains(c.name.local));
      if (a.childElements.isEmpty) body.remove(a);
    }
  }

  Iterable<XmlElement> get notes => groups.expand((g) => g.notes);
  bool get silent => groups.every((g) => g.rest);
  List<String> get rhythm => [for (final g in groups) g.rhythm];
  List<String> get pitches => [for (final g in groups) g.pitches];

  static int _duration(XmlElement e) => int.tryParse(e.getElement('duration')?.innerText.trim() ?? '') ?? 0;
}

/// A note, or a chord of notes sounding together.
class _Group {
  _Group(XmlElement first) : notes = [first];
  final List<XmlElement> notes;

  bool get rest => notes.first.getElement('rest') != null;

  /// What the notes look like in time: grace or not, rest or not, length, value and dots,
  /// tuplet.
  String get rhythm {
    final n = notes.first;
    final tuplet = n.getElement('time-modification');
    return [
      n.getElement('grace') != null,
      n.getElement('cue') != null,
      rest,
      n.getElement('duration')?.innerText.trim(),
      n.getElement('type')?.innerText.trim(),
      n.findElements('dot').length,
      tuplet?.getElement('actual-notes')?.innerText.trim(),
      tuplet?.getElement('normal-notes')?.innerText.trim(),
    ].join('|');
  }

  String get pitches => ([for (final n in notes) Condenser._pitchKey(n)]..sort()).join(',');

  /// Semitones of the highest and lowest note (0 for a rest).
  int get highest => notes.map(_semitones).fold(-1000, (a, b) => a > b ? a : b);
  int get lowest => notes.map(_semitones).fold(1000, (a, b) => a < b ? a : b);

  static int _semitones(XmlElement note) {
    final pitch = note.getElement('pitch');
    if (pitch == null) return 0;
    const steps = {'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11};
    final step = steps[pitch.getElement('step')?.innerText.trim()] ?? 0;
    final octave = int.tryParse(pitch.getElement('octave')?.innerText.trim() ?? '') ?? 4;
    final alter = double.tryParse(pitch.getElement('alter')?.innerText.trim() ?? '')?.round() ?? 0;
    return octave * 12 + step + alter;
  }
}
