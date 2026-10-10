import 'package:flutter/material.dart';

/// The accent colours offered under Settings ▸ Appearance.
enum AccentColor {
  sky('Sky', Color(0xFF4DA8F0), Color(0xFF1F8AE0)),
  indigo('Indigo', Color(0xFF6D7BEA), Color(0xFF4454D6)),
  teal('Teal', Color(0xFF2BB3A3), Color(0xFF12897C)),
  violet('Violet', Color(0xFFA078E3), Color(0xFF7C4DCF)),
  rose('Rose', Color(0xFFEC7393), Color(0xFFD1456A)),
  amber('Amber', Color(0xFFF2A83E), Color(0xFFC77D12)),
  graphite('Graphite', Color(0xFF8A94A1), Color(0xFF59636F));

  const AccentColor(this.label, this.color, this.strong);
  final String label;
  final Color color;

  /// The darker shade for lines and selected things on a light background.
  final Color strong;
}

/// How the controls look (Settings ▸ Appearance ▸ Style), the same on every platform.
enum UiStyle {
  /// Quiet desktop controls: no ripples, a small switch, square-cornered buttons.
  refined('Refined'),

  /// Material's controls, as the app first had them.
  classic('Classic');

  const UiStyle(this.label);
  final String label;
}

/// The [UiStyle] a theme was built in, for widgets that draw their own controls ([AppSwitch]).
@immutable
class AppStyle extends ThemeExtension<AppStyle> {
  const AppStyle(this.style);
  final UiStyle style;

  @override
  AppStyle copyWith() => this;

  @override
  AppStyle lerp(AppStyle? other, double t) => t < 0.5 || other == null ? this : other;
}

