import 'dart:io';

import 'package:flutter/foundation.dart';

/// Where the app keeps files of its own that outlive a run, each system's usual place for
/// them, apart from the projects the user saves and from `ScratchSpace`'s temporary files:
///
/// | | [data] (kept) | [cache] (can be fetched or made again) |
/// |---|---|---|
/// | macOS | `~/Library/Application Support/Curator` | `~/Library/Caches/Curator` |
/// | Windows | `%LocalAppData%\Curator` | `%LocalAppData%\Curator\Cache` |
/// | Linux | `$XDG_DATA_HOME/curator` (`~/.local/share/curator`) | `$XDG_CACHE_HOME/curator` (`~/.cache/curator`) |
///
/// Nothing is created until asked for ([folder]).
abstract final class AppFolders {
  static const name = 'Curator';

  /// Files the app keeps: downloads it needs again next time, things the user added.
  static Directory get data => Directory(dataFor(Platform.operatingSystem, Platform.environment, Directory.systemTemp.path));

  /// Files the app can always get again, which the system or the user may clear.
  static Directory get cache => Directory(cacheFor(Platform.operatingSystem, Platform.environment, Directory.systemTemp.path));

  /// A folder of [data] (or [cache]) for one kind of file, e.g. `folder('Models')`, created
  /// if it isn't there. [kind] is one plain name: no separators, no `..`.
  static Directory folder(String kind, {bool cached = false}) {
    if (!isPlainName(kind)) throw ArgumentError.value(kind, 'kind', 'not a plain folder name');
    final dir = Directory('${(cached ? cache : data).path}${Platform.pathSeparator}$kind');
    dir.createSync(recursive: true);
    return dir;
  }

  /// A name that stays one entry inside a folder on every system.
  static bool isPlainName(String name) =>
      name.isNotEmpty && name != '.' && name != '..' && !name.contains(RegExp(r'[/\\:\x00-\x1f]')) && name.trim() == name;

  /// [data] on [os] (`Platform.operatingSystem`) with [env]; [temp] when there is no home.
  @visibleForTesting
  static String dataFor(String os, Map<String, String> env, String temp) => switch (os) {
        'windows' => _join(_windowsLocal(env, temp), '\\', name),
        'macos' => _join(_home(env, temp), '/', 'Library/Application Support/$name'),
        _ => _join(_xdg(env, 'XDG_DATA_HOME') ?? _join(_home(env, temp), '/', '.local/share'), '/', name.toLowerCase()),
      };

  /// [cache] on [os] with [env]; [temp] when there is no home.
  @visibleForTesting
  static String cacheFor(String os, Map<String, String> env, String temp) => switch (os) {
        'windows' => _join(_windowsLocal(env, temp), '\\', '$name\\Cache'),
        'macos' => _join(_home(env, temp), '/', 'Library/Caches/$name'),
        _ => _join(_xdg(env, 'XDG_CACHE_HOME') ?? _join(_home(env, temp), '/', '.cache'), '/', name.toLowerCase()),
      };

  /// `%LocalAppData%` (not the roaming `%AppData%`: what is kept here is big and of this
  /// machine), else the profile's `AppData\Local`. Windows names variables in any case.
  static String _windowsLocal(Map<String, String> env, String temp) {
    final upper = {for (final e in env.entries) e.key.toUpperCase(): e.value};
    bool absolute(String? p) => p != null && RegExp(r'^([A-Za-z]:\\|\\\\)').hasMatch(p);
    final local = upper['LOCALAPPDATA'];
    if (absolute(local)) return local!;
    final profile = upper['USERPROFILE'];
    if (absolute(profile)) return _join(profile!, '\\', 'AppData\\Local');
    return temp;
  }

  static String _home(Map<String, String> env, String temp) {
    final home = env['HOME'];
    return home != null && home.startsWith('/') ? home : temp;
  }

  /// An XDG variable, only when it is an absolute path (the spec says to ignore it otherwise).
  static String? _xdg(Map<String, String> env, String key) {
    final value = env[key];
    return value != null && value.startsWith('/') ? value : null;
  }

  /// [base] then [rest], one [separator] between them (`C:\` and `/` already end in one).
  static String _join(String base, String separator, String rest) =>
      base.endsWith(separator) ? '$base$rest' : '$base$separator$rest';
}
