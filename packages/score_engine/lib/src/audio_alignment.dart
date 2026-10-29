import 'dart:math' as math;
import 'dart:typed_data';

import 'scroll_map.dart';
import 'sounding_notes.dart';
import 'sync_map.dart';

/// How much of each pitch class a recording sounds, frame by frame, [frameRate] frames a second,
/// frame `f` centred on second `f / frameRate`: for each, [values] numbers, a short-time Fourier
/// transform's energy summed by the pitch class each bin is nearest (C to B), twice: over a long
/// window (what sounds: chroma) and a short one (when it starts: onsets).
///
/// The samples go in as they are read ([add], then [finish]), so a long recording never has to
/// be held whole: they are low-passed and kept one in [_factor] (about 5.5 kHz, enough for every
/// fundamental below C7), then cut into Hann windows [_hop] apart. Its state is plain data, so it
/// can go to an isolate and back with each block.
class AudioChroma {
  AudioChroma(double sampleRate)
      : _factor = math.max(1, (sampleRate / 5512.5).round()),
        _kept = Float32List(_long ~/ 2) {
    final rate = sampleRate / _factor;
    _hop = math.max(1, (rate / targetFrameRate).round());
    frameRate = rate / _hop;
    _filter = _lowPass(_factor);
    _input = Float32List(_filter.length ~/ 2); // the filter's first output is the first sample's
    Int8List classes(int window, double lowest) => Int8List.fromList([
          for (var k = 0; k <= window ~/ 2; k++)
            if (k * rate / window case final hz when hz >= lowest && hz <= 2500)
              (69 + 12 * math.log(hz / 440) / math.ln2).round() % 12
            else
              -1,
        ]);
    _longClasses = classes(_long, 80);
    _shortClasses = classes(_short, 250); // coarser bins: only where they are a semitone or less
  }

  /// About how many frames a second it gives ([frameRate] is exact).
  static const targetFrameRate = 20.0;

  /// The numbers a frame has: 12 of chroma, then 12 of onsets.
  static const values = 24;

  static const _long = 2048, _short = 512;

  /// About how long a frame's long window is.
  static const windowSeconds = _long / 5512.5;

  /// Frames a second, exactly.
  late final double frameRate;

  final int _factor;
  late final int _hop;
  late final Float32List _filter;
  late final Int8List _longClasses, _shortClasses;

  /// Input not yet low-passed (the filter's half length before the next sample kept, and on).
  late Float32List _input;

  /// Samples kept and not yet in a frame (the first window starts half a window early, in
  /// silence, so frame 0 is centred on the first sample).
  Float32List _kept;

  /// Adds the next [samples] (mono, at the sample rate given) and returns the frames they
  /// complete, [values] numbers each.
  Float32List add(Float32List samples) {
    _decimate(samples);
    return _frames();
  }

  /// The frames left once the recording has ended.
  Float32List finish() {
    _decimate(Float32List(_filter.length ~/ 2));
    _kept = _joined(_kept, Float32List(_long ~/ 2));
    return _frames();
  }

  void _decimate(Float32List samples) {
    final input = _joined(_input, samples);
    if (_factor == 1) {
      _kept = _joined(_kept, input);
      _input = Float32List(0);
      return;
    }
    final count = math.max(0, (input.length - _filter.length) ~/ _factor + 1);
    final out = Float32List(count);
    for (var o = 0; o < count; o++) {
      final at = o * _factor;
      var sum = 0.0;
      for (var k = 0; k < _filter.length; k++) {
        sum += _filter[k] * input[at + k];
      }
      out[o] = sum;
    }
    _input = Float32List.fromList(Float32List.sublistView(input, count * _factor));
    _kept = _joined(_kept, out);
  }

  Float32List _frames() {
    final count = _kept.length < _long ? 0 : (_kept.length - _long) ~/ _hop + 1;
    final out = Float32List(count * values);
    final re = Float64List(_long), im = Float64List(_long);
    void spectrum(int at, int window, Float64List hann, Int8List classes, int to) {
      for (var i = 0; i < window; i++) {
        re[i] = _kept[at + i] * hann[i];
        im[i] = 0;
      }
      _fft(re, im, window);
      for (var k = 0; k < classes.length; k++) {
        final c = classes[k];
        if (c >= 0) out[to + c] += re[k] * re[k] + im[k] * im[k];
      }
    }

    for (var f = 0; f < count; f++) {
      spectrum(f * _hop, _long, _longHann, _longClasses, f * values);
      spectrum(f * _hop + (_long - _short) ~/ 2, _short, _shortHann, _shortClasses, f * values + 12);
    }
    _kept = Float32List.fromList(Float32List.sublistView(_kept, count * _hop));
    return out;
  }

