import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

class _MultiFilterFakeStackingService implements LiveStackingService {
  @override
  bool get readsHost => false;

  final Map<String, int> frameCounts = {};
  final List<String> updatedConfigs = [];
  final List<String> resetFilters = [];
  final List<String> stoppedFilters = [];
  final List<String> ingestedPaths = [];
  int stopCalls = 0;
  int resetCalls = 0;
  Object? stopError;
  Object? resetError;
  Completer<void>? startGate;
  Uint16List? lastReturnedPixels;
  int inFlightAdds = 0;
  int maxConcurrentAdds = 0;
  Duration addDelay = Duration.zero;

  LiveStackingResult _makeResult(String filterKey, int frames) {
    final pixels = Uint16List(16)..fillRange(0, 16, 1000 + frames * 100);
    lastReturnedPixels = pixels;
    return LiveStackingResult(
      width: 4,
      height: 4,
      channels: 1,
      data: pixels,
      filterKey: filterKey,
      revision: frames,
      stats: LiveStackingStats(
        stackedFrameCount: frames,
        totalFramesAttempted: frames,
        avgMatchedPairs: frames > 1 ? 24.0 : 0.0,
        avgAlignmentResidual: frames > 1 ? 0.42 : 0.0,
        totalIntegrationSecs: frames * 60.0,
      ),
      lastEvent: LiveStackFrameEvent(
        sequenceIndex: frames,
        filterKey: filterKey,
        sourceLabel: '${filterKey}_$frames.fits',
        accepted: true,
        detectedStars: 40,
        matchedPairs: 24,
        inlierPairs: 22,
        alignmentResidualPx: frames > 1 ? 0.42 : 0.0,
        shiftXPx: frames > 1 ? 1.2 : 0.0,
        shiftYPx: frames > 1 ? -0.6 : 0.0,
        rotationDeg: 0.02,
        exposureSecs: 60.0,
        timestamp: DateTime.utc(2026, 11, 19, 21, 0, frames),
      ),
    );
  }

