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
/// Drag from a port to a function to wire it (onto a file's name: a new function there, made
/// for the port); click a wired port and press Delete to unwire it; drag a card by its name to
/// move it; click a socket for its properties at the right; double-click a function to see its
/// code. Add Socket puts in another. What it can't draw (a later Curator's socket) is shown
/// as it is, and kept.
class ConnectorView extends StatefulWidget {
  const ConnectorView({
    super.key,
    required this.graph,
    required this.functions,
    required this.onChanged,
    this.onOpen,
    this.onCreate,
    this.readOnly = false,
  });

  final ConnectorGraph graph;

  /// Each file of the extension (by its path under src/) with the functions it offers; null
  /// for one that doesn't read.
  final Map<String, List<FileFunction>?> functions;
  final ValueChanged<ConnectorGraph> onChanged;

  /// Shows [function] of [file] in the code (a double click on it).
  final void Function(String file, String function)? onOpen;

  /// Writes a new function for [port] of node [node] into [file] and returns its name; null:
  /// it couldn't.
  final String? Function(String file, GraphNode node, ApiPort port)? onCreate;
  final bool readOnly;

  @override
  State<ConnectorView> createState() => _ConnectorViewState();
}

const _nodeWidth = 230.0, _fileWidth = 260.0, _header = 30.0, _row = 24.0, _foot = 6.0;

/// Where everything is in the picture.
class _Layout {
  final nodes = <String, Rect>{}, files = <String, Rect>{};

  /// Each port ("lane.items") and function ("main.lua#items"): its row, and its dot's centre.
  final ports = <String, Rect>{}, functions = <String, Rect>{};
  final portDots = <String, Offset>{}, functionDots = <String, Offset>{};

  /// The functions wires name that their file doesn't offer, and the files that aren't there.
  final missing = <String>{}, missingFiles = <String>{};
  final portsOf = <String, List<String>>{}, functionsOf = <String, List<String>>{};
  Size size = Size.zero;
}

class _ConnectorViewState extends State<ConnectorView> {
  ConnectorGraph get graph => widget.graph;
  final _canvas = GlobalKey();
  final _focus = FocusNode(debugLabel: 'connector');
  final _hScroll = ScrollController(), _vScroll = ScrollController();

  /// The node whose properties show, and the port whose wire is marked.
  String? _node, _port;

  /// A wire being pulled from a port, and where its end is.
  String? _pulling;
  Offset _pullTo = Offset.zero;

  @override
  void dispose() {
    _focus.dispose();
    _hScroll.dispose();
    _vScroll.dispose();
    super.dispose();
  }

