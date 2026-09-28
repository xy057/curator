import 'dart:convert';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/foundation.dart';
import 'package:score_engine/score_engine.dart' show EngravingOptions;
import 'package:shared_preferences/shared_preferences.dart';

import 'app_colors.dart';
import 'project_file.dart';
import 'video_export.dart';

/// Preferences that apply to every project (Settings…, ⌘,).
class AppSettings extends ChangeNotifier {
  AppSettings._(this._prefs)
      : _autosave = Duration(seconds: _prefs?.getInt(_autosaveKey) ?? defaultAutosave.inSeconds),
        _media = MediaStorage.values.asNameMap()[_prefs?.getString(_mediaKey)] ?? MediaStorage.embed,
        _undoSteps = _prefs?.getInt(_undoKey) ?? defaultUndoSteps,
        _themeMode = ThemeMode.values.asNameMap()[_prefs?.getString(_themeKey)] ?? ThemeMode.system,
        _accent = AccentColor.values.asNameMap()[_prefs?.getString(_accentKey)] ?? AccentColor.sky,
        _transition = _prefs?.getDouble(_transitionKey) ?? defaultTransition,
        _recent = List.unmodifiable(_prefs?.getStringList(_recentKey) ?? const <String>[]),
        _videoResolution =
            VideoResolution.values.asNameMap()[_prefs?.getString(_videoResolutionKey)] ?? VideoResolution.hd1080,
        _videoRatio = VideoRatio.parse(_prefs?.getString(_videoRatioKey) ?? '') ?? VideoRatio.widescreen,
        _videoFps = _prefs?.getInt(_videoFpsKey) ?? 30,
        _videoPaper = VideoPaper.values.asNameMap()[_prefs?.getString(_videoPaperKey)] ?? VideoPaper.light,
        _engraving = _readEngraving(_prefs?.getString(_engravingKey)),
        _checkForUpdates = _prefs?.getBool(_updatesKey) ?? true,
        _previewVideoFrame = _prefs?.getBool(_previewFrameKey) ?? false;

  /// Defaults, kept in memory only (tests, or when there is no preferences store).
  AppSettings.memory() : this._(null);

  static Future<AppSettings> load() async {
    try {
      return AppSettings._(await SharedPreferences.getInstance());
    } catch (_) {
      return AppSettings.memory();
    }
  }

  final SharedPreferences? _prefs;

  static const _autosaveKey = 'autosaveSeconds', _mediaKey = 'mediaStorage', _undoKey = 'undoSteps';
  static const _themeKey = 'themeMode', _accentKey = 'accentColor', _transitionKey = 'transition';
  static const _recentKey = 'recentFiles', _engravingKey = 'engravingOptions', _updatesKey = 'checkForUpdates';
  static const _videoResolutionKey = 'videoResolution', _videoFpsKey = 'videoFps', _videoPaperKey = 'videoPaper';
  static const _videoRatioKey = 'videoRatio', _previewFrameKey = 'previewVideoFrame';
  static const defaultAutosave = Duration(minutes: 2);

