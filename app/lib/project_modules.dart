import 'dart:io' show FileSystemException;
import 'dart:typed_data';
import 'dart:ui' show Color, Rect;

import 'package:score_engine/score_engine.dart';

import 'file_names.dart';
import 'image_patch.dart';
import 'project_state.dart';

/// Reads one of a project's files (a module's own, under `<id>/`); null when it has none.
typedef ModuleFileReader = Uint8List? Function(String entry, {required int limit});

/// Adds one of a module's files to a project; [compress]: whether deflating it gains anything.
typedef ModuleFileWriter = void Function(String entry, Uint8List bytes, {bool compress});

/// One part of what a project stores: `modules/<id>.json`, and its files under `<id>/`
/// (`images/<id>`, `fonts/<name>.font`). Each module has a version of its own.
///
/// To change what a module saves: bump its [version] and add a step from the old one to
/// [migrations], so older files still open. A Curator that doesn't know the new version refuses
/// the project, unless the module is [optional]. Something new that has no place in an existing
/// module is a new module: a project without it (an older one) reads as having none.
abstract class ProjectModule {
  const ProjectModule(this.id, {this.version = 1, this.optional = false});

  /// Its file's name (`modules/<id>.json`) and its files' folder: lower-case letters, digits and
  /// `-`; never `score`, `media` or `modules`.
  final String id;

  /// The version [write] writes.
  final int version;

  /// Whether a Curator that can't read it (one too old) may open the project without it, and
  /// keep it as it is ([ForeignModule]): nothing the score shows or plays depends on it.
  final bool optional;

  /// Upgrades this module's JSON written by version `n` to version `n + 1`, by `n`.
  Map<int, Map<String, Object?> Function(Map<String, Object?>)> get migrations => const {};

  /// What it saves of [state], adding its files to [files].
  Map<String, Object?> write(ProjectState state, ModuleFileWriter files);

  /// [state] with what [json] holds (empty when the project has no such module), its files
  /// from [files]. Throws a [FormatException] that names the damaged field.
  ProjectState read(JsonReader json, ProjectState state, ModuleFileReader files);
}

/// The modules a project is saved in, in the order they are read.
abstract final class ProjectModules {
  static const fonts = _Fonts();
  static const engraving = _Engraving();
  static const display = _Display();
  static const extensions = _Extensions();
  static const instruments = _Instruments();
  static const texts = _Texts();
  static const curation = _Curation();
  static const sync = _Sync();
  static const takes = _Takes();
  static const images = _Images();
  static const captions = _Captions();
  static const spacers = _Spacers();
  static const view = _View();

  /// Every module: a project (.ccs).
  static const List<ProjectModule> all = [
    fonts, engraving, display, extensions, instruments, texts, curation, sync, takes, images, captions, spacers, view, //
  ];

  /// The score-wide settings, what a page of Project Settings sets for the whole score: a
  /// settings file (.ccf).
  static const List<ProjectModule> settings = [fonts, engraving, display, extensions];

  /// The most an added music font, or its metadata, may unpack to.
  static const maxFontBytes = 64 << 20;

  /// [state] as [modules] save it, by id, leaving out their files: to compare two states.
  static Map<String, Object?> toJson(ProjectState state, [List<ProjectModule> modules = all]) => {
        for (final m in modules) m.id: m.write(state, (entry, bytes, {compress = true}) {}),
      };
}

FormatException _damaged(String what) => FormatException('The project is damaged: $what');

