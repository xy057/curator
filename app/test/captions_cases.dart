// What the Captions extension is put through, and what is written down of it: edits made at
// random, subtitle files made at random, projects that are damaged, scores that are replaced.
// The app's own captions were put through the same before the package took their place; what
// they gave is the digests in captions_extension_test.dart.
import 'dart:convert';
import 'dart:math';

import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/extensions/extension_reader.dart';
import 'package:curated_score/project_modules.dart';
import 'package:curated_score/project_state.dart';
import 'package:curated_score/score_replacement.dart';
import 'package:score_engine/score_engine.dart';

/// A caption: where it starts and ends (quarters) and its text.
typedef Cap = (double start, double end, String text);

/// A subtitle: when it starts and ends (seconds) and its text.
typedef Cue = (double start, double end, String text);

/// [v] kept from [low] to [high]; as it is when they are the wrong way round.
double within(double v, double low, double high) => high < low ? v : v.clamp(low, high);

void noFiles(String entry, List<int> bytes, {bool compress = true}) {}

/// What changes the captions: the extension's own functions.
abstract class CaptionSide {
  void add(Cap caption);
  void update(int index, Cap caption);
  void replaceAll(List<Cap> captions);
  void remove([int? index]);
  int? get selected;
  void select(int? index);

  /// A new caption from [quarter], among [among] (the captions by default); null: no room.
  (double, double)? draft(double quarter, [List<(double, double)>? among]);

  // The lane's drags.
  void laneBegin();
  void laneUpdate(int index, double start, double end);
  void laneReplaceAll(List<({int from, double start, double end})> pieces);

  /// The lane's stretches, each with its label.
  List<String> lane();
}

/// The project's captions module as it is saved.
String captionsModule(EditorController c) => jsonEncode(ProjectModules.captions.write(c.projectState, noFiles));

List<Cap> savedCaptions(EditorController c) => [
      for (final row in (jsonDecode(captionsModule(c)) as Map<String, Object?>)['captions']! as List<Object?>)
        if (row case [final num a, final num b, final String text]) (a.toDouble(), b.toDouble(), text),
    ];

const captionTexts = [
  'Hello', ' padded ', '*it* and **bold**', '', '   ', 'Line\nbreak', '5 * 3', r'\*star', '***both*** ends', 'Tab\there', '中文 字幕', 'é', //
  'A long one that goes on and on, far past what a lane has room for, to the very end',
];

