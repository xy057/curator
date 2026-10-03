import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:xml/xml.dart';

import 'native/bindings.dart';

/// A SMuFL music font: one of the bundled ones, or one the user added (its file kept with the
/// project). Verovio lays out with its metrics and the renderer draws the same font, so
/// engraving and drawing agree. Adding a bundled one means its OTF (pubspec fonts), its
/// Verovio metrics (`assets/verovio/Name.xml`) and its engraving defaults here.
@immutable
class MusicFont {
  const MusicFont._(this.name, this._defaults)
      : file = null,
        metadata = null,
        _digest = 0;

  const MusicFont._added(this.name, Uint8List this.file, this.metadata, this._defaults, this._digest);

  /// A font the user adds: its file (OTF or TTF) and the SMuFL metadata published with it
  /// (`<name>_metadata.json`: anchors and engraving defaults; without it glyphs are placed by
  /// their outlines alone, with Bravura's defaults). It is named by the metadata's `fontName`,
  /// else [family]. Throws a [FormatException] when the metadata isn't SMuFL metadata or the
  /// name is a bundled font's.
  factory MusicFont.added({required String family, required Uint8List file, Uint8List? metadata}) {
    var name = family;
    final defaults = <String, double>{};
    if (metadata != null) {
      final Object? json;
      try {
        json = jsonDecode(utf8.decode(metadata, allowMalformed: true));
      } on FormatException {
        throw const FormatException('The SMuFL metadata is not JSON.');
      }
      if (json is! Map) throw const FormatException('The SMuFL metadata is not JSON.');
      if (json['fontName'] case final String n when n.trim().isNotEmpty) name = n.trim();
      if (json['engravingDefaults'] case final Map map) {
        for (final key in bravura._defaults.keys) {
          if (map[key] case final num v when v.isFinite && v >= 0) defaults[key] = v.toDouble();
        }
      }
    }
    // Verovio finds a font's metrics by its name, as a file name.
    name = name.replaceAll(RegExp(r'[^A-Za-z0-9 _\-]'), '_').trim();
    if (name.isEmpty) throw const FormatException('The font has no name.');
    if (bundled.any((f) => f.name.toLowerCase() == name.toLowerCase()) || name.toLowerCase() == 'leipzig') {
      throw FormatException('$name is already included.');
    }
    return MusicFont._added(name, file, metadata, Map.unmodifiable(defaults), _fnv(file) ^ _fnv(metadata ?? Uint8List(0)));
  }

  /// Reads the font file at [path] and finds its SMuFL metadata: [metadataPath], else a
  /// `*metadata*.json` beside it, else in a SMuFL folder
  /// (`Library/Application Support/SMuFL/Fonts/<family>/`). Throws a [FormatException] when it isn't a font.
  static Future<MusicFont> read(String path, {String? metadataPath}) async {
    final family = using((arena) => vb_font_file_family(path.toNativeUtf8(allocator: arena)).toDartString());
    if (family.isEmpty) throw const FormatException('Not a font.');
    metadataPath ??= _metadataBeside(path) ?? _smuflFolders.map((dir) => _metadataIn('$dir/$family')).nonNulls.firstOrNull;
    return MusicFont.added(
      family: family,
      file: await File(path).readAsBytes(),
      metadata: metadataPath == null ? null : await File(metadataPath).readAsBytes(),
    );
  }

