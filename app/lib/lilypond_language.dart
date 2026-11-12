import 'package:material_ui/material_ui.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/re_highlight.dart';

/// LilyPond as the LilyPond editor reads it: how its source is coloured ([lilyPondMode], in
/// [lilyPondTheme]'s colours) and what is offered as it is typed ([LilyPondPrompts]).

/// How LilyPond's source is highlighted: comments, strings, commands (those that build the score
/// apart), contexts and grobs, durations and numbers, variables being defined, and the Scheme in
/// `#(…)` with its own comments, strings, keywords and symbols.
Mode lilyPondMode() {
  final escape = Mode(begin: r'\\[\s\S]', relevance: 0);
  // Scheme, after # or $.
  final schemeAtoms = <Mode>[
    Mode(scope: 'string', begin: '"', end: '"', contains: [escape]),
    Mode(scope: 'comment', begin: ';', end: r'$'),
    Mode(scope: 'comment', begin: r'#!', end: r'!#'),
    Mode(scope: 'literal', begin: r'#(?:t|f|true|false)\b|#\\[^\s()]+'),
    Mode(scope: 'symbol', begin: r"""'[^\s()\[\]{}"';`,]+"""),
    Mode(scope: 'number', begin: r'[-+]?\d+(?:\.\d+)?(?:/\d+)?(?![\w-])', relevance: 0),
  ];
  final schemeWords = {
    r'$pattern': r'''[^\s()\[\]{}"';`,]+''',
    'keyword': 'define define* define-public define-music-function define-scheme-function define-void-function '
        'define-event-function define-markup-command lambda lambda* let let* letrec letrec* if cond case and or when unless begin '
        'set! quote quasiquote unquote else do',
    'built_in': 'display newline list cons car cdr cadr null? pair? list? not eq? equal? map for-each append reverse length '
        'string-append number->string string->symbol symbol->string make-music ly:make-moment ly:music-property '
        'ly:grob-property ly:grob-set-property! ly:context-property ly:make-pitch ly:pitch-transpose make-sequential-music '
        'make-simultaneous-music markup? number? string? symbol? procedure? assoc assq ref apply',
  };
  final schemeList = Mode(begin: r'\(', end: r'\)', relevance: 0, keywords: schemeWords);
  schemeList.contains = <Mode>[Mode(self: true), ...schemeAtoms];
  return Mode(
    name: 'LilyPond',
    aliases: ['lilypond', 'ly'],
    contains: <Mode>[
      Mode(scope: 'comment', begin: r'%\{', end: r'%\}'),
      Mode(scope: 'comment', begin: '%', end: r'$'),
      Mode(scope: 'string', begin: '"', end: '"', contains: [escape]),
      // Scheme: a list, or one thing (##t, #'Staff, #"text", #-1.5, #red).
      Mode(begin: r'[#$]\(', end: r'\)', keywords: schemeWords, contains: <Mode>[schemeList, ...schemeAtoms]),
      Mode(scope: 'string', begin: r'[#$]"', end: '"', contains: [escape]),
      Mode(scope: 'literal', begin: r'''[#$](?:#[tf]\b|#\\\S|'[^\s()\[\]{}"';`,]+|:[\w-]+|[-+]?\d+(?:\.\d+)?|[a-zA-Z][\w\-:!?*<>=/+.]*)'''),
      Mode(scope: 'keyword', begin: '\\\\(?:${_structural.join('|')})(?![A-Za-z])'),
      Mode(scope: 'built_in', begin: r'\\(?:[A-Za-z]+(?:[-_][A-Za-z]+)*|[!<>()\[\]~=\\])'),
      Mode(scope: 'variable', begin: r'^[A-Za-z][A-Za-z_-]*(?=\s*=)'),
      Mode(scope: 'title', begin: r'\b[A-Z][A-Za-z]*(?:_[a-z]+)*\b', relevance: 0),
      Mode(scope: 'number', begin: r'\d+(?:/\d+)?\.*', relevance: 0),
      Mode(scope: 'meta', begin: r'[|~]', relevance: 0),
    ],
  );
}

