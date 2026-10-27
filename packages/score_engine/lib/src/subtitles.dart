import 'dart:convert';
import 'dart:math' as math;

import 'score_caption.dart';
import 'scroll_map.dart';

/// A subtitle: [text] from [start] to [end] seconds. Its text uses captions' markup
/// (`*italic*`, `**bold**`); lines are joined by spaces, as a caption wraps on its own.
typedef SubtitleCue = ({double start, double end, String text});

/// The subtitle files Captions reads and writes.
enum SubtitleFormat {
  srt('SubRip', 'srt'),
  vtt('WebVTT', 'vtt');

  const SubtitleFormat(this.label, this.extension);
  final String label, extension;

  /// By a file's extension (either case); null for another.
  static SubtitleFormat? ofPath(String path) {
    final dot = path.lastIndexOf('.');
    final ext = dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
    return values.where((f) => f.extension == ext).firstOrNull;
  }
}

/// Thrown when a file has no cue that can be read.
class SubtitleException implements Exception {
  const SubtitleException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The largest subtitle file read: an hour of dense subtitles is some 100 KB.
const maxSubtitleBytes = 8 << 20;

/// A subtitle file's text: UTF-8, UTF-16 by its byte-order mark, else Windows Latin-1 (as
/// older SRT files are).
String decodeSubtitles(List<int> bytes) {
  if (bytes.length > maxSubtitleBytes) throw const SubtitleException('This subtitle file is too large.');
  if (bytes.length >= 2 && ((bytes[0] == 0xFF && bytes[1] == 0xFE) || (bytes[0] == 0xFE && bytes[1] == 0xFF))) {
    final little = bytes[0] == 0xFF;
    return String.fromCharCodes([
      for (var i = 2; i + 1 < bytes.length; i += 2) little ? bytes[i] | bytes[i + 1] << 8 : bytes[i] << 8 | bytes[i + 1],
    ]);
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return latin1.decode(bytes);
  }
}

final _timing =RegExp(r'^\s*((?:\d+:)?\d{1,2}:\d{2}[.,]\d{1,3})\s*-->\s*((?:\d+:)?\d{1,2}:\d{2}[.,]\d{1,3})');

/// "01:02:03,456", "02:03.456" (WebVTT may leave out the hours): seconds.
double? _seconds(String s) {
  final parts = s.replaceAll(',', '.').split(':');
  var total = 0.0;
  for (final part in parts) {
    final v = double.tryParse(part);
    if (v == null) return null;
    total = total * 60 + v;
  }
  return total;
}

/// The cues of an SRT or WebVTT file, in order, either way it's written. `<i>` and `<b>`
/// become captions' markup; other tags (voices, classes, colours, karaoke times, `{\an8}`)
/// go, and HTML entities are read. Blocks without a timing (WebVTT's header, NOTE, STYLE,
/// REGION; an SRT's stray lines) are passed over. Throws [SubtitleException] when no cue is left.
List<SubtitleCue> parseSubtitles(String source) {
  final lines = source.replaceFirst('﻿', '').replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
  final cues = <SubtitleCue>[];
  for (var i = 0; i < lines.length; i++) {
    final m = _timing.firstMatch(lines[i]);
    if (m == null) continue;
    final start = _seconds(m[1]!), end = _seconds(m[2]!);
    final text = <String>[];
    while (i + 1 < lines.length && lines[i + 1].trim().isNotEmpty) {
      text.add(lines[++i].trim());
    }
    final said = _fromTags(text.join(' '));
    if (start != null && end != null && end > start && said.trim().isNotEmpty) {
      cues.add((start: start, end: end, text: said.trim()));
    }
  }
  if (cues.isEmpty) throw const SubtitleException('No subtitles found in this file.');
  return cues;
}

/// A cue's text with its tags turned into markup: a star typed in it stays a star. Spaces
/// just inside a tag move outside its marker (markup opens before a letter and closes after
/// one), and a tag around nothing goes.
String _fromTags(String text) {
  final parts = <String>[]; // plain text, '*' or '**'
  final open = {'*': false, '**': false};
  void mark(String marker, bool opening) {
    if (open[marker] == opening) return; // nested or stray: already so
    open[marker] = opening;
    if (!opening) {
      if (parts.lastOrNull == marker) {
        parts.removeLast(); // around nothing
        return;
      }
      // Its spaces after it.
      final last = parts.lastOrNull ?? '', trimmed = last.trimRight();
      if (!_isMarker(last) && trimmed.length < last.length) {
        parts
          ..[parts.length - 1] = trimmed
          ..add(marker)
          ..add(last.substring(trimmed.length));
        return;
      }
    }
    parts.add(marker);
  }

  for (final m in RegExp(r'<(/?)([a-zA-Z]+)[^>]*>|<[^>]*>|\{\\[^}]*\}|([^<{]+|[<{])').allMatches(text)) {
    if (m[3] case final raw?) {
      var plain = _entities(raw).replaceAll('*', r'\*');
      // Spaces after an opener go before it.
      if (_isMarker(parts.lastOrNull) && open[parts.last]!) {
        final trimmed = plain.trimLeft();
        if (trimmed.length < plain.length) {
          parts.insert(parts.length - 1, plain.substring(0, plain.length - trimmed.length));
          plain = trimmed;
        }
      }
      if (plain.isNotEmpty) parts.add(plain);
    } else if (m[2]?.toLowerCase() case final tag?) {
      if (tag == 'i' || tag == 'em') mark('*', m[1]!.isEmpty);
      if (tag == 'b' || tag == 'strong') mark('**', m[1]!.isEmpty);
    }
  }
  return parts.join().replaceAll(RegExp(r'\s+'), ' ');
}

bool _isMarker(String? s) => s == '*' || s == '**';

String _entities(String s) => s.replaceAllMapped(RegExp(r'&(amp|lt|gt|nbsp|quot|apos|#\d+|#x[0-9a-fA-F]+);'), (m) {
      final name = m[1]!;
      return switch (name) {
        'amp' => '&',
        'lt' => '<',
        'gt' => '>',
        'nbsp' => ' ',
        'quot' => '"',
        'apos' => "'",
        _ when name.startsWith('#x') => _character(int.tryParse(name.substring(2), radix: 16)),
        _ => _character(int.tryParse(name.substring(1))),
      };
    });

/// The character [code] names; the replacement character for none (past U+10FFFF, or too long).
String _character(int? code) => String.fromCharCode(code != null && code <= 0x10FFFF ? code : 0xFFFD);

/// [cues] as a file in [format]: numbered (SRT) or under its header (WebVTT), markup as `<i>`
/// and `<b>`.
String writeSubtitles(List<SubtitleCue> cues, SubtitleFormat format) {
  String time(double seconds) {
    final ms = (math.max(0.0, seconds) * 1000).round();
    String two(int v) => v.toString().padLeft(2, '0');
    final sep = format == SubtitleFormat.srt ? ',' : '.';
    return '${two(ms ~/ 3600000)}:${two(ms ~/ 60000 % 60)}:${two(ms ~/ 1000 % 60)}$sep${(ms % 1000).toString().padLeft(3, '0')}';
  }

  final out = StringBuffer(format == SubtitleFormat.vtt ? 'WEBVTT\n\n' : '');
  for (final (i, c) in cues.indexed) {
    if (format == SubtitleFormat.srt) out.writeln(i + 1);
    out
      ..writeln('${time(c.start)} --> ${time(c.end)}')
      ..writeln(_toTags(c.text, escape: format == SubtitleFormat.vtt))
      ..writeln();
  }
  return out.toString();
}

/// [text]'s markup as tags; [escape]: `&`, `<` and `>` as entities (WebVTT needs them; SRT
/// players mostly show them as typed).
String _toTags(String text, {required bool escape}) {
  final out = StringBuffer();
  var italic = false, bold = false;
  for (final run in captionRuns(text)) {
    // Closed and opened again around each run, so tags never cross.
    if (bold && !run.bold) out.write('</b>');
    if (italic && !run.italic) out.write('</i>');
    if (run.italic && !italic) out.write('<i>');
    if (run.bold && !bold) out.write('<b>');
    (italic, bold) = (run.italic, run.bold);
    out.write(escape ? run.text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;') : run.text);
  }
  if (bold) out.write('</b>');
  if (italic) out.write('</i>');
  return out.toString();
}

/// The captions as subtitles of a performance: each time its music sounds ([captionSpans]),
/// those between [from] and [to] seconds (clipped to them), timed from [from].
List<SubtitleCue> captionCues(List<Caption> captions, ScoreTimeline timeline, {double from = 0, double? to}) => [
      for (final s in captionSpans(captions, timeline))
        if (s.end > from + 1e-6 && (to == null || s.start < to - 1e-6))
          (
            start: math.max(s.start, from) - from,
            end: (to == null ? s.end : math.min(s.end, to)) - from,
            text: captions[s.caption].text,
          ),
    ];

/// [cues] as captions, each placed in the score where [timeline] has its music: a cue
/// heard again on a repeat gives the same caption, made once. Cues outside the music
/// ([total] score quarters) go, and those left are kept apart ([separateCaptions]).
List<Caption> captionsFromCues(List<SubtitleCue> cues, ScoreTimeline timeline, double total) {
  final seen = <Caption>{};
  for (final c in cues) {
    final a = timeline.quarterAtSeconds(c.start).clamp(0.0, total), b = timeline.quarterAtSeconds(c.end).clamp(0.0, total);
    // Rounded so a repeat's copy matches its first time to the millionth of a quarter.
    double r(double q) => (q * 1e6).roundToDouble() / 1e6;
    if (b - a > 1e-3) seen.add(Caption(r(a), r(b), c.text));
  }
  return separateCaptions([...seen]);
}
