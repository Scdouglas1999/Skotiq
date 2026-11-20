import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

class _MultiFilterFakeStackingService implements LiveStackingService {
  final Map<String, int> frameCounts = {};
  final List<String> updatedConfigs = [];
  final List<String> resetFilters = [];
  final List<String> stoppedFilters = [];
  final List<String> ingestedPaths = [];
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
  Future<LiveStackingStats> startFromFileForFilter({
    required String filterKey,
    required String referenceImagePath,
    LiveStackingConfig config = const LiveStackingConfig(),
  }) async {
    frameCounts[filterKey] = 1;
    return _makeResult(filterKey, 1).stats;
  }

  @override
  Future<LiveStackingResult> addFrameFromFileForFilter(
    String imagePath, {
    required String filterKey,
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
      final next = (frameCounts[filterKey] ?? 0) + 1;
      frameCounts[filterKey] = next;
      return _makeResult(filterKey, next);
    } finally {
      inFlightAdds--;
    }
  }

  @override
  Future<LiveStackingResult> getCurrentResultForFilter(String filterKey) async {
    return _makeResult(filterKey, frameCounts[filterKey] ?? 1);
  }

  @override
  Future<LiveStackingStats> getStatsForFilter(String filterKey) async {
    return _makeResult(filterKey, frameCounts[filterKey] ?? 0).stats;
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
  Future<void> resetForFilter(String filterKey) async {
    resetFilters.add(filterKey);
    frameCounts[filterKey] = 0;
  }

  @override
  Future<void> stopForFilter(String filterKey) async {
    stoppedFilters.add(filterKey);
    frameCounts.remove(filterKey);
  }

  @override
  Future<void> stop() async {
    frameCounts.clear();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('Multi-filter live stacking, presets, and quality gates', () {
    test('arm + multi-filter feeds create independent sorted filter stacks',
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
    });

    test('HFR and minimum star count gates skip bad frames transparently',
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
        config: const LiveStackingConfig(
          maxHfrPx: 3.5,
          minStarCount: 20,
        ),
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
        starCount: 40,
      );
      await notifier.addFrameFromFileWithMetadata(
        '/subs/cloudy.fits',
        filter: 'L',
        hfr: 2.4,
        starCount: 6,
      );

      final state = container.read(liveStackingProvider);
      // Only the sharp frame reached the native stacker.
      expect(fakeService.frameCounts['L'], 1);
      expect(state.frameLog, hasLength(3));
      expect(state.frameLog[0].accepted, isFalse);
      expect(state.frameLog[0].rejectionReason, contains('star-count gate'));
      expect(state.frameLog[1].accepted, isFalse);
      expect(state.frameLog[1].rejectionReason, contains('HFR gate'));
      expect(state.frameLog[2].accepted, isTrue);
    });

    test('presets preserve OSC/filter routing and updateConfig pushes live',
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
      await notifier.addFrameFromFileWithMetadata('/subs/f1.fits', filter: 'L');
      notifier.updateConfig(strict);
      await Future<void>.delayed(Duration.zero);

      expect(fakeService.updatedConfigs, isNotEmpty);
      expect(fakeService.updatedConfigs.last, contains('1.2'));
    });

    test('resetFilter and stopFilter isolate a single filter slot', () async {
      final fakeService = _MultiFilterFakeStackingService();
      final container = ProviderContainer(
        overrides: [
          liveStackingServiceProvider.overrideWithValue(fakeService),
        ],
      );
      addTearDown(container.dispose);

      final notifier = container.read(liveStackingProvider.notifier);
      await notifier.arm();
      await notifier.addFrameFromFileWithMetadata('/subs/l1.fits', filter: 'L');
      await notifier.addFrameFromFileWithMetadata('/subs/h1.fits', filter: 'Ha');

      await notifier.resetFilter('Ha');
      expect(fakeService.resetFilters, ['Ha']);
      expect(
        container.read(liveStackingProvider).filterStacks['L']!.stats.stackedFrameCount,
        1,
      );
      expect(
        container.read(liveStackingProvider).filterStacks['Ha']!.stats.stackedFrameCount,
        0,
      );

      await notifier.stopFilter('Ha');
      expect(fakeService.stoppedFilters, ['Ha']);
      expect(container.read(liveStackingProvider).availableFilters, ['L']);
    });

    test(
      'serializes rapid frame bursts and reuses Uint16List zero-copy',
      () async {
        final fakeService = _MultiFilterFakeStackingService()
          ..addDelay = const Duration(milliseconds: 15);
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
        expect(identical(state.previewData, fakeService.lastReturnedPixels), isTrue);
      },
    );
  });
}
