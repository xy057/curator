import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:score_engine/score_engine.dart' show LilyPondScore;

import 'app_folders.dart';
import 'downloader.dart';
import 'error_text.dart';
import 'l10n/l10n.dart';
import 'project_state.dart';
import 'scratch_space.dart';

/// One of LilyPond's official builds: its file in the release, its size and SHA-256 (the
/// release's own), so what is downloaded is checked before it is unpacked.
class LilyPondPackage {
  const LilyPondPackage(this.file, this.size, this.sha256);
  final String file;
  final int size;
  final String sha256;

  Uri get url => Uri.https('gitlab.com', '/lilypond/lilypond/-/releases/v${LilyPond.version}/downloads/$file');
}

/// A problem LilyPond reported: where (a file of the score's, its line and column, both from 1)
/// when it said, and whether it stopped the score being engraved.
@immutable
class LilyProblem {
  const LilyProblem(this.message, {this.file, this.line, this.column, this.error = false});
  final String message;
  final String? file;
  final int? line, column;
  final bool error;

  @override
  bool operator ==(Object other) =>
      other is LilyProblem &&
      other.message == message &&
      other.file == file &&
      other.line == line &&
      other.column == column &&
      other.error == error;

  @override
  int get hashCode => Object.hash(message, file, line, column, error);
}

/// A LilyPond score's source: its main file's [text], named [name], in [folder] under the
/// score's root, and the files it includes ([files]), each by its path under that root (`/`
/// between folders). The root is the main file's folder, or one above it that an include
/// reaches (`\include "../global.ily"`). [origin]: the folder it was read from, where anything
/// it includes and isn't kept is looked for too; none for a project's.
@immutable
class LilySource {
  const LilySource({required this.name, required this.text, this.folder = '', this.files = const {}, this.origin});
  final String name;
  final String text;
  final String folder;
  final Map<String, Uint8List> files;
  final String? origin;

  /// A project's score: its main file, [name] and [text], with what it keeps ([project]).
  factory LilySource.of(String name, String text, LilyPondProject project) =>
      LilySource(name: name, text: text, folder: project.folder, files: project.files);

  LilySource withText(String text) => LilySource(name: name, text: text, folder: folder, files: files, origin: origin);

  /// The main file's path under the root, as LilyPond's links and problems name it: its name
  /// made safe as a file's (no folders, nothing a system refuses).
  String get path {
    final plain = name.replaceAll(RegExp(r'[/\\:\x00-\x1f]'), '_').trim();
    final file = plain.isEmpty || plain == '.' || plain == '..' ? 'score.ly' : plain;
    return folder.isEmpty ? file : '$folder/$file';
  }

  /// How many folders above the main file's an include may reach.
  static const maxUp = 3;

