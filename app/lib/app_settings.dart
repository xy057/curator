import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart' show Color, ThemeMode;
import 'package:score_engine/score_engine.dart'
    show EngravingOptions, MusicFont, PdfAiExamResult, ScoreMotion, ScoreTypography, TextDynamics, TextFonts;
import 'package:shared_preferences/shared_preferences.dart';

import 'ai_providers.dart';
import 'app_colors.dart';
import 'key_bindings.dart';
import 'l10n/l10n.dart';
import 'updater.dart' show UpdateChannel;
import 'video_export.dart';
import 'window_chrome.dart' show WindowFrame;

/// Preferences that apply to every project (Settings…, ⌘,).
class AppSettings extends ChangeNotifier {
  AppSettings._(this._prefs)
      : _autosave = Duration(seconds: _prefs?.getInt(_autosaveKey) ?? defaultAutosave.inSeconds),
        _undoSteps = _prefs?.getInt(_undoKey) ?? defaultUndoSteps,
        _themeMode = ThemeMode.values.asNameMap()[_prefs?.getString(_themeKey)] ?? ThemeMode.system,
        _customAccent = _readColor(_prefs, _customAccentKey),
        _accent = AccentColor.named(_prefs?.getString(_accentKey)) ?? AccentColor.sky,
        _uiStyle = UiStyle.named(_prefs?.getString(_uiStyleKey)) ?? UiStyle.refined,
        _textSize = TextSize.values.asNameMap()[_prefs?.getString(_textSizeKey)] ?? TextSize.medium,
        _density = UiDensity.values.asNameMap()[_prefs?.getString(_densityKey)] ?? UiDensity.standard,
        _reduceMotion = _prefs?.getBool(_reduceMotionKey) ?? false,
        _alignAddedRecordings = _prefs?.getBool(_alignAddedKey) ?? true,
        _autoCurateImported = _prefs?.getBool(_autoCurateKey) ?? true,
        _autoCuratePdf = _prefs?.getBool(_autoCuratePdfKey) ?? false,
        _fineSeek = _readStep(_prefs, _fineSeekKey, fineSeekChoices, defaultFineSeek),
        _anchorNudge = _readStep(_prefs, _anchorNudgeKey, anchorNudgeChoices, defaultAnchorNudge),
        _language = AppLanguage.named(_prefs?.getString(_languageKey)),
        _transition = _prefs?.getDouble(_transitionKey) ?? defaultTransition,
        _musicFont = _prefs?.getString(_musicFontKey) ?? MusicFont.bravura.name,
        _textFont = _prefs?.getString(_textFontKey) ?? TextFonts.academico,
        _embedFont = _prefs?.getBool(_embedFontKey) ?? defaultEmbedFont,
        _mascotIcon = _prefs?.getBool(_mascotIconKey) ?? false,
        _scrollFollow = (_prefs?.getDouble(_scrollFollowKey) ?? defaultScrollFollow).clamp(0.0, 1.0),
        _motion = _readMotion(_prefs?.getString(_motionKey)),
        _typography = _readTypography(_prefs?.getString(_typographyKey)),
        _recent = List.unmodifiable(_prefs?.getStringList(_recentKey) ?? const <String>[]),
        _videoResolution =
            VideoResolution.values.asNameMap()[_prefs?.getString(_videoResolutionKey)] ?? defaultVideoResolution,
        _videoRatio = VideoRatio.parse(_prefs?.getString(_videoRatioKey) ?? '') ?? VideoRatio.widescreen,
        // Whole numbers until build 49 (24 and 25 were offered then: kept, as typed rates).
        _videoFps = _readFps(_prefs),
        _videoPaper = VideoPaper.values.asNameMap()[_prefs?.getString(_videoPaperKey)] ?? VideoPaper.light,
        _videoCodec = VideoCodec.values.asNameMap()[_prefs?.getString(_videoCodecKey)] ?? defaultVideoCodec,
        _videoTransparent = _prefs?.getBool(_videoTransparentKey) ?? false,
        _engraving = _readEngraving(_prefs?.getString(_engravingKey)),
        _checkForUpdates = _prefs?.getBool(_updatesKey) ?? true,
        _updateChannel = UpdateChannel.values.asNameMap()[_prefs?.getString(_updateChannelKey)] ?? UpdateChannel.release,
        _textDynamics = _prefs?.getBool(_textDynamicsKey) ?? defaultTextDynamics,
        _rehearsalInRow = _prefs?.getBool(_rehearsalInRowKey) ?? defaultRehearsalInRow,
        _centeredLyrics = _prefs?.getBool(_centeredLyricsKey) ?? defaultCenteredLyrics,
        legacyExtensions = _readLegacyExtensions(_prefs),
        _videoSubtitles = _prefs?.getBool(_videoSubtitlesKey) ?? false,
        _videoChapters = _prefs?.getBool(_videoChaptersKey) ?? true,
        _previewVideoFrame = _prefs?.getBool(_previewFrameKey) ?? false,
        _tabBar = _prefs?.getBool(_tabBarKey) ?? true,
        _rememberWindow = _prefs?.getBool(_rememberWindowKey) ?? true,
        _windowFrame = WindowFrame.parse(_prefs?.getString(_windowFrameKey)),
        _aiProviders = List.unmodifiable(AiProvider.read(_prefs?.getString(_aiProvidersKey))),
        _pdfAiModel = _prefs?.getString(_pdfAiModelKey) ?? '',
        _pdfAiExams = _readPdfAiExams(_prefs?.getString(_pdfAiExamsKey)),
        _hideAi = _prefs?.getBool(_hideAiKey) ?? false,
        aiHidden = _prefs?.getBool(_hideAiKey) ?? false,
        _engravingPreview = _prefs?.getBool(_engravingPreviewKey) ?? true,
        _keys = KeyMap.read(_prefs?.getString(_keysKey)) {
    // Classic is gone: it opens as Refined (UiStyle.named), and is saved so from now on.
    if (_prefs?.getString(_uiStyleKey) == 'classic') _prefs?.setString(_uiStyleKey, _uiStyle.name);
    final custom = _customAccent;
    if (_prefs?.getString(_accentKey) == 'custom' && custom != null) _accent = AccentColor.custom(custom);
  }

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

