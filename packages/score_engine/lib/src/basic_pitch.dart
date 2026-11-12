import 'dart:math' as math;
import 'dart:typed_data';

/// Spotify's Basic Pitch (the ICASSP 2022 model, Apache 2.0; app/assets/basic_pitch, written by
/// Tools/make_basic_pitch_weights.py from the release's ONNX export): a small network that hears,
/// [framesPerSecond] times a second, how likely each of the piano's [keys] keys is to be sounding
/// (notes) and to be starting (onsets), whatever plays it.
///
/// It runs on windows of [windowLength] samples at [sampleRate] ([run]), as the release does:
/// a constant-Q transform of three bins a semitone (nine octaves, each a 256-sample kernel pair
/// run over the signal halved again and again), its log-power scaled to 0–1 across the window,
/// stacked with itself shifted by the first eight harmonics, then six convolutions. Everything is
/// float32 and four at a time ([Float32x4]); the frames match the release's to about 1e-5. A model
/// is for one isolate: it keeps its buffers from one window to the next.
final class BasicPitch {
  /// [weights]: nmp.bin's bytes. Throws a [FormatException] when they aren't the model's.
  BasicPitch(Uint8List weights) {
    final data = ByteData.sublistView(weights);
    if (weights.length < 8 || String.fromCharCodes(weights, 0, 4) != 'BPW1') throw const FormatException('Not Basic Pitch weights');
    final count = data.getUint32(4, Endian.little);
    final tensors = <String, Float32List>{};
    var at = 8;
    try {
      for (var i = 0; i < count; i++) {
        final name = String.fromCharCodes(weights, at + 1, at + 1 + weights[at]);
        at += 1 + weights[at];
        final rank = weights[at++];
        var size = 1;
        for (var d = 0; d < rank; d++, at += 4) {
          size *= data.getUint32(at, Endian.little);
        }
        tensors[name] = Float32List.fromList([for (var k = 0; k < size; k++) data.getFloat32(at + 4 * k, Endian.little)]);
        at += 4 * size;
      }
    } on RangeError {
      throw const FormatException('Basic Pitch weights cut short');
    }
    Float32List take(String name, int size) {
      final t = tensors[name];
      if (t == null || t.length != size) throw FormatException('Basic Pitch weights: $name');
      return t;
    }

    _real = _vectors(take('cqt.real', _octaveBins * _kernel));
    _imaginary = _vectors(take('cqt.imaginary', _octaveBins * _kernel));
    _lowPass = _vectors(take('cqt.lowPass', _kernel));
    _scale = take('cqt.scale', _bins);
    final norm = take('cqt.norm', 2);
    _normScale = norm[0];
    _normShift = norm[1];
    _Conv conv(String name, int out, int inputs, int kt, int kf, {int stride = 1}) => _Conv(
        take('$name.weight', out * inputs * kt * kf), take('$name.bias', out),
        out: out, inputs: inputs, kt: kt, kf: kf, stride: stride);
    _onset = conv('onset', 32, _harmonics.length, 5, 5, stride: 3);
    _contour = conv('contour', 8, _harmonics.length, 3, 39);
    _contourOut = conv('contour.out', 1, 8, 5, 5);
    _note = conv('note', 32, 1, 7, 7, stride: 3);
    _noteOut = conv('note.out', 1, 32, 7, 3);
    _onsetOut = conv('onset.out', 1, 33, 3, 3);
  }

  /// The weights, as the app bundles them (nmp.bin).
  static const asset = 'assets/basic_pitch/nmp.bin';

  static const sampleRate = 22050;

  /// Samples from one frame to the next.
  static const hop = 256;
  static const framesPerSecond = sampleRate / hop;

  /// The samples a window takes (2 s less a frame), and the frames it gives.
  static const windowLength = 2 * sampleRate - hop, windowFrames = 172;

  /// The keys heard, A0 (MIDI [lowestKey]) up.
  static const keys = 88, lowestKey = 21;

  static const _kernel = 256, _octaveBins = 36, _octaves = 9, _bins = 309, _contourBins = 3 * keys;

  /// Each harmonic stacked, as a shift of the transform's bins (3 a semitone): ½, 1, 2 … 7.
  static const _harmonics = [-36, 0, 36, 57, 72, 84, 93, 101];

