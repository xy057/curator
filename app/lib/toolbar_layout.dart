import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'l10n/l10n.dart';

/// The app's toolbars, each with items and a layout of its own: the one above the score
/// ([editor]) and the timeline's, one for each of its tabs.
enum BarKind {
  editor('Toolbar'),
  instruments('Instruments'),
  audio('Audio'),
  video('Video');

  const BarKind(this.label);

  /// Its name, in English (translated where shown).
  final String label;

  /// The timeline's, for the tab at [index] of its tabs (BottomTab).
  static BarKind ofTab(int index) => values[index + 1];

  /// Its tab's place among the timeline's; null for the one above the score.
  int? get tab => this == editor ? null : index - 1;
}

const _everywhere = BarKind.values;
const _editor = [BarKind.editor];
const _panel = [BarKind.instruments, BarKind.audio, BarKind.video];
const _instruments = [BarKind.instruments];
const _audio = [BarKind.audio];
const _video = [BarKind.video];
const _macroBars = [BarKind.editor, BarKind.instruments, BarKind.audio];

/// What a toolbar can hold (View ▸ Customize Toolbar…), by the name it is saved under, and
/// which toolbars ([on]). One with a [command] is a button doing that command of the app's
/// ([PluginApi.commands]), greyed out while the menus' item is: any toolbar takes it. The rest
/// are controls of a toolbar's own (the time, the view's switch, a tab's tools…). [space] and
/// [divider] can be there any number of times ([repeats]); everything else once, on the bar or
/// in its menu.
enum BarItem {
  goToStart('Go to start', command: 'goToStart'),
  playPause('Play / Pause', command: 'playPause'),
  goToEnd('Go to end', command: 'goToEnd'),
  metronome('Metronome', command: 'metronome'),

  /// The time and the bar.beat sounding, clicked to type where to go.
  readout('Go to bar or time', on: _editor),
  findPhrase('Find Phrase…', command: 'findPhrase'),

  /// The score, its MIDI view or the player map in its place.
  viewSwitch('Score / Player Map', on: _editor),
  undo('Undo', command: 'undo'),
  redo('Redo', command: 'redo'),

  /// Attach Image's Manage assets…: there only while the project has the extension on.
  assets('Manage assets…', on: _editor),

  /// The buttons plugins put on the toolbar, all of them.
  plugins('Plugins', on: _editor),

  /// The Export menu: a video or a web page.
  export('Export', on: _editor),
  videoRatio('Video ratio', on: _editor),
  scoreSize('Score size', on: _editor),
  newProject('New Project', command: 'newProject'),
  open('Open…', command: 'open'),
  importScore('Import…', command: 'importScore'),
  save('Save', command: 'save'),
  exportVideo('Export Video…', command: 'exportVideo'),
  exportWeb('Export to Web…', command: 'exportWeb'),
  followDaw('Connect Attacca…', command: 'followDaw'),
  cut('Cut', command: 'cut'),
  copy('Copy', command: 'copy'),
  paste('Paste', command: 'paste'),
  delete('Delete', command: 'delete'),
  tapAnchors('Tap anchors', command: 'tapAnchors'),
  warp('Warp', command: 'warp'),
  showPreview('Hide / Show Preview', command: 'showPreview'),
  showTimeline('Hide / Show Timeline', command: 'showTimeline'),
  projectSettings('Project Settings…', command: 'projectSettings'),
  settings('Settings…', command: 'settings'),

  // The timeline's, in every tab.

  /// The lanes' tools, one chosen.
  laneTools('Select / Draw / Erase', on: _panel),
  zoomOut('Zoom out', on: _panel),
  zoomIn('Zoom in', on: _panel),
  fit('Fit', on: _panel),
  speed('Playback speed', on: _panel),

  // The Instruments tab's. Those of the selection are there only while something is selected.
  trimStart('Start at the playhead', on: _instruments),
  trimEnd('End at the playhead', on: _instruments),

