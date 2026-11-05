import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';

import 'updater.dart' show appVersion;

/// Where a download comes from: a plain https address ([HttpsSource]), or a file in a
/// Git Xet repository on Hugging Face ([XetSource]).
sealed class DownloadSource {
  const DownloadSource();

  /// The first address asked.
  Uri get url;
}

/// A file at an https address.
class HttpsSource extends DownloadSource {
  HttpsSource(this.url);

  @override
  final Uri url;
}

/// What kind of Hugging Face repository a [XetSource] is in.
enum XetRepoKind {
  model(''),
  dataset('datasets'),
  space('spaces');

  const XetRepoKind(this.prefix);
  final String prefix;
}

/// A file in a Git Xet (or Git LFS) repository on Hugging Face, fetched over https the way
/// `git xet` / `huggingface_hub` do: `<endpoint>/<repo>/resolve/<revision>/<path>`. That answer
/// is a redirect to the Xet bridge (a CDN), which serves the whole file and byte ranges of it;
/// the redirect itself names the file's SHA-256 (`X-Linked-Etag`), its size (`X-Linked-Size`)
/// and the commit [revision] resolved to (`X-Repo-Commit`), so a download checks itself even
/// without a hash given, and can be resumed.
class XetSource extends DownloadSource {
  /// [repo] is `owner/name`; [path] the file's path in it (`/`-separated); [revision] a
  /// branch, tag or commit (a commit hash never changes what it names: use one to pin).
  XetSource(this.repo, this.path, {this.revision = 'main', this.kind = XetRepoKind.model, Uri? endpoint})
      : endpoint = endpoint ?? Uri.https('huggingface.co') {
    if (!RegExp(r'^[\w.-]+/[\w.-]+$').hasMatch(repo) || repo.split('/').any((p) => p == '.' || p == '..')) {
      throw ArgumentError.value(repo, 'repo', 'not owner/name');
    }
    if (_segments(path).isEmpty || _segments(path).any((p) => p.isEmpty || p == '.' || p == '..')) {
      throw ArgumentError.value(path, 'path', 'not a file path in the repository');
    }
    if (revision.isEmpty || revision.split('/').any((p) => p.isEmpty || p == '.' || p == '..')) {
      throw ArgumentError.value(revision, 'revision');
    }
  }

  final String repo, path, revision;
  final XetRepoKind kind;

  /// The Hub (`https://huggingface.co`, or a mirror's address).
  final Uri endpoint;

  static List<String> _segments(String path) => path.split('/');

  @override
  Uri get url => endpoint.replace(pathSegments: [
        ...endpoint.pathSegments.where((s) => s.isNotEmpty),
        if (kind.prefix.isNotEmpty) kind.prefix,
        ...repo.split('/'),
        'resolve',
        revision, // a branch named `a/b` is one segment, its slash escaped, as the Hub expects
        ..._segments(path),
      ]);
}

/// Why a download failed.
enum DownloadProblem {
  /// No connection, or the server stopped answering.
  network,

  /// An address that isn't https (a redirect to plain http too), or too many redirects.
  insecure,

  /// The server answered with an error ([DownloadException.status]).
  status,

  /// More bytes than allowed, or than the file was said to have.
  tooBig,

  /// The bytes received aren't the file (size or SHA-256 differ). Nothing is kept.
  corrupt,

  /// Another download is writing the same file.
  busy,

  /// [DownloadCancel.cancel] was called. What arrived is kept, to resume from.
  cancelled,

  /// The file couldn't be written.
  disk,
}

class DownloadException implements Exception {
  const DownloadException(this.problem, [this.detail, this.status]);
  final DownloadProblem problem;
  final String? detail;

  /// The HTTP status, for [DownloadProblem.status].
  final int? status;

  @override
  String toString() => 'DownloadException(${problem.name}${status == null ? '' : ' $status'}${detail == null ? '' : ': $detail'})';
}

/// Stops a download under way ([Downloader.fetch]'s `cancel`).
class DownloadCancel {
  bool get cancelled => _cancelled;
  var _cancelled = false;
  final _listeners = <void Function()>[];

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }
}

/// What [Downloader.fetch] wrote.
class Downloaded {
  const Downloaded(this.file, {required this.sha256, required this.size, this.revision, this.fetched = true});
  final File file;

  /// The file's SHA-256, in lowercase hex.
  final String sha256;
  final int size;

  /// The commit a [XetSource]'s revision resolved to (to pin it next time).
  final String? revision;

  /// False when the file was already there with the hash asked for.
  final bool fetched;
}

