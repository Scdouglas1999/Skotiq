// On the demo rig the phone's guider is simulated in the app and has no
// settings anywhere, so its Settings tab says that instead of sending the
// user to Equipment for an external guider.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/guiding/guiding_screen.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../../harness/harness.dart';

class _DemoGuiderConnected extends GuiderStateNotifier {
  _DemoGuiderConnected(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const GuiderState(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'sim_guider_1',
      deviceName: 'Demo Guider',
    );
  }
}

void main() {
  testWidgets('the demo guider has no settings to send the user to', (
    tester,
  ) async {
    final demo = DemoBackend(latitudeDeg: 40, longitudeDeg: -105);
    addTearDown(demo.dispose);
    await pumpAppScreen(
      tester,
      const GuidingScreen(),
      size: const Size(360, 780),
      settle: false,
      extraOverrides: [
        backendProvider.overrideWith((ref) => TestBackendNotifier(ref, demo)),
        guiderStateProvider.overrideWith(_DemoGuiderConnected.new),
        phd2StateProvider.overrideWith((ref) => Phd2State.stopped),
      ],
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.bySemanticsLabel(RegExp('^Settings')).last);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.text('Demo guider'), findsOneWidget);
    expect(find.text('Open guider settings'), findsNothing);
    expect(find.text('External guider'), findsNothing);
  });
}
