import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'display_list.dart';
import 'engraving.dart';
import 'lilypond_svg.dart';
import 'native/constants.dart';
import 'score_metadata.dart';
import 'spacers.dart';

/// Where something drawn came from in a LilyPond score's source: what a click on it jumps to.
class LilyLink {
  const LilyLink({required this.staff, required this.bounds, required this.file, required this.line, required this.column});

  /// The staff it is drawn on (0: a barline, which every staff draws).
  final int staff;

  /// Where its ink is, device units.
  final ui.Rect bounds;

  /// The file as LilyPond named it, its line (1 the first) and the character in that line (0
  /// the first).
  final String file;
  final int line, column;
}

/// A score LilyPond engraved with Curator's settings (the app's `assets/lilypond/curator.ly`):
/// the whole piece on one endless line, its SVG drawn into Curator's own engraving (so it takes
/// the ink, dark mode, the frozen zone and every other look an engraved score does) and what it
/// is (its staves, bars, notes and marks, from the data file the settings write) written out as
/// MusicXML (so it plays, curates, aligns and is searched as any other score).
class LilyPondScore {
  LilyPondScore._(
      {required this.engraving,
      required this.musicXML,
      required this.links,
      required this._keys,
      required this._keyShift,
      required this._times,
      required this._barlineCommands,
      required this._timeCommands,
      required this._referenceTop});

  /// Device units a staff space (LilyPond's SVG measures in staff spaces).
  static const unit = 20.0;

  /// The score's own staves as drawn (a vertical spacer's are added by [engravingWith]).
  final EngravingData engraving;

  /// What the score is, as a score written for it ([ScoreMetadata] reads it).
  final String musicXML;

  /// Every drawn thing that says where it came from in the source, left to right.
  final List<LilyLink> links;

  // What a vertical spacer's staff is drawn with: the key signatures of the first staff that
  // has any (as written, x and fifths) and how many fifths its transposition takes off for the
  // concert key; the time signatures; that staff's barlines' and time changes' commands, and
  // where its top line is.
  final List<({double x, int fifths})> _keys;
  final int _keyShift;
  final List<TimeSignature> _times;
  final List<int> _barlineCommands, _timeCommands;
  final double _referenceTop;

  /// Reads LilyPond's [svg] and the [data] file its run with Curator's settings wrote. Throws a
  /// [FormatException] when they hold no score.
  static LilyPondScore read(String svg, String data) => _Reader(data, readLilyPondSvg(svg, unit: unit)).read();

  /// The link drawn nearest [point] on [staff] (0: on any), within [slack] device units; null
  /// when there is none.
  LilyLink? linkAt(ui.Offset point, {int staff = 0, double slack = unit / 2}) {
    LilyLink? best;
    var bestDistance = slack;
    for (final link in links) {
      if (staff != 0 && link.staff != staff && link.staff != 0) continue;
      final b = link.bounds;
      if (point.dx < b.left - slack || point.dx > b.right + slack) continue;
      final dx = math.max(0.0, math.max(b.left - point.dx, point.dx - b.right));
      final dy = math.max(0.0, math.max(b.top - point.dy, point.dy - b.bottom));
      final distance = math.sqrt(dx * dx + dy * dy);
      // Inside two things (a note on its stem): the smaller.
      if (distance < bestDistance ||
          (distance == 0 && bestDistance == 0 && best != null && b.width * b.height < best.bounds.width * best.bounds.height)) {
        best = link;
        bestDistance = distance;
      }
    }
    return best;
  }

  /// [engraving] with a staff for each of [metadata]'s vertical spacers ([Spacers.write]'s parts,
  /// after the score's own), as Verovio would engrave one: its lines, the score's barlines and
  /// time changes, and the clef, key and time signatures the frozen zone shows ([spacers]: their
  /// keys).
  EngravingData engravingWith(ScoreMetadata metadata, List<VerticalSpacer> spacers) {
    final added = [
      for (final p in metadata.parts)
        if (Spacers.isSpacer(p.id)) (part: p, spacer: spacers.where((s) => s.id == p.id).firstOrNull ?? VerticalSpacer(id: p.id)),
    ];
    if (added.isEmpty) return engraving;
    final data = engraving;
    final commands = _CommandWriter.from(data);
    final staves = [...data.staves];
    final signatures = [...data.signatures];
    var bottom = staves.fold(0.0, (b, s) => math.max(b, s.top + s.height));
    final lines = data.staves.isEmpty ? (left: 0.0, right: data.width) : _lineExtent(data);
    final thickness = _lineThickness(data);
    for (final (:part, :spacer) in added) {
      final n = part.staffNumbers.first, top = bottom + 10 * unit;
      bottom = top + 4 * unit;
      staves.add(StaffInfo(n: n, top: top, height: 4 * unit, lines: 5));
      for (var k = 0; k < 5; k++) {
        commands.line(n, 'staff', lines.left, top + k * unit, lines.right, thickness);
      }
      final dy = top - _referenceTop;
      for (final i in _barlineCommands) {
        commands.copy(data, i, staff: 0, dy: dy);
      }
      for (final i in _timeCommands) {
        commands.copy(data, i, staff: n, dy: dy);
      }
      signatures.add(ClefSignature(staff: n, x: 0, commandStart: 0, commandCount: 0, shape: ClefShape.g, line: 2, octave: 0));
      for (final k in _keys) {
        signatures.add(KeySignature(staff: n, x: k.x, commandStart: 0, commandCount: 0, fifths: spacer.key.keyOf(k.fifths - _keyShift)));
      }
      for (final t in _times) {
        signatures.add(TimeSignature(
            staff: n,
            x: t.x,
            commandStart: 0,
            commandCount: 0,
            count: t.count,
            unit: t.unit,
            symbol: t.symbol,
            summands: t.summands));
      }
    }
    signatures.sort((a, b) => a.x.compareTo(b.x));
    return commands.build(data, staves: staves, signatures: signatures);
  }

  static ({double left, double right}) _lineExtent(EngravingData data) {
    var left = double.infinity, right = -double.infinity;
    final staff = data.classNames.indexOf('staff');
    for (var i = 0; i < data.commandCount; i++) {
      final base = i * Cmd.words;
      if (data.commandInts[base + Cmd.classIndex] != staff) continue;
      final e = data.commandInts[base + Cmd.start];
      left = math.min(left, math.min(data.pathFloats[e * 7 + 1], data.pathFloats[(e + 1) * 7 + 1]));
      right = math.max(right, math.max(data.pathFloats[e * 7 + 1], data.pathFloats[(e + 1) * 7 + 1]));
    }
    return left > right ? (left: 0.0, right: data.width) : (left: left, right: right);
  }

  static double _lineThickness(EngravingData data) {
    final staff = data.classNames.indexOf('staff');
    for (var i = 0; i < data.commandCount; i++) {
      if (data.commandInts[i * Cmd.words + Cmd.classIndex] == staff) return data.commandFloats[i * Cmd.words + Cmd.strokeWidth];
    }
    return 0.1 * unit;
  }
}

/// An exact time or length in whole notes, as LilyPond writes them ("3/8", "-1/4", "5").
class _Q implements Comparable<_Q> {
  factory _Q(int n, int d) {
    if (d < 0) (n, d) = (-n, -d);
    final g = n.gcd(d);
    return g <= 1 ? _Q._(n, d) : _Q._(n ~/ g, d ~/ g);
  }
  const _Q._(this.n, this.d);
  static const zero = _Q._(0, 1);
  final int n, d;

  static _Q? parse(Object? text) {
    if (text is int) return _Q._(text, 1);
    if (text is! String) return null;
    final s = text.trim(), slash = s.indexOf('/');
    if (slash < 0) return int.tryParse(s) == null ? null : _Q._(int.parse(s), 1);
    final n = int.tryParse(s.substring(0, slash)), d = int.tryParse(s.substring(slash + 1));
    return n == null || d == null || d == 0 ? null : _Q(n, d);
  }