/// The colours [lilyPondMode]'s scopes are drawn in: on a light page, or a dark one.
Map<String, TextStyle> lilyPondTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  Color c(int light, int night) => Color(dark ? night : light);
  return {
    'comment': TextStyle(color: c(0xFF8A8F98, 0xFF7F848E), fontStyle: FontStyle.italic),
    'string': TextStyle(color: c(0xFF2F7D32, 0xFF98C379)),
    'keyword': TextStyle(color: c(0xFFA626A4, 0xFFC678DD), fontWeight: FontWeight.w600),
    'built_in': TextStyle(color: c(0xFF0B61A4, 0xFF61AFEF)),
    'title': TextStyle(color: c(0xFF0E7C86, 0xFF56B6C2)),
    'number': TextStyle(color: c(0xFFB45309, 0xFFD19A66)),
    'variable': TextStyle(color: c(0xFF7C3AED, 0xFFE5C07B), fontWeight: FontWeight.w600),
    'literal': TextStyle(color: c(0xFFC2410C, 0xFFE06C75)),
    'symbol': TextStyle(color: c(0xFFC2410C, 0xFFE06C75)),
    'meta': TextStyle(color: c(0xFF6B7280, 0xFF8B929C)),
  };
}

/// What is offered as LilyPond is typed: a word to put in, and what it is (a command, a
/// context…), as the list shows it.
/// What a word offered is (shown beside it).
enum LilyPondKind { context, clef, repeat, barline, language, property, grob, variable, command }

class LilyPondPrompt extends CodePrompt {
  const LilyPondPrompt(String word, this.kind) : super(word: word);
  final LilyPondKind kind;

  @override
  CodeAutocompleteResult get autocomplete => CodeAutocompleteResult.fromWord(word);

  @override
  bool match(String input) => word != input && word.startsWith(input);

  @override
  bool operator ==(Object other) => other is LilyPondPrompt && other.word == word && other.kind == kind;

  @override
  int get hashCode => Object.hash(word, kind);
}

/// What to offer where the caret is in LilyPond: after `\new` or `\context` a context, after
/// `\clef` a clef, after `\repeat` a kind of repeat, in `\bar "` a barline, in `\language "` a
/// language, after `\override`, `\revert` or `\tweak` a grob (or a context, then its grob) and
/// after its dot a property, after `\set` or `\unset` a context property; after `\` a command or a
/// variable the score defines ([text], the whole source). Nothing in a comment.
class LilyPondPrompts implements CodeAutocompletePromptsBuilder {
  LilyPondPrompts(this.text);

  /// The source as it is now (its variables are offered after `\`).
  final String Function() text;

  /// How many are shown at most.
  static const limit = 40;

  @override
  CodeAutocompleteEditingValue? build(BuildContext context, CodeLine codeLine, CodeLineSelection selection) =>
      promptsFor(codeLine.text.substring(0, selection.extentOffset.clamp(0, codeLine.text.length)));

  /// What to offer with [before] (the line up to the caret) typed: what is being typed and the
  /// words it may become; null for nothing.
  CodeAutocompleteEditingValue? promptsFor(String before) {
    if (_inComment(before)) return null;
    CodeAutocompleteEditingValue? offer(String input, Iterable<LilyPondPrompt> all) {
      final seen = <String>{};
      final prompts = [
        for (final p in all)
          if ((input.isEmpty || p.match(input)) && p.word != input && seen.add(p.word)) p,
      ].take(limit).toList();
      return prompts.isEmpty ? null : CodeAutocompleteEditingValue(input: input, prompts: prompts, index: 0);
    }

    Iterable<LilyPondPrompt> of(List<String> words, LilyPondKind kind) => words.map((w) => LilyPondPrompt(w, kind));
    if (RegExp(r'\\(?:new|context)\s+([A-Za-z]*)$').firstMatch(before) case final m?) {
      return offer(m[1]!, of(contexts, LilyPondKind.context));
    }
    if (RegExp(r'\\clef\s+"?([A-Za-z0-9_^]*)$').firstMatch(before) case final m?) return offer(m[1]!, of(clefs, LilyPondKind.clef));
    if (RegExp(r'\\repeat\s+([a-z]*)$').firstMatch(before) case final m?) return offer(m[1]!, of(repeats, LilyPondKind.repeat));
    if (RegExp(r'\\bar\s+"([^"\s]*)$').firstMatch(before) case final m?) return offer(m[1]!, of(barlines, LilyPondKind.barline));
    if (RegExp(r'\\language\s+"([a-zçñ]*)$').firstMatch(before) case final m?) return offer(m[1]!, of(languages, LilyPondKind.language));
    // \override Staff.NoteHead.color: after a context a grob, after a grob a property.
    if (RegExp(r'\\(?:override|revert|tweak)\s+((?:[A-Z][A-Za-z]*\.)*)([A-Za-z-]*)$').firstMatch(before) case final m?) {
      final last = m[1]!.split('.').where((s) => s.isNotEmpty).lastOrNull;
      if (last != null && !contexts.contains(last)) return offer(m[2]!, of(grobProperties, LilyPondKind.property));
      return offer(m[2]!, [...of(grobs, LilyPondKind.grob), if (last == null) ...of(contexts, LilyPondKind.context)]);
    }
    if (RegExp(r'\\(?:set|unset)\s+(?:([A-Z][A-Za-z]*)\.)?([A-Za-z]*)$').firstMatch(before) case final m?) {
      return offer(m[2]!, [...of(contextProperties, LilyPondKind.property), if (m[1] == null) ...of(contexts, LilyPondKind.context)]);
    }
    if (RegExp(r'\\([A-Za-z][A-Za-z-]*)$').firstMatch(before) case final m?) {
      return offer(m[1]!, [...of(variables(text()), LilyPondKind.variable), ...of(commands, LilyPondKind.command)]);
    }
    return null;
  }