  static const _autosaveKey = 'autosaveSeconds', _undoKey = 'undoSteps';
  static const _themeKey = 'themeMode', _accentKey = 'accentColor', _transitionKey = 'transition';
  static const _uiStyleKey = 'uiStyle', _customAccentKey = 'customAccent', _textSizeKey = 'textSize';
  static const _densityKey = 'density', _reduceMotionKey = 'reduceMotion', _languageKey = 'language';
  static const _scrollFollowKey = 'scrollFollow', _motionKey = 'scoreMotion', _typographyKey = 'scoreTypography';
  static const _musicFontKey = 'musicFont', _textFontKey = 'textFont', _embedFontKey = 'embedFont';
  static const _mascotIconKey = 'mascotIcon', _alignAddedKey = 'alignAddedRecordings';
  static const _autoCurateKey = 'autoCurateImported', _autoCuratePdfKey = 'autoCuratePdf', _fineSeekKey = 'fineSeekSeconds';
  static const _anchorNudgeKey = 'anchorNudgeSeconds';
  static const _recentKey = 'recentFiles', _engravingKey = 'engravingOptions', _updatesKey = 'checkForUpdates';
  static const _updateChannelKey = 'updateChannel';
  static const _videoResolutionKey = 'videoResolution', _videoFpsKey = 'videoFps', _videoPaperKey = 'videoPaper';
  static const _videoRatioKey = 'videoRatio', _previewFrameKey = 'previewVideoFrame', _videoCodecKey = 'videoCodec';
  static const _videoTransparentKey = 'videoTransparent', _videoFrameRateKey = 'videoFrameRate';
  static const _tabBarKey = 'showTabBar';
  // macOS reads the flag itself, before Dart runs (MainFlutterWindow.swift: "flutter." + this).
  static const _rememberWindowKey = 'rememberWindow', _windowFrameKey = 'windowFrame';
  static const _aiProvidersKey = 'aiProviders', _pdfAiModelKey = 'pdfAiModel', _pdfAiExamsKey = 'pdfAiExams';
  static const _hideAiKey = 'hideAi', _keysKey = 'keyBindings';
  static const _textDynamicsKey = 'textDynamics', _engravingPreviewKey = 'engravingPreview';
  static const _rehearsalInRowKey = 'rehearsalInRow', _centeredLyricsKey = 'centredLyrics'; // the flag's first spelling, kept

