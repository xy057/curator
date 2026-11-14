import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:re_editor/re_editor.dart';

import 'app_colors.dart';
import 'app_icons.dart';
import 'l10n/l10n.dart';
import 'lilypond_dialog.dart' show monospace;
import 'ui_kit.dart';

/// What the code editors share (the LilyPond editor's, the score editor's MusicXML): code in
/// re_editor ([CodeView]), coloured a line at a time by its controller, what can be typed offered
/// as it is, Find and Replace over it, and what is wrong with it listed under it
/// ([CodeProblemList]).
///
/// Not re_highlight, re_editor's own highlighting: it colours the whole text again on every
/// change, in a time that grows as the square of the text.

/// Code being edited: monospace, numbered lines, what [folds] finds folded (default: brackets'
/// insides), each line coloured as the [controller] says (its span builder: `lilyPondCode`,
/// `musicXmlCode`); what [prompts] offers where the caret is shown under it as it is typed (with
/// what [kindOf] says each is beside it); Find (⌘F) and Replace (⌥⌘F) at its top right.
class CodeView extends StatelessWidget {
  const CodeView({
    super.key,
    required this.controller,
    required this.findController,
    required this.focusNode,
    required this.prompts,
    this.kindOf,
    this.folds,
    this.readOnly = false,
  });

  /// Whether the code is only read (one of Curator's own extensions).
  final bool readOnly;

  final CodeLineEditingController controller;
  final CodeFindController findController;
  final FocusNode focusNode;
  final CodeChunkAnalyzer? folds;
  final CodeAutocompletePromptsBuilder prompts;
  final String? Function(CodePrompt prompt)? kindOf;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final gutter = TextStyle(fontSize: 12, color: colors.textMuted.withValues(alpha: 0.7), fontFamily: monospace.fontFamily,
        fontFamilyFallback: monospace.fontFamilyFallback);
    return CodeAutocomplete(
      viewBuilder: (context, notifier, onSelected) => CodePromptList(notifier: notifier, onSelected: onSelected, kindOf: kindOf),
      promptsBuilder: prompts,
      child: CodeEditor(
        controller: controller,
        findController: findController,
        focusNode: focusNode,
        readOnly: readOnly,
        chunkAnalyzer: folds,
        wordWrap: false,
        padding: const EdgeInsets.fromLTRB(4, 8, 12, 8),
        style: CodeEditorStyle(
          fontSize: 13,
          fontFamily: monospace.fontFamily,
          fontFamilyFallback: monospace.fontFamilyFallback,
          fontHeight: 1.45,
          textColor: colors.text,
          backgroundColor: colors.surface,
          selectionColor: colors.accent.withValues(alpha: 0.25),
          highlightColor: colors.accent.withValues(alpha: 0.3),
          cursorColor: colors.accent,
          cursorLineColor: colors.accentWash.withValues(alpha: 0.5),
        ),
        indicatorBuilder: (context, editing, chunks, notifier) => Row(children: [
          DefaultCodeLineNumber(controller: editing, notifier: notifier, textStyle: gutter, focusedTextStyle: gutter.copyWith(color: colors.text)),
          DefaultCodeChunkIndicator(width: 18, controller: chunks, notifier: notifier),
        ]),
        findBuilder: (context, controller, readOnly) => CodeFindBar(controller: controller, readOnly: readOnly),
      ),
    );
  }
}

/// What can be typed where the caret is, the chosen one marked, with what [kindOf] says each is
/// beside it: ↑ and ↓ choose, Return or a click puts it in.
class CodePromptList extends StatefulWidget implements PreferredSizeWidget {
  const CodePromptList({super.key, required this.notifier, required this.onSelected, this.kindOf});
  final ValueNotifier<CodeAutocompleteEditingValue> notifier;
  final ValueChanged<CodeAutocompleteResult> onSelected;
  final String? Function(CodePrompt prompt)? kindOf;

  static const _row = 24.0, _rows = 8;

  @override
  /// Its rows, the list's padding (4 above and below) and its border's (1).
  Size get preferredSize => Size(300, math.min(notifier.value.prompts.length, _rows) * _row + 10);

  @override
  State<CodePromptList> createState() => _CodePromptListState();
}

class _CodePromptListState extends State<CodePromptList> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.notifier.addListener(_moved);
  }

  @override
  void dispose() {
    widget.notifier.removeListener(_moved);
    _scroll.dispose();
    super.dispose();
  }

  void _moved() {
    if (!mounted) return;
    setState(() {});
    if (!_scroll.hasClients) return;
    final top = widget.notifier.value.index * CodePromptList._row, view = _scroll.position.viewportDimension;
    if (top < _scroll.offset) {
      _scroll.jumpTo(top);
    } else if (top + CodePromptList._row > _scroll.offset + view) {
      _scroll.jumpTo(top + CodePromptList._row - view);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors, value = widget.notifier.value, dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: widget.preferredSize.width,
      height: widget.preferredSize.height,
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.line),
        borderRadius: AppStyle.of(context).radius(6),
        boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 12, offset: Offset(0, 4))],
      ),
      child: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.all(4),
        itemExtent: CodePromptList._row,
        itemCount: value.prompts.length,
        itemBuilder: (context, i) {
          final prompt = value.prompts[i], chosen = i == value.index;
          final kind = widget.kindOf?.call(prompt);
          // The chosen one in the accent's light tint, as a sidebar's chosen row.
          final ink = chosen ? colors.accentOn(colors.accentSoft, dark: dark) : colors.text;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => widget.onSelected(value.copyWith(index: i).autocomplete),
            child: Container(
              decoration: BoxDecoration(color: chosen ? colors.accentSoft : null, borderRadius: BorderRadius.circular(4)),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(children: [
                Expanded(child: Text(prompt.word, overflow: TextOverflow.ellipsis, style: monospace.copyWith(fontSize: 13, color: ink))),
                if (kind != null)
                  Text(kind, style: TextStyle(fontSize: 11.5, color: chosen ? ink.withValues(alpha: 0.75) : colors.textMuted)),
              ]),
            ),
          );
        },
      ),
    );
  }
}

