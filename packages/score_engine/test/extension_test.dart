import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

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
  String language = 'zh-Hans';
  @override
  void report(ExtensionProblem problem) => problems.add(problem);
  @override
  void print(String extension, String line) => printed.add(line);
}

/// A host with no window: what a plugin prints and gets wrong, and how often it changed
/// what it adds.
class PluginTestHost extends PluginHost {
  final printed = <String>[], problems = <ScriptProblem>[];
  int changes = 0;

  @override
  LoadedScore? get score => null;
  @override
  ScoreTimeline? get timeline => null;
  @override
  BeatGrid? get beats => null;
  @override
  String language = 'zh-Hans';
  @override
  void report(ScriptProblem problem) => problems.add(problem);
  @override
  void print(String extension, String line) => printed.add(line);
  @override
  void changed() => changes++;
}

PluginPackage plugin({String? main}) => PluginPackage(
      manifest: const {'format': PluginPackage.mimeType, 'id': 'com.example.hello', 'name': 'Hello', 'version': '2.0.0', 'api': 1, 'later': 'kept'},
      sources: {
        'main.lua': main ??
            '''
          local words = require("util.words")
          print("started", curator.name, curator.api, curator.language)
          app.command{
            title = "Count Bars…", menu = "View", after = "Find Phrase...", key = "cmd+shift+b", toolbar = true, icon = "music",
            enabled = function() return score.open() end,
            run = function() print(#score.bars()) end,
          }
          app.command{
            id = "greet", title = "Greet", menu = "Tools/People",
            checked = function() return true end,
            run = function(who) print(words.hello, who) end,
          }
          app.hide("exportWeb")
          app.rename("Export Video...", "Make a Movie…")
          app.rebind("save", "cmd+alt+s")
          app.rebind("Warp", nil)
          app.wrap("close", function(original) original() end)
          app.on("project.opened", function() error("first listener") end)
          local off = app.on("project.opened", function(project) print("opened", project.name) end)
          function stop() off() end
        ''',
        'util/words.lua': 'return {hello = "hello"}\n',
      },
      locales: const {
        'zh-Hans': {'Count Bars…': '数小节…'},
      },
      readme: '# Hello\n',
    );

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
        'zh-Hans': {'{n} notes': '{n} 条笔记', 'Key': '键', 'music|Key': '调'},
      },
      assets: {'words.txt': Uint8List.fromList(utf8.encode('hello'))},
      readme: '# Notes\n',
    );

