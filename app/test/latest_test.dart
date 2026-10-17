import 'package:curated_score/latest.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the latest turn wins; a cancel leaves every turn behind', () {
    final latest = Latest();
    final a = latest.start(), b = latest.start();
    expect((a.isLatest, b.isLatest), (false, true));
    final document = latest.current;
    expect(document.isLatest, isTrue);
    latest.cancel();
    expect((b.isLatest, document.isLatest, latest.current.isLatest), (false, false, true));
  });
}
