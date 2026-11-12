// The Equipment header's one primary action follows the rig: "Connect all"
// while a profile device is down, nothing primary once the rig is up, and no
// header actions at all on the tabs they do not act on.
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/equipment/equipment_screen.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

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

Finder _headerButton(String label) => find.descendant(
      of: find.byType(PageHeader),
      matching: find.widgetWithText(SkotiqButton, label),
    );

ButtonVariant _variant(WidgetTester tester, String label) =>
    tester.widget<SkotiqButton>(_headerButton(label)).variant;

Future<HarnessHandle> _pumpWithProfile(WidgetTester tester) async {
  final handle = await pumpAppScreen(
    tester,
    const EquipmentScreen(),
    size: const Size(1280, 800),
    settle: false,
    extraOverrides: [_noContactPoll],
  );
  await handle.container.read(equipmentProfilesDaoProvider).createProfile(
        EquipmentProfilesCompanion.insert(
          name: 'Header Rig',
          cameraId: const Value('sim_camera_1'),
          isActive: const Value(true),
        ),
      );
  await _drainFrames(tester);
  return handle;
}

void main() {
  testWidgets('a profile device that is down makes Connect all the primary',
      (tester) async {
    await _pumpWithProfile(tester);

    expect(_headerButton('Connect all'), findsOneWidget);
    expect(_variant(tester, 'Connect all'), ButtonVariant.primary);
    expect(_variant(tester, 'Scan for devices'), ButtonVariant.secondary);

  });

  testWidgets('with the profile up, no header action is primary',
      (tester) async {
    final handle = await _pumpWithProfile(tester);
    handle.container.read(cameraStateProvider.notifier)
      ..setConnecting('sim_camera_1', 'Simulated Camera')
      ..setConnected();
    await _drainFrames(tester);

    expect(_headerButton('Connect all'), findsNothing);
    expect(_variant(tester, 'Disconnect all'), ButtonVariant.secondary);
    expect(_variant(tester, 'Scan for devices'), ButtonVariant.secondary);

  });

  testWidgets('the Profiles tab has no header actions', (tester) async {
    await _pumpWithProfile(tester);

    await tester.tap(find.text('Profiles'));
    await _drainFrames(tester);

    expect(_headerButton('Scan for devices'), findsNothing);
    expect(_headerButton('Connect all'), findsNothing);

  });
}