  static Color? _readColor(SharedPreferences? prefs, String key) {
    try {
      return switch (prefs?.getInt(key)) { final argb? => Color(argb), _ => null };
    } catch (_) {
      return null; // not a number
    }
  }

  /// A step saved under [key] (seconds), if one of [choices].
  static double _readStep(SharedPreferences? prefs, String key, List<double> choices, double fallback) {
    try {
      final seconds = prefs?.getDouble(key);
      return choices.contains(seconds) ? seconds! : fallback;
    } catch (_) {
      return fallback; // not a number
    }
  }

  static double _readFps(SharedPreferences? prefs) {
    try {
      return prefs?.getDouble(_videoFrameRateKey) ?? prefs?.getInt(_videoFpsKey)?.toDouble() ?? defaultVideoFps;
    } catch (_) {
      return defaultVideoFps; // not a number
    }
  }
  static const _extensionDefaultsKey = 'extensionDefaults'; // deprecated: read, never written
  static const _captionFontKey = 'captionFont';
  static const _captionCountdownKey = 'captionCountdown', _captionSizeKey = 'captionSize';
  static const _captionAlignKey = 'captionAlign', _captionPlateKey = 'captionPlate';
  static const _videoSubtitlesKey = 'videoSubtitles', _videoChaptersKey = 'videoChapters';
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

  /// The colour of selections, regions, the playhead…: a swatch, or the user's own.
  AccentColor get accent => _accent;
  AccentColor _accent;
  set accent(AccentColor value) {
    if (value == _accent) return;
    _accent = value;
    _prefs?.setString(_accentKey, value.name);
    if (value.isCustom) {
      _customAccent = value.color;
      _prefs?.setInt(_customAccentKey, value.color.toARGB32());
    }
    notifyListeners();
  }

  /// The user's own accent colour, the last one chosen, kept while a swatch is the accent.
  Color? get customAccent => _customAccent;
  Color? _customAccent;

  /// How the controls look: quiet desktop ones, or Material's as before.
  UiStyle get uiStyle => _uiStyle;
  UiStyle _uiStyle;
  set uiStyle(UiStyle value) {
    if (value == _uiStyle) return;
    _uiStyle = value;
    _prefs?.setString(_uiStyleKey, value.name);
    notifyListeners();
  }

  /// How big the interface's text is.
  TextSize get textSize => _textSize;
  TextSize _textSize;
  set textSize(TextSize value) {
    if (value == _textSize) return;
    _textSize = value;
    _prefs?.setString(_textSizeKey, value.name);
    notifyListeners();
  }

  /// How tightly toolbars, rows and menus are set.
  UiDensity get density => _density;
  UiDensity _density;
  set density(UiDensity value) {
    if (value == _density) return;
    _density = value;
    _prefs?.setString(_densityKey, value.name);
    notifyListeners();
  }

  /// The interface's language; [AppLanguage.system] follows the system's, as does one whose
  /// translations the app no longer carries.
  AppLanguage get language => AppLanguage.values.contains(_language) ? _language : AppLanguage.system;
  AppLanguage _language;
  set language(AppLanguage value) {
    if (value == _language) return;
    _language = value;
    _prefs?.setString(_languageKey, value.name);
    notifyListeners();
  }

