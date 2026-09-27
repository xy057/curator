/// One visible-or-animating staff in the curated view, measured in logical pixels.
class StaffSlot {
  const StaffSlot({
    required this.height,
    required this.inkAbove,
    required this.inkBelow,
    required this.visibility,
  });

  /// Distance from the top to the bottom staff line.
  final double height;

  /// How far notes, ledger lines, slurs and dynamics reach above the top line / below the
  /// bottom line, over the stretch of score the layout is for (a segment of the curation).
  final double inkAbove;
  final double inkBelow;

  /// 1 = shown, 0 = hidden (takes no room). The spacing plan only lays out keyframes, so it
  /// passes 0 or 1; moving between them is done by blending keyframes.
  final double visibility;
}

class StackMetrics {
  const StackMetrics({required this.availableHeight, required this.minGap, required this.maxGap});

  /// Height available for staves (frame margins already removed).
  final double availableHeight;

  /// Clear space between the ink of neighbouring staves never drops below this.
  final double minGap;

  /// Gaps never grow beyond this, even with only one or two staves on screen.
  final double maxGap;
}

abstract final class StaffStack {
  /// y of each slot's top staff line, in logical pixels from the top of the available area.
  ///
  /// Evaluated ahead of playback, once per segment of the curation (see SpacingPlan), with
  /// visibility 1 for shown staves and 0 for hidden ones: a hidden staff takes no room.
  static List<double> layout(List<StaffSlot> slots, StackMetrics metrics) {
    // Ink each staff needs, weighted by how visible it is: a hidden staff takes no room.
    var ink = 0.0, weight = 0.0;
    for (final slot in slots) {
      ink += (slot.inkAbove + slot.height + slot.inkBelow) * slot.visibility;
      weight += slot.visibility;
    }
    if (weight <= 0) return List.filled(slots.length, metrics.availableHeight / 2);

    // Share the free height equally between the gaps (one more gap than staves, so there is
    // air above the first and below the last). Wide when few staves are shown, never wider
    // than maxGap; squeezed below minGap only when the frame is genuinely full.
    final free = metrics.availableHeight - ink;
    var gap = (free / (weight + 1)).clamp(metrics.minGap, metrics.maxGap);
    if (ink + gap * (weight + 1) > metrics.availableHeight) {
      gap = (free / (weight + 1)).clamp(4.0, metrics.minGap);
    }

    // Centre the group vertically in whatever room is left over.
    final total = ink + gap * (weight + 1);
    var y = (metrics.availableHeight - total) / 2 + gap;
    return [
      for (final slot in slots)
        () {
          final top = y + slot.inkAbove * slot.visibility;
          y += (slot.inkAbove + slot.height + slot.inkBelow + gap) * slot.visibility;
          return top;
        }(),
    ];
  }
}
