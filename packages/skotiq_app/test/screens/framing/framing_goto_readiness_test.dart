// Step 4 of the framing rail ("GoTo & Frame") showed a green "Ready" pill over
// a filled primary "Slew to Target" button while the mount was PARKED at
// RA 00h00m/Dec +00 and the sidebar's own coordinates card said the target was
// 5.7 deg below the horizon. Clicking it produced no dialog, no toast and not
// one new line in app.log.
//
// The readiness predicate consulted only `hasTarget && isMountConnected`, so
// these pin the two states it ignored: a parked mount (which no driver will
// GoTo from) and a target under the ground. The rail is now the Framing
// column's Telescope section; its readiness note carries the same states.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/framing/widgets/framing_actions_panel.dart';
import 'package:skotiq_app/widgets/slew_dropdown_button.dart';
import 'package:skotiq_app/widgets/tutorial_keys/framing_keys.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

class _SeededFraming extends FramingNotifier {
  _SeededFraming(super.ref, FramingState seed) {
    // ignore: invalid_use_of_protected_member
    state = seed;
  }
}

class _SeededMount extends MountStateNotifier {
  _SeededMount(super.ref, MountState seed) {
    // ignore: invalid_use_of_protected_member
    state = seed;
  }
}

class _SeededSettings extends AppSettingsNotifier {
  _SeededSettings(this._seed);
  final AppSettingsState _seed;

  @override
  Future<AppSettingsState> build() async => _seed;
}

/// A circumpolar target from a far-northern site: always well above the
/// horizon, so the horizon check cannot be what a test is measuring.
const _highTarget = FramingTarget(
  name: 'Polaris Field',
  raHours: 2.53,
  decDegrees: 89.26,
);

/// The same site sees a deep-southern target permanently below the horizon.
const _lowTarget = FramingTarget(
  name: 'Southern Field',
  raHours: 6.0,
  decDegrees: -75.0,
);

const _site = AppSettingsState(latitude: 47.6, longitude: -122.3);

MountState _mount({required bool connected, required bool parked}) =>
    MountState(
      connectionState: connected
          ? DeviceConnectionState.connected
          : DeviceConnectionState.disconnected,
      deviceId: connected ? 'mount-1' : null,
      deviceName: connected ? 'Simulated Mount' : null,
      isParked: parked,
    );

Future<void> pumpRail(
  WidgetTester tester, {
  required FramingTarget target,
  required MountState mount,
}) async {
  await pumpAppScreen(
    tester,
    const SingleChildScrollView(
      child: SizedBox(width: 500, child: FramingTelescopeSection()),
    ),
    size: const Size(700, 1200),
    settle: false,
    extraOverrides: [
      framingProvider.overrideWith(
        (ref) => _SeededFraming(ref, FramingState(target: target)),
      ),
      mountStateProvider.overrideWith((ref) => _SeededMount(ref, mount)),
      appSettingsProvider.overrideWith(() => _SeededSettings(_site)),
      framingFOVProvider.overrideWith(
        (ref) async =>
            const FramingEquipmentResult(status: EquipmentStatus.noProfile),
      ),
    ],
  );
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

bool _slewEnabled(WidgetTester tester) => tester
    .widget<SlewDropdownButton>(find.byKey(FramingTutorialKeys.slewBtn))
    .isEnabled;

/// The Telescope section's own readiness note, named by key so the assertion
/// cannot match a 'Ready' elsewhere on the column.
Finder _gotoStatus(String value) => find.descendant(
      of: find.byKey(framingGotoStatusKey),
      matching: find.text(value),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a parked mount is not "Ready" and the slew button is disabled',
      (tester) async {
    await pumpRail(
      tester,
      target: _highTarget,
      mount: _mount(connected: true, parked: true),
    );

    expect(_gotoStatus('Ready'), findsNothing,
        reason: 'a parked mount cannot GoTo; "Ready" was the lie');
    expect(_gotoStatus('Parked'), findsOneWidget);
    expect(
      find.textContaining('mount is parked'),
      findsOneWidget,
      reason: 'the step has to say what to do about it',
    );
    expect(_slewEnabled(tester), isFalse);
  });

  testWidgets('an unparked mount on a target above the horizon is Ready',
      (tester) async {
    await pumpRail(
      tester,
      target: _highTarget,
      mount: _mount(connected: true, parked: false),
    );

    expect(_gotoStatus('Ready'), findsOneWidget);
    expect(_gotoStatus('Parked'), findsNothing);
    expect(find.textContaining('below the horizon'), findsNothing);
    expect(_slewEnabled(tester), isTrue);
  });

  testWidgets('a target below the horizon is flagged, not badged Ready',
      (tester) async {
    await pumpRail(
      tester,
      target: _lowTarget,
      mount: _mount(connected: true, parked: false),
    );

    expect(_gotoStatus('Ready'), findsNothing);
    expect(_gotoStatus('Below horizon'), findsOneWidget);
    expect(find.textContaining('below the horizon'), findsOneWidget);
    // Advisory only: a target that has not risen yet is still a legitimate
    // pre-point, so the command stays available.
    expect(_slewEnabled(tester), isTrue);
  });

  testWidgets('a disconnected mount keeps reporting "No mount"',
      (tester) async {
    await pumpRail(
      tester,
      target: _highTarget,
      mount: _mount(connected: false, parked: true),
    );

    expect(_gotoStatus('No mount'), findsOneWidget);
    expect(
      _gotoStatus('Parked'),
      findsNothing,
      reason: 'isParked defaults to true on an unknown mount — do not report a '
          'park state we have never been told',
    );
    expect(_slewEnabled(tester), isFalse);
  });
}
