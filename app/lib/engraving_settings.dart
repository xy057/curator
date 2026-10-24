import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:score_engine/score_engine.dart';

import 'app_colors.dart';
import 'app_settings.dart';
import 'controller_settings.dart';
import 'editor_controller.dart';
import 'menu_kit.dart';
import 'motion_settings.dart' show ResetSlot, SettingSlider;
import 'project_document.dart' show sampleProjectAsset;
import 'project_file.dart';
import 'scratch_space.dart';
import 'ui_kit.dart';

/// An engraving option by plain name, under a heading: the ones most scores want changed on
/// Project Settings ▸ Engraving ([all]), every other one on Advanced Engraving ([advanced]).
class EngravingSetting {
  const EngravingSetting(this.group, this.title, this.key, {this.ownStep, this.labels = const {}, this.keywords = ''});

  /// The page's heading it is under.
  final String group;
  final String title;

  /// [EngraveOption.key].
  final String key;

  /// The slider's step as given; null: [step] works it out.
  final double? ownStep;

  /// A choice's names, by value ([EngraveOption.choices]).
  final Map<String, String> labels;
  final String keywords;

  EngraveOption get option => EngraveOption.byKey(key)!;

  /// A slider's step: integers go by 1; a number by its own, or about a hundredth of its range.
  double get step {
    if (option.kind == EngraveOptionKind.integer) return 1;
    if (ownStep case final step?) return step;
    final span = option.max! - option.min!;
    return span <= 1 ? 0.01 : (span <= 5 ? 0.05 : 0.1);
  }

  static const all = [
    EngravingSetting('Spacing', 'Note spacing', 'spacingLinear', ownStep: 0.01, keywords: 'width wide narrow'),
    EngravingSetting('Spacing', 'Spacing ratio', 'spacingNonLinear', ownStep: 0.01, keywords: 'long short duration'),
    EngravingSetting('Spacing', 'Minimum bar width', 'measureMinWidth', keywords: 'measure'),
    EngravingSetting('Spacing', 'Even spacing', 'evenNoteSpacing', keywords: 'equal'),
    EngravingSetting('Line thickness', 'Staff lines', 'engravingDefaults.staffLineThickness', ownStep: 0.005,
        keywords: 'weight'),
    EngravingSetting('Line thickness', 'Stems', 'engravingDefaults.stemThickness', ownStep: 0.005, keywords: 'weight'),
    EngravingSetting('Line thickness', 'Ledger lines', 'engravingDefaults.legerLineThickness', ownStep: 0.01,
        keywords: 'leger weight'),
    EngravingSetting('Line thickness', 'Barlines', 'engravingDefaults.thinBarlineThickness', ownStep: 0.01,
        keywords: 'bar line weight'),
    EngravingSetting('Notation', 'Slur curvature', 'slurCurveFactor', ownStep: 0.05, keywords: 'curve'),
    EngravingSetting('Notation', 'Maximum beam slope', 'beamMaxSlope', keywords: 'angle'),
    EngravingSetting('Notation', 'Grace note size', 'graceFactor', ownStep: 0.05, keywords: 'small'),
    EngravingSetting('Notation', 'Lyric size', 'lyricSize', ownStep: 0.1, keywords: 'text words'),
  ];

  static const _thickness = 'Line thickness', _before = 'Space before', _after = 'Space after';
  static const _above = 'Space above', _below = 'Space below';

