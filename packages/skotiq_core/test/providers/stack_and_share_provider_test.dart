import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/database/database.dart' as db;
import 'package:skotiq_core/src/database/daos/stacked_results_dao.dart';
import 'package:skotiq_core/src/models/imaging/stack_and_share_models.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/stack_and_share_provider.dart';
import 'package:skotiq_core/src/services/live_stacking_service.dart';
import 'package:skotiq_core/src/services/stack_and_share_service.dart';

/// A controllable stand-in for [StackAndShareService] that drives the notifier
/// through a scripted sequence of progress events and a terminal outcome,
/// without touching the native stacker, the DAO chain, or the filesystem.
class _FakeStackAndShareService implements StackAndShareService {
  _FakeStackAndShareService({
    this.progressScript = const [],
    this.result,
    this.error,
    this.raw,
    this.rgba,
  });

  /// Progress events emitted (in order) before the terminal outcome.
  final List<StackAndShareProgress> progressScript;

  /// Result returned on success (required unless [error] is set).
  final StackAndShareResult? result;

  /// When non-null, [run] throws this instead of returning [result].
  final Object? error;

  /// Buffers the notifier should capture on success.
  final StackedRawResult? raw;
  final StackedRgbaResult? rgba;

  StackedRawResult? _lastRaw;
  StackedRgbaResult? _lastRgba;
  int runCount = 0;

  @override
  StackedRawResult? get lastRawResult => _lastRaw;

  @override
  StackedRgbaResult? get lastRgbaResult => _lastRgba;

  @override
  void retire() {}

  @override
  Future<StackAndShareResult> run({
    required int sessionId,
    required StackAndShareConfig config,
    void Function(StackAndShareProgress)? onProgress,
  }) async {
    runCount++;
    // Reference the call args so a misconfigured override surfaces loudly
    // rather than silently ignoring the session/config the notifier passed.
    assert(sessionId >= 0);
    assert(config.minQualityScore >= 0);
    _lastRaw = null;
    _lastRgba = null;

    for (final p in progressScript) {
      // Yield so the awaiting notifier observes each transition as a distinct
      // microtask, mirroring the real async service.
      await Future<void>.delayed(Duration.zero);
      onProgress?.call(p);
    }

    if (error != null) {
      throw error!;
    }

    onProgress?.call(
      const StackAndShareProgress(phase: StackAndSharePhase.complete),
    );
    _lastRaw = raw;
    _lastRgba = rgba;
    return result!;
  }
}

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

