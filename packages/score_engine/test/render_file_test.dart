// Renders any score to PNG frames for visual review. Skipped unless SCORE_FILE is set.
//
//   SCORE_FILE=../../Samples/x.musicxml SNAPSHOT_DIR=/tmp/out SNAPSHOT_TIMES=0,10,20 flutter test test/render_file_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

Future<void> _font(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final path in paths) {
    loader.addFont(Future.value(ByteData.sublistView(File(path).readAsBytesSync())));
  }
  await loader.load();
}

void main() {
  final file = Platform.environment['SCORE_FILE'];
  final out = Platform.environment['SNAPSHOT_DIR'] ?? Directory.systemTemp.path;

  test('render ${file ?? '(set SCORE_FILE)'}', () async {
    if (file == null) return;
    await _font('packages/score_engine/Bravura', ['assets/fonts/Bravura.otf']);
    final academico = Directory('assets/fonts').listSync().whereType<File>().where((f) => f.path.contains('Academico'));
    if (academico.isNotEmpty) await _font('packages/score_engine/Academico', [for (final f in academico) f.path]);

    final stopwatch = Stopwatch()..start();
    final score = await LoadedScore.open(file);
    // ignore: avoid_print
    print('${score.metadata.parts.length} parts, ${score.engraving.measures.length} measures, '
        '${score.duration.toStringAsFixed(1)} s, engraved in ${stopwatch.elapsedMilliseconds} ms');

    final curation = Curation(score.metadata.parts.map((p) => p.id));
    for (final p in score.metadata.parts) {
      curation.setLane(p.id, [Region(0, score.timeline.measureStarts.last)]);
    }
    final scene = CuratedScene(score)
      ..minGap = 16
      ..verticalMargin = 24;
    final staves = score.engraving.staves.length;
    final size = ui.Size(2000, 120.0 + staves * 72);
    const dpr = 2.0;
    final times = (Platform.environment['SNAPSHOT_TIMES'] ?? '0,${score.duration / 2}')
        .split(',')
        .map(double.parse);
    for (final t in times) {
      final recorder = ui.PictureRecorder();
      scene.paint(ui.Canvas(recorder)..scale(dpr), size, time: t, curation: curation, devicePixelRatio: dpr);
      final image = recorder.endRecording().toImageSync((size.width * dpr).round(), (size.height * dpr).round());
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      final name = file.split('/').last.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
      File('$out/${name}_${t.toStringAsFixed(0)}.png').writeAsBytesSync(png!.buffer.asUint8List());
    }
    scene.dispose();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
