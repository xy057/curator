// The window the app's widget tests run in, and screenshots of it for visual review.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// A 1440 × 900 window at 2 pixels a point, as on a MacBook; back to the default after the test.
void desktopWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(2880, 1800);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
}

/// Where [screenshot] saves (SCREENSHOT_DIR); unset, it saves nothing.
final screenshotDir = Platform.environment['SCREENSHOT_DIR'];

/// Saves the repaint boundary around [inside] (the window's, by default) as [name].png in
/// [screenshotDir]: the nearest one, or the [outermost].
Future<void> screenshot(WidgetTester tester, String name,
    {Finder? inside, bool outermost = false, double pixelRatio = 2}) async {
  final dir = screenshotDir;
  if (dir == null) return;
  await tester.runAsync(() async {
    final around = find.ancestor(of: inside ?? find.byType(Scaffold), matching: find.byType(RepaintBoundary));
    final boundary = tester.renderObject<RenderRepaintBoundary>(outermost ? around.last : around.first);
    final image = await boundary.toImage(pixelRatio: pixelRatio);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$dir/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
  });
}
