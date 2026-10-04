// Builds the native engine (Verovio + recording bridge) with CMake and bundles it
// with the app. Runs automatically during `flutter run`, `flutter build` and `flutter test`.
// CMake builds in parallel and incrementally: the first build takes a few minutes,
// later ones only recompile what changed.

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final code = input.config.code;
    final os = code.targetOS;
    final arch = code.targetArchitecture;

    final source = input.packageRoot.resolve('src/');
    _checkPatched(input.packageRoot);
    // Shared across hook runs so incremental builds survive `flutter clean` of the app.
    final buildDir = input.outputDirectoryShared.resolve('cmake-${os.name}-${arch.name}/');
    final cmake = _findCMake();

    await _run(cmake, [
      '-S', source.toFilePath(),
      '-B', buildDir.toFilePath(),
      '-DCMAKE_BUILD_TYPE=Release',
      if (os == OS.macOS) ...[
        '-DCMAKE_OSX_ARCHITECTURES=${arch == Architecture.arm64 ? 'arm64' : 'x86_64'}',
        '-DCMAKE_OSX_DEPLOYMENT_TARGET=${code.macOS.targetVersion}',
      ],
      if (os == OS.windows) ...['-A', arch == Architecture.arm64 ? 'ARM64' : 'x64'],
    ]);
    await _run(cmake, [
      '--build', buildDir.toFilePath(),
      '--config', 'Release',
      '--parallel', '${Platform.numberOfProcessors}',
    ]);

    final library = switch (os) {
      OS.windows => buildDir.resolve('Release/score_engine.dll'),
      _ => buildDir.resolve(os.dylibFileName('score_engine')),
    };
    output.assets.code.add(CodeAsset(
      package: input.packageName,
      name: 'src/native/bindings.dart',
      linkMode: DynamicLoadingBundled(),
      file: library,
    ));

    // Re-run the hook when the bridge, the font measuring, the build script or our Verovio
    // patches change.
    // Verovio itself is pinned.
    for (final file in ['CMakeLists.txt', 'verovio_bridge.cpp', 'verovio_bridge.h', 'font_metrics.cpp', 'stb_truetype.h']) {
      output.dependencies.add(source.resolve(file));
    }
    for (final patch in _patches(input.packageRoot)) {
      output.dependencies.add(patch.uri);
    }
  });
}

List<File> _patches(Uri packageRoot) {
  final dir = Directory.fromUri(packageRoot.resolve('../../patches/'));
  if (!dir.existsSync()) return const [];
  return dir.listSync().whereType<File>().where((f) => f.path.endsWith('.patch')).toList();
}

/// Verovio has to be patched with every patch as it is now (`make setup` does it and leaves a
/// stamp); building unpatched sources would quietly lose what the patches fix.
void _checkPatched(Uri packageRoot) {
  final stamp = File.fromUri(packageRoot.resolve('third_party/verovio/.curated-score-patched'));
  final stale = !stamp.existsSync() ||
      _patches(packageRoot).any((p) => p.lastModifiedSync().isAfter(stamp.lastModifiedSync()));
  if (stale) {
    throw Exception('Verovio is missing our patches (or they changed since). Run `make setup` at the repository root.');
  }
}

String _findCMake() {
  final candidates = [
    '/opt/homebrew/bin/cmake',
    '/usr/local/bin/cmake',
    '/Applications/CMake.app/Contents/bin/cmake',
    '/usr/bin/cmake',
  ];
  for (final path in candidates) {
    if (File(path).existsSync()) return path;
  }
  return 'cmake'; // rely on PATH (Windows: Visual Studio ships one)
}

Future<void> _run(String executable, List<String> arguments) async {
  final result = await Process.run(executable, arguments, runInShell: Platform.isWindows);
  if (result.exitCode != 0) {
    throw Exception('$executable ${arguments.join(' ')} failed (${result.exitCode}):\n'
        '${result.stdout}\n${result.stderr}');
  }
}
