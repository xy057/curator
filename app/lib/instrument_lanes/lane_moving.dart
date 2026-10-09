part of '../timeline_panel.dart';

/// Lanes moved by holding their names, and lanes that slide to their new places.
mixin _LaneMoving on _LaneGeometry, SingleTickerProviderStateMixin<InstrumentLanes> {
  @override
  void initState() {
    super.initState();
    _motion = createTicker(_tick);
    c.addListener(_orderChanged);
  }

  @override
  void dispose() {
    c.removeListener(_orderChanged);
    _motion.dispose();
    _frame.dispose();
    super.dispose();
  }

  /// The lane held by its name, and the lanes moving with it (itself, or every selected lane
  /// when it is one of them), top to bottom; the lanes as they will be when let go, and where
  /// the pointer is.
  String? _lifted;
  List<String> _held = const [];
  List<ScorePart>? _reordered;
  Offset _liftPointer = Offset.zero;
  double _grab = 0; // where the held name was taken, from the top of the held block

  /// How far each held lane was from its place in the block when lifted, and how far the
  /// block has gathered (0…1): all of them close up together, then move as one.
  Map<String, double> _gatherFrom = const {};
  double _gathered = 1;
  final _headersKey = GlobalKey();
  final _viewportKey = GlobalKey();

  /// Lanes on their way to their place (their top, by part id): the held one follows the
  /// pointer, the others slide aside, and the held one settles into its place when let go.
  final _rowY = <String, double>{};
  late final Ticker _motion;
  Duration _lastTick = Duration.zero;

  /// A frame of lanes moving: the names and the lanes are drawn again where they now are,
  /// and nothing else is built.
  final _frame = RepaintSignal();

  /// The top of lane [i] as drawn now.
  double _rowTop(int i) => _rowY[parts[i].id] ?? i * _laneHeight;

  /// The held lanes as objects: each run of held lanes that touch is one block, and once
  /// they have gathered (as they are lifted) there is one. Empty when none is held.
  List<Rect> _heldBlocks(double width) {
    final rows = [for (var i = 0; i < parts.length; i++) if (_held.contains(parts[i].id)) _rowTop(i)]..sort();
    final blocks = <Rect>[];
    for (final top in rows) {
      final last = blocks.lastOrNull;
      if (last != null && top <= last.bottom + 0.5) {
        blocks.last = Rect.fromLTRB(0, last.top, width, top + _laneHeight);
      } else {
        blocks.add(Rect.fromLTWH(0, top, width, _laneHeight));
      }
    }
    return blocks;
  }
  /// The lanes' order as last drawn at rest (part ids).
  List<String> _shownOrder = const [];

  /// Lanes moved some other way (the ⋯ menu, Undo, condensing) slide to their new places too.
  void _orderChanged() {
    final ids = [for (final p in c.laneParts) p.id];
    if (_lifted != null || listEquals(ids, _shownOrder)) return;
    _slideFrom(_shownOrder);
    _shownOrder = ids;
  }

  /// Lanes not already moving start from where they are in [order] (part ids, top to bottom).
  void _slideFrom(List<String> order) {
    if (order.isEmpty) return;
    for (final (i, id) in order.indexed) {
      _rowY.putIfAbsent(id, () => i * _laneHeight);
    }
    _animate();
  }

  void _lift(String partId, Offset global) {
    final lanes = c.laneParts;
    final i = lanes.indexWhere((p) => p.id == partId);
    final box = _headersKey.currentContext?.findRenderObject() as RenderBox?;
    if (i < 0 || box == null) return;
    // A selected lane takes the whole selection with it, gathered into one block.
    final selected = c.lanes.selectedPartIds;
    final held = selected.contains(partId) ? [for (final p in lanes) if (selected.contains(p.id)) p.id] : [partId];
    if (!selected.contains(partId)) c.clearSelection();
    final blockTop = _rowTop(i) - held.indexOf(partId) * _laneHeight;
    _grab = box.globalToLocal(global).dy - blockTop;
    _gatherFrom = {
      for (final (k, id) in held.indexed) id: _rowTop(lanes.indexWhere((p) => p.id == id)) - (blockTop + k * _laneHeight),
    };
    _gathered = 0;
    _liftPointer = global;
    setState(() {
      _lifted = partId;
      _held = held;
      _reordered = lanes;
    });
    _animate();
  }

  void _dragLifted(Offset global) => _liftPointer = global;

  void _dropLifted() {
    final held = _held, lanes = _reordered;
    setState(() {
      _lifted = null;
      _held = const [];
      _reordered = null;
    });
    if (lanes == null) return;
    _shownOrder = [for (final p in lanes) p.id]; // already there, but for the held ones
    c.moveLanes(held, lanes.indexWhere((p) => held.contains(p.id)));
    _animate(); // the held lanes settle into their places
  }

  void _animate() {
    if (_motion.isActive) return;
    _lastTick = Duration.zero;
    _motion.start();
  }

  /// One frame of moving lanes: scroll near the panel's edges, follow the pointer, put the
  /// held lane where it now is, and ease every other lane towards its place.
  void _tick(Duration elapsed) {
    final dt = ((elapsed - _lastTick).inMicroseconds / 1e6).clamp(0.0, 0.05);
    _lastTick = elapsed;
    final lifted = _lifted;
    var blockTop = 0.0;
    if (lifted != null) {
      _scrollNearEdge(dt);
      final box = _headersKey.currentContext?.findRenderObject() as RenderBox?;
      final lanes = _reordered!;
      final others = [for (final p in lanes) if (!_held.contains(p.id)) p];
      if (box != null) {
        blockTop = (box.globalToLocal(_liftPointer).dy - _grab).clamp(0.0, others.length * _laneHeight);
        // The block follows the pointer exactly; its lanes close up on the held one together.
        _gathered = math.min(1, _gathered + dt / 0.15);
        final closing = 1 - _gathered * _gathered * (3 - 2 * _gathered);
        for (final (k, id) in _held.indexed) {
          _rowY[id] = blockTop + k * _laneHeight + (_gatherFrom[id] ?? 0) * closing;
        }
        final to = ((blockTop + _laneHeight / 2) / _laneHeight).floor().clamp(0, others.length);
        final next = [
          ...others.take(to),
          for (final p in lanes) if (_held.contains(p.id)) p,
          ...others.skip(to),
        ];
        if (!listEquals([for (final p in next) p.id], [for (final p in lanes) p.id])) {
          _slideFrom([for (final p in lanes) p.id]);
          _reordered = next;
        }
      }
    }
    final ease = 1 - math.exp(-dt / 0.05); // a lane covers most of its way in about a tenth of a second
    var moving = false;
    for (final (i, part) in parts.indexed) {
      if (lifted != null && _held.contains(part.id)) continue; // placed with its block
      // Let go, a block is one distance from its place in every lane: it settles as one.
      final target = i * _laneHeight;
      final y = _rowY[part.id] ?? target;
      final next = y + (target - y) * ease;
      if ((next - target).abs() < 0.5) {
        _rowY.remove(part.id);
      } else {
        _rowY[part.id] = next;
        moving = true;
      }
    }
    if (!moving && lifted == null) {
      _rowY.clear();
      _motion.stop();
    }
    _frame.ping();
  }

  /// Near the top or bottom of the panel the lanes scroll, for a lane that goes further: the
  /// closer to the edge, the faster.
  void _scrollNearEdge(double dt) {
    final box = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !_vScroll.hasClients) return;
    const edge = 32.0, speed = 600.0; // points a second, at the very edge
    final y = box.globalToLocal(_liftPointer).dy;
    final depth = y < edge ? y - edge : y > box.size.height - edge ? y - (box.size.height - edge) : 0.0;
    if (depth == 0) return;
    final position = _vScroll.position;
    final to = (position.pixels + (depth / edge).clamp(-1.0, 1.0) * speed * dt)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if (to != position.pixels) _vScroll.jumpTo(to);
  }
}
