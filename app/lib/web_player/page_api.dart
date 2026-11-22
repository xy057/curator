import 'dart:ui' show PlatformDispatcher, Brightness, Color;

import 'package:flutter/foundation.dart';
import 'package:score_engine/score_engine.dart';

import '../app_colors.dart' show ScorePaper;
import '../key_bindings.dart';
import '../web_page.dart';
import 'playing_page.dart';

/// A button a plugin put on the transport.
typedef PageButton = ({String id, String title, String? icon, String? text, bool checked, bool enabled});

/// A row a plugin put in Options, under its [group] (the plugin's name): a "switch" (its
/// [value] a bool), a "choice" among [options] (its [value] one of theirs), or an "action".
typedef PageOption = ({String id, String group, String type, String label, Object? value, List<({String value, String label})> options, bool enabled});

/// What a page's plugins ask of the player, each by its name ([call]), and what they have added
/// to the page, which [PagePlayer] shows: it tells its listeners when that is other than it was.
/// Everything in and out is JSON (numbers, texts, lists, maps), so the same answers serve the
/// browser's JavaScript (`plugin_host.dart`) and a test. The API as plugins see it is
/// `curator-web.d.ts`; `web_plugins/host.ts` makes it of these.
///
/// Times are told and taken in seconds from the start of what is heard ([PlayingPage.now]).
class PageApi extends ChangeNotifier {
  PageApi(this.player);

  final PlayingPage player;

  // MARK: What plugins added

  List<PageButton> get buttons => _buttons;
  List<PageButton> _buttons = const [];

  List<PageOption> get options => _options;
  List<PageOption> _options = const [];

  /// The keys plugins took, each with the id it is told by.
  Map<KeyChord, String> get keys => _keys;
  Map<KeyChord, String> _keys = const {};

  /// The room plugins' panels take at the window's edges: left, top, right, bottom, points.
  List<double> get insets => _insets;
  List<double> _insets = const [0, 0, 0, 0];

  /// A line to show at the page's foot for a moment, and Options to open: the player's to do.
  void Function(String text)? onMessage;
  VoidCallback? onShowOptions;

  /// The viewer pressed button [id], changed option [id] to [value], pressed the key told by [id].
  void pressed(String id) => player.listener?.call('ui.press', {'id': id});

  void changed(String id, Object? value) {
    _options = [for (final o in _options) o.id == id ? _with(o, value: value) : o];
    notifyListeners();
    player.listener?.call('ui.change', {'id': id, 'value': value});
  }

  void keyed(String id) => player.listener?.call('ui.key', {'id': id});

  static PageOption _with(PageOption o, {required Object? value}) =>
      (id: o.id, group: o.group, type: o.type, label: o.label, value: value, options: o.options, enabled: o.enabled);

  // MARK: What plugins ask