  static Float32List _joined(Float32List a, Float32List b) => a.isEmpty
      ? Float32List.fromList(b)
      : b.isEmpty
          ? a
          : (Float32List(a.length + b.length)
            ..setAll(0, a)
            ..setAll(a.length, b));

  /// A windowed-sinc low-pass for keeping one sample in [factor]: its gain 1, passing up to
  /// 90 % of the new Nyquist frequency.
  static Float32List _lowPass(int factor) {
    if (factor == 1) return Float32List.fromList([1]);
    final half = 6 * factor, cutoff = 0.45 / factor;
    final h = Float32List(2 * half + 1);
    var sum = 0.0;
    for (var k = 0; k < h.length; k++) {
      final x = (k - half).toDouble();
      final sinc = x == 0 ? 2 * cutoff : math.sin(2 * math.pi * cutoff * x) / (math.pi * x);
      final blackman = 0.42 - 0.5 * math.cos(2 * math.pi * k / (h.length - 1)) + 0.08 * math.cos(4 * math.pi * k / (h.length - 1));
      sum += h[k] = sinc * blackman;
    }
    for (var k = 0; k < h.length; k++) {
      h[k] /= sum;
    }
    return h;
  }

  static Float64List _hann(int n) => Float64List.fromList([for (var i = 0; i < n; i++) 0.5 - 0.5 * math.cos(2 * math.pi * i / n)]);
  static final _longHann = _hann(_long), _shortHann = _hann(_short);

  /// e^(-2πik/[_long]) for k below half of it, real and imaginary in turn.
  static final _twiddles = Float64List.fromList([
    for (var k = 0; k < _long ~/ 2; k++) ...[math.cos(-2 * math.pi * k / _long), math.sin(-2 * math.pi * k / _long)],
  ]);

  /// In place, radix 2, over the first [n] (a power of two up to [_long]) of [re] and [im].
  static void _fft(Float64List re, Float64List im, int n) {
    for (var i = 1, j = 0; i < n; i++) {
      var bit = n >> 1;
      for (; j & bit != 0; bit >>= 1) {
        j ^= bit;
      }
      j ^= bit;
      if (i < j) {
        final r = re[i], m = im[i];
        re[i] = re[j];
        im[i] = im[j];
        re[j] = r;
        im[j] = m;
      }
    }
    for (var size = 2; size <= n; size <<= 1) {
      final half = size >> 1, step = _long ~/ size;
      for (var start = 0; start < n; start += size) {
        for (var k = 0; k < half; k++) {
          final wr = _twiddles[2 * k * step], wi = _twiddles[2 * k * step + 1];
          final a = start + k, b = a + half;
          final xr = re[b] * wr - im[b] * wi, xi = re[b] * wi + im[b] * wr;
          re[b] = re[a] - xr;
          im[b] = im[a] - xi;
          re[a] += xr;
          im[a] += xi;
        }
      }
    }
  }
}

