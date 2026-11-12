import 'dart:io';
import 'dart:typed_data';

import 'package:curated_score/lilypond.dart';
import 'package:curated_score/project_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart' show LilyPondScore;

void main() {
  test("LilyPond's problems are read with where they are, its own folder taken off", () {
    const log = '/work/lilypond-3/score.ly:12:5: error: syntax error, unexpected NOTENAME_PITCH\n'
        '  c4 d e\n'
        '    ^\n'
        '/work/lilypond-3/parts/flute.ily:3:17: warning: barcheck failed at: 1/4\n'
        'fatal error: failed files: "score.ly"\n'
        'Processing `score.ly\'\n';
    expect(LilyPond.parseProblems(log, workPath: '/work/lilypond-3'), [
      const LilyProblem('syntax error, unexpected NOTENAME_PITCH', file: 'score.ly', line: 12, column: 5, error: true),
      const LilyProblem('barcheck failed at: 1/4', file: 'parts/flute.ily', line: 3, column: 17),
      const LilyProblem('failed files: "score.ly"', error: true),
    ]);
  });

  test('links name the files by their place in the score, not where it was engraved', () {
    const svg = '<a xlink:href="textedit:///work/my%20scores/lilypond-3/score/../global.ily:1:4:5">'
        '<a xlink:href="textedit:///work/my%20scores/lilypond-3/score.ly:14:4:5">'
        '<a xlink:href="textedit:///work/my scores/lilypond-3/parts/a.ily:2:0:1">'
        '<a xlink:href="textedit:///usr/share/lilypond/ly/init.ly:1:0:1">';
    expect(LilyPond.relativeLinks(svg, '/work/my scores/lilypond-3'),
        '<a xlink:href="textedit://global.ily:1:4:5">'
        '<a xlink:href="textedit://score.ly:14:4:5"><a xlink:href="textedit://parts/a.ily:2:0:1">'
        '<a xlink:href="textedit:///usr/share/lilypond/ly/init.ly:1:0:1">');
  });

  test('links are made relative in a folder whose name LilyPond escapes: each byte but letters, digits and -._/, in lowercase', () {
    // As LilyPond 2.26.0 writes them, engraving in such a folder (a user's folder in Japanese, as on Windows).
    const svg = '<a xlink:href="textedit:///Users/%e5%b1%b1%e7%94%b0/Temp/a%2bb%7ec_d/s%20q.ly:2:2:3">';
    expect(LilyPond.relativeLinks(svg, '/Users/山田/Temp/a+b~c_d'), '<a xlink:href="textedit://s%20q.ly:2:2:3">');
    const capitals = '<a xlink:href="textedit:///Users/%E5%B1%B1%E7%94%B0/Temp/a%2Bb%7Ec_d/s%20q.ly:2:2:3">';
    expect(LilyPond.relativeLinks(capitals, '/Users/山田/Temp/a+b~c_d'), '<a xlink:href="textedit://s%20q.ly:2:2:3">',
        reason: 'escaped in capitals, as another writer may');
  });

  test('a new score starts from a staff of a few bars, its instrument named as given, quoted as LilyPond reads it', () {
    final blank = LilySource.blank('Untitled.ly', part: r'Fl"ute\');
    expect(blank.text, startsWith('\\version "${LilyPond.version}"\n'));
    expect(blank.text, contains(r'instrumentName = "Fl\"ute\\"'));
    expect(blank.path, 'Untitled.ly');
    expect(blank.files, isEmpty);
  });

  test("a score is read with the files it includes, as far as they go, and LilyPond's own left out", () {
    final dir = Directory.systemTemp.createTempSync('lilysource');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/score.ly').writeAsStringSync('\\version "2.26.0"\n\\include "english.ly"\n\\include "parts/flute.ily"\n'
        '% \\include "old.ily"\n{ \\flute }\n');
    Directory('${dir.path}/parts').createSync();
    File('${dir.path}/parts/flute.ily').writeAsStringSync('\\include "notes.ily"\nflute = { \\notes }\n');
    File('${dir.path}/parts/notes.ily').writeAsStringSync('notes = { c4 }\n');
    File('${dir.path}/old.ily').writeAsStringSync('% commented out: not kept\n');
    final source = LilySource.read('${dir.path}/score.ly');
    expect(source.name, 'score.ly');
    expect(source.origin, dir.path);
    expect(source.files.keys.toSet(), {'parts/flute.ily', 'parts/notes.ily'});
    expect(source.text, contains('{ \\flute }'));
  });

  test('a score including from the folders above its own is kept from the highest of them, as LilyPond finds them', () {
    final dir = Directory.systemTemp.createTempSync('lilyroot');
    addTearDown(() => dir.deleteSync(recursive: true));
    Directory('${dir.path}/piece/score/parts').createSync(recursive: true);
    File('${dir.path}/piece/global.ily').writeAsStringSync('g = 1\n');
    // Each from the folder of the file that includes it: both name piece/global.ily.
    File('${dir.path}/piece/score/parts/flute.ily').writeAsStringSync('\\include "../../global.ily"\nflute = { c4 }\n');
    File('${dir.path}/piece/score/full.ly').writeAsStringSync('\\include "../global.ily"\n\\include "parts/flute.ily"\n'
        '\\include "../../../../../../../../../../etc/hosts"\n{ \\flute }\n');
    final source = LilySource.read('${dir.path}/piece/score/full.ly');
    expect((source.folder, source.path), ('score', 'score/full.ly'));
    expect(source.files.keys.toSet(), {'global.ily', 'score/parts/flute.ily'});
    // Kept as a project keeps it, and read back.
    final kept = LilySource.of('full.ly', source.text, LilyPondProject(folder: source.folder, files: source.files, svg: '', data: '', version: ''));
    expect((kept.path, kept.files.length, kept.origin), ('score/full.ly', 2, null));
  });

  test("LilyPond's download is unpacked into place whole, its own folder name taken off", () async {
    final dir = Directory.systemTemp.createTempSync('lilyunpack');
    addTearDown(() => dir.deleteSync(recursive: true));
    final top = Directory('${dir.path}/src/lilypond-${LilyPond.version}/bin')..createSync(recursive: true);
    File('${top.path}/lilypond').writeAsStringSync('#!/bin/sh\n');
    final archive = File('${dir.path}/lilypond.tar.gz');
    final made = await Process.run('tar', ['-czf', archive.path, '-C', '${dir.path}/src', 'lilypond-${LilyPond.version}']);
    expect(made.exitCode, 0, reason: '${made.stderr}');
    final into = Directory('${dir.path}/data/LilyPond/${LilyPond.version}');
    await LilyPondInstaller.unpack(archive, into);
    expect(File('${into.path}/bin/lilypond').existsSync(), isTrue);
    expect(into.parent.listSync().map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last), [LilyPond.version]);
    // One that isn't LilyPond's leaves nothing behind.
    final other = File('${dir.path}/other.tar.gz');
    await Process.run('tar', ['-czf', other.path, '-C', dir.path, 'src']);
    await expectLater(LilyPondInstaller.unpack(other, Directory('${dir.path}/data/LilyPond/x')), throwsA(isA<FileSystemException>()));
    expect(into.parent.listSync(), hasLength(1));
  });

  // With LILYPOND set to a LilyPond 2.26 (`LILYPOND=/path/to/bin/lilypond flutter test …`): a
  // score is engraved with Curator's settings, its links named by its own files.
  final lilypond = Platform.environment['LILYPOND'];
  testWidgets('a score is engraved with Curator’s settings', (tester) async {
    LilyPond.debugExecutable = File(lilypond!);
    addTearDown(() => LilyPond.debugExecutable = null);
    final run = await tester.runAsync(() => LilyPond.engrave(const LilySource(
        name: 'song.ly', text: '\\version "2.26.0"\n\\include "melody.ily"\n\\score { \\new Staff \\melody }\n',
        files: {})))
        .then((r) => r!);
    expect(run.engraved, isFalse); // melody.ily isn't there
    expect(run.problems.where((p) => p.error).first.file, 'song.ly');
    final ok = await tester.runAsync(() => LilyPond.engrave(LilySource(
        name: 'song.ly',
        text: '\\version "2.26.0"\n\\include "melody.ily"\n\\score { \\new Staff \\melody }\n',
        files: {'melody.ily': Uint8List.fromList('melody = \\relative { c\'4 d e f | g1 }\n'.codeUnits)})))
        .then((r) => r!);
    expect(ok.engraved, isTrue, reason: ok.log);
    expect(ok.svg, contains('textedit://melody.ily:1:'));
    expect(ok.data, contains('"t":"NoteHead"'));
  }, skip: lilypond == null);

  testWidgets('a new score engraves as it starts, named in Japanese: its part named, its links naming its file', (tester) async {
    LilyPond.debugExecutable = File(lilypond!);
    addTearDown(() => LilyPond.debugExecutable = null);
    final run = await tester.runAsync(() => LilyPond.engrave(LilySource.blank('名称未設定.ly', part: 'メロディ'))).then((r) => r!);
    expect(run.engraved, isTrue, reason: run.log);
    // No errors. (Warnings may come of the fonts here: without a font cache it can write, LilyPond
    // finds none with kana in, and says so.)
    expect(run.problems.where((p) => p.error), isEmpty, reason: run.log);
    final score = LilyPondScore.read(run.svg!, run.data!);
    expect(score.musicXML, contains('<part-name>メロディ</part-name>'));
    expect({for (final l in score.links) l.file}, {'名称未設定.ly'});
  }, skip: lilypond == null);

  testWidgets('a score including from above its own folder is engraved laid out as it was, with nothing else to look in', (tester) async {
    LilyPond.debugExecutable = File(lilypond!);
    addTearDown(() => LilyPond.debugExecutable = null);
    final dir = Directory.systemTemp.createTempSync('lilyabove');
    addTearDown(() => dir.deleteSync(recursive: true));
    Directory('${dir.path}/piece/score').createSync(recursive: true);
    File('${dir.path}/piece/global.ily').writeAsStringSync('melody = \\relative { c\'4 d e f | g1 }\n');
    File('${dir.path}/piece/score/full.ly')
        .writeAsStringSync('\\version "2.26.0"\n\\include "../global.ily"\n\\score { \\new Staff \\melody }\n');
    final read = LilySource.read('${dir.path}/piece/score/full.ly');
    final kept = LilySource(name: read.name, text: read.text, folder: read.folder, files: read.files); // a project's: no origin
    final run = await tester.runAsync(() => LilyPond.engrave(kept)).then((r) => r!);
    expect(run.engraved, isTrue, reason: run.log);
    expect(run.svg, contains('textedit://global.ily:1:'));
  }, skip: lilypond == null);
}
