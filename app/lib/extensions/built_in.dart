import 'package:flutter/widgets.dart';

import '../app_icons.dart';
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
