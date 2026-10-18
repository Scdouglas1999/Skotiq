// The Pier readout in Imaging → Mount says the side of pier the mount reports,
// and is absent — not a dash — when the mount does not report one. A tracking
// mount used to show "Pier —" because the poll never copied the reported side
// into the mount state at all.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/tabs/mount_tab.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../../harness/harness.dart';

class _TrackingMountNotifier extends MountStateNotifier {
  _TrackingMountNotifier(super.ref, String? sideOfPier) {
    // ignore: invalid_use_of_protected_member
    state = MountState(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'simulator:mount:0',
      deviceName: 'Simulated Mount',
      isParked: false,
      isTracking: true,
      sideOfPier: sideOfPier,
    );
  }
}

Future<void> _pump(WidgetTester tester, String? sideOfPier) async {
  await pumpAppScreen(
    tester,
    const MountTab(),
    settle: false,
    extraOverrides: <Override>[
      mountStateProvider
          .overrideWith((ref) => _TrackingMountNotifier(ref, sideOfPier)),
    ],
  );
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('a reported side of pier is shown', (tester) async {
    await _pump(tester, 'West');

    expect(find.text('PIER'), findsOneWidget);
    expect(find.text('West'), findsOneWidget);
  });

  testWidgets('an unreported side of pier leaves no dash behind',
      (tester) async {
    await _pump(tester, null);

    expect(find.text('PIER'), findsNothing);
    // The status readout beside it still renders.
    expect(find.text('STATUS'), findsOneWidget);
    expect(find.text('Ready'), findsOneWidget);
  });
}