  /// The interface without motion: no fades, slides or cross-fades (the score still scrolls and
  /// its staves still come and go as the project says).
  bool get reduceMotion => _reduceMotion;
  bool _reduceMotion;
  set reduceMotion(bool value) {
    if (value == _reduceMotion) return;
    _reduceMotion = value;
    _prefs?.setBool(_reduceMotionKey, value);
    notifyListeners();
  }

  /// Whether a recording added to a score with no anchors yet is aligned at once (Align).
  bool get alignAddedRecordings => _alignAddedRecordings;
  bool _alignAddedRecordings;
  set alignAddedRecordings(bool value) {
    if (value == _alignAddedRecordings) return;
    _alignAddedRecordings = value;
    _prefs?.setBool(_alignAddedKey, value);
    notifyListeners();
  }

  /// Whether a score imported is auto-curated (its lanes where each part plays, fitted to the
  /// video's frame); off, every staff is shown throughout.
  bool get autoCurateImported => _autoCurateImported;
  bool _autoCurateImported;
  set autoCurateImported(bool value) {
    if (value == _autoCurateImported) return;
    _autoCurateImported = value;
    _prefs?.setBool(_autoCurateKey, value);
    notifyListeners();
  }

  /// Whether a PDF's project (no notes: only what each staff's bars hold) can be auto-curated:
  /// on import (with [autoCurateImported]), Auto-curate and Auto-Curate Lane. Off, its lanes
  /// are drawn by hand.
  bool get autoCuratePdf => _autoCuratePdf;
  bool _autoCuratePdf;
  set autoCuratePdf(bool value) {
    if (value == _autoCuratePdf) return;
    _autoCuratePdf = value;
    _prefs?.setBool(_autoCuratePdfKey, value);
    notifyListeners();
  }

  static const defaultFineSeek = 0.1;

  /// Choices offered for how far ⌥←/→ move the playhead, seconds.
  static const fineSeekChoices = [0.05, 0.1, 0.2, 0.5, 1.0];

  /// How far ⌥←/→ move the playhead, seconds.
  double get fineSeek => _fineSeek;
  double _fineSeek;
  set fineSeek(double value) {
    if (value == _fineSeek || !fineSeekChoices.contains(value)) return;
    _fineSeek = value;
    _prefs?.setDouble(_fineSeekKey, value);
    notifyListeners();
  }

  static const defaultAnchorNudge = 0.01;

  /// Choices offered for how far ←/→ nudge the selected anchors, seconds.
  static const anchorNudgeChoices = [0.001, 0.005, 0.01, 0.02, 0.05];

  /// How far ←/→ nudge the selected anchors, seconds (⇧ always 1 ms).
  double get anchorNudge => _anchorNudge;
  double _anchorNudge;
  set anchorNudge(double value) {
    if (value == _anchorNudge || !anchorNudgeChoices.contains(value)) return;
    _anchorNudge = value;
    _prefs?.setDouble(_anchorNudgeKey, value);
    notifyListeners();
  }

  // MARK: Animation

  static const defaultTransition = 0.3;

  /// Choices offered for how long a staff takes to enter or leave, seconds.
  static const transitionChoices = [0.15, 0.3, 0.5, 0.8, 1.2];

  /// The staff transition new projects start with (each project saves its own; Project
  /// Settings ▸ Display ▸ Save as default).
  double get transition => _transition;
  double _transition;
  set transition(double value) {
    if (value == _transition) return;
    _transition = value;
    _prefs?.setDouble(_transitionKey, value);
    notifyListeners();
  }

  // MARK: Fonts

  /// The music font new projects start with, by name: a bundled one or one installed here
  /// (each project saves its own; one not installed where a score is imported is Bravura).
  String get musicFont => _musicFont;
  String _musicFont;
  set musicFont(String value) {
    if (value == _musicFont || value.trim().isEmpty) return;
    _musicFont = value;
    _prefs?.setString(_musicFontKey, value);
    notifyListeners();
  }

