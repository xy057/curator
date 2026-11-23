/// Curating by writing: a script says when each lane is shown, a statement a line, and running it
/// does to the lanes what the Instruments tab's tools do ([Curation]'s own edits: Draw is
/// `show`, Erase is `hide`, Auto-Curate is `auto`…). The language is Curator's own and small:
///
/// ```
/// # The winds come in at bar 9.
/// let winds = "Flute*", "Oboe*"
/// clear
/// show "Violin I", "Violin II" 1-8, 17-24
/// show winds from 9 until 17 transition in 0.5
/// show "Piano" 1-4 without staff 2
/// ```
///
/// [LaneScript.parse] reads one (what doesn't read is a [LaneScriptProblem] with its line),
/// [LaneScript.run] does it over a [LaneScriptHost] (the project), [LaneScript.check] finds what
/// running it would get wrong without changing anything, and [LaneScript.write] writes the lanes
/// as they are as a script that makes them again. Every statement is listed once
/// ([LaneScriptApi.statements]): the docs' reference and what the editor offers come from it.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'auto_curate.dart';
import 'beat_grid.dart';
import 'curation.dart';
import 'lane_script_api.dart';

/// A lane as a script names it: by its [name], as the lane shows it.
@immutable
class ScriptLane {
  const ScriptLane({required this.id, required this.name, String? instrument, this.staff, this.staves = 1}) : instrument = instrument ?? id;

  /// The curation's id of it ([Curation.lane]): an instrument's, or a staff's of one split.
  final String id;

  /// Its instrument's name (a staff's lane has its instrument's: `"Piano"/1` names it).
  final String name;

  /// Its instrument's lane id: its own, unless it is a staff's.
  final String instrument;

  /// Which staff of its instrument it is (1 the top one), when the instrument's lane is split.
  final int? staff;

  /// How many staves its instrument is on: more than one can be split.
  final int staves;
}

/// What a script runs over: the project's lanes and what only the app does to them.
abstract class LaneScriptHost {
  /// The lanes, top to bottom, as they are now (a split or a move changes them).
  List<ScriptLane> get lanes;

  /// The score's bars and beats, its bars counted as the project counts them.
  BeatGrid get beats;

  Curation get curation;

  /// The score's rehearsal marks: each one's text with where its bar starts, in quarters.
  List<(String, double)> get marks => const [];

  /// Auto-Curate on the lanes [ids]; false when this score's lanes can't be.
  bool autoCurate(List<String> ids);

  /// Whether this score's lanes can be filled from its notes (`follow`, `fit`).
  bool get curates => true;

  /// The bars the lane [id] plays in (its instrument's, either player's of a pair), a bar
  /// each; null for a lane that plays nothing of its own, which stays as it is.
  List<bool>? playing(String id) => null;

  /// What to hide of the lanes [ids], as they are now, so the staves don't run off the frame:
  /// each one's stretches, found in phrases of [phrase] bars. None where there is no frame.
  Map<String, List<Region>> fit(List<String> ids, {required int phrase}) => const {};

  /// Splits the lane of [instrument] into a lane a staff, or joins them.
  void setSplit(String instrument, bool on);

  /// Moves the lanes [ids] to just above lane [before]; null: under the last.
  void moveLanes(List<String> ids, {String? before});

  /// Puts the lanes back in the score's order.
  void restoreOrder();
}

/// Something wrong with a script, on its [line] (1 the first).
@immutable
class LaneScriptProblem {
  const LaneScriptProblem(this.line, this.message);
  final int line;
  final String message;

  @override
  String toString() => 'Line $line: $message';
}

class _Fail implements Exception {
  const _Fail(this.message);
  final String message;
}

enum _Kind { word, text, number, quarter, symbol }

typedef _Token = ({_Kind kind, String text, int at, int end});

/// A place in the score as written: a bar or a beat ("12", "12.3"), quarters from the start
/// ("@12.5"), the piece's start or end, a rehearsal mark.
typedef _Place = ({String? bar, double? quarter, bool start, bool end, String? mark});

/// A stretch as written: [from] through [through] (a bar's or a beat's whole, both in bars and
/// beats), or from [from] (null: the start) until [until] (null: the end).
typedef _Range = ({_Place? from, _Place? through, _Place? until, bool whole});

/// A lane, or several, as written.
typedef _Term = ({String? name, String? group, bool all, int? nth, int? staff});
typedef _Lanes = ({List<_Term> include, List<_Term> exclude});

/// A transition as written: not [given], the project's ([seconds] null), or its own.
typedef _Fade = ({bool given, double? seconds});

