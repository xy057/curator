/// The web player's plugin API: what a page's plugins are given is written down, with its
/// types, in `app/assets/web_plugins/curator-web.d.ts`, and done by the player's host
/// (`web_plugins/host.ts`) over what the player answers (`PageApi`). It only grows, as the
/// app's own plugin API does ([PluginApi]): nothing declared is taken away or made to mean
/// something else; a plugin says the level it needs (`"api"` in plugin.json) and may ask for
/// more with `curator.has`.
abstract final class WebPluginApi {
  /// This build's API level.
  static const level = 1;

  /// The file that declares it, for TypeScript.
  static const typesName = 'curator-web.d.ts';

  /// The docs whole, as Markdown: the [guide] to writing a web plugin, then the API as [types]
  /// (the file [typesName]) declares it.
  static String docs(String guide, String types) =>
      '${guide.trimRight()}\n\n# Reference\n\nAPI level $level: `$typesName`, whole.\n\n```ts\n${types.trimRight()}\n```\n';
}
