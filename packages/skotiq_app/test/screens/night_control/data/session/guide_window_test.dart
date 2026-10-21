// The guiding chart's window and scale: the samples a window keeps, the
// shape-preserving thinning of a long window, the gaps it leaves where the
// guider was quiet, and a scale that one dither or lost star cannot flatten.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/data/session/guide_series_provider.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_core/skotiq_core.dart';

import 'session_test_support.dart';

final DateTime _t0 = DateTime(2026, 10, 20, 22);

/// One sample every [everySeconds] for [minutes], RA and Dec from [ra]/[dec].
List<NightGuideSample> _samples({
  required int minutes,
  int everySeconds = 2,
  double Function(int i)? ra,
  double Function(int i)? dec,
}) =>
    <NightGuideSample>[
      for (var i = 0; i * everySeconds < minutes * 60; i++)
        NightGuideSample(
          _t0.add(Duration(seconds: i * everySeconds)),
          ra?.call(i) ?? (i.isEven ? 0.2 : -0.2),
          dec?.call(i) ?? (i % 3 == 0 ? 0.1 : -0.15),
        ),
    ];

List<SeriesPoint> _ra(List<NightGuideSample> samples) => <SeriesPoint>[
      for (final s in samples) SeriesPoint(s.t, s.raPx),
    ];

class _Samples extends NightGuideSamplesNotifier {
  _Samples(super.ref, List<NightGuideSample> initial) {
    state = initial;
  }
}

