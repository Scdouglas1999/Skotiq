import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import '../harness/in_memory_database.dart';
import 'package:skotiq_core/utils.dart';
import 'package:skotiq_core/errors.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _MockLocalBackend extends Mock implements SkotiqBackend {}

class _ControlledLocalStackingService extends LiveStackingService {
  _ControlledLocalStackingService(super.ref);

  final startResult = Completer<LiveStackingStats>();
  int stopCalls = 0;

  @override
  Future<LiveStackingStats> start({
    String? referenceImagePath,
    LiveStackingConfig config = const LiveStackingConfig(),
    String? filterKey,
  }) => startResult.future;

  @override
  Future<void> stop({String? filterKey}) async {
    stopCalls++;
  }
}

class _ReplaceableBackendNotifier extends BackendNotifier {
  _ReplaceableBackendNotifier(super.ref, SkotiqBackend initial) : super() {
    state = initial;
  }

  void replaceWith(SkotiqBackend next) => state = next;
}

ProviderContainer _container(
  SkotiqBackend backend, {
  void Function(_ReplaceableBackendNotifier notifier)? onNotifier,
}) {
  final container = ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      backendProvider.overrideWith((ref) {
        final notifier = _ReplaceableBackendNotifier(ref, backend);
        onNotifier?.call(notifier);
        return notifier;
      }),
      loggingServiceProvider.overrideWithValue(LoggingService()),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  setUpAll(() {
    registerFallbackValue(const LiveStackingConfig());
  });

  test(
    'Stop waits for an in-flight remote Start and disarms exactly once',
    () async {
      final backend = _MockNetworkBackend();
      final startCompleter = Completer<LiveStackingStats>();
      when(
        () => backend.stackingStart(config: any(named: 'config')),
      ).thenAnswer((_) => startCompleter.future);
      when(backend.stackingStop).thenAnswer((_) async {});

      final container = _container(backend);
      final notifier = container.read(liveStackingProvider.notifier);
      const config = LiveStackingConfig(sigmaClipThreshold: 2.5);

      final start = notifier.startRemote(config: config);
      await Future<void>.delayed(Duration.zero);
      final stopA = notifier.stop();
      final stopB = notifier.stop();
      verifyNever(backend.stackingStop);

      startCompleter.complete(const LiveStackingStats(stackedFrameCount: 0));
      await Future.wait([start, stopA, stopB]);

      verify(backend.stackingStop).called(1);
      final state = container.read(liveStackingProvider);
      expect(state.status, LiveStackingStatus.idle);
      expect(
        state.config,
        config,
        reason: 'Stop must preserve operator config.',
      );
    },
  );

  test(
    'a backend swap rejects a late Start completion from the old rig',
    () async {
      final oldBackend = _MockNetworkBackend();
      final newBackend = _MockNetworkBackend();
      final startCompleter = Completer<LiveStackingStats>();
      when(
        () => oldBackend.stackingStart(config: any(named: 'config')),
      ).thenAnswer((_) => startCompleter.future);

      late _ReplaceableBackendNotifier backendNotifier;
      final container = _container(
        oldBackend,
        onNotifier: (value) => backendNotifier = value,
      );
      final notifier = container.read(liveStackingProvider.notifier);

      final start = notifier.startRemote();
      await Future<void>.delayed(Duration.zero);
      backendNotifier.replaceWith(newBackend);
      startCompleter.complete(const LiveStackingStats(stackedFrameCount: 9));
      await start;

      final state = container.read(liveStackingProvider);
      expect(state.status, LiveStackingStatus.idle);
      expect(state.stats.stackedFrameCount, 0);
      verifyNever(newBackend.stackingGetResult);
    },
  );

  test(
    'backend switch releases the outgoing local stacker, not the new one',
    () async {
      final oldBackend = _MockLocalBackend();
      final newBackend = _MockLocalBackend();
      late _ReplaceableBackendNotifier backendNotifier;
      late _ControlledLocalStackingService oldService;
      late _ControlledLocalStackingService newService;
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) =>
                backendNotifier = _ReplaceableBackendNotifier(ref, oldBackend),
          ),
          loggingServiceProvider.overrideWithValue(LoggingService()),
          liveStackingServiceProvider.overrideWith((ref) {
            final backend = ref.watch(backendProvider);
            final service = _ControlledLocalStackingService(ref);
            if (identical(backend, oldBackend)) {
              oldService = service;
            } else {
              newService = service;
            }
            return service;
          }),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(liveStackingProvider.notifier);

      final start = notifier.startFromFile('/tmp/reference.fits');
      await Future<void>.delayed(Duration.zero);
      backendNotifier.replaceWith(newBackend);
      container.read(liveStackingServiceProvider);
      oldService.startResult.complete(
        const LiveStackingStats(stackedFrameCount: 1),
      );
      await start;
      await Future<void>.delayed(Duration.zero);

      expect(
        container.read(liveStackingProvider).status,
        LiveStackingStatus.idle,
      );
      expect(oldService.stopCalls, 1);
      expect(newService.stopCalls, 0);
    },
  );

  test('a slot that changes during a slow download is fetched again after '
      'it, never alongside it', () {
    fakeAsync((async) {
      final backend = _MockNetworkBackend();
      final downloads = <Completer<LiveStackingResult>>[];
      when(
        () => backend.stackingStart(config: any(named: 'config')),
      ).thenAnswer((_) async => const LiveStackingStats());
      when(
        () => backend.stackingGetResult(filterKey: any(named: 'filterKey')),
      ).thenAnswer((_) {
        final download = Completer<LiveStackingResult>();
        downloads.add(download);
        return download.future;
      });

      final container = _container(backend);
      final notifier = container.read(liveStackingProvider.notifier);
      unawaited(notifier.startRemote());
      async.flushMicrotasks();
      LiveStackSummary described(int revision) => LiveStackSummary(
        armed: true,
        slots: [
          LiveStackSlotSummary(
            filterKey: 'L',
            stats: LiveStackingStats(stackedFrameCount: revision),
            width: 1,
            height: 1,
            channels: 1,
            revision: revision,
          ),
        ],
      );

      notifier.applyHostStack(described(1), backend);
      async.flushMicrotasks();
      expect(downloads, hasLength(1));
      notifier.applyHostStack(described(2), backend);
      async.elapse(const Duration(seconds: 10));
      expect(downloads, hasLength(1));

      downloads[0].complete(
        const LiveStackingResult(
          width: 1,
          height: 1,
          data: [42],
          stats: LiveStackingStats(stackedFrameCount: 1),
        ),
      );
      async.flushMicrotasks();
      expect(downloads, hasLength(2));
      downloads[1].complete(
        const LiveStackingResult(
          width: 1,
          height: 1,
          data: [43],
          stats: LiveStackingStats(stackedFrameCount: 2),
        ),
      );
      async.elapse(const Duration(seconds: 10));
      expect(downloads, hasLength(2));
      expect(container.read(liveStackingProvider).previewData, [43]);
    });
  });

  test('failed Stop stays active and is retryable', () async {
    final backend = _MockNetworkBackend();
    when(
      () => backend.stackingStart(config: any(named: 'config')),
    ).thenAnswer((_) async => const LiveStackingStats());
    when(backend.stackingGetResult).thenThrow(
      const ServerError(
        code: 'no_active_stack',
        message: 'Live stacking is not running.',
        httpStatus: 404,
      ),
    );
    var stopAttempts = 0;
    when(backend.stackingStop).thenAnswer((_) async {
      stopAttempts++;
      if (stopAttempts == 1) throw StateError('link lost');
    });

    final container = _container(backend);
    final notifier = container.read(liveStackingProvider.notifier);
    await notifier.startRemote();
    await notifier.stop();

    var state = container.read(liveStackingProvider);
    expect(state.status, LiveStackingStatus.running);
    expect(state.errorMessage, contains('Failed to stop'));

    await notifier.stop();
    state = container.read(liveStackingProvider);
    expect(state.status, LiveStackingStatus.idle);
    verify(backend.stackingStop).called(2);
  });

  test(
    'remote per-filter start, reset, and stop keep the filter key',
    () async {
      final backend = _MockNetworkBackend();
      when(
        () => backend.stackingStart(
          referencePath: any(named: 'referencePath'),
          config: any(named: 'config'),
          filterKey: any(named: 'filterKey'),
        ),
      ).thenAnswer((_) async => const LiveStackingStats(stackedFrameCount: 1));
      when(
        () => backend.stackingGetResult(filterKey: any(named: 'filterKey')),
      ).thenAnswer(
        (_) async => const LiveStackingResult(
          width: 2,
          height: 2,
          data: [1, 2, 3, 4],
          stats: LiveStackingStats(stackedFrameCount: 1),
        ),
      );
      when(
        () => backend.stackingReset(filterKey: any(named: 'filterKey')),
      ).thenAnswer((_) async {});
      when(
        () => backend.stackingStop(filterKey: any(named: 'filterKey')),
      ).thenAnswer((_) async {});

      final container = _container(backend);
      final notifier = container.read(liveStackingProvider.notifier);
      await notifier.startFromFileForFilter('/subs/ha.fits', filterKey: 'Ha');
      await notifier.startFromFileForFilter(
        '/subs/oiii.fits',
        filterKey: 'OIII',
      );
      await notifier.resetFilter('Ha');
      await notifier.stopFilter('OIII');

      verify(
        () => backend.stackingStart(
          referencePath: '/subs/ha.fits',
          config: any(named: 'config'),
          filterKey: 'Ha',
        ),
      ).called(1);
      verify(
        () => backend.stackingStart(
          referencePath: '/subs/oiii.fits',
          config: any(named: 'config'),
          filterKey: 'OIII',
        ),
      ).called(1);
      verify(() => backend.stackingReset(filterKey: 'Ha')).called(1);
      verifyNever(() => backend.stackingReset());
      verify(() => backend.stackingStop(filterKey: 'OIII')).called(1);
      verifyNever(() => backend.stackingStop());
      expect(container.read(liveStackingProvider).availableFilters, ['Ha']);
      await notifier.stopFilter('Ha');
      verify(() => backend.stackingStop(filterKey: 'Ha')).called(1);
      verifyNever(() => backend.stackingStop());
      expect(
        container.read(liveStackingProvider).status,
        LiveStackingStatus.idle,
      );
    },
  );
}
