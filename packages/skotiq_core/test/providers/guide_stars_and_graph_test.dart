// Provider tests for the built-in multi-star guider's UI data path
// (Phase F, guider-ui):
//
//   1. guideGraphProvider — the SAME graph the PHD2 path uses must populate for
//      the internal guider too. The internal guider publishes `Correction`
//      events, which the backend maps to `GuideStep` (RADistanceRaw /
//      DECDistanceRaw). This test pins that a GuideStep event flows into
//      `guideGraphProvider` as a graph point, so the panel graph is no longer
//      empty under the internal guider.
//
//   2. guideStarsProvider — polls the guiding status (which now carries the
//      per-star `trackedStars` list) while the internal guider is looping/
//      guiding, and exposes the list to the star-list UI. It must stay empty
//      for PHD2 (which reports no per-star list).

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

const _builtinGuiderId = 'native:builtin_guider:multi_star';

ProviderContainer _container(SkotiqBackend backend) {
  final container = ProviderContainer(
    overrides: [
      backendProvider.overrideWith(
        (ref) => _FixedBackendNotifier(ref, backend),
      ),
      loggingServiceProvider.overrideWithValue(LoggingService()),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// A guiding `GuideStep`-equivalent event (the internal guider's `Correction`
/// maps to this on both transports).
SkotiqEvent _guideStepEvent({required double ra, required double dec}) {
  return SkotiqEvent(
    severity: EventSeverity.info,
    category: EventCategory.guiding,
    eventType: 'GuideStep',
    data: {'RADistanceRaw': ra, 'DECDistanceRaw': dec},
    timestamp: DateTime.now().millisecondsSinceEpoch,
  );
}

void main() {
  setUpAll(() {
    registerFallbackValue(const Stream<SkotiqEvent>.empty());
  });

  group('guideGraphProvider (shared graph)', () {
    test('a GuideStep event adds a point with the mapped RA/Dec', () async {
      final controller = StreamController<SkotiqEvent>.broadcast();
      addTearDown(controller.close);

      final backend = _MockNetworkBackend();
      when(() => backend.eventStream).thenAnswer((_) => controller.stream);

      final container = _container(backend);

      // Materialize the provider so its event binding subscribes.
      expect(container.read(guideGraphProvider), isEmpty);

      controller.add(_guideStepEvent(ra: 1.5, dec: -0.75));
      await Future<void>.delayed(Duration.zero);

      final points = container.read(guideGraphProvider);
      expect(points, hasLength(1));
      expect(points.single.ra, 1.5);
      expect(points.single.dec, -0.75);
    });

    test('GuidingStopped clears the graph', () async {
      final controller = StreamController<SkotiqEvent>.broadcast();
      addTearDown(controller.close);

      final backend = _MockNetworkBackend();
      when(() => backend.eventStream).thenAnswer((_) => controller.stream);

      final container = _container(backend);
      container.read(guideGraphProvider);

      controller.add(_guideStepEvent(ra: 1.0, dec: 1.0));
      await Future<void>.delayed(Duration.zero);
      expect(container.read(guideGraphProvider), hasLength(1));

      controller.add(
        SkotiqEvent(
          severity: EventSeverity.info,
          category: EventCategory.guiding,
          eventType: 'GuidingStopped',
          data: const {},
          timestamp: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(container.read(guideGraphProvider), isEmpty);
    });
  });

  group('guideStatsProvider (per-axis peak)', () {
    // The RA/Dec Peak tiles in the guiding panel read
    // Phd2GuideStats.peakRa/peakDec, so _handleGuideStep must populate them —
    // an omitted field defaults to 0.0 and the tiles render 0.00 forever.
    // This drives the REAL GuideStatsNotifier through GuideStep events (no
    // seeded override) and asserts the peak is the worst single-frame absolute
    // excursion over the rolling window.
    test(
      'GuideStep events populate per-axis peak from the rolling window',
      () async {
        final controller = StreamController<SkotiqEvent>.broadcast();
        addTearDown(controller.close);

        final backend = _MockNetworkBackend();
        when(() => backend.eventStream).thenAnswer((_) => controller.stream);

        final container = _container(backend);

        // Materialize the provider so its event binding subscribes.
        final initial = container.read(guideStatsProvider);
        expect(initial.peakRa, 0.0);
        expect(initial.peakDec, 0.0);

        // Feed a sequence whose worst absolute excursion is unambiguous and
        // includes a negative spike (peak must be |value|, not the signed max).
        controller.add(_guideStepEvent(ra: 0.5, dec: -0.2));
        controller.add(_guideStepEvent(ra: -2.5, dec: 0.4));
        controller.add(_guideStepEvent(ra: 1.0, dec: -1.8));
        await Future<void>.delayed(Duration.zero);

        final stats = container.read(guideStatsProvider);
        // Worst |RA| = 2.5 (from the -2.5 spike); worst |Dec| = 1.8.
        expect(
          stats.peakRa,
          closeTo(2.5, 1e-9),
          reason: 'peakRa must be the max absolute RA excursion in the window.',
        );
        expect(
          stats.peakDec,
          closeTo(1.8, 1e-9),
          reason: 'peakDec must be the max absolute Dec excursion.',
        );
      },
    );

    test('a GuideStats SNR update preserves the accumulated peak', () async {
      final controller = StreamController<SkotiqEvent>.broadcast();
      addTearDown(controller.close);

      final backend = _MockNetworkBackend();
      when(() => backend.eventStream).thenAnswer((_) => controller.stream);

      final container = _container(backend);
      container.read(guideStatsProvider);

      controller.add(_guideStepEvent(ra: -3.0, dec: 2.0));
      await Future<void>.delayed(Duration.zero);
      expect(container.read(guideStatsProvider).peakRa, closeTo(3.0, 1e-9));

      // A standalone GuideStats event (SNR/StarMass) must not wipe the peak.
      controller.add(
        SkotiqEvent(
          severity: EventSeverity.info,
          category: EventCategory.guiding,
          eventType: 'GuideStats',
          data: const {'SNR': 22.0, 'StarMass': 5000.0},
          timestamp: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      final stats = container.read(guideStatsProvider);
      expect(stats.snr, 22.0);
      expect(
        stats.peakRa,
        closeTo(3.0, 1e-9),
        reason: 'peak must survive an interleaved SNR-only update.',
      );
      expect(stats.peakDec, closeTo(2.0, 1e-9));
    });
  });

  group('guideStarsProvider (internal multi-star list)', () {
    test(
      'populates from status poll when the built-in guider is looping',
      () async {
        final backend = _MockNetworkBackend();
        when(
          () => backend.eventStream,
        ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
        when(() => backend.phd2GetStatus()).thenAnswer(
          (_) async => const Phd2Status(
            state: 'Guiding',
            connected: true,
            trackedStars: [
              GuideStar(
                id: 0,
                x: 10,
                y: 12,
                snr: 18,
                isLock: true,
                residual: 0.4,
              ),
              GuideStar(id: 1, x: 60, y: 64, snr: 9, residual: 0.9),
            ],
          ),
        );

        final container = _container(backend);

        // Mark the built-in guider as the active, connected guider.
        container.read(guiderStateProvider.notifier)
          ..setConnecting(_builtinGuiderId)
          ..setConnected();
        // Materialize the provider so its listeners attach before we drive state.
        container.read(guideStarsProvider);
        expect(container.read(isBuiltinGuiderProvider), isTrue);

        // Looping/Guiding triggers the immediate poll.
        container.read(phd2StateProvider.notifier).state = Phd2State.guiding;
        await Future<void>.delayed(const Duration(milliseconds: 10));

        final stars = container.read(guideStarsProvider);
        expect(stars, hasLength(2));
        expect(stars.first.isLock, isTrue);
        expect(stars.first.residual, 0.4);
        expect(stars[1].snr, 9);
      },
    );

    test('stays empty for PHD2 (no per-star list) and never polls', () async {
      final backend = _MockNetworkBackend();
      when(
        () => backend.eventStream,
      ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
      when(() => backend.phd2GetStatus()).thenAnswer(
        (_) async => const Phd2Status(state: 'Guiding', connected: true),
      );

      final container = _container(backend);

      // PHD2 guider — NOT the built-in id.
      container.read(guiderStateProvider.notifier)
        ..setConnecting('phd2_guider')
        ..setConnected();
      container.read(guideStarsProvider);
      expect(container.read(isBuiltinGuiderProvider), isFalse);

      container.read(phd2StateProvider.notifier).state = Phd2State.guiding;
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(container.read(guideStarsProvider), isEmpty);
      verifyNever(() => backend.phd2GetStatus());
    });

    test('setStars seeds the list (UI/test hook)', () async {
      final backend = _MockNetworkBackend();
      when(
        () => backend.eventStream,
      ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());

      final container = _container(backend);
      container.read(guideStarsProvider.notifier).setStars(const [
        GuideStar(id: 0, x: 1, y: 2, snr: 5, isLock: true),
      ]);

      expect(container.read(guideStarsProvider), hasLength(1));
      expect(container.read(guideStarsProvider).single.isLock, isTrue);
    });

    test(
      'a slow status request cannot repopulate stars after mode stops',
      () async {
        final backend = _MockNetworkBackend();
        final statusCompleter = Completer<Phd2Status>();
        when(
          () => backend.eventStream,
        ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
        when(backend.phd2GetStatus).thenAnswer((_) => statusCompleter.future);

        final container = _container(backend);
        container.read(guiderStateProvider.notifier)
          ..setConnecting(_builtinGuiderId)
          ..setConnected();
        container.read(guideStarsProvider);
        container.read(phd2StateProvider.notifier).state = Phd2State.guiding;
        await Future<void>.delayed(Duration.zero);

        container.read(phd2StateProvider.notifier).state = Phd2State.stopped;
        statusCompleter.complete(
          const Phd2Status(
            state: 'Guiding',
            connected: true,
            trackedStars: [GuideStar(id: 7, x: 1, y: 2, snr: 20)],
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(container.read(guideStarsProvider), isEmpty);
      },
    );

    test('timer skips ticks while a guide-star poll is still in flight', () {
      fakeAsync((async) {
        final backend = _MockNetworkBackend();
        final statusCompleter = Completer<Phd2Status>();
        when(
          () => backend.eventStream,
        ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
        when(backend.phd2GetStatus).thenAnswer((_) => statusCompleter.future);

        final container = _container(backend);
        container.read(guiderStateProvider.notifier)
          ..setConnecting(_builtinGuiderId)
          ..setConnected();
        container.read(guideStarsProvider);
        container.read(phd2StateProvider.notifier).state = Phd2State.guiding;
        async.flushMicrotasks();

        verify(backend.phd2GetStatus).called(1);
        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();
        verifyNever(backend.phd2GetStatus);

        statusCompleter.complete(
          const Phd2Status(state: 'Guiding', connected: true),
        );
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        verify(backend.phd2GetStatus).called(1);
      });
    });
  });
}
