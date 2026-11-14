import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';
import 'package:score_engine/score_engine.dart';

import '../edit_dialogs.dart' show confirmSavePath;
import '../error_text.dart';
import '../file_names.dart';

/// The most an extension is given of a file (`ui.open_file`), whatever it asks for.
const maxExtensionFileBytes = 64 << 20;

/// A file's text: UTF-8, UTF-16 by its byte-order mark, else Windows Latin-1 (as older
/// subtitle files are).
String decodeText(List<int> bytes) {
  if (bytes.length >= 2 && ((bytes[0] == 0xFF && bytes[1] == 0xFE) || (bytes[0] == 0xFE && bytes[1] == 0xFF))) {
    final little = bytes[0] == 0xFF;
    return String.fromCharCodes([
      for (var i = 2; i + 1 < bytes.length; i += 2) little ? bytes[i] | bytes[i + 1] << 8 : bytes[i] << 8 | bytes[i + 1],
    ]);
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return latin1.decode(bytes);
  }
}

List<XTypeGroup> _types(LuaTable spec) => [
      if (spec['types'] case final LuaTable types)
        for (final t in types.array.whereType<LuaTable>())
          XTypeGroup(
            label: switch (t['label']) { final String s => s, _ => null },
            extensions: [
              if (t['extensions'] case final LuaTable extensions)
                for (final e in extensions.array.whereType<String>()) e,
            ],
          ),
    ];

/// Asks for a file an extension reads (`ui.open_file`), and hands its `done` the file as text:
/// {name, text}; {name, too_big} past the bytes it reads at most (`max`); {name, error} when it
/// can't be read. Nothing chosen calls nothing.
Future<void> openExtensionFile(ExtensionRuntime runtime, LuaTable spec) async {
  final file = await openFile(acceptedTypeGroups: _types(spec));
  final done = spec['done'];
  if (file == null || done is! LuaFunction) return;
  final most = switch (spec['max']) { final num n when n >= 1 && n <= maxExtensionFileBytes => n.toInt(), _ => maxExtensionFileBytes };
  final result = LuaTable.map({'name': file.name});
  try {
    if (await file.length() > most) {
      result['too_big'] = true;
    } else {
      result['text'] = decodeText(await file.readAsBytes());
    }
  } catch (e) {
    result['error'] = describeError(e);
  }
  runtime.call(done, args: [result], where: 'ui.open_file done');
}

/// Asks where an extension's file goes (`ui.save_file`), then writes what its `write` gives
/// for the place chosen: {name, extension}, the extension the name's when it is one of the
/// types', else the chosen type's first. `done` is told once it is written, or why it wasn't
/// ({error}).
Future<void> saveExtensionFile(BuildContext context, ExtensionRuntime runtime, LuaTable spec) async {
  final types = _types(spec);
  final location = await getSaveLocation(acceptedTypeGroups: types, suggestedName: switch (spec['name']) { final String s => s, _ => null });
  if (location == null || !context.mounted) return;
  final known = [for (final t in types) ...?t.extensions];
  final dot = location.path.lastIndexOf('.'), typed = dot < 0 ? '' : location.path.substring(dot + 1).toLowerCase();
  final extension = known.contains(typed) ? typed : location.activeFilter?.extensions?.firstOrNull ?? known.firstOrNull;
  final path = extension == null ? location.path : await confirmSavePath(context, location.path, extension);
  if (path == null) return;
  final file = LuaTable.map({'name': fileNameOf(path), 'extension': extension ?? typed});
  final write = spec['write'], done = spec['done'];
  if (write is! LuaFunction) return;
  final text = runtime.call(write, args: [file], where: 'ui.save_file write')?.firstOrNull;
  if (text is! String) return; // it wrote nothing: what went wrong is among its problems
  try {
    await File(path).writeAsString(text);
  } catch (e) {
    file['error'] = describeError(e);
  }
  if (done is LuaFunction) runtime.call(done, args: [file], where: 'ui.save_file done');
}