  /// [path]'s score with the files it includes (`\include "…"`, each found from the folder of
  /// the file that includes it, as LilyPond does, and as far as they go: not on another drive,
  /// nor more than [maxUp] folders up), rooted where the highest of them is.
  static LilySource read(String path) {
    final file = File(path).absolute;
    final origin = file.parent.path;
    final text = utf8.decode(file.readAsBytesSync(), allowMalformed: true);
    // Each file found, by its path from the main file's folder ("parts/flute.ily", "../global.ily").
    final found = <String, Uint8List>{};
    var total = 0;
    var full = false;
    void include(String text, List<String> from) {
      for (final m in _includes.allMatches(_withoutComments(text))) {
        if (full) return;
        final name = m.group(1)!.replaceAll(r'\', '/');
        if (name.startsWith('/') || name.contains(':')) continue; // a path of this computer's: LilyPond's own, or elsewhere
        final segments = _resolved([...from, ...name.split('/')]);
        final up = segments.takeWhile((s) => s == '..').length;
        if (up > maxUp || up == segments.length) continue;
        final relative = segments.join('/');
        if (found.containsKey(relative)) continue;
        final included = File([origin, ...segments].join(Platform.pathSeparator));
        if (!included.existsSync()) continue; // LilyPond's own (english.ly…), or not there
        final bytes = included.readAsBytesSync();
        total += bytes.length;
        if (total > LilyPondProject.maxIncluded || found.length >= LilyPondProject.maxFiles) {
          full = true;
          return;
        }
        found[relative] = bytes;
        include(utf8.decode(bytes, allowMalformed: true), segments.sublist(0, segments.length - 1));
      }
    }

    include(text, const []);
    // The folders between the root and the main file's: as many as the files reach up, while
    // there are folders above it.
    final reach = found.keys.map((k) => k.split('/').takeWhile((s) => s == '..').length).fold(0, (a, b) => a > b ? a : b);
    final above = <String>[];
    for (var dir = Directory(origin); above.length < reach && dir.parent.path != dir.path; dir = dir.parent) {
      above.insert(0, dir.uri.pathSegments.lastWhere((s) => s.isNotEmpty));
    }
    return LilySource(
      name: file.uri.pathSegments.last,
      text: text,
      folder: above.join('/'),
      files: {
        for (final MapEntry(key: relative, value: bytes) in found.entries)
          ?_rooted(relative, above): bytes,
      },
      origin: origin,
    );
  }

  /// [segments] with `.` and `..` taken out where they can be: those left lead (`../..`).
  static List<String> _resolved(List<String> segments) {
    final out = <String>[];
    for (final s in segments) {
      if (s.isEmpty || s == '.') continue;
      if (s == '..' && out.isNotEmpty && out.last != '..') {
        out.removeLast();
      } else {
        out.add(s);
      }
    }
    return out;
  }

  /// [relative] (from the main file's folder) as a path under the root, [above] the folders
  /// between them; null when it reaches higher.
  static String? _rooted(String relative, List<String> above) {
    final segments = relative.split('/');
    final up = segments.takeWhile((s) => s == '..').length;
    if (up > above.length) return null;
    return [...above.take(above.length - up), ...segments.skip(up)].join('/');
  }

  static final _includes = RegExp(r'\\include\s+"([^"]+)"');

  /// [read] on another isolate. Called from a static function, so its closure takes nothing else
  /// along: one made beside code that uses an object's state would take that too, which can't be
  /// sent.
  static Future<LilySource> readApart(String path) => Isolate.run(() => read(path));

  /// [text] without its `%` comments (`%{ … %}` too), so an include commented out isn't kept.
  static String _withoutComments(String text) =>
      text.replaceAll(RegExp(r'%\{[\s\S]*?%\}'), '').replaceAll(RegExp(r'%[^\n]*'), '');
}

/// What a run of LilyPond gave: its SVG and the data file Curator's settings wrote (both null
/// when it engraved nothing), and what it reported.
class LilyPondRun {
  const LilyPondRun({this.svg, this.data, this.problems = const [], this.log = ''});
  final String? svg, data;
  final List<LilyProblem> problems;

  /// Everything it said, as it said it.
  final String log;

  bool get engraved => svg != null && data != null;

  /// What a project keeps of [source] as this run engraved it ([engraved]).
  LilyPondProject keep(LilySource source) => LilyPondProject(
      folder: source.folder, files: source.files, svg: svg!, data: data!, version: LilyPond.version, settings: LilyPond.settingsVersion);
}

/// LilyPond, which engraves a LilyPond project's score: the official build of [version],
/// downloaded from Settings ▸ Download Hub (or when a LilyPond file is opened) into the app's
/// data folder ([folder]).
///
/// A LilyPond file is a program (its Scheme can do anything the user can; LilyPond has no
/// safe mode any more), so a score is engraved as the file says, like running a script.
abstract final class LilyPond {
  static const version = '2.26.0';

  /// The revision of Curator's settings ([settingsAsset]) a project's engraving was made with:
  /// one older than this build's can be engraved again from its source.
  static const settingsVersion = 1;

  /// [svg] and [data] (a run's, or a project's) read as a score on another isolate: a long
  /// score's takes a while. Static, so its closure takes nothing else along ([LilySource.readApart]).
  static Future<LilyPondScore> readScore(String svg, String data) => Isolate.run(() => LilyPondScore.read(svg, data));