  late final Float32x4List _real, _imaginary, _lowPass;
  late final Float32List _scale;
  late final double _normScale, _normShift;
  late final _Conv _onset, _contour, _contourOut, _note, _noteOut, _onsetOut;

  /// The frames of [samples] ([windowLength] of them at [sampleRate], mono), frame `t` centred on
  /// sample `t * hop`: for each, [keys] values of `notes` and of `onsets` (0–1). Both are the
  /// model's own buffers, good until it runs again (a window allocates none of its own).
  ({Float32List notes, Float32List onsets}) run(Float32List samples) {
    assert(samples.length == windowLength);
    const t = windowFrames;
    final stacked = _stacked(_transform(samples));
    final onsetHidden = _onset.run(stacked, t, keys)..relu();
    final contourHidden = _contour.run(stacked, t, _contourBins)..relu();
    final contour = _contourOut.run(contourHidden.planes, t, _contourBins)..sigmoid();
    final noteHidden = _note.run(contour.planes, t, keys)..relu();
    final notes = _noteOut.run(noteHidden.planes, t, keys)..sigmoid();
    final onsets = _onsetOut.run([...notes.planes, ...onsetHidden.planes], t, keys)..sigmoid();
    return (notes: notes.values, onsets: onsets.values);
  }

  final _power = Float64List(windowFrames * _bins), _scaled = Float32List(windowFrames * _bins);
  final _planes = [for (final _ in _harmonics) Float32List(windowFrames * _contourBins)];

  /// Each octave's signal halved, and its copies padded ([_shifted]), by length.
  final _halves = <int, Float32List>{}, _copies = <(int, int), (Float32List, List<Float32x4List>)>{};

  /// The constant-Q transform's log-power, scaled to 0–1 over the window and normalized as the
  /// model was trained: [windowFrames] rows of [_bins] bins, 27.5 Hz up, three a semitone.
  Float32List _transform(Float32List samples) {
    const frames = windowFrames, all = _octaves * _octaveBins, dropped = all - _bins;
    final power = _power;
    var x = samples;
    var hop = BasicPitch.hop;
    for (var o = 0; o < _octaves; o++) {
      if (o > 0) {
        x = _halved(x);
        hop ~/= 2;
      }
      // The signal mirrored half a kernel either side (frames centred), in four copies each a
      // sample further on, so a kernel's start is always a whole vector into one of them.
      final padded = _shifted(x, _kernel ~/ 2, mirror: true);
      final first = (_octaves - 1 - o) * _octaveBins; // lower octaves come first
      for (var f = 0; f < frames; f++) {
        final start = f * hop, copy = padded[start & 3], from = start >> 2;
        for (var k = 0; k < _octaveBins; k++) {
          final bin = first + k - dropped;
          if (bin < 0) continue;
          var re = Float32x4.zero(), im = Float32x4.zero();
          for (var j = 0, w = k * (_kernel ~/ 4); j < _kernel ~/ 4; j++, w++) {
            final s = copy[from + j];
            re += s * _real[w];
            im += s * _imaginary[w];
          }
          final r = re.x + re.y + re.z + re.w, i = im.x + im.y + im.z + im.w, s = _scale[bin];
          power[f * _bins + bin] = (r * r + i * i) * s * s;
        }
      }
    }
    var lowest = double.infinity, highest = double.negativeInfinity;
    for (var i = 0; i < power.length; i++) {
      final db = 10 * math.log(power[i] + 1e-10) / math.ln10;
      power[i] = db;
      lowest = math.min(lowest, db);
      highest = math.max(highest, db);
    }
    final range = highest - lowest;
    for (var i = 0; i < power.length; i++) {
      _scaled[i] = (range > 0 ? (power[i] - lowest) / range : 0) * _normScale + _normShift;
    }
    return _scaled;
  }

  /// [x] low-passed and kept one sample in two (zeros beyond its ends, as the release pads).
  Float32List _halved(Float32List x) {
    const half = (_kernel - 1) ~/ 2;
    final count = (x.length - 2) ~/ 2 + 1, out = _halves[count] ??= Float32List(count);
    final padded = _shifted(x, half);
    for (var n = 0; n < count; n++) {
      final start = 2 * n, copy = padded[start & 3], from = start >> 2;
      var sum = Float32x4.zero();
      for (var j = 0; j < _kernel ~/ 4; j++) {
        sum += copy[from + j] * _lowPass[j];
      }
      out[n] = sum.x + sum.y + sum.z + sum.w;
    }
    return out;
  }

