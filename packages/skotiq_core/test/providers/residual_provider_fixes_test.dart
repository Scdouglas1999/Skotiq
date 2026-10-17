import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/phd2_models.dart';
import 'package:skotiq_core/src/providers/autofocus_progress_provider.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';
import 'package:skotiq_core/src/providers/guiding_provider.dart';

import '../mocks/mock_backend.dart';

class TestBackendNotifier extends BackendNotifier {
  TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late MockBackend mockBackend;
  late StreamController<SkotiqEvent> eventStreamController;

  setUpAll(() {
    registerMocktailFallbackValues();
  });

  setUp(() {
    mockBackend = MockBackend();
    eventStreamController = StreamController<SkotiqEvent>.broadcast();

    when(
      () => mockBackend.eventStream,
    ).thenAnswer((_) => eventStreamController.stream);
    when(
      () => mockBackend.polarAlignmentEvents,
    ).thenAnswer((_) => const Stream.empty());

    container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => TestBackendNotifier(ref, mockBackend),
        ),
      ],
    );
  });

  tearDown(() async {
    await eventStreamController.close();
    container.dispose();
  });

  test(
    'autofocus overlay surfaces malformed progress events as errors',
    () async {
      container.read(autofocusOverlayProvider.notifier).onAutofocusStarted();

      eventStreamController.add(
        SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: EventSeverity.warning,
          category: EventCategory.equipment,
          eventType: 'AutofocusProgress',
          data: const {'detail': 'not valid autofocus progress'},
        ),
      );

      await Future<void>.delayed(Duration.zero);

      final state = container.read(autofocusOverlayProvider);
      expect(state.hasError, isTrue);
      expect(state.status, contains('could not be parsed'));
    },
  );

  test('late autofocus progress cannot resurrect a completed run', () async {
    final notifier = container.read(autofocusOverlayProvider.notifier);
    const result = AutofocusResult(
      bestPosition: 1234,
      bestHfr: 1.7,
      focusData: [],
      method: 'Hyperbolic',
      timestamp: 1,
      curveFitQuality: 0.95,
      backlashApplied: true,
    );
    notifier.onAutofocusStarted();
    notifier.onAutofocusCompleted(result);

    eventStreamController.add(
      SkotiqEvent(
        timestamp: 2,
        severity: EventSeverity.info,
        category: EventCategory.equipment,
        eventType: 'AutofocusProgress',
        data: {
          'detail': jsonEncode({
            'type': 'autofocus_progress',
            'point': 2,
            'total_points': 9,
            'hfr': 2.1,
            'star_count': 20,
            'focus_range': {'min': 1000, 'max': 1800},
            'vcurve_points': [
              {'position': 1100, 'hfr': 2.1},
            ],
            'star_crops': <Object>[],
          }),
        },
      ),
    );
    await Future<void>.delayed(Duration.zero);

    final state = container.read(autofocusOverlayProvider);
    expect(state.isRunning, isFalse);
    expect(state.result, same(result));
    expect(state.status, contains('Complete'));
  });

  test('autofocus cancellation is terminal but not an error', () {
    final notifier = container.read(autofocusOverlayProvider.notifier);
    notifier.onAutofocusStarted();
    notifier.onAutofocusCancellationRequested();
    expect(
      container.read(autofocusOverlayProvider).status,
      contains('Cancelling'),
    );

    notifier.onAutofocusCancelled();
    final state = container.read(autofocusOverlayProvider);
    expect(state.isRunning, isFalse);
    expect(state.hasError, isFalse);
    expect(state.status, 'Autofocus cancelled');
  });

  test(
    'calibration complete refreshes calibration data through public API',
    () async {
      var fetchCount = 0;
      when(() => mockBackend.phd2GetCalibrationData()).thenAnswer((_) async {
        fetchCount++;
        return const Phd2CalibrationData(
          isCalibrated: true,
          rotationAngle: 12.5,
          raRate: 1.45,
        );
      });

      container.read(phd2ControllerProvider);
      final guiderNotifier = container.read(guiderStateProvider.notifier);
      guiderNotifier.setConnecting('phd2_guider', 'PHD2');
      guiderNotifier.setConnected();

      eventStreamController.add(
        SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: EventSeverity.info,
          category: EventCategory.guiding,
          eventType: 'CalibrationComplete',
          data: const <String, dynamic>{},
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(fetchCount, greaterThan(0));
      final state = container.read(calibrationStateProvider);
      expect(state.isCalibrated, isTrue);
    },
  );
}
