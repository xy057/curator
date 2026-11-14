// The extension editor: Lua as it colours and prompts it, the connector as a picture, the
// reference, and what Project Settings ▸ Extensions does with a package.
import 'package:curated_score/app_colors.dart';
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/extensions/bundled.dart';
import 'package:curated_score/extensions/connector_view.dart';
import 'package:curated_score/extensions/extension_actions.dart';
import 'package:curated_score/extensions/extension_editor.dart';
import 'package:curated_score/lua_language.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:re_editor/re_editor.dart';
import 'package:score_engine/score_engine.dart';

import 'extensions_test.dart' show notes;
import 'test_fonts.dart';
import 'window.dart';

void main() {
  test('Lua is coloured a line at a time, a long comment or string running on to the next', () {
    List<String> scopes(String line, {int state = 0}) => [for (final (scope, text) in luaTokens(line, state: state).runs) if (scope != null) '$scope:$text'];
    expect(scopes('local n = score.bars() -- all'), ['keyword:local', 'built_in:score', 'comment:-- all']);
    expect(scopes('function M.items(a, b) return nil, 0x1F, 1.5e-3, "a\\"b" end'),
        ['keyword:function', 'title:items', 'keyword:return', 'literal:nil', 'number:0x1F', 'number:1.5e-3', 'string:"a\\"b"', 'keyword:end']);
    expect(scopes("local function tidy(list) for i, v in ipairs(list) do end end"),
        ['keyword:local', 'keyword:function', 'title:tidy', 'keyword:for', 'keyword:in', 'built_in:ipairs', 'keyword:do', 'keyword:end', 'keyword:end']);
    expect(scopes('data.score = 1'), ['number:1'], reason: 'a field named as a library is a field');
    // --[==[ … ]==] and [[ … ]] run over lines: the state says which is open.
    final open = luaTokens('x = 1 --[==[ a comment');
    expect(open.state, isNot(0));
    expect(scopes('still ]] in it', state: open.state), ['comment:still ]] in it']);
    expect(luaTokens('still ]] in it', state: open.state).state, open.state);
    final closed = luaTokens('done ]==] y = [[text', state: open.state);
    expect([for (final (scope, text) in closed.runs) '$scope:$text'], ['comment:done ]==]', 'null: y = ', 'string:[[text']);
    expect(luaTokens('more]] z = 2', state: closed.state).state, 0);
  });

  test('What is offered as Lua is typed: a library’s functions after its dot, names otherwise, nothing in a comment or a string', () {
    final prompts = LuaPrompts(() => 'local chapters = require("chapters")\nlocal function tidy() end');
    List<String>? words(String before) => prompts.promptsFor(before)?.prompts.map((p) => p.word).toList();
    expect(words('  local bars = score.'), containsAll(['bars', 'spans', 'format', 'parse']));
    expect(words('  local bars = score.sp'), ['spans']);
    expect(words('curator.'), containsAll(['data', 'save', 'tr', 'api', 'null']));
    expect(words('x = math.ro'), ['round']);
    expect(words('string.f'), ['find', 'format']);
    expect(words('  cur'), ['curator']);
    expect(words('  ch'), ['chapters']);
    expect(words('  ti'), ['tidy']);
    expect(words('-- score.'), isNull);
    expect(words('x = "score.'), isNull);
    expect(words('x = "a" .. score.f'), ['format']);
    expect(words('unknown.'), isNull);
    final spans = prompts.promptsFor('score.sp')!.prompts.single as LuaPrompt;
    expect(spans.function!.signature, 'score.spans(places, end) → list');
  });

  testWidgets('the editor: the connector as a picture, a wire pulled onto a file, the reference, Done', (tester) async {
    await tester.runAsync(loadTestFonts);
    desktopWindow(tester);
    ExtensionPackage? result;
    var closed = false;
    await tester.pumpWidget(MaterialApp(
      theme: AppColors.theme(style: UiStyle.refined, brightness: Brightness.light),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async {
                result = await showExtensionEditor(context, notes());
                closed = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // The connector: each socket with its ports, the file with its functions.
    expect(find.byType(ConnectorView), findsOneWidget);
    expect(find.text('Notes'), findsWidgets);
    for (final port in ['opened', 'items', 'add', 'move', 'erase', 'run', 'enabled']) {
      expect(find.text(port), findsWidgets, reason: port);
    }
    expect(find.text('main.lua'), findsNWidgets(2), reason: 'in the list of files and in the picture');
    await screenshot(tester, 'extension-connector', inside: find.byType(ExtensionEditor), outermost: true);

    // A port pulled onto the file's name: a function is written for it, and wired.
    final connector = find.byType(ConnectorView);
    final move = find.descendant(of: connector, matching: find.text('move'));
    final file = find.descendant(of: connector, matching: find.text('main.lua'));
    final gesture = await tester.startGesture(tester.getCenter(move));
    await tester.pump(const Duration(milliseconds: 50));
    for (final step in [0.2, 0.5, 0.8, 1.0]) {
      await gesture.moveTo(Offset.lerp(tester.getCenter(move), tester.getCenter(file), step)!);
      await tester.pump(const Duration(milliseconds: 20));
    }
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('notes_move'), findsOneWidget);

    // The reference: searched as typed.
    await tester.enterText(find.descendant(of: find.byType(ExtensionReference), matching: find.byType(EditableText)), 'score.spans');
    await tester.pump();
    expect(find.textContaining('score.spans(places, end)'), findsOneWidget);
    expect(find.textContaining('curator.save'), findsNothing);

    // A file's code, and the guide.
    await tester.tap(find.text('main.lua').first);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(CodeEditor), findsOneWidget);
    await screenshot(tester, 'extension-code', inside: find.byType(ExtensionEditor), outermost: true);
    await tester.tap(find.byTooltip('Help'));
    await tester.pump(); // the guide is asked for
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('Writing an extension', findRichText: true), findsOneWidget);
    await screenshot(tester, 'extension-help', inside: find.byType(ExtensionEditor), outermost: true);

    await tester.tap(find.widgetWithText(FilledButton, 'Done'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(closed, isTrue);
    final edited = result!;
    expect(edited.graph.wire('notes', 'move')!.to, 'main.lua#notes_move');
    expect(edited.sources['main.lua'], contains('-- notes.move: Markers: item index is being dragged'));
    expect(edited.sources['main.lua'], endsWith('function M.notes_move(index, at)\nend\n\nreturn M\n'));
    expect(checkExtension(edited), isEmpty);
    expect(ExtensionPackage.read(edited.write()), edited, reason: 'as a .cpe, and back');
  });

  testWidgets('what is wrong with an extension as written shows under it, with its file and line', (tester) async {
    desktopWindow(tester);
    final broken = notes().copyWith(sources: {'main.lua': 'local M = {}\nfunction M.items(\nreturn M\n'});
    await tester.pumpWidget(MaterialApp(
      theme: AppColors.theme(style: UiStyle.refined, brightness: Brightness.light),
      home: ExtensionEditor(package: broken),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('main.lua:3:'), findsOneWidget);
  });

  test('a copy of one of Curator’s own is the project’s to change: an id and data of its own', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    final c = EditorController(vsync: const TestVSync());
    addTearDown(c.dispose);
    final chapters = BundledExtensions.byId('chapters')!;
    final copy = ExtensionActions.copyOf(chapters, c);
    expect((copy.id, copy.name, copy.version), ('user.chapters', 'Chapters Copy', '1.0.0'));
    expect(copy.data, {'version': 1}, reason: 'its data is kept under its own id, not in Chapters’ module');
    expect(copy.sources, chapters.sources);
    expect(copy.graph.toText(), chapters.graph.toText());
    c.extensions.add(copy);
    expect(ExtensionActions.idFor('Chapters', c), 'user.chapters-2');
    expect(ExtensionActions.idFor('  My Notes! ', c), 'user.my-notes');
    expect(ExtensionActions.idFor('音符', c), 'user.extension');
    expect(AppSettings.memory().extensionSettings('user.chapters'), isNull);
  });
}