/// A script read: its statements, or what is wrong with it as written.
class LaneScript {
  LaneScript._(this._statements, this.problems);

  /// The most a script holds.
  static const maxLength = 1 << 20;

  final List<(int, void Function(_Run))> _statements;

  /// What doesn't read, by line: none, and it can be [run].
  final List<LaneScriptProblem> problems;

  /// The words of the language, and its statements ([LaneScriptApi]).
  static const keywords = LaneScriptApi.keywords;
  static const statements = LaneScriptApi.statements;

  // MARK: Reading

  static final _token = RegExp(r'(#.*$)|"((?:[^"\\]|\\.)*)("?)|@(\d+(?:\.\d+)?)|(\d+(?:\.\d+){0,2})|([\p{L}_][\p{L}\p{N}_]*)|([,\-–/\[\]=])|(\s+)|(.)', unicode: true);

  /// [line] in runs for colouring, each with what it is: a `comment`, a `string`, a `number`,
  /// a `keyword`, or null. It never fails: what doesn't read is not coloured.
  static List<(String?, String)> tokens(String line) => [
        for (final m in _token.allMatches(line))
          (
            m[1] != null
                ? 'comment'
                : m[2] != null
                    ? 'string'
                    : m[4] != null || m[5] != null
                        ? 'number'
                        : m[6] != null && keywords.contains(m[6]!.toLowerCase())
                            ? 'keyword'
                            : null,
            m[0]!,
          ),
      ];

  static List<_Token> _lex(String line) {
    final out = <_Token>[];
    for (final m in _token.allMatches(line)) {
      if (m[1] != null || m[8] != null) continue;
      _Token token(_Kind kind, String text) => (kind: kind, text: text, at: m.start, end: m.end);
      if (m[2] != null) {
        if (m[3]!.isEmpty) throw const _Fail('A name’s closing quote is missing.');
        out.add(token(_Kind.text, m[2]!));
      } else if (m[4] != null) {
        out.add(token(_Kind.quarter, m[4]!));
      } else if (m[5] != null) {
        out.add(token(_Kind.number, m[5]!));
      } else if (m[6] != null) {
        // The language's words are read however they are cased; a group's name is as written.
        final lower = m[6]!.toLowerCase();
        out.add(token(_Kind.word, keywords.contains(lower) ? lower : m[6]!));
      } else if (m[7] != null) {
        out.add(token(_Kind.symbol, m[7] == '–' ? '-' : m[7]!));
      } else {
        throw _Fail('“${m[0]}” isn’t part of a script.');
      }
    }
    return out;
  }

  /// Reads [source], a statement a line; `#` starts a comment.
  static LaneScript parse(String source) {
    final statements = <(int, void Function(_Run))>[], problems = <LaneScriptProblem>[];
    if (source.length > maxLength) return LaneScript._(const [], const [LaneScriptProblem(1, 'The script is too long.')]);
    for (final (i, line) in source.split(RegExp(r'\r\n|\r|\n')).indexed) {
      try {
        final tokens = _lex(line);
        if (tokens.isEmpty) continue;
        statements.add((i + 1, _Parser(tokens).statement()));
      } on _Fail catch (e) {
        problems.add(LaneScriptProblem(i + 1, e.message));
      }
    }
    return LaneScript._(statements, List.unmodifiable(problems));
  }

  // MARK: Running

  /// Does every statement over [host], in order. One that can't be done (a lane there isn't, a
  /// bar past the end) is left out and listed: whoever runs it puts the lanes back then. A
  /// script that doesn't read ([problems]) does nothing.
  List<LaneScriptProblem> run(LaneScriptHost host) => _go(_Run(host, dry: false));

  /// What is wrong with it were it run now, with nothing changed: what doesn't read, and what
  /// the lines that do would get wrong, by line.
  List<LaneScriptProblem> check(LaneScriptHost host) => _go(_Run(host, dry: true));

  List<LaneScriptProblem> _go(_Run run) {
    if (problems.isNotEmpty && !run.dry) return problems;
    final found = [...problems];
    for (final (line, statement) in _statements) {
      try {
        statement(run);
      } on _Fail catch (e) {
        found.add(LaneScriptProblem(line, e.message));
      }
    }
    return found..sort((a, b) => a.line.compareTo(b.line));
  }

  // MARK: Writing

