import 'dart:math' as math;

import 'package:flutter/material.dart';

/// An accent colour (Settings ▸ Appearance): one of the swatches, [values], or one of the user's
/// own ([AccentColor.custom]), from which each style works out the shades it needs.
@immutable
class AccentColor {
  const AccentColor._(this.name, this.label, this.color, this.strong, this.carbon);

  /// [color] as the user chose it: its strong shade and its IBM-like grades worked out from it.
  factory AccentColor.custom(Color color) {
    color = color.withValues(alpha: 1);
    final hsl = HSLColor.fromColor(color);
    Color at(double lightness, [double saturation = 1]) =>
        hsl.withLightness(lightness.clamp(0, 1)).withSaturation((hsl.saturation * saturation).clamp(0, 1)).toColor();
    final l = hsl.lightness;
    final fill = math.min(l, 0.42); // white reads on it, as on Carbon's 60 grades
    return AccentColor._(
      'custom',
      'Custom',
      color,
      at(math.min(l - 0.1, 0.5)),
      CarbonHue(at(fill), at(fill - 0.05), at(fill - 0.18), at(0.9, 0.9), at(math.max(l, 0.55)), at(math.max(l, 0.68)),
          at(0.2)),
    );
  }

  static const sky = AccentColor._('sky', 'Sky', Color(0xFF4DA8F0), Color(0xFF1F8AE0),
      // Blue: Carbon's own $interactive, $button-primary(-hover, -active) and $highlight.
      CarbonHue(Color(0xFF0F62FE), Color(0xFF0050E6), Color(0xFF002D9C), Color(0xFFD0E2FF), Color(0xFF4589FF),
          Color(0xFF78A9FF), Color(0xFF002D9C)));
  static const indigo = AccentColor._('indigo', 'Indigo', Color(0xFF6D7BEA), Color(0xFF4454D6),
      CarbonHue(Color(0xFF6929C4), Color(0xFF5923A8), Color(0xFF491D8B), Color(0xFFE8DAFF), Color(0xFFA56EFF),
          Color(0xFFBE95FF), Color(0xFF491D8B))); // Purple 70
  static const cyan = AccentColor._('cyan', 'Cyan', Color(0xFF3BB8D6), Color(0xFF168FAD),
      CarbonHue(Color(0xFF0072C3), Color(0xFF0066AF), Color(0xFF003A6D), Color(0xFFBAE6FF), Color(0xFF1192E8),
          Color(0xFF33B1FF), Color(0xFF003A6D)));
  static const teal = AccentColor._('teal', 'Teal', Color(0xFF2BB3A3), Color(0xFF12897C),
      CarbonHue(Color(0xFF007D79), Color(0xFF006D6B), Color(0xFF004144), Color(0xFF9EF0F0), Color(0xFF009D9A),
          Color(0xFF08BDBA), Color(0xFF004144)));
  static const green = AccentColor._('green', 'Green', Color(0xFF5CBF6A), Color(0xFF2F9441),
      CarbonHue(Color(0xFF198038), Color(0xFF166F31), Color(0xFF044317), Color(0xFFA7F0BA), Color(0xFF24A148),
          Color(0xFF42BE65), Color(0xFF044317)));
  static const violet = AccentColor._('violet', 'Violet', Color(0xFFA078E3), Color(0xFF7C4DCF),
      CarbonHue(Color(0xFF8A3FFC), Color(0xFF7A34E0), Color(0xFF491D8B), Color(0xFFE8DAFF), Color(0xFFBE95FF),
          Color(0xFFD4BBFF), Color(0xFF491D8B))); // Purple 60
  static const rose = AccentColor._('rose', 'Rose', Color(0xFFEC7393), Color(0xFFD1456A),
      CarbonHue(Color(0xFFD02670), Color(0xFFB81F62), Color(0xFF740937), Color(0xFFFFD6E8), Color(0xFFEE5396),
          Color(0xFFFF7EB6), Color(0xFF740937))); // Magenta
  static const amber = AccentColor._('amber', 'Amber', Color(0xFFF2A83E), Color(0xFFC77D12),
      CarbonHue(Color(0xFFBA4E00), Color(0xFFA24300), Color(0xFF5E2900), Color(0xFFFFD9BE), Color(0xFFEB6200),
          Color(0xFFFF832B), Color(0xFF5E2900))); // Orange
  static const sand = AccentColor._('sand', 'Sand', Color(0xFFB09A86), Color(0xFF85705D),
      CarbonHue(Color(0xFF736F6F), Color(0xFF635F5F), Color(0xFF3C3838), Color(0xFFE5E0DF), Color(0xFF8F8B8B),
          Color(0xFFADA8A8), Color(0xFF3C3838))); // Warm Gray
  static const graphite = AccentColor._('graphite', 'Graphite', Color(0xFF8A94A1), Color(0xFF59636F),
      CarbonHue(Color(0xFF697077), Color(0xFF5B6268), Color(0xFF343A3F), Color(0xFFDDE1E6), Color(0xFF878D96),
          Color(0xFFA2A9B0), Color(0xFF343A3F))); // Cool Gray

