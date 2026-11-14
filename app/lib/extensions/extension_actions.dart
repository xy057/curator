import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'package:score_engine/score_engine.dart';

import '../app_colors.dart';
import '../app_icons.dart';
import '../dialog_kit.dart';
import '../edit_dialogs.dart' show confirmSavePath;
import '../editor_controller.dart';
import '../error_text.dart';
import '../menu_kit.dart';
import '../ui_kit.dart';
import '../l10n/l10n.dart';
import 'extension.dart';
import 'extension_editor.dart';
import 'extension_reader.dart';
import 'extension_settings.dart';

/// What Project Settings ▸ Extensions does with an extension that is a package: make a new
/// one, add one from a file, edit it (the extension editor), save it as a file, take it out
/// of the project, and copy one of Curator's own to change.
abstract final class ExtensionActions {
  static const _types = XTypeGroup(label: 'Curator Extension', extensions: [ExtensionPackage.fileExtension]);

  static Future<void> _say(BuildContext context, String title, String message) => showAppDialog<void>(
        context: context,
        builder: (context) => AppDialog(
          title: Text(title),
          content: SizedBox(width: dialogWidth(context, 380), child: Text(message)),
          actions: [FilledButton(onPressed: () => Navigator.pop(context), child: Text('OK'.tr))],
        ),
      );

  /// An id for an extension named [name] that the project has none with: "user.my-notes".
  static String idFor(String name, EditorController controller) {
    final slug = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    final base = 'user.${slug.isEmpty ? 'extension' : slug}';
    for (var n = 1;; n++) {
      final id = n == 1 ? base : '$base-$n';
      if (controller.extensions.package(id) == null) return id;
    }
  }

  /// Asks for a new extension's name, adds it to the project and opens it in the editor.
  static Future<void> create(BuildContext context, EditorController controller) async {
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
            title: Text('New Extension'.tr),
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
    final package = ExtensionPackage.blank(id: idFor(chosen, controller), name: chosen);
    controller.extensions.add(package);
    controller.setExtension(package.id, true);
    await edit(context, controller, package);
  }

  /// Adds an extension from a .cpe file the user chooses (in place of the one the project
  /// carries with its id).
  static Future<void> addFromFile(BuildContext context, EditorController controller) async {
    final file = await openFile(acceptedTypeGroups: const [_types]);
    if (file == null || !context.mounted) return;
    try {
      controller.extensions.add(ExtensionPackage.read(await file.readAsBytes()));
    } on FormatException catch (e) {
      if (context.mounted) await _say(context, 'Couldn’t Add the Extension'.tr, e.message.tr);
    } on FileSystemException catch (e) {
      if (context.mounted) await _say(context, 'Couldn’t Add the Extension'.tr, describeError(e));
    }
  }

  /// Opens [package] in the extension editor: one the project carries is edited there (Run
  /// hands it to the project as it stands, Done keeps it). One of Curator's own is edited too,
  /// as the sample project is: it runs as changed while the project is open
  /// ([ExtensionEditing.tryOut]) and is never saved; Duplicate keeps a copy.
  static Future<void> edit(BuildContext context, EditorController controller, ExtensionPackage package) async {
    final own = !ExtensionPackage.isThirdPartyId(package.id);
    package = controller.extensions.package(package.id) ?? package;
    final edited = await showExtensionEditor(
      context,
      package,
      unsaved: own,
      onRun: (p) {
        controller.extensions.clearProblems(p.id);
        if (own) return controller.extensions.tryOut(p);
        controller.extensions.add(p);
        controller.extensions.restart(p.id);
      },
      calls: () => controller.extensions.runtime(package.id)?.calls,
      problems: controller.extensions.problems,
      log: controller.extensions.log,
    );
    if (edited != null) {
      controller.extensions.clearProblems(edited.id);
      own ? controller.extensions.tryOut(edited) : controller.extensions.add(edited);
    }
  }

  /// Whether [package] has settings of its own (a `settings` socket).
  static bool hasSettings(ExtensionPackage package) => package.graph.nodes.any((n) => n.type == 'settings');

  /// Opens [package]'s own settings, kept for every project: asked of the extension as it
  /// runs in the project, or run for this alone while it is off.
  static Future<void> settings(BuildContext context, EditorController controller, ExtensionPackage package) {
    final id = package.id;
    final runtime = controller.extensions.runtime(id) ??
        ExtensionRuntime(
          package,
          ReadingHost(package, null,
              settingsNow: () => controller.extensionSettings?.call(id), onSaveSettings: (json) => controller.saveExtensionSettings?.call(id, json)),
        );
    return showExtensionSettings(context, runtime);
  }

  /// Saves [package] as a .cpe file where the user says.
  static Future<void> export(BuildContext context, ExtensionPackage package) async {
    final location = await getSaveLocation(acceptedTypeGroups: const [_types], suggestedName: '${package.name}.${ExtensionPackage.fileExtension}');
    if (location == null || !context.mounted) return;
    final path = await confirmSavePath(context, location.path, ExtensionPackage.fileExtension);
    if (path == null) return;
    try {
      await File(path).writeAsBytes(package.write());
    } on FileSystemException catch (e) {
      if (context.mounted) await _say(context, 'Couldn’t Save the Extension'.tr, describeError(e));
    }
  }

  /// A copy of [package] (one of Curator's own) the project carries and can change, named
  /// "… Copy", with an id of its own and data of its own.
  static ExtensionPackage copyOf(ExtensionPackage package, EditorController controller) {
    final name = '{name} Copy'.fill({'name': package.name.tr});
    final data = {...package.data}..remove('module');
    return package.copyWith(manifest: {
      ...package.manifest,
      'id': idFor(package.id, controller),
      'name': name,
      'version': '1.0.0',
      if (data.isEmpty) 'data': null else 'data': data,
    }..removeWhere((key, value) => value == null));
  }

  static Future<void> duplicate(BuildContext context, EditorController controller, ExtensionPackage package) async {
    final copy = copyOf(package, controller);
    controller.extensions.add(copy);
    await edit(context, controller, copy);
  }
}

/// An extension's row menu in Project Settings ▸ Extensions: Settings… (when it has its own), Edit… (and Revert for one of Curator's own that was changed),
/// Duplicate, Export…, Remove.
class ExtensionMenu extends StatelessWidget {
  const ExtensionMenu({super.key, required this.controller, required this.extension});
  final EditorController controller;
  final PackageExtension extension;

  @override
  Widget build(BuildContext context) {
    final own = extension.bundled, package = controller.extensions.package(extension.id) ?? extension.package;
    return AppPopupMenuButton<VoidCallback>(
      tooltip: 'More'.tr,
      iconSize: 18,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 150),
      icon: Icon(AppIcon.more.of(context), color: context.colors.textMuted),
      onSelected: (action) => action(),
      itemBuilder: (_) => [
        if (ExtensionActions.hasSettings(package)) menuItem(context, value: () => ExtensionActions.settings(context, controller, package), child: Text('Settings…'.tr)),
        menuItem(context, value: () => ExtensionActions.edit(context, controller, package), child: Text('Edit…'.tr)),
        if (controller.extensions.tried(package.id)) menuItem(context, value: () => controller.extensions.revert(package.id), child: Text('Revert'.tr)),
        menuItem(context, value: () => ExtensionActions.duplicate(context, controller, package), child: Text('Duplicate'.tr)),
        menuItem(context, value: () => ExtensionActions.export(context, package), child: Text('Export…'.tr)),
        if (!own) menuItem(context, value: () => controller.extensions.remove(package.id), child: Text('Remove'.tr)),
      ],
    );
  }
}
