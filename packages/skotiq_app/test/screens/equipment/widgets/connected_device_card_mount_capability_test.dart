import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'device_action_finder.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/equipment/widgets/connected_device_card.dart';
import 'package:skotiq_app/screens/equipment/widgets/device_tile_width.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../../harness/harness.dart';

class _MountNotifier extends MountStateNotifier {
  _MountNotifier(super.ref, this.initial) {
    state = initial;
  }

  final MountState initial;
}

Future<HarnessHandle> pumpMount(
  WidgetTester tester, {
  required MountState state,
  required MountCapabilities capabilities,
  SequenceExecutionState execution = SequenceExecutionState.idle,
  double tileWidth = DeviceTileWidth.fallbackWidth,
}) {
  final backend = mockBackend();
  when(() => backend.getMountCapabilities('mount-1'))
      .thenAnswer((_) async => capabilities);
  return pumpAppScreen(
    tester,
    DeviceTileWidth(
      width: tileWidth,
      child: const ConnectedDeviceCard(type: ConnectedDeviceType.mount),
    ),
    backend: backend,
    extraOverrides: [
      mountStateProvider.overrideWith((ref) => _MountNotifier(ref, state)),
      sequenceExecutionStateProvider.overrideWith((ref) => execution),
    ],
  );
}

void main() {
  const connected = MountState(
    connectionState: DeviceConnectionState.connected,
    deviceId: 'mount-1',
    isTracking: true,
    isParked: false,
    ra: 7.5,
    dec: -20,
  );

  testWidgets('mount actions are disabled when capabilities are unsupported',
      (tester) async {
    await pumpMount(
      tester,
      state: connected,
      capabilities: const MountCapabilities(),
    );

    for (final label in ['Park', 'Stop Tracking', 'Home', 'Flip']) {
      await expectDeviceAction(tester, label, enabled: false, reason: label);
    }
  });

  testWidgets('supported mount actions are enabled when the rig is settled',
      (tester) async {
    await pumpMount(
      tester,
      state: connected,
      capabilities: const MountCapabilities(
        canPark: true,
        canSetTracking: true,
        canFindHome: true,
        canSlew: true,
        canGetSideOfPier: true,
        isEquatorial: true,
      ),
    );

    for (final label in ['Park', 'Stop Tracking', 'Home', 'Flip']) {
      await expectDeviceAction(tester, label, enabled: true, reason: label);
    }
  });

  testWidgets('manual Flip is disabled while a sequence owns the mount',
      (tester) async {
    await pumpMount(
      tester,
      state: connected,
      execution: SequenceExecutionState.running,
      capabilities: const MountCapabilities(
        canSlew: true,
        canGetSideOfPier: true,
        isEquatorial: true,
      ),
    );

    await expectDeviceAction(tester, 'Flip', enabled: false);
  });

  testWidgets('parked mount requires explicit unpark capability',
      (tester) async {
    await pumpMount(
      tester,
      state: connected.copyWith(isParked: true),
      capabilities: const MountCapabilities(canPark: true, canUnpark: false),
    );
    await expectDeviceAction(tester, 'Unpark', enabled: false);

    await pumpMount(
      tester,
      state: connected.copyWith(isParked: true),
      capabilities: const MountCapabilities(canPark: true, canUnpark: true),
    );
    await expectDeviceAction(tester, 'Unpark', enabled: true);
  });

  const homeCapable = MountCapabilities(
    canPark: true,
    canUnpark: true,
    canSetTracking: true,
    canFindHome: true,
  );

  testWidgets('Home sits next to Park', (tester) async {
    await pumpMount(tester, state: connected, capabilities: homeCapable);

    final park = find.widgetWithText(SkotiqButton, 'Park');
    final home = find.widgetWithText(SkotiqButton, 'Home');
    expect(park, findsOneWidget, reason: 'Park is the first inline action');
    expect(home, findsOneWidget, reason: 'Home is inline beside Park');
    expect(tester.getTopLeft(home).dy, tester.getTopLeft(park).dy);
    expect(tester.getTopLeft(home).dx, greaterThan(tester.getTopLeft(park).dx));
  });

  testWidgets('Home is disabled with the reason on a parked mount',
      (tester) async {
    await pumpMount(
      tester,
      state: connected.copyWith(isParked: true),
      capabilities: homeCapable,
      // A grid cell wide enough that "Unpark" and "Home" both stay inline,
      // so the reason is on the button rather than behind the menu.
      tileWidth: 420,
    );

    await expectDeviceAction(tester, 'Home', enabled: false);
    final tooltip = tester.widget<SkotiqTooltip>(
      find.ancestor(
        of: find.widgetWithText(SkotiqButton, 'Home'),
        matching: find.byType(SkotiqTooltip),
      ),
    );
    expect(tooltip.message, 'Unpark the mount before sending it home.');
  });

  testWidgets('Home is disabled with the reason when the mount cannot home',
      (tester) async {
    await pumpMount(
      tester,
      state: connected,
      capabilities: const MountCapabilities(canPark: true),
    );

    await expectDeviceAction(tester, 'Home', enabled: false);
    final tooltip = tester.widget<SkotiqTooltip>(
      find.ancestor(
        of: find.widgetWithText(SkotiqButton, 'Home'),
        matching: find.byType(SkotiqTooltip),
      ),
    );
    expect(tooltip.message, 'This mount does not have a home position.');
  });

  testWidgets('Park and Home are disabled while a home is in progress',
      (tester) async {
    await pumpMount(
      tester,
      state: connected.copyWith(isHoming: true),
      capabilities: homeCapable,
    );

    await expectDeviceAction(tester, 'Park', enabled: false);
    await expectDeviceAction(tester, 'Home', enabled: false);
  });
}
