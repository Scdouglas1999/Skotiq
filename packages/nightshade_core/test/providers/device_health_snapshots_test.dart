// A device that never connected is not a failing heartbeat.
//
// Clicking Connect on the built-in guider can fail correctly (no focal length
// in the profile), leaving the row on "Connect" with a grey dot — while DEVICE
// HEARTBEATS grows a card for it, System Health drops from "100 - Excellent" to
// "75 - Good / 1 issue", and the insight reads "Unhealthy devices detected:
// native:builtin_guider:multi_star". A refused connection is not a heartbeat
// failure, and the copy must not quote a raw internal id.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightshade_core/nightshade_core.dart';

class _FakeGuiderNotifier extends StateNotifier<GuiderState>
    implements GuiderStateNotifier {
  _FakeGuiderNotifier(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeMountNotifier extends StateNotifier<MountState>
    implements MountStateNotifier {
  _FakeMountNotifier(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ProviderContainer _container({
  required GuiderState guider,
  required MountState mount,
}) {
  final container = ProviderContainer(
    overrides: [
      guiderStateProvider.overrideWith((ref) => _FakeGuiderNotifier(guider)),
      mountStateProvider.overrideWith((ref) => _FakeMountNotifier(mount)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  const connectedMount = MountState(
    connectionState: DeviceConnectionState.connected,
    deviceId: 'sim:mount:1',
    deviceName: 'Simulated Mount',
  );

  for (final hasContact in [false, true]) {
    test(
      'failed heartbeat updates health immediately (contact: $hasContact)',
      () async {
        const deviceId = 'native:zwo:0';
        final contactTime = DateTime.utc(2026, 10, 7, 23, 47, 56);
        var responsive = true;
        final contacts = DeviceLastContactNotifier(
          probe: (_) async => (contactTime.millisecondsSinceEpoch, responsive),
          autoStart: false,
        );
        final container = ProviderContainer(
          overrides: [
            connectedDeviceDescriptorsProvider.overrideWithValue(const [
              DeviceConnectionDescriptor(
                deviceId: deviceId,
                deviceLabel: 'ASI1600MM-Cool',
                isHealthy: true,
              ),
            ]),
            deviceLastContactProvider.overrideWith((ref) => contacts),
          ],
        );
        addTearDown(container.dispose);
        // Keep the same subscription as the visible health panel.
        final subscription = container.listen(
          deviceHealthSnapshotsProvider,
          (_, __) {},
          fireImmediately: true,
        );
        addTearDown(subscription.close);
        if (hasContact) {
          contacts.track([deviceId]);
          await contacts.refresh();
        }
        expect(subscription.read().single.isHealthy, isTrue);
        final heartbeat = container.read(
          deviceHeartbeatHealthProvider.notifier,
        );
        for (final status in ['degraded', 'reconnecting']) {
          heartbeat.applyStatusEvent(
            deviceId: deviceId,
            status: status,
            consecutiveFailures: 1,
          );
          final snapshot = subscription.read().single;
          expect(snapshot.isHealthy, isFalse, reason: status);
          expect(
            snapshot.lastSuccessfulTimestampMs,
            hasContact ? contactTime.millisecondsSinceEpoch : 0,
          );
        }
        heartbeat.applyStatusEvent(deviceId: deviceId, status: 'healthy');
        expect(subscription.read().single.isHealthy, isTrue);
        if (hasContact) {
          responsive = false;
          await contacts.refresh();
          expect(subscription.read().single.isHealthy, isFalse);
          heartbeat.applyStatusEvent(deviceId: deviceId, status: 'healthy');
          expect(subscription.read().single.isHealthy, isFalse);
        }
      },
    );
  }

  test('a guider whose connect attempt failed is not a heartbeat entry', () {
    final container = _container(
      guider: const GuiderState(
        connectionState: DeviceConnectionState.error,
        deviceId: 'native:builtin_guider:multi_star',
        deviceName: 'Built-in Multi-Star Guider',
      ),
      mount: connectedMount,
    );

    final ids = container
        .read(deviceHealthSnapshotsProvider)
        .map((snapshot) => snapshot.deviceId)
        .toList();

    expect(ids, isNot(contains('native:builtin_guider:multi_star')));
    expect(ids, contains('sim:mount:1'));
  });

  test('a device the user disconnected is not reported unhealthy', () {
    final container = _container(
      guider: const GuiderState(
        connectionState: DeviceConnectionState.disconnected,
        deviceId: 'native:builtin_guider:multi_star',
        deviceName: 'Built-in Multi-Star Guider',
      ),
      mount: connectedMount,
    );

    expect(
      container
          .read(deviceHealthSnapshotsProvider)
          .where((snapshot) => !snapshot.isHealthy),
      isEmpty,
    );
  });

  test('heartbeat-failure copy names the device, never its internal id', () {
    const service = EquipmentHealthService();
    final report = service.analyze(
      sessions: const [],
      deviceHealth: const [
        DeviceHealthSnapshot(
          deviceId: 'native:builtin_guider:multi_star',
          deviceLabel: 'Built-in Multi-Star Guider',
          lastSuccessfulTimestampMs: 0,
          isHealthy: false,
        ),
      ],
    );

    final message = report.insights
        .firstWhere((insight) => insight.title == 'Device heartbeat failures')
        .message;
    expect(message, contains('Built-in Multi-Star Guider'));
    expect(message, isNot(contains('native:builtin_guider:multi_star')));
  });
}