  /// [name] as a script writes it, in quotes.
  static String quoted(String name) => '"${name.replaceAllMapped(RegExp(r'[\\"*]'), (m) => '\\${m[0]}')}"';

  /// The lanes of [host] as they are, as a script that makes them again from any others: which
  /// instruments are split, the project's transition, then every lane's regions with their own
  /// transitions and the staves they leave out. Not the lanes' order.
  static String write(LaneScriptHost host) {
    final lanes = host.lanes, beats = host.beats, curation = host.curation, out = StringBuffer();
    final instruments = <String>[];
    for (final lane in lanes) {
      if (!instruments.contains(lane.instrument)) instruments.add(lane.instrument);
    }
    final called = references(lanes);
    String named(ScriptLane lane) => called[lane.id]!;
    // (An instrument's own name: its lane's, without the staff.)
    String instrument(ScriptLane lane) => lane.staff == null ? named(lane) : named(lane).substring(0, named(lane).lastIndexOf('/'));

    if (lanes.any((l) => l.staves > 1)) out.writeln('join all');
    for (final id in instruments) {
      final lane = lanes.firstWhere((l) => l.instrument == id);
      if (lane.staff != null) out.writeln('split ${instrument(lane)}');
    }
    out.writeln('clear');
    out.writeln('transition ${number(curation.transition)}');
    for (final lane in lanes) {
      final regions = curation.lane(lane.id);
      bool plain(Region r) => r.transitionIn == null && r.transitionOut == null && r.hiddenStaves.isEmpty;
      final whole = regions.where(plain).toList();
      if (whole.isNotEmpty) out.writeln('show ${named(lane)} ${whole.map((r) => range(beats, r.start, r.end)).join(', ')}'.trimRight());
      for (final r in regions.where((r) => !plain(r))) {
        final fades = r.transitionIn != null && r.transitionIn == r.transitionOut
            ? ' transition ${number(r.transitionIn!)}'
            : '${r.transitionIn == null && r.transitionOut == null ? '' : ' transition'}'
                '${r.transitionIn == null ? '' : ' in ${number(r.transitionIn!)}'}${r.transitionOut == null ? '' : ' out ${number(r.transitionOut!)}'}';
        final staves = r.hiddenStaves.isEmpty ? '' : ' without ${r.hiddenStaves.length == 1 ? 'staff' : 'staves'} ${r.hiddenStaves.join(', ')}';
        out.writeln('show ${named(lane)} ${range(beats, r.start, r.end)}'.trimRight() + fades + staves);
      }
    }
    return out.toString();
  }

  /// A number as short as it reads back the same: "0.3", "2".
  static String number(double n) => n == n.roundToDouble() ? n.toStringAsFixed(0) : n.toString();

  /// What a script calls each of [lanes], by its id: its name in quotes, the nth of that name
  /// where several instruments have it, a staff's lane by its staff (`"Violin"[2]`, `"Piano"/1`).
  static Map<String, String> references(List<ScriptLane> lanes) {
    final instruments = <String>[];
    for (final lane in lanes) {
      if (!instruments.contains(lane.instrument)) instruments.add(lane.instrument);
    }
    final names = {for (final lane in lanes) lane.instrument: _plain(lane.name)};
    return {
      for (final lane in lanes)
        if ([for (final id in instruments) if (names[id] == names[lane.instrument]) id] case final same)
          lane.id: '${quoted(lane.name)}${same.length > 1 ? '[${same.indexOf(lane.instrument) + 1}]' : ''}${lane.staff == null ? '' : '/${lane.staff}'}',
    };
  }

  /// [quarter] as a script writes a place: its bar and beat, or quarters from the start
  /// (`@12.5`) where that doesn't say it.
  static String place(BeatGrid beats, double quarter) {
    final text = beats.format(quarter, compact: true), back = beats.parse(text);
    return back != null && (back - quarter).abs() <= 1e-9 ? text : '@$quarter';
  }

  /// The stretch from [start] to [end] as a script writes it: whole bars as "1-8", anything
  /// else from a place until another; nothing for the whole piece.
  static String range(BeatGrid beats, double start, double end) {
    final starts = beats.measureStarts, total = beats.totalQuarters;
    final atStart = start <= 1e-9, atEnd = end >= total - 1e-9;
    if (atStart && atEnd) return '';
    int barAt(double q) => starts.indexWhere((s) => (s - q).abs() <= 1e-9);
    final (first, last) = (barAt(start), barAt(end));
    if (first >= 0 && last > first) {
      return last - 1 == first ? '${beats.barNumber(first)}' : '${beats.barNumber(first)}-${beats.barNumber(last - 1)}';
    }
    return [if (!atStart) 'from ${place(beats, start)}', if (!atEnd) 'until ${place(beats, end)}'].join(' ');
  }

  static final _spaces = RegExp(r'\s+');

  /// A name as names are compared: spaces squeezed, in lower case.
  static String _plain(String name) => name.replaceAll(_spaces, ' ').trim().toLowerCase();

  /// What a name as written matches: itself, however it is cased and spaced, a `*` standing
  /// for anything (`\*` for a star).
  static RegExp _matcher(String pattern) {
    final out = StringBuffer('^');
    final text = _plain(pattern);
    for (var i = 0; i < text.length; i++) {
      final c = text[i];
      if (c == '\\' && i + 1 < text.length) {
        out.write(RegExp.escape(text[++i]));
      } else if (c == '*') {
        out.write('.*');
      } else {
        out.write(RegExp.escape(c));
      }
    }
    return RegExp('$out\$', unicode: true);
  }
}

/// A script running over a host; [dry]: only finding what is wrong.
class _Run {
  _Run(this.host, {required this.dry}) : _lanes = dry ? [...host.lanes] : null;
  final LaneScriptHost host;
  final bool dry;
  final groups = <String, _Lanes>{};

