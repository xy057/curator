import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:curated_score/audio_track.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/media_converter.dart';
import 'package:curated_score/video_export.dart';
import 'package:flutter/painting.dart' show Size;
import 'package:flutter_test/flutter_test.dart';

import 'demo_project.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('choosing the H.264 encoder', () {
    const listing = '''
Encoders:
 V..... = Video
 ------
 V....D libx264              libx264 H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10 (codec h264)
 V....D h264_videotoolbox    VideoToolbox H.264 Encoder (codec h264)
 V....D h264_mf              H264 via MediaFoundation (codec h264)
 A....D aac                  AAC (Advanced Audio Coding)
''';

    test('libx264 when the build has it', () => expect(VideoEncoder.pick(listing), 'libx264'));

    test('else the platform\'s own: VideoToolbox (macOS), Media Foundation (Windows)', () {
      expect(VideoEncoder.pick(listing.replaceAll(' libx264 ', ' libx265 ')), 'h264_videotoolbox');
      expect(VideoEncoder.pick(' V....D h264_mf  H264 via MediaFoundation\n'), 'h264_mf');
    });

    test('none: null (audio encoders and the legend don\'t count)', () {
      expect(VideoEncoder.pick(' V..... = Video\n A....D aac  AAC\n V....D mpeg4  MPEG-4 part 2\n'), isNull);
    });
  });

  group('FFmpeg arguments', () {
    const format = VideoFormat(width: 1920, height: 1080, fps: 30);

    test('raw RGBA frames in, H.264 4:2:0 BT.709 + AAC in a streamable MP4 out', () {
      final args = VideoEncoder.arguments(
          encoder: 'libx264', format: format, seconds: 12.5, output: 'out.mp4.part', audio: 'take.flac');
      final line = args.join(' ');
      expect(line, contains('-f rawvideo -pix_fmt rgba -s 1920x1080 -framerate 30 -i -'));
      expect(line, contains('-i take.flac -map 0:v:0 -map 1:a:0'));
      expect(line, contains('format=yuv420p'));
      expect(line, contains('-c:v libx264 -preset medium -crf 18 -profile:v high'));
      expect(line, contains('-colorspace bt709'));
      expect(line, contains('-c:a aac -b:a 192k -ar 48000 -ac 2'));
      expect(line, contains('-t 12.500000 -movflags +faststart -f mp4 out.mp4.part'));
    });

    test('hardware encoders get a bit rate; no recording, no audio track', () {
      final args = VideoEncoder.arguments(encoder: 'h264_videotoolbox', format: format, seconds: 1, output: 'o');
      expect(args.join(' '), contains('-c:v h264_videotoolbox -b:v 7465k'));
      expect(args.where((a) => a == '-i'), hasLength(1));
      expect(args, isNot(contains('-c:a')));
    });
  });

  test('every size frames the score alike: 1080p is the 540-point layout at 2 pixels a point', () {
    expect(VideoFormat.of(VideoResolution.hd1080, fps: 30).devicePixelRatio, 2);
    expect(VideoFormat.of(VideoResolution.uhd2160, fps: 30).devicePixelRatio, 4);
    for (final r in VideoResolution.values) {
      final f = VideoFormat.of(r, fps: 30);
      expect(f.width / f.devicePixelRatio, 960);
    }
    const format = VideoFormat(width: 320, height: 180, fps: 25);
    expect(format.frameCount(2), 50);
    expect(format.frameCount(2.01), 51);
    expect(format.timeOf(25), 1);
  });

  group('the video\'s ratio', () {
    test('the size is the short side: wide ones are that high, tall ones that wide', () {
      VideoFormat at(VideoRatio ratio, [VideoResolution r = VideoResolution.hd1080]) =>
          VideoFormat.of(r, ratio: ratio, fps: 30);
      expect((at(VideoRatio.widescreen).width, at(VideoRatio.widescreen).height), (1920, 1080));
      expect((at(const VideoRatio(9, 16)).width, at(const VideoRatio(9, 16)).height), (1080, 1920));
      expect((at(const VideoRatio(1, 1)).width, at(const VideoRatio(1, 1)).height), (1080, 1080));
      expect((at(const VideoRatio(4, 3), VideoResolution.uhd2160).width), 2880);
      // H.264 in 4:2:0 needs even sizes: 2.39 × 1080 = 2581.2, so 2582.
      expect(at(const VideoRatio(2.39, 1)).width, 2582);
      // Every ratio is laid out 540 points on its short side: 1080p is 2 pixels a point,
      // so a tall video draws the score as big as a wide one, with room for more staves.
      expect(at(const VideoRatio(9, 16)).devicePixelRatio, 2);
      expect(VideoFormat.layoutOf(9 / 16), const Size(540, 960));
      expect(VideoFormat.layoutOf(21 / 9), const Size(1260, 540));
    });

    test('typed as W:H, W/H, pixels (reduced) or one number; out of range or junk is null', () {
      expect(VideoRatio.parse('16:9'), VideoRatio.widescreen);
      expect(VideoRatio.parse(' 1920 x 1080 '), VideoRatio.widescreen);
      expect(VideoRatio.parse('1080×1920'), const VideoRatio(9, 16));
      expect(VideoRatio.parse('4/5'), const VideoRatio(4, 5));
      expect(VideoRatio.parse('2.39'), const VideoRatio(2.39, 1));
      expect(VideoRatio.parse('2.39:1')!.label, '2.39:1');
      expect(VideoRatio.parse('64:18')!.label, '32:9');
      expect(VideoRatio.parse('7:3')!.label, '21:9', reason: 'a preset\'s shape is named as the preset');
      for (final bad in ['', 'wide', '16:', ':9', '0:1', '-4:3', '5:1', '1:5', '1:2:3', 'NaN']) {
        expect(VideoRatio.parse(bad), isNull, reason: bad);
      }
      for (final r in VideoRatio.presets) {
        expect(VideoRatio.parse(r.label), r, reason: 'a preset reads back as itself');
      }
    });
  });

  group('writing a video of the demo', () {
    final ffmpeg = MediaConverter.findFfmpeg();
    final ffprobe = ffmpeg?.replaceFirst(RegExp(r'ffmpeg(\.exe)?$'), 'ffprobe\$1');
    final skip = ffmpeg == null ? 'FFmpeg is not installed here' : false;
    const small = VideoFormat(width: 320, height: 180, fps: 10);

    late EditorController c;
    late Directory dir;
    setUp(() async {
      c = EditorController(vsync: const TestVSync());
      await c.openFile(demoScore.path);
      dir = Directory.systemTemp.createTempSync('video-test-');
    });
    tearDown(() {
      c.dispose();
      dir.deleteSync(recursive: true);
    });

    Future<void> useRecording(String path) async => c.audio.debugTrack = AudioTrack.forTesting(
        name: path, length: 60, waveform: await Waveform.analyze(Float32List(64), 64));

    test('an MP4 that plays anywhere, with the recording as its sound', () async {
      await useRecording(demoRecording.path);
      final export = VideoExport.of(c);
      addTearDown(export.dispose);
      final out = '${dir.path}/demo.mp4';
      final seen = <int>[];
      await export.write(out, format: small, to: 1.5, onProgress: (p) => seen.add(p.frame));
      expect(seen, List.generate(15, (i) => i + 1));
      expect(File('$out.part').existsSync(), isFalse);

      if (ffprobe == null || !File(ffprobe).existsSync()) return;
      final r = await Process.run(ffprobe, [
        '-v', 'error', '-of', 'json', '-show_format',
        '-show_entries', 'stream=codec_name,profile,pix_fmt,width,height,color_space,sample_rate,channels,nb_frames', out,
      ]);
      final info = jsonDecode('${r.stdout}') as Map<String, dynamic>;
      final [video, audio] = (info['streams'] as List).cast<Map<String, dynamic>>();
      expect(video, containsPair('codec_name', 'h264'));
      expect(video, containsPair('pix_fmt', 'yuv420p'));
      expect(video, containsPair('color_space', 'bt709'));
      expect((video['width'], video['height'], video['nb_frames']), (320, 180, '15'));
      expect(audio, containsPair('codec_name', 'aac'));
      expect((audio['sample_rate'], audio['channels']), ('48000', 2));
      expect(double.parse(info['format']['duration'] as String), closeTo(1.5, 0.05));
    }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

    test('cancelling leaves no file behind, and an older video of that name as it was', () async {
      final export = VideoExport.of(c);
      addTearDown(export.dispose);
      final out = File('${dir.path}/demo.mp4')..writeAsStringSync('the old one');
      final writing = export.write(out.path, format: small, to: 5, onProgress: (p) {
        if (p.frame == 3) export.cancel();
      });
      await expectLater(writing, throwsA(isA<VideoExportCancelled>()));
      expect(out.readAsStringSync(), 'the old one');
      expect(File('${out.path}.part').existsSync(), isFalse);
    }, skip: skip);

    test('after a cancelled export, exporting again writes the video', () async {
      final export = VideoExport.of(c);
      addTearDown(export.dispose);
      final out = '${dir.path}/demo.mp4';
      await expectLater(export.write(out, format: small, to: 5, onProgress: (p) {
        if (p.frame == 2) export.cancel();
      }), throwsA(isA<VideoExportCancelled>()));
      await export.write(out, format: small, to: 0.3);
      expect(File(out).lengthSync(), greaterThan(0));
    }, skip: skip);

    test('when FFmpeg fails, it says why and leaves nothing', () async {
      await useRecording('${dir.path}/missing.flac');
      final export = VideoExport.of(c);
      addTearDown(export.dispose);
      final out = '${dir.path}/demo.mp4';
      await expectLater(export.write(out, format: small, to: 1),
          throwsA(isA<VideoExportException>().having((e) => e.message, 'message', contains('missing.flac'))));
      expect(dir.listSync(), isEmpty);
    }, skip: skip);

    test('the export keeps the curation it started with', () async {
      final export = VideoExport.of(c);
      addTearDown(export.dispose);
      c.curation!.clearAll(); // edited in the editor after the export was made
      final out = '${dir.path}/demo.mp4';
      await export.write(out, format: small, to: 0.2);
      expect(File(out).lengthSync(), greaterThan(0));
      expect(export.duration, c.playback.duration);
    }, skip: skip);

    test('the export condenses the pairs the editor did when it started', () {
      c.setCondensed(['cond-P2-P3'], on: true);
      final export = VideoExport.of(c);
      addTearDown(export.dispose);
      c.setCondensed(['cond-P2-P3'], on: false); // changed in the editor afterwards
      expect(export.condensed, {'cond-P2-P3'});
    });

    test('the export stacks the instruments as the editor did when it started', () {
      c.moveLane('P17', 0); // Violin I on top
      final export = VideoExport.of(c);
      addTearDown(export.dispose);
      c.restoreScoreOrder(); // changed in the editor afterwards
      expect(export.partOrder.first, 'P17');
    });
  });
}
