import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/providers/equipment/filter_wheel_state_provider.dart';

void main() {
  group('resolveEffectiveFilterNames', () {
    test('prefers profile names when wheel reports generic slots', () {
      expect(
        resolveEffectiveFilterNames(
          wheelNames: const ['Filter 1', 'Filter 2', 'Filter 3', 'Filter 4'],
          profileNames: const ['L', 'R', 'G', 'B'],
        ),
        equals(['L', 'R', 'G', 'B']),
      );
    });

    test('keeps wheel names when both sides are generic', () {
      const wheel = ['Filter 1', 'Filter 2'];
      expect(
        resolveEffectiveFilterNames(
          wheelNames: wheel,
          profileNames: const ['Filter 1', 'Filter 2'],
        ),
        equals(wheel),
      );
    });

    test('keeps real wheel names when driver reports band labels', () {
      const wheel = ['Ha', 'OIII', 'SII'];
      expect(
        resolveEffectiveFilterNames(
          wheelNames: wheel,
          profileNames: const ['L', 'R', 'G', 'B'],
        ),
        equals(wheel),
      );
    });

    test('pads profile names when wheel has more slots', () {
      expect(
        resolveEffectiveFilterNames(
          wheelNames: const ['Filter 1', 'Filter 2', 'Filter 3'],
          profileNames: const ['L', 'R'],
        ),
        equals(['L', 'R', 'Filter 3']),
      );
    });
  });

  group('isGenericFilterSlotName', () {
    test('matches common driver slot labels', () {
      expect(isGenericFilterSlotName('Filter 1'), isTrue);
      expect(isGenericFilterSlotName('filter2'), isTrue);
      expect(isGenericFilterSlotName('Ha'), isFalse);
      expect(isGenericFilterSlotName('L'), isFalse);
    });
  });
}
