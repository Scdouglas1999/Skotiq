// Imaging › Mount offers Home beside Park. It is enabled only for an
// unparked mount whose driver has a home position, says why when it is not,
// and a home in progress reads the way a slew does.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/imaging/tabs/mount_tab.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../harness/harness.dart';

const _mountId = 'simulator:mount:0';

class _MountNotifier extends MountStateNotifier {
  _MountNotifier(super.ref, MountState initial) {
    // ignore: invalid_use_of_protected_member
    state = initial;
  }
}

const _connected = MountState(
  connectionState: DeviceConnectionState.connected,
  deviceId: _mountId,
  deviceName: 'Simulated Mount',
  isParked: false,
  isTracking: true,
);

Future<void> _pump(
  WidgetTester tester, {
  MountState state = _connected,
  bool canFindHome = true,
}) async {
  final backend = mockBackend();
  when(() => backend.getMountCapabilities(_mountId)).thenAnswer(
    (_) async => MountCapabilities(
      canFindHome: canFindHome,
      canPark: true,
      canUnpark: true,
      canSetTracking: true,
      canAbortSlew: true,
    ),
  );
  await pumpAppScreen(
    tester,
    const MountTab(),
    backend: backend,
    settle: false,
    extraOverrides: <Override>[
      mountStateProvider.overrideWith((ref) => _MountNotifier(ref, state)),
    ],
  );
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 25));
  }
}

Finder get _home => find.widgetWithText(SkotiqButton, 'Home');

String _homeTooltip(WidgetTester tester) => tester
    .widget<SkotiqTooltip>(
      find.ancestor(of: _home, matching: find.byType(SkotiqTooltip)),
    )
    .message;

void main() {
  testWidgets('Home is enabled for an unparked mount that can home', (
    tester,
  ) async {
    await _pump(tester);

    expect(tester.widget<SkotiqButton>(_home).onPressed, isNotNull);
    expect(_homeTooltip(tester), contains('stays unparked'));
    expect(
      tester.widget<SkotiqButton>(_home).variant,
      ButtonVariant.secondary,
      reason: 'Home is not a primary action',
    );
  });

  testWidgets('Home sits next to Park, after the stop actions', (
    tester,
  ) async {
    await _pump(tester);

    final park = tester.getTopLeft(find.widgetWithText(SkotiqButton, 'Park'));
    final home = tester.getTopLeft(_home);
    final abort = tester.getTopLeft(
      find.widgetWithText(SkotiqButton, 'Abort slew'),
    );
    expect(home.dy, park.dy);
    expect(home.dx, greaterThan(park.dx));
    expect(park.dy, greaterThan(abort.dy));
  });

  testWidgets('Home is disabled with a reason on a parked mount', (
    tester,
  ) async {
    await _pump(tester, state: _connected.copyWith(isParked: true));

    expect(tester.widget<SkotiqButton>(_home).onPressed, isNull);
    expect(_homeTooltip(tester), 'Unpark the mount before sending it home.');
    expect(
      tester.widget<SkotiqButton>(_home).semanticsHint,
      'Unpark the mount before sending it home.',
    );
  });

  testWidgets('Home is disabled with a reason when the mount cannot home', (
    tester,
  ) async {
    await _pump(tester, canFindHome: false);

    expect(tester.widget<SkotiqButton>(_home).onPressed, isNull);
    expect(_homeTooltip(tester), 'This mount does not have a home position.');
  });

  testWidgets('a home in progress shows as Homing and keeps Abort slew live', (
    tester,
  ) async {
    await _pump(tester, state: _connected.copyWith(isHoming: true));

    expect(find.text('Homing'), findsOneWidget);
    expect(tester.widget<SkotiqButton>(_home).onPressed, isNull);
    expect(
      tester
          .widget<SkotiqButton>(find.widgetWithText(SkotiqButton, 'Park'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<SkotiqButton>(find.widgetWithText(SkotiqButton, 'Abort slew'))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets(
      'the status readout tells a confirmed home from an unconfirmed '
      'one', (tester) async {
    await _pump(
      tester,
      state: _connected.copyWith(isTracking: false, isAtHome: true),
    );
    expect(find.text('At home'), findsOneWidget);

    await _pump(
      tester,
      state: _connected.copyWith(isTracking: false, homeUnconfirmed: true),
    );
    expect(find.text('Home (unconfirmed)'), findsOneWidget);
  });
}