  /// [x] with [pad] samples either side (zeros, or mirrored about its ends), and three more
  /// copies each starting a sample later; each long enough for a kernel at its last frame.
  List<Float32x4List> _shifted(Float32List x, int pad, {bool mirror = false}) {
    final length = x.length + 2 * pad + _kernel, vectors = (length + 3) ~/ 4;
    final (base, copies) = _copies[(x.length, pad)] ??= (
      Float32List(length + 3),
      [for (var s = 0; s < 4; s++) Float32x4List(vectors)],
    );
    base.setAll(pad, x); // the padding either side is zeros, or mirrored over each time
    if (mirror) {
      for (var i = 1; i <= pad; i++) {
        base[pad - i] = x[i];
        base[pad + x.length - 1 + i] = x[x.length - 1 - i];
      }
    }
    for (var s = 0; s < 4; s++) {
      Float32List.view(copies[s].buffer).setRange(0, math.min(vectors * 4, base.length - s), base, s);
    }
    return copies;
  }

  /// [transform]'s rows stacked with themselves shifted by each harmonic: [_harmonics] planes of
  /// [windowFrames] rows of [_contourBins] (those shifted past the transform's ends stay zero).
  List<Float32List> _stacked(Float32List transform) {
    for (final (h, shift) in _harmonics.indexed) {
      final from = math.max(0, -shift), to = math.min(_contourBins, _bins - shift);
      for (var t = 0; t < windowFrames; t++) {
        _planes[h].setRange(t * _contourBins + from, t * _contourBins + to, transform, t * _bins + from + shift);
      }
    }
    return _planes;
  }

  static Float32x4List _vectors(Float32List values) => Float32x4List.view(Float32List.fromList(values).buffer);
}

/// A convolution over time (rows) and frequency (columns), padded as Keras's "same", striding
/// [stride] columns.
///
/// Each output vector (four columns) is summed in registers over every input, row and column of
/// the kernel, eight output planes at a time, so an input vector is read once for eight of them.
/// The inputs are first laid out so each of those reads is a whole vector: for each input, each
/// column phase of the stride and each shift of 0–3 columns, its rows padded by the kernel.
final class _Conv {
  _Conv(Float32List weights, Float32List bias, {required this.out, required this.inputs, required this.kt, required this.kf, required this.stride})
      : _bias = [for (final b in bias) Float32x4.splat(b)],
        _weights = Float32x4List(out * inputs * kt * kf) {
    // [group of 8 planes][term: input, row, column][plane in the group]
    final group = math.min(out, 8), terms = inputs * kt * kf;
    for (var o = 0; o < out; o++) {
      for (var i = 0; i < terms; i++) {
        _weights[(o ~/ group * terms + i) * group + o % group] = Float32x4.splat(weights[o * terms + i]);
      }
    }
  }

  final int out, inputs, kt, kf, stride;
  final List<Float32x4> _bias;
  final Float32x4List _weights;

  /// The inputs laid out, where each term reads them, and the output planes: kept from one run
  /// to the next (a window's are the same size each time; what is beyond the inputs' edges is
  /// never written, so stays zero).
  ({int rows, int columns, int width, Float32List laid, Int32List at, _Planes result})? _kept;