  /// The lanes as the statements so far would leave them, when nothing is changed.
  final List<ScriptLane>? _lanes;

  List<ScriptLane> get lanes => _lanes ?? host.lanes;
  BeatGrid get beats => host.beats;
  Curation get curation => host.curation;
  double get total => beats.totalQuarters;

  // MARK: Lanes

  List<ScriptLane> _of(_Term term) {
    final all = lanes;
    if (term.all) return all;
    if (term.group case final group?) {
      final lanes = groups[group];
      if (lanes == null) throw _Fail('There is no group “$group”. A lane’s name goes in quotes: "$group".');
      return resolve(lanes);
    }
    final name = term.name!, matches = LaneScript._matcher(name);
    var found = [for (final lane in all) if (matches.hasMatch(LaneScript._plain(lane.name))) lane];
    if (found.isEmpty) throw _Fail('There is no lane named “$name”.');
    if (term.nth case final nth?) {
      final instruments = <String>[];
      for (final lane in found) {
        if (!instruments.contains(lane.instrument)) instruments.add(lane.instrument);
      }
      if (nth < 1 || nth > instruments.length) {
        throw _Fail(instruments.length == 1 ? 'There is one lane named “$name”.' : 'There are ${instruments.length} lanes named “$name”.');
      }
      found = [for (final lane in found) if (lane.instrument == instruments[nth - 1]) lane];
    }
    if (term.staff case final staff?) {
      for (final lane in found) {
        if (staff < 1 || staff > lane.staves) throw _Fail(lane.staves == 1 ? '“${lane.name}” is on one staff.' : '“${lane.name}” is on ${lane.staves} staves.');
        if (lane.staff == null) throw _Fail('“${lane.name}” isn’t split: write split ${LaneScript.quoted(lane.name)} first.');
      }
      found = [for (final lane in found) if (lane.staff == staff) lane];
    }
    return found;
  }

  /// The lanes [written] names, top to bottom, each once.
  List<ScriptLane> resolve(_Lanes written) {
    final wanted = {for (final term in written.include) for (final lane in _of(term)) lane.id};
    final left = wanted.difference({for (final term in written.exclude) for (final lane in _of(term)) lane.id});
    if (left.isEmpty) throw const _Fail('That leaves no lane.');
    return [for (final lane in lanes) if (left.contains(lane.id)) lane];
  }

  /// The one lane [written] names.
  ScriptLane one(_Lanes written) {
    final found = resolve(written);
    if ({for (final lane in found) lane.instrument}.length > 1) throw _Fail('One lane goes here, and that names ${found.length}.');
    return found.first;
  }

  // MARK: Places

  /// The bar [text] ("12") names, from 0.
  int _bar(String text) {
    final bar = int.tryParse(text), m = bar == null ? -1 : bar - beats.firstBar;
    if (m < 0 || m >= beats.measureStarts.length - 1) throw _Fail('There is no bar $text.');
    return m;
  }

  /// Where the bar or the beat [text] names starts and ends.
  (double, double) _span(String text) {
    if (!text.contains('.')) {
      final m = _bar(text);
      return (beats.measureStarts[m], beats.measureStarts[m + 1]);
    }
    _bar(text.split('.').first);
    final q = beats.parse(text);
    if (q == null) throw _Fail('There is no beat $text.');
    return (q, text.split('.').length > 2 ? q : beats.beatAt(q).end);
  }

