import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_settings.dart';
import 'caption_settings.dart';
import 'dialog_kit.dart';
import 'editor_controller.dart';
import 'ui_kit.dart';

/// The optional first-party components (Settings ▸ Extension). Each is a switch for the whole
/// app (not per project), off by default; what it adds works only while it is on.
enum AppExtension {
  attachImage('Attach Image', Icons.image_outlined, '1.0', 'Images on the score, scrolling with it.',
      'image picture photo svg png jpg'),
  captions('Captions', Icons.subtitles_outlined, '1.0', 'Timed text under the score.',
      'caption subtitle commentary note text');

  const AppExtension(this.label, this.icon, this.version, this.summary, this.keywords);
  final String label;
  final IconData icon;

  /// Shown after [label]; raised when what the extension does changes.
  final String version;

  /// One short line under [label].
  final String summary;

  /// For Settings' search.
  final String keywords;

  /// The extension's own settings, in a dialog from its row's settings button (greyed out
  /// while this is null).
  Widget Function(BuildContext context, AppSettings settings)? get settings => switch (this) {
        attachImage => null,
        captions => (context, settings) => CaptionSettings(settings: settings),
      };

  bool isOn(AppSettings settings) => switch (this) {
        attachImage => settings.attachImage,
        captions => settings.captions,
      };

  void set(AppSettings settings, bool on) => switch (this) {
        attachImage => settings.attachImage = on,
        captions => settings.captions = on,
      };

  /// The extensions what [controller] has open uses (images on the score…).
  static List<AppExtension> usedBy(EditorController controller) => [
        if (controller.images.patches.isNotEmpty) attachImage,
        if (controller.captions.captions.isNotEmpty || controller.captions.font != null) captions,
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
        void setAll(bool on) {
          for (final e in extensions) {
            e.set(settings, on);
          }
        }

        return AppDialog(
          title: const Text('Extensions in this project'),
          contentPadding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
          divided: true,
          content: SizedBox(
            width: dialogWidth(context, 360),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (extensions.length > 1) ...[
                _SwitchRow(
                  label: const Text('All', style: TextStyle(fontWeight: FontWeight.w600)),
                  value: allOn,
                  onChanged: setAll,
                ),
                const Divider(height: 1),
              ],
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: extensions.length,
                  itemExtent: isRefinedDialog(context) ? 40 : 44,
                  itemBuilder: (context, i) {
                    final e = extensions[i];
                    return _SwitchRow(
                      icon: e.icon,
                      label: Text(e.label),
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

/// A row with a switch, turned by a click anywhere on it: a list tile in [UiStyle.classic], a
/// 40 px row in [UiStyle.refined].
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({this.icon, required this.label, required this.value, required this.onChanged});
  final IconData? icon;
  final Widget label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final control = AppSwitch(value: value, onChanged: onChanged);
    if (!isRefinedDialog(context)) {
      return ListTile(
        dense: true,
        leading: icon == null ? null : Icon(icon, size: 18),
        title: label,
        trailing: control,
        onTap: () => onChanged(!value),
      );
    }
    return InkWell(
      borderRadius: BorderRadius.circular(7),
      onTap: () => onChanged(!value),
      child: SizedBox(
        height: 40,
        child: Row(children: [
          const SizedBox(width: 8),
          if (icon != null) ...[Icon(icon, size: 18, color: context.colors.textMuted), const SizedBox(width: 12)],
          Expanded(child: DefaultTextStyle.merge(style: const TextStyle(fontSize: 14), child: label)),
          control,
          const SizedBox(width: 4),
        ]),
      ),
    );
  }
}
