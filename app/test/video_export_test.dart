import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:curated_score/audio_track.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/media_converter.dart';
import 'package:curated_score/video_export.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_project.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('frames drawn ahead', () {
    test('come out in order, at most three at a time, whatever order they finish in', () async {
      final jobs = <int, Completer<int>>{};
      var most = 0;
      final out = <int>[];
      final done = VideoExport.inOrder(10, (i) {
        jobs[i] = Completer<int>();
        final running = jobs.values.where((c) => !c.isCompleted).length;
        if (running > most) most = running;
        return jobs[i]!.future;
      }).forEach(out.add);
      for (var round = 0; round < 10; round++) {
        await pumpEventQueue();
        // Finish the newest running one first, the oldest last.
        for (final c in jobs.values.toList().reversed) {
          if (!c.isCompleted) c.complete(jobs.entries.firstWhere((e) => e.value == c).key);
        }
      }
      await done;
      expect(out, List.generate(10, (i) => i));
      expect(most, 3);
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

    test('cancelling leaves no file behind, and an older video of that name as it was; exporting again writes it', () async {
      final export = VideoExport.of(c);
      addTearDown(export.dispose);
      final out = File('${dir.path}/demo.mp4')..writeAsStringSync('the old one');
      final writing = export.write(out.path, format: small, to: 5, onProgress: (p) {
        if (p.frame == 3) export.cancel();
      });
      await expectLater(writing, throwsA(isA<VideoExportCancelled>()));
      expect(out.readAsStringSync(), 'the old one');
      expect(File('${out.path}.part').existsSync(), isFalse);

      await export.write(out.path, format: small, to: 0.3);
      expect(out.lengthSync(), greaterThan('the old one'.length));
    }, skip: skip);

    test('bars A–B: from where A first sounds to where B ends, then the ending; all of them is the whole video', () {
      final export = VideoExport.of(c);
      addTearDown(export.dispose);
      expect(export.bars, 44);
      expect(export.barRange(1, 44), (start: 0.0, end: export.duration));
      expect(export.span, (start: 0.0, end: export.duration));
      final r = export.barRange(5, 12)!;
      final timeline = c.timeline, starts = timeline.measureStarts;
      expect(r.start, closeTo(timeline.secondsAtQuarter(starts[4]), 1e-9));
      expect(r.end, closeTo(timeline.secondsAtQuarter(starts[12]) + ScoreMotion.standard.ending, 1e-9),
          reason: 'B ends as the piece does: the score comes to rest, then fades');
      expect(export.showBars(5, 12), isTrue);
      expect(export.span, r);
      expect(export.showBars(12, 5), isFalse);
      expect(export.span, r, reason: 'a wrong range changes nothing');
      expect(export.barBeatAt(r.start + 1e-6), '5.1');
      expect(export.barRange(12, 5), isNull);
      expect(export.barRange(0, 5), isNull);
      expect(export.barRange(1, 45), isNull);
    });

  });
}
