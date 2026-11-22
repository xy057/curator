// The page's plugins, in the browser: only the web player's main.dart reaches this file.
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:score_engine/score_engine.dart' show WebPluginApi;

import '../web_page.dart';
import 'page_api.dart';
import 'playing_page.dart';

/// The plugin host, beside the player (`web_plugins/host.ts`, built into `web/plugin_host.js`).
const _hostFile = 'plugin_host.js';

extension type _HostModule(JSObject _) implements JSObject {
  external _Host start(JSObject bridge, JSAny? page);
}

extension type _Host(JSObject _) implements JSObject {
  external bool emit(String event, JSAny? data);
}

/// Starts the page's plugins: loads the host, hands it what answers them ([api], as `call` and
/// `audio`) and the page's [WebPage.plugins], and gives what tells them of what happens. Null
/// when the host can't be loaded: the page then plays without them, and the console says why.
///
/// A call answers `{ok: value}`, or `{error: message}` for one that can't be done: the host
/// throws that as an error of the plugin's own, where its code can catch it.
Future<PageListener?> startPagePlugins(PageApi api) async {
  final page = api.player.page;
  final bridge = JSObject()
    ..['call'] = ((String method, JSArray<JSAny?> args) {
      try {
        return {'ok': api.call(method, [for (final a in args.toDart) a.dartify()])}.jsify();
      } on ArgumentError catch (e) {
        return {'error': '${e.message}'}.jsify();
      } catch (e) {
        return {'error': '$e'}.jsify();
      }
    }).toJS
    ..['audio'] = (() => api.audioElement as JSAny?).toJS;
  try {
    final module = _HostModule(await importModule(Uri.base.resolve(_hostFile).toString().toJS).toDart);
    final host = module.start(
        bridge,
        {
          'api': WebPluginApi.level,
          'folder': WebPage.folder,
          'plugins': [
            for (final p in page.plugins) {...p.toJson(), 'folder': '${WebPage.folder}/${WebPage.pluginFolder(p.id)}'},
          ],
        }.jsify());
    // (Typed here: left to be inferred through the Future, `data` is dynamic, and jsify is an extension's.)
    bool tell(String event, Map<String, Object?> data) => host.emit(event, data.jsify());
    return tell;
  } catch (e) {
    _console.callMethod('error'.toJS, 'Curator: the page’s plugins couldn’t be started.'.toJS, '$e'.toJS);
    return null;
  }
}

@JS('console')
external JSObject get _console;
