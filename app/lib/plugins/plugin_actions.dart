import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'package:score_engine/score_engine.dart';

import '../app_colors.dart';
import '../app_icons.dart';
import '../dialog_kit.dart';
import '../edit_dialogs.dart' show saveFileAs;
import '../error_text.dart';
import '../menu_kit.dart';
import '../ui_kit.dart';
import '../l10n/l10n.dart';
import 'plugin_editor.dart';
import 'plugins.dart';

/// What Settings ▸ Plugins does with a plugin: make a new one, add one from a file, edit it
/// (the plugin editor), save it as a file, take it out of the app, and copy one of Curator's
/// own to change.
abstract final class PluginActions {
  static const _types = XTypeGroup(label: 'Curator Plugin', extensions: [PluginPackage.fileExtension]);

  /// Keeps [package] in the app, saying so when its file can't be written; whether it was.
  static Future<bool> _keep(BuildContext context, Plugins plugins, PluginPackage package, {String title = 'Couldn’t Save the Plugin'}) async {
    try {
      plugins.add(package);
      return true;
    } on FormatException catch (e) {
      if (context.mounted) await showNotice(context, title.tr, describeError(e));
    } on FileSystemException catch (e) {
      if (context.mounted) await showNotice(context, title.tr, describeError(e));
    }
    return false;
  }

  /// Asks for a new plugin's name, adds it to the app, on, and opens it in the editor.
  static Future<void> create(BuildContext context, Plugins plugins) async {
    final name = TextEditingController();
    final chosen = await showAppDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          final text = name.text.trim();
          void add() {
            if (text.isNotEmpty) Navigator.pop(context, text);
          }

          return AppDialog(
            title: Text('New Plugin'.tr),
            content: SizedBox(
              width: dialogWidth(context, 360),
              child: AppTextField(controller: name, label: 'Name', autofocus: true, maxLength: 60, onChanged: (_) => setState(() {}), onSubmitted: (_) => add()),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel'.tr)),
              FilledButton(onPressed: text.isEmpty ? null : add, child: Text('Create'.tr)),
            ],
          );
        },
      ),
    ).whenComplete(name.dispose);
    if (chosen == null || !context.mounted) return;
    final package = PluginPackage.blank(id: plugins.idFor(chosen), name: chosen);
    if (!await _keep(context, plugins, package) || !context.mounted) return;
    plugins.turn(package.id, true);
    await edit(context, plugins, package);
  }

  /// Adds the plugin in the .cgp file at [path] (in place of the one the app has with its id),
  /// off until its switch is turned: it is someone else's code. Whether it was added.
  static Future<bool> addFile(BuildContext context, Plugins plugins, String path) async {
    try {
      final package = PluginPackage.read(await File(path).readAsBytes());
      if (!context.mounted) return false;
      // One of Curator's own comes with the app: a file can't stand in for it.
      if (!PluginPackage.isThirdPartyId(package.id)) throw const WordsFormatException(Words('The plugin has no id Curator can use.'));
      return await _keep(context, plugins, package, title: 'Couldn’t Add the Plugin');
    } on FormatException catch (e) {
      if (context.mounted) await showNotice(context, 'Couldn’t Add the Plugin'.tr, describeError(e));
    } on FileSystemException catch (e) {
      if (context.mounted) await showNotice(context, 'Couldn’t Add the Plugin'.tr, describeError(e));
    }
    return false;
  }

  /// Adds a plugin from a .cgp file the user chooses.
  static Future<void> addFromFile(BuildContext context, Plugins plugins) async {
    final file = await openFile(acceptedTypeGroups: const [_types]);
    if (file == null || !context.mounted) return;
    await addFile(context, plugins, file.path);
  }

  /// Opens [package] in the plugin editor. One the user added is edited there: Run keeps it as
  /// it stands and starts it again (turning it on), Done keeps it, and Cancel puts back the one
  /// there was, run since or not. One of Curator's own is
  /// read there; Duplicate makes a copy to change.
  static Future<void> edit(BuildContext context, Plugins plugins, PluginPackage package) async {
    final own = plugins.isOwn(package.id);
    package = plugins.package(package.id) ?? package;
    final on = plugins.isOn(package.id);
    final edited = await showPluginEditor(
      context,
      package,
      readOnly: own,
      onRun: own
          ? null
          : (p) async {
              plugins.clearProblems(p.id);
              // As it stands: kept (which starts it again when it changed), on, and started
              // again when it is what was kept already.
              final same = plugins.package(p.id) == p;
              if (!same && !await _keep(context, plugins, p)) return;
              if (!plugins.isOn(p.id)) {
                plugins.turn(p.id, true);
              } else if (same) {
                plugins.restart(p.id);
              }
            },
      problems: plugins.problems,
      log: plugins.log,
    );
    if (!context.mounted) return;
    if (edited != null) {
      await _keep(context, plugins, edited);
    } else if (!own && plugins.package(package.id) != package) {
      // Left without keeping it, after Run kept another: the one there was is back, on or off
      // as it was.
      await _keep(context, plugins, package);
      if (plugins.isOn(package.id) != on) plugins.turn(package.id, on);
    }
  }

  /// Saves [package] as a .cgp file where the user says.
  static Future<void> export(BuildContext context, PluginPackage package) async {
    await saveFileAs(context,
        types: const [_types],
        suggestedName: '${package.name}.${PluginPackage.fileExtension}',
        extension: PluginPackage.fileExtension,
        failTitle: 'Couldn’t Save the Plugin'.tr,
        write: (file) => file.writeAsBytes(package.write()));
  }

  /// A copy of [package] the user can change, named "… Copy", with an id of its own (and so a
  /// switch and settings of its own).
  static PluginPackage copyOf(PluginPackage package, Plugins plugins, {bool own = false}) {
    final name = '{name} Copy'.fill({'name': own ? package.name.tr : package.name});
    return package.copyWith(manifest: {...package.manifest, 'id': plugins.idFor(package.name), 'name': name, 'version': '1.0.0'});
  }

  static Future<void> duplicate(BuildContext context, Plugins plugins, PluginPackage package) async {
    final copy = copyOf(package, plugins, own: plugins.isOwn(package.id));
    if (await _keep(context, plugins, copy) && context.mounted) await edit(context, plugins, copy);
  }

  /// Takes [package] out of the app, once the user says so: its file goes with it.
  static Future<void> remove(BuildContext context, Plugins plugins, PluginPackage package) async {
    final sure = await showAppDialog<bool>(
      context: context,
      builder: (context) => AppDialog(
        title: Text('Remove “{name}”?'.fill({'name': package.name})),
        content: SizedBox(width: dialogWidth(context, 360), child: Text('This one can’t be undone.'.tr)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text('Cancel'.tr)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text('Remove'.tr)),
        ],
      ),
    );
    if (sure == true) plugins.remove(package.id);
  }
}