  /// Removes the selection: the Instruments tab's regions, the Video tab's stretch.
  remove('Remove', on: [BarKind.instruments, BarKind.video]),
  transition('Transition', on: _instruments),
  staves('Staves', on: _instruments),
  tidy('Tidy All Lanes', on: _instruments),
  autoCurate('Auto-curate', on: _instruments),
  clearLanes('Clear all lanes', on: _instruments),

  /// The lanes written instead of drawn: the script in their place.
  script('Script', on: _instruments),

  /// The app's macros, run from a menu, and what edits them.
  macros('Macros', on: [BarKind.instruments, BarKind.audio]),

  /// A macro as a button of its own, under its icon: one for each of the first nine, as their
  /// keys count them ([macro]: which). There only while there is such a macro.
  macro1('Macro 1', on: _macroBars, macro: 0),
  macro2('Macro 2', on: _macroBars, macro: 1),
  macro3('Macro 3', on: _macroBars, macro: 2),
  macro4('Macro 4', on: _macroBars, macro: 3),
  macro5('Macro 5', on: _macroBars, macro: 4),
  macro6('Macro 6', on: _macroBars, macro: 5),
  macro7('Macro 7', on: _macroBars, macro: 6),
  macro8('Macro 8', on: _macroBars, macro: 7),
  macro9('Macro 9', on: _macroBars, macro: 8),

  // The Audio tab's. Those of the sync are there only while a recording's sync is edited.
  addRecording('Add Recording…', on: _audio),
  crossfade('Crossfade', on: _audio),
  align('Align', on: _audio),

  /// What a tap, a click and ↑/↓ step by: a bar or a beat.
  syncStep('Anchor step', on: _audio),
  startsAt('Silence before bar 1 (s)', on: _audio),
  syncMenu('Sync', on: _audio),

  // The Video tab's.

  /// The view the stretch selected shows, or the one Draw paints.
  viewKind('View', on: _video, context: 'video'),
  mapPlace('Where the map goes', on: _video),
  mapSize('Map size', on: _video),

  /// How long the change into the stretch selected takes.
  viewFade('Crossfade', on: _video),

  /// Room that takes what the bar has left over, shared among all of them.
  space('Flexible Space', repeats: true),
  divider('Divider', repeats: true);

  const BarItem(this.label, {this.command, this.repeats = false, this.on = _everywhere, this.context, this.macro});

  /// The macros' buttons, the first macro's first.
  static const macroButtons = [macro1, macro2, macro3, macro4, macro5, macro6, macro7, macro8, macro9];

  /// Its name, in English ([title]: translated).
  final String label;

  /// What tells [label] from the same word meaning something else, for its translation.
  final String? context;

  /// The app's command it does, by its id; null for a control of a toolbar's own.
  final String? command;

  /// The macro it runs, by its place in the app's list (0 the first); null for any other item.
  final int? macro;

  /// Whether a toolbar can hold several.
  final bool repeats;

  /// The toolbars that can hold it.
  final List<BarKind> on;

  /// Its name as shown.
  String get title => context == null ? label.tr : label.trIn(context!);
}

/// Where the toolbar's items are: on the bar, or in the menu at its end (»).
enum BarArea { bar, menu }

/// A place among an area's items: before the one at [index] (its length: after the last).
typedef BarPlace = ({BarArea area, int index});

/// An item being dragged while a toolbar is customized: from its place, or (null) from the
/// palette.
typedef BarDrag = ({BarItem item, BarPlace? from});

/// Where a toolbar ([kind]) has its items, left to right on the [bar] and top to bottom in the
/// [menu] at its end; those in neither are the ones left to add ([palette]). The same for
/// every project ([AppSettings.toolbarOf]).
@immutable
class ToolbarLayout {
  /// [bar] and [menu] as given, without what [kind] can't hold, an item that can be there only
  /// once kept where it comes first, and no room to share out in the menu.
  factory ToolbarLayout({required BarKind kind, required List<BarItem> bar, List<BarItem> menu = const []}) {
    final seen = <BarItem>{};
    bool keep(BarItem item) => item.on.contains(kind) && (item.repeats || seen.add(item));
    return ToolbarLayout._(
      kind,
      List.unmodifiable(bar.where(keep)),
      List.unmodifiable(menu.where((item) => item != BarItem.space && keep(item))),
    );
  }

