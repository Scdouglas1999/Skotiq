// The optical-train step must not ask for a number the app already holds.
//
// Live finding: onboarding step 3 picks the camera, and step 8 then showed an
// empty "Camera pixel size" field whose placeholder was literally "Look this up
// in your camera spec sheet". Pixel pitch is a physical property of the sensor
// the driver just named, not a preference — and the app ships a camera library
// that knows it. Image scale, plate-solve field of view and the FITS header all
// hang off that number, so getting it wrong is a real cost.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/onboarding/steps/camera_step.dart';
import 'package:skotiq_core/skotiq_core.dart';
// Outside the core barrel by design (it collides with `cameraPresetsProvider`),
// so imported by source path — the same route camera_step.dart takes.
// ignore: implementation_imports
import 'package:skotiq_core/src/providers/hardware_presets_provider.dart';

import '../../harness/pump_app_screen.dart';

/// Discovery that reports exactly one camera, named the way a real driver
/// names it — the prefill has to survive going through the name matcher.
class _OneCameraDiscovery extends UnifiedDiscoveryNotifier {
  _OneCameraDiscovery(super.ref) {
    state = state.copyWith(
      groupedDevices: [_camera],
      rawDevices: const [],
    );
  }

  @override
  Future<void> discoverAll({
    bool includeIndi = true,
    bool includeAlpaca = true,
  }) async {}
}

const _camera = UnifiedDevice(
  canonicalName: 'asi2600mm pro',
  displayName: 'ASI2600MM Pro',
  type: DeviceType.camera,
  availableBackends: {
    DriverType.native: DeviceInfo(
      id: 'native:asi2600mm',
      name: 'ASI2600MM Pro',
      deviceType: DeviceType.camera,
      driverType: DriverType.native,
      description: '',
      driverVersion: '',
    ),
  },
);

Future<HarnessHandle> _pumpCameraStep(WidgetTester tester) async {
  final handle = await pumpAppScreen(
    tester,
    const OnboardingCameraStep(),
    size: const Size(1200, 900),
    extraOverrides: [
      unifiedDiscoveryProvider.overrideWith(_OneCameraDiscovery.new),
    ],
    settle: false,
  );
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
  return handle;
}

void main() {
  testWidgets('picking a known camera seeds its pixel size', (tester) async {
    final handle = await _pumpCameraStep(tester);
    await handle.container.read(onboardingDraftProvider.notifier).loaded;

    expect(
      handle.container.read(onboardingDraftProvider).pixelSizeMicrons,
      isNull,
      reason: 'nothing picked yet, so nothing may be claimed',
    );

    await tester.tap(find.text('ASI2600MM Pro').first);
    await tester.pumpAndSettle();

    final draft = handle.container.read(onboardingDraftProvider);
    expect(draft.cameraId, 'native:asi2600mm');
    // IMX571 mono: 3.76 um. Sourced from the shipped camera library, not
    // invented here — a wrong prefill is worse than an empty field.
    final expected = handle.container
        .read(hardwarePresetsServiceProvider)
        .matchCameraByName('ASI2600MM Pro')
        ?.pixelSizeMicrons;
    expect(expected, isNotNull,
        reason: 'the camera library no longer knows this camera; '
            'the test proves nothing');
    expect(draft.pixelSizeMicrons, expected);
  });

  testWidgets('an unrecognised camera prefills nothing', (tester) async {
    // Guessing a pixel size for a camera the library has never heard of would
    // put a plausible wrong number into image scale and the FITS header.
    final handle = await _pumpCameraStep(tester);
    await handle.container.read(onboardingDraftProvider.notifier).loaded;
    final service = handle.container.read(hardwarePresetsServiceProvider);
    expect(service.matchCameraByName('Homebrew CCD 1'), isNull);

    await handle.container.read(onboardingDraftProvider.notifier).setCamera(
          id: 'native:homebrew',
          name: 'Homebrew CCD 1',
          pixelSizeMicrons:
              service.matchCameraByName('Homebrew CCD 1')?.pixelSizeMicrons,
        );

    expect(
      handle.container.read(onboardingDraftProvider).pixelSizeMicrons,
      isNull,
    );
  });
}
