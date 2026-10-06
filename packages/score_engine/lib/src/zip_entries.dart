import 'dart:io' show ZLibDecoder;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart' hide ZLibDecoder;

/// Reading entries of a zip someone else made (a project, an .mxl). A zip says how big an
/// entry is, but inflating it can make far more (a few kilobytes can unpack to gigabytes), and
/// `package:archive` unpacks without a limit; so here the bytes are counted as they come, and
/// an entry is refused past its limit. Only stored and deflated entries are read: what Curator
/// writes, and what other apps write.
abstract final class ZipEntries {
  static const _chunk = 64 << 10;

  /// [file]'s bytes; a [FormatException] when there would be more than [limit].
  static Uint8List read(ArchiveFile file, {required int limit}) {
    final out = BytesBuilder(copy: false);
    write(file, out.add, limit: limit);
    return out.takeBytes();
  }

  /// Hands [file]'s bytes to [add] a piece at a time; a [FormatException] as soon as there
  /// would be more than [limit] (the pieces before it have been handed over).
  static void write(ArchiveFile file, void Function(Uint8List bytes) add, {required int limit}) {
    final zip = file.rawContent;
    if (!file.isFile || zip is! ZipFile) throw FormatException('${file.name} is not a file.');
    if (file.size > limit) throw _tooBig(file);
    var total = 0;
    void counted(List<int> bytes) {
      total += bytes.length;
      if (total > limit) throw _tooBig(file);
      add(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
    }

    final raw = zip.getStream(decompress: false);
    final start = raw.position;
    try {
      switch (zip.compressionMethod) {
        case CompressionType.none:
          while (!raw.isEOS) {
            counted(raw.readBytes(math.min(_chunk, raw.length)).toUint8List());
          }
        case CompressionType.deflate:
          final inflate = ZLibDecoder(raw: true).startChunkedConversion(_Sink(counted));
          while (!raw.isEOS) {
            inflate.add(raw.readBytes(math.min(_chunk, raw.length)).toUint8List());
          }
          inflate.close();
        case CompressionType.bzip2:
          throw FormatException('${file.name} is compressed in a way Curator does not read.');
      }
    } finally {
      raw.setPosition(start);
    }
  }

  static FormatException _tooBig(ArchiveFile file) => FormatException('${file.name} is too big.');
}

class _Sink implements Sink<List<int>> {
  _Sink(this._add);
  final void Function(List<int>) _add;

  @override
  void add(List<int> data) => _add(data);

  @override
  void close() {}
}
