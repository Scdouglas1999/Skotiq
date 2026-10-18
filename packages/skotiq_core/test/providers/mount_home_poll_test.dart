// The mount poll carries the driver's AtHome into the mount state, and an
// unconfirmed home stops being the mount's position once it moves again.

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/disconnected_backend.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/equipment/equipment_models.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';

void main() {
  test('the poll reports AtHome and clears an unconfirmed home on motion', () {
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

      final notifier = container.read(mountStateProvider.notifier)
        ..setConnecting('mount-1', 'Simulated Mount')
        ..setConnected();

      backend.next = _status(atHome: true);
      async.elapse(const Duration(seconds: 2));
      async.flushMicrotasks();
      expect(container.read(mountStateProvider).isAtHome, isTrue);

      // A home whose driver could not confirm it, then the mount stopped.
      backend.next = _status();
      notifier.setHomeUnconfirmed(true);
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect(container.read(mountStateProvider).isAtHome, isFalse);
      expect(
        container.read(mountStateProvider).homeUnconfirmed,
        isTrue,
        reason: 'a stopped mount is still where the home left it',
      );

      // It moves: wherever it ends up, it is no longer the unconfirmed home.
      backend.next = _status(slewing: true);
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect(container.read(mountStateProvider).homeUnconfirmed, isFalse);

      container.dispose();
      async.flushMicrotasks();
    });
  });

  test('starting a home clears the previous unconfirmed home', () {
    const before = MountState(homeUnconfirmed: true);
    expect(before.copyWith(isHoming: true).homeUnconfirmed, isTrue);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(mountStateProvider.notifier)
      ..setHomeUnconfirmed(true)
      ..setHoming(true);
    expect(container.read(mountStateProvider).homeUnconfirmed, isFalse);
    expect(container.read(mountStateProvider).isHoming, isTrue);
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
      next ?? _status();
}

MountStatus _status({bool atHome = false, bool slewing = false}) => MountStatus(
  connected: true,
  tracking: false,
  slewing: slewing,
  parked: false,
  atHome: atHome,
  sideOfPier: PierSide.west,
  rightAscension: 1.5,
  declination: 89.9,
  trackingRate: TrackingRate.sidereal,
  canPark: true,
  canSlew: true,
  canSync: true,
  canPulseGuide: true,
  canSetTrackingRate: true,
  availability: const {'at_home': 'available'},
);
