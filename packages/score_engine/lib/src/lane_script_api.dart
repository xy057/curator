/// The script language as a list: every statement with what it does, and its words. The one
/// place it is written down: the editor's Help and what it offers as a script is typed are made
/// from it, and so is docs/lane-script.md (app/tool/script_docs.dart). Plain Dart, with nothing
/// of Flutter's, so a tool reads it.
library;

/// A statement of the language, for the docs and what the editor offers.
class ScriptStatement {
  const ScriptStatement(this.word, this.syntax, this.summary, this.example);

  /// What it starts with.
  final String word;
  final String syntax, summary, example;
}

abstract final class LaneScriptApi {
  /// The words of the language: none is a group's name.
  static const keywords = {
    'show', 'hide', 'only', 'clear', 'auto', 'bridge', 'rests', 'remove', 'short', 'in', 'copy', 'to', 'split', 'join', 'move', 'top', 'bottom', //
    'before', 'after', 'restore', 'order', 'transition', 'out', 'default', 'without', 'staff', 'staves', 'let', 'all', 'except', 'bar', 'bars', //
    'from', 'until', 'start', 'end', 'mark',
  };

  static const statements = <ScriptStatement>[
    ScriptStatement('show', 'show <lanes> [<ranges>] [transition …] [without staff <n>]',
        'Shows the lanes over the ranges, as Draw does: joined with what it touches. Without a range, throughout. '
            '`transition 0.5` gives the stretch its own transition at both ends, `transition in 0.5 out 1` at each; '
            '`without staff 2` leaves a staff of the instrument out there.',
        'show "Flute 1", "Oboe 1" 1-8, 17-24'),
    ScriptStatement('hide', 'hide <lanes> [<ranges>]', 'Hides the lanes over the ranges, as Erase does: regions there are trimmed, split or removed.', 'hide "Violin II" from 33'),
    ScriptStatement('only', 'only <lanes> [<ranges>]', 'Shows the lanes over the ranges and hides every other lane there.', 'only "Piano" 9-16'),
    ScriptStatement('clear', 'clear [<lanes>]', 'Empties the lanes; without any, every lane.', 'clear'),
    ScriptStatement('auto', 'auto [<lanes>]', 'Auto-Curate: fills the lanes (every lane without any) from where each instrument plays, cut back to fit the frame.', 'auto "Violin*"'),
    ScriptStatement('bridge', 'bridge rests <bars> [in <lanes>]', 'Tidy’s Bridge Rests: joins regions with at most that many bars between them.', 'bridge rests 2'),
    ScriptStatement('remove', 'remove short <bars> [in <lanes>]', 'Tidy’s Remove Regions Shorter Than: takes out regions shorter than that many bars.', 'remove short 1 in "Timpani"'),
    ScriptStatement('copy', 'copy <lane> to <lanes>', 'Copy Lane To: the lanes get that lane’s regions in place of their own.', 'copy "Violin I" to "Violin II", "Viola"'),
    ScriptStatement('split', 'split <lanes>', 'Split Lane: an instrument on several staves gets a lane a staff, named "Piano"/1, "Piano"/2.', 'split "Piano"'),
    ScriptStatement('join', 'join <lanes>', 'Join Lanes: a split instrument has one lane again.', 'join "Piano"'),
    ScriptStatement('move', 'move <lanes> to top | to bottom | before <lane> | after <lane>', 'Moves the lanes, and their staves in the score, together.', 'move "Harp" before "Violin I"'),
    ScriptStatement('restore', 'restore order', 'Restore Score Order: the lanes as the score has them.', 'restore order'),
    ScriptStatement('transition', 'transition <seconds>', 'The project’s transition: how long a staff takes to come and go.', 'transition 0.3'),
    ScriptStatement('transition', 'transition <lanes> [<ranges>] [in <seconds>] [out <seconds>]',
        'The regions’ own transitions, at every start (`in`) and end (`out`) inside the ranges; `default` for seconds gives the project’s back.', 'transition "Flute 1" 9-16 in 1 out default'),
    ScriptStatement('let', 'let <name> = <lanes>', 'Names lanes, for the statements after it.', 'let strings = "Violin*", "Viola", "Cello"'),
  ];

  /// The statements as the docs list them, in Markdown.
  static String reference() {
    final out = StringBuffer('## Statements\n');
    for (final s in statements) {
      out.writeln('\n- `${s.syntax}`: ${s.summary}\n\n```\n${s.example}\n```');
    }
    return out.toString();
  }

  /// The docs whole, as Markdown: the [guide] to writing a script, then the [reference].
  static String docs(String guide) => '${guide.trimRight()}\n\n${reference()}';
}
