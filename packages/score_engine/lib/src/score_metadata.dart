import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import 'beat_grid.dart';
import 'engraving.dart';
import 'zip_entries.dart';

enum InstrumentFamily {
  woodwinds('Woodwinds'),
  brass('Brass'),
  percussion('Percussion'),
  keyboards('Keyboards'),
  voices('Voices'),
  strings('Strings'),
  other('Other');

  const InstrumentFamily(this.label);
  final String label;

  /// From the MusicXML standard sound id (e.g. "strings.violin"), else from the name.
  static InstrumentFamily classify({String? sound, required String name}) {
    final key = (sound ?? '').toLowerCase();
    if (key.startsWith('wind.')) return woodwinds;
    if (key.startsWith('brass.')) return brass;
    if (['drum.', 'metal.', 'wood.', 'pitched-percussion.'].any(key.startsWith)) return percussion;
    if (key.startsWith('keyboard.')) return keyboards;
    if (key.startsWith('voice.')) return voices;
    if (key.startsWith('strings.') || key.startsWith('pluck.')) return strings;

    final lower = name.toLowerCase();
    const words = {
      woodwinds: ['flute', 'piccolo', 'oboe', 'clarinet', 'bassoon', 'cor anglais', 'english horn', 'sax'],
      brass: ['horn', 'trumpet', 'trombone', 'tuba', 'cornet'],
      percussion: ['timpani', 'drum', 'cymbal', 'triangle', 'percussion'],
      keyboards: ['piano', 'organ', 'celesta', 'harpsichord'],
      voices: ['soprano', 'alto', 'tenor', 'baritone', 'choir', 'voice'],
      strings: ['violin', 'viola', 'cello', 'contrabass', 'double bass', 'harp'],
    };
    for (final entry in words.entries) {
      if (entry.value.any(lower.contains)) return entry.key;
    }
    return other;
  }
}

/// A part (instrument) from the MusicXML part-list.
class ScorePart {
  const ScorePart({
    required this.id,
    required this.name,
    required this.abbreviation,
    required this.sound,
    required this.staffNumbers,
    this.silentStaves = const {},
    this.isUnpitchedPercussion = false,
  });

  final String id;
  final String name;
  final String abbreviation;

  /// MusicXML standard sound id, e.g. "strings.violin".
  final String? sound;

  /// Staff numbers (@n) that belong to this part, e.g. [3, 4] for a piano.
  final List<int> staffNumbers;

  /// Staves of this part that never contain a note (e.g. an unused divisi staff exported by
  /// Dorico). They are left out of the curated view, like Dorico's "hide empty staves".
  final Set<int> silentStaves;

  /// Uses a percussion clef: drawn without key signatures, like any engraved score.
  final bool isUnpitchedPercussion;

  /// The staves that are actually shown.
  List<int> get shownStaffNumbers => [for (final n in staffNumbers) if (!silentStaves.contains(n)) n];

  InstrumentFamily get family => InstrumentFamily.classify(sound: sound, name: name);
}

class ScoreMetadata {
  const ScoreMetadata({
    required this.title,
    required this.parts,
    required this.tempo,
    required this.activeMeasures,
    this.meters = const [],
    this.pickups = const {},
  });

  final String title;
  final List<ScorePart> parts;

  /// Part id → for each measure (in score order), whether the part plays any note in it.
  /// Drives auto-curation and the activity hints in the timeline.
  final Map<String, List<bool>> activeMeasures;

  /// First `<sound tempo>` in the file that is a tempo (above 0), quarter notes per minute.
  final double? tempo;

  /// The time signature in force in each measure (null before the first one).
  final List<Meter?> meters;

  /// Incomplete measures (`implicit="yes"`): upbeats, and the second half of split bars.
  final Set<int> pickups;

  static ScoreMetadata read(String musicXML) => fromDocument(parse(musicXML));

