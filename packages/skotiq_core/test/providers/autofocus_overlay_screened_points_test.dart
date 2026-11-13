// The autofocus panel on 2026-11-07:
//
// 1. Far from focus the rig's Newtonian made donut stars the detector missed,
//    so a few points read a falsely low HFR and the curve became a W. Once a
//    sweep is measured the native side re-sends its points, each marked with
//    whether the fit used it. The panel keeps the marks and never takes a
//    point the fit left out as the best HFR.
// 2. An autofocus started through the REST API ended, but the host's panel
//    kept reading "point 13 of 13" with only a Cancel button. Every sweep's
//    end now arrives as AutofocusFinished, and the panel can be hidden while a
//    run goes on.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/models/autofocus_progress.dart';
import 'package:skotiq_core/src/providers/autofocus_progress_provider.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';

import '../mocks/mock_backend.dart';
import '../harness/in_memory_database.dart';
import 'package:skotiq_core/src/models/backend/backend_types.dart';

SkotiqEvent _progress(int point, List<Map<String, Object>> points) =>
    SkotiqEvent(
      timestamp: DateTime.now().millisecondsSinceEpoch,
      severity: EventSeverity.info,
      category: EventCategory.equipment,
      eventType: 'AutofocusProgress',
      data: {
        'detail': jsonEncode({
          'type': 'autofocus_progress',
          'point': point,
          'total_points': 5,
          'hfr': points.last['hfr'],
          'star_count': points.last['star_count'],
          'focus_range': {'min': 45088, 'max': 45808},
          'vcurve_points': points,
          'star_crops': <Object>[],
        }),
      },
    );

SkotiqEvent _finished(Map<String, Object?> value) => SkotiqEvent(
  timestamp: DateTime.now().millisecondsSinceEpoch,
  severity: EventSeverity.info,
  category: EventCategory.equipment,
  eventType: 'PropertyChanged',
  data: {
    'device_type': 'focuser',
    'device_id': 'native:zwo_eaf:0',
    'property': 'AutofocusFinished',
    'value': jsonEncode(value),
  },
);

const _sweep = <Map<String, Object>>[
  {'position': 45416, 'hfr': 2.35, 'star_count': 253},
  {'position': 45476, 'hfr': 4.49, 'star_count': 136},
  {'position': 45536, 'hfr': 7.28, 'star_count': 120},
  {'position': 45716, 'hfr': 19.57, 'star_count': 32},
  {'position': 45776, 'hfr': 1.88, 'star_count': 3},
];

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

  Future<ProviderContainer> measuredSweep() async {
    final container = buildContainer();
    container.read(autofocusOverlayProvider.notifier);
    await _pump();
    for (var i = 0; i < _sweep.length; i++) {
      events.add(_progress(i + 1, _sweep.sublist(0, i + 1)));
      await _pump();
    }
    return container;
  }

  test('a point read from donut specks is marked and never the best', () async {
    final container = await measuredSweep();
    expect(
      container.read(autofocusOverlayProvider).bestHfr,
      1.88,
      reason: 'before the screen, the speck reads as the sharpest point',
    );

    events.add(
      _progress(5, [
        ..._sweep.take(4),
        {
          ..._sweep.last,
          'rejected': 'HFR below 19.57 nearer focus, likely missed donut stars',
        },
      ]),
    );
    await _pump();

    final state = container.read(autofocusOverlayProvider);
    expect(state.isRunning, isTrue);
    expect(state.vcurvePoints, hasLength(5));
    expect(
      state.vcurvePoints.where((p) => p.isRejected).map((p) => p.position),
      [45776],
    );
    expect(state.vcurvePoints.last.rejectedReason, contains('nearer focus'));
    expect(state.bestHfr, 2.35);
  });

  test('a point without a verdict parses as used', () {
    final point = VCurvePoint.fromJson(const {
      'position': 1,
      'hfr': 2.0,
      'star_count': 9,
    });
    expect(point.isRejected, isFalse);
    expect(point.rejectedReason, isNull);
  });

  test(
    'a sweep started elsewhere ends on the native outcome, not at point 13',
    () async {
      // Nothing in this window started the run: it learned of it from the
      // progress events, as the host did for the API run of 2026-11-07.
      final container = await measuredSweep();
      expect(container.read(autofocusOverlayProvider).isRunning, isTrue);

      events.add(
        _finished({
          'status': 'Success',
          'message': null,
          'result': {
            'best_position': 45416,
            'best_hfr': 2.35,
            'curve_fit_quality': 0.99,
            'method_used': 'Hyperbolic',
            'data_points': [
              for (final p in _sweep.take(4))
                {
                  'position': p['position'],
                  'hfr': p['hfr'],
                  'fwhm': null,
                  'star_count': p['star_count'],
                },
            ],
            'temperature_celsius': null,
            'backlash_applied': false,
            'rejected_points': [
              {
                'position': 45776,
                'hfr': 1.88,
                'star_count': 3,
                'reason': 'HFR below 19.57 nearer focus, likely missed donut stars',
              },
            ],
          },
        }),
      );
      await _pump();

      final state = container.read(autofocusOverlayProvider);
      expect(state.isRunning, isFalse);
      expect(state.result?.bestPosition, 45416);
    },
  );

  test('a failed sweep started elsewhere ends as failed', () async {
    final container = await measuredSweep();
    events.add(
      _finished({
        'status': 'Failure',
        'message': 'Autofocus failed: Insufficient stars detected.',
        'result': null,
      }),
    );
    await _pump();
    final state = container.read(autofocusOverlayProvider);
    expect(state.isRunning, isFalse);
    expect(state.hasError, isTrue);
    expect(state.status, contains('Insufficient stars'));
  });

  test('a hidden panel stays hidden for the rest of its sweep', () async {
    final container = buildContainer();
    container.read(autofocusOverlayProvider.notifier);
    await _pump();
    events.add(_progress(1, _sweep.sublist(0, 1)));
    await _pump();
    expect(container.read(autofocusOverlayProvider).isVisible, isTrue);

    container.read(autofocusOverlayProvider.notifier).hide();
    events.add(_progress(2, _sweep.sublist(0, 2)));
    await _pump();
    var state = container.read(autofocusOverlayProvider);
    expect(state.isVisible, isFalse);
    expect(state.isRunning, isTrue, reason: 'hiding is not cancelling');
    expect(state.currentPoint, 2);

    events.add(
      _finished({'status': 'Cancelled', 'message': null, 'result': null}),
    );
    await _pump();
    events.add(_progress(1, _sweep.sublist(0, 1)));
    await _pump();
    state = container.read(autofocusOverlayProvider);
    expect(state.isVisible, isTrue, reason: 'the next run shows the panel');
    expect(state.isRunning, isTrue);
  });
}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend initial) : super() {
    state = initial;
  }
}
