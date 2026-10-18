// polarAlignmentStateProvider and autofocusOverlayProvider re-bind when the
// active backend is swapped (local FFI <-> network). Binding once to
// backend.eventStream in the constructor leaves them deaf after a reconnect.
// These tests swap the backend and assert events from the NEW backend still
// drive the notifiers.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/providers/autofocus_progress_provider.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';
import 'package:skotiq_core/src/providers/guiding_provider.dart';
import 'package:skotiq_core/src/providers/polar_alignment_provider.dart';
import 'package:skotiq_core/src/models/phd2_models.dart';

import '../mocks/mock_backend.dart';

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend initial) : super() {
    state = initial;
  }

  void swapTo(SkotiqBackend backend) => state = backend;
}

SkotiqEvent _polarEvent() => SkotiqEvent(
  timestamp: DateTime.now().millisecondsSinceEpoch,
  severity: EventSeverity.info,
  category: EventCategory.polarAlignment,
  eventType: 'PolarAlignment',
  data: const {
    'azimuth_error': 1.5,
    'altitude_error': -0.75,
    'total_error': 1.68,
  },
);

SkotiqEvent _autofocusEvent() => SkotiqEvent(
  timestamp: DateTime.now().millisecondsSinceEpoch,
  severity: EventSeverity.info,
  category: EventCategory.equipment,
  eventType: 'AutofocusProgress',
  // No 'detail' payload -> the notifier routes to onAutofocusFailed, which is
  // an observable state change proving the event was received.
  data: const {},
);

SkotiqEvent _guidingEvent(
  String eventType, [
  Map<String, dynamic> data = const {},
]) => SkotiqEvent(
  timestamp: DateTime.now().millisecondsSinceEpoch,
  severity: EventSeverity.info,
  category: EventCategory.guiding,
  eventType: eventType,
  data: data,
);

