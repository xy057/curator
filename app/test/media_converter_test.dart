import 'dart:convert';
import 'dart:io';

import 'package:curated_score/media_converter.dart';
import 'package:flutter_test/flutter_test.dart';

const _video = 'test/fixtures/tiny-video.mp4';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('convert-test-'));
  tearDown(() => dir.deleteSync(recursive: true));

  bool isFlac(String path) => ascii.decode(File(path).readAsBytesSync().sublist(0, 4)) == 'fLaC';

  final ffmpeg = MediaConverter.findFfmpeg();

  test('FFmpeg (what Windows and Linux use) takes the sound out of a video as FLAC', () async {
    final out = '${dir.path}/tiny.flac';
    final r = await Process.run(ffmpeg!, MediaConverter.ffmpegArguments(_video, out));
    expect(r.exitCode, 0, reason: '${r.stderr}');
    expect(isFlac(out), isTrue);
  }, skip: ffmpeg == null ? 'FFmpeg is not installed here' : false);

  test('FFmpeg fails clearly on a file without sound', () async {
    final silent = '${dir.path}/silent.mp4';
    await Process.run(ffmpeg!, ['-y', '-loglevel', 'error', '-i', _video, '-an', '-c:v', 'copy', silent]);
    final r = await Process.run(ffmpeg, MediaConverter.ffmpegArguments(silent, '${dir.path}/x.flac'));
    expect(r.exitCode, isNot(0));
  }, skip: ffmpeg == null ? 'FFmpeg is not installed here' : false);

  test('FFmpeg reads every kind of recording the app takes, and nothing that would open other files', () async {
    for (final ext in MediaFormats.all) {
      final take = '${dir.path}/take.$ext';
      final codec = switch (ext) {
        'webm' || 'ogg' || 'opus' => ['-c:a', 'libopus'],
        'mp3' => ['-c:a', 'libmp3lame'],
        'wav' || 'aif' || 'aiff' || 'caf' => <String>[],
        'flac' => ['-c:a', 'flac'],
        _ => ['-c:a', 'aac'],
      };
      final format = switch (ext) { 'aif' => ['-f', 'aiff'], 'opus' => ['-f', 'ogg'], _ => <String>[] };
      final made = await Process.run(ffmpeg!, ['-y', '-loglevel', 'error', '-i', _video, '-vn', ...codec, ...format, take]);
      if (made.exitCode != 0) continue; // this FFmpeg can't write it
      final r = await Process.run(ffmpeg, MediaConverter.ffmpegArguments(take, '${dir.path}/$ext.flac'));
      expect(r.exitCode, 0, reason: '.$ext: ${r.stderr}');
    }

    // A playlist (HLS) has FFmpeg open the files and addresses it lists.
    final playlist = File('${dir.path}/take.m3u8')
      ..writeAsStringSync('#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\n${File(_video).absolute.path}\n#EXT-X-ENDLIST\n');
    final r = await Process.run(ffmpeg!, MediaConverter.ffmpegArguments(playlist.path, '${dir.path}/list.flac'));
    expect(r.exitCode, isNot(0));
    expect('${r.stderr}', contains('whitelist'));
  }, skip: ffmpeg == null ? 'FFmpeg is not installed here' : false);

  test('toFlac converts with whatever this machine has', () async {
    final out = await MediaConverter.toFlac(_video, '${dir.path}/out');
    expect(out, '${dir.path}/out${Platform.pathSeparator}tiny-video.flac');
    expect(isFlac(out), isTrue);
  }, skip: Platform.isMacOS || ffmpeg != null ? false : 'no converter here');

  test("when afconvert can't read a file (MKV), FFmpeg takes over", () async {
    final mkv = '${dir.path}/take.mkv';
    await Process.run(ffmpeg!, ['-y', '-loglevel', 'error', '-i', _video, '-c', 'copy', mkv]);
    expect(isFlac(await MediaConverter.toFlac(mkv, '${dir.path}/out')), isTrue);
  }, skip: ffmpeg == null ? 'FFmpeg is not installed here' : false);

  group('finding FFmpeg on Windows', () {
    const env = {
      'Path': r'C:\Windows\System32;C:\Tools\bin;',
      'LOCALAPPDATA': r'C:\Users\ana\AppData\Local',
      'USERPROFILE': r'C:\Users\ana',
    };
    String? find(Set<String> files, {Map<String, String> environment = env}) => MediaConverter.findFfmpeg(
          windows: true,
          environment: environment,
          appDirectory: r'C:\Program Files\Curator',
          exists: files.contains,
        );

    test('next to the app first', () {
      expect(find({r'C:\Program Files\Curator\ffmpeg.exe', r'C:\Tools\bin\ffmpeg.exe'}),
          r'C:\Program Files\Curator\ffmpeg.exe');
    });

    test('then on PATH (whatever its case)', () {
      expect(find({r'C:\Tools\bin\ffmpeg.exe'}), r'C:\Tools\bin\ffmpeg.exe');
    });

    test('then where winget, Scoop and Chocolatey install it', () {
      expect(find({r'C:\Users\ana\AppData\Local\Microsoft\WinGet\Links\ffmpeg.exe'}),
          r'C:\Users\ana\AppData\Local\Microsoft\WinGet\Links\ffmpeg.exe');
      expect(find({r'C:\Users\ana\scoop\shims\ffmpeg.exe'}), r'C:\Users\ana\scoop\shims\ffmpeg.exe');
      expect(find({r'C:\ProgramData\chocolatey\bin\ffmpeg.exe'}), r'C:\ProgramData\chocolatey\bin\ffmpeg.exe');
    });

    test('null when missing, and the help says how to install it', () {
      expect(find({}), isNull);
      expect(MediaConverter.missingFfmpegHelp(windows: true), contains('winget install Gyan.FFmpeg'));
    });
  });

  test('on macOS, Homebrew FFmpeg is found although a GUI app has no shell PATH', () {
    expect(
      MediaConverter.findFfmpeg(
        windows: false,
        environment: const {'PATH': '/usr/bin:/bin'},
        appDirectory: '/Applications/Curator.app/Contents/MacOS',
        exists: {'/opt/homebrew/bin/ffmpeg'}.contains,
      ),
      '/opt/homebrew/bin/ffmpeg',
    );
  });
}