/// [steps] edits made at random on [side], each written down with what the project then saves,
/// what is selected, what the lane and the scene show, and where a new caption would go.
String captionEdits(CaptionSide side, EditorController c, Random random, int steps) {
  final out = StringBuffer();
  final total = c.beats.totalQuarters, end = c.timeline.endSeconds;
  double place() => switch (random.nextInt(5)) {
        0 => random.nextInt(total.ceil() + 4) - 2.0,
        1 => random.nextInt((total * 2).ceil()) / 2,
        2 => random.nextDouble() * total,
        3 => c.beats.measureStarts[random.nextInt(c.beats.measureStarts.length)],
        _ => random.nextInt((total * 4).ceil()) / 4,
      };
  Cap caption() {
    final start = place();
    return (start, start + const [0.25, 0.5, 1.0, 2.0, 4.0, 7.5, 16.0, -1.0, 0.0][random.nextInt(9)], captionTexts[random.nextInt(captionTexts.length)]);
  }

  for (var step = 0; step < steps; step++) {
    final saved = savedCaptions(c), n = saved.length;
    final String did;
    switch (random.nextInt(14)) {
      case 0 || 1 || 2:
        final cap = caption();
        side.add(cap);
        did = 'add $cap';
      case 3 || 4:
        final index = random.nextInt(n + 2) - 1, cap = n > 0 && random.nextBool() ? (saved[random.nextInt(n)].$1, saved[random.nextInt(n)].$2, captionTexts[random.nextInt(captionTexts.length)]) : caption();
        side.update(index, cap);
        did = 'update $index $cap';
      case 5:
        final list = [
          for (final cap in saved)
            if (random.nextInt(5) > 0) random.nextInt(4) == 0 ? (cap.$1, cap.$2 + random.nextInt(5) - 1, random.nextInt(3) == 0 ? '' : cap.$3) : cap,
          if (random.nextBool()) caption(),
        ];
        if (random.nextBool()) list.shuffle(random);
        side.replaceAll(list);
        did = 'replaceAll $list';
      case 6:
        final index = random.nextInt(4) == 0 ? null : random.nextInt(n + 2) - 1;
        side.remove(index);
        did = 'remove $index';
      case 7 || 8:
        final index = n == 0 || random.nextInt(4) == 0 ? null : random.nextInt(n);
        side.select(index);
        did = 'select $index';
      case 9 || 10:
        // A drag in the lane: one caption moved or trimmed, step by step, between its neighbours.
        if (n == 0) {
          did = 'drag (none)';
          break;
        }
        final index = random.nextInt(n), cap = saved[index];
        side.laneBegin();
        side.select(index);
        final room = [for (final (i, o) in saved.indexed) if (i != index) o];
        final low = room.where((o) => o.$2 <= cap.$1 + 1e-9).fold(0.0, (m, o) => max(m, o.$2)), high = room.where((o) => o.$1 >= cap.$2 - 1e-9).fold(total, (m, o) => min(m, o.$1));
        final moves = <String>[];
        for (var k = random.nextInt(4); k >= 0; k--) {
          var start = cap.$1, stop = cap.$2;
          switch (random.nextInt(3)) {
            case 0:
              final by = (random.nextInt(9) - 4) / 2;
              final d = within(by, low - cap.$1, high - cap.$2);
              start += d;
              stop += d;
            case 1:
              start = within(cap.$1 + (random.nextInt(9) - 4) / 4, low, cap.$2 - 0.25);
            default:
              stop = within(cap.$2 + (random.nextInt(9) - 4) / 4, cap.$1 + 0.25, high);
          }
          side.laneUpdate(index, start, stop);
          moves.add('$start–$stop');
        }
        did = 'drag $index $moves';
      case 11:
        // The Erase tool: every caption as it is left, some cut, some gone.
        side.laneBegin();
        final pieces = <({int from, double start, double end})>[];
        for (final (i, cap) in saved.indexed) {
          switch (random.nextInt(5)) {
            case 0:
              break;
            case 1:
              final cut = cap.$1 + (cap.$2 - cap.$1) * random.nextDouble();
              pieces.add((from: i, start: cap.$1, end: cut));
              if (random.nextBool()) pieces.add((from: i, start: (cut + cap.$2) / 2, end: cap.$2));
            default:
              pieces.add((from: i, start: cap.$1, end: cap.$2));
          }
        }
        if (random.nextInt(6) == 0) pieces.add((from: n + 1, start: 0, end: 1));
        side.laneReplaceAll(pieces);
        did = 'erase $pieces';
      case 12:
        if (c.canUndo) c.undo();
        did = 'undo';
      default:
        if (c.canRedo) c.redo();
        did = 'redo';
    }
    final q = place(), seconds = random.nextDouble() * end;
    final among = random.nextInt(3) == 0 ? [for (final cap in savedCaptions(c)) if (random.nextBool()) (cap.$1, cap.$2)] : null;
    out
      ..writeln('$step $did')
      ..writeln('  ${captionsModule(c)}')
      ..writeln('  selected ${side.selected} lane ${side.lane()}')
      ..writeln('  scene ${c.sceneSettings.captions} showing ${c.scene?.captionShowingAt(seconds)}')
      ..writeln('  draft $q ${side.draft(q)} among $among ${among == null ? '' : side.draft(q, among)} undo ${c.canUndo} ${c.canRedo}');
  }
  return out.toString();
}

/// What reads and writes subtitle files.
abstract class SubtitleSide {
  /// The cues of a file; a [FormatException] with what it says when it has none.
  List<Cue> parse(String source);
  String write(List<Cue> cues, String format);
  List<Cap> fromCues(List<Cue> cues);
  List<Cue> cues(List<Cap> captions, {double from = 0, double? to});
}

