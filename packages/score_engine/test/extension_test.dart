import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

/// A host with no score: what an extension saves, prints and gets wrong.
class TestHost extends ExtensionHost {
  @override
  Object? data;
  @override
  int revision = 0;
  final saved = <String?>[], printed = <String>[], problems = <ExtensionProblem>[];

  @override
  void save(Object? json, {String? label}) {
    data = json;
    revision++;
    saved.add(label);
  }

  @override
  LoadedScore? get score => null;
  @override
  ScoreTimeline? get timeline => null;
  @override
  BeatGrid? get beats => BeatGrid([0, 4, 8, 12], meters: [Meter.quarters, Meter.quarters, Meter.quarters]);
  @override
  String get language => 'zh-Hans';
  @override
  void report(ExtensionProblem problem) => problems.add(problem);
  @override
  void print(String extension, String line) => printed.add(line);
}

ExtensionPackage package({Map<String, String>? sources, List<List<String>> wires = const []}) => ExtensionPackage(
      manifest: const {'format': ExtensionPackage.mimeType, 'id': 'com.example.notes', 'name': 'Notes', 'version': '1.2.0', 'api': 1, 'later': {'kept': true}},
      graph: ConnectorGraph.fromJson({
        'nodes': [
          {'id': 'project', 'type': 'project', 'at': [40, 40]},
          {'id': 'lane', 'type': 'lane', 'at': [40, 200.5], 'title': 'Notes', 'kind': 'markers'},
          {'id': 'hologram', 'type': 'from-the-future', 'at': [0, 0], 'depth': 3},
        ],
        'wires': [for (final w in wires) w],
        'files': {'main.lua': [400, 40]},
        'theme': 'kept too',
      }),
      sources: sources ?? const {'main.lua': 'function opened() end\n'},
      locales: const {
        'zh-Hans': {'{n} notes': '{n} 条笔记'},
      },
      assets: {'words.txt': Uint8List.fromList(utf8.encode('hello'))},
      readme: '# Notes\n',
    );

