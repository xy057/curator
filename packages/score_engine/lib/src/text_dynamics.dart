import 'package:xml/xml.dart';

/// Dynamics a notation program wrote as text: a `<words>` "f" set in a music font (Sibelius
/// does this for an "f" typed in a text style other than Expression), or SMuFL's dynamics
/// characters. MusicXML has no way to say such text means forte, so Verovio engraves it as
/// words in the text font; [apply] makes each a `<dynamics>` element, kept where it was.
abstract final class TextDynamics {
  /// Rewrites every such `<words>` in [doc] as `<dynamics>`; returns how many.
  static int apply(XmlDocument doc) {
    var count = 0;
    for (final words in doc.findAllElements('words').toList()) {
      final name = dynamicOf(words);
      final type = words.parent;
      if (name == null || type is! XmlElement || type.name.local != 'direction-type') continue;
      _replace(
          type,
          words,
          XmlElement.tag('dynamics', attributes: [
            for (final a in words.attributes)
              if (_kept.contains(a.name.local)) XmlAttribute(XmlName.qualified(a.name.local), a.value),
          ], children: [
            XmlElement.tag(name)
          ]));
      count++;
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
    return _names.contains(name) ? name : null;
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

  /// [words] becomes [dynamics]. A direction-type holds one kind of thing, so text beside it
  /// moves into direction-types of its own, before and after, in the same order.
  static void _replace(XmlElement type, XmlElement words, XmlElement dynamics) {
    final kids = type.childElements.toList();
    final i = kids.indexOf(words);
    if (kids.length == 1) return words.replace(dynamics);
    XmlElement typeOf(Iterable<XmlNode> children) =>
        XmlElement.tag('direction-type', children: [for (final c in children) c.copy()]);
    final split = [
      if (i > 0) typeOf(kids.take(i)),
      typeOf([dynamics]),
      if (i < kids.length - 1) typeOf(kids.skip(i + 1)),
    ];
    final siblings = type.parent!.children;
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
