import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Reads the sample rate from the header of the files SoLoud decodes (WAV, FLAC, MP3, Ogg).
///
/// SoLoud reads a waveform in whole-frame steps (`totalFrames ~/ numSamples`), so asking for
/// "3000 samples a second" of a 44.1 kHz file gives a step of 14 frames, not 14.7: the samples
/// then cover only 95 % of the file and the waveform drifts ahead of the audio. Knowing the
/// real rate lets [samplingPlan] ask for a count whose step is exact.
abstract final class AudioFormat {
  /// The file's sample rate in Hz, or null when the header isn't recognised.
  static int? sampleRateOf(String path) {
    RandomAccessFile? file;
    try {
      file = File(path).openSync();
      final length = file.lengthSync();
      Uint8List read(int offset, int count) {
        if (offset >= length) return Uint8List(0);
        file!.setPositionSync(offset);
        return file.readSync(math.min(count, length - offset));
      }

      var start = 0;
      final head = read(0, 10);
      if (_ascii(head, 0, 'ID3') && head.length >= 10) {
        // ID3v2 tag (MP3, sometimes FLAC): skip it, it can hold megabytes of artwork.
        final size = (head[6] & 0x7f) << 21 | (head[7] & 0x7f) << 14 | (head[8] & 0x7f) << 7 | (head[9] & 0x7f);
        start = 10 + size + ((head[5] & 0x10) != 0 ? 10 : 0);
      }
      final bytes = read(start, 1 << 16);
      if (_ascii(bytes, 0, 'RIFF') || _ascii(bytes, 0, 'RF64') || _ascii(bytes, 0, 'BW64')) {
        return _wav(read, start);
      }
      return fromHeader(bytes);
    } catch (_) {
      return null;
    } finally {
      file?.closeSync();
    }
  }

  /// The sample rate from the first bytes of a FLAC, Ogg or MP3 stream (after any ID3 tag).
  static int? fromHeader(Uint8List b) {
    final data = ByteData.sublistView(b);
    if (_ascii(b, 0, 'fLaC') && b.length >= 8 + 13) {
      // STREAMINFO is always the first metadata block: 20 bits of rate after 10 bytes.
      return b[18] << 12 | b[19] << 4 | b[20] >> 4;
    }
    if (_ascii(b, 0, 'OggS') && b.length > 27) {
      final packet = 27 + b[26];
      if (_ascii(b, packet, '\x01vorbis') && b.length >= packet + 16) {
        return data.getUint32(packet + 12, Endian.little);
      }
      if (_ascii(b, packet, 'OpusHead')) return 48000; // Opus always decodes at 48 kHz
      return null;
    }
    return _mp3(b);
  }

  /// WAV: walks the RIFF chunks to `fmt ` (tools put LIST or bext chunks first).
  static int? _wav(Uint8List Function(int offset, int count) read, int start) {
    var offset = start + 12;
    for (var i = 0; i < 64; i++) {
      final header = read(offset, 16);
      if (header.length < 8) return null;
      final size = ByteData.sublistView(header).getUint32(4, Endian.little);
      if (_ascii(header, 0, 'fmt ')) {
        return header.length >= 16 ? ByteData.sublistView(header).getUint32(12, Endian.little) : null;
      }
      offset += 8 + size + (size & 1);
    }
    return null;
  }

  static const _mpeg1Rates = [44100, 48000, 32000];

  /// MP3: the first valid MPEG audio frame header.
  static int? _mp3(Uint8List b) {
    for (var i = 0; i + 3 < b.length; i++) {
      if (b[i] != 0xff || (b[i + 1] & 0xe0) != 0xe0) continue;
      final version = (b[i + 1] >> 3) & 3; // 3: MPEG-1, 2: MPEG-2, 0: MPEG-2.5
      final layer = (b[i + 1] >> 1) & 3;
      final bitrate = b[i + 2] >> 4;
      final rate = (b[i + 2] >> 2) & 3;
      if (version == 1 || layer == 0 || bitrate == 0 || bitrate == 15 || rate == 3) continue;
      return _mpeg1Rates[rate] >> (version == 3 ? 0 : version == 2 ? 1 : 2);
    }
    return null;
  }

  static bool _ascii(Uint8List b, int offset, String text) {
    if (offset + text.length > b.length) return false;
    for (var i = 0; i < text.length; i++) {
      if (b[offset + i] != text.codeUnitAt(i)) return false;
    }
    return true;
  }

  /// How many samples to ask SoLoud for, and the rate they then really have, so the waveform
  /// lines up with the audio: the step between samples is a whole number of frames.
  /// Without a known [sampleRate], asks for [target] a second and trusts it (the old way).
  static ({int count, double rate}) samplingPlan(double seconds, int? sampleRate, {double target = 3000}) {
    if (sampleRate == null || sampleRate <= 0) {
      final count = math.max(1, (seconds * target).round());
      return (count: count, rate: count / math.max(seconds, 1e-3));
    }
    final step = math.max(1, (sampleRate / target).round());
    final frames = (seconds * sampleRate).round();
    return (count: math.max(1, frames ~/ step), rate: sampleRate / step);
  }
}