  /// The text font family new projects start with (one not installed is Academico).
  String get textFont => _textFont;
  String _textFont;
  set textFont(String value) {
    if (value == _textFont || value.trim().isEmpty) return;
    _textFont = value;
    _prefs?.setString(_textFontKey, value);
    notifyListeners();
  }

  static const defaultEmbedFont = true;

  /// Whether new projects embed their music font (Project Settings ▸ Engraving ▸ Embed font).
  bool get embedFont => _embedFont;
  bool _embedFont;
  set embedFont(bool value) {
    if (value == _embedFont) return;
    _embedFont = value;
    _prefs?.setBool(_embedFontKey, value);
    notifyListeners();
  }

  /// The mascot in place of the app icon, in the app (AppLogo) and in the Dock or taskbar
  /// (WindowChrome.showAppIcon); a click on the icon in Settings ▸ About toggles it.
  bool get mascotIcon => _mascotIcon;
  bool _mascotIcon;
  set mascotIcon(bool value) {
    if (value == _mascotIcon) return;
    _mascotIcon = value;
    _prefs?.setBool(_mascotIconKey, value);
    notifyListeners();
  }

  static const defaultScrollFollow = 0.4;

  /// How closely the scroll follows the notes in a project without its own (Project Settings ▸
  /// Animation ▸ Save as default), 0–1: 0 glides from beat to beat (as
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

  /// How the score moves in a project without its own (Project Settings ▸ Animation ▸ Save as
  /// default): the house style until then.
  ScoreMotion get motion => _motion;
  ScoreMotion _motion;
  set motion(ScoreMotion value) {
    if (value == _motion) return;
    _motion = value;
    _prefs?.setString(_motionKey, jsonEncode(value.toJson()));
    notifyListeners();
  }

  static ScoreMotion _readMotion(String? json) {
    try {
      return json == null ? ScoreMotion.standard : ScoreMotion.fromJson((jsonDecode(json) as Map).cast<String, Object?>());
    } catch (_) {
      return ScoreMotion.standard; // not a motion: a newer version's, or damaged
    }
  }

  /// How the score's texts look in a project without its own (Project Settings ▸ Typography ▸
  /// Save as default): the house style until then.
  ScoreTypography get typography => _typography;
  ScoreTypography _typography;
  set typography(ScoreTypography value) {
    if (value == _typography) return;
    _typography = value;
    _prefs?.setString(_typographyKey, jsonEncode(value.toJson()));
    notifyListeners();
  }

  static ScoreTypography _readTypography(String? json) {
    try {
      return json == null
          ? ScoreTypography.standard
          : ScoreTypography.fromJson((jsonDecode(json) as Map).cast<String, Object?>());
    } catch (_) {
      return ScoreTypography.standard; // not a typography: a newer version's, or damaged
    }
  }

  // MARK: Export Video (the choices made last time)

  /// What a video is until changed: an MP4 (H.264), 1080p at 30 frames a second.
  static const defaultVideoResolution = VideoResolution.hd1080, defaultVideoFps = 30.0;
  static const defaultVideoCodec = VideoCodec.h264;

  /// What the video is written as.
  VideoCodec get videoCodec => _videoCodec;
  VideoCodec _videoCodec;
  set videoCodec(VideoCodec value) {
    if (value == _videoCodec) return;
    _videoCodec = value;
    _prefs?.setString(_videoCodecKey, value.name);
    notifyListeners();
  }

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

  /// No paper behind the score, where the [videoCodec] keeps it ([VideoCodec.alpha]); the
  /// [videoPaper] then says which ink. Off by default.
  bool get videoTransparent => _videoTransparent;
  bool _videoTransparent;
  set videoTransparent(bool value) {
    if (value == _videoTransparent) return;
    _videoTransparent = value;
    _prefs?.setBool(_videoTransparentKey, value);
    notifyListeners();
  }

  /// The video these choices make; the preview's frame is its [VideoFormat.aspectRatio].
  VideoFormat get videoFormat =>
      VideoFormat.of(videoResolution, ratio: videoRatio, fps: videoFps, paper: videoPaper, codec: videoCodec, transparent: videoTransparent);

