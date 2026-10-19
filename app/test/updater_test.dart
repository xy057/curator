import 'dart:convert';
import 'dart:io';

import 'package:curated_score/updater.dart';
import 'package:flutter_test/flutter_test.dart';


/// A stand-in for GitHub: the latest-release endpoint and its download.
class _FakeGitHub {
  _FakeGitHub._(this._server);

  static Future<_FakeGitHub> start() async {
    final github = _FakeGitHub._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    github._server.listen(github._answer);
    return github;
  }

  final HttpServer _server;
  String tag = 'v9.0.0';
  int status = HttpStatus.ok;
  final zip = List.generate(200000, (i) => i % 251);

  Uri get api => Uri.parse('http://127.0.0.1:${_server.port}/repos/xy057/curator/releases/latest');
  String get _base => 'http://127.0.0.1:${_server.port}';

  Future<void> _answer(HttpRequest request) async {
    final response = request.response;
    if (request.uri.path.endsWith('/latest')) {
      response.statusCode = status;
      response.write(jsonEncode({
        'tag_name': tag,
        'html_url': '$_base/releases/tag/$tag',
        'assets': [
          {'name': 'Curator-9.0.0-windows.zip', 'browser_download_url': '$_base/dl/win.zip', 'size': 1},
          {
            'name': 'Curator-9.0.0-macos.zip',
            'browser_download_url': '$_base/dl/Curator-9.0.0-macos.zip',
            'size': zip.length,
          },
        ],
      }));
    } else if (request.uri.path.startsWith('/dl/')) {
      for (var i = 0; i < zip.length; i += 50000) {
        response.add(zip.sublist(i, (i + 50000).clamp(0, zip.length)));
        await response.flush();
      }
    } else {
      response.statusCode = HttpStatus.notFound;
    }
    await response.close();
  }

  Future<void> close() => _server.close(force: true);
}

void main() {
  test("an answer can't send the download or the page anywhere but GitHub, nor name a file outside Downloads", () {
    Release? read(String url, {String page = 'https://github.com/xy057/curator/releases/tag/v9.0.0'}) =>
        Release.fromJson({
          'tag_name': 'v9.0.0',
          'html_url': page,
          'assets': [
            {'name': 'Curator-9.0.0-macos.zip', 'browser_download_url': url, 'size': 'big'},
          ],
        }, platform: 'macos');
    for (final url in [
      'http://github.com/a/Curator.zip',
      'https://evil.example/Curator.zip',
      'file:///etc/passwd',
      'https://github.com.evil.example/x.zip',
    ]) {
      expect(read(url)!.download, isNull, reason: url);
    }
    for (final page in ['file:///Applications/Calculator.app', 'javascript:alert(1)', 'https://evil.example/']) {
      expect(read('https://github.com/x.zip', page: page)!.pageUrl, '$repositoryUrl/releases', reason: page);
    }
    expect(read('https://github.com/x.zip')!.downloadSize, isNull, reason: 'a size that is no number');
    for (final name in ['..', '..%2F..%2F.zshrc', '..%5Cevil.zip', 'Curator.app', '.hidden.zip']) {
      expect(read('https://github.com/d/$name')!.fileName, 'Curator-9.0.0-macos.zip', reason: name);
    }
    final local = Release.fromJson({
      'tag_name': 'v9.0.0',
      'assets': [
        {'name': 'Curator-9.0.0-macos.zip', 'browser_download_url': 'http://127.0.0.1:8080/dl/a.zip'},
      ],
    }, platform: 'macos', origin: Uri.parse('http://127.0.0.1:8080/latest'));
    expect(local!.download, isNotNull, reason: 'the server asked');
  });

  group('against GitHub', () {
    late _FakeGitHub github;
    late Directory downloads;
    // Flutter's test binding answers every request with 400; these talk to a real (local) server.
    final testOverrides = HttpOverrides.current;
    setUp(() async {
      HttpOverrides.global = null;
      github = await _FakeGitHub.start();
      downloads = Directory.systemTemp.createTempSync('updater_test');
    });
    tearDown(() async {
      await github.close();
      downloads.deleteSync(recursive: true);
      HttpOverrides.global = testOverrides;
    });

    Updater updater() => Updater(api: github.api, downloads: downloads.path, platform: 'macos');

    test('a newer release is found, with the download for this system', () async {
      final u = updater();
      final release = await u.check();
      expect(u.status, isA<UpdateAvailable>());
      expect(release!.version, const Version(9, 0, 0));
      expect(release.fileName, 'Curator-9.0.0-macos.zip');
    });
  });

}