  double _at(_Place place) {
    if (place.start) return 0;
    if (place.end) return total;
    if (place.quarter case final q?) {
      if (q > total + 1e-9) throw _Fail('The piece is ${LaneScript.number(total)} quarters long.');
      return q;
    }
    if (place.mark case final mark?) {
      final wanted = LaneScript._plain(mark);
      for (final (text, at) in host.marks) {
        if (LaneScript._plain(text) == wanted) return at;
      }
      throw _Fail('There is no rehearsal mark “$mark”.');
    }
    final text = place.bar!;
    // The bar after the last is the end.
    if (!text.contains('.') && int.tryParse(text) == beats.barNumber(beats.measureStarts.length - 1)) return total;
    return _span(text).$1;
  }

  /// The stretches [ranges] name; the whole piece for none.
  List<Region> stretches(List<_Range> ranges) {
    if (ranges.isEmpty) return [Region(0, total)];
    return [
      for (final range in ranges)
        () {
          final (double from, double to) = range.whole
              ? (_span(range.from!.bar!).$1, _span((range.through ?? range.from!).bar!).$2)
              : (range.from == null ? 0.0 : _at(range.from!), range.until == null ? total : _at(range.until!));
          if (to - from <= 1e-9) throw const _Fail('The range ends before it starts.');
          return Region(from, to);
        }(),
    ];
  }

  // MARK: What the statements do

  /// Sets each of [lanes] to what [edit] makes of its regions.
  void edit(List<ScriptLane> lanes, List<Region> Function(ScriptLane lane, List<Region> regions) edit) {
    if (dry) return;
    curation.setLanes({for (final lane in lanes) lane.id: edit(lane, curation.lane(lane.id))});
  }

  /// [regions] with [stretch] shown: drawn on, or in place of what is there where that leaves
  /// out other staves.
  static List<Region> shown(List<Region> regions, Region stretch) {
    final differs = regions.any((r) => r.overlaps(stretch) && !listEquals(r.hiddenStaves, stretch.hiddenStaves));
    return Curation.painted(differs ? Curation.painted(regions, stretch, shown: false) : regions, stretch);
  }

  void split(List<ScriptLane> lanes, {required bool on, required bool strict}) {
    final instruments = <String>[];
    for (final lane in lanes) {
      if (instruments.contains(lane.instrument)) continue;
      if (lane.staves < 2) {
        if (on && strict) throw _Fail('“${lane.name}” is on one staff.');
        continue;
      }
      if ((lane.staff != null) != on) instruments.add(lane.instrument);
    }
    for (final id in instruments) {
      if (!dry) {
        host.setSplit(id, on);
        continue;
      }
      final all = _lanes!, at = all.indexWhere((l) => l.instrument == id), was = all[at];
      all.removeWhere((l) => l.instrument == id);
      all.insertAll(at, [
        if (on)
          for (var n = 1; n <= was.staves; n++) ScriptLane(id: Curation.staffLaneId(id, n), name: was.name, instrument: id, staff: n, staves: was.staves)
        else
          ScriptLane(id: id, name: was.name, staves: was.staves),
      ]);
    }
  }

  void move(List<ScriptLane> moving, {ScriptLane? before, ScriptLane? after, bool top = false}) {
    final instruments = {for (final lane in moving) lane.instrument};
    final target = before ?? after;
    if (target != null && instruments.contains(target.instrument)) throw _Fail('“${target.name}” is one of the lanes moved.');
    final others = [for (final lane in lanes) if (!instruments.contains(lane.instrument)) lane];
    String? above;
    if (top) {
      above = others.firstOrNull?.id;
    } else if (before != null) {
      above = others.firstWhere((l) => l.instrument == before.instrument).id;
    } else if (after != null) {
      final at = others.lastIndexWhere((l) => l.instrument == after.instrument);
      above = at + 1 < others.length ? others[at + 1].id : null;
    }
    if (dry) {
      final all = _lanes!, block = [for (final lane in all) if (instruments.contains(lane.instrument)) lane];
      all.removeWhere((l) => instruments.contains(l.instrument));
      all.insertAll(above == null ? all.length : all.indexWhere((l) => l.id == above), block);
    } else {
      host.moveLanes([for (final lane in moving) lane.id], before: above);
    }
  }
}

/// A line's tokens read as a statement: what it does when it runs.
class _Parser {
  _Parser(this._tokens);
  final List<_Token> _tokens;
  int _at = 0;

  _Token? get _next => _at < _tokens.length ? _tokens[_at] : null;
  bool _is(String word, [int ahead = 0]) {
    final t = _at + ahead < _tokens.length ? _tokens[_at + ahead] : null;
    return t != null && (t.kind == _Kind.word || t.kind == _Kind.symbol) && t.text == word;
  }