  _Layout _layout() {
    final l = _Layout();
    var right = 0.0, bottom = 0.0;
    for (final node in graph.nodes) {
      final socket = ExtensionApi.socket(node.type);
      final ports = [
        ...?socket?.ports.map((p) => p.name),
        for (final w in graph.wires)
          if (w.node == node.id && socket?.port(w.port) == null) w.port,
      ];
      l.portsOf[node.id] = ports;
      final rect = Rect.fromLTWH(node.x, node.y, _nodeWidth, _header + ports.length * _row + _foot);
      l.nodes[node.id] = rect;
      for (final (i, port) in ports.indexed) {
        final row = Rect.fromLTWH(rect.left, rect.top + _header + i * _row, _nodeWidth, _row);
        l.ports['${node.id}.$port'] = row;
        l.portDots['${node.id}.$port'] = Offset(rect.right, row.center.dy);
      }
      right = math.max(right, rect.right);
      bottom = math.max(bottom, rect.bottom);
    }
    final paths = {...widget.functions.keys, for (final w in graph.wires) if (!widget.functions.containsKey(w.file)) w.file};
    var stack = 40.0;
    for (final path in paths) {
      if (!widget.functions.containsKey(path)) l.missingFiles.add(path);
      final offered = [...?widget.functions[path]?.map((f) => f.name)];
      final names = {
        ...offered,
        for (final w in graph.wires)
          if (w.file == path && !offered.contains(w.function)) w.function,
      }.toList();
      for (final name in names) {
        if (!offered.contains(name) && widget.functions[path] != null) l.missing.add('$path#$name');
      }
      l.functionsOf[path] = names;
      final height = _header + names.length * _row + _foot;
      final at = graph.files[path];
      final rect = Rect.fromLTWH(at?.$1 ?? 420, at?.$2 ?? stack, _fileWidth, height);
      stack = math.max(stack, rect.bottom + 20);
      l.files[path] = rect;
      for (final (i, name) in names.indexed) {
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

  Offset _local(Offset global) => (_canvas.currentContext!.findRenderObject()! as RenderBox).globalToLocal(global);

  void _change(ConnectorGraph next) => widget.onChanged(next);

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

  void _moveNode(String id, Offset by) => _change(graph.copyWith(nodes: [
        for (final n in graph.nodes)
          n.id == id ? n.copyWith(x: math.max(0, n.x + by.dx).roundToDouble(), y: math.max(0, n.y + by.dy).roundToDouble()) : n,
      ]));

  void _moveFile(String path, Rect from, Offset by) => _change(graph.copyWith(files: {
        ...graph.files,
        path: (math.max(0, from.left + by.dx).roundToDouble(), math.max(0, from.top + by.dy).roundToDouble()),
      }));

  /// The end of a pulled wire let go at [at]: onto a function, or a file's card (a new function).
  void _drop(_Layout l, String port, Offset at) {
    for (final MapEntry(key: target, value: rect) in l.functions.entries) {
      if (rect.contains(at)) return _wire(port, target);
    }
    for (final MapEntry(key: path, value: rect) in l.files.entries) {
      if (!rect.contains(at) || widget.functions[path] == null) continue;
      final dot = port.lastIndexOf('.');
      final node = graph.node(port.substring(0, dot)), apiPort = ExtensionApi.socket(node?.type ?? '')?.port(port.substring(dot + 1));
      if (node == null || apiPort == null) return;
      final name = widget.onCreate?.call(path, node, apiPort);
      if (name != null) _wire(port, '$path#$name');
      return;
    }
  }

  void _addNode(ApiSocket socket) {
    final id = graph.freeId(socket.type);
    final bottom = graph.nodes.fold(20.0, (y, n) => math.max(y, _layout().nodes[n.id]!.bottom + 20));
    _change(graph.copyWith(nodes: [
      ...graph.nodes,
      GraphNode(id: id, type: socket.type, x: 40, y: bottom, props: {
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

  @override
  Widget build(BuildContext context) {
    final colors = context.colors, l = _layout();
    final selected = _node == null ? null : graph.node(_node!);
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(
        child: Focus(
          focusNode: _focus,
          onKeyEvent: (_, event) {
            final port = _port;
            if (widget.readOnly || port == null || event is! KeyDownEvent) return KeyEventResult.ignored;
            if (event.logicalKey != LogicalKeyboardKey.delete && event.logicalKey != LogicalKeyboardKey.backspace) return KeyEventResult.ignored;
            _unwire(port);
            return KeyEventResult.handled;
          },
          child: Stack(children: [
            Positioned.fill(
              child: ColoredBox(
                color: colors.surface,
                child: Scrollbar(
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
                          behavior: HitTestBehavior.translucent,
                          onTap: () {
                            _focus.requestFocus();
                            setState(() => (_node = null, _port = null));
                          },
                          child: SizedBox(
                            key: _canvas,
                            width: l.size.width,
                            height: l.size.height,
                            child: Stack(clipBehavior: Clip.none, children: [
                              for (final node in graph.nodes) _nodeCard(context, l, node),
                              for (final path in l.files.keys) _fileCard(context, l, path),
                              // Over the cards, so a wire shows where it meets them; it takes no clicks.
                              Positioned.fill(
                                child: IgnorePointer(
                                  child: CustomPaint(
                                    painter: _WiresPainter(
                                      graph: graph,
                                      layout: l,
                                      marked: _port,
                                      pulling: _pulling,
                                      pullTo: _pullTo,
                                      color: colors.accent,
                                      bad: colors.erase,
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
            if (!widget.readOnly)
              Positioned(
                left: 12,
                bottom: 12,
                child: AppPopupMenuButton<ApiSocket>(
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

  BoxDecoration _card(BuildContext context, {required bool selected, bool bad = false}) {
    final colors = context.colors;
    return BoxDecoration(
      color: colors.chrome,
      borderRadius: AppStyle.of(context).radius(8),
      border: Border.all(color: bad ? colors.erase : selected ? colors.accent : colors.line, width: selected ? 1.5 : 1),
    );
  }

  Widget _nodeCard(BuildContext context, _Layout l, GraphNode node) {
    final colors = context.colors, rect = l.nodes[node.id]!;
    final socket = ExtensionApi.socket(node.type);
    final title = switch (node.props['title']) { final String s when s.isNotEmpty => s, _ => socket?.title ?? node.type };
    return Positioned.fromRect(
      rect: rect,
      child: GestureDetector(
        onTap: () {
          _focus.requestFocus();
          setState(() => (_node = node.id, _port = null));
        },
        child: DecoratedBox(
          decoration: _card(context, selected: _node == node.id),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            MouseRegion(
              cursor: widget.readOnly ? MouseCursor.defer : SystemMouseCursors.move,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanUpdate: widget.readOnly ? null : (d) => _moveNode(node.id, d.delta),
                child: SizedBox(
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
              ),
            ),
            for (final port in l.portsOf[node.id]!) _portRow(context, l, node, socket?.port(port), port),
          ]),
        ),
      ),
    );
  }

  static AppIcon _socketIcon(GraphNode node, ApiSocket? socket) => switch (node.type) {
        'project' => AppIcon.project,
        'lane' => AppIcon.lanes,
        'command' => extensionIcon(node.props['icon'] ?? 'play'),
        'export' => AppIcon.export,
        'layer' => AppIcon.frame,
        _ => AppIcon.extensions,
      };

  Widget _portRow(BuildContext context, _Layout l, GraphNode node, ApiPort? port, String name) {
    final colors = context.colors, key = '${node.id}.$name';
    final wired = graph.wire(node.id, name) != null, marked = _port == key;
    final row = SizedBox(
      height: _row,
      child: Padding(
        padding: const EdgeInsets.only(left: 12, right: 14),
        child: Row(children: [
          Expanded(
            child: Text(name,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: port == null ? colors.textMuted : colors.text, fontWeight: marked ? FontWeight.w600 : null)),
          ),
          if (marked && wired && !widget.readOnly)
            Tip(
              message: 'Unwire'.tr,
              child: InkResponse(radius: 10, onTap: () => _unwire(key), child: Icon(AppIcon.close.of(context), size: 13, color: colors.textMuted)),
            ),
        ]),
      ),
    );
    return MouseRegion(
      cursor: widget.readOnly ? MouseCursor.defer : SystemMouseCursors.precise,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          _focus.requestFocus();
          setState(() => (_port = wired ? key : null, _node = node.id));
        },
        onPanStart: widget.readOnly ? null : (d) => setState(() => (_pulling = key, _pullTo = _local(d.globalPosition))),
        onPanUpdate: widget.readOnly ? null : (d) => setState(() => _pullTo = _local(d.globalPosition)),
        onPanEnd: widget.readOnly
            ? null
            : (_) {
                final at = _pullTo;
                setState(() => _pulling = null);
                _drop(l, key, at);
              },
        onPanCancel: () => setState(() => _pulling = null),
        child: port == null ? row : Tip(message: '${port.signature}\n${port.summary}', child: row),
      ),
    );
  }

  Widget _fileCard(BuildContext context, _Layout l, String path) {
    final colors = context.colors, rect = l.files[path]!;
    final unread = widget.functions.containsKey(path) && widget.functions[path] == null, gone = l.missingFiles.contains(path);
    final by = {for (final f in widget.functions[path] ?? const <FileFunction>[]) f.name: f};
    return Positioned.fromRect(
      rect: rect,
      child: DecoratedBox(
        decoration: _card(context, selected: false, bad: unread || gone),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          MouseRegion(
            cursor: widget.readOnly ? MouseCursor.defer : SystemMouseCursors.move,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanUpdate: widget.readOnly ? null : (d) => _moveFile(path, l.files[path]!, d.delta),
              child: SizedBox(
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
            ),
          ),
          for (final name in l.functionsOf[path]!)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onDoubleTap: by.containsKey(name) ? () => widget.onOpen?.call(path, name) : null,
              child: SizedBox(
                height: _row,
                child: Padding(
                  padding: const EdgeInsets.only(left: 14, right: 12),
                  child: Align(
                    alignment: Alignment.centerLeft,
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
    );
  }
}

/// The wires, each a curve from its port's dot to its function's, with the dots.
class _WiresPainter extends CustomPainter {
  _WiresPainter({required this.graph, required this.layout, required this.marked, required this.pulling, required this.pullTo, required this.color, required this.bad});
  final ConnectorGraph graph;
  final _Layout layout;
  final String? marked, pulling;
  final Offset pullTo;
  final Color color, bad;

  static Path _curve(Offset a, Offset b) {
    final reach = math.max(40.0, (b.dx - a.dx).abs() / 2);
    return Path()
      ..moveTo(a.dx, a.dy)
      ..cubicTo(a.dx + reach, a.dy, b.dx - reach, b.dy, b.dx, b.dy);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final wired = <String>{};
    for (final w in graph.wires) {
      final a = layout.portDots[w.from], b = layout.functionDots[w.to];
      if (a == null || b == null) continue;
      wired
        ..add(w.from)
        ..add(w.to);
      final broken = layout.missing.contains(w.to) || layout.missingFiles.contains(w.file);
      final on = w.from == marked;
      canvas.drawPath(
        _curve(a, b),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = on ? 2.5 : 1.5
          ..color = (broken ? bad : color).withValues(alpha: on || pulling == null ? 1 : 0.5),
      );
    }
    final dot = Paint()..color = color, hollow = Paint()..color = color.withValues(alpha: 0.35);
    for (final MapEntry(key: port, value: at) in layout.portDots.entries) {
      canvas.drawCircle(at, wired.contains(port) ? 4 : 3, wired.contains(port) ? dot : hollow);
    }
    for (final MapEntry(key: fn, value: at) in layout.functionDots.entries) {
      canvas.drawCircle(at, wired.contains(fn) ? 4 : 3, layout.missing.contains(fn) ? (Paint()..color = bad) : wired.contains(fn) ? dot : hollow);
    }
    if (pulling case final port?) {
      if (layout.portDots[port] case final a?) {
        canvas.drawPath(
          _curve(a, pullTo),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = color,
        );
        canvas.drawCircle(pullTo, 4, dot);
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