  /// SMuFL fonts installed on this computer besides the bundled ones: each with metadata in a
  /// SMuFL folder and its font installed. Sorted by name.
  static List<({String name, String file, String metadata})> installed() {
    final found = <String, ({String name, String file, String metadata})>{};
    for (final root in _smuflFolders) {
      final dir = Directory(root);
      if (!dir.existsSync()) continue;
      for (final folder in dir.listSync().whereType<Directory>()) {
        final name = folder.path.split(Platform.pathSeparator).last;
        final metadata = _metadataIn(folder.path);
        if (metadata == null || found.containsKey(name) || bundled.any((f) => f.name == name)) continue;
        final file = using((arena) => vb_font_family_file(name.toNativeUtf8(allocator: arena)).toDartString());
        if (file.isNotEmpty) found[name] = (name: name, file: file, metadata: metadata);
      }
    }
    return found.values.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  static List<String> get _smuflFolders => [
        if (Platform.environment['HOME'] case final home?) '$home/Library/Application Support/SMuFL/Fonts',
        '/Library/Application Support/SMuFL/Fonts',
      ];

  static String? _metadataBeside(String fontPath) => _metadataIn(File(fontPath).parent.path);

  static String? _metadataIn(String folder) {
    final dir = Directory(folder);
    if (!dir.existsSync()) return null;
    return dir
        .listSync()
        .whereType<File>()
        .map((f) => f.path)
        .where((p) => p.toLowerCase().endsWith('.json') && p.split(Platform.pathSeparator).last.toLowerCase().contains('metadata'))
        .firstOrNull;
  }

  static const bravura = MusicFont._('Bravura', {
    // From bravura_metadata.json: Steinberg's own values, the ones Dorico engraves with.
    'staffLineThickness': 0.13, 'stemThickness': 0.12, 'legerLineThickness': 0.16,
    'legerLineExtension': 0.4, 'slurEndpointThickness': 0.1, 'slurMidpointThickness': 0.22,
    'tieEndpointThickness': 0.1, 'tieMidpointThickness': 0.22, 'thinBarlineThickness': 0.16,
    'thickBarlineThickness': 0.5, 'barlineSeparation': 0.4, 'repeatBarlineDotSeparation': 0.16,
    'dashedBarlineDashLength': 0.5, 'dashedBarlineGapLength': 0.25, 'bracketThickness': 0.5,
    'subBracketThickness': 0.16, 'hairpinThickness': 0.16, 'octaveLineThickness': 0.16,
    'pedalLineThickness': 0.16, 'repeatEndingLineThickness': 0.16, 'lyricLineThickness': 0.16,
    'tupletBracketThickness': 0.16, 'textEnclosureThickness': 0.16, 'hBarThickness': 1.0,
  });

  // The others' from their own metadata (leland_metadata.json…); what one lacks is Bravura's.
  static const leland = MusicFont._('Leland', {
    'staffLineThickness': 0.11, 'stemThickness': 0.1, 'legerLineThickness': 0.16,
    'legerLineExtension': 0.33, 'slurEndpointThickness': 0.05, 'slurMidpointThickness': 0.21,
    'tieEndpointThickness': 0.05, 'tieMidpointThickness': 0.21, 'thinBarlineThickness': 0.18,
    'thickBarlineThickness': 0.55, 'barlineSeparation': 0.37, 'repeatBarlineDotSeparation': 0.37,
    'dashedBarlineDashLength': 0.6, 'dashedBarlineGapLength': 0.4, 'bracketThickness': 0.45,
    'subBracketThickness': 0.11, 'hairpinThickness': 0.12, 'octaveLineThickness': 0.11,
    'pedalLineThickness': 0.11, 'repeatEndingLineThickness': 0.11, 'lyricLineThickness': 0.1,
    'tupletBracketThickness': 0.1, 'textEnclosureThickness': 0.11, 'hBarThickness': 0.7,
  });

  static const petaluma = MusicFont._('Petaluma', {
    'staffLineThickness': 0.13, 'stemThickness': 0.2, 'legerLineThickness': 0.16,
    'legerLineExtension': 0.4, 'slurEndpointThickness': 0.16, 'slurMidpointThickness': 0.33,
    'tieEndpointThickness': 0.1, 'tieMidpointThickness': 0.33, 'thinBarlineThickness': 0.16,
    'thickBarlineThickness': 0.5, 'barlineSeparation': 0.4, 'repeatBarlineDotSeparation': 0.16,
    'dashedBarlineDashLength': 0.5, 'dashedBarlineGapLength': 0.25, 'bracketThickness': 0.5,
    'subBracketThickness': 0.16, 'hairpinThickness': 0.33, 'octaveLineThickness': 0.16,
    'pedalLineThickness': 0.16, 'repeatEndingLineThickness': 0.16, 'lyricLineThickness': 0.16,
    'tupletBracketThickness': 0.16, 'textEnclosureThickness': 0.16,
  });

  static const leipzig = MusicFont._('Leipzig', {
    'staffLineThickness': 0.08, 'stemThickness': 0.076, 'legerLineThickness': 0.16,
    'legerLineExtension': 0.27, 'slurEndpointThickness': 0.1, 'slurMidpointThickness': 0.22,
    'tieEndpointThickness': 0.1, 'tieMidpointThickness': 0.22, 'thinBarlineThickness': 0.15,
    'thickBarlineThickness': 0.5, 'barlineSeparation': 0.4, 'repeatBarlineDotSeparation': 0.18,
    'dashedBarlineDashLength': 0.5, 'dashedBarlineGapLength': 0.25, 'bracketThickness': 0.5,
    'subBracketThickness': 0.16, 'hairpinThickness': 0.16, 'octaveLineThickness': 0.16,
    'pedalLineThickness': 0.16, 'repeatEndingLineThickness': 0.16, 'lyricLineThickness': 0.16,
    'tupletBracketThickness': 0.16, 'textEnclosureThickness': 0.16, 'hBarThickness': 1.0,
  });

  static const gootville = MusicFont._('Gootville', {
    'staffLineThickness': 0.13, 'stemThickness': 0.12, 'legerLineThickness': 0.16,
    'legerLineExtension': 0.4, 'slurEndpointThickness': 0.1, 'slurMidpointThickness': 0.22,
    'tieEndpointThickness': 0.1, 'tieMidpointThickness': 0.22, 'thinBarlineThickness': 0.16,
    'thickBarlineThickness': 0.5, 'barlineSeparation': 0.4, 'repeatBarlineDotSeparation': 0.16,
    'dashedBarlineDashLength': 0.5, 'dashedBarlineGapLength': 0.25, 'bracketThickness': 0.4,
    'subBracketThickness': 0.16, 'hairpinThickness': 0.16, 'octaveLineThickness': 0.16,
    'pedalLineThickness': 0.16, 'repeatEndingLineThickness': 0.16, 'lyricLineThickness': 0.16,
    'tupletBracketThickness': 0.16, 'textEnclosureThickness': 0.16,
  });

  /// The fonts the app ships, in the order offered.
  static const bundled = [bravura, leland, petaluma, leipzig, gootville];

  /// The bundled font named [name], if any.
  static MusicFont? bundledNamed(String name) => bundled.where((f) => f.name == name).firstOrNull;

  /// Verovio's name for it, and the one shown.
  final String name;

  /// An added font's file; null for a bundled one.
  final Uint8List? file;

  /// An added font's SMuFL metadata (JSON), if it came with one.
  final Uint8List? metadata;

  final Map<String, double> _defaults;
  final int _digest;

  bool get isBundled => file == null;

  /// SMuFL engraving defaults (staff spaces): the font's own, Bravura's where it has none.
  Map<String, double> get engravingDefaults => {...bravura._defaults, ..._defaults};

  /// The family the renderer draws it with (an added one's is registered by [load]).
  String get family => isBundled ? 'packages/score_engine/$name' : 'Curator $name ${_digest.toRadixString(16)}';

  /// Makes an added font drawable (bundled ones always are).
  Future<void> load() async {
    if (isBundled || !_loaded.add(family)) return;
    await ui.loadFontFromList(file!, fontFamily: family);
  }

  static final _loaded = <String>{};

  @override
  bool operator ==(Object other) =>
      other is MusicFont && other.name == name && other._digest == _digest && other.file?.length == file?.length;

  @override
  int get hashCode => Object.hash(name, _digest);

  @override
  String toString() => 'MusicFont($name)';

  /// FNV-1a: tells two added files apart without keeping a copy to compare.
  static int _fnv(Uint8List bytes) {
    var h = 0x811c9dc5;
    for (final b in bytes) {
      h = ((h ^ b) * 0x01000193) & 0xffffffff;
    }
    return h;
  }
}

/// Text fonts (tempo marks, expressions, instrument names): Academico, which the app ships, or
/// any font family installed on the computer, by name.
abstract final class TextFonts {
  static const academico = 'Academico';

