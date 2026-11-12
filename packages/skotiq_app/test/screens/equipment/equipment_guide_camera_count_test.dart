// The built-in guider's guide camera is counted with the guider: the connect
// sweep scores devices the way the cards show them, and the guider's card
// names its guide camera.
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/equipment/equipment_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

Future<void> _drainFrames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

final _noContactPoll = deviceLastContactProvider.overrideWith(
  (ref) => DeviceLastContactNotifier(
    probe: (_) async => (0, false),
    autoStart: false,
  ),
);

DeviceConnectProgress _ok(String label) => DeviceConnectProgress(
      deviceType: label,
      deviceId: 'id-$label',
      status: DeviceConnectProgressStatus.connected,
    );

void main() {
  testWidgets('the sweep counts the guide camera with the guider, whose card '
      'names it', (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const EquipmentScreen(),
      // Wide tiles: the cards' telemetry rows overflow a 390 px tile in the
      // test font.
      size: const Size(2600, 900),
      settle: false,
      extraOverrides: [_noContactPoll],
    );
    await handle.container.read(equipmentProfilesDaoProvider).createProfile(
          EquipmentProfilesCompanion.insert(
            name: 'Guided Rig',
            cameraId: const Value('sim_camera_1'),
            guiderId: const Value(builtinGuiderDeviceId),
            guideCameraId: const Value('sim_camera_2'),
            guideCameraName: const Value('Simulated Guide Camera'),
            isActive: const Value(true),
          ),
        );
    handle.container.read(cameraStateProvider.notifier)
      ..setConnecting('sim_camera_1', 'Simulated Camera')
      ..setConnected();
    handle.container.read(guiderStateProvider.notifier)
      ..setConnecting(builtinGuiderDeviceId, 'Built-in Multi-Star Guider')
      ..setConnected();
    final sweep = handle.container.read(
      deviceConnectionProgressProvider.notifier,
    );
    sweep.startSweep(source: 'Connect All');
    for (final label in ['camera', guideCameraLabel, 'guider']) {
      sweep.record(_ok(label));
    }
    sweep.endSweep();
    await _drainFrames(tester);

    expect(find.textContaining('2 of 2 succeeded'), findsOneWidget);
    expect(find.textContaining('guide camera ·'), findsNothing);
    expect(find.text('2 connected'), findsOneWidget);
    expect(
      find.text('Guide camera: Simulated Guide Camera'),
      findsOneWidget,
    );
  });
}
