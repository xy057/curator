import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'automation.dart';

/// What a frame shows: the score, the player map, both side by side, or the score with the map
/// in a corner.
enum ViewKind { score, map, split, inset }

/// Where a split view puts the map: the score takes the rest.
enum MapSide { right, left, bottom, top }

/// Which corner an inset map sits in.
enum MapCorner { bottomRight, bottomLeft, topRight, topLeft }

/// One of the views a video (and the preview, and a web page) can show ([ViewKind]), with where
/// the map goes in it: a split's [side] and the share of the frame it takes ([size]); an inset's
/// [corner] and its height over the frame's ([size]).
@immutable
class SceneView {
  const SceneView(this.kind, {this.side = MapSide.right, this.corner = MapCorner.bottomRight, double? size})
      : size = size ?? (kind == ViewKind.inset ? defaultInset : defaultShare);

  final ViewKind kind;
  final MapSide side;
  final MapCorner corner;

  /// A split's map's share of the frame (its width, or height at the top or bottom); an inset
  /// map's height over the frame's. Unused by the others.
  final double size;

  static const score = SceneView(ViewKind.score);
  static const map = SceneView(ViewKind.map);

  static const defaultShare = 0.4, defaultInset = 0.32;
  static const minSize = 0.2, maxShare = 0.6, maxInset = 0.5;

  /// The sizes offered, as fractions.
  static const shares = [0.3, 0.4, 0.5, 0.6], insets = [0.25, 0.32, 0.4, 0.5];

  /// Whether it draws the player map.
  bool get showsMap => kind != ViewKind.score;

  /// Whether it draws the score.
  bool get showsScore => kind != ViewKind.map;

  SceneView copyWith({ViewKind? kind, MapSide? side, MapCorner? corner, double? size}) {
    final k = kind ?? this.kind;
    // A size goes with its kind: another kind takes its own default.
    return SceneView(k, side: side ?? this.side, corner: corner ?? this.corner, size: size ?? (k == this.kind ? this.size : null));
  }

  /// Where the score and the map go in a frame of [frame] points ([ViewPlacement]).
  ViewPlacement place(ui.Size frame) {
    final full = ui.Offset.zero & frame;
    switch (kind) {
      case ViewKind.score:
        return (score: full, scoreLayout: frame, map: null, inset: false);
      case ViewKind.map:
        return (score: null, scoreLayout: frame, map: full, inset: false);
      case ViewKind.inset:
        final h = frame.height * size.clamp(minSize, maxInset), w = math.min(frame.width * 0.5, h * 1.6);
        final m = frame.shortestSide * 0.03;
        final left = corner == MapCorner.bottomLeft || corner == MapCorner.topLeft, top = corner == MapCorner.topLeft || corner == MapCorner.topRight;
        final map = ui.Rect.fromLTWH(left ? m : frame.width - m - w, top ? m : frame.height - m - h, w, h);
        return (score: full, scoreLayout: frame, map: map, inset: true);
      case ViewKind.split:
        final share = size.clamp(minSize, maxShare);
        switch (side) {
          case MapSide.right || MapSide.left:
            final w = frame.width * share, right = side == MapSide.right;
            final score = ui.Rect.fromLTWH(right ? 0 : w, 0, frame.width - w, frame.height);
            // Laid out at its own width, the full height: the staves as tall as ever.
            return (score: score, scoreLayout: score.size, map: ui.Rect.fromLTWH(right ? frame.width - w : 0, 0, w, frame.height), inset: false);
          case MapSide.bottom || MapSide.top:
            final h = frame.height * share, bottom = side == MapSide.bottom;
            final score = ui.Rect.fromLTWH(0, bottom ? 0 : h, frame.width, frame.height - h);
            // Laid out at the frame's height and scaled into its room, so the staves fit as they
            // do full-frame.
            final scale = score.height / frame.height;
            return (
              score: score,
              scoreLayout: ui.Size(score.width / scale, frame.height),
              map: ui.Rect.fromLTWH(0, bottom ? frame.height - h : 0, frame.width, h),
              inset: false,
            );
        }
    }
  }

  @override
  bool operator ==(Object other) =>
      other is SceneView &&
      other.kind == kind &&
      (kind != ViewKind.split || other.side == side) &&
      (kind != ViewKind.inset || other.corner == corner) &&
      (!_sized || other.size == size);

  bool get _sized => kind == ViewKind.split || kind == ViewKind.inset;

  @override
  int get hashCode => Object.hash(kind, kind == ViewKind.split ? side : null, kind == ViewKind.inset ? corner : null, _sized ? size : null);

  @override
  String toString() => 'SceneView(${kind.name}${kind == ViewKind.split ? ' ${side.name}' : ''}${kind == ViewKind.inset ? ' ${corner.name}' : ''}'
      '${_sized ? ' $size' : ''})';

  Map<String, Object?> toJson() => {
        'kind': kind.name,
        if (kind == ViewKind.split) 'side': side.name,
        if (kind == ViewKind.inset) 'corner': corner.name,
        if (_sized) 'size': size,
      };

  static SceneView fromJson(Object? json, String where) {
    if (json is! Map) throw FormatException('$where is not a view.');
    T named<T extends Enum>(List<T> values, String key, T fallback) => switch (json[key]) {
          null => fallback,
          final String name => values.asNameMap()[name] ?? (throw FormatException('$where.$key "$name" is unknown.')),
          _ => throw FormatException('$where.$key is not a name.'),
        };
    final kind = switch (json['kind']) {
      final String name => ViewKind.values.asNameMap()[name] ?? (throw FormatException('$where.kind "$name" is unknown.')),
      _ => throw FormatException('$where.kind is not a name.'),
    };
    final size = json['size'];
    if (size != null && (size is! num || !size.isFinite || size < SceneView.minSize - 1e-9 || size > SceneView.maxShare + 1e-9)) {
      throw FormatException('$where.size is out of range.');
    }
    return SceneView(kind, side: named(MapSide.values, 'side', MapSide.right), corner: named(MapCorner.values, 'corner', MapCorner.bottomRight), size: (size as num?)?.toDouble());
  }
}

/// Where a [SceneView] puts things in a frame: the score drawn in [score] (laid out at
/// [scoreLayout], scaled to fit it; null: no score), the map in [map] (null: none), over the
/// score when [inset].
typedef ViewPlacement = ({ui.Rect? score, ui.Size scoreLayout, ui.Rect? map, bool inset});

/// The automation of what a frame shows ([SceneView]): the Video tab's View lane.
abstract final class SceneViews {
  static const target = _ViewTarget();
}

final class _ViewTarget extends AutomationTarget<SceneView> {
  const _ViewTarget() : super('view');

  @override
  SceneView get base => SceneView.score;

  @override
  Object? encode(SceneView value) => value.toJson();

  @override
  SceneView decode(Object? json, String where) => SceneView.fromJson(json, where);
}

/// Every automation target the engine knows, for reading a project's lanes.
const List<AutomationTarget<Object?>> automationTargets = [SceneViews.target];
