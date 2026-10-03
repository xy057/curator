import 'package:flutter/material.dart';

import 'app_settings.dart';
import 'editor_controller.dart';
import 'ui_kit.dart';

/// The optional first-party components (Settings ▸ Extension). Each is a switch for the whole
/// app (not per project), off by default; what it adds works only while it is on.
enum AppExtension {
  attachImage('Attach Image', Icons.image_outlined, 'image picture photo svg png jpg');

  const AppExtension(this.label, this.icon, this.keywords);
  final String label;
  final IconData icon;

  /// For Settings' search.
  final String keywords;

  bool isOn(AppSettings settings) => switch (this) {
        attachImage => settings.attachImage,
      };

  void set(AppSettings settings, bool on) => switch (this) {
        attachImage => settings.attachImage = on,
      };

  /// The extensions what [controller] has open uses (images on the score…).
  static List<AppExtension> usedBy(EditorController controller) => [
        if (controller.images.patches.isNotEmpty) attachImage,
      ];
}

/// After a project opens: when it uses extensions that are off, lists them with a switch
/// each (and one for all), so it can show as it was made.
Future<void> promptForExtensions(BuildContext context, AppSettings settings, EditorController controller) async {
  final used = AppExtension.usedBy(controller);
  if (used.every((e) => e.isOn(settings))) return;
  await showAppDialog<void>(context: context, builder: (_) => ExtensionsDialog(settings: settings, extensions: used));
}

/// The extensions a project uses, each with its switch.
class ExtensionsDialog extends StatelessWidget {
  const ExtensionsDialog({super.key, required this.settings, required this.extensions});
  final AppSettings settings;
  final List<AppExtension> extensions;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final allOn = extensions.every((e) => e.isOn(settings));
        return AlertDialog(
          title: const Text('Extensions in this project'),
          contentPadding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
          content: SizedBox(
            width: 360,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (extensions.length > 1) ...[
                SwitchListTile(
                  dense: true,
                  title: const Text('All', style: TextStyle(fontWeight: FontWeight.w600)),
                  value: allOn,
                  onChanged: (on) {
                    for (final e in extensions) {
                      e.set(settings, on);
                    }
                  },
                ),
                const Divider(height: 1),
              ],
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: extensions.length,
                  itemExtent: 44,
                  itemBuilder: (context, i) {
                    final e = extensions[i];
                    return SwitchListTile(
                      dense: true,
                      secondary: Icon(e.icon, size: 18),
                      title: Text(e.label),
                      value: e.isOn(settings),
                      onChanged: (on) => e.set(settings, on),
                    );
                  },
                ),
              ),
            ]),
          ),
          actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))],
        );
      },
    );
  }
}
