import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';
import 'package:xml/xml.dart';

import 'demo_score.dart';

/// The glyph boxes of a Verovio metrics file, by code.
Map<String, List<double>> boxes(String xml) => {
      for (final g in XmlDocument.parse(xml).rootElement.findElements('g'))
        g.getAttribute('c')!: [for (final a in ['x', 'y', 'w', 'h', 'h-a-x']) double.parse(g.getAttribute(a) ?? '0')],
    };

/// A TrueType font made to break a reader that trusts it: U+E050's glyph claims 60 001 points
/// that lie past the end of the file, and U+E062's is a composite glyph made of itself.
Uint8List hostileFont() {
  final head = ByteData(54)
    ..setUint32(0, 0x00010000)
    ..setUint32(12, 0x5F0F3CF5)
    ..setUint16(18, 1000) // units per em
    ..setUint16(50, 1); // long loca offsets
  final hhea = ByteData(36)..setUint16(34, 3);
  final maxp = ByteData(6)
    ..setUint32(0, 0x00005000)
    ..setUint16(4, 3);
  final hmtx = ByteData(12)
    ..setUint16(0, 500)
    ..setUint16(4, 500)
    ..setUint16(8, 500);
  final cmap = ByteData(12 + 16 + 24)
    ..setUint16(2, 1)
    ..setUint16(4, 3)
    ..setUint16(6, 10)
    ..setUint32(8, 12)
    ..setUint16(12, 12) // format 12
    ..setUint32(16, 40)
    ..setUint32(24, 2)
    ..setUint32(28, 0xE050)
    ..setUint32(32, 0xE050)
    ..setUint32(36, 1)
    ..setUint32(40, 0xE062)
    ..setUint32(44, 0xE062)
    ..setUint32(48, 2);
  final loca = ByteData(16)
    ..setUint32(8, 12)
    ..setUint32(12, 28);
  final glyf = ByteData(28)
    ..setInt16(0, 1) // glyph 1: one contour…
    ..setUint16(10, 60000) // …of 60 001 points, and 65 535 bytes of instructions
    ..setInt16(12, -1) // glyph 2: a composite…
    ..setUint16(22, 0x0002)
    ..setUint16(24, 2); // …of glyph 2
  final tables = {'cmap': cmap, 'head': head, 'hhea': hhea, 'hmtx': hmtx, 'loca': loca, 'maxp': maxp, 'glyf': glyf};
  final header = ByteData(12)
    ..setUint32(0, 0x00010000)
    ..setUint16(4, tables.length);
  final out = BytesBuilder()..add(header.buffer.asUint8List());
  var at = 12 + 16 * tables.length;
  for (final MapEntry(key: tag, value: data) in tables.entries) {
    final record = ByteData(16)
      ..setUint32(8, at)
      ..setUint32(12, data.lengthInBytes);
    for (var i = 0; i < 4; i++) {
      record.setUint8(i, tag.codeUnitAt(i));
    }
    out.add(record.buffer.asUint8List());
    at += data.lengthInBytes;
  }
  for (final data in tables.values) {
    out.add(data.buffer.asUint8List());
  }
  return out.toBytes(); // glyf last: what glyph 1 reads past it is past the file
}

void main() {
  late Directory work;

  setUpAll(() => work = Directory.systemTemp.createTempSync('fonts-test'));
  tearDownAll(() => work.deleteSync(recursive: true));

  test('engraves and draws in another music font, bundled or added (under its own name), and text font', () async {
    FontResources.workDirectory = work.path;
    addTearDown(() => FontResources.workDirectory = null);
    final standard = await LoadedScore.load(demoScore());
    final leland = await LoadedScore.load(demoScore(),
        fonts: const ScoreFonts(music: MusicFont.leland, text: 'Helvetica'));
    expect(leland.fonts.music, MusicFont.leland);
    expect(leland.textFontFound, isTrue);
    expect(leland.musicFontFamily, 'packages/score_engine/Leland');
    expect(leland.textFontFamily, 'Curator text Helvetica');
    expect(leland.engraving.staves.length, standard.engraving.staves.length);
    expect(leland.engraving.measures.length, standard.engraving.measures.length);
    expect(leland.engraving.width, isNot(standard.engraving.width), reason: 'other glyphs, other spacing');

    final scene = CuratedScene(leland);
    expect(scene.style.musicFontFamily, 'packages/score_engine/Leland');
    expect(scene.style.textFontFamily, 'Curator text Helvetica');
    scene.dispose();

    final metadata = jsonDecode(File('third_party/verovio/fonts/Leland/leland_metadata.json').readAsStringSync()) as Map;
    final font = MusicFont.added(
      family: 'Leland Copy',
      file: File('assets/fonts/Leland.otf').readAsBytesSync(),
      metadata: utf8.encode(jsonEncode({...metadata, 'fontName': 'Leland Copy'})),
    );
    final added = await LoadedScore.load(demoScore(), fonts: ScoreFonts(music: font, text: 'Helvetica'));
    expect(added.musicFontFamily, startsWith('Curator Leland Copy'));
    expect(added.engraving.measures.length, 44);
    // Measured from the same file as Verovio's own Leland metrics: the same layout, to a hair.
    expect((added.engraving.width - leland.engraving.width).abs() / leland.engraving.width, lessThan(0.01));
    expect(work.listSync().whereType<Directory>().where((d) => File('${d.path}/Leland Copy.xml').existsSync()), hasLength(1));
  }, skip: Platform.isMacOS ? false : 'uses Helvetica, a macOS font');

  test('a font made to break its reader is measured within its own bytes', () {
    final file = File('${work.path}/hostile.ttf')..writeAsBytesSync(hostileFont());
    final font = MusicFont.added(family: 'Hostile', file: file.readAsBytesSync());
    const bravura = '<bounding-boxes><g c="E050" n="gClef"/><g c="E062" n="fClef"/></bounding-boxes>';
    final xml = FontResources.smuflMetrics(font, file.path, bravura: bravura)!;
    final measured = boxes(xml);
    expect(measured['E050']![4], 500, reason: 'read, its points past the end of the file read as nothing');
    expect(measured['E062']![4], 500, reason: 'read, its endless nesting cut off');
  });
}
