import 'dart:io';

/// The recordings the app takes, by what it does with them. The one list every part of the
/// app (the player, the file picker, drag and drop) goes by.
abstract final class MediaFormats {
  /// Audio the player reads as it is.
  static const playable = {'wav', 'mp3', 'flac', 'ogg', 'opus'};

  /// Audio converted to FLAC first ([MediaConverter]).
  static const convertedAudio = {'m4a', 'aac', 'aif', 'aiff', 'caf'};

  /// Video: only its soundtrack is used, converted to FLAC.
  static const video = {'mp4', 'mov', 'm4v', 'mkv', 'webm', 'avi'};

  /// Everything that can be loaded as the recording.
  static const all = {...playable, ...convertedAudio, ...video};

  static String extensionOf(String path) => path.split('.').last.toLowerCase();
  static bool isPlayable(String path) => playable.contains(extensionOf(path));
  static bool isVideo(String path) => video.contains(extensionOf(path));
  static bool isRecording(String path) => all.contains(extensionOf(path));

  /// FFmpeg's readers for [all] (`mov,mp4,…` is one reader, by FFmpeg's name for it). Given
  /// before a recording's `-i`, FFmpeg reads it with one of these or not at all: never as a
  /// playlist or anything else that would have it open other files or addresses.
  static const ffmpegReaders = ['-format_whitelist', 'mov,mp4,m4a,3gp,3g2,mj2,matroska,webm,avi,aac,aiff,caf,mp3,wav,flac,ogg'];

  /// MIDI files: not a recording, but a tempo map the sync can follow.
  static const midi = {'mid', 'midi', 'smf', 'rmi'};
  static bool isMidi(String path) => midi.contains(extensionOf(path));
}

/// Turns recordings SoLoud can't read (videos, AAC/M4A, AIFF, CAF…) into FLAC audio.
///
/// FLAC is lossless, so sound that is already compressed (a video's AAC) isn't degraded a
/// second time, and SoLoud plays it directly on every platform.
///
/// Tools, tried in order:
///  * macOS: the built-in `afconvert` (MP4, MOV, M4A, AIFF, CAF…);
///  * FFmpeg, anywhere: bundled next to the app, on PATH, or where winget, Scoop,
///    Chocolatey or Homebrew put it (see [findFfmpeg]). Windows and Linux rely on it.
abstract final class MediaConverter {
  /// Converts [input] (its first sound track) to `<directory>/<name>.flac` and returns that path.
  static Future<String> toFlac(String input, String directory) async {
    await Directory(directory).create(recursive: true);
    final name = input.split(RegExp(r'[/\\]')).last;
    final dot = name.lastIndexOf('.');
    final output = '$directory${Platform.pathSeparator}${dot > 0 ? name.substring(0, dot) : name}.flac';

    final problems = <String>[];
    if (Platform.isMacOS) {
      final r = await Process.run('/usr/bin/afconvert', ['-f', 'flac', '-d', 'flac', input, output]);
      if (r.exitCode == 0) return output;
      problems.add('afconvert: ${'${r.stderr}'.trim()}');
    }
    final ffmpeg = findFfmpeg();
    if (ffmpeg == null) {
      if (problems.isEmpty) throw MediaConversionException(missingFfmpegHelp(), input);
      problems.add(missingFfmpegHelp()); // afconvert failed; FFmpeg reads more formats
    } else {
      final r = await Process.run(ffmpeg, ffmpegArguments(input, output));
      if (r.exitCode == 0) return output;
      problems.add('ffmpeg: ${_lastLines('${r.stderr}')}');
    }
    throw MediaConversionException('The sound could not be read from this file.\n${problems.join('\n')}', input);
  }

  /// FFmpeg: the first sound track only (no video), as FLAC, overwriting, never waiting for input.
  static List<String> ffmpegArguments(String input, String output) =>
      ['-nostdin', '-hide_banner', '-loglevel', 'error', '-y', ...MediaFormats.ffmpegReaders, '-i', input, '-map', '0:a:0', '-vn', '-c:a', 'flac', output];

  /// Where FFmpeg is, or null. A GUI app doesn't see the PATH a terminal has (macOS), and on
  /// Windows a fresh `winget install` only reaches new processes' PATH, so the usual install
  /// locations are checked too. Parameters are for tests; they default to this machine.
  static String? findFfmpeg({
    bool? windows,
    Map<String, String>? environment,
    String? appDirectory,
    bool Function(String path)? exists,
  }) {
    final win = windows ?? Platform.isWindows;
    final env = environment ?? Platform.environment;
    final isFile = exists ?? (p) => File(p).existsSync();
    final exe = win ? 'ffmpeg.exe' : 'ffmpeg';
    final sep = win ? r'\' : '/';
    String? variable(String name) =>
        env[name] ?? env.entries.where((e) => e.key.toUpperCase() == name.toUpperCase()).firstOrNull?.value;
    String inDir(String dir) => dir.endsWith(sep) ? '$dir$exe' : '$dir$sep$exe';

    final candidates = <String>[
      // Shipped with the app (e.g. a Windows build with windows/ffmpeg/ffmpeg.exe).
      inDir(appDirectory ?? File(Platform.resolvedExecutable).parent.path),
      for (final dir in (variable('PATH') ?? '').split(win ? ';' : ':'))
        if (dir.trim().isNotEmpty) inDir(dir.trim()),
      if (win) ...[
        if (variable('LOCALAPPDATA') case final local?) '$local\\Microsoft\\WinGet\\Links\\$exe',
        if (variable('USERPROFILE') case final home?) '$home\\scoop\\shims\\$exe',
        '${variable('ProgramData') ?? r'C:\ProgramData'}\\chocolatey\\bin\\$exe',
        'C:\\ffmpeg\\bin\\$exe',
      ] else ...[
        '/opt/homebrew/bin/ffmpeg',
        '/usr/local/bin/ffmpeg',
        '/usr/bin/ffmpeg',
      ],
    ];
    return candidates.where(isFile).firstOrNull;
  }

  /// What to tell someone who needs FFmpeg, for their platform: [lead], then how to install it.
  static String missingFfmpegHelp({
    String lead = 'Videos and AAC/M4A audio need FFmpeg (free). Install it once, then load the recording again:',
    bool? windows,
    bool? linux,
  }) {
    if (windows ?? Platform.isWindows) return '$lead\n  winget install Gyan.FFmpeg';
    if (linux ?? Platform.isLinux) return '$lead\n  sudo apt install ffmpeg   (or your distribution\'s package)';
    return '$lead\n  brew install ffmpeg';
  }

  static String _lastLines(String text) => text.trim().split('\n').reversed.take(3).toList().reversed.join('\n');
}

class MediaConversionException implements Exception {
  const MediaConversionException(this.message, this.path);
  final String message;
  final String path;

  @override
  String toString() => message;
}
