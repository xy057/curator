import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// This build's version: `version` in pubspec.yaml without the build number (a test keeps them
/// equal). The Release workflow tags each release `v` + this.
const appVersion = '0.1.2';

/// Where the source and the releases live.
const repositoryUrl = 'https://github.com/xy057/curator';

/// A released version: `v1.2.3` or `1.2.3`, compared number by number.
@immutable
class Version implements Comparable<Version> {
  const Version(this.major, this.minor, this.patch);

  /// Null when [text] isn't major.minor.patch (a suffix such as `-beta` is ignored).
  static Version? tryParse(String text) {
    final m = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)').firstMatch(text.trim());
    if (m == null) return null;
    return Version(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
  }

  static final current = tryParse(appVersion)!;

  final int major, minor, patch;

  @override
  int compareTo(Version other) => switch ((major - other.major, minor - other.minor, patch - other.patch)) {
        (final d, _, _) when d != 0 => d,
        (_, final d, _) when d != 0 => d,
        (_, _, final d) => d,
      };

  bool operator >(Version other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) => other is Version && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch);

  @override
  String toString() => '$major.$minor.$patch';
}

/// The newest release on GitHub, and its download for this platform (null when it has none).
@immutable
class Release {
  const Release({required this.version, required this.pageUrl, this.download, this.downloadSize});

  /// Reads a GitHub API release (`GET /repos/…/releases/latest`); null when it has no version.
  static Release? fromJson(Object? json, {String platform = ''}) {
    if (json is! Map) return null;
    final version = Version.tryParse('${json['tag_name']}');
    if (version == null) return null;
    final assets = [for (final a in json['assets'] as List? ?? const []) if (a is Map) a];
    // The workflow names downloads `Curator-<version>-<platform>.zip`.
    final asset = assets.where((a) => '${a['name']}'.contains('-$platform.')).firstOrNull;
    return Release(
      version: version,
      pageUrl: '${json['html_url'] ?? '$repositoryUrl/releases'}',
      download: asset == null ? null : Uri.tryParse('${asset['browser_download_url']}'),
      downloadSize: asset?['size'] as int?,
    );
  }

  final Version version;
  final String pageUrl;
  final Uri? download;
  final int? downloadSize;

  String get fileName => download?.pathSegments.last ?? 'Curator-$version.zip';
}

/// Where an update check or download has got to.
sealed class UpdateStatus {
  const UpdateStatus();
}

class UpdateIdle extends UpdateStatus {
  const UpdateIdle();
}

class UpdateChecking extends UpdateStatus {
  const UpdateChecking();
}

class UpToDate extends UpdateStatus {
  const UpToDate();
}

class UpdateAvailable extends UpdateStatus {
  const UpdateAvailable(this.release);
  final Release release;
}

class UpdateDownloading extends UpdateStatus {
  const UpdateDownloading(this.release, this.progress);
  final Release release;

  /// 0…1, or null while the size isn't known.
  final double? progress;
}

class UpdateDownloaded extends UpdateStatus {
  const UpdateDownloaded(this.release, this.path);
  final Release release;
  final String path;
}

class UpdateFailed extends UpdateStatus {
  const UpdateFailed(this.message, {this.release});
  final String message;

  /// What was being downloaded, so it can be tried again.
  final Release? release;
}

/// Settings ▸ Update: asks GitHub for the latest release and downloads it to the Downloads
/// folder. It never replaces the running app; the user unzips what it downloaded.
class Updater extends ChangeNotifier {
  Updater({Uri? api, this._downloads, String? platform})
      : api = api ?? Uri.parse('https://api.github.com/repos/xy057/curator/releases/latest'),
        platform = platform ?? Platform.operatingSystem;

  /// The latest-release endpoint (a local server in tests).
  final Uri api;
  final String? _downloads;

  /// Which download is this platform's: `macos`, `windows` or `linux`.
  final String platform;

  UpdateStatus get status => _status;
  UpdateStatus _status = const UpdateIdle();
  set _set(UpdateStatus value) {
    _status = value;
    notifyListeners();
  }

  bool get busy => _status is UpdateChecking || _status is UpdateDownloading;