  /// The family the renderer draws [name] with.
  static String familyOf(String name) => name == academico ? 'packages/score_engine/$academico' : name;

  /// The font families installed on this computer, sorted (none off macOS).
  static List<String> installed() {
    final names = vb_font_families().toDartString().split('\n').where((n) => n.isNotEmpty).toSet().toList();
    return names..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  }
}

/// The fonts a score is engraved and drawn with.
@immutable
class ScoreFonts {
  const ScoreFonts({this.music = MusicFont.bravura, this.text = TextFonts.academico});

  /// What a new project starts with: Bravura and its companion, Academico.
  static const standard = ScoreFonts();

  final MusicFont music;

  /// The text font's family name ([TextFonts.academico] or an installed one).
  final String text;

  ScoreFonts copyWith({MusicFont? music, String? text}) => ScoreFonts(music: music ?? this.music, text: text ?? this.text);

  @override
  bool operator ==(Object other) => other is ScoreFonts && other.music == music && other.text == text;

  @override
  int get hashCode => Object.hash(music, text);

  @override
  String toString() => 'ScoreFonts(${music.name}, $text)';
}

/// Verovio's resource folder for a pair of fonts. It reads every music font's metrics from
/// `<folder>/<name>.xml` (always Bravura's and Leipzig's as well) and the text font's from
/// `<folder>/text/Times*.xml`, whatever the font. The bundled folder has every bundled music
/// font, and Academico's metrics under those names; for other fonts a folder is written once,
/// with metrics measured from the font itself.
abstract final class FontResources {
  /// Where those folders go (the app's scratch space); a temporary folder when not set.
  static String? workDirectory;