  /// This computer's build; null where LilyPond makes none (Linux on Arm). Windows on Arm runs
  /// the x86-64 build.
  static LilyPondPackage? get package => switch (Abi.current()) {
        Abi.macosArm64 => const LilyPondPackage(
            'lilypond-2.26.0-darwin-arm64.tar.gz', 40823655, '18ffc454fef3753c26a015d95a3c232f89b22f052b897c046e0198740a1221be'),
        Abi.macosX64 => const LilyPondPackage(
            'lilypond-2.26.0-darwin-x86_64.tar.gz', 41539857, '6dcbca34b13ad6d4ba3606a0b48edd02688284fcd52e9c00141242df1996a148'),
        Abi.linuxX64 => const LilyPondPackage(
            'lilypond-2.26.0-linux-x86_64.tar.gz', 42590078, 'cd8a097a9f52cb2b9f4e7914774786f203f4fc61fcd299afcbb63c23fa5c6b24'),
        Abi.windowsX64 || Abi.windowsArm64 => const LilyPondPackage(
            'lilypond-2.26.0-mingw-x86_64.zip', 45581453, '14ddddc233b469ef60d4ffc1c7f35520f15ac6b58e38cab458c60bdcc3af650c'),
        _ => null,
      };

  /// Where it is installed: `LilyPond/<version>` in the app's data folder.
  static Directory get folder => debugFolder ?? Directory([AppFolders.data.path, 'LilyPond', version].join(Platform.pathSeparator));

  /// Where a test has it installed, or not, in place of [folder].
  @visibleForTesting
  static Directory? debugFolder;

  /// Its program, when it is installed.
  static File? get executable {
    final file = File([folder.path, 'bin', Platform.isWindows ? 'lilypond.exe' : 'lilypond'].join(Platform.pathSeparator));
    return file.existsSync() ? file : null;
  }

  static bool get installed => debugExecutable != null || executable != null;

  /// A LilyPond to run in place of the installed one (a test's): installed while it is set.
  @visibleForTesting
  static File? debugExecutable;

  /// The file names LilyPond scores have (a score, a file one includes).
  static const extensions = ['ly', 'ily'];

  static bool isLilyPond(String path) => extensions.contains(path.split('.').last.toLowerCase());

  /// Curator's settings for LilyPond (`assets/lilypond/curator.ly`): the piece on one line, its
  /// drawing tagged, what it is written to a data file.
  static const settingsAsset = 'assets/lilypond/curator.ly';

  /// Engraves [source] with Curator's settings; [cancel] stops it. Throws a [StateError] when
  /// LilyPond isn't installed.
  static Future<LilyPondRun> engrave(LilySource source, {DownloadCancel? cancel}) async {
    final program = debugExecutable ?? executable;
    if (program == null) throw StateError('LilyPond is not installed.');
    final work = ScratchSpace.folder('lilypond');
    try {
      String at(String relative) => [work.path, ...relative.split('/')].join(Platform.pathSeparator);
      for (final MapEntry(key: path, value: bytes) in source.files.entries) {
        File(at(path))
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(bytes);
      }
      final main = File(at(source.path))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(source.text);
      final settings = File(at('.curator-settings.ly'))
        ..writeAsStringSync(await rootBundle.loadString(settingsAsset));
      final dataFile = File(at('.curator-data.jsonl'));
      final output = at('.curator-out');
      final origin = source.origin;
      final process = await Process.start(
        program.path,
        [
          '--loglevel=WARN',
          '-dbackend=svg',
          '-fsvg',
          '-dinclude-settings=${settings.path}',
          if (origin != null && Directory(origin).existsSync()) '--include=$origin',
          '-o',
          output,
          main.path,
        ],
        workingDirectory: work.path,
        environment: {'CURATOR_LILYPOND_DATA': dataFile.path},
      );
      cancel?.whenCancelled(process.kill);
      final log = StringBuffer();
      final out = process.stdout.transform(utf8.decoder).forEach(log.write);
      final err = process.stderr.transform(utf8.decoder).forEach(log.write);
      final code = await process.exitCode;
      await Future.wait([out, err]);
      if (cancel?.cancelled ?? false) throw const DownloadException(DownloadProblem.cancelled);
      final text = log.toString();
      final problems = parseProblems(text, workPath: work.path);
      final svg = _page(output);
      final data = dataFile.existsSync() ? dataFile.readAsStringSync() : null;
      if (code != 0 && problems.every((p) => !p.error)) {
        problems.add(LilyProblem(text.trim().split('\n').lastOrNull ?? 'LilyPond stopped.', error: true));
      }
      return LilyPondRun(
        svg: svg == null || data == null ? null : relativeLinks(svg, work.path),
        data: svg == null ? null : data,
        problems: problems,
        log: text.replaceAll('${work.path}${Platform.pathSeparator}', ''),
      );
    } finally {
      ScratchSpace.release(work);
    }
  }