  /// Every option not in [all], in page order ([EngraveOption.all] has each once, here or there).
  static const advanced = [
    EngravingSetting('Notes and rests', 'Align grace notes', 'graceRhythmAlign', keywords: 'rhythm'),
    EngravingSetting('Notes and rests', 'Ledger line length', 'engravingDefaults.legerLineExtension',
        keywords: 'leger extension'),
    EngravingSetting('Notes and rests', 'Multi-bar rests', 'multiRestStyle',
        labels: {'auto': 'Automatic', 'default': 'H-bar', 'block': 'Block', 'symbols': 'Rest symbols'},
        keywords: 'multirest measure style'),
    EngravingSetting('Notes and rests', 'Bar number interval', 'mnumInterval', keywords: 'measure numbers every'),
    EngravingSetting('Tuplets', 'Number by the noteheads', 'tupletNumHead', keywords: 'triplet side'),
    EngravingSetting('Tuplets', 'Angled brackets on beams', 'tupletAngledOnBeams', keywords: 'triplet slope'),
    EngravingSetting('Slurs and ties', 'Maximum slur slope', 'slurMaxSlope', keywords: 'angle'),
    EngravingSetting('Slurs and ties', 'Slur symmetry', 'slurSymmetry', keywords: 'even'),
    EngravingSetting('Slurs and ties', 'Slur clearance', 'slurMargin', keywords: 'margin distance'),
    EngravingSetting('Slurs and ties', 'Minimum tie length', 'tieMinLength', keywords: 'short'),
    EngravingSetting('Dynamics and lines', 'Dynamics distance', 'dynamDist', keywords: 'dynamic staff'),
    EngravingSetting('Dynamics and lines', 'Dynamics as one glyph', 'dynamSingleGlyphs', keywords: 'dynamic smufl'),
    EngravingSetting('Dynamics and lines', 'Hairpin opening', 'hairpinSize', keywords: 'crescendo diminuendo wedge'),
    EngravingSetting('Dynamics and lines', 'Alternative octave marks', 'octaveAlternativeSymbols',
        keywords: '8va 8vb ottava'),
    EngravingSetting(_thickness, 'Thick barlines', 'engravingDefaults.thickBarlineThickness', keywords: 'bar line'),
    EngravingSetting(_thickness, 'Slur ends', 'engravingDefaults.slurEndpointThickness', ownStep: 0.005),
    EngravingSetting(_thickness, 'Slur middles', 'engravingDefaults.slurMidpointThickness'),
    EngravingSetting(_thickness, 'Tie ends', 'engravingDefaults.tieEndpointThickness', ownStep: 0.005),
    EngravingSetting(_thickness, 'Tie middles', 'engravingDefaults.tieMidpointThickness'),
    EngravingSetting(_thickness, 'Brackets', 'engravingDefaults.bracketThickness', keywords: 'system'),
    EngravingSetting(_thickness, 'Sub-brackets', 'engravingDefaults.subBracketThickness', keywords: 'system'),
    EngravingSetting(_thickness, 'Hairpins', 'engravingDefaults.hairpinThickness', keywords: 'crescendo wedge'),
    EngravingSetting(_thickness, 'Octave lines', 'engravingDefaults.octaveLineThickness', keywords: '8va ottava'),
    EngravingSetting(_thickness, 'Pedal lines', 'engravingDefaults.pedalLineThickness'),
    EngravingSetting(_thickness, 'Ending brackets', 'engravingDefaults.repeatEndingLineThickness',
        keywords: 'volta repeat'),
    EngravingSetting(_thickness, 'Lyric lines', 'engravingDefaults.lyricLineThickness', keywords: 'extender'),
    EngravingSetting(_thickness, 'Tuplet brackets', 'engravingDefaults.tupletBracketThickness', keywords: 'triplet'),
    EngravingSetting(_thickness, 'Text boxes', 'engravingDefaults.textEnclosureThickness', keywords: 'enclosure'),
    EngravingSetting(_thickness, 'Multi-bar rests', 'engravingDefaults.hBarThickness', keywords: 'h-bar'),
    EngravingSetting('Barlines', 'Double barline gap', 'engravingDefaults.barlineSeparation', keywords: 'separation'),
    EngravingSetting('Barlines', 'Repeat dot gap', 'engravingDefaults.repeatBarlineDotSeparation'),
    EngravingSetting('Barlines', 'Dash length', 'engravingDefaults.dashedBarlineDashLength', keywords: 'dashed'),
    EngravingSetting('Barlines', 'Dash gap', 'engravingDefaults.dashedBarlineGapLength', keywords: 'dashed'),
    EngravingSetting(_before, 'Anything', 'defaultLeftMargin', keywords: 'default margin left'),
    EngravingSetting(_before, 'Accidentals', 'leftMarginAccid', keywords: 'margin left'),
    EngravingSetting(_before, 'Barlines', 'leftMarginBarLine', keywords: 'margin left'),
    EngravingSetting(_before, 'Opening barlines', 'leftMarginLeftBarLine', keywords: 'margin left'),
    EngravingSetting(_before, 'Closing barlines', 'leftMarginRightBarLine', keywords: 'margin left'),
    EngravingSetting(_before, 'Beat repeats', 'leftMarginBeatRpt', keywords: 'margin left'),
    EngravingSetting(_before, 'Chords', 'leftMarginChord', keywords: 'margin left'),
    EngravingSetting(_before, 'Clefs', 'leftMarginClef', keywords: 'margin left'),
    EngravingSetting(_before, 'Key signatures', 'leftMarginKeySig', keywords: 'margin left'),
    EngravingSetting(_before, 'Mensuration signs', 'leftMarginMensur', keywords: 'margin left'),
    EngravingSetting(_before, 'Time signatures', 'leftMarginMeterSig', keywords: 'margin left meter'),
    EngravingSetting(_before, 'Whole-bar rests', 'leftMarginMRest', keywords: 'margin left measure'),
    EngravingSetting(_before, 'Multi-bar rests', 'leftMarginMultiRest', keywords: 'margin left'),
    EngravingSetting(_before, 'Multi-bar repeats', 'leftMarginMultiRpt', keywords: 'margin left'),
    EngravingSetting(_before, 'Notes', 'leftMarginNote', keywords: 'margin left'),
    EngravingSetting(_before, 'Rests', 'leftMarginRest', keywords: 'margin left'),
    EngravingSetting(_before, 'Tablature rhythms', 'leftMarginTabDurSym', keywords: 'margin left tab'),
    EngravingSetting(_after, 'Anything', 'defaultRightMargin', keywords: 'default margin right'),
    EngravingSetting(_after, 'Accidentals', 'rightMarginAccid', keywords: 'margin right'),
    EngravingSetting(_after, 'Barlines', 'rightMarginBarLine', keywords: 'margin right'),
    EngravingSetting(_after, 'Opening barlines', 'rightMarginLeftBarLine', keywords: 'margin right'),
    EngravingSetting(_after, 'Closing barlines', 'rightMarginRightBarLine', keywords: 'margin right'),
    EngravingSetting(_after, 'Beat repeats', 'rightMarginBeatRpt', keywords: 'margin right'),
    EngravingSetting(_after, 'Chords', 'rightMarginChord', keywords: 'margin right'),
    EngravingSetting(_after, 'Clefs', 'rightMarginClef', keywords: 'margin right'),
    EngravingSetting(_after, 'Key signatures', 'rightMarginKeySig', keywords: 'margin right'),
    EngravingSetting(_after, 'Mensuration signs', 'rightMarginMensur', keywords: 'margin right'),
    EngravingSetting(_after, 'Time signatures', 'rightMarginMeterSig', keywords: 'margin right meter'),
    EngravingSetting(_after, 'Whole-bar rests', 'rightMarginMRest', keywords: 'margin right measure'),
    EngravingSetting(_after, 'Multi-bar rests', 'rightMarginMultiRest', keywords: 'margin right'),
    EngravingSetting(_after, 'Multi-bar repeats', 'rightMarginMultiRpt', keywords: 'margin right'),
    EngravingSetting(_after, 'Notes', 'rightMarginNote', keywords: 'margin right'),
    EngravingSetting(_after, 'Rests', 'rightMarginRest', keywords: 'margin right'),
    EngravingSetting(_after, 'Tablature rhythms', 'rightMarginTabDurSym', keywords: 'margin right tab'),
    EngravingSetting(_above, 'Anything', 'defaultTopMargin', keywords: 'default margin top'),
    EngravingSetting(_above, 'Articulations', 'topMarginArtic', keywords: 'margin top'),
    EngravingSetting(_above, 'Chord symbols', 'topMarginHarm', keywords: 'margin top harmony'),
    EngravingSetting(_below, 'Anything', 'defaultBottomMargin', keywords: 'default margin bottom'),
    EngravingSetting(_below, 'Articulations', 'bottomMarginArtic', keywords: 'margin bottom'),
    EngravingSetting(_below, 'Chord symbols', 'bottomMarginHarm', keywords: 'margin bottom harmony'),
    EngravingSetting(_below, 'Octave marks', 'bottomMarginOctave', keywords: 'margin bottom 8va ottava'),
  ];
}