  /// The swatches, in the order shown.
  static const values = [sky, indigo, cyan, teal, green, violet, rose, amber, sand, graphite];

  /// The swatch saved as [name]; null for another name (a custom one is saved as its colour).
  static AccentColor? named(String? name) => values.where((a) => a.name == name).firstOrNull;

  /// What it is saved as: a swatch's name, or "custom".
  final String name;
  final String label;
  final Color color;

  /// The darker shade for lines and selected things on a light background.
  final Color strong;

  /// The IBM hue that stands in for it in [UiStyle.carbon].
  final CarbonHue carbon;

  bool get isCustom => name == 'custom';

  @override
  bool operator ==(Object other) => other is AccentColor && other.name == name && other.color == color;

  @override
  int get hashCode => Object.hash(name, color);
}

/// How the controls look (Settings ▸ Appearance ▸ Style), the same on every platform.
enum UiStyle {
  /// Quiet desktop controls: soft corners, a small switch, no ripples.
  refined('Refined'),

  /// IBM's Carbon Design System: square corners, IBM Plex, Carbon's tokens and controls.
  carbon('Carbon');

  const UiStyle(this.label);
  final String label;

  /// The style saved as [name]; Classic, which is gone, is Refined.
  static UiStyle? named(String? name) => name == 'classic' ? refined : values.asNameMap()[name];
}

/// How big the interface's text is (Settings ▸ Appearance ▸ Text size): the score's is its own.
enum TextSize {
  small('Small', 0.9),
  medium('Medium', 1),
  large('Large', 1.15);

  const TextSize(this.label, this.scale);
  final String label;
  final double scale;
}

/// How tightly the interface is set (Settings ▸ Appearance ▸ Density): toolbars, their controls,
/// rows and menus; a dialog's fields stay as they are.
enum UiDensity {
  compact('Compact'),
  standard('Standard'),
  roomy('Roomy');

  const UiDensity(this.label);
  final String label;
}

/// A [UiStyle]'s measures and motion, which the app's widgets read rather than asking which
/// style it is: corners, control sizes, menu rows, how long things take. Read it with
/// [AppStyle.of]; a theme without one (a bare [MaterialApp]'s) is [refined].
@immutable
class AppStyle extends ThemeExtension<AppStyle> {
  const AppStyle._({
    required this.style,
    this.density = UiDensity.standard,
    this.still = false,
    required this.rounded,
    required this.control,
    required this.toolbar,
    required this.panelBar,
    required this.field,
    required this.fieldInset,
    required this.row,
    required this.menuRow,
    required this.menuInset,
    required this.menuOpen,
    required this.menuClose,
    required this.curve,
    required this.enterCurve,
    required this.exitCurve,
  });

  static const refined = AppStyle._(
    style: UiStyle.refined,
    rounded: true,
    control: 28,
    toolbar: 38,
    panelBar: 36,
    field: 36,
    fieldInset: 10,
    row: 34,
    menuRow: 22,
    menuInset: 8,
    menuOpen: Duration(milliseconds: 190),
    menuClose: Duration(milliseconds: 120),
    curve: Curves.easeOutCubic,
    enterCurve: Curves.easeOutCubic,
    exitCurve: Curves.easeIn,
  );

  /// Carbon at its small (sm, 32 px) size for controls, medium (40 px) for a dialog's fields, and
  /// extra-small (24 px) menu rows; its productive motion curves.
  static const carbon = AppStyle._(
    style: UiStyle.carbon,
    rounded: false,
    control: 32,
    toolbar: 40,
    panelBar: 40,
    field: 40,
    fieldInset: 16,
    row: 32,
    menuRow: 24,
    menuInset: 16,
    menuOpen: Duration(milliseconds: 110), // $duration-fast-02
    menuClose: Duration(milliseconds: 70), // $duration-fast-01
    curve: Cubic(0.2, 0, 0.38, 0.9), // motion(standard, productive)
    enterCurve: Cubic(0, 0, 0.38, 0.9), // motion(entrance, productive)
    exitCurve: Cubic(0.2, 0, 1, 0.9), // motion(exit, productive)
  );

  factory AppStyle.of(BuildContext context) => Theme.of(context).extension<AppStyle>() ?? refined;

  static AppStyle forStyle(UiStyle style, {UiDensity density = UiDensity.standard, bool still = false}) =>
      switch (style) { UiStyle.refined => refined, UiStyle.carbon => carbon }.at(density, still: still);

  /// This style at [density]: controls and toolbars 4 px smaller or bigger, rows and menus 2 (a
  /// whole Carbon size step, xs 24 px, crowds the toolbars' icons).
  /// [still]: with no motion (Settings ▸ Appearance ▸ Reduce motion).
  AppStyle at(UiDensity density, {bool still = false}) {
    if (density == this.density && still == this.still) return this;
    final step = 4.0 * (density.index - this.density.index);
    return AppStyle._(
      style: style,
      density: density,
      still: still,
      rounded: rounded,
      control: control + step,
      toolbar: toolbar + step,
      panelBar: panelBar + step,
      field: field,
      fieldInset: fieldInset,
      row: row + step / 2,
      menuRow: math.max(rounded ? 20 : 24, menuRow + step / 2),
      menuInset: menuInset,
      menuOpen: still ? Duration.zero : menuOpen,
      menuClose: still ? Duration.zero : menuClose,
      curve: curve,
      enterCurve: enterCurve,
      exitCurve: exitCurve,
    );
  }

