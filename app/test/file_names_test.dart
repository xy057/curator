import 'package:curated_score/file_names.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a path names its file the same with either slash', () {
    expect(fileNameOf('/Users/a/Op. 9.mxl'), 'Op. 9.mxl');
    expect(fileNameOf(r'C:\Users\a\Take.ccs'), 'Take.ccs');
    expect(fileNameOf('Take.ccs'), 'Take.ccs');
  });

  test('a name loses only its last extension; a leading dot is no extension', () {
    expect(stemOf('Op. 9.mxl'), 'Op. 9');
    expect(stemOf('score.musicxml.zip'), 'score.musicxml');
    expect(stemOf('.hidden'), '.hidden');
    expect(stemOf('Untitled'), 'Untitled');
  });
}
