import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/src/backend/roles/mount_guard_backend.dart';

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend initial) {
    state = initial;
  }

  void switchTo(SkotiqBackend backend) => state = backend;
}

class _FakeMountGuardBackend extends DisconnectedBackend
    implements MountGuardBackend {
  _FakeMountGuardBackend(this._onState);

  final Future<List<MountGuardEntry>> Function() _onState;
  final _events = StreamController<SkotiqEvent>.broadcast();

  @override
  Stream<SkotiqEvent> get eventStream => _events.stream;

  @override
  Future<List<MountGuardEntry>> mountGuardState() => _onState();

  @override
  Future<void> mountGuardAcknowledgeFault(String deviceId) async {}

  @override
  Future<void> mountGuardConfirmRehomed(String deviceId) async {}

  @override
  Future<void> mountGuardRecoverySync(
    String deviceId,
    double raHours,
    double decDegrees,
  ) async {}

  @override
  Future<void> mountGuardSetAutoSyncResume(bool enabled) async {}

  @override
  Future<MountGuardSolveResult> mountGuardSolve(
    String deviceId, {
    String? cameraId,
    double exposureSecs = 5,
  }) async => throw UnimplementedError();

  @override
  void dispose() {
    _events.close();
    super.dispose();
  }
}

void main() {
  group('MountGuardNotifier host swap and disposal safety', () {
    test(
      'ignores stale in-flight guard response after backend swap and refreshes new host',
      () async {
        final hostAGate = Completer<List<MountGuardEntry>>();
        final hostA = _FakeMountGuardBackend(() => hostAGate.future);
        final hostB = _FakeMountGuardBackend(
          () async => const [
            MountGuardEntry(deviceId: 'mount-b', blockReason: 'host-b-fault'),
          ],
        );
        addTearDown(hostA.dispose);
        addTearDown(hostB.dispose);

        late _SwappableBackendNotifier backendNotifier;
        final container = ProviderContainer(
          overrides: [
            backendProvider.overrideWith(
              (ref) => backendNotifier = _SwappableBackendNotifier(ref, hostA),
            ),
          ],
        );
        addTearDown(container.dispose);

        // Kick off initial microtask refresh against hostA (which stays pending).
        expect(container.read(mountGuardProvider), isEmpty);
        await Future<void>.delayed(Duration.zero);

        // Swap to hostB while hostA's mountGuardState() is still in flight.
        backendNotifier.switchTo(hostB);
        container.read(mountGuardProvider);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // hostB's state must load immediately (not blocked by hostA's _refreshing).
        expect(
          container.read(mountGuardProvider).map((e) => e.deviceId).toList(),
          ['mount-b'],
        );

        // Now resolve hostA's stale response — it must NOT overwrite hostB's state.
        hostAGate.complete(const [
          MountGuardEntry(deviceId: 'mount-a', blockReason: 'stale-fault'),
        ]);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(
          container.read(mountGuardProvider).map((e) => e.deviceId).toList(),
          ['mount-b'],
        );
      },
    );

    test(
      'disposing container while mountGuardState is in flight does not throw',
      () async {
        final gate = Completer<List<MountGuardEntry>>();
        final host = _FakeMountGuardBackend(() => gate.future);
        addTearDown(host.dispose);

        final container = ProviderContainer(
          overrides: [
            backendProvider.overrideWith(
              (ref) => _SwappableBackendNotifier(ref, host),
            ),
          ],
        );
        container.read(mountGuardProvider);
        await Future<void>.delayed(Duration.zero);

        container.dispose();
        gate.complete(const [MountGuardEntry(deviceId: 'mount-1')]);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      },
    );
  });
}
