import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';
import 'package:xml/xml.dart';

import 'demo_score.dart';

/// The glyph boxes of a Verovio metrics file, by code.
Map<String, List<double>> boxes(String xml) => {
      for (final g in XmlDocument.parse(xml).rootElement.findElements('g'))
        g.getAttribute('c')!: [for (final a in ['x', 'y', 'w', 'h', 'h-a-x']) double.parse(g.getAttribute(a) ?? '0')],
    };

void main() {
  final bravuraXml = File('assets/verovio/Bravura.xml').readAsStringSync();
  final times = File('assets/verovio/text/Times.xml').readAsStringSync();
  late Directory work;

  setUpAll(() => work = Directory.systemTemp.createTempSync('fonts-test'));
  tearDownAll(() => work.deleteSync(recursive: true));

  test('measures a SMuFL font as Verovio does', () {
    // Bravura measured from its file matches the metrics Verovio generated for it.
    final font = MusicFont.added(
      family: 'Bravura copy',
      file: File('assets/fonts/Bravura.otf').readAsBytesSync(),
      metadata: utf8.encode('{"fontName": "Bravura copy"}'),
    );
    final xml = FontResources.smuflMetrics(font, 'assets/fonts/Bravura.otf', bravura: bravuraXml)!;
    final ours = boxes(xml), verovio = boxes(bravuraXml);
    expect(ours.length, verovio.length);
    var off = 0;
    for (final MapEntry(key: c, value: box) in verovio.entries) {
      for (var i = 0; i < 5; i++) {
        if ((ours[c]![i] - box[i]).abs() > 2) off++;
      }
    }
    expect(off, lessThan(verovio.length ~/ 50), reason: 'glyph boxes and advances agree to a font unit or two');
    expect(xml, contains('n="noteheadBlack"'));
  });

  test('takes anchors and engraving defaults from the SMuFL metadata', () {
    final font = MusicFont.added(
      family: 'Some Family',
      file: File('assets/fonts/Leland.otf').readAsBytesSync(),
      metadata: utf8.encode(jsonEncode({
        'fontName': 'My Font/1',
        'engravingDefaults': {'stemThickness': 0.09, 'textFontFamily': ['Edwin']},
        'glyphsWithAnchors': {
          'noteheadBlack': {'stemUpSE': [1.18, 0.168]},
        },
      })),
    );
    expect(font.name, 'My Font_1', reason: 'a file name for Verovio');
    expect(font.isBundled, isFalse);
    expect(font.engravingDefaults['stemThickness'], 0.09);
    expect(font.engravingDefaults['staffLineThickness'], 0.13, reason: "what it lacks is Bravura's");
    final xml = FontResources.smuflMetrics(font, 'assets/fonts/Leland.otf', bravura: bravuraXml)!;
    final head = XmlDocument.parse(xml).rootElement.findElements('g').firstWhere((g) => g.getAttribute('n') == 'noteheadBlack');
    expect(head.findElements('a').single.getAttribute('n'), 'stemUpSE');
    expect(head.findElements('a').single.getAttribute('x'), '1.18');
  });

  test('refuses a bundled name, and metadata that is not JSON', () {
    final bytes = File('assets/fonts/Leland.otf').readAsBytesSync();
    expect(() => MusicFont.added(family: 'Leland', file: bytes), throwsFormatException);
    expect(() => MusicFont.added(family: 'Other', file: bytes, metadata: utf8.encode('{"fontName": "bravura"}')),
        throwsFormatException);
    expect(() => MusicFont.added(family: 'Other', file: bytes, metadata: utf8.encode('not json')), throwsFormatException);
    expect(MusicFont.added(family: 'Other', file: bytes), MusicFont.added(family: 'Other', file: bytes));
  });

  test('measures installed text fonts, and knows when one is missing', () {
    expect(TextFonts.installed(), contains('Helvetica'));
    final helvetica = boxes(FontResources.textMetrics('Helvetica', bold: false, italic: false, reference: times)!);
    final bold = boxes(FontResources.textMetrics('Helvetica', bold: true, italic: false, reference: times)!);
    final academico = boxes(times);
    expect(helvetica.keys, containsAll(['41', '61', '20']));
    expect(helvetica['6D']![4], isNot(academico['6D']![4]), reason: 'its own widths');
    expect(bold['6D']![4], greaterThan(helvetica['6D']![4]), reason: 'bold is wider');
    expect(FontResources.textMetrics('No Such Font 12345', bold: false, italic: false, reference: times), isNull);
  });

  test('engraves and draws in another music font and text font', () async {
    final standard = await LoadedScore.load(demoScore());
    final leland = await LoadedScore.load(demoScore(),
        fonts: const ScoreFonts(music: MusicFont.leland, text: 'Helvetica'));
    expect(leland.fonts.music, MusicFont.leland);
    expect(leland.textFontFound, isTrue);
    expect(leland.musicFontFamily, 'packages/score_engine/Leland');
    expect(leland.textFontFamily, 'Helvetica');
    expect(leland.engraving.staves.length, standard.engraving.staves.length);
    expect(leland.engraving.measures.length, standard.engraving.measures.length);
    expect(leland.engraving.width, isNot(standard.engraving.width), reason: 'other glyphs, other spacing');

    final scene = CuratedScene(leland);
    expect(scene.style.musicFontFamily, 'packages/score_engine/Leland');
    expect(scene.style.textFontFamily, 'Helvetica');
    scene.dispose();
  });

  test('a text font not installed falls back to Academico', () async {
    final score = await LoadedScore.load(demoScore(), fonts: const ScoreFonts(text: 'No Such Font 12345'));
    expect(score.fonts.text, 'No Such Font 12345', reason: 'the choice is kept');
    expect(score.textFontFound, isFalse);
    expect(score.textFontFamily, 'packages/score_engine/Academico');
  });

  test('engraves with a SMuFL font the user added, under its own name', () async {
    FontResources.workDirectory = work.path;
    addTearDown(() => FontResources.workDirectory = null);
    final metadata = jsonDecode(File('third_party/verovio/fonts/Leland/leland_metadata.json').readAsStringSync()) as Map;
    final font = MusicFont.added(
      family: 'Leland Copy',
      file: File('assets/fonts/Leland.otf').readAsBytesSync(),
      metadata: utf8.encode(jsonEncode({...metadata, 'fontName': 'Leland Copy'})),
    );
    final added = await LoadedScore.load(demoScore(), fonts: ScoreFonts(music: font));
    final bundled = await LoadedScore.load(demoScore(), fonts: const ScoreFonts(music: MusicFont.leland));
    expect(added.musicFontFamily, startsWith('Curator Leland Copy'));
    expect(added.engraving.measures.length, 44);
    // Measured from the same file as Verovio's own Leland metrics: the same layout, to a hair.
    expect((added.engraving.width - bundled.engraving.width).abs() / bundled.engraving.width, lessThan(0.01));
    expect(work.listSync().whereType<Directory>().where((d) => File('${d.path}/Leland Copy.xml').existsSync()), hasLength(1));
  });
}
