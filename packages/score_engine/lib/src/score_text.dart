import 'package:xml/xml.dart';

import 'condensing.dart';
import 'score_metadata.dart';

/// A piece of text written in the score (a direction like "arco" or "dolce", a tempo mark, or
/// a rehearsal mark) that can be edited.
class ScoreText {
  const ScoreText({
    required this.id,
    required this.partId,
    required this.measure,
    required this.text,
    required this.kind,
  });

  /// Stable id: the MusicXML `<direction>` id (assigned in document order if missing), with
  /// "-reh" for a rehearsal mark.
  final String id;
  final String partId;

  /// Measure index (0-based, score order).
  final int measure;
  final String text;
  final ScoreTextKind kind;
}

enum ScoreTextKind { direction, tempo, rehearsal }

/// The MusicXML prepared for engraving: every direction has an id, text edits are applied,
/// and the players that can share a staff have one (see [Condenser]).
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
  /// built-in pairs and the user's [pairs].
  static PreparedScore prepare(XmlDocument doc, Map<String, String> edits,
      {ScoreMetadata? metadata, List<PlayerPair> pairs = const []}) {
    final texts = <ScoreText>[];
    var counter = 0;
    for (final part in doc.rootElement.findElements('part')) {
      final partId = part.getAttribute('id') ?? '';
      for (final (m, measure) in part.findElements('measure').indexed) {
        for (final direction in measure.findElements('direction')) {
          final id = direction.getAttribute('id') ?? 'cs-dir-${counter++}';
          direction.setAttribute('id', id);
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
            final edit = edits['$id-reh'];
            if (edit != null) {
              if (edit.isEmpty) {
                rehearsal.parent?.children.remove(rehearsal);
              } else {
                rehearsal.innerText = edit;
              }
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
    final options = metadata == null ? null : Condenser.options(doc, metadata);
    final condensed =
        metadata == null ? const <CondensedGroup>[] : Condenser.condense(doc, metadata, custom: pairs, options: options);
    return PreparedScore._(doc.toXmlString(), texts, condensed, options);
  }

  /// The first words element takes the new text (keeping its font and position); the rest go.
  static void _replaceWords(List<XmlElement> words, String text) {
    for (final w in words.skip(text.isEmpty ? 0 : 1)) {
      w.parent?.children.remove(w);
    }
    if (text.isNotEmpty) words.first.innerText = text;
  }
}
