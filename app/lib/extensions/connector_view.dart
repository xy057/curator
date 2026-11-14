import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:score_engine/score_engine.dart';

import '../app_colors.dart';
import '../app_icons.dart';
import '../dialog_kit.dart';
import '../menu_kit.dart';
import '../ui_kit.dart';
import '../l10n/l10n.dart';
import 'extension_lane.dart' show extensionIcon;

/// A function a file offers, as [Lua.functionsIn] reads it.
typedef FileFunction = ({String name, List<String> parameters, int line});

/// An extension's connector as a picture, edited by hand: Curator's sockets it uses on the
/// left (each a card with its ports), its files on the right (each with the functions it
/// offers), and a wire from a port to the function Curator calls for it.
///
/// A card is dragged anywhere on it, and none ever lies over another: one dropped on another
/// goes below it ([_Layout]). A wire is pulled from a port's pin to a function, or from a
/// function's pin to a port (onto a file: a new function there, made for the port); a click
/// on a wire or its port marks it, and Delete takes it out, as it takes out a selected socket.
/// The empty picture is dragged to move over it. Add Socket puts in another, Tidy Up sets the
/// cards in two columns, the files by what they are wired to. Read only, the cards can still
/// be moved, to read it; that is not kept.
///
/// It is where an extension is worked on from: a double click on a port shows the function
/// wired to it, or writes one for it (as a wire let go on nothing does) and shows that; on a
/// function or a file's name, its code. While the extension runs, each port says how often
/// Curator has called it ([calls]), and one whose function failed is marked with what went
/// wrong ([problems]). What it can't draw (a later Curator's socket) is
/// shown as it is, and kept.
class ConnectorView extends StatefulWidget {
  const ConnectorView({
    super.key,
    required this.graph,
    required this.functions,
    required this.onChanged,
    this.onOpen,
    this.onCreate,
    this.problems = const {},
    this.calls,
    this.readOnly = false,
  });

  final ConnectorGraph graph;

  /// Each file of the extension (by its path under src/) with the functions it offers; null
  /// for one that doesn't read.
  final Map<String, List<FileFunction>?> functions;
  final ValueChanged<ConnectorGraph> onChanged;

  /// Shows [function] of [file] in the code (a double click on it or on its port); the file
  /// from its top when null.
  final void Function(String file, String? function)? onOpen;

  /// Writes a new function for [port] of node [node] into [file] and returns its name; null:
  /// it couldn't.
  final String? Function(String file, GraphNode node, ApiPort port)? onCreate;

  /// What went wrong at each port ("lane.items") as the extension ran.
  final Map<String, String> problems;

  /// How often each port has been called, the extension running; null: it isn't.
  final Map<String, int>? Function()? calls;
  final bool readOnly;

  @override
  State<ConnectorView> createState() => _ConnectorViewState();
}

const _nodeWidth = 230.0, _fileWidth = 260.0, _header = 30.0, _row = 24.0, _foot = 6.0;

/// A pin's part of its row (where a wire is pulled from), the room kept between cards, the
/// grid a dragged card keeps to, and where the two columns of a tidy picture are.
const _pin = 26.0, _gap = 16.0, _grid = 10.0, _nodesLeft = 40.0, _filesLeft = 430.0;

/// Where everything is in the picture.
class _Layout {
  _Layout._();

  final nodes = <String, Rect>{}, files = <String, Rect>{};

  /// Each port ("lane.items") and function ("main.lua#items"): its row, and its dot's centre.
  final ports = <String, Rect>{}, functions = <String, Rect>{};
  final portDots = <String, Offset>{}, functionDots = <String, Offset>{};

  /// The functions wires name that their file doesn't offer, and the files that aren't there.
  final missing = <String>{}, missingFiles = <String>{};
  final portsOf = <String, List<String>>{}, functionsOf = <String, List<String>>{};
  Size size = Size.zero;

