// The score editor's MusicXML view: its highlighting, what it offers as MusicXML is typed, where
// a bar is in its text, and the view itself (toggled, read back into the score, Undo, problems).
import 'package:curated_score/app_colors.dart';
import 'package:curated_score/musicxml_language.dart';
import 'package:curated_score/score_editor.dart';
import 'package:curated_score/ui_kit.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:re_editor/re_editor.dart';
import 'package:score_engine/score_engine.dart';

import 'window.dart';

/// A flute, two empty bars of 4/4.
const _flute = '''<?xml version="1.0" encoding="UTF-8"?>
<score-partwise version="4.0">
  <part-list><score-part id="P1"><part-name>Flute</part-name></score-part><score-part id="P2"><part-name>Oboe</part-name></score-part></part-list>
  <part id="P1">
    <measure number="1"><attributes><divisions>1</divisions><key><fifths>0</fifths></key><time><beats>4</beats><beat-type>4</beat-type></time><clef><sign>G</sign><line>2</line></clef></attributes>
      <note><rest measure="yes"/><duration>4</duration><voice>1</voice></note></measure>
    <measure number="2"><note><rest measure="yes"/><duration>4</duration><voice>1</voice></note></measure>
  </part>
  <part id="P2">
    <measure number="1"><attributes><divisions>1</divisions><key><fifths>0</fifths></key><time><beats>4</beats><beat-type>4</beat-type></time><clef><sign>G</sign><line>2</line></clef></attributes>
      <note><rest measure="yes"/><duration>4</duration><voice>1</voice></note></measure>
    <measure number="2"><note><rest measure="yes"/><duration>4</duration><voice>1</voice></note></measure>
  </part>
</score-partwise>''';

/// The editor as on a Mac, as Curator is (re_editor reads the platform once: on a phone its caret
/// waits on a timer of its own).
final _mac = TargetPlatformVariant.only(TargetPlatform.macOS);