/// A subtitle file made at random: SubRip or WebVTT, with tags, entities, stray lines, timings
/// that don't read, cues that overlap.
String randomSubtitles(Random r) {
  const texts = [
    'Plain words', '<i>italic</i>', '<b> bold </b> after', '<i><b>both</b></i>', '<v Bob>hi there</v>', r'{\an8}top', '&amp; &lt;x&gt; &nbsp;&quot;q&apos;', //
    '&#233;&#x1F600;&#x110000;&bogus; &#99999999999;', '5 * 3 = 15', '**', '<i></i>gone', '< not a tag', '{ brace }', '<font color="red">red</font>', '<c.cls>k</c>',
    '<00:01.000>karaoke', '</i> stray', '<I>UP</I>', '<em>e</em> <strong>s</strong>', 'tab\there', '中文字幕', '  spaced  out  ', '<i>open', 'a<b>b<i>c</b>d</i>e',
    '<i> lead</i>', '<b>trail </b>x', '*star* <i>it</i>', r'back\slash', '<>', '<i><i>twice</i></i>', '{\\k20}ka{\\k30}ra', 'x<br/>y', '-->', '<b></b><i> </i>',
  ];
  String time(double t, int style) {
    final ms = (max(0.0, t) * 1000).round(), h = ms ~/ 3600000, m = ms ~/ 60000 % 60, s = ms ~/ 1000 % 60, f = ms % 1000;
    String two(int v) => v.toString().padLeft(2, '0');
    return switch (style) {
      0 => '${two(h)}:${two(m)}:${two(s)},${f.toString().padLeft(3, '0')}',
      1 => '${two(h * 60 + m)}:${two(s)}.${f.toString().padLeft(3, '0')}',
      2 => '$h:${two(m)}:${two(s)}.${f ~/ 100}',
      3 => '${two(m)}:${two(s)},${(f ~/ 10).toString().padLeft(2, '0')}',
      4 => '$m:$s:$f', // doesn't read
      _ => '${two(h)}:${two(m)}:${two(s)}.${f.toString().padLeft(3, '0')}',
    };
  }

  final vtt = r.nextBool(), nl = const ['\n', '\n', '\r\n', '\r'][r.nextInt(4)];
  final out = StringBuffer();
  if (r.nextInt(6) == 0) out.write('﻿');
  if (vtt) out.write('WEBVTT${r.nextBool() ? ' - a title' : ''}$nl$nl');
  if (vtt && r.nextInt(3) == 0) out.write('NOTE a comment${nl}still the comment$nl$nl');
  if (vtt && r.nextInt(4) == 0) out.write('STYLE$nl::cue { color: red }$nl$nl');
  var t = r.nextDouble() * 5;
  for (var n = r.nextInt(9), k = 1; n > 0; n--, k++) {
    final length = r.nextInt(8) == 0 ? -0.5 : 0.3 + r.nextDouble() * 6, style = r.nextInt(12) == 0 ? 4 : r.nextInt(vtt ? 6 : 4) % 6;
    if (!vtt || r.nextBool()) out.write('${r.nextInt(10) == 0 ? 'cue-$k' : k}$nl');
    out.write('${r.nextInt(8) == 0 ? '  ' : ''}${time(t, style)}${const [' --> ', '-->', '  -->  ', ' -> '][r.nextInt(20) == 0 ? 3 : r.nextInt(3)]}${time(t + length, style)}'
        '${vtt && r.nextInt(4) == 0 ? ' line:0 position:20%' : ''}$nl');
    for (var lines = r.nextInt(4); lines > 0; lines--) {
      out.write('${r.nextInt(6) == 0 ? ' ' : ''}${texts[r.nextInt(texts.length)]}${r.nextInt(3) == 0 ? ' ${texts[r.nextInt(texts.length)]}' : ''}$nl');
    }
    if (r.nextInt(7) > 0) out.write(nl);
    if (r.nextInt(9) == 0) out.write('$nl$nl');
    t += max(0.0, length) + (r.nextInt(3) == 0 ? -1 : r.nextDouble() * 2);
  }
  return out.toString();
}

