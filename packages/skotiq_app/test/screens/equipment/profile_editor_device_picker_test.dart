// In the profile editor each device row leads with a wide device picker that
// offers the device connected now and the devices saved profiles assign, and
// names the chosen device; the display name is the secondary field.
import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/equipment/dialogs/profile_editor_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

Future<ProviderContainer> _pumpNewProfile(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1024, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  final container = ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
  addTearDown(container.dispose);
  await container.read(equipmentProfilesDaoProvider).createProfile(
        EquipmentProfilesCompanion.insert(
          name: 'Sim Rig',
          focuserId: const Value('sim_focuser_1'),
          focuserName: const Value('Simulated Focuser'),
        ),
      );
  container.read(cameraStateProvider.notifier)
    ..setConnecting('sim_camera_1', 'Simulated Camera')
    ..setConnected();

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(body: ProfileEditorDialog()),
      ),
    ),
  );
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  return container;
}

void main() {
  testWidgets('the picker offers the connected camera and names it once chosen',
      (tester) async {
    await _pumpNewProfile(tester);

    final picker = find.bySemanticsLabel('Camera: choose a device');
    expect(picker, findsOneWidget);
    await tester.ensureVisible(picker);
    await tester.tap(picker);
    await tester.pumpAndSettle();
    expect(find.text('Connected now'), findsOneWidget);

    await tester.tap(find.text('Simulated Camera').last);
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('Camera: Simulated Camera'), findsOneWidget);
  });

  testWidgets('the picker offers a device a saved profile assigns',
      (tester) async {
    await _pumpNewProfile(tester);

    final picker = find.bySemanticsLabel('Focuser: choose a device');
    await tester.ensureVisible(picker);
    await tester.tap(picker);
    await tester.pumpAndSettle();

    expect(find.text('Simulated Focuser'), findsOneWidget);
    expect(find.text('In Sim Rig'), findsOneWidget);
  });

  testWidgets('the device picker is the wide control, the name the narrow one',
      (tester) async {
    await _pumpNewProfile(tester);

    final picker = tester.getSize(
      find.bySemanticsLabel('Camera: choose a device'),
    );
    final name = tester.getSize(
      find.bySemanticsLabel(RegExp('^Camera display name')),
    );
    expect(picker.width, greaterThan(name.width));
  });
}
