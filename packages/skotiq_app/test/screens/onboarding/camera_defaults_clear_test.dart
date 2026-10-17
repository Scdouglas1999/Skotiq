// The camera-defaults step must store what its fields show.
//
// `setCameraDefaults` treats a null argument as "leave unchanged", so emptying
// the Gain box must not leave the preset's gain in the draft — and therefore in
// the equipment profile the wizard creates, displaying "no gain" while building
// a rig with one. Same shape for offset, binning and the cooling set-point.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/onboarding/steps/camera_defaults_step.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// A draft as it stands after a camera preset has been applied.
class _PresetAppliedNotifier extends OnboardingNotifier {
  _PresetAppliedNotifier(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const OnboardingDraft(
      currentStep: OnboardingStep.cameraDefaults,
      cameraPresetId: 'zwo-asi2600mc',
      defaultGain: 100,
      defaultOffset: 50,
      defaultBinX: 1,
      defaultBinY: 1,
      defaultCoolingTempC: -10,
    );
  }
}

Future<ProviderContainer> _pump(WidgetTester tester) async {
  final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1280, 1400);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  late ProviderContainer container;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        onboardingDraftProvider.overrideWith(_PresetAppliedNotifier.new),
      ],
      child: Consumer(builder: (ctx, ref, _) {
        container = ProviderScope.containerOf(ctx);
        return MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: Padding(
              padding: EdgeInsets.all(16),
              child: OnboardingCameraDefaultsStep(),
            ),
          ),
        );
      }),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('emptying Gain clears it from the draft', (tester) async {
    final container = await _pump(tester);
    expect(container.read(onboardingDraftProvider).defaultGain, 100);

    await tester.enterText(find.widgetWithText(TextField, '100'), '');
    await tester.pumpAndSettle();

    expect(
      container.read(onboardingDraftProvider).defaultGain,
      isNull,
      reason: 'a blank field cannot sit above a stored value',
    );
    // Untouched neighbours keep their values.
    expect(container.read(onboardingDraftProvider).defaultOffset, 50);
  });

  testWidgets('a rejected binning is not stored', (tester) async {
    final container = await _pump(tester);
    expect(container.read(onboardingDraftProvider).defaultBinX, 1);

    // Bin X is one of the two fields showing "1"; take the first (Bin X).
    await tester.enterText(find.widgetWithText(TextField, '1').first, '0');
    await tester.pumpAndSettle();

    expect(find.text('Binning is 1 or more.'), findsOneWidget);
    expect(
      container.read(onboardingDraftProvider).defaultBinX,
      isNull,
      reason: 'the step refused the value, so it must not reach the profile',
    );
  });

  testWidgets(
      'emptying the cooling set-point clears it but keeps the field '
      'open for editing', (tester) async {
    final container = await _pump(tester);
    expect(container.read(onboardingDraftProvider).defaultCoolingTempC, -10);

    await tester.enterText(find.widgetWithText(TextField, '-10'), '');
    await tester.pumpAndSettle();

    expect(container.read(onboardingDraftProvider).defaultCoolingTempC, isNull);
    // The section stays open — the toggle is the user's choice, not a
    // side effect of the value being momentarily absent.
    expect(find.text('Cooling set-point'), findsOneWidget);

    // Typing a new set-point records it.
    await tester.enterText(find.byType(TextField).last, '-5');
    await tester.pumpAndSettle();
    expect(container.read(onboardingDraftProvider).defaultCoolingTempC, -5);
  });
}