/// Lines a recording up with the score (Align, the Audio tab): the score's notes are laid out
/// as played ([passes], the repeats taken) and made into the features a recording of them would
/// have, both are matched frame by frame by multiscale dynamic time warping, and the path is
/// thinned into a [SyncMap]'s anchors: one at a bar where the tempo changes, a warp where a pass
/// ends, one at the end.
///
/// Chroma (which pitch classes sound) finds the way through the piece; onsets (which start)
/// place it within a harmony held or repeated, where chroma alone can't tell one bar from the
/// next. Both count at every frame rate the warping is solved at: a bar chroma misplaces at a
/// coarse one is further off than the finer ones' band reaches.
abstract final class AudioAlignment {
  /// The anchors for [audio] ([AudioChroma]'s frames, [frameRate] a second) against [notes], in
  /// a score of [measureStarts] (the end of the last bar included) played as [passes]. Bars
  /// whose times a straight line through their neighbours' puts within [tolerance] seconds
  /// get none. Empty when the recording is silent or the score has no notes.
  static List<SyncAnchor> anchors({
    required Float32List audio,
    required double frameRate,
    required List<SoundingNote> notes,
    required List<double> measureStarts,
    required List<ScorePass> passes,
    double tolerance = 0.03,
  }) {
    const v = AudioChroma.values;
    final frames = audio.length ~/ v;
    final played = passes.fold(0.0, (sum, p) => sum + p.end - p.start);
    if (frames < 8 || played <= 0 || notes.isEmpty) return const [];

    // Where the music sounds: the recording's silence (or noise, 40 dB under its loud frames)
    // either side is left out.
    final loudness = Float64List(frames);
    for (var f = 0; f < frames; f++) {
      for (var c = 0; c < 12; c++) {
        loudness[f] += audio[f * v + c];
      }
    }
    final loud = _percentile(loudness, 0.95);
    if (loud <= 0) return const [];
    var first = 0, last = frames - 1;
    while (first < last && loudness[first] < loud * 1e-4) {
      first++;
    }
    while (last > first && loudness[last] < loud * 1e-4) {
      last--;
    }
    final heard = last - first + 1;
    if (heard < 8) return const [];
    final chroma = Float32List(heard * 12), short = Float32List(heard * 12);
    for (var f = 0; f < heard; f++) {
      for (var c = 0; c < 12; c++) {
        chroma[f * 12 + c] = audio[(first + f) * v + c];
        short[f * 12 + c] = audio[(first + f) * v + 12 + c];
      }
    }

    // The score as many frames as the music heard, so the path runs about diagonally.
    final perFrame = played / heard;
    final score = _scoreFrames(notes, passes, perFrame, heard, frameRate: frameRate);
    final path = _Warping.path(_features(score.chroma, heard), _features(chroma, heard), heard, heard,
        onsets: (_onsets(_compressed(score.onsets, heard), heard), _onsets(_rises(short, heard), heard)));

    // When each score frame sounds: the mean of the recording's frames the path pairs it with,
    // smoothed over half a second, less at the ends (so they stay where they are heard). Both
    // keep the times in order.
    final sum = Float64List(heard), count = Int32List(heard);
    for (var k = 0; k < path.length; k += 2) {
      sum[path[k]] += path[k + 1];
      count[path[k]]++;
    }
    final raw = Float64List.fromList([for (var i = 0; i < heard; i++) sum[i] / count[i]]);
    final reach = math.max(1, (frameRate / 4).round());
    final times = Float64List(heard);
    for (var i = 0; i < heard; i++) {
      final r = math.min(reach, math.min(i, heard - 1 - i));
      var s = 0.0;
      for (var k = i - r; k <= i + r; k++) {
        s += raw[k];
      }
      times[i] = (first + s / (2 * r + 1)) / frameRate;
    }
    double secondsAt(double performed) {
      final i = (performed / perFrame).clamp(0.0, heard - 1.0);
      final lo = i.floor(), hi = math.min(heard - 1, lo + 1);
      return times[lo] + (i - lo) * (times[hi] - times[lo]);
    }

    // Every bar as played; the first of a pass after the first is the warp that leads to it.
    final points = <_Point>[];
    var offset = 0.0;
    for (final (k, pass) in passes.indexed) {
      for (final start in measureStarts) {
        if (start < pass.start - 1e-9 || start >= pass.end - 1e-9 || (k > 0 && start <= pass.start + 1e-9)) continue;
        final p = offset + start - pass.start;
        points.add(_Point(p, SyncAnchor(start, secondsAt(p))));
      }
      offset += pass.end - pass.start;
      final next = k + 1 < passes.length ? passes[k + 1].start : null;
      // The final barline is where the music stops (a last chord held as long as the player
      // likes is still the last bar's).
      final seconds = next == null ? math.max(secondsAt(offset), (last + 0.5) / frameRate) : secondsAt(offset);
      points.add(_Point(offset, SyncAnchor(pass.end, seconds, jumpTo: next), keep: true));
    }
    points.first.keep = true;

    // Thinned: a bar keeps its anchor when leaving it out would put a bar between the anchors
    // either side further than [tolerance] from where the alignment heard it.
    final kept = <_Point>[points.first];
    var from = 0; // the last kept
    for (var e = 1; e < points.length; e++) {
      final a = points[from], b = points[e].keep ? points[e] : points[e + 1];
      bool fits(_Point m) {
        final t = a.anchor.seconds + (m.performed - a.performed) / (b.performed - a.performed) * (b.anchor.seconds - a.anchor.seconds);
        return (t - m.anchor.seconds).abs() <= tolerance;
      }

      if (points[e].keep || !points.sublist(from + 1, e + 1).every(fits)) {
        kept.add(points[e]);
        from = e;
      }
    }

    // Strictly later each time, as a sync map keeps them.
    final out = <SyncAnchor>[];
    for (final p in kept) {
      final a = p.anchor;
      out.add(out.isEmpty || a.seconds > out.last.seconds + 0.01 ? a : a.at(out.last.seconds + 0.01));
    }
    return out;
  }