  bool _take(String word) {
    if (!_is(word)) return false;
    _at++;
    return true;
  }

  String _said(_Token? token) => token == null ? 'the line’s end' : '“${token.kind == _Kind.text ? '"${token.text}"' : token.text}”';

  Never _wanted(String what) => throw _Fail('$what goes here, not ${_said(_next)}.');

  void _need(String word) {
    if (!_take(word)) _wanted('“$word”');
  }

  void _end() {
    if (_next != null) throw _Fail('${_said(_next)} isn’t expected here.');
  }

  double _number(String what, {double max = double.infinity}) {
    final t = _next, n = t != null && t.kind == _Kind.number ? double.tryParse(t.text) : null;
    if (n == null) _wanted(what);
    if (n > max) throw _Fail('$what is ${LaneScript.number(max)} at most.');
    _at++;
    return n;
  }

  int _whole(String what) {
    final t = _next, n = t != null && t.kind == _Kind.number ? int.tryParse(t.text) : null;
    if (n == null) _wanted(what);
    _at++;
    return n;
  }

  // MARK: Lanes

  bool get _atTerm => switch (_next) {
        null => false,
        final t when t.kind == _Kind.text => true,
        final t when t.kind == _Kind.word => t.text == 'all' || !LaneScript.keywords.contains(t.text),
        _ => false,
      };

  _Term _term() {
    final t = _next;
    if (t == null || !_atTerm) _wanted('A lane’s name in quotes');
    _at++;
    if (t.kind == _Kind.word) return (name: null, group: t.text == 'all' ? null : t.text, all: t.text == 'all', nth: null, staff: null);
    int? nth, staff;
    if (_take('[')) {
      nth = _whole('A number');
      _need(']');
    }
    if (_take('/')) staff = _whole('A staff’s number');
    return (name: t.text, group: null, all: false, nth: nth, staff: staff);
  }

  List<_Term> _terms() {
    final terms = [_term()];
    while (_is(',') && _at + 1 < _tokens.length && (_tokens[_at + 1].kind == _Kind.text || (_tokens[_at + 1].kind == _Kind.word && !_placeWords.contains(_tokens[_at + 1].text)))) {
      _at++;
      terms.add(_term());
    }
    return terms;
  }

  _Lanes _lanes() => (include: _terms(), exclude: _take('except') ? _terms() : const []);

  // MARK: Ranges

  static const _placeWords = {'bar', 'bars', 'from', 'until', 'start', 'end', 'mark'};

  bool get _atRange => switch (_next) {
        null => false,
        final t when t.kind == _Kind.number || t.kind == _Kind.quarter => true,
        final t when t.kind == _Kind.word => _placeWords.contains(t.text),
        _ => false,
      };

  _Place _place() {
    final t = _next;
    _Place place({String? bar, double? quarter, bool start = false, bool end = false, String? mark}) => (bar: bar, quarter: quarter, start: start, end: end, mark: mark);
    if (t == null) _wanted('A bar');
    _at++;
    switch (t.kind) {
      case _Kind.number:
        return place(bar: t.text);
      case _Kind.quarter:
        return place(quarter: double.parse(t.text));
      case _Kind.word when t.text == 'start':
        return place(start: true);
      case _Kind.word when t.text == 'end':
        return place(end: true);
      case _Kind.word when t.text == 'mark':
        final name = _next;
        if (name == null || name.kind == _Kind.symbol) _wanted('A rehearsal mark');
        _at++;
        return place(mark: name.text);
      default:
        _at--;
        _wanted('A bar');
    }
  }

  _Range _range() {
    if (_take('from')) {
      final from = _place();
      return (from: from, through: null, until: _take('until') ? _place() : null, whole: false);
    }
    if (_take('until')) return (from: null, through: null, until: _place(), whole: false);
    final t = _next;
    if (t == null || t.kind != _Kind.number) _wanted('A bar');
    final from = _place();
    if (!_take('-')) return (from: from, through: null, until: null, whole: true);
    if (_next?.kind != _Kind.number) _wanted('A bar');
    return (from: from, through: _place(), until: null, whole: true);
  }

  /// The ranges written here; none when none is.
  List<_Range> _ranges() {
    if (!_atRange) return const [];
    if (!_take('bars')) _take('bar');
    final ranges = [_range()];
    while (_take(',')) {
      ranges.add(_range());
    }
    return ranges;
  }

  // MARK: Transitions

  static const _maxSeconds = 30.0;

  /// Seconds, or `default`: the project's.
  double? _seconds() => _take('default') ? null : _number('Seconds', max: _maxSeconds);

