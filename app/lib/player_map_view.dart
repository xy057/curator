import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:score_engine/score_engine.dart';

import 'app_colors.dart';
import 'app_icons.dart';
import 'color_dialog.dart';
import 'dialog_kit.dart';
import 'edit_dialogs.dart' show confirmSavePath;
import 'editor_controller.dart';
import 'error_text.dart';
import 'menu_kit.dart';
import 'ui_kit.dart';
import 'l10n/l10n.dart';
import 'player_map_paint.dart';

export 'player_map_paint.dart';

// MARK: The panel

/// The toolbar's Player Map (View ▸ Show Player Map): the project's map in the score's place,
/// swelling with the music as it plays; Edit… (or a double click) opens [showPlayerMapEditor], its
/// menu makes one by a smart seating, imports one (`.cpm`), exports it, or removes it, each an
/// Undo step.
class PlayerMapPanel extends StatelessWidget {
  const PlayerMapPanel({super.key, required this.controller});
  final EditorController controller;

  @override
  Widget build(BuildContext context) => Material(
        color: context.colors.surface,
        child: Select<PlayerMap?>(
          listenable: controller,
          select: () => controller.playerMap.map,
          builder: (context, map) => map == null
              ? _empty(context)
              : Stack(children: [
                  Positioned.fill(child: _map(context, map)),
                  PositionedDirectional(
                    top: 8,
                    end: 8,
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      ToolbarButton(icon: AppIcon.draw.of(context), tooltip: 'Edit…'.tr, onPressed: () => showPlayerMapEditor(context, controller)),
                      PlayerMapMenu(controller: controller),
                    ]),
                  ),
                ]),
        ),
      );

  Widget _map(BuildContext context, PlayerMap map) => GestureDetector(
        onDoubleTap: () => showPlayerMapEditor(context, controller),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
          // The pulses are asked of again when the notes arrive (the controller notifies).
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) => CustomPaint(
              size: Size.infinite,
              painter: PlayerMapPainter(
                map: map,
                pulses: controller.playerMap.pulses,
                time: controller.playback.time,
                textDirection: Directionality.of(context),
              ),
            ),
          ),
        ),
      );

  Widget _empty(BuildContext context) {
    final colors = context.colors;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('No player map'.tr, style: TextStyle(color: colors.textMuted)),
          const SizedBox(height: 14),
          AppPopupMenuButton<SeatingPreset>(
            tooltip: '',
            position: PopupMenuPosition.under,
            onSelected: (preset) => controller.playerMap.set(controller.playerMap.smart(preset)),
            itemBuilder: (context) => [for (final p in SeatingPreset.values) menuItem(context, value: p, child: Text(seatingName(p)))],
            child: IgnorePointer(child: FilledButton(onPressed: () {}, child: Text('Smart Seating'.tr))),
          ),
          const SizedBox(height: 8),
          TextButton(onPressed: () => PlayerMapFiles.import(context, controller), child: Text('Import…'.tr)),
        ]),
      ),
    );
  }
}

/// What a smart seating is called.
String seatingName(SeatingPreset preset) => switch (preset) {
      SeatingPreset.american => 'Orchestra (American)'.tr,
      SeatingPreset.european => 'Orchestra (European)'.tr,
      SeatingPreset.ensemble => 'Ensemble'.tr,
    };

enum _MenuChoice { american, european, ensemble, import, export, remove }

/// The player map's ⋯ menu: a smart seating for each preset, Import…, Export…, Remove.
class PlayerMapMenu extends StatelessWidget {
  const PlayerMapMenu({super.key, required this.controller});
  final EditorController controller;

