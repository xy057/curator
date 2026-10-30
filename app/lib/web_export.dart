import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:score_engine/score_engine.dart';

import 'editor_controller.dart';
import 'extensions/extension.dart';
import 'file_names.dart';
import 'image_patch.dart';
import 'l10n/l10n.dart';
import 'project_file.dart';
import 'project_modules.dart';
import 'project_archive.dart';
import 'project_state.dart';
import 'video_export.dart';
import 'web_page.dart';

/// File ▸ Export to Web…: the open project as a folder to put on any web server, the web player
/// (built into the app, [playerAsset]) beside what it shows ([WebPage]).
abstract final class WebExport {
  /// The web player as `flutter build web` makes it (`make web-player`), zipped.
  static const playerAsset = 'assets/web_player/player.zip';

  /// Whether this build has the web player.
  static Future<bool> available() async {
    try {
      await rootBundle.load(playerAsset);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Writes [editor]'s project to the folder [output] as [page] says (its recordings, fonts and
  /// name colours are filled in here): [takes] heard whole as well as the performance, the
  /// captions and the images only if [captions] and [images]. Written beside it and moved in at
  /// the end; a folder there already is replaced only if it is an earlier page. Returns the
  /// path of its `index.html`. Throws a [VideoExportException] saying why it couldn't. A test
  /// gives the [player] (zipped), as it has no build of it.
  static Future<String> write(EditorController editor, String output,
      {required WebPage page,
      List<String> takes = const [],
      bool captions = true,
      bool images = true,
      @visibleForTesting Uint8List? player}) async {
    final score = editor.score;
    if (score == null) throw const VideoExportException('Nothing is open.');
    if (Directory(output).existsSync() && Directory(output).listSync().isNotEmpty &&
        !File('$output/${WebPage.folder}/${WebPage.pageFile}').existsSync()) {
      throw VideoExportException('“{name}” already holds other files. Choose another name.'.fill({'name': fileNameOf(output)}));
    }
    if (player == null) {
      try {
        final asset = await rootBundle.load(playerAsset);
        player = asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes);
      } catch (_) {
        throw VideoExportException('This build of Curator has no web player.'.tr);
      }
    }

    final part = Directory('$output.part');
    if (part.existsSync()) part.deleteSync(recursive: true); // an export that never finished
    try {
      for (final f in ZipDecoder().decodeBytes(player).files) {
        if (!f.isFile) continue;
        File('${part.path}/${f.name}')
          ..createSync(recursive: true)
          ..writeAsBytesSync(f.content);
      }
      final folder = '${part.path}/${WebPage.folder}';
      Directory('$folder/audio').createSync(recursive: true);

      // What the page shows: the project with every setting its own, and the score engraved.
      var edits = editor.pageState;
      if (!captions) edits = edits.copyWith(captions: const [], extensions: {...edits.extensions, Extensions.captions.id: false});
      if (!images) edits = edits.copyWith(patches: const []);
      if (WebPage.requestOf(edits) != score.request) {
        throw VideoExportException('The score is still being engraved. Try again in a moment.'.tr);
      }
      final kept = {for (final p in edits.patches) p.image};
      final state = ProjectState(edits: edits, images: {
        for (final MapEntry(key: id, value: image) in editor.projectState.images.entries)
          if (kept.contains(id))
            // Sized here: the page can't measure an SVG with no size of its own.
            id: image.kind == ImageKind.vector ? PatchImage(id, image.kind, await PatchImage.sized(image.bytes)) : image,
      });
      final zip = _StoredZip()..startEncode(OutputFileStream('$folder/${WebPage.projectFile}'));
      ProjectArchive.write(zip, state, mimeType: ProjectFile.mimeType, stub: 'project.json', modules: ProjectModules.all, manifest: {
        'score': {'name': 'score.musicxml', 'entry': WebPage.scoreEntry},
      });
      zip.add(ArchiveFile.string(WebPage.scoreEntry, score.musicXML));
      zip.endEncode();
      File('$folder/${WebPage.engravingFile}').writeAsBytesSync(EngravingFile.write(score.engraving));

      // The text fonts the score and the captions are drawn in, when they are installed ones.
      final fonts = <({String family, List<String> files})>[];
      for (final name in {
        if (score.textFontFound) score.fonts.text,
        if (captions && editor.extensionOn(Extensions.captions.id)) editor.captions.font ?? editor.captions.defaultFont,
      }) {
        if (name.isEmpty || name == TextFonts.academico) continue;
        final faces = await TextFonts.faces(name);
        if (faces == null) continue;
        final files = <String>[];
        for (final face in faces.values.toSet()) {
          final file = 'fonts/${fonts.length}-${files.length}.font';
          File('$folder/$file')
            ..createSync(recursive: true)
            ..writeAsBytesSync(FontFiles.faceBytes(face));
          files.add(file);
        }
        fonts.add((family: TextFonts.familyOf(name), files: files));
      }

      // Each way to hear it, its sound mixed as a video's would be.
      final recordings = <WebRecording>[];
      final all = editor.pageState.takes;
      for (final take in [null, if (all.length > 1) ...takes]) {
        final video = VideoExport.of(editor, take: take);
        try {
          if (!video.showBars(page.firstBar, page.lastBar)) throw VideoExportException('Those aren’t bars of the score.'.tr);
          final audio = all.isEmpty ? null : 'audio/${recordings.length + 1}.m4a';
          if (audio != null) await video.writeSound('$folder/$audio');
          recordings.add(WebRecording(
            label: take == null ? 'Performance'.tr : all.firstWhere((t) => t.id == take).label,
            take: take,
            audio: audio,
            start: video.span.start,
            end: video.span.end,
            musicEnd: video.musicEnd,
          ));
        } finally {
          video.dispose();
        }
      }

      final written = WebPage(
        title: page.title,
        staffSpace: page.staffSpace,
        ratio: page.ratio,
        firstBar: page.firstBar,
        lastBar: page.lastBar,
        recordings: recordings,
        captionStyle: editor.captions.style,
        nameColors: editor.nameColors,
        fonts: fonts,
        instruments: page.instruments,
        recording: page.recording.copyWith(value: page.recording.value.clamp(0, recordings.length - 1)),
        captions: page.captions,
        barNumbers: page.barNumbers,
        speed: page.speed,
      );
      File('$folder/${WebPage.pageFile}').writeAsStringSync(const JsonEncoder.withIndent(' ').convert(written.toJson()));
      _title(File('${part.path}/index.html'), page.title);

      if (Directory(output).existsSync()) Directory(output).deleteSync(recursive: true);
      part.renameSync(output);
    } catch (e) {
      if (part.existsSync()) part.deleteSync(recursive: true);
      if (e is VideoExportException) rethrow;
      throw VideoExportException('${'Couldn’t write the page.'.tr}\n$e');
    }
    return '$output/index.html';
  }

  /// Gives the player's page [title] (what a browser's tab shows).
  static void _title(File index, String title) {
    if (!index.existsSync()) return;
    const escape = HtmlEscape(HtmlEscapeMode.element);
    index.writeAsStringSync(index.readAsStringSync().replaceFirst(RegExp(r'<title>[^<]*</title>'), '<title>${escape.convert(title)}</title>'));
  }
}

/// A zip whose entries are all stored: a browser reads them without inflating ([ZipEntries]
/// inflates with dart:io, which a page hasn't got), and a web server compresses what it sends.
class _StoredZip extends ZipEncoder {
  @override
  void add(ArchiveFile entry, {bool autoClose = true, ArchiveCallback? callback, int? level}) =>
      super.add(entry..compression = CompressionType.none, autoClose: autoClose, callback: callback, level: level);
}