/// A plugin's row menu in Settings ▸ Plugins: Settings… (while it shows its own), Edit… (View…
/// for one of Curator's own), Duplicate, Export…, Remove.
class PluginMenu extends StatelessWidget {
  const PluginMenu({super.key, required this.plugins, required this.package});
  final Plugins plugins;
  final PluginPackage package;

  @override
  Widget build(BuildContext context) {
    final own = plugins.isOwn(package.id);
    return AppPopupMenuButton<VoidCallback>(
      tooltip: 'More'.tr,
      iconSize: 18,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 150),
      icon: Icon(AppIcon.more.of(context), color: context.colors.textMuted),
      onSelected: (action) => action(),
      itemBuilder: (_) => [
        if (plugins.hasSettings(package.id)) menuItem(context, value: () => plugins.showSettings(package.id), child: Text('Settings…'.tr)),
        menuItem(context, value: () => PluginActions.edit(context, plugins, package), child: Text(own ? 'View…'.tr : 'Edit…'.tr)),
        menuItem(context, value: () => PluginActions.duplicate(context, plugins, package), child: Text('Duplicate'.tr)),
        menuItem(context, value: () => PluginActions.export(context, package), child: Text('Export…'.tr)),
        if (!own) menuItem(context, value: () => PluginActions.remove(context, plugins, package), child: Text('Remove'.tr)),
      ],
    );
  }
}