  @override
  Widget build(BuildContext context) => AppPopupMenuButton<_MenuChoice>(
        tooltip: 'Player Map'.tr,
        icon: Icon(AppIcon.more.of(context), size: 18),
        position: PopupMenuPosition.under,
        onSelected: (choice) => switch (choice) {
          _MenuChoice.american => controller.playerMap.set(controller.playerMap.smart(SeatingPreset.american)),
          _MenuChoice.european => controller.playerMap.set(controller.playerMap.smart(SeatingPreset.european)),
          _MenuChoice.ensemble => controller.playerMap.set(controller.playerMap.smart(SeatingPreset.ensemble)),
          _MenuChoice.import => PlayerMapFiles.import(context, controller),
          _MenuChoice.export => PlayerMapFiles.export(context, controller.playerMap.map!, suggestedName: controller.score?.metadata.title),
          _MenuChoice.remove => controller.playerMap.set(null),
        },
        itemBuilder: (context) {
          final has = controller.playerMap.map != null;
          return [
            menuHeader(context, 'Smart Seating'.tr),
            menuItem(context, value: _MenuChoice.american, child: Text(seatingName(SeatingPreset.american))),
            menuItem(context, value: _MenuChoice.european, child: Text(seatingName(SeatingPreset.european))),
            menuItem(context, value: _MenuChoice.ensemble, child: Text(seatingName(SeatingPreset.ensemble))),
            menuDivider(context),
            menuItem(context, value: _MenuChoice.import, child: Text('Import…'.tr)),
            menuItem(context, value: _MenuChoice.export, enabled: has, child: Text('Export…'.tr)),
            menuDivider(context),
            menuItem(context, value: _MenuChoice.remove, enabled: has, child: Text('Remove'.tr)),
          ];
        },
      );
}

// MARK: Files

/// A map as a file of its own (`.cpm`): imported into a project (its players found again among
/// the score's instruments by name) and exported.
abstract final class PlayerMapFiles {
  static const _types = XTypeGroup(label: 'Player Map', extensions: [PlayerMap.fileExtension]);

  static Future<void> _say(BuildContext context, String title, String message) => showAppDialog<void>(
        context: context,
        builder: (context) => AppDialog(
          title: Text(title),
          content: SizedBox(width: dialogWidth(context, 380), child: Text(message)),
          actions: [FilledButton(onPressed: () => Navigator.pop(context), child: Text('OK'.tr))],
        ),
      );

  /// A map the user picks, made the project's: one Undo step. Its players play the score's
  /// instruments of the same names; null when nothing was picked or it couldn't be read.
  static Future<PlayerMap?> pick(BuildContext context, EditorController controller) async {
    final file = await openFile(acceptedTypeGroups: const [_types]);
    if (file == null || !context.mounted) return null;
    try {
      if (await file.length() > 16 << 20) throw const FormatException('It isn’t a player map.');
      return controller.playerMap.fitted(PlayerMap.decode(await file.readAsString()));
    } on FormatException catch (e) {
      if (context.mounted) {
        await _say(context, 'Couldn’t Import the Player Map'.tr,
            e.message.contains('newer') ? 'It needs a newer version of Curator.'.tr : 'It isn’t a player map.'.tr);
      }
    } on FileSystemException catch (e) {
      if (context.mounted) await _say(context, 'Couldn’t Import the Player Map'.tr, describeError(e));
    }
    return null;
  }

  /// Imports a map in place of the project's: one Undo step.
  static Future<void> import(BuildContext context, EditorController controller) async {
    final map = await pick(context, controller);
    if (map != null) controller.playerMap.set(map);
  }

  /// Saves [map] as a .cpm file where the user says.
  static Future<void> export(BuildContext context, PlayerMap map, {String? suggestedName}) async {
    final name = (suggestedName == null || suggestedName.trim().isEmpty) ? 'Player Map'.tr : suggestedName.trim();
    final location = await getSaveLocation(acceptedTypeGroups: const [_types], suggestedName: '$name.${PlayerMap.fileExtension}');
    if (location == null || !context.mounted) return;
    final path = await confirmSavePath(context, location.path, PlayerMap.fileExtension);
    if (path == null) return;
    try {
      await File(path).writeAsString(map.encode());
    } on FileSystemException catch (e) {
      if (context.mounted) await _say(context, 'Couldn’t Export the Player Map'.tr, describeError(e));
    }
  }
}

// MARK: The editor