/// The engraving options a control changes: the open project's, over the app's defaults
/// ([AppSettings.engravingOptions], set only by [saveAsDefault]). Each change is an edit; a
/// reset goes back to the house style, even over a default.
class EngravingTarget {
  EngravingTarget(this.settings, this.controller);
  final AppSettings settings;
  final EditorController controller;

  EngravingOptions get own => controller.projectEngraving;
  set own(EngravingOptions options) => controller.setProjectEngraving(options);

  /// What the score is engraved with.
  EngravingOptions get effective => own.over(settings.engravingOptions);

  /// Whether [option] is engraved other than the house style.
  bool isChanged(EngraveOption option) => valueOf(option) != baseOf(option);

  /// Whether any option is.
  bool get anyChanged => EngraveOption.all.any(isChanged);

  /// Sets [option] here; null resets it to the house style (kept here over a default).
  void set(EngraveOption option, Object? value) {
    if (value == null && settings.engravingOptions.isChanged(option)) value = baseOf(option);
    own = own.withValue(option, value, keepDefault: true);
  }

  /// Every option back to the house style.
  void resetAll() {
    var options = const EngravingOptions();
    for (final option in EngraveOption.all) {
      if (settings.engravingOptions.isChanged(option)) options = options.withValue(option, baseOf(option), keepDefault: true);
    }
    own = options;
  }