  _Q operator +(_Q o) => _Q(n * o.d + o.n * d, d * o.d);
  _Q operator -(_Q o) => _Q(n * o.d - o.n * d, d * o.d);
  _Q operator *(_Q o) => _Q(n * o.n, d * o.d);
  bool operator <(_Q o) => n * o.d < o.n * d;
  bool operator <=(_Q o) => n * o.d <= o.n * d;
  bool operator >(_Q o) => n * o.d > o.n * d;
  bool operator >=(_Q o) => n * o.d >= o.n * d;
  double get value => n / d;

  @override
  int compareTo(_Q o) => (n * o.d).compareTo(o.n * d);
  @override
  bool operator ==(Object o) => o is _Q && o.n == n && o.d == d;
  @override
  int get hashCode => Object.hash(n, d);
  @override
  String toString() => d == 1 ? '$n' : '$n/$d';
}

typedef _Rec = Map<String, Object?>;

class _Ctx {
  _Ctx(this.name, this.id, this.parent);
  final String name, id;
  final int parent;
}

/// A clef, key or time signature as the data file says it, with where it is drawn.
class _Sig {
  _Sig(this.record, this.moment, this.signature);
  final _Rec record;
  final _Q moment;
  final Signature signature;
}

/// Builds the recorded commands of an engraving.
class _CommandWriter {
  _CommandWriter();

  /// One that adds to [data]'s commands.
  factory _CommandWriter.from(EngravingData data) {
    final w = _CommandWriter();
    w._ints.addAll(data.commandInts);
    w._paths.addAll(data.pathInts);
    w._text.add(data.text);
    w.classNames.addAll(data.classNames);
    w.sourceIds.addAll(data.sourceIds);
    return w;
  }

  // The words as ints; floats are stored as their bits.
  final _ints = <int>[];
  final _paths = <int>[];
  final _text = BytesBuilder(copy: false);
  final classNames = <String>[];
  final sourceIds = <String>[];
  static final _bits = ByteData(4);

  int get count => _ints.length ~/ Cmd.words;

  static int _f(double v) => (_bits..setFloat32(0, v)).getInt32(0);

  int classOf(String name) {
    final i = classNames.indexOf(name);
    if (i >= 0) return i;
    classNames.add(name);
    return classNames.length - 1;
  }

  int sourceOf(String? id) {
    if (id == null) return -1;
    final i = sourceIds.indexOf(id);
    if (i >= 0) return i;
    sourceIds.add(id);
    return sourceIds.length - 1;
  }

  void _command({
    required int kind,
    required int staff,
    required int flags,
    required int classIndex,
    double strokeWidth = 0,
    double dash = 0,
    double gap = 0,
    double x = 0,
    double y = 0,
    double size = 0,
    int alignment = 0,
    int start = 0,
    int count = 0,
    ui.Rect bounds = ui.Rect.zero,
    int source = -1,
  }) {
    _ints.addAll([
      kind, staff, flags, classIndex, _f(strokeWidth), _f(dash), _f(gap), _f(x), _f(y), _f(size), 0, alignment, start, count, 0, //
      _f(bounds.left), _f(bounds.top), _f(bounds.width), _f(bounds.height), source, _f(0), _f(0),
    ]);
  }

  void path(int staff, int classIndex, LilyPath p, {int source = -1}) {
    final start = _paths.length ~/ 7;
    for (var i = 0; i < p.ops.length; i++) {
      _paths.add(p.ops[i]);
      for (var k = 0; k < 6; k++) {
        _paths.add(_f(p.points[i * 6 + k]));
      }
    }
    _command(
        kind: VBKind.path,
        staff: staff,
        flags: (p.fill ? VBFlag.fill : 0) | (p.stroke ? VBFlag.stroke | p.flags : 0),
        classIndex: classIndex,
        strokeWidth: p.width,
        dash: p.dash,
        gap: p.gap,
        start: start,
        count: p.ops.length,
        bounds: p.bounds,
        source: source);
  }

  /// A plain stroke from ([x0], [y]) to ([x1], [y]): what the display list takes for a staff line.
  void line(int staff, String className, double x0, double y, double x1, double width) {
    final start = _paths.length ~/ 7;
    _paths.addAll([VBPathOp.move, _f(x0), _f(y), 0, 0, 0, 0, VBPathOp.line, _f(x1), _f(y), 0, 0, 0, 0]);
    _command(
        kind: VBKind.path,
        staff: staff,
        flags: VBFlag.stroke,
        classIndex: classOf(className),
        strokeWidth: width,
        start: start,
        count: 2,
        bounds: ui.Rect.fromLTRB(x0, y - width / 2, x1, y + width / 2));
  }

  void text(int staff, int classIndex, LilyText t, {int source = -1}) {
    final bytes = utf8.encode(t.text);
    final start = _text.length;
    _text.add(bytes);
    _command(
        kind: VBKind.text,
        staff: staff,
        flags: VBFlag.newTextBlock | (t.italic ? VBFlag.italic : 0) | (t.bold ? VBFlag.bold : 0),
        classIndex: classIndex,
        x: t.x,
        y: t.y,
        size: t.size,
        alignment: t.anchor,
        start: start,
        count: bytes.length,
        bounds: t.bounds,
        source: source);
  }

  /// [data]'s command [i] again, on [staff], [dy] lower.
  void copy(EngravingData data, int i, {required int staff, required double dy}) {
    final base = i * Cmd.words;
    final words = [for (var k = 0; k < Cmd.words; k++) data.commandInts[base + k]];
    words[Cmd.staff] = staff;
    double float(int k) => data.commandFloats[base + k];
    words[Cmd.y] = _f(float(Cmd.y) + dy);
    words[Cmd.bounds + 1] = _f(float(Cmd.bounds + 1) + dy);
    if (data.commandInts[base + Cmd.kind] == VBKind.path) {
      final start = data.commandInts[base + Cmd.start], count = data.commandInts[base + Cmd.count];
      words[Cmd.start] = _paths.length ~/ 7;
      for (var e = start; e < start + count; e++) {
        final op = data.pathInts[e * 7];
        _paths.add(op);
        for (var k = 0; k < 6; k++) {
          final v = data.pathFloats[e * 7 + 1 + k];
          // The y of each point (an ellipse's box: its top).
          _paths.add(_f(k.isOdd && (op != VBPathOp.ellipse || k == 1) ? v + dy : v));
        }
      }
    } else if (data.commandInts[base + Cmd.kind] == VBKind.text) {
      final bytes = data.text.sublist(data.commandInts[base + Cmd.start], data.commandInts[base + Cmd.start] + data.commandInts[base + Cmd.count]);
      words[Cmd.start] = _text.length;
      _text.add(bytes);
    }
    _ints.addAll(words);
  }

  EngravingData build(EngravingData? like,
      {double? width,
      List<StaffInfo>? staves,
      List<MeasureLayout>? measures,
      List<Signature>? signatures,
      List<String>? warnings,
      Map<String, double>? engravingDefaults}) {
    final commands = Uint8List(_ints.length * 4), paths = Uint8List(_paths.length * 4);
    commands.buffer.asInt32List().setAll(0, _ints);
    paths.buffer.asInt32List().setAll(0, _paths);
    return EngravingData(
      width: width ?? like!.width,
      staffSpace: LilyPondScore.unit,
      staves: staves ?? like!.staves,
      measures: measures ?? like!.measures,
      commandBytes: commands,
      pathBytes: paths,
      text: _text.toBytes(),
      classNames: List.unmodifiable(classNames),
      fontNames: const ['serif'],
      signatures: List.unmodifiable(signatures ?? like!.signatures),
      sourceIds: List.unmodifiable(sourceIds),
      warnings: warnings ?? like!.warnings,
      engravingDefaults: engravingDefaults ?? like?.engravingDefaults ?? const {},
    );
  }
}

