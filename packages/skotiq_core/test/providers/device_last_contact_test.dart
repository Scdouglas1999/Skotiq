// System Health ages every device, not just the camera.
//
// Filling `lastSuccessfulCommunication` from `cameraStateProvider` alone —
// every other device going through `addBasic`, which passes none — leaves a rig
// with Camera, Mount, Focuser, Filter Wheel, Dome and Weather Station all
// connected showing an age only for the camera ("OK - 0s ago"). The other five
// read "OK - last contact unknown" permanently while the panel above them says
// "100/100 — All metrics within normal ranges".
//
// The observable is `deviceHealthSnapshotsProvider`: a connected mount whose
// snapshot carries `lastSuccessfulTimestampMs == 0` is what the panel renders
// as "last contact unknown".
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/providers/device_last_contact_provider.dart';
import 'package:skotiq_core/src/providers/equipment_health_provider.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';

/// A scripted stand-in for `DeviceBackend.getDeviceHealth`.
class _FakeProbe {
  _FakeProbe(this.answers);

  /// deviceId -> (lastSuccessfulCommunicationMs, isHealthy)
  final Map<String, (int, bool)> answers;
  final List<String> asked = <String>[];

  Future<(int, bool)> call(String deviceId) async {
    asked.add(deviceId);
    final answer = answers[deviceId];
    if (answer == null) throw StateError('Device $deviceId not found');
    return answer;
  }
}

ProviderContainer _containerWith(_FakeProbe probe) {
  late final DeviceLastContactNotifier notifier;
  final container = ProviderContainer(
    overrides: [
      deviceLastContactProvider.overrideWith((ref) {
        notifier = DeviceLastContactNotifier(
          probe: probe.call,
          autoStart: false,
        );
        ref.listen(
          connectedDeviceDescriptorsProvider,
          (previous, next) => notifier.track(next.map((d) => d.deviceId)),
          fireImmediately: true,
        );
        return notifier;
      }),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('DeviceLastContactNotifier', () {
    test('records a contact time for every tracked device', () async {
      final probe = _FakeProbe({
        'sim_mount_1': (1754000000000, true),
        'sim_focuser_1': (1754000005000, true),
      });
      final notifier = DeviceLastContactNotifier(
        probe: probe.call,
        autoStart: false,
      );
      addTearDown(notifier.dispose);

      notifier.track(const ['sim_mount_1', 'sim_focuser_1']);
      await notifier.refresh();

      expect(notifier.state.keys.toSet(), {'sim_mount_1', 'sim_focuser_1'});
      expect(
        notifier.state['sim_mount_1']!.lastContact,
        DateTime.fromMillisecondsSinceEpoch(1754000000000),
      );
      expect(notifier.state['sim_focuser_1']!.isResponsive, isTrue);
    });

    test(
      'a device that never answered stays absent, not epoch-stamped',
      () async {
        final probe = _FakeProbe({'sim_dome_1': (0, false)});
        final notifier = DeviceLastContactNotifier(
          probe: probe.call,
          autoStart: false,
        );
        addTearDown(notifier.dispose);

        notifier.track(const ['sim_dome_1']);
        await notifier.refresh();

        expect(notifier.state, isEmpty);
      },
    );

    test('untracking a device drops its stale contact record', () async {
      final probe = _FakeProbe({'sim_mount_1': (1754000000000, true)});
      final notifier = DeviceLastContactNotifier(
        probe: probe.call,
        autoStart: false,
      );
      addTearDown(notifier.dispose);

      notifier.track(const ['sim_mount_1']);
      await notifier.refresh();
      expect(notifier.state, isNotEmpty);

      notifier.track(const <String>[]);
      expect(notifier.state, isEmpty);
      expect(notifier.trackedDevices, isEmpty);
    });

    test('a probe that throws keeps the previous record', () async {
      final probe = _FakeProbe({'sim_mount_1': (1754000000000, true)});
      final notifier = DeviceLastContactNotifier(
        probe: probe.call,
        autoStart: false,
      );
      addTearDown(notifier.dispose);

      notifier.track(const ['sim_mount_1']);
      await notifier.refresh();
      probe.answers.remove('sim_mount_1');
      await notifier.refresh();

      expect(
        notifier.state['sim_mount_1']!.lastContact,
        DateTime.fromMillisecondsSinceEpoch(1754000000000),
      );
    });
  });

  group('deviceHealthSnapshotsProvider', () {
    test('a connected mount carries the backend last-contact time', () async {
      final probe = _FakeProbe({'sim_mount_1': (1754000000000, true)});
      final container = _containerWith(probe);

      final mount = container.read(mountStateProvider.notifier);
      mount.setConnecting('sim_mount_1', 'Simulated Mount');
      mount.setConnected();

      // Force the poll the provider schedules on connect.
      await container.read(deviceLastContactProvider.notifier).refresh();

      final snapshots = container.read(deviceHealthSnapshotsProvider);
      final mountSnapshot = snapshots.firstWhere(
        (s) => s.deviceId == 'sim_mount_1',
      );
      // A 0 here — the value every non-camera device gets without the
      // heartbeat wiring — renders as "OK - last contact unknown".
      expect(mountSnapshot.lastSuccessfulTimestampMs, 1754000000000);
      expect(mountSnapshot.isHealthy, isTrue);
    });

    test(
      'a mount the backend calls unresponsive is not reported healthy',
      () async {
        final probe = _FakeProbe({'sim_mount_1': (1754000000000, false)});
        final container = _containerWith(probe);

        final mount = container.read(mountStateProvider.notifier);
        mount.setConnecting('sim_mount_1', 'Simulated Mount');
        mount.setConnected();
        await container.read(deviceLastContactProvider.notifier).refresh();

        final snapshot = container
            .read(deviceHealthSnapshotsProvider)
            .firstWhere((s) => s.deviceId == 'sim_mount_1');
        expect(snapshot.isHealthy, isFalse);
        expect(snapshot.lastSuccessfulTimestampMs, 1754000000000);
      },
    );

    test('the poller follows the connected set', () async {
      final probe = _FakeProbe({
        'sim_mount_1': (1754000000000, true),
        'sim_focuser_1': (1754000009000, true),
      });
      final container = _containerWith(probe);
      final notifier = container.read(deviceLastContactProvider.notifier);

      expect(notifier.trackedDevices, isEmpty);

      // Riverpod delivers `ref.listen` notifications after the current
      // microtask, so settle before reading the tracked set.
      Future<void> settle() => Future<void>.delayed(Duration.zero);

      final mount = container.read(mountStateProvider.notifier);
      mount.setConnecting('sim_mount_1', 'Simulated Mount');
      mount.setConnected();
      await settle();
      expect(notifier.trackedDevices, {'sim_mount_1'});

      final focuser = container.read(focuserStateProvider.notifier);
      focuser.setConnecting('sim_focuser_1', 'Simulated Focuser');
      focuser.setConnected();
      await settle();
      expect(notifier.trackedDevices, {'sim_mount_1', 'sim_focuser_1'});

      mount.setDisconnected();
      await settle();
      expect(notifier.trackedDevices, {'sim_focuser_1'});
    });
  });
}