StackAndShareResult _result({int id = 42}) => StackAndShareResult(
  id: id,
  sessionId: 7,
  targetName: 'M51',
  width: 4,
  height: 2,
  framesStacked: 3,
  framesAttempted: 4,
  integrationSecs: 180,
  avgAlignmentResidual: 0.42,
  filter: 'L',
  createdAt: DateTime.utc(2026, 5, 28, 3),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('StackAndShareNotifier.runForSession', () {
    test(
      'streams idle -> selecting -> stacking -> complete and captures result',
      () async {
        final raw = StackedRawResult(
          width: 4,
          height: 2,
          data: Uint16List.fromList(List<int>.generate(8, (i) => i * 100)),
        );
        final rgba = StackedRgbaResult(
          width: 4,
          height: 2,
          rgba: Uint8List.fromList(List<int>.generate(32, (i) => i)),
        );
        final fake = _FakeStackAndShareService(
          progressScript: const [
            StackAndShareProgress(
              phase: StackAndSharePhase.selectingLights,
              framesTotal: 4,
            ),
            StackAndShareProgress(
              phase: StackAndSharePhase.stacking,
              framesTotal: 4,
              framesProcessed: 2,
            ),
          ],
          result: _result(),
          raw: raw,
          rgba: rgba,
        );

        final container = ProviderContainer(
          overrides: [stackAndShareServiceProvider.overrideWithValue(fake)],
        );
        addTearDown(container.dispose);

        // Keep the autoDispose notifier alive for the duration of the test.
        final sub = container.listen(stackAndShareProvider, (_, __) {});
        addTearDown(sub.close);

        final phases = <StackAndSharePhase>[];
        final phaseSub = container.listen<StackAndShareState>(
          stackAndShareProvider,
          (_, next) {
            phases.add(next.progress.phase);
          },
        );
        addTearDown(phaseSub.close);

        // Initial state is idle.
        expect(
          container.read(stackAndShareProvider).progress.phase,
          StackAndSharePhase.idle,
        );

        await container
            .read(stackAndShareProvider.notifier)
            .runForSession(7, config: StackAndShareConfig.defaults);

        final state = container.read(stackAndShareProvider);
        expect(state.progress.phase, StackAndSharePhase.complete);
        expect(state.isComplete, isTrue);
        expect(state.errorMessage, isNull);
        expect(state.result, equals(_result()));
        expect(state.resultWidth, 4);
        expect(state.resultHeight, 2);
        expect(state.resultMono, equals(raw.data));
        expect(state.resultRgba, equals(rgba.rgba));
        // A mono integration (StackedRawResult default channels == 1) must leave
        // the state's channel layout at mono.
        expect(state.resultChannels, 1);
        expect(state.isColorResult, isFalse);

        // The observed transitions go through selecting and stacking before
        // completing (the leading idle is the pre-run baseline).
        expect(phases, contains(StackAndSharePhase.selectingLights));
        expect(phases, contains(StackAndSharePhase.stacking));
        expect(phases.last, StackAndSharePhase.complete);
        // selecting must precede stacking which must precede complete.
        expect(
          phases.indexOf(StackAndSharePhase.selectingLights) <
              phases.indexOf(StackAndSharePhase.stacking),
          isTrue,
        );
        expect(
          phases.indexOf(StackAndSharePhase.stacking) <
              phases.lastIndexOf(StackAndSharePhase.complete),
          isTrue,
        );
      },
    );

    test(
      'color run carries channels==3 (interleaved RGB16) into state',
      () async {
        // A 2x2 OSC integration: interleaved RGB16 has width*height*3 samples.
        const width = 2;
        const height = 2;
        final raw = StackedRawResult(
          width: width,
          height: height,
          channels: 3,
          data: Uint16List.fromList(
            List<int>.generate(width * height * 3, (i) => i * 1000),
          ),
        );
        final rgba = StackedRgbaResult(
          width: width,
          height: height,
          rgba: Uint8List.fromList(
            List<int>.generate(width * height * 4, (i) => i),
          ),
        );
        final fake = _FakeStackAndShareService(
          progressScript: const [
            StackAndShareProgress(phase: StackAndSharePhase.stacking),
          ],
          result: _result(),
          raw: raw,
          rgba: rgba,
        );

        final container = ProviderContainer(
          overrides: [stackAndShareServiceProvider.overrideWithValue(fake)],
        );
        addTearDown(container.dispose);
        final sub = container.listen(stackAndShareProvider, (_, __) {});
        addTearDown(sub.close);

        await container.read(stackAndShareProvider.notifier).runForSession(7);

        final state = container.read(stackAndShareProvider);
        expect(state.isComplete, isTrue);
        expect(state.resultChannels, 3);
        expect(state.isColorResult, isTrue);
        expect(state.resultWidth, width);
        expect(state.resultHeight, height);
        // The interleaved RGB16 buffer is carried through verbatim (no flatten to
        // a mono plane), so its length is width*height*3.
        expect(state.resultMono, equals(raw.data));
        expect(state.resultMono, hasLength(width * height * 3));

        // reset() must drop the colour layout back to the mono default.
        container.read(stackAndShareProvider.notifier).reset();
        final afterReset = container.read(stackAndShareProvider);
        expect(afterReset.resultChannels, 1);
        expect(afterReset.isColorResult, isFalse);
      },
    );

    test('error path sets errorMessage and terminal error phase', () async {
      final fake = _FakeStackAndShareService(
        progressScript: const [
          StackAndShareProgress(phase: StackAndSharePhase.selectingLights),
        ],
        error: const LiveStackBusyException(
          'Stop live stacking before running Stack-and-Share',
        ),
      );

      final container = ProviderContainer(
        overrides: [stackAndShareServiceProvider.overrideWithValue(fake)],
      );
      addTearDown(container.dispose);
      final sub = container.listen(stackAndShareProvider, (_, __) {});
      addTearDown(sub.close);

      await container.read(stackAndShareProvider.notifier).runForSession(7);

      final state = container.read(stackAndShareProvider);
      expect(state.hasError, isTrue);
      expect(state.progress.phase, StackAndSharePhase.error);
      expect(state.result, isNull);
      expect(state.resultMono, isNull);
      expect(state.resultRgba, isNull);
      expect(state.errorMessage, contains('Stop live stacking'));
    });

    test(
      'mounted guard: disposing mid-run leaves no late state mutation',
      () async {
        // A service that completes only after we have torn the container down.
        final fake = _FakeStackAndShareService(
          progressScript: const [
            StackAndShareProgress(phase: StackAndSharePhase.selectingLights),
            StackAndShareProgress(phase: StackAndSharePhase.stacking),
          ],
          result: _result(),
          raw: StackedRawResult(width: 4, height: 2, data: Uint16List(8)),
        );

        final container = ProviderContainer(
          overrides: [stackAndShareServiceProvider.overrideWithValue(fake)],
        );
        final notifier = container.read(stackAndShareProvider.notifier);

        // Start the run but do NOT await it; dispose the notifier immediately so
        // its `mounted` becomes false while the fake's awaits are still pending.
        final future = notifier.runForSession(7);
        container.dispose();

        // The run must complete without throwing a "used after dispose" error;
        // the mounted guards swallow the late `state =` writes.
        await expectLater(future, completes);
      },
    );

    test('reset returns to idle and clears result + buffers', () async {
      final fake = _FakeStackAndShareService(
        result: _result(),
        raw: StackedRawResult(width: 4, height: 2, data: Uint16List(8)),
      );
      final container = ProviderContainer(
        overrides: [stackAndShareServiceProvider.overrideWithValue(fake)],
      );
      addTearDown(container.dispose);
      final sub = container.listen(stackAndShareProvider, (_, __) {});
      addTearDown(sub.close);

      await container.read(stackAndShareProvider.notifier).runForSession(7);
      expect(container.read(stackAndShareProvider).isComplete, isTrue);

      container.read(stackAndShareProvider.notifier).reset();
      final state = container.read(stackAndShareProvider);
      expect(state.progress.phase, StackAndSharePhase.idle);
      expect(state.result, isNull);
      expect(state.resultMono, isNull);
      expect(state.resultRgba, isNull);
      expect(state.errorMessage, isNull);
    });

    test(
      'remote mode refuses the local pipeline before invoking its service',
      () async {
        final backend = _MockNetworkBackend();
        final fake = _FakeStackAndShareService(result: _result());
        final container = ProviderContainer(
          overrides: [
            backendProvider.overrideWith(
              (ref) => _FixedBackendNotifier(ref, backend),
            ),
            stackAndShareServiceProvider.overrideWithValue(fake),
          ],
        );
        addTearDown(container.dispose);

        await container.read(stackAndShareProvider.notifier).runForSession(7);

        expect(fake.runCount, 0);
        final state = container.read(stackAndShareProvider);
        expect(state.progress.phase, StackAndSharePhase.error);
        expect(state.errorMessage, contains('imaging host'));
      },
    );
  });

  group('stackResultViewerProvider / recentStackedResultsProvider', () {
    late db.SkotiqDatabase database;
    late ProviderContainer container;

    setUp(() {
      database = db.SkotiqDatabase.forTesting(NativeDatabase.memory());
      container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(database)],
      );
    });

    tearDown(() async {
      container.dispose();
      await database.close();
    });

    test('stackResultViewerProvider loads a persisted result by id', () async {
      final dao = container.read(stackedResultsDaoProvider);
      final id = await dao.insertResult(
        StackAndShareResult(
          sessionId: 7,
          targetName: 'M81',
          width: 100,
          height: 80,
          framesStacked: 5,
          framesAttempted: 6,
          integrationSecs: 300,
          avgAlignmentResidual: 0.3,
          filter: 'Ha',
          createdAt: DateTime.utc(2026, 5, 27, 22),
        ),
      );

      final loaded = await container.read(stackResultViewerProvider(id).future);
      expect(loaded.id, id);
      expect(loaded.targetName, 'M81');
      expect(loaded.filter, 'Ha');
      expect(loaded.width, 100);
    });

    test(
      'stackResultViewerProvider throws StateError for an unknown id',
      () async {
        await expectLater(
          container.read(stackResultViewerProvider(999999).future),
          throwsStateError,
        );
      },
    );

    test('recentStackedResultsProvider returns rows newest first', () async {
      final dao = container.read(stackedResultsDaoProvider);
      await dao.insertResult(
        StackAndShareResult(
          targetName: 'Older',
          width: 10,
          height: 10,
          framesStacked: 1,
          framesAttempted: 1,
          integrationSecs: 60,
          avgAlignmentResidual: 0,
          createdAt: DateTime.utc(2026, 5, 1),
          stats: const LiveStackingStats(),
        ),
      );
      await dao.insertResult(
        StackAndShareResult(
          targetName: 'Newer',
          width: 10,
          height: 10,
          framesStacked: 1,
          framesAttempted: 1,
          integrationSecs: 60,
          avgAlignmentResidual: 0,
          createdAt: DateTime.utc(2026, 5, 20),
          stats: const LiveStackingStats(),
        ),
      );

      final recent = await container.read(recentStackedResultsProvider.future);
      expect(recent, hasLength(2));
      expect(recent.first.targetName, 'Newer');
      expect(recent.last.targetName, 'Older');
    });
  });

  group('remote result authority', () {
    late ProviderContainer container;
    late _MockNetworkBackend backend;
    late RemoteStackedResult record;

    setUp(() {
      backend = _MockNetworkBackend();
      record = RemoteStackedResult(
        result: StackAndShareResult(
          id: 1,
          sessionId: 7,
          targetName: 'Remote M81',
          width: 2,
          height: 1,
          framesStacked: 5,
          framesAttempted: 6,
          integrationSecs: 300,
          avgAlignmentResidual: 0.3,
          isColor: true,
          channels: 3,
          createdAt: DateTime.utc(2026, 5, 27, 22),
        ),
        previewAvailable: true,
      );
      when(
        () => backend.stackingGetSavedResult(1),
      ).thenAnswer((_) async => record);
      when(
        () => backend.stackingGetSavedResults(),
      ).thenAnswer((_) async => [record]);
      final preview = img.Image(width: 2, height: 1);
      preview.setPixelRgba(0, 0, 1, 2, 3, 255);
      preview.setPixelRgba(1, 0, 4, 5, 6, 255);
      when(
        () => backend.stackingGetSavedResultPreview(1),
      ).thenAnswer((_) async => Uint8List.fromList(img.encodePng(preview)));
      container = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
        ],
      );
    });

    tearDown(() => container.dispose());

    test(
      'result detail reads host metadata without a controller database',
      () async {
        final result = await container.read(
          stackResultViewerProvider(1).future,
        );
        expect(result, record.result);
        verify(() => backend.stackingGetSavedResult(1)).called(1);
      },
    );

    test(
      'result history reads the host rather than controller-local rows',
      () async {
        final results = await container.read(
          recentStackedResultsProvider.future,
        );
        expect(results, [record.result]);
        verify(() => backend.stackingGetSavedResults()).called(1);
      },
    );

    test(
      'remote preview decodes PNG bytes and validates the host dimensions',
      () async {
        final rgba = await container.read(stackResultPreviewProvider(1).future);
        expect(rgba, <int>[1, 2, 3, 255, 4, 5, 6, 255]);
        verify(() => backend.stackingGetSavedResultPreview(1)).called(1);
      },
    );
  });
}
