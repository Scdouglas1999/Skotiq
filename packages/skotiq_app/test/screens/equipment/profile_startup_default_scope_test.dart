// "Make Startup Default" must change only what launches at startup.
//
// The sidebar fix that gave the Equipment screen a real "Use this profile"
// action also relabelled the star from "Set as Default" to "Make Startup
// Default" — but the handler behind it still called
// setDefaultProfile(makeActive: true), which routes through
// activateProfileStrictTransactional and switches the rig you are imaging
// with right now (re-pushing its devices to the Rust executor mid-session).
// So the relabel swapped one inaccurate label for another. Settings >
// Equipment Profiles has always passed makeActive: false for the same action
// (screen_shell.dart), which is what made the two surfaces disagree.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/equipment/equipment_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/models/equipment_profile.dart'
    as remote_profile;

import '../../harness/harness.dart';
import '../../harness/provider_teardown.dart';

/// Local activation write-throughs to the native executor store; with no real
/// backend that throws, so stand in a no-op writer. This keeps the write path
/// succeeding, so the test goes red on the behaviour under test (the active rig
/// moved) rather than on an incidental failure.
class _NoopProfileSettingsBackend implements ProfileSettingsBackend {
  @override
  Future<void> loadProfile(String id) async {}

  @override
  Future<void> saveProfile(remote_profile.EquipmentProfile profile) async {}

  // Only loadProfile/saveProfile are on the activation path; anything else
  // reaching this fake is a signal the test drifted, so let it throw.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'starring a profile you are not using does not switch the active rig',
      (tester) async {
    final db = mockDatabase();
    addTearDown(db.close);
    final dao = db.equipmentProfilesDao;

    // createProfile auto-activates the FIRST row, so A is the rig in use.
    final rigA = await dao.createProfile(
      EquipmentProfilesCompanion.insert(name: 'Refractor Rig'),
    );
    final rigB = await dao.createProfile(
      EquipmentProfilesCompanion.insert(name: 'Newtonian Rig'),
    );
    await dao.setDefaultProfile(rigA, makeActive: true);
    expect((await dao.getActiveProfile())?.id, rigA);

    await pumpAppScreen(
      tester,
      const EquipmentScreen(),
      database: db,
      settle: false,
      extraOverrides: [
        profileSettingsBackendProvider.overrideWithValue(
          _NoopProfileSettingsBackend(),
        ),
        selectedEquipmentProfileIdProvider.overrideWith((ref) => rigB),
        // The profile list is the Profiles tab now (06 Equipment).
        equipmentTabIndexProvider.overrideWith((ref) => 1),
      ],
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // Open the per-profile menu on the rig that is NOT in use and star it.
    await tester.longPress(find.text('Newtonian Rig').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start up with this profile').last);
    await tester.pumpAndSettle();

    expect(
      (await dao.getDefaultProfile())?.id,
      rigB,
      reason: 'the star must move the startup default',
    );
    expect(
      (await dao.getActiveProfile())?.id,
      rigA,
      reason: 'the star must NOT switch the rig currently in use',
    );

    await settleProviderTeardown(tester);
  });
}
