// The live stack is registered onto its reference frame, so the stack's pixel
// geometry IS that sub's. Keeping the reference's path on the state is what
// lets a consumer resolve the stack's WCS, scale and orientation from a real
// header instead of inferring them — and it is only true while a stack that
// was started from that file is running, which is what these pin.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../harness/in_memory_database.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _MockLocalBackend extends Mock implements SkotiqBackend {}

/// Local stacker stand-in that answers both calls `_startFromFile` makes, so
/// the host path runs end to end without the native singleton.
class _FakeLocalStackingService extends LiveStackingService {
  _FakeLocalStackingService(super.ref);

  String? startedFrom;
  int stopCalls = 0;
  int resetCalls = 0;

  @override
  Future<LiveStackingStats> startFromFile({
    required String referenceImagePath,
    LiveStackingConfig config = const LiveStackingConfig(),
  }) async {
    startedFrom = referenceImagePath;
    return const LiveStackingStats(stackedFrameCount: 1);
  }

  @override
  Future<LiveStackingStats> startFromData({
    required int width,
    required int height,
    required List<int> data,
    LiveStackingConfig config = const LiveStackingConfig(),
  }) async => const LiveStackingStats(stackedFrameCount: 1);

  @override
  Future<LiveStackingResult> getCurrentResult() async =>
      const LiveStackingResult(
        width: 2,
        height: 1,
        data: [1, 2],
        stats: LiveStackingStats(stackedFrameCount: 1),
      );

  @override
  Future<void> reset() async {
    resetCalls++;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
  }
}

ProviderContainer _localContainer(
  _FakeLocalStackingService Function(Ref) build,
) {
  final container = ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      backendProvider.overrideWith((ref) => _TestBackendNotifier(ref)),
      loggingServiceProvider.overrideWithValue(LoggingService()),
      liveStackingServiceProvider.overrideWith(build),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref) {
    state = _MockLocalBackend();
  }
}

void main() {
  setUpAll(() {
    registerFallbackValue(const LiveStackingConfig());
  });

  test('a stack started from a file names the sub it is aligned to', () async {
    late _FakeLocalStackingService service;
    final container = _localContainer((ref) {
      service = _FakeLocalStackingService(ref);
      return service;
    });
    final notifier = container.read(liveStackingProvider.notifier);

    await notifier.startFromFile('/data/m42/light_0001.fits');

    expect(
      container.read(liveStackingProvider).status,
      LiveStackingStatus.running,
    );
    expect(
      container.read(liveStackingProvider).referenceImagePath,
      '/data/m42/light_0001.fits',
    );
    expect(service.startedFrom, '/data/m42/light_0001.fits');
  });

  test('stopping clears it — an idle stack is aligned to nothing', () async {
    final container = _localContainer(_FakeLocalStackingService.new);
    final notifier = container.read(liveStackingProvider.notifier);

    await notifier.startFromFile('/data/m42/light_0001.fits');
    await notifier.stop();

    expect(container.read(liveStackingProvider).referenceImagePath, isNull);
  });

  test(
    'a reset starts the evidence over and drops the old reference',
    () async {
      final container = _localContainer(_FakeLocalStackingService.new);
      final notifier = container.read(liveStackingProvider.notifier);

      await notifier.startFromFile('/data/m42/light_0001.fits');
      await notifier.reset();

      // Reset rebuilds the session from scratch; the frames it had were
      // registered onto a reference the new stack no longer holds.
      expect(container.read(liveStackingProvider).referenceImagePath, isNull);
    },
  );

  test('a second session replaces the first session\'s reference', () async {
    final container = _localContainer(_FakeLocalStackingService.new);
    final notifier = container.read(liveStackingProvider.notifier);

    await notifier.startFromFile('/data/m42/light_0001.fits');
    await notifier.stop();
    await notifier.startFromFile('/data/m42/light_0002.fits');

    expect(
      container.read(liveStackingProvider).referenceImagePath,
      '/data/m42/light_0002.fits',
    );
  });

  test('a stack built from raw pixels names no file', () async {
    final container = _localContainer(_FakeLocalStackingService.new);
    final notifier = container.read(liveStackingProvider.notifier);

    await notifier.startFromData(width: 2, height: 1, data: const [1, 2]);

    expect(
      container.read(liveStackingProvider).status,
      LiveStackingStatus.running,
    );
    expect(container.read(liveStackingProvider).referenceImagePath, isNull);
  });

  test('a failed start names no reference', () async {
    late _FailingStackingService service;
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith((ref) => _TestBackendNotifier(ref)),
        loggingServiceProvider.overrideWithValue(LoggingService()),
        liveStackingServiceProvider.overrideWith((ref) {
          service = _FailingStackingService(ref);
          return service;
        }),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(liveStackingProvider.notifier);

    await notifier.startFromFile('/data/m42/unreadable.fits');

    // A path on a stack that does not exist would be a claim about geometry
    // nothing is aligned to.
    expect(
      container.read(liveStackingProvider).status,
      LiveStackingStatus.error,
    );
    expect(container.read(liveStackingProvider).referenceImagePath, isNull);
  });

  test('arming a remote host without a reference names none', () async {
    final backend = _MockNetworkBackend();
    when(
      () => backend.stackingStart(config: any(named: 'config')),
    ).thenAnswer((_) async => const LiveStackingStats());
    when(backend.stackingGetResult).thenAnswer(
      (_) async => const LiveStackingResult(
        width: 1,
        height: 1,
        data: [1],
        stats: LiveStackingStats(stackedFrameCount: 1),
      ),
    );
    when(backend.stackingStop).thenAnswer((_) async {});

    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith(
          (ref) => _RemoteBackendNotifier(ref, backend),
        ),
        loggingServiceProvider.overrideWithValue(LoggingService()),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(liveStackingProvider.notifier);

    await notifier.startRemote();
    await notifier.stop();

    // The host owns that stack's reference; until it reports one there is
    // nothing honest to put here.
    expect(container.read(liveStackingProvider).referenceImagePath, isNull);
  });

  test('copyWith keeps the reference unless asked to clear it', () {
    const original = LiveStackingState(
      status: LiveStackingStatus.running,
      referenceImagePath: '/data/m42/light_0001.fits',
    );

    expect(
      original.copyWith(previewWidth: 3).referenceImagePath,
      '/data/m42/light_0001.fits',
    );
    expect(
      original.copyWith(clearReferenceImagePath: true).referenceImagePath,
      isNull,
    );
  });
}

class _FailingStackingService extends LiveStackingService {
  _FailingStackingService(super.ref);

  @override
  Future<LiveStackingStats> startFromFile({
    required String referenceImagePath,
    LiveStackingConfig config = const LiveStackingConfig(),
  }) async => throw StateError('cannot read $referenceImagePath');
}

class _RemoteBackendNotifier extends BackendNotifier {
  _RemoteBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}
