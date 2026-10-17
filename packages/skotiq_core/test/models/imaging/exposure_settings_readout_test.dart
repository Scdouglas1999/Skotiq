// Tests for the readout-mode handling on [ExposureSettings] in
// `src/models/imaging/imaging_models.dart`.
//
// These pin the back-compat bridge between the legacy [fastReadout] boolean and
// the newer explicit [readoutModeIndex]:
//   - resolveReadoutModeIndex falls back to the fastReadout mapping when no
//     explicit index is set (fast -> last mode, slow -> mode 0);
//   - an explicit readoutModeIndex always wins over fastReadout;
//   - readoutIsFast derives correctly from both the explicit index and the
//     legacy boolean;
//   - copyWith on readoutModeIndex does not clobber fastReadout, so a profile
//     saved before readoutModeIndex existed never regresses on persistence.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/imaging/imaging_models.dart';

void main() {
  // A camera with 3 readout modes: index 0 (slow) .. index 2 (fast).
  const modeCount = 3;

  const base = ExposureSettings(exposureTime: 30.0, gain: 100, offset: 10);

  group('ExposureSettings.resolveReadoutModeIndex', () {
    test('falls back to fastReadout when readoutModeIndex is null', () {
      final fast = base.copyWith(fastReadout: true);
      final slow = base.copyWith(fastReadout: false);

      // No explicit index: legacy boolean drives the resolution.
      expect(fast.readoutModeIndex, isNull);
      expect(slow.readoutModeIndex, isNull);

      // Fast maps to the last mode, slow maps to mode 0 (vendor convention).
      expect(fast.resolveReadoutModeIndex(modeCount), modeCount - 1);
      expect(slow.resolveReadoutModeIndex(modeCount), 0);
    });

    test('explicit readoutModeIndex wins over fastReadout', () {
      // fastReadout=false would otherwise resolve to 0, but the explicit middle
      // mode must override it.
      final explicit = base.copyWith(fastReadout: false, readoutModeIndex: 1);
      expect(explicit.resolveReadoutModeIndex(modeCount), 1);

      // fastReadout=true would otherwise resolve to the last mode (2), but the
      // explicit index 0 must override it.
      final explicitSlow = base.copyWith(
        fastReadout: true,
        readoutModeIndex: 0,
      );
      expect(explicitSlow.resolveReadoutModeIndex(modeCount), 0);
    });

    test(
      'single-mode camera resolves to 0 for both fast and slow fallback',
      () {
        const single = 1;
        final fast = base.copyWith(fastReadout: true);
        final slow = base.copyWith(fastReadout: false);

        // fast -> modeCount-1 == 0 when there is only one mode.
        expect(fast.resolveReadoutModeIndex(single), 0);
        expect(slow.resolveReadoutModeIndex(single), 0);
      },
    );
  });

  group('ExposureSettings.readoutIsFast', () {
    test('derives from fastReadout when readoutModeIndex is null', () {
      expect(base.copyWith(fastReadout: true).readoutIsFast(modeCount), isTrue);
      expect(
        base.copyWith(fastReadout: false).readoutIsFast(modeCount),
        isFalse,
      );
    });

    test('derives from readoutModeIndex when it is set', () {
      // Pointing at the last mode is "fast" regardless of the legacy boolean.
      final atLast = base.copyWith(fastReadout: false, readoutModeIndex: 2);
      expect(atLast.readoutIsFast(modeCount), isTrue);

      // Pointing at any non-last mode is not fast, even if fastReadout is true.
      final atMiddle = base.copyWith(fastReadout: true, readoutModeIndex: 1);
      expect(atMiddle.readoutIsFast(modeCount), isFalse);

      final atFirst = base.copyWith(fastReadout: true, readoutModeIndex: 0);
      expect(atFirst.readoutIsFast(modeCount), isFalse);
    });
  });

  group('ExposureSettings.copyWith persistence back-compat', () {
    test('preserves fastReadout when only readoutModeIndex changes', () {
      // A profile loaded from pre-readoutModeIndex persistence carries only the
      // boolean. Picking an explicit mode in the UI must not drop it.
      final legacy = base.copyWith(fastReadout: true);
      final updated = legacy.copyWith(readoutModeIndex: 0);

      expect(updated.readoutModeIndex, 0);
      expect(
        updated.fastReadout,
        isTrue,
        reason: 'fastReadout must survive a readoutModeIndex-only update',
      );
    });

    test('preserves readoutModeIndex when only fastReadout changes', () {
      final withIndex = base.copyWith(readoutModeIndex: 1);
      final updated = withIndex.copyWith(fastReadout: true);

      expect(updated.readoutModeIndex, 1);
      expect(updated.fastReadout, isTrue);
    });

    test(
      'default ExposureSettings has null readoutModeIndex and slow readout',
      () {
        expect(base.readoutModeIndex, isNull);
        expect(base.fastReadout, isFalse);
      },
    );

    test('readoutModeIndex participates in value equality', () {
      final a = base.copyWith(readoutModeIndex: 1);
      final b = base.copyWith(readoutModeIndex: 1);
      final c = base.copyWith(readoutModeIndex: 2);

      expect(a, equals(b));
      expect(a, isNot(equals(c)));
      expect(a, isNot(equals(base)));
    });
  });
}