  /// Whether the caret is in a `%` comment: one outside a string.
  static bool _inComment(String before) {
    var quoted = false;
    for (var i = 0; i < before.length; i++) {
      final c = before[i];
      if (c == '\\' && quoted) {
        i++;
      } else if (c == '"') {
        quoted = !quoted;
      } else if (c == '%' && !quoted) {
        return true;
      }
    }
    return false;
  }

  /// The variables [source] defines (`melody = …` at a line's start), as written.
  static List<String> variables(String source) => [
        for (final m in RegExp(r'^([A-Za-z][A-Za-z_-]*)\s*=', multiLine: true).allMatches(source)) m[1]!,
      ];

  /// LilyPond's commands, the most used first.
  static const commands = [
    ..._structural, 'partial', 'time', 'key', 'clef', 'bar', 'mark', 'textMark', 'sectionLabel', 'tempo', 'major', 'minor', //
    'voiceOne', 'voiceTwo', 'voiceThree', 'voiceFour', 'oneVoice', 'break', 'noBreak', 'pageBreak', 'noPageBreak', 'fine',
    'segnoMark', 'codaMark', 'ottava', 'autoBeamOff', 'autoBeamOn', 'cadenzaOn', 'cadenzaOff', 'fermata', 'staccato', 'accent',
    'tenuto', 'marcato', 'portato', 'staccatissimo', 'espressivo', 'trill', 'turn', 'mordent', 'prall', 'upbow', 'downbow',
    'flageolet', 'open', 'stopped', 'harmonic', 'arpeggio', 'glissando', 'breathe', 'caesura', 'segno', 'coda', 'varcoda',
    'ppppp', 'pppp', 'ppp', 'pp', 'p', 'mp', 'mf', 'f', 'ff', 'fff', 'ffff', 'fffff', 'fp', 'sf', 'sff', 'sfz', 'sfp', 'rfz', 'sp',
    'spp', 'cresc', 'decresc', 'dim', 'endcresc', 'enddecresc', 'enddim', 'crescTextCresc', 'dimTextDim', 'crescHairpin',
    'dimHairpin', 'stemUp', 'stemDown', 'stemNeutral', 'slurUp', 'slurDown', 'slurNeutral', 'slurDashed', 'slurDotted', 'slurSolid',
    'tieUp', 'tieDown', 'tieNeutral', 'dynamicUp', 'dynamicDown', 'dynamicNeutral', 'tupletUp', 'tupletDown', 'tupletNeutral',
    'hideNotes', 'unHideNotes', 'omit', 'hide', 'ionian', 'dorian', 'phrygian', 'lydian', 'mixolydian', 'aeolian', 'locrian',
    'startTrillSpan', 'stopTrillSpan', 'sustainOn', 'sustainOff', 'unaCorda', 'treCorde', 'sostenutoOn', 'sostenutoOff',
    'xNote', 'xNotesOn', 'xNotesOff', 'improvisationOn', 'improvisationOff', 'easyHeadsOn', 'easyHeadsOff', 'numericTimeSignature',
    'defaultTimeSignature', 'compressMMRests', 'compressEmptyMeasures', 'expandEmptyMeasures', 'parallelMusic', 'skip', 'rest',
    'unfoldRepeats', 'articulate', 'shape', 'magnifyMusic', 'scaleDurations', 'harmonicsOn', 'harmonicsOff', 'italianChords',
    'germanChords', 'frenchChords', 'semiGermanChords', 'powerChords', 'chordRepeats', 'textLengthOn', 'textLengthOff',
    'markLengthOn', 'markLengthOff', 'mergeDifferentlyDottedOn', 'mergeDifferentlyHeadedOn', 'shiftOn', 'shiftOff', 'shiftOnn',
    'shiftOnnn', 'balloonText', 'footnote', 'startStaff', 'stopStaff', 'startGroup', 'stopGroup', 'startTextSpan', 'stopTextSpan',
    'repeatTie', 'laissezVibrer', 'bold', 'italic', 'upright', 'medium', 'caps', 'smallCaps', 'normal-text', 'fontsize', 'huge',
    'large', 'normalsize', 'small', 'tiny', 'teeny', 'column', 'line', 'center-column', 'center-align', 'left-align',
    'right-align', 'fill-line', 'wordwrap', 'justify', 'vspace', 'hspace', 'concat', 'char', 'musicglyph', 'note', 'rest',
    'fraction', 'circle', 'box', 'rounded-box', 'with-color', 'with-url', 'underline', 'sharp', 'flat', 'natural',
    'doublesharp', 'doubleflat', 'dynamic', 'finger', 'abs-fontsize', 'magnify', 'raise', 'lower', 'translate', 'rotate',
    'general-align', 'halign', 'path', 'draw-line', 'draw-circle', 'filled-box', 'null', 'epsfile', 'score',
  ];

