// The Equipment screen's profile sidebar must be able to switch which profile
// the app is using, and must advertise its per-profile menu.
//
// Live finding: clicking a non-active profile only highlighted the row — the
// header, connected devices and status bar stayed on the previous profile —
// and the footer collapsed to "Edit profile". The only route to a different
// active rig was right-click → "Set as Default", which ALSO rewrote which
// profile launches at startup, so switching scopes for one night silently
// changed every night after it. The menu itself was right-click-only with no
// affordance on the card saying it existed.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/equipment/widgets/profile_sidebar.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

EquipmentProfileModel _profile({
  required int id,
  required String name,
  bool isDefault = false,
}) {
  return EquipmentProfileModel(
    id: id,
    name: name,
    cameraId: 'sim_camera_1',
    cameraName: 'Simulated Camera',
    isDefault: isDefault,
  );
}

/// Every slot present and unassigned — the sidebar reads all six core slots,
/// and `ProfileConnectionStatus[slot]` throws on a missing entry.
ProfileConnectionStatus _emptyStatus(EquipmentProfileModel profile) {
  return ProfileConnectionStatus(
    profileId: profile.id,
    connections: [
      for (final slot in ProfileDeviceSlot.values)
        ProfileDeviceConnection(
          slot: slot,
          profileId: null,
          connectedId: null,
          connectedState: DeviceConnectionState.disconnected,
        ),
    ],
  );
}

Future<List<EquipmentProfileModel>> _pumpSidebar(
  WidgetTester tester, {
  required List<EquipmentProfileModel> profiles,
  required int selectedProfileId,
  required int activeProfileId,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(900, 1000);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final activated = <EquipmentProfileModel>[];

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sortedProfilesProvider.overrideWithValue(profiles),
        activeEquipmentProfileProvider.overrideWithValue(
          profiles.firstWhere((p) => p.id == activeProfileId),
        ),
        profileConnectionStatusProvider
            .overrideWith((ref, profile) => _emptyStatus(profile)),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: SizedBox(
            width: 280,
            child: ProfileSidebar(
              selectedProfileId: selectedProfileId,
              onProfileSelected: (_) {},
              onCreateProfile: () {},
              onEditProfile: (_) {},
              onConnectAll: (_) {},
              onDisconnectAll: () {},
              onSetDefault: (_) {},
              onActivateProfile: activated.add,
              onDuplicateProfile: (_) {},
              onDeleteProfile: (_) {},
              onReorderProfiles: (_, __) {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return activated;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final rigA = _profile(id: 1, name: 'Refractor Rig', isDefault: true);
  final rigB = _profile(id: 2, name: 'Newtonian Rig');

  testWidgets('selecting a profile that is not in use offers a way to use it',
      (tester) async {
    final activated = await _pumpSidebar(
      tester,
      profiles: [rigA, rigB],
      selectedProfileId: 2,
      activeProfileId: 1,
    );

    final activateButton = find.byKey(profileSidebarActivateButtonKey);
    expect(activateButton, findsOneWidget,
        reason: 'a selected, not-in-use profile must be switchable to');

    await tester.tap(activateButton);
    await tester.pumpAndSettle();

    expect(activated.map((p) => p.id).toList(), [2]);
  });

  testWidgets('the profile already in use offers no redundant switch',
      (tester) async {
    await _pumpSidebar(
      tester,
      profiles: [rigA, rigB],
      selectedProfileId: 1,
      activeProfileId: 1,
    );

    expect(find.byKey(profileSidebarActivateButtonKey), findsNothing);
  });

  testWidgets('the in-use profile is distinguishable from the selected one',
      (tester) async {
    await _pumpSidebar(
      tester,
      profiles: [rigA, rigB],
      selectedProfileId: 2,
      activeProfileId: 1,
    );

    // Exactly one card carries the in-use marker, and it is not the selected
    // one — the whole point of the finding.
    expect(find.text('In use'), findsOneWidget);
  });

  testWidgets('every profile card advertises its menu without a right-click',
      (tester) async {
    await _pumpSidebar(
      tester,
      profiles: [rigA, rigB],
      selectedProfileId: 2,
      activeProfileId: 1,
    );

    expect(find.byKey(profileCardMenuButtonKey(1)), findsOneWidget);
    expect(find.byKey(profileCardMenuButtonKey(2)), findsOneWidget);

    await tester.tap(find.byKey(profileCardMenuButtonKey(2)));
    // The card carries an onDoubleTap, whose recognizer HOLDS the gesture
    // arena for its 300 ms window; pumpAndSettle alone does not advance a bare
    // Timer, so the tap would never be delivered.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    // The menu keeps "use this profile" and "start up with this profile"
    // separate: the star must not move just because tonight's rig changed.
    // Two: the footer button on the selected row, and the menu item.
    expect(find.text('Use this profile'), findsNWidgets(2));
    expect(find.text('Start up with this profile'), findsOneWidget);
    expect(find.text('Duplicate'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
  });
}
