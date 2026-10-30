import 'dart:convert';
import 'dart:math' as math;
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
import 'updater.dart' show appBuild, appCommit, appVersion, openInBrowser, repositoryUrl;
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
  /// the end. A folder there already is written into only if it holds an earlier page, and then
  /// only what the export writes is replaced: what else it holds (a repository, a host's own
  /// files) stays. Returns the
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
      for (final name in _textFonts(editor, captions: captions)) {
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
      File('${part.path}/$sourceFile').writeAsStringSync(source);

      if (Directory(output).existsSync()) {
        _moveIn(part, output);
      } else {
        part.renameSync(output);
      }
    } catch (e) {
      if (part.existsSync()) part.deleteSync(recursive: true);
      if (e is VideoExportException) rethrow;
      throw VideoExportException('${'Couldn’t write the page.'.tr}\n$e');
    }
    return '$output/index.html';
  }

  /// Beside a page: where the player's source is, as the GPL asks of a program passed on (its
  /// licence, LICENSE.txt, is the player's own file).
  static const sourceFile = 'SOURCE.txt';

  static String get source {
    final at = appCommit.isEmpty ? 'v$appVersion' : appCommit;
    return 'This page plays in the web player of Curator $appVersion ($appBuild${appCommit.isEmpty ? '' : ', $appCommit'}),\n'
        'free software under the GNU General Public License, version 3 (LICENSE.txt).\n'
        'Its source code: $repositoryUrl/tree/$at\n'
        '\n'
        'What else the player is made of, and its licences: assets/NOTICES.\n'
        'The fonts it brings, and their licences: assets/packages/score_engine/assets/fonts/ and\n'
        'assets/assets/fonts/.\n';
  }

  /// The fonts installed here that a page of [editor]'s project carries (with [captions], the
  /// captions' too): their licences decide whether it may be published.
  static List<String> installedFonts(EditorController editor, {required bool captions}) {
    final music = editor.score?.fonts.music;
    return [
      if (music != null && !music.isBundled && !music.isMissing) music.name,
      ..._textFonts(editor, captions: captions),
    ];
  }

  /// The installed text fonts the score and (with [captions]) the captions are drawn in.
  static Set<String> _textFonts(EditorController editor, {required bool captions}) {
    final score = editor.score;
    if (score == null) return const {};
    return {
      if (score.textFontFound) score.fonts.text,
      if (captions && editor.extensionOn(Extensions.captions.id)) editor.captions.font ?? editor.captions.defaultFont,
    }..removeWhere((name) => name.isEmpty || name == TextFonts.academico);
  }

  /// Moves what [part] holds into the folder [output], each in place of what is there by its
  /// name, then lets [part] go.
  static void _moveIn(Directory part, String output) {
    for (final entry in part.listSync()) {
      final there = '$output${Platform.pathSeparator}${entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty)}';
      switch (FileSystemEntity.typeSync(there, followLinks: false)) {
        case FileSystemEntityType.notFound:
          break;
        case FileSystemEntityType.directory:
          Directory(there).deleteSync(recursive: true);
        case FileSystemEntityType.link:
          Link(there).deleteSync();
        default:
          File(there).deleteSync();
      }
      entry.renameSync(there);
    }
    part.deleteSync(recursive: true);
  }

  /// Gives the player's page [title] (what a browser's tab shows).
  static void _title(File index, String title) {
    if (!index.existsSync()) return;
    const escape = HtmlEscape(HtmlEscapeMode.element);
    index.writeAsStringSync(index.readAsStringSync().replaceFirst(RegExp(r'<title>[^<]*</title>'), '<title>${escape.convert(title)}</title>'));
  }
}

/// A page tried on this computer: a browser won't let a page opened from disk read its files, so
/// Curator serves the folder itself, on the loopback address only, while it runs.
abstract final class WebPreview {
  static final _servers = <String, Future<HttpServer>>{};

  /// Opens the page in [folder] in the default browser; returns its address.
  static Future<String> open(String folder) async {
    final server = await _servers.putIfAbsent(folder, () => serve(folder));
    final url = 'http://localhost:${server.port}/';
    await openInBrowser(url);
    return url;
  }

  /// A server of [folder]'s files at a free port, with byte ranges (Safari plays a recording only
  /// from a server that sends them). Nothing outside the folder, and only to this computer's own
  /// addresses: a request naming any other host (a site rebinding its name to this computer) is
  /// refused.
  @visibleForTesting
  static Future<HttpServer> serve(String folder) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final response = request.response;
      try {
        await _answer(request, folder);
      } catch (_) {
        // The browser went away mid-file, or the folder was exported again: it asks again.
        try {
          await response.close();
        } catch (_) {}
      }
    });
    return server;
  }

  static Future<void> _answer(HttpRequest request, String folder) async {
    final response = request.response;
    Future<void> refuse(int status) {
      response.statusCode = status;
      return response.close();
    }

    if (!const {'localhost', '127.0.0.1'}.contains(request.headers.host)) return refuse(HttpStatus.forbidden);
    final segments = [...request.uri.pathSegments];
    if (segments.isEmpty || segments.last.isEmpty) segments.add('index.html');
    final file = File([folder, ...segments.where((s) => s.isNotEmpty)].join(Platform.pathSeparator));
    if (request.method != 'GET' || segments.any((s) => s == '..' || s.contains(RegExp(r'[/\\]'))) || !file.existsSync()) {
      return refuse(HttpStatus.notFound);
    }
    final length = file.lengthSync();
    var (start, end) = (0, length);
    final range = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(request.headers.value(HttpHeaders.rangeHeader) ?? '');
    if (range != null && '${range[1]}${range[2]}'.isNotEmpty) {
      // A number too big to read is past any file.
      final from = range[1]!.isEmpty ? null : int.tryParse(range[1]!) ?? length;
      final to = range[2]!.isEmpty ? null : int.tryParse(range[2]!) ?? length;
      (start, end) = from == null ? (math.max(0, length - to!), length) : (from, math.min(length, (to ?? length - 1) + 1));
      if (start >= end) {
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$length');
        return refuse(HttpStatus.requestedRangeNotSatisfiable);
      }
      response
        ..statusCode = HttpStatus.partialContent
        ..headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-${end - 1}/$length');
    }
    response.headers
      ..contentType = ContentType.parse(_types[segments.last.split('.').last] ?? 'application/octet-stream')
      ..contentLength = end - start
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..set(HttpHeaders.cacheControlHeader, 'no-cache'); // an export again shows at once
    await response.addStream(file.openRead(start, end));
    await response.close();
  }

  static const _types = {
    'html': 'text/html; charset=utf-8',
    'js': 'text/javascript',
    'mjs': 'text/javascript',
    'json': 'application/json',
    'wasm': 'application/wasm',
    'css': 'text/css',
    'png': 'image/png',
    'ico': 'image/x-icon',
    'svg': 'image/svg+xml',
    'ttf': 'font/ttf',
    'otf': 'font/otf',
    'm4a': 'audio/mp4',
  };
}

/// A zip whose entries are all stored: a browser reads them without inflating ([ZipEntries]
/// inflates with dart:io, which a page hasn't got), and a web server compresses what it sends.
class _StoredZip extends ZipEncoder {
  @override
  void add(ArchiveFile entry, {bool autoClose = true, ArchiveCallback? callback, int? level}) =>
      super.add(entry..compression = CompressionType.none, autoClose: autoClose, callback: callback, level: level);
}
