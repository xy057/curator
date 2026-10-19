import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

void main() {
  ArchiveFile entry(List<int> bytes, CompressionType compression) {
    final zip = ZipEncoder().encodeBytes(Archive()..add(ArchiveFile.bytes('e', bytes)..compression = compression));
    return ZipDecoder().decodeBytes(zip).findFile('e')!;
  }

  test('an entry that unpacks to more than its limit is refused, whatever size it claims', () {
    final bomb = entry(Uint8List(64 << 20), CompressionType.deflate); // 64 MB of zeros, a few dozen KB packed
    expect(() => ZipEntries.read(bomb, limit: 1 << 20), throwsFormatException);
    bomb.size = 10; // claims to be small
    expect(() => ZipEntries.read(bomb, limit: 1 << 20), throwsFormatException);

    var handed = 0;
    expect(() => ZipEntries.write(bomb, (b) => handed += b.length, limit: 1 << 20), throwsFormatException);
    expect(handed, lessThanOrEqualTo(1 << 20), reason: 'stops as the limit is reached, not after');
  });
}
