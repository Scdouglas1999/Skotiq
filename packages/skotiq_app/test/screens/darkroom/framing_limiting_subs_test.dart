// qa-surfaces S31: the framing check said "One sub cuts the rest away" for a
// sub whose removal kept the same 98.9% of the field.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/darkroom/targets/framing_check.dart';
import 'package:skotiq_core/services.dart';

void main() {
  test('a sub limits the field only when leaving it out keeps more', () {
    final subs = framingLimitingSubs(
      const [
        DarkroomLimitingFrame(path: 'a', group: 'L', retainedWithout: 0.989),
        DarkroomLimitingFrame(path: 'b', group: 'L', retainedWithout: 0.995),
      ],
      retainedArea: 0.989,
      referencePath: null,
      leftOut: const {},
    );
    expect(subs.map((f) => f.path), ['b']);
  });

  test('a gain the card cannot show is no gain', () {
    final subs = framingLimitingSubs(
      const [
        // 99.14% beside 99.06%: both read "99.1%".
        DarkroomLimitingFrame(path: 'a', group: 'L', retainedWithout: 0.9914),
        DarkroomLimitingFrame(path: 'b', group: 'L', retainedWithout: 0.9922),
      ],
      retainedArea: 0.9906,
      referencePath: null,
      leftOut: const {},
    );
    expect(subs.map((f) => f.path), ['b']);
  });
}