  /// Does [method] with [args], and gives its answer. An [ArgumentError] says what is wrong with
  /// a call: no such method, an argument that isn't what it takes.
  Object? call(String method, [List<Object?> args = const []]) {
    final a = _Args(method, args);
    final p = player, score = p.loaded.score, timeline = p.scene.timeline, start = p.heard.start;
    switch (method) {
      case 'page':
        return {
          'title': p.page.title,
          'firstBar': p.page.firstBar,
          'lastBar': p.page.lastBar,
          'ratio': p.page.ratio,
          'recordings': [
            for (final r in p.page.recordings)
              {'label': r.label, 'duration': r.end - r.start, 'musicEnd': r.musicEnd - r.start, 'sound': r.audio != null},
          ],
          'player': {'release': p.page.release, 'build': p.page.build},
          'open': {
            'recording': p.page.recording.open,
            'speed': p.page.speed.open,
            'captions': p.page.captions.open,
            'barNumbers': p.page.barNumbers.open,
            'view': p.page.view.open,
            'instruments': p.page.instruments.open,
          },
          'available': [for (final s in p.available) s.name],
        };

      // What is heard.
      case 'playback.playing':
        return p.playing;
      case 'playback.time':
        return p.now;
      case 'playback.duration':
        return p.duration;
      case 'playback.musicEnd':
        return p.heard.musicEnd - start;
      case 'playback.play':
        p.play();
      case 'playback.pause':
        p.pause();
      case 'playback.seek':
        p.seek(start + a.number(0));
      case 'playback.speed':
        return p.speed;
      case 'playback.setSpeed':
        p.speed = a.number(0);
      case 'playback.recording':
        return p.recording;
      case 'playback.setRecording':
        final index = a.integer(0);
        if (index < 0 || index >= p.page.recordings.length) throw ArgumentError('$method: the page has no recording $index');
        p.pick(index);
      case 'playback.volume':
        return p.volume;
      case 'playback.setVolume':
        p.volume = a.number(0);
      case 'playback.muted':
        return p.muted;
      case 'playback.setMuted':
        p.muted = a.boolean(0);

      // What shows.
      case 'view.shows':
        return p.shows.name;
      case 'view.setShows':
        final shows = a.named(0, PageShows.values);
        if (!p.available.contains(shows)) throw ArgumentError('$method: the page has no ${shows.name} to show');
        p.shows = shows;
      case 'view.captions':
        return p.captions;
      case 'view.setCaptions':
        p.captions = a.boolean(0);
      case 'view.barNumbers':
        return p.barNumbers;
      case 'view.setBarNumbers':
        p.barNumbers = a.boolean(0);
      case 'view.instruments':
        return [
          for (final part in score.metadata.parts)
            {'id': part.id, 'name': p.loaded.edits.partNames[part.id]?.name ?? part.name, 'shown': (p.shown[part.id] ?? PartShown.curated).name},
        ];
      case 'view.show':
        final id = a.text(0);
        if (!score.metadata.parts.any((part) => part.id == id)) throw ArgumentError('$method: the score has no part $id');
        p.show(id, a.named(1, PartShown.values));
      case 'view.frame':
        return PlayingPage.rectJson(p.frame);
      case 'view.theme':
        return theme;
      case 'view.quarterAt':
        return p.scrolling?.quarterAtFrameX(a.number(0) / p.frameScale, p.time.value, p.frame.size / p.frameScale);
      case 'view.xOf':
        final scene = p.scrolling;
        return scene == null ? null : scene.frameXAtQuarter(a.number(0), p.time.value, p.frame.size / p.frameScale) * p.frameScale;

      // The score, and the performance heard.
      case 'score.title':
        return score.metadata.title;
      case 'score.quarters':
        return p.beats.totalQuarters;
      case 'score.bars':
        return [for (var i = 0; i + 1 < p.beats.measureStarts.length; i++) p.barJson(i)];
      case 'score.barAt':
        return p.barJson(p.beats.measureAt(a.number(0)).clamp(0, p.beats.measureStarts.length - 2));
      case 'score.beatAt':
        final beat = p.beats.beatAt(a.number(0));
        return {'start': beat.start, 'end': beat.end};
      case 'score.format':
        return p.beats.format(a.number(0), compact: a.booleanOr(1, false));
      case 'score.parse':
        return p.beats.parse(a.text(0));
      case 'score.seconds':
        final pass = a.integerOr(1, 0);
        if (pass < 0 || pass >= timeline.passes.length) throw ArgumentError('$method: the score is played through ${timeline.passes.length} times, not ${pass + 1}');
        return timeline.secondsAtQuarter(a.number(0), pass: pass) - start;
      case 'score.quarter':
        return timeline.quarterAtSeconds(start + a.number(0));
      case 'score.passAt':
        return timeline.passAt(start + a.number(0));
      case 'score.passes':
        return [
          for (final (k, pass) in timeline.passes.indexed)
            {
              'from': pass.start,
              'to': pass.end,
              'starts': timeline.secondsAtQuarter(pass.start, pass: k) - start,
              'ends': timeline.secondsAtQuarter(pass.end, pass: k) - start,
            },
        ];
      case 'score.spans':
        final end = a.numberOr(1);
        return [
          for (final s in markerSpans(a.numbers(0), timeline, end: end == null ? null : start + end))
            {'index': s.marker, 'from': s.start - start, 'to': s.end - start},
        ];
      case 'score.rehearsalMarks':
        final starts = score.timeline.measureStarts;
        return [
          for (final text in score.texts)
            if (text.kind == ScoreTextKind.rehearsal && text.measure >= 0 && text.measure < starts.length - 1)
              {'at': starts[text.measure], 'bar': text.measure, 'text': score.currentText(text)},
        ];
      case 'score.parts':
        return [
          for (final part in score.metadata.parts) {'id': part.id, 'name': part.name, 'staves': part.staffNumbers.length},
        ];
      case 'score.notes':
        final part = a.textOr(0);
        if (!score.hasNotes) return const <Object?>[];
        final notes = <Map<String, Object?>>[];
        // Each note once: one a tie carries on is its note going on.
        final open = <(String, int, String, int), Map<String, Object?>>{};
        for (final n in soundingNotes(score.musicXML, score.timeline.measureStarts)) {
          if (part != null && n.partId != part) continue;
          final at = (n.partId, n.staff, n.voice, n.midi);
          if (open[at] case final note? when n.tied && ((note['end'] as double) - n.start).abs() < 1e-6) {
            note['end'] = n.end;
            continue;
          }
          notes.add(open[at] = {'part': n.partId, 'staff': n.staff, 'start': n.start, 'end': n.end, 'pitch': n.midi});
        }
        return notes;
      case 'score.chapters':
        return [
          for (final c in p.chapters) {'name': c.name, 'start': c.start, 'end': c.end},
        ];
      case 'score.captions':
        final captions = p.extensions.captions;
        return [
          for (final s in captionSpans(captions, timeline))
            if (s.end > start && s.start < p.heard.end) {'text': captions[s.caption].text, 'start': s.start - start, 'end': s.end - start},
        ];

      // What a plugin adds to the page.
      case 'ui.button':
        final spec = a.map(0);
        final button = (
          id: _text(spec, 'id', method),
          title: _text(spec, 'title', method),
          icon: spec['icon'] as String?,
          text: spec['text'] as String?,
          checked: spec['checked'] == true,
          enabled: spec['enabled'] != false,
        );
        _buttons = _put(_buttons, button, (b) => b.id == button.id);
        notifyListeners();
      case 'ui.removeButton':
        _buttons = [for (final b in _buttons) if (b.id != a.text(0)) b];
        notifyListeners();
      case 'ui.option':
        final spec = a.map(0);
        final type = switch (spec['type']) { 'switch' => 'switch', 'choice' => 'choice', 'action' => 'action', final t => throw ArgumentError('$method: no option is a $t') };
        final choices = [
          if (spec['options'] case final List<Object?> list)
            for (final o in list)
              if (o case {'value': final String value}) (value: value, label: switch (o['label']) { final String l => l, _ => value }),
        ];
        final value = spec['value'];
        if (type == 'choice' && !choices.any((c) => c.value == value)) throw ArgumentError('$method: a choice’s value is one of its options’');
        final option = (
          id: _text(spec, 'id', method),
          group: _text(spec, 'group', method),
          type: type,
          label: _text(spec, 'label', method),
          value: switch (type) { 'switch' => value == true, 'choice' => value, _ => null },
          options: choices,
          enabled: spec['enabled'] != false,
        );
        _options = _put(_options, option, (o) => o.id == option.id);
        notifyListeners();
      case 'ui.removeOption':
        _options = [for (final o in _options) if (o.id != a.text(0)) o];
        notifyListeners();
      case 'ui.key':
        final id = a.text(0), key = PluginKey.parse(a.text(1));
        if (key == null) throw ArgumentError('$method: ${a.text(1)} isn’t a key');
        _keys = {
          for (final MapEntry(key: chord, value: told) in _keys.entries)
            if (told != id) chord: told,
          KeyChord.written(key): id,
        };
        notifyListeners();
      case 'ui.removeKey':
        _keys = {
          for (final MapEntry(key: chord, value: told) in _keys.entries)
            if (told != a.text(0)) chord: told,
        };
        notifyListeners();
      case 'ui.insets':
        final insets = [for (var i = 0; i < 4; i++) a.number(i).clamp(0.0, 4000.0)];
        if (!listEquals(insets, _insets)) {
          _insets = insets;
          notifyListeners();
        }
      case 'ui.message':
        onMessage?.call(a.text(0));
      case 'ui.showOptions':
        onShowOptions?.call();
      case 'ui.controlsVisible':
        return p.controlsShown.value;
      case 'ui.controlsHidden':
        return p.controlsHidden;
      case 'ui.hideControls':
        p.controlsHidden = a.boolean(0);
      default:
        throw ArgumentError('The player has no $method');
    }
    return null;
  }