class _Reader {
  _Reader(String data, this.groups) {
    for (final line in const LineSplitter().convert(data)) {
      if (line.trim().isEmpty) continue;
      final Object? decoded;
      try {
        decoded = jsonDecode(line);
      } on FormatException {
        continue;
      }
      if (decoded is! Map<String, Object?>) continue;
      final score = decoded['s'];
      if (score is int && score > 0) {
        scores = math.max(scores, score + 1);
        continue;
      }
      if (score != 0) continue;
      final kind = decoded['t'];
      switch (kind) {
        case 'ctx':
          contexts[_int(decoded['k'])] = _Ctx('${decoded['n'] ?? ''}', '${decoded['id'] ?? ''}', _int(decoded['p']));
        case 'measure':
          measureRecords.add(decoded);
        case 'end':
          end = _Q.parse(decoded['m']);
        case 'span':
          voltaEnds[_int(decoded['c'])] = _Q.parse(decoded['end']);
        case 'tie':
          tieStarts.add(_int(decoded['from']));
          tieStops.add(_int(decoded['to']));
        case 'error':
          break;
        case 'VerticalAxisGroup':
          affinity[_int(decoded['l'])] = '${decoded['aff'] ?? ''}';
        default:
          if (kind == 'StaffSymbol') staffLines.add(_int(decoded['l']));
          records.add(decoded);
          byGrob[_int(decoded['c'])] = decoded;
      }
    }
    for (final g in groups) {
      if (g.shapes.isNotEmpty) drawn[g.id] = g;
    }
  }

  static const unit = LilyPondScore.unit;

  final List<LilyGroup> groups;
  final drawn = <int, LilyGroup>{};
  final contexts = <int, _Ctx>{};
  final affinity = <int, String>{};
  final staffLines = <int>{};
  final records = <_Rec>[];
  final byGrob = <int, _Rec>{};
  final measureRecords = <_Rec>[];
  final voltaEnds = <int, _Q?>{};

  /// The notes ties start at and end at (their grob numbers).
  final tieStarts = <int>{}, tieStops = <int>{};
  _Q? end;
  var scores = 1;

  static int _int(Object? v) => v is int ? v : (v is num ? v.toInt() : int.tryParse('$v') ?? -1);
  static _Q _moment(_Rec r) => _Q.parse(r['m']) ?? _Q.zero;
  static bool _grace(_Rec r) => (_Q.parse(r['g']) ?? _Q.zero) != _Q.zero;

  // Staves: line key → where its lines are; then numbered, part by part.
  final staffAt = <int, ({double top, double bottom, int lines, double left, double right, double thickness})>{};
  final staffNumber = <int, int>{}; // staff line key → staff number
  final parts = <({int key, List<int> staves})>[]; // a part's context key and its staves' line keys
  final lineStaff = <int, int>{}; // any line key → the staff it is drawn with

  LilyPondScore read() {
    _staves();
    if (staffNumber.isEmpty) throw const FormatException('LilyPond drew no staff.');
    _lines();

    final starts = _measureStarts();
    final finish = _finish(starts);
    final onsets = _onsets();
    final xs = _boundaries(starts, finish, onsets);

    // The drawing, in order, each group's commands kept together ([Signature]s take ranges).
    final w = _CommandWriter();
    final ranges = <int, ({int start, int count})>{};
    final links = <LilyLink>[];
    final barlineCommands = <int>[];
    final reference = parts.first.staves.first; // whose barlines and time changes a spacer copies
    final timeCommands = <int>[];
    for (final (g, clef) in _ordered()) {
      if (_skipped.contains(g.kind)) continue;
      final start = w.count;
      final staff = g.kind == 'BarLine' ? 0 : _staffOf(g);
      if (g.kind == 'StaffSymbol') {
        for (final s in g.shapes) {
          if (s is! LilyPath || !s.isHorizontalLine) continue;
          final y = s.points[1], x0 = math.min(s.points[0], s.points[6]), x1 = math.max(s.points[0], s.points[6]);
          // LilyPond's lines have round caps, set in by half their width: as long, with none.
          final cap = s.flags & VBFlag.roundCap != 0 ? s.width / 2 : 0.0;
          w.line(staff, 'staff', x0 - cap, y, x1 + cap, s.width);
        }
      } else {
        final classIndex = w.classOf(switch (g.kind) {
          'BarLine' => 'barLine',
          'KeySignature' || 'KeyCancellation' => 'keySig',
          final kind => kind,
        });
        final source = w.sourceOf(_sourceId(g));
        for (final s in g.shapes) {
          switch (s) {
            case LilyPath():
              w.path(staff, classIndex, s, source: source);
            case LilyText():
              w.text(staff, classIndex, s, source: source);
          }
        }
      }
      ranges[g.id] = (start: start, count: w.count - start);
      // A clef's 8 is drawn (and hidden) with it.
      if (ranges[clef] case final owner?) ranges[clef!] = (start: owner.start, count: w.count - owner.start);
      if (g.kind == 'BarLine' && g.line == reference) {
        for (var i = start; i < w.count; i++) {
          barlineCommands.add(i);
        }
      }
      if (g.kind == 'TimeSignature' && g.line == reference && _moment(byGrob[g.id] ?? const {}) != starts.first) {
        for (var i = start; i < w.count; i++) {
          timeCommands.add(i);
        }
      }
      if (g.sourceLine case final line?) {
        links.add(LilyLink(staff: staff, bounds: g.bounds, file: g.file ?? '', line: line, column: g.column ?? 0));
      }
    }
    links.sort((a, b) => a.bounds.left.compareTo(b.bounds.left));

    final measures = <MeasureLayout>[
      for (final (i, start) in starts.indexed)
        () {
          final next = i + 1 < starts.length ? starts[i + 1] : finish;
          final times = <double>[], at = <double>[];
          for (final (moment, x) in onsets) {
            if (moment >= start && moment < next) {
              times.add((moment - start).value * 4);
              at.add(x);
            }
          }
          return MeasureLayout(
              left: xs[i],
              right: xs[i + 1],
              duration: (next - start).value * 4,
              onsetTimes: Float64List.fromList(times),
              onsetXs: Float64List.fromList(at));
        }(),
    ];

    final sigs = _signatures(ranges, starts, xs);
    final staves = [
      for (final MapEntry(key: line, value: n) in staffNumber.entries)
        StaffInfo(n: n, top: staffAt[line]!.top, height: staffAt[line]!.bottom - staffAt[line]!.top, lines: staffAt[line]!.lines),
    ]..sort((a, b) => a.n.compareTo(b.n));
    var right = xs.last;
    for (final g in drawn.values) {
      if (!_skipped.contains(g.kind)) right = math.max(right, g.bounds.right);
    }
    final barWidth = [
      for (final r in records)
        if (r['t'] == 'BarLine' && r['glyph'] == '|')
          if (drawn[_int(r['c'])]?.shapes.firstOrNull case final LilyPath p when p.rect) p.bounds.width,
    ].firstOrNull;
    final engraving = w.build(null,
        width: right + 2 * unit,
        staves: staves,
        measures: measures,
        signatures: [for (final s in sigs) s.signature]..sort((a, b) => a.x.compareTo(b.x)),
        warnings: [if (scores > 1) 'Only the first score of the file is shown.'],
        engravingDefaults: {
          'staffLineThickness': (staffAt.values.firstOrNull?.thickness ?? 0.1 * unit) / unit,
          'thinBarlineThickness': (barWidth ?? 0.19 * unit) / unit,
        });

    // What a spacer copies: the reference staff's keys (concert fifths come from its
    // transposition) and times.
    final keyStaff = staffNumber.keys.firstWhere(
        (line) => sigs.any((s) => s.signature is KeySignature && s.record['l'] == line),
        orElse: () => reference);
    // (Written less concert: a B♭ clarinet's D major is C, two sharps more.)
    final keyShift = -_fifthsOf(_transposition(keyStaff)?.semitones ?? 0);
    return LilyPondScore._(
      engraving: engraving,
      musicXML: _MusicXmlWriter(this, starts, finish, sigs).write(),
      links: List.unmodifiable(links),
      keys: [
        for (final s in sigs)
          if (s.signature case final KeySignature k when s.record['l'] == keyStaff) (x: k.x, fifths: k.fifths),
      ],
      keyShift: keyShift,
      times: [
        for (final s in sigs)
          if (s.signature case final TimeSignature t when s.record['l'] == reference) t,
      ],
      barlineCommands: barlineCommands,
      timeCommands: timeCommands,
      referenceTop: staffAt[reference]!.top,
    );
  }

