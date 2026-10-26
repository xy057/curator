import 'package:flutter/material.dart';

import '../app_colors.dart';
import '../dialog_kit.dart';
import '../editor_controller.dart';
import '../ui_kit.dart';
import 'extension.dart';
import '../l10n/l10n.dart';

/// After a project opens: when it uses extensions it never chose to have on or off, lists them
/// with a switch each (and one for all), so it can show as it was made. The project keeps what
/// the dialog ends with, so it asks once.
Future<void> promptForExtensions(BuildContext context, EditorController controller) async {
  final unchosen = [
    for (final e in Extensions.usedBy(controller))
      if (!controller.extensionChosen(e.id)) e,
  ];
  if (unchosen.isEmpty) return;
  await showAppDialog<void>(context: context, builder: (_) => ExtensionsDialog(controller: controller, extensions: unchosen));
  controller.keepExtensions([for (final e in unchosen) e.id]);
}

/// The extensions a project uses, each with its switch.
class ExtensionsDialog extends StatelessWidget {
  const ExtensionsDialog({super.key, required this.controller, required this.extensions});
  final EditorController controller;
  final List<CuratorExtension> extensions;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final allOn = extensions.every((e) => e.isOn(controller));
        void setAll(bool on) => controller.setExtensions({for (final e in extensions) e.id: on});

        return AppDialog(
          title: Text('Extensions in this project'.tr),
          divided: true,
          content: SizedBox(
            width: dialogWidth(context, 360),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (extensions.length > 1) ...[
                _SwitchRow(
                  label: Text('All'.tr, style: TextStyle(fontWeight: FontWeight.w600)),
                  value: allOn,
                  onChanged: setAll,
                ),
                const Divider(height: 1),
              ],
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: extensions.length,
                  itemExtent: 40,
                  itemBuilder: (context, i) {
                    final e = extensions[i];
                    return _SwitchRow(
                      icon: e.icon(context),
                      label: Text(e.label.tr),
                      value: e.isOn(controller),
                      onChanged: (on) => e.set(controller, on),
                    );
                  },
                ),
              ),
            ]),
          ),
          actions: [FilledButton(onPressed: () => Navigator.pop(context), child: Text('Done'.tr))],
        );
      },
    );
  }
}

/// A row with a switch, turned by a click anywhere on it: 40 px, flush with the dialog's content.
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({this.icon, required this.label, required this.value, required this.onChanged});
  final IconData? icon;
  final Widget label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final control = AppSwitch(value: value, onChanged: onChanged);
    // Flush with the dialog's other content, as its check rows are.
    return InkWell(
      hoverColor: Colors.transparent,
      highlightColor: Colors.transparent,
      onTap: () => onChanged(!value),
      child: SizedBox(
        height: 40,
        child: Row(children: [ ...[Icon(icon, size: 18, color: context.colors.textMuted), const SizedBox(width: 12)],
          Expanded(child: DefaultTextStyle.merge(style: const TextStyle(fontSize: 14), child: label)),
          control,
        ]),
      ),
    );
  }
}
