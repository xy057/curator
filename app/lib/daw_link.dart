import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:score_engine/score_engine.dart';

import 'app_folders.dart';
import 'attacca_version.dart';

/// Curator's end of Attacca, the ARA plug-in a DAW loads (see docs/daw-link.md).
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

  /// The app’s one link, started while Settings ▸ General ▸ Listen for Attacca is on.
  static final shared = DawLink();

  final Directory? _folder;
  ServerSocket? _server;
  File? _discovery;
  String _token = '';
  final _sessions = <DawSession>[];

  /// The connections that haven't said hello: each is let go when it hasn't within
  /// [greetWithin], and all when listening stops (one kept could say it after, to a link that
  /// listens no more).
  final _ungreeted = <DawSession>{};

  /// How long a connection has to say hello: the plug-in says it as it connects.
  static const greetWithin = Duration(seconds: 10);

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
      for (final d in s._documents.values) {
        yield (s, d);
      }
    }
  }

  /// Who follows which document ([DawEditing]): each DAW is told the projects following one of
  /// its documents (`followers`), for its Attacca window.
  final _followers = <Object, ({String document, String name})>{};

  /// [who] follows [document] as the project [name]; null: [who] follows nothing.
  void followedBy(Object who, ({String document, String name})? follow) {
    if (follow == null ? _followers.remove(who) == null : _followers[who] == follow) return;
    if (follow != null) _followers[who] = follow;
    _tellFollowers();
  }

  /// Each DAW the projects following its documents, when they differ from what it was told.
  void _tellFollowers() {
    for (final s in _sessions) {
      final names = {for (final f in _followers.values) if (s._documents.containsKey(f.document)) f.name}.toList()..sort();
      s._tell({'t': 'followers', 'names': names.join('\n')});
    }
  }

  /// Whether a DAW is writing a file for Curator now (a recording, a track, a capture): its
  /// cache isn't cleared meanwhile ([AttaccaCache]).
  bool get busy => _sessions.any((s) => s._recordings.isNotEmpty);

  /// The document [id] and the DAW it is in, or null when it isn't open (any longer).
  (DawSession, DawDocument)? find(String id) {
    for (final s in _sessions) {
      if (s._documents[id] case final d?) return (s, d);
    }
    return null;
  }

  /// [start] and [stop], one after the other in the order asked: one asked while another is under
  /// way waits for it, so the last asked holds (the switch flicked on and off ends off, and two
  /// asked to start at once open one port).
  Future<void> _turn = Future.value();

  Future<void> _inTurn(Future<void> Function() job) {
    final done = _turn.then((_) => job());
    _turn = done.then<void>((_) {}, onError: (Object _) {});
    return done;
  }

  /// Starts listening and writes the discovery file. Does nothing when listening already. Throws
  /// when it can't (no port, or the file can't be written): it isn't listening then.
  Future<void> start() => _inTurn(_start);

  /// Stops listening, lets every DAW go and removes the discovery file (when it is still ours).
  Future<void> stop() => _inTurn(_stop);

  Future<void> _start() async {
    if (_server != null) return;
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final random = math.Random.secure();
    _token = [for (var i = 0; i < 16; i++) random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
    server.listen(_accept, onError: (_) {});
    final folder = _folder ?? AppFolders.data;
    final file = File('${folder.path}${Platform.pathSeparator}daw-link.json');
    try {
      await folder.create(recursive: true);
      final partial = File('${file.path}.part');
      // Written whole, then put in place: a plug-in never reads half of it.
      await partial.writeAsString(jsonEncode({'port': server.port, 'token': _token, 'pid': pid, 'protocol': protocol, 'build': attaccaVersion}));
      await partial.rename(file.path);
    } catch (_) {
      // No plug-in can find a port no file names: not left open.
      await server.close();
      rethrow;
    }
    _server = server;
    _discovery = file;
    notifyListeners();
  }

  Future<void> _stop() async {
    final server = _server;
    if (server == null) return;
    _server = null;
    await server.close();
    for (final s in [..._sessions, ..._ungreeted]) {
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
    _ungreeted.add(session);
    session._greeting = Timer(greetWithin, session._close);
    // (A name a DAW gives that isn't UTF-8 is read as it can be: refused, the connection would
    // end, and the plug-in connect and say the same again each second.)
    final lines = const LineSplitter().bind(const Utf8Decoder(allowMalformed: true).bind(_limited(socket)));
    lines.listen(
      (line) {
        try {
          final message = jsonDecode(line);
          if (message is Map<String, Object?>) session._receive(message);
        } on FormatException {
          // A line that isn't JSON is passed over (what speaks no Attacca is let go at hello).
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

  /// Asks [capturer] (in [session]'s DAW: [capturersOf]) for what it hears from song time [from]
  /// for [length] seconds, as the DAW plays it, written in Curator's cache as [name].wav;
  /// completes with its path once every moment of it was heard. [document]'s Attacca (in
  /// [session]) is asked to have the DAW stop (`stop`), then, once the Capturer is `ready` (the
  /// DAW stopped and fallen quiet: what still rang from before isn't the mix; ten seconds at
  /// most), to play from a second before (`play`, where the DAW lets it ask), and to stop once it
  /// is done, whichever way: the Capturer is in a bundle of its own, so Curator says when.
  /// [progress] hears how much was, 0–1. As [recording] otherwise.
  ///
  /// [played] is the song time the DAW plays of it (a recording's region, its `start` and
  /// `end`): only that is to be heard, the rest of the file silence, so the capture is done when
  /// the DAW has played the region, however long the file; the whole of it when null.
  Future<String> capture(DawSession session, String document, DawCapturer capturer,
      {required double from,
      required double length,
      required String name,
      ({double start, double end})? played,
      void Function(double done)? progress}) async {
    final key = (document, 'capturer', capturer.id);
    final ready = capturer.session._ready[key] = Completer<void>();
    void go() {
      if (!ready.isCompleted) ready.complete();
    }

    final captured = capturer.session._ask(key, {
      't': 'capture',
      'document': document,
      'capturer': capturer.id,
      'from': from,
      'length': length,
      'name': name,
      if (played != null) ...{'start': played.start, 'end': played.end},
    }, progress);
    var over = false;
    unawaited(captured.then((_) {}, onError: (_) {}).whenComplete(() {
      over = true;
      go();
    }));
    final wait = Timer(const Duration(seconds: 10), go);
    drive(session, document, 'stop');
    try {
      await ready.future;
      // A second before what is to be heard (Attacca puts it no earlier than 0).
      if (!over) drive(session, document, 'play', at: (played?.start ?? from) - 1);
      return await captured;
    } finally {
      wait.cancel();
      capturer.session._ready.remove(key);
      session._send({'t': 'stop', 'document': document});
    }
  }

  /// Asks [document]'s Attacca in [session] to have the DAW's transport [command]: `play` (from
  /// song time [at], if given), `stop`, or `seek` to [at]; where the DAW lets it
  /// ([DawDocument.playback]), the next time the DAW asks Attacca for updates.
  void drive(DawSession session, String document, String command, {double? at}) =>
      session._send({'t': command, 'document': document, 'at': ?at});

  /// Ends [capture] of [capturer] under way: it fails as `cancelled`.
  void cancelCapture(String document, DawCapturer capturer) => capturer.session._send({'t': 'cancel', 'document': document, 'capturer': capturer.id});

  /// The Attacca Capturers in [session]'s DAW: its own and those of the other connections from
  /// the same process (Attacca Capturer's VST3 is a bundle of its own, with its own connection).
  List<DawCapturer> capturersOf(DawSession session) => [for (final s in _sameDaw(session)) ...s.capturers];

  /// The Attacca Capturer linked to the Attacca of [session]'s DAW (chosen in Attacca's window:
  /// [DawSession.linkedCapturer]), if it is there: Record from DAW… captures with it.
  DawCapturer? linkedCapturerOf(DawSession session) {
    final linked = {for (final s in _sameDaw(session)) if (s.linkedCapturer.isNotEmpty) s.linkedCapturer};
    return capturersOf(session).where((c) => linked.contains(c.id)).firstOrNull;
  }

  /// The connections from [session]'s DAW: itself, and the others from its process.
  List<DawSession> _sameDaw(DawSession session) => [for (final s in _sessions) if (s == session || (session.pid > 0 && s.pid == session.pid)) s];

  /// Each connection told, from what its DAW's connections say: Attacca's, the Capturers there
  /// for its window's Capturer menu (`inserts`); a Capturer's, which of its Capturers are linked to
  /// an Attacca there with a document (`linked`: its window says Linked, or Not linked).
  void _tellLinked() {
    for (final s in _sessions) {
      final daw = _sameDaw(s);
      final capturers = capturersOf(s);
      s._tell({
        't': 'inserts',
        'ids': [for (final c in capturers) c.id].join('\n'),
        'names': [
          for (final (i, c) in capturers.indexed) c.name.isNotEmpty ? c.name : capturers.length > 1 ? 'Attacca Capturer ${i + 1}' : 'Attacca Capturer',
        ].join('\n'),
      });
      if (s.capturers.isEmpty) continue;
      final linked = {for (final o in daw) if (o._documents.isNotEmpty && o.linkedCapturer.isNotEmpty) o.linkedCapturer};
      s._tell({'t': 'linked', 'ids': [for (final c in s.capturers) if (linked.contains(c.id)) c.id].join('\n')});
    }
  }
}

/// An Attacca Capturer in a DAW ([DawSession.capturers]): what it hears, [channels] at [rate];
/// [session] the connection it is on; [name] the DAW's channel it is on ('' unsaid).
@immutable
class DawCapturer {
  const DawCapturer(this.session, this.id, {this.name = '', this.channels = 2, this.rate = 0});
  final DawSession session;
  final String id;
  final String name;
  final int channels;
  final double rate;
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
  DawSession._(this._link, this._socket) {
    // A DAW that goes with lines unread resets the connection: the reading side closes the
    // session; the writing side's error is nothing more.
    _socket.done.then<void>((_) {}, onError: (Object _) {});
  }

  final DawLink _link;
  final Socket _socket;
  bool _greeted = false, _closed = false;

  /// Runs out when it hasn't said hello ([DawLink.greetWithin]).
  Timer? _greeting;

  /// The DAW's name: its process's ("Cubase 15"; on Windows "Cubase15", its program without
  /// ".exe"). Shown, never judged by ([supported]).
  String host = '';

  /// Whether this DAW gives Attacca what it needs: told by the ARA interfaces its documents
  /// say it gives ([DawDocument.missing]), never by its name. One that doesn't is told of, and
  /// Connect Attacca… refuses its recordings unless ⌥ is held. (A DAW with no document, Attacca
  /// on no recording there, isn't known not to.)
  bool get supported => missing.isEmpty;

  /// What Attacca needs of ARA that this DAW doesn't give ([DawDocument.needed]'s order).
  List<String> get missing => [for (final i in DawDocument.needed) if (_documents.values.any((d) => d.missing.contains(i))) i];

  /// Its Attacca's version (`build` in `hello`; 0: one that doesn't say). One from before
  /// Attacca had a version of its own ([attaccaVersion]) says Curator's build then: lower.
  int version = 0;

  /// The Attacca Capturer its Attacca is linked to (`link`, chosen in Attacca's window; ''
  /// none): [DawLink.linkedCapturerOf].
  String linkedCapturer = '';

  /// The DAW's process (0: unsaid): Attacca's and Attacca Capturer's connections from one DAW
  /// share it.
  int pid = 0;

  /// Whether its Attacca is older than the one this Curator bundles ([attaccaVersion]), installed
  /// already ([AttaccaPlugIns.installedVersion]: the DAW loads it once it opens again) or not
  /// yet. A newer Curator whose Attacca is the same one leaves it be.
  bool get outdated => version > 0 && version < attaccaVersion;

  final _documents = <String, DawDocument>{};

  /// Its documents (most DAWs have one open).
  List<DawDocument> get documents => List.unmodifiable(_documents.values);

  /// Where it is playing, as it last said; null until it has.
  final transport = ValueNotifier<DawTransport?>(null);

  /// The Attacca Capturers in it (inserts, usually last on its output): Record from DAW…
  /// captures the mix with the one linked ([DawLink.capture]); Attacca's own files (a recording
  /// or a track, through ARA) are written whether or not there is one.
  List<DawCapturer> capturers = const [];

  /// Files asked for and not yet written, by document, kind ("source", "track") and id.
  final _recordings = <(String, String, String), ({Completer<String> completer, List<void Function(double)> progress})>{};

  /// Captures asked for whose Capturer isn't `ready` yet ([DawLink.capture]), by key.
  final _ready = <(String, String, String), Completer<void>>{};

  /// What the file [key] is, sent as [message] unless it was asked for already.
  Future<String> _ask((String, String, String) key, Map<String, Object?> message, void Function(double)? progress) {
    final asked = _recordings.containsKey(key);
    final pending = _recordings[key] ??= (completer: Completer<String>(), progress: <void Function(double)>[]);
    if (progress != null) pending.progress.add(progress);
    if (!asked) _send(message);
    return pending.completer.future;
  }

  /// The key of the file a `progress`, `exported`, `stemmed` or `captured` message is about.
  static (String, String, String)? _keyOf(Map<String, Object?> message) => switch (message) {
        {'document': final String d, 'capturer': final String c} => (d, 'capturer', c),
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
      _greeting?.cancel();
      _link._ungreeted.remove(this);
      host = (message['host'] as String?) ?? '';
      version = (message['build'] as num?)?.toInt() ?? 0;
      pid = (message['pid'] as num?)?.toInt() ?? 0;
      _link._sessions.add(this);
      _link.notifyListeners();
      _link._tellFollowers();
      _link._tellLinked(); // the Capturers already in its DAW, for its window's Capturer menu
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
        final id = message['id'];
        _documents.remove(id);
        // What was asked of it and not yet written never will be (the plug-in lets its queue go
        // with it): told so, or Curator would wait on it while the DAW stays connected. A
        // capture is asked of the Capturer's connection from the same DAW, and is cancelled
        // there: the Capturer would else wait for the DAW to play its span.
        for (final s in _link._sameDaw(this)) {
          for (final (_, kind, capturer) in [for (final key in s._recordings.keys) if (key.$1 == id) key]) {
            if (kind == 'capturer') s._send({'t': 'cancel', 'document': id, 'capturer': capturer});
          }
          s._fail((key) => key.$1 == id, 'gone');
        }
      case 'transport':
        transport.value = dawTransportOf(message);
        return;
      case 'link':
        linkedCapturer = (message['capturer'] as String?) ?? '';
      case 'capturers':
        capturers = [
          for (final c in (message['list'] as List?) ?? const [])
            if (c case {'id': final String id}) DawCapturer(this, id, name: (c['name'] as String?) ?? '', channels: (c['channels'] as num?)?.toInt() ?? 2, rate: (c['rate'] as num?)?.toDouble() ?? 0),
        ];
      case 'ready':
        if (_ready[_keyOf(message)] case final ready? when !ready.isCompleted) ready.complete();
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
      case 'exported' || 'stemmed' || 'captured':
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
    _link._tellFollowers(); // a document followed may have come or gone
    _link._tellLinked();
    notifyListeners();
    _link.notifyListeners();
  }

  /// What this connection was last told of a state, by the message's type: the projects
  /// following its DAW (`followers`: their names, one a line), its Capturers linked (`linked`)
  /// and its DAW's Capturers (`inserts`). Each is sent only when it changes; none followers or
  /// inserts is what it starts with (said only once there were some), none linked is said.
  final _told = <String, String>{
    for (final none in [
      {'t': 'followers', 'names': ''},
      {'t': 'inserts', 'ids': '', 'names': ''},
    ])
      none['t']!: jsonEncode(none),
  };

  void _tell(Map<String, String> state) {
    final said = jsonEncode(state);
    if (_told[state['t']] == said) return;
    _told[state['t']!] = said;
    _send(state);
  }

  void _send(Map<String, Object?> message) {
    if (_closed) return _fail((_) => true, 'disconnected');
    _socket.write('${jsonEncode(message)}\n');
  }

  /// Fails the files asked for [which] keys says, for [reason] ([DawLinkException]).
  void _fail(bool Function((String, String, String) key) which, String reason) {
    final failed = [for (final key in _recordings.keys) if (which(key)) key];
    for (final key in failed) {
      _recordings.remove(key)!.completer.completeError(DawLinkException(reason));
    }
  }

  void _close() {
    if (_closed) return;
    _closed = true;
    _greeting?.cancel();
    _link._ungreeted.remove(this);
    _socket.destroy();
    _fail((_) => true, 'disconnected');
    _documents.clear();
    if (_link._sessions.remove(this)) {
      _link._tellLinked();
      _link.notifyListeners();
    }
    notifyListeners();
  }
}

/// What Attacca wrote for Curator (`DAW Link` in [AppFolders.cache]): recordings, tracks and
/// captures as WAV files, each left there once Curator has loaded it. A project open plays its
/// recording from there until it closes (saved, it holds a copy of its own), so nothing ever
/// removed them: Settings ▸ General ▸ DAW shows how much there is, and clears it.
abstract final class AttaccaCache {
  static Directory get folder => Directory('${AppFolders.cache.path}${Platform.pathSeparator}DAW Link');

  /// The bytes its files take up; 0 when there is none.
  static Future<int> size({Directory? folder}) async {
    folder ??= AttaccaCache.folder;
    var bytes = 0;
    try {
      await for (final e in folder.list(recursive: true, followLinks: false)) {
        if (e is File) bytes += await e.length();
      }
    } on FileSystemException {
      // (No such folder, or a file gone meanwhile: what was counted.)
    }
    return bytes;
  }

  /// Removes its files, all but those in [keep] (what the recordings open now play:
  /// `AudioTrack.filesInUse`), and the folders left empty. One that can't be removed stays.
  static Future<void> clear({Directory? folder, Iterable<String> keep = const []}) async {
    folder ??= AttaccaCache.folder;
    if (!folder.existsSync()) return;
    // (By where each really is: the cache named through a link is the same place.)
    String real(String path) {
      try {
        return File(path).resolveSymbolicLinksSync();
      } on FileSystemException {
        return File(path).absolute.path;
      }
    }

    final kept = {for (final path in keep) real(path)};
    final entries = await folder.list(recursive: true, followLinks: false).toList();
    for (final e in entries) {
      if (e is Directory || kept.contains(real(e.path))) continue;
      try {
        await e.delete();
      } on FileSystemException {
        // In use by something else: left.
      }
    }
    // The deepest first; one that still holds a file doesn't go.
    final folders = [for (final e in entries) if (e is Directory) e]..sort((a, b) => b.path.length.compareTo(a.path.length));
    for (final d in folders) {
      try {
        await d.delete();
      } on FileSystemException {
        // Not empty.
      }
    }
  }
}

/// Attacca's VST3 and Audio Unit as this Curator bundles them (`make daw-link` zips them
/// into [asset]), put where DAWs look for plug-ins: `~/Library/Audio/Plug-Ins/VST3` and
/// `…/Components`. macOS only; a build made without them has none to install ([bundled]).
abstract final class AttaccaPlugIns {
  static const asset = 'assets/daw_link/Attacca.zip';
  static const vst3 = 'Attacca.vst3', component = 'Attacca.component', capturerVst3 = 'Attacca Capturer.vst3';

  /// The bundles as they were named before (Curator Link): the same plug-in to a DAW, so they
  /// go wherever these come or go.
  static const _formerly = ['VST3/Curator Link.vst3', 'Components/Curator Link.component'];

  /// Every bundle of it in [folder], under either name.
  static List<String> _bundlesIn(String folder) =>
      ['$folder/VST3/$vst3', '$folder/VST3/$capturerVst3', '$folder/Components/$component', for (final b in _formerly) '$folder/$b'];

  /// Whether this system can have it: macOS, and Windows (its two VST3s: Audio Units are
  /// macOS's). Elsewhere Settings say it isn't available and Connect Attacca… is greyed out;
  /// Curator doesn't listen.
  static bool get supported => debugSupported ?? (Platform.isMacOS || Platform.isWindows);

  /// Stands in for the system in tests; null: the real one.
  @visibleForTesting
  static bool? debugSupported;

  /// Where DAWs look for the user's own plug-ins, `VST3` in it (and on macOS `Components`):
  /// `~/Library/Audio/Plug-Ins`; on Windows `%LocalAppData%\Programs\Common`, the user's own
  /// VST3 folder there, written without an administrator. Null without a home.
  static String? get plugInsFolder => plugInsFolderFor(Platform.operatingSystem, Platform.environment);

  /// [plugInsFolder] on [os] (`Platform.operatingSystem`) with [env].
  @visibleForTesting
  static String? plugInsFolderFor(String os, Map<String, String> env) {
    if (os == 'windows') {
      final local = AppFolders.windowsLocal(env);
      return local == null ? null : '$local${local.endsWith('\\') ? '' : '\\'}Programs\\Common';
    }
    final home = env['HOME'];
    return home == null || !home.startsWith('/') ? null : '$home/Library/Audio/Plug-Ins';
  }

  /// The Attacca installed in [folder] ([plugInsFolder]), the VST3's: what it calls its
  /// version (`name`: "630"; "0.10.625 (625)" from before Attacca had a version of its own, when
  /// it had Curator's and its build; '' when it doesn't say) and the number compared
  /// (`version`, [attaccaVersion]'s; null unsaid). Null when there is none. A macOS bundle says
  /// them in its Info.plist (CFBundleShortVersionString, CFBundleVersion), a Windows one in
  /// Contents/Resources/version.txt ("630"; "0.10.625+625" before: daw_link/CMakeLists.txt).
  static ({String name, int? version})? _installed(String? folder) {
    folder ??= plugInsFolder;
    if (folder == null) return null;
    final contents = '$folder/VST3/$vst3/Contents';
    final plist = File('$contents/Info.plist'), text = File('$contents/Resources/version.txt');
    final String? name, version;
    if (plist.existsSync()) {
      final said = plist.readAsStringSync();
      String? value(String key) => RegExp('<key>$key</key>\\s*<string>([^<]*)</string>').firstMatch(said)?.group(1);
      (name, version) = (value('CFBundleShortVersionString'), value('CFBundleVersion'));
    } else if (text.existsSync()) {
      final said = RegExp(r'^(?:([0-9A-Za-z.-]+)\+)?(\d+)\s*$').firstMatch(text.readAsStringSync());
      (name, version) = (said?[1] ?? said?[2], said?[2]);
    } else {
      return null;
    }
    return (name: name == null ? '' : version == null || version == name ? name : '$name ($version)', version: int.tryParse(version ?? ''));
  }

  /// What the Attacca installed in [folder] ([plugInsFolder]) calls its version ("630"; '' when
  /// it doesn't say), or null when there is none.
  static String? installed({String? folder}) => _installed(folder)?.name;

  /// The version of the Attacca installed in [folder] ([plugInsFolder]), as [attaccaVersion]
  /// counts; null when there is none, or it doesn't say.
  static int? installedVersion({String? folder}) => _installed(folder)?.version;

  /// Removes both bundles from [folder] ([plugInsFolder]), whichever are there (and any by its
  /// former name). Throws a
  /// [FileSystemException] when it can't, and on Windows [AttaccaInUse] while a DAW has it.
  static Future<void> uninstall({String? folder}) async {
    folder ??= plugInsFolder;
    if (folder == null) return;
    _checkFree(folder);
    for (final bundle in _bundlesIn(folder)) {
      final dir = Directory(bundle);
      if (dir.existsSync()) await dir.delete(recursive: true);
    }
  }

  /// Windows lets no program replace or remove a plug-in a DAW has loaded (macOS does, the DAW
  /// keeping the one it loaded): throws [AttaccaInUse] when one in [folder] can't be written
  /// now, before anything there is touched (a bundle half removed is one no DAW can load).
  static void _checkFree(String folder) {
    if (!Platform.isWindows) return;
    for (final bundle in _bundlesIn(folder)) {
      final dir = Directory(bundle);
      if (!dir.existsSync()) continue;
      for (final file in dir.listSync(recursive: true).whereType<File>()) {
        if (!file.path.toLowerCase().endsWith('.vst3')) continue;
        try {
          file.openSync(mode: FileMode.append).closeSync();
        } on FileSystemException {
          throw const AttaccaInUse();
        }
      }
    }
  }

  /// The zip [bytes] (the asset) unpacked over what is installed in [folder] ([plugInsFolder]): each bundle (and any by its former name) removed whole,
  /// then written anew, its program made executable. Throws a [FileSystemException] when it
  /// can't write there, and on Windows [AttaccaInUse] while a DAW has it. Unpacked and written on another isolate: the bundles are megabytes.
  static Future<void> install(Uint8List bytes, {String? folder}) async {
    final to = folder ?? plugInsFolder;
    if (to == null) throw const FileSystemException('No home folder.');
    await Isolate.run(() => _install(bytes, to));
  }

  static Future<void> _install(Uint8List bytes, String folder) async {
    final files = ZipDecoder().decodeBytes(bytes).files;
    String? target(String name) => name.startsWith('$vst3/') || name.startsWith('$capturerVst3/')
        ? '$folder/VST3/$name'
        : name.startsWith('$component/')
            ? '$folder/Components/$name'
            : null;
    await uninstall(folder: folder);
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

/// Attacca can't be installed, updated or removed now: a DAW has it loaded (Windows).
class AttaccaInUse implements Exception {
  const AttaccaInUse();

  @override
  String toString() => 'AttaccaInUse';
}
