// Builds the native engine (Verovio + recording bridge) with CMake and bundles it
// with the app, beside PDFium (fetched once, a release of bblanchon/pdfium-binaries, checked
// by its SHA-256), which opens PDF scores. Runs automatically during `flutter run`, `flutter build` and `flutter test`.
// CMake builds in parallel and incrementally: the first build takes a few minutes,
// later ones only recompile what changed.

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
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
        // The whole version (12.0, not 12); AppleVersion's toString isn't one.
        '-DCMAKE_OSX_DEPLOYMENT_TARGET=${code.macOS.deploymentVersion.major}.${code.macOS.deploymentVersion.minor}',
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

    output.assets.code.add(CodeAsset(
      package: input.packageName,
      name: 'src/native/pdfium.dart',
      linkMode: DynamicLoadingBundled(),
      file: await _pdfium(input.outputDirectoryShared, os, arch),
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

/// PDFium's release, and each build's SHA-256 (its .tgz as published).
const _pdfiumRelease = 'chromium/8152';
const _pdfiumBuilds = {
  'mac-arm64': '30b0c3f55448840f0947b54bedbe35185bbaccbadd35b8cd960270d6fa6caf80',
  'mac-x64': 'acb975e637ffa1f41430205c62baacac70e34b60811e22fc0e0274dfcd601fcc',
  'win-x64': 'cee2b0e9990bc67c0721774932961b9dbf2766046c10eec925acd4cfba6fdfe3',
  'win-arm64': '8614b10c6a780acc3ae9fdd425d6b61f9d22ae84301b19e1ac82f573930c217c',
  'linux-x64': '384ab5c51882408a143a21f9c14dcd2caf1f75280ae41c554d0489b46c3dba9f',
  'linux-arm64': 'c6ed1a91234aede0cfafdc09c401b83bd44ac69deafc4599fda75d511c36403e',
};

/// PDFium's library for [os] on [arch], fetched into [shared] the first time (and kept there,
/// as the CMake build is), refused unless its archive is the one published.
Future<Uri> _pdfium(Uri shared, OS os, Architecture arch) async {
  final platform = switch (os) {
    OS.macOS => 'mac',
    OS.windows => 'win',
    OS.linux => 'linux',
    _ => throw UnsupportedError('No PDFium for $os'),
  };
  final build = '$platform-${arch == Architecture.arm64 ? 'arm64' : 'x64'}';
  final hash = _pdfiumBuilds[build] ?? (throw UnsupportedError('No PDFium for $build'));
  final (member, name) = switch (os) {
    OS.windows => ('bin/pdfium.dll', 'pdfium.dll'),
    OS.macOS => ('lib/libpdfium.dylib', 'libpdfium.dylib'),
    _ => ('lib/libpdfium.so', 'libpdfium.so'),
  };
  final library = shared.resolve('pdfium-${_pdfiumRelease.replaceAll('/', '-')}/$build/$name');
  final file = File.fromUri(library);
  if (file.existsSync()) return library;
  final url = Uri.parse('https://github.com/bblanchon/pdfium-binaries/releases/download/'
      '${Uri.encodeComponent(_pdfiumRelease)}/pdfium-$build.tgz');
  final client = HttpClient();
  final List<int> bytes;
  try {
    final response = await (await client.getUrl(url)).close();
    if (response.statusCode != 200) throw Exception('Couldn’t fetch PDFium ($url): HTTP ${response.statusCode}');
    bytes = [for (final chunk in await response.toList()) ...chunk];
  } finally {
    client.close();
  }
  if (sha256.convert(bytes).toString() != hash) throw Exception('PDFium from $url isn’t the build expected (SHA-256)');
  final entry = TarDecoder().decodeBytes(GZipDecoder().decodeBytes(bytes)).findFile(member) ??
      (throw Exception('$url has no $member'));
  file.parent.createSync(recursive: true);
  final part = File('${file.path}.part')..writeAsBytesSync(entry.content);
  part.renameSync(file.path);
  return library;
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
