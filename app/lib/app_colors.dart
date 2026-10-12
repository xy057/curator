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
    Color? chrome,
    Color? well,
  })  : chrome = chrome ?? surface,
        well = well ?? accentWash;

  /// The palette for [style]; [UiStyle.classic] by default, as video export draws in it.
  factory AppColors.of(AccentColor accent, Brightness brightness, [UiStyle style = UiStyle.classic]) {
    if (style == UiStyle.refined) return AppColors._refinedOf(accent, brightness);
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

  /// [UiStyle.refined]'s palette: neutral greys (the classic one mixes the accent into every
  /// line and wash), neutral text, and a [chrome] tone for toolbars and sidebars around the
  /// white (or dark) work area. The accent is left for what is selected or on.
  factory AppColors._refinedOf(AccentColor accent, Brightness brightness) {
    final a = accent.color;
    Color mix(Color base, double t) => Color.lerp(base, a, t)!;
    if (brightness == Brightness.light) {
      const surface = Color(0xFFFFFFFF);
      return AppColors(
        accent: a,
        accentStrong: accent.strong,
        accentSoft: mix(surface, 0.2),
        // Nearly all white: the chrome and the lane stripes a whisper off it, hairlines doing the
        // separating.
        accentWash: const Color(0xFFFBFBFC),
        surface: surface,
        chrome: const Color(0xFFFAFAFB),
        well: const Color(0xFFF2F2F4),
        line: const Color(0xFFE3E3E7),
        grid: const Color(0xFFF0F0F3),
        activity: const Color(0xFFD2D2D7),
        text: const Color(0xFF1D1D1F),
        textMuted: const Color(0xFF6E6E73),
        erase: const Color(0xFFD9534F),
        recording: const Color(0xFFC62828),
        recordingWash: const Color(0xFFFFF4F3),
        waveform: mix(surface, 0.62),
        onset: const Color(0xFFA1A1A6),
        scorePaper: const Color(0xFFFFFFFF),
        scoreInk: const Color(0xFF14171A),
      );
    }
    const surface = Color(0xFF1E1E20);
    return AppColors(
      accent: a,
      accentStrong: Color.lerp(a, Colors.white, 0.28)!,
      accentSoft: mix(surface, 0.3),
      accentWash: const Color(0xFF232325),
      well: const Color(0xFF232325),
      surface: surface,
      chrome: const Color(0xFF2A2A2D),
      line: const Color(0xFF38383C),
      grid: const Color(0xFF29292C),
      activity: const Color(0xFF4A4A4F),
      text: const Color(0xFFE8E8EA),
      textMuted: const Color(0xFF98989E),
      erase: const Color(0xFFEF6B66),
      recording: const Color(0xFFFF6B63),
      recordingWash: const Color(0xFF3A2322),
      waveform: mix(surface, 0.7),
      onset: const Color(0xFF6C6C72),
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

  /// Behind toolbars and sidebars: [surface] in the classic style, a step off it in the refined.
  final Color chrome;

  /// The recess of a segmented control, the chosen segment raised out of it.
  final Color well;

  /// A solid accent for white to read on (the default button, a selected sidebar row): the
  /// strong shade, darkened where it is light (amber, and every accent's dark-theme shade).
  Color get accentFill {
    final hsl = HSLColor.fromColor(accentStrong);
    return hsl.withLightness(hsl.lightness.clamp(0, 0.42)).toColor();
  }

  static ThemeData theme({
    AccentColor accent = AccentColor.sky,
    Brightness brightness = Brightness.light,
    UiStyle style = UiStyle.refined,
  }) {
    final c = AppColors.of(accent, brightness, style);
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
    // Buttons: 28 px, a 5 px corner, the label in a medium weight, as a desktop app's.
    const shape = WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(5))));
    final label = WidgetStatePropertyAll(
        type.labelLarge!.copyWith(fontSize: 13, fontWeight: FontWeight.w500, letterSpacing: 0));
    const size = WidgetStatePropertyAll(Size(64, 28));
    const padding = WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12));
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
    // The default action: white on the accent, darkened while pressed, as a desktop button is.
    final fill = c.accentFill;
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
      side: WidgetStatePropertyAll(BorderSide(color: dark ? const Color(0xFF4A4A4F) : const Color(0xFFCFCFD4))),
    );
    // A secondary action (Cancel, an inline action): plain text that a hover puts on a tint.
    final text = button.copyWith(
      foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.disabled) ? c.textMuted.withValues(alpha: 0.5) : c.text),
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10)),
    );
    // A segmented control as on a desktop: a recessed well, the chosen segment raised out of it
    // in the window's own colour (not tinted with the accent).
    final segment = ButtonStyle(
      shape: shape,
      textStyle: label,
      minimumSize: const WidgetStatePropertyAll(Size(0, 26)),
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)),
      animationDuration: quick,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
      side: WidgetStatePropertyAll(BorderSide(color: c.line)),
      backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected)
          ? (dark ? const Color(0xFF4A4A4F) : Colors.white)
          : c.well),
      foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled)
          ? c.textMuted.withValues(alpha: 0.5)
          : s.contains(WidgetState.selected)
              ? c.text
              : c.textMuted),
      iconColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.text : c.textMuted),
      iconSize: const WidgetStatePropertyAll(15),
    );
    final strong = dark ? c.accent : c.accentStrong;
    // Dialogs and menus: in the dark, a step lighter than the window, as raised things are.
    final raised = dark ? const Color(0xFF2C2C2F) : c.surface;
    const fields = InputDecorationThemeData(
      isDense: true,
      contentPadding: EdgeInsets.symmetric(horizontal: 9, vertical: 8),
      border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(5))),
    );
    final menu = MenuStyle(
      backgroundColor: WidgetStatePropertyAll(raised),
      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      elevation: const WidgetStatePropertyAll(8),
      shadowColor: WidgetStatePropertyAll(Colors.black.withValues(alpha: dark ? 0.5 : 0.25)),
      padding: const WidgetStatePropertyAll(EdgeInsets.all(4)),
      shape: WidgetStatePropertyAll(_SteadyBorder(borderRadius: BorderRadius.circular(6), side: BorderSide(color: c.line))),
    );
    final outline = dark ? const Color(0xFF5C5C62) : const Color(0xFFB8B8BE);
    // A desktop's type scale: 13 px body text, titles a little larger and semibold.
    TextStyle? sized(TextStyle? style, double size, [FontWeight? weight]) =>
        style?.copyWith(fontSize: size, fontWeight: weight, letterSpacing: 0, height: style.height == null ? null : 1.3);
    TextStyle? tight(TextStyle? style) => style?.copyWith(letterSpacing: 0);
    final t = theme.textTheme;
    return theme.copyWith(
      colorScheme: theme.colorScheme.copyWith(
        surfaceContainerHigh: raised,
        surfaceContainerHighest: dark ? const Color(0xFF323236) : c.accentWash,
        outline: dark ? const Color(0xFF4A4A4F) : const Color(0xFFC4C4CA),
      ),
      tooltipTheme: theme.tooltipTheme.copyWith(
        // Inherited, as the classic one is: the two lerp into each other.
        textStyle: TextStyle(fontSize: 11.5, color: dark ? c.surface : Colors.white),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: dark ? const Color(0xFFE8E8EA) : const Color(0xE81D1D1F),
          borderRadius: BorderRadius.circular(5),
        ),
      ),
      popupMenuTheme: theme.popupMenuTheme.copyWith(
        color: raised,
        menuPadding: const EdgeInsets.all(4),
        shape: _SteadyBorder(borderRadius: BorderRadius.circular(6), side: BorderSide(color: c.line)),
      ),
      // Text set as the platform sets it: Material's tracking (up to 0.5 px between letters,
      // for small phone text) reads loose on a desktop.
      textTheme: t.copyWith(
        displayLarge: tight(t.displayLarge),
        displayMedium: tight(t.displayMedium),
        displaySmall: tight(t.displaySmall),
        headlineLarge: tight(t.headlineLarge),
        headlineMedium: tight(t.headlineMedium),
        headlineSmall: sized(t.headlineSmall, 20, FontWeight.w600),
        titleLarge: sized(t.titleLarge, 16, FontWeight.w600),
        titleMedium: sized(t.titleMedium, 14, FontWeight.w600),
        titleSmall: sized(t.titleSmall, 13, FontWeight.w600),
        bodyLarge: sized(t.bodyLarge, 14),
        bodyMedium: sized(t.bodyMedium, 13),
        bodySmall: sized(t.bodySmall, 11.5),
        labelLarge: sized(t.labelLarge, 13, FontWeight.w500),
        labelMedium: sized(t.labelMedium, 12, FontWeight.w500),
        labelSmall: sized(t.labelSmall, 11, FontWeight.w500),
      ),
      // A pointer, not a finger: no control padded out to 48 px.
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      // A slider's knob: white with a hairline and a soft shadow, no halo while dragged, no dots
      // along the track for its steps.
      sliderTheme: theme.sliderTheme.copyWith(
        thumbShape: _KnobThumbShape(outline: outline),
        tickMarkShape: SliderTickMarkShape.noTickMark,
        overlayColor: Colors.transparent,
        trackHeight: 4,
      ),
      checkboxTheme: CheckboxThemeData(
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(3))),
        side: WidgetStateBorderSide.resolveWith((s) =>
            s.contains(WidgetState.selected) ? BorderSide.none : BorderSide(color: outline, width: 1.5)),
        fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? strong : null),
        checkColor: WidgetStatePropertyAll(dark ? c.surface : Colors.white),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        splashRadius: 0,
        visualDensity: VisualDensity.compact,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: strong,
        linearTrackColor: c.line,
        linearMinHeight: 4,
        borderRadius: const BorderRadius.all(Radius.circular(2)),
        circularTrackColor: Colors.transparent,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: const WidgetStatePropertyAll(6),
        radius: const Radius.circular(3),
        thumbColor: WidgetStateProperty.resolveWith(
            (s) => c.textMuted.withValues(alpha: s.contains(WidgetState.dragged) ? 0.6 : s.contains(WidgetState.hovered) ? 0.45 : 0.3)),
      ),
      // Fields: a compact box, as the app's own fields (the time field, Export's) already are.
      // Only the outline's shape: a state's border here would win over a field's own `border`.
      inputDecorationTheme: fields,
      // Menus: a small radius, rows as tall as a desktop menu's.
      menuTheme: MenuThemeData(style: menu),
      dropdownMenuTheme: DropdownMenuThemeData(
        menuStyle: menu,
        textStyle: type.bodyMedium!.copyWith(fontSize: 13, letterSpacing: 0),
        inputDecorationTheme: fields,
      ),
      menuButtonTheme: MenuButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(0, 26)),
          padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 8)),
          shape: const WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(4)))),
          textStyle: WidgetStatePropertyAll(type.bodyMedium!.copyWith(fontSize: 13, letterSpacing: 0)),
          visualDensity: VisualDensity.compact,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(style: filled),
      elevatedButtonTheme: ElevatedButtonThemeData(style: filled),
      outlinedButtonTheme: OutlinedButtonThemeData(style: outlined),
      textButtonTheme: TextButtonThemeData(style: text),
      segmentedButtonTheme: SegmentedButtonThemeData(style: segment),
      dialogTheme: theme.dialogTheme.copyWith(
        backgroundColor: raised,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: dark ? c.line : Colors.transparent)),
        titleTextStyle: type.titleLarge!.copyWith(fontSize: 15, fontWeight: FontWeight.w600, color: c.text, letterSpacing: 0),
        contentTextStyle: type.bodyMedium!.copyWith(fontSize: 13, height: 1.4, color: c.text, letterSpacing: 0),
        actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
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
      chrome: l(chrome, other.chrome),
      well: l(well, other.well),
    );
  }
}

/// [UiStyle.refined]'s slider knob: a white disc with a hairline outline and a soft shadow, the
/// same size pressed or not (its value shows in the bubble instead).
class _KnobThumbShape extends SliderComponentShape {
  const _KnobThumbShape({required this.outline});
  final Color outline;
  static const _radius = 8.0;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => const Size.fromRadius(_radius);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final canvas = context.canvas;
    final enabled = enableAnimation.value;
    canvas.drawCircle(center.translate(0, 0.8), _radius,
        Paint()..color = Color.fromRGBO(0, 0, 0, 0.22 * enabled)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5));
    canvas.drawCircle(center, _radius, Paint()..color = Color.lerp(outline, Colors.white, 0.4 + 0.6 * enabled)!);
    canvas.drawCircle(center, _radius - 0.5, Paint()..color = outline..style = PaintingStyle.stroke..strokeWidth = 1);
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
