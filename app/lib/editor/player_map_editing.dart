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

  /// Seats the score's instruments as [preset] places them, in place of the project's map: one
  /// Undo step.
  void seat(SeatingPreset preset) => set(smart(preset));

  /// [map] (a file's, from another score perhaps) made this score's: its links found again by
  /// name, else by id.
  PlayerMap fitted(PlayerMap map) => map.relinked(parts, nameOf: nameOf);

  // MARK: Pulses

  /// The score's notes (unpitched ones too) as loud as its dynamics have them, read on another
  /// isolate for the score they belong to; null while being read; none for a PDF's score.
  ({String xml, PlayerNotes notes})? _notes;
  String? _reading;

  /// How swollen players are at each time, whatever map they are in (the project's, or the one
  /// its editor has): [PlayerPulses.none] until the notes have been read (they are read the first
  /// time this is asked while there is a map), made again only when the notes or the performance
  /// change, which costs nothing ([PlayerPulses]).
  PlayerPulses get pulses {
    final score = _editor._score;
    if (score == null || map == null || !_editor.hasNotes) return PlayerPulses.none;
    final notes = _notes;
    if (notes == null || !identical(notes.xml, score.musicXML) && notes.xml != score.musicXML) {
      _read(score);
      return PlayerPulses.none;
    }
    final timeline = _editor.timeline;
    if (_pulses case (final n, final t, final p) when identical(n, notes.notes) && identical(t, timeline)) return p;
    final pulses = PlayerPulses(notes.notes, timeline);
    _pulses = (notes.notes, timeline, pulses);
    return pulses;
  }

  (PlayerNotes, ScoreTimeline, PlayerPulses)? _pulses;

  /// The score's notes as [pulses] reads them, for a performance of another timeline (a video's):
  /// those read already, else read now. None while there is no map, or no notes.
  Future<PlayerNotes> notes() async {
    final score = _editor._score;
    if (score == null || map == null || !_editor.hasNotes) return PlayerNotes.none;
    final kept = _notes;
    if (kept != null && (identical(kept.xml, score.musicXML) || kept.xml == score.musicXML)) return kept.notes;
    try {
      return await _notesOff(score.musicXML, score.timeline.measureStarts);
    } catch (e) {
      debugPrint('Player map: the notes couldn’t be read: $e');
      return PlayerNotes.none;
    }
  }

  /// Static, so the isolate is sent the score's text and bars alone, never the controller.
  static Future<PlayerNotes> _notesOff(String xml, List<double> starts) =>
      Isolate.run(() => PlayerNotes.ofScore(xml, starts));

  void _read(LoadedScore score) {
    final xml = score.musicXML;
    if (_reading == xml) return;
    _reading = xml;
    final starts = score.timeline.measureStarts;
    unawaited(_notesOff(xml, starts).then((read) {
      if (_editor._disposed || _reading != xml) return;
      _notes = (xml: xml, notes: read);
      _reading = null;
      _editor.playback._markDirty();
      _editor._changed();
    }, onError: (Object e) {
      // A score that can't be read for its notes swells nothing.
      debugPrint('Player map: the notes couldn’t be read: $e');
      if (_editor._disposed || _reading != xml) return;
      _notes = (xml: xml, notes: PlayerNotes.none);
      _reading = null;
    }));
  }
}
