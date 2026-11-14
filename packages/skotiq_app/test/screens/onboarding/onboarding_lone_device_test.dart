// What the scan already answered is not asked again.
//
// Walk-2 F3: with exactly one mount (focuser, wheel) found, nothing was
// selected and Next on the mount step stopped at "Pick a mount before
// continuing."; the camera-defaults step said "Pick your camera" with the
// camera picked two steps earlier.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/onboarding/steps/camera_defaults_step.dart';
import 'package:skotiq_app/screens/onboarding/steps/guider_step.dart';
import 'package:skotiq_app/screens/onboarding/steps/mount_step.dart';
import 'package:skotiq_app/screens/onboarding/steps/optical_train_step.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';

UnifiedDevice _device(String id, String name, DeviceType type,
        [DriverType driver = DriverType.native]) =>
    UnifiedDevice(
      canonicalName: name.toLowerCase(),
      displayName: name,
      type: type,
      availableBackends: {
        driver: DeviceInfo(
          id: id,
          name: name,
          deviceType: type,
          driverType: driver,
          description: '',
          driverVersion: '',
        ),
      },
    );

class _Discovery extends UnifiedDiscoveryNotifier {
  _Discovery(super.ref) {
    state = state.copyWith(
      groupedDevices: [
        _device('native:eq6', 'EQ6-R Pro', DeviceType.mount),
        _device(
          'native:builtin_guider:multi_star',
          'Built-in Multi-Star Guider',
          DeviceType.guider,
        ),
      ],
      rawDevices: const [],
    );
  }

  @override
  Future<void> discoverAll({
    bool includeIndi = true,
    bool includeAlpaca = true,
  }) async {}
}

Future<HarnessHandle> _pump(WidgetTester tester, Widget step) async {
  final handle = await pumpAppScreen(
    tester,
    step,
    size: const Size(1200, 1000),
    extraOverrides: [unifiedDiscoveryProvider.overrideWith(_Discovery.new)],
    settle: false,
  );
  await handle.container.read(onboardingDraftProvider.notifier).loaded;
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
  return handle;
}

void main() {
  testWidgets('the only mount found is picked', (tester) async {
    final handle = await _pump(tester, const OnboardingMountStep());

    final draft = handle.container.read(onboardingDraftProvider);
    expect(draft.mountId, 'native:eq6');
    expect(draft.mountName, 'EQ6-R Pro');
  });

  testWidgets('a mount the user cleared stays cleared', (tester) async {
    final handle = await _pump(tester, const OnboardingMountStep());
    expect(handle.container.read(onboardingDraftProvider).mountId, isNotNull);

    await tester.tap(find.text('Clear selection'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('Scan again'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    expect(handle.container.read(onboardingDraftProvider).mountId, isNull);
  });

  testWidgets('the built-in guider is not picked for the user', (tester) async {
    // Most users guide with PHD2, chosen above the list; a lone native guider
    // is not an answer to the step.
    final handle = await _pump(tester, const OnboardingGuiderStep());

    expect(handle.container.read(onboardingDraftProvider).guiderId, isNull);
  });

  testWidgets('camera defaults name the camera already picked', (tester) async {
    final handle = await _pump(tester, const OnboardingCameraDefaultsStep());
    await handle.container
        .read(onboardingDraftProvider.notifier)
        .setCamera(id: 'sim_camera_1', name: 'Simulated Camera');
    await tester.pump();

    expect(find.textContaining('Pick your camera'), findsNothing);
    expect(
      find.textContaining('Simulated Camera is not in the camera library'),
      findsOneWidget,
    );
  });

  testWidgets('a library camera shows its field of view with the optics',
      (tester) async {
    final handle = await _pump(tester, const OnboardingOpticalTrainStep());
    final notifier = handle.container.read(onboardingDraftProvider.notifier);
    // IMX571: 6248 x 4176 at 3.76 um. At 800 mm that is 0.97"/px, so
    // 1.68 x 1.12 degrees.
    await notifier.setCamera(
      id: 'native:asi2600mm',
      name: 'ASI2600MM Pro',
      pixelSizeMicrons: 3.76,
    );
    await notifier.setOpticalTrain(
      focalLengthMm: 800,
      apertureMm: 160,
      pixelSizeMicrons: 3.76,
    );
    await tester.pump();

    final fov = find.byWidgetPredicate(
      (w) => w is Readout && w.label == 'Field of view',
    );
    expect(fov, findsOneWidget);
    expect(tester.widget<Readout>(fov).value, '1.68° × 1.12°');
  });
}
