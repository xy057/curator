import 'dart:math' as math;
import 'dart:typed_data';

import 'basic_pitch.dart';
import 'scroll_map.dart';
import 'sounding_notes.dart';
import 'sync_map.dart';

/// What Align hears of a recording: [BasicPitch]'s notes and onsets, [frameRate] frames a second,
/// frame `a` centred on second `a / frameRate`: for each, [values] numbers, how likely each of
/// the 88 keys is to be sounding (the mean of four of Basic Pitch's frames), then to be starting
/// (the most of the four), then the mean square of the samples.
///
/// A recording is heard a chunk at a time ([chunk], [chunkFrames] frames each), each on its own
/// from the samples about it ([sourceRange]), so the chunks can be heard in any order, at once.
/// They are resampled to Basic Pitch's rate and run as windows a whole number of frames apart,
/// each keeping its frames away from its edges (as the release keeps them, but without its
/// windows' drift of half a percent), so every frame is on one grid.
abstract final class AudioNotes {
  /// Frames a second (about 21.5): one for every four of Basic Pitch's.
  static const frameRate = BasicPitch.framesPerSecond / _pool;

  /// The numbers a frame has.
  static const values = 2 * BasicPitch.keys + 1;

  static const _pool = 4;

  /// Basic Pitch's windows in a chunk, the frames each keeps, and those left at its start (as
  /// many at its end).
  static const _windows = 10, _kept = 142, _trim = 15;

  /// The frames a chunk gives (about 16.5 seconds).
  static const chunkFrames = _windows * _kept ~/ _pool;

  /// From one window's start to the next, and all a chunk's windows span, in samples at Basic
  /// Pitch's rate.
  static const _step = _kept * BasicPitch.hop, _span = (_windows - 1) * _step + BasicPitch.windowLength;

  /// Where chunk [index]'s first window starts, in samples at Basic Pitch's rate from the
  /// recording's start. Basic Pitch's frame `g` is centred 1.5 hops before `g` hops in, so the
  /// four in frame `a` are centred on `a / frameRate`.
  static int _start(int index) => (index * _windows * _kept - _trim) * BasicPitch.hop - (_pool - 1) * BasicPitch.hop ~/ 2;

  /// How many chunks a recording [seconds] long takes.
  static int chunks(double seconds) => (seconds * frameRate).floor() ~/ chunkFrames + 1;

  /// The recording's frames (at [sampleRate]) chunk [index] is heard from: `from` up to `to`
  /// (either may be beyond the recording; what is is silence).
  static ({int from, int to}) sourceRange(int index, double sampleRate) {
    final ratio = sampleRate / BasicPitch.sampleRate, reach = _Resampler.reach(sampleRate);
    return (from: (_start(index) * ratio).floor() - reach, to: ((_start(index) + _span) * ratio).ceil() + reach);
  }

  /// Chunk [index]'s [chunkFrames] frames, [values] numbers each, heard by [model] from
  /// [samples] (mono, at [sampleRate]), the recording's from frame [from] on.
  static Float32List chunk(BasicPitch model, int index, Float32List samples, {required int from, required double sampleRate}) {
    const keys = BasicPitch.keys;
    final start = _start(index);
    final heard = _Resampler(sampleRate).run(samples, from, start, _span);
    final out = Float32List(chunkFrames * values);
    for (var w = 0; w < _windows; w++) {
      final frames = model.run(Float32List.sublistView(heard, w * _step, w * _step + BasicPitch.windowLength));
      for (var t = 0; t < _kept; t++) {
        final to = (w * _kept + t) ~/ _pool * values, at = (t + _trim) * keys;
        for (var k = 0; k < keys; k++) {
          out[to + k] += frames.notes[at + k] / _pool;
          out[to + keys + k] = math.max(out[to + keys + k], frames.onsets[at + k]);
        }
      }
    }
    // The mean square of the samples a frame spans.
    const width = _pool * BasicPitch.hop;
    for (var a = 0; a < chunkFrames; a++) {
      final centre = (index * chunkFrames + a) * width - start;
      var sum = 0.0;
      for (var i = centre - width ~/ 2; i < centre + width ~/ 2; i++) {
        sum += heard[i] * heard[i];
      }
      out[a * values + values - 1] = sum / width;
    }
    return out;
  }
}

