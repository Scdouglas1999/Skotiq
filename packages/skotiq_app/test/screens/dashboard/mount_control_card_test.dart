import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/dashboard/widgets/mount_control_card.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

const _mountId = 'simulator:mount:0';

class _ConnectedMountNotifier extends MountStateNotifier {
  _ConnectedMountNotifier(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const MountState(
      connectionState: DeviceConnectionState.connected,
      deviceId: _mountId,
      deviceName: 'Simulated Mount',
      isParked: false,
      isTracking: true,
      trackingRate: TrackingRate.sidereal,
      canSetTrackingRate: true,
    );
  }
}

Future<void> _pump(
  WidgetTester tester,
  Future<MountCapabilities?> Function(Ref ref) capabilities,
) async {
  await pumpAppScreen(
    tester,
    const SizedBox(
      width: 420,
      child: MountControlCard(colors: SkotiqColors.dark),
    ),
    extraOverrides: [
      mountStateProvider.overrideWith(_ConnectedMountNotifier.new),
      mountCapabilitiesProvider(_mountId).overrideWith(capabilities),
    ],
    settle: false,
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('unknown capabilities do not advertise fabricated tracking rates',
      (tester) async {
    await _pump(tester, (_) async => null);

    final dropdown = tester.widget<DropdownButton<TrackingRate>>(
      find.byType(DropdownButton<TrackingRate>),
    );
    expect(dropdown.onChanged, isNull);
    expect(
      dropdown.items!.map((item) => item.value),
      [TrackingRate.sidereal],
    );
  });

  testWidgets('only driver-advertised tracking rates are selectable',
      (tester) async {
    await _pump(
      tester,
      (_) async => const MountCapabilities(
        canSetTrackingRate: true,
        supportedTrackingRates: [
          TrackingRate.sidereal,
          TrackingRate.lunar,
        ],
      ),
    );

    final dropdown = tester.widget<DropdownButton<TrackingRate>>(
      find.byType(DropdownButton<TrackingRate>),
    );
    expect(dropdown.onChanged, isNotNull);
    expect(
      dropdown.items!.map((item) => item.value),
      [TrackingRate.sidereal, TrackingRate.lunar],
    );
  });
}