String _cues(List<Cue> cues) => [for (final (a, b, text) in cues) '$a|$b|$text'].join('\n');

/// [count] subtitle files made at random, each written down as [side] reads it, writes it back
/// either way, places it in the score, and gives it as the subtitles of a video.
String subtitleFiles(SubtitleSide side, Random random, int count, {required double end}) {
  final out = StringBuffer();
  for (var i = 0; i < count; i++) {
    final source = randomSubtitles(random);
    out.writeln('file $i');
    final List<Cue> cues;
    try {
      cues = side.parse(source);
    } on FormatException catch (e) {
      out.writeln('  ${e.message}');
      continue;
    }
    final captions = side.fromCues(cues);
    final from = random.nextDouble() * end / 2, to = from + random.nextDouble() * end / 2;
    out
      ..writeln(_cues(cues))
      ..writeln(side.write(cues, 'srt'))
      ..writeln(side.write(cues, 'vtt'))
      ..writeln('captions $captions')
      ..writeln(_cues(side.cues(captions)))
      ..writeln('$from–$to')
      ..writeln(_cues(side.cues(captions, from: from, to: to)))
      ..writeln(side.write(side.cues(captions, from: from, to: to), 'vtt'));
  }
  return out.toString();
}

/// What a project whose captions module is [json] opens as: its captions as saved again, or
/// what is said of it when it is damaged.
String readCaptions(Object? json) {
  try {
    final state = ProjectModules.captions.read(JsonReader(json, 'captions'), const ProjectState(), (entry, {required limit}) => null);
    return jsonEncode(ProjectModules.captions.write(checkedExtensionData(state), noFiles));
  } on FormatException catch (e) {
    return e.message;
  }
}

/// Captions modules to open: some as they should be, some damaged, some made at random.
List<Object?> captionModules(Random random) => [
      {'captions': <Object?>[]},
      {'captions': 5},
      <String, Object?>{},
      {
        'captions': [[0, 16, 'One'], [4.0, 8.5, ' two '], [2, 3, '*three*']],
      },
      for (final entry in <Object?>[
        [-1, 4, 'x'], [4, 4, 'x'], [5, 4, 'x'], [0, 4, ''], [0, 4, '  '], [0, 4], [0, 4, 'x', 'y'], [0, 4, 5], [0, 4, null], ['0', 4, 'x'], [0, null, 'x'], //
        [1e12, 2e12, 'x'], [0, 1e12, 'x'], [-1e12, 4, 'x'], null, 5, 'x', {'start': 0}, <Object?>[], [0.5, 1.5, 'x'], [-2, -4, 'x'], [2, 2.0000000001, 'x'],
      ])
        {
          'captions': [[0, 8, 'first'], entry],
        },
      for (var i = 0; i < 60; i++)
        {
          'captions': [
            for (var k = random.nextInt(8); k > 0; k--)
              [random.nextInt(40) * (random.nextBool() ? 1 : 0.5), random.nextInt(60) + 0.25, captionTexts[random.nextInt(captionTexts.length)]],
          ],
        },
    ];

/// Bars of 4 quarters that become bars of 3, the score ending at bar 6.
final barsBefore = [for (var i = 0; i <= 12; i++) i * 4.0], barsAfter = [for (var i = 0; i <= 6; i++) i * 3.0];

double? carriedQuarter(double q) => ScoreSwap.quarterAt(q, barsBefore, barsAfter);

/// Lists of captions made at random, for a score that is replaced.
List<List<Cap>> captionsToCarry(Random random) => [
      for (var i = 0; i < 80; i++)
        [
          for (var k = random.nextInt(6); k > 0; k--)
            if (random.nextInt(48) * 1.0 case final start) (start, start + 1 + random.nextInt(20), 'c$k'),
        ],
    ];
