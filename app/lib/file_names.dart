/// Names in paths, read the same on every platform (a Windows path has backslashes).
library;

/// The last part of [path]: the name of its file or folder (a folder's path may end in a
/// separator, as a failed listing's does).
String fileNameOf(String path) => path.split(RegExp(r'[/\\]')).lastWhere((part) => part.isNotEmpty, orElse: () => path);

/// [name] without its extension ("Op. 9.mxl" → "Op. 9"); a name whose only dot leads it
/// (".hidden") has none.
String stemOf(String name) {
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

/// [path]'s extension, lower-case, without its dot ("Score.MXL" → "mxl"; the whole name when it
/// has no dot).
String extensionOf(String path) => path.split('.').last.toLowerCase();

/// [name] as a file name that is safe as a zip entry and on every file system.
String safeFileName(String name) {
  final cleaned = name.replaceAll(RegExp(r'[/\\:*?"<>|\x00-\x1f]'), '_').trim();
  return cleaned.isEmpty ? 'file' : cleaned;
}

/// [folder] as shown: `~` for [home] where it is that folder or one inside it (never one whose
/// name only starts as home's does: `/Users/anna` is not in `/Users/ann`).
String underHome(String folder, String? home) {
  if (home == null || home.isEmpty) return folder;
  final root = home.replaceFirst(RegExp(r'[/\\]+$'), '');
  if (root.isEmpty || !folder.startsWith(root)) return folder;
  final rest = folder.substring(root.length);
  return rest.isEmpty || rest.startsWith('/') || rest.startsWith(r'\') ? '~$rest' : folder;
}