  /// The contexts a score is made of, the most used first.
  static const contexts = [
    'Staff', 'Voice', 'PianoStaff', 'GrandStaff', 'StaffGroup', 'ChoirStaff', 'Lyrics', 'Score', 'DrumStaff', 'DrumVoice',
    'RhythmicStaff', 'TabStaff', 'TabVoice', 'ChordNames', 'FiguredBass', 'FretBoards', 'Dynamics', 'NoteNames', 'CueVoice',
    'NullVoice', 'OneStaff', 'Timing', 'Devnull', 'MensuralStaff', 'MensuralVoice', 'PetrucciStaff', 'PetrucciVoice',
    'VaticanaStaff', 'VaticanaVoice', 'GregorianTranscriptionStaff', 'GregorianTranscriptionVoice', 'KievanStaff', 'KievanVoice',
  ];

  /// The clefs `\clef` takes.
  static const clefs = [
    'treble', 'bass', 'alto', 'tenor', 'percussion', 'treble_8', 'bass_8', 'treble^8', 'bass^8', 'violin', 'G', 'G2', 'GG',
    'tenorG', 'french', 'soprano', 'mezzosoprano', 'C', 'baritone', 'varbaritone', 'F', 'subbass', 'varC', 'altovarC',
    'tenorvarC', 'baritonevarC', 'varpercussion', 'tab', 'moderntab',
  ];

  /// The kinds of repeat `\repeat` makes.
  static const repeats = ['volta', 'unfold', 'percent', 'tremolo', 'segno'];

  /// The barlines `\bar` draws.
  static const barlines = [
    '|', '||', '|.', '.|', '.|:', ':|.', ':..:', ':|.|:', ':|.:', '[|:', ':|]', ':|][|:', '!', ';', '.', "'", '..', '|.|',
    'k', 'S', 'S-||', 'S-|.', '|.S', 'x-.', '-span|',
  ];

  /// The languages note names are written in (`\language`).
  static const languages = [
    'english', 'nederlands', 'deutsch', 'italiano', 'français', 'francais', 'español', 'espanol', 'português', 'portugues',
    'català', 'catalan', 'suomi', 'svenska', 'norsk', 'vlaams', 'arabic', 'bagpipe', 'persian',
  ];

  /// The grobs (what is drawn) `\override` sets, the most used first.
  static const grobs = [
    'NoteHead', 'Stem', 'Beam', 'Slur', 'Tie', 'Accidental', 'Rest', 'Clef', 'KeySignature', 'TimeSignature', 'BarLine',
    'BarNumber', 'DynamicText', 'Hairpin', 'TextScript', 'Script', 'Fingering', 'StaffSymbol', 'MetronomeMark', 'RehearsalMark',
    'TextMark', 'SectionLabel', 'VerticalAxisGroup', 'SpacingSpanner', 'Glissando', 'TupletBracket', 'TupletNumber', 'LyricText',
    'LyricHyphen', 'LyricExtender', 'ChordName', 'Arpeggio', 'Dots', 'Flag', 'MultiMeasureRest', 'MultiMeasureRestNumber',
    'OttavaBracket', 'TrillSpanner', 'VoltaBracket', 'InstrumentName', 'SystemStartBrace', 'SystemStartBracket', 'SystemStartBar',
    'NoteColumn', 'PaperColumn', 'NonMusicalPaperColumn', 'StemTremolo', 'DynamicLineSpanner', 'DynamicTextSpanner',
    'TextSpanner', 'LedgerLineSpanner', 'Ambitus', 'BreathingSign', 'Footnote', 'Fermata', 'PhrasingSlur', 'SustainPedal',
    'PianoPedalBracket', 'SpanBar', 'StringNumber', 'StrokeFinger', 'TabNoteHead', 'Parentheses', 'VerticalAlignment',
    'StaffGrouper', 'ClefModifier', 'KeyCancellation', 'GraceSpacing', 'NoteSpacing', 'StaffSpacing', 'CombineTextScript',
  ];

