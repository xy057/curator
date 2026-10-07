// The desktop engine accepts every semantics update the app sends: hovering each tooltip,
// opening and closing a project, a popup menu and each dialog (the extensions' too), frame by frame. A rejected
// update logs "Failed to update ui::AXTree" in `make run` and breaks VoiceOver's view of the
// window for good (see accessibility_mirror.dart).
import 'package:curated_score/app_extensions.dart';
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/assets_dialog.dart';
import 'package:curated_score/captions_dialog.dart';
import 'package:curated_score/condensing_dialog.dart';
import 'package:curated_score/edit_dialogs.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/engrave_options_dialog.dart';
import 'package:curated_score/export_dialog.dart';
import 'package:curated_score/fonts_dialog.dart';
import 'package:curated_score/image_patch.dart';
import 'package:curated_score/main.dart';
import 'package:curated_score/score_view.dart';
import 'package:curated_score/settings_dialog.dart';
import 'package:curated_score/ui_kit.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:score_engine/score_engine.dart';

import 'accessibility_mirror.dart';
import 'demo_project.dart';
import 'image_patch_test.dart' show png;

void main() {
  final binding = AccessibilityMirrorBinding();
  final mirror = binding.mirror;

  testWidgets('the mirror rejects an overlay whose owner has no semantics', (tester) async {
    // flutter/flutter#190357: a slider faded out keeps its overlay, which then has no parent.
    final handle = tester.ensureSemantics();
    final opacity = ValueNotifier(0.0);
    addTearDown(opacity.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ValueListenableBuilder(
          valueListenable: opacity,
          builder: (context, value, _) => FadeTransition(
            opacity: AlwaysStoppedAnimation(value),
            child: Slider(value: 0.5, onChanged: (_) {}),
          ),
        ),
      ),
    ));
    opacity.value = 1;
    await tester.pump();
    expect(mirror.takeErrors(), isNotEmpty);
    handle.dispose();
  });

  testWidgets('every update is one the engine accepts', (tester) async {
    tester.view.physicalSize = const Size(2880, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final handle = tester.ensureSemantics();
    mirror.takeErrors();
    void check(String after) => expectAccessibilityTreeIntact(mirror, after);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    // Shows and hides the tooltip of every Tooltip under [scope] that the pointer can reach
    // (not scrolled out of sight).
    Future<void> hoverTooltips(String where, [Finder? scope]) async {
      final tooltips = scope == null ? find.byType(Tooltip) : find.descendant(of: scope, matching: find.byType(Tooltip));
      for (final tooltip in tooltips.evaluate().map((e) => e.widget as Tooltip).toList()) {
        if (find.byWidget(tooltip).hitTestable().evaluate().isEmpty) continue;
        final what = '$where: "${tooltip.message?.split('\n').first}"';
        await mouse.moveTo(tester.getCenter(find.byWidget(tooltip)));
        await tester.pump(const Duration(milliseconds: 1500));
        expect(find.text(tooltip.message!), findsOneWidget, reason: 'showing $what');
        check('showing $what');
        await mouse.moveTo(Offset.zero);
        await tester.pump(const Duration(seconds: 1));
        check('hiding $what');
      }
    }

    // Pumps a transition a frame at a time, as the engine sees each frame.
    Future<void> frames(String what) async {
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 40));
        check('$what, frame $i');
      }
      await tester.pump(const Duration(seconds: 1));
      check(what);
    }

    final settings = AppSettings.memory()..addRecent(demoProject.absolute.path);
    await tester.pumpWidget(CuratedScoreApp(settings: settings));
    await tester.pump(const Duration(seconds: 1));
    check('starting');
    await hoverTooltips('home');

    // Opening cross-fades the home screen into the editor, which has the score size slider.
    await tester.tap(find.text('Try the sample'));
    final state = tester.state(find.byType(HomePage)) as dynamic;
    final c = state.controller as EditorController;
    for (var i = 0; i < 100 && c.score == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      check('opening the sample');
    }
    await frames('opening the sample');
    await hoverTooltips('instruments');

    await tester.tap(find.byTooltip('Lane options').first);
    await frames('opening a lane menu');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await frames('closing a lane menu');

    await tester.tap(find.byIcon(Icons.graphic_eq_rounded));
    await frames('switching to the Audio tab');
    c.anchors.selectAll(); // the selection chip, with a tooltip of its own inside
    await frames('selecting every anchor');
    await hoverTooltips('audio');

    BuildContext context() => tester.element(find.byType(HomePage));
    final dialogs = <String, void Function()>{
      'Export Video': () => showExportDialog(context(), c, settings, suggestedName: 'Demo'),
      'Engrave Option': () => showEngraveOptionsDialog(context(), settings, controller: c),
      'Condensing': () => showCondensingDialog(context(), c),
      'Rename': () => showRenameDialog(context(), c, c.score!.metadata.parts.first),
      'Warp': () => showAnchorDialog(context(), beats: c.beats, quarter: 9, jumpTo: 0, warp: true),
      'Settings': () => showSettingsDialog(context(), settings, controller: c),
    };
    Future<void> openEach(Map<String, void Function()> dialogs) async {
      for (final MapEntry(key: name, value: open) in dialogs.entries) {
        open();
        await frames('opening $name');
        final dialog = find.byWidgetPredicate((w) => w is Dialog || w.runtimeType.toString() == '_SettingsWindow').last;
        await hoverTooltips(name, dialog);
        Navigator.of(tester.element(dialog)).pop();
        await frames('closing $name');
      }
    }

    await openEach(dialogs);

    // The extensions: the Captions lane, Attach Image's toolbar, the score's menu, their dialogs.
    settings
      ..attachImage = true
      ..captions = true;
    await frames('turning the extensions on');
    final bar = c.score!.timeline.measureStarts;
    c.captions.add(Caption(bar[0], bar[4], 'The horns answer'));
    await tester.runAsync(() => c.images.add(ImageKind.raster, png, quarter: bar[1], top: 2));
    c.tab = BottomTab.instruments;
    await frames('adding a caption and an image');
    await hoverTooltips('extensions');
    final score = tester.getRect(find.byType(ScoreView));
    await tester.tapAt(score.center, buttons: kSecondaryButton);
    await frames("opening the score's menu");
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await frames("closing the score's menu");
    await openEach({
      'Caption': () => showCaptionDialog(context(), c, index: 0),
      'Add Caption': () => showCaptionDialog(context(), c, draft: Caption(bar[6], bar[8], '')),
      'Captions': () => showCaptionsDialog(context(), c),
      'Manage assets': () => showAssetsDialog(context(), c),
      'Fonts': () => showFontsDialog(context(), c),
      'Captions settings': () => showAppDialog<void>(
          context: context(),
          builder: (context) => AlertDialog(content: Builder(builder: (context) => AppExtension.captions.settings!(context, settings)))),
    });

    await tester.tap(find.byTooltip('Close project (Ctrl+W)'));
    await frames('closing the project');
    handle.dispose();
  });
}
