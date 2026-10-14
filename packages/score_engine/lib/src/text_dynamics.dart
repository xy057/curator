import 'package:xml/xml.dart';

/// Dynamics a notation program wrote as text: a `<words>` "f" set in a music font (Sibelius
/// does this for an "f" typed in a text style other than Expression), or SMuFL's dynamics
/// characters. MusicXML has no way to say such text means forte, so Verovio engraves it as
/// words in the text font; [apply] makes each a `<dynamics>` element, kept where it was.
abstract final class TextDynamics {
  /// Rewrites every such `<words>` in [doc] as `<dynamics>`; returns how many.
  static int apply(XmlDocument doc) {
    var count = 0;
    for (final type in doc.findAllElements('direction-type').toList()) {
      final kids = type.childElements.toList();
      final names = [for (final k in kids) k.name.local == 'words' ? dynamicOf(k) : null];
      final found = names.nonNulls.length;
      if (found == 0) continue;
      count += found;
      _split(type, kids, names);
    }
    return count;
  }

  /// The MusicXML dynamics element [words] stands for ("f", "mp", "sfz"), or null when it is
  /// ordinary text.
  static String? dynamicOf(XmlElement words) {
    final text = words.innerText.trim();
    if (text.isEmpty) return null;
    final smufl = _smuflLetters(text);
    if (smufl != null) return _names.contains(smufl) ? smufl : null;
    if (!_inMusicFont(words.getAttribute('font-family'))) return null;
    // Case aside: an exporter may map the glyph to another letter through its font's table.
    final name = text.toLowerCase();
    // In these fonts "n" is the natural sign, not niente (that is only SMuFL's character).
    return name != 'n' && _names.contains(name) ? name : null;
  }

  /// The letters a run of SMuFL dynamics characters spells, or null if [text] has others.
  static String? _smuflLetters(String text) {
    final letters = StringBuffer();
    for (final rune in text.runes) {
      final spelled = _smufl[rune];
      if (spelled == null) return null;
      letters.write(spelled);
    }
    return letters.toString();
  }

  static bool _inMusicFont(String? families) =>
      families != null &&
      families.split(',').any((f) => _musicTextFonts.contains(f.trim().replaceAll(RegExp('[\'"]'), '').toLowerCase()));

  /// What a `<dynamics>` may keep of a `<words>`' attributes: its place and colour, not its font
  /// (the score's music font draws it).
  static const _kept = {'default-x', 'default-y', 'relative-x', 'relative-y', 'color', 'halign', 'valign', 'id'};

  /// [words] as a `<dynamics>` [name]: its place and colour kept, not its font.
  static XmlElement _dynamics(XmlElement words, String name) => XmlElement.tag('dynamics', attributes: [
        for (final a in words.attributes)
          if (_kept.contains(a.name.local)) XmlAttribute(XmlName.qualified(a.name.local), a.value),
      ], children: [
        XmlElement.tag(name)
      ]);

  /// [type]'s children [kids], where [names] says which are dynamics, made dynamics. A
  /// direction-type holds one kind of thing, so each dynamic gets one of its own, and the text
  /// beside them goes into direction-types of its own between them, in the same order.
  static void _split(XmlElement type, List<XmlElement> kids, List<String?> names) {
    if (kids.length == 1) return kids.single.replace(_dynamics(kids.single, names.single!));
    final split = <XmlElement>[];
    var run = <XmlNode>[];
    void endRun() {
      if (run.isNotEmpty) split.add(XmlElement.tag('direction-type', children: run));
      run = [];
    }

    for (final (i, kid) in kids.indexed) {
      if (names[i] case final name?) {
        endRun();
        split.add(XmlElement.tag('direction-type', children: [_dynamics(kid, name)]));
      } else {
        run.add(kid.copy());
      }
    }
    endRun();
    final siblings = type.parent!.children; // found in the document: it has one
    siblings.insertAll(siblings.indexOf(type), split);
    type.remove();
  }

  /// MusicXML's dynamics elements made of letters.
  static const _names = {
    'p', 'pp', 'ppp', 'pppp', 'ppppp', 'pppppp', 'f', 'ff', 'fff', 'ffff', 'fffff', 'ffffff', //
    'mp', 'mf', 'sf', 'sfp', 'sfpp', 'fp', 'rf', 'rfz', 'sfz', 'sffz', 'fz', 'n', 'pf', 'sfzp',
  };

  /// SMuFL's dynamics characters (U+E520–E53D) and the letters each draws.
  static const _smufl = {
    0xE520: 'p', 0xE521: 'm', 0xE522: 'f', 0xE523: 'r', 0xE524: 's', 0xE525: 'z', 0xE526: 'n', //
    0xE527: 'pppppp', 0xE528: 'ppppp', 0xE529: 'pppp', 0xE52A: 'ppp', 0xE52B: 'pp', 0xE52C: 'mp',
    0xE52D: 'mf', 0xE52E: 'pf', 0xE52F: 'ff', 0xE530: 'fff', 0xE531: 'ffff', 0xE532: 'fffff',
    0xE533: 'ffffff', 0xE534: 'fp', 0xE535: 'fz', 0xE536: 'sf', 0xE537: 'sfp', 0xE538: 'sfpp',
    0xE539: 'sfz', 0xE53A: 'sfzp', 0xE53B: 'sffz', 0xE53C: 'rf', 0xE53D: 'rfz',
  };

  /// Fonts whose letters draw dynamics (Finale's, Sibelius's, Dorico's, MuseScore's), lower case.
  static const _musicTextFonts = {
    'maestro', 'maestro wide', 'petrucci', 'sonata', 'jazz', 'jazz text', 'jazztext', 'engraver text',
    'engraver font set', 'broadway copyist', 'broadway copyist text', 'golden age', 'golden age text',
    'finale maestro', 'finale maestro text', 'finale jazz', 'finale jazz text', 'finale broadway',
    'finale broadway text', 'finale engraver', 'finale engraver text', 'finale legacy', 'finale legacy text',
    'finale copyist text', 'finale ash', 'finale ash text',
    'opus', 'opus std', 'opus text', 'opus text std', 'opus special', 'opus special std', 'opus special extra',
    'opus special extra std', 'helsinki', 'helsinki std', 'helsinki text', 'helsinki text std', 'helsinki special',
    'helsinki special std', 'reprise', 'reprise std', 'reprise text', 'reprise text std', 'reprise special',
    'reprise special std', 'inkpen2', 'inkpen2 std', 'inkpen2 text', 'inkpen2 text std', 'inkpen2 special',
    'inkpen2 special std', 'norfolk', 'norfolk std', 'norfolk text', 'norfolk text std',
    'bravura', 'bravura text', 'leland', 'leland text', 'petaluma', 'petaluma text', 'sebastian',
    'sebastian text', 'gootville', 'gootville text', 'leipzig', 'emmentaler', 'mscore', 'mscore text',
  };
}
