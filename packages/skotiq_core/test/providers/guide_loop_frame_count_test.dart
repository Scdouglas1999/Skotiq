// `Frame Count` counts the loop's own frames during a Loop Exposures run.
//
// `frameCount` counts guide STEPS, and a loop takes no corrections, so a
// step-only counter leaves the row at `0` for a whole run while the guide-star
// badge and the SNR / Star Mass rows above it update on every frame. While
// looping, the row counts the loop's frames, and each new loop counts again
// from one.
//
// The looping guider publishes exactly one `GuideStats` event per captured
// frame (bridge/src/builtin_guider/loop_runner.rs, `publish_star_measurement`),
// so that event is the loop's frame.

import 'dart:async';

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

SkotiqEvent _guideStatsEvent({double snr = 24.5, double starMass = 18342}) {
  return SkotiqEvent(
    severity: EventSeverity.info,
    category: EventCategory.guiding,
    eventType: 'GuideStats',
    data: {'SNR': snr, 'StarMass': starMass},
    timestamp: DateTime.now().millisecondsSinceEpoch,
  );
}

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

  late StreamController<SkotiqEvent> events;
  late ProviderContainer container;

  setUp(() {
    events = StreamController<SkotiqEvent>.broadcast();
    addTearDown(events.close);

    final backend = _MockNetworkBackend();
    when(() => backend.eventStream).thenAnswer((_) => events.stream);
    container = _container(backend);

    // Materialize the notifier so its event binding and its looping listener
    // are both armed before any event or state change.
    container.read(guideStatsProvider);
  });

  Future<void> emit(SkotiqEvent event) async {
    events.add(event);
    await Future<void>.delayed(Duration.zero);
  }

  void setState(Phd2State state) {
    container.read(phd2StateProvider.notifier).state = state;
  }

  test('every loop frame advances the loop count', () async {
    setState(Phd2State.looping);

    for (var i = 1; i <= 3; i++) {
      await emit(_guideStatsEvent());
      expect(container.read(guideStatsProvider).loopFrameCount, i);
    }

    // Guide steps are the other count, and a loop takes none of them — the
    // RMS/Peak readouts stay em-dashed off this field for the whole loop.
    expect(container.read(guideStatsProvider).frameCount, 0);
  });

  test('a new loop counts from one again', () async {
    setState(Phd2State.looping);
    await emit(_guideStatsEvent());
    await emit(_guideStatsEvent());
    await emit(_guideStatsEvent());
    expect(container.read(guideStatsProvider).loopFrameCount, 3);

    setState(Phd2State.stopped);
    setState(Phd2State.looping);
    expect(
      container.read(guideStatsProvider).loopFrameCount,
      0,
      reason: 'the new loop must not inherit the previous loop\'s frames',
    );

    await emit(_guideStatsEvent());
    expect(container.read(guideStatsProvider).loopFrameCount, 1);
  });

  test('guiding measurements do not advance the loop count', () async {
    setState(Phd2State.looping);
    await emit(_guideStatsEvent());
    expect(container.read(guideStatsProvider).loopFrameCount, 1);

    setState(Phd2State.guiding);
    await emit(_guideStatsEvent());
    await emit(_guideStepEvent(ra: 0.4, dec: -0.3));

    final stats = container.read(guideStatsProvider);
    expect(
      stats.loopFrameCount,
      1,
      reason: 'guiding frames are not loop frames',
    );
    expect(stats.frameCount, 1, reason: 'the guide step is counted as one');
  });

  test('GuidingStopped clears the loop count', () async {
    setState(Phd2State.looping);
    await emit(_guideStatsEvent());
    await emit(_guideStatsEvent());
    expect(container.read(guideStatsProvider).loopFrameCount, 2);

    await emit(
      SkotiqEvent(
        severity: EventSeverity.info,
        category: EventCategory.guiding,
        eventType: 'GuidingStopped',
        data: const {},
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ),
    );

    expect(container.read(guideStatsProvider).loopFrameCount, 0);
  });

  // `Phd2Controller` handles the SAME `GuideStats` event and calls
  // `updateStarData` for it, so a count kept inside that method would advance
  // twice for one frame. Stand in for the controller's duplicate call and pin
  // that it moves the star data but not the count.
  test(
    'a second updateStarData for the same frame does not double-count',
    () async {
      setState(Phd2State.looping);
      await emit(_guideStatsEvent(snr: 24.5, starMass: 18342));

      container.read(guideStatsProvider.notifier).updateStarData(24.5, 18342);

      final stats = container.read(guideStatsProvider);
      expect(stats.loopFrameCount, 1);
      expect(stats.snr, 24.5);
    },
  );
}