  final UiStyle style;
  final UiDensity density;

  /// Whether the interface keeps still: every [duration] none (the score still moves).
  final bool still;

  /// [duration], or none while the interface keeps [still]: for motion not given as Material's.
  Duration moving(Duration duration) => still ? Duration.zero : duration;
  bool get isCarbon => style == UiStyle.carbon;

  /// Whether corners are rounded: Carbon's are square (but a toggle's and a radio's).
  final bool rounded;

  /// A toolbar's buttons and fields, square.
  final double control;

  /// The editor's toolbar, and the bottom panel's bar.
  final double toolbar, panelBar;

  /// A dialog's field, and how far its text is in from the field's edge (the same in a text
  /// field and a select, so what is typed and what is chosen start at one place).
  final double field, fieldInset;

  /// A dialog's row (a check row; a list in a dialog is this many rows tall).
  final double row;

  /// A menu's row, and how far its text is in.
  final double menuRow, menuInset;
  final Duration menuOpen, menuClose;

  /// Motion: a change in place, something coming in, something going.
  final Curve curve, enterCurve, exitCurve;

  /// [radius] px of rounding as [refined] has it, here.
  double corner(double radius) => rounded ? radius : 0;
  BorderRadius radius(double radius) => BorderRadius.circular(corner(radius));

  /// [ms] of Material's motion, as this style has it: Refined's about three quarters as long,
  /// Carbon's on its own duration steps.
  Duration duration(int ms) {
    if (still) return Duration.zero;
    if (rounded) return Duration(milliseconds: (ms * 0.775).round());
    const steps = [70, 110, 150, 240, 400, 700]; // $duration-fast-01 … $duration-slow-02
    final want = ms * 0.7;
    return Duration(milliseconds: steps.reduce((a, b) => (b - want).abs() < (a - want).abs() ? b : a));
  }

  @override
  AppStyle copyWith() => this;

  @override
  AppStyle lerp(AppStyle? other, double t) => t < 0.5 || other == null ? this : other;
}

/// An IBM palette hue standing in for an [AccentColor] in [UiStyle.carbon]: its grades for a
/// light theme (the 60 a button's fill, 20 a highlight) and for Gray 100 (50 and 40, 80).
@immutable
class CarbonHue {
  const CarbonHue(this.fill, this.hover, this.active, this.soft, this.dark, this.darkStrong, this.darkSoft);
  final Color fill, hover, active, soft, dark, darkStrong, darkSoft;
}

/// [UiStyle.carbon]'s tokens beyond the shared [AppColors], named as Carbon names them: the
/// White theme's, or in the dark Gray 100's. Read it with [CarbonColors.of] in a Carbon theme.
@immutable
class CarbonColors extends ThemeExtension<CarbonColors> {
  const CarbonColors._({
    required this.layer01,
    required this.layer02,
    required this.layerHover,
    required this.layerSelected,
    required this.layerAccent,
    required this.field,
    required this.borderSubtle,
    required this.borderStrong,
    required this.borderInverse,
    required this.textPrimary,
    required this.textSecondary,
    required this.textHelper,
    required this.textPlaceholder,
    required this.textDisabled,
    required this.textInverse,
    required this.backgroundInverse,
    required this.selectedInverse,
    required this.backgroundHover,
    required this.backgroundActive,
    required this.backgroundSelected,
    required this.focus,
    required this.focusInset,
    required this.primary,
    required this.primaryHover,
    required this.primaryActive,
    required this.secondary,
    required this.secondaryHover,
    required this.secondaryActive,
    required this.tertiary,
    required this.tertiaryHover,
    required this.tertiaryActive,
    required this.onTertiaryHover,
    required this.buttonDisabled,
    required this.onColorDisabled,
    required this.link,
    required this.linkHover,
    required this.error,
    required this.success,
    required this.toggleOff,
    required this.overlay,
  });