/// A recording resampled to Basic Pitch's rate: each sample a windowed sinc's sum of those about
/// it (Kaiser, 16 zero crossings either side; below the lower rate's Nyquist frequency, less 5 %).
final class _Resampler {
  _Resampler(double sampleRate)
      : _ratio = sampleRate / BasicPitch.sampleRate,
        _cutoff = 0.95 * math.min(1.0, BasicPitch.sampleRate / sampleRate) {
    _half = _zeros / _cutoff;
    // The kernel from 0 to [_half] source samples, [_resolution] values a sample.
    _table = Float64List((_half * _resolution).ceil() + 2);
    final norm = _bessel(_beta);
    for (var i = 0; i < _table.length; i++) {
      final d = i / _resolution, r = d / _half;
      if (r >= 1) continue;
      final x = math.pi * _cutoff * d;
      _table[i] = _cutoff * (x == 0 ? 1 : math.sin(x) / x) * _bessel(_beta * math.sqrt(1 - r * r)) / norm;
    }
  }

  static const _zeros = 16, _beta = 8.6, _resolution = 512;

  /// The recording's samples (at [sampleRate]) either side of one that its resampling reads.
  static int reach(double sampleRate) => (_zeros / (0.95 * math.min(1.0, BasicPitch.sampleRate / sampleRate))).ceil() + 1;

  final double _ratio, _cutoff;
  late final double _half;
  late final Float64List _table;

  /// [length] samples at Basic Pitch's rate from its sample [start] on, from [samples], the
  /// recording's from frame [from] on (silence where they don't reach).
  Float32List run(Float32List samples, int from, int start, int length) {
    final out = Float32List(length);
    if (_ratio == 1) {
      for (var i = 0; i < length; i++) {
        final k = start + i - from;
        if (k >= 0 && k < samples.length) out[i] = samples[k];
      }
      return out;
    }
    for (var i = 0; i < length; i++) {
      final p = (start + i) * _ratio - from; // in [samples]
      final lo = math.max(0, (p - _half).ceil()), hi = math.min(samples.length - 1, (p + _half).floor());
      var sum = 0.0;
      for (var k = lo; k <= hi; k++) {
        final d = (p - k).abs() * _resolution, j = d.floor(), f = d - j;
        sum += samples[k] * (_table[j] + f * (_table[j + 1] - _table[j]));
      }
      out[i] = sum;
    }
    return out;
  }

  /// The modified Bessel function of the first kind, order 0.
  static double _bessel(double x) {
    var sum = 1.0, term = 1.0;
    for (var k = 1; k < 50; k++) {
      term *= (x / (2 * k)) * (x / (2 * k));
      sum += term;
      if (term < 1e-12 * sum) break;
    }
    return sum;
  }
}

