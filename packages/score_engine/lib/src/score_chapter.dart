import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'scroll_map.dart';

/// A chapter (the Chapters extension): the music from score quarter [at] on, up to the next
/// chapter, named [name]. Nothing of it is drawn on the score: a video carries its chapters
/// for its player, a web page lists them.
@immutable
class Chapter {
  const Chapter(this.at, this.name);
  final double at;
  final String name;

  Chapter copyWith({double? at, String? name}) => Chapter(at ?? this.at, name ?? this.name);

  @override
  bool operator ==(Object other) => other is Chapter && other.at == at && other.name == name;
  @override
  int get hashCode => Object.hash(at, name);
  @override
  String toString() => 'Chapter($at, "$name")';
}

/// The longest name a chapter keeps.
const maxChapterName = 80;

/// [chapters] as they are kept: in the score's order, names trimmed (one without a name
/// goes), one to a place (of two at one place, the later in the list stays).
List<Chapter> tidyChapters(List<Chapter> chapters) {
  final byPlace = <int, Chapter>{};
  for (final c in chapters) {
    final name = c.name.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (name.isEmpty || !c.at.isFinite || c.at < 0) continue;
    // To the millionth of a quarter, as captions read from a file are placed.
    byPlace[(c.at * 1e6).round()] = Chapter(c.at, name.length > maxChapterName ? name.substring(0, maxChapterName) : name);
  }
  return [for (final key in byPlace.keys.toList()..sort()) byPlace[key]!];
}

/// A chapter as it sounds: [chapter] (an index into the chapters; -1: the music before the
/// first) from [start] to [end] seconds.
typedef ChapterSpan = ({int chapter, double start, double end});

/// The chapters in time, in order: at any moment the chapter is the last one starting at or
/// before the place in the score that sounds, so a repeat back into an earlier chapter is that
/// chapter again, and one inside a single chapter doesn't split it. They cover the whole
/// performance: the first from 0 (the silence before the music is its), the last to [end]
/// seconds (the end of the music by default). Empty without chapters.
List<ChapterSpan> chapterSpans(List<Chapter> chapters, ScoreTimeline timeline, {double? end}) => [
      for (final s in placeSpans([for (final c in chapters) c.at], timeline, end: end)) (chapter: s.index, start: s.start, end: s.end),
    ];

/// What sounds when, of things that each start at a place in the score ([starts], score
/// quarters) and run on to the next (chapters, key areas): [index] into [starts] (-1: the music
/// before the first) from [start] to [end] seconds, in order. See [chapterSpans].
List<({int index, double start, double end})> placeSpans(List<double> starts, ScoreTimeline timeline, {double? end}) {
  if (starts.isEmpty) return const [];
  final order = [for (var i = 0; i < starts.length; i++) i]..sort((a, b) {
      final by = starts[a].compareTo(starts[b]);
      return by != 0 ? by : a.compareTo(b);
    });
  final out = <({int index, double start, double end})>[];
  void add(int index, double start, double end) {
    if (end - start <= 1e-6) return;
    if (out.lastOrNull case final last? when last.index == index) {
      out[out.length - 1] = (index: index, start: last.start, end: end);
    } else {
      out.add((index: index, start: start, end: end));
    }
  }

  for (final (k, p) in timeline.passes.indexed) {
    double seconds(double q) => timeline.secondsAtQuarter(q, pass: k);
    var from = p.start, current = -1;
    for (final i in order) {
      final at = starts[i];
      if (at >= p.end - 1e-9) break;
      if (at > p.start + 1e-9) {
        add(current, seconds(from), seconds(at));
        from = at;
      }
      current = i;
    }
    add(current, seconds(from), seconds(p.end));
  }
  if (out.isEmpty) return out;
  if (out.first.start > 0) out[0] = (index: out.first.index, start: 0, end: out.first.end);
  end ??= timeline.endSeconds;
  if (end > out.last.end) out[out.length - 1] = (index: out.last.index, start: out.last.start, end: end);
  return out;
}

/// A chapter of a video: [name] from [start] to [end] seconds.
typedef ChapterCue = ({double start, double end, String name});

/// The chapters of a video showing [from]–[to] seconds of a performance, timed from [from]:
/// they cover it whole, as players expect, so the one under way at [from] starts with the
/// video, and music before the first chapter is one named [opening]. Empty when no chapter
/// sounds in it.
List<ChapterCue> chapterCues(List<Chapter> chapters, ScoreTimeline timeline,
    {double from = 0, required double to, required String opening}) {
  final spans = [
    for (final s in chapterSpans(chapters, timeline, end: to))
      if (s.end > from + 1e-6 && s.start < to - 1e-6) s,
  ];
  if (spans.every((s) => s.chapter < 0)) return const [];
  return [
    for (final s in spans)
      (start: math.max(s.start, from) - from, end: math.min(s.end, to) - from, name: s.chapter < 0 ? opening : chapters[s.chapter].name),
  ];
}

/// [cues] as the list of times a video's description takes, a line each ("0:00 Opening"):
/// m:ss, or h:mm:ss throughout once the last starts an hour in.
String chapterTimestamps(List<ChapterCue> cues) {
  final hours = cues.isNotEmpty && cues.last.start >= 3600;
  String two(int v) => v.toString().padLeft(2, '0');
  String time(double seconds) {
    final s = seconds.floor(); // never past where it starts
    return hours ? '${s ~/ 3600}:${two(s ~/ 60 % 60)}:${two(s % 60)}' : '${s ~/ 60}:${two(s % 60)}';
  }

  return [for (final c in cues) '${time(c.start)} ${c.name}\n'].join();
}

/// [cues] as an FFmpeg metadata file (`-f ffmetadata`), which a movie's chapters are read
/// from: times in milliseconds, each ending where the next starts.
String chapterMetadata(List<ChapterCue> cues) {
  // "=", ";", "#", "\" and a newline are escaped with a backslash.
  String escaped(String s) => s.replaceAllMapped(RegExp(r'[=;#\\\n]'), (m) => '\\${m[0]}');
  final out = StringBuffer(';FFMETADATA1\n');
  for (final c in cues) {
    final start = (c.start * 1000).round(), end = math.max(start + 1, (c.end * 1000).round());
    out
      ..writeln('[CHAPTER]')
      ..writeln('TIMEBASE=1/1000')
      ..writeln('START=$start')
      ..writeln('END=$end')
      ..writeln('title=${escaped(c.name)}');
  }
  return out.toString();
}
