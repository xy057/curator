import 'package:curated_score/lanes_common.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a second press soon and near is a double-click; a third starts again', () {
    final clicks = DoubleClicks();
    Duration ms(int n) => Duration(milliseconds: n);
    expect(clicks.press(ms(0), Offset.zero), isFalse);
    expect(clicks.press(ms(200), const Offset(3, 2)), isTrue);
    expect(clicks.press(ms(300), const Offset(3, 2)), isFalse, reason: 'a third is a first');
    expect(clicks.press(ms(800), const Offset(3, 2)), isFalse, reason: 'too late');
    expect(clicks.press(ms(900), const Offset(20, 2)), isFalse, reason: 'too far');
    expect(clicks.press(ms(1000), const Offset(21, 2)), isTrue);
  });
}