  static final _textStyles = {
    'Times': (bold: false, italic: false),
    'Times-bold': (bold: true, italic: false),
    'Times-italic': (bold: false, italic: true),
    'Times-bold-italic': (bold: true, italic: true),
  };

  /// The folder to engrave [fonts] with, given the bundled one ([base]). [textFound] is false
  /// when the text font isn't installed: Academico's metrics stand in. Measures fonts, so run
  /// it off the UI isolate.
  static ({String directory, bool textFound}) prepare(ScoreFonts fonts, {required String base, String? work}) {
    final music = fonts.music, text = fonts.text;
    if (music.isBundled && text == TextFonts.academico) return (directory: base, textFound: true);
    work ??= workDirectory ?? '${Directory.systemTemp.path}/curated-score-fonts';
    final key = MusicFont._fnv(utf8.encode('${music.name}|${music._digest}|$text|$base'));
    final dir = Directory('$work/fonts-${key.toRadixString(16)}');
    final done = File('${dir.path}/.done');
    if (done.existsSync()) return (directory: dir.path, textFound: done.readAsStringSync() == 'text');

    // Written aside and moved in at once, so an engraving running beside this one never reads
    // half a folder.
    final draft = Directory('${dir.path}.$pid-${DateTime.now().microsecondsSinceEpoch}')..createSync(recursive: true);
    Directory('${draft.path}/text').createSync();
    var textFound = true;
    try {
      for (final name in {'Bravura', 'Leipzig', if (music.isBundled) music.name}) {
        File('$base/$name.xml').copySync('${draft.path}/$name.xml');
      }
      if (!music.isBundled) {
        final fontFile = File('${draft.path}/${music.name}.font')..writeAsBytesSync(music.file!);
        final xml = smuflMetrics(music, fontFile.path, bravura: File('$base/Bravura.xml').readAsStringSync());
        if (xml == null) throw const FormatException('The music font could not be read.');
        File('${draft.path}/${music.name}.xml').writeAsStringSync(xml);
        fontFile.deleteSync();
      }
      final reference = File('$base/text/Times.xml').readAsStringSync();
      final measured = {
        if (text != TextFonts.academico)
          for (final MapEntry(key: file, value: style) in _textStyles.entries)
            file: textMetrics(text, bold: style.bold, italic: style.italic, reference: reference),
      };
      textFound = text == TextFonts.academico || measured['Times'] != null;
      for (final file in _textStyles.keys) {
        if (textFound ? measured[file] : null case final xml?) {
          File('${draft.path}/text/$file.xml').writeAsStringSync(xml);
        } else {
          File('$base/text/$file.xml').copySync('${draft.path}/text/$file.xml');
        }
      }
      File('${draft.path}/.done').writeAsStringSync(textFound ? 'text' : 'missing');
      try {
        draft.renameSync(dir.path);
      } on FileSystemException {
        draft.deleteSync(recursive: true); // another engraving wrote it first
      }
    } catch (_) {
      if (draft.existsSync()) draft.deleteSync(recursive: true);
      rethrow;
    }
    return (directory: dir.path, textFound: textFound);
  }