  /// The page LilyPond drew the score on: `<output>.svg`, or of several pages (a book with a
  /// title page) the first with anything Curator's settings tagged.
  static String? _page(String output) {
    final single = File('$output.svg');
    if (single.existsSync()) return single.readAsStringSync();
    for (var n = 1; n < 1000; n++) {
      final page = File('$output-$n.svg');
      if (!page.existsSync()) return null;
      final svg = page.readAsStringSync();
      if (svg.contains('data-c=')) return svg;
    }
    return null;
  }

  /// [svg] with its point-and-click links naming each file by its path in the score's folder
  /// ([workPath]'s), not where it was engraved: what the editor finds them by, and no path of
  /// this computer's saved in a project.
  @visibleForTesting
  static String relativeLinks(String svg, String workPath) {
    final prefix = workPath.replaceAll(r'\', '/');
    final forms = {
      for (final p in [prefix, '/$prefix']) ...{p, _percentEncoded(p)},
    }.where((p) => !p.startsWith('//')).toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    var out = svg;
    for (final p in forms) {
      out = out.replaceAll('textedit://$p/', 'textedit://');
    }
    // A file found through `..` is named so (`score/../global.ily`): named as it is.
    return out.replaceAllMapped(RegExp(r'textedit://([^":]+)'), (m) => 'textedit://${_normalized(m[1]!)}');
  }

  /// [path] with its `.` and `..` folders taken out where they can be (a leading `/` kept).
  static String _normalized(String path) {
    if (!path.contains('.')) return path;
    final out = <String>[];
    for (final s in path.split('/')) {
      if (s.isEmpty || s == '.') continue;
      if (s == '..' && out.isNotEmpty && out.last != '..') {
        out.removeLast();
      } else {
        out.add(s);
      }
    }
    return '${path.startsWith('/') ? '/' : ''}${out.join('/')}';
  }

  /// [path] as LilyPond writes it in a link: every byte but letters, digits, `-._~` and `/`
  /// as `%XX`.
  static String _percentEncoded(String path) {
    final out = StringBuffer();
    for (final b in utf8.encode(path)) {
      final c = String.fromCharCode(b);
      out.write(RegExp(r'[A-Za-z0-9\-._~/]').hasMatch(c) ? c : '%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
    return out.toString();
  }

  /// The problems in what LilyPond said ([log]): `file:line:column: error: message` and the
  /// like (a file in [workPath] named by its path there).
  @visibleForTesting
  static List<LilyProblem> parseProblems(String log, {String? workPath}) {
    final out = <LilyProblem>[];
    final located = RegExp(r'^(.+?):(\d+):(\d+): (warning|error|fatal error|programming error): (.*)$');
    final plain = RegExp(r'^(warning|error|fatal error|programming error): (.*)$');
    for (final line in const LineSplitter().convert(log)) {
      if (located.firstMatch(line) case final m?) {
        var file = m.group(1)!;
        if (workPath != null && file.startsWith(workPath)) {
          file = _normalized(file.substring(workPath.length).replaceAll(r'\', '/').replaceFirst(RegExp(r'^/+'), ''));
        }
        out.add(LilyProblem(m.group(5)!.trim(),
            file: file, line: int.parse(m.group(2)!), column: int.parse(m.group(3)!), error: m.group(4) != 'warning'));
      } else if (plain.firstMatch(line) case final m?) {
        out.add(LilyProblem(m.group(2)!.trim(), error: m.group(1) != 'warning'));
      }
    }
    return out;
  }
}

/// What to tell the user about LilyPond's failed download ([LilyPondInstaller.failure]).
String describeLilyPondFailure(Object? failure) => switch (failure) {
      DownloadException(problem: DownloadProblem.network) => 'Can’t reach GitLab. Is the internet connected?'.tr,
      DownloadException(problem: DownloadProblem.disk) => 'Couldn’t write the download.'.tr,
      DownloadException(problem: DownloadProblem.corrupt || DownloadProblem.tooBig) => 'The download was damaged. Try again.'.tr,
      DownloadException(problem: DownloadProblem.status, :final status) => 'GitLab answered {status}.'.fill({'status': '${status ?? ''}'}),
      UnsupportedError() => 'Not available for this computer.'.tr,
      final FileSystemException e => describeError(e),
      _ => 'Couldn’t download LilyPond.'.tr,
    };

/// Where downloading LilyPond has got ([LilyPondInstaller.stage]).
enum LilyPondStage { idle, downloading, unpacking, failed }

/// Downloads LilyPond and unpacks it into place ([LilyPond.folder]), one install at a time,
/// for everything that shows it (Settings ▸ Download Hub, the prompt when a LilyPond file is
/// opened); or removes it.
class LilyPondInstaller extends ChangeNotifier {
  LilyPondInstaller._();
  static final instance = LilyPondInstaller._();

  LilyPondStage get stage => _stage;
  LilyPondStage _stage = LilyPondStage.idle;

  /// Bytes downloaded so far, of [total].
  int get received => _received;
  int _received = 0;
  int get total => LilyPond.package?.size ?? 0;

  /// Why the last install failed ([stage] failed).
  Object? get failure => _failure;
  Object? _failure;

  bool get busy => _stage == LilyPondStage.downloading || _stage == LilyPondStage.unpacking;

  DownloadCancel? _cancel;
  Future<bool>? _running;

  /// Downloads and installs it (the same install while one is under way); true once it is
  /// installed.
  Future<bool> install() => _running ??= _install().whenComplete(() => _running = null);

  void cancel() => _cancel?.cancel();

  Future<bool> _install() async {
    if (LilyPond.installed) return true;
    final package = LilyPond.package;
    if (package == null) {
      _set(LilyPondStage.failed, failure: UnsupportedError('LilyPond has no build for this computer.'));
      return false;
    }
    final cancel = _cancel = DownloadCancel();
    _received = 0;
    _set(LilyPondStage.downloading);
    final downloads = AppFolders.folder('Downloads', cached: true);
    final archive = File('${downloads.path}${Platform.pathSeparator}${package.file}');
    try {
      await Downloader().fetch(HttpsSource(package.url), archive,
          sha256: package.sha256, size: package.size, maxBytes: package.size, cancel: cancel, onProgress: (received, _) {
        _received = received;
        notifyListeners();
      });
      if (cancel.cancelled) throw const DownloadException(DownloadProblem.cancelled);
      _set(LilyPondStage.unpacking);
      await unpack(archive, LilyPond.folder);
      ScratchSpace.release(archive); // installed: the download isn't needed
      _set(LilyPondStage.idle);
      return LilyPond.installed;
    } on DownloadException catch (e) {
      _set(e.problem == DownloadProblem.cancelled ? LilyPondStage.idle : LilyPondStage.failed, failure: e);
      return false;
    } on Exception catch (e) {
      _set(LilyPondStage.failed, failure: e);
      return false;
    } finally {
      _cancel = null;
    }
  }

  /// Unpacks [archive] (the release's, its files in `lilypond-<version>/`) into [into], whole or
  /// not at all: into a folder beside it, then renamed into place. The system's tar reads both
  /// a .tar.gz and a .zip (Windows 10's too), keeping the files' modes and links.
  @visibleForTesting
  static Future<void> unpack(File archive, Directory into) async {
    final parent = into.parent..createSync(recursive: true);
    final temp = Directory('${parent.path}${Platform.pathSeparator}.unpacking-${DateTime.now().microsecondsSinceEpoch}');
    try {
      temp.createSync();
      final result = await Process.run('tar', ['-xf', archive.path, '-C', temp.path]);
      if (result.exitCode != 0) throw FileSystemException('Couldn’t unpack LilyPond: ${result.stderr}'.trim(), archive.path);
      final top = Directory('${temp.path}${Platform.pathSeparator}lilypond-${LilyPond.version}');
      if (!top.existsSync()) throw FileSystemException('LilyPond’s download holds no lilypond-${LilyPond.version}', archive.path);
      if (into.existsSync()) into.deleteSync(recursive: true);
      top.renameSync(into.path);
    } finally {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    }
  }

  /// Removes the installed LilyPond.
  Future<void> remove() async {
    if (busy) return;
    final folder = LilyPond.folder;
    if (folder.existsSync()) await folder.delete(recursive: true);
    _set(LilyPondStage.idle);
  }

  void _set(LilyPondStage stage, {Object? failure}) {
    _stage = stage;
    _failure = failure;
    notifyListeners();
  }
}
