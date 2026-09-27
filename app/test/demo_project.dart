// The bundled demo project (assets/demo/WI275 - 01 Intro.ccs), shared by the tests:
// a 44-bar 6/8 orchestral intro with its recording and a finished curation.
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:curated_score/audio_track.dart';
import 'package:curated_score/project_document.dart';

/// The demo project; tests run in app/, where the asset path resolves.
final demoProject = File(sampleProjectAsset);

final _archive = ZipDecoder().decodeBytes(demoProject.readAsBytesSync());
final _temp = Directory.systemTemp.createTempSync('demo-project-');

File _unpack(String folder) {
  final entry = _archive.files.firstWhere((f) => f.isFile && f.name.startsWith('$folder/'));
  final file = File('${_temp.path}/${entry.name.split('/').last}');
  if (!file.existsSync()) file.writeAsBytesSync(entry.content);
  return file;
}

/// Its score, unpacked (the same bytes as inside the project).
File get demoScore => _unpack('score');

/// Its recording (FLAC), unpacked.
File get demoRecording => _unpack('media');

/// The recording's length in seconds and its waveform, analysed like the app does: 3000
/// equally spaced samples a second, as SoLoud's readSamplesFromFile gives them.
/// Null where the FLAC can't be decoded (afconvert is macOS only).
Future<({double length, Waveform waveform})?> demoWaveform() async {
  if (!Platform.isMacOS) return null;
  final wav = '${_temp.path}/demo-mono.wav';
  if (!File(wav).existsSync()) {
    final r = await Process.run('/usr/bin/afconvert', ['-f', 'WAVE', '-d', 'LEI16', '-c', '1', demoRecording.path, wav]);
    if (r.exitCode != 0) return null;
  }
  final bytes = File(wav).readAsBytesSync();
  final data = ByteData.sublistView(bytes);
  // Walk the RIFF chunks: afconvert puts a padding chunk between fmt and data.
  var sampleRate = 0, offset = 12, pcm = 0, frames = 0;
  while (offset + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes, offset, offset + 4);
    final size = data.getUint32(offset + 4, Endian.little);
    if (id == 'fmt ') sampleRate = data.getUint32(offset + 12, Endian.little);
    if (id == 'data') {
      pcm = offset + 8;
      frames = size ~/ 2;
      break;
    }
    offset += 8 + size + (size & 1);
  }
  final length = frames / sampleRate;
  final n = (length * 3000).round();
  final samples = Float32List(n);
  for (var i = 0; i < n; i++) {
    samples[i] = data.getInt16(pcm + (i * frames ~/ n) * 2, Endian.little) / 32768;
  }
  return (length: length, waveform: await Waveform.analyze(samples, n / length));
}
