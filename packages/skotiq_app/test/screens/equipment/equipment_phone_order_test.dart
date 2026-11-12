// At phone width the devices come first: the profile above them, readiness
// and health below them, and the header's actions (which a phone header has
// no room for) in the profile's menu.
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/equipment/equipment_screen.dart';
import 'package:skotiq_app/screens/equipment/widgets/connected_device_card.dart';
import 'package:skotiq_app/screens/equipment/widgets/equipment_readiness_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

Future<void> _drainFrames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// The last-contact poll a connected device starts would outlive the test.
final _noContactPoll = deviceLastContactProvider.overrideWith(
  (ref) => DeviceLastContactNotifier(
    probe: (_) async => (0, false),
    autoStart: false,
  ),
);

Future<void> _pumpPhoneWithCamera(WidgetTester tester) async {
  final handle = await pumpAppScreen(
    tester,
    const EquipmentScreen(),
    size: const Size(390, 844),
    settle: false,
    extraOverrides: [_noContactPoll],
  );
  await handle.container.read(equipmentProfilesDaoProvider).createProfile(
        EquipmentProfilesCompanion.insert(
          name: 'Phone Rig',
          cameraId: const Value('sim_camera_1'),
          mountId: const Value('sim_mount_1'),
          isActive: const Value(true),
        ),
      );
  handle.container.read(cameraStateProvider.notifier)
    ..setConnecting('sim_camera_1', 'Simulated Camera')
    ..setConnected();
  await _drainFrames(tester);
}

void main() {
  testWidgets('the device cards come before readiness on a phone',
      (tester) async {
    await _pumpPhoneWithCamera(tester);

    final card = tester.getTopLeft(find.byType(ConnectedDeviceCard).first);
    final readiness = tester.getTopLeft(find.byType(EquipmentReadinessPanel));
    expect(card.dy, lessThan(readiness.dy));
    expect(tester.getTopLeft(find.text('Phone Rig')).dy, lessThan(card.dy));

  });

  testWidgets("the profile's menu carries Connect all, Disconnect all and Scan",
      (tester) async {
    await _pumpPhoneWithCamera(tester);

    await tester.tap(find.byTooltip('Profile actions'));
    await _drainFrames(tester);

    expect(find.text('Connect all'), findsOneWidget);
    expect(find.text('Disconnect all'), findsOneWidget);
    expect(find.text('Scan for devices'), findsOneWidget);

  });
}
