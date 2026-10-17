// The two library presets in the optics/camera steps.
//
// Optics: picking Askar FRA400 fills the optics and leaves a green-ticked
// "✓ Askar FRA400" beside the library button. Typing 1234 into the focal length
// must clear it, or the tick sits over 1234 mm / 72 mm / f/13.71 — a scope that
// does not exist — while the green check reads as "validated against the
// library".
//
// Camera: choosing a camera preset on step 9 must not silently rewrite the pixel
// size typed on step 8, with the review page's image scale then computed from
// the replacement and nothing on any screen saying so.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/onboarding/steps/camera_defaults_step.dart';
import 'package:skotiq_app/screens/onboarding/steps/optical_train_step.dart';
import 'package:skotiq_core/skotiq_core.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/providers/hardware_presets_provider.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Future<ProviderContainer> _pump(WidgetTester tester, Widget step) async {
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
      overrides: [databaseProvider.overrideWithValue(db)],
      child: Consumer(builder: (ctx, ref, _) {
        container = ProviderScope.containerOf(ctx);
        return MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(body: step),
        );
      }),
    ),
  );
  await tester.pump();
  await container.read(onboardingDraftProvider.notifier).loaded;
  await tester.pumpAndSettle();
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the telescope badge stops claiming a model once it is edited',
      (tester) async {
    final container = await _pump(tester, const OnboardingOpticalTrainStep());
    final preset =
        container.read(hardwarePresetsServiceProvider).allTelescopes().first;
    await container
        .read(onboardingDraftProvider.notifier)
        .applyTelescopePreset(preset);
    await tester.pumpAndSettle();

    expect(find.text(preset.displayName), findsOneWidget);

    // The step's fields carry their labels as sibling help rows, so the
    // focal length is the first input on the card.
    await tester.enterText(find.byType(TextField).at(0), '1234');
    await tester.pumpAndSettle();

    expect(
      find.text(preset.displayName),
      findsNothing,
      reason: 'a green tick beside a model name reads as "validated"',
    );
    expect(find.text('${preset.displayName} — edited'), findsOneWidget);
  });

  testWidgets('a camera preset says when it replaced a typed pixel size',
      (tester) async {
    final container = await _pump(tester, const OnboardingCameraDefaultsStep());
    final presets = container.read(hardwarePresetsServiceProvider);
    final preset = presets
        .allCameras()
        .firstWhere((p) => (p.pixelSizeMicrons - 3.76).abs() > 0.001);

    final notifier = container.read(onboardingDraftProvider.notifier);
    // Name the camera the step already knows about, so its one-tap
    // "Use <camera> settings" affordance is the path under test.
    await notifier.setCamera(id: 'sim_camera_1', name: preset.displayName);
    await notifier.setOpticalTrain(pixelSizeMicrons: 3.76);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(cameraDefaultsUseMatchedPresetKey));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Pixel size changed from 3.76 to '
          '${preset.pixelSizeMicrons} µm by the ${preset.displayName} preset'),
      findsOneWidget,
    );
  });

  testWidgets('the pixel-size hint does not deny the camera library exists',
      (tester) async {
    await _pump(tester, const OnboardingOpticalTrainStep());
    expect(
      find.text("Not in the camera library — check your camera's datasheet"),
      findsNothing,
    );
  });
}
