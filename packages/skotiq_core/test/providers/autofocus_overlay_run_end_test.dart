// Regressions for two ways the autofocus surfaces misreported a live run.
//
// 1. The floating progress panel stayed EXPANDED after the run ended. It is
//    shell-mounted bottom-right, which is exactly where the imaging Focus
//    column sits, so the finished panel covered the "Run Autofocus" button plus
//    the Step Size / Steps Out / Exposure fields and swallowed every click
//    aimed at them — retrying a focus run looked like a dead button. It must
//    collapse to its summary line as soon as the run stops.
//
// 2. The always-visible status-bar chip only ever had its step text set once,
//    at startOperation ("Initializing..."), so a 35-second sweep read as a hung
//    run on every screen except the one hosting the overlay. Each progress
//    event must push the real phase into the active-operation record.

import 'dart:async';

import 'package:fake_async/fake_async.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/providers/autofocus_progress_provider.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/operation_progress_provider.dart';

import '../mocks/mock_backend.dart';
import '../harness/in_memory_database.dart';

SkotiqEvent _progressEvent({
  required int point,
  required int totalPoints,
  double hfr = 3.2,
}) => SkotiqEvent(
  timestamp: DateTime.now().millisecondsSinceEpoch,
  severity: EventSeverity.info,
  category: EventCategory.equipment,
  eventType: 'AutofocusProgress',
  data: {
    'detail':
        '{"type":"autofocus_progress","point":$point,'
        '"total_points":$totalPoints,"hfr":$hfr,"star_count":42,'
        '"focus_range":{"min":24000,"max":26000},'
        '"vcurve_points":[{"position":24000,"hfr":$hfr}],'
        '"star_crops":[]}',
  },
);