  /// Choices offered for autosave; [Duration.zero] turns it off.
  static const autosaveChoices = [
    Duration.zero,
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 2),
    Duration(minutes: 5),
    Duration(minutes: 10),
  ];

  /// How often a saved project with changes is written again. Zero: never.
  Duration get autosave => _autosave;
  Duration _autosave;
  set autosave(Duration value) {
    if (value == _autosave) return;
    _autosave = value;
    _prefs?.setInt(_autosaveKey, value.inSeconds);
    notifyListeners();
  }

  static const defaultUndoSteps = 200;

  /// Choices offered for how many steps Undo can go back.
  static const undoStepChoices = [50, 100, 200, 500, 1000];

  /// How many steps Undo can go back (in the instrument lanes and in the sync, each).
  int get undoSteps => _undoSteps;
  int _undoSteps;
  set undoSteps(int value) {
    if (value == _undoSteps) return;
    _undoSteps = value;
    _prefs?.setInt(_undoKey, value);
    notifyListeners();
  }

  /// Whether saves embed the recording's audio or link to the recording.
  MediaStorage get mediaStorage => _media;
  MediaStorage _media;
  set mediaStorage(MediaStorage value) {
    if (value == _media) return;
    _media = value;
    _prefs?.setString(_mediaKey, value.name);
    notifyListeners();
  }

  // MARK: Appearance

  /// Light, dark, or following the system.
  ThemeMode get themeMode => _themeMode;
  ThemeMode _themeMode;
  set themeMode(ThemeMode value) {
    if (value == _themeMode) return;
    _themeMode = value;
    _prefs?.setString(_themeKey, value.name);
    notifyListeners();
  }

  /// The colour of selections, regions, the playhead…
  AccentColor get accent => _accent;
  AccentColor _accent;
  set accent(AccentColor value) {
    if (value == _accent) return;
    _accent = value;
    _prefs?.setString(_accentKey, value.name);
    notifyListeners();
  }

  // MARK: Animation

  static const defaultTransition = 0.3;

  /// Choices offered for how long a staff takes to enter or leave, seconds.
  static const transitionChoices = [0.15, 0.3, 0.5, 0.8, 1.2];

  /// The staff transition new projects start with (each project saves its own).
  double get transition => _transition;
  double _transition;
  set transition(double value) {
    if (value == _transition) return;
    _transition = value;
    _prefs?.setDouble(_transitionKey, value);
    notifyListeners();
  }

  // MARK: Export Video (the choices made last time)

  VideoResolution get videoResolution => _videoResolution;
  VideoResolution _videoResolution;
  set videoResolution(VideoResolution value) {
    if (value == _videoResolution) return;
    _videoResolution = value;
    _prefs?.setString(_videoResolutionKey, value.name);
    notifyListeners();
  }

  /// The video's shape: a preset, or one the user typed.
  VideoRatio get videoRatio => _videoRatio;
  VideoRatio _videoRatio;
  set videoRatio(VideoRatio value) {
    if (value == _videoRatio) return;
    _videoRatio = value;
    _prefs?.setString(_videoRatioKey, value.label);
    notifyListeners();
  }

  /// The video these choices make; the preview's frame is its [VideoFormat.aspectRatio].
  VideoFormat get videoFormat =>
      VideoFormat.of(videoResolution, ratio: videoRatio, fps: videoFps, paper: videoPaper);

  /// Frames a second, one of [VideoFormat.frameRates].
  int get videoFps => VideoFormat.frameRates.contains(_videoFps) ? _videoFps : 30;
  int _videoFps;
  set videoFps(int value) {
    if (value == _videoFps) return;
    _videoFps = value;
    _prefs?.setInt(_videoFpsKey, value);
    notifyListeners();
  }

  VideoPaper get videoPaper => _videoPaper;
  VideoPaper _videoPaper;
  set videoPaper(VideoPaper value) {
    if (value == _videoPaper) return;
    _videoPaper = value;
    _prefs?.setString(_videoPaperKey, value.name);
    notifyListeners();
  }

  /// The score preview shows the video's frame ([videoFormat]'s aspect ratio, laid out
  /// like the video), instead of filling the window. Off by default.
  bool get previewVideoFrame => _previewVideoFrame;
  bool _previewVideoFrame;
  set previewVideoFrame(bool value) {
    if (value == _previewVideoFrame) return;
    _previewVideoFrame = value;
    _prefs?.setBool(_previewFrameKey, value);
    notifyListeners();
  }

  // MARK: Advanced

  /// Verovio options every score is engraved with (those changed from the house style).
  EngravingOptions get engravingOptions => _engraving;
  EngravingOptions _engraving;
  set engravingOptions(EngravingOptions value) {
    if (value == _engraving) return;
    _engraving = value;
    _prefs?.setString(_engravingKey, jsonEncode(value.toJson()));
    notifyListeners();
  }

  static EngravingOptions _readEngraving(String? json) {
    try {
      return EngravingOptions.fromJson(json == null ? null : jsonDecode(json));
    } on FormatException {
      return const EngravingOptions();
    }
  }

  // MARK: Update

  /// Whether the app asks GitHub for a newer release when it starts.
  bool get checkForUpdates => _checkForUpdates;
  bool _checkForUpdates;
  set checkForUpdates(bool value) {
    if (value == _checkForUpdates) return;
    _checkForUpdates = value;
    _prefs?.setBool(_updatesKey, value);
    notifyListeners();
  }

  // MARK: Open Recent

  static const recentLimit = 10;

  /// Projects and scores opened or saved lately, most recent first.
  List<String> get recentFiles => _recent;
  List<String> _recent;

  void addRecent(String path) => _setRecent([path, ..._recent.where((p) => p != path)].take(recentLimit).toList());

  void removeRecent(String path) => _setRecent(_recent.where((p) => p != path).toList());

  void clearRecent() => _setRecent(const []);

  void _setRecent(List<String> paths) {
    if (listEquals(paths, _recent)) return;
    _recent = List.unmodifiable(paths);
    _prefs?.setStringList(_recentKey, _recent);
    notifyListeners();
  }
}