void main() {
  test('A .cpe is read as it was written, what this build doesn’t know kept', () {
    final p = package(wires: [
      ['project.opened', 'main.lua#opened'],
    ]);
    final bytes = p.write();
    expect(p.write(), bytes, reason: 'the same package, the same bytes');
    final back = ExtensionPackage.read(bytes);
    expect(back, p);
    expect((back.id, back.name, back.version, back.api), ('com.example.notes', 'Notes', '1.2.0', 1));
    expect(back.manifest['later'], {'kept': true});
    expect(back.graph.other, {'theme': 'kept too'});
    expect(back.graph.node('hologram')!.props, {'depth': 3});
    expect(back.graph.node('lane')!.y, 200.5);
    expect(back.graph.wire('project', 'opened')!.to, 'main.lua#opened');
    expect(back.sources.keys, ['main.lua']);
    expect(utf8.decode(back.assets['words.txt']!), 'hello');
    // A changed file is another package.
    expect(back.copyWith(sources: {'main.lua': 'function opened() return 1 end\n'}) == p, isFalse);
    expect(() => ExtensionPackage.read(Uint8List.fromList([1, 2, 3])), throwsFormatException);
    expect(() => ExtensionPackage.fromFiles({'extension.json': Uint8List.fromList(utf8.encode('{"id": "Bad Id"}'))}), throwsFormatException);
    expect(ExtensionPackage.isThirdPartyId('com.example.notes') && !ExtensionPackage.isThirdPartyId('captions'), isTrue);
    expect(ExtensionPackage.read(ExtensionPackage.blank(id: 'com.example.new', name: 'New').write()).sources['main.lua'], contains('function opened()'));
  });

  test('An extension runs: files with globals of their own, wires called, data saved, texts translated', () {
    final host = TestHost()..data = {'notes': [
      {'at': 4.0, 'text': 'Here'},
    ]};
    final runtime = ExtensionRuntime(
      package(sources: {
        'main.lua': '''
          local util = require("util")
          count = 0                       -- this file's own: util.lua has another
          function opened() count = count + 1 print("opened", util.count, curator.name, curator.api) end
          function items()
            local out = {}
            for i, note in ipairs(curator.data().notes) do out[i] = {at = note.at, label = note.text} end
            return out
          end
          function add(at)
            local data = curator.data()
            table.insert(data.notes, {at = at, text = curator.tr("{n} notes", {n = #data.notes + 1})})
            curator.save("Add Note")
          end
          function broken() local nothing = nil return nothing.field end
        ''',
        'util.lua': 'count = "util\'s"\nfunction place(q) return score.format(q, true) end\n',
      }, wires: [
        ['project.opened', 'main.lua#opened'],
        ['lane.items', 'main.lua#items'],
        ['lane.add', 'main.lua#add'],
        ['lane.open', 'main.lua#broken'],
      ]),
      host,
    );
    expect(runtime.problems, isEmpty);
    expect(host.problems, isEmpty);
    runtime.fire('project', 'opened');
    expect(host.printed, ['opened\tutil\'s\tNotes\t1']);
    expect(runtime.wired('lane', 'items') && !runtime.wired('lane', 'move') && !runtime.wired('nothing', 'here'), isTrue);

    runtime.fire('lane', 'add', args: [8.0]);
    expect(host.saved, ['Add Note']);
    expect(host.data, {'notes': [
      {'at': 4.0, 'text': 'Here'},
      {'at': 8.0, 'text': '2 条笔记'},
    ]});
    expect(jsonEncode(host.data), contains('"at":8.0'), reason: 'a place stays a fraction in the file');
    final items = runtime.ask('lane', 'items') as LuaTable;
    expect([for (final item in items.array) ((item as LuaTable)['at'], item['label'])], [(4.0, 'Here'), (8.0, '2 条笔记')]);

    // Undo puts other data under it: the next read is of that.
    host
      ..data = {'notes': <Object?>[]}
      ..revision += 1;
    expect((runtime.ask('lane', 'items') as LuaTable).length, 0);
    expect(runtime.lua.run('return require("util").place(4), curator.has("score.bars"), curator.has("socket:lane.items"), curator.has("score.telepathy")'), ['2', true, true, false]);

    // An error is reported with where it is, and the extension goes on.
    expect(runtime.fire('lane', 'open', args: [1]), isNull);
    expect((host.problems.single.file, host.problems.single.line, host.problems.single.where), ('main.lua', 14, 'lane.open'));
    expect(host.problems.single.message, "main.lua:14: attempt to index a nil value (local 'nothing')");
    // One that draws every frame says so once.
    host.problems.clear();
    runtime
      ..fire('lane', 'open', quiet: true)
      ..fire('lane', 'open', quiet: true);
    expect(host.problems, hasLength(1));
  });

  test('What is wrong with an extension’s files is listed, not thrown', () {
    final host = TestHost();
    final runtime = ExtensionRuntime(
      package(sources: {
        'main.lua': 'function opened( end',
        'other.lua': 'function there() end',
      }, wires: [
        ['project.opened', 'main.lua#opened'],
        ['project.changed', 'other.lua#missing'],
        ['lane.items', 'gone.lua#items'],
      ]),
      host,
    );
    expect([for (final p in runtime.problems) p.message], [
      "main.lua:1: <name> expected near 'end'",
      'The connector names gone.lua, which isn’t in the extension.',
      'other.lua has no function missing (wired to project.changed).',
    ]);
    expect(runtime.fire('project', 'opened'), isNull);
    expect([
      for (final f in Lua.functionsIn('local M = {}\nfunction M.draw(g, frame) end\nfunction opened() end\nM.items = function(...) end\nfunction M:method() end\nlocal function hidden() end\nreturn M'))
        '${f.name}(${f.parameters.join(', ')}) at ${f.line}',
    ], ['draw(g, frame) at 2', 'opened() at 3', 'items(...) at 4']);
  });

  test('What Curator adds to Lua: text as people write it, rounding, a snippet run, what a host lacks', () {
    final runtime = ExtensionRuntime(package(), TestHost());
    Object? value(String code) => runtime.run('return $code').firstOrNull;
    // Every kind of space, as Dart's \\s and trim() take them: a no-break space, an ideographic one.
    expect(value(r'text.squeeze("  A\u{A0}\u{3000} B\n\tC  ")'), 'A B C');
    expect(value(r'text.trim("\u{85} x \u{85}")'), 'x');
    expect(value('text.upper("où é")'), 'OÙ É');
    expect(value('#text.lines("a\\r\\nb\\nc")'), 3);
    expect([value('math.round(2.5)'), value('math.round(-2.5)'), value('math.round(0.49999999999999994)'), value('math.round(7)')], [3, -3, 0, 7]);
    // A place stays a fraction once it is one: saved as 4.0, not 4.
    expect(LuaJson.fromLua(runtime.run('return {4 + 0.0, 4}').first, where: 'data').toString(), '[4.0, 4]');
    // The list has `ui`, but this host gives none: an extension can ask before using it.
    expect([value('curator.has("ui.form")'), value('curator.has("text.squeeze")'), value('curator.has("socket:lane.items")'), value('curator.has("nothing.here")')],
        [false, true, true, false]);
    expect(() => runtime.run('error("no", 0)'), throwsA(isA<LuaError>().having((e) => e.message, 'message', 'no')));
  });

  test('Every socket and function of the API says what it is', () {
    for (final s in ExtensionApi.sockets) {
      expect(s.summary, isNotEmpty, reason: s.type);
      for (final p in s.ports) {
        expect(p.signature, startsWith('${p.name}('), reason: '${s.type}.${p.name}');
        expect(p.since, lessThanOrEqualTo(ExtensionApi.level));
      }
    }
    for (final l in ExtensionApi.libraries) {
      for (final f in l.functions) {
        expect(f.name, startsWith('${l.name}.'));
        expect(f.signature, startsWith(f.name), reason: f.name);
        expect(f.summary, isNotEmpty, reason: f.name);
      }
    }
    // What the runtime gives is what the list says, both ways.
    final runtime = ExtensionRuntime(package(), TestHost());
    for (final l in ExtensionApi.libraries) {
      final table = runtime.lua.globals[l.name];
      if (table is! LuaTable) continue; // the editor's own, not here
      for (final f in l.functions) {
        expect(table[f.name.substring(l.name.length + 1)], isA<LuaFunction>(), reason: '${f.name} is listed but missing');
      }
      if (l.addsTo) continue; // Lua's own library: only what Curator adds is listed
      for (final key in table.hashKeys) {
        if (table[key] is LuaFunction) expect(ExtensionApi.has('${l.name}.$key'), isTrue, reason: '${l.name}.$key is there but not listed');
      }
    }
  });
}
