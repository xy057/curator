part of '../editor_controller.dart';

/// What the window's commands do now (the Edit menu, the keys, the toolbars' Remove): each acts
/// on the tab showing, the Instruments tab's regions or the Audio tab's anchors. A menu item is
/// enabled by the same `can…` its command checks.
class EditCommands {
  EditCommands._(this._editor);
  final EditorController _editor;

  bool get _open => _editor._score != null;
  bool get _curating => _open && _editor._tab == BottomTab.instruments;
  bool get _syncing => _open && _editor._tab == BottomTab.audio;
  LaneEditing get _lanes => _editor.lanes;
  SyncEditing get _anchors => _editor.anchors;

  /// Cut and Copy: the regions selected in the Instruments tab.
  bool get canCopy => _curating && _lanes.selected.isNotEmpty;

  void copy() {
    if (canCopy) _lanes.copy();
  }

  void cut() {
    if (canCopy) _lanes.cut();
  }

  /// Whether Paste puts copied regions in (in the Instruments tab while there are some).
  bool get pastesRegions => _curating && _lanes.canPaste;

  /// Whether Paste is Attach Image's: an image from the clipboard (see [ImageEditing.paste]).
  bool get pastesImage => _open && !pastesRegions && _editor.images.enabled;

  bool get canPaste => pastesRegions || pastesImage;

  /// Paste, when it puts regions in ([pastesRegions]); an image is the window's to paste, as
  /// it says when there is none.
  void pasteRegions() {
    if (pastesRegions) _lanes.paste();
  }

  /// Whether Delete has anything to remove.
  bool get canDelete =>
      _open &&
      (_editor.images._selected != null ||
          _editor.captions._selected != null ||
          _editor.spacers.hasSelection ||
          (_syncing ? !_anchors._isEmpty || _editor.takeSelection != null : _lanes.selected.isNotEmpty));

  /// Delete: a selected image goes first, then a selected caption, a selected spacer, then what is selected in
  /// the tab showing.
  void delete() {
    if (!_open) return;
    if (_editor.images._selected != null) return _editor.images.remove();
    if (_editor.captions._selected != null) return _editor.captions.remove();
    if (_editor.spacers.hasSelection) {
      _editor.spacers.removeSelected();
      return;
    }
    if (_syncing && _editor.takeSelection != null) return _editor.removeTakeRegion();
    _syncing ? _anchors.delete() : _lanes.delete();
  }

  bool get canSelectAll => _open;

  void selectAll() {
    if (_syncing) _anchors.selectAll();
    if (_curating) _lanes.selectAll();
  }

  /// Space: taps an anchor while tapping is armed (the Audio tab), else plays or pauses.
  void space() => _syncing && _anchors.tapArmed ? _anchors.tap() : _editor.playback.togglePlay();

  /// ←/→ nudge the selected anchors (10 ms, [fine] 1 ms) or regions (a bar, [fine] a beat);
  /// with nothing selected, skip 5 s ([fine] 1 s). [nudge] (⌥) always moves the playhead 0.1 s.
  void arrow(int direction, {required bool fine, bool nudge = false}) {
    if (nudge) {
      _editor.playback.skip(direction * 0.1);
    } else if (_syncing && _anchors.selected.isNotEmpty) {
      _anchors.nudge(direction * (fine ? 0.001 : 0.01));
    } else if (_curating && _lanes.selected.isNotEmpty) {
      _lanes.nudge(direction, beat: fine);
    } else {
      _editor.playback.skip(direction * (fine ? 1.0 : 5.0));
    }
  }

  /// ↑/↓ move the selection to the lane above / below, or re-bar the selected anchors (↑ the
  /// next bar or beat, ↓ the previous).
  void vertical(int direction) {
    if (_curating) {
      _lanes.selectNextLane(direction);
    } else if (_syncing) {
      _anchors.shift(-direction);
    }
  }

  /// Esc: stops tapping, else goes back to the Select tool, else selects nothing.
  void escape() {
    if (_anchors.tapArmed) {
      _anchors.tapArmed = false;
      _editor.playback.pause();
    } else if (_open && _lanes.selected.isEmpty && _lanes.tool != LaneTool.select) {
      _lanes.tool = LaneTool.select;
    } else {
      _editor.clearSelection();
    }
  }

  /// V, D, E: the lanes' tool (the instruments', and the recordings' in the Audio tab).
  void tool(LaneTool tool) {
    if (_open) _lanes.tool = tool;
  }

  /// [ / ]: the selected regions start (end) at the playhead's beat.
  void trim({required bool start}) {
    if (_curating) _lanes.trimToPlayhead(start: start);
  }
}