  /// What the frozen zone and the header draw instead, and what nothing does.
  static const _skipped = {
    'SystemStartBracket', 'SystemStartBrace', 'SystemStartBar', 'SystemStartSquare', 'SpanBar', 'SpanBarStub', //
    'InstrumentName', 'BarNumber', 'VerticalAxisGroup',
  };

  /// Its staff lines' y, by staff line key; the staves numbered in score order (a piano's or a
  /// harp's staves one part's), the parts in the order they stand.
  void _staves() {
    for (final g in groups) {
      if (g.kind != 'StaffSymbol' || !staffLines.contains(g.line)) continue;
      for (final s in g.shapes) {
        if (s is! LilyPath || !s.isHorizontalLine) continue;
        final y = s.points[1], x0 = math.min(s.points[0], s.points[6]), x1 = math.max(s.points[0], s.points[6]);
        final cap = s.flags & VBFlag.roundCap != 0 ? s.width / 2 : 0.0;
        final known = staffAt[g.line];
        final ys = <double>{...?_lineYs[g.line], y};
        _lineYs[g.line] = ys;
        staffAt[g.line] = (
          top: math.min(known?.top ?? y, y),
          bottom: math.max(known?.bottom ?? y, y),
          lines: ys.length,
          left: math.min(known?.left ?? x0 - cap, x0 - cap),
          right: math.max(known?.right ?? x1 + cap, x1 + cap),
          thickness: known?.thickness ?? s.width,
        );
      }
    }
    final ordered = [...staffAt.keys]..sort((a, b) => staffAt[a]!.top.compareTo(staffAt[b]!.top));
    final byPart = <int, List<int>>{};
    for (final line in ordered) {
      byPart.putIfAbsent(_partKey(line), () => []).add(line);
    }
    var n = 0;
    for (final MapEntry(key: key, value: staves) in byPart.entries) {
      parts.add((key: key, staves: staves));
      for (final line in staves) {
        staffNumber[line] = ++n;
        lineStaff[line] = n;
      }
    }
  }

  final _lineYs = <int, Set<double>>{};

  /// The part a staff is of: the piano (or grand) staff it is in, or itself.
  int _partKey(int line) {
    var k = contexts[line]?.parent ?? -1;
    while (k >= 0) {
      final c = contexts[k];
      if (c == null || c.name == 'Score') break;
      if (c.name == 'PianoStaff' || c.name == 'GrandStaff') return k;
      k = c.parent;
    }
    return line;
  }

  /// Each line that isn't a staff (lyrics, chord names, figures, dynamics) drawn with the staff
  /// it belongs to: the one above it, or below as its affinity says.
  void _lines() {
    final extent = <int, ui.Rect>{};
    for (final g in drawn.values) {
      if (g.line < 0 || staffNumber.containsKey(g.line)) continue;
      extent[g.line] = extent[g.line]?.expandToInclude(g.bounds) ?? g.bounds;
    }
    for (final MapEntry(key: line, value: box) in extent.entries) {
      final direction = switch (affinity[line]) { '1' || '1.0' => 1, '-1' || '-1.0' => -1, '0' || '0.0' => 1, _ => 0 };
      lineStaff[line] = _nearest(box.center.dy, direction: direction);
    }
  }

  /// The staff nearest [y]: with [direction] 1 the one above it (or about it), -1 below, else
  /// either.
  int _nearest(double y, {int direction = 0}) {
    int? best;
    var bestDistance = double.infinity;
    for (final MapEntry(key: line, value: at) in staffAt.entries) {
      final n = staffNumber[line];
      if (n == null) continue;
      if (direction == 1 && at.top > y) continue;
      if (direction == -1 && at.bottom < y) continue;
      final distance = y < at.top ? at.top - y : (y > at.bottom ? y - at.bottom : 0.0);
      if (distance < bestDistance) {
        best = n;
        bestDistance = distance;
      }
    }
    return best ?? (direction == 0 ? 1 : _nearest(y));
  }

  /// The staff a group is drawn with: its line's, or the nearest (a mark above the score: the
  /// top staff).
  int _staffOf(LilyGroup g) => lineStaff[g.line] ?? _nearest(g.bounds.center.dy);

  String? _sourceId(LilyGroup g) {
    final r = byGrob[g.id];
    if (r == null) return null;
    return switch (g.kind) {
      'MetronomeMark' => 'ly-tempo-${g.id}',
      'RehearsalMark' => 'ly-mark-${g.id}-reh',
      'TextScript' || 'TextMark' || 'SectionLabel' when '${r['text'] ?? ''}'.trim().isNotEmpty => 'ly-text-${g.id}',
      _ => null,
    };
  }

  /// The groups in drawing order, each clef's octave mark (the 8 of a tenor's treble clef) right
  /// after it, with that clef's number: the frozen zone hides the opening clef's commands, all
  /// of them.
  List<(LilyGroup, int?)> _ordered() {
    final modifiers = <int, List<LilyGroup>>{};
    final taken = <int>{};
    final clefs = [for (final g in groups) if (g.kind == 'Clef' && g.shapes.isNotEmpty) g];
    for (final m in groups) {
      if (m.kind != 'ClefModifier' || m.shapes.isEmpty) continue;
      LilyGroup? best;
      var bestDistance = 3 * unit;
      for (final c in clefs) {
        if (c.line != m.line) continue;
        final distance = (c.bounds.center.dx - m.bounds.center.dx).abs();
        if (distance < bestDistance) {
          best = c;
          bestDistance = distance;
        }
      }
      if (best != null) {
        modifiers.putIfAbsent(best.id, () => []).add(m);
        taken.add(m.id);
      }
    }
    return [
      for (final g in groups)
        if (!taken.contains(g.id)) ...[(g, null), for (final m in modifiers[g.id] ?? const <LilyGroup>[]) (m, g.id)],
    ];
  }

  List<_Q> _measureStarts() {
    final starts = <_Q>{for (final r in measureRecords) _moment(r)}.toList()..sort();
    if (starts.isEmpty || starts.first > _Q.zero) starts.insert(0, _Q.zero);
    final last = end, first = starts.first;
    if (last != null) starts.removeWhere((s) => s >= last && s != first);
    return starts;
  }

  /// Where the piece ends: the end the data file gives, else after its last note.
  _Q _finish(List<_Q> starts) {
    var finish = end ?? starts.last;
    for (final r in records) {
      if (r['t'] != 'NoteHead' && r['t'] != 'Rest') continue;
      final m = _moment(r) + (_Q.parse(r['d']) ?? _Q.zero);
      if (end == null && m > finish) finish = m;
    }
    return finish > starts.last ? finish : starts.last + const _Q._(1, 4);
  }