  /// At each of [frames] score frames, [perFrame] played quarters apart (about the recording's
  /// [frameRate]): the pitch classes sounding (`chroma`: each note its own class, with a little
  /// of its third and fifth harmonics', a fifth and a third above, dying away from its start
  /// (a tie's, from the note it carries on) to a third over about a second, as most instruments
  /// do, and smoothed by a Hann window as long as the recording's long windows), and those of the
  /// notes starting (`onsets`, a tie's carrying on not one).
  static ({Float32List chroma, Float32List onsets}) _scoreFrames(
      List<SoundingNote> notes, List<ScorePass> passes, double perFrame, int frames,
      {required double frameRate}) {
    final sounding = Float32List(frames * 12), onsets = Float32List(frames * 12);
    void add(Float32List to, int f, int c, double amount) {
      to[f * 12 + c] += amount;
      to[f * 12 + (c + 7) % 12] += 0.3 * amount;
      to[f * 12 + (c + 4) % 12] += 0.15 * amount;
    }

    var offset = 0.0;
    for (final pass in passes) {
      final struck = <(String, int), double>{}; // where each part's pitch was last struck
      for (final n in notes) {
        final origin = n.tied ? struck[(n.partId, n.midi)] ?? n.start : n.start;
        struck[(n.partId, n.midi)] = origin;
        final start = math.max(n.start, pass.start), end = math.min(n.end, pass.end);
        if (end <= start) continue;
        final from = ((offset + start - pass.start) / perFrame).ceil();
        final to = math.min(frames - 1, ((offset + end - pass.start) / perFrame).ceil() - 1);
        final c = n.midi % 12, at = (offset + math.max(origin, pass.start) - pass.start) / perFrame;
        for (var f = math.max(0, from); f <= to; f++) {
          add(sounding, f, c, 0.3 + 0.7 * math.exp(-(f - at) / frameRate));
        }
        final onset = ((offset + start - pass.start) / perFrame).round();
        if (!n.tied && start == n.start && onset < frames) add(onsets, onset, c, 1);
      }
      offset += pass.end - pass.start;
    }

    final half = math.max(1, (AudioChroma.windowSeconds * frameRate / 2).round());
    final weights = [for (var k = -half; k <= half; k++) 0.5 + 0.5 * math.cos(math.pi * k / (half + 1))];
    final chroma = Float32List(frames * 12);
    for (var f = 0; f < frames; f++) {
      for (var k = -half; k <= half; k++) {
        final g = f + k;
        if (g < 0 || g >= frames) continue;
        final w = weights[k + half];
        for (var c = 0; c < 12; c++) {
          chroma[f * 12 + c] += w * sounding[g * 12 + c];
        }
      }
    }
    return (chroma: chroma, onsets: onsets);
  }

  /// [energy]'s [frames] frames log-compressed against its loud frames: 1 + 100 × the share of
  /// a loud frame's energy, as a log.
  static Float32List _compressed(Float32List energy, int frames) {
    final totals = Float64List(frames);
    for (var f = 0; f < frames; f++) {
      for (var c = 0; c < 12; c++) {
        totals[f] += energy[f * 12 + c];
      }
    }
    final loud = math.max(1e-12, _percentile(totals, 0.95));
    return Float32List.fromList([for (final e in energy) math.log(1 + 100 * e / loud)]);
  }

  /// Chroma features: unit vectors of [energy] compressed; a silent frame is every class alike.
  static Float32List _features(Float32List energy, int frames) {
    final out = _compressed(energy, frames);
    for (var f = 0; f < frames; f++) {
      var norm = 0.0;
      for (var c = 0; c < 12; c++) {
        norm += out[f * 12 + c] * out[f * 12 + c];
      }
      norm = math.sqrt(norm);
      for (var c = 0; c < 12; c++) {
        out[f * 12 + c] = norm < 1e-3 ? 1 / math.sqrt(12) : out[f * 12 + c] / norm;
      }
    }
    return out;
  }

