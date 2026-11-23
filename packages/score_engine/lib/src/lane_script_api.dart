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
    'from', 'until', 'start', 'end', 'mark', 'follow', 'fit', 'phrase', 'thin', 'refill', 'lone', 'hear', 'match', 'snap', 'anchors', 'within', 'align',
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
    ScriptStatement('auto', 'auto [<lanes>]', 'Auto-Curate: fills the lanes (every lane without any) from where each instrument plays, cut back to fit the frame (`follow`, then `fit`).', 'auto "Violin*"'),
    ScriptStatement('follow', 'follow [<lanes>] [<ranges>] [bridge <bars>]',
        'Auto-Curate’s first half: each lane (every lane without any) is shown where its instrument plays and hidden where it rests, over the ranges '
            '(without one, throughout). `bridge 1` keeps it through a rest of up to that many bars between two runs. A lane that plays nothing stays as it is.',
        'follow "Violin*" bridge 1'),
    ScriptStatement('fit', 'fit [<lanes>] [phrase <bars>]',
        'Auto-Curate’s second half: hides of the lanes (every lane without any) what the frame has no room for; the other lanes stay as they are. '
            'It is `thin`, `refill` and `remove lone`, one after another. `follow all bridge 1` and then `fit` is what `auto` does.',
        'fit'),
    ScriptStatement('thin', 'thin [<lanes>] [phrase <bars>]',
        'The first step of `fit`: where the staves would run off the frame, hides the lane that matters least there, a phrase (4 bars, or as given) at a time, '
            'until they fit. What it hides is remembered until the script ends, for `refill` and `remove lone`.',
        'thin phrase 8'),
    ScriptStatement('refill', 'refill [<lanes>]',
        'The second step of `fit`: shows again what `thin` hid wherever the frame holds it now, what matters most first, a phrase and else a bar at a time. '
            'Nothing where the staves still run off.',
        'refill'),
    ScriptStatement('remove', 'remove lone [in <lanes>]',
        'The third step of `fit`: a lane left showing for a single bar, next to bars `thin` hid of it, is hidden there too.', 'remove lone'),
    ScriptStatement('align', 'align',
        'The Audio tab’s Align: sets the anchors from the recording, heard against the score, in place of those there. '
            'It is `hear`, `match` and, where the Audio tab’s Snap to Notes is on, `snap anchors`.',
        'align'),
    ScriptStatement('hear', 'hear',
        'The first step of `align`: listens to the recording for the notes in it. It takes a while and changes nothing; what is heard is kept until the script ends, for `match`.',
        'hear'),
    ScriptStatement('match', 'match',
        'The second step of `align`: finds the score in what `hear` heard (through its repeats: the warps set by hand, or with none the score’s own) '
            'and sets the anchors from it, in place of those there.',
        'match'),
    ScriptStatement('snap', 'snap anchors [within <seconds>]',
        'The third step of `align`: moves each anchor onto the nearest note heard starting, within 0.05 seconds of it or as given.', 'snap anchors within 0.08'),
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
