// A mount that cannot report where it is pointing in the horizon frame must
// say so, not report the horizon.
//
// With no observing site the native side returns `altitude: None,
// azimuth: None, sidereal_time: None` (see
// `sim_gate::apply_derived_mount_telemetry` — the horizon frame is a function
// of the site and the clock, not of the mount). Both Dart entry points then
// wrote `?? 0.0` onto a non-nullable double, so a parked simulated mount on a
// machine with no site printed `Alt 0.00° / Az 0.00°` in the Imaging → Mount
// card that was honestly printing `Pier --` two rows below. 0° is the horizon:
// a measurement, not a blank.

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/disconnected_backend.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/equipment/equipment_models.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';

void main() {
  test('a status with no horizon frame parses as unknown, not as 0°', () {
    final status = MountStatus.fromJson(const {
      'connected': true,
      'tracking': false,
      'slewing': false,
      'parked': true,
      'right_ascension': 0.0,
      'declination': 0.0,
      // altitude / azimuth / sidereal_time absent: the mount could not say.
      'availability': {
        'altitude': 'unsupported',
        'azimuth': 'unsupported',
        'sidereal_time': 'unsupported',
      },
    });

    expect(status.altitude, isNull);
    expect(status.azimuth, isNull);
    expect(status.siderealTime, isNull);
    // The coordinates the mount DOES know are still required doubles.
    expect(status.rightAscension, 0.0);
    expect(status.declination, 0.0);
  });

  test('a real 0.0 in the payload still parses as a real 0.0', () {
    final status = MountStatus.fromJson(const {
      'connected': true,
      'altitude': 0.0,
      'azimuth': 0.0,
      'sidereal_time': 0.0,
    });

    expect(status.altitude, 0.0);
    expect(status.azimuth, 0.0);
    expect(status.siderealTime, 0.0);
  });

  test('a poll that reports the horizon frame as unknown clears the last '
      'computed pair instead of leaving it on screen', () {
    fakeAsync((async) {
      final backend = _ScriptedMountBackend();
      final container = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _TestBackendNotifier(ref, backend),
          ),
        ],
      );
      addTearDown(container.dispose);

      container.read(mountStateProvider.notifier)
        ..setConnecting('mount-1', 'Simulated Mount')
        ..setConnected();

      // First poll: a site is configured, so the mount reports a real
      // horizon-frame position.
      backend.next = _status(
        altitude: -3.07,
        azimuth: 87.2,
        siderealTime: 17.7,
      );
      async.elapse(const Duration(seconds: 2));
      async.flushMicrotasks();
      expect(container.read(mountStateProvider).altitude, -3.07);
      expect(container.read(mountStateProvider).azimuth, 87.2);

      // Second poll: the site is gone, so the mount cannot say any more.
      backend.next = _status(altitude: null, azimuth: null, siderealTime: null);
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();

      final state = container.read(mountStateProvider);
      expect(
        state.altitude,
        isNull,
        reason:
            'a stale altitude outliving the site it was computed for is '
            'the same untruth as a fabricated one',
      );
      expect(state.azimuth, isNull);
      // The equatorial coordinates the mount reports on its own are untouched.
      expect(state.ra, 0.0);
      expect(state.dec, 0.0);

      container.dispose();
      async.flushMicrotasks();
    });
  });

  test('copyWith without clearHorizonFrame still means "leave unchanged"', () {
    const before = MountState(altitude: 42.0, azimuth: 180.0);
    expect(before.copyWith(isTracking: true).altitude, 42.0);
    expect(before.copyWith(isTracking: true).azimuth, 180.0);
    expect(before.copyWith(clearHorizonFrame: true).altitude, isNull);
    expect(before.copyWith(clearHorizonFrame: true).azimuth, isNull);
  });
}

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    // ignore: invalid_use_of_protected_member
    state = backend;
  }
}

class _ScriptedMountBackend extends DisconnectedBackend {
  MountStatus? next;

  @override
  Future<MountStatus> getMountStatus(String deviceId) async =>
      next ?? _status(altitude: null, azimuth: null, siderealTime: null);
}

MountStatus _status({
  required double? altitude,
  required double? azimuth,
  required double? siderealTime,
}) => MountStatus(
  connected: true,
  tracking: false,
  slewing: false,
  parked: true,
  atHome: false,
  sideOfPier: PierSide.unknown,
  rightAscension: 0.0,
  declination: 0.0,
  altitude: altitude,
  azimuth: azimuth,
  siderealTime: siderealTime,
  trackingRate: TrackingRate.sidereal,
  canPark: true,
  canSlew: true,
  canSync: true,
  canPulseGuide: true,
  canSetTrackingRate: true,
);
