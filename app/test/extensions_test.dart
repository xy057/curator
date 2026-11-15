// Extensions as packages in the app: one a project carries is saved with it, runs while its
// switch is on, keeps its data in the project's edits, and shows its lane. And plugins, the
// app's own for every project: what they add to the menus and the keys, what they change of
// the app's commands, what they are told, and Curator's own doing what they say.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:curated_score/app_menus.dart';

import 'package:curated_score/app_icons.dart';
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/extensions/extension.dart';
import 'package:curated_score/key_bindings.dart';
import 'package:curated_score/lua_language.dart';
import 'package:curated_score/plugins/plugin_docs.dart';
import 'package:curated_score/plugins/plugins.dart';
import 'package:curated_score/project_document.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:score_engine/score_engine.dart';

import 'demo_project.dart';

ExtensionPackage notes({int api = 1, String version = '1.0.0'}) => ExtensionPackage(
      manifest: {'format': ExtensionPackage.mimeType, 'id': 'com.example.notes', 'name': 'Notes', 'version': version, 'summary': 'Notes on the score.', 'api': api, 'data': {'version': 2}},
      graph: ConnectorGraph.fromJson({
        'nodes': [
          {'id': 'project', 'type': 'project', 'at': [40, 40]},
          {'id': 'notes', 'type': 'lane', 'at': [40, 200], 'title': 'Notes', 'order': 5},
          {'id': 'clear', 'type': 'command', 'at': [40, 400], 'title': 'Clear', 'icon': 'delete', 'lane': 'notes'},
        ],
        'wires': [
          ['project.load', 'main.lua#load'],
          ['notes.items', 'main.lua#items'],
          ['notes.add', 'main.lua#add'],
          ['notes.remove', 'main.lua#remove'],
          ['clear.run', 'main.lua#clear'],
          ['clear.enabled', 'main.lua#any'],
        ],
      }),
      sources: const {
        'main.lua': '''
local M = {}
local function notes()
  local data = curator.data()
  data.notes = data.notes or {}
  return data.notes
end
function M.load(data, version)
  -- Version 1 kept bare places.
  if version == 1 then
    for i, at in ipairs(data.notes or {}) do data.notes[i] = {at = at, text = "Note"} end
  end
  return data
end
function M.items()
  local items = {}
  for i, note in ipairs(notes()) do items[i] = {at = note.at, label = note.text} end
  return items
end
function M.add(at)
  table.insert(notes(), {at = at, text = "Note " .. #notes() + 1})
  table.sort(notes(), function(a, b) return a.at < b.at end)
  curator.save("Add Note")
end
function M.remove(index)
  table.remove(notes(), index)
  curator.save("Remove Note")
end
function M.clear()
  curator.data().notes = {}
  curator.save("Clear Notes")
end
function M.any() return #notes() > 0 end
return M
''',
      },
    );

/// The app's window as plugins act on it: what they showed, opened and did is kept.
class _Window implements PluginWindow {
  final messages = <String>[], opened = <String>[], did = <String>[];
  EditorController? editor;

