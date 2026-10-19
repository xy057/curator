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
    expect(MediaFormats.isVideo('Take.MOV'), isTrue);
    expect(MediaFormats.isVideo('take.m4a'), isFalse);
  }, skip: Platform.isMacOS || ffmpeg != null ? false : 'no converter here');
}
