import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/utils.dart' show LogLevel;
import 'package:skotiq_core/src/backend/roles/mount_guard_backend.dart';

import '../harness/captured_log.dart';

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend initial) {
    state = initial;
  }

  void switchTo(SkotiqBackend backend) => state = backend;
}

class _RecordingMountGuard extends MountGuardNotifier {
  final appliedAfterDispose = <List<MountGuardEntry>>[];
  var _disposed = false;

  @override
  List<MountGuardEntry> build() {
    ref.onDispose(() => _disposed = true);
    return super.build();
  }

  @override
  set state(List<MountGuardEntry> value) {
    if (_disposed) appliedAfterDispose.add(value);
    super.state = value;
  }
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

    test('a failed guard read is logged', () async {
      final appLog = await captureAppLog();
      final host = _FakeMountGuardBackend(
        () async => throw StateError('host unreachable'),
      );
      addTearDown(host.dispose);
      final container = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _SwappableBackendNotifier(ref, host),
          ),
        ],
      );
      addTearDown(container.dispose);

      container.read(mountGuardProvider);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final lines = logFrom(appLog, 'MountGuard');
      expect(lines, hasLength(1));
      expect(lines.single.level, LogLevel.debug);
      expect(lines.single.message, contains('Mount guard read failed'));
      expect(lines.single.message, contains('host unreachable'));
    });

    test(
      'a guard read that finishes after dispose is not applied and is not logged as a failed read',
      () async {
        final appLog = await captureAppLog();

        final gate = Completer<List<MountGuardEntry>>();
        var reads = 0;
        final host = _FakeMountGuardBackend(() {
          reads++;
          return gate.future;
        });
        addTearDown(host.dispose);
        final guard = _RecordingMountGuard();

        final container = ProviderContainer(
          overrides: [
            backendProvider.overrideWith(
              (ref) => _SwappableBackendNotifier(ref, host),
            ),
            mountGuardProvider.overrideWith(() => guard),
          ],
        );
        container.read(mountGuardProvider);
        await Future<void>.delayed(Duration.zero);
        expect(reads, 1);

        container.dispose();
        gate.complete(const [
          MountGuardEntry(deviceId: 'mount-late', blockReason: 'after-dispose'),
        ]);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(guard.appliedAfterDispose, isEmpty);
        expect(reads, 1, reason: 'a disposed guard does not poll again');
        expect(
          logFrom(
            appLog,
            'MountGuard',
          ).where((e) => e.message.contains('Mount guard read failed')),
          isEmpty,
        );
      },
    );
  });
}
