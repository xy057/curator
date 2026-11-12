// The LilyPond editor: its highlighting, what it offers as LilyPond is typed, and the editor
// itself (engraving with a stand-in LilyPond, its preview and problems, Done).
import 'dart:io';
import 'dart:typed_data';

import 'package:curated_score/app_colors.dart';
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/main.dart';
import 'package:curated_score/project_document.dart';
import 'package:curated_score/project_tabs.dart';
import 'package:curated_score/lilypond.dart';
import 'package:curated_score/lilypond_editor.dart';
import 'package:curated_score/lilypond_language.dart';
import 'package:curated_score/ui_kit.dart' show SidebarTile;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:score_engine/score_engine.dart';

import 'window.dart';

/// The engine's fixture: a score LilyPond 2.26.0 engraved with Curator's settings.
const _fixture = '../packages/score_engine/test/lilypond/fixture';

/// The editor as on a Mac, as Curator is (re_editor reads the platform once: on a phone its caret
/// waits on a timer of its own).
final _mac = TargetPlatformVariant.only(TargetPlatform.macOS);

/// [source] highlighted: each scoped run of text, as (scope, text), a nested scope its own.
List<(String, String)> _scoped(String source) {
  final highlight = Highlight()..registerLanguage('lilypond', lilyPondMode());
  final out = _Runs();
  highlight.highlight(code: source, language: 'lilypond').render(out);
  return out.runs;
}

class _Runs implements HighlightRenderer {
  final runs = <(String, String)>[];
  final _scopes = <String?>[];
  String? _text;

  @override
  void addText(String text) => _text = (_text ?? '') + text;

  @override
  void openNode(DataNode node) {
    _flush();
    _scopes.add(node.scope ?? (_scopes.isEmpty ? null : _scopes.last));
  }

  @override
  void closeNode(DataNode node) {
    _flush();
    if (_scopes.isNotEmpty) _scopes.removeLast();
  }

  void _flush() {
    final text = _text, scope = _scopes.isEmpty ? null : _scopes.last;
    _text = null;
    if (text != null && scope != null && text.trim().isNotEmpty) runs.add((scope, text.trim()));
  }
}

