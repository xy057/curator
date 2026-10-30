// The web player: what File ▸ Export to Web… puts beside a page's score (`make web-player`
// builds it). It reads the page from `score/` next to it (see WebPage) and plays it.
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import '../l10n/l10n.dart';
import '../web_page.dart';
import 'html_audio.dart';
import 'page_audio.dart';
import 'page_loader.dart';
import 'player.dart';

void main() => runApp(const _PageApp());

Future<Uint8List> _fetch(String path) async {
  final response = await web.window.fetch('${WebPage.folder}/$path'.toJS).toDart;
  if (!response.ok) throw FormatException('Couldn’t load {file} ({status}).'.fill({'file': path, 'status': response.status}));
  return (await response.arrayBuffer().toDart).toDart.asUint8List();
}

class _PageApp extends StatefulWidget {
  const _PageApp();

  @override
  State<_PageApp> createState() => _PageAppState();
}

class _PageAppState extends State<_PageApp> {
  late final Future<LoadedPage> _page = LoadedPage.load(_fetch).then((p) {
    web.document.title = p.page.title;
    return p;
  });

  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness b) => ThemeData(
          brightness: b,
          colorSchemeSeed: const Color(0xFF3B6FD4),
          fontFamily: 'IBM Plex Sans',
          sliderTheme: const SliderThemeData(trackHeight: 3, overlayShape: RoundSliderOverlayShape(overlayRadius: 14)),
        );
    return MaterialApp(
      title: 'Curator',
      debugShowCheckedModeBanner: false,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      home: FutureBuilder(
        future: _page,
        builder: (context, page) => switch (page) {
          AsyncSnapshot(:final data?) =>
            PagePlayer(data, audioFor: (file) => file == null ? SilentAudio() : HtmlAudio('${WebPage.folder}/$file')),
          AsyncSnapshot(:final error?) => Scaffold(
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(error is FormatException ? error.message : '$error', textAlign: TextAlign.center),
                ),
              ),
            ),
          _ => const Scaffold(body: Center(child: SizedBox.square(dimension: 28, child: CircularProgressIndicator(strokeWidth: 2.5)))),
        },
      ),
    );
  }
}