void main() {
  test('extensions and plugins: a .cpe read as written, one run with its wires, what is wrong with one listed and found, what Lua adds and gives, the API described; a .cgp read as written, a plugin’s commands, changes and events', () {
    // A .cpe is read as it was written, what this build doesn’t know kept.
    {
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
    }

    // An extension runs: files with globals of their own, wires called, data saved, texts translated.
    {
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
    }

    // What is wrong with an extension’s files is listed, not thrown.
    {
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
    }

    // What Curator adds to Lua: text as people write it, rounding, a snippet run, what a host lacks.
    {
      final host = TestHost();
      final runtime = ExtensionRuntime(package(), host);
      Object? value(String code) => runtime.run('return $code').firstOrNull;
      // Every kind of space, as Dart's \\s and trim() take them: a no-break space, an ideographic one.
      expect(value(r'text.squeeze("  A\u{A0}\u{3000} B\n\tC  ")'), 'A B C');
      expect(value(r'text.trim("\u{85} x \u{85}")'), 'x');
      expect(value('text.upper("où é")'), 'OÙ É');
      expect(value('#text.lines("a\\r\\nb\\nc")'), 3);
      expect([value('math.round(2.5)'), value('math.round(-2.5)'), value('math.round(0.49999999999999994)'), value('math.round(7)')], [3, -3, 0, 7]);
      // A place stays a fraction once it is one: saved as 4.0, not 4.
      expect(LuaJson.fromLua(runtime.run('return {4 + 0.0, 4}').first, where: 'data').toString(), '[4.0, 4]');
      // A table held twice by each of many in turn is refused before it is written out 2^n times.
      expect(() => LuaJson.fromLua(runtime.run('local t = {1} for i = 1, 40 do t = {a = t, b = t} end return t').first), throwsA(isA<LuaError>().having((e) => e.message, 'message', contains('too much to save'))));
      // The list has `ui`, but this host gives none: an extension can ask before using it.
      expect([value('curator.has("ui.form")'), value('curator.has("text.squeeze")'), value('curator.has("socket:lane.items")'), value('curator.has("nothing.here")')],
          [false, true, true, false]);
      expect(() => runtime.run('error("no", 0)'), throwsA(isA<LuaError>().having((e) => e.message, 'message', 'no')));
      // As Dart clamps: a zero below zero is zero, what isn't a number is the highest.
      expect([value('math.clamp(5, 0, 3)'), value('math.clamp(-1, 0.5, 3)'), value('math.clamp(2, 0, 3)'), value('math.clamp(0/0, 0, 3)'), value('1 / math.clamp(-0.0, 0.0, 1.0)')],
          [3, 0.5, 2, 3, double.infinity]);
      expect(() => runtime.run('return math.clamp(1, 3, 0)'), throwsA(isA<LuaError>()));
      // What Curator's own functions give is paid for in steps as what Lua's give is: a text
      // made of a long one a thousand times isn't kept a thousand times.
      expect(() => runtime.lua.run('kept = {}\nlocal s = ("x"):rep(64000)\nwhile true do kept[#kept + 1] = text.upper(s) end', steps: 4000), throwsA(isA<LuaLimit>()));
      expect(runtime.lua.run('return #kept').single, lessThan(5));
      // A text that means two things, by its context; without one for it, as tr gives it.
      expect([value('curator.tr("Key")'), value('curator.tr_in("music", "Key")'), value('curator.tr_in("door", "Key")'), value('curator.tr_in("music", "{n} notes", {n = 2})')],
          ['键', '调', '键', '2 条笔记']);
      // The language is the interface's as it is now: changed while the extension runs, it is
      // the new one, as what curator.tr gives is.
      expect(value('curator.language'), 'zh-Hans');
      host.language = 'ja';
      expect([value('curator.language'), value('curator.tr("Key")')], ['ja', 'Key']);
      host.language = 'zh-Hans';
    }

    // What Lua gives the app: a colour, the music of a score.
    {
      final lua = Lua();
      Object? value(String code) => lua.call(lua.load('return $code', chunk: 'test'), const [], 100000).firstOrNull;
      expect(luaColor('#3366cc'), const ui.Color(0xFF3366CC));
      expect(luaColor('#3366cc80'), const ui.Color(0x803366CC));
      expect(luaColor(value('{r = 1, g = 0.5, b = 0}')), const ui.Color.from(alpha: 1, red: 1, green: 0.5, blue: 0));
      expect(luaColor(value('{0.25, 2, -1, 0.5}')), const ui.Color.from(alpha: 0.5, red: 0.25, green: 1, blue: 0));
      expect([luaColor('blue'), luaColor('#12'), luaColor(value('{r = 1}')), luaColor(null), luaColor(7)], everyElement(isNull));

      const xml = '<score-partwise><part id="P1"><measure><attributes><divisions>1</divisions><key><fifths>-1</fifths><mode>minor</mode></key></attributes>'
          '<note><pitch><step>D</step><octave>4</octave></pitch><duration>2</duration></note>'
          '<note><chord/><pitch><step>F</step><octave>4</octave></pitch><duration>2</duration></note></measure>'
          '<measure><attributes><key><fifths>2</fifths></key></attributes><note><pitch><step>D</step><octave>4</octave></pitch><duration>4</duration><tie type="stop"/></note></measure></part></score-partwise>';
      final music = scoreMusicTable(readScoreMusic(xml, [0, 2, 6]));
      expect(LuaJson.fromLua(music).toString(),
          '{notes: [{from: 0.0, to: 2.0, pitch: 62, tied: false, chord: false, part: P1, staff: 1, voice: 1}, {from: 0.0, to: 2.0, pitch: 65, tied: false, chord: true, part: P1, staff: 1, voice: 1}, '
          '{from: 2.0, to: 6.0, pitch: 62, tied: true, chord: false, part: P1, staff: 1, voice: 1}], keys: [{bar: 1, fifths: -1, minor: true}, {bar: 2, fifths: 2}], bars: [0.0, 2.0, 6.0]}');
    }

    // What is wrong with an extension as written is found without running it.
    {
      String said(ExtensionPackage p) => [for (final x in checkExtension(p)) '${x.warning ? 'warning' : 'error'} ${x.file}${x.line == null ? '' : ':${x.line}'} ${x.message}'].join('\n');
      // As it should be: only the node of a later Curator's is said, as a warning.
      final fine = said(package(wires: [
        ['project.opened', 'main.lua#opened'],
      ]));
      expect(fine, 'warning connect.json This Curator has no “from-the-future” socket (hologram).');

      final broken = said(package(sources: {
        'main.lua': 'local M = {}\nfunction M.items() return {} end\nM.made = function() end\nreturn M\n',
        'bad.lua': 'local x = 1\nlocal y = = 2\n',
      }, wires: [
        ['lane.items', 'main.lua#items'],
        ['lane.add', 'main.lua#made'],
        ['lane.open', 'main.lua#nowhere'],
        ['lane.fly', 'main.lua#items'],
        ['ghost.run', 'main.lua#items'],
        ['project.opened', 'gone.lua#opened'],
        ['project.changed', 'bad.lua#changed'],
      ]));
      expect(broken, contains('error bad.lua:2 '));
      expect(broken, contains('error main.lua main.lua has no function nowhere (wired to lane.open).'));
      expect(broken, isNot(contains('function made')), reason: 'a function made another way is in the file');
      expect(broken, contains('warning connect.json A “lane” socket has no port fly here (lane.fly).'));
      expect(broken, contains('error connect.json ghost.run is wired, but there is no node ghost.'));
      expect(broken, contains('error connect.json project.opened is wired to gone.lua, which isn’t in the extension.'));
      expect(broken, isNot(contains('changed')), reason: 'a file that doesn’t read says so once');

      // A second project socket, and a later API level.
      final p = package();
      final twice = ExtensionPackage(
        manifest: {...p.manifest, 'api': ExtensionApi.level + 1},
        graph: ConnectorGraph.fromJson({
          'nodes': [
            {'id': 'project', 'type': 'project', 'at': [0, 0]},
            {'id': 'again', 'type': 'project', 'at': [0, 0]},
          ],
          'wires': const [],
        }),
        sources: p.sources,
      );
      expect(said(twice), 'warning extension.json It needs API level ${ExtensionApi.level + 1}; this Curator has ${ExtensionApi.level}.\n'
          'error connect.json An extension has one “project” socket (again is a second).');
    }

    // Every socket and function of the API says what it is.
    {
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
          if (f.editor) continue; // the editor's own, not here
          expect(table[f.name.substring(l.name.length + 1)], isA<LuaFunction>(), reason: '${f.name} is listed but missing');
        }
        if (l.addsTo) continue; // Lua's own library: only what Curator adds is listed
        for (final key in table.hashKeys) {
          if (table[key] is LuaFunction) expect(ExtensionApi.has('${l.name}.$key'), isTrue, reason: '${l.name}.$key is there but not listed');
        }
      }
    }

    // A .cgp is read as it was written; what is wrong with one is said without running it.
    {
      final p = plugin();
      final back = PluginPackage.read(p.write());
      expect(back, p);
      expect(p.write(), back.write(), reason: 'the same package, the same bytes');
      expect((back.id, back.name, back.version, back.api), ('com.example.hello', 'Hello', '2.0.0', 1));
      expect(back.manifest['later'], 'kept');
      expect(back.sources.keys, unorderedEquals(['main.lua', 'util/words.lua']));
      expect(back.copyWith(sources: {'main.lua': '-- other'}) == p, isFalse);
      expect(() => PluginPackage.read(Uint8List.fromList([1, 2, 3])), throwsFormatException);
      expect(() => PluginPackage.read(package().write()), throwsFormatException, reason: 'an extension is no plugin');
      expect(() => ExtensionPackage.read(p.write()), throwsFormatException, reason: 'nor a plugin an extension');
      expect(() => PluginPackage.fromFiles({'plugin.json': Uint8List.fromList(utf8.encode('{"id": "Bad Id"}'))}), throwsFormatException);
      expect(checkPlugin(p), isEmpty);
      expect(checkPlugin(PluginPackage.read(PluginPackage.blank(id: 'user.new', name: 'New').write())), isEmpty);
      final wrong = checkPlugin(p.copyWith(manifest: {...p.manifest, 'api': 9}, sources: {'other.lua': 'local x =\n= 2'}));
      expect([for (final w in wrong) (w.file, w.line, w.warning)], [('plugin.json', null, true), ('plugin.json', null, false), ('other.lua', 2, false)]);
    }

    // A key as a plugin writes one.
    {
      expect(PluginKey.parse('cmd+shift+K'), const PluginKey('k', command: true, shift: true));
      expect(PluginKey.parse(' Option + Return ').toString(), 'alt+enter');
      expect(PluginKey.parse('ctrl+,').toString(), 'ctrl+,');
      expect(PluginKey.parse('f5').toString(), 'f5');
      expect([for (final bad in ['', 'cmd+', 'cmd+cmd+k', 'hyper+k', 'cmd+kk', '+']) PluginKey.parse(bad)], everyElement(isNull));
    }

    // A plugin runs: main.lua once, its commands added, the app’s own changed, events heard.
    {
      final host = PluginTestHost();
      final runtime = PluginRuntime(plugin(), host);
      expect(runtime.problems, isEmpty);
      expect(host.problems, isEmpty);
      expect(host.printed, ['started\tHello\t1\tzh-Hans']);
      expect([for (final c in runtime.commands) (c.id, c.title, c.menu.join('/'), c.key?.toString(), c.toolbar, c.before, c.after)], [
        ('count-bars', 'Count Bars…', 'View', 'cmd+shift+b', true, null, 'findPhrase'),
        ('greet', 'Greet', 'Tools/People', null, false, null, null),
      ]);
      final count = runtime.command('Count Bars...')!, greet = runtime.command('greet')!;
      expect(runtime.translate(count.title), '数小节…');
      expect(runtime.canRun(count), isFalse, reason: 'no score is open');
      expect(runtime.canRun(greet) && runtime.isChecked(greet), isTrue);
      expect(runtime.perform(greet, ['you']), isTrue);
      expect(host.printed.last, 'hello\tyou');
      // The app’s own commands, changed: by id or by title, three dots for an ellipsis.
      expect(runtime.hidden, {'exportWeb'});
      expect(runtime.titles, {'exportVideo': 'Make a Movie…'});
      expect(runtime.keys, {'save': const PluginKey('s', command: true, alt: true), 'warp': null});
      expect(runtime.wraps.keys, ['close']);
      final changes = host.changes;
      expect(changes, greaterThan(0));
      // Events: heard until off() is called; one listener failing leaves the next told.
      expect(runtime.listens('project.opened') && !runtime.listens('project.saved'), isTrue);
      runtime.emit('project.opened', [LuaTable.map({'name': 'Demo'})]);
      expect(host.printed.last, 'opened\tDemo');
      expect(host.problems.single.message, contains('first listener'));
      expect(host.problems.single.where, 'project.opened');
      host.problems.clear();
      runtime.run('require("main").stop()'); // a file’s globals are its own
      expect(runtime.listens('project.opened'), isTrue, reason: 'the failing one still listens');
      runtime.emit('project.opened', [LuaTable.map({'name': 'Again'})]);
      expect(host.printed.last, 'opened\tDemo');
      // A command added again by its id replaces it; one removed is gone.
      runtime.run('app.command{id = "greet", title = "Greet Again", run = function() end} app.remove("count-bars")');
      expect([for (final c in runtime.commands) (c.id, c.title)], [('greet', 'Greet Again')]);
      expect(host.changes, greaterThan(changes));
      // app.refresh says so too: what its commands hang on changed where the app can't know.
      final before = host.changes;
      runtime.run('app.refresh()');
      expect(host.changes, before + 1);
      runtime.run('app.show("exportWeb") app.rename("Export Video...", nil) app.wrap("close", nil)');
      expect(runtime.hidden.isEmpty && runtime.titles.isEmpty && runtime.wraps.isEmpty, isTrue);
      // What a plugin gets wrong says so, where it is written.
      for (final (code, message) in [
        ('app.command{run = function() end}', 'needs a title'),
        ('app.command{title = "X"}', 'needs run'),
        ('app.command{title = "Save", id = "save", run = function() end}', 'of the app’s own'),
        ('app.command{title = "X", key = "cmd+nothing", run = function() end}', 'is not a key'),
        ('app.command{title = "X", icon = "unicorn", run = function() end}', "no icon 'unicorn'"),
        ('app.hide("no such thing")', "no command 'no such thing'"),
        ('app.rebind("undo", "cmd+u")', 'keeps its key'),
        ('app.wrap("greet", function() end)', 'only the app’s own'),
        ('app.on("project.exploded", function() end)', "no event 'project.exploded'"),
        ('curator.data()', 'attempt to call a nil value'),
      ]) {
        expect(() => runtime.run(code), throwsA(isA<LuaError>().having((e) => e.message, 'message', contains(message))), reason: code);
      }
      expect(runtime.run('return curator.has("app.command"), curator.has("event:project.saved"), curator.has("command:Export Video..."), curator.has("setting:theme"), curator.has("curator.data"), curator.has("ui.form")'),
          [true, true, true, true, false, false], reason: 'ui is the app’s to give: this host has none');
      // A plugin whose main.lua fails says so and adds nothing more; one without it says that.
      final broken = PluginTestHost();
      expect(PluginRuntime(plugin(main: 'app.command{title = "Kept", run = function() end}\nerror("stop here")'), broken).commands.single.title, 'Kept');
      expect((broken.problems.single.file, broken.problems.single.line, broken.problems.single.message), ('main.lua', 2, 'main.lua:2: stop here'));
      expect(PluginRuntime(plugin().copyWith(sources: const {'other.lua': ''}), PluginTestHost()).problems.single.message, contains('no src/main.lua'));
    }

    // The plugin API as it is described: every entry said, what the runtime gives listed.
    {
      expect({for (final c in PluginApi.commands) c.id}, hasLength(PluginApi.commands.length));
      expect(PluginApi.command('Export Video...')!.id, 'exportVideo');
      for (final l in PluginApi.libraries) {
        expect(l.summary, isNotEmpty, reason: l.name);
        for (final f in l.functions) {
          expect(f.name, startsWith('${l.name}.'));
          expect(f.signature, startsWith(f.name), reason: f.name);
          expect(f.summary, isNotEmpty, reason: f.name);
          expect(f.since, lessThanOrEqualTo(PluginApi.level));
        }
      }
      final runtime = PluginRuntime(plugin(), PluginTestHost());
      for (final name in ['curator', 'score', 'text']) {
        final table = runtime.lua.globals[name] as LuaTable, l = PluginApi.libraries.firstWhere((l) => l.name == name);
        for (final f in l.functions) {
          expect(table[f.name.substring(name.length + 1)], isA<LuaFunction>(), reason: '${f.name} is listed but missing');
        }
        for (final key in table.hashKeys) {
          if (table[key] is LuaFunction) expect(PluginApi.has('$name.$key'), isTrue, reason: '$name.$key is there but not listed');
        }
      }
      // The engine gives the part of `app` that keeps what a plugin adds; the app the rest.
      final app = runtime.lua.globals['app'] as LuaTable;
      for (final key in app.hashKeys) {
        expect(PluginApi.has('app.$key'), isTrue, reason: 'app.$key is there but not listed');
      }
      final docs = PluginApi.docs('# Writing a plugin\n');
      expect(docs, allOf(contains('`app.command(spec) → id`'), contains('`"project.opened"`'), contains('`exportVideo`: Export Video…'), contains('`score.bars() → list`')));
      expect(docs, isNot(contains('score.music')), reason: 'the editor’s own');
      expect((PluginApi.toJson()['commands'] as List).length, PluginApi.commands.length);
    }
  });
}
