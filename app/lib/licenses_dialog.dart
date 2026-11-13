// Settings ▸ About ▸ Licenses: Curator's own licence, then those of everything it is built with
// and bundles, a package at a time: Flutter's NOTICES and what main.dart's bundledLicenses adds.
import 'package:flutter/foundation.dart' show LicenseEntry, LicenseParagraph, LicenseRegistry;
import 'package:material_ui/material_ui.dart';

import 'app_colors.dart';
import 'dialog_kit.dart';
import 'l10n/l10n.dart';
import 'ui_kit.dart';

/// The Licenses window: the packages listed on the left, Curator first, then by name; the chosen
/// one's text on the right, selectable. [groupColor] is Settings' group fill, the text's pane's.
Future<void> showLicensesDialog(BuildContext context, {required Color Function(BuildContext) groupColor}) =>
    showAppDialog<void>(context: context, builder: (_) => _LicensesDialog(groupColor));

/// Every package's licences in the order they are listed: Curator, then by name. Read once (the
/// registry decompresses Flutter's NOTICES each time it is asked).
Future<List<(String, List<LicenseEntry>)>> get packageLicenses => _packages ??= _load();
Future<List<(String, List<LicenseEntry>)>>? _packages;

Future<List<(String, List<LicenseEntry>)>> _load() async {
  final byPackage = <String, List<LicenseEntry>>{};
  try {
    await for (final entry in LicenseRegistry.licenses) {
      for (final package in entry.packages) {
        (byPackage[package] ??= []).add(entry);
      }
    }
  } catch (_) {
    _packages = null; // asked again the next time
    rethrow;
  }
  final names = byPackage.keys.toList()
    ..sort((a, b) => a == b
        ? 0
        : a == 'Curator'
            ? -1
            : b == 'Curator'
                ? 1
                : a.toLowerCase().compareTo(b.toLowerCase()));
  return [for (final name in names) (name, byPackage[name]!)];
}

class _LicensesDialog extends StatefulWidget {
  const _LicensesDialog(this.groupColor);
  final Color Function(BuildContext) groupColor;

  @override
  State<_LicensesDialog> createState() => _LicensesDialogState();
}

class _LicensesDialogState extends State<_LicensesDialog> {
  int _chosen = 0;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final carbon = AppStyle.of(context).isCarbon;
    return AppDialog(
      title: Text('Licenses'.tr),
      content: SizedBox(
        // The window as wide as a dialog goes, less its padding; the panes as tall as there's room.
        width: (size.width - 64 - (carbon ? 32 : 48)).clamp(420, 760),
        height: (size.height - 240).clamp(240, 480),
        child: FutureBuilder(
          future: packageLicenses,
          builder: (context, snapshot) {
            final packages = snapshot.data;
            if (packages == null || packages.isEmpty) {
              return Center(
                child: snapshot.connectionState == ConnectionState.done
                    ? Text('Couldn’t read the licenses.'.tr, style: TextStyle(fontSize: 13, color: context.colors.textMuted))
                    : const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
              );
            }
            final (name, entries) = packages[_chosen.clamp(0, packages.length - 1)];
            return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(
                width: 200,
                child: ListView.builder(
                  itemCount: packages.length,
                  itemBuilder: (context, i) => SidebarTile(
                    icon: null,
                    label: packages[i].$1,
                    selected: i == _chosen,
                    onTap: () => setState(() => _chosen = i),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(child: _LicenseText(key: ValueKey(name), name: name, entries: entries, fill: widget.groupColor(context))),
            ]);
          },
        ),
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(context), child: Text('Done'.tr))],
    );
  }
}

/// One package's licences, its name over them and a line between each, in a scrolling pane
/// whose text can be selected and copied.
class _LicenseText extends StatefulWidget {
  const _LicenseText({super.key, required this.name, required this.entries, required this.fill});
  final String name;
  final List<LicenseEntry> entries;
  final Color fill;

  @override
  State<_LicenseText> createState() => _LicenseTextState();
}

class _LicenseTextState extends State<_LicenseText> {
  /// Each licence's paragraphs, a null between two licences: parsed once, as it is first shown.
  late final List<LicenseParagraph?> _paragraphs = [
    for (final (i, entry) in widget.entries.indexed) ...[if (i > 0) null, ...entry.paragraphs],
  ];

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = TextStyle(fontSize: 12, height: 1.45, color: colors.text);
    return DecoratedBox(
      decoration: BoxDecoration(color: widget.fill, borderRadius: AppStyle.of(context).radius(10)),
      child: SelectionArea(
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          itemCount: _paragraphs.length + 1,
          itemBuilder: (context, i) {
            if (i == 0) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(widget.name, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: colors.text)),
              );
            }
            final paragraph = _paragraphs[i - 1];
            if (paragraph == null) return Divider(height: 28, color: colors.line);
            final centred = paragraph.indent == LicenseParagraph.centeredIndent;
            return Padding(
              padding: EdgeInsets.only(left: centred ? 0 : 16.0 * paragraph.indent, bottom: 8),
              child: Text(paragraph.text, textAlign: centred ? TextAlign.center : TextAlign.start, style: text),
            );
          },
        ),
      ),
    );
  }
}