  /// [option]'s value as engraved: set, or the house style's, or for a line the open score's
  /// font's own (Verovio takes the font's engraving defaults unless one is set).
  Object valueOf(EngraveOption option) {
    final options = effective;
    if (options.isChanged(option)) return options.valueOf(option);
    return baseOf(option);
  }

  /// The house style's value: what a reset goes back to.
  Object baseOf(EngraveOption option) => fontDefault(option) ?? option.defaultValue;

  double? fontDefault(EngraveOption option) => switch (option.smuflKey) {
        final name? => controller.fonts.music.engravingDefaults[name],
        null => null,
      };

  /// The engraving as engraved here, as the app's: what every project engraves with unless
  /// it sets its own.
  EngravingOptions get _asDefault {
    var options = const EngravingOptions();
    for (final option in EngraveOption.all) {
      if (isChanged(option)) options = options.withValue(option, valueOf(option), keepDefault: true);
    }
    return options;
  }

  /// Whether this project's fonts and engraving are already the app's defaults.
  bool get isDefault =>
      settings.engravingOptions == _asDefault &&
      settings.musicFont == controller.fonts.music.name &&
      settings.textFont == controller.fonts.text &&
      settings.embedFont == controller.embedFont;

  /// This project's fonts (for new projects) and engraving (for every project not setting
  /// its own) made the app's.
  void saveAsDefault() {
    settings.engravingOptions = _asDefault;
    settings.musicFont = controller.fonts.music.name;
    settings.textFont = controller.fonts.text;
    settings.embedFont = controller.embedFont;
  }

  /// This project's fonts and engraving back to the app's defaults (fonts not installed here:
  /// Bravura or Academico, as for a new project). Call inside one edit.
  Future<void> resetToDefault() async {
    final (:fonts, :embed) = await controller.defaultFonts();
    await controller.setFonts(fonts, embed: embed);
    await controller.setProjectEngraving(const EngravingOptions());
  }
}

