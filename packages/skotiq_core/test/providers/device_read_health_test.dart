import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/backend/device_types.dart';
import 'package:skotiq_core/src/providers/device_heartbeat_health_provider.dart';
import 'package:skotiq_core/src/providers/equipment/device_read_health_provider.dart';

void main() {
  final t0 = DateTime.utc(2026, 11, 8, 0, 29, 34);

  // The rig, Nov 8 2026: every mount read failed and Tonight kept showing the
  // last position as current.
  test('failing reads make a slot stale, with the age of the last good '
      'read and the driver reason', () {
    var now = t0;
    final reads = DeviceReadHealthNotifier(now: () => now);
    reads.recordSuccess(DeviceType.mount, 'ascom:NYX');
    now = t0.add(const Duration(seconds: 2));
    reads.recordFailure(
      DeviceType.mount,
      'ascom:NYX',
      Exception('Failed to get RA: Starting the driver is required 0x80040401'),
    );
    expect(
      staleReadingsFor(reads.state, const {}, DeviceType.mount, 'ascom:NYX'),
      isNull,
      reason: 'one failed read is not yet stale',
    );
    reads.recordFailure(
      DeviceType.mount,
      'ascom:NYX',
      Exception('Failed to get RA: Starting the driver is required 0x80040401'),
    );
    final stale = staleReadingsFor(
      reads.state,
      const {},
      DeviceType.mount,
      'ascom:NYX',
    )!;
    expect(stale.since, t0);
    expect(stale.reason, startsWith('Failed to get RA'));
    expect(
      staleAgeText(stale.ageAt(t0.add(const Duration(minutes: 3)))!),
      '3 min',
    );

    reads.recordSuccess(DeviceType.mount, 'ascom:NYX');
    expect(
      staleReadingsFor(reads.state, const {}, DeviceType.mount, 'ascom:NYX'),
      isNull,
      reason: 'a good read makes the values current again',
    );
  });

  // Every poll of every connected device ends in a good read; telling the
  // listeners each time recomputed Tonight's panels and cost a frame per poll.
  test('a good read after a good read tells no one', () {
    var now = t0;
    final reads = DeviceReadHealthNotifier(now: () => now);
    var told = 0;
    reads.addListener((_) => told++, fireImmediately: false);

    reads.recordSuccess(DeviceType.mount, 'ascom:NYX');
    for (var i = 1; i <= 30; i++) {
      now = t0.add(Duration(seconds: 2 * i));
      reads.recordSuccess(DeviceType.mount, 'ascom:NYX');
    }
    expect(told, 1, reason: 'only the first read changes what is known');

    now = now.add(const Duration(seconds: 2));
    reads.recordFailure(DeviceType.mount, 'ascom:NYX', 'x');
    reads.recordFailure(DeviceType.mount, 'ascom:NYX', 'x');
    expect(
      staleReadingsFor(
        reads.state,
        const {},
        DeviceType.mount,
        'ascom:NYX',
      )!.since,
      t0.add(const Duration(seconds: 60)),
      reason: 'the stale age still counts from the last good read',
    );
  });

  test('another device in the slot is not stale for this one', () {
    final reads = DeviceReadHealthNotifier();
    reads.recordFailure(DeviceType.camera, 'native:zwo:1', 'x');
    reads.recordFailure(DeviceType.camera, 'native:zwo:1', 'x');
    expect(
      staleReadingsFor(
        reads.state,
        const {},
        DeviceType.camera,
        'native:zwo:0',
      ),
      isNull,
    );
  });

  test('a degraded heartbeat marks a polled-by-events device stale', () {
    final since = t0.subtract(const Duration(minutes: 1));
    final stale = staleReadingsFor(
      const {},
      {
        'native:zwo_eaf:0': DeviceHeartbeatHealthState(
          health: HeartbeatHealth.degraded,
          lastChange: since,
          reason: 'Device not responding',
        ),
      },
      DeviceType.focuser,
      'native:zwo_eaf:0',
    )!;
    expect(stale.since, since);
    expect(stale.reason, 'Device not responding');
  });

  // As seen live: the host's reason arrives wrapped by the bridge, a linked
  // client's by the host's error code.
  test('read errors lose their wrappers', () {
    const driver =
        'Failed to get RA: Starting the driver is required 0x80040401';
    expect(
      readErrorText('SkotiqError.operationFailed(field0: $driver)'),
      driver,
    );
    expect(readErrorText('internal_error: $driver'), driver);
    expect(
      readErrorText(
        'Exception: SkotiqError.connectionFailed(deviceId: m, reason: $driver)',
      ),
      driver,
    );
    expect(readErrorText(driver), driver);
  });

  test('stale ages read plainly', () {
    expect(staleAgeText(const Duration(seconds: 45)), '45 s');
    expect(staleAgeText(const Duration(minutes: 130)), '2 h 10 min');
    expect(staleAgeText(const Duration(hours: 2)), '2 h');
  });
}