  /// Verovio text metrics (`text/Times*.xml`) for an installed [family], for the characters
  /// the [reference] file has (its `c` is each character's UTF-8 bytes, in hex); null when the
  /// family isn't installed.
  static String? textMetrics(String family, {required bool bold, required bool italic, required String reference}) {
    final codes = [
      for (final m in RegExp(r'<g c="([0-9A-Fa-f]+)"').allMatches(reference)) m.group(1)!,
    ];
    final chars = [for (final c in codes) _utf8Char(c)];
    final measured = _measure(family, isFile: false, bold: bold, italic: italic, codes: [for (final c in chars) c ?? 0]);
    if (measured == null) return null;
    final out = StringBuffer('<?xml version="1.0" encoding="UTF-8"?>\n<bounding-boxes font-family="Times" units-per-em="${measured.upm}">\n');
    for (final (i, c) in codes.indexed) {
      final g = measured.glyphs[i];
      if (chars[i] == null || g == null) continue;
      out.writeln('   <g c="$c" x="${_n(g.x)}" y="${_n(g.y)}" w="${_n(g.w)}" h="${_n(g.h)}" h-a-x="${_n(g.advance)}" />');
    }
    out.writeln('</bounding-boxes>');
    return out.toString();
  }

  /// Verovio music metrics for an added [font] (its file at [path]): every glyph [bravura]'s
  /// metrics name that the font has, with its anchors from the font's SMuFL metadata. Null when
  /// the file can't be opened.
  static String? smuflMetrics(MusicFont font, String path, {required String bravura}) {
    final glyphs = XmlDocument.parse(bravura).rootElement.findElements('g').toList();
    final codes = [for (final g in glyphs) int.tryParse(g.getAttribute('c') ?? '', radix: 16) ?? 0];
    final measured = _measure(path, isFile: true, bold: false, italic: false, codes: codes);
    if (measured == null) return null;
    final anchors = switch (font.metadata) {
      null => const <String, Object?>{},
      final bytes => switch (jsonDecode(utf8.decode(bytes, allowMalformed: true))) {
          {'glyphsWithAnchors': final Map<String, Object?> map} => map,
          _ => const <String, Object?>{},
        },
    };
    final out = StringBuffer("<?xml version='1.0' encoding='UTF-8'?>\n"
        '<bounding-boxes font-family="${font.name}" units-per-em="${measured.upm}">\n');
    for (final (i, element) in glyphs.indexed) {
      final g = measured.glyphs[i];
      final name = element.getAttribute('n');
      if (g == null || name == null) continue;
      out.write('  <g c="${element.getAttribute('c')}" x="${_n(g.x)}" y="${_n(g.y)}" w="${_n(g.w)}" h="${_n(g.h)}" '
          'h-a-x="${_n(g.advance)}" n="$name"');
      final own = anchors[name];
      if (own is Map && own.isNotEmpty) {
        out.writeln('>');
        for (final MapEntry(key: anchor, value: at) in own.entries) {
          if (at case [final num x, final num y]) out.writeln('    <a n="$anchor" x="$x" y="$y" />');
        }
        out.writeln('  </g>');
      } else {
        out.writeln(' />');
      }
    }
    out.writeln('</bounding-boxes>');
    return out.toString();
  }

  static String _n(double v) => v.toStringAsFixed(1);

  static int? _utf8Char(String hex) {
    if (hex.length.isOdd) return null;
    final bytes = [for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)];
    try {
      final runes = utf8.decode(bytes).runes;
      return runes.length == 1 ? runes.first : null;
    } on FormatException {
      return null;
    }
  }

  static ({int upm, List<({double x, double y, double w, double h, double advance})?> glyphs})? _measure(String font,
          {required bool isFile, required bool bold, required bool italic, required List<int> codes}) =>
      using((arena) {
        final codePointer = arena<Uint32>(codes.length);
        for (final (i, c) in codes.indexed) {
          codePointer[i] = c;
        }
        final out = arena<Float>(codes.length * 5);
        final upm = vb_measure_font(font.toNativeUtf8(allocator: arena), isFile, bold, italic, codePointer, codes.length, out);
        if (upm <= 0) return null;
        return (
          upm: upm,
          glyphs: [
            for (var i = 0; i < codes.length; i++)
              out[i * 5 + 4] < 0 || codes[i] == 0
                  ? null
                  : (x: out[i * 5], y: out[i * 5 + 1], w: out[i * 5 + 2], h: out[i * 5 + 3], advance: out[i * 5 + 4]),
          ],
        );
      });
}