  /// The page's colours as the browser has them now: light or dark, the paper and the ink.
  static Map<String, Object?> get theme {
    final brightness = PlatformDispatcher.instance.platformBrightness;
    String hex(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
    return {'dark': brightness == Brightness.dark, 'paper': hex(ScorePaper.paper(brightness)), 'ink': hex(ScorePaper.ink(brightness))};
  }

  /// What the page's sound plays through (a browser's `<audio>` element); null: none.
  Object? get audioElement => player.audio.element;

  static String _text(Map<String, Object?> spec, String key, String method) =>
      switch (spec[key]) { final String s when s.isNotEmpty => s, _ => throw ArgumentError('$method: $key isn’t a text') };

  /// [list] with [item] where the one [same] picks was, else at its end.
  static List<T> _put<T>(List<T> list, T item, bool Function(T) same) =>
      list.any(same) ? [for (final other in list) same(other) ? item : other] : [...list, item];
}

/// A call's arguments, each taken as what the method needs.
class _Args {
  const _Args(this.method, this.args);
  final String method;
  final List<Object?> args;

  Never _bad(int i, String what) => throw ArgumentError('$method: argument ${i + 1} isn’t $what');
  Object? _at(int i) => i < args.length ? args[i] : null;

  double number(int i) => switch (_at(i)) { final num n when n.isFinite => n.toDouble(), _ => _bad(i, 'a number') };
  double? numberOr(int i) => _at(i) == null ? null : number(i);
  int integer(int i) => switch (_at(i)) { final num n when n.isFinite && n == n.roundToDouble() => n.toInt(), _ => _bad(i, 'a whole number') };
  int integerOr(int i, int otherwise) => _at(i) == null ? otherwise : integer(i);
  bool boolean(int i) => switch (_at(i)) { final bool b => b, _ => _bad(i, 'true or false') };
  bool booleanOr(int i, bool otherwise) => _at(i) == null ? otherwise : boolean(i);
  String text(int i) => switch (_at(i)) { final String s => s, _ => _bad(i, 'a text') };
  String? textOr(int i) => _at(i) == null ? null : text(i);
  Map<String, Object?> map(int i) => switch (_at(i)) {
        final Map<Object?, Object?> m => {for (final MapEntry(:key, :value) in m.entries) '$key': value},
        _ => _bad(i, 'an object'),
      };
  List<double> numbers(int i) => switch (_at(i)) {
        final List<Object?> list => [for (final v in list) v is num && v.isFinite ? v.toDouble() : _bad(i, 'a list of numbers')],
        _ => _bad(i, 'a list of numbers'),
      };
  T named<T extends Enum>(int i, List<T> values) {
    final name = text(i);
    for (final v in values) {
      if (v.name == name) return v;
    }
    return _bad(i, 'one of ${values.map((v) => v.name).join(', ')}');
  }
}