/// Downloads one file at a time over https, into a file of the caller's choosing (e.g. in
/// `AppFolders.folder(…)`): written as `<file>.part`, locked while it is written, checked
/// (size, SHA-256) and only then renamed into place, so a file of that name is always whole.
/// A download that stops (a lost connection, [DownloadCancel]) keeps its part, and the next
/// one for the same file carries on from there when the file's hash is known (given, or
/// named by a [XetSource]): what doesn't add up to it is thrown away.
///
/// Redirects are followed by hand, https only; a [token] goes only to the source's own host,
/// never to where it redirects (the CDN's addresses carry their own signature).
class Downloader {
  Downloader({
    String? userAgent,
    this.timeout = const Duration(seconds: 30),
    this.maxRedirects = 5,
    @visibleForTesting this.allowLoopbackHttp = false,
  }) : userAgent = userAgent ?? 'Curator/$appVersion';

  final String userAgent;

  /// How long connecting, and each wait for more bytes, may take.
  final Duration timeout;
  final int maxRedirects;

  /// Tests serve on the loopback address over plain http.
  final bool allowLoopbackHttp;

  /// Fetches [source] into [target]. [sha256] (hex) and [size], when known, are checked;
  /// a [target] already there with that [sha256] is kept, not fetched again. [maxBytes] caps
  /// what is written whatever the server says. [token] is a bearer token (a private or gated
  /// Hugging Face repository). [onProgress] hears the bytes so far and the total, when known.
  Future<Downloaded> fetch(
    DownloadSource source,
    File target, {
    String? sha256,
    int? size,
    int maxBytes = 16 << 30,
    String? token,
    void Function(int received, int? total)? onProgress,
    DownloadCancel? cancel,
  }) async {
    String? expectedHash = sha256 == null ? null : _hash(sha256);
    if (sha256 != null && expectedHash == null) throw ArgumentError.value(sha256, 'sha256', 'not 64 hex digits');
    if (expectedHash != null && target.existsSync()) {
      final have = await _hashOf(target);
      if (have == expectedHash) return Downloaded(target, sha256: have, size: target.lengthSync(), fetched: false);
    }
    if (cancel?.cancelled ?? false) throw const DownloadException(DownloadProblem.cancelled);

    final part = File('${target.path}.part');
    RandomAccessFile file;
    try {
      target.parent.createSync(recursive: true);
      file = part.openSync(mode: FileMode.append);
    } on FileSystemException catch (e) {
      throw DownloadException(DownloadProblem.disk, e.message);
    }
    try {
      file.lockSync(FileLock.exclusive); // throws while another download holds it
    } on FileSystemException {
      file.closeSync();
      throw const DownloadException(DownloadProblem.busy);
    }

    final client = HttpClient()
      ..connectionTimeout = timeout
      ..autoUncompress = false // the bytes as stored: what the hash and ranges are of
      ..userAgent = userAgent;
    void abort() => client.close(force: true);
    cancel?._listeners.add(abort);
    var keepPart = true, open = true;
    try {
      var expectedSize = size;
      String? revision;
      var have = file.lengthSync();
      var uri = source.url;
      var restarted = false;
      HttpClientResponse response;
      for (var hops = 0;; hops++) {
        if (hops > maxRedirects) throw const DownloadException(DownloadProblem.insecure, 'too many redirects');
        _checkSecure(uri);
        // A part is only worth keeping when the hash will tell whether it joins up.
        final from = expectedHash != null && have > 0 && (expectedSize == null || have < expectedSize) ? have : 0;
        final request = await client.getUrl(uri).timeout(timeout);
        request
          ..followRedirects = false
          ..headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        if (token != null && _sameOrigin(uri, source.url)) request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        if (from > 0) request.headers.set(HttpHeaders.rangeHeader, 'bytes=$from-');
        response = await request.close().timeout(timeout);

        if (source is XetSource && _sameOrigin(uri, source.url)) {
          revision ??= response.headers.value('x-repo-commit');
          final linked = _hash(response.headers.value('x-linked-etag'));
          if (linked != null) {
            if (expectedHash != null && linked != expectedHash) {
              throw DownloadException(DownloadProblem.corrupt, 'the repository has another file ($linked)');
            }
            expectedHash = linked;
          }
          expectedSize ??= int.tryParse(response.headers.value('x-linked-size') ?? '');
        }
        if (response.isRedirect) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          await _drain(response);
          if (location == null) throw DownloadException(DownloadProblem.status, 'a redirect to nowhere', response.statusCode);
          uri = uri.resolve(location);
          continue;
        }
        if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable && from > 0 && !restarted) {
          await _drain(response);
          have = 0; // the part is no prefix of this file: start over, once
          file.truncateSync(0);
          restarted = true;
          hops = -1;
          uri = source.url;
          continue;
        }
        if (response.statusCode == HttpStatus.partialContent && from > 0) {
          final start = RegExp(r'^bytes (\d+)-').firstMatch(response.headers.value(HttpHeaders.contentRangeHeader) ?? '')?[1];
          if (int.tryParse(start ?? '') != from) {
            await _drain(response);
            throw const DownloadException(DownloadProblem.status, 'a range other than the one asked');
          }
        } else if (response.statusCode == HttpStatus.ok) {
          have = 0; // the whole file, from the start (the server ignored the range)
        } else {
          await _drain(response);
          throw DownloadException(DownloadProblem.status, response.reasonPhrase, response.statusCode);
        }
        break;
      }