  /// [graph] laid out: each card where the graph has it (a file it has no place for under the
  /// others), then moved down past any it would lie over, the higher of two staying. The card
  /// [floating] (a node's id, or a file's path after "#") is at [floatingAt] whatever is under
  /// it: the one being dragged.
  factory _Layout.of(ConnectorGraph graph, Map<String, List<FileFunction>?> functions, {String? floating, Offset? floatingAt}) {
    final l = _Layout._();
    final cards = <(String, Rect)>[]; // a node's id, or "#" and a file's path
    for (final node in graph.nodes) {
      final socket = ExtensionApi.socket(node.type);
      final ports = [
        ...?socket?.ports.map((p) => p.name),
        for (final w in graph.wires)
          if (w.node == node.id && socket?.port(w.port) == null) w.port,
      ];
      l.portsOf[node.id] = ports;
      cards.add((node.id, Rect.fromLTWH(node.x, node.y, _nodeWidth, _header + ports.length * _row + _foot)));
    }
    final paths = {...functions.keys, for (final w in graph.wires) if (!functions.containsKey(w.file)) w.file};
    var stack = 40.0;
    for (final path in paths) {
      if (!functions.containsKey(path)) l.missingFiles.add(path);
      final offered = [...?functions[path]?.map((f) => f.name)];
      final names = {
        ...offered,
        for (final w in graph.wires)
          if (w.file == path && !offered.contains(w.function)) w.function,
      }.toList();
      for (final name in names) {
        if (!offered.contains(name) && functions[path] != null) l.missing.add('$path#$name');
      }
      l.functionsOf[path] = names;
      final at = graph.files[path];
      final rect = Rect.fromLTWH(at?.$1 ?? _filesLeft, at?.$2 ?? stack, _fileWidth, _header + names.length * _row + _foot);
      stack = math.max(stack, rect.bottom + _gap);
      cards.add(('#$path', rect));
    }
    // None over another: from the top, each goes below those already placed that it meets.
    final order = [...cards.indexed]..sort((a, b) => switch (a.$2.$2.top.compareTo(b.$2.$2.top)) { 0 => a.$1.compareTo(b.$1), final by => by });
    final placed = <Rect>[];
    for (final (_, (key, at)) in order) {
      var rect = at;
      if (key == floating) {
        rect = floatingAt == null ? rect : floatingAt & rect.size;
      } else {
        for (var again = true; again;) {
          again = false;
          for (final other in placed) {
            if (rect.inflate(_gap / 2).overlaps(other.inflate(_gap / 2 - 0.01))) {
              rect = rect.translate(0, other.bottom + _gap - rect.top);
              again = true;
            }
          }
        }
        placed.add(rect);
      }
      key.startsWith('#') ? l.files[key.substring(1)] = rect : l.nodes[key] = rect;
    }
    var right = 0.0, bottom = 0.0;
    for (final MapEntry(key: id, value: rect) in l.nodes.entries) {
      for (final (i, port) in l.portsOf[id]!.indexed) {
        final row = Rect.fromLTWH(rect.left, rect.top + _header + i * _row, _nodeWidth, _row);
        l.ports['$id.$port'] = row;
        l.portDots['$id.$port'] = Offset(rect.right, row.center.dy);
      }
      right = math.max(right, rect.right);
      bottom = math.max(bottom, rect.bottom);
    }
    for (final MapEntry(key: path, value: rect) in l.files.entries) {
      for (final (i, name) in l.functionsOf[path]!.indexed) {
        final row = Rect.fromLTWH(rect.left, rect.top + _header + i * _row, _fileWidth, _row);
        l.functions['$path#$name'] = row;
        l.functionDots['$path#$name'] = Offset(rect.left, row.center.dy);
      }
      right = math.max(right, rect.right);
      bottom = math.max(bottom, rect.bottom);
    }
    l.size = Size(right + 80, bottom + 80);
    return l;
  }

  /// [graph] with every card where it is drawn.
  ConnectorGraph placed(ConnectorGraph graph) => graph.copyWith(
        nodes: [for (final n in graph.nodes) n.copyWith(x: nodes[n.id]!.left, y: nodes[n.id]!.top)],
        files: {for (final MapEntry(key: path, value: rect) in files.entries) path: (rect.left, rect.top)},
      );
}

/// [graph] with its cards in two columns: the sockets on the left, in the order they are in
/// from the top, the files on the right, each as near as it can be to the ports wired to it,
/// so the wires cross as little as they can.
ConnectorGraph tidyConnector(ConnectorGraph graph, Map<String, List<FileFunction>?> functions) {
  final now = _Layout.of(graph, functions);
  final nodes = [...graph.nodes]..sort((a, b) => now.nodes[a.id]!.top.compareTo(now.nodes[b.id]!.top));
  var y = 40.0;
  final at = <String, double>{};
  for (final n in nodes) {
    at[n.id] = y;
    y += now.nodes[n.id]!.height + _gap + 8;
  }
  final stacked = graph.copyWith(nodes: [for (final n in graph.nodes) n.copyWith(x: _nodesLeft, y: at[n.id])]);
  final ports = _Layout.of(stacked, functions).portDots;
  // A file's place: the middle of the ports wired to it; one with none after the rest.
  double middle(String path) {
    final wired = [for (final w in graph.wires) if (w.file == path) ?ports[w.from]?.dy];
    return wired.isEmpty ? double.infinity : wired.reduce((a, b) => a + b) / wired.length;
  }

  final paths = now.files.keys.toList(), places = {for (final path in paths) path: middle(path)};
  final order = [...paths.indexed]..sort((a, b) => switch (places[a.$2]!.compareTo(places[b.$2]!)) { 0 => a.$1.compareTo(b.$1), final by => by });
  y = 40.0;
  final files = <String, (double, double)>{};
  for (final (_, path) in order) {
    files[path] = (_filesLeft, y);
    y += now.files[path]!.height + _gap + 8;
  }
  return stacked.copyWith(files: files);
}

class _ConnectorViewState extends State<ConnectorView> {
  /// Read only, the cards can still be moved, to read the picture: kept here, never saved.
  ConnectorGraph? _own;
  ConnectorGraph get graph => _own ?? widget.graph;

