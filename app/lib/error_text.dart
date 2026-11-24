import 'dart:io';

import 'package:score_engine/score_engine.dart' show WordsFormatException;

import 'file_names.dart';
import 'l10n/l10n.dart';

/// What to tell the user about [error]: a sentence, not a stack of type names.
///
/// The app's own exceptions already read well (EngraveException, MediaConversionException,
/// a damaged project's FormatException), the engine's in words the app says
/// ([WordsFormatException]); file errors say which file and why.
String describeError(Object error) => _damaged(switch (error) {
      FileSystemException(:final message, :final path, :final osError) => [
          if (path == null)
            '{error}.'.fill({'error': message.isEmpty ? 'Couldn’t use the file'.tr : message.tr})
          else
            '{error}: “{file}”.'.fill({'error': message.isEmpty ? 'Couldn’t use the file'.tr : message.tr, 'file': fileNameOf(path)}),
          if (osError != null && osError.message.isNotEmpty) '(${osError.message})',
        ].join(' '),
      WordsFormatException(:final words) => words.tr,
      FormatException(:final message) => message.tr,
      StateError(:final message) => message.tr,
      _ => '$error'.replaceFirst(RegExp(r'^(Exception|Error): '), '').tr,
    });

/// A damaged file's message: what is wrong in it stays as the code names it (a field), after the
/// words in the interface's language.
String _damaged(String message) {
  const project = 'The project is damaged: ', settings = 'The settings are damaged: ';
  if (message.startsWith(project)) {
    return 'The project is damaged: {detail}'.fill({'detail': message.substring(project.length)});
  }
  if (message.startsWith(settings)) {
    return 'The settings are damaged: {detail}'.fill({'detail': message.substring(settings.length)});
  }
  return message;
}
