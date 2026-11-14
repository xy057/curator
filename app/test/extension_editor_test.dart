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
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
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

  testWidgets('the connector: no card over another, cards dragged, wires pulled either way, marked and deleted, a port double-clicked, Tidy Up', (tester) async {
    await tester.runAsync(loadTestFonts);
    desktopWindow(tester);
    // Two sockets in the same place, and two files with no place at all.
    var graph = ConnectorGraph(
      nodes: [GraphNode(id: 'project', type: 'project', x: 40, y: 40), GraphNode(id: 'lane', type: 'lane', x: 40, y: 60, props: const {'title': 'Notes'})],
      wires: const [GraphWire('lane.items', 'b.lua#items')],
    );
    final functions = <String, List<FileFunction>?>{
      'a.lua': [(name: 'opened', parameters: const [], line: 1)],
      'b.lua': [(name: 'items', parameters: const [], line: 1), (name: 'add', parameters: const ['at'], line: 3)],
    };
    final opened = <String>[], calls = <String, int>{};
    var changes = 0, readOnly = false;
    late StateSetter rebuild;
    await tester.pumpWidget(MaterialApp(
      theme: AppColors.theme(style: UiStyle.refined, brightness: Brightness.light),
      home: Scaffold(
        body: StatefulBuilder(builder: (context, setState) {
          rebuild = setState;
          return ConnectorView(
            graph: graph,
            functions: functions,
            readOnly: readOnly,
            calls: () => calls,
            problems: const {'lane.items': 'attempt to index a nil value'},
            onChanged: (g) => setState(() {
              graph = g;
              changes++;
            }),
            onOpen: (file, function) => opened.add('$file#$function'),
            onCreate: (file, node, port) {
              functions[file] = [...functions[file]!, (name: '${node.id}_${port.name}', parameters: const [], line: 9)];
              return '${node.id}_${port.name}';
            },
          );
        }),
      ),
    ));
    Rect card(String title) => tester.getRect(find.ancestor(of: find.text(title), matching: find.byType(DecoratedBox)).first);
    Offset pin(String of) => tester.getCenter(find.byKey(ValueKey('pin:$of')));
    Future<void> drag(Offset from, Offset to, {int steps = 8}) async {
      final gesture = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
      for (var i = 1; i <= steps; i++) {
        await gesture.moveTo(Offset.lerp(from, to, i / steps)!);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 50));
    }

    // As it comes: nothing lies over anything.
    final cards = [card('Project'), card('Notes'), card('a.lua'), card('b.lua')];
    for (final (i, a) in cards.indexed) {
      for (final b in cards.skip(i + 1)) {
        expect(a.overlaps(b), isFalse, reason: '$a and $b');
      }
    }
    expect(card('Notes').top, greaterThan(card('Project').bottom));
    await screenshot(tester, 'connector-cards');

    // A card dragged by a row of it, a hair at a time: it follows the pointer, on the grid.
    final from = tester.getCenter(find.text('changed')), before = card('Project');
    await drag(from, from + const Offset(300.2, 0), steps: 600);
    expect(card('Project').left - before.left, 300);
    expect(changes, 1, reason: 'kept once, when let go');
    // Let go on another card, it goes below it.
    await drag(tester.getCenter(find.text('Notes')), tester.getCenter(find.text('b.lua')) + const Offset(60, 10));
    expect(card('Notes').overlaps(card('b.lua')), isFalse);
    expect(card('Notes').overlaps(card('a.lua')), isFalse);

    // Tidy Up: the sockets in one column, the files in the other, the wired file by its port.
    await tester.tap(find.text('Tidy Up'));
    await tester.pump();
    expect((card('Project').left, card('Notes').left), (card('Project').left, card('Project').left));
    expect(card('b.lua').top, lessThan(card('a.lua').top), reason: 'b.lua is wired, a.lua not');
    expect(graph.nodes.map((n) => n.x).toSet(), {40.0});

    // A wire pulled from a port's pin to a function, and from a function's pin to a port.
    await drag(pin('project.opened'), tester.getCenter(find.textContaining('opened', findRichText: true).last));
    expect(graph.wire('project', 'opened')!.to, 'a.lua#opened');
    await drag(pin('b.lua#add'), tester.getCenter(find.text('add')));
    expect(graph.wire('lane', 'add')!.to, 'b.lua#add');
    // Let go on nothing: a function is written for it, in the file its socket uses most.
    await drag(pin('lane.move'), pin('lane.move') + const Offset(60, 500));
    expect(graph.wire('lane', 'move')!.to, 'b.lua#lane_move');

    // A click on a wire marks it; Delete takes it out.
    final a = pin('project.opened'), b = pin('a.lua#opened');
    await tester.tapAt(Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();
    expect(graph.wire('project', 'opened'), isNull);

    // A port double-clicked: its function's code; with none, one is written first.
    await tester.tap(find.text('items'));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(find.text('items'));
    await tester.pump();
    expect(opened, ['b.lua#items']);
    await tester.tap(find.text('erase'));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(find.text('erase'));
    await tester.pump();
    await tester.pump();
    expect(graph.wire('lane', 'erase')!.to, 'b.lua#lane_erase');
    expect(opened.last, 'b.lua#lane_erase');
    await tester.tap(find.text('b.lua'));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(find.text('b.lua'));
    expect(opened.last, 'b.lua#null', reason: 'a file’s name: the file');

    // Running, each port says how often it was called.
    calls['lane.items'] = 12;
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('12'), findsOneWidget);
    await screenshot(tester, 'connector-wired');

    // Read only, a card still moves, and nothing is changed.
    rebuild(() => readOnly = true);
    await tester.pump();
    final kept = changes, was = card('Project');
    await drag(tester.getCenter(find.text('changed')), tester.getCenter(find.text('changed')) + const Offset(0, 700));
    expect(card('Project').top, greaterThan(was.top));
    await drag(pin('project.changed'), tester.getCenter(find.text('a.lua')));
    expect((changes, graph.wire('project', 'changed')), (kept, null));
    await tester.pumpWidget(const SizedBox());
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
    final move = find.descendant(of: connector, matching: find.byKey(const ValueKey('pin:notes.move')));
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
