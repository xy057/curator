import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// A stretch of the band along a frame's top ([CuratedScene.bands]): the music from score
/// quarter [start] to [end], in [color], named [label] at its start. What an extension's `band`
/// socket gives (Tonality's: the key the music is in, in the key's colour).
@immutable
class ScoreBand {
  const ScoreBand(this.start, this.end, this.color, this.label);
  final double start, end;
  final ui.Color color;
  final String label;

  @override
  bool operator ==(Object other) => other is ScoreBand && other.start == start && other.end == end && other.color == color && other.label == label;
  @override
  int get hashCode => Object.hash(start, end, color, label);
  @override
  String toString() => 'ScoreBand($start–$end, "$label", $color)';
}