/// One option as a slider (with its value), a switch or a menu, and a reset once changed: as
/// every settings page's rows.
class EngravingControl extends StatelessWidget {
  const EngravingControl({super.key, required this.target, required this.setting});
  final EngravingTarget target;
  final EngravingSetting setting;

  @override
  Widget build(BuildContext context) {
    final option = setting.option;
    final value = target.valueOf(option);
    final control = switch (option.kind) {
      EngraveOptionKind.toggle => AppSwitch(value: value as bool, onChanged: (v) => target.set(option, v)),
      EngraveOptionKind.choice => SettingsDropdown<String>(
          value: value as String,
          width: 132,
          items: [
            for (final c in option.choices) DropdownMenuItem(value: c, child: Text(setting.labels[c] ?? c)),
          ],
          onChanged: (v) => target.set(option, v),
        ),
      _ => SettingSlider(
          value: (value as num).toDouble(),
          min: option.min!.toDouble(),
          max: option.max!.toDouble(),
          step: setting.step,
          format: (v) => formatOptionValue(option.kind == EngraveOptionKind.integer ? v.round() : v),
          onChanged: (v) => target.set(option, v),
        ),
    };
    return Row(mainAxisSize: MainAxisSize.min, children: [
      control,
      ResetSlot(changed: target.isChanged(option), color: context.colors.textMuted, onReset: () => target.set(option, null)),
    ]);
  }
}

/// A value as the settings show it: numbers without trailing zeros.
String formatOptionValue(Object value) => switch (value) {
      int() => '$value',
      double() => value.toStringAsFixed(3).replaceFirst(RegExp(r'\.?0+$'), ''),
      bool() => value ? 'on' : 'off',
      _ => '$value',
    };

/// [EngravingPreview] of the open score, or with none the bundled demo, engraved on its own
/// with the app's options (and again whenever they change) for as long as this is shown and
/// nothing is open: a project opening or closing meanwhile (the menu bar works) switches.
class EngravingPreviewHost extends StatefulWidget {
  const EngravingPreviewHost({super.key, required this.settings, this.controller, this.scale = 1});
  final AppSettings settings;
  final EditorController? controller;
  final double scale;

  @override
  State<EngravingPreviewHost> createState() => _EngravingPreviewHostState();
}

class _EngravingPreviewHostState extends State<EngravingPreviewHost> with TickerProviderStateMixin {
  EditorController? _demo;
  bool _failed = false;

  /// Where the demo has music on most staves.
  static const _demoTime = 20.0;

  @override
  void initState() {
    super.initState();
    widget.settings.addListener(_optionsChanged);
    widget.controller?.addListener(_openChanged);
    _openChanged();
  }

  @override
  void didUpdateWidget(EngravingPreviewHost old) {
    super.didUpdateWidget(old);
    if (old.settings != widget.settings) {
      old.settings.removeListener(_optionsChanged);
      widget.settings.addListener(_optionsChanged);
      _optionsChanged();
    }
    if (old.controller != widget.controller) {
      old.controller?.removeListener(_openChanged);
      widget.controller?.addListener(_openChanged);
      _openChanged();
    }
  }

  /// The demo while nothing is open, and only then.
  void _openChanged() {
    final open = EngravingPreview.canShow(widget.controller);
    if (open && _demo != null) {
      _demo!.dispose();
      setState(() => _demo = null);
    } else if (!open && _demo == null && !_failed && !(widget.controller?.isLoading ?? false)) {
      _loadDemo();
    }
  }

