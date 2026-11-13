import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'app_colors.dart';
import 'app_settings.dart';
import 'key_bindings.dart';
import 'l10n/l10n.dart';
import 'motion_settings.dart' show ResetSlot;
import 'ui_kit.dart';

/// Settings ▸ Shortcuts: a command's keys, at the right of its row. One the user can change
/// ([KeyCommand.editable]) is a field: clicked (or Return or Space on it), the next keys typed are
/// its own (Esc leaves it as it was, ⌫ takes its key away), unless another command where it works
/// has them or a menu can't take them, which it says; Reset gives it its own again. The rest are
/// keycaps ([KeyCaps]).
class ShortcutKeys extends StatelessWidget {
  const ShortcutKeys({super.key, required this.command, required this.settings});
  final KeyCommand command;
  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final keys = settings.keys;
    if (!command.editable) return KeyCaps(keys.labelsOf(command));
    return Row(mainAxisSize: MainAxisSize.min, children: [
      ResetSlot(
        changed: keys.isChanged(command),
        color: context.colors.textMuted,
        onReset: () => settings.keys = settings.keys.reset(command),
      ),
      const SizedBox(width: 4),
      _KeyField(command: command, keys: keys, onChanged: (key) => settings.keys = settings.keys.withKey(command, key)),
    ]);
  }
}

/// Keys as keycaps, side by side: what a command takes that can't be changed.
class KeyCaps extends StatelessWidget {
  const KeyCaps(this.labels, {super.key});
  final List<String> labels;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    // On a Settings group: Carbon's $border-subtle as it is there.
    final edge = CarbonColors.maybeOf(context)?.borderSubtle ?? colors.line;
    return Row(mainAxisSize: MainAxisSize.min, spacing: 4, children: [
      for (final label in labels)
        Container(
          constraints: const BoxConstraints(minWidth: 26),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(border: Border.all(color: edge), borderRadius: AppStyle.of(context).radius(4)),
          child: Text(label, textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: colors.textMuted)),
        ),
    ]);
  }
}

class _KeyField extends StatefulWidget {
  const _KeyField({required this.command, required this.keys, required this.onChanged});
  final KeyCommand command;
  final KeyMap keys;

  /// A key typed for it (null: ⌫, none).
  final ValueChanged<KeyChord?> onChanged;

  @override
  State<_KeyField> createState() => _KeyFieldState();
}

class _KeyFieldState extends State<_KeyField> {
  final _focus = FocusNode(debugLabel: 'Shortcut');

  /// The field moved, not built again, as its hover text comes and goes: it keeps the keyboard.
  final _fieldKey = GlobalKey();

  /// Whether the next keys typed are its own.
  bool _recording = false;
  bool _hovered = false;

  /// While recording: the modifiers held ("⇧⌘"), or why the keys typed last aren't taken.
  String? _held, _problem;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_focusChanged);
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _focusChanged() {
    if (!_focus.hasFocus) _recording = false;
    setState(() {});
  }

  void _start() {
    _focus.requestFocus();
    setState(() {
      _recording = true;
      _held = _problem = null;
    });
  }

  void _stop() => setState(() {
        _recording = false;
        _held = _problem = null;
      });

  KeyEventResult _key(FocusNode _, KeyEvent event) {
    final key = event.logicalKey;
    if (!_recording) {
      if (event is KeyDownEvent &&
          (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter || key == LogicalKeyboardKey.space)) {
        _start();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    // Every key is the field's while it records: none reaches the window (Esc would close it).
    final keyboard = HardwareKeyboard.instance;
    final chord = KeyChord.of(event, keyboard);
    if (chord == null || event is KeyUpEvent) {
      setState(() => _held = _heldNow(keyboard)); // a modifier held or let go
      return KeyEventResult.handled;
    }
    if (event is KeyRepeatEvent) return KeyEventResult.handled;
    final bare = !chord.commanded && !chord.alt;
    if (bare && !chord.shift && key == LogicalKeyboardKey.escape) {
      _stop();
      return KeyEventResult.handled;
    }
    if (bare && key == LogicalKeyboardKey.tab) {
      _stop();
      return KeyEventResult.ignored; // the keyboard moves on
    }
    if (bare && !chord.shift && (key == LogicalKeyboardKey.backspace || key == LogicalKeyboardKey.delete)) {
      widget.onChanged(null);
      _stop();
      return KeyEventResult.handled;
    }
    final problem = widget.command.refuses(chord) ??
        switch (widget.keys.takenBy(widget.command, chord)) {
          final other? => 'Used by {command}'.fill({'command': other.label.tr}),
          null => null,
        };
    if (problem != null) {
      setState(() {
        _problem = problem;
        _held = null;
      });
      return KeyEventResult.handled;
    }
    widget.onChanged(chord);
    _stop();
    return KeyEventResult.handled;
  }

  /// The modifiers held now, as a chord starts: "⇧⌘" on macOS, "Ctrl+Shift+" elsewhere.
  static String? _heldNow(HardwareKeyboard keys) {
    final held = defaultTargetPlatform == TargetPlatform.macOS
        ? '${keys.isControlPressed ? '⌃' : ''}${keys.isAltPressed ? '⌥' : ''}${keys.isShiftPressed ? '⇧' : ''}${keys.isMetaPressed ? '⌘' : ''}'
        : [if (keys.isControlPressed) 'Ctrl+', if (keys.isAltPressed) 'Alt+', if (keys.isShiftPressed) 'Shift+'].join();
    return held.isEmpty ? null : held;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final error = CarbonColors.maybeOf(context)?.error ?? colors.erase;
    final key = widget.keys[widget.command];
    // A key saved for it that another command has since been given (a newer version's own).
    final taken = key == null ? null : widget.keys.takenBy(widget.command, key);
    final (text, color) = _recording
        ? switch ((_held, _problem)) {
            (final held?, _) => (held, colors.text),
            (null, final problem?) => (problem, error),
            _ => ('Type Shortcut'.tr, colors.textMuted),
          }
        : key == null
            ? ('None'.tr, colors.textMuted)
            : (key.label, taken == null ? colors.text : error);
    final borders = fieldBorders(context, bad: _recording ? _problem != null && _held == null : taken != null);
    final fill = fieldFill(context);
    final field = TapRegion(
      key: _fieldKey,
      // A click anywhere else ends it, as it is.
      onTapOutside: _recording ? (_) => _focus.unfocus() : null,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _recording ? null : _start,
          child: Focus(
            focusNode: _focus,
            onKeyEvent: _key,
            child: SizedBox(
              width: 160,
              child: InputDecorator(
                isFocused: _recording || _focus.hasFocus,
                isHovering: _hovered,
                decoration: InputDecoration(
                  isDense: true,
                  filled: fill != null,
                  fillColor: fill,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  border: borders.rest,
                  enabledBorder: borders.rest,
                  focusedBorder: borders.focused,
                ),
                child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: color)),
              ),
            ),
          ),
        ),
      ),
    );
    final hint = _recording ? _problem : taken == null ? null : 'Used by {command}'.fill({'command': taken.label.tr});
    return Semantics(
      button: true,
      label: widget.command.label.tr,
      value: text,
      onTap: _recording ? null : _start,
      excludeSemantics: true,
      child: hint == null ? field : Tip(message: hint, child: field),
    );
  }
}
