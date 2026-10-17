/// Turns for work that overlaps (an engraving, a font being read): what a job does once it is
/// done counts only while its turn is still the latest. A later [start] or a [cancel] (the
/// document closed) leaves every earlier turn behind.
class Latest {
  int _count = 0;

  /// A new turn, leaving every earlier one behind: the latest call wins.
  Turn start() => Turn._(this, ++_count);

  /// The turn now, which [start] or [cancel] leaves behind: the work of one document, say.
  Turn get current => Turn._(this, _count);

  /// Leaves every turn so far behind.
  void cancel() => _count++;
}

/// One of [Latest]'s turns.
class Turn {
  Turn._(this._of, this._n);
  final Latest _of;
  final int _n;

  /// Whether nothing has started (or cancelled) since this turn.
  bool get isLatest => _n == _of._count;
}
