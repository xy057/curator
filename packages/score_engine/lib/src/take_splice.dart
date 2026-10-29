import 'dart:math' as math;

import 'curation.dart';
import 'scroll_map.dart';
import 'search.dart';

/// A stretch of one recording heard in a [TakeSplice]: [take] (an index into its takes) from
/// [from] seconds into its file at [at] seconds of the performance, for [length] seconds
/// (infinite: to the file's end). Its sound rises from nothing over [fadeIn] and dies away over
/// [fadeOut], each centred on the edge of the region it plays ([gainAt]); an edge where the
/// performance starts or ends doesn't fade.
typedef SoundChunk = ({int take, double from, double at, double length, double fadeIn, double fadeOut});

/// How loud [chunk] is (0–1) at [seconds] of the performance: straight ramps, as SoLoud's
/// fades and FFmpeg's `afade` make them, so a crossfade sounds the same in the preview and a video.
double gainAt(SoundChunk chunk, double seconds) {
  double ramp(double past, double length) => length > 0 ? (past / length).clamp(0.0, 1.0) : (past >= 0 ? 1.0 : 0.0);
  return math.min(ramp(seconds - chunk.at, chunk.fadeIn), ramp(chunk.at + chunk.length - seconds, chunk.fadeOut));
}

/// One stretch of the performance, played straight through: score quarters [start]–[end] of
/// [pass], timed by [take]'s sync in its own pass [takePass] (from [takeFrom] to [takeTo]
/// seconds of its recording), heard from it unless [silent].
typedef _Piece = ({
  int pass,
  double start,
  double end,
  int take,
  int takePass,
  double takeFrom,
  double takeTo,
  bool silent,
});

/// A performance spliced from several recordings of the score, as their lanes say: in each
/// stretch the recording whose lane has a region there is heard, at its own tempo, and time runs
/// on from one to the next. Where no lane has a region nothing is heard, and the time goes on
/// at the tempo of the recording heard last (the first lane's before any). Regions in different
/// lanes never overlap (the app keeps them apart); were they to, the higher lane would win.
///
/// The form (which bars play, how often: [passes]) is the first recording's. A recording plays
/// a stretch the same time over as the performance does, or in its last pass to play it when
/// it plays it fewer times (as [ScoreTimelinePasses.carriedTo] carries a time).
class TakeSplice implements ScoreTimeline {
  TakeSplice._(this._takes, this._pieces, this._starts, this.chunks);

