import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

/// One face of a font file (a .ttc holds several).
typedef FontFace = ({String path, int index, String family, int weight, bool italic});

/// Reading font files without asking the system: which families and faces a file holds (its
/// `name` and `OS/2` tables), the fonts installed in the platform's font folders, and one face
/// as a file of its own. The same on every platform.
abstract final class FontFiles {
  static const extensions = ['.ttf', '.otf', '.ttc', '.otc'];

  /// The fonts installed in [systemFolders], by family: read once, on another isolate.
  static Future<Map<String, List<FontFace>>> get installed => _installed ??= Isolate.run(() => scan(systemFolders));
  static Future<Map<String, List<FontFace>>>? _installed;

  /// The folders fonts are installed in on this platform.
  static List<String> get systemFolders {
    final env = Platform.environment;
    final home = env['HOME'] ?? env['USERPROFILE'];
    if (Platform.isMacOS) {
      return ['/System/Library/Fonts', '/Library/Fonts', if (home != null) '$home/Library/Fonts'];
    }
    if (Platform.isWindows) {
      return [
        '${env['WINDIR'] ?? r'C:\Windows'}\\Fonts',
        if (env['LOCALAPPDATA'] case final local?) '$local\\Microsoft\\Windows\\Fonts',
      ];
    }
    return [
      '/usr/share/fonts',
      '/usr/local/share/fonts',
      if (home != null) ...['$home/.local/share/fonts', '$home/.fonts'],
    ];
  }

  /// The folders SMuFL fonts keep their metadata in (`<folder>/<font name>/…metadata.json`), as
  /// the SMuFL specification places them on each platform.
  static List<String> get smuflFolders {
    final env = Platform.environment;
    final home = env['HOME'] ?? env['USERPROFILE'];
    if (Platform.isMacOS) {
      return [if (home != null) '$home/Library/Application Support/SMuFL/Fonts', '/Library/Application Support/SMuFL/Fonts'];
    }
    if (Platform.isWindows) {
      return [
        if (env['LOCALAPPDATA'] case final local?) '$local\\SMuFL\\Fonts',
        if (env['COMMONPROGRAMFILES'] case final common?) '$common\\SMuFL\\Fonts',
      ];
    }
    final dataHome = env['XDG_DATA_HOME'] ?? (home == null ? null : '$home/.local/share');
    final dataDirs = (env['XDG_DATA_DIRS'] ?? '/usr/local/share:/usr/share').split(':');
    return [?(dataHome == null ? null : '$dataHome/SMuFL/Fonts'), for (final d in dataDirs) if (d.isNotEmpty) '$d/SMuFL/Fonts'];
  }

  /// Every face of every font in [folders] (and their subfolders), by family. Files that
  /// aren't fonts, or can't be read, are passed over.
  static Map<String, List<FontFace>> scan(List<String> folders) {
    final families = <String, List<FontFace>>{};
    for (final folder in folders) {
      final dir = Directory(folder);
      if (!dir.existsSync()) continue;
      final files = dir.listSync(recursive: true, followLinks: false).whereType<File>();
      for (final file in files) {
        final lower = file.path.toLowerCase();
        if (!extensions.any(lower.endsWith)) continue;
        for (final face in faces(file.path)) {
          if (face.family.isEmpty || face.family.startsWith('.')) continue; // the system's hidden UI fonts
          families.putIfAbsent(face.family, () => []).add(face);
        }
      }
    }
    return families;
  }

  /// The faces in the font file at [path]; none when it isn't a font.
  static List<FontFace> faces(String path) {
    RandomAccessFile? file;
    try {
      file = File(path).openSync();
      final head = _read(file, 0, 12);
      final tag = String.fromCharCodes(head.buffer.asUint8List(0, 4));
      if (tag == 'ttcf') {
        final count = head.getUint32(8);
        final offsets = _read(file, 12, 4 * count);
        return [
          for (var i = 0; i < count; i++) ?_face(file, path, i, offsets.getUint32(4 * i)),
        ];
      }
      return [?_face(file, path, 0, 0)];
    } catch (_) {
      return const [];
    } finally {
      file?.closeSync();
    }
  }

  /// The face nearest a weight and slant among [faces]: the slant first, then the weight.
  static FontFace? pick(Iterable<FontFace> faces, {required bool bold, required bool italic}) {
    FontFace? best;
    int score(FontFace f) => (f.italic == italic ? 0 : 10000) + (f.weight - (bold ? 700 : 400)).abs();
    for (final f in faces) {
      if (best == null || score(f) < score(best)) best = f;
    }
    return best;
  }

