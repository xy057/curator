// Project Settings ▸ Project Info ▸ Score ▸ Replace…: another score file or PDF under the
// project, and the PDF pages each replacement holds, kept or let go.
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/project_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_project.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Replace… puts a score file or a PDF in place, the project its kind; a PDF’s pages go with the replacement that holds them', () async {
    final c = EditorController(vsync: const TestVSync());
    addTearDown(c.dispose);
    await c.openFile(demoScore.path);
    final lanes = c.curation!.lanes;
    final pdf = File('assets/exam/pdf-ai-exam.pdf').readAsBytesSync();
    PdfScoreLayout layout(PdfPages pages, String name) => PdfScoreLayout(
          pages: pages.sizes,
          instruments: [PdfInstrument(id: 'P1', name: name)],
          systems: [
            PdfSystem.cut(
                page: 0, top: 80, bottom: 150, left: 100, right: 420, //
                staves: const [PdfStaff(top: 100, space: 6, part: 'P1')], barlines: const [PdfBarline(420)]),
          ],
        );
    // A closed document reads nothing.
    Future<bool> closed(PdfPages pages) =>
        pages.render(0, const Rect.fromLTWH(0, 0, 10, 10), 1).then((_) => false, onError: (_) => true);

    // Another score file: carried over as it is, nothing differs.
    final dir = Directory.systemTemp.createTempSync('replace-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final other = demoScore.copySync('${dir.path}/Other${demoScore.path.substring(demoScore.path.lastIndexOf('.'))}');
    final same = await c.prepareReplacement(other.path);
    expect((same.differences.isEmpty, same.pages), (true, null));
    await c.replaceScore(same);
    expect((c.fileName, c.isPdf), (other.uri.pathSegments.last, false));
    expect(c.curation!.lanes, lanes);

    // A PDF: the project a PDF's, drawn from its pages.
    final a = await PdfPages.open(pdf);
    final toPdf = await c.prepareReplacementWith('A.pdf', pdf, pdf: layout(a, 'Flute'), pages: a);
    expect(toPdf.differences, isNotEmpty);
    await c.replaceScore(toPdf);
    expect((c.isPdf, c.projectState.kind, c.pdfPages), (true, ProjectKind.pdf, a));

    // Another PDF declined: its pages closed, the open ones kept.
    final b = await PdfPages.open(pdf);
    c.discardReplacement(await c.prepareReplacementWith('B.pdf', pdf, pdf: layout(b, 'Oboe'), pages: b));
    expect((await closed(b), await closed(a), c.pdfPages), (true, false, a));

    // The open PDF's import set again, declined: its pages stay open.
    c.discardReplacement(await c.prepareReplacementWith('A.pdf', pdf, pdf: layout(a, 'Flute')));
    expect(await closed(a), isFalse);

    // Made, but another score opened before it went in: let go with its pages.
    final d = await PdfPages.open(pdf);
    final stale = await c.prepareReplacementWith('D.pdf', pdf, pdf: layout(d, 'Flute'), pages: d);
    await c.openFile(demoScore.path);
    expect((await closed(a), c.pdfPages), (true, null), reason: 'opening a score closes the PDF before');
    await c.replaceScore(stale);
    expect((await closed(d), c.isPdf), (true, false));

    // Another PDF in place of a PDF, then a score file in place of that: each time the pages
    // before closed.
    final e = await PdfPages.open(pdf);
    await c.replaceScore(await c.prepareReplacementWith('E.pdf', pdf, pdf: layout(e, 'Flute'), pages: e));
    final f = await PdfPages.open(pdf);
    await c.replaceScore(await c.prepareReplacementWith('F.pdf', pdf, pdf: layout(f, 'Flute'), pages: f));
    expect((await closed(e), c.pdfPages, c.fileName), (true, f, 'F.pdf'));
    await c.replaceScore(await c.prepareReplacement(other.path));
    expect((await closed(f), c.pdfPages, c.isPdf, c.projectState.kind), (true, null, false, ProjectKind.score));
  });
}
