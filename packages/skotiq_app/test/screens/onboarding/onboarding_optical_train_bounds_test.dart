// The optical-train step must not present an implausible optical system as a
// computed fact, and must point at the field that is wrong.
//
// Checking only "> 0" leaves focal length 999999999 with aperture 0.0001
// un-flagged, and the Computed values panel prints "f/9999999990000.00" in the
// same confident mono readout it uses for real numbers. Focal length reaches the
// FITS FOCALLEN card, plate-solve field-of-view estimation and the arcsec/px
// image scale, so this is not cosmetic.
//
// The bounds themselves live in OpticalTrainLimits (skotiq_core) and are
// unit-tested there. What is pinned here is that the STEP honours them: the
// offending field turns red with the same numbers, and no derived value is
// rendered from rejected inputs.
//
// The second half of each case matters as much as the first: a real rig must
// still sail through with no friction.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/onboarding/steps/optical_train_step.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/pump_app_screen.dart';

/// Field order in the step: focal length, aperture, reducer, pixel size.
const _focalLength = 0;
const _aperture = 1;
const _reducer = 2;
const _pixelSize = 3;

Future<void> _type(WidgetTester tester, int field, String value) async {
  await tester.enterText(find.byType(TextField).at(field), value);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'an implausible train renders no derived value and flags the field',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const OnboardingOpticalTrainStep(),
      size: const Size(1000, 900),
    );
    await handle.container.read(onboardingDraftProvider.notifier).loaded;
    await tester.pumpAndSettle();

    await _type(tester, _focalLength, '999999999');
    await _type(tester, _aperture, '0.0001');
    await _type(tester, _pixelSize, '3.76');

    // The headline defect: no fabricated focal ratio anywhere on the step.
    expect(
      find.textContaining('f/'),
      findsNothing,
      reason: 'a focal ratio was rendered from out-of-range inputs',
    );
    // The readouts withhold every derived quantity: an em dash, never a
    // number the optics cannot support. The reason is on the field itself,
    // asserted below.
    expect(find.text('\u2014'), findsWidgets);

    // Both offending fields carry the shared bound, so the user knows where the
    // edge is without pressing Next.
    expect(
      find.text('Must be between ${OpticalTrainLimits.minFocalLengthMm.toInt()}'
          ' and ${OpticalTrainLimits.maxFocalLengthMm.toInt()} mm.'),
      findsOneWidget,
    );
    expect(
      find.text('Must be between ${OpticalTrainLimits.minApertureMm.toInt()}'
          ' and ${OpticalTrainLimits.maxApertureMm.toInt()} mm.'),
      findsOneWidget,
    );

    // And the wizard-level gate agrees with the field-level one.
    final draft = handle.container.read(onboardingDraftProvider);
    expect(
      OpticalTrainLimits.validate(
        focalLengthMm: draft.focalLengthMm,
        apertureMm: draft.apertureMm,
        pixelSizeMicrons: draft.pixelSizeMicrons,
        reducerFactor: draft.reducerFactor,
      ),
      isNotNull,
    );
  });

  testWidgets('an ordinary rig computes cleanly with no warnings',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const OnboardingOpticalTrainStep(),
      size: const Size(1000, 900),
    );
    await handle.container.read(onboardingDraftProvider.notifier).loaded;
    await tester.pumpAndSettle();

    // 600 mm f/6 refractor with a 3.76 µm sensor — the single most ordinary
    // small-scope imaging setup there is.
    await _type(tester, _focalLength, '600');
    await _type(tester, _aperture, '100');
    await _type(tester, _pixelSize, '3.76');

    expect(find.text('f/6.00'), findsOneWidget);
    expect(find.textContaining('600.0'), findsOneWidget);
    expect(find.text('\u2014'), findsNothing);
    expect(find.textContaining('Must be between'), findsNothing);

    final draft = handle.container.read(onboardingDraftProvider);
    expect(
      OpticalTrainLimits.validate(
        focalLengthMm: draft.focalLengthMm,
        apertureMm: draft.apertureMm,
        pixelSizeMicrons: draft.pixelSizeMicrons,
        reducerFactor: draft.reducerFactor,
      ),
      isNull,
      reason: 'a 600/100 f/6 rig with a 3.76 µm sensor must not be blocked',
    );
  });

  testWidgets('a reducer outside its bounds suppresses the derived numbers',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const OnboardingOpticalTrainStep(),
      size: const Size(1000, 900),
    );
    await handle.container.read(onboardingDraftProvider.notifier).loaded;
    await tester.pumpAndSettle();

    await _type(tester, _focalLength, '600');
    await _type(tester, _aperture, '100');
    await _type(tester, _pixelSize, '3.76');
    expect(find.text('f/6.00'), findsOneWidget);

    // A 500x "reducer" is a typo, not an accessory.
    await _type(tester, _reducer, '500');
    expect(find.textContaining('f/'), findsNothing);
    expect(find.text('\u2014'), findsWidgets);
    expect(
      find.text('Must be between ${OpticalTrainLimits.minReducerFactor} and '
          '${OpticalTrainLimits.maxReducerFactor.toInt()}.'),
      findsOneWidget,
    );

    // Back to a real 0.79x reducer: everything recomputes, nothing complains.
    await _type(tester, _reducer, '0.79');
    expect(find.text('f/4.74'), findsOneWidget);
    expect(find.text('\u2014'), findsNothing);
  });
}
