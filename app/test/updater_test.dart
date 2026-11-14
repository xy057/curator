import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:curated_score/updater.dart';
import 'package:flutter_test/flutter_test.dart';

/// A release as GitHub's API gives one.
Map<String, Object?> _release(String tag, {bool prerelease = false, bool draft = false, String body = ''}) => {
      'tag_name': tag,
      'html_url': 'https://github.com/xy057/curator/releases/tag/$tag',
      'prerelease': prerelease,
      'draft': draft,
      'published_at': '2026-11-13T09:30:00Z',
      'body': body,
      'assets': [
        {'name': 'Curator-${tag.substring(1)}-macos.zip', 'browser_download_url': 'https://github.com/d/Curator-${tag.substring(1)}-macos.zip', 'size': 10},
      ],
    };

void main() {
  test("the updater: what a release says is new, the newest of a list, each channel's question, nowhere but GitHub and Downloads", () async {
    // A release says what is new up to the install line, and whether it is a pre-release.
    {
      final release = Release.fromJson(
        _release('v9.0.0',
            prerelease: true, body: '<!-- written by hand -->\r\n## New\r\n- Channels\r\n\r\n${Release.installMarker}\n## Install\nunzip'),
        platform: 'macos',
      )!;
      expect(release.notes, '## New\n- Channels');
      expect(release.prerelease, isTrue);
      expect(release.published, DateTime.utc(2026, 11, 13, 9, 30));
      final plain = Release.fromJson(_release('v9.0.0', body: 'All of it'), platform: 'macos')!;
      expect((plain.notes, plain.prerelease), ('All of it', false), reason: 'no install line: the whole description');
      expect(Release.fromJson({'tag_name': 'v9.0.0', 'body': 7, 'prerelease': 'yes', 'published_at': 'soon'})!.notes, '',
          reason: 'what is no text, flag or date is none');
    }

    // The newest of a list is the highest version that is no draft.
    {
      final list = [
        _release('v9.5.0', draft: true),
        _release('v9.1.0'),
        _release('v9.2.0', prerelease: true, body: 'first'),
        _release('v9.2.0', body: 'second'),
        'nonsense',
        {'tag_name': 'nightly'},
      ];
      final newest = Release.newest(list, platform: 'macos')!;
      expect(('${newest.version}', newest.prerelease, newest.notes), ('9.2.0', true, 'first'));
      expect(Release.newest([_release('v9.5.0', draft: true)]), isNull);
      expect(Release.newest({'tag_name': 'v9.0.0'}), isNull, reason: 'not a list');
    }

    // Each channel asks GitHub its own question; a change of channel drops the answer still on its way.
    {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final asked = <String>[];
      Completer<void>? hold;
      server.listen((request) async {
        asked.add('${request.uri}');
        await hold?.future;
        final latest = request.uri.path.endsWith('/latest');
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(latest ? _release('v8.0.0') : [_release('v9.0.0', prerelease: true, body: 'Try it'), _release('v8.0.0')]));
        await request.response.close();
      });
      final updater = Updater(api: Uri.parse('http://127.0.0.1:${server.port}/repos/x/y/releases'), platform: 'macos');
      addTearDown(updater.dispose);

      expect('${(await updater.check())!.version}', '8.0.0');
      expect(asked.single, '/repos/x/y/releases/latest');
      expect((updater.status as UpdateAvailable).release.prerelease, isFalse);

      updater.channel = UpdateChannel.prerelease;
      expect(updater.status, isA<UpdateIdle>(), reason: 'what the other channel found is forgotten');
      final found = (await updater.check())!;
      expect(asked.last, '/repos/x/y/releases?per_page=20');
      expect(('${found.version}', found.prerelease, found.notes), ('9.0.0', true, 'Try it'));

      // Asked on one channel, answered after the other was chosen.
      hold = Completer();
      final late = updater.check();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      updater.channel = UpdateChannel.release;
      expect(updater.status, isA<UpdateIdle>());
      hold.complete();
      expect(await late, isNull);
      expect(updater.status, isA<UpdateIdle>(), reason: 'the pre-release is not offered on the release channel');
      hold = null;
      expect('${(await updater.check())!.version}', '8.0.0');
    }

    // An answer can't send the download or the page anywhere but GitHub, nor name a file outside Downloads.
    {
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
    }
  });
}
