// The Equipment guider card names the guider's state as Tonight does. On the
// rig it read "Idle" while PHD2 looped and Tonight said "Looping".
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/equipment/widgets/connected_device_card.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../harness/harness.dart';

class _GuiderNotifier extends GuiderStateNotifier {
  _GuiderNotifier(super.ref) {
    state = const GuiderState(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'phd2:localhost:4400',
      deviceName: 'PHD2',
    );
  }
}

Future<void> _pump(WidgetTester tester, Phd2State state) => pumpAppScreen(
      tester,
      const ConnectedDeviceCard(type: DeviceType.guider),
      extraOverrides: [
        guiderStateProvider.overrideWith(_GuiderNotifier.new),
        phd2StateProvider.overrideWith((ref) => state),
      ],
    );

void main() {
  for (final (state, label) in [
    (Phd2State.looping, 'Looping'),
    (Phd2State.stopped, 'Stopped'),
    (Phd2State.calibrating, 'Calibrating'),
    (Phd2State.guiding, 'Guiding'),
    (Phd2State.lostLock, 'Star lost'),
  ]) {
    testWidgets('a guider that is ${state.name} reads "$label"',
        (tester) async {
      await _pump(tester, state);
      final readout = tester.widget<Readout>(
        find.byWidgetPredicate((w) => w is Readout && w.label == 'State'),
      );
      expect(readout.value, label);
    });
  }
}
