import 'package:flutter/widgets.dart';

import '../app_settings.dart';
import '../editor_controller.dart';
import 'built_in.dart';

/// Where an extension comes from. Only [builtIn] exists today: the app ships each one, and
/// nothing is loaded from elsewhere. [thirdParty] marks where others would fit later.
enum ExtensionOrigin { builtIn, thirdParty }

/// An optional component (Project Settings ▸ Extensions): what the app needs to know about one
/// to list it, switch it per project and ask for it when a project uses it.
///
/// Everything here is by [id], never by type, so the app's own code needs no change for one
/// more: each project saves its switches by id (`EditState.extensions`; there is no app-wide
/// default), and the editor turns each on through [apply].
///
/// What an extension adds to the editor (its menu items, toolbar buttons, drop targets, what
/// it draws and exports) is still wired into the app by hand, behind its switch: the built-in
/// ones only. A contribution API for others is not part of this yet.
abstract class CuratorExtension {
  const CuratorExtension();

  /// Stable for good: projects save their switches under it. Built-in ones are one
  /// word ('captions'); one from elsewhere would need a reverse-domain id
  /// ('com.example.lyrics') so the two can never clash.
  String get id;

  String get label;
  IconData icon(BuildContext context);

  /// Shown after [label]; raised when what the extension does changes.
  String get version;

  /// One short line under [label].
  String get summary;

  /// For Settings' search.
  String get keywords;

  ExtensionOrigin get origin => ExtensionOrigin.builtIn;

  /// Its own settings, the content of a dialog from its row's settings button (greyed out
  /// while null). They are the app's, for every project.
  Widget Function(BuildContext context, AppSettings settings)? get settings => null;

  /// Whether the open project uses it (images on the score…): opening one that does but
  /// never chose to have it on or off asks.
  bool isUsedBy(EditorController controller);

  /// Turns what it adds to [controller] on or off, as the project's switch says: on opening,
  /// on Undo, and whenever the switch changes.
  void apply(EditorController controller, bool on);

  /// Whether it is on in [controller]'s project.
  bool isOn(EditorController controller) => controller.extensionOn(id);

  /// Turns it on or off in [controller]'s project: an Undo step.
  void set(EditorController controller, bool on) => controller.setExtension(id, on);
}

/// Every extension the app knows, in the order Project Settings lists them.
abstract final class Extensions {
  static const attachImage = AttachImageExtension();
  static const captions = CaptionsExtension();

  /// Built in, shipped with the app.
  static const builtIn = <CuratorExtension>[attachImage, captions];

  /// All of them: the built-in ones, the only ones there are for now.
  static List<CuratorExtension> get all => builtIn;

  static CuratorExtension? byId(String id) => all.where((e) => e.id == id).firstOrNull;

  /// The ones [controller]'s project uses.
  static List<CuratorExtension> usedBy(EditorController controller) => [
        for (final e in all)
          if (e.isUsedBy(controller)) e,
      ];
}