  final _canvas = GlobalKey();
  final _focus = FocusNode(debugLabel: 'connector');
  final _hScroll = ScrollController(), _vScroll = ScrollController();

  /// The node whose properties show, and the port whose wire is marked.
  String? _node, _port;

  /// A wire being pulled from a port's pin or a function's, where its end is, and the port,
  /// function or file ("#" and its path) it would go to if let go.
  String? _pulling, _target;
  bool _fromFunction = false;
  Offset _pullTo = Offset.zero;

  /// The card being dragged (a node's id, or "#" and a file's path), where it was, and how far
  /// it has been taken.
  String? _dragging;
  Offset _dragFrom = Offset.zero, _dragBy = Offset.zero;

  /// The pin under the pointer.
  String? _hover;

  /// The calls counted when last looked at, and the look every half second.
  Map<String, int> _calls = const {};
  Timer? _watch;

  /// The row clicked last, and when: a second click soon after is a double click. (Kept by
  /// hand: a double-tap recogniser would hold every single click back to wait for it.)
  String? _clicked;
  Duration _clickedAt = Duration.zero;
  final _clock = Stopwatch()..start();

  bool _twice(String row) {
    final now = _clock.elapsed, twice = _clicked == row && now - _clickedAt < const Duration(milliseconds: 400);
    _clicked = twice ? null : row;
    _clickedAt = now;
    return twice;
  }

