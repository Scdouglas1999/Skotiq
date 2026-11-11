import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/equipment/profile_actions.dart';
import 'package:skotiq_app/screens/equipment/widgets/profiles_manager.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) {
    // ignore: invalid_use_of_protected_member
    state = backend;
  }

  void swap(SkotiqBackend backend) {
    // ignore: invalid_use_of_protected_member
    state = backend;
  }
}

class _ProfileSettingsBackendFake implements ProfileSettingsBackend {
  @override
  Future<void> loadProfile(String id) async {}

  @override
  Future<void> saveProfile(EquipmentProfile profile) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('profile import is single-flight and discards an old-host file',
      (tester) async {
    final pick = Completer<XFile?>();
    var pickerCalls = 0;

    final handle = await pumpAppScreen(
      tester,
      const ProfilesManager(),
      extraOverrides: [
        backendProvider.overrideWith(
          (ref) => _SwappableBackendNotifier(ref, DisconnectedBackend()),
        ),
        profileSettingsBackendProvider.overrideWithValue(
          _ProfileSettingsBackendFake(),
        ),
        equipmentProfileImportPickerProvider.overrideWithValue(() {
          pickerCalls++;
          return pick.future;
        }),
      ],
    );

    await tester.tap(find.byTooltip('Import profiles'));
    await tester.tap(find.byTooltip('Import profiles'));
    await tester.pump();
    expect(pickerCalls, 1);

    final backendNotifier = handle.container.read(backendProvider.notifier)
        as _SwappableBackendNotifier;
    backendNotifier.swap(DisconnectedBackend());
    await tester.pump();
    await tester.pumpAndSettle();

    // The file does not exist: reading it would surface as an import error.
    pick.complete(XFile('/old-host-profiles.json'));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('Could not import'), findsNothing);
    expect(find.byTooltip('Import profiles'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('profile import completion after disposal is ignored',
      (tester) async {
    final pick = Completer<XFile?>();
    await pumpAppScreen(
      tester,
      const ProfilesManager(),
      extraOverrides: [
        equipmentProfileImportPickerProvider
            .overrideWithValue(() => pick.future),
      ],
    );

    await tester.tap(find.byTooltip('Import profiles'));
    await tester.pump();
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));

    pick.complete(XFile('/late-profiles.json'));
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('profile import reports failures and unlocks retry',
      (tester) async {
    var pickerCalls = 0;
    await pumpAppScreen(
      tester,
      const ProfilesManager(),
      extraOverrides: [
        equipmentProfileImportPickerProvider.overrideWithValue(() async {
          pickerCalls++;
          throw StateError('picker unavailable');
        }),
      ],
    );

    await tester.tap(find.byTooltip('Import profiles'));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('picker unavailable'), findsOneWidget);

    await tester.tap(find.byTooltip('Import profiles'));
    await tester.pump();
    expect(pickerCalls, 2);
    expect(tester.takeException(), isNull);
  });

  test('duplicate and import names never collide', () {
    expect(uniqueProfileName('Rig', const ['Other']), 'Rig');
    expect(uniqueProfileName('Rig', const ['rig ', 'Rig (1)']), 'Rig (2)');
  });
}