/// Edit… of the player map: its sections on the stage at the left, the one selected at the right
/// (its name, the instrument and staff it plays, its colour, players, how they sit, their size);
/// in Players mode a player of it, which may play another instrument or staff than its section.
/// Dragged, a section moves (a player alone in Players mode; a name on its own); arrows nudge
/// it, Delete removes it. Its own Undo while open; Done makes it the project's, one Undo step.
Future<void> showPlayerMapEditor(BuildContext context, EditorController controller) async {
  final map = controller.playerMap.map;
  if (map == null) return;
  final edited = await Navigator.of(context, rootNavigator: true).push<PlayerMap>(PageRouteBuilder(
    fullscreenDialog: true,
    transitionDuration: motion(context, 200),
    reverseTransitionDuration: motion(context, 160),
    pageBuilder: (_, _, _) => PlayerMapEditor(controller: controller, map: map),
    transitionsBuilder: (_, animation, _, child) => FadeTransition(opacity: CurvedAnimation(parent: animation, curve: Curves.easeOutCubic), child: child),
  ));
  if (edited != null) controller.playerMap.set(edited);
}

enum _Mode { sections, players }

class PlayerMapEditor extends StatefulWidget {
  const PlayerMapEditor({super.key, required this.controller, required this.map});
  final EditorController controller;
  final PlayerMap map;

  @override
  State<PlayerMapEditor> createState() => _PlayerMapEditorState();
}

class _PlayerMapEditorState extends State<PlayerMapEditor> {
  late PlayerMap _map = widget.map;
  final _undo = <PlayerMap>[], _redo = <PlayerMap>[];
  int? _section, _seat;
  _Mode _mode = _Mode.sections;
  final _name = TextEditingController();
  final _focus = FocusNode();

  EditorController get c => widget.controller;
  MapSection? get _selected => _section == null || _section! >= _map.sections.length ? null : _map.sections[_section!];

  @override
  void dispose() {
    _name.dispose();
    _focus.dispose();
    super.dispose();
  }

  // MARK: Changes

  /// Makes [map] the one edited: an Undo step of the editor's ([gesture]: the drag's first move
  /// takes it, the rest join it).
  void _change(PlayerMap map, {bool gesture = false}) {
    if (map == _map) return;
    if (!gesture) {
      _undo.add(_map);
      _redo.clear();
    }
    setState(() => _map = map);
  }

  void _stepBack() {
    if (_undo.isEmpty) return;
    _redo.add(_map);
    setState(() {
      _map = _undo.removeLast();
      _keepSelection();
    });
  }

  void _stepOn() {
    if (_redo.isEmpty) return;
    _undo.add(_map);
    setState(() {
      _map = _redo.removeLast();
      _keepSelection();
    });
  }

  void _keepSelection() {
    if (_selected == null) _section = _seat = null;
    if (_seat != null && _seat! >= _selected!.seats.length) _seat = null;
    _name.text = _selected?.name ?? '';
  }

  void _select(int? section, {int? seat}) {
    _typing = null;
    setState(() {
      _section = section;
      _seat = _mode == _Mode.players ? seat : null;
      _name.text = _selected?.name ?? '';
    });
    _focus.requestFocus();
  }

  /// Section [k] made what [to] makes it.
  void _setSection(int k, MapSection Function(MapSection s) to, {bool gesture = false}) =>
      _change(_map.withSections([for (final (i, s) in _map.sections.indexed) i == k ? to(s) : s]), gesture: gesture);

  /// Section [k] seated anew as [section], what it would now cover moved out of its way.
  void _reseat(int k, MapSection section) => _change(_map.roomFor(k, section));

  void _addSection() {
    final colors = _map.sections.map((s) => s.color).toSet();
    final color = MapColors.all.firstWhere((c) => !colors.contains(c), orElse: () => MapColors.all.first);
    final section = MapSection(name: 'Section'.tr, color: color, labelX: 0.5, labelY: 0.5, seats: const [MapSeat(0.5, 0.45)])
        .arranged(SeatShape.rows, 4, aspect: _map.aspect);
    _change(_map.withSections([..._map.sections, section]));
    _select(_map.sections.length - 1);
  }

