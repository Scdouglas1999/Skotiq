// The mount poll reads the side of pier on every tick. It used to drop it, so
// MountState.sideOfPier was null for every mount: Imaging → Mount printed
// "Pier —" beside a tracking mount, and the meridian-flip countdown never saw
// the pier side change that marks a completed flip.

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/disconnected_backend.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/equipment/equipment_models.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';

void main() {
  test('each poll carries the reported side of pier into the mount state, '
      'and an unknown side clears it', () {
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

      backend.next = _status(PierSide.east);
      async.elapse(const Duration(seconds: 2));
      async.flushMicrotasks();
      expect(container.read(mountStateProvider).sideOfPier, 'East');

      // The flip happened.
      backend.next = _status(PierSide.west);
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect(container.read(mountStateProvider).sideOfPier, 'West');

      // The driver stops saying: the last side must not linger as if live.
      backend.next = _status(PierSide.unknown);
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect(container.read(mountStateProvider).sideOfPier, isNull);

      container.dispose();
      async.flushMicrotasks();
    });
  });

  test('copyWith keeps the side of pier unless told to clear it', () {
    const before = MountState(sideOfPier: 'East');
    expect(before.copyWith(isTracking: true).sideOfPier, 'East');
    expect(before.copyWith(clearSideOfPier: true).sideOfPier, isNull);
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
      next ?? _status(PierSide.unknown);
}

MountStatus _status(PierSide side) => MountStatus(
  connected: true,
  tracking: true,
  slewing: false,
  parked: false,
  atHome: false,
  sideOfPier: side,
  rightAscension: 1.5,
  declination: 15.0,
  altitude: 44.9,
  azimuth: 109.3,
  siderealTime: 22.6,
  trackingRate: TrackingRate.sidereal,
  canPark: true,
  canSlew: true,
  canSync: true,
  canPulseGuide: true,
  canSetTrackingRate: true,
);
