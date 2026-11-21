import 'dart:convert';

import 'package:flutter/foundation.dart';

/// What the editor's toolbar can hold (View ▸ Customize Toolbar…), by the name it is saved
/// under. One with a [command] is a button doing that command of the app's
/// ([PluginApi.commands]), greyed out while the menus' item is; the rest are controls of the
/// toolbar's own (the time, the view's switch, the Export menu…). [space] and [divider] can be
/// there any number of times ([repeats]); everything else once, on the bar or in its menu.
enum BarItem {
  goToStart('Go to start', command: 'goToStart'),
  playPause('Play / Pause', command: 'playPause'),
  goToEnd('Go to end', command: 'goToEnd'),
  metronome('Metronome', command: 'metronome'),

  /// The time and the bar.beat sounding, clicked to type where to go.
  readout('Go to bar or time'),
  findPhrase('Find Phrase…', command: 'findPhrase'),

  /// The score, its MIDI view or the player map in its place.
  viewSwitch('Score / Player Map'),
  undo('Undo', command: 'undo'),
  redo('Redo', command: 'redo'),

  /// Attach Image's Manage assets…: there only while the project has the extension on.
  assets('Manage assets…'),

  /// The buttons plugins put on the toolbar, all of them.
  plugins('Plugins'),

  /// The Export menu: a video or a web page.
  export('Export'),
  videoRatio('Video ratio'),
  scoreSize('Score size'),
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

  /// Room that takes what the bar has left over, shared among all of them.
  space('Flexible Space', repeats: true),
  divider('Divider', repeats: true);

  const BarItem(this.label, {this.command, this.repeats = false});

  /// Its name, in English (translated where shown).
  final String label;

  /// The app's command it does, by its id; null for a control of the toolbar's own.
  final String? command;

  /// Whether the toolbar can hold several.
  final bool repeats;
}

/// Where the toolbar's items are: on the bar, or in the menu at its end (»).
enum BarArea { bar, menu }

/// A place among an area's items: before the one at [index] (its length: after the last).
typedef BarPlace = ({BarArea area, int index});

/// An item being dragged while the toolbar is customized: from its place, or (null) from the
/// palette.
typedef BarDrag = ({BarItem item, BarPlace? from});

/// Where the editor's toolbar has its items, left to right on the [bar] and top to bottom in
/// the [menu] at its end; those in neither are the ones left to add ([palette]). The same for
/// every project ([AppSettings.toolbar]).
@immutable
class ToolbarLayout {
  /// [bar] and [menu] as given, an item that can be there only once kept where it comes
  /// first, and no room to share out in the menu.
  factory ToolbarLayout({required List<BarItem> bar, List<BarItem> menu = const []}) {
    final seen = <BarItem>{};
    bool keep(BarItem item) => item.repeats || seen.add(item);
    return ToolbarLayout._(
      List.unmodifiable(bar.where(keep)),
      List.unmodifiable(menu.where((item) => item != BarItem.space && keep(item))),
    );
  }

  const ToolbarLayout._(this.bar, this.menu);

  /// The toolbar as the app comes.
  static const standard = ToolbarLayout._([
    BarItem.goToStart, BarItem.playPause, BarItem.metronome, BarItem.readout, BarItem.findPhrase, BarItem.divider, BarItem.viewSwitch, //
    BarItem.space,
    BarItem.undo, BarItem.redo, BarItem.divider, BarItem.assets, BarItem.plugins, BarItem.export, BarItem.videoRatio, BarItem.divider, BarItem.scoreSize,
  ], []);

  final List<BarItem> bar, menu;

  bool get isStandard => this == standard;

  List<BarItem> of(BarArea area) => area == BarArea.bar ? bar : menu;

  /// What can be added: every item in neither, and those there can be several of.
  List<BarItem> get palette => [
        for (final item in BarItem.values)
          if (item.repeats || !(bar.contains(item) || menu.contains(item))) item,
      ];

  /// [item] taken from [from] (null: from the palette) and put at [to] (null: back to the
  /// palette). [to] is a place as the area is now, [item] still at [from].
  ToolbarLayout moved(BarItem item, {BarPlace? from, BarPlace? to}) {
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
    return ToolbarLayout(bar: lists[BarArea.bar]!, menu: lists[BarArea.menu]!);
  }

  /// As saved: `{"bar": ["goToStart", "space", …], "menu": []}`, by name.
  String write() => jsonEncode({'bar': [for (final item in bar) item.name], 'menu': [for (final item in menu) item.name]});

  /// What [write] wrote, an item this version hasn't got left out; the standard toolbar from
  /// nothing, or from what can't be read.
  static ToolbarLayout read(String? json) {
    if (json == null) return standard;
    try {
      final saved = jsonDecode(json) as Map;
      final names = BarItem.values.asNameMap();
      List<BarItem> items(Object? list) => [for (final name in list as List) ?names[name]];
      return ToolbarLayout(bar: items(saved['bar']), menu: items(saved['menu'] ?? const []));
    } catch (_) {
      return standard; // damaged, or a newer version's
    }
  }

  @override
  bool operator ==(Object other) => other is ToolbarLayout && listEquals(other.bar, bar) && listEquals(other.menu, menu);

  @override
  int get hashCode => Object.hash(Object.hashAll(bar), Object.hashAll(menu));
}
