import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:score_engine/score_engine.dart';

import 'app_folders.dart';

/// Curator's end of Curator Link, the ARA plug-in a DAW loads (see docs/daw-link.md).
///
/// Curator listens on the loopback address at a port the system picks and says where in its
/// discovery file (`daw-link.json` in [AppFolders.data]: the port and a token), which the
/// plug-in reads every second until it finds one; the plug-in connects and says the token back
/// (`hello`), so nothing else that reaches the port is listened to. Each DAW process is a
/// [DawSession]: its documents as it last sent them ([DawDocument]), where it is playing
/// ([DawSession.transport]), and its recordings written out as files when asked for
/// ([recording]). Messages are JSON objects, one a line, each way.
class DawLink extends ChangeNotifier {
  /// [_folder]: where the discovery file goes ([AppFolders.data]; a test gives its own).
  DawLink([this._folder]);

  /// The app’s one link, started while Settings ▸ General ▸ Listen for Curator Link is on.
  static final shared = DawLink();

  final Directory? _folder;
  ServerSocket? _server;
  File? _discovery;
  String _token = '';
  final _sessions = <DawSession>[];

  /// The protocol this Curator speaks (`LINK_PROTOCOL` in daw_link/src/link_config.h).
  static const protocol = 1;

  /// The longest line read: a DAW document with thousands of regions is a few megabytes.
  static const maxLine = 32 << 20;

  bool get listening => _server != null;

  /// The DAWs connected now, in the order they came.
  List<DawSession> get sessions => List.unmodifiable(_sessions);

  /// Every document of every DAW connected.
  Iterable<(DawSession, DawDocument)> get documents sync* {
    for (final s in _sessions) {
      for (final d in s.documents) {
        yield (s, d);
      }
    }
  }

  /// The document [id] and the DAW it is in, or null when it isn't open (any longer).
  (DawSession, DawDocument)? find(String id) => documents.where((e) => e.$2.id == id).firstOrNull;

  /// Starts listening and writes the discovery file. Does nothing when listening already.
  Future<void> start() async {
    if (_server != null) return;
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    final random = math.Random.secure();
    _token = [for (var i = 0; i < 16; i++) random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
    server.listen(_accept, onError: (_) {});
    final folder = _folder ?? AppFolders.data;
    await folder.create(recursive: true);
    final file = File('${folder.path}${Platform.pathSeparator}daw-link.json');
    final partial = File('${file.path}.part');
    // Written whole, then put in place: a plug-in never reads half of it.
    await partial.writeAsString(jsonEncode({'port': server.port, 'token': _token, 'pid': pid, 'protocol': protocol}));
    await partial.rename(file.path);
    _discovery = file;
    notifyListeners();
  }

  /// Stops listening, lets every DAW go and removes the discovery file (when it is still ours).
  Future<void> stop() async {
    final server = _server;
    if (server == null) return;
    _server = null;
    await server.close();
    for (final s in [..._sessions]) {
      s._close();
    }
    final file = _discovery;
    _discovery = null;
    try {
      // Another Curator started since may have written its own: that one stays.
      if (file != null && file.existsSync() && (jsonDecode(file.readAsStringSync()) as Map)['token'] == _token) file.deleteSync();
    } catch (_) {}
    notifyListeners();
  }

  void _accept(Socket socket) {
    final session = DawSession._(this, socket);
    final lines = const LineSplitter().bind(utf8.decoder.bind(_limited(socket)));
    lines.listen(
      (line) {
        try {
          final message = jsonDecode(line);
          if (message is Map<String, Object?>) session._receive(message);
        } on FormatException {
          // A line that isn't JSON is passed over (what speaks no Curator Link is let go at hello).
        }
      },
      onDone: session._close,
      onError: (_) => session._close(),
      cancelOnError: true,
    );
  }

  /// The bytes of [socket], ended past [maxLine] without a line break.
  Stream<List<int>> _limited(Socket socket) async* {
    var sinceBreak = 0;
    await for (final chunk in socket) {
      final at = chunk.lastIndexOf(10);
      sinceBreak = at < 0 ? sinceBreak + chunk.length : chunk.length - at - 1;
      if (sinceBreak > maxLine) throw const FormatException('A line too long.');
      yield chunk;
    }
  }

  /// Asks the DAW of [session] for [source] of [document] as a file, written in Curator's
  /// cache; completes with its path. [progress] hears how far it has got, 0–1. Throws a
  /// [DawLinkException] when the DAW can't (or is gone).
  Future<String> recording(DawSession session, String document, String source, {void Function(double done)? progress}) =>
      session._ask((document, 'source', source), {'t': 'export', 'document': document, 'source': source}, progress);

  /// Asks the DAW of [session] for [track] of [document] as the song plays it (a stem), from
  /// song time [from] for [length] seconds, written in Curator's cache; completes with its path.
  /// As [recording] otherwise.
  Future<String> stem(DawSession session, String document, String track,
          {required double from, required double length, void Function(double done)? progress}) =>
      session._ask((document, 'track', track), {'t': 'stem', 'document': document, 'track': track, 'from': from, 'length': length}, progress);
}

/// What a DAW said went wrong: [reason] is the plug-in's word for it ("gone", "unreadable",
/// "too long", "out of memory", "empty", "unwritable", "cancelled", "disconnected").
class DawLinkException implements Exception {
  const DawLinkException(this.reason);
  final String reason;
  @override
  String toString() => 'DawLinkException($reason)';
}

/// One DAW connected to Curator: [host] is its process's name ("Cubase 15", "Logic Pro").
class DawSession extends ChangeNotifier {
  DawSession._(this._link, this._socket);