  @override
  void initState() {
    super.initState();
    if (widget.calls == null) return;
    _watch = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final calls = widget.calls?.call() ?? const <String, int>{};
      if (calls.length != _calls.length || calls.entries.any((e) => _calls[e.key] != e.value)) setState(() => _calls = Map.of(calls));
    });
  }

  @override
  void didUpdateWidget(ConnectorView old) {
    super.didUpdateWidget(old);
    if (!identical(widget.graph, old.graph)) _own = null;
  }

  @override
  void dispose() {
    _watch?.cancel();
    _focus.dispose();
    _hScroll.dispose();
    _vScroll.dispose();
    super.dispose();
  }

  /// Where the dragged card is now: on the grid, never off the picture's top or left.
  Offset get _draggedTo {
    final at = _dragFrom + _dragBy;
    return Offset(math.max(0, (at.dx / _grid).round() * _grid), math.max(0, (at.dy / _grid).round() * _grid));
  }

  _Layout _layout() => _Layout.of(graph, widget.functions, floating: _dragging, floatingAt: _dragging == null ? null : _draggedTo);

  Offset _local(Offset global) => (_canvas.currentContext!.findRenderObject()! as RenderBox).globalToLocal(global);

  void _change(ConnectorGraph next) => widget.onChanged(next);

  /// The cards moved: the extension's to keep, or read only this view's.
  void _arrange(ConnectorGraph next) => widget.readOnly ? setState(() => _own = next) : _change(next);

  void _wire(String port, String to) => _change(graph.copyWith(wires: [
        for (final w in graph.wires)
          if (w.from != port) w,
        GraphWire(port, to),
      ]));

  void _unwire(String port) {
    _change(graph.copyWith(wires: [
      for (final w in graph.wires)
        if (w.from != port) w,
    ]));
    setState(() => _port = null);
  }

  // MARK: Dragging a card

  void _dragStart(String card, Offset from) {
    _focus.requestFocus();
    setState(() => (_dragging = card, _dragFrom = from, _dragBy = Offset.zero));
  }

  void _dragUpdate(DragUpdateDetails d) => setState(() => _dragBy += d.delta);

  /// Let go: it stays where it is, or below the card it was let go on, and every card is kept
  /// where it is drawn.
  void _dragEnd() {
    final card = _dragging;
    if (card == null) return;
    final to = _draggedTo;
    setState(() => _dragging = null);
    if (to == _dragFrom) return;
    final moved = card.startsWith('#')
        ? graph.copyWith(files: {...graph.files, card.substring(1): (to.dx, to.dy)})
        : graph.copyWith(nodes: [for (final n in graph.nodes) n.id == card ? n.copyWith(x: to.dx, y: to.dy) : n]);
    _arrange(_Layout.of(moved, widget.functions).placed(moved));
  }

  /// The empty picture dragged: it moves under the pointer.
  void _pan(DragUpdateDetails d) {
    for (final (scroll, by) in [(_hScroll, d.delta.dx), (_vScroll, d.delta.dy)]) {
      if (scroll.hasClients) scroll.jumpTo((scroll.offset - by).clamp(0.0, scroll.position.maxScrollExtent));
    }
  }

  // MARK: Pulling a wire

  /// What a wire pulled to [at] would go to: a port (from a function), or a function or else
  /// a file that reads (from a port).
  String? _targetAt(_Layout l, Offset at) {
    if (_fromFunction) return l.ports.entries.where((e) => e.value.contains(at)).firstOrNull?.key;
    for (final MapEntry(key: target, value: rect) in l.functions.entries) {
      if (rect.contains(at)) return target;
    }
    for (final MapEntry(key: path, value: rect) in l.files.entries) {
      if (rect.contains(at) && widget.functions[path] != null) return '#$path';
    }
    return null;
  }

  void _pullStart(String from, {required bool function, required Offset global}) {
    _focus.requestFocus();
    setState(() => (_pulling = from, _fromFunction = function, _pullTo = _local(global), _target = null));
  }

  void _pullUpdate(_Layout l, Offset global) {
    final at = _local(global);
    setState(() => (_pullTo = at, _target = _targetAt(l, at)));
  }

  /// The end of a pulled wire let go: onto a function or a port, or a file's card (a new
  /// function there, made for the port).
  void _pullEnd() {
    final from = _pulling, target = _target;
    setState(() => (_pulling = null, _target = null));
    if (from == null) return;
    if (_fromFunction) return target == null ? null : _wire(target, from);
    if (target != null && !target.startsWith('#')) return _wire(from, target);
    // Onto a file, a new function there; onto nothing, in the file the port's socket uses most.
    _write(from, target?.substring(1));
  }

  /// Writes a function for [port] into [file] (by default the file most of its socket's wires
  /// go to, else most of all, else the first) and wires it: where it is, or null.
  ({String file, String function})? _write(String port, [String? file]) {
    final dot = port.lastIndexOf('.');
    final node = graph.node(port.substring(0, dot)), apiPort = ExtensionApi.socket(node?.type ?? '')?.port(port.substring(dot + 1));
    if (node == null || apiPort == null || widget.readOnly) return null;
    final files = [for (final MapEntry(key: path, value: read) in widget.functions.entries) if (read != null) path];
    int wires(String path, {bool own = false}) => graph.wires.where((w) => w.file == path && (!own || w.node == node.id)).length;
    file ??= files.fold<String?>(null, (best, path) {
      if (best == null) return path;
      final (a, b) = ((wires(path, own: true), wires(path)), (wires(best, own: true), wires(best)));
      return a.$1 > b.$1 || (a.$1 == b.$1 && a.$2 > b.$2) ? path : best;
    });
    if (file == null) return null;
    final name = widget.onCreate?.call(file, node, apiPort);
    if (name == null) return null;
    _wire(port, '$file#$name');
    return (file: file, function: name);
  }

  /// A port double-clicked: the function wired to it is shown, one written for it first when
  /// it has none.
  void _openPort(String port) {
    final dot = port.lastIndexOf('.');
    if (graph.wire(port.substring(0, dot), port.substring(dot + 1)) case final wire?) return widget.onOpen?.call(wire.file, wire.function);
    final written = _write(port);
    if (written == null) return;
    // Once the function is in the file's text.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onOpen?.call(written.file, written.function);
    });
  }

  /// The port of the wire that passes [at], if one does.
  String? _wireAt(_Layout l, Offset at) {
    for (final w in graph.wires.reversed) {
      final a = l.portDots[w.from], b = l.functionDots[w.to];
      if (a == null || b == null) continue;
      for (final metric in _WiresPainter._curve(a, b).computeMetrics()) {
        for (var d = 0.0; d <= metric.length; d += 4) {
          if ((metric.getTangentForOffset(d)!.position - at).distance <= 6) return w.from;
        }
      }
    }
    return null;
  }

  // MARK: Sockets

  void _addNode(ApiSocket socket) {
    final id = graph.freeId(socket.type), l = _layout();
    final bottom = graph.nodes.fold(40.0 - _gap - 8, (y, n) => math.max(y, l.nodes[n.id]!.bottom));
    _change(graph.copyWith(nodes: [
      ...graph.nodes,
      GraphNode(id: id, type: socket.type, x: _nodesLeft, y: bottom + _gap + 8, props: {
        for (final p in socket.props)
          if (p.name == 'title') 'title': socket.title,
      }),
    ]));
    setState(() => _node = id);
  }

  void _removeNode(String id) {
    _change(graph.copyWith(
      nodes: [
        for (final n in graph.nodes)
          if (n.id != id) n,
      ],
      wires: [
        for (final w in graph.wires)
          if (w.node != id) w,
      ],
    ));
    setState(() => _node = null);
  }

  /// Renames node [id] to [to], its wires and the nodes that name it following.
  void _renameNode(String id, String to) {
    _change(graph.copyWith(
      nodes: [
        for (final n in graph.nodes)
          n.id == id
              ? n.copyWith(id: to)
              : n.copyWith(props: {
                  for (final MapEntry(:key, :value) in n.props.entries)
                    key: value == id && ExtensionApi.socket(n.type)?.prop(key)?.type == ApiPropType.node ? to : value,
                }),
      ],
      wires: [
        for (final w in graph.wires) w.node == id ? GraphWire('$to.${w.port}', w.to) : w,
      ],
    ));
    setState(() => _node = to);
  }

  void _setProp(GraphNode node, String name, Object? value) => _change(graph.copyWith(nodes: [
        for (final n in graph.nodes)
          n.id == node.id
              ? n.copyWith(props: {
                  for (final MapEntry(:key, value: v) in n.props.entries)
                    if (key != name) key: v,
                  if (value != null && value != '') name: value,
                })
              : n,
      ]));

  /// Delete takes out the marked wire, else the selected socket (one an extension may be
  /// without); Escape lets go of a wire being pulled, then of what is selected.
  KeyEventResult _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (_pulling == null && _node == null && _port == null) return KeyEventResult.ignored;
      setState(() => _pulling == null ? (_node = null, _port = null) : (_pulling = null, _target = null));
      return KeyEventResult.handled;
    }
    if (widget.readOnly || (event.logicalKey != LogicalKeyboardKey.delete && event.logicalKey != LogicalKeyboardKey.backspace)) return KeyEventResult.ignored;
    if (_port case final port?) {
      _unwire(port);
      return KeyEventResult.handled;
    }
    final node = _node == null ? null : graph.node(_node!);
    if (node == null || (ExtensionApi.socket(node.type)?.single ?? false)) return KeyEventResult.ignored;
    _removeNode(node.id);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors, l = _layout();
    final selected = _node == null ? null : graph.node(_node!);
    final dragged = _dragging;
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(
        child: Focus(
          focusNode: _focus,
          onKeyEvent: (_, event) => _onKey(event),
          child: Stack(children: [
            Positioned.fill(
              child: ColoredBox(
                color: colors.surface,
                child: LayoutBuilder(
                  builder: (context, box) => Scrollbar(
                    controller: _vScroll,
                    child: SingleChildScrollView(
                      controller: _vScroll,
                      child: Scrollbar(
                        controller: _hScroll,
                        notificationPredicate: (n) => n.depth == 0,
                        child: SingleChildScrollView(
                          controller: _hScroll,
                          scrollDirection: Axis.horizontal,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTapUp: (d) {
                              _focus.requestFocus();
                              final wire = _wireAt(l, d.localPosition);
                              setState(() => (_node = null, _port = wire));
                            },
                            onPanUpdate: _pan,
                            child: SizedBox(
                              key: _canvas,
                              width: math.max(l.size.width, box.maxWidth),
                              height: math.max(l.size.height, box.maxHeight),
                              child: Stack(clipBehavior: Clip.none, children: [
                                for (final node in graph.nodes)
                                  if (node.id != dragged) _nodeCard(context, l, node),
                                for (final path in l.files.keys)
                                  if ('#$path' != dragged) _fileCard(context, l, path),
                                // The one being dragged, over the rest.
                                if (dragged != null && !dragged.startsWith('#'))
                                  if (graph.node(dragged) case final node?) _nodeCard(context, l, node),
                                if (dragged != null && dragged.startsWith('#') && l.files.containsKey(dragged.substring(1))) _fileCard(context, l, dragged.substring(1)),
                                // Over the cards, so a wire shows where it meets them; it takes no clicks.
                                Positioned.fill(
                                  child: IgnorePointer(
                                    child: CustomPaint(
                                      painter: _WiresPainter(
                                        graph: graph,
                                        layout: l,
                                        marked: _port,
                                        pulling: _pulling,
                                        fromFunction: _fromFunction,
                                        pullTo: _pullTo,
                                        target: _target,
                                        hover: _hover,
                                        failed: widget.problems.keys.toSet(),
                                        color: colors.accent,
                                        bad: colors.erase,
                                        ground: colors.chrome,
                                      ),
                                    ),
                                  ),
                                ),
                              ]),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 12,
              bottom: 12,
              child: Row(children: [
                if (!widget.readOnly) ...[
                  AppPopupMenuButton<ApiSocket>(
                    tooltip: 'Add Socket',
                    padding: EdgeInsets.zero,
                    onSelected: _addNode,
                    itemBuilder: (context) => [
                      for (final socket in ExtensionApi.sockets)
                        menuItem(
                          context,
                          value: socket,
                          enabled: !socket.single || !graph.nodes.any((n) => n.type == socket.type),
                          child: Text(socket.title),
                        ),
                    ],
                    child: IgnorePointer(child: OutlinedButton.icon(onPressed: () {}, icon: Icon(AppIcon.add.of(context), size: 16), label: Text('Add Socket'.tr))),
                  ),
                  const SizedBox(width: 8),
                ],
                OutlinedButton.icon(
                  onPressed: () => _arrange(tidyConnector(graph, widget.functions)),
                  icon: Icon(AppIcon.tidy.of(context), size: 16),
                  label: Text('Tidy Up'.tr),
                ),
              ]),
            ),
          ]),
        ),
      ),
      if (selected != null) ...[
        VerticalDivider(width: 1, color: colors.line),
        SizedBox(
          width: 280,
          child: _Inspector(
            key: ValueKey(selected.id),
            node: selected,
            graph: graph,
            readOnly: widget.readOnly,
            onRename: (to) => _renameNode(selected.id, to),
            onProp: (name, value) => _setProp(selected, name, value),
            onRemove: () => _removeNode(selected.id),
          ),
        ),
      ],
    ]);
  }

  BoxDecoration _card(BuildContext context, {required bool selected, bool bad = false, bool lifted = false}) {
    final colors = context.colors;
    return BoxDecoration(
      color: colors.chrome,
      borderRadius: AppStyle.of(context).radius(8),
      border: Border.all(color: bad ? colors.erase : selected ? colors.accent : colors.line, width: selected ? 1.5 : 1),
      boxShadow: lifted ? [BoxShadow(color: colors.text.withValues(alpha: 0.18), blurRadius: 14, offset: const Offset(0, 4))] : null,
    );
  }

  /// A card, dragged anywhere on it but its pins.
  Widget _draggable(String card, Rect rect, {VoidCallback? onTap, required Widget child}) => Positioned.fromRect(
        rect: rect,
        child: MouseRegion(
          cursor: _dragging == card ? SystemMouseCursors.grabbing : SystemMouseCursors.grab,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap ?? _focus.requestFocus,
            onPanStart: (_) => _dragStart(card, rect.topLeft),
            onPanUpdate: _dragUpdate,
            onPanEnd: (_) => _dragEnd(),
            onPanCancel: _dragEnd,
            child: child,
          ),
        ),
      );

  /// A row's pin: where a wire is pulled from [from] (a port, or a [function]).
  Widget _pinZone(_Layout l, String from, {required bool function, VoidCallback? onTap}) {
    final zone = SizedBox(key: ValueKey('pin:$from'), width: _pin, height: _row);
    if (widget.readOnly) return zone;
    return MouseRegion(
      cursor: SystemMouseCursors.precise,
      onEnter: (_) => setState(() => _hover = from),
      onExit: (_) => setState(() => _hover == from ? _hover = null : null),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onPanStart: (d) => _pullStart(from, function: function, global: d.globalPosition),
        onPanUpdate: (d) => _pullUpdate(l, d.globalPosition),
        onPanEnd: (_) => _pullEnd(),
        onPanCancel: () => setState(() => (_pulling = null, _target = null)),
        child: zone,
      ),
    );
  }

  Widget _nodeCard(BuildContext context, _Layout l, GraphNode node) {
    final colors = context.colors, rect = l.nodes[node.id]!;
    final socket = ExtensionApi.socket(node.type);
    final title = switch (node.props['title']) { final String s when s.isNotEmpty => s, _ => socket?.title ?? node.type };
    return _draggable(
      node.id,
      rect,
      onTap: () {
        _focus.requestFocus();
        setState(() => (_node = node.id, _port = null));
      },
      child: DecoratedBox(
        decoration: _card(context, selected: _node == node.id, lifted: _dragging == node.id),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(
            height: _header,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(children: [
                Icon(_socketIcon(node, socket).of(context), size: 15, color: colors.textMuted),
                const SizedBox(width: 6),
                Flexible(child: Text(title, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: colors.text))),
                const SizedBox(width: 6),
                Text(socket == null ? node.type : node.id, style: TextStyle(fontSize: 11, color: colors.textMuted)),
              ]),
            ),
          ),
          for (final port in l.portsOf[node.id]!) _portRow(context, l, node, socket?.port(port), port),
        ]),
      ),
    );
  }

  static AppIcon _socketIcon(GraphNode node, ApiSocket? socket) => switch (node.type) {
        'project' => AppIcon.project,
        'lane' => AppIcon.lanes,
        'command' => extensionIcon(node.props['icon'] ?? 'play'),
        'export' => AppIcon.export,
        'captions' => AppIcon.captions,
        'images' => AppIcon.image,
        'spacers' => AppIcon.verticalSpacer,
        'settings' => AppIcon.settings,
        'band' => AppIcon.tonality,
        'layer' => AppIcon.frame,
        _ => AppIcon.extensions,
      };

  Widget _portRow(BuildContext context, _Layout l, GraphNode node, ApiPort? port, String name) {
    final colors = context.colors, key = '${node.id}.$name';
    final wired = graph.wire(node.id, name) != null, marked = _port == key;
    final problem = widget.problems[key], calls = _calls[key];
    void mark() {
      _focus.requestFocus();
      if (_twice(key)) return _openPort(key);
      setState(() => (_port = wired ? key : null, _node = node.id));
    }

    final label = Padding(
      padding: const EdgeInsets.only(left: 12),
      child: Row(children: [
        Expanded(
          child: Text(name,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: problem != null ? colors.erase : port == null ? colors.textMuted : colors.text, fontWeight: marked ? FontWeight.w600 : null)),
        ),
        if (calls != null && !marked) Text('$calls', style: TextStyle(fontSize: 10.5, color: colors.textMuted, fontFeatures: const [FontFeature.tabularFigures()])),
        if (marked && wired && !widget.readOnly)
          Tip(
            message: 'Unwire'.tr,
            child: InkResponse(radius: 10, onTap: () => _unwire(key), child: Icon(AppIcon.close.of(context), size: 13, color: colors.textMuted)),
          ),
      ]),
    );
    return ColoredBox(
      color: _target == key ? colors.accent.withValues(alpha: 0.14) : const Color(0x00000000),
      child: SizedBox(
        height: _row,
        child: Row(children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: mark,
              child: port == null && problem == null ? label : Tip(message: [?problem, if (port != null) '${port.signature}\n${port.summary}'].join('\n\n'), child: label),
            ),
          ),
          _pinZone(l, key, function: false, onTap: mark),
        ]),
      ),
    );
  }

  Widget _fileCard(BuildContext context, _Layout l, String path) {
    final colors = context.colors, rect = l.files[path]!;
    final unread = widget.functions.containsKey(path) && widget.functions[path] == null, gone = l.missingFiles.contains(path);
    final by = {for (final f in widget.functions[path] ?? const <FileFunction>[]) f.name: f};
    return _draggable(
      '#$path',
      rect,
      onTap: () {
        _focus.requestFocus();
        if (_twice('#$path') && !gone) widget.onOpen?.call(path, null);
      },
      child: DecoratedBox(
        decoration: _card(context, selected: _target == '#$path', bad: unread || gone, lifted: _dragging == '#$path'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(
            height: _header,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(children: [
                Icon(AppIcon.code.of(context), size: 15, color: colors.textMuted),
                const SizedBox(width: 6),
                Expanded(child: Text(path, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: colors.text))),
                if (unread || gone) Icon(AppIcon.failed.of(context), size: 14, color: colors.erase),
              ]),
            ),
          ),
          for (final name in l.functionsOf[path]!)
            ColoredBox(
              color: _target == '$path#$name' ? colors.accent.withValues(alpha: 0.14) : const Color(0x00000000),
              child: SizedBox(
                height: _row,
                child: Row(children: [
                  if (by.containsKey(name)) _pinZone(l, '$path#$name', function: true) else const SizedBox(width: _pin),
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        _focus.requestFocus();
                        if (_twice('$path#$name') && by.containsKey(name)) widget.onOpen?.call(path, name);
                      },
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 12),
                          child: Text.rich(
                            TextSpan(children: [
                              TextSpan(text: name, style: TextStyle(color: l.missing.contains('$path#$name') ? colors.erase : colors.text)),
                              if (by[name] case final f?) TextSpan(text: '(${f.parameters.join(', ')})', style: TextStyle(color: colors.textMuted)),
                            ]),
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ),
                    ),
                  ),
                ]),
              ),
            ),
        ]),
      ),
    );
  }
}

