import 'app_settings.dart';
import 'editor_controller.dart';
import 'video_export.dart';

/// Settings (the app's, the same for every project) as the editor follows them.
extension ControllerSettings on EditorController {
  /// Takes what [settings] say for every project: how far Undo goes back, what a project
  /// starts with (its transition, scroll, motion and fonts), the extensions an old project had on,
  /// the captions' look, the video's frame (its ratio), and the engraving options and flags
  /// (re-engraving what is open when they change). Call it again whenever they change: what
  /// is the same already changes nothing.
  void takeSettings(AppSettings settings) {
    undoLimit = settings.undoSteps;
    defaultTransition = settings.transition;
    newProjectFonts = (music: settings.musicFont, text: settings.textFont, embed: settings.embedFont);
    defaultScrollFollow = settings.scrollFollow;
    defaultMotion = settings.motion;
    legacyExtensions = settings.legacyExtensions;
    captions.configure(
        font: settings.captionFont,
        countdown: settings.captionCountdown,
        size: settings.captionSize);
    engravingOptions = settings.engravingOptions;
    defaultTextDynamics = settings.textDynamics;
    videoLayout = VideoFormat.layoutOf(settings.videoRatio.value);
  }
}
