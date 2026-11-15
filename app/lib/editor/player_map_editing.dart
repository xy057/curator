part of '../editor_controller.dart';

/// The player map (View ▸ Show Player Map): where the players sit, which instrument and staff
/// each plays ([PlayerMap], the project's, so opening, Undo and closing take it), and how swollen
/// each is at a time ([pulses]: the score's notes as the performance plays them).
class PlayerMapEditing {
  PlayerMapEditing._(this._editor);
  final EditorController _editor;

  /// The project's map; null while it has none.
  PlayerMap? get map => _editor._doc.playerMap;

  /// Makes [map] the project's (null: none): one Undo step.
  void set(PlayerMap? map) {
    if (map == this.map) return;
    _editor._doc = _editor._doc.copyWith(playerMap: map);
    _editor._edited();
  }

  /// The instruments a player can play, in the score's order: no spacers, condensed staves or a
  /// PDF's blank lanes.
  List<ScorePart> get parts {
    final score = _editor._score;
    if (score == null) return const [];
    return [
      for (final p in score.metadata.parts)
        if (!Spacers.isSpacer(p.id) && !p.id.startsWith(Condenser.idPrefix) && !_editor.isBlankLane(p.id)) p,
    ];
  }

  /// [part]'s name as the project shows it.
  String nameOf(ScorePart part) => _editor.partName(part);

  /// A link to [part]'s staff [staff] (null: all of it), named as the project names it.
  PlayerLink linkTo(ScorePart part, {int? staff}) => PlayerLink(part.id, staff: staff, name: nameOf(part));

  /// The score's instruments seated as [preset] places them.
  PlayerMap smart(SeatingPreset preset) => PlayerMap.smart(parts, preset: preset, nameOf: nameOf);

  /// [map] (a file's, from another score perhaps) made this score's: its links found again by
  /// name, else by id.
  PlayerMap fitted(PlayerMap map) => map.relinked(parts, nameOf: nameOf);

  // MARK: Pulses

  /// The score's notes (unpitched ones too), read on another isolate for the score they belong
  /// to; empty while being read, and for a PDF's score, which has none.
  ({String xml, List<SoundingNote> notes})? _notes;
  String? _reading;

  /// How swollen the map's players are at each time: [PlayerPulses.none] until the notes have
  /// been read (they are read the first time this is asked), worked out again only when the
  /// notes, the performance or what the map links change.
  PlayerPulses get pulses {
    final score = _editor._score, map = this.map;
    if (score == null || map == null || _editor.isPdf) return PlayerPulses.none;
    final notes = _notes;
    if (notes == null || !identical(notes.xml, score.musicXML) && notes.xml != score.musicXML) {
      _read(score);
      return PlayerPulses.none;
    }
    final timeline = _editor.timeline, links = map.links;
    if (_pulses case (final n, final t, final l, final p) when identical(n, notes.notes) && identical(t, timeline) && setEquals(l, links)) {
      return p;
    }
    final pulses = PlayerPulses.of(notes.notes, timeline, links);
    _pulses = (notes.notes, timeline, links, pulses);
    return pulses;
  }

  (List<SoundingNote>, ScoreTimeline, Set<PlayerLink>, PlayerPulses)? _pulses;

  /// Static, so the isolate is sent the score's text and bars alone, never the controller.
  static Future<List<SoundingNote>> _notesOff(String xml, List<double> starts) =>
      Isolate.run(() => soundingNotes(xml, starts, unpitched: true).toList());

  void _read(LoadedScore score) {
    final xml = score.musicXML;
    if (_reading == xml) return;
    _reading = xml;
    final starts = score.timeline.measureStarts;
    unawaited(_notesOff(xml, starts).then((notes) {
      if (_editor._disposed || _reading != xml) return;
      _notes = (xml: xml, notes: notes);
      _reading = null;
      _editor.playback._markDirty();
      _editor._changed();
    }, onError: (Object e) {
      // A score that can't be read for its notes swells nothing.
      debugPrint('Player map: the notes couldn’t be read: $e');
      if (_editor._disposed || _reading != xml) return;
      _notes = (xml: xml, notes: const []);
      _reading = null;
    }));
  }
}