  const ToolbarLayout._(this.kind, this.bar, this.menu);

  /// Each toolbar as the app comes.
  static const _standard = {
    BarKind.editor: ToolbarLayout._(BarKind.editor, [
      BarItem.goToStart, BarItem.playPause, BarItem.metronome, BarItem.readout, BarItem.findPhrase, BarItem.divider, BarItem.viewSwitch, //
      BarItem.space,
      BarItem.undo, BarItem.redo, BarItem.divider, BarItem.assets, BarItem.plugins, BarItem.export, BarItem.videoRatio, BarItem.divider, BarItem.scoreSize,
    ], []),
    BarKind.instruments: ToolbarLayout._(BarKind.instruments, [
      BarItem.laneTools, //
      BarItem.space,
      BarItem.trimStart, BarItem.trimEnd, BarItem.remove, BarItem.divider, BarItem.transition, BarItem.staves, BarItem.divider, //
      BarItem.tidy, BarItem.autoCurate, BarItem.clearLanes, BarItem.divider, ..._panelEnd,
    ], []),
    BarKind.audio: ToolbarLayout._(BarKind.audio, [
      BarItem.addRecording, BarItem.laneTools, BarItem.crossfade, BarItem.divider, //
      BarItem.align, BarItem.tapAnchors, BarItem.warp, BarItem.syncStep, BarItem.startsAt, //
      BarItem.space,
      BarItem.syncMenu, BarItem.divider, BarItem.speed, BarItem.divider, ..._panelEnd,
    ], []),
    BarKind.video: ToolbarLayout._(BarKind.video, [
      BarItem.laneTools, BarItem.viewKind, BarItem.mapPlace, BarItem.mapSize, BarItem.divider, BarItem.viewFade, BarItem.remove, //
      BarItem.space,
      ..._panelEnd,
    ], []),
  };

  /// The end of the timeline's bar in every tab: its zoom, then Project Settings….
  static const _panelEnd = [BarItem.zoomOut, BarItem.zoomIn, BarItem.fit, BarItem.divider, BarItem.projectSettings];

  /// [kind]'s toolbar as the app comes.
  static ToolbarLayout standard(BarKind kind) => _standard[kind]!;

  /// The toolbar it is of.
  final BarKind kind;
  final List<BarItem> bar, menu;

  bool get isStandard => this == standard(kind);

  List<BarItem> of(BarArea area) => area == BarArea.bar ? bar : menu;

  /// What can be added: every item of this toolbar's in neither, and those there can be
  /// several of.
  List<BarItem> get palette => [
        for (final item in BarItem.values)
          if (item.on.contains(kind) && (item.repeats || !(bar.contains(item) || menu.contains(item)))) item,
      ];

  /// [item] taken from [from] (null: from the palette) and put at [to] (null: back to the
  /// palette). [to] is a place as the area is now, [item] still at [from]. As it is for an
  /// item this toolbar can't hold.
  ToolbarLayout moved(BarItem item, {BarPlace? from, BarPlace? to}) {
    if (!item.on.contains(kind)) return this;
    final lists = {BarArea.bar: [...bar], BarArea.menu: [...menu]};
    var at = to?.index;
    if (from != null) {
      final list = lists[from.area]!;
      if (from.index < 0 || from.index >= list.length || list[from.index] != item) return this; // not there any more
      list.removeAt(from.index);
      if (to != null && to.area == from.area && from.index < to.index) at = at! - 1;
    }
    if (to != null) {
      final list = lists[to.area]!;
      // One of a kind coming from the palette while it is somewhere already (it isn't offered
      // then): moved, not doubled.
      if (from == null && !item.repeats) {
        for (final each in lists.values) {
          final was = each.indexOf(item);
          if (was < 0) continue;
          each.removeAt(was);
          if (identical(each, list) && was < at!) at--;
        }
      }
      list.insert(at!.clamp(0, list.length), item);
    }
    return ToolbarLayout(kind: kind, bar: lists[BarArea.bar]!, menu: lists[BarArea.menu]!);
  }

