// The desktop engine accepts every semantics update while each settings page is opened in a short
// window and scrolled to its end, frame by frame: a slider whose row scrolled out of the tree kept
// its overlay, which the engine then rejected ("Failed to update ui::AXTree" in `make run`; see
// accessibility_mirror.dart and OverlaySemantics).
import 'package:curated_score/app_settings.dart';
import 'package:curated_score/editor_controller.dart';
import 'package:curated_score/main.dart';
import 'package:curated_score/settings_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'accessibility_mirror.dart';
import 'demo_project.dart';

void main() {
  final binding = AccessibilityMirrorBinding();
  final mirror = binding.mirror;

  testWidgets('every settings page, scrolled through in a short window, keeps the accessibility tree whole', (tester) async {
    tester.view
      ..physicalSize = const Size(2000, 1240)
      ..devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final handle = tester.ensureSemantics();
    void check(String after) => expectAccessibilityTreeIntact(mirror, after);
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
    await tester.tap(find.text('Open Sample'));
    final c = (tester.state(find.byType(HomePage)) as dynamic).controller as EditorController;
    for (var i = 0; i < 100 && c.score == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    await frames('opening the sample');
    mirror.takeErrors();

    BuildContext context() => tester.element(find.byType(HomePage));
    Future<void> page(String name, void Function() open, [String? tab]) async {
      open();
      await frames('opening $name');
      if (tab != null) {
        await tester.tap(find.text(tab).last);
        await frames('$name ▸ $tab');
      }
      for (final list in find.byType(Scrollable).evaluate().where((e) => e.findAncestorWidgetOfExactType<ListView>() != null).toList()) {
        final position = ((list as StatefulElement).state as ScrollableState).position;
        if (!position.hasContentDimensions || position.maxScrollExtent == 0) continue;
        position.jumpTo(position.maxScrollExtent);
        await frames('$name ${tab ?? ''} scrolled to its end');
        position.jumpTo(0);
        await frames('$name ${tab ?? ''} scrolled back');
      }
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await frames('closing $name');
    }

    for (final p in ['General', 'Appearance', 'Advanced', 'About']) {
      await page(p, () => showSettingsDialog(context(), settings, controller: c, page: p));
    }
    for (final p in ['Project Info', 'Animation', 'Instruments', 'Sections', 'Condensing', 'Extensions', 'Flags', 'Engraving']) {
      await page('Project $p', () => showProjectSettingsDialog(context(), settings, c, page: p));
    }
    for (final t in ['Typography', 'Advanced']) {
      await page('Project Engraving', () => showProjectSettingsDialog(context(), settings, c, page: 'Engraving'), t);
    }
    handle.dispose();
  });
}
