import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/disconnected_backend.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/equipment/equipment_models.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';

void main() {
  test('a late position poll cannot repopulate state after disconnect', () {
    fakeAsync((async) {
      final backend = _DelayedMountBackend();
      final container = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _TestBackendNotifier(ref, backend),
          ),
        ],
      );

      final notifier = container.read(mountStateProvider.notifier)
        ..setConnecting('mount-old', 'Old Mount')
        ..setConnected();

      async.elapse(const Duration(seconds: 2));
      async.flushMicrotasks();
      expect(backend.statusRequested, isTrue);

      notifier.setDisconnected();
      backend.status.complete(_status(ra: 12.5, dec: -30));
      async.flushMicrotasks();

      final state = container.read(mountStateProvider);
      expect(state.connectionState, DeviceConnectionState.disconnected);
      expect(state.deviceId, isNull);
      expect(state.ra, isNull);
      expect(state.dec, isNull);
      expect(state.isTracking, isFalse);

      container.dispose();
      async.flushMicrotasks();
    });
  });
}

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    // ignore: invalid_use_of_protected_member
    state = backend;
  }
}

class _DelayedMountBackend extends DisconnectedBackend {
  final status = Completer<MountStatus>();
  bool statusRequested = false;

  @override
  Future<MountStatus> getMountStatus(String deviceId) {
    statusRequested = true;
    return status.future;
  }
}

MountStatus _status({required double ra, required double dec}) => MountStatus(
  connected: true,
  tracking: true,
  slewing: false,
  parked: false,
  atHome: false,
  sideOfPier: PierSide.east,
  rightAscension: ra,
  declination: dec,
  altitude: 45,
  azimuth: 180,
  siderealTime: 10,
  trackingRate: TrackingRate.sidereal,
  canPark: true,
  canSlew: true,
  canSync: true,
  canPulseGuide: true,
  canSetTrackingRate: true,
);
