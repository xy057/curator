// Extensions as packages in the app: one a project carries is saved with it, runs while its
// switch is on, keeps its data in the project's edits, and shows its lane.
import 'dart:io';

import 'package:curated_score/app_icons.dart';
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/extensions/extension.dart';
import 'package:curated_score/project_document.dart';
import 'package:flutter_test/flutter_test.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every icon a connector may name is one of the app’s', () {
    final names = AppIcon.values.asNameMap();
    expect([for (final icon in ExtensionApi.icons) if (!names.containsKey(icon)) icon], isEmpty);
  });

  test('a project carries an extension: it runs while on, its data is an edit, both are saved', () async {
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
  });

  test('Curator’s own extensions are packages too, listed with those written in the app', () {
    expect(Extensions.all.map((e) => e.id), ['attachImage', 'captions', 'chapters', 'tonality']);
    final chapters = Extensions.byId('chapters')!;
    expect(chapters, isA<PackageExtension>());
    expect((chapters.label, chapters.summary, chapters.version), ('Chapters', 'Named places to jump to in a video or web page.', null));
    expect(() => EditorController(vsync: const TestVSync())..extensions.add(ExtensionPackage.blank(id: 'chapters', name: 'Mine')), throwsFormatException,
        reason: 'a one-word id is Curator’s');
  });
}
