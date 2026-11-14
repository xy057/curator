import 'package:flutter/widgets.dart';
import 'package:score_engine/score_engine.dart' show ExtensionPackage;

import '../app_icons.dart';
import '../app_settings.dart';
import '../editor_controller.dart';
import 'built_in.dart';
import 'bundled.dart';

/// Where an extension comes from: the app ships it ([builtIn]), or the project carries it, a
/// package made elsewhere ([thirdParty]).
enum ExtensionOrigin { builtIn, thirdParty }

/// An optional component (Project Settings ▸ Extensions): what the app needs to know about one
/// to list it, switch it per project and ask for it when a project uses it.
///
/// Everything here is by [id], never by type, so the app's own code needs no change for one
/// more: each project saves its switches by id (`EditState.extensions`; there is no app-wide
/// default), and the editor turns each on through [apply].
///
/// What one written in the app adds to the editor (its menu items, toolbar buttons, drop
/// targets, what it draws and exports) is wired into the app by hand, behind its switch. One
/// that is a package ([PackageExtension]) adds everything through the extension API: its
/// connector says which of Curator's sockets it uses, and its Lua does the rest.
abstract class CuratorExtension {
  const CuratorExtension();

  /// Stable for good: projects save their switches under it. Built-in ones are one
  /// word ('captions'); one from elsewhere would need a reverse-domain id
  /// ('com.example.lyrics') so the two can never clash.
  String get id;

  String get label;
  IconData icon(BuildContext context);

  /// Shown after [label] when there is one; raised when what the extension does changes. A
  /// built-in one has none: it changes with the app.
  String? get version => null;

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

/// An extension that is a package: one of Curator's own ([BundledExtensions]) or one the
/// project carries. Its switch starts and stops its [ExtensionRuntime]
/// ([EditorController.extensions]).
class PackageExtension extends CuratorExtension {
  const PackageExtension(this.package, {required this.bundled});
  final ExtensionPackage package;

  /// Whether it is Curator's own: it changes with the app, and shows no version.
  final bool bundled;

  @override
  String get id => package.id;
  @override
  String get label => package.name;
  @override
  IconData icon(BuildContext context) => (AppIcon.values.asNameMap()[package.icon] ?? AppIcon.extensions).of(context);
  @override
  String? get version => bundled ? null : package.version;
  @override
  String get summary => package.summary;
  @override
  String get keywords => package.keywords;
  @override
  ExtensionOrigin get origin => bundled ? ExtensionOrigin.builtIn : ExtensionOrigin.thirdParty;
  @override
  bool isUsedBy(EditorController controller) => controller.extensions.uses(id);
  @override
  void apply(EditorController controller, bool on) {} // the controller starts and stops it
}

/// Every extension there is, in the order Project Settings lists them.
abstract final class Extensions {
  static const attachImage = AttachImageExtension();
  static const captions = CaptionsExtension();

  /// Written in the app.
  static const builtIn = <CuratorExtension>[attachImage, captions];

  /// The order Curator's own are listed in; one not named here follows, by id.
  static const _order = ['attachImage', 'captions', 'chapters', 'tonality'];

  /// Curator's own: those written in the app and those bundled as packages, in one order.
  static List<CuratorExtension> get all {
    final all = <CuratorExtension>[...builtIn, for (final p in BundledExtensions.packages) PackageExtension(p, bundled: true)];
    int place(CuratorExtension e) => switch (_order.indexOf(e.id)) { -1 => _order.length, final i => i };
    return all..sort((a, b) => switch (place(a).compareTo(place(b))) { 0 => a.id.compareTo(b.id), final by => by });
  }

  /// Those [controller]'s project can turn on: Curator's own, then the ones it carries.
  static List<CuratorExtension> of(EditorController controller) => [
        ...all,
        for (final p in controller.extensions.carried.values) PackageExtension(p, bundled: false),
      ];

  static CuratorExtension? byId(String id) => all.where((e) => e.id == id).firstOrNull;

  /// The ones [controller]'s project uses.
  static List<CuratorExtension> usedBy(EditorController controller) => [
        for (final e in of(controller))
          if (e.isUsedBy(controller)) e,
      ];
}