/// The wires, each a curve from its port's pin to its function's, with the pins: filled when
/// wired, a ring when not, bigger under the pointer and where a pulled wire would go.
class _WiresPainter extends CustomPainter {
  _WiresPainter({
    required this.graph,
    required this.layout,
    required this.marked,
    required this.pulling,
    required this.fromFunction,
    required this.pullTo,
    required this.target,
    required this.hover,
    required this.failed,
    required this.color,
    required this.bad,
    required this.ground,
  });
  final ConnectorGraph graph;
  final _Layout layout;
  final String? marked, pulling, target, hover;
  final Set<String> failed;
  final bool fromFunction;
  final Offset pullTo;
  final Color color, bad, ground;

  static Path _curve(Offset a, Offset b) {
    final reach = math.max(40.0, (b.dx - a.dx).abs() / 2);
    return Path()
      ..moveTo(a.dx, a.dy)
      ..cubicTo(a.dx + reach, a.dy, b.dx - reach, b.dy, b.dx, b.dy);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final wired = <String>{};
    Paint line(Color color, double width) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..color = color;
    // The marked one last, over the others.
    final wires = [...graph.wires]..sort((a, b) => (a.from == marked ? 1 : 0) - (b.from == marked ? 1 : 0));
    for (final w in wires) {
      final a = layout.portDots[w.from], b = layout.functionDots[w.to];
      if (a == null || b == null) continue;
      wired
        ..add(w.from)
        ..add(w.to);
      final broken = layout.missing.contains(w.to) || layout.missingFiles.contains(w.file);
      final on = w.from == marked;
      canvas.drawPath(_curve(a, b), line((broken ? bad : color).withValues(alpha: on || (pulling == null && marked == null) ? 1 : 0.35), on ? 2.5 : 1.5));
    }
    void pin(String key, Offset at, {bool broken = false}) {
      final big = key == hover || key == target || key == pulling;
      final radius = big ? 6.0 : 4.0, ink = broken ? bad : color;
      if (wired.contains(key) || big) {
        canvas.drawCircle(at, radius, Paint()..color = ink);
      } else {
        canvas
          ..drawCircle(at, radius, Paint()..color = ground)
          ..drawCircle(at, radius - 0.75, line(ink.withValues(alpha: 0.6), 1.5));
      }
    }

    for (final MapEntry(key: port, value: at) in layout.portDots.entries) {
      pin(port, at, broken: failed.contains(port));
    }
    for (final MapEntry(key: fn, value: at) in layout.functionDots.entries) {
      pin(fn, at, broken: layout.missing.contains(fn));
    }
    if (pulling case final from?) {
      final start = fromFunction ? layout.functionDots[from] : layout.portDots[from];
      if (start != null) {
        // To the pin it would go to, when over one.
        final end = switch (target) { null => pullTo, final t => layout.functionDots[t] ?? layout.portDots[t] ?? pullTo };
        canvas.drawPath(fromFunction ? _curve(end, start) : _curve(start, end), line(color, 2));
        canvas.drawCircle(end, 4, Paint()..color = color);
      }
    }
  }