  @override
  Future<void> updateLiveConfig(
    LiveStackingConfig config, {
    String? filterKey,
  }) async {
    updatedConfigs.add(
      '${filterKey ?? "all"}:${config.sigmaClipThreshold}:${config.maxAlignmentResidualPx}',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  Future<LiveStackingStats> start({
    String? referenceImagePath,
    LiveStackingConfig config = const LiveStackingConfig(),
    String? filterKey,
  }) async {
    final gate = startGate;
    if (gate != null) await gate.future;
    frameCounts[filterKey!] = 1;
    return _makeResult(filterKey, 1).stats;
  }

  @override
  Future<LiveStackingStats> startFromData({
    required int width,
    required int height,
    required List<int> data,
    double pedestal = 0.0,
    LiveStackingConfig config = const LiveStackingConfig(),
    String? filterKey,
  }) async {
    frameCounts[filterKey!] = 1;
    return _makeResult(filterKey, 1).stats;
  }

  @override
  Future<LiveStackingResult> addFrameFromFile(
    String imagePath, {
    String? filterKey,
  }) async {
    inFlightAdds++;
    if (inFlightAdds > maxConcurrentAdds) {
      maxConcurrentAdds = inFlightAdds;
    }
    try {
      if (addDelay > Duration.zero) {
        await Future<void>.delayed(addDelay);
      }
      ingestedPaths.add(imagePath);
      final next = (frameCounts[filterKey!] ?? 0) + 1;
      frameCounts[filterKey] = next;
      return _makeResult(filterKey, next);
    } finally {
      inFlightAdds--;
    }
  }

  @override
  Future<LiveStackingResult> getCurrentResult({String? filterKey}) async {
    return _makeResult(filterKey!, frameCounts[filterKey] ?? 1);
  }

  @override
  Future<LiveStackingStats> getStats({String? filterKey}) async {
    return _makeResult(filterKey!, frameCounts[filterKey] ?? 0).stats;
  }

  @override
  Future<void> reset({String? filterKey}) async {
    if (filterKey != null) {
      final error = resetError;
      if (error != null) throw error;
      resetFilters.add(filterKey);
      frameCounts[filterKey] = 0;
      return;
    }
    resetCalls++;
    frameCounts.clear();
  }

  @override
  Future<void> stop({String? filterKey}) async {
    if (filterKey != null) {
      stoppedFilters.add(filterKey);
      frameCounts.remove(filterKey);
      return;
    }
    stopCalls++;
    final error = stopError;
    if (error != null) throw error;
    // The native engine rejects stop when no slot was ever opened.
    if (frameCounts.isEmpty) {
      throw StateError('Live stacker not initialized');
    }
    frameCounts.clear();
  }
}

void main() {
  group('Multi-filter live stacking, presets, and quality gates', () {
    test('arm then stop with zero frames disarms', () async {
      final fakeService = _MultiFilterFakeStackingService();
      final container = ProviderContainer(
        overrides: [liveStackingServiceProvider.overrideWithValue(fakeService)],
      );
      addTearDown(container.dispose);

      final notifier = container.read(liveStackingProvider.notifier);
      await notifier.arm();
      await notifier.stop();

      final state = container.read(liveStackingProvider);
      expect(fakeService.stopCalls, 1);
      expect(state.status, LiveStackingStatus.idle);
      expect(state.isArmed, isFalse);
      expect(state.errorMessage, isNull);
    });

    test('a stop failure other than an empty stack stays armed', () async {
      final fakeService = _MultiFilterFakeStackingService()
        ..stopError = StateError('disk full');
      final container = ProviderContainer(
        overrides: [liveStackingServiceProvider.overrideWithValue(fakeService)],
      );
      addTearDown(container.dispose);

      final notifier = container.read(liveStackingProvider.notifier);
      await notifier.arm();
      await notifier.stop();

      final state = container.read(liveStackingProvider);
      expect(state.status, LiveStackingStatus.running);
      expect(state.isArmed, isTrue);
      expect(state.errorMessage, contains('disk full'));
    });

    test('a failed ingest step does not strand the next one', () async {
      final fakeService = _MultiFilterFakeStackingService()
        ..resetError = _UnrenderableError();
      final container = ProviderContainer(
        overrides: [liveStackingServiceProvider.overrideWithValue(fakeService)],
      );
      addTearDown(container.dispose);

      final notifier = container.read(liveStackingProvider.notifier);
      await notifier.arm();
      await notifier.addFrameFromFileWithMetadata('/subs/l1.fits', filter: 'L');
      await notifier.addFrameFromFileWithMetadata(
        '/subs/h1.fits',
        filter: 'Ha',
      );

      await notifier.resetFilter('Ha');
      fakeService.resetError = null;
      await notifier.resetFilter('L').timeout(const Duration(seconds: 2));

      expect(fakeService.resetFilters, ['L']);
      expect(
        container
            .read(liveStackingProvider)
            .filterStacks['L']!
            .stats
            .stackedFrameCount,
        0,
      );
    });

    test(
      'arm + multi-filter feeds create independent sorted filter stacks',
      () async {
        final fakeService = _MultiFilterFakeStackingService();
        final container = ProviderContainer(
          overrides: [
            liveStackingServiceProvider.overrideWithValue(fakeService),
          ],
        );
        addTearDown(container.dispose);

        final notifier = container.read(liveStackingProvider.notifier);
        await notifier.arm();

        expect(container.read(liveStackingProvider).isArmed, isTrue);
        expect(
          container.read(liveStackingProvider).status,
          LiveStackingStatus.running,
        );

        // Feed frames across OIII, L, Ha — order of arrival intentionally unsorted.
        await notifier.addFrameFromFileWithMetadata(
          '/subs/oiii_1.fits',
          filter: 'OIII',
          exposureSecs: 300,
        );
        await notifier.addFrameFromFileWithMetadata(
          '/subs/l_1.fits',
          filter: 'L',
          exposureSecs: 60,
        );
        await notifier.addFrameFromFileWithMetadata(
          '/subs/l_2.fits',
          filter: 'L',
          exposureSecs: 60,
        );
        await notifier.addFrameFromFileWithMetadata(
          '/subs/ha_1.fits',
          filter: 'Ha',
          exposureSecs: 300,
        );

        final state = container.read(liveStackingProvider);
        // Canonical astrophotography order: L before Ha before OIII.
        expect(state.availableFilters, ['L', 'Ha', 'OIII']);
        expect(state.filterStacks['L']!.stats.stackedFrameCount, 2);
        expect(state.filterStacks['Ha']!.stats.stackedFrameCount, 1);
        expect(state.filterStacks['OIII']!.stats.stackedFrameCount, 1);
        expect(state.totalFramesAcrossFilters, 4);
        expect(state.frameLog, hasLength(4));

        // First filter started was OIII, so it is initially selected.
        expect(state.selectedFilterKey, 'OIII');

        // Switching to L mirrors L's preview and stats onto top-level state.
        notifier.selectFilter('L');
        final switched = container.read(liveStackingProvider);
        expect(switched.selectedFilterKey, 'L');
        expect(switched.stats.stackedFrameCount, 2);
        expect(switched.referenceImagePath, '/subs/l_1.fits');
      },
    );

    test(
      'HFR and minimum star count gates skip bad frames transparently',
      () async {
        final fakeService = _MultiFilterFakeStackingService();
        final container = ProviderContainer(
          overrides: [
            liveStackingServiceProvider.overrideWithValue(fakeService),
          ],
        );
        addTearDown(container.dispose);

        final notifier = container.read(liveStackingProvider.notifier);
        await notifier.arm(
          config: const LiveStackingConfig(maxHfrPx: 3.5, minStarCount: 20),
        );

        await notifier.addFrameFromFileWithMetadata(
          '/subs/sharp.fits',
          filter: 'L',
          hfr: 2.1,
          starCount: 45,
        );
        await notifier.addFrameFromFileWithMetadata(
          '/subs/blurry.fits',
          filter: 'L',
          hfr: 4.8,
        );
        await notifier.addFrameFromFileWithMetadata(
          '/subs/cloudy.fits',
          filter: 'L',
          hfr: 2.4,
          starCount: 6,
        );

        final state = container.read(liveStackingProvider);
        expect(
          state.frameLog
              .firstWhere((e) => e.sourceLabel == 'blurry.fits')
              .detectedStars,
          isNull,
        );
        expect(
          state.frameLog
              .firstWhere((e) => e.sourceLabel == 'cloudy.fits')
              .detectedStars,
          6,
        );
        // Only the sharp frame reached the native stacker.
        expect(fakeService.frameCounts['L'], 1);
        expect(state.frameLog, hasLength(3));
        expect(state.frameLog[0].accepted, isFalse);
        expect(state.frameLog[0].rejectionReason, contains('star-count gate'));
        expect(state.frameLog[1].accepted, isFalse);
        expect(state.frameLog[1].rejectionReason, contains('HFR gate'));
        expect(state.frameLog[2].accepted, isTrue);
      },
    );

    test(
      'presets preserve OSC/filter routing and updateConfig pushes live',
      () async {
        final fakeService = _MultiFilterFakeStackingService();
        final container = ProviderContainer(
          overrides: [
            liveStackingServiceProvider.overrideWithValue(fakeService),
          ],
        );
        addTearDown(container.dispose);

        final notifier = container.read(liveStackingProvider.notifier);
        const base = LiveStackingConfig(
          sensorMode: 'osc',
          bayerPattern: 'RGGB',
          separateByFilter: false,
        );
        final strict = LiveStackingPreset.strictQuality.applyTo(base);
        expect(strict.sensorMode, 'osc');
        expect(strict.bayerPattern, 'RGGB');
        expect(strict.separateByFilter, isFalse);
        expect(strict.maxAlignmentResidualPx, 1.2);
        expect(strict.matchedPreset, LiveStackingPreset.strictQuality);

        await notifier.arm(config: base);
        await notifier.addFrameFromFileWithMetadata(
          '/subs/f1.fits',
          filter: 'L',
        );
        notifier.updateConfig(strict);
        await Future<void>.delayed(Duration.zero);

        expect(fakeService.updatedConfigs, isNotEmpty);
        expect(fakeService.updatedConfigs.last, contains('1.2'));
      },
    );

    test('resetFilter and stopFilter isolate a single filter slot', () async {
      final fakeService = _MultiFilterFakeStackingService();
      final container = ProviderContainer(
        overrides: [liveStackingServiceProvider.overrideWithValue(fakeService)],
      );
      addTearDown(container.dispose);

      final notifier = container.read(liveStackingProvider.notifier);
      await notifier.arm();
      await notifier.addFrameFromFileWithMetadata('/subs/l1.fits', filter: 'L');
      await notifier.addFrameFromFileWithMetadata(
        '/subs/h1.fits',
        filter: 'Ha',
      );

      await notifier.resetFilter('Ha');
      expect(fakeService.resetFilters, ['Ha']);
      expect(
        container
            .read(liveStackingProvider)
            .filterStacks['L']!
            .stats
            .stackedFrameCount,
        1,
      );
      expect(
        container
            .read(liveStackingProvider)
            .filterStacks['Ha']!
            .stats
            .stackedFrameCount,
        0,
      );

      await notifier.stopFilter('Ha');
      expect(fakeService.stoppedFilters, ['Ha']);
      expect(container.read(liveStackingProvider).availableFilters, ['L']);
    });

    test('serializes rapid frame bursts and reuses Uint16List zero-copy', () async {
      final fakeService = _MultiFilterFakeStackingService()
        ..addDelay = const Duration(milliseconds: 15);
      final container = ProviderContainer(
        overrides: [liveStackingServiceProvider.overrideWithValue(fakeService)],
      );
      addTearDown(container.dispose);

      final notifier = container.read(liveStackingProvider.notifier);
      await notifier.arm();
      await notifier.addFrameFromFileWithMetadata('/subs/l1.fits', filter: 'L');

      // Fire 3 frames concurrently without awaiting between them.
      await Future.wait(<Future<void>>[
        notifier.addFrameFromFileWithMetadata('/subs/l2.fits', filter: 'L'),
        notifier.addFrameFromFileWithMetadata('/subs/l3.fits', filter: 'L'),
        notifier.addFrameFromFileWithMetadata('/subs/l4.fits', filter: 'L'),
      ]);

      // Never overlaps concurrent heavy FITS reads/stacks, preserves exact order.
      expect(fakeService.maxConcurrentAdds, 1);
      expect(fakeService.ingestedPaths, [
        '/subs/l2.fits',
        '/subs/l3.fits',
        '/subs/l4.fits',
      ]);
      final state = container.read(liveStackingProvider);
      expect(state.stats.stackedFrameCount, 4);
      // Zero-copy Uint16List handoff (same buffer instance, no UI-thread copy).
      expect(
        identical(state.previewData, fakeService.lastReturnedPixels),
        isTrue,
      );
    });

    test(
      'stop() racing an in-flight armed frame start still releases the native stacker',
      () async {
        final gate = Completer<void>();
        final fakeService = _MultiFilterFakeStackingService()..startGate = gate;
        final container = ProviderContainer(
          overrides: [
            liveStackingServiceProvider.overrideWithValue(fakeService),
          ],
        );
        addTearDown(container.dispose);

        final notifier = container.read(liveStackingProvider.notifier);
        await notifier.arm();
        final ingestFuture = notifier.addFrameFromFileWithMetadata(
          '/subs/ha_1.fits',
          filter: 'Ha',
        );
        // Let the ingest enter startFromFileForFilter and block on `gate`.
        await Future<void>.delayed(const Duration(milliseconds: 10));

        final stopFuture = notifier.stop();
        gate.complete();
        await Future.wait([ingestFuture, stopFuture]);

        expect(fakeService.stopCalls, 1);
        expect(fakeService.frameCounts, isEmpty);
        expect(
          container.read(liveStackingProvider).status,
          LiveStackingStatus.idle,
        );
      },
    );

    test(
      'reset() on a single named filter calls resetForFilter instead of default reset',
      () async {
        final fakeService = _MultiFilterFakeStackingService();
        final container = ProviderContainer(
          overrides: [
            liveStackingServiceProvider.overrideWithValue(fakeService),
          ],
        );
        addTearDown(container.dispose);

        final notifier = container.read(liveStackingProvider.notifier);
        await notifier.arm();
        await notifier.addFrameFromFileWithMetadata(
          '/subs/ha1.fits',
          filter: 'Ha',
        );
        await notifier.reset();

        expect(fakeService.resetFilters, ['Ha']);
        expect(fakeService.resetCalls, 0);
      },
    );

    test(
      'stopFilter serializes after in-flight ingest and normalizes untrimmed filter keys',
      () async {
        final fakeService = _MultiFilterFakeStackingService()
          ..addDelay = const Duration(milliseconds: 25);
        final container = ProviderContainer(
          overrides: [
            liveStackingServiceProvider.overrideWithValue(fakeService),
          ],
        );
        addTearDown(container.dispose);

        final notifier = container.read(liveStackingProvider.notifier);
        await notifier.arm();
        await notifier.addFrameFromFileWithMetadata(
          '/subs/l1.fits',
          filter: 'L',
        );
        await notifier.addFrameFromFileWithMetadata(
          '/subs/h1.fits',
          filter: 'Ha',
        );

        // Start ingesting Ha frame 2, then immediately stop Ha with spaces.
        final addFuture = notifier.addFrameFromFileWithMetadata(
          '/subs/h2.fits',
          filter: 'Ha',
        );
        final stopFuture = notifier.stopFilter(' Ha ');
        await Future.wait([addFuture, stopFuture]);

        expect(fakeService.stoppedFilters, ['Ha']);
        expect(
          container.read(liveStackingProvider).filterStacks.containsKey('Ha'),
          isFalse,
        );
        expect(container.read(liveStackingProvider).availableFilters, ['L']);
      },
    );

    test(
      'startFromData for a second filter preserves existing filter stacks',
      () async {
        final fakeService = _MultiFilterFakeStackingService();
        final container = ProviderContainer(
          overrides: [
            liveStackingServiceProvider.overrideWithValue(fakeService),
          ],
        );
        addTearDown(container.dispose);

        final notifier = container.read(liveStackingProvider.notifier);
        await notifier.startFromData(
          filterKey: 'Ha',
          width: 4,
          height: 4,
          data: List<int>.filled(16, 1000),
          pedestal: 0.0,
        );
        await notifier.startFromData(
          filterKey: 'OIII',
          width: 4,
          height: 4,
          data: List<int>.filled(16, 2000),
          pedestal: 0.0,
        );

        final state = container.read(liveStackingProvider);
        expect(state.availableFilters, ['Ha', 'OIII']);
        expect(state.filterStacks['Ha']!.stats.stackedFrameCount, 1);
        expect(state.filterStacks['OIII']!.stats.stackedFrameCount, 1);
      },
    );

    test(
      'LiveStackingService does not touch local native stacker when remote',
      () async {
        final remote = _DummyHostLiveStack();
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final service = container.read(
          Provider(
            (ref) => LinkedLiveStackingService(
              ref.read(loggingServiceProvider),
              remote,
            ),
          ),
        );

        expect(service.isActive, isFalse);
        expect(service.frameCount, 0);
        await expectLater(
          () => service.renderStackPreviewRgba(filterKey: 'L'),
          throwsA(isA<StateError>()),
        );
      },
    );
  });
}

/// Rendering this error throws, which is how a step's own failure report
/// escapes the step.
class _UnrenderableError implements Exception {
  @override
  String toString() => throw StateError('unrenderable');
}

class _DummyHostLiveStack implements HostLiveStack {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