void main() {
  test('LilyPond is highlighted: comments, strings, commands, contexts, durations, variables and its Scheme', () {
    final scoped = _scoped('''
\\version "2.26.0" % the version
melody = \\relative c' { \\clef treble c4. d8 e2 | f1~ f }
\\score { \\new Staff \\with { \\override NoteHead.color = #red } \\melody }
#(define (twice x) (* 2 x)) %{ a block %}
\\paper { indent = ##f }
''');
    expect(scoped, containsAll([
      ('keyword', r'\version'),
      ('string', '"2.26.0"'),
      ('comment', '% the version'),
      ('variable', 'melody'),
      ('keyword', r'\relative'),
      ('built_in', r'\clef'),
      ('number', '4.'),
      ('meta', '|'),
      ('keyword', r'\new'),
      ('title', 'Staff'),
      ('title', 'NoteHead'),
      ('literal', '#red'),
      ('keyword', 'define'),
      ('number', '2'),
      ('comment', '%{ a block %}'),
      ('literal', '##f'),
    ]));
  });

  group('what is offered', () {
    final prompts = LilyPondPrompts(() => 'melody = { c }\nbassLine = { c, }\n');
    List<String>? words(String before) => prompts.promptsFor(before)?.prompts.map((p) => p.word).toList();
    String? input(String before) => prompts.promptsFor(before)?.input;

    test('after \\new or \\context a context, the most used first', () {
      expect(words(r'\new ')!.take(3), ['Staff', 'Voice', 'PianoStaff']);
      expect(words(r'  \context Ch'), ['ChoirStaff', 'ChordNames']);
      expect(input(r'\new Pi'), 'Pi');
    });

    test('after \\clef a clef; after \\repeat a repeat; in \\bar " a barline; in \\language " a language', () {
      expect(words(r'\clef tr'), ['treble', 'treble_8', 'treble^8']);
      expect(words(r'\clef "ba'), ['bass', 'bass_8', 'bass^8', 'baritone', 'baritonevarC']);
      expect(words(r'\repeat '), LilyPondPrompts.repeats);
      expect(words(r'\bar ":|'), containsAll([':|.', ':|.|:', ':|]']));
      expect(words(r'\language "en'), ['english']);
    });

    test('after \\override a grob or context, after its dot a property; after \\set a context property', () {
      expect(words(r'\override Note')!.first, 'NoteHead');
      expect(words(r'\override Sta'), containsAll(['StaffSymbol', 'Staff', 'StaffGroup']));
      expect(words(r'\override Staff.Time'), ['TimeSignature']);
      expect(words(r'\once \override NoteHead.col'), ['color']);
      expect(words(r'\set Staff.inst'), ['instrumentName']);
    });

    test('after \\ a command, or a variable the score defines; nothing in a comment', () {
      expect(words(r'c4\stacc'), ['staccato', 'staccatissimo']);
      expect(words(r'\me')!.first, 'melody');
      expect(words(r'{ \bass'), ['bassLine']);
      expect(words(r'c4 % \new '), isNull);
      expect(words(r'\markup "100% \bo'), ['book', 'bookpart', 'bold', 'box']);
      expect(words('c4 d'), isNull);
    });
  });

  group('the editor', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('lilypond-editor-'));
    tearDown(() {
      LilyPond.debugExecutable = null;
      // Read again by the next test: the bundle keeps what it read as a future of this test's
      // clock, which nothing moves after it.
      rootBundle.evict(LilyPond.settingsAsset);
      dir.deleteSync(recursive: true);
    });

    /// A stand-in for LilyPond running [script] (sh) with OUT set to where it writes its SVG.
    void standIn(String script) {
      final file = File('${dir.path}/lilypond')
        ..writeAsStringSync('#!/bin/sh\nOUT=""\nwhile [ \$# -gt 0 ]; do\n  if [ "\$1" = "-o" ]; then OUT="\$2"; shift; fi\n  shift\ndone\n$script');
      Process.runSync('chmod', ['+x', file.path]);
      LilyPond.debugExecutable = file;
    }

    // The fixture's score as a file of the editor's own: its links name it, and what it is.
    final svg = File('$_fixture.svg').absolute.path, data = File('$_fixture.jsonl').absolute.path;
    final engraves = "sed 's#textedit:///score/fixture.ly:#textedit://song.ly:#g' '$svg' > \"\$OUT.svg\"\n"
        "cp '$data' \"\$CURATOR_LILYPOND_DATA\"\n"
        'echo "song.ly:2:5: warning: barcheck failed at: 1/4" >&2\n';
    final source = LilySource(name: 'song.ly', text: File('$_fixture.ly').readAsStringSync(), files: {
      'parts/notes.ily': Uint8List.fromList('notes = { c4 }\n'.codeUnits),
    });

    LilyPondEdit? edit;
    var closed = false;
    Future<void> open(WidgetTester tester) async {
      edit = null;
      closed = false;
      tester.view.physicalSize = const Size(2400, 1600);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: AppColors.theme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                edit = await showLilyPondEditor(context, source);
                closed = true;
              },
              child: const Text('Edit'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('Edit'));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    /// Pumps until [done], LilyPond's run and the reading of its drawing let through (both start
    /// on a timer of no delay, which only a pump that moves the clock lets go).
    Future<void> until(WidgetTester tester, bool Function() done) async {
      for (var i = 0; i < 400 && !done(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(done(), isTrue);
    }

    CodeLineEditingController code(WidgetTester tester) => tester.widget<CodeEditor>(find.byType(CodeEditor)).controller!;

    testWidgets('engraved, its score is drawn, a click goes to where a note is written, a problem to its line, and Done gives it back',
        (tester) async {
      standIn(engraves);
      await open(tester);
      // The files it is made of, the main one first.
      Finder file(String path) => find.descendant(of: find.byType(SidebarTile), matching: find.text(path));
      expect(tester.getTopLeft(file('song.ly')).dy, lessThan(tester.getTopLeft(file('parts/notes.ily')).dy));
      expect(find.text('Engrave to see the score.'), findsOneWidget);

      await tester.tap(find.text('Engrave'));
      await until(tester, () => find.byKey(const ValueKey('LilyPond preview')).evaluate().isNotEmpty);
      // LilyPond's warning, where it is: a click goes there.
      expect(find.text('song.ly:2:5: barcheck failed at: 1/4'), findsOneWidget);
      await tester.tap(file('parts/notes.ily'));
      await tester.pump();
      expect(find.byKey(const ValueKey('parts/notes.ily')), findsOneWidget);
      await tester.tap(find.text('song.ly:2:5: barcheck failed at: 1/4'));
      await tester.pump();
      expect(find.byKey(const ValueKey('song.ly')), findsOneWidget);
      expect((code(tester).selection.extentIndex, code(tester).selection.extentOffset), (1, 4));

      // The flute's first note, clicked in the preview: its line (\partial 4 d4, line 14).
      final drawn = LilyPondDrawing(LilyPondScore.read(
          File('$_fixture.svg').readAsStringSync().replaceAll('textedit:///score/fixture.ly:', 'textedit://song.ly:'),
          File('$_fixture.jsonl').readAsStringSync()));
      addTearDown(drawn.dispose);
      final extent = drawn.bounds.inflate(2 * LilyPondScore.unit), staff = drawn.score.engraving.staves.first;
      final note = Offset(drawn.score.engraving.measures.first.onsetXs.first + LilyPondScore.unit / 2, staff.top + LilyPondScore.unit);
      await tester.tapAt(tester.getTopLeft(find.byKey(const ValueKey('LilyPond preview'))) + (note - extent.topLeft) * (5.5 / LilyPondScore.unit));
      await tester.pump();
      expect(code(tester).selection.extentIndex, 13);

      await tester.tap(find.text('Done'));
      await until(tester, () => closed);
      expect(edit?.run.engraved, isTrue);
      expect(edit?.source.text, source.text);
      expect(edit?.source.files.keys, ['parts/notes.ily']);
    }, variant: _mac);

    testWidgets('LilyPond’s errors are listed, and Done stays until it engraves', (tester) async {
      standIn('echo "song.ly:3:1: error: syntax error, unexpected \'}\'" >&2\nexit 1\n');
      await open(tester);
      await tester.tap(find.text('Done'));
      await until(tester, () => find.text("song.ly:3:1: syntax error, unexpected '}'").evaluate().isNotEmpty);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(closed, isFalse);
      expect(find.text('Nothing to show yet.'), findsOneWidget);
      // Cancel, nothing changed: closed with nothing.
      await tester.tap(find.text('Cancel'));
      await until(tester, () => closed);
      expect(edit, isNull);
    }, variant: _mac);

    testWidgets('File ▸ New LilyPond Score… opens the editor on a few bars; Done makes them a new project in a tab, unsaved, Cancel nothing',
        (tester) async {
      standIn("cp '$svg' \"\$OUT.svg\"\ncp '$data' \"\$CURATOR_LILYPOND_DATA\"\n");
      desktopWindow(tester);
      final settings = AppSettings.memory()..autosave = Duration.zero;
      await tester.pumpWidget(CuratedScoreApp(settings: settings));
      await tester.pump(const Duration(seconds: 1));
      Future<void> frames([int n = 20]) async {
        for (var i = 0; i < n; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
      }

      // The menu bar in the window, as off a Mac.
      Future<void> newScore() async {
        await tester.tap(find.text('File'));
        await frames(10);
        await tester.tap(find.text('New LilyPond Score…'));
        await frames();
      }

      final pages = find.byType(ProjectPage, skipOffstage: false);
      await newScore();
      expect(code(tester).text, contains('instrumentName = "Melody"'));
      await tester.tap(find.text('Cancel'));
      await frames();
      expect(find.byType(LilyPondEditor), findsNothing);
      expect(pages, findsNothing);

      await newScore();
      await tester.tap(find.text('Done'));
      dynamic page() => (pages.evaluate().single as StatefulElement).state;
      await until(tester, () => pages.evaluate().isNotEmpty && (page().controller as EditorController).score != null);
      await frames();
      final controller = page().controller as EditorController, document = page().document as ProjectDocument;
      expect((controller.isLilyPond, controller.fileName), (true, 'Untitled.ly'));
      // In no file: unsaved from the start, and not a recent file.
      expect((document.isDirty, document.path), (true, null));
      expect(settings.recentFiles, isEmpty);
      expect(find.descendant(of: find.byType(ProjectTabs), matching: find.text('Untitled')), findsOneWidget);

      // Closed (its × shows under the pointer: an edited tab has a dot), it asks to save it first.
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.descendant(of: find.byType(ProjectTabs), matching: find.text('Untitled'))));
      await tester.pump();
      await tester.tap(find.descendant(of: find.byType(ProjectTabs), matching: find.byType(IconButton)));
      await frames();
      expect(find.text('Don’t Save'), findsOneWidget);
      await tester.tap(find.text('Don’t Save'));
      await until(tester, () => pages.evaluate().isEmpty);
      await frames(30);
    });
  }, skip: Platform.isWindows);
}