  @override
  bool shouldRepaint(_WiresPainter old) => true;
}

/// A socket's properties: its name in the connector, and what its kind lets it say.
class _Inspector extends StatefulWidget {
  const _Inspector({super.key, required this.node, required this.graph, required this.readOnly, required this.onRename, required this.onProp, required this.onRemove});
  final GraphNode node;
  final ConnectorGraph graph;
  final bool readOnly;
  final ValueChanged<String> onRename;
  final void Function(String name, Object? value) onProp;
  final VoidCallback onRemove;

  @override
  State<_Inspector> createState() => _InspectorState();
}

class _InspectorState extends State<_Inspector> {
  late final _id = TextEditingController(text: widget.node.id);
  final _fields = <String, TextEditingController>{};

  @override
  void dispose() {
    _id.dispose();
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// Why the name typed can't be the node's; null: it can (or it is its name).
  String? get _idProblem {
    final id = _id.text;
    if (id == widget.node.id) return null;
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9_]*$').hasMatch(id)) return 'Letters, digits and _, starting with a letter'.tr;
    if (widget.graph.node(id) != null) return 'Another socket has this name'.tr;
    return null;
  }

  TextEditingController _field(ApiProp prop) =>
      _fields[prop.name] ??= TextEditingController(text: switch (widget.node.props[prop.name]) { null => '', final v => '$v' });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors, node = widget.node, socket = ExtensionApi.socket(node.type);
    final problem = _idProblem;
    Widget help(String text) => Padding(
          padding: const EdgeInsets.only(top: 4, left: 2),
          child: Text(text, style: TextStyle(fontSize: 11.5, height: 1.35, color: colors.textMuted)),
        );

