import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/data/session/session_events_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/session_series_provider.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_core/skotiq_core.dart';

import 'session_test_support.dart';

void main() {
  test('a run-counted autofocus marks the HFR chart once', () async {
    final h = await sessionHarness();
    final keep = h.container.listen(nightSessionEventsProvider, (_, __) {});
    addTearDown(keep.close);
    final stats = h.container.read(liveSequenceStatsProvider.notifier);
    stats.state = SequenceRunStats();
    stats.state = SequenceRunStats()..autofocusRuns = 1;

    // The overlay's result for the same run fills the mark in.
    final overlay = h.container.read(autofocusOverlayProvider.notifier);
    overlay.onAutofocusStarted();
    overlay.onAutofocusCompleted(
      const AutofocusResult(
        bestPosition: 45484,
        bestHfr: 1.98,
        focusData: <FocusDataPoint>[],
        method: 'vcurve',
        timestamp: 0,
        curveFitQuality: 0.98,
        backlashApplied: false,
      ),
    );

    final runs = h.read(nightSessionEventsProvider).autofocusRuns;
    expect(runs, hasLength(1));
    expect(runs.single.position, 45484);
    expect(
      h.read(nightSessionEventsProvider).markers.single.kind,
      SeriesMarkerKind.autofocus,
    );
  });

  test('a failed autofocus leaves no mark', () async {
    final h = await sessionHarness();
    final keep = h.container.listen(nightSessionEventsProvider, (_, __) {});
    addTearDown(keep.close);
    final overlay = h.container.read(autofocusOverlayProvider.notifier);
    overlay.onAutofocusStarted();
    overlay.onAutofocusFailed('no stars');
    expect(h.read(nightSessionEventsProvider).autofocusRuns, isEmpty);
  });

  test('a successful flip is marked, a failed one is not', () async {
    final h = await sessionHarness();
    final keep = h.container.listen(nightSessionEventsProvider, (_, __) {});
    addTearDown(keep.close);
    SkotiqEvent flip(String outcome, int minutes) => SkotiqEvent(
          timestamp:
              kNight.add(Duration(minutes: minutes)).millisecondsSinceEpoch,
          severity: EventSeverity.info,
          category: EventCategory.sequencer,
          eventType: 'MeridianFlipOutcome',
          data: <String, dynamic>{'outcome': outcome},
        );
    h.backend
      ..emitEvent(flip('failed', 10))
      ..emitEvent(flip('success', 20));
    await Future<void>.delayed(Duration.zero);
    expect(
      h.read(nightSessionEventsProvider).flips,
      <DateTime>[kNight.add(const Duration(minutes: 20))],
    );
  });

  test('the temperature chart uses the cooler history inside the session',
      () async {
    final h = await sessionHarness();
    await h.addFrame(
      minutes: 0,
      hfr: 2.1,
      focuserTemp: 12.4,
      focuserPosition: 45502,
      sensorTemp: -10,
    );
    await h.addFrame(
      minutes: 30,
      hfr: 2.1,
      focuserTemp: 12.0,
      focuserPosition: 45484,
      sensorTemp: -10,
    );
    final history = h.container.read(temperatureHistoryProvider.notifier);
    // One reading before the session, two inside it.
    history.addPoint(-7.4, at: kNight.subtract(const Duration(minutes: 5)));
    history.addPoint(-9.9, at: kNight.add(const Duration(minutes: 1)));
    history.addPoint(-10.0, at: kNight.add(const Duration(minutes: 20)));

    final vm = await h.settle(nightTemperatureSeriesProvider);
    final sensor = vm.lines.firstWhere((l) => l.id == NightSeriesId.sensorTemp);
    expect(sensor.points.map((p) => p.y), <double>[-9.9, -10.0]);
    final position =
        vm.lines.firstWhere((l) => l.id == NightSeriesId.focuserPosition);
    expect(position.stepped, isTrue);
    expect(position.secondaryAxis, isTrue);
    expect(
      vm.legend.map((m) => '${m.label.key} ${m.value}'),
      <String>[
        'nightSessionFocuserTemp 12.0 °C',
        'nightSessionFocuserPosition 45 484',
        'nightSessionSensorTemp −10.0 °C',
      ],
    );
    // No ambient line: nothing records ambient over time.
    expect(
      vm.lines.map((l) => l.id),
      isNot(contains(NightSeriesId.ambientTemp)),
    );

    final cooler = h.read(nightCoolerHistoryProvider);
    expect(cooler.from, kNight.subtract(const Duration(minutes: 5)));
    expect(cooler.lines.single.points, hasLength(3));
  });
}
