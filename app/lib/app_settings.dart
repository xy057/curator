import 'dart:convert';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/foundation.dart';
import 'package:score_engine/score_engine.dart' show CaptionCountdown, CaptionPosition, CaptionSize, EngravingOptions;
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
        _scrollFollow = (_prefs?.getDouble(_scrollFollowKey) ?? defaultScrollFollow).clamp(0.0, 1.0),
        _recent = List.unmodifiable(_prefs?.getStringList(_recentKey) ?? const <String>[]),
        _videoResolution =
            VideoResolution.values.asNameMap()[_prefs?.getString(_videoResolutionKey)] ?? defaultVideoResolution,
        _videoRatio = VideoRatio.parse(_prefs?.getString(_videoRatioKey) ?? '') ?? VideoRatio.widescreen,
        _videoFps = _prefs?.getInt(_videoFpsKey) ?? defaultVideoFps,
        _videoPaper = VideoPaper.values.asNameMap()[_prefs?.getString(_videoPaperKey)] ?? VideoPaper.light,
        _engraving = _readEngraving(_prefs?.getString(_engravingKey)),
        _checkForUpdates = _prefs?.getBool(_updatesKey) ?? true,
        _attachImage = _prefs?.getBool(_attachImageKey) ?? false,
        _captions = _prefs?.getBool(_captionsKey) ?? false,
        _captionFont = _prefs?.getString(_captionFontKey) ?? '',
        _captionPosition = CaptionPosition.values.asNameMap()[_prefs?.getString(_captionPositionKey)] ?? CaptionPosition.bottom,
        _captionCountdown =
            CaptionCountdown.values.asNameMap()[_prefs?.getString(_captionCountdownKey)] ?? CaptionCountdown.line,
        _captionSize = CaptionSize.values.asNameMap()[_prefs?.getString(_captionSizeKey)] ?? CaptionSize.medium,
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
  static const _scrollFollowKey = 'scrollFollow';
  static const _recentKey = 'recentFiles', _engravingKey = 'engravingOptions', _updatesKey = 'checkForUpdates';
  static const _videoResolutionKey = 'videoResolution', _videoFpsKey = 'videoFps', _videoPaperKey = 'videoPaper';
  static const _videoRatioKey = 'videoRatio', _previewFrameKey = 'previewVideoFrame';
  static const _attachImageKey = 'attachImage', _captionsKey = 'captions';
  static const _captionFontKey = 'captionFont', _captionPositionKey = 'captionPosition';
  static const _captionCountdownKey = 'captionCountdown', _captionSizeKey = 'captionSize';
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

  static const defaultScrollFollow = 0.4;

  /// How closely the score's scroll follows the notes, 0–1: 0 glides from beat to beat (as
  /// before 0.2), 1 puts every note under the pointer exactly as it sounds; in between, a
  /// blend. It applies to the preview and to exported videos.
  double get scrollFollow => _scrollFollow;
  double _scrollFollow;
  set scrollFollow(double value) {
    value = value.isFinite ? value.clamp(0.0, 1.0) : defaultScrollFollow;
    if (value == _scrollFollow) return;
    _scrollFollow = value;
    _prefs?.setDouble(_scrollFollowKey, value);
    notifyListeners();
  }

  // MARK: Export Video (the choices made last time)

  /// What a video is until changed: 1080p at 30 frames a second.
  static const defaultVideoResolution = VideoResolution.hd1080, defaultVideoFps = 30;

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
  int get videoFps => VideoFormat.frameRates.contains(_videoFps) ? _videoFps : defaultVideoFps;
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

  // MARK: Extension

  /// The Attach Image extension. Off by default; everything it adds works only while it is on.
  bool get attachImage => _attachImage;
  bool _attachImage;
  set attachImage(bool value) {
    if (value == _attachImage) return;
    _attachImage = value;
    _prefs?.setBool(_attachImageKey, value);
    notifyListeners();
  }

  /// The Captions extension. Off by default; everything it adds works only while it is on.
  bool get captions => _captions;
  bool _captions;
  set captions(bool value) {
    if (value == _captions) return;
    _captions = value;
    _prefs?.setBool(_captionsKey, value);
    notifyListeners();
  }

  /// The Captions extension's own settings (its settings button), for every project.
  /// The font captions are drawn in when a project doesn't choose one: a text font family,
  /// or '' for the score's own text font.
  String get captionFont => _captionFont;
  String _captionFont;
  set captionFont(String value) {
    if (value == _captionFont) return;
    _captionFont = value;
    _prefs?.setString(_captionFontKey, value);
    notifyListeners();
  }

  CaptionPosition get captionPosition => _captionPosition;
  CaptionPosition _captionPosition;
  set captionPosition(CaptionPosition value) {
    if (value == _captionPosition) return;
    _captionPosition = value;
    _prefs?.setString(_captionPositionKey, value.name);
    notifyListeners();
  }

  CaptionCountdown get captionCountdown => _captionCountdown;
  CaptionCountdown _captionCountdown;
  set captionCountdown(CaptionCountdown value) {
    if (value == _captionCountdown) return;
    _captionCountdown = value;
    _prefs?.setString(_captionCountdownKey, value.name);
    notifyListeners();
  }

  CaptionSize get captionSize => _captionSize;
  CaptionSize _captionSize;
  set captionSize(CaptionSize value) {
    if (value == _captionSize) return;
    _captionSize = value;
    _prefs?.setString(_captionSizeKey, value.name);
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
