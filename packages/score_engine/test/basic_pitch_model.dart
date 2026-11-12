import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:score_engine/score_engine.dart';

/// The weights the app bundles; tests run in packages/score_engine/.
final basicPitchWeights = File('../../app/${BasicPitch.asset}').readAsBytesSync();

/// Basic Pitch with them.
final basicPitch = BasicPitch(basicPitchWeights);

/// [samples] (mono, at [rate]) heard as the app hears a recording ([AudioNotes]): chunk by
/// chunk, each from only the samples its [AudioNotes.sourceRange] says, the frames then cut to
/// the recording's length.
Float32List heardFrames(Float32List samples, double rate) {
  final seconds = samples.length / rate;
  final out = Float32List(((seconds * AudioNotes.frameRate).floor() + 1) * AudioNotes.values);
  for (var c = 0, at = 0; c < AudioNotes.chunks(seconds); c++) {
    final range = AudioNotes.sourceRange(c, rate);
    final from = math.max(0, range.from), to = math.max(from, math.min(samples.length, range.to));
    final frames = AudioNotes.chunk(basicPitch, c, Float32List.sublistView(samples, from, to), from: from, sampleRate: rate);
    final take = math.min(frames.length, out.length - at);
    out.setRange(at, at + take, frames);
    at += take;
  }
  return out;
}