  /// `in <seconds>` and `out <seconds>`, either or both; with [both], seconds alone for the two.
  (_Fade, _Fade) _fades({required bool both}) {
    const none = (given: false, seconds: null);
    if (both && (_next?.kind == _Kind.number || _is('default'))) {
      final fade = (given: true, seconds: _seconds());
      return (fade, fade);
    }
    _Fade fadeIn = none, fadeOut = none;
    if (_take('in')) fadeIn = (given: true, seconds: _seconds());
    if (_take('out')) fadeOut = (given: true, seconds: _seconds());
    if (!fadeIn.given && !fadeOut.given) _wanted(both ? 'Seconds, “in” or “out”' : '“in” or “out”');
    return (fadeIn, fadeOut);
  }

  // MARK: Statements

  void Function(_Run) statement() {
    final first = _next!;
    if (first.kind != _Kind.word || !LaneScript.statements.any((s) => s.word == first.text)) {
      throw _Fail('A line starts with what it does (show, hide, auto…), not ${_said(first)}.');
    }
    _at++;
    switch (first.text) {
      case 'show':
        final lanes = _lanes(), ranges = _ranges();
        _Fade fadeIn = (given: false, seconds: null), fadeOut = fadeIn;
        var hidden = const <int>[];
        while (_next != null) {
          if (_take('transition')) {
            (fadeIn, fadeOut) = _fades(both: true);
          } else if (_take('without')) {
            if (!_take('staff')) _need('staves');
            hidden = [_whole('A staff’s number')];
            while (_take(',')) {
              hidden.add(_whole('A staff’s number'));
            }
          } else {
            _end();
          }
        }
        return (run) {
          final found = run.resolve(lanes), stretches = run.stretches(ranges);
          for (final lane in found) {
            if (hidden.isEmpty) continue;
            if (lane.staff != null) throw _Fail('“${lane.name}” is split: show the staves’ lanes instead (${LaneScript.quoted(lane.name)}/1).');
            if (hidden.any((n) => n < 1 || n > lane.staves)) throw _Fail(lane.staves == 1 ? '“${lane.name}” is on one staff.' : '“${lane.name}” is on ${lane.staves} staves.');
            if ({...hidden}.length >= lane.staves) throw _Fail('That leaves “${lane.name}” no staff.');
          }
          run.edit(found, (lane, regions) {
            for (final s in stretches) {
              regions = _Run.shown(regions, Region(s.start, s.end, transitionIn: fadeIn.seconds, transitionOut: fadeOut.seconds).withHiddenStaves(lane.staff == null ? hidden : const []));
            }
            return regions;
          });
        };
      case 'hide' || 'only':
        final lanes = _lanes(), ranges = _ranges();
        _end();
        final only = first.text == 'only';
        return (run) {
          final found = run.resolve(lanes), stretches = run.stretches(ranges), named = {for (final lane in found) lane.id};
          run.edit(only ? run.lanes : found, (lane, regions) {
            for (final s in stretches) {
              regions = only && named.contains(lane.id) ? _Run.shown(regions, s) : Curation.painted(regions, s, shown: false);
            }
            return regions;
          });
        };
      case 'clear' || 'auto':
        final lanes = _atTerm ? _lanes() : null;
        _end();
        final auto = first.text == 'auto';
        return (run) {
          final found = lanes == null ? run.lanes : run.resolve(lanes);
          if (!auto) {
            run.edit(found, (_, _) => const []);
          } else if (!run.dry && !run.host.autoCurate([for (final lane in found) lane.id])) {
            throw const _Fail('This score’s lanes can’t be auto-curated.');
          }
        };
      case 'follow':
        final lanes = _atTerm ? _lanes() : null, ranges = _ranges();
        final bridge = _take('bridge') ? _whole('A number of bars') : 0;
        _end();
        return (run) {
          final found = lanes == null ? run.lanes : run.resolve(lanes), stretches = run.stretches(ranges);
          if (!run.host.curates) throw const _Fail('This score’s lanes can’t be auto-curated.');
          if (run.dry) return;
          final starts = run.beats.measureStarts, bars = starts.length - 1;
          final playing = {for (final lane in found) lane.id: run.host.playing(lane.id)};
          run.edit([for (final lane in found) if (playing[lane.id] != null) lane], (lane, regions) {
            // Where it plays, a rest of up to [bridge] bars between two runs kept: Auto-Curate's own.
            final runs = [
              for (final (first, end) in autoCurateMeasures(playing[lane.id]!, bridge: bridge))
                if (first < bars) Region(starts[first], starts[math.min(end, bars)]),
            ];
            if (ranges.isEmpty) return runs;
            for (final s in stretches) {
              regions = Curation.painted(regions, s, shown: false);
              for (final r in runs) {
                if (r.overlaps(s)) regions = _Run.shown(regions, Region(math.max(r.start, s.start), math.min(r.end, s.end)));
              }
            }
            return regions;
          });
        };
      case 'fit':
        final lanes = _atTerm ? _lanes() : null;
        final phrase = _take('phrase') ? _whole('A number of bars') : 4;
        if (phrase < 1) throw const _Fail('A phrase is a bar at least.');
        _end();
        return (run) {
          final found = lanes == null ? run.lanes : run.resolve(lanes);
          if (!run.host.curates) throw const _Fail('This score’s lanes can’t be auto-curated.');
          if (run.dry) return;
          final hide = run.host.fit([for (final lane in found) lane.id], phrase: phrase);
          run.edit([for (final lane in found) if (hide[lane.id]?.isNotEmpty ?? false) lane], (lane, regions) {
            for (final r in hide[lane.id]!) {
              regions = Curation.painted(regions, r, shown: false);
            }
            return regions;
          });
        };
      case 'bridge' || 'remove':
        final bridge = first.text == 'bridge';
        _need(bridge ? 'rests' : 'short');
        final bars = _number('A number of bars', max: 1000);
        final lanes = _take('in') ? _lanes() : null;
        _end();
        return (run) {
          final ids = [for (final lane in lanes == null ? run.lanes : run.resolve(lanes)) lane.id];
          if (run.dry) return;
          final starts = run.beats.measureStarts;
          bridge ? run.curation.fillGaps(starts, bars, partIds: ids) : run.curation.removeShort(starts, bars, partIds: ids);
        };
      case 'copy':
        final from = _lanes();
        _need('to');
        final to = _lanes();
        _end();
        return (run) {
          final sources = run.resolve(from);
          if (sources.length > 1) throw _Fail('One lane is copied, and that names ${sources.length}.');
          final targets = [for (final lane in run.resolve(to)) if (lane.id != sources.single.id) lane.id];
          if (!run.dry) run.curation.copyLane(sources.single.id, targets);
        };
      case 'split' || 'join':
        final lanes = _lanes();
        _end();
        final strict = !(lanes.include.length == 1 && lanes.include.single.all && lanes.exclude.isEmpty);
        return (run) => run.split(run.resolve(lanes), on: first.text == 'split', strict: strict);
      case 'move':
        final lanes = _lanes();
        _Lanes? before, after;
        var top = false;
        if (_take('to')) {
          top = _take('top');
          if (!top) _need('bottom');
        } else if (_take('before')) {
          before = _lanes();
        } else if (_take('after')) {
          after = _lanes();
        } else {
          _wanted('“to top”, “to bottom”, “before” or “after”');
        }
        _end();
        return (run) => run.move(run.resolve(lanes), before: before == null ? null : run.one(before), after: after == null ? null : run.one(after), top: top);
      case 'restore':
        _need('order');
        _end();
        return (run) {
          if (!run.dry) run.host.restoreOrder();
        };
      case 'transition':
        if (_next?.kind == _Kind.number) {
          final seconds = _number('Seconds', max: _maxSeconds);
          _end();
          return (run) {
            if (!run.dry) run.curation.transition = seconds;
          };
        }
        final lanes = _lanes(), ranges = _ranges();
        final (fadeIn, fadeOut) = _is('default') ? _fades(both: true) : _fades(both: false);
        _end();
        return (run) {
          final found = run.resolve(lanes), stretches = run.stretches(ranges);
          run.edit(found, (_, regions) => [
                for (final r in regions)
                  Region(r.start, r.end,
                      transitionIn: fadeIn.given && stretches.any((s) => r.start >= s.start - 1e-9 && r.start < s.end - 1e-9) ? fadeIn.seconds : r.transitionIn,
                      transitionOut: fadeOut.given && stretches.any((s) => r.end > s.start + 1e-9 && r.end <= s.end + 1e-9) ? fadeOut.seconds : r.transitionOut,
                      hiddenStaves: r.hiddenStaves),
              ]);
        };
      default: // let
        final name = _next;
        if (name == null || name.kind != _Kind.word) _wanted('A name for the lanes');
        if (LaneScript.keywords.contains(name.text)) throw _Fail('“${name.text}” is a word of the language: call them something else.');
        _at++;
        _need('=');
        final lanes = _lanes();
        _end();
        return (run) {
          run.resolve(lanes);
          run.groups[name.text] = lanes;
        };
    }
  }
}
