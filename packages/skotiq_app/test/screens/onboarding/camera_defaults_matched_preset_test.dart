// Don't make the user identify their camera twice.
//
// Live finding: onboarding step 3 picks the camera; step 9 ("Set your capture
// defaults") then offered only "Choose from camera library", so the operator
// had to find the same camera again in a list the app can search itself. The
// step now leads with the library entry for the camera already chosen, by name.
//
// Still a tap, not a silent write: gain and offset are the imager's call and
// the library only recommends. An unrecognised camera offers nothing rather
// than guessing.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/onboarding/steps/camera_defaults_step.dart';
import 'package:skotiq_core/skotiq_core.dart';
// Outside the core barrel by design; see camera_defaults_step.dart.
// ignore: implementation_imports
import 'package:skotiq_core/src/providers/hardware_presets_provider.dart';

import '../../harness/pump_app_screen.dart';

Future<HarnessHandle> _pumpWithCamera(
  WidgetTester tester,
  String? cameraName,
) async {
  final handle = await pumpAppScreen(
    tester,
    const OnboardingCameraDefaultsStep(),
    size: const Size(1200, 900),
    settle: false,
  );
  final notifier = handle.container.read(onboardingDraftProvider.notifier);
  await notifier.loaded;
  if (cameraName != null) {
    await notifier.setCamera(id: 'native:cam', name: cameraName);
  }
  await tester.pumpAndSettle();
  return handle;
}

void main() {
  testWidgets('the camera already chosen is offered by name', (tester) async {
    final handle = await _pumpWithCamera(tester, 'ASI2600MM Pro');

    final button = find.byKey(cameraDefaultsUseMatchedPresetKey);
    expect(button, findsOneWidget);
    expect(find.textContaining('ASI2600MM'), findsWidgets);

    // Nothing is applied until it is asked for.
    expect(
        handle.container.read(onboardingDraftProvider).cameraPresetId, isNull);

    await tester.tap(button);
    await tester.pumpAndSettle();

    final draft = handle.container.read(onboardingDraftProvider);
    final preset = handle.container
        .read(hardwarePresetsServiceProvider)
        .matchCameraByName('ASI2600MM Pro')!;
    expect(draft.cameraPresetId, preset.id);
    expect(draft.defaultGain, preset.recommendedGain);
    expect(draft.defaultOffset, preset.recommendedOffset);

    // Once applied the shortcut retires — the library button remains for a
    // deliberate change of mind.
    expect(find.byKey(cameraDefaultsUseMatchedPresetKey), findsNothing);
    expect(find.text('Choose from camera library'), findsOneWidget);
  });

  testWidgets('an unrecognised camera offers no shortcut', (tester) async {
    // A plausible wrong gain is worse than an empty field.
    final handle = await _pumpWithCamera(tester, 'Homebrew CCD 1');
    expect(
      handle.container
          .read(hardwarePresetsServiceProvider)
          .matchCameraByName('Homebrew CCD 1'),
      isNull,
    );

    expect(find.byKey(cameraDefaultsUseMatchedPresetKey), findsNothing);
    expect(find.text('Choose from camera library'), findsOneWidget);
  });

  testWidgets('no camera chosen offers no shortcut', (tester) async {
    await _pumpWithCamera(tester, null);
    expect(find.byKey(cameraDefaultsUseMatchedPresetKey), findsNothing);
  });
}