  final DawLink _link;
  final Socket _socket;
  bool _greeted = false, _closed = false;

  String host = '';

  /// The plug-in's version (Curator's, when they came together).
  String plugin = '';

  final _documents = <String, DawDocument>{};

  /// Its documents (most DAWs have one open).
  List<DawDocument> get documents => List.unmodifiable(_documents.values);

  /// Where it is playing, as it last said; null until it has.
  final transport = ValueNotifier<DawTransport?>(null);

  /// Files asked for and not yet written, by document, kind ("source", "track") and id.
  final _recordings = <(String, String, String), ({Completer<String> completer, List<void Function(double)> progress})>{};

  /// What the file [key] is, sent as [message] unless it was asked for already.
  Future<String> _ask((String, String, String) key, Map<String, Object?> message, void Function(double)? progress) {
    final asked = _recordings.containsKey(key);
    final pending = _recordings[key] ??= (completer: Completer<String>(), progress: <void Function(double)>[]);
    if (progress != null) pending.progress.add(progress);
    if (!asked) _send(message);
    return pending.completer.future;
  }

  /// The key of the file a `progress`, `exported` or `stemmed` message is about.
  static (String, String, String)? _keyOf(Map<String, Object?> message) => switch (message) {
        {'document': final String d, 'track': final String t} => (d, 'track', t),
        {'document': final String d, 'source': final String s} => (d, 'source', s),
        _ => null,
      };

  void _receive(Map<String, Object?> message) {
    final type = message['t'];
    if (!_greeted) {
      // The first word must be hello, with the token from the discovery file.
      if (type != 'hello' || message['token'] != _link._token || message['protocol'] != DawLink.protocol) return _close();
      _greeted = true;
      host = (message['host'] as String?) ?? '';
      plugin = (message['plugin'] as String?) ?? '';
      _link._sessions.add(this);
      _link.notifyListeners();
      return;
    }
    switch (type) {
      case 'document':
        try {
          final document = DawDocument.fromJson(message);
          _documents[document.id] = document;
        } on FormatException {
          return;
        }
      case 'closed':
        _documents.remove(message['id']);
      case 'transport':
        transport.value = dawTransportOf(message);
        return;
      case 'progress':
        final pending = _recordings[_keyOf(message)];
        final done = message['done'];
        if (pending != null && done is num) {
          for (final f in pending.progress) {
            f(done.toDouble().clamp(0, 1));
          }
        }
        return;
      case 'exported' || 'stemmed':
        final pending = _recordings.remove(_keyOf(message));
        if (pending == null) return;
        if (message['path'] case final String path) {
          pending.completer.complete(path);
        } else {
          pending.completer.completeError(DawLinkException((message['error'] as String?) ?? 'unwritable'));
        }
        return;
      default:
        return; // a later plug-in's
    }
    notifyListeners();
    _link.notifyListeners();
  }

