import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_icons.dart';
import 'app_settings.dart';
import 'ui_kit.dart';

/// The app's icon as the app shows it (Home, Settings ▸ About), [size] square: the icon, or the
/// mascot on the same tile while [AppSettings.mascotIcon] is on, cross-fading when it changes.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, required this.settings, required this.size});
  final AppSettings settings;
  final double size;

  static const icon = 'assets/icon/app_icon.png';
  static const mascot = 'assets/icon/mascot.png';

  /// The mascot's tile at the Dock's largest (256 pt at 2×), for WindowChrome.showAppIcon.
  static const mascotDock = 'assets/icon/mascot_512.png';

  @override
  Widget build(BuildContext context) {
    final style = AppStyle.of(context);
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => AnimatedSwitcher(
        duration: motion(context, 250),
        switchInCurve: style.enterCurve,
        switchOutCurve: style.exitCurve,
        child: Image.asset(
          settings.mascotIcon ? mascot : icon,
          key: ValueKey(settings.mascotIcon),
          width: size,
          height: size,
          filterQuality: FilterQuality.medium,
          errorBuilder: (_, _, _) => Icon(AppIcon.music.of(context), size: size * 0.84, color: context.colors.accent),
        ),
      ),
    );
  }
}