  /// The macros' buttons following their macros to other places in the app's list ([to]: where
  /// the macro at a place is now; null: gone, and its button with it, as is one past the ninth).
  ToolbarLayout macrosMoved(int? Function(int at) to) {
    BarItem? moved(BarItem item) {
      final at = item.macro;
      if (at == null) return item;
      final now = to(at);
      return now == null || now < 0 || now >= BarItem.macroButtons.length ? null : BarItem.macroButtons[now];
    }

    return ToolbarLayout(kind: kind, bar: _ruledOnce([for (final item in bar) ?moved(item)]), menu: [for (final item in menu) ?moved(item)]);
  }

  /// [items] without a rule that another follows, or that nothing does where the bar didn't end
  /// with one: what an item taken from between two, or from after the last, leaves.
  List<BarItem> _ruledOnce(List<BarItem> items) => items.length == bar.length
      ? items
      : [
          for (final (i, item) in items.indexed)
            if (item != BarItem.divider || (i + 1 == items.length ? bar.last == BarItem.divider : items[i + 1] != BarItem.divider)) item,
        ];

  /// With [item] on the bar, before its end's group (the zoom and what follows, where it has
  /// one) or last, a rule setting it apart from a tool before it (not from another macro's
  /// button); as it is when [item] is there already, on the bar or in the menu.
  ToolbarLayout added(BarItem item) {
    if (!item.on.contains(kind) || bar.contains(item) || menu.contains(item)) return this;
    var at = bar.indexOf(BarItem.zoomOut);
    if (at > 0 && bar[at - 1] == BarItem.divider) at--;
    if (at < 0) at = bar.length;
    final before = at > 0 ? bar[at - 1] : null;
    final apart = before != null && before != BarItem.divider && before != BarItem.space && before.macro == null;
    return ToolbarLayout(kind: kind, bar: [...bar]..insertAll(at, [if (apart) BarItem.divider, item]), menu: menu);
  }

  /// Without [item], on the bar or in the menu (and the rule that set it apart, with the last).
  ToolbarLayout without(BarItem item) =>
      ToolbarLayout(kind: kind, bar: _ruledOnce([for (final each in bar) if (each != item) each]), menu: [for (final each in menu) if (each != item) each]);

  /// As saved: `{"bar": ["goToStart", "space", …], "menu": []}`, by name.
  String write() => jsonEncode({'bar': [for (final item in bar) item.name], 'menu': [for (final item in menu) item.name]});

  /// What [write] wrote for [kind]'s toolbar, an item this version hasn't got left out; the
  /// standard toolbar from nothing, or from what can't be read.
  static ToolbarLayout read(BarKind kind, String? json) {
    if (json == null) return standard(kind);
    try {
      final saved = jsonDecode(json) as Map;
      final names = BarItem.values.asNameMap();
      List<BarItem> items(Object? list) => [for (final name in list as List) ?names[name]];
      return ToolbarLayout(kind: kind, bar: items(saved['bar']), menu: items(saved['menu'] ?? const []));
    } catch (_) {
      return standard(kind); // damaged, or a newer version's
    }
  }

  @override
  bool operator ==(Object other) =>
      other is ToolbarLayout && other.kind == kind && listEquals(other.bar, bar) && listEquals(other.menu, menu);

  @override
  int get hashCode => Object.hash(kind, Object.hashAll(bar), Object.hashAll(menu));
}