  Future<void> _loadDemo() async {
    final demo = _demo = EditorController(vsync: this)..takeSettings(widget.settings);
    bool current() => mounted && identical(_demo, demo); // not let go meanwhile (a score opened)
    final folder = ScratchSpace.folder('engraving-preview');
    try {
      final data = await rootBundle.load(sampleProjectAsset);
      final file = File('${folder.path}${Platform.pathSeparator}demo.ccs');
      await file.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
      final project = await ProjectFile.read(file.path, mediaDirectory: folder.path);
      if (!current()) return;
      // No recording: the preview never plays.
      await demo.openProject(name: project.scoreName, scoreBytes: project.scoreBytes, state: project.state);
      if (current()) demo.playback.time.value = _demoTime;
    } catch (_) {
      if (current()) setState(() => _failed = true);
    } finally {
      ScratchSpace.release(folder);
    }
    if (current()) setState(() {});
  }

  void _optionsChanged() => _demo?.takeSettings(widget.settings);

  @override
  void dispose() {
    widget.settings.removeListener(_optionsChanged);
    widget.controller?.removeListener(_openChanged);
    _demo?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final open = widget.controller;
    if (EngravingPreview.canShow(open)) return EngravingPreview(controller: open!, scale: widget.scale);
    final demo = _demo;
    if (_failed || demo == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: demo,
      builder: (context, _) => EngravingPreview.canShow(demo)
          ? EngravingPreview(controller: demo, scale: widget.scale)
          : ColoredBox(color: context.colors.scorePaper), // blank paper while it engraves
    );
  }
}

/// The open score as engraved, at the playhead until scrubbed: drawn as the score view and a
/// video frame draw it, again whenever it is re-engraved.
class EngravingPreview extends StatefulWidget {
  const EngravingPreview({super.key, required this.controller, this.scale = 1});
  final EditorController controller;

  /// Drawn this much smaller, so a short strip shows more staves.
  final double scale;

  /// Whether [controller] has a score to show.
  static bool canShow(EditorController? c) => c?.scene != null && c?.curation != null;

  @override
  State<EngravingPreview> createState() => _EngravingPreviewState();
}

class _EngravingPreviewState extends State<EngravingPreview> {
  late double _time = widget.controller.playback.time.value;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final c = widget.controller;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        if (!EngravingPreview.canShow(c)) return const SizedBox.shrink();
        final duration = c.playback.duration;
        final time = _time.clamp(0.0, math.max(duration, 0.0)).toDouble();
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: Stack(children: [
              Positioned.fill(
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: _PreviewPainter(c.scene!, c.curation!, time, MediaQuery.devicePixelRatioOf(context),
                        colors.scorePaper, colors.scoreInk, widget.scale, c.editRevision.value),
                  ),
                ),
              ),
              if (c.isReengraving)
                const Positioned(
                  right: 12,
                  top: 12,
                  child: SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                ),
            ]),
          ),
          Divider(height: 1, color: colors.line),
          SizedBox(
            height: 32,
            child: OverlaySemantics(
              child: Slider(
                value: time,
                max: math.max(duration, 0.001),
                onChanged: (t) => setState(() => _time = t),
              ),
            ),
          ),
        ]);
      },
    );
  }
}

class _PreviewPainter extends CustomPainter {
  _PreviewPainter(this.scene, this.curation, this.time, this.devicePixelRatio, this.paper, this.ink, this.scale, this.revision);
  final CuratedScene scene;
  final Curation curation;
  final double time;
  final double devicePixelRatio;
  final Color paper, ink;
  final double scale;

  /// The edit shown: an edit that only redraws (a drawn text's look) keeps the scene.
  final int revision;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    canvas.drawColor(paper, BlendMode.src);
    canvas.scale(scale);
    scene.paint(canvas, size / scale,
        time: time, curation: curation, devicePixelRatio: devicePixelRatio * scale, paper: paper, ink: ink);
  }

  @override
  bool shouldRepaint(_PreviewPainter old) =>
      old.scene != scene ||
      old.curation != curation ||
      old.time != time ||
      old.devicePixelRatio != devicePixelRatio ||
      old.paper != paper ||
      old.ink != ink ||
      old.scale != scale ||
      old.revision != revision;
}
