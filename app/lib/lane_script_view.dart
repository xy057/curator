import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:re_editor/re_editor.dart';
import 'package:score_engine/score_engine.dart' show LaneScript, LaneScriptApi, LaneScriptProblem;

import 'app_colors.dart';
import 'app_icons.dart';
import 'code_view.dart';
import 'editor_controller.dart';
import 'l10n/l10n.dart';
import 'lilypond_language.dart' show lilyPondTheme;
import 'markdown_text.dart';
import 'ui_kit.dart';

/// The guide to writing a script, which Help shows before the statements ([LaneScriptApi.docs]).
const laneScriptGuideAsset = 'assets/help/script.md';

/// The Instruments tab's Script: the lanes written instead of drawn (see *The lanes can be
/// written*). The project's script ([LaneEditing.script]) in a [CodeView], coloured a line at a
/// time and what can be typed offered as it is; Run (⌘R) does it as one Undo step
/// ([LaneEditing.runScript]); what is wrong with it is listed under it as it is typed
/// ([LaneEditing.checkScript]), a click going to its line; From Lanes writes the lanes as they
/// are ([LaneEditing.asScript]); Help shows the guide beside it.
class LaneScriptView extends StatefulWidget {
  const LaneScriptView({super.key, required this.controller});
  final EditorController controller;

  @override
  State<LaneScriptView> createState() => _LaneScriptViewState();
}

class _LaneScriptViewState extends State<LaneScriptView> {
  late final CodeLineEditingController _code = laneScriptCode(_mine);

  /// The script as this last gave it to the project (or took it): another there is the
  /// project's own, changed under it.
  late String _mine = widget.controller.lanes.script;
  late final _find = CodeFindController(_code);
  final _focus = FocusNode(debugLabel: 'Script');

  /// What the check finds wrong with the script as it is typed: Run waits for none.
  List<LaneScriptProblem> _problems = const [];

  /// What the last Run found wrong, listed in the check's place until the script is typed in
  /// again: what only running finds (an Align under way, a recording the score isn't heard in)
  /// is no reason not to run it again.
  List<LaneScriptProblem>? _found;

  /// What the last Run came to, until the script is typed in again.
  String? _said;
  bool _help = false, _running = false;
  Timer? _checking;

  EditorController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _problems = _c.lanes.checkScript(_code.text);
    _code.addListener(_typed);
    _c.addListener(_projectChanged);
  }

  @override
  void dispose() {
    _checking?.cancel();
    _c.removeListener(_projectChanged);
    _code.removeListener(_typed);
    _find.dispose();
    _code.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Checked a moment after the last key: what is wrong is said once the line is written.
  void _typed() {
    final text = _code.text;
    if (text == _mine) return; // the caret moved
    _c.lanes.script = _mine = text;
    if (_said != null || _found != null) setState(() => _said = _found = null);
    _checking?.cancel();
    _checking = Timer(const Duration(milliseconds: 350), () {
      if (mounted) setState(() => _problems = _c.lanes.checkScript(_code.text));
    });
  }

  /// Another project's script (a score replaced, a project opened here): checked as it comes.
  void _projectChanged() {
    if (identical(_c.lanes.script, _mine)) return;
    _code.text = _mine = _c.lanes.script;
    _checking?.cancel();
    setState(() {
      _said = _found = null;
      _problems = _c.lanes.checkScript(_code.text);
    });
  }

  /// (A script that hears the recording waits for it, with Align's progress in the Audio tab:
  /// where this is left for that by the time it ends, what went wrong is said in the window.)
  Future<void> _run() async {
    if (_running) return;
    _checking?.cancel();
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _running = true);
    try {
      final (:problems, :changed) = await _c.lanes.runScriptReady(_code.text);
      if (!mounted) {
        if (problems.firstOrNull case final problem?) {
          messenger
            ?..clearSnackBars()
            ..showSnackBar(SnackBar(content: Text('${'Script'.tr}: ${problem.message}')));
        }
        return;
      }
      setState(() {
        _found = problems.isEmpty ? null : problems;
        _problems = _c.lanes.checkScript(_code.text);
        _said = problems.isNotEmpty ? null : (changed ? 'Done'.tr : 'Nothing changed'.tr);
      });
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  /// The lanes as they are in the script's place, as one step of the code's own Undo.
  void _fromLanes() {
    _code
      ..selectAll()
      ..replaceSelection(_c.lanes.asScript);
    _focus.requestFocus();
  }

  void _goTo(int line) {
    final index = (line - 1).clamp(0, _code.lineCount - 1);
    _code.selection = CodeLineSelection.collapsed(index: index, offset: _code.codeLines[index].length);
    _code.makeCursorVisible();
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyR, meta: true): _run,
        const SingleActivator(LogicalKeyboardKey.keyR, control: true): _run,
      },
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _bar(context),
        Divider(height: 1, color: colors.line),
        Expanded(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Expanded(
                  child: TypingArea(
                    child: CodeView(
                      controller: _code,
                      findController: _find,
                      focusNode: _focus,
                      prompts: LaneScriptPrompts(() => _c.lanes.scriptNames),
                      kindOf: (prompt) => prompt is LaneScriptPrompt && prompt.lane ? 'Lane'.tr : null,
                    ),
                  ),
                ),
                if (_found ?? _problems case final listed when listed.isNotEmpty) ...[
                  Divider(height: 1, color: colors.line),
                  CodeProblemList(problems: [
                    for (final p in listed) (text: '${p.line}: ${p.message}', error: true, onTap: () => _goTo(p.line)),
                  ]),
                ],
              ]),
            ),
            if (_help) ...[
              VerticalDivider(width: 1, color: colors.line),
              const SizedBox(width: 380, child: _Guide()),
            ],
          ]),
        ),
      ]),
    );
  }

  Widget _bar(BuildContext context) {
    final colors = context.colors;
    final compact = ButtonStyle(
      visualDensity: VisualDensity.compact,
      minimumSize: const WidgetStatePropertyAll(Size(0, 26)),
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)),
      textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: 12.5)),
    );
    return Container(
      height: 36,
      color: colors.chrome,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(children: [
        Tip(
          message: 'Run ({key})'.fill({'key': shortcut('⌘R')}),
          child: FilledButton(style: compact, onPressed: _problems.isEmpty && _code.text.trim().isNotEmpty && !_running ? _run : null, child: Text('Run'.tr)),
        ),
        const SizedBox(width: 8),
        Tip(
          message: 'Write the lanes as a script'.tr,
          child: OutlinedButton(style: compact, onPressed: _fromLanes, child: Text('From Lanes'.tr)),
        ),
        const SizedBox(width: 12),
        Expanded(child: FadingText(_said ?? '', style: TextStyle(fontSize: 12, color: colors.textMuted))),
        ToolbarButton(
            icon: AppIcon.search.of(context),
            tooltip: 'Find ({key})'.fill({'key': shortcut('⌘F')}),
            onPressed: () => _find
              ..findMode()
              ..focusOnFindInput()),
        ToolbarButton(icon: AppIcon.website.of(context), tooltip: 'Help'.tr, selected: _help, onPressed: () => setState(() => _help = !_help)),
      ]),
    );
  }
}