Future<void> _pump() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late StreamController<SkotiqEvent> events;
  late MockBackend backend;

  setUp(() {
    events = StreamController<SkotiqEvent>.broadcast();
    backend = MockBackend();
    when(() => backend.eventStream).thenAnswer((_) => events.stream);
  });

  tearDown(() async {
    await events.close();
  });

  ProviderContainer buildContainer() {
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('overlay collapses to its summary line when a run completes', () async {
    final container = buildContainer();
    final notifier = container.read(autofocusOverlayProvider.notifier);

    notifier.onAutofocusStarted();
    expect(
      container.read(autofocusOverlayProvider).isMinimized,
      isFalse,
      reason: 'a live run shows the full V-curve',
    );

    notifier.onAutofocusCompleted(
      const AutofocusResult(
        bestPosition: 25075,
        bestHfr: 2.1,
        focusData: [],
        method: 'Hyperbolic',
        timestamp: 0,
        curveFitQuality: 0.92,
        backlashApplied: true,
      ),
    );

    final state = container.read(autofocusOverlayProvider);
    expect(state.isRunning, isFalse);
    expect(
      state.isMinimized,
      isTrue,
      reason: 'an expanded finished panel covers the Run Autofocus button',
    );
    expect(state.isVisible, isTrue, reason: 'the result stays readable');
    expect(state.result?.bestPosition, 25075);
  });

  test('overlay collapses when a run fails or is cancelled', () async {
    final container = buildContainer();
    final notifier = container.read(autofocusOverlayProvider.notifier);

    notifier.onAutofocusStarted();
    notifier.onAutofocusFailed('curve fit R² 0.100 below threshold 0.700');
    var state = container.read(autofocusOverlayProvider);
    expect(state.isMinimized, isTrue);
    expect(state.hasError, isTrue);
    expect(state.status, contains('Failed'));

    notifier.onAutofocusStarted();
    expect(container.read(autofocusOverlayProvider).isMinimized, isFalse);
    notifier.onAutofocusCancelled();
    state = container.read(autofocusOverlayProvider);
    expect(state.isMinimized, isTrue);
    expect(state.result, isNull);
  });

  test(
    'progress events push the real phase into the status-bar chip',
    () async {
      final container = buildContainer();
      container.read(autofocusOverlayProvider.notifier);
      final operations = container.read(activeOperationsProvider.notifier);
      await _pump();

      operations.startOperation(
        type: OperationType.autofocus,
        description: 'Running autofocus (Hyperbolic)',
        currentStep: 'Initializing...',
        canCancel: true,
      );

      events.add(_progressEvent(point: 1, totalPoints: 9));
      await _pump();
      expect(
        container
            .read(activeOperationsProvider)[OperationType.autofocus]
            ?.currentStep,
        'Measuring point 1/9',
      );

      events.add(_progressEvent(point: 6, totalPoints: 9, hfr: 2.1));
      await _pump();
      final op = container.read(
        activeOperationsProvider,
      )[OperationType.autofocus];
      expect(
        op?.currentStep,
        'Measuring point 6/9',
        reason: 'the chip used to read "Initializing..." for the whole sweep',
      );
      expect(op?.progress, closeTo(6 / 9, 1e-9));
      expect(
        container.read(autofocusOverlayProvider).status,
        'Measuring point 6/9',
        reason: 'chip and floating panel must agree',
      );
    },
  );

  group('a sequence autofocus', () {
    SkotiqEvent finished(String value) => SkotiqEvent(
      timestamp: DateTime.now().millisecondsSinceEpoch,
      severity: EventSeverity.info,
      category: EventCategory.equipment,
      eventType: 'PropertyChanged',
      data: {
        'device_type': 'focuser',
        'device_id': 'native:zwo_eaf:0',
        'property': 'AutofocusFinished',
        'value': value,
      },
    );

    test(
      'draws live and settles on the result the native side sends',
      () async {
        final container = buildContainer();
        container.read(autofocusOverlayProvider.notifier);
        await _pump();

        events.add(_progressEvent(point: 1, totalPoints: 9, hfr: 7.46));
        await _pump();
        expect(container.read(autofocusOverlayProvider).isRunning, isTrue);
        expect(container.read(autofocusOverlayProvider).currentPoint, 1);

        events.add(
          finished(
            '{"status":"Success","message":null,"result":{'
            '"best_position":45359,"best_hfr":3.79,"curve_fit_quality":0.94,'
            '"method_used":"Hyperbolic","temperature_celsius":8.5,'
            '"backlash_applied":false,"data_points":['
            '{"position":45184,"hfr":7.46,"fwhm":null,"star_count":812}]}}',
          ),
        );
        await _pump();

        final state = container.read(autofocusOverlayProvider);
        expect(state.isRunning, isFalse);
        expect(state.hasError, isFalse);
        expect(state.result?.bestPosition, 45359);
        expect(state.result?.bestHfr, 3.79);
        expect(state.result?.curveFitQuality, 0.94);
        expect(state.result?.focusData.single.starCount, 812);
      },
    );

    test('a failed sweep reads as failed with its reason', () async {
      final container = buildContainer();
      container.read(autofocusOverlayProvider.notifier);
      await _pump();
      events.add(_progressEvent(point: 1, totalPoints: 9));
      await _pump();

      events.add(
        finished(
          '{"status":"Failure","message":"curve fit R² 0.41 below 0.70",'
          '"result":null}',
        ),
      );
      await _pump();

      final state = container.read(autofocusOverlayProvider);
      expect(state.isRunning, isFalse);
      expect(state.hasError, isTrue);
      expect(state.status, contains('R² 0.41'));
    });

    test('a stopped run reads as cancelled', () async {
      final container = buildContainer();
      container.read(autofocusOverlayProvider.notifier);
      await _pump();
      events.add(_progressEvent(point: 1, totalPoints: 9));
      await _pump();

      events.add(finished('{"status":"Cancelled","message":null}'));
      await _pump();

      final state = container.read(autofocusOverlayProvider);
      expect(state.isRunning, isFalse);
      expect(state.hasError, isFalse);
      expect(state.status, 'Autofocus cancelled');
    });

    test('an outcome for no running sweep changes nothing', () async {
      final container = buildContainer();
      final notifier = container.read(autofocusOverlayProvider.notifier);
      await _pump();
      notifier.onAutofocusStarted();
      notifier.onAutofocusCompleted(
        const AutofocusResult(
          bestPosition: 25075,
          bestHfr: 2.1,
          focusData: [],
          method: 'Hyperbolic',
          timestamp: 0,
          curveFitQuality: 0.92,
          backlashApplied: true,
        ),
      );

      events.add(finished('{"status":"Failure","message":"late"}'));
      await _pump();

      final state = container.read(autofocusOverlayProvider);
      expect(state.hasError, isFalse);
      expect(state.result?.bestPosition, 25075);
    });
  });

  test('progress for an untracked run does not invent an operation', () async {
    // Sequencer-driven autofocus emits the same events but registers no
    // OperationType.autofocus record; the push must be a no-op there.
    final container = buildContainer();
    container.read(autofocusOverlayProvider.notifier);
    await _pump();

    events.add(_progressEvent(point: 1, totalPoints: 9));
    await _pump();

    expect(
      container.read(activeOperationsProvider)[OperationType.autofocus],
      isNull,
    );
    expect(container.read(autofocusOverlayProvider).isRunning, isTrue);
  });

  // Audit 2026-08-03: the completed-result pill never expired. The overlay is
  // shell-mounted so it survives navigation during a run (by design), which
  // meant a finished result followed the operator onto Guiding / Plan Tonight
  // / Framing and covered their controls until the app was restarted.
  ProviderContainer fakeAsyncContainer() => ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      backendProvider.overrideWith(
        (ref) => _FixedBackendNotifier(ref, backend),
      ),
    ],
  );

  const finishedRun = AutofocusResult(
    bestPosition: 25075,
    bestHfr: 2.1,
    focusData: [],
    method: 'Hyperbolic',
    timestamp: 0,
    curveFitQuality: 0.92,
    backlashApplied: true,
  );

  test('a completed result dismisses itself', () {
    fakeAsync((async) {
      final container = fakeAsyncContainer();
      final notifier = container.read(autofocusOverlayProvider.notifier);
      notifier.onAutofocusStarted();
      notifier.onAutofocusCompleted(finishedRun);
      expect(container.read(autofocusOverlayProvider).isVisible, isTrue);

      async.elapse(
        AutofocusOverlayNotifier.resultAutoDismissDelay -
            const Duration(seconds: 1),
      );
      expect(
        container.read(autofocusOverlayProvider).isVisible,
        isTrue,
        reason: 'the result must stay readable for its full window',
      );

      async.elapse(const Duration(seconds: 2));
      expect(container.read(autofocusOverlayProvider).isVisible, isFalse);
      expect(
        container.read(autofocusOverlayProvider).result?.bestPosition,
        25075,
        reason:
            'the Tonight Focus tab reads the last result after the '
            'floating panel closes',
      );
      container.dispose();
    });
  });

  test('a failed run stays up: it carries an error to read', () {
    fakeAsync((async) {
      final container = fakeAsyncContainer();
      final notifier = container.read(autofocusOverlayProvider.notifier);
      notifier.onAutofocusStarted();
      notifier.onAutofocusFailed('curve fit R2 0.100 below threshold 0.700');

      async.elapse(AutofocusOverlayNotifier.resultAutoDismissDelay * 3);
      expect(container.read(autofocusOverlayProvider).isVisible, isTrue);
      expect(container.read(autofocusOverlayProvider).hasError, isTrue);
      container.dispose();
    });
  });

  test('a new run cancels the previous result countdown', () {
    fakeAsync((async) {
      final container = fakeAsyncContainer();
      final notifier = container.read(autofocusOverlayProvider.notifier);
      notifier.onAutofocusStarted();
      notifier.onAutofocusCompleted(finishedRun);
      async.elapse(const Duration(seconds: 5));
      notifier.onAutofocusStarted();
      async.elapse(const Duration(seconds: 30));

      expect(
        container.read(autofocusOverlayProvider).isVisible,
        isTrue,
        reason: 'a stale countdown must not close a live run',
      );
      expect(container.read(autofocusOverlayProvider).isRunning, isTrue);
      container.dispose();
    });
  });
}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend initial) : super() {
    state = initial;
  }
}
