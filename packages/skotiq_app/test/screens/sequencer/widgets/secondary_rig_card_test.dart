import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/secondary_rig_card.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  testWidgets(
      'missing or primary camera selection is safe and cannot start the rig',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          secondaryRigConfigProvider.overrideWith(
            (ref) => _SeededSecondaryRigConfigNotifier('missing-camera'),
          ),
          cameraStateProvider.overrideWith(_PrimaryCameraNotifier.new),
          availableCamerasProvider.overrideWith(
            (ref) async => const [
              DeviceInfo(
                id: 'primary-camera',
                name: 'Primary camera',
                deviceType: DeviceType.camera,
                driverType: DriverType.simulator,
                description: '',
                driverVersion: '',
              ),
              DeviceInfo(
                id: 'secondary-camera',
                name: 'Secondary camera',
                deviceType: DeviceType.camera,
                driverType: DriverType.simulator,
                description: '',
                driverVersion: '',
              ),
            ],
          ),
          secondaryRigStatusProvider.overrideWith(
            (ref) => Stream.value(null),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: SecondaryRigCard()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      find.text('The previously selected camera is unavailable.'),
      findsOneWidget,
    );

    final dropdown = tester.widget<DropdownButton<String>>(
      find.byType(DropdownButton<String>),
    );
    expect(dropdown.value, isNull);
    expect(dropdown.items!.map((item) => item.value), ['secondary-camera']);

    final start = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Start secondary'),
    );
    expect(start.onPressed, isNull);

    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Secondary camera').last);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Start secondary'),
          )
          .onPressed,
      isNotNull,
    );

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Exposure (s)'),
      '.',
    );
    await tester.pump();
    expect(find.text('Enter a number'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Start secondary'),
          )
          .onPressed,
      isNull,
    );
  });
}

class _SeededSecondaryRigConfigNotifier extends SecondaryRigConfigNotifier {
  _SeededSecondaryRigConfigNotifier(String cameraId) {
    setCamera(cameraId);
  }
}

class _PrimaryCameraNotifier extends CameraStateNotifier {
  _PrimaryCameraNotifier(super.ref) {
    state = const CameraStateSnapshot(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'primary-camera',
      deviceName: 'Primary camera',
    );
  }
}