  /// How much each class of [energy] rises from one frame to the next, compressed.
  static Float32List _rises(Float32List energy, int frames) {
    final level = _compressed(energy, frames);
    final out = Float32List(frames * 12);
    for (var f = 1; f < frames; f++) {
      for (var c = 0; c < 12; c++) {
        out[f * 12 + c] = math.max(0, level[f * 12 + c] - level[(f - 1) * 12 + c]);
      }
    }
    return out;
  }

  /// Onset features from [rises]: each rise dying away over four frames (so an onset a frame
  /// early or late still meets its own), scaled by the largest within a second and a half
  /// either side (a soft passage's onsets count as a loud one's), never by less than a fifth
  /// of a loud frame's.
  static Float32List _onsets(Float32List rises, int frames) {
    const decay = [1.0, 0.87, 0.71, 0.5];
    final held = Float32List(frames * 12);
    final norms = Float64List(frames);
    for (var f = 0; f < frames; f++) {
      var norm = 0.0;
      for (var c = 0; c < 12; c++) {
        var s = 0.0;
        for (var k = 0; k < decay.length && k <= f; k++) {
          s += decay[k] * rises[(f - k) * 12 + c];
        }
        held[f * 12 + c] = s;
        norm += s * s;
      }
      norms[f] = math.sqrt(norm);
    }
    final floor = math.max(1e-6, 0.2 * _percentile(norms, 0.95));
    final reach = 30; // frames
    for (var f = 0; f < frames; f++) {
      var most = floor;
      for (var g = math.max(0, f - reach); g <= math.min(frames - 1, f + reach); g++) {
        most = math.max(most, norms[g]);
      }
      for (var c = 0; c < 12; c++) {
        held[f * 12 + c] /= most;
      }
    }
    return held;
  }

  static double _percentile(Float64List values, double p) {
    final sorted = Float64List.fromList(values)..sort();
    return sorted[((sorted.length - 1) * p).round()];
  }
}

class _Point {
  _Point(this.performed, this.anchor, {this.keep = false});

  /// Played quarters from the start.
  final double performed;
  final SyncAnchor anchor;
  bool keep;
}

/// Dynamic time warping of two feature sequences, solved coarse to fine (multiscale DTW): a full
/// table at a frame rate low enough to afford, then at each finer one only a band around the
/// path the coarser found.
abstract final class _Warping {
  static const _factor = 4, _coarsest = 2500, _radius = 6;

  /// The path from (0, 0) to (n - 1, m - 1) pairing [x]'s [n] frames with [y]'s [m] (unit
  /// vectors, 12 values each), as (i, j) pairs in order. With [onsets] (one sequence of 12
  /// values a frame for each), a cell also costs 1.5 times the squared distance of its onsets
  /// (at a coarser rate, the strongest of each class the frame takes in).
  static Int32List path(Float32List x, Float32List y, int n, int m, {(Float32List, Float32List)? onsets}) {
    if (math.max(n, m) <= _coarsest || math.min(n, m) < 2 * _factor) {
      return _banded(x, y, n, m, Int32List(n), Int32List(n)..fillRange(0, n, m - 1), onsets);
    }
    final cn = (n + _factor - 1) ~/ _factor, cm = (m + _factor - 1) ~/ _factor;
    final coarse = path(_pooled(x, n), _pooled(y, m), cn, cm,
        onsets: onsets == null ? null : (_strongest(onsets.$1, n), _strongest(onsets.$2, m)));
    final lo = Int32List(n)..fillRange(0, n, m), hi = Int32List(n)..fillRange(0, n, -1);
    for (var k = 0; k < coarse.length; k += 2) {
      final i = coarse[k], j = coarse[k + 1];
      for (var a = i * _factor; a < math.min(n, (i + 1) * _factor); a++) {
        lo[a] = math.min(lo[a], j * _factor);
        hi[a] = math.max(hi[a], math.min(m - 1, (j + 1) * _factor - 1));
      }
    }
    final wideLo = Int32List(n), wideHi = Int32List(n);
    for (var i = 0; i < n; i++) {
      var l = m, h = -1;
      for (var a = math.max(0, i - _radius); a <= math.min(n - 1, i + _radius); a++) {
        l = math.min(l, lo[a]);
        h = math.max(h, hi[a]);
      }
      wideLo[i] = math.max(0, l - _radius);
      wideHi[i] = math.min(m - 1, h + _radius);
    }
    wideLo[0] = 0;
    wideHi[n - 1] = m - 1;
    return _banded(x, y, n, m, wideLo, wideHi, onsets);
  }