  void _delete() {
    final k = _section;
    if (k == null) return;
    if (_seat case final i? when _mode == _Mode.players && _map.sections[k].seats.length > 1) {
      // The rest seated anew as their plan seats one fewer, each keeping what it plays.
      final s = _map.sections[k], links = [for (final (j, x) in s.seats.indexed) if (j != i) x.link];
      final fewer = s.withCount(s.seats.length - 1, aspect: _map.aspect);
      _reseat(k, fewer.copyWith(seats: [for (final (j, x) in fewer.seats.indexed) x.linked(links[j])]));
      _select(k);
      return;
    }
    _change(_map.withSections([..._map.sections]..removeAt(k)));
    _select(null);
  }

  /// The selection moved by [dx], [dy] of the stage.
  void _nudge(double dx, double dy) {
    final k = _section;
    if (k == null) return;
    _setSection(k, (s) {
      if (_seat case final i? when _mode == _Mode.players) {
        return s.copyWith(seats: [for (final (j, seat) in s.seats.indexed) j == i ? seat.at(seat.x + dx, seat.y + dy) : seat]);
      }
      return s.moved(dx, dy);
    });
  }

  Future<void> _cancel() async {
    if (_map == widget.map) return Navigator.of(context).pop();
    final discard = await showAppDialog<bool>(
      context: context,
      builder: (context) => AppDialog(
        title: Text('Discard Your Changes?'.tr),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text('Keep Editing'.tr)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text('Discard'.tr)),
        ],
        confirmsOnReturn: false,
      ),
    );
    if (discard == true && mounted) Navigator.of(context).pop();
  }

  void _done() => Navigator.of(context).pop(_map == widget.map ? null : _map);

  // MARK: Pointer

  MapStage _stage(Size size) => MapStage(size, _map.aspect, inset: 12);

  /// What is at [p]: a seat (section, seat), a name (section, null), or nothing.
  (int, int?)? _hit(Offset p, Size size) {
    final stage = _stage(size);
    for (var k = _map.sections.length - 1; k >= 0; k--) {
      final s = _map.sections[k], r = stage.radius(s.size) + 3;
      for (var i = s.seats.length - 1; i >= 0; i--) {
        if ((stage.toView(s.seats[i].x, s.seats[i].y) - p).distance <= r) return (k, i);
      }
    }
    for (var k = _map.sections.length - 1; k >= 0; k--) {
      final s = _map.sections[k];
      final half = Size(s.name.length * stage.labelSize * 0.3 + 6, stage.labelSize * 0.7);
      final at = stage.toView(s.labelX, s.labelY);
      if ((p.dx - at.dx).abs() <= half.width && (p.dy - at.dy).abs() <= half.height) return (k, null);
    }
    return null;
  }

  /// What the drag under way moves: a section, one seat of it, or its name.
  ({int section, int? seat, bool label, Offset from, PlayerMap start})? _drag;

  void _down(Offset p, Size size) {
    final hit = _hit(p, size);
    if (hit == null) {
      _select(null);
      return;
    }
    final (k, i) = hit;
    _select(k, seat: i);
    _drag = (section: k, seat: _mode == _Mode.players ? i : null, label: i == null, from: p, start: _map);
  }

  void _move(Offset p, Size size) {
    final drag = _drag;
    if (drag == null) return;
    final stage = _stage(size);
    final dx = (p.dx - drag.from.dx) / stage.rect.width, dy = (p.dy - drag.from.dy) / stage.rect.height;
    final s = drag.start.sections[drag.section];
    final moved = switch (drag) {
      (label: true, seat: _, section: _, from: _, start: _) => s.copyWith(labelX: s.labelX + dx, labelY: s.labelY + dy),
      (seat: final int i, label: _, section: _, from: _, start: _) =>
        s.copyWith(seats: [for (final (j, seat) in s.seats.indexed) j == i ? seat.at(seat.x + dx, seat.y + dy) : seat]),
      _ => s.moved(dx, dy),
    };
    final first = identical(_map, drag.start);
    if (first) {
      _undo.add(drag.start);
      _redo.clear();
    }
    setState(() => _map = drag.start.withSections([for (final (j, x) in drag.start.sections.indexed) j == drag.section ? moved : x]));
  }

  // MARK: Building

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) _cancel();
      },
      child: Material(
        color: colors.surface,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _toolbar(context),
          Divider(height: 1, color: colors.line),
          Expanded(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(child: _canvas(context)),
              VerticalDivider(width: 1, color: colors.line),
              SizedBox(width: 300, child: _inspector(context)),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _toolbar(BuildContext context) {
    final colors = context.colors, style = AppStyle.of(context);
    return Container(
      height: style.toolbar + 8,
      color: colors.chrome,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(children: [
        Text('Edit Player Map'.tr, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: colors.text)),
        const SizedBox(width: 16),
        ToolbarButton(icon: AppIcon.undo.of(context), tooltip: 'Undo ({key})'.fill({'key': shortcut('⌘Z')}), onPressed: _undo.isEmpty ? null : _stepBack),
        ToolbarButton(
            icon: AppIcon.redo.of(context), tooltip: 'Redo ({key})'.fill({'key': shortcut('⇧⌘Z', 'Ctrl+Y')}), onPressed: _redo.isEmpty ? null : _stepOn),
        const ToolbarDivider(),
        Select<bool>(
          listenable: c,
          select: () => c.playback.isPlaying,
          builder: (context, playing) => ToolbarButton(
            icon: (playing ? AppIcon.pause : AppIcon.play).of(context),
            tooltip: playing ? 'Pause'.tr : 'Play'.tr,
            onPressed: c.playback.togglePlay,
          ),
        ),
        const ToolbarDivider(),
        AppSegmented<_Mode>(
          segments: [
            ButtonSegment(value: _Mode.sections, label: Text('Sections'.tr)),
            ButtonSegment(value: _Mode.players, label: Text('Players'.tr)),
          ],
          selected: _mode,
          onChanged: (mode) => setState(() {
            _mode = mode;
            _seat = null;
          }),
        ),
        const SizedBox(width: 8),
        ToolbarButton(icon: AppIcon.add.of(context), tooltip: 'Add Section'.tr, onPressed: _addSection),
        ToolbarButton(icon: AppIcon.delete.of(context), tooltip: 'Delete'.tr, onPressed: _section == null ? null : _delete),
        AppPopupMenuButton<SeatingPreset>(
          tooltip: 'Smart Seating'.tr,
          icon: Icon(AppIcon.autoCurate.of(context), size: 18),
          position: PopupMenuPosition.under,
          onSelected: (preset) {
            _change(c.playerMap.smart(preset));
            _select(null);
          },
          itemBuilder: (context) => [
            menuHeader(context, 'Smart Seating'.tr),
            for (final p in SeatingPreset.values) menuItem(context, value: p, child: Text(seatingName(p))),
          ],
        ),
        const Spacer(),
        TextButton(onPressed: _cancel, child: Text('Cancel'.tr)),
        const SizedBox(width: 8),
        FilledButton(onPressed: _done, child: Text('Done'.tr)),
      ]),
    );
  }

  Widget _canvas(BuildContext context) {
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    final step = 0.005;
    return CallbackShortcuts(
      bindings: {
        SingleActivator(LogicalKeyboardKey.keyZ, meta: mac, control: !mac): _stepBack,
        SingleActivator(LogicalKeyboardKey.keyZ, meta: mac, control: !mac, shift: true): _stepOn,
        if (!mac) const SingleActivator(LogicalKeyboardKey.keyY, control: true): _stepOn,
        const SingleActivator(LogicalKeyboardKey.delete): _delete,
        const SingleActivator(LogicalKeyboardKey.backspace): _delete,
        const SingleActivator(LogicalKeyboardKey.escape): () => _select(null),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _nudge(-step, 0),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _nudge(step, 0),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => _nudge(0, -step),
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => _nudge(0, step),
        const SingleActivator(LogicalKeyboardKey.space): c.playback.togglePlay,
      },
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        child: LayoutBuilder(builder: (context, constraints) {
          final size = constraints.biggest;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanDown: (d) => _down(d.localPosition, size),
            onPanUpdate: (d) => _move(d.localPosition, size),
            onPanEnd: (_) => setState(() => _drag = null),
            onPanCancel: () => _drag = null,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: ListenableBuilder(
                listenable: c,
                builder: (context, _) => CustomPaint(
                  size: Size.infinite,
                  painter: PlayerMapPainter(
                    map: _map,
                    pulses: c.playerMap.pulses,
                    time: c.playback.time,
                    selected: _section,
                    selectedSeat: _mode == _Mode.players ? _seat : null,
                    accent: context.colors.accent,
                    textDirection: Directionality.of(context),
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  // MARK: Inspector

  Widget _inspector(BuildContext context) {
    final s = _selected;
    return ListView(padding: const EdgeInsets.all(16), children: s == null ? _sections(context) : _sectionFields(context, s));
  }

  /// With nothing selected: every section, a click selecting it.
  List<Widget> _sections(BuildContext context) {
    final colors = context.colors;
    return [
      _Heading('Sections'.tr),
      for (final (k, s) in _map.sections.indexed)
        InkWell(
          onTap: () => _select(k),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(children: [
              Container(width: 10, height: 10, decoration: BoxDecoration(color: Color(s.color), shape: BoxShape.circle)),
              const SizedBox(width: 10),
              Expanded(child: Text(s.name.isEmpty ? '–' : s.name, overflow: TextOverflow.ellipsis)),
              Text('${s.seats.length}', style: TextStyle(color: colors.textMuted)),
            ]),
          ),
        ),
      const SizedBox(height: 12),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: OutlinedButton(onPressed: _addSection, child: Text('Add Section'.tr)),
      ),
    ];
  }

  /// The instruments a link may name, and a choice for none (or the section's).
  Widget _linkFields(BuildContext context, {required PlayerLink? link, required ValueChanged<PlayerLink?> onChanged, String? none}) {
    final parts = c.playerMap.parts;
    final part = parts.where((p) => p.id == link?.part).firstOrNull;
    final staves = part?.staffNumbers.length ?? 0;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      AppDropdown<String>(
        label: 'Instrument'.tr,
        isExpanded: true,
        boxed: true,
        value: part?.id ?? '',
        items: [
          DropdownMenuItem(value: '', child: Text(none ?? 'None'.tr)),
          for (final p in parts) DropdownMenuItem(value: p.id, child: Text(c.playerMap.nameOf(p), overflow: TextOverflow.ellipsis)),
        ],
        onChanged: (id) {
          final p = parts.where((p) => p.id == id).firstOrNull;
          onChanged(p == null ? null : c.playerMap.linkTo(p));
        },
      ),
      if (part != null && staves > 1) ...[
        SizedBox(height: dialogGap(context) / 2),
        AppDropdown<int>(
          label: 'Staff'.trIn('player map'),
          isExpanded: true,
          boxed: true,
          value: link?.staff ?? 0,
          items: [
            DropdownMenuItem(value: 0, child: Text('All Staves'.tr)),
            for (var n = 1; n <= staves; n++) DropdownMenuItem(value: n, child: Text('Staff {n}'.fill({'n': '$n'}))),
          ],
          onChanged: (n) => onChanged(c.playerMap.linkTo(part, staff: n == 0 ? null : n)),
        ),
      ],
    ]);
  }

  List<Widget> _sectionFields(BuildContext context, MapSection s) {
    final k = _section!, gap = dialogGap(context);
    final seat = _mode == _Mode.players ? _seat : null;
    return [
      AppTextField(
        controller: _name,
        label: 'Name'.tr,
        // A section's name typed at one go is one Undo step.
        onChanged: (text) {
          _setSection(k, (s) => s.copyWith(name: text), gesture: _typing == k);
          _typing = k;
        },
      ),
      SizedBox(height: gap),
      _linkFields(context, link: s.link, onChanged: (link) => _setSection(k, (s) => s.linked(link))),
      SizedBox(height: gap),
      _Heading('Color'.tr),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final color in MapColors.all) _Swatch(color: color, chosen: s.color == color, onTap: () => _setSection(k, (s) => s.copyWith(color: color))),
        _Swatch(
          color: MapColors.all.contains(s.color) ? null : s.color,
          chosen: !MapColors.all.contains(s.color),
          onTap: () async {
            final picked = await showColorDialog(context, initial: Color(s.color));
            if (picked != null) _setSection(k, (s) => s.copyWith(color: picked.toARGB32() | 0xFF000000));
          },
        ),
      ]),
      SizedBox(height: gap),
      _Heading('Players'.tr),
      Row(children: [
        IconButton(
          icon: const Text('−', style: TextStyle(fontSize: 18, height: 1)),
          tooltip: 'Fewer'.tr,
          onPressed: s.seats.length > 1 ? () => _reseat(k, s.withCount(s.seats.length - 1, aspect: _map.aspect)) : null,
        ),
        SizedBox(width: 36, child: Text('${s.seats.length}', textAlign: TextAlign.center)),
        IconButton(
          icon: Icon(AppIcon.add.of(context), size: 16),
          tooltip: 'More'.tr,
          onPressed: s.seats.length < 64 ? () => _reseat(k, s.withCount(s.seats.length + 1, aspect: _map.aspect)) : null,
        ),
      ]),
      SizedBox(height: gap / 2),
      AppSegmented<SeatShape>(
        // Auto (back to how Smart Seating seated it) only for a section it seated.
        key: ValueKey(s.auto != null),
        expand: true,
        segments: [
          if (s.auto != null) ButtonSegment(value: SeatShape.auto, label: Text('Auto'.tr)),
          ButtonSegment(value: SeatShape.rows, label: Text('Rows'.tr)),
          ButtonSegment(value: SeatShape.arc, label: Text('Arc'.tr)),
          ButtonSegment(value: SeatShape.line, label: Text('Line'.tr)),
        ],
        selected: s.shape,
        onChanged: (shape) => _reseat(k, s.arranged(shape, s.seats.length, aspect: _map.aspect)),
      ),
      SizedBox(height: gap),
      _Heading('Size'.tr),
      Slider(
        value: s.size.clamp(MapSection.minSize, 0.12),
        min: MapSection.minSize,
        max: 0.12,
        onChangeStart: (_) {
          _undo.add(_map);
          _redo.clear();
        },
        onChanged: (v) => _setSection(k, (s) => s.copyWith(size: v), gesture: true),
      ),
      if (seat != null && seat < s.seats.length) ...[
        SizedBox(height: gap),
        Divider(height: 1, color: context.colors.line),
        SizedBox(height: gap),
        _Heading('Player {n}'.fill({'n': '${seat + 1}'})),
        _linkFields(
          context,
          link: s.seats[seat].link,
          none: 'Same as Section'.tr,
          onChanged: (link) => _setSection(k, (s) => s.copyWith(seats: [for (final (j, x) in s.seats.indexed) j == seat ? x.linked(link) : x])),
        ),
      ],
      SizedBox(height: gap * 1.5),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: OutlinedButton(onPressed: _delete, child: Text(seat != null ? 'Remove Player'.tr : 'Remove Section'.tr)),
      ),
    ];
  }

  /// The section whose name is being typed: its keystrokes are one Undo step.
  int? _typing;
}

/// A heading over the inspector's fields.
class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: context.colors.textMuted)),
      );
}

/// A colour to choose; without one, Custom… (a rainbow ring).
class _Swatch extends StatelessWidget {
  const _Swatch({required this.color, required this.chosen, required this.onTap});
  final int? color;
  final bool chosen;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Tip(
      message: color == null ? 'Custom…' : '',
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color == null ? null : Color(color!),
            gradient: color == null
                ? const SweepGradient(colors: [Color(0xFFE53935), Color(0xFFFDD835), Color(0xFF43A047), Color(0xFF1E88E5), Color(0xFF8E24AA), Color(0xFFE53935)])
                : null,
            border: Border.all(color: chosen ? colors.accent : colors.line, width: chosen ? 2 : 1),
          ),
        ),
      ),
    );
  }
}
