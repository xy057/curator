import 'package:flutter/material.dart';
import 'package:score_engine/score_engine.dart';

import 'app_colors.dart';
import 'editor_controller.dart';
import 'image_patch.dart';
import 'ui_kit.dart';

/// The images the project keeps (Attach Image), each with where it is used: a use's bar
/// locates it, Remove takes the image off the score everywhere (one Undo step). Below them
/// the unused ones (removed, kept for Undo), which Purge unused lets go of.
Future<void> showAssetsDialog(BuildContext context, EditorController c) =>
    showAppDialog<void>(context: context, builder: (context) => AssetsDialog(controller: c));

class AssetsDialog extends StatelessWidget {
  const AssetsDialog({super.key, required this.controller});
  final EditorController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final open = controller.score != null;
        final stored = open ? controller.images.stored : const <PatchImage>[];
        final unused = open ? controller.images.unused : const <PatchImage>[];
        final muted = TextStyle(color: context.colors.textMuted);
        return AlertDialog(
          title: const Text('Assets'),
          content: SizedBox(
            width: 480,
            height: 360,
            child: stored.isEmpty && unused.isEmpty
                ? Center(child: Text('No images', style: muted))
                : ListView(children: [
                    for (final (i, image) in stored.indexed) ...[
                      if (i > 0) const Divider(height: 1),
                      _AssetRow(controller: controller, image: image),
                    ],
                    if (unused.isNotEmpty)
                      Padding(
                        padding: EdgeInsets.only(top: stored.isEmpty ? 0 : 16, bottom: 4),
                        child: Text('Unused', style: muted.copyWith(fontSize: 12, fontWeight: FontWeight.w600)),
                      ),
                    for (final (i, image) in unused.indexed) ...[
                      if (i > 0) const Divider(height: 1),
                      _AssetRow(controller: controller, image: image),
                    ],
                  ]),
          ),
          actions: [
            TextButton(onPressed: unused.isEmpty ? null : controller.images.purgeUnused, child: const Text('Purge unused')),
            FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
          ],
        );
      },
    );
  }
}

/// One image: its thumbnail, kind and size, its uses (each a bar), and Remove (none when it
/// is unused).
class _AssetRow extends StatelessWidget {
  const _AssetRow({required this.controller, required this.image});
  final EditorController controller;
  final PatchImage image;

  static String _bytes(int n) => n < 1 << 10
      ? '$n B'
      : n < 1 << 20
          ? '${(n / (1 << 10)).toStringAsFixed(0)} KB'
          : '${(n / (1 << 20)).toStringAsFixed(1)} MB';

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final images = controller.images, art = images.artOfImage(image.id);
    final uses = images.usesOf(image.id);
    final type = image.id.split('.').last.toUpperCase();
    final pixels = art is RasterArt ? '${art.image.width} × ${art.image.height}' : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        Container(
          width: 72,
          height: 48,
          decoration: BoxDecoration(color: colors.scorePaper, border: Border.all(color: colors.line), borderRadius: BorderRadius.circular(4)),
          child: art == null ? null : CustomPaint(painter: _Thumbnail(art)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text([type, ?pixels, _bytes(image.bytes.length)].join(' · '),
                style: TextStyle(fontSize: 12, color: colors.textMuted, fontFeatures: const [FontFeature.tabularFigures()])),
            const SizedBox(height: 2),
            Wrap(spacing: 2, children: [
              for (final i in uses)
                Tip(
                  message: 'Locate',
                  child: TextButton(
                    style: TextButton.styleFrom(
                        minimumSize: const Size(0, 26), padding: const EdgeInsets.symmetric(horizontal: 6), visualDensity: VisualDensity.compact),
                    onPressed: () {
                      Navigator.pop(context);
                      images.locate(i);
                    },
                    child: Text('Bar ${controller.beats.format(images.patches[i].quarter, compact: true)}',
                        style: const TextStyle(fontSize: 12.5)),
                  ),
                ),
            ]),
          ]),
        ),
        if (uses.isNotEmpty)
          ToolbarButton(icon: Icons.delete_outline_rounded, tooltip: 'Remove', onPressed: () => images.removeImage(image.id)),
      ]),
    );
  }
}

/// The whole image, fitted in the box keeping its shape.
class _Thumbnail extends CustomPainter {
  _Thumbnail(this.art);
  final PatchArt art;

  @override
  void paint(Canvas canvas, Size size) {
    final box = Offset.zero & size;
    final fitted = applyBoxFit(BoxFit.contain, art.size, box.deflate(3).size);
    final destination = Alignment.center.inscribe(fitted.destination, box);
    art.paint(canvas, Offset.zero & art.size, destination);
  }

  @override
  bool shouldRepaint(_Thumbnail old) => old.art != art;
}
