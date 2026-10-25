import 'package:xml/xml.dart';

import 'condensing.dart';
import 'score_metadata.dart';
import 'score_typography.dart';
import 'text_dynamics.dart';

/// A piece of text written in the score (a direction like "arco" or "dolce", a tempo mark, or
/// a rehearsal mark) that can be edited.
class ScoreText {
  const ScoreText({
    required this.id,
    required this.partId,
    required this.measure,
    required this.text,
    required this.kind,
    this.extended = false,
  });

  /// Stable id: the MusicXML `<direction>` id (assigned in document order if missing), with
  /// "-reh" for a rehearsal mark.
  final String id;
  final String partId;

  /// Measure index (0-based, score order).
  final int measure;
  final String text;
  final ScoreTextKind kind;

  /// Whether dashes or a bracket run on from it (`rit. - - -`), to where it ends.
  final bool extended;

  /// What [current] (this text, as shown) says of the speed.
  TempoRole tempoRole(String current) {
    if (kind == ScoreTextKind.rehearsal) return TempoRole.none;
    final words = current.toLowerCase();
    if (_back.hasMatch(words)) return TempoRole.back;
    if (_change.hasMatch(words)) return TempoRole.change;
    return kind == ScoreTextKind.tempo ? TempoRole.tempo : TempoRole.none;
  }

  static final _back = RegExp(r'^\W*(a|in) tempo\b');
  static final _change = RegExp(r'\b(rit|ritard|ritardando|riten|ritenuto|rall|rallent|rallentando|allarg|allargando|'
      r'largando|accel|accelerando|string|stringendo|stretto|slentando|incalzando|affrettando|trattenuto)\b');
}

enum ScoreTextKind { direction, tempo, rehearsal }

/// What a text says of the speed: nothing, a tempo ("Allegro"), a change for a while ("rit.",
/// "accel.": until its dashes end or another mark comes), or back to the tempo ("a tempo").
enum TempoRole { none, tempo, change, back }

/// The MusicXML prepared for engraving: every direction has an id, text edits are applied,
/// dynamics written as text are dynamics (see [TextDynamics]), and the players that can share
/// a staff have one (see [Condenser]).
class PreparedScore {
  PreparedScore._(this.musicXML, this.texts, this.condensed, this.condensing);

  /// Ready for Verovio.
  final String musicXML;

  /// Every editable text, as written in the original file (before edits).
  final List<ScoreText> texts;

  /// The shared staves added for pairs of players.
  final List<CondensedGroup> condensed;

  /// Who could share a staff with whom (null without [prepare]'s metadata).
  final CondensingOptions? condensing;

