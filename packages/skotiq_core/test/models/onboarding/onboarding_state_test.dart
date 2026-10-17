import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('OnboardingDraft', () {
    test('defaults to welcome step with empty selections', () {
      const draft = OnboardingDraft();
      expect(draft.currentStep, OnboardingStep.welcome);
      expect(draft.selectedDrivers, isEmpty);
      expect(draft.cameraId, isNull);
      expect(draft.reducerFactor, 1.0);
      expect(draft.filterNames, isEmpty);
    });

    test('imageScaleArcsecPerPixel returns null when inputs missing', () {
      const draft = OnboardingDraft();
      expect(draft.imageScaleArcsecPerPixel, isNull);

      const onlyFocal = OnboardingDraft(focalLengthMm: 1000);
      expect(onlyFocal.imageScaleArcsecPerPixel, isNull);

      const onlyPixel = OnboardingDraft(pixelSizeMicrons: 3.76);
      expect(onlyPixel.imageScaleArcsecPerPixel, isNull);
    });

    test('imageScaleArcsecPerPixel applies reducer factor', () {
      // 1000mm × 0.79 reducer, 3.76 µm pixels → 0.98 arcsec/px
      const draft = OnboardingDraft(
        focalLengthMm: 1000,
        pixelSizeMicrons: 3.76,
        reducerFactor: 0.79,
      );
      final scale = draft.imageScaleArcsecPerPixel!;
      expect(scale, closeTo(0.98, 0.02));
    });

    test('copyWith preserves unspecified fields', () {
      const original = OnboardingDraft(
        cameraId: 'cam-1',
        mountId: 'mount-1',
        focalLengthMm: 500,
      );
      final updated = original.copyWith(focalLengthMm: 1000);
      expect(updated.cameraId, 'cam-1');
      expect(updated.mountId, 'mount-1');
      expect(updated.focalLengthMm, 1000);
    });

    test('copyWith clear flags wipe individual device picks', () {
      const original = OnboardingDraft(
        focuserId: 'foc-1',
        focuserName: 'My focuser',
        filterWheelId: 'fw-1',
        guiderId: 'g-1',
      );
      final cleared = original.copyWith(
        clearFocuser: true,
        clearFilterWheel: true,
        clearGuider: true,
      );
      expect(cleared.focuserId, isNull);
      expect(cleared.focuserName, isNull);
      expect(cleared.filterWheelId, isNull);
      expect(cleared.guiderId, isNull);
    });

    test('JSON round-trip preserves all fields', () {
      const draft = OnboardingDraft(
        currentStep: OnboardingStep.opticalTrain,
        selectedDrivers: {DriverType.native, DriverType.ascom},
        cameraId: 'native:zwo:0',
        cameraName: 'ASI294MC Pro',
        mountId: 'ascom:EQMOD',
        mountName: 'EQ6-R',
        focalLengthMm: 1000,
        apertureMm: 80,
        pixelSizeMicrons: 3.76,
        reducerFactor: 0.79,
        filterNames: ['L', 'R', 'G', 'B'],
        captureDirectory: 'C:/captures',
        profileName: 'Main rig',
      );
      final json = draft.toJsonString();
      final restored = OnboardingDraft.fromJsonStringOrEmpty(json);
      expect(restored, draft);
    });

    test('fromJsonStringOrEmpty returns default on invalid input', () {
      expect(
        OnboardingDraft.fromJsonStringOrEmpty(null),
        const OnboardingDraft(),
      );
      expect(
        OnboardingDraft.fromJsonStringOrEmpty(''),
        const OnboardingDraft(),
      );
      expect(
        OnboardingDraft.fromJsonStringOrEmpty('not json'),
        const OnboardingDraft(),
      );
      // Wrong shape (array instead of object)
      expect(
        OnboardingDraft.fromJsonStringOrEmpty('[1,2,3]'),
        const OnboardingDraft(),
      );
    });

    test('optional steps are flagged for skip-button rendering', () {
      expect(OnboardingStep.focuser.isOptional, isTrue);
      expect(OnboardingStep.filterWheel.isOptional, isTrue);
      expect(OnboardingStep.guider.isOptional, isTrue);
      expect(OnboardingStep.site.isOptional, isTrue);
      expect(OnboardingStep.camera.isOptional, isFalse);
      expect(OnboardingStep.mount.isOptional, isFalse);
      expect(OnboardingStep.opticalTrain.isOptional, isFalse);
    });

    test('site step sits immediately before summary', () {
      expect(OnboardingStep.site.order, OnboardingStep.summary.order - 1);
    });

    test('clear flags null out acquisition set-points a plain null cannot', () {
      // `copyWith(defaultGain: null)` means "leave unchanged", so the
      // camera-defaults step needs an explicit way to say "the user emptied
      // this field" — otherwise a blank box sits above a stored value and the
      // created profile disagrees with the wizard that built it.
      const applied = OnboardingDraft(
        defaultGain: 100,
        defaultOffset: 50,
        defaultBinX: 2,
        defaultBinY: 2,
        defaultCoolingTempC: -10,
      );

      expect(
        applied.copyWith().defaultGain,
        100,
        reason: 'a plain copyWith still preserves the value',
      );

      final cleared = applied.copyWith(
        clearGain: true,
        clearOffset: true,
        clearBinX: true,
        clearBinY: true,
        clearCoolingTempC: true,
      );
      expect(cleared.defaultGain, isNull);
      expect(cleared.defaultOffset, isNull);
      expect(cleared.defaultBinX, isNull);
      expect(cleared.defaultBinY, isNull);
      expect(cleared.defaultCoolingTempC, isNull);

      // Clearing one field leaves its neighbours alone.
      final onlyGain = applied.copyWith(clearGain: true);
      expect(onlyGain.defaultGain, isNull);
      expect(onlyGain.defaultOffset, 50);
      expect(onlyGain.defaultBinX, 2);
      expect(onlyGain.defaultCoolingTempC, -10);
    });

    test('step order maps to display index', () {
      expect(OnboardingStep.welcome.order, 0);
      // The terminal step is now `nextSteps` (the post-creation "what's next"
      // screen), which sits after `summary`.
      expect(OnboardingStep.nextSteps.order, OnboardingStep.values.length - 1);
      expect(OnboardingStep.summary.order, OnboardingStep.nextSteps.order - 1);
      expect(OnboardingStepOrder.total, OnboardingStep.values.length);
    });
  });
}