/// The guide to writing a script, then its statements.
class _Guide extends StatefulWidget {
  const _Guide();

  @override
  State<_Guide> createState() => _GuideState();
}

class _GuideState extends State<_Guide> {
  static String? _text;
  late final Future<String> _loading =
      _text != null ? Future.value(_text) : rootBundle.loadString(laneScriptGuideAsset).then((guide) => _text = LaneScriptApi.docs(guide));

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: context.colors.chrome,
        child: FutureBuilder(
          future: _loading,
          builder: (context, guide) => guide.data == null
              ? const SizedBox.shrink()
              : SingleChildScrollView(padding: const EdgeInsets.fromLTRB(16, 14, 16, 24), child: MarkdownText(guide.data!, flow: true)),
        ),
      );
}

final _themes = <Brightness, Map<String, TextStyle>>{};

/// A script's text, [text] to begin with: a controller whose lines are coloured as they are
/// drawn ([LaneScript.tokens]: nothing runs over a line), in the code editors' colours.
CodeLineEditingController laneScriptCode(String text) => CodeLineEditingController(
      codeLines: CodeLines.fromText(text),
      options: const CodeLineOptions(indentSize: 2),
      spanBuilder: ({required context, required index, required codeLine, required textSpan, required style}) {
        final brightness = Theme.of(context).brightness;
        final theme = _themes[brightness] ??= lilyPondTheme(brightness);
        return TextSpan(style: style, children: [
          for (final (scope, text) in LaneScript.tokens(codeLine.text)) TextSpan(text: text, style: scope == null ? null : theme[scope]),
        ]);
      },
    );

/// A word offered as a script is typed; [lane]: a lane's name, closed with its quote.
class LaneScriptPrompt extends CodePrompt {
  const LaneScriptPrompt(String word, {this.lane = false}) : super(word: word);
  final bool lane;

  @override
  CodeAutocompleteResult get autocomplete => CodeAutocompleteResult.fromWord(word);

  @override
  bool match(String input) => word != input && word.toLowerCase().startsWith(input.toLowerCase());

  @override
  bool operator ==(Object other) => other is LaneScriptPrompt && other.word == word && other.lane == lane;

  @override
  int get hashCode => Object.hash(word, lane);
}

/// What to offer where the caret is in a script: inside a name's quotes the lanes' names
/// ([names], as they are now); a line's first word, what a statement starts with; elsewhere,
/// once two letters are typed, the language's words. Nothing in a comment.
class LaneScriptPrompts implements CodeAutocompletePromptsBuilder {
  LaneScriptPrompts(this.names);
  final List<String> Function() names;

  static const limit = 40;

  @override
  CodeAutocompleteEditingValue? build(BuildContext context, CodeLine codeLine, CodeLineSelection selection) =>
      promptsFor(codeLine.text.substring(0, selection.extentOffset.clamp(0, codeLine.text.length)));

  CodeAutocompleteEditingValue? promptsFor(String before) {
    final runs = LaneScript.tokens(before);
    if (runs.isEmpty || runs.last.$1 == 'comment') return null;
    CodeAutocompleteEditingValue? offer(String input, Iterable<LaneScriptPrompt> all) {
      final prompts = [for (final p in all) if (input.isEmpty || p.match(input)) p].take(limit).toList();
      return prompts.isEmpty ? null : CodeAutocompleteEditingValue(input: input, prompts: prompts, index: 0);
    }

    final (scope, last) = runs.last;
    // A name being written: its quote is open.
    if (scope == 'string' && (last.length == 1 || !last.endsWith('"') || last.endsWith(r'\"'))) {
      return offer(last.substring(1), [for (final name in names()) LaneScriptPrompt('${LaneScript.quoted(name).substring(1)} ', lane: true)]);
    }
    if (scope != null && scope != 'keyword') return null;
    if (!RegExp(r'^[A-Za-z]+$').hasMatch(last)) return null;
    final first = runs.length == 1 || (runs.length == 2 && runs.first.$2.trim().isEmpty);
    if (first) return offer(last, {for (final s in LaneScript.statements) s.word}.map(LaneScriptPrompt.new));
    return last.length < 2 ? null : offer(last, [for (final word in LaneScript.keywords) LaneScriptPrompt(word)]);
  }
}