  /// [takes]' syncs (at least one) cut by [lanes] (one per take, in the same order). An edge
  /// fades over its region's transition, or [crossfade] where it sets none.
  factory TakeSplice({required List<ScoreTimeline> takes, required List<List<Region>> lanes, double crossfade = 0.3}) {
    assert(takes.isNotEmpty && lanes.length == takes.length);
    final form = takes.first;
    int? owner(double q) {
      for (final (i, lane) in lanes.indexed) {
        if (lane.any((r) => r.start <= q && q < r.end)) return i;
      }
      return null;
    }

    final pieces = <_Piece>[];
    int? last;
    for (final (k, p) in form.passes.indexed) {
      final cuts = {
        p.start,
        p.end,
        for (final lane in lanes)
          for (final r in lane) ...[r.start, r.end],
      }.where((q) => q >= p.start - 1e-9 && q <= p.end + 1e-9).toList()
        ..sort();
      for (var j = 0; j + 1 < cuts.length; j++) {
        final a = cuts[j], b = cuts[j + 1];
        if (b - a <= 1e-9) continue;
        final mid = (a + b) / 2, heard = owner(mid);
        final take = heard ?? last ?? 0;
        if (heard != null) last = heard;
        final timing = takes[take];
        final here = form.timesOf(mid).toList(), there = timing.timesOf(mid).toList();
        final time = math.max(0, here.indexWhere((t) => t.pass == k));
        final takePass = there.isEmpty ? math.min(k, timing.passes.length - 1) : there[math.min(time, there.length - 1)].pass;
        pieces.add((
          pass: k,
          start: a,
          end: b,
          take: take,
          takePass: takePass,
          takeFrom: timing.secondsAtQuarter(a, pass: takePass),
          takeTo: timing.secondsAtQuarter(b, pass: takePass),
          silent: heard == null,
        ));
      }
    }

    // When each piece starts in the performance: the first where its recording plays it.
    final starts = <double>[pieces.first.takeFrom];
    for (final p in pieces) {
      starts.add(starts.last + math.max(0, p.takeTo - p.takeFrom));
    }

    // The sound: each run of pieces one recording plays straight on, faded at its regions' edges.
    Region? regionAt(int take, double q, {required bool start}) =>
        lanes[take].where((r) => ((start ? r.start : r.end) - q).abs() < 1e-6).firstOrNull;
    final chunks = <SoundChunk>[];
    for (var i = 0; i < pieces.length; i++) {
      final first = pieces[i];
      if (first.silent) continue;
      var j = i;
      while (j + 1 < pieces.length &&
          !pieces[j + 1].silent &&
          pieces[j + 1].take == first.take &&
          (pieces[j + 1].takeFrom - pieces[j].takeTo).abs() < 1e-6) {
        j++;
      }
      final lastPiece = pieces[j];
      final openStart = i == 0 && first.start <= form.passes.first.start + 1e-9;
      final openEnd = j == pieces.length - 1 && lastPiece.end >= form.passes.last.end - 1e-9;
      final fadeIn = openStart ? 0.0 : regionAt(first.take, first.start, start: true)?.transitionIn ?? crossfade;
      final fadeOut = openEnd ? 0.0 : regionAt(first.take, lastPiece.end, start: false)?.transitionOut ?? crossfade;
      // Open at the start: from the very start of its file, so a lead-in is heard.
      var from = openStart ? 0.0 : first.takeFrom - fadeIn / 2;
      var at = openStart ? starts[i] - first.takeFrom : starts[i] - fadeIn / 2;
      if (from < 0) {
        at -= from;
        from = 0;
      }
      final end = openEnd ? double.infinity : starts[j + 1] + fadeOut / 2;
      chunks.add((take: first.take, from: from, at: at, length: end - at, fadeIn: fadeIn, fadeOut: fadeOut));
      i = j;
    }
    return TakeSplice._(takes, pieces, starts, List.unmodifiable(chunks));
  }

  final List<ScoreTimeline> _takes;
  final List<_Piece> _pieces;

  /// When each piece starts, and the last ends.
  final List<double> _starts;

  /// What is heard, in order of [SoundChunk.at].
  final List<SoundChunk> chunks;

  @override
  List<double> get measureStarts => _takes.first.measureStarts;

  @override
  List<ScorePass> get passes => _takes.first.passes;

  int _pieceAt(double seconds) {
    if (seconds <= _starts.first) return 0;
    if (seconds >= _starts.last) return _pieces.length - 1;
    return segmentAt(_starts.length, seconds, (i) => _starts[i]);
  }

  @override
  int passAt(double seconds) => _pieces[_pieceAt(seconds)].pass;

  /// The piece of [pass] that plays [quarter]; outside it, its first or last.
  int _pieceOf(double quarter, int pass) {
    pass = pass.clamp(0, passes.length - 1);
    int? first, last;
    for (final (i, p) in _pieces.indexed) {
      if (p.pass != pass) continue;
      first ??= i;
      last = i;
      if (quarter >= p.start - 1e-9 && quarter < p.end - 1e-9) return i;
    }
    return quarter < _pieces[first!].start ? first : last!;
  }

  double _secondsIn(int i, double quarter) {
    final p = _pieces[i];
    return _starts[i] + _takes[p.take].secondsAtQuarter(quarter, pass: p.takePass) - p.takeFrom;
  }

  @override
  double secondsAtQuarter(double quarter, {int pass = 0}) => _secondsIn(_pieceOf(quarter, pass), quarter);

  @override
  double quarterAtSeconds(double seconds) {
    final i = _pieceAt(seconds), p = _pieces[i];
    final q = _takes[p.take].quarterAtSeconds(p.takeFrom + seconds - _starts[i]);
    // Inside, a piece plays its own bars only (a recording's own warp at its end is the next piece's).
    final inside = seconds > _starts.first && seconds < _starts.last;
    return inside ? q.clamp(p.start, p.end) : q;
  }

  @override
  double secondsAt(MusicalPosition position, {int pass = 0}) {
    final start = position.measure < measureStarts.length ? measureStarts[position.measure] : 0.0;
    return secondsAtQuarter(start + position.beat, pass: pass);
  }
}