/// The app's palette: a clean surface with one accent colour, in a light and a dark variant.
/// Read it with `context.colors`; painters receive it from the widget that builds them.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.accent,
    required this.accentStrong,
    required this.accentSoft,
    required this.accentWash,
    required this.surface,
    required this.line,
    required this.grid,
    required this.activity,
    required this.text,
    required this.textMuted,
    required this.erase,
    required this.recording,
    required this.recordingWash,
    required this.waveform,
    required this.onset,
    required this.scorePaper,
    required this.scoreInk,
  });

  factory AppColors.of(AccentColor accent, Brightness brightness) {
    final a = accent.color;
    Color mix(Color base, double t) => Color.lerp(base, a, t)!;
    if (brightness == Brightness.light) {
      const surface = Color(0xFFFFFFFF);
      return AppColors(
        accent: a,
        accentStrong: accent.strong,
        accentSoft: mix(surface, 0.2),
        accentWash: mix(surface, 0.055),
        surface: surface,
        line: mix(const Color(0xFFE5E8EC), 0.07),
        grid: mix(const Color(0xFFEEF0F3), 0.05),
        activity: mix(const Color(0xFFD4D9DF), 0.08),
        text: const Color(0xFF1B2733),
        textMuted: const Color(0xFF6B7C8D),
        erase: const Color(0xFFD9534F),
        recording: const Color(0xFFC62828),
        recordingWash: const Color(0xFFFFF4F3),
        waveform: mix(surface, 0.62),
        onset: const Color(0xFF9AA8B6),
        scorePaper: const Color(0xFFFFFFFF),
        scoreInk: const Color(0xFF14171A),
      );
    }
    const surface = Color(0xFF1D1F23);
    return AppColors(
      accent: a,
      accentStrong: Color.lerp(a, Colors.white, 0.28)!,
      accentSoft: mix(surface, 0.3),
      accentWash: mix(surface, 0.045),
      surface: surface,
      line: mix(const Color(0xFF34373D), 0.06),
      grid: mix(const Color(0xFF2A2D32), 0.05),
      activity: mix(const Color(0xFF4A4F57), 0.08),
      text: const Color(0xFFE4E7EB),
      textMuted: const Color(0xFF98A0AA),
      erase: const Color(0xFFEF6B66),
      recording: const Color(0xFFFF6B63),
      recordingWash: const Color(0xFF3A2322),
      waveform: mix(surface, 0.7),
      onset: const Color(0xFF6C7580),
      scorePaper: const Color(0xFF17191C),
      scoreInk: const Color(0xFFE3E4E0),
    );
  }

  final Color accent;
  final Color accentStrong;
  final Color accentSoft;
  final Color accentWash;
  final Color surface;
  final Color line;
  final Color grid;
  final Color activity;
  final Color text;
  final Color textMuted;
  final Color erase;

  /// Tap mode: the record button and the anchor lane while armed.
  final Color recording;
  final Color recordingWash;
  final Color waveform;
  final Color onset;

  /// The score preview's "digital paper" and its ink: black on white, or in the dark theme
  /// light ink on dark paper (the engraving is recoloured as it is drawn, see ScoreRenderer).
  final Color scorePaper;
  final Color scoreInk;

  static ThemeData theme({
    AccentColor accent = AccentColor.sky,
    Brightness brightness = Brightness.light,
    UiStyle style = UiStyle.refined,
  }) {
    final c = AppColors.of(accent, brightness);
    final dark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(seedColor: accent.color, brightness: brightness).copyWith(
      primary: dark ? c.accent : c.accentStrong,
      surface: c.surface,
      onSurface: c.text,
      onSurfaceVariant: c.textMuted,
      surfaceContainerLowest: c.surface,
      surfaceContainerLow: c.surface,
      surfaceContainer: c.accentWash,
      surfaceContainerHigh: dark ? const Color(0xFF26292E) : c.surface,
      surfaceContainerHighest: dark ? const Color(0xFF2E3137) : c.accentWash,
      secondaryContainer: c.accentSoft,
      onSecondaryContainer: c.text,
      outline: dark ? const Color(0xFF4A4F57) : const Color(0xFFBFC8D2),
      outlineVariant: c.line,
    );
    final theme = ThemeData(
      colorScheme: scheme,
      brightness: brightness,
      scaffoldBackgroundColor: c.surface,
      canvasColor: c.surface,
      dividerColor: c.line,
      visualDensity: VisualDensity.compact,
      extensions: [c, AppStyle(style)],
      splashFactory: InkSparkle.splashFactory,
      dividerTheme: DividerThemeData(color: c.line, space: 1, thickness: 1),
      sliderTheme: SliderThemeData(
        activeTrackColor: c.accent,
        inactiveTrackColor: c.line,
        thumbColor: dark ? c.accent : c.accentStrong,
        trackHeight: 3,
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7, elevation: 1, pressedElevation: 2),
        showValueIndicator: ShowValueIndicator.onDrag,
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 450),
        textStyle: TextStyle(fontSize: 12, color: dark ? c.surface : Colors.white),
        decoration: BoxDecoration(
          color: dark ? const Color(0xFFE4E7EB) : const Color(0xE61B2733),
          borderRadius: BorderRadius.circular(6),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: c.text,
          disabledForegroundColor: c.textMuted.withValues(alpha: 0.4),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          visualDensity: VisualDensity.compact,
          side: WidgetStatePropertyAll(BorderSide(color: c.line)),
          backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.accentSoft : null),
          foregroundColor: WidgetStateProperty.resolveWith(
              (s) => s.contains(WidgetState.selected) ? c.accentStrong : c.textMuted),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: dark ? const Color(0xFF24272B) : c.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: dark ? const Color(0xFF26292E) : c.surface,
        surfaceTintColor: Colors.transparent,
        shape: _SteadyBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: c.line)),
      ),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating, width: 520),
    );
    return style == UiStyle.refined ? _refined(theme, accent, c, dark) : theme;
  }

  /// [UiStyle.refined] over the classic theme: what a desktop app does, not a phone. A press
  /// shows as a tint, not a ripple, and a hover as a fainter one.
  static ThemeData _refined(ThemeData theme, AccentColor accent, AppColors c, bool dark) {
    // Text styles as Theme.of gives them (merged with the typography's geometry, not
    // inherited): a button lerps its label from one style to the other when the style changes,
    // and two text styles lerp only when both inherit or neither does.
    final type = theme.typography.englishLike.merge(theme.textTheme);
    // Buttons: square-cornered, as tall as a field, the label in a medium weight.
    const shape = WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(7))));
    final label = WidgetStatePropertyAll(
        type.labelLarge!.copyWith(fontSize: 13.5, fontWeight: FontWeight.w500, letterSpacing: 0));
    const size = WidgetStatePropertyAll(Size(64, 32));
    const padding = WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 14));
    const quick = Duration(milliseconds: 120);
    final button = ButtonStyle(
      shape: shape,
      textStyle: label,
      minimumSize: size,
      padding: padding,
      animationDuration: quick,
      visualDensity: VisualDensity.standard,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    // The default action: the accent's strong shade, dark enough for white to read on it
    // (amber's isn't), darkened while pressed, as a desktop button is.
    final hsl = HSLColor.fromColor(accent.strong);
    final fill = hsl.withLightness(hsl.lightness.clamp(0, 0.42)).toColor();
    final filled = button.copyWith(
      backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled)
          ? c.textMuted.withValues(alpha: 0.18)
          : fill),
      foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.disabled) ? c.textMuted.withValues(alpha: 0.6) : Colors.white),
      overlayColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.pressed)
          ? Colors.black.withValues(alpha: 0.14)
          : s.contains(WidgetState.hovered)
              ? Colors.white.withValues(alpha: 0.08)
              : null),
      elevation: const WidgetStatePropertyAll(0),
    );
    final outlined = button.copyWith(
      foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.disabled) ? c.textMuted.withValues(alpha: 0.5) : c.text),
      side: WidgetStatePropertyAll(BorderSide(color: dark ? const Color(0xFF4A4F57) : const Color(0xFFCDD4DC))),
    );
    final text = button.copyWith(
      foregroundColor: WidgetStateProperty.resolveWith((s) =>
          s.contains(WidgetState.disabled) ? c.textMuted.withValues(alpha: 0.5) : (dark ? c.accent : c.accentStrong)),
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10)),
    );
    final segment = theme.segmentedButtonTheme.style!.copyWith(
      shape: shape,
      textStyle: label,
      minimumSize: const WidgetStatePropertyAll(Size(0, 30)),
      animationDuration: quick,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    return theme.copyWith(
      filledButtonTheme: FilledButtonThemeData(style: filled),
      elevatedButtonTheme: ElevatedButtonThemeData(style: filled),
      outlinedButtonTheme: OutlinedButtonThemeData(style: outlined),
      textButtonTheme: TextButtonThemeData(style: text),
      segmentedButtonTheme: SegmentedButtonThemeData(style: segment),
      dialogTheme: theme.dialogTheme.copyWith(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        titleTextStyle: type.titleLarge!.copyWith(fontSize: 18, fontWeight: FontWeight.w600, color: c.text, letterSpacing: 0),
        contentTextStyle: type.bodyMedium!.copyWith(fontSize: 14, height: 1.4, color: c.text, letterSpacing: 0),
        actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      ),
      splashFactory: NoSplash.splashFactory,
      splashColor: Colors.transparent,
      hoverColor: c.text.withValues(alpha: dark ? 0.06 : 0.045),
      highlightColor: c.text.withValues(alpha: dark ? 0.1 : 0.08),
      focusColor: c.accent.withValues(alpha: 0.14),
    );
  }

  @override
  AppColors copyWith() => this;

  @override
  AppColors lerp(AppColors? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppColors(
      accent: l(accent, other.accent),
      accentStrong: l(accentStrong, other.accentStrong),
      accentSoft: l(accentSoft, other.accentSoft),
      accentWash: l(accentWash, other.accentWash),
      surface: l(surface, other.surface),
      line: l(line, other.line),
      grid: l(grid, other.grid),
      activity: l(activity, other.activity),
      text: l(text, other.text),
      textMuted: l(textMuted, other.textMuted),
      erase: l(erase, other.erase),
      recording: l(recording, other.recording),
      recordingWash: l(recordingWash, other.recordingWash),
      waveform: l(waveform, other.waveform),
      onset: l(onset, other.onset),
      scorePaper: l(scorePaper, other.scorePaper),
      scoreInk: l(scoreInk, other.scoreInk),
    );
  }
}

/// An outline a Material shows as given. A Material animates a change of its shape on its own, so
/// at a change of theme its outline would trail the window's cross-fade; where it cannot be told
/// not to (a popup menu), this shape takes the new outline at once.
class _SteadyBorder extends RoundedRectangleBorder {
  const _SteadyBorder({super.side, super.borderRadius});

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) => this;
}

extension AppColorsContext on BuildContext {
  /// The app palette of the current theme.
  AppColors get colors => Theme.of(this).extension<AppColors>()!;
}