void main() {
  group('window', () {
    test('five minutes is the default', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(
        container.read(nightGuideWindowProvider),
        NightGuideWindow.fiveMinutes,
      );
    });

    test('a window keeps the newest samples within its span', () {
      final all = _samples(minutes: 60);
      final last = all.last.t;
      for (final window in <NightGuideWindow>[
        NightGuideWindow.twoMinutes,
        NightGuideWindow.fiveMinutes,
        NightGuideWindow.fifteenMinutes,
      ]) {
        final kept = nightGuideInWindow(all, window);
        expect(kept.last.t, last);
        expect(
          kept.first.t.isBefore(last.subtract(window.duration!)),
          isFalse,
          reason: '$window',
        );
        // Every sample inside the span is kept: 2 s apart over the span.
        expect(kept.length, window.duration!.inSeconds ~/ 2 + 1);
      }
      expect(nightGuideInWindow(all, NightGuideWindow.night), all);
      expect(
          nightGuideInWindow(
              const <NightGuideSample>[], NightGuideWindow.fiveMinutes),
          isEmpty);
    });

    test('the store keeps the whole night, not ten minutes', () async {
      final h = await sessionHarness();
      final container = h.container;
      final notifier = container.read(nightGuideSamplesProvider.notifier);
      for (final s in _samples(minutes: 180, everySeconds: 10)) {
        notifier.add(s);
      }
      final state = container.read(nightGuideSamplesProvider);
      expect(state.first.t, _t0);
      expect(state.length, 180 * 6);
      // The guide tab's numbers still describe the recent ten minutes.
      final recent = container.read(nightGuideRecentSamplesProvider);
      expect(
          recent.first.t.isBefore(
              state.last.t.subtract(NightGuideSamplesNotifier.recent)),
          isFalse);
      expect(recent.length, 61);
    });

    test('the chart spans the window and the legend describes only it',
        () async {
      // An hour of quiet guiding, then 140 s of 1 px error.
      final quiet = _samples(minutes: 60);
      final rough = <NightGuideSample>[
        for (var i = 1; i <= 70; i++)
          NightGuideSample(
            quiet.last.t.add(Duration(seconds: i * 2)),
            i.isEven ? 1 : -1,
            0,
          ),
      ];
      final h = await sessionHarness(overrides: [
        nightGuideSamplesProvider.overrideWith(
          (ref) => _Samples(ref, <NightGuideSample>[...quiet, ...rough]),
        ),
        nightGuideScaleProvider.overrideWithValue(null),
      ]);
      final container = h.container;

      container.read(nightGuideWindowProvider.notifier).state =
          NightGuideWindow.twoMinutes;
      var vm = container.read(nightGuideSeriesProvider);
      expect(vm.to, rough.last.t);
      expect(vm.from, rough.last.t.subtract(const Duration(minutes: 2)));
      String legend(NightSeriesVm vm, String key) =>
          vm.legend.firstWhere((m) => m.label.key == key).value!;
      expect(legend(vm, 'nightSessionGuideRa'), '1.00 px');

      container.read(nightGuideWindowProvider.notifier).state =
          NightGuideWindow.night;
      vm = container.read(nightGuideSeriesProvider);
      expect(vm.from, quiet.first.t);
      expect(vm.to, rough.last.t);
      // Over the night the rough patch is a small part of the RMS.
      expect(double.parse(legend(vm, 'nightSessionGuideRa').split(' ').first),
          lessThan(0.4));
      expect(legend(vm, 'nightSessionGuideRms'), isNotEmpty);
    });
  });

  group('trace', () {
    test('a short window passes every sample through', () {
      final samples = _samples(minutes: 5);
      final trace = nightGuideTrace(_ra(samples));
      expect(trace.map((p) => p.y), samples.map((s) => s.raPx));
    });

    test('a long window is thinned but keeps each bucket\'s extremes', () {
      // Eight hours at 1 Hz with one 6 px excursion in the middle.
      final samples = _samples(
        minutes: 480,
        everySeconds: 1,
        ra: (i) => i == 14400 ? 6.0 : (i.isEven ? 0.2 : -0.3),
      );
      final trace = nightGuideTrace(_ra(samples), maxPoints: 600);
      expect(trace.length, lessThanOrEqualTo(600));
      final ys = trace.map((p) => p.y).whereType<double>().toList();
      expect(ys, contains(6.0));
      expect(ys, contains(-0.3));
      // Still in time order.
      for (var i = 1; i < trace.length; i++) {
        expect(trace[i].t.isBefore(trace[i - 1].t), isFalse);
      }
    });

    test('a pause in guiding is a gap, not a bridge', () {
      final before = _samples(minutes: 2);
      final after = <NightGuideSample>[
        for (final s in _samples(minutes: 2))
          NightGuideSample(
            s.t.add(const Duration(minutes: 20)),
            s.raPx,
            s.decPx,
          ),
      ];
      final trace =
          nightGuideTrace(_ra(<NightGuideSample>[...before, ...after]));
      final gaps = trace.where((p) => p.y == null).toList();
      expect(gaps, hasLength(1));
      expect(trace.length, before.length + after.length + 1);
    });
  });

  group('scale', () {
    test('quiet guiding gets the floor, rounded to a step', () {
      expect(nightGuideSpan(<double>[0.1, -0.2, 0.15]), 0.5);
      expect(nightGuideSpan(const <double>[]), 0.5);
    });

    test('everything shows when nothing stands out', () {
      final values = <double>[
        for (var i = 0; i < 300; i++) (i % 7 - 3) * 0.4,
      ];
      final span = nightGuideSpan(values);
      expect(span, greaterThanOrEqualTo(1.2));
      expect(values.every((v) => v.abs() <= span), isTrue);
    });

    test('one dither or a lost star does not flatten the trace', () {
      final values = <double>[
        for (var i = 0; i < 300; i++) i.isEven ? 0.3 : -0.25,
        4.5, -3.8, 2.1, // a dither
        200, // a lost-star excursion
      ];
      final span = nightGuideSpan(values);
      expect(span, lessThan(3));
      expect(span, greaterThanOrEqualTo(0.5));
      // The usual error still fills a good part of the height.
      expect(0.3 / span, greaterThan(0.1));
    });

    test('a nice ceiling', () {
      expect(nightNiceCeil(0.42), 0.5);
      expect(nightNiceCeil(0.5), 0.5);
      expect(nightNiceCeil(0.51), 0.6);
      expect(nightNiceCeil(1.26), 1.5);
      expect(nightNiceCeil(3.3), 4);
      expect(nightNiceCeil(7), 8);
      expect(nightNiceCeil(13), 15);
    });
  });

  test('a GuideStep with no timestamp is still placed', () {
    final sample = nightGuideSampleFrom(
      const SkotiqEvent(
        timestamp: 0,
        severity: EventSeverity.info,
        category: EventCategory.guiding,
        eventType: 'GuideStep',
        data: <String, dynamic>{'RADistanceRaw': 0.1, 'DECDistanceRaw': 0.2},
      ),
    );
    expect(sample, isNotNull);
  });
}