  factory CarbonColors.of(AccentColor accent, Brightness brightness) {
    final h = accent.carbon;
    if (brightness == Brightness.light) {
      return CarbonColors._(
        layer01: const Color(0xFFF4F4F4),
        layer02: const Color(0xFFFFFFFF),
        layerHover: const Color(0xFFE8E8E8),
        layerSelected: const Color(0xFFE0E0E0),
        layerAccent: const Color(0xFFE0E0E0),
        field: const Color(0xFFFFFFFF), // $field-02: fields sit on a layer (a dialog, a toolbar)
        borderSubtle: const Color(0xFFC6C6C6),
        borderStrong: const Color(0xFF8D8D8D),
        borderInverse: const Color(0xFF161616),
        textPrimary: const Color(0xFF161616),
        textSecondary: const Color(0xFF525252),
        textHelper: const Color(0xFF6F6F6F),
        textPlaceholder: const Color(0xFFA8A8A8),
        textDisabled: const Color(0x40161616),
        textInverse: const Color(0xFFFFFFFF),
        backgroundInverse: const Color(0xFF393939),
        selectedInverse: const Color(0xFF161616),
        backgroundHover: const Color(0x1F8D8D8D),
        backgroundActive: const Color(0x808D8D8D),
        backgroundSelected: const Color(0x338D8D8D),
        focus: h.fill,
        focusInset: const Color(0xFFFFFFFF),
        primary: h.fill,
        primaryHover: h.hover,
        primaryActive: h.active,
        secondary: const Color(0xFF393939),
        secondaryHover: const Color(0xFF474747),
        secondaryActive: const Color(0xFF6F6F6F),
        tertiary: h.fill,
        tertiaryHover: h.hover,
        tertiaryActive: h.active,
        onTertiaryHover: const Color(0xFFFFFFFF),
        buttonDisabled: const Color(0xFFC6C6C6),
        onColorDisabled: const Color(0xFF8D8D8D),
        link: h.fill,
        linkHover: h.active,
        error: const Color(0xFFDA1E28),
        success: const Color(0xFF24A148),
        toggleOff: const Color(0xFF8D8D8D),
        overlay: const Color(0x80161616),
      );
    }
    return CarbonColors._(
      layer01: const Color(0xFF262626),
      layer02: const Color(0xFF393939),
      layerHover: const Color(0xFF333333),
      layerSelected: const Color(0xFF393939),
      layerAccent: const Color(0xFF393939),
      field: const Color(0xFF393939),
      borderSubtle: const Color(0xFF525252),
      borderStrong: const Color(0xFF6F6F6F),
      borderInverse: const Color(0xFFF4F4F4),
      textPrimary: const Color(0xFFF4F4F4),
      textSecondary: const Color(0xFFC6C6C6),
      textHelper: const Color(0xFFA8A8A8),
      textPlaceholder: const Color(0xFF6F6F6F),
      textDisabled: const Color(0x40F4F4F4),
      textInverse: const Color(0xFF161616),
      backgroundInverse: const Color(0xFFF4F4F4),
      selectedInverse: const Color(0xFFF4F4F4),
      backgroundHover: const Color(0x298D8D8D),
      backgroundActive: const Color(0x668D8D8D),
      backgroundSelected: const Color(0x3D8D8D8D),
      focus: const Color(0xFFFFFFFF),
      focusInset: const Color(0xFF161616),
      primary: h.fill,
      primaryHover: h.hover,
      primaryActive: h.active,
      secondary: const Color(0xFF6F6F6F),
      secondaryHover: const Color(0xFF5E5E5E),
      secondaryActive: const Color(0xFF393939),
      tertiary: const Color(0xFFFFFFFF),
      tertiaryHover: const Color(0xFFF4F4F4),
      tertiaryActive: const Color(0xFFC6C6C6),
      onTertiaryHover: const Color(0xFF161616),
      buttonDisabled: const Color(0xFF525252),
      onColorDisabled: const Color(0xFF8D8D8D),
      link: h.darkStrong,
      linkHover: Color.lerp(h.darkStrong, Colors.white, 0.35)!,
      error: const Color(0xFFFA4D56),
      success: const Color(0xFF42BE65),
      toggleOff: const Color(0xFF6F6F6F),
      overlay: const Color(0xA6000000),
    );
  }

  /// The theme's; null outside a Carbon theme.
  static CarbonColors? maybeOf(BuildContext context) => Theme.of(context).extension<CarbonColors>();

  final Color layer01, layer02, layerHover, layerSelected, layerAccent, field;
  final Color borderSubtle, borderStrong, borderInverse;
  final Color textPrimary, textSecondary, textHelper, textPlaceholder, textDisabled, textInverse;

  /// A tooltip's fill, and a content switcher's chosen segment ($layer-selected-inverse).
  final Color backgroundInverse, selectedInverse;
  final Color backgroundHover, backgroundActive, backgroundSelected;
  final Color focus, focusInset;
  final Color primary, primaryHover, primaryActive;
  final Color secondary, secondaryHover, secondaryActive;
  final Color tertiary, tertiaryHover, tertiaryActive, onTertiaryHover;
  final Color buttonDisabled, onColorDisabled;
  final Color link, linkHover;
  final Color error, success, toggleOff, overlay;

  @override
  CarbonColors copyWith() => this;

  @override
  CarbonColors lerp(CarbonColors? other, double t) => t < 0.5 || other == null ? this : other;
}

/// Carbon's focus: a 2 px ring in $focus and inside it 1 px of $focus-inset, so it shows on a
/// filled button too. A square [OutlinedBorder] a button's shape takes while focused.
class CarbonFocusBorder extends RoundedRectangleBorder {
  const CarbonFocusBorder({required this.focus, required this.inset});
  final Color focus, inset;

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) => this;

  @override
  ShapeBorder? lerpTo(ShapeBorder? b, double t) => b;

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    canvas.drawRect(rect.deflate(1), Paint()..color = focus..style = PaintingStyle.stroke..strokeWidth = 2);
    canvas.drawRect(rect.deflate(2.5), Paint()..color = inset..style = PaintingStyle.stroke..strokeWidth = 1);
  }
}

