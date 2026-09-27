import 'dart:io';

/// What to tell the user about [error]: a sentence, not a stack of type names.
///
/// The app's own exceptions already read well (EngraveException, MediaConversionException,
/// a damaged project's FormatException); file errors say which file and why.
String describeError(Object error) => switch (error) {
      FileSystemException(:final message, :final path, :final osError) => [
          '${message.isEmpty ? 'The file could not be used' : message}${path == null ? '' : ': “${path.split(RegExp(r'[/\\]')).last}”'}.',
          if (osError != null && osError.message.isNotEmpty) '(${osError.message})',
        ].join(' '),
      FormatException(:final message) => message,
      StateError(:final message) => message,
      _ => '$error'.replaceFirst(RegExp(r'^(Exception|Error): '), ''),
    };
