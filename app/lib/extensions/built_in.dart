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
  String get summary => 'Images and spacers that scroll with the score.';
  @override
  String get keywords => 'image picture photo svg png jpg gif apng webp bmp ico tiff heic avif animated animation spacer space gap blank placeholder';

  @override
  bool isUsedBy(EditorController controller) =>
      controller.images.patches.isNotEmpty || controller.spacers.vertical.isNotEmpty || controller.spacers.horizontal.isNotEmpty;

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

/// Named stretches of the piece, for a video's player and a web page ([EditorController.chapters]).
class ChaptersExtension extends CuratorExtension {
  const ChaptersExtension();

  @override
  String get id => 'chapters';
  @override
  String get label => 'Chapters';
  @override
  IconData icon(BuildContext context) => AppIcon.chapters.of(context);
  @override
  String get summary => 'Named places to jump to in a video or web page.';
  @override
  String get keywords => 'chapter marker bookmark section movement rehearsal mark youtube timestamp jump navigation';

  @override
  bool isUsedBy(EditorController controller) => controller.chapters.chapters.isNotEmpty;

  @override
  void apply(EditorController controller, bool on) => controller.chapters.enabled = on;
}
