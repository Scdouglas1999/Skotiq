// The profile card's overflow menu must open ON its button, not adrift in the
// middle of the window.
//
// Live finding (owner, Equipment > Profiles at 1920x1080): "if you click the 3
// dots next to your profile ... the actual drop-down box appears in like the
// middle of the screen". `_showProfileContextMenu` built its `RelativeRect`
// from a GLOBAL offset, but `showMenu` measures those insets against the
// enclosing Navigator's OVERLAY. Under `AppShell` those origins differ: the
// route lives in the nested Navigator go_router's `ShellRoute` hands the shell,
// whose overlay starts below the `TitleBar` and right of the `SideNavigation`.
// The overlay origin was therefore added twice.
//
// The signature measured live: collapsing the nav rail by 156 px moved the menu
// 312 px — exactly twice, because both terms carried the rail width. So these
// tests assert the menu lands on the button AND that it stays there when the
// stand-in chrome changes size. A single-inset test would pass on a fix that
// merely subtracted one particular constant.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/equipment/widgets/profile_sidebar.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The width the Profiles tab gives the list, mirrored here so the overflow
/// button sits where it really sits — well clear of the right screen edge.
const double _listWidth = 360.0;

EquipmentProfileModel _profile({required int id, required String name}) {
  return EquipmentProfileModel(
    id: id,
    name: name,
    cameraId: 'sim_camera_1',
    cameraName: 'Simulated Camera',
  );
}

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

