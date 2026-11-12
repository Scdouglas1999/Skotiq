// The built-in guider needs a camera to guide with.
//
// Walk-2 F4: picking "Built-in Multi-Star Guider" asked nothing more; Review
// listed the guider and no guide camera, and a rig with real hardware was saved
// with a guider that had nothing to take frames with.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/onboarding/steps/guider_step.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../../harness/pump_app_screen.dart';

UnifiedDevice _device(String id, String name, DeviceType type) =>
    UnifiedDevice(
      canonicalName: name.toLowerCase(),
      displayName: name,
      type: type,
      availableBackends: {
        DriverType.native: DeviceInfo(
          id: id,
          name: name,
          deviceType: type,
          driverType: DriverType.native,
          description: '',
          driverVersion: '',
        ),
      },
    );

class _Discovery extends UnifiedDiscoveryNotifier {
  _Discovery(super.ref) {
    state = state.copyWith(
      groupedDevices: [
        _device('native:asi2600', 'ASI2600MM Pro', DeviceType.camera),
        _device('native:asi120', 'ASI120MM Mini', DeviceType.camera),
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

void main() {
  testWidgets('choosing the built-in guider asks which camera guides',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const OnboardingGuiderStep(),
      size: const Size(1200, 1600),
      extraOverrides: [unifiedDiscoveryProvider.overrideWith(_Discovery.new)],
      settle: false,
    );
    final notifier = handle.container.read(onboardingDraftProvider.notifier);
    await notifier.loaded;
    await notifier.setCamera(id: 'native:asi2600', name: 'ASI2600MM Pro');
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('WHICH CAMERA GUIDES?'), findsNothing);

    await tester.tap(find.text('Built-in Multi-Star Guider'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('WHICH CAMERA GUIDES?'), findsOneWidget);
    // The imaging camera is not offered as its own guide camera, so the one
    // camera left is the answer.
    expect(find.text('ASI2600MM Pro'), findsNothing);
    final draft = handle.container.read(onboardingDraftProvider);
    expect(draft.guideCameraId, 'native:asi120');
    expect(draft.guideCameraName, 'ASI120MM Mini');

    await tester.enterText(
      find.descendant(
        of: find.byKey(guideFocalLengthFieldKey),
        matching: find.byType(TextField),
      ),
      '162',
    );
    await tester.pump();
    expect(
      handle.container.read(onboardingDraftProvider).guideFocalLengthMm,
      162,
    );
  });
}
