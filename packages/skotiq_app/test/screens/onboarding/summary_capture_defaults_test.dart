// "Review and save" has to show the acquisition set-points it is about to bake
// into the equipment profile.
//
// The review card listed devices, optics, folder and site but silently omitted
// everything the camera-defaults step collected, so the last screen before the
// rig is created did not show gain, offset, binning or the cooling set-point
// that the profile would carry.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/onboarding/steps/summary_step.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _SeededNotifier extends OnboardingNotifier {
  _SeededNotifier(super.ref, OnboardingDraft draft) {
    // ignore: invalid_use_of_protected_member
    state = draft;
  }
}

Future<void> _pump(WidgetTester tester, OnboardingDraft draft) async {
  final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1280, 1400);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        onboardingDraftProvider
            .overrideWith((ref) => _SeededNotifier(ref, draft)),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: EdgeInsets.all(16),
            child: OnboardingSummaryStep(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the review card lists the capture defaults being saved', (
    tester,
  ) async {
    await _pump(
      tester,
      const OnboardingDraft(
        currentStep: OnboardingStep.summary,
        profileName: 'Rig',
        defaultGain: 100,
        defaultOffset: 50,
        defaultBinX: 1,
        defaultBinY: 1,
        defaultCoolingTempC: -10,
      ),
    );

    expect(find.text('Capture defaults'), findsOneWidget);
    expect(
        find.text('gain 100 · offset 50 · bin 1×1 · -10 °C'), findsOneWidget);
  });

  testWidgets('no set-points reads as not set rather than invented numbers', (
    tester,
  ) async {
    await _pump(
      tester,
      const OnboardingDraft(
        currentStep: OnboardingStep.summary,
        profileName: 'Rig',
      ),
    );

    expect(find.text('Capture defaults'), findsOneWidget);
    // Every unset row renders the same muted placeholder; the point is that no
    // gain/offset value is printed for a profile that carries none.
    expect(find.textContaining('gain'), findsNothing);
  });
}