/// Find (⌘F), and Replace (⌥⌘F): over the code at its top right; Return finds the next, Esc
/// closes it.
class CodeFindBar extends StatelessWidget implements PreferredSizeWidget {
  const CodeFindBar({super.key, required this.controller, required this.readOnly});
  final CodeFindController controller;
  final bool readOnly;

  static const _row = 38.0;

  @override
  Size get preferredSize => Size(double.infinity, switch (controller.value) {
        null => 0,
        final v when v.replaceMode && !readOnly => _row * 2,
        _ => _row,
      });

  @override
  Widget build(BuildContext context) {
    final value = controller.value;
    if (value == null) return const SizedBox.shrink();
    final colors = context.colors;
    final result = value.result;
    final count = value.option.pattern.isEmpty
        ? ''
        : result == null || result.matches.isEmpty
            ? 'No matches'.tr
            : '{n} of {all}'.fill({'n': result.index + 1, 'all': result.matches.length});
    // Return the next match (or, replacing, replaces it), ⇧Return the one before; Esc closes.
    Widget field(TextEditingController text, FocusNode focus, String hint, VoidCallback onSubmitted, {VoidCallback? back}) => SizedBox(
          width: 240,
          height: 28,
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): controller.close,
              if (back != null) ...{
                const SingleActivator(LogicalKeyboardKey.enter, shift: true): back,
                const SingleActivator(LogicalKeyboardKey.numpadEnter, shift: true): back,
              },
            },
            child: TextField(
              controller: text,
              focusNode: focus,
              style: monospace.copyWith(fontSize: 13, color: colors.text),
              onSubmitted: (_) => onSubmitted(),
              decoration: InputDecoration(
                isDense: true,
                hintText: hint,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                border: OutlineInputBorder(borderRadius: AppStyle.of(context).radius(4)),
              ),
            ),
          ),
        );
    return Container(
      height: preferredSize.height,
      decoration: BoxDecoration(color: colors.chrome, border: Border(bottom: BorderSide(color: colors.line))),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(children: [
        SizedBox(
          height: _row,
          child: Row(children: [
            field(controller.findInputController, controller.findInputFocusNode, 'Find'.tr, () {
              controller.nextMatch();
              controller.findInputFocusNode.requestFocus();
            }, back: controller.previousMatch),
            const SizedBox(width: 8),
            Text(count, style: TextStyle(fontSize: 12, color: colors.textMuted)),
            const Spacer(),
            ToolbarButton(
                icon: AppIcon.previous.of(context),
                tooltip: 'Previous ({key})'.fill({'key': shortcut('⇧↩', 'Shift+Enter')}),
                onPressed: result == null ? null : controller.previousMatch),
            ToolbarButton(
                icon: AppIcon.next.of(context),
                tooltip: 'Next ({key})'.fill({'key': shortcut('↩', 'Enter')}),
                onPressed: result == null ? null : controller.nextMatch),
            if (!readOnly) ToolbarButton(icon: AppIcon.more.of(context), tooltip: 'Replace'.tr, onPressed: controller.toggleMode),
            ToolbarButton(icon: AppIcon.close.of(context), tooltip: 'Close'.tr, onPressed: controller.close),
          ]),
        ),
        if (value.replaceMode && !readOnly)
          SizedBox(
            height: _row,
            child: Row(children: [
              field(controller.replaceInputController, controller.replaceInputFocusNode, 'Replace'.tr, controller.replaceMatch),
              const SizedBox(width: 8),
              TextButton(onPressed: result == null ? null : controller.replaceMatch, child: Text('Replace'.tr)),
              TextButton(onPressed: result == null ? null : controller.replaceAllMatches, child: Text('Replace All'.tr)),
            ]),
          ),
      ]),
    );
  }
}

/// Something wrong with the code: its [text], whether it is an [error] (else a warning), and
/// where it is, gone to by a click ([onTap]; null: it has no place).
typedef CodeProblem = ({String text, bool error, VoidCallback? onTap});

/// What is wrong with the code, a row each under it (five shown, the rest scrolled to): an
/// error's icon or a warning's, and what it says.
class CodeProblemList extends StatelessWidget {
  const CodeProblemList({super.key, required this.problems});
  final List<CodeProblem> problems;

  static const _row = 26.0;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      height: math.min(problems.length, 5) * _row + 8,
      color: colors.chrome,
      child: ListView(padding: const EdgeInsets.symmetric(vertical: 4), itemExtent: _row, children: [
        for (final p in problems)
          InkWell(
            onTap: p.onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(children: [
                Icon((p.error ? AppIcon.failed : AppIcon.warning).of(context),
                    size: 15, color: p.error ? Theme.of(context).colorScheme.error : const Color(0xFFD08A1E)),
                const SizedBox(width: 8),
                Expanded(child: Text(p.text, overflow: TextOverflow.ellipsis, style: monospace.copyWith(fontSize: 12.5, color: colors.text))),
              ]),
            ),
          ),
      ]),
    );
  }
}