  static XmlDocument parse(String musicXML) {
    try {
      return XmlDocument.parse(musicXML);
    } on XmlException catch (e) {
      throw EngraveException('This is not a valid MusicXML file (${e.message}).');
    }
  }

  static ScoreMetadata fromDocument(XmlDocument doc) {
    final root = doc.rootElement;
    if (root.name.local == 'score-timewise') {
      throw EngraveException('Timewise MusicXML is not supported yet; export as partwise.');
    }

    final title = [
      ...root.findAllElements('work-title'),
      ...root.findAllElements('movement-title'),
    ].map((e) => e.innerText.trim()).firstWhere((t) => t.isNotEmpty, orElse: () => '');

    final staffCounts = <String, int>{};
    final soundingStaves = <String, Set<int>>{};
    final percussion = <String>{};
    final activeMeasures = <String, List<bool>>{};
    for (final part in root.findElements('part')) {
      final id = part.getAttribute('id') ?? '';
      final staves = part.findAllElements('staves').firstOrNull;
      staffCounts[id] = int.tryParse(staves?.innerText.trim() ?? '') ?? 1;
      if (part.findAllElements('clef').firstOrNull?.getElement('sign')?.innerText.trim() == 'percussion') {
        percussion.add(id);
      }
      soundingStaves[id] = {
        for (final note in part.findAllElements('note'))
          if (note.findElements('rest').isEmpty) int.tryParse(note.getElement('staff')?.innerText.trim() ?? '') ?? 1,
      };
      activeMeasures[id] = [
        for (final measure in part.findElements('measure'))
          measure.findElements('note').any((note) => note.findElements('rest').isEmpty),
      ];
    }

    var next = 1;
    final parts = <ScorePart>[];
    for (final element in root.findAllElements('score-part')) {
      final id = element.getAttribute('id') ?? 'P${parts.length + 1}';
      final count = staffCounts[id] ?? 1;
      String? text(String name) => element.findElements(name).firstOrNull?.innerText.trim();
      parts.add(ScorePart(
        id: id,
        name: prettyInstrumentName(_display(element, 'part-name-display') ?? text('part-name') ?? id),
        abbreviation: prettyInstrumentName(_display(element, 'part-abbreviation-display') ?? text('part-abbreviation') ?? ''),
        sound: element.findAllElements('instrument-sound').firstOrNull?.innerText.trim(),
        staffNumbers: [for (var n = next; n < next + count; n++) n],
        isUnpitchedPercussion: percussion.contains(id),
        silentStaves: {
          // Only for multi-staff parts: a single staff always stays, even if it rests throughout.
          if (count > 1)
            for (var local = 1; local <= count; local++)
              if (!(soundingStaves[id] ?? const {}).contains(local)) next + local - 1,
        },
      ));
      next += count;
    }

    // A tempo of 0 (the schema allows it), "NaN" or "INF" would put every bar at infinity.
    final tempo = root
        .findAllElements('sound')
        .map((e) => double.tryParse(e.getAttribute('tempo') ?? ''))
        .firstWhere((t) => t != null && t.isFinite && t > 0, orElse: () => null);

    // Time signatures from the first part (MusicXML repeats them in every part).
    final meters = <Meter?>[];
    final pickups = <int>{};
    Meter? meter;
    for (final (i, measure) in (root.findElements('part').firstOrNull?.findElements('measure') ?? const <XmlElement>[]).indexed) {
      final time = measure.findElements('attributes').expand((a) => a.findElements('time')).firstOrNull;
      if (time != null) {
        final beats = time.findElements('beats').toList(), types = time.findElements('beat-type').toList();
        meter = Meter.fromMusicXML([
          for (var j = 0; j < math.min(beats.length, types.length); j++) (beats[j].innerText, types[j].innerText),
        ]); // senza misura has neither: null, so quarters
      }
      meters.add(meter);
      if (measure.getAttribute('implicit') == 'yes') pickups.add(i);
    }

    return ScoreMetadata(
      title: title,
      parts: parts,
      tempo: tempo,
      activeMeasures: activeMeasures,
      meters: meters,
      pickups: pickups,
    );
  }
}

