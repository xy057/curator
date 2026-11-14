part of '../editor_controller.dart';

/// How the captions under the score look. What they say is an extension's (its `captions`
/// socket: [ExtensionEditing.captions]); the bar they show in is the scene's, drawn in the
/// font the project chooses for it and as the extension's `captions.style` asks.
class CaptionLook {
  CaptionLook._(this._editor);
  final EditorController _editor;

  /// Whether an extension that is on gives captions: no caption is drawn, and nothing here
  /// works, while none does.
  bool get enabled => _editor.extensions.hasCaptions;

  /// The font captions are drawn in, chosen for this project (Project Settings ▸ Engraving): a text font
  /// family; null: the extension's ([defaultFont]). An edit.
  String? get font => _font;
  String? _font;

  void setFont(String? name) {
    if (!enabled || _editor._score == null || name == _font) return;
    _font = name;
    _applyStyle();
    _editor._edited();
  }

  /// What the extension asks for (its `captions.style`): the font when a project chooses none
  /// (a family, or '' for the score's text font), the countdown, the size, the side and the
  /// backing.
  CaptionAsk _asked = const (font: '', countdown: CaptionCountdown.line, size: CaptionSize.medium, align: CaptionAlign.center, plate: false);

  String get defaultFont => _asked.font;

  /// Asks the extension again how its captions look: it was turned on or off, or its settings
  /// changed.
  void _follow() {
    final asked = captionAskOf(_editor.extensions._runtimes.values);
    if (asked == _asked) return;
    _asked = asked;
    _applyStyle();
  }

  /// The font in effect ('' : the score's text font).
  String get effectiveFont => _font ?? defaultFont;

  /// False while [effectiveFont] isn't installed here: the score's text font stands in.
  bool get fontFound => _fontFound;
  bool _fontFound = true;

  /// As the scene draws them.
  CaptionStyle get style => _style;
  CaptionStyle _style = const CaptionStyle();
  final _styles = Latest();

  /// Works out [style] (an installed family is read and registered first) and gives it to the
  /// scene. The latest call wins. Never throws (it isn't awaited): a family that can't be read
  /// is drawn as one not installed.
  Future<void> _applyStyle() async {
    final turn = _styles.start(), name = effectiveFont, asked = _asked;
    // At once when there is nothing to read: the score's own font, or Academico.
    final reading = captionFamily(name);
    final (:family, :found) = reading is Future ? await reading : reading;
    if (!turn.isLatest || _editor._disposed) return;
    _fontFound = found;
    _style = CaptionStyle(fontFamily: family, countdown: asked.countdown, size: asked.size, align: asked.align, plate: asked.plate);
    _editor._showSettings();
    _editor.playback._markDirty(); // the preview repaints only when asked
    _editor._changed();
  }

  void _load(String? font) {
    _font = font;
    _asked = captionAskOf(_editor.extensions._runtimes.values);
    _editor._showSettings();
    _applyStyle();
  }

  /// After Undo / Redo.
  void _restore(String? font) {
    if (font != _font) {
      _font = font;
      _applyStyle();
    }
  }

  void _reset() => _font = null;
}