void main() {
  test('MusicXML is coloured a line at a time: the declaration, comments, tags (the score\'s shape apart), attributes, values, entities, numbers', () {
    List<(String?, String)> scoped(String line) => [for (final t in musicXmlTokens(line)) if (t.$2.trim().isNotEmpty) t];
    expect(scoped('<?xml version="1.0" encoding="UTF-8"?>'), [('meta', '<?xml version="1.0" encoding="UTF-8"?>')]);
    expect(scoped('<!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 4.0 Partwise//EN">'), [
      ('meta', '<!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 4.0 Partwise//EN">'),
    ]);
    expect(scoped('  <!-- the flute --> <measure number="12">'), [
      ('comment', '<!-- the flute -->'),
      ('tag', '<'),
      ('keyword', 'measure'),
      ('attr', 'number'),
      (null, '='),
      ('string', '"12"'),
      ('tag', '>'),
    ]);
    expect(scoped('<octave>5</octave>'), [('tag', '<'), ('name', 'octave'), ('tag', '>'), ('number', '5'), ('tag', '</'), ('name', 'octave'), ('tag', '>')]);
    expect(scoped('<slur type="start" number="1"/>'), [
      ('tag', '<'), ('name', 'slur'), ('attr', 'type'), (null, '='), ('string', '"start"'), ('attr', 'number'), (null, '='), ('string', '"1"'), ('tag', '/>'),
    ]);
    expect(scoped('<words>Fl. &amp; Ob. 2</words>'), [
      ('tag', '<'), ('name', 'words'), ('tag', '>'), (null, 'Fl. '), ('symbol', '&amp;'), (null, ' Ob. 2'), ('tag', '</'), ('name', 'words'), ('tag', '>'),
    ]);
    // A name that begins as one of the score's shape is another: part-name, measure-style.
    expect(scoped('<part-name>Fl.</part-name>')[1], ('name', 'part-name'));
    expect(scoped('</note>'), [('tag', '</'), ('keyword', 'note'), ('tag', '>')]);
    // What isn't a tag is text, and every character is in a run.
    const odd = 'a < b && c <3> "d"';
    expect(musicXmlTokens(odd).map((t) => t.$2).join(), odd);
  });

  test('an element whose tags are on lines of their own folds, from its start tag\'s line to its end tag\'s', () {
    final lines = EditableScore.parse(_flute).toMusicXMLText().text;
    final folds = const MusicXmlFolds().run(CodeLines.fromText(lines));
    final rows = lines.split('\n');
    String fold(CodeChunk c) => '${rows[c.index].trim()}…${rows[c.end].trim()}';
    expect(folds.map(fold), containsAll(['<score-partwise version="4.0">…</score-partwise>', '<part id="P1">…</part>', '<measure number="2">…</measure>']));
    expect(folds.map(fold).where((f) => f.startsWith('<step>')), isEmpty); // on one line: nothing to fold
    expect(folds.map((c) => c.index).toList(), [...folds.map((c) => c.index)]..sort());
  });

  group('what is offered', () {
    final prompts = MusicXmlPrompts((_) => '');
    List<String>? words(String before, {String after = '', List<String> above = const []}) =>
        prompts.promptsFor(before, after: after, above: above)?.prompts.map((p) => p.word).toList();
    String? put(String before, String word, {String after = '', List<String> above = const []}) {
      final value = prompts.promptsFor(before, after: after, above: above)!;
      final result = value.copyWith(index: value.prompts.indexWhere((p) => p.word == word)).autocomplete;
      // As the editor puts it in: the word in place of what was typed, the caret where it says.
      final start = before.substring(0, before.length - result.input.length);
      return '$start${result.word.substring(0, result.selection.baseOffset + result.input.length)}|'
          '${result.word.substring(result.selection.baseOffset + result.input.length)}$after';
    }

    test('after < the elements the one the caret is in holds, in the schema\'s order; put in with their end tag', () {
      expect(words('      <', above: ['    <note>', '  <measure number="1">'])!.take(6), ['grace', 'chord', 'pitch', 'unpitched', 'rest', 'tie']);
      expect(words('    <p', above: ['  <note>']), ['pitch', 'play']);
      expect(put('    <pi', 'pitch', above: ['  <note>']), '    <pitch>|</pitch>');
      // Holding nothing: <chord/>.
      expect(put('    <ch', 'chord', above: ['  <note>']), '    <chord/>|');
      // A name being changed: the word alone.
      expect(put('    <ch', 'chord', after: 'ord/>', above: ['  <note>']), '    <chord|ord/>');
      // Outside every element: the score.
      expect(words('<', above: ['<?xml version="1.0"?>']), ['score-partwise']);
    });

    test('the element the caret is in is read back through the lines above, an element seen whole on the way telling it', () {
      expect(MusicXmlPrompts.openElement('<pitch><step>C</step>', const []), 'pitch');
      // A whole sibling with one place to be in: a bar is in a part, a note in a bar.
      expect(MusicXmlPrompts.openElement('    ', ['    </measure>', '      </note>', '      <note>', '    <measure number="1">']), 'part');
      expect(MusicXmlPrompts.openElement('      <chord/>', const []), 'note');
      expect(MusicXmlPrompts.openElement('', ['<?xml version="1.0" encoding="UTF-8"?>']), isNull); // read to the top, nothing open
      expect(MusicXmlPrompts.openElement('', ['      <direction-type>', '        <words>a</words>']), 'direction-type');
      // Not found within reach: every element is offered.
      final far = List.filled(MusicXmlPrompts.reach, '  <!-- -->');
      expect(MusicXmlPrompts.openElement('', far), '');
      expect(words('<pitc', above: far), ['pitch', 'pitched']);
    });

    test('after </ the end tag of the element the caret is in', () {
      expect(put('      </', 'note', above: ['      <rest/>', '    <note>']), '      </note>|');
      expect(put('      </n', 'note', after: '>', above: ['    <note>']), '      </note|>');
      expect(words('</', above: ['<?xml version="1.0"?>']), isNull);
    });

    test('in a start tag its attributes not written yet, put in with their quotes; in the quotes their values', () {
      expect(words('<slur ')!.take(3), ['type', 'number', 'line-type']);
      expect(words('<slur type="start" n'), ['number']);
      expect(words('<slur type="start" ty'), isNull);
      expect(put('<slur ty', 'type'), '<slur type="|"');
      expect(words('<slur type="'), ['start', 'stop', 'continue']);
      expect(words('<note print-object="'), ['yes', 'no']);
      expect(put('<wedge type="cre', 'crescendo', after: '"/>'), '<wedge type="crescendo|"/>');
    });

    test('in an element\'s text its values, its end tag put in after one where none follows; after & an entity; nothing in a comment', () {
      expect(words('<type>')!.take(3), ['1024th', '512th', '256th']);
      expect(words('<type>q'), ['quarter']);
      expect(put('<type>q', 'quarter'), '<type>quarter|</type>');
      expect(put('<type>q', 'quarter', after: '</type>'), '<type>quarter|</type>');
      expect(words('<step>'), ['A', 'B', 'C', 'D', 'E', 'F', 'G']);
      expect(words('<beam number="1">b'), ['begin', 'backward hook']);
      expect(words('<mode>m'), ['major', 'minor', 'mixolydian']); // from the schema's words, not its list
      expect(words('<words>Allegro'), isNull);
      expect(put('<words>Fl. &am', 'amp'), '<words>Fl. &amp;|');
      expect(words('<!-- <no'), isNull);
    });
  });

  test('where a bar is in the text: its part and place, its number; the line a bar starts on', () {
    final text = EditableScore.parse(_flute).toMusicXMLText().text.split('\n');
    String line(int i) => text[i];
    final second = MusicXmlLines.lineOfBar(line, text.length, 1, 1)!;
    expect(text[second].trim(), '<measure number="2">');
    expect(MusicXmlLines.barAt(line, second + 2), (part: 1, id: 'P2', measure: 1, number: '2'));
    expect(MusicXmlLines.barAt(line, second + 2, count: false), (part: -1, id: 'P2', measure: -1, number: '2'));
    expect(MusicXmlLines.barAt(line, MusicXmlLines.lineOfBar(line, text.length, 0, 0)!), (part: 0, id: 'P1', measure: 0, number: '1'));
    expect(MusicXmlLines.barAt(line, 2), isNull); // the part list
    expect(MusicXmlLines.barAt(line, text.indexWhere((l) => l.trim() == '<part id="P2">')), isNull);
    expect(MusicXmlLines.lineOfBar(line, text.length, 1, 2), isNull);
  });

  testWidgets('the score editor\'s MusicXML view: toggled, read into the score, Undo going back across it, what is wrong said, Done', (tester) async {
    desktopWindow(tester);
    String? result;
    var closed = false;
    await tester.pumpWidget(MaterialApp(
      theme: AppColors.theme(),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showScoreEditor(context, EditableScore.parse(_flute), name: 'Duet.musicxml');
              closed = true;
            },
            child: const Text('Open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    Future<void> settle() async {
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
    }

    await settle();
    final toggle = find.byWidgetPredicate((w) => w is ToolbarButton && w.tooltip == 'MusicXML');
    ToolbarButton button(String tooltip) => tester.widget<ToolbarButton>(find.byWidgetPredicate((w) => w is ToolbarButton && w.tooltip.startsWith(tooltip)));
    CodeLineEditingController code() => tester.widget<CodeEditor>(find.byType(CodeEditor)).controller!;
    Future<void> command(LogicalKeyboardKey key, {bool shift = false}) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(key);
      if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
    }

    // A note typed first (the flute's C), so the score before the text has a step to undo.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    for (final key in [LogicalKeyboardKey.digit6, LogicalKeyboardKey.keyC, LogicalKeyboardKey.escape]) {
      await tester.sendKeyEvent(key);
    }
    await settle();

    // Shown: the score as text, an element a line; the panels and the zoom gone, the text's Undo.
    await tester.tap(toggle);
    await settle();
    expect(find.byType(CodeEditor), findsOneWidget);
    expect(tester.widget<ToolbarButton>(toggle).selected, isTrue);
    expect(find.byWidgetPredicate((w) => w is ToolbarButton && w.tooltip == 'Zoom In'), findsNothing);
    expect(code().codeLines[1].text, '<score-partwise version="4.0">');
    expect(button('Undo').onPressed, isNull);
    // Its keys are its own: a letter is not a note.
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.keyC), isFalse);
    await screenshot(tester, 'score-editor-musicxml', inside: find.byType(ScoreEditor));

    // The oboe's second bar made a G, the caret there: back in the score it is that bar's note.
    final lines = code().text.split('\n');
    final bar = MusicXmlLines.lineOfBar((i) => lines[i], lines.length, 1, 1)!;
    final rest = lines.indexWhere((l) => l.contains('<rest measure="yes"/>'), bar);
    code().text = [...lines.take(rest), '        <pitch><step>G</step><octave>4</octave></pitch>', ...lines.skip(rest + 1)].join('\n');
    code().selection = CodeLineSelection.collapsed(index: rest, offset: 8);
    await tester.pump();
    expect(find.text('Oboe · Bar 2'), findsOneWidget);
    expect(button('Undo').onPressed, isNotNull);
    await tester.tap(toggle);
    await settle();
    expect(find.byType(CodeEditor), findsNothing);
    expect(find.textContaining('Oboe · 2.1 · G4'), findsOneWidget);

    // Undo goes back to the score before the text was read, Redo on to it again.
    await command(LogicalKeyboardKey.keyZ);
    await settle();
    expect(find.textContaining('G4'), findsNothing);
    expect(button('Redo').onPressed, isNotNull);
    // A key that changes nothing (a slur with no notes) leaves Redo as it was.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await settle();
    expect(button('Redo').onPressed, isNotNull);
    await command(LogicalKeyboardKey.keyZ, shift: true);
    await settle();
    expect(button('Undo').onPressed, isNotNull);

    // What can't be read is said, where it is; the view stays.
    await tester.tap(toggle);
    await settle();
    final g = code().text.split('\n').indexWhere((l) => l.contains('<step>G</step>'));
    expect(g, greaterThan(0));
    code().text = code().text.replaceFirst('<octave>4</octave>', '<octave>4</octav>');
    await tester.tap(find.text('Done'));
    await settle();
    expect(closed, isFalse);
    expect(find.byType(CodeEditor), findsOneWidget);
    // (The end tag that doesn't match is on the line after the step's.)
    final problem = find.textContaining(RegExp('^${g + 2}:\\d+: '));
    expect(problem, findsOneWidget);
    code().selection = const CodeLineSelection.collapsed(index: 0, offset: 0);
    await tester.tap(problem);
    await tester.pump();
    expect(code().selection.extentIndex, g + 1);

    // Mended, Done reads it and gives the score as edited.
    code().text = code().text.replaceFirst('<octave>4</octav>', '<octave>5</octave>');
    await tester.tap(find.text('Done'));
    await settle();
    expect(closed, isTrue);
    final oboe = EditableScore.parse(result!).eventsIn(1, 1, const VoiceKey(1, '1'));
    expect([for (final e in oboe) e.pitches.single.name], ['G5']);
    expect(EditableScore.parse(result!).eventsIn(0, 0, const VoiceKey(1, '1')).first.pitches.single.name, 'C5'); // the note typed first
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100)); // the code view's timers run out
    }
  }, variant: _mac);
}
