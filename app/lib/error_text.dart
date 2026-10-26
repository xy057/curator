import 'dart:io';
import 'file_names.dart';
import 'l10n/l10n.dart';

/// What to tell the user about [error]: a sentence, not a stack of type names.
///
/// The app's own exceptions already read well (EngraveException, MediaConversionException,
/// a damaged project's FormatException); file errors say which file and why.
String describeError(Object error) => _damaged(switch (error) {
      FileSystemException(:final message, :final path, :final osError) => [
          '${message.isEmpty ? 'Couldn’t use the file'.tr : message.tr}${path == null ? '' : ': “${fileNameOf(path)}”'}.',
          if (osError != null && osError.message.isNotEmpty) '(${osError.message})',
        ].join(' '),
      FormatException(:final message) => message.tr,
      StateError(:final message) => message.tr,
      _ => '$error'.replaceFirst(RegExp(r'^(Exception|Error): '), '').tr,
    });

/// A damaged file's message: what is wrong in it stays as the code names it (a field), after the
/// words in the interface's language.
String _damaged(String message) {
  for (final lead in const ['The project is damaged: ', 'The settings are damaged: ']) {
    if (message.startsWith(lead)) return '${lead.tr}${message.substring(lead.length)}';
  }
  return message;
}
