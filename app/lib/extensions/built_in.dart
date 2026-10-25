import 'package:flutter/widgets.dart';

import '../app_icons.dart';
import '../app_settings.dart';
import '../caption_settings.dart';
import '../editor_controller.dart';
import 'extension.dart';

/// Images that scroll with the score ([EditorController.images]).
class AttachImageExtension extends CuratorExtension {
  const AttachImageExtension();

  @override
  String get id => 'attachImage';
  @override
  String get label => 'Attach Image';
  @override
  IconData icon(BuildContext context) => AppIcon.image.of(context);
  @override
  String get version => '1.0';
  @override
  String get summary => 'Images that scroll with the score.';
  @override
  String get keywords => 'image picture photo svg png jpg';

  @override
  bool isUsedBy(EditorController controller) => controller.images.patches.isNotEmpty;

  @override
  void apply(EditorController controller, bool on) => controller.images.enabled = on;
}

/// Timed text under the score ([EditorController.captions]).
class CaptionsExtension extends CuratorExtension {
  const CaptionsExtension();

  @override
  String get id => 'captions';
  @override
  String get label => 'Captions';
  @override
  IconData icon(BuildContext context) => AppIcon.captions.of(context);
  @override
  String get version => '1.1';
  @override
  String get summary => 'Timed text under the score.';
  @override
  String get keywords => 'caption subtitle commentary note text srt vtt webvtt';

  @override
  Widget Function(BuildContext context, AppSettings settings) get settings =>
      (context, settings) => CaptionSettings(settings: settings);

  @override
  bool isUsedBy(EditorController controller) =>
      controller.captions.captions.isNotEmpty || controller.captions.font != null;

  @override
  void apply(EditorController controller, bool on) => controller.captions.enabled = on;
}