/// The score's "digital paper" and its ink, alike in every style: black on white, or in the dark
/// light ink on dark paper (the engraving is recoloured as it is drawn, see ScoreRenderer).
/// Video export draws on these.
abstract final class ScorePaper {
  static Color paper(Brightness brightness) =>
      brightness == Brightness.light ? const Color(0xFFFFFFFF) : const Color(0xFF17191C);
  static Color ink(Brightness brightness) =>
      brightness == Brightness.light ? const Color(0xFF14171A) : const Color(0xFFE3E4E0);
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
    required this.chrome,
    required this.well,
    this._fill,
  });

  /// The palette for [style].
  factory AppColors.of(AccentColor accent, Brightness brightness, [UiStyle style = UiStyle.refined]) =>
      switch (style) {
        UiStyle.refined => AppColors._refinedOf(accent, brightness),
        UiStyle.carbon => AppColors._carbonOf(accent, brightness),
      };

  /// [UiStyle.carbon]'s palette: the White theme ($background white, $layer-01 #f4f4f4 for the
  /// chrome) or Gray 100, the accent an IBM hue ([CarbonHue]).
  factory AppColors._carbonOf(AccentColor accent, Brightness brightness) {
    final h = accent.carbon;
    final light = brightness == Brightness.light;
    final surface = light ? const Color(0xFFFFFFFF) : const Color(0xFF161616);
    final a = light ? h.fill : h.dark;
    return AppColors(
      accent: a,
      accentStrong: light ? h.fill : h.darkStrong,
      accentSoft: light ? h.soft : h.darkSoft,
      accentWash: light ? const Color(0xFFF4F4F4) : const Color(0xFF262626),
      fill: h.fill,
      surface: surface,
      chrome: light ? const Color(0xFFF4F4F4) : const Color(0xFF262626),
      well: light ? const Color(0xFFE0E0E0) : const Color(0xFF393939),
      line: light ? const Color(0xFFE0E0E0) : const Color(0xFF393939),
      grid: light ? const Color(0xFFE0E0E0) : const Color(0xFF393939),
      activity: light ? const Color(0xFFC6C6C6) : const Color(0xFF525252),
      text: light ? const Color(0xFF161616) : const Color(0xFFF4F4F4),
      textMuted: light ? const Color(0xFF525252) : const Color(0xFFC6C6C6),
      erase: light ? const Color(0xFFDA1E28) : const Color(0xFFFA4D56),
      recording: light ? const Color(0xFFDA1E28) : const Color(0xFFFA4D56),
      recordingWash: light ? const Color(0xFFFFF1F1) : const Color(0xFF2D0709),
      waveform: Color.lerp(surface, a, light ? 0.62 : 0.7)!,
      onset: light ? const Color(0xFF8D8D8D) : const Color(0xFF6F6F6F),
      scorePaper: ScorePaper.paper(brightness),
      scoreInk: ScorePaper.ink(brightness),
    );
  }

  /// [UiStyle.refined]'s palette: neutral greys (Material's would mix the accent into every
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
        scorePaper: ScorePaper.paper(brightness),
        scoreInk: ScorePaper.ink(brightness),
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
      scorePaper: ScorePaper.paper(brightness),
      scoreInk: ScorePaper.ink(brightness),
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

  /// Behind toolbars and sidebars: a step off [surface].
  final Color chrome;

  /// The recess of a segmented control, the chosen segment raised out of it.
  final Color well;

  /// A solid accent for white to read on (the default button, a selected sidebar row): the
  /// style's own (Carbon's $button-primary), or the strong shade darkened where it is light
  /// (amber, and every accent's dark-theme shade).
  Color get accentFill {
    if (_fill case final fill?) return fill;
    final hsl = HSLColor.fromColor(accentStrong);
    return hsl.withLightness(hsl.lightness.clamp(0, 0.42)).toColor();
  }

  final Color? _fill;

  static ThemeData theme({
    AccentColor accent = AccentColor.sky,
    Brightness brightness = Brightness.light,
    UiStyle style = UiStyle.refined,
    UiDensity density = UiDensity.standard,
    bool still = false,
  }) {
    final c = AppColors.of(accent, brightness, style);
    final measures = AppStyle.forStyle(style, density: density, still: still);
    final dark = brightness == Brightness.dark;
    final carbon = style == UiStyle.carbon ? CarbonColors.of(accent, brightness) : null;
    // Material's theme, in the style's palette, under the style's own: what it doesn't set.
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
      fontFamily: carbon == null ? null : carbonFont,
      fontFamilyFallback: carbon == null ? null : carbonFontFallback,
      scaffoldBackgroundColor: c.surface,
      canvasColor: c.surface,
      dividerColor: c.line,
      visualDensity: VisualDensity.compact,
      extensions: [c, measures, ?carbon],
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
    return carbon == null ? _refined(theme, c, measures, dark) : _carbon(theme, c, measures, carbon, dark);
  }

  /// Carbon's typeface, IBM Plex Sans (bundled: Light, Regular, SemiBold), and what stands in for
  /// a glyph it hasn't.
  static const carbonFont = 'IBM Plex Sans';
  static const carbonFontFallback = ['Helvetica Neue', 'Arial', 'sans-serif'];

  /// [UiStyle.refined] over Material's: what a desktop app does, not a phone. A press
  /// shows as a tint, not a ripple, and a hover as a fainter one.
  static ThemeData _refined(ThemeData theme, AppColors c, AppStyle m, bool dark) {
    // Text styles as Theme.of gives them (merged with the typography's geometry, not
    // inherited): a button lerps its label from one style to the other when the style changes,
    // and two text styles lerp only when both inherit or neither does.
    final type = theme.typography.englishLike.merge(theme.textTheme);
    // Buttons: 28 px (the density's control), a 5 px corner, the label in a medium weight, as a desktop app's.
    const shape = WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(5))));
    final label = WidgetStatePropertyAll(
        type.labelLarge!.copyWith(fontSize: 13, fontWeight: FontWeight.w500, letterSpacing: 0));
    final size = WidgetStatePropertyAll(Size(64, m.control));
    const padding = WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12));
    const quick = Duration(milliseconds: 95);
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
        // Inherited, as Material's is: the two lerp into each other.
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
          // 22 px rows (the density's), as a popup menu's and a desktop menu's.
          minimumSize: WidgetStatePropertyAll(Size(0, m.menuRow)),
          padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 8)),
          shape: const WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(4)))),
          textStyle: WidgetStatePropertyAll(type.bodyMedium!.copyWith(fontSize: 13, letterSpacing: 0)),
          visualDensity: VisualDensity.standard,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(style: filled),
      elevatedButtonTheme: ElevatedButtonThemeData(style: filled),
      outlinedButtonTheme: OutlinedButtonThemeData(style: outlined),
      textButtonTheme: TextButtonThemeData(style: text),
      dialogTheme: theme.dialogTheme.copyWith(
        backgroundColor: raised,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: dark ? c.line : Colors.transparent)),
        titleTextStyle: type.titleLarge!.copyWith(fontSize: 18, fontWeight: FontWeight.w600, color: c.text, letterSpacing: 0),
        contentTextStyle: type.bodyMedium!.copyWith(fontSize: 14, height: 1.45, color: c.text, letterSpacing: 0),
        actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      ),
      splashFactory: NoSplash.splashFactory,
      splashColor: Colors.transparent,
      hoverColor: c.text.withValues(alpha: dark ? 0.06 : 0.045),
      highlightColor: c.text.withValues(alpha: dark ? 0.1 : 0.08),
      focusColor: c.accent.withValues(alpha: 0.14),
    );
  }

  /// [UiStyle.carbon] over Material's: IBM's Carbon Design System as its components are specified
  /// (v11): no corners, Plex on Carbon's productive type set, sm (32 px) buttons whose label sits
  /// at the left with room at the right, fields filled with a line under them, a 2 px focus ring,
  /// and state shown by fills ($background-hover, $background-active), never ripples.
  static ThemeData _carbon(ThemeData theme, AppColors c, AppStyle m, CarbonColors k, bool dark) {
    final type = theme.typography.englishLike.merge(theme.textTheme);
    final t = theme.textTheme;
    // Carbon's type tokens: size / line height, its tracking, and weight (Plex Regular or SemiBold).
    TextStyle? set(TextStyle? style, double size, double line, double tracking, [FontWeight weight = FontWeight.w400]) =>
        style?.copyWith(
            fontSize: size, height: style.height == null ? null : line / size, letterSpacing: tracking, fontWeight: weight);
    const square = RoundedRectangleBorder();
    final focusRing = CarbonFocusBorder(focus: k.focus, inset: k.focusInset);
    WidgetStateProperty<OutlinedBorder> shape([BorderSide side = BorderSide.none]) =>
        WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.focused) && !s.contains(WidgetState.pressed)
            ? focusRing
            : RoundedRectangleBorder(side: side));
    // body-compact-01, as Carbon sets a button's label.
    final label = type.labelLarge!.copyWith(fontSize: 14, fontWeight: FontWeight.w400, letterSpacing: 0.16, height: 18 / 14);
    WidgetStateProperty<Color?> states(Color rest, {Color? hover, Color? press, Color? disabled}) =>
        WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled)
            ? disabled
            : s.contains(WidgetState.pressed)
                ? press ?? rest
                : s.contains(WidgetState.hovered)
                    ? hover ?? rest
                    : rest);
    final button = ButtonStyle(
      shape: shape(),
      textStyle: WidgetStatePropertyAll(label),
      minimumSize: WidgetStatePropertyAll(Size(0, m.control)),
      // The condensed density's inline padding: the label at the left, room for an icon at the right.
      padding: const WidgetStatePropertyAll(EdgeInsets.fromLTRB(7, 0, 39, 0)),
      alignment: Alignment.centerLeft,
      animationDuration: const Duration(milliseconds: 70),
      visualDensity: VisualDensity.standard,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      elevation: const WidgetStatePropertyAll(0),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      splashFactory: NoSplash.splashFactory,
    );
    final primary = button.copyWith(
      backgroundColor: states(k.primary, hover: k.primaryHover, press: k.primaryActive, disabled: k.buttonDisabled),
      foregroundColor: states(Colors.white, disabled: k.onColorDisabled),
    );
    // Tertiary: an outline in the accent, filled while hovered.
    final tertiary = button.copyWith(
      backgroundColor: states(Colors.transparent, hover: k.tertiaryHover, press: k.tertiaryActive, disabled: Colors.transparent),
      foregroundColor: states(k.tertiary, hover: k.onTertiaryHover, press: k.onTertiaryHover, disabled: k.textDisabled),
      shape: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.focused) && !s.contains(WidgetState.pressed)
          ? focusRing
          : RoundedRectangleBorder(side: BorderSide(color: s.contains(WidgetState.disabled) ? k.buttonDisabled : k.tertiary))),
    );
    // Ghost: the accent's link colour on nothing, a hover's fill under it.
    final ghost = button.copyWith(
      backgroundColor: states(Colors.transparent, hover: k.backgroundHover, press: k.backgroundActive),
      foregroundColor: states(k.link, hover: k.linkHover, press: k.linkHover, disabled: k.textDisabled),
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 7)),
    );
    final menu = MenuStyle(
      backgroundColor: WidgetStatePropertyAll(k.layer01),
      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      elevation: const WidgetStatePropertyAll(6),
      shadowColor: WidgetStatePropertyAll(Colors.black.withValues(alpha: dark ? 0.8 : 0.3)),
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 4)),
      shape: const WidgetStatePropertyAll(_SteadyBorder()),
    );
    final menuText = type.bodyMedium!.copyWith(fontSize: 14, letterSpacing: 0.16);
    final fields = InputDecorationThemeData(
      isDense: true,
      filled: true,
      fillColor: k.field,
      hoverColor: k.layerHover,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      hintStyle: TextStyle(color: k.textPlaceholder),
      // Only the shape: a state's border here would win over a field's own `border`.
      border: UnderlineInputBorder(borderRadius: BorderRadius.zero, borderSide: BorderSide(color: k.borderStrong)),
    );
    return theme.copyWith(
      colorScheme: theme.colorScheme.copyWith(
        primary: c.accent,
        surfaceContainerHigh: k.layer01,
        surfaceContainerHighest: k.layerAccent,
        outline: k.borderStrong,
        error: k.error,
      ),
      textTheme: t.copyWith(
        displayLarge: set(t.displayLarge, 42, 50, 0, FontWeight.w300), // heading-06
        displayMedium: set(t.displayMedium, 32, 40, 0), // heading-05
        displaySmall: set(t.displaySmall, 28, 36, 0), // heading-04
        headlineLarge: set(t.headlineLarge, 28, 36, 0),
        headlineMedium: set(t.headlineMedium, 20, 28, 0),
        headlineSmall: set(t.headlineSmall, 20, 28, 0), // heading-03
        titleLarge: set(t.titleLarge, 20, 28, 0), // heading-03
        titleMedium: set(t.titleMedium, 16, 22, 0, FontWeight.w600), // heading-compact-02
        titleSmall: set(t.titleSmall, 14, 18, 0.16, FontWeight.w600), // heading-compact-01
        bodyLarge: set(t.bodyLarge, 16, 22, 0), // body-compact-02
        bodyMedium: set(t.bodyMedium, 14, 18, 0.16), // body-compact-01
        bodySmall: set(t.bodySmall, 12, 16, 0.32), // label-01, helper-text-01
        labelLarge: set(t.labelLarge, 14, 18, 0.16),
        labelMedium: set(t.labelMedium, 12, 16, 0.32),
        labelSmall: set(t.labelSmall, 12, 16, 0.32),
      ),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      tooltipTheme: theme.tooltipTheme.copyWith(
        textStyle: TextStyle(fontSize: 14, letterSpacing: 0.16, color: k.textInverse),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        decoration: BoxDecoration(color: k.backgroundInverse, borderRadius: BorderRadius.circular(2)),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          foregroundColor: states(k.textPrimary, disabled: k.textDisabled),
          backgroundColor: states(Colors.transparent, hover: k.backgroundHover, press: k.backgroundActive),
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          shape: shape(),
          splashFactory: NoSplash.splashFactory,
          animationDuration: const Duration(milliseconds: 70), // $duration-fast-01
        ),
      ),
      popupMenuTheme: theme.popupMenuTheme.copyWith(
        color: k.layer01,
        elevation: 6,
        shadowColor: Colors.black.withValues(alpha: dark ? 0.8 : 0.3),
        menuPadding: const EdgeInsets.symmetric(vertical: 4),
        textStyle: menuText.copyWith(color: k.textSecondary),
        labelTextStyle: WidgetStatePropertyAll(menuText.copyWith(color: k.textPrimary)),
        shape: const _SteadyBorder(),
      ),
      sliderTheme: theme.sliderTheme.copyWith(
        activeTrackColor: k.borderInverse,
        inactiveTrackColor: k.borderSubtle,
        thumbColor: k.selectedInverse,
        trackHeight: 2,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7, elevation: 0, pressedElevation: 0),
        trackShape: const RectangularSliderTrackShape(),
        tickMarkShape: SliderTickMarkShape.noTickMark,
        overlayColor: Colors.transparent,
        valueIndicatorColor: k.backgroundInverse,
        valueIndicatorTextStyle: TextStyle(fontSize: 12, letterSpacing: 0.32, color: k.textInverse),
      ),
      checkboxTheme: CheckboxThemeData(
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(2))),
        side: WidgetStateBorderSide.resolveWith((s) => s.contains(WidgetState.selected)
            ? BorderSide.none
            : BorderSide(color: s.contains(WidgetState.disabled) ? k.textDisabled : k.textPrimary)),
        fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected)
            ? (s.contains(WidgetState.disabled) ? k.textDisabled : k.textPrimary)
            : Colors.transparent),
        checkColor: WidgetStatePropertyAll(c.surface),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        splashRadius: 0,
        visualDensity: VisualDensity.compact,
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStatePropertyAll(k.textPrimary),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        splashRadius: 0,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: c.accent,
        linearTrackColor: k.layerAccent,
        linearMinHeight: 4,
        borderRadius: BorderRadius.zero,
        circularTrackColor: Colors.transparent,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: const WidgetStatePropertyAll(6),
        radius: Radius.zero,
        thumbColor: WidgetStateProperty.resolveWith((s) =>
            k.borderStrong.withValues(alpha: s.contains(WidgetState.dragged) ? 1 : s.contains(WidgetState.hovered) ? 0.8 : 0.55)),
      ),
      inputDecorationTheme: fields,
      menuTheme: MenuThemeData(style: menu),
      dropdownMenuTheme: DropdownMenuThemeData(menuStyle: menu, textStyle: menuText, inputDecorationTheme: fields),
      menuButtonTheme: MenuButtonThemeData(
        style: ButtonStyle(
          minimumSize: WidgetStatePropertyAll(Size(0, m.menuRow)),
          padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: m.menuInset)),
          shape: shape(),
          textStyle: WidgetStatePropertyAll(menuText),
          foregroundColor: states(k.textSecondary, hover: k.textPrimary, press: k.textPrimary, disabled: k.textDisabled),
          iconColor: states(k.textSecondary, hover: k.textPrimary, press: k.textPrimary, disabled: k.textDisabled),
          backgroundColor: states(Colors.transparent, hover: k.layerHover, press: k.backgroundActive),
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          visualDensity: VisualDensity.standard,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(style: primary),
      elevatedButtonTheme: ElevatedButtonThemeData(style: primary),
      outlinedButtonTheme: OutlinedButtonThemeData(style: tertiary),
      textButtonTheme: TextButtonThemeData(style: ghost),
      // A modal: $layer-01 on the $overlay, square, its heading heading-03 and its body body-01.
      dialogTheme: theme.dialogTheme.copyWith(
        backgroundColor: k.layer01,
        barrierColor: k.overlay,
        elevation: 0,
        shape: square,
        titleTextStyle: type.titleLarge!.copyWith(fontSize: 20, height: 28 / 20, fontWeight: FontWeight.w400, color: k.textPrimary, letterSpacing: 0),
        contentTextStyle: type.bodyMedium!.copyWith(fontSize: 14, height: 20 / 14, color: k.textPrimary, letterSpacing: 0.16),
        actionsPadding: EdgeInsets.zero,
      ),
      // A toast notification, high contrast.
      snackBarTheme: theme.snackBarTheme.copyWith(
        backgroundColor: k.backgroundInverse,
        contentTextStyle: TextStyle(fontSize: 14, letterSpacing: 0.16, color: k.textInverse),
        actionTextColor: dark ? k.primary : Color.lerp(k.primary, Colors.white, 0.5),
        shape: square,
        elevation: 2,
      ),
      splashFactory: NoSplash.splashFactory,
      splashColor: Colors.transparent,
      hoverColor: k.backgroundHover,
      highlightColor: k.backgroundActive,
      focusColor: k.focus.withValues(alpha: 0.16),
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
      fill: _fill == null || other._fill == null ? null : l(_fill, other._fill),
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
  const _SteadyBorder({super.side, super.borderRadius = BorderRadius.zero});

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) => this;
}

extension AppColorsContext on BuildContext {
  /// The app palette of the current theme; in a theme without one (a bare [MaterialApp]'s, as
  /// [AppStyle.of] has Refined there), Refined's.
  AppColors get colors {
    final theme = Theme.of(this);
    return theme.extension<AppColors>() ?? AppColors.of(AccentColor.sky, theme.brightness);
  }
}