/// "#A86B3C".
String _hex(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

/// "#A86B3C"; null for anything else.
Color? _color(Object? hex) => switch (hex) {
      final String s when RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(s) => Color(0xFF000000 | int.parse(s.substring(1), radix: 16)),
      _ => null,
    };

/// [r]'s [key], read by [fromJson], saying which of its fields is damaged; null when absent.
T? _nested<T>(JsonReader r, String key, T Function(Map<String, Object?>) fromJson) {
  if (r.isAbsent(key)) return null;
  try {
    return fromJson(r.map(key));
  } on FormatException catch (e) {
    throw _damaged('${r.where}.$key.${e.message}');
  }
}

/// A part's section or name group: a name, or null for none.
String? _nameOrNone(Object? value, String where) => switch (value) {
      null => null,
      final String n when n.trim().isNotEmpty => n,
      _ => throw _damaged('$where is not a name.'),
    };

/// The music and text fonts, the captions' font, and the added music font's file and metadata
/// (`fonts/<name>.font`, `.json`; only when it is embedded).
final class _Fonts extends ProjectModule {
  const _Fonts() : super('fonts');

  @override
  Map<String, Object?> write(ProjectState state, ModuleFileWriter files) {
    final EditState(:fonts, :captionFont, :embedFont) = state.edits;
    // A missing font can't be embedded: it is looked for again next time.
    final embedded = embedFont && !fonts.music.isMissing;
    if (fonts.music.file case final file? when embedded) {
      final entry = 'fonts/${safeFileName(fonts.music.name)}';
      files('$entry.font', file);
      if (fonts.music.metadata case final metadata?) files('$entry.json', metadata);
    }
    return {'music': fonts.music.name, 'text': fonts.text, 'caption': ?captionFont, 'embed': embedded};
  }

  @override
  ProjectState read(JsonReader r, ProjectState state, ModuleFileReader files) {
    final music = r.string('music'), text = r.string('text'), caption = r.string('caption');
    if (text != null && text.trim().isEmpty) throw _damaged('${r.where}.text is empty.');
    if (caption != null && caption.trim().isEmpty) throw _damaged('${r.where}.caption is empty.');
    final embed = r.boolean('embed') ?? true;
    MusicFont added(String name) {
      final entry = 'fonts/${safeFileName(name)}';
      return switch (files('$entry.font', limit: ProjectModules.maxFontBytes)) {
        null when !embed => MusicFont.missing(name), // looked for when it opens
        null => throw _damaged('the music font $name is missing.'),
        final file => MusicFont.added(family: name, file: file, metadata: files('$entry.json', limit: ProjectModules.maxFontBytes)),
      };
    }

    return state.copyWith(
      edits: state.edits.copyWith(
        fonts: ScoreFonts(
          music: music == null ? MusicFont.bravura : MusicFont.bundledNamed(music) ?? added(music),
          text: text ?? TextFonts.academico,
        ),
        captionFont: caption,
        embedFont: embed,
      ),
    );
  }
}

/// The engraving options over the app's, the typography, and the flags that change the engraving.
final class _Engraving extends ProjectModule {
  const _Engraving() : super('engraving');

  @override
  Map<String, Object?> write(ProjectState state, ModuleFileWriter files) {
    final EditState(:engraving, :typography, :textDynamics, :rehearsalInRow, :centeredLyrics) = state.edits;
    return {
      'options': engraving.toJson(),
      'typography': ?typography?.toJson(),
      'textDynamics': ?textDynamics,
      'rehearsalInRow': ?rehearsalInRow,
      'centeredLyrics': ?centeredLyrics,
    };
  }

  @override
  ProjectState read(JsonReader r, ProjectState state, ModuleFileReader files) => state.copyWith(
        edits: state.edits.copyWith(
          // An option this version doesn't know (or no longer offers) is left out, as the app's are.
          engraving: EngravingOptions.fromJson(r.map('options'), keepDefault: true),
          typography: _nested(r, 'typography', ScoreTypography.fromJson),
          textDynamics: r.boolean('textDynamics'),
          rehearsalInRow: r.boolean('rehearsalInRow'),
          centeredLyrics: r.boolean('centeredLyrics'),
        ),
      );
}

/// How the score is shown over the whole piece: transitions, scrolling, motion, bar numbers,
/// sections, the playback line, the names' colours.
final class _Display extends ProjectModule {
  const _Display() : super('display');

  /// The longest a staff may take to glide in or out, seconds (far more than any dialog offers).
  static const maxTransition = 60.0;

  @override
  Map<String, Object?> write(ProjectState state, ModuleFileWriter files) {
    final e = state.edits;
    return {
      'transition': ?e.transition,
      'scrollFollow': ?e.scrollFollow,
      'motion': ?e.motion?.toJson(),
      'barNumbers': e.barNumbers,
      'groupSections': e.groupSections,
      if (e.playheadColor case final color?) 'playheadColor': _hex(color),
      'colorNames': e.colorNames,
      if (e.nameColors.isNotEmpty) 'familyColors': {for (final MapEntry(key: f, value: c) in e.nameColors.entries) f.name: _hex(c)},
    };
  }

  @override
  ProjectState read(JsonReader r, ProjectState state, ModuleFileReader files) => state.copyWith(
        edits: state.edits.copyWith(
          transition: switch (r.number('transition')) {
            final s? when s < 0 || s > maxTransition => throw _damaged('${r.where}.transition is not a length of time.'),
            final s => s,
          },
          scrollFollow: switch (r.number('scrollFollow')) {
            final f? when f < 0 || f > 1 => throw _damaged('${r.where}.scrollFollow is not between 0 and 1.'),
            final f => f,
          },
          motion: _nested(r, 'motion', ScoreMotion.fromJson),
          barNumbers: r.boolean('barNumbers') ?? true,
          groupSections: r.boolean('groupSections') ?? false,
          playheadColor: switch (r.string('playheadColor')) {
            null => null,
            final hex => _color(hex) ?? (throw _damaged('${r.where}.playheadColor is not a colour.')),
          },
          colorNames: r.boolean('colorNames') ?? false,
          // A family this version doesn't know is left out.
          nameColors: {
            for (final MapEntry(key: name, value: hex) in r.map('familyColors').entries)
              ?InstrumentFamily.values.asNameMap()[name]: _color(hex) ?? (throw _damaged('${r.where}.familyColors.$name is not a colour.')),
          },
        ),
      );
}

/// The extensions this project turned on or off, by id.
final class _Extensions extends ProjectModule {
  const _Extensions() : super('extensions');

  @override
  Map<String, Object?> write(ProjectState state, ModuleFileWriter files) => {'enabled': state.edits.extensions};

  @override
  ProjectState read(JsonReader r, ProjectState state, ModuleFileReader files) => state.copyWith(
        edits: state.edits.copyWith(
          // One this version doesn't know is kept, so a newer version's choice survives a save here.
          extensions: Map.unmodifiable({
            for (final MapEntry(key: name, value: on) in r.map('enabled').entries)
              name: on is bool ? on : throw _damaged('${r.where}.enabled.$name is not on or off.'),
          }),
        ),
      );
}

/// What the user set for each instrument, by part id: order, names, sections, name groups, pairs.
final class _Instruments extends ProjectModule {
  const _Instruments() : super('instruments');

  @override
  Map<String, Object?> write(ProjectState state, ModuleFileWriter files) {
    final e = state.edits;
    return {
      'order': e.partOrder,
      'names': {for (final MapEntry(key: id, value: p) in e.partNames.entries) id: [p.name, p.abbreviation]},
      'sections': e.sections,
      'groups': [
        for (final g in e.nameGroups) {'id': g.id, 'name': g.name, 'color': _hex(g.color)},
      ],
      'groupOf': e.nameGroupOf,
      'condensed': [...e.condensed],
      'pairs': [for (final p in e.pairs) p.partIds],
    };
  }

  @override
  ProjectState read(JsonReader r, ProjectState state, ModuleFileReader files) {
    String text(Object? id, String where) => id is String ? id : throw _damaged('$where is not text.');
    return state.copyWith(
      edits: state.edits.copyWith(
        partOrder: [for (final (i, id) in r.list('order').indexed) text(id, '${r.where}.order[$i]')],
        partNames: {
          for (final MapEntry(key: id, value: name) in r.map('names').entries)
            id: switch (name) {
              [final String name, final String abbreviation] => (name: name, abbreviation: abbreviation),
              _ => throw _damaged('${r.where}.names.$id is not a name and an abbreviation.'),
            },
        },
        sections: {
          for (final MapEntry(key: id, value: s) in r.map('sections').entries) id: _nameOrNone(s, '${r.where}.sections.$id'),
        },
        nameGroups: [
          for (final (i, g) in r.list('groups').indexed)
            () {
              final group = JsonReader(g, '${r.where}.groups[$i]');
              final id = group.string('id', required: true)!;
              if (!id.startsWith('group-')) throw _damaged('${group.where}.id is not a group of the user\'s.');
              return NameGroup(
                id,
                group.string('name', required: true)!,
                _color(group.string('color', required: true)) ?? (throw _damaged('${group.where}.color is not a colour.')),
              );
            }(),
        ],
        nameGroupOf: {
          for (final MapEntry(key: id, value: g) in r.map('groupOf').entries) id: _nameOrNone(g, '${r.where}.groupOf.$id'),
        },
        condensed: {for (final (i, id) in r.list('condensed').indexed) text(id, '${r.where}.condensed[$i]')},
        pairs: [
          for (final (i, pair) in r.list('pairs').indexed)
            switch (pair) {
              [final String a, final String b] when a != b => PlayerPair(a, b),
              _ => throw _damaged('${r.where}.pairs[$i] is not two part ids.'),
            },
        ],
      ),
    );
  }
}

/// Score texts the user changed: text id → new text ('' removes it).
final class _Texts extends ProjectModule {
  const _Texts() : super('texts');

  @override
  Map<String, Object?> write(ProjectState state, ModuleFileWriter files) => {'edits': state.edits.textEdits};

  @override
  ProjectState read(JsonReader r, ProjectState state, ModuleFileReader files) => state.copyWith(
        edits: state.edits.copyWith(textEdits: {
          for (final MapEntry(key: id, value: text) in r.map('edits').entries)
            id: text is String ? text : throw _damaged('${r.where}.edits.$id is not text.'),
        }),
      );
}

/// When each instrument is shown: its regions, `[start, end]` or `[start, end, in, out]` in
/// seconds of the score, the last two a transition of its own (null: the project's).
final class _Curation extends ProjectModule {
  const _Curation() : super('curation');

  @override
  Map<String, Object?> write(ProjectState state, ModuleFileWriter files) => {
        if (state.edits.lanes case final lanes?)
          'lanes': {
            for (final MapEntry(key: id, value: lane) in lanes.entries)
              id: [
                for (final r in lane) regionJson(r),
              ],
          },
      };

  /// A region as saved: `[start, end]`, or `[start, end, in, out]` with transitions of its own.
  static List<Object?> regionJson(Region r) =>
      [r.start, r.end, if (r.transitionIn != null || r.transitionOut != null) ...[r.transitionIn, r.transitionOut]];

  @override
  ProjectState read(JsonReader r, ProjectState state, ModuleFileReader files) => state.copyWith(
        // None saved: filled from where each part plays.
        edits: state.edits.copyWith(
          lanes: r.isAbsent('lanes')
              ? null
              : {
                  for (final MapEntry(key: id, value: lane) in r.map('lanes').entries)
                    id: [
                      for (final (i, region) in JsonReader.listAt(lane, '${r.where}.lanes.$id').indexed)
                        readRegion(region, '${r.where}.lanes.$id[$i]'),
                    ],
                },
        ),
      );

  static Region readRegion(Object? json, String where) {
    final [start!, end!, transitionIn, transitionOut] = JsonReader.numbers(json, where, 4, optional: 2);
    if (start < 0) throw _damaged('$where starts before the score.');
    if (end < start) throw _damaged('$where ends before it starts.');
    for (final s in [transitionIn, transitionOut]) {
      if (s != null && (s < 0 || s > _Display.maxTransition)) throw _damaged('$where has a transition that is not a length of time.');
    }
    return Region(start, end, transitionIn: transitionIn, transitionOut: transitionOut);
  }
}

/// The tempo track: the start before any anchor, the anchors (`[quarter, seconds]`, or
/// `[quarter, seconds, jumpTo]` for a warp), and the MIDI tempo map followed instead of them.
final class _Sync extends ProjectModule {
  const _Sync() : super('sync');

  @override
  Map<String, Object?> write(ProjectState state, ModuleFileWriter files) {
    final EditState(:leadIn, :anchors, :midi) = state.edits;
    return toJson(leadIn, anchors, midi);
  }

  /// A sync as saved (the state's, or a take's, [_Takes]).
  static Map<String, Object?> toJson(double leadIn, List<SyncAnchor> anchors, MidiTempoMap? midi) => {
        'leadIn': leadIn,
        'anchors': [
          for (final a in anchors) [a.quarter, a.seconds, ?a.jumpTo],
        ],
        if (midi != null)
          'midi': {
            'name': midi.name,
            'tempos': [for (final t in midi.tempos) [t.quarter, t.quartersPerMinute]],
            if (midi.warps.isNotEmpty) 'warps': [for (final w in midi.warps) [w.at, w.jumpTo]],
          },
      };

  @override
  ProjectState read(JsonReader r, ProjectState state, ModuleFileReader files) {
    final (:leadIn, :anchors, :midi) = fromJson(r);
    return state.copyWith(edits: state.edits.copyWith(leadIn: leadIn, anchors: anchors, midi: midi));
  }

  /// A sync saved by [toJson].
  static ({double leadIn, List<SyncAnchor> anchors, MidiTempoMap? midi}) fromJson(JsonReader r) => (
        leadIn: r.number('leadIn') ?? 0,
        anchors: [
          for (final (i, anchor) in r.list('anchors').indexed)
            switch (JsonReader.numbers(anchor, '${r.where}.anchors[$i]', 3, optional: 1)) {
              [final quarter!, final seconds!, final jumpTo] => SyncAnchor(quarter, seconds, jumpTo: jumpTo),
              _ => throw StateError('unreachable'),
            },
        ]..sort((a, b) => a.seconds.compareTo(b.seconds)),
        midi: r.isAbsent('midi') ? null : _midi(r.child('midi')),
      );

  static MidiTempoMap _midi(JsonReader r) {
    final tempos = <MidiTempo>[
      for (final (i, t) in r.list('tempos').indexed)
        switch (t) {
          [final num q, final num qpm] when q >= 0 && qpm > 0 && q.isFinite && qpm.isFinite =>
            (quarter: q.toDouble(), quartersPerMinute: qpm.toDouble()),
          _ => throw _damaged('${r.where}.tempos[$i] is not a quarter and a tempo.'),
        },
    ];
    for (var i = 0; i < tempos.length; i++) {
      if (i == 0 ? tempos[i].quarter != 0 : tempos[i].quarter <= tempos[i - 1].quarter) {
        throw _damaged('${r.where}.tempos are out of order.');
      }
    }
    if (tempos.isEmpty) throw _damaged('${r.where}.tempos is empty.');
    final warps = <MidiWarp>[
      for (final (i, w) in r.list('warps').indexed)
        switch (w) {
          [final num at, final num jumpTo] when at > 0 && jumpTo >= 0 && at.isFinite && jumpTo.isFinite =>
            (at: at.toDouble(), jumpTo: jumpTo.toDouble()),
          _ => throw _damaged('${r.where}.warps[$i] is not a quarter and where it jumps to.'),
        },
    ];
    return MidiTempoMap(r.string('name') ?? '', tempos, warps: warps);
  }
}

/// The recordings of the score ([EditState.takes]), top lane first: each one's id, name, lane
/// (regions, as the curation's), and (but the focus's, in [_Sync]) sync; which is the focus; the
/// crossfade. The files themselves are the project's (`media/`). Optional: a Curator from before
/// keeps the focus's recording, with its sync.
final class _Takes extends ProjectModule {
  const _Takes() : super('takes', optional: true);

  @override
  Map<String, Object?> write(ProjectState state, ModuleFileWriter files) {
    final EditState(:takes, :focus, :crossfade) = state.edits;
    return {
      'focus': ?focus,
      'crossfade': ?crossfade,
      'takes': [
        for (final t in takes)
          {
            'id': t.id,
            'label': t.label,
            'regions': [for (final r in t.regions) _Curation.regionJson(r)],
            if (t.id != focus) ..._Sync.toJson(t.leadIn, t.anchors, t.midi),
          },
      ],
    };
  }

  @override
  ProjectState read(JsonReader r, ProjectState state, ModuleFileReader files) {
    final takes = <Take>[];
    for (final (i, value) in r.list('takes').indexed) {
      final t = JsonReader(value, '${r.where}.takes[$i]');
      final id = t.string('id', required: true)!, label = t.string('label') ?? '';
      if (!isTakeId(id) || takes.any((other) => other.id == id)) throw _damaged('${t.where}.id is not a take of its own.');
      final (:leadIn, :anchors, :midi) = _Sync.fromJson(t);
      final regions = [
        for (final (j, region) in t.list('regions').indexed) _Curation.readRegion(region, '${t.where}.regions[$j]'),
      ];
      takes.add(Take(id, label, regions: regions, anchors: anchors, leadIn: leadIn, midi: midi));
    }
    final focus = r.string('focus');
    if (focus != null && !takes.any((t) => t.id == focus)) throw _damaged('${r.where}.focus is not one of its takes.');
    final crossfade = r.number('crossfade');
    if (crossfade != null && (crossfade < 0 || crossfade > _Display.maxTransition)) {
      throw _damaged('${r.where}.crossfade is not a length of time.');
    }
    return state.copyWith(edits: state.edits.copyWith(takes: takes, focus: focus, crossfade: crossfade));
  }

  /// `take-1`, `take-2`…: safe in a file's name.
  static bool isTakeId(String id) => RegExp(r'^take-[1-9][0-9]{0,5}$').hasMatch(id);
}

/// Images on the score (Attach Image), bottom to top, and each one's file, byte for byte, as
/// `images/<id>`: only those on the score (Undo keeps the rest while the project is open).
final class _Images extends ProjectModule {
  const _Images() : super('images');

  /// Whether image [id]'s file is compressed already, so deflating it gains nothing (an SVG,
  /// BMP or ICO isn't).
  static bool _packed(String id) => !const ['svg', 'bmp', 'ico'].contains(id.split('.').last.toLowerCase());

  @override
  Map<String, Object?> write(ProjectState state, ModuleFileWriter files) {
    final patches = state.edits.patches;
    for (final id in {for (final p in patches) p.image}) {
      final image = state.images[id];
      if (image == null || !PatchImage.isId(id)) throw FileSystemException('An image on the score is missing', id);
      files('images/$id', image.bytes, compress: !_packed(id));
    }
    return {
      'patches': [
        for (final p in patches)
          {
            'image': p.image,
            'quarter': p.quarter,
            'top': p.top,
            'width': p.width,
            'height': p.height,
            if (p.crop != ImagePatch.full) 'crop': [p.crop.left, p.crop.top, p.crop.right, p.crop.bottom],
            if (p.ink) 'ink': true,
          },
      ],
    };
  }

  @override
  ProjectState read(JsonReader r, ProjectState state, ModuleFileReader files) {
    final images = <String, PatchImage>{};
    final patches = [
      for (final (i, patch) in r.list('patches').indexed) _patch(JsonReader(patch, '${r.where}.patches[$i]'), images, files),
    ];
    return state.copyWith(edits: state.edits.copyWith(patches: patches), images: images);
  }

  /// One patch, its image read into [images] (once, however many patches show it).
  static ImagePatch _patch(JsonReader r, Map<String, PatchImage> images, ModuleFileReader files) {
    final image = r.string('image', required: true)!;
    // Saved as images/<id> as it is: a name that would change there (a/b.png, a:b.png) would
    // leave the patch without its image when opened again.
    if (!PatchImage.isId(image)) throw _damaged('the image of ${r.where} is not a file name.');
    images[image] ??= switch ((PatchImage.kindOfId(image), files('images/$image', limit: PatchImage.maxBytes))) {
      (final kind?, final bytes?) => PatchImage(image, kind, bytes),
      _ => throw _damaged('the image of ${r.where} is missing.'),
    };
    double size(String key) {
      final v = r.number(key, required: true)!;
      if (!(v > 0)) throw _damaged('${r.where}.$key is not a size.');
      return v;
    }

    final crop = switch (r.list('crop')) {
      [] => ImagePatch.full,
      [final num l, final num t, final num rt, final num b] when 0 <= l && l < rt && rt <= 1 && 0 <= t && t < b && b <= 1 =>
        Rect.fromLTRB(l.toDouble(), t.toDouble(), rt.toDouble(), b.toDouble()),
      _ => throw _damaged('${r.where}.crop is not a part of the image.'),
    };
    return ImagePatch(
      image: image,
      quarter: r.number('quarter', required: true)!,
      top: r.number('top', required: true)!,
      width: size('width'),
      height: size('height'),
      crop: crop,
      ink: r.boolean('ink') ?? false,
    );
  }
}

/// Captions under the score (Captions), `[start, end, text]`, in the order they were added.
final class _Captions extends ProjectModule {
  const _Captions() : super('captions');

  @override
  Map<String, Object?> write(ProjectState state, ModuleFileWriter files) => {
        'captions': [
          for (final c in state.edits.captions) [c.start, c.end, c.text],
        ],
      };

  @override
  ProjectState read(JsonReader r, ProjectState state, ModuleFileReader files) => state.copyWith(
        edits: state.edits.copyWith(
          // Kept apart (those saved before captions couldn't overlap show as they did).
          captions: separateCaptions([
            for (final (i, caption) in r.list('captions').indexed)
              switch (caption) {
                [final num start, final num end, final String text] when start.abs() <= JsonReader.maxNumber && end.abs() <= JsonReader.maxNumber =>
                  start < 0
                      ? throw _damaged('${r.where}.captions[$i] starts before the score.')
                      : end <= start
                          ? throw _damaged('${r.where}.captions[$i] ends before it starts.')
                          : Caption(start.toDouble(), end.toDouble(), text),
                _ => throw _damaged('${r.where}.captions[$i] is not a start, an end and a text.'),
              },
          ]),
        ),
      );
}

/// Spacers (Attach Image): vertical ones, staves of nothing, in the order they were added;
/// horizontal ones, blanks between beats, in the score's order.
final class _Spacers extends ProjectModule {
  const _Spacers() : super('spacers');

  @override
  Map<String, Object?> write(ProjectState state, ModuleFileWriter files) => {
        'vertical': [
          for (final s in state.edits.spacers)
            {
              'id': s.id,
              if (s.key != SpacerKey.c) 'key': s.key.name,
              if (s.frozen) 'frozen': true,
              if (s.lines) 'lines': true,
              'height': s.height,
            },
        ],
        'horizontal': [
          for (final g in state.edits.gaps) {'bar': g.bar, 'offset': g.offset, 'length': g.length, 'width': g.width},
        ],
      };

  @override
  ProjectState read(JsonReader r, ProjectState state, ModuleFileReader files) => state.copyWith(
        edits: state.edits.copyWith(
          spacers: [
            for (final (i, spacer) in r.list('vertical').indexed) _vertical(JsonReader(spacer, '${r.where}.vertical[$i]')),
          ],
          gaps: [
            for (final (i, gap) in r.list('horizontal').indexed) _horizontal(JsonReader(gap, '${r.where}.horizontal[$i]')),
          ]..sort((a, b) => a.bar != b.bar ? a.bar.compareTo(b.bar) : a.offset.compareTo(b.offset)),
        ),
      );

  static VerticalSpacer _vertical(JsonReader r) {
    final id = r.string('id', required: true)!;
    if (!Spacers.isSpacer(id)) throw _damaged('${r.where}.id is not a spacer\'s.');
    final height = r.number('height') ?? VerticalSpacer.defaultHeight;
    if (height < VerticalSpacer.minHeight || height > VerticalSpacer.maxHeight) throw _damaged('${r.where}.height is out of range.');
    return VerticalSpacer(
        id: id, key: SpacerKey.named(r.string('key')), frozen: r.boolean('frozen') ?? false, lines: r.boolean('lines') ?? false, height: height);
  }

  static HorizontalSpacer _horizontal(JsonReader r) {
    final bar = r.number('bar', required: true)!, offset = r.number('offset', required: true)!;
    final width = r.number('width') ?? HorizontalSpacer.defaultWidth;
    final length = r.number('length') ?? HorizontalSpacer.defaultLength;
    if (bar < 0 || bar != bar.roundToDouble() || offset < 0) throw _damaged('${r.where} is not in a bar.');
    if (length < HorizontalSpacer.minLength - 1e-9) throw _damaged('${r.where}.length is too short.');
    if (width < HorizontalSpacer.minWidth || width > HorizontalSpacer.maxWidth) throw _damaged('${r.where}.width is out of range.');
    return HorizontalSpacer(bar: bar.toInt(), offset: offset, length: length, width: width);
  }
}

/// How the editor was left: zoom, grid, snapping, the playhead. Optional: a Curator that can't
/// read it opens the project in its own view.
final class _View extends ProjectModule {
  const _View() : super('view', optional: true);

  @override
  Map<String, Object?> write(ProjectState state, ModuleFileWriter files) => {
        'staffSpace': ?state.view.staffSpace,
        'grid': ?state.view.grid?.name,
        'snapTapsToOnsets': ?state.view.snapTapsToOnsets,
        'time': ?state.view.time,
      };

  @override
  ProjectState read(JsonReader r, ProjectState state, ModuleFileReader files) => state.copyWith(
        view: ViewState(
          staffSpace: r.number('staffSpace'),
          grid: switch (r.string('grid')) {
            null => null,
            final name => SyncGrid.values.asNameMap()[name] ?? (throw _damaged('${r.where}.grid "$name" is unknown.')),
          },
          snapTapsToOnsets: r.boolean('snapTapsToOnsets'),
          time: r.number('time'),
        ),
      );
}