  /// [input]'s planes ([inputs] of them, [rows] rows each) convolved into [out] planes of [rows]
  /// rows of [columns] (a multiple of 4).
  _Planes run(List<Float32List> input, int rows, int columns) {
    assert(input.length == inputs && columns % 4 == 0 && (out == 1 || out % 8 == 0));
    final width = input.first.length ~/ rows;
    final left = math.max(0, (columns - 1) * stride + kf - width) ~/ 2, top = kt ~/ 2;
    final vectors = columns ~/ 4, plane = rows * vectors;
    final reach = (kf - 1) ~/ stride; // how many vectors' worth of columns a kernel row spans
    final rowVectors = vectors + (reach >> 2) + 1, padded = rows + kt - 1, copy = padded * rowVectors;

    final terms = inputs * kt * kf;
    var kept = _kept;
    if (kept == null || kept.rows != rows || kept.columns != columns || kept.width != width) {
      // Where each term (input, kernel row, kernel column) reads, in vectors, for output (0, 0).
      final at = Int32List(terms);
      for (var c = 0, i = 0; c < inputs; c++) {
        for (var dt = 0; dt < kt; dt++) {
          for (var df = 0; df < kf; df++, i++) {
            final q = df ~/ stride;
            at[i] = ((c * stride + df % stride) * 4 + (q & 3)) * copy + dt * rowVectors + (q >> 2);
          }
        }
      }
      _kept = kept = (
        rows: rows,
        columns: columns,
        width: width,
        laid: Float32List(inputs * stride * 4 * copy * 4),
        at: at,
        result: _Planes(out, rows, columns),
      );
    }

    // laid[((c * stride + m) * 4 + k) * copy + r * rowVectors + u] (in vectors' lanes): input c's
    // row r - top, column stride * (u + k) + m - left; zero beyond its edges.
    final laid = kept.laid, at = kept.at;
    for (var c = 0; c < inputs; c++) {
      final x = input[c];
      for (var m = 0; m < stride; m++) {
        for (var k = 0; k < 4; k++) {
          final base = ((c * stride + m) * 4 + k) * copy * 4;
          for (var r = 0; r < rows; r++) {
            final to = base + (r + top) * rowVectors * 4, from = r * width;
            final first = math.max(0, ((left - m) / stride - k).ceil());
            final last = math.min(rowVectors * 4 - 1, ((width - 1 + left - m) / stride - k).floor());
            if (stride == 1) {
              if (last >= first) laid.setRange(to + first, to + last + 1, x, from + first + k - left);
            } else {
              for (var u = first; u <= last; u++) {
                laid[to + u] = x[from + stride * (u + k) + m - left];
              }
            }
          }
        }
      }
    }
    final x = Float32x4List.view(laid.buffer);

    final result = kept.result;
    final sums = Float32x4List.view(result.values.buffer), w = _weights;
    if (out == 1) {
      final bias = _bias[0];
      for (var r = 0; r < rows; r++) {
        for (var j = 0; j < vectors; j++) {
          final p = r * rowVectors + j;
          var a = bias;
          for (var i = 0; i < terms; i++) {
            a += w[i] * x[at[i] + p];
          }
          sums[r * vectors + j] = a;
        }
      }
      return result;
    }
    for (var g = 0; g < out; g += 8) {
      final b0 = _bias[g], b1 = _bias[g + 1], b2 = _bias[g + 2], b3 = _bias[g + 3];
      final b4 = _bias[g + 4], b5 = _bias[g + 5], b6 = _bias[g + 6], b7 = _bias[g + 7];
      final first = g * terms;
      for (var r = 0; r < rows; r++) {
        for (var j = 0; j < vectors; j++) {
          final p = r * rowVectors + j;
          var a0 = b0, a1 = b1, a2 = b2, a3 = b3, a4 = b4, a5 = b5, a6 = b6, a7 = b7;
          for (var i = 0, k = first; i < terms; i++, k += 8) {
            final v = x[at[i] + p];
            a0 += w[k] * v;
            a1 += w[k + 1] * v;
            a2 += w[k + 2] * v;
            a3 += w[k + 3] * v;
            a4 += w[k + 4] * v;
            a5 += w[k + 5] * v;
            a6 += w[k + 6] * v;
            a7 += w[k + 7] * v;
          }
          final s = g * plane + r * vectors + j;
          sums[s] = a0;
          sums[s + plane] = a1;
          sums[s + 2 * plane] = a2;
          sums[s + 3 * plane] = a3;
          sums[s + 4 * plane] = a4;
          sums[s + 5 * plane] = a5;
          sums[s + 6 * plane] = a6;
          sums[s + 7 * plane] = a7;
        }
      }
    }
    return result;
  }
}

/// [count] planes of [rows] rows of [columns], one after another in [values].
final class _Planes {
  _Planes(this.count, this.rows, this.columns) : values = Float32List(count * rows * columns);

  final int count, rows, columns;
  final Float32List values;

  List<Float32List> get planes => [for (var p = 0; p < count; p++) Float32List.sublistView(values, p * rows * columns, (p + 1) * rows * columns)];

  void relu() {
    for (var i = 0; i < values.length; i++) {
      if (values[i] < 0) values[i] = 0;
    }
  }

  void sigmoid() {
    for (var i = 0; i < values.length; i++) {
      values[i] = 1 / (1 + math.exp(-values[i]));
    }
  }
}