/// Lines a recording up with the score (Align, the Audio tab): the score's notes are laid out
/// as played ([passes], the repeats taken) and made into what [AudioNotes] would hear of them,
/// both are matched frame by frame by multiscale dynamic time warping, and the path is thinned
/// into a [SyncMap]'s anchors: one at a bar where the tempo changes, a warp where a pass ends, one
/// at the end.
///
/// What sounds (each key's likelihood, against how many of the score's notes hold it) finds the
/// way through the piece; onsets (which keys start) place it within a harmony held or repeated,
/// where what sounds alone can't tell one bar from the next. Both count at every frame rate the
/// warping is solved at: a bar misplaced at a coarse one is further off than the finer ones' band
/// reaches.
abstract final class AudioAlignment {
  /// The anchors for [audio] ([AudioNotes]' frames) against [notes], in a score of
  /// [measureStarts] (the end of the last bar included) played as [passes]. Bars whose times a
  /// straight line through their neighbours' puts within [tolerance] seconds get none. Empty when
  /// the recording is silent or the score has no notes.
  static List<SyncAnchor> anchors({
    required Float32List audio,
    required List<SoundingNote> notes,
    required List<double> measureStarts,
    required List<ScorePass> passes,
    double tolerance = 0.03,
  }) {
    const v = AudioNotes.values, keys = BasicPitch.keys, frameRate = AudioNotes.frameRate;
    final frames = audio.length ~/ v;
    final played = passes.fold(0.0, (sum, p) => sum + p.end - p.start);
    if (frames < 8 || played <= 0 || notes.isEmpty) return const [];

    // Where the music sounds: the recording's silence (or noise, 40 dB under its loud frames)
    // either side is left out.
    final loudness = Float64List.fromList([for (var f = 0; f < frames; f++) audio[f * v + v - 1]]);
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
    final sounding = Float32List(heard * keys), starting = Float32List(heard * keys);
    for (var f = 0; f < heard; f++) {
      final at = (first + f) * v;
      sounding.setRange(f * keys, (f + 1) * keys, audio, at);
      starting.setRange(f * keys, (f + 1) * keys, audio, at + keys);
    }

    // The score as many frames as the music heard, so the path runs about diagonally.
    final perFrame = played / heard;
    final score = _scoreFrames(notes, passes, perFrame, heard);
    final path = _Warping.path(_unit(score.sounding, heard), _unit(sounding, heard), heard, heard,
        onsets: (_onsets(_compressed(score.onsets, heard), heard), _onsets(starting, heard)));

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

  /// At each of [frames] score frames, [perFrame] played quarters apart: how many notes hold each
  /// key (`sounding`), and how many start on it (`onsets`, a tie's carrying on not one). Notes
  /// beyond the piano's keys are left out: Basic Pitch hears none there.
  static ({Float32List sounding, Float32List onsets}) _scoreFrames(List<SoundingNote> notes, List<ScorePass> passes, double perFrame, int frames) {
    const keys = BasicPitch.keys;
    final sounding = Float32List(frames * keys), onsets = Float32List(frames * keys);
    var offset = 0.0;
    for (final pass in passes) {
      for (final n in notes) {
        final key = n.midi - BasicPitch.lowestKey;
        final start = math.max(n.start, pass.start), end = math.min(n.end, pass.end);
        if (key < 0 || key >= keys || end <= start) continue;
        final from = ((offset + start - pass.start) / perFrame).ceil();
        final to = math.min(frames - 1, ((offset + end - pass.start) / perFrame).ceil() - 1);
        for (var f = math.max(0, from); f <= to; f++) {
          sounding[f * keys + key]++;
        }
        final onset = ((offset + start - pass.start) / perFrame).round();
        if (!n.tied && start == n.start && onset < frames) onsets[onset * keys + key]++;
      }
      offset += pass.end - pass.start;
    }
    return (sounding: sounding, onsets: onsets);
  }

  /// [values]' [frames] frames log-compressed against its loud frames: 1 + 100 × the share of
  /// a loud frame's total, as a log.
  static Float32List _compressed(Float32List values, int frames) {
    const keys = BasicPitch.keys;
    final totals = Float64List(frames);
    for (var f = 0; f < frames; f++) {
      for (var k = 0; k < keys; k++) {
        totals[f] += values[f * keys + k];
      }
    }
    final loud = math.max(1e-12, _percentile(totals, 0.95));
    return Float32List.fromList([for (final e in values) math.log(1 + 100 * e / loud)]);
  }

  /// [values]' frames as unit vectors; a silent frame is every key alike.
  static Float32List _unit(Float32List values, int frames) {
    const keys = BasicPitch.keys;
    final out = Float32List.fromList(values);
    for (var f = 0; f < frames; f++) {
      var norm = 0.0;
      for (var k = 0; k < keys; k++) {
        norm += out[f * keys + k] * out[f * keys + k];
      }
      norm = math.sqrt(norm);
      for (var k = 0; k < keys; k++) {
        out[f * keys + k] = norm < 1e-3 ? 1 / math.sqrt(keys) : out[f * keys + k] / norm;
      }
    }
    return out;
  }

  /// Onset features from [onsets]: each dying away over four frames (so an onset a frame early
  /// or late still meets its own), scaled by the largest within a second and a half either side
  /// (a soft passage's onsets count as a loud one's), never by less than a fifth of a loud
  /// frame's.
  static Float32List _onsets(Float32List onsets, int frames) {
    const keys = BasicPitch.keys, decay = [1.0, 0.87, 0.71, 0.5];
    final held = Float32List(frames * keys);
    final norms = Float64List(frames);
    for (var f = 0; f < frames; f++) {
      var norm = 0.0;
      for (var k = 0; k < keys; k++) {
        var s = 0.0;
        for (var d = 0; d < decay.length && d <= f; d++) {
          s += decay[d] * onsets[(f - d) * keys + k];
        }
        held[f * keys + k] = s;
        norm += s * s;
      }
      norms[f] = math.sqrt(norm);
    }
    final floor = math.max(1e-6, 0.2 * _percentile(norms, 0.95));
    final reach = (1.5 * AudioNotes.frameRate).round();
    for (var f = 0; f < frames; f++) {
      var most = floor;
      for (var g = math.max(0, f - reach); g <= math.min(frames - 1, f + reach); g++) {
        most = math.max(most, norms[g]);
      }
      for (var k = 0; k < keys; k++) {
        held[f * keys + k] /= most;
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
  static const _factor = 4, _coarsest = 2500, _radius = 6, _keys = BasicPitch.keys;

  /// The path from (0, 0) to (n - 1, m - 1) pairing [x]'s [n] frames with [y]'s [m] (unit
  /// vectors, a value a key each), as (i, j) pairs in order. With [onsets] (one sequence of a
  /// value a key a frame for each), a cell also costs 1.5 times the squared distance of its
  /// onsets (at a coarser rate, the strongest of each key the frame takes in).
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

  /// [frames] frames averaged [_factor] at a time and made unit vectors again.
  static Float32List _pooled(Float32List f, int frames) {
    final count = (frames + _factor - 1) ~/ _factor;
    final out = Float32List(count * _keys);
    for (var i = 0; i < frames; i++) {
      for (var c = 0; c < _keys; c++) {
        out[i ~/ _factor * _keys + c] += f[i * _keys + c];
      }
    }
    for (var i = 0; i < count; i++) {
      var norm = 0.0;
      for (var c = 0; c < _keys; c++) {
        norm += out[i * _keys + c] * out[i * _keys + c];
      }
      norm = math.sqrt(norm);
      for (var c = 0; c < _keys; c++) {
        out[i * _keys + c] = norm < 1e-9 ? 1 / math.sqrt(_keys) : out[i * _keys + c] / norm;
      }
    }
    return out;
  }

  /// [frames] frames of onsets, the strongest of each key in every [_factor].
  static Float32List _strongest(Float32List f, int frames) {
    final out = Float32List((frames + _factor - 1) ~/ _factor * _keys);
    for (var i = 0; i < frames; i++) {
      for (var c = 0; c < _keys; c++) {
        final k = i ~/ _factor * _keys + c;
        out[k] = math.max(out[k], f[i * _keys + c]);
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
        for (var c = 0; c < _keys; c++) {
          dot += x[i * _keys + c] * y[j * _keys + c];
        }
        var cost = math.max(0.0, 1 - dot);
        if (onsets case (final ox, final oy)) {
          var d = 0.0;
          for (var c = 0; c < _keys; c++) {
            final e = ox[i * _keys + c] - oy[j * _keys + c];
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