  /// The face [face] as a font file of its own (a face of a collection copied out with its
  /// tables), for drawing it: Flutter loads only a file's first face.
  static Uint8List faceBytes(FontFace face) {
    final bytes = File(face.path).readAsBytesSync();
    final data = ByteData.sublistView(bytes);
    final tag = String.fromCharCodes(bytes.sublist(0, 4));
    if (tag != 'ttcf') return bytes;
    final start = data.getUint32(12 + 4 * face.index);
    final count = data.getUint16(start + 4);
    final tables = [
      for (var i = 0; i < count; i++)
        (
          record: start + 12 + 16 * i,
          offset: data.getUint32(start + 12 + 16 * i + 8),
          length: data.getUint32(start + 12 + 16 * i + 12),
        ),
    ];
    var size = 12 + 16 * count;
    for (final t in tables) {
      size += (t.length + 3) & ~3;
    }
    final out = Uint8List(size);
    final outData = ByteData.sublistView(out);
    out.setRange(0, 12, bytes, start);
    var at = 12 + 16 * count;
    for (final (i, t) in tables.indexed) {
      out.setRange(12 + 16 * i, 12 + 16 * i + 16, bytes, t.record);
      outData.setUint32(12 + 16 * i + 8, at);
      out.setRange(at, at + t.length, bytes, t.offset);
      at += (t.length + 3) & ~3;
    }
    return out;
  }

  static ByteData _read(RandomAccessFile file, int offset, int length) {
    file.setPositionSync(offset);
    final bytes = file.readSync(length);
    if (bytes.length < length) throw const FormatException('Short font file.');
    return ByteData.sublistView(bytes);
  }

  static FontFace? _face(RandomAccessFile file, String path, int index, int offset) {
    final header = _read(file, offset, 12);
    final version = header.getUint32(0);
    if (version != 0x00010000 && version != 0x4F54544F /* OTTO */ && version != 0x74727565 /* true */) return null;
    final count = header.getUint16(4);
    final records = _read(file, offset + 12, 16 * count);
    final tables = <String, (int, int)>{};
    for (var i = 0; i < count; i++) {
      final tag = String.fromCharCodes(records.buffer.asUint8List(records.offsetInBytes + 16 * i, 4));
      tables[tag] = (records.getUint32(16 * i + 8), records.getUint32(16 * i + 12));
    }
    final name = tables['name'];
    if (name == null) return null;
    final names = _names(_read(file, name.$1, name.$2));
    final family = names[16] ?? names[1] ?? '';
    final subfamily = (names[17] ?? names[2] ?? '').toLowerCase();
    var weight = subfamily.contains('bold') ? 700 : 400;
    var italic = subfamily.contains('italic') || subfamily.contains('oblique');
    if (tables['OS/2'] case (final at, final length) when length >= 64) {
      final os2 = _read(file, at, 64);
      weight = os2.getUint16(4);
      final selection = os2.getUint16(62);
      italic = selection & 0x201 != 0; // ITALIC or OBLIQUE
    }
    return (path: path, index: index, family: family.trim(), weight: weight, italic: italic);
  }

  /// The `name` table's strings by name id, in English where there is a choice.
  static Map<int, String> _names(ByteData table) {
    final count = table.getUint16(2), storage = table.getUint16(4);
    final found = <int, (int, String)>{}; // id → (rank, text); a lower rank wins
    for (var i = 0; i < count; i++) {
      final r = 6 + 12 * i;
      final platform = table.getUint16(r), encoding = table.getUint16(r + 2), language = table.getUint16(r + 4);
      final id = table.getUint16(r + 6), length = table.getUint16(r + 8), at = storage + table.getUint16(r + 10);
      if (at + length > table.lengthInBytes) continue;
      final bytes = table.buffer.asUint8List(table.offsetInBytes + at, length);
      final String text;
      final int rank;
      if (platform == 3 && (encoding == 1 || encoding == 10) || platform == 0) {
        text = String.fromCharCodes([for (var k = 0; k + 1 < length; k += 2) bytes[k] << 8 | bytes[k + 1]]);
        rank = platform == 3 && language == 0x409 ? 0 : 2;
      } else if (platform == 1 && encoding == 0) {
        text = String.fromCharCodes(bytes); // Mac Roman: ASCII names read right
        rank = language == 0 ? 1 : 3;
      } else {
        continue;
      }
      if (found[id] case (final best, _) when best <= rank) continue;
      found[id] = (rank, text);
    }
    return {for (final MapEntry(:key, :value) in found.entries) key: value.$2};
  }
}