  /// Each moment a note (else a rest) starts, with the x its notes are drawn at (the middle of
  /// their left edges: a chord's second set off the stem doesn't move it), in time order.
  List<(_Q, double)> _onsets() {
    final notes = <_Q, List<double>>{}, rests = <_Q, List<double>>{};
    for (final r in records) {
      final into = switch (r['t']) { 'NoteHead' || 'TabNoteHead' => notes, 'Rest' => rests, _ => null };
      if (into == null || _grace(r)) continue;
      final g = drawn[_int(r['c'])];
      if (g == null) continue;
      into.putIfAbsent(_moment(r), () => []).add(g.bounds.left);
    }
    double median(List<double> v) => (v..sort())[v.length ~/ 2];
    final out = <(_Q, double)>[
      for (final MapEntry(key: m, value: xs) in notes.entries) (m, median(xs)),
      for (final MapEntry(key: m, value: xs) in rests.entries)
        if (!notes.containsKey(m)) (m, median(xs)),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    return out;
  }

  /// The x of each bar's start and of the end: where the barline is drawn; where none is, before
  /// the bar's first note. The first bar starts after the opening clefs, keys and times.
  List<double> _boundaries(List<_Q> starts, _Q finish, List<(_Q, double)> onsets) {
    final barlines = <_Q, ui.Rect>{};
    for (final r in records) {
      if (r['t'] != 'BarLine') continue;
      final g = drawn[_int(r['c'])];
      if (g == null) continue;
      final m = _moment(r);
      barlines[m] = barlines[m]?.expandToInclude(g.bounds) ?? g.bounds;
    }
    final staffLeft = staffAt.values.fold(double.infinity, (l, s) => math.min(l, s.left));
    final staffRight = staffAt.values.fold(-double.infinity, (r, s) => math.max(r, s.right));
    double? firstOnsetFrom(_Q m) => onsets.where((o) => o.$1 >= m).firstOrNull?.$2;
    double? lastOnsetBefore(_Q m) => onsets.where((o) => o.$1 < m).lastOrNull?.$2;

    final xs = <double>[];
    // The first bar: after what is drawn before its first note at its start.
    final firstNote = firstOnsetFrom(starts.first) ?? staffRight;
    if (barlines[starts.first] case final bar?) {
      xs.add(bar.center.dx);
    } else {
      var opening = staffLeft;
      for (final r in records) {
        if (!const {'Clef', 'KeySignature', 'KeyCancellation', 'TimeSignature'}.contains(r['t']) || _moment(r) != starts.first) continue;
        final g = drawn[_int(r['c'])];
        if (g != null && g.bounds.left < firstNote) opening = math.max(opening, g.bounds.right);
      }
      xs.add(math.min(opening + unit / 2, firstNote - unit / 4));
    }
    for (final m in [...starts.skip(1), finish]) {
      final bar = barlines[m];
      double x;
      if (bar != null) {
        x = bar.center.dx;
      } else if (m == finish) {
        x = math.max(staffRight, (lastOnsetBefore(m) ?? xs.last) + unit);
      } else {
        final before = lastOnsetBefore(m), after = firstOnsetFrom(m);
        x = after != null
            ? after - math.min(unit, before == null ? unit : (after - before) / 2)
            : (before ?? xs.last) + 2 * unit;
      }
      xs.add(math.max(x, xs.last));
    }
    return xs;
  }

  /// Every clef, key and time signature: the first of each on a staff, then each change (LilyPond
  /// makes a clef and key at every barline, drawn only where a line would break: not changes).
  List<_Sig> _signatures(Map<int, ({int start, int count})> ranges, List<_Q> starts, List<double> xs) {
    final out = <_Sig>[];
    final lastClef = <int, String>{}, lastKey = <int, String>{}, lastTime = <int, String>{};
    double xAt(_Q m) {
      for (final (i, s) in starts.indexed) {
        if (s == m) return xs[i];
        if (s > m) return xs[math.max(0, i - 1)];
      }
      return xs.last;
    }

    for (final r in records) {
      final kind = r['t'];
      if (kind != 'Clef' && kind != 'KeySignature' && kind != 'TimeSignature') continue;
      final line = _int(r['l']), n = staffNumber[line];
      if (n == null) continue;
      final c = _int(r['c']), m = _moment(r);
      final g = drawn[c], range = ranges[c] ?? (start: 0, count: 0);
      final x = g?.bounds.left ?? (m == starts.first ? 0.0 : xAt(m));
      switch (kind) {
        case 'Clef':
          final said = '${r['glyph']} ${r['pos']} ${r['oct']}';
          if (lastClef[line] == said) continue;
          lastClef[line] = said;
          final glyph = '${r['glyph'] ?? ''}';
          final pos = _int(r['pos']), octave = _int(r['oct']);
          out.add(_Sig(
              r,
              m,
              ClefSignature(
                  staff: n,
                  x: x,
                  commandStart: range.start,
                  commandCount: range.count,
                  shape: switch (glyph) {
                    'clefs.GG' => ClefShape.gg,
                    _ when glyph.contains('percussion') => ClefShape.percussion,
                    _ when glyph.contains('tab') => ClefShape.tab,
                    _ when glyph.contains('F') || glyph.contains('fa') => ClefShape.f,
                    _ when glyph.contains('C') || glyph.contains('do') => ClefShape.c,
                    _ => ClefShape.g,
                  },
                  line: ((pos + 6) / 2).round(),
                  octave: (octave / 7).round())));
        case 'KeySignature':
          final said = '${r['alts']}';
          if (lastKey[line] == said) continue;
          lastKey[line] = said;
          out.add(_Sig(r, m, KeySignature(staff: n, x: x, commandStart: range.start, commandCount: range.count, fifths: _fifths(said))));
        case 'TimeSignature':
          // (Made again at a grace note's moment and its main note's.)
          final said = '${r['sig']} ${r['style']}';
          if (lastTime[line] == said) continue;
          lastTime[line] = said;
          final meter = _meter('${r['sig'] ?? ''}');
          if (meter == null) continue;
          final symbol = r['style'] == 'C' && meter.summands.length == 1
              ? switch ((meter.count, meter.unit)) { (4, 4) => 0xE08A, (2, 2) => 0xE08B, _ => null }
              : null;
          out.add(_Sig(
              r,
              m,
              TimeSignature(
                  staff: n,
                  x: x,
                  commandStart: range.start,
                  commandCount: range.count,
                  count: meter.count,
                  unit: meter.unit,
                  symbol: symbol,
                  summands: meter.summands)));
      }
    }
    return out;
  }

  /// The key a `keyAlterations` alist ("((3 . 1/2) (0 . 1/2))") is: sharps, else minus flats.
  static int _fifths(String alterations) {
    var sharps = 0, flats = 0;
    for (final m in RegExp(r'\((-?\d+) \. (-?[\d/.]+)\)').allMatches(alterations)) {
      final alter = _Q.parse(m.group(2)!)?.value ?? double.tryParse(m.group(2)!) ?? 0;
      if (alter > 0) sharps++;
      if (alter < 0) flats++;
    }
    return flats == 0 ? sharps : (sharps == 0 ? -flats : sharps - flats);
  }

  /// A `time-signature` ("(3 . 4)", "((2 3) . 8)", "((3 8) (2 4))") as beats in its smallest
  /// unit: 3/8 + 2/4 is seven quavers, three and four.
  static ({int count, int unit, List<int> summands})? _meter(String text) {
    final fractions = <(int, int)>[];
    final simple = RegExp(r'^\((\d+) \. (\d+)\)$').firstMatch(text);
    final additive = RegExp(r'^\(\(([\d ]+)\) \. (\d+)\)$').firstMatch(text);
    if (simple != null) {
      fractions.add((int.parse(simple.group(1)!), int.parse(simple.group(2)!)));
    } else if (additive != null) {
      for (final n in additive.group(1)!.trim().split(RegExp(r'\s+'))) {
        fractions.add((int.parse(n), int.parse(additive.group(2)!)));
      }
    } else {
      for (final m in RegExp(r'\(([\d ]+)\)').allMatches(text)) {
        final numbers = [for (final n in m.group(1)!.trim().split(RegExp(r'\s+'))) int.parse(n)];
        if (numbers.length < 2) continue;
        for (final n in numbers.take(numbers.length - 1)) {
          fractions.add((n, numbers.last));
        }
      }
    }
    if (fractions.isEmpty || fractions.any((f) => f.$2 <= 0)) return null;
    final unit = fractions.map((f) => f.$2).reduce(math.max);
    final summands = [for (final (n, d) in fractions) n * unit ~/ d];
    return (count: summands.fold(0, (a, b) => a + b), unit: unit, summands: summands);
  }

  /// How a staff's instrument sounds against what is written (`\transposition`), from its
  /// first note: semitones and steps (a B♭ clarinet's -2 and -1); null for one in C.
  ({int semitones, int steps})? _transposition(int line) {
    for (final r in records) {
      if (r['t'] != 'NoteHead' || _int(r['l']) != line) continue;
      final t = r['tr'];
      if (t is! List || t.length < 3) return null;
      final octave = _int(t[0]), step = _int(t[1]), alter = _Q.parse(t[2])?.value ?? 0;
      final semitones = octave * 12 + const [0, 2, 4, 5, 7, 9, 11][step.clamp(0, 6)] + (alter * 2).round();
      return semitones == 0 ? null : (semitones: semitones, steps: octave * 7 + step);
    }
    return null;
  }

  /// How many fifths an interval of [semitones] moves a key (a whole tone down: two flats).
  static int _fifthsOf(int semitones) {
    var f = (semitones * 7) % 12;
    if (f > 6) f -= 12;
    return f;
  }
}

/// The score as MusicXML: its parts and staves, bars, notes (voices, chords, ties, graces and
/// tuplets), clefs, keys, times and transpositions, tempo and rehearsal marks, texts and dynamics,
/// repeats and endings.
class _MusicXmlWriter {
  _MusicXmlWriter(this.r, this.starts, this.finish, this.sigs);
  final _Reader r;
  final List<_Q> starts;
  final _Q finish;
  final List<_Sig> sigs;
  final out = StringBuffer();
  late final int divisions = _divisions();