  static const _timeout = Duration(seconds: 20);

  HttpClient _client() => HttpClient()
    ..connectionTimeout = _timeout
    ..userAgent = 'Curator/$appVersion';

  /// Asks GitHub for the latest release. Returns it when it is newer than this build.
  Future<Release?> check() async {
    if (busy) return null;
    _set = const UpdateChecking();
    final client = _client();
    try {
      final request = await client.getUrl(api).timeout(_timeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final response = await request.close().timeout(_timeout);
      final body = await response.transform(utf8.decoder).join().timeout(_timeout);
      if (response.statusCode == HttpStatus.notFound) {
        _set = const UpToDate(); // nothing released yet
        return null;
      }
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('GitHub answered ${response.statusCode}');
      }
      final release = Release.fromJson(jsonDecode(body), platform: platform);
      if (release == null) throw const FormatException('The latest release has no version');
      if (release.version > Version.current) {
        _set = UpdateAvailable(release);
        return release;
      }
      _set = const UpToDate();
    } catch (e) {
      _set = UpdateFailed(_describe(e));
    } finally {
      client.close(force: true);
    }
    return null;
  }

  /// Downloads [release] into the Downloads folder (never over a file already there).
  Future<void> download(Release release) async {
    final url = release.download;
    if (url == null || busy) return;
    _set = UpdateDownloading(release, 0);
    final client = _client();
    File? part;
    try {
      final response = await (await client.getUrl(url).timeout(_timeout)).close().timeout(_timeout);
      if (response.statusCode != HttpStatus.ok) throw HttpException('GitHub answered ${response.statusCode}');
      final total = response.contentLength > 0 ? response.contentLength : release.downloadSize;
      final target = _freeName(downloadsFolder, release.fileName);
      part = File('$target.part');
      final sink = part.openWrite();
      var received = 0;
      try {
        await for (final chunk in response.timeout(_timeout)) {
          sink.add(chunk);
          received += chunk.length;
          _set = UpdateDownloading(release, total == null ? null : (received / total).clamp(0.0, 1.0));
        }
      } finally {
        await sink.close();
      }
      await part.rename(target);
      _set = UpdateDownloaded(release, target);
    } catch (e) {
      try {
        if (part != null && part.existsSync()) part.deleteSync();
      } on FileSystemException {
        // leave it; it is plainly a leftover
      }
      _set = UpdateFailed(_describe(e), release: release);
    } finally {
      client.close(force: true);
    }
  }

  /// The user's Downloads folder (their home folder when it has none).
  String get downloadsFolder {
    if (_downloads case final dir?) return dir;
    final home = Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'] ?? Directory.systemTemp.path;
    final downloads = '$home${Platform.pathSeparator}Downloads';
    return Directory(downloads).existsSync() ? downloads : home;
  }

  /// `name`, or `name (2)`, `name (3)`… when that is taken.
  static String _freeName(String dir, String name) {
    final dot = name.lastIndexOf('.');
    final (stem, ext) = dot > 0 ? (name.substring(0, dot), name.substring(dot)) : (name, '');
    for (var n = 1;; n++) {
      final path = '$dir${Platform.pathSeparator}${n == 1 ? name : '$stem ($n)$ext'}';
      if (!File(path).existsSync() && !File('$path.part').existsSync()) return path;
    }
  }

  static String _describe(Object e) => switch (e) {
        SocketException() || HandshakeException() => 'No connection to GitHub.',
        TimeoutException() => 'GitHub didn’t answer in time.',
        HttpException(:final message) => '$message.',
        FileSystemException(:final path) => 'Couldn’t write ${path ?? 'the download'}.',
        _ => 'Couldn’t read GitHub’s answer.',
      };
}

/// Opens [url] in the default browser.
Future<void> openInBrowser(String url) async {
  try {
    if (Platform.isMacOS) {
      await Process.run('open', [url]);
    } else if (Platform.isWindows) {
      await Process.run('rundll32', ['url.dll,FileProtocolHandler', url]);
    } else {
      await Process.run('xdg-open', [url]);
    }
  } on ProcessException {
    // no browser to open: the address is shown beside the button
  }
}
