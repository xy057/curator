import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:curated_score/app_colors.dart';
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/settings_dialog.dart';
import 'package:curated_score/updater.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_fonts.dart';

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
  test('appVersion is the version in pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(RegExp(r'^version: *([\d.]+)', multiLine: true).firstMatch(pubspec)![1], appVersion);
  });

  test('versions compare number by number', () {
    expect(Version.tryParse('v0.10.0')! > Version.tryParse('0.9.9')!, isTrue);
    expect(Version.tryParse('1.0.0')! > Version.tryParse('v1.0.0')!, isFalse);
    expect(Version.tryParse('v1.2.3-beta'), const Version(1, 2, 3));
    expect(Version.tryParse('nightly'), isNull);
  });

  test('each system finds its own zip, and nothing else', () {
    Map<String, Object> asset(String name) => {'name': name, 'browser_download_url': 'https://x/$name', 'size': 1};
    final json = {
      'tag_name': 'v9.0.0',
      'assets': [
        asset('Curator-9.0.0-macos.zip.sha256'),
        asset('Curator-9.0.0-windows.zip.sha256'),
        asset('Curator-9.0.0-windows.zip'),
        asset('Curator-9.0.0-macos.zip'),
      ],
    };
    expect(Release.fromJson(json, platform: 'macos')!.fileName, 'Curator-9.0.0-macos.zip');
    expect(Release.fromJson(json, platform: 'windows')!.fileName, 'Curator-9.0.0-windows.zip');
    expect(Release.fromJson(json, platform: 'linux')!.download, isNull);
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

    test('the same or an older version, or nothing released, is up to date', () async {
      final u = updater();
      github.tag = 'v$appVersion';
      expect(await u.check(), isNull);
      expect(u.status, isA<UpToDate>());
      github.tag = 'v0.0.1';
      await u.check();
      expect(u.status, isA<UpToDate>());
      github.status = HttpStatus.notFound;
      await u.check();
      expect(u.status, isA<UpToDate>());
    });

    test('a download lands in Downloads, never over a file already there', () async {
      final u = updater();
      final release = (await u.check())!;
      final seen = <double>[];
      u.addListener(() {
        if (u.status case UpdateDownloading(:final progress?)) seen.add(progress);
      });

      await u.download(release);
      final first = (u.status as UpdateDownloaded).path;
      expect(first, '${downloads.path}/Curator-9.0.0-macos.zip');
      expect(File(first).readAsBytesSync(), github.zip);
      expect(seen.last, 1.0);

      await u.download(release);
      expect((u.status as UpdateDownloaded).path, '${downloads.path}/Curator-9.0.0-macos (2).zip');
      expect(downloads.listSync().where((f) => f.path.endsWith('.part')), isEmpty);
    });

    test('no connection is a failure that says so', () async {
      final u = updater();
      await github.close();
      await u.check();
      expect((u.status as UpdateFailed).message, 'No connection to GitHub.');
    });
  });

  testWidgets('Settings ▸ Update shows the version, the changelog and the repository, and checks', (tester) async {
    final settings = AppSettings.memory();
    final updater = Updater(api: Uri.parse('http://127.0.0.1:1/latest'));
    final shots = Platform.environment['SCREENSHOT_DIR'];
    if (shots != null) await tester.runAsync(loadTestFonts);
    tester.view.physicalSize = const Size(2000, 1400);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: AppColors.theme(accent: settings.accent),
      builder: (context, child) => RepaintBoundary(child: child),
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => showSettingsDialog(context, settings, updater: updater, page: 'Update'),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Version $appVersion'), findsOneWidget);
    expect(find.text('github.com/xy057/curator'), findsOneWidget);
    expect(find.text('0x57.cc/xylabs-changelog'), findsOneWidget);
    if (shots != null) {
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(find.byType(RepaintBoundary).first);
        final png = await (await boundary.toImage(pixelRatio: 2)).toByteData(format: ui.ImageByteFormat.png);
        File('$shots/settings-update.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }

    await tester.tap(find.byType(Switch));
    expect(settings.checkForUpdates, isFalse);

    // Nothing listens on port 1 (and widget tests answer every request with 400 anyway).
    await tester.runAsync(() async {
      await tester.tap(find.text('Check for Updates'));
      while (updater.busy) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();
    expect(updater.status, isA<UpdateFailed>());
    expect(find.text((updater.status as UpdateFailed).message), findsOneWidget);
    expect(find.text('Check for Updates'), findsOneWidget, reason: 'it can be tried again');
  });
}
