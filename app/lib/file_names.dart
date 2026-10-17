/// Names in paths, read the same on every platform (a Windows path has backslashes).
library;

/// The last part of [path]: the name of its file or folder.
String fileNameOf(String path) => path.split(RegExp(r'[/\\]')).last;

/// [name] without its extension ("Op. 9.mxl" → "Op. 9"); a name whose only dot leads it
/// (".hidden") has none.
String stemOf(String name) {
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}