  /// [edits]: text id → new text ('' removes it). [metadata] is what [doc] says; with it,
  /// shared staves are added (after the edits, so they copy the edited texts), for the
  /// built-in pairs and the user's [pairs]. [textDynamics] off leaves dynamics written as text
  /// as text. The engraved texts take [typography]'s looks ([textSize]: the engraving's, in
  /// virtual units).
  static PreparedScore prepare(XmlDocument doc, Map<String, String> edits,
      {ScoreMetadata? metadata,
      List<PlayerPair> pairs = const [],
      bool textDynamics = true,
      ScoreTypography typography = ScoreTypography.standard,
      double textSize = 4.5}) {
    final texts = <ScoreText>[];
    var counter = 0;
    for (final part in doc.rootElement.findElements('part')) {
      final partId = part.getAttribute('id') ?? '';
      for (final (m, measure) in part.findElements('measure').indexed) {
        for (final direction in measure.findElements('direction')) {
          final id = direction.getAttribute('id') ?? 'cs-dir-${counter++}';
          direction.setAttribute('id', id);
          _dropRepeats(direction);
          final types = direction.findElements('direction-type');
          final words = [for (final t in types) ...t.findElements('words')];
          final rehearsal = [for (final t in types) ...t.findElements('rehearsal')].firstOrNull;
          final isTempo = types.any((t) => t.findElements('metronome').isNotEmpty) ||
              direction.getElement('sound')?.getAttribute('tempo') != null;

          if (words.isNotEmpty) {
            final text = words.map((w) => w.innerText).join().trim();
            texts.add(ScoreText(
              id: id,
              partId: partId,
              measure: m,
              text: text,
              kind: isTempo ? ScoreTextKind.tempo : ScoreTextKind.direction,
              extended: [for (final t in types) ...t.findElements('dashes'), for (final t in types) ...t.findElements('bracket')]
                  .any((e) => e.getAttribute('type') == 'start'),
            ));
            final edit = edits[id];
            if (edit != null) _replaceWords(words, edit);
          }
          if (rehearsal != null) {
            texts.add(ScoreText(
              id: '$id-reh',
              partId: partId,
              measure: m,
              text: rehearsal.innerText.trim(),
              kind: ScoreTextKind.rehearsal,
            ));
            final edit = edits['$id-reh']?.trim();
            if (edit != null && edit.isEmpty) {
              rehearsal.parent?.children.remove(rehearsal);
            } else {
              // Spaces after "A " would widen its box on one side.
              rehearsal.innerText = edit ?? rehearsal.innerText.trim();
            }
          }
        }
      }
    }
    // Remove direction-types left empty by deletions (MusicXML requires content).
    for (final type in doc.findAllElements('direction-type').toList()) {
      if (type.childElements.isEmpty) type.parent?.children.remove(type);
    }
    for (final direction in doc.findAllElements('direction').toList()) {
      if (direction.findElements('direction-type').isEmpty) direction.parent?.children.remove(direction);
    }
    // After the edits (an edited "F" is read as edited) and before condensing (which copies it).
    if (textDynamics) TextDynamics.apply(doc);
    typography.applyTo(doc, textSize: textSize);
    _numberVerses(doc);
    final options = metadata == null ? null : Condenser.options(doc, metadata);
    final condensed =
        metadata == null ? const <CondensedGroup>[] : Condenser.condense(doc, metadata, custom: pairs, options: options);
    return PreparedScore._(doc.toXmlString(), texts, condensed, options);
  }

  /// Some exporters write a direction's text twice over ("pizz.pizz.", "mf mf", two hairpins): a
  /// direction-type the same as one before it in the direction, but for where it is drawn, goes.
  static void _dropRepeats(XmlElement direction) {
    final seen = <String>{};
    for (final type in direction.findElements('direction-type').toList()) {
      final unplaced = type.copy();
      for (final e in [unplaced, ...unplaced.descendantElements]) {
        e.attributes.removeWhere((a) => _placement.contains(a.name.local));
      }
      if (!seen.add(unplaced.toXmlString())) direction.children.remove(type);
    }
  }

  static const _placement = {'default-x', 'default-y', 'relative-x', 'relative-y'};

  /// A lyric's number may be any token ("part1verse2", "chorus"), but Verovio reads it as a
  /// whole number, so every other token would be verse 1. In a part with one, the verses are
  /// numbered 1, 2, … in the order of the last number in each token, then as they first come.
  static void _numberVerses(XmlDocument doc) {
    for (final part in doc.rootElement.findElements('part')) {
      final lyrics = [for (final note in part.findAllElements('note')) ...note.findElements('lyric')];
      String token(XmlElement lyric) => lyric.getAttribute('number')?.trim() ?? '1';
      if (lyrics.every((l) => (int.tryParse(token(l)) ?? 0) > 0)) continue;
      final tokens = {for (final l in lyrics) token(l)}.toList();
      int? lastNumber(String t) => int.tryParse(RegExp(r'\d+').allMatches(t).lastOrNull?.group(0) ?? '');
      final ordered = [...tokens]..sort((a, b) {
          final na = lastNumber(a), nb = lastNumber(b);
          if (na != nb) return na == null ? 1 : (nb == null ? -1 : na.compareTo(nb));
          return tokens.indexOf(a).compareTo(tokens.indexOf(b));
        });
      for (final l in lyrics) {
        l.setAttribute('number', '${ordered.indexOf(token(l)) + 1}');
      }
    }
  }

  /// The first words element takes the new text (keeping its font and position); the rest go.
  static void _replaceWords(List<XmlElement> words, String text) {
    for (final w in words.skip(text.isEmpty ? 0 : 1)) {
      w.parent?.children.remove(w);
    }
    if (text.isNotEmpty) words.first.innerText = text;
  }
}
