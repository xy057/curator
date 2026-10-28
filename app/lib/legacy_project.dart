import 'project_state.dart';

/// Projects and settings files saved before modules (formats 1–26, Curator 0.6.1 and before):
/// one `state` object in project.json (settings.json). Read by bringing the state up to format
/// 26, then dealing its fields out to the modules that hold them now ([ProjectModules]), in
/// their shapes; the modules check them as they read them.
abstract final class LegacyProject {
  /// The last format of one `state`. A project in modules says one past it to the Curators
  /// that read only that ([ProjectArchive.stubVersion]).
  static const lastVersion = 26;

  /// Upgrades a state written by format `n` to format `n + 1`. Frozen: what changes now
  /// changes in a module ([ProjectModule.migrations]).
  static final Map<int, Map<String, Object?> Function(Map<String, Object?>)> _migrations = {
    1: (state) => {...state, 'condensed': const <String>[]}, // condensing came in 2: nothing condensed
    2: (state) => {...state, 'pairs': const <Object?>[]}, // the user's own pairs came in 3: none
    // 3–16: warps, the instruments' order, a region's own transitions, MIDI tempo maps, images,
    // fonts, an image's ink, captions, a caption font, engraving options, not embedding a font,
    // a MIDI map's warps, sections: each came absent meaning none, nothing to change.
    17: (state) => {...state, 'barNumbers': false}, // bar numbers came in 18: off, as made
    // 18–25: name colours, motion, typography, flags, spacers, the playback line's colour, more
    // image formats: absent meaning none (or the app's).
  };

  /// [json], a state written by format [savedVersion], as each module's JSON, by id.
  static Map<String, Map<String, Object?>> modules(Map<String, Object?> json, int savedVersion) {
    var state = json;
    // The first format is 1: a file claiming one before it (-1e9) is read as 1, not stepped
    // up from there.
    for (var v = savedVersion.clamp(1, lastVersion); v < lastVersion; v++) {
      if (_migrations[v] case final migrate?) state = migrate(state);
    }
    final r = JsonReader(state, 'state');
    final fonts = r.map('fonts'), flags = r.map('flags'), curation = r.map('curation'), sync = r.map('sync');
    return {
      'fonts': fonts,
      'engraving': {
        'options': state['engraving'],
        'typography': state['typography'],
        'textDynamics': flags['textDynamics'],
        'rehearsalInRow': flags['rehearsalInRow'],
        'centeredLyrics': flags['centredLyrics'], // the flag's first spelling
      },
      'display': {
        'transition': curation['transition'],
        'scrollFollow': curation['scrollFollow'],
        'motion': state['motion'],
        'barNumbers': state['barNumbers'] ?? true,
        'groupSections': state['groupSections'],
        'playheadColor': state['playheadColor'],
        'colorNames': state['colorNames'],
        'familyColors': state['nameColors'],
      },
      // mediaStorage (to format 20) is left: saves always embed the recording.
      'extensions': {'enabled': state['extensions']},
      'instruments': {
        'order': state['partOrder'],
        'names': _entries(state['partNames'], (p) => p is Map ? [p['name'], p['abbreviation'] ?? ''] : p),
        'sections': _entries(state['sections'], _none),
        'groups': state['nameGroups'],
        'groupOf': _entries(state['nameGroupOf'], _none),
        'condensed': state['condensed'],
        'pairs': state['pairs'],
      },
      'texts': {'edits': state['textEdits']},
      'curation': {
        if (curation['lanes'] case final lanes?)
          'lanes': _entries(lanes, (lane) => _each(lane, (region) => _tuple(region, const ['start', 'end', 'transitionIn', 'transitionOut']))),
      },
      'sync': {
        'leadIn': sync['leadIn'],
        'anchors': _each(sync['anchors'], (anchor) => _tuple(anchor, const ['quarter', 'seconds', 'jumpTo'])),
        'midi': sync['midi'],
      },
      'images': {'patches': state['patches']},
      'captions': {'captions': _each(state['captions'], (caption) => _tuple(caption, const ['start', 'end', 'text']))},
      'spacers': {'vertical': state['spacers'], 'horizontal': state['gaps']},
      'view': r.map('view'),
    };
  }

  /// A section or name group: 'none' was none.
  static Object? _none(Object? value) => value == 'none' ? null : value;

  /// [map]'s values through [f]; anything but a map as it is, for its module to say so.
  static Object? _entries(Object? map, Object? Function(Object? value) f) =>
      map is Map ? {for (final MapEntry(:key, :value) in map.entries) key: f(value)} : map;

  /// [list]'s items through [f]; anything but a list as it is.
  static Object? _each(Object? list, Object? Function(Object? item) f) => list is List ? [for (final item in list) f(item)] : list;

  /// An object's [keys] as a list, in order; anything but an object as it is.
  static Object? _tuple(Object? object, List<String> keys) => object is Map ? [for (final k in keys) object[k]] : object;
}