  /// [frames] frames of 12 averaged [_factor] at a time and made unit vectors again.
  static Float32List _pooled(Float32List f, int frames) {
    final count = (frames + _factor - 1) ~/ _factor;
    final out = Float32List(count * 12);
    for (var i = 0; i < frames; i++) {
      for (var c = 0; c < 12; c++) {
        out[i ~/ _factor * 12 + c] += f[i * 12 + c];
      }
    }
    for (var i = 0; i < count; i++) {
      var norm = 0.0;
      for (var c = 0; c < 12; c++) {
        norm += out[i * 12 + c] * out[i * 12 + c];
      }
      norm = math.sqrt(norm);
      for (var c = 0; c < 12; c++) {
        out[i * 12 + c] = norm < 1e-9 ? 1 / math.sqrt(12) : out[i * 12 + c] / norm;
      }
    }
    return out;
  }

  /// [frames] frames of 12 onsets, the strongest of each class in every [_factor].
  static Float32List _strongest(Float32List f, int frames) {
    final out = Float32List((frames + _factor - 1) ~/ _factor * 12);
    for (var i = 0; i < frames; i++) {
      for (var c = 0; c < 12; c++) {
        final k = i ~/ _factor * 12 + c;
        out[k] = math.max(out[k], f[i * 12 + c]);
      }
    }
    return out;
  }

  /// The cheapest path through the cells of row i from column [lo]`[i]` to [hi]`[i]`, by steps
  /// of one frame in either sequence or both (weighted 1.5, 1.5 and 2, as synctoolbox does, so
  /// no tempo is favoured), each cell costing 1 minus the cosine of its frames (and its onsets'
  /// distance, see [path]).
  static Int32List _banded(Float32List x, Float32List y, int n, int m, Int32List lo, Int32List hi, (Float32List, Float32List)? onsets) {
    final starts = Int32List(n + 1);
    for (var i = 0; i < n; i++) {
      starts[i + 1] = starts[i] + math.max(0, hi[i] - lo[i] + 1);
    }
    final steps = Uint8List(starts[n]); // 0: both, 1: x only (from the row before), 2: y only
    var previous = Float64List(0);
    for (var i = 0; i < n; i++) {
      final l = lo[i], h = hi[i];
      final current = Float64List(math.max(0, h - l + 1));
      final pl = i > 0 ? lo[i - 1] : 0, ph = i > 0 ? hi[i - 1] : -1;
      for (var j = l; j <= h; j++) {
        var dot = 0.0;
        for (var c = 0; c < 12; c++) {
          dot += x[i * 12 + c] * y[j * 12 + c];
        }
        var cost = math.max(0.0, 1 - dot);
        if (onsets case (final ox, final oy)) {
          var d = 0.0;
          for (var c = 0; c < 12; c++) {
            final e = ox[i * 12 + c] - oy[j * 12 + c];
            d += e * e;
          }
          cost += 1.5 * d;
        }
        var best = double.infinity, step = 0;
        if (i == 0 && j == 0) best = cost;
        if (i > 0 && j > 0 && j - 1 >= pl && j - 1 <= ph) {
          best = previous[j - 1 - pl] + 2 * cost;
        }
        if (i > 0 && j >= pl && j <= ph && previous[j - pl] + 1.5 * cost < best) {
          best = previous[j - pl] + 1.5 * cost;
          step = 1;
        }
        if (j > l && current[j - 1 - l] + 1.5 * cost < best) {
          best = current[j - 1 - l] + 1.5 * cost;
          step = 2;
        }
        current[j - l] = best;
        steps[starts[i] + j - l] = step;
      }
      previous = current;
    }

    final out = <int>[];
    var i = n - 1, j = m - 1;
    while (true) {
      out
        ..add(j)
        ..add(i);
      if (i == 0 && j == 0) break;
      switch (steps[starts[i] + j - lo[i]]) {
        case 0:
          i--;
          j--;
        case 1:
          i--;
        default:
          j--;
      }
    }
    return Int32List.fromList(out.reversed.toList());
  }
}