/// Text of a MusicXML `<part-name-display>` / `<part-abbreviation-display>`, with
/// `<accidental-text>` turned into ♭ / ♯ / ♮.
String? _display(XmlElement part, String name) {
  final display = part.findElements(name).firstOrNull;
  if (display == null) return null;
  const accidentals = {'flat': '♭', 'sharp': '♯', 'natural': '♮', 'double-flat': '𝄫', 'double-sharp': '𝄪'};
  final text = StringBuffer();
  for (final child in display.childElements) {
    if (child.name.local == 'display-text') text.write(child.innerText);
    if (child.name.local == 'accidental-text') text.write(accidentals[child.innerText.trim()] ?? '');
  }
  final result = text.toString().trim();
  return result.isEmpty ? null : result;
}

/// Engraver-style instrument names: "Clarinet (B Flat) 1" → "Clarinet in B♭ 1",
/// "Horn (F) 2" → "Horn in F 2", "Trumpet in Bb" → "Trumpet in B♭".
String prettyInstrumentName(String raw) {
  String accidental(String? word) => switch (word?.toLowerCase()) {
        'flat' || 'b' => '♭',
        'sharp' || '#' => '♯',
        _ => '',
      };
  final bracketed = RegExp(r'^(.*?)\s*\(([A-G])\s*(flat|sharp|b|#)?\)\s*(.*)$', caseSensitive: false).firstMatch(raw);
  if (bracketed != null) {
    final rest = bracketed[4]!.trim();
    return '${bracketed[1]} in ${bracketed[2]!.toUpperCase()}${accidental(bracketed[3])}${rest.isEmpty ? '' : ' $rest'}';
  }
  return raw.replaceAllMapped(
    RegExp(r'\bin ([A-G])(?:\s*(flat|sharp)|(b|#))(?=\s|$)', caseSensitive: false),
    (m) => 'in ${m[1]!.toUpperCase()}${accidental(m[2] ?? m[3])}',
  );
}

abstract final class ScoreFile {
  /// The most MusicXML a score may unpack to (an .mxl, or the score in a project): many times
  /// the largest real score, and a limit on what a damaged or hostile file can take.
  static const maxBytes = 256 << 20;

  /// Reads .musicxml / .xml directly and unpacks compressed .mxl archives.
  static Future<String> readMusicXML(String path) async => decodeMusicXML(await File(path).readAsBytes());

  /// The same for a file's bytes (e.g. the source score stored inside a project).
  static String decodeMusicXML(Uint8List bytes) {
    if (bytes.length > 4 && bytes[0] == 0x50 && bytes[1] == 0x4B) {
      try {
        return _fromMxl(bytes);
      } on FormatException catch (e) {
        throw EngraveException('The .mxl archive could not be read: ${e.message}');
      }
    }
    if (bytes.length > 2 && ((bytes[0] == 0xFF && bytes[1] == 0xFE) || (bytes[0] == 0xFE && bytes[1] == 0xFF))) {
      throw EngraveException('UTF-16 MusicXML is not supported yet; save the file as UTF-8.');
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  static String _fromMxl(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    String? rootPath;
    final container = archive.findFile('META-INF/container.xml');
    if (container != null) {
      final xml = XmlDocument.parse(utf8.decode(ZipEntries.read(container, limit: 1 << 20), allowMalformed: true));
      rootPath = xml.findAllElements('rootfile').firstOrNull?.getAttribute('full-path');
    }
    rootPath ??= archive.files
        .map((f) => f.name)
        .firstWhere((n) => !n.startsWith('META-INF') && (n.endsWith('.xml') || n.endsWith('.musicxml')),
            orElse: () => '');
    final file = archive.findFile(rootPath);
    if (file == null) throw EngraveException('No score was found inside the .mxl archive.');
    return utf8.decode(ZipEntries.read(file, limit: maxBytes), allowMalformed: true);
  }
}

