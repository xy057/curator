// The LilyPond editor: its colouring, what it offers as LilyPond is typed, and the editor itself
// (engraving with a stand-in LilyPond, its preview and problems, Done).
import 'dart:io';
import 'dart:typed_data';

import 'package:curated_score/app_colors.dart';
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/font_settings.dart' show TextFontPicker;
import 'package:curated_score/main.dart';
import 'package:curated_score/project_document.dart';
import 'package:curated_score/project_tabs.dart';
import 'package:curated_score/lilypond.dart';
import 'package:curated_score/lilypond_editor.dart';
import 'package:curated_score/lilypond_language.dart';
import 'package:curated_score/ui_kit.dart' show SidebarTile;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:re_editor/re_editor.dart';
import 'package:score_engine/score_engine.dart';

import 'window.dart';

/// The engine's fixture: a score LilyPond 2.26.0 engraved with Curator's settings.
const _fixture = '../packages/score_engine/test/lilypond/fixture';

/// The editor as on a Mac, as Curator is (re_editor reads the platform once: on a phone its caret
/// waits on a timer of its own).
final _mac = TargetPlatformVariant.only(TargetPlatform.macOS);

/// [source] coloured a line at a time, each line from where the one above left off: each run of
/// text that is coloured, as (scope, text).
List<(String, String)> _scoped(String source) {
  final lines = source.split('\n'), out = <(String, String)>[];
  var state = 0;
  for (var i = 0; i < lines.length; i++) {
    final tokens = lilyPondTokens(lines[i], state: state, after: lines.skip(i + 1));
    expect(tokens.runs.map((r) => r.$2).join(), lines[i]);
    state = tokens.state;
    for (final (scope, text) in tokens.runs) {
      if (scope != null && text.trim().isNotEmpty) out.add((scope, text.trim()));
    }
  }
  return out;
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

  test('a block comment, a string or Scheme running over lines colours the lines after it, as a variable whose = is on the next', () {
    expect(_scoped('''
%{ a comment
over \\new Staff lines %} \\new Staff
\\markup "a string
over lines" c4
#(define (f x)
  (display "x") ; done
  #! a block
  comment !# x) d8
melody
  = { c }
'''), [
      ('comment', '%{ a comment'),
      ('comment', r'over \new Staff lines %}'),
      ('keyword', r'\new'),
      ('title', 'Staff'),
      ('keyword', r'\markup'),
      ('string', '"a string'),
      ('string', 'over lines"'),
      ('number', '4'),
      ('keyword', 'define'),
      ('built_in', 'display'),
      ('string', '"x"'),
      ('comment', '; done'),
      ('comment', '#! a block'),
      ('comment', 'comment !#'),
      ('number', '8'),
      ('variable', 'melody'),
    ]);
  });

  test('each line starts where the one above left off, read again from the first line changed: edited, put in, folded', () {
    final code = CodeLineEditingController.fromText('c4 d\n\\new Staff\ne8 f');
    addTearDown(code.dispose);
    final states = LilyPondStates(() => code.codeLines);
    List<String?> scopes(int i) => [for (final (scope, _) in lilyPondTokens(code.codeLines[i].text, state: states.at(i)).runs) scope];
    expect(scopes(1), ['keyword', null, 'title']);
    // A block comment opened on the first line: the lines under it in it.
    code.selection = const CodeLineSelection.collapsed(index: 0, offset: 0);
    code.replaceSelection('%{ ');
    expect([scopes(1), scopes(2)], [['comment'], ['comment']]);
    // Closed on a line put in under it: the lines under that out of it again.
    code.selection = const CodeLineSelection.collapsed(index: 0, offset: 7);
    code.replaceSelection('\n%}');
    expect([scopes(1), scopes(2)], [['comment'], ['keyword', null, 'title']]);
    // A line folded: what is folded under it read with it.
    code.codeLines = CodeLines.of(const [CodeLine('{', [CodeLine('%{'), CodeLine('}')]), CodeLine(r'\new Staff')]);
    expect(scopes(1), ['comment']);
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
    var closed = false, hub = 0;
    Future<void> open(WidgetTester tester) async {
      edit = null;
      closed = false;
      hub = 0;
      tester.view.physicalSize = const Size(2400, 1600);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: AppColors.theme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                edit = await showLilyPondEditor(context, source, downloadHub: () => hub++);
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

    testWidgets('its code is coloured a line at a time as it is drawn, in the page’s colours', (tester) async {
      await open(tester);
      final view = tester.element(find.byType(CodeEditor));
      List<InlineSpan>? line(int i) =>
          code(tester).buildTextSpan(context: view, index: i, textSpan: const TextSpan(), style: const TextStyle()).children;
      final theme = lilyPondTheme(Brightness.light);
      expect(line(0), [TextSpan(text: r'\version', style: theme['keyword']), const TextSpan(text: ' '), TextSpan(text: '"2.26.0"', style: theme['string'])]);
      expect(line(1), [TextSpan(text: source.text.split('\n')[1], style: theme['comment'])]);
      await tester.tap(find.text('Cancel'));
      await until(tester, () => closed);
    }, variant: _mac);

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

    testWidgets('without LilyPond, Engrave asks for it: Open Download Hub goes there, the editor staying', (tester) async {
      LilyPond.debugFolder = Directory('${dir.path}/none');
      addTearDown(() => LilyPond.debugFolder = null);
      await open(tester);
      await tester.tap(find.text('Engrave'));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(find.text('Download LilyPond?'), findsOneWidget);
      await tester.tap(find.text(LilyPond.package == null ? 'Cancel' : 'Open Download Hub').last);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(find.text('Download LilyPond?'), findsNothing);
      expect(hub, LilyPond.package == null ? 0 : 1);
      expect((find.byType(LilyPondEditor).evaluate().length, closed), (1, false));
      expect(find.text('Engrave to see the score.'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await until(tester, () => closed);
      expect(edit, isNull);
    }, variant: _mac);

    testWidgets('without LilyPond, File ▸ New LilyPond Score… asks for it first; Open Download Hub opens Settings there', (tester) async {
      LilyPond.debugFolder = Directory('${dir.path}/none');
      addTearDown(() => LilyPond.debugFolder = null);
      desktopWindow(tester);
      await tester.pumpWidget(CuratedScoreApp(settings: AppSettings.memory()));
      await tester.pump(const Duration(seconds: 1));
      Future<void> frames([int n = 20]) async {
        for (var i = 0; i < n; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
      }

      await tester.tap(find.text('File'));
      await frames(10);
      await tester.tap(find.text('New LilyPond Score…'));
      await frames();
      expect(find.text('Download LilyPond?'), findsOneWidget);
      expect(find.byType(LilyPondEditor), findsNothing);
      final package = LilyPond.package;
      if (package == null) return; // none for this computer
      final mb = (package.size / 1e6).round();
      expect(find.text('LilyPond scores are engraved with LilyPond ($mb MB).'), findsOneWidget);
      await tester.tap(find.text('Open Download Hub'));
      await frames(30);
      // Settings, on the Download Hub: LilyPond's row, to download it; no editor.
      expect(find.text('Download LilyPond?'), findsNothing);
      expect(find.text('Engraves LilyPond scores. $mb MB.'), findsOneWidget);
      expect(find.text('Download'), findsOneWidget);
      expect(find.byType(LilyPondEditor), findsNothing);
    });

    testWidgets('without LilyPond, Project Settings ▸ Text font asks for it: Open Download Hub leaves for Settings there, the font as it was',
        (tester) async {
      final installed = await tester.runAsync(TextFonts.installed) ?? const <String>[];
      final family = ['Georgia', 'Times New Roman', 'DejaVu Serif', 'Liberation Serif'].where(installed.contains).firstOrNull;
      final package = LilyPond.package;
      if (family == null || package == null) return markTestSkipped('no serif font installed here, or no LilyPond for this computer');
      standIn("cp '$svg' \"\$OUT.svg\"\ncp '$data' \"\$CURATOR_LILYPOND_DATA\"\n");
      desktopWindow(tester);
      await tester.pumpWidget(CuratedScoreApp(settings: AppSettings.memory()..autosave = Duration.zero));
      await tester.pump(const Duration(seconds: 1));
      Future<void> frames([int n = 20]) async {
        for (var i = 0; i < n; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
      }

      // The menu bar in the window, as off a Mac.
      Future<void> menu(String name, String item) async {
        await tester.tap(find.text(name));
        await frames(10);
        await tester.tap(find.text(item));
        await frames();
      }

      // A LilyPond score made here; then LilyPond is gone.
      await menu('File', 'New LilyPond Score…');
      await tester.tap(find.text('Done'));
      final pages = find.byType(ProjectPage, skipOffstage: false);
      EditorController? controller() =>
          pages.evaluate().isEmpty ? null : ((pages.evaluate().single as StatefulElement).state as dynamic).controller as EditorController;
      await until(tester, () => controller()?.score != null);
      await frames();
      LilyPond.debugExecutable = null;
      LilyPond.debugFolder = Directory('${dir.path}/none');
      addTearDown(() => LilyPond.debugFolder = null);

      await menu('Edit', 'Project Settings…');
      await tester.tap(find.text('Engraving').first);
      await frames(30);
      // The families installed here, read on another isolate, reach the picker outside the test's clock.
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await frames();
      await tester.enterText(find.descendant(of: find.byType(TextFontPicker).first, matching: find.byType(TextField)), family);
      await frames();
      await tester.tap(find.descendant(of: find.byType(MenuItemButton), matching: find.text(family)).first);
      await frames();
      expect(find.text('Download LilyPond?'), findsOneWidget);
      await tester.tap(find.text('Open Download Hub'));
      await frames(40);
      // Project Settings gone, Settings on the Download Hub: LilyPond's row, to download it. The font as it was.
      expect(find.text('Download LilyPond?'), findsNothing);
      expect(find.byType(TextFontPicker), findsNothing);
      expect(find.text('Engraves LilyPond scores. ${(package.size / 1e6).round()} MB.'), findsOneWidget);
      expect(controller()!.fonts.text, TextFonts.academico);
    });

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
