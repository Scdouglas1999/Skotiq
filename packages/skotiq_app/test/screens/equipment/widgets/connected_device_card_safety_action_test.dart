import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/equipment/widgets/connected_device_card.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../../harness/harness.dart';

class _UnsafeSafetyMonitorNotifier extends SafetyMonitorStateNotifier {
  _UnsafeSafetyMonitorNotifier(super.ref) {
    state = const SafetyMonitorState(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'safety-1',
      deviceName: 'Test Safety Monitor',
      isSafe: false,
    );
  }
}

final _testSafetyStatusProvider =
    StateProvider<WeatherSafetyStatus>((_) => WeatherSafetyStatus.unsafe);

void main() {
  testWidgets('unsafe quick action uses canonical snooze and cancellation',
      (tester) async {
    Duration? snoozedFor;
    var cancelCalls = 0;
    await pumpAppScreen(
      tester,
      const ConnectedDeviceCard(type: ConnectedDeviceType.safetyMonitor),
      extraOverrides: [
        safetyMonitorStateProvider.overrideWith(
          _UnsafeSafetyMonitorNotifier.new,
        ),
        equipmentSafetySnoozeStatusProvider.overrideWith(
          (ref) => ref.watch(_testSafetyStatusProvider),
        ),
        equipmentSafetySnoozeActionProvider.overrideWith((ref) {
          return (duration) {
            snoozedFor = duration;
            ref.read(_testSafetyStatusProvider.notifier).state =
                WeatherSafetyStatus.snoozed;
          };
        }),
        equipmentSafetyCancelSnoozeActionProvider.overrideWith((ref) {
          return () {
            cancelCalls++;
            ref.read(_testSafetyStatusProvider.notifier).state =
                WeatherSafetyStatus.unsafe;
          };
        }),
      ],
    );

    expect(find.text('Snooze 15m'), findsOneWidget);
    expect(find.text('Acknowledge'), findsNothing);

    await tester.tap(find.text('Snooze 15m'));
    await tester.pump();

    expect(snoozedFor, const Duration(minutes: 15));
    expect(find.text('Cancel Snooze'), findsOneWidget);

    await tester.tap(find.text('Cancel Snooze'));
    await tester.pump();

    expect(cancelCalls, 1);
    expect(find.text('Snooze 15m'), findsOneWidget);
  });
}
