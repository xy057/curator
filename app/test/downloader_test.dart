import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:curated_score/app_folders.dart';
import 'package:curated_score/downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test("the app's folders on each system, and a download fetched through its redirect, resumed, checked and pinned, or refused", () async {
    // Each system's own folders for the app's data and cache.
    {
      const temp = '/tmp';
      final cases = {
        ('macos', {'HOME': '/Users/a'}): ('/Users/a/Library/Application Support/Curator', '/Users/a/Library/Caches/Curator'),
        ('windows', {'LocalAppData': r'C:\Users\a\AppData\Local'}): (r'C:\Users\a\AppData\Local\Curator', r'C:\Users\a\AppData\Local\Curator\Cache'),
        ('windows', {'USERPROFILE': 'D:\\'}): (r'D:\AppData\Local\Curator', r'D:\AppData\Local\Curator\Cache'),
        ('linux', {'HOME': '/home/a'}): ('/home/a/.local/share/curator', '/home/a/.cache/curator'),
        ('linux', {'HOME': '/home/a', 'XDG_DATA_HOME': '/d/', 'XDG_CACHE_HOME': 'relative'}): ('/d/curator', '/home/a/.cache/curator'),
      };
      for (final MapEntry(key: (os, env), value: (data, cache)) in cases.entries) {
        expect((AppFolders.dataFor(os, env, temp), AppFolders.cacheFor(os, env, temp)), (data, cache), reason: '$os $env');
      }
      for (final name in ['', '..', 'a/b', r'a\b', 'C:', ' x']) {
        expect(AppFolders.isPlainName(name), isFalse, reason: name);
      }
    }

    // A Xet file is fetched through its redirect, resumed, checked and pinned; plain http, a wrong hash, too many bytes refused.
    {
      final content = Uint8List.fromList(List.generate(300000, (i) => (i * 7 + i ~/ 256) & 0xff));
      final hash = '${crypto.sha256.convert(content)}';
      const commit = '0123456789abcdef0123456789abcdef01234567';
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final cdn = 'http://127.0.0.1:${server.port}'; // another origin than the hub's `localhost`
      final seen = <String, (String?, String?)>{}; // path: (authorization, range)
      server.listen((request) async {
        final r = request.response;
        final path = request.uri.path;
        seen[path] = (request.headers.value('authorization'), request.headers.value('range'));
        if (path == '/owner/repo/resolve/main/dir/file.bin') {
          r.statusCode = HttpStatus.found;
          r.headers
            ..set('location', '$cdn/cdn/file?signed=1')
            ..set('x-linked-etag', '"$hash"')
            ..set('x-linked-size', '${content.length}')
            ..set('x-repo-commit', commit);
        } else if (path == '/cdn/file' || path == '/cdn/bad') {
          final body = path == '/cdn/bad' ? Uint8List.fromList(content.reversed.toList()) : content;
          final from = int.tryParse(RegExp(r'bytes=(\d+)-').firstMatch(request.headers.value('range') ?? '')?[1] ?? '');
          if (from != null) {
            r.statusCode = HttpStatus.partialContent;
            r.headers.set('content-range', 'bytes $from-${body.length - 1}/${body.length}');
          }
          r.contentLength = body.length - (from ?? 0);
          r.add(body.sublist(from ?? 0));
        } else if (path == '/to-http') {
          r.statusCode = HttpStatus.found;
          r.headers.set('location', 'http://example.com/file');
        } else {
          r.statusCode = HttpStatus.notFound;
        }
        await r.close();
      });

      final dir = await Directory.systemTemp.createTemp('downloader_test');
      addTearDown(() => dir.delete(recursive: true));
      final target = File('${dir.path}/sub/file.bin');
      Directory('${dir.path}/sub').createSync();
      File('${target.path}.part').writeAsBytesSync(content.sublist(0, 100000)); // a download that stopped
      final downloader = Downloader(allowLoopbackHttp: true);
      final source = XetSource('owner/repo', 'dir/file.bin', endpoint: Uri.parse('http://localhost:${server.port}'));
      Future<T> network<T>(Future<T> Function() body) => HttpOverrides.runWithHttpOverrides(body, _Network());

      final progress = <int>[];
      final got = await network(() => downloader.fetch(source, target, token: 'secret', onProgress: (n, total) {
            expect(total, content.length);
            progress.add(n);
          }));
      expect((got.sha256, got.size, got.revision, got.fetched), (hash, content.length, commit, true));
      expect(target.readAsBytesSync(), content);
      expect(File('${target.path}.part').existsSync(), isFalse);
      expect(progress.first, 100000, reason: 'carried on from the part');
      expect(seen['/owner/repo/resolve/main/dir/file.bin'], ('Bearer secret', null));
      expect(seen['/cdn/file'], (null, 'bytes=100000-'), reason: 'the token stays with the hub');

      seen.clear();
      final again = await network(() => downloader.fetch(source, target, sha256: hash));
      expect(again.fetched, isFalse);
      expect(seen, isEmpty, reason: 'nothing asked: the file was there with its hash');

      Future<DownloadProblem?> problem(DownloadSource s, {String? sha256, int maxBytes = 1 << 30}) async {
        final file = File('${dir.path}/other.bin');
        try {
          await network(() => downloader.fetch(s, file, sha256: sha256, maxBytes: maxBytes));
          return null;
        } on DownloadException catch (e) {
          expect((file.existsSync(), File('${file.path}.part').existsSync()), (false, false), reason: '$e');
          return e.problem;
        }
      }

      expect(await problem(HttpsSource(Uri.parse('$cdn/cdn/bad')), sha256: hash), DownloadProblem.corrupt);
      expect(await problem(HttpsSource(Uri.parse('$cdn/cdn/file')), maxBytes: 1000), DownloadProblem.tooBig);
      expect(await problem(HttpsSource(Uri.parse('$cdn/to-http'))), DownloadProblem.insecure);
      expect(await problem(HttpsSource(Uri.parse('$cdn/missing'))), DownloadProblem.status);
      expect(await problem(HttpsSource(Uri.parse('http://example.com/file'))), DownloadProblem.insecure);

      expect('${XetSource('openai-community/gpt2', 'onnx/model.onnx', kind: XetRepoKind.dataset).url}',
          'https://huggingface.co/datasets/openai-community/gpt2/resolve/main/onnx/model.onnx');
      for (final (repo, path) in [('../x', 'a'), ('a', 'b'), ('a/b', '../c'), ('a/b', 'c//d')]) {
        expect(() => XetSource(repo, path), throwsArgumentError, reason: '$repo $path');
      }
    }
  });
}

class _Network extends HttpOverrides {}