    Widget control(ApiProp prop) {
      final value = node.props[prop.name] ?? prop.fallback;
      DropdownMenuItem<String> item(String v, {Widget? leading}) => DropdownMenuItem(
            value: v,
            child: Row(mainAxisSize: MainAxisSize.min, children: [if (leading != null) ...[leading, const SizedBox(width: 8)], Text(v)]),
          );
      switch (prop.type) {
        case ApiPropType.toggle:
          return AppCheckRow(value: value == true, named: true, label: prop.name, onChanged: widget.readOnly ? (_) {} : (v) => widget.onProp(prop.name, v ?? false));
        case ApiPropType.choice || ApiPropType.icon || ApiPropType.node:
          final choices = switch (prop.type) {
            ApiPropType.icon => ExtensionApi.icons,
            ApiPropType.node => [for (final n in widget.graph.nodes) if (prop.choices.contains(n.type)) n.id],
            _ => prop.choices,
          };
          return AppDropdown<String>(
            label: prop.name,
            isExpanded: true,
            value: choices.contains(value) ? value as String : null,
            items: [
              for (final c in choices) item(c, leading: prop.type == ApiPropType.icon ? Icon(extensionIcon(c).of(context), size: 16) : null),
            ],
            onChanged: widget.readOnly ? null : (v) => widget.onProp(prop.name, v),
          );
        case ApiPropType.number || ApiPropType.text:
          return AppTextField(
            controller: _field(prop),
            label: prop.name,
            hint: prop.fallback == null ? null : '${prop.fallback}',
            onChanged: widget.readOnly
                ? null
                : (text) => widget.onProp(prop.name, prop.type == ApiPropType.number ? num.tryParse(text.trim()) : text),
          );
      }
    }

    return ColoredBox(
      color: colors.chrome,
      child: ListView(padding: const EdgeInsets.all(14), children: [
        Text(socket?.title ?? node.type, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: colors.text)),
        if (socket != null) help(socket.summary),
        const SizedBox(height: 14),
        AppTextField(
          controller: _id,
          label: 'Name'.tr,
          bad: problem != null,
          helper: problem,
          onChanged: (_) => setState(() {}),
          onSubmitted: widget.readOnly || problem != null || _id.text == node.id ? null : (_) => widget.onRename(_id.text),
        ),
        if (_id.text != node.id && problem == null && !widget.readOnly)
          Align(alignment: Alignment.centerRight, child: TextButton(onPressed: () => widget.onRename(_id.text), child: Text('Rename'.tr))),
        for (final prop in socket?.props ?? const <ApiProp>[]) ...[
          const SizedBox(height: 12),
          control(prop),
          help(prop.summary),
        ],
        if (!widget.readOnly && !(socket?.single ?? false)) ...[
          const SizedBox(height: 18),
          Align(alignment: Alignment.centerLeft, child: OutlinedButton(onPressed: widget.onRemove, child: Text('Remove Socket'.tr))),
        ],
      ]),
    );
  }
}