/// Mounts the sidebar the way `AppShell` mounts a routed screen: inside a
/// NESTED [Navigator] that is inset from the window by [chromeInset] on the
/// left (the side rail) and the top (the title bar). That inset is the whole
/// point — with the sidebar mounted at the window origin, the buggy and the
/// fixed code produce identical output.
Future<void> _pumpShellHostedSidebar(
  WidgetTester tester, {
  required List<EquipmentProfileModel> profiles,
  required double chromeInset,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1400, 1000);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sortedProfilesProvider.overrideWithValue(profiles),
        activeEquipmentProfileProvider.overrideWithValue(profiles.first),
        profileConnectionStatusProvider
            .overrideWith((ref, profile) => _emptyStatus(profile)),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: Column(
            children: [
              SizedBox(height: chromeInset),
              Expanded(
                child: Row(
                  children: [
                    SizedBox(width: chromeInset),
                    Expanded(
                      child: Navigator(
                        onGenerateRoute: (settings) => MaterialPageRoute<void>(
                          // Align: the route hands its child TIGHT
                          // constraints, so a bare SizedBox would be widened
                          // to the whole window and put the overflow button
                          // against the right edge — where the menu is clamped
                          // back on screen and the misplacement is hidden.
                          // The tab gives the list 360 px; so does this.
                          builder: (_) => Align(
                            alignment: Alignment.topLeft,
                            child: SizedBox(
                              width: _listWidth,
                              child: ProfileSidebar(
                                selectedProfileId: profiles.first.id,
                                onProfileSelected: (_) {},
                                onCreateProfile: () {},
                                onEditProfile: (_) {},
                                onConnectAll: (_) {},
                                onDisconnectAll: () {},
                                onSetDefault: (_) {},
                                onActivateProfile: (_) {},
                                onDuplicateProfile: (_) {},
                                onDeleteProfile: (_) {},
                                onReorderProfiles: (_, __) {},
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Taps the overflow button and waits for the menu.
///
/// The plain `pumpAndSettle` is not enough: the profile card carries an
/// `onDoubleTap`, and that recognizer HOLDS the gesture arena for its 300 ms
/// window, which `pumpAndSettle` does not advance.
Future<void> _tapMenuButton(WidgetTester tester, Finder button) async {
  await tester.tap(button);
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

/// Global rect of the menu `showMenu` put on screen, as the union of its items.
///
/// Measured from the items rather than from a `find.text`: "Edit profile" is
/// also the label of the sidebar's own footer button, and rather than from an
/// ancestor `Material`, of which the popup route has several.
Rect _openMenuRect(WidgetTester tester) {
  final items = find.byType(PopupMenuItem<String>);
  expect(items, findsWidgets, reason: 'the profile menu should be open');
  return items.evaluate().map((element) {
    final box = element.findRenderObject()! as RenderBox;
    return box.localToGlobal(Offset.zero) & box.size;
  }).reduce((a, b) => a.expandToInclude(b));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final rigA = _profile(id: 1, name: 'Refractor Rig');
  final rigB = _profile(id: 2, name: 'Newtonian Rig');

  /// How far the menu may sit from the button that opened it. A popup is
  /// allowed to be nudged to stay on screen, so this is not zero — but the
  /// defect put it ~230 px away horizontally, far outside any nudge.
  const double tolerance = 24.0;

  for (final inset in <double>[0, 64, 220]) {
    testWidgets(
      'profile menu opens on its button when the shell insets the overlay by '
      '$inset px',
      (tester) async {
        await _pumpShellHostedSidebar(
          tester,
          profiles: [rigA, rigB],
          chromeInset: inset,
        );

        final button = find.byKey(profileCardMenuButtonKey(rigA.id));
        expect(button, findsOneWidget);
        final buttonRect = tester.getRect(button);

        await _tapMenuButton(tester, button);

        final menuRect = _openMenuRect(tester);

        // Horizontally the menu must line up with the button, not sit a
        // rail-width to its right. This is the assertion the defect failed:
        // at inset 220 the menu's left edge was ~220 px right of here.
        expect(
          (menuRect.left - buttonRect.left).abs() <= tolerance ||
              (menuRect.right - buttonRect.right).abs() <= tolerance,
          isTrue,
          reason: 'menu $menuRect should share an edge with button '
              '$buttonRect; it is ${menuRect.left - buttonRect.left} px off',
        );

        // Vertically it must hang off the button, not a title-bar height below
        // it. `PopupMenuPosition.over` lets the menu overlap its button, so the
        // test bounds the gap rather than demanding it start below.
        expect(
          menuRect.top,
          closeTo(buttonRect.top, buttonRect.height + tolerance),
          reason: 'menu $menuRect should be anchored vertically on button '
              '$buttonRect',
        );
      },
    );
  }

  testWidgets('the menu anchor does not move with the shell chrome',
      (tester) async {
    // The live signature of the defect: the menu moved TWICE as far as the
    // widget that opened it when the nav rail changed width. Measured as the
    // button-to-menu offset, a correct anchor keeps that offset constant.
    final offsets = <double>[];
    for (final inset in <double>[0, 220]) {
      await _pumpShellHostedSidebar(
        tester,
        profiles: [rigA, rigB],
        chromeInset: inset,
      );
      final button = find.byKey(profileCardMenuButtonKey(rigA.id));
      final buttonLeft = tester.getRect(button).left;
      await _tapMenuButton(tester, button);
      offsets.add(_openMenuRect(tester).left - buttonLeft);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
    }

    expect(
      offsets.first,
      closeTo(offsets.last, 1.0),
      reason: 'button-to-menu offset must not track the shell inset; '
          'got $offsets',
    );
  });

  testWidgets('right-clicking a profile card opens the menu at the cursor',
      (tester) async {
    await _pumpShellHostedSidebar(
      tester,
      profiles: [rigA, rigB],
      chromeInset: 220,
    );

    final card = find.text(rigB.name);
    final cursor = tester.getCenter(card);
    await tester.tapAt(cursor, buttons: kSecondaryButton);
    await tester.pumpAndSettle();

    final menuRect = _openMenuRect(tester);
    expect(
      (menuRect.left - cursor.dx).abs(),
      lessThanOrEqualTo(tolerance),
      reason: 'a context menu belongs under the cursor; menu $menuRect '
          'against cursor $cursor',
    );
  });
}
