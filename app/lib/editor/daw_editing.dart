part of '../editor_controller.dart';

/// What a project follows of a DAW through Attacca (see docs/daw-link.md): the recording
/// [source] of the DAW document [document] (its region [region] in the song, or the first
/// playing it), the score's bar 1 at the DAW's bar [bar], and, with [transport], where the DAW
/// plays.
typedef DawFollow = ({String document, String source, String? region, int bar, bool transport});

/// Following a DAW (Attacca): the sync takes the tempo map of the DAW's song where the
/// recording followed is placed in it, as it follows a MIDI file's ([EditorController.followTempoMap]),
/// now and again each time the DAW sends its document changed; and while the DAW plays, the
/// playhead goes where it is in the recording ([Playback]'s DAW clock). Lasts while the project
/// is open and the DAW is there; the tempo map taken is the project's as any is. A tempo map
/// chosen or edited here, or anchors, end it.
class DawEditing {
  DawEditing._(this._editor);

  final EditorController _editor;
  DawLink? _link;
  DawFollow? _follow;
  DawSession? _session;

  /// The project's name, told the DAW followed (its Attacca window shows it).
  String get name => _name;
  String _name = '';
  set name(String value) {
    if (value == _name) return;
    _name = value;
    _tell();
  }

  /// [_link] told what this project follows, if anything.
  void _tell() {
    final f = _follow;
    _link?.followedBy(this, f == null ? null : (document: f.document, name: _name));
  }

  /// What is followed, or null.
  DawFollow? get following => _follow;

  /// The DAW document followed and its DAW, as last sent; null when it is gone (or nothing is
  /// followed).
  (DawSession, DawDocument)? get document => _follow == null ? null : _link?.find(_follow!.document);

  /// Starts following [follow] in [link]'s DAWs, taking its tempo now; false (following
  /// nonetheless, for when it comes) when the DAW gives no tempo for it.
  bool follow(DawLink link, DawFollow follow) {
    stop();
    _link = link;
    _follow = follow;
    link.addListener(_linkChanged);
    _tell();
    _watchTransport();
    final taken = _take();
    _editor._changed();
    return taken;
  }

  /// Stops following (the tempo map taken stays).
  void stop() {
    if (_follow == null) return;
    _link?.removeListener(_linkChanged);
    _link?.followedBy(this, null);
    _session?.transport.removeListener(_transportChanged);
    _session = null;
    _follow = null;
    _editor.playback._dawStopped();
    _editor._changed();
  }

  void _linkChanged() {
    _watchTransport();
    if (document == null) {
      _editor.playback._dawStopped(); // the DAW is gone: the playhead stays where it was
      return;
    }
    _take();
  }

  /// The region followed in the document as it is.
  DawRegion? _regionIn(DawDocument d) => d.region(_follow!.region) ?? d.regionsOf(_follow!.source).firstOrNull;

  /// Where the score's first full bar starts: an upbeat's length, else 0.
  double get _pickup {
    final score = _editor._score;
    if (score == null || !score.metadata.pickups.contains(0)) return 0;
    final starts = score.timeline.measureStarts;
    return starts.length > 1 ? starts[1] : 0;
  }

  /// The DAW's tempo for the region followed, into the sync (when it differs from what it follows).
  bool _take() {
    final f = _follow, found = document;
    if (f == null || found == null) return false;
    final (session, doc) = found;
    final region = _regionIn(doc);
    if (region == null) return false;
    final track = doc.track(region.track);
    final context = doc.context(track?.context);
    final name = [if (session.host.isNotEmpty) session.host, if (track != null && track.name.isNotEmpty) track.name else region.name].join(' · ');
    final tempo = context?.tempoFor(region, name: name, bar: f.bar, pickup: _pickup);
    if (tempo == null) return false;
    _editor.followTempoMap(tempo.map, start: tempo.start);
    return true;
  }

  void _watchTransport() {
    final session = document?.$1;
    if (session == _session) return;
    _session?.transport.removeListener(_transportChanged);
    _session = session;
    session?.transport.addListener(_transportChanged);
  }

  void _transportChanged() {
    final f = _follow, t = _session?.transport.value, found = document;
    if (f == null || !f.transport || t == null || found == null) return;
    final region = found.$2.regionAt(f.source, t.seconds);
    if (region == null) return;
    _editor.playback._fromDaw(playing: t.playing, seconds: region.sourceAt(t.seconds));
  }
}