  void _send(Map<String, Object?> message) {
    if (_closed) {
      for (final p in _recordings.values) {
        p.completer.completeError(const DawLinkException('disconnected'));
      }
      _recordings.clear();
      return;
    }
    _socket.write('${jsonEncode(message)}\n');
  }

  void _close() {
    if (_closed) return;
    _closed = true;
    _socket.destroy();
    for (final p in _recordings.values) {
      p.completer.completeError(const DawLinkException('disconnected'));
    }
    _recordings.clear();
    _documents.clear();
    if (_link._sessions.remove(this)) _link.notifyListeners();
    notifyListeners();
  }
}

/// Curator Link's VST3 and Audio Unit as this Curator bundles them (`make daw-link` zips them
/// into [asset]), put where DAWs look for plug-ins: `~/Library/Audio/Plug-Ins/VST3` and
/// `…/Components`. macOS only; a build made without them has none to install ([bundled]).
abstract final class CuratorLinkPlugIns {
  static const asset = 'assets/daw_link/CuratorLink.zip';
  static const vst3 = 'Curator Link.vst3', component = 'Curator Link.component';

  /// Whether this system can have it: macOS. Elsewhere Settings say it isn't available and
  /// Follow DAW… is greyed out; Curator doesn't listen.
  static bool get supported => debugSupported ?? Platform.isMacOS;

  /// Stands in for the system in tests; null: the real one.
  @visibleForTesting
  static bool? debugSupported;

  /// `~/Library/Audio/Plug-Ins`, or null without a home.
  static String? get plugInsFolder {
    final home = Platform.environment['HOME'];
    return home == null || !home.startsWith('/') ? null : '$home/Library/Audio/Plug-Ins';
  }

  /// The version installed ("0.9.0 (468)", the VST3's) in [folder] ([plugInsFolder]), or null
  /// when there is none.
  static String? installed({String? folder}) {
    folder ??= plugInsFolder;
    if (folder == null) return null;
    final plist = File('$folder/VST3/$vst3/Contents/Info.plist');
    if (!plist.existsSync()) return null;
    final text = plist.readAsStringSync();
    String? value(String key) => RegExp('<key>$key</key>\\s*<string>([^<]*)</string>').firstMatch(text)?.group(1);
    final version = value('CFBundleShortVersionString'), build = value('CFBundleVersion');
    return version == null ? '' : build == null ? version : '$version ($build)';
  }

  /// Removes both bundles from [folder] ([plugInsFolder]), whichever are there. Throws a
  /// [FileSystemException] when it can't.
  static Future<void> uninstall({String? folder}) async {
    folder ??= plugInsFolder;
    if (folder == null) return;
    for (final bundle in ['$folder/VST3/$vst3', '$folder/Components/$component']) {
      final dir = Directory(bundle);
      if (dir.existsSync()) await dir.delete(recursive: true);
    }
  }

  /// The zip [bytes] (the asset) unpacked over what is installed in [folder] ([plugInsFolder]): each bundle removed whole,
  /// then written anew, its program made executable. Throws a [FileSystemException] when it
  /// can't write there.
  static Future<void> install(Uint8List bytes, {String? folder}) async {
    folder ??= plugInsFolder;
    if (folder == null) throw const FileSystemException('No home folder.');
    final files = ZipDecoder().decodeBytes(bytes).files;
    String? target(String name) => name.startsWith('$vst3/')
        ? '$folder/VST3/$name'
        : name.startsWith('$component/')
            ? '$folder/Components/$name'
            : null;
    for (final bundle in ['$folder/VST3/$vst3', '$folder/Components/$component']) {
      final dir = Directory(bundle);
      if (dir.existsSync()) await dir.delete(recursive: true);
    }
    final programs = <String>[];
    for (final f in files) {
      final path = target(f.name);
      if (!f.isFile || path == null || f.name.contains('..')) continue;
      await (File(path)..createSync(recursive: true)).writeAsBytes(f.content);
      if (f.name.contains('/Contents/MacOS/')) programs.add(path);
    }
    if (programs.isNotEmpty) await Process.run('chmod', ['755', ...programs]);
  }
}
