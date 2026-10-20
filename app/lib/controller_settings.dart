import 'app_settings.dart';
import 'editor_controller.dart';

/// Settings (the app's, the same for every project) as the editor follows them.
extension ControllerSettings on EditorController {
  /// Takes what [settings] say for every project: how far Undo goes back, what a project
  /// starts with (its transition, scroll and fonts), the extensions a project starts
  /// with and
  /// the captions' look, and the engraving options and flags (re-engraving what is open when
  /// they change). Call it again whenever they change: what is the same already changes nothing.
  void takeSettings(AppSettings settings) {
    undoLimit = settings.undoSteps;
    defaultTransition = settings.transition;
    newProjectFonts = (music: settings.musicFont, text: settings.textFont, embed: settings.embedFont);
    defaultScrollFollow = settings.scrollFollow;
    defaultExtensions = settings.extensionDefaults;
    captions.configure(
        font: settings.captionFont,
        position: settings.captionPosition,
        countdown: settings.captionCountdown,
        size: settings.captionSize);
    engravingOptions = settings.engravingOptions;
    defaultTextDynamics = settings.textDynamics;
  }
}
