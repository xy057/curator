import 'dart:io';

import 'package:curated_score/error_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('errors read as sentences', () {
    expect(describeError(const FileSystemException('Cannot open file', '/a/b/Take 1.wav', OSError('No such file or directory', 2))),
        'Cannot open file: “Take 1.wav”. (No such file or directory)');
    expect(describeError(const FormatException('The project is damaged: state.view.grid is not text.')),
        'The project is damaged: state.view.grid is not text.');
    expect(describeError(Exception('Something odd')), 'Something odd');
    expect(describeError(StateError('Choose where to save it.')), 'Choose where to save it.');
  });
}