  int _bar(_Q m) {
    var lo = 0, hi = starts.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (starts[mid] <= m) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  _Q _next(int bar) => bar + 1 < starts.length ? starts[bar + 1] : finish;

  int _ticks(_Q q) => (q.value * 4 * divisions).round();

  int _divisions() {
    var lcm = 1;
    void take(_Q q) {
      final d = (q * const _Q._(4, 1)).d;
      lcm = lcm ~/ lcm.gcd(d) * d;
    }

    for (final rec in r.records) {
      if (const {'NoteHead', 'TabNoteHead', 'Rest'}.contains(rec['t'])) {
        if (_Q.parse(rec['d']) case final d?) take(d);
        take(_Reader._moment(rec));
      }
      if (lcm > 1 << 20) return 10080;
    }
    for (final s in starts) {
      take(s);
    }
    take(finish);
    return lcm > 1 << 20 ? 10080 : lcm;
  }

  static String _x(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

  String write() {
    final parts = r.parts;
    // Each voice: its part (that of the staff it first plays on) and its events.
    final partOfStaff = <int, int>{};
    for (final (i, p) in parts.indexed) {
      for (final line in p.staves) {
        partOfStaff[line] = i;
      }
    }
    final voices = <int, ({int part, List<_Rec> events})>{};
    for (final rec in r.records) {
      if (!const {'NoteHead', 'TabNoteHead', 'Rest', 'MultiMeasureRest'}.contains(rec['t'])) continue;
      final line = _Reader._int(rec['l']);
      final part = partOfStaff[line];
      if (part == null) continue;
      voices.putIfAbsent(_Reader._int(rec['k']), () => (part: part, events: [])).events.add(rec);
    }

    out.write('<?xml version="1.0" encoding="UTF-8"?>\n<score-partwise version="4.0">\n<part-list>\n');
    final chains = [for (final p in parts) _groups(p.key, p.staves.first)];
    var open = <int>[];
    var number = 0;
    final numbers = <int, int>{};
    for (final (i, p) in parts.indexed) {
      final chain = chains[i];
      var common = 0;
      while (common < open.length && common < chain.length && open[common] == chain[common]) {
        common++;
      }
      for (final g in open.sublist(common).reversed) {
        out.write('<part-group type="stop" number="${numbers[g]}"/>\n');
      }
      for (final g in chain.sublist(common)) {
        numbers[g] = ++number;
        final name = r.contexts[g]?.name ?? '';
        out.write('<part-group type="start" number="${numbers[g]}"><group-symbol>${name == 'GrandStaff' ? 'brace' : 'bracket'}'
            '</group-symbol><group-barline>${name == 'ChoirStaff' ? 'no' : 'yes'}</group-barline></part-group>\n');
      }
      open = chain;
      final (name, short) = _names(p.key, p.staves);
      out.write('<score-part id="P${i + 1}"><part-name>${_x(name)}</part-name>'
          '${short.isEmpty ? '' : '<part-abbreviation>${_x(short)}</part-abbreviation>'}</score-part>\n');
    }
    for (final g in open.reversed) {
      out.write('<part-group type="stop" number="${numbers[g]}"/>\n');
    }
    out.write('</part-list>\n');

    for (final (i, p) in parts.indexed) {
      _part(i, p, [for (final MapEntry(key: k, value: v) in voices.entries) if (v.part == i) (key: k, events: v.events)]);
    }
    out.write('</score-partwise>\n');
    return out.toString();
  }

  /// The groups (staff groups, choirs) a part stands in, outermost first.
  List<int> _groups(int partKey, int firstStaff) {
    final chain = <int>[];
    var k = r.contexts[partKey == firstStaff ? firstStaff : partKey]?.parent ?? -1;
    while (k >= 0) {
      final c = r.contexts[k];
      if (c == null || c.name == 'Score' || c.name == 'Global') break;
      if (c.name.endsWith('Group') || c.name.endsWith('Staff')) chain.add(k);
      k = c.parent;
    }
    return chain.reversed.toList();
  }

  /// A part's name and short name: its instrument name's, else its first staff's, else the
  /// name its context was given (`\new Staff = "violin"`).
  (String, String) _names(int partKey, List<int> staves) {
    String clean(Object? s) =>
        '${s ?? ''}'.trim().replaceAllMapped(RegExp(r'(\w) ([♭♯♮𝄫𝄪])'), (m) => '${m[1]}${m[2]}');
    for (final key in [partKey, ...staves]) {
      final name = r.records.where((rec) => rec['t'] == 'InstrumentName' && _Reader._int(rec['k']) == key).firstOrNull;
      if (name != null && clean(name['long']).isNotEmpty) return (clean(name['long']), clean(name['short']));
    }
    final id = r.contexts[partKey]?.id ?? '';
    return (id.startsWith(r'\') ? '' : id, '');
  }

  void _part(int index, ({int key, List<int> staves}) p, List<({int key, List<_Rec> events})> voices) {
    final staffIndex = {for (final (k, line) in p.staves.indexed) line: k + 1};
    final many = p.staves.length > 1;
    final first = index == 0;
    // Clefs, keys and times by bar: this part's staves' clefs, its first staff's keys and times.
    final changes = <int, List<_Sig>>{};
    for (final s in sigs) {
      final line = _Reader._int(s.record['l']);
      if (!staffIndex.containsKey(line)) continue;
      if (s.signature is! ClefSignature && line != p.staves.first) continue;
      changes.putIfAbsent(_bar(s.moment), () => []).add(s);
    }
    // What is said at a moment: marks above the score (in the first part), texts and dynamics.
    final directions = <int, List<_Rec>>{};
    for (final rec in r.records) {
      final kind = rec['t'];
      final line = _Reader._int(rec['l']);
      final ours = switch (kind) {
        'MetronomeMark' || 'RehearsalMark' || 'TextMark' || 'SectionLabel' => first,
        'DynamicText' || 'TextScript' => staffIndex.containsKey(line),
        _ => false,
      };
      if (ours) directions.putIfAbsent(_bar(_Reader._moment(rec)), () => []).add(rec);
    }
    final volta = <int, List<_Rec>>{};
    final voltaStops = <int, List<_Rec>>{};
    final forward = <int>{}, backward = <int>{};
    final styles = <int, String>{};
    for (final rec in r.records) {
      if (rec['t'] == 'VoltaBracket') {
        final start = _bar(_Reader._moment(rec));
        volta.putIfAbsent(start, () => []).add(rec);
        final end = r.voltaEnds[_Reader._int(rec['c'])];
        final stop = end == null ? starts.length - 1 : math.max(start, _bar(end - const _Q._(1, 1 << 20)));
        voltaStops.putIfAbsent(stop, () => []).add(rec);
      }
      if (rec['t'] == 'BarLine') {
        final glyph = '${rec['glyph'] ?? ''}', m = _Reader._moment(rec);
        final bar = starts.indexOf(m);
        if (glyph.endsWith(':') && bar >= 0) forward.add(bar);
        if (glyph.startsWith(':')) backward.add(m == finish ? starts.length - 1 : math.max(0, bar < 0 ? _bar(m) : bar - 1));
        final style = switch (glyph) { '|.' || ':|.' => 'light-heavy', '||' => 'light-light', _ => null };
        if (style != null) styles[m == finish ? starts.length - 1 : math.max(0, (bar < 0 ? _bar(m) + 1 : bar) - 1)] = style;
      }
    }
    String endingNumbers(_Rec rec) {
      final numbers = [for (final m in RegExp(r'\d+').allMatches('${rec['text'] ?? ''}')) m.group(0)!];
      return numbers.isEmpty ? '1' : numbers.join(', ');
    }

    // Each voice's events, by bar.
    final byBar = <int, Map<int, List<_Rec>>>{};
    for (final v in voices) {
      for (final e in v.events) {
        byBar.putIfAbsent(_bar(_Reader._moment(e)), () => {}).putIfAbsent(v.key, () => []).add(e);
      }
    }
    final voiceNumber = {for (final (k, v) in voices.indexed) v.key: k + 1};
    final transposition = r._transposition(p.staves.first);

    out.write('<part id="P${index + 1}">\n');
    for (var bar = 0; bar < starts.length; bar++) {
      final start = starts[bar], length = _next(bar) - start;
      final record = r.measureRecords.where((m) => _Reader._moment(m) == start).firstOrNull;
      final pickup = bar == 0 && (_Q.parse(record?['pos']) ?? _Q.zero) < _Q.zero;
      final number = pickup ? '0' : '${record?['bar'] ?? bar + 1}';
      out.write('<measure number="${_x(number)}"${pickup ? ' implicit="yes"' : ''}>\n');
      if (forward.contains(bar) || volta.containsKey(bar)) {
        out.write('<barline location="left">');
        for (final v in volta[bar] ?? const <_Rec>[]) {
          out.write('<ending number="${endingNumbers(v)}" type="start">${_x('${v['text'] ?? ''}')}</ending>');
        }
        if (forward.contains(bar)) out.write('<repeat direction="forward"/>');
        out.write('</barline>\n');
      }
      final here = changes[bar] ?? const <_Sig>[];
      if (bar == 0 || here.isNotEmpty) {
        out.write('<attributes>');
        if (bar == 0) out.write('<divisions>$divisions</divisions>');
        for (final s in here) {
          if (s.signature case final KeySignature k) out.write('<key><fifths>${k.fifths}</fifths></key>');
        }
        for (final s in here) {
          if (s.signature case final TimeSignature t) {
            final symbol = switch (t.symbol) { 0xE08A => ' symbol="common"', 0xE08B => ' symbol="cut"', _ => '' };
            out.write('<time$symbol><beats>${t.summands.join('+')}</beats><beat-type>${t.unit}</beat-type></time>');
          }
        }
        if (bar == 0 && many) out.write('<staves>${p.staves.length}</staves>');
        for (final s in here) {
          if (s.signature case final ClefSignature c) {
            final k = staffIndex[_Reader._int(s.record['l'])]!;
            final sign = switch (c.shape) {
              ClefShape.f => 'F',
              ClefShape.c => 'C',
              ClefShape.percussion => 'percussion',
              ClefShape.tab => 'TAB',
              _ => 'G',
            };
            final line = c.shape == ClefShape.percussion || c.shape == ClefShape.tab ? '' : '<line>${c.line}</line>';
            final octave = c.octave == 0 ? '' : '<clef-octave-change>${c.octave}</clef-octave-change>';
            out.write('<clef${many ? ' number="$k"' : ''}><sign>$sign</sign>$line$octave</clef>');
          }
        }
        if (bar == 0 && transposition != null) {
          final octaves = transposition.semitones ~/ 12;
          out.write('<transpose><diatonic>${transposition.steps - 7 * octaves}</diatonic>'
              '<chromatic>${transposition.semitones - 12 * octaves}</chromatic>'
              '${octaves == 0 ? '' : '<octave-change>$octaves</octave-change>'}</transpose>');
        }
        out.write('</attributes>\n');
      }
      for (final d in directions[bar] ?? const <_Rec>[]) {
        _direction(d, start, staffIndex, many);
      }
      var cursor = 0;
      final played = byBar[bar] ?? const {};
      for (final v in voices) {
        final events = played[v.key];
        if (events == null) continue;
        if (cursor > 0) {
          out.write('<backup><duration>$cursor</duration></backup>\n');
          cursor = 0;
        }
        cursor = _voice(events, start, length, voiceNumber[v.key]!, staffIndex, many);
      }
      final stops = voltaStops[bar] ?? const <_Rec>[];
      if (backward.contains(bar) || stops.isNotEmpty || styles.containsKey(bar)) {
        out.write('<barline location="right">');
        if (styles[bar] case final style?) out.write('<bar-style>$style</bar-style>');
        for (final v in stops) {
          out.write('<ending number="${endingNumbers(v)}" type="${backward.contains(bar) ? 'stop' : 'discontinue'}"/>');
        }
        if (backward.contains(bar)) out.write('<repeat direction="backward"/>');
        out.write('</barline>\n');
      }
      out.write('</measure>\n');
    }
    out.write('</part>\n');
  }

  void _direction(_Rec d, _Q start, Map<int, int> staffIndex, bool many) {
    final c = _Reader._int(d['c']);
    final offset = _ticks(_Reader._moment(d) - start);
    final at = offset > 0 ? '<offset>$offset</offset>' : '';
    final staff = many && staffIndex[_Reader._int(d['l'])] != null ? '<staff>${staffIndex[_Reader._int(d['l'])]}</staff>' : '';
    final text = '${d['text'] ?? ''}'.trim();
    switch (d['t']) {
      case 'MetronomeMark':
        final unit = _Q.parse(d['unit']);
        final count = double.tryParse(RegExp(r'[\d.]+').firstMatch('${d['count'] ?? ''}')?.group(0) ?? '');
        if (text.isEmpty && (unit == null || count == null)) return;
        out.write('<direction placement="above" id="ly-tempo-$c">');
        if (text.isNotEmpty) out.write('<direction-type><words>${_x(text)}</words></direction-type>');
        final beat = unit == null ? null : _beatUnit(unit);
        if (beat != null && count != null) {
          out.write('<direction-type><metronome><beat-unit>${beat.$1}</beat-unit>${'<beat-unit-dot/>' * beat.$2}'
              '<per-minute>${_number(count)}</per-minute></metronome></direction-type>');
        }
        out.write(at);
        if (unit != null && count != null) out.write('<sound tempo="${_number(count * unit.value * 4)}"/>');
        out.write('</direction>\n');
      case 'RehearsalMark':
        if (text.isEmpty) return;
        out.write('<direction placement="above" id="ly-mark-$c"><direction-type><rehearsal>${_x(text)}</rehearsal>'
            '</direction-type>$at</direction>\n');
      case 'TextScript' || 'TextMark' || 'SectionLabel':
        if (text.isEmpty) return;
        out.write('<direction placement="above" id="ly-text-$c"><direction-type><words>${_x(text)}</words></direction-type>'
            '$at$staff</direction>\n');
      case 'DynamicText':
        if (text.isEmpty) return;
        final mark = _dynamics.contains(text) ? '<$text/>' : '<other-dynamics>${_x(text)}</other-dynamics>';
        out.write('<direction placement="below"><direction-type><dynamics>$mark</dynamics></direction-type>$at$staff</direction>\n');
    }
  }

  static const _dynamics = {
    'p', 'pp', 'ppp', 'pppp', 'ppppp', 'pppppp', 'f', 'ff', 'fff', 'ffff', 'fffff', 'ffffff', 'mp', 'mf', 'sf', 'sfp', 'sfpp', //
    'fp', 'rf', 'rfz', 'sfz', 'sffz', 'fz', 'n', 'pf', 'sfzp',
  };

  static String _number(double v) => v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(2);

  /// The note value of a beat [unit] (whole notes) and its dots: 3/8 a dotted crotchet.
  static (String, int)? _beatUnit(_Q unit) {
    for (var dots = 0; dots <= 2; dots++) {
      // A value with dots is the plain one times (2 - 1/2^dots).
      final plain = unit.value / (2 - 1 / (1 << dots));
      final log = -(math.log(plain) / math.ln2);
      if ((log - log.round()).abs() < 1e-9 && _types.containsKey(log.round())) return (_types[log.round()]!, dots);
    }
    return null;
  }

  static const _types = {
    -2: 'long', -1: 'breve', 0: 'whole', 1: 'half', 2: 'quarter', 3: 'eighth', 4: '16th', 5: '32nd', 6: '64th', //
    7: '128th', 8: '256th', 9: '512th', 10: '1024th',
  };

  /// One voice's events in a bar from [start], set where they fall ([length] long); returns how
  /// far in the bar it has written.
  int _voice(List<_Rec> events, _Q start, _Q length, int voice, Map<int, int> staffIndex, bool many) {
    final sorted = [...events]..sort((a, b) {
        final m = _Reader._moment(a).compareTo(_Reader._moment(b));
        if (m != 0) return m;
        return (_Q.parse(a['g']) ?? _Q.zero).compareTo(_Q.parse(b['g']) ?? _Q.zero);
      });
    var cursor = 0;
    for (var i = 0; i < sorted.length;) {
      final head = sorted[i];
      final m = _Reader._moment(head), g = _Q.parse(head['g']) ?? _Q.zero;
      var j = i + 1;
      final isRest = head['t'] == 'Rest' || head['t'] == 'MultiMeasureRest';
      while (!isRest &&
          j < sorted.length &&
          _Reader._moment(sorted[j]) == m &&
          (_Q.parse(sorted[j]['g']) ?? _Q.zero) == g &&
          sorted[j]['t'] != 'Rest' &&
          sorted[j]['t'] != 'MultiMeasureRest') {
        j++;
      }
      final chord = sorted.sublist(i, j);
      i = j;
      final grace = g != _Q.zero;
      final at = _ticks(m - start);
      if (!grace && at > cursor) {
        final staff = many ? '<staff>${staffIndex[_Reader._int(head['l'])] ?? 1}</staff>' : '';
        out.write('<forward><duration>${at - cursor}</duration><voice>$voice</voice>$staff</forward>\n');
        cursor = at;
      } else if (!grace && at < cursor) {
        out.write('<backup><duration>${cursor - at}</duration></backup>\n');
        cursor = at;
      }
      var advance = 0;
      for (final (k, e) in chord.indexed) {
        final full = e['t'] == 'MultiMeasureRest';
        var duration = _Q.parse(e['d']) ?? length;
        if (full || duration > length) duration = length;
        final ticks = math.max(1, _ticks(duration));
        if (k == 0) advance = grace ? 0 : ticks;
        out.write('<note>');
        if (grace) out.write('<grace/>');
        if (k > 0) out.write('<chord/>');
        if (e['t'] == 'Rest' || full) {
          out.write(full ? '<rest measure="yes"/>' : '<rest/>');
        } else if (e['p'] case [final octave, final step, final alter]) {
          final o = _Reader._int(octave), s = _Reader._int(step).clamp(0, 6);
          final semis = (_Q.parse(alter)?.value ?? 0) * 2;
          out.write('<pitch><step>${'CDEFGAB'[s]}</step>${semis == 0 ? '' : '<alter>${_number(semis)}</alter>'}'
              '<octave>${o + 4}</octave></pitch>');
        } else {
          // A drum: where it is drawn, read as in a treble clef (the middle line a B).
          final degree = 34 + _Reader._int(e['sp']);
          out.write('<unpitched><display-step>${'CDEFGAB'[degree % 7]}</display-step>'
              '<display-octave>${degree ~/ 7}</display-octave></unpitched>');
        }
        if (!grace) out.write('<duration>$ticks</duration>');
        final c = _Reader._int(e['c']);
        final stop = r.tieStops.contains(c), startTie = r.tieStarts.contains(c);
        if (stop) out.write('<tie type="stop"/>');
        if (startTie) out.write('<tie type="start"/>');
        out.write('<voice>$voice</voice>');
        if (_types[_Reader._int(e['dl'])] case final type? when !full) {
          out.write('<type>$type</type>${'<dot/>' * math.max(0, _Reader._int(e['dd']))}');
        }
        if (_Q.parse(e['ds']) case final scale? when scale != const _Q._(1, 1) && scale.n > 0) {
          out.write('<time-modification><actual-notes>${scale.d}</actual-notes><normal-notes>${scale.n}</normal-notes>'
              '</time-modification>');
        }
        if (many) out.write('<staff>${staffIndex[_Reader._int(e['l'])] ?? 1}</staff>');
        if (stop || startTie) {
          out.write('<notations>${stop ? '<tied type="stop"/>' : ''}${startTie ? '<tied type="start"/>' : ''}</notations>');
        }
        out.write('</note>\n');
      }
      cursor += advance;
    }
    return cursor;
  }
}

/// A LilyPond score drawn whole as LilyPond engraved it, on its one line and nothing set apart:
/// the LilyPond editor's preview. In the engraving's units ([LilyPondScore.unit] a staff space).
class LilyPondDrawing {
  LilyPondDrawing(this.score, {String textFontFamily = 'packages/score_engine/Academico'})
      : _list = ScoreDisplayList.build(score.engraving, RenderStyle(textFontFamily: textFontFamily));

  final LilyPondScore score;
  final ScoreDisplayList _list;

  /// Where its ink is.
  late final ui.Rect bounds = () {
    ui.Rect? all;
    for (final layer in [..._list.staves, _list.barlines]) {
      for (final item in layer.items) {
        all = all?.expandToInclude(item.bounds) ?? item.bounds;
      }
      for (final line in layer.lines) {
        final r = ui.Rect.fromLTRB(line.left, line.y - line.thickness / 2, line.right, line.y + line.thickness / 2);
        all = all?.expandToInclude(r) ?? r;
      }
    }
    return all ?? ui.Rect.zero;
  }();

  /// Draws what of it lies in [visible] in [ink].
  void paint(ui.Canvas canvas, ui.Rect visible, ui.Color ink) {
    canvas.saveLayer(visible, ui.Paint()..colorFilter = ui.ColorFilter.mode(ink, ui.BlendMode.srcIn));
    final linePaint = ui.Paint()..color = const ui.Color(0xFF000000);
    // What a staff draws reaches this far above and below its lines (lyrics, marks).
    const reach = 16 * LilyPondScore.unit;
    for (final layer in _list.staves) {
      final top = layer.info.top, bottom = top + layer.info.height;
      if (top - reach > visible.bottom || bottom + reach < visible.top) continue;
      for (final line in layer.lines) {
        final a = math.max(line.left, visible.left), b = math.min(line.right, visible.right);
        if (a >= b) continue;
        linePaint.strokeWidth = line.thickness;
        canvas.drawLine(ui.Offset(a, line.y), ui.Offset(b, line.y), linePaint);
      }
      for (final item in layer.itemsIn(visible.left, visible.right)) {
        item.paint(canvas);
      }
      // The barlines, the stretch over this staff's lines.
      canvas
        ..save()
        ..clipRect(ui.Rect.fromLTRB(visible.left, top - 0.5, visible.right, bottom + 0.5));
      for (final item in _list.barlines.itemsIn(visible.left, visible.right)) {
        item.paint(canvas);
      }
      canvas.restore();
    }
    canvas.restore();
  }

  void dispose() => _list.dispose();
}