  @override
  BuildContext? get dialogContext => null;
  @override
  EditorController? get controller => editor;
  @override
  PluginProject? get project => editor == null ? null : (name: 'Demo', path: '/demo.curator', edited: true);
  @override
  List<PluginProject> get projects => [?project];
  @override
  int? get showing => editor == null ? null : 0;
  @override
  void showTab(int? index) {}
  @override
  void open(String path) => opened.add(path);
  @override
  void message(String text) => messages.add(text);
  @override
  Map<String, VoidCallback?> get commands => {'save': () => did.add('save'), 'exportVideo': () => did.add('exportVideo'), 'open': null};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('extensions in a project: carried, run while on, data an edit, saved; Curator’s own as packages, one changed run and never saved; connector icons the app’s; plugins in the app: menus, keys, the app’s commands changed, events, Curator’s own', () async {
    // Every icon a connector may name is one of the app’s.
    {
      final names = AppIcon.values.asNameMap();
      expect([for (final icon in ExtensionApi.icons) if (!names.containsKey(icon)) icon], isEmpty);
    }

    // A project carries an extension: it runs while on, its data is an edit, both are saved.
    {
      final dir = Directory.systemTemp.createTempSync('extensions-test-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final settings = AppSettings.memory()..autosave = Duration.zero;
      final c = EditorController(vsync: const TestVSync());
      final doc = ProjectDocument(c, settings);
      addTearDown(() {
        doc.dispose();
        c.dispose();
      });
      await doc.importScore(demoScore.path);

      final package = notes();
      c.extensions.add(package);
      expect(Extensions.of(c).map((e) => e.id), contains('com.example.notes'));
      expect(c.extensions.running, isEmpty, reason: 'off until its switch is turned');
      c.setExtension('com.example.notes', true);
      final runtime = c.extensions.runtime('com.example.notes')!;
      expect(c.extensions.problems.value, isEmpty);
      expect(c.extensions.lanes.map((l) => l.node.id), ['notes']);
      final lane = runtime.graph.node('notes')!, clear = runtime.graph.node('clear')!;
      expect(c.extensions.commands(runtime, lane: 'notes').map((n) => n.id), ['clear']);
      expect(c.extensions.canRun(runtime, clear), isFalse);

      // The Draw tool adds; each is an Undo step, and the lane follows.
      runtime.fire('notes', 'add', args: [8.0]);
      runtime.fire('notes', 'add', args: [2.0]);
      expect(c.extensions.items(runtime, lane), [(at: 2.0, label: 'Note 2'), (at: 8.0, label: 'Note 1')]);
      expect(c.extensions.canRun(runtime, clear), isTrue);
      c.undo();
      expect(c.extensions.items(runtime, lane), [(at: 8.0, label: 'Note 1')]);
      c.redo();
      // Delete removes what is selected in its lane.
      c.extensions.select('com.example.notes', 'notes', 0);
      expect(c.commands.canDelete, isTrue);
      c.commands.delete();
      expect(c.extensions.items(runtime, lane), [(at: 8.0, label: 'Note 1')]);
      expect(c.extensions.hasSelection, isFalse);
      expect(c.extensions.data('com.example.notes'), {
        'notes': [
          {'at': 8.0, 'text': 'Note 1'},
        ],
      });

      // Saved with the project: the package as it is shared, its data, the data's version.
      final path = '${dir.path}/notes.ccs';
      await doc.save(path);
      final c2 = EditorController(vsync: const TestVSync());
      final doc2 = ProjectDocument(c2, settings);
      addTearDown(() {
        doc2.dispose();
        c2.dispose();
      });
      await doc2.open(path);
      expect(c2.extensions.carried.keys, ['com.example.notes']);
      expect(c2.extensions.carried.values.single.digest, package.digest);
      expect(c2.projectState.dataVersions['com.example.notes'], 2);
      expect(c2.extensionOn('com.example.notes'), isTrue);
      final again = c2.extensions.runtime('com.example.notes')!;
      expect(c2.extensions.items(again, again.graph.node('notes')!), [(at: 8.0, label: 'Note 1')]);
      expect(c2.extensions.problems.value, isEmpty);

      // Off: nothing of it runs, what it saved stays.
      c2.setExtension('com.example.notes', false);
      expect(c2.extensions.running, isEmpty);
      expect(c2.extensions.lanes, isEmpty);
      expect(c2.extensions.data('com.example.notes'), isNotNull);
      expect(c2.extensions.uses('com.example.notes'), isTrue);

      // One written for a later Curator says so, and doesn't run.
      c2.extensions.add(notes(api: ExtensionApi.level + 1, version: '2.0.0'));
      c2.setExtension('com.example.notes', true);
      expect(c2.extensions.running, isEmpty);
      expect(c2.extensions.problems.value.single.message, 'Notes needs a newer Curator.');

      // Taken out of the project: its switch does nothing; its data waits for it.
      c2.extensions.remove('com.example.notes');
      expect(Extensions.of(c2).map((e) => e.id), isNot(contains('com.example.notes')));
      expect(c2.extensions.data('com.example.notes'), isNotNull);
    }

    // One of Curator’s own, changed, runs in the project while it is open and is never saved.
    {
      final c = EditorController(vsync: const TestVSync());
      final doc = ProjectDocument(c, AppSettings.memory()..autosave = Duration.zero);
      addTearDown(() {
        doc.dispose();
        c.dispose();
      });
      await doc.importScore(demoScore.path);
      c.setExtension('chapters', true);
      final own = c.extensions.package('chapters')!;
      // Its lane renamed in the connector.
      final changed = own.copyWith(
          graph: own.graph.copyWith(nodes: [for (final n in own.graph.nodes) n.id == 'lane' ? n.copyWith(props: {...n.props, 'title': 'Sections'}) : n]));
      c.extensions.tryOut(changed);
      expect(c.extensions.tried('chapters'), isTrue);
      expect(c.extensions.runtime('chapters')!.package, changed, reason: 'running as changed');
      expect(c.extensions.lanes.single.node.props['title'], 'Sections');
      expect(c.projectState.packages, isEmpty, reason: 'not the project’s to keep');
      expect(Extensions.byId('chapters')!.label, 'Chapters', reason: 'Curator’s own is as it was');
      c.extensions.revert('chapters');
      expect((c.extensions.tried('chapters'), c.extensions.runtime('chapters')!.package), (false, own));
      // As it came is no change; a project closed forgets one.
      c.extensions.tryOut(own);
      expect(c.extensions.tried('chapters'), isFalse);
      c.extensions.tryOut(changed);
      await doc.importScore(demoScore.path);
      expect(c.extensions.tried('chapters'), isFalse);
    }

    // Curator’s own extensions are packages too, listed in their order.
    {
      expect(Extensions.all.map((e) => e.id), ['attachImage', 'captions', 'chapters', 'tonality']);
      final chapters = Extensions.byId('chapters')!;
      expect(chapters, isA<PackageExtension>());
      expect((chapters.label, chapters.summary, chapters.version), ('Chapters', 'Named places to jump to in a video or web page.', null));
      expect(() => EditorController(vsync: const TestVSync())..extensions.add(ExtensionPackage.blank(id: 'chapters', name: 'Mine')), throwsFormatException,
          reason: 'a one-word id is Curator’s');
    }

    // Plugins: what changes the app itself, kept by it for every project.
    {
      final settings = AppSettings.memory();
      final plugins = Plugins(settings), window = _Window();
      addTearDown(plugins.dispose);
      plugins
        ..attach(window)
        ..start();
      // The menus as the window builds them, and one of them (a menu inside one after a slash).
      AppMenus menus() => AppMenus(
            keys: plugins.keysOver(settings.keys),
            plugins: plugins,
            onOpen: () {},
            onImport: () {},
            onSave: window.commands['save'],
            onSaveAs: () {},
            onSettings: () {},
            onExportVideo: window.commands['exportVideo'],
            onExportWeb: () {},
            onFindPhrase: () {},
            onSelectAll: () {},
            child: const SizedBox(),
          );
      List<PlatformMenuItem> flat(List<PlatformMenuItem> items) => [for (final i in items) if (i is PlatformMenuItemGroup) ...flat(i.members) else i];
      List<PlatformMenuItem> menu(String path) {
        var items = flat(menus().menus);
        for (final name in path.split('/')) {
          items = flat(items.whereType<PlatformMenu>().firstWhere((m) => m.label == name).menus);
        }
        return items;
      }

      List<String> labels(String path) => [for (final i in menu(path)) i.label];
      PlatformMenuItem item(String path, String label) => menu(path).firstWhere((i) => i.label == label);

      // Curator's own, by name, each off until asked for: the menus are the app's.
      expect(plugins.packages.map((p) => p.id), ['appearanceMenu', 'reopenLast', 'saveBeforeExport', 'scoreFacts']);
      expect(plugins.packages.every((p) => plugins.isOwn(p.id) && !plugins.isOn(p.id) && checkPlugin(p).isEmpty), isTrue);
      expect(plugins.running, isEmpty);
      final file = labels('File'), view = labels('View');
      expect(file, containsAll(['Open…', 'Export Video…', 'Export to Web…']));

      // Score Facts: in View with its key and on the toolbar, grey until a score shows. What it
      // asks for that isn't there (a window for its dialog) is said, at the window's foot too.
      plugins.turn('scoreFacts', true);
      expect(labels('View'), [...view, 'Score Facts…']);
      expect(plugins.chords(settings.keys), {'scoreFacts': Plugins.chordOf(PluginKey.parse('cmd+shift+i')!)});
      expect(plugins.commandsWhere((c) => c.toolbar).single.command.icon, 'score');
      expect(item('View', 'Score Facts…').onSelected, isNull);
      final c = EditorController(vsync: const TestVSync());
      final doc = ProjectDocument(c, AppSettings.memory()..autosave = Duration.zero);
      addTearDown(() {
        doc.dispose();
        c.dispose();
      });
      await doc.importScore(demoScore.path);
      window.editor = c;
      item('View', 'Score Facts…').onSelected!();
      expect(window.messages.single, startsWith('Score Facts: '), reason: 'named by its plugin');
      expect(plugins.problemOf('scoreFacts')!.message, contains('ui.ask'), reason: 'the facts themselves were counted');
      plugins.turn('scoreFacts', false);
      expect(labels('View'), view);
      expect((plugins.problemOf('scoreFacts'), plugins.running.length), (null, 0));

      // Appearance Menu: a menu inside View, the theme in use ticked; choosing one sets it.
      plugins.turn('appearanceMenu', true);
      expect(labels('View').last, 'Appearance');
      expect(labels('View/Appearance'), ['Light', 'Dark', '✓ System']);
      item('View/Appearance', 'Dark').onSelected!();
      expect(settings.themeMode, ThemeMode.dark);
      expect(labels('View/Appearance'), ['Light', '✓ Dark', 'System']);
      plugins.turn('appearanceMenu', false);

      // Save Before Export: Export Video… saves first, from its menu or run by name; off, it
      // is the app's again.
      plugins.turn('saveBeforeExport', true);
      item('File', 'Export Video…').onSelected!();
      expect(window.did, ['save', 'exportVideo']);
      window.did.clear();
      expect((plugins.run('Export Video...'), plugins.run('open'), plugins.run('nothing')), (true, false, null));
      expect(window.did, ['save', 'exportVideo']);
      plugins.turn('saveBeforeExport', false);
      window.did.clear();
      item('File', 'Export Video…').onSelected!();
      expect(window.did, ['exportVideo']);

      // Reopen Last Project: told that the app started, it opens the latest file while nothing
      // is open; turned on later it is told nothing.
      settings.addRecent('/last.curator');
      plugins.turn('reopenLast', true);
      expect(window.opened, isEmpty);
      final starting = Plugins(settings), home = _Window();
      addTearDown(starting.dispose);
      starting
        ..attach(home)
        ..start();
      expect(home.opened, ['/last.curator']);
      plugins.turn('reopenLast', false);

      // One the user added: the guide's whole plugin, as the guide has it. Off until its switch
      // is turned; then its command, what it listens to, and what it keeps (the app's, by its id).
      final guide = File('assets/help/plugins.md').readAsStringSync(), whole = guide.substring(guide.indexOf('## A whole plugin'));
      final greeting = PluginPackage(
        manifest: jsonDecode(RegExp(r'```json\n([\s\S]*?)```').firstMatch(whole)![1]!) as Map<String, Object?>,
        sources: {'main.lua': RegExp(r'```lua\n([\s\S]*?)```').firstMatch(whole)![1]!},
      );
      final id = greeting.id;
      expect((id, checkPlugin(greeting).length), ('com.example.greeting', 0));
      plugins.add(greeting);
      expect((plugins.isOn(id), plugins.runtime(id), plugins.isOwn(id)), (false, null, false));
      plugins.turn(id, true);
      expect(plugins.problems.value, isEmpty);
      expect(labels('Help').last, 'Greet');
      expect(plugins.run('Greet'), isTrue);
      expect(window.messages.last, 'Hello');
      plugins.emit('project.opened', [Plugins.projectTable(window.project)]);
      expect(window.messages.last, 'Hello, Demo');
      expect(plugins.hasSettings(id), isTrue);
      plugins.runtime(id)!.run('curator.save_settings({greeting = "Hi"})');
      expect(settings.pluginSettings(id), {'greeting': 'Hi'});
      plugins.perform(plugins.entry('greet')!);
      expect(window.messages.last, 'Hi');
      // A file of it is what it is: added to a folder, it is kept there, and gone when removed.
      final folder = Directory.systemTemp.createTempSync('plugins');
      addTearDown(() => folder.deleteSync(recursive: true));
      final kept = Plugins(AppSettings.memory(), folder: folder);
      addTearDown(kept.dispose);
      kept.add(greeting);
      final cgp = File('${folder.path}/$id.cgp');
      expect(PluginPackage.read(cgp.readAsBytesSync()), greeting);
      kept.remove(id);
      expect((cgp.existsSync(), kept.package(id)), (false, null));
      expect(() => kept.add(PluginPackage.blank(id: 'scoreFacts', name: 'Mine')), throwsFormatException, reason: 'a one-word id is Curator’s');

      // One changing the app's own: a command hidden, one renamed, one given another key, and
      // its own placed beside one of the app's, keyed, and offered on Home and over the score.
      final tweaks = PluginPackage.blank(id: 'com.example.tweaks', name: 'Tweaks').copyWith(sources: {
        'main.lua': '''
app.hide("exportWeb")
app.rename("importScore", "Import a Score…")
app.rebind("findPhrase", "cmd+shift+f")
app.command{ title = "Mark", menu = "Edit", after = "selectAll", key = "m", run = function() ui.message("marked") end }
app.command{ title = "Taken", key = "cmd+o", run = function() end }
app.command{ title = "Here", preview = true, home = true, run = function(at) ui.message(string.format("at %d", at)) end }
''',
      });
      plugins.add(tweaks);
      plugins.turn(tweaks.id, true);
      expect(labels('File'), [for (final label in file) if (label != 'Export to Web…') label == 'Import…' ? 'Import a Score…' : label]);
      final shifted = Plugins.chordOf(PluginKey.parse('cmd+shift+f')!);
      expect(plugins.keysOver(settings.keys)[KeyCommand.findPhrase], shifted);
      final edit = labels('Edit');
      expect(edit.indexOf('Mark'), edit.indexOf('Select All') + 1);
      // A key the app's own command has stays the app's, and the plugin is told.
      expect(plugins.chords(plugins.keysOver(settings.keys)).keys, ['greet', 'mark']);
      expect(plugins.problems.value.where((p) => p.warning && p.extension == tweaks.id).single.message, contains('Open…'));
      expect(plugins.commandsWhere((c) => c.preview).single.command.title, 'Here');
      plugins.actionOf(plugins.commandsWhere((c) => c.home).single, [12.0])!();
      expect(window.messages.last, 'at 12');
      // The key the user chose in Settings ▸ Shortcuts wins.
      final chosen = Plugins.chordOf(PluginKey.parse('cmd+alt+f')!);
      settings.keys = settings.keys.withKey(KeyCommand.findPhrase, chosen);
      expect(plugins.keysOver(settings.keys)[KeyCommand.findPhrase], chosen);
      settings.keys = KeyMap.standard;
      // Off, everything is as it was; removed, it is gone.
      plugins.turn(tweaks.id, false);
      expect(labels('File'), file);
      expect(plugins.keysOver(settings.keys), settings.keys);
      plugins.remove(tweaks.id);
      expect((plugins.package(tweaks.id), plugins.isOn(tweaks.id)), (null, false));

      // What is offered as a plugin's Lua is typed is the plugin API's; the docs handed to a
      // person or a model carry the guide, the API and Curator's own as examples.
      final offered = LuaPrompts(() => '', libraries: PluginApi.libraries).promptsFor('app.comm')!;
      expect(offered.prompts.map((p) => p.word), ['command', 'commands']);
      expect(LuaPrompts(() => '').promptsFor('app.comm'), isNull, reason: 'not an extension’s');
      final pack = ZipDecoder().decodeBytes(pluginDocsPack(guide, examples: plugins.packages.where((p) => plugins.isOwn(p.id)).toList()));
      expect([for (final f in pack.files) f.name],
          containsAll(['curator-plugin-docs/README.md', 'curator-plugin-docs/plugin-api.md', 'curator-plugin-docs/api.json', 'curator-plugin-docs/examples/scoreFacts/src/main.lua']));
    }
  });
}