  /// Frames a second: one of [VideoFormat.frameRates] or one typed, [VideoFormat.minFps] to
  /// [VideoFormat.maxFps].
  double get videoFps => _videoFps >= VideoFormat.minFps && _videoFps <= VideoFormat.maxFps ? _videoFps : defaultVideoFps;
  double _videoFps;
  set videoFps(double value) {
    if (value == _videoFps || !value.isFinite) return;
    _videoFps = value;
    _prefs?.setDouble(_videoFrameRateKey, value);
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

  /// View ▸ Show / Hide Tab Bar: the projects' tabs along the window's top, while one is open.
  /// On by default; hidden, the editor's toolbar has a Home button instead.
  bool get tabBar => _tabBar;
  bool _tabBar;
  set tabBar(bool value) {
    if (value == _tabBar) return;
    _tabBar = value;
    _prefs?.setBool(_tabBarKey, value);
    notifyListeners();
  }

  /// Whether the window opens where and as big as it was left. The frame is kept either way.
  bool get rememberWindow => _rememberWindow;
  bool _rememberWindow;
  set rememberWindow(bool value) {
    if (value == _rememberWindow) return;
    _rememberWindow = value;
    _prefs?.setBool(_rememberWindowKey, value);
    notifyListeners();
  }

  /// Settings ▸ General ▸ Hide AI features: no remote AI anywhere, from the next launch on
  /// ([aiHidden]).
  bool get hideAi => _hideAi;
  bool _hideAi;
  set hideAi(bool value) {
    if (value == _hideAi) return;
    _hideAi = value;
    _prefs?.setBool(_hideAiKey, value);
    notifyListeners();
  }

  /// Whether AI is hidden while the app runs: [hideAi] as it was at launch. Nothing asks a remote
  /// model then (no Read with AI, no AI for PDF import), and Settings ▸ Remote AI Provider lies
  /// under a cover. AI run on this computer is never hidden: Align's Basic Pitch, and what
  /// Settings ▸ Download Hub downloads.
  final bool aiHidden;

  /// Whether [hideAi] has changed since launch: it applies once the app is opened again.
  bool get aiRestartPending => _hideAi != aiHidden;

  /// Settings ▸ Remote AI Provider: the AI services and their credentials, in the order listed;
  /// the built-in ones always among them ([AiProvider.read]).
  List<AiProvider> get aiProviders => _aiProviders;
  List<AiProvider> _aiProviders;
  set aiProviders(List<AiProvider> value) {
    if (listEquals(value, _aiProviders)) return;
    _aiProviders = List.unmodifiable(value);
    _prefs?.setString(_aiProvidersKey, AiProvider.write(value));
    notifyListeners();
  }

  /// [provider] in place of the one with its id, or after the others when there is none.
  void setAiProvider(AiProvider provider) {
    final i = _aiProviders.indexWhere((p) => p.id == provider.id);
    aiProviders = [
      for (final p in _aiProviders) p.id == provider.id ? provider : p,
      if (i < 0) provider,
    ];
  }

  /// The provider with [id] gone (only one of the user's).
  void removeAiProvider(String id) => aiProviders = [for (final p in _aiProviders) if (p.id != id || p.builtIn) p];

  /// The model the PDF import's Read with AI asks ([AiModels.keyOf]); '' for none. Kept while its
  /// provider is off or without it, though then nothing is asked ([pdfAi]).
  String get pdfAiModel => _pdfAiModel;
  String _pdfAiModel;
  set pdfAiModel(String value) {
    if (value == _pdfAiModel) return;
    _pdfAiModel = value;
    _prefs?.setString(_pdfAiModelKey, value);
    notifyListeners();
  }

  /// The model the PDF import reads with, while it is there to ask.
  AiModel? get pdfAi => _pdfAiModel.isEmpty ? null : _aiProviders.model(_pdfAiModel);

  /// How [model] ([AiModels.keyOf]) last did in the PDF import's exam ([PdfAiExam]); null: it hasn't
  /// taken this one.
  PdfAiExamResult? pdfAiExam(String model) => _pdfAiExams[model];
  Map<String, PdfAiExamResult> _pdfAiExams;
  void setPdfAiExam(String model, PdfAiExamResult result) {
    _pdfAiExams = Map.unmodifiable({..._pdfAiExams, model: result});
    _prefs?.setString(_pdfAiExamsKey, jsonEncode({for (final e in _pdfAiExams.entries) e.key: e.value.toJson()}));
    notifyListeners();
  }

  /// The results kept, those of this exam ([PdfAiExamResult.fromJson]).
  static Map<String, PdfAiExamResult> _readPdfAiExams(String? json) {
    try {
      if (jsonDecode(json ?? '{}') case final Map map) {
        return Map.unmodifiable({
          for (final MapEntry(:key, :value) in map.entries)
            if ((key, PdfAiExamResult.fromJson(value)) case (final String model, final result?)) model: result,
        });
      }
    } on FormatException {
      // Unreadable: none kept.
    }
    return const {};
  }

  /// The window as it was left (Windows and Linux; macOS keeps its own, NSWindow's autosave).
  WindowFrame? get windowFrame => _windowFrame;
  WindowFrame? _windowFrame;

  /// Waits for the write: this happens as the app quits.
  Future<void> saveWindowFrame(WindowFrame frame) async {
    if (frame == _windowFrame) return;
    _windowFrame = frame;
    await _prefs?.setString(_windowFrameKey, frame.encode());
  }

  // MARK: Extension

  /// Deprecated: the extensions the app once switched on for every project, by extension id
  /// (until build 69 a switch each in Settings, then Save as default). Nothing sets them any
  /// more: each project keeps its own (`EditState.extensions`). Read only for a project saved
  /// before it did, which takes one it uses that was on here ([EditorController.legacyExtensions]).
  final Map<String, bool> legacyExtensions;

  static Map<String, bool> _readLegacyExtensions(SharedPreferences? prefs) {
    try {
      if (prefs?.getString(_extensionDefaultsKey) case final json?) {
        return Map.unmodifiable({
          for (final MapEntry(:key, :value) in (jsonDecode(json) as Map<String, Object?>).entries)
            if (value is bool) key: value,
        });
      }
      return Map.unmodifiable({
        for (final id in const ['attachImage', 'captions']) id: ?prefs?.getBool(id),
      });
    } catch (_) {
      return const {}; // not readable: all off
    }
  }

  /// Whether Export writes the captions as an .srt beside a movie (Captions on, with captions).
  bool get videoSubtitles => _videoSubtitles;
  bool _videoSubtitles;
  set videoSubtitles(bool value) {
    if (value == _videoSubtitles) return;
    _videoSubtitles = value;
    _prefs?.setBool(_videoSubtitlesKey, value);
    notifyListeners();
  }

  /// What was kept since the app started, by extension (settings kept nowhere, a test's, are
  /// here alone).
  final _extensionSettings = <String, Object?>{};

  /// What extension [id] keeps for every project (`curator.settings` in its Lua), as JSON;
  /// null: nothing yet.
  Object? extensionSettings(String id) {
    if (_extensionSettings.containsKey(id)) return _extensionSettings[id];
    final saved = _prefs?.getString('extension.$id');
    if (saved == null) return id == 'captions' ? _captionsBefore : null;
    try {
      return jsonDecode(saved);
    } on FormatException {
      return null;
    }
  }

  /// Keeps [json] as extension [id]'s settings (`curator.save_settings`), and tells the
  /// listeners: what shows of them (its captions' look) follows.
  void setExtensionSettings(String id, Object? json) {
    _extensionSettings[id] = json;
    if (json == null) {
      _prefs?.remove('extension.$id');
    } else {
      _prefs?.setString('extension.$id', jsonEncode(json));
    }
    notifyListeners();
  }

  /// The captions' look as it was kept while Captions was written in the app (a setting each),
  /// which the extension takes as its own until it keeps them itself; null: none was changed.
  Object? get _captionsBefore {
    final font = _prefs?.getString(_captionFontKey), countdown = _prefs?.getString(_captionCountdownKey), size = _prefs?.getString(_captionSizeKey);
    final align = _prefs?.getString(_captionAlignKey), plate = _prefs?.getBool(_captionPlateKey);
    if (font == null && countdown == null && size == null && align == null && plate == null) return null;
    return {'font': ?font, 'countdown': ?countdown, 'size': ?size, 'align': ?align, 'plate': ?plate};
  }

  /// Whether Export puts the chapters in a movie, and their times beside it (Chapters on, with
  /// chapters). On by default.
  bool get videoChapters => _videoChapters;
  bool _videoChapters;
  set videoChapters(bool value) {
    if (value == _videoChapters) return;
    _videoChapters = value;
    _prefs?.setBool(_videoChaptersKey, value);
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

  /// Whether the engraving pages (Project Settings ▸ Engraving, Typography, Advanced Engraving)
  /// show the score above their rows. On by default.
  bool get engravingPreview => _engravingPreview;
  bool _engravingPreview;
  set engravingPreview(bool value) {
    if (value == _engravingPreview) return;
    _engravingPreview = value;
    _prefs?.setBool(_engravingPreviewKey, value);
    notifyListeners();
  }

  /// The keys the user gave the menus' and the editor's commands (Settings ▸ Shortcuts), the
  /// rest as they come.
  KeyMap get keys => _keys;
  KeyMap _keys;
  set keys(KeyMap value) {
    if (value == _keys) return;
    _keys = value;
    value.isStandard ? _prefs?.remove(_keysKey) : _prefs?.setString(_keysKey, value.write());
    notifyListeners();
  }

  static EngravingOptions _readEngraving(String? json) {
    try {
      return EngravingOptions.fromJson(json == null ? null : jsonDecode(json));
    } on FormatException {
      return const EngravingOptions();
    }
  }

  // MARK: Flags

  static const defaultTextDynamics = true, defaultRehearsalInRow = true, defaultCenteredLyrics = false;

  /// Dynamics a notation program wrote as text ("f" in a music font) are engraved as dynamics
  /// ([TextDynamics]) in a project that hasn't chosen (Project Settings ▸ Flags ▸ Save as
  /// default). On by default.
  bool get textDynamics => _textDynamics;
  bool _textDynamics;
  set textDynamics(bool value) {
    if (value == _textDynamics) return;
    _textDynamics = value;
    _prefs?.setBool(_textDynamicsKey, value);
    notifyListeners();
  }

  /// While bar numbers are shown, rehearsal marks leave the music for their bars in that row
  /// ([CuratedScene.rehearsalInRow]), in a project that hasn't chosen. On by default.
  bool get rehearsalInRow => _rehearsalInRow;
  bool _rehearsalInRow;
  set rehearsalInRow(bool value) {
    if (value == _rehearsalInRow) return;
    _rehearsalInRow = value;
    _prefs?.setBool(_rehearsalInRowKey, value);
    notifyListeners();
  }

  /// Each syllable is centred under its notehead, but one an extender follows
  /// ([EngraveRequest.centeredLyrics]), in a project that hasn't chosen. Off by default.
  bool get centeredLyrics => _centeredLyrics;
  bool _centeredLyrics;
  set centeredLyrics(bool value) {
    if (value == _centeredLyrics) return;
    _centeredLyrics = value;
    _prefs?.setBool(_centeredLyricsKey, value);
    notifyListeners();
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

  /// Which releases the updater offers: the releases, or pre-releases too.
  UpdateChannel get updateChannel => _updateChannel;
  UpdateChannel _updateChannel;
  set updateChannel(UpdateChannel value) {
    if (value == _updateChannel) return;
    _updateChannel = value;
    _prefs?.setString(_updateChannelKey, value.name);
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