Future<void> _pump() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late StreamController<SkotiqEvent> oldEvents;
  late StreamController<SkotiqEvent> newEvents;
  late MockBackend oldBackend;
  late MockBackend newBackend;

  setUp(() {
    oldEvents = StreamController<SkotiqEvent>.broadcast();
    newEvents = StreamController<SkotiqEvent>.broadcast();
    oldBackend = MockBackend();
    newBackend = MockBackend();
    when(() => oldBackend.eventStream).thenAnswer((_) => oldEvents.stream);
    when(() => newBackend.eventStream).thenAnswer((_) => newEvents.stream);
  });

  tearDown(() async {
    await oldEvents.close();
    await newEvents.close();
  });

  ProviderContainer buildContainer() {
    final container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _SwappableBackendNotifier(ref, oldBackend),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test(
    'polar alignment re-binds to the swapped backend event stream',
    () async {
      final container = buildContainer();
      container.read(polarAlignmentStateProvider.notifier);
      await _pump();

      // Swap the active backend, then emit from the NEW backend.
      (container.read(backendProvider.notifier) as _SwappableBackendNotifier)
          .swapTo(newBackend);
      await _pump();

      expect(
        container.read(polarAlignmentStateProvider).currentError,
        isNull,
        reason: 'no event delivered yet',
      );

      newEvents.add(_polarEvent());
      await _pump();

      final error = container.read(polarAlignmentStateProvider).currentError;
      expect(error, isNotNull);
      expect(error!.totalError, closeTo(1.68, 1e-9));
    },
  );

  test(
    'autofocus overlay re-binds to the swapped backend event stream',
    () async {
      final container = buildContainer();
      container.read(autofocusOverlayProvider.notifier);
      await _pump();

      (container.read(backendProvider.notifier) as _SwappableBackendNotifier)
          .swapTo(newBackend);
      await _pump();

      expect(container.read(autofocusOverlayProvider).hasError, isFalse);

      newEvents.add(_autofocusEvent());
      await _pump();

      expect(container.read(autofocusOverlayProvider).hasError, isTrue);
    },
  );

  test(
    'guiding history, lock, and calibration re-bind and clear old-host state',
    () async {
      final container = buildContainer();
      container.read(targetDisplayHistoryProvider.notifier);
      container.read(lockPositionProvider.notifier);
      container.read(calibrationStateProvider.notifier);
      await _pump();

      oldEvents
        ..add(
          _guidingEvent('GuideStep', {
            'RADistanceRaw': 1.0,
            'DECDistanceRaw': -2.0,
          }),
        )
        ..add(_guidingEvent('StarSelected', {'X': 10.0, 'Y': 20.0}))
        ..add(_guidingEvent('CalibrationComplete'));
      await _pump();
      expect(container.read(targetDisplayHistoryProvider), hasLength(1));
      expect(container.read(lockPositionProvider), (x: 10.0, y: 20.0));
      expect(container.read(calibrationStateProvider).isCalibrated, isTrue);

      (container.read(backendProvider.notifier) as _SwappableBackendNotifier)
          .swapTo(newBackend);
      await _pump();
      expect(container.read(targetDisplayHistoryProvider), isEmpty);
      expect(container.read(lockPositionProvider), isNull);
      expect(container.read(calibrationStateProvider).isCalibrated, isFalse);

      // Old-host traffic cannot repopulate the new-host screen.
      oldEvents
        ..add(
          _guidingEvent('GuideStep', {
            'RADistanceRaw': 99.0,
            'DECDistanceRaw': 99.0,
          }),
        )
        ..add(_guidingEvent('StarSelected', {'X': 99.0, 'Y': 99.0}))
        ..add(_guidingEvent('CalibrationComplete'));
      await _pump();
      expect(container.read(targetDisplayHistoryProvider), isEmpty);
      expect(container.read(lockPositionProvider), isNull);
      expect(container.read(calibrationStateProvider).isCalibrated, isFalse);

      newEvents
        ..add(
          _guidingEvent('GuideStep', {
            'RADistanceRaw': 3.0,
            'DECDistanceRaw': 4.0,
          }),
        )
        ..add(_guidingEvent('StarSelected', {'X': 30.0, 'Y': 40.0}))
        ..add(_guidingEvent('CalibrationComplete'));
      await _pump();
      expect(container.read(targetDisplayHistoryProvider), hasLength(1));
      expect(container.read(lockPositionProvider), (x: 30.0, y: 40.0));
      expect(container.read(calibrationStateProvider).isCalibrated, isTrue);
    },
  );

  test('late old-host star image is discarded after backend swap', () async {
    final imageGate = Completer<Phd2StarImage>();
    when(
      () => oldBackend.guiderGetStarImage(
        deviceId: any(named: 'deviceId'),
        size: any(named: 'size'),
      ),
    ).thenAnswer((_) => imageGate.future);

    final container = buildContainer();
    container.read(guiderStateProvider.notifier)
      ..setConnecting('phd2_guider', 'PHD2')
      ..setConnected();
    // Watched, as the Guiding screen watches it: unwatched, the auto-disposed
    // notifier would be replaced by a fresh one and the assertion below would
    // pass without the late image ever being discarded.
    final sub = container.listen(starImageProvider, (_, __) {});
    addTearDown(sub.close);
    final notifier = container.read(starImageProvider.notifier);

    final refresh = notifier.refresh();
    await _pump();
    (container.read(backendProvider.notifier) as _SwappableBackendNotifier)
        .swapTo(newBackend);
    await _pump();

    imageGate.complete(
      Phd2StarImage(
        frame: 7,
        width: 1,
        height: 1,
        starX: 0,
        starY: 0,
        pixels: Uint8List.fromList([42]),
      ),
    );
    await refresh;
    await _pump();

    expect(
      identical(container.read(starImageProvider.notifier), notifier),
      isTrue,
      reason: 'the same notifier received the late image',
    );
    expect(container.read(starImageProvider).isLoading, isTrue);
  });

  test('a star image is polled when PHD2 is already looping', () async {
    when(
      () => oldBackend.guiderGetStarImage(
        deviceId: any(named: 'deviceId'),
        size: any(named: 'size'),
      ),
    ).thenAnswer(
      (_) async => Phd2StarImage(
        frame: 3,
        width: 1,
        height: 1,
        starX: 0,
        starY: 0,
        pixels: Uint8List.fromList([7]),
      ),
    );

    final container = buildContainer();
    container.read(guiderStateProvider.notifier)
      ..setConnecting('phd2_guider', 'PHD2')
      ..setConnected();
    // PHD2 started looping before anything read the star image — the Guiding
    // screen opened onto a loop already running.
    container.read(phd2StateProvider.notifier).state = Phd2State.looping;
    // Watched, as the Guiding screen watches it: the image is polled only
    // while something shows it.
    final sub = container.listen(starImageProvider, (_, __) {});
    addTearDown(sub.close);
    await _pump();

    expect(container.read(starImageProvider).valueOrNull?.frame, 3);
  });

  test(
    'late old-host brain settings are discarded after backend swap',
    () async {
      final namesGate = Completer<List<String>>();
      when(
        () => oldBackend.phd2GetAlgoParamNames(axis: 'ra'),
      ).thenAnswer((_) => namesGate.future);
      when(
        () => oldBackend.phd2GetAlgoParamNames(axis: 'dec'),
      ).thenAnswer((_) async => const []);
      when(
        () => oldBackend.phd2GetAlgoParam(axis: 'ra', name: 'Aggressiveness'),
      ).thenAnswer((_) async => 70.0);

      final container = buildContainer();
      final notifier = container.read(brainParamsProvider.notifier);
      final fetch = notifier.fetch();
      await _pump();

      (container.read(backendProvider.notifier) as _SwappableBackendNotifier)
          .swapTo(newBackend);
      await _pump();
      namesGate.complete(const ['Aggressiveness']);
      await fetch;
      await _pump();

      expect(container.read(brainParamsProvider).isLoading, isTrue);
      verifyNever(
        () => oldBackend.phd2GetAlgoParam(axis: 'ra', name: 'Aggressiveness'),
      );
    },
  );

  test(
    'built-in guider config fetch failure is not disguised as defaults',
    () async {
      when(
        () => oldBackend.builtinGuiderGetConfig(),
      ).thenThrow(StateError('guider config unavailable'));

      final container = buildContainer();
      await container.read(builtinGuiderConfigProvider.notifier).fetch();

      final result = container.read(builtinGuiderConfigProvider);
      expect(result.hasError, isTrue);
      expect(result.error, isA<StateError>());
    },
  );

  test(
    'late old-host built-in guider config is discarded after swap',
    () async {
      final configGate = Completer<BuiltinGuiderConfig>();
      when(
        () => oldBackend.builtinGuiderGetConfig(),
      ).thenAnswer((_) => configGate.future);

      final container = buildContainer();
      final fetch = container
          .read(builtinGuiderConfigProvider.notifier)
          .fetch();
      await _pump();
      (container.read(backendProvider.notifier) as _SwappableBackendNotifier)
          .swapTo(newBackend);
      await _pump();

      configGate.complete(BuiltinGuiderConfig.defaults);
      await fetch;
      await _pump();

      expect(container.read(builtinGuiderConfigProvider).isLoading, isTrue);
    },
  );
}
