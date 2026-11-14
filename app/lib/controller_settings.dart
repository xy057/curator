import 'app_settings.dart';
import 'editor_controller.dart';
import 'video_export.dart';

/// Settings (the app's, the same for every project) as the editor follows them.
extension ControllerSettings on EditorController {
  /// Takes what [settings] say for every project: how far Undo goes back, whether a recording
  /// added is aligned, whether a score (a PDF) imported is auto-curated, how far ⌥←/→ seek and ←/→ nudge anchors, what a project
  /// starts with (its transition, scroll, motion, typography and fonts), the extensions an old project had on,
  /// the look an extension keeps for its captions, the video's frame (its ratio), the engraving options and flags
  /// (re-engraving what is open when they change), and the language the key areas are named in. Call it again whenever they change: what
  /// is the same already changes nothing.
  void takeSettings(AppSettings settings) {
    undoLimit = settings.undoSteps;
    anchors.alignAdded = settings.alignAddedRecordings;
    autoCurateImported = settings.autoCurateImported;
    autoCuratePdf = settings.autoCuratePdf;
    fineSeek = settings.fineSeek;
    anchorNudge = settings.anchorNudge;
    defaultTransition = settings.transition;
    newProjectFonts = (music: settings.musicFont, text: settings.textFont, embed: settings.embedFont);
    defaultScrollFollow = settings.scrollFollow;
    defaultMotion = settings.motion;
    defaultTypography = settings.typography;
    legacyExtensions = settings.legacyExtensions;
    extensions.followSettings(); // what an extension keeps for every project: its captions' look
    engravingOptions = settings.engravingOptions;
    defaultTextDynamics = settings.textDynamics;
    defaultRehearsalInRow = settings.rehearsalInRow;
    defaultCenteredLyrics = settings.centeredLyrics;
    videoLayout = VideoFormat.layoutOf(settings.videoRatio.value);
    extensions.followLanguage(settings.language);
  }
}