      final length = response.contentLength;
      final total = expectedSize ?? (length >= 0 ? have + length : null);
      if (total != null && total > maxBytes) {
        keepPart = false;
        throw DownloadException(DownloadProblem.tooBig, '$total bytes');
      }
      file
        ..truncateSync(have)
        ..setPositionSync(have);
      onProgress?.call(have, total);
      try {
        await for (final chunk in response.timeout(timeout)) {
          have += chunk.length;
          if (have > maxBytes || (expectedSize != null && have > expectedSize)) {
            keepPart = false;
            throw DownloadException(DownloadProblem.tooBig, '$have bytes or more');
          }
          await file.writeFrom(chunk);
          onProgress?.call(have, total);
        }
      } on DownloadException {
        rethrow;
      } on FileSystemException {
        rethrow;
      } catch (e) {
        throw _failure(e, cancel); // a lost connection, a timeout
      }
      if (cancel?.cancelled ?? false) throw const DownloadException(DownloadProblem.cancelled);
      if (length >= 0 && have != total) {
        throw DownloadException(DownloadProblem.network, 'the connection ended at $have of $total bytes');
      }
      if (expectedSize != null && have != expectedSize) {
        keepPart = false;
        throw DownloadException(DownloadProblem.corrupt, '$have bytes, not $expectedSize');
      }

      // Read back through the locked handle (Windows' locks are mandatory: no other may read).
      file.setPositionSync(0);
      final sink = _DigestSink();
      final hasher = crypto.sha256.startChunkedConversion(sink);
      final buffer = Uint8List(1 << 20);
      for (int n; (n = await file.readInto(buffer)) > 0;) {
        hasher.add(Uint8List.sublistView(buffer, 0, n));
      }
      hasher.close();
      final got = '${sink.value}';
      if (expectedHash != null && got != expectedHash) {
        keepPart = false;
        throw DownloadException(DownloadProblem.corrupt, 'SHA-256 $got, not $expectedHash');
      }
      file.closeSync(); // and with it the lock
      open = false;
      try {
        await part.rename(target.path);
      } on FileSystemException catch (e) {
        throw DownloadException(DownloadProblem.disk, e.message);
      }
      return Downloaded(target, sha256: got, size: have, revision: revision);
    } catch (e) {
      throw _failure(e, cancel);
    } finally {
      cancel?._listeners.remove(abort);
      client.close(force: true);
      if (open) file.closeSync();
      if (!keepPart || (part.existsSync() && part.lengthSync() == 0)) {
        try {
          if (part.existsSync()) part.deleteSync();
        } on FileSystemException {
          // left behind: the next download of it starts it over
        }
      }
    }
  }

  /// [e] as a [DownloadException]; whatever cancelling broke, as [DownloadProblem.cancelled].
  static DownloadException _failure(Object e, DownloadCancel? cancel) => switch (e) {
        DownloadException() => e,
        _ when cancel?.cancelled ?? false => const DownloadException(DownloadProblem.cancelled),
        FileSystemException(:final message) => DownloadException(DownloadProblem.disk, message),
        TimeoutException() => const DownloadException(DownloadProblem.network, 'no answer'),
        SocketException(:final message) || HandshakeException(:final message) || HttpException(:final message) =>
          DownloadException(DownloadProblem.network, message),
        _ => DownloadException(DownloadProblem.network, '$e'),
      };

  void _checkSecure(Uri uri) {
    if (uri.scheme == 'https' && uri.host.isNotEmpty) return;
    if (allowLoopbackHttp && uri.scheme == 'http' && const {'localhost', '127.0.0.1', '::1'}.contains(uri.host)) return;
    throw DownloadException(DownloadProblem.insecure, '$uri');
  }

  /// Reads what is left of an answer not wanted, so its connection is freed.
  static Future<void> _drain(HttpClientResponse response) async {
    try {
      await response.drain<void>().timeout(const Duration(seconds: 5));
    } catch (_) {
      // the client is closed at the end anyway
    }
  }

  static bool _sameOrigin(Uri a, Uri b) => a.scheme == b.scheme && a.host == b.host && a.port == b.port;

  /// [value] as a SHA-256 in lowercase hex (quotes and a weak `W/` stripped), or null.
  static String? _hash(String? value) {
    final v = value?.trim().replaceFirst(RegExp(r'^W/'), '').replaceAll('"', '').toLowerCase();
    return v != null && RegExp(r'^[0-9a-f]{64}$').hasMatch(v) ? v : null;
  }

  static Future<String> _hashOf(File file) async => '${await crypto.sha256.bind(file.openRead()).first}';
}

class _DigestSink implements Sink<crypto.Digest> {
  crypto.Digest? value;

  @override
  void add(crypto.Digest data) => value = data;

  @override
  void close() {}
}