  /// The properties a grob has that are set most.
  static const grobProperties = [
    'color', 'font-size', 'stencil', 'transparent', 'X-offset', 'Y-offset', 'extra-offset', 'direction', 'thickness', 'padding',
    'staff-padding', 'length', 'height', 'minimum-length', 'positions', 'details', 'font-shape', 'font-series', 'font-name',
    'style', 'avoid-slur', 'outside-staff-priority', 'outside-staff-padding', 'self-alignment-X', 'self-alignment-Y',
    'break-visibility', 'whiteout', 'layer', 'shorten-pair', 'staff-position', 'text', 'glyph-name', 'bound-details',
    'line-count', 'line-positions', 'staff-space', 'beam-thickness', 'gap', 'dash-period', 'dash-fraction', 'springs-and-rods',
    'base-shortest-duration', 'shortest-duration-space', 'common-shortest-duration', 'minimum-distance', 'X-extent',
    'Y-extent', 'staff-staff-spacing', 'nonstaff-relatedstaff-spacing', 'nonstaff-nonstaff-spacing', 'duration-log',
    'bracket-visibility', 'number-type', 'edge-height', 'neutral-direction', 'rotation', 'parenthesized', 'no-ledgers',
  ];

  /// The context properties `\set` sets most.
  static const contextProperties = [
    'instrumentName', 'shortInstrumentName', 'midiInstrument', 'currentBarNumber', 'tempoHideNote', 'autoBeaming', 'fontSize',
    'explicitKeySignatureVisibility', 'printKeyCancellation', 'keyAlterationOrder', 'barNumberVisibility', 'ottavation',
    'proportionalNotationDuration', 'midiMinimumVolume', 'midiMaximumVolume', 'rehearsalMarkFormatter', 'extraNatural',
    'middleCPosition', 'skipBars', 'timeSignatureFraction', 'measureLength', 'measurePosition', 'baseMoment', 'beatStructure',
    'beamExceptions', 'tupletFullLength', 'tupletSpannerDuration', 'stanza', 'vocalName', 'shortVocalName', 'associatedVoice',
    'includeGraceNotes', 'melismaBusyProperties', 'ignoreMelismata', 'chordChanges', 'majorSevenSymbol', 'chordNameExceptions',
    'pedalSustainStyle', 'stringTunings', 'tablatureFormat', 'drumStyleTable', 'whichBar', 'defaultBarType', 'doubleRepeatBarType',
    'startRepeatBarType', 'endRepeatBarType', 'sectionBarType', 'fineBarType', 'systemStartDelimiter', 'alignAboveContext',
    'alignBelowContext', 'figuredBassAlterationDirection', 'suggestAccidentals', 'aDueText', 'soloText', 'soloIIText',
    'printPartCombineTexts', 'timing', 'connectArpeggios', 'crescendoSpanner', 'decrescendoSpanner', 'harmonicDots',
    'restNumberThreshold', 'countPercentRepeats', 'repeatCountVisibility', 'subdivideBeams', 'clefGlyph', 'clefPosition',
    'clefTransposition', 'markFormatter', 'printTrivialVoltaRepeats', 'voltaSpannerDuration',
  ];
}

/// Commands that make the score's shape (blocks, contexts, modes, music functions on whole
/// passages): highlighted apart from the rest.
const _structural = [
  'score', 'new', 'context', 'with', 'layout', 'midi', 'paper', 'header', 'book', 'bookpart', 'version', 'include', 'language',
  'relative', 'fixed', 'transpose', 'transposition', 'repeat', 'alternative', 'volta', 'tuplet', 'times', 'grace',
  'acciaccatura', 'appoggiatura', 'afterGrace', 'slashedGrace', 'set', 'unset', 'override', 'revert', 'once', 'tweak',
  'temporary', 'undo', 'markup', 'markuplist', 'lyricmode', 'lyricsto', 'addlyrics', 'chordmode', 'chords', 'drummode',
  'drums', 'figuremode', 'figures', 'notemode', 'lyrics', 'default', 'change', 'consists', 'remove', 'accepts', 'denies',
  'alias', 'defaultchild', 'name', 'type', 'description', 'partCombine', 'quoteDuring', 'addQuote', 'cueDuring', 'keepWithTag',
  'removeWithTag', 'tag', 'pushToTag', 'appendToTag', 'void', 'displayMusic', 'displayLilyMusic',
];
