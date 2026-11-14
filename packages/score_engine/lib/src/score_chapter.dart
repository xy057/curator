import 'dart:math' as math;

/// A chapter of a video or a web page: [name] from [start] to [end] seconds. An extension gives
/// them (`export.chapters`: the Chapters extension); what is here writes them as players read
/// them.
typedef ChapterCue = ({double start, double end, String name});

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
