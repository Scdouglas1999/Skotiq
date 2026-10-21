// The chart row: the three session charts with data-built labels during a
// run, the guide chart in pixels or (with a known scale) arcseconds, and the
// before-the-run cards.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/center/session_charts_row.dart';
import 'package:skotiq_app/screens/night_control/data/session/guide_series_provider.dart';
import 'package:skotiq_app/screens/night_control/data/session/session_series_provider.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../golden/surface_golden_harness.dart';
import '../fixtures/night_fixtures.dart';
import 'center_test_support.dart';

/// The guide series as P1b builds it: legend values in pixels.
NightSeriesVm _guideInPixels() {
  final base = NightFixtures.guideSeries();
  return NightSeriesVm(
    lines: base.lines,
    markers: base.markers,
    from: base.from,
    to: base.to,
    legend: const <MetricVm>[
      MetricVm(label: NightText('nightSessionGuideRms'), value: '0.29 px'),
      MetricVm(label: NightText('nightSessionGuideRa'), value: '0.21 px'),
      MetricVm(label: NightText('nightSessionGuideDec'), value: '0.20 px'),
      MetricVm(label: NightText('nightSessionGuidePeak'), value: '0.95 px'),
      MetricVm(label: NightText('nightSessionGuideSnr'), value: '42'),
    ],
  );
}

String _allText(WidgetTester tester) => tester
    .widgetList<RichText>(find.byType(RichText))
    .map((r) => r.text.toPlainText())
    .join('\n');

void main() {
  // Real faces, so the legend fits by the widths the app measures.
  setUpAll(SurfaceGoldenHarness.ensureFonts);

  testWidgets('during a run: three charts with labels built from the data',
      (tester) async {
    final handle = tester.ensureSemantics();
    await pumpCenter(
      tester,
      centerOverrides(NightFixtures.running(), guideSeries: _guideInPixels()),
      child: const SessionChartsRow(),
      size: const Size(744, 120),
    );
    // HFR, guiding, and focus · temperature as two bands.
    expect(find.byType(SeriesChart), findsNWidgets(4));
    expect(find.text('HFR · stars'), findsOneWidget);
    expect(find.text('87 frames'), findsOneWidget);
    expect(find.text('Guiding'), findsOneWidget);
    expect(find.text('Focus · temperature'), findsOneWidget);

    final hfr = tester.widget<SeriesChart>(find.byType(SeriesChart).at(0));
    expect(hfr.semanticLabel, contains('87 frames'));
    expect(hfr.semanticLabel, contains('autofocus at 21:40, 23:10'));
    expect(hfr.semanticLabel, contains('1 rejected'));
    // The rejected frame is a dot on the HFR line, not a vertical.
    expect(hfr.highlights, hasLength(1));
    expect(hfr.highlights.single.y, 3.05);
    expect(hfr.markers, hasLength(2));

    final guide = tester.widget<SeriesChart>(find.byType(SeriesChart).at(1));
    expect(
        guide.semanticLabel, startsWith('Guide error in pixels over 10 min'));
    expect(guide.semanticLabel, contains('1 dithers'));
    expect(guide.zeroLineY, 0);

    final temp = tester.widget<SeriesChart>(find.byType(SeriesChart).at(2));
    expect(temp.semanticLabel, contains('focuser temperature from 16.0 °C'));
    expect(temp.semanticLabel, contains('focuser position from 45'));
    expect(temp.semanticLabel, contains('3 autofocus runs'));
    expect(
      temp.semanticLabel,
      contains('autofocus at 23:10 moved the focuser −18 steps'),
    );
    expect(tester.takeException(), isNull);
    handle.dispose();
  });

  testWidgets('the guide chart and its legend read in pixels', (tester) async {
    await pumpCenter(
      tester,
      centerOverrides(NightFixtures.running(), guideSeries: _guideInPixels()),
      child: const SessionChartsRow(),
      size: const Size(1200, 120),
    );
    // The span picker sits where the unit note was; the scale has the unit.
    expect(find.text('5 min'), findsOneWidget);
    final text = _allText(tester);
    expect(text, contains('RMS 0.29 px'));
    expect(text, contains('RA 0.21 px'));
    expect(text, contains('Dec 0.20 px'));
    expect(text, contains('dither'));
    expect(text, isNot(contains('″')));
    expect(text, isNot(contains('arcsec')));
  });

  testWidgets('with the guider\'s pixel scale the guide chart reads arcsec',
      (tester) async {
    final handle = tester.ensureSemantics();
    final base = NightFixtures.guideSeries();
    await pumpCenter(
      tester,
      <Override>[
        ...centerOverrides(
          NightFixtures.running(),
          guideSeries: NightSeriesVm(
            lines: base.lines,
            markers: base.markers,
            from: base.from,
            to: base.to,
            legend: const <MetricVm>[
              MetricVm(label: NightText('nightSessionGuideRa'), value: '0.32″'),
              MetricVm(
                label: NightText('nightSessionGuideDec'),
                value: '0.30″',
              ),
            ],
          ),
        ),
        nightGuideScaleProvider.overrideWithValue(1.5),
      ],
      child: const SessionChartsRow(),
      size: const Size(1200, 120),
    );
    expect(_allText(tester), contains('″'));
    final guide = tester.widget<SeriesChart>(find.byType(SeriesChart).at(1));
    expect(guide.semanticLabel,
        startsWith('Guide error in arcseconds over 10 min'));
    expect(guide.semanticLabel, contains('arcseconds'));
    expect(guide.semanticLabel, isNot(contains(' px')));
    expect(_allText(tester), contains('RA 0.32″'));
    handle.dispose();
  });

  testWidgets('a run without guide data says so instead of drawing zero',
      (tester) async {
    await pumpCenter(
      tester,
      centerOverrides(
        NightFixtures.running(),
        guideSeries: const NightSeriesVm(lines: <SeriesLineVm>[]),
      ),
      child: const SessionChartsRow(),
      size: const Size(744, 120),
    );
    expect(find.text('No guide data yet'), findsOneWidget);
    expect(find.byType(SeriesChart), findsNWidgets(3));
  });

  testWidgets('before a run: focus, guider idle and cooling cards',
      (tester) async {
    await pumpCenter(
      tester,
      centerOverrides(
        NightFixtures.ready(),
        lastAutofocus: const NightAutofocusCurveVm(
          points: <(int, double)>[
            (45200, 3.4),
            (45300, 2.7),
            (45400, 2.1),
            (45500, 2.0),
            (45600, 2.6),
          ],
          bestPosition: 45484,
          bestHfr: 1.98,
          temperature: 13.1,
        ),
        coolerHistory: NightSeriesVm(
          lines: <SeriesLineVm>[
            SeriesLineVm(
              id: NightSeriesId.sensorTemp,
              points: <SeriesPoint>[
                for (var m = 0; m <= 10; m++)
                  SeriesPoint(
                    NightFixtures.at(18, 22).add(Duration(minutes: m)),
                    12 - m * 1.94,
                  ),
              ],
              tone: SeriesTone.secondary,
            ),
          ],
          from: NightFixtures.at(18, 22),
          to: NightFixtures.at(18, 32),
          legend: const <MetricVm>[
            MetricVm(
              label: NightText('nightSessionSensorTemp'),
              value: '−7.4 °C',
            ),
            MetricVm(label: NightText('nightSessionCoolerPower'), value: '64%'),
          ],
        ),
      ),
      child: const SessionChartsRow(),
      size: const Size(744, 120),
    );
    expect(find.text('Focus'), findsOneWidget);
    expect(
      _allText(tester),
      contains(RegExp(r'best 45\s484 · HFR 1\.98 · 13\.1 °C')),
    );
    expect(find.text('PHD2 idle'), findsOneWidget);
    expect(find.text('Start looping'), findsOneWidget);
    expect(find.text('Cooling'), findsOneWidget);
    expect(find.text('since 18:22'), findsOneWidget);
    expect(_allText(tester), contains('sensor −7.4 °C'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('before a run with PHD2 closed it offers Open PHD2',
      (tester) async {
    await pumpCenter(
      tester,
      centerOverrides(
        NightFixtures.ready(),
        guider: const NightGuiderIdleVm(connected: false, canCommand: true),
      ),
      child: const SessionChartsRow(),
      size: const Size(744, 120),
    );
    expect(find.text('PHD2 not connected'), findsOneWidget);
    expect(find.text('Open PHD2'), findsOneWidget);
    expect(find.text('Start looping'), findsNothing);
    expect(find.text('No autofocus run since Skotiq started'), findsOneWidget);
    expect(find.text('No cooler readings yet'), findsOneWidget);
  });

  testWidgets('a viewer that cannot command gets the reason, not the button',
      (tester) async {
    final handle = tester.ensureSemantics();
    await pumpCenter(
      tester,
      centerOverrides(
        NightFixtures.ready(),
        guider: const NightGuiderIdleVm(
          connected: true,
          canCommand: false,
          state: Phd2State.stopped,
        ),
      ),
      child: const SessionChartsRow(),
      size: const Size(744, 120),
    );
    final data = tester
        .getSemantics(find.bySemanticsLabel('Start looping'))
        .getSemanticsData();
    expect(data.hint, 'Not connected to the host that runs the rig');
    handle.dispose();
  });

  group('guide chart window and scale', () {
    /// Five minutes of 0.3 px guiding with a dither and a 200 px lost-star
    /// excursion in the middle.
    NightSeriesVm spiky() {
      final end = NightFixtures.at(23, 52);
      final start = end.subtract(const Duration(minutes: 5));
      final ra = <SeriesPoint>[];
      final dec = <SeriesPoint>[];
      for (var s = 0; s <= 300; s += 2) {
        final t = start.add(Duration(seconds: s));
        final spike = s == 150 ? 200.0 : (s == 100 ? 4.0 : 0.0);
        ra.add(SeriesPoint(t, (s % 4 == 0 ? 0.3 : -0.3) + spike));
        dec.add(SeriesPoint(t, s % 6 == 0 ? 0.25 : -0.2));
      }
      return NightSeriesVm(
        lines: <SeriesLineVm>[
          SeriesLineVm(
            id: NightSeriesId.guideRa,
            points: ra,
            tone: SeriesTone.primary,
          ),
          SeriesLineVm(
            id: NightSeriesId.guideDec,
            points: dec,
            tone: SeriesTone.tertiary,
          ),
        ],
        from: start,
        to: end,
        legend: const <MetricVm>[
          MetricVm(label: NightText('nightSessionGuideRms'), value: '16.3 px'),
          MetricVm(label: NightText('nightSessionGuideRa'), value: '16.3 px'),
          MetricVm(label: NightText('nightSessionGuideDec'), value: '0.22 px'),
        ],
      );
    }

    test('points beyond the scale sit at its edge and are counted', () {
      final vm = spiky();
      final span = nightGuideSpan(<double>[
        for (final line in vm.lines)
          for (final p in line.points) p.y!,
      ]);
      expect(span, lessThanOrEqualTo(2.5));
      final scaled = nightGuideChartLines(vm, span);
      expect(scaled.offScale, 2);
      expect(scaled.offScaleMarks.map((m) => m.y), everyElement(span));
      for (final line in scaled.lines) {
        expect(line.minY, -span);
        expect(line.maxY, span);
        for (final (_, y) in line.points) {
          expect(y!.abs(), lessThanOrEqualTo(span));
        }
      }
    });

    testWidgets('a lost star does not flatten the trace; it is marked',
        (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCenter(
        tester,
        centerOverrides(NightFixtures.running(), guideSeries: spiky()),
        child: const SessionChartsRow(),
        size: const Size(1200, 120),
      );
      final guide = tester.widget<SeriesChart>(find.byType(SeriesChart).at(1));
      // The scale follows the 0.3 px guiding, not the 200 px step.
      expect(guide.lines.first.maxY, lessThanOrEqualTo(2.5));
      expect(guide.highlights, hasLength(2));
      expect(guide.semanticLabel, contains('2 readings beyond the scale'));
      expect(_allText(tester), contains('off scale'));
      // The scale's top label is a round value with the unit.
      expect(_allText(tester), contains('${guide.lines.first.maxY} px'));
      handle.dispose();
    });

    testWidgets('the span picker switches the chart\'s window', (tester) async {
      final container = await pumpCenter(
        tester,
        centerOverrides(NightFixtures.running(), guideSeries: spiky()),
        child: const SessionChartsRow(),
        size: const Size(1200, 120),
      );
      expect(
        container.read(nightGuideWindowProvider),
        NightGuideWindow.fiveMinutes,
      );
      for (final (label, window) in const <(String, NightGuideWindow)>[
        ('2 min', NightGuideWindow.twoMinutes),
        ('15 min', NightGuideWindow.fifteenMinutes),
        ('Night', NightGuideWindow.night),
      ]) {
        await tester.tap(find.text(label));
        await tester.pump();
        expect(container.read(nightGuideWindowProvider), window);
      }
    });

    testWidgets('a narrow cell gets the short span labels', (tester) async {
      await pumpCenter(
        tester,
        centerOverrides(NightFixtures.running(), guideSeries: spiky()),
        child: const SessionChartsRow(),
        size: const Size(600, 120),
      );
      expect(find.text('5m'), findsOneWidget);
      expect(find.text('All'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('focus · temperature', () {
    test('the last autofocus: its move and the drift since', () {
      final shift = nightLastFocusShift(NightFixtures.temperatureSeries())!;
      expect(shift.at, NightFixtures.at(23, 10));
      expect(shift.steps, -18);
      expect(shift.tempSince, closeTo(-0.72, 0.01));
    });

    test('no autofocus run: nothing to report', () {
      const vm = NightSeriesVm(lines: <SeriesLineVm>[]);
      expect(nightLastFocusShift(vm), isNull);
    });

    testWidgets('position and temperature in their own bands, units on each',
        (tester) async {
      await pumpCenter(
        tester,
        centerOverrides(NightFixtures.running()),
        child: const SessionChartsRow(),
        size: const Size(1200, 120),
      );
      final position =
          tester.widget<SeriesChart>(find.byType(SeriesChart).at(2));
      final temp = tester.widget<SeriesChart>(find.byType(SeriesChart).at(3));
      expect(position.lines.single.stepped, isTrue);
      expect(position.lines.single.points.last.$2, 45484);
      expect(temp.lines.single.points.first.$2, 16);
      // The sensor's flat -10 is not drawn against the air temperature.
      expect(temp.lines, hasLength(1));
      // Every autofocus run is marked through both bands.
      expect(position.markers, hasLength(3));
      expect(temp.markers, hasLength(3));
      final text = _allText(tester);
      expect(text, contains('steps'));
      expect(text, contains('°C'));
      expect(text, contains('AF 23:10: −18 steps'));
      expect(text, contains('−0.7 °C since AF'));
    });

    testWidgets('a short legend never leaves the drift beside a bare name',
        (tester) async {
      await pumpCenter(
        tester,
        centerOverrides(NightFixtures.running()),
        child: const SessionChartsRow(),
        size: const Size(744, 120),
      );
      final legend = tester
          .widgetList<RichText>(find.byType(RichText))
          .map((r) => r.text.toPlainText())
          .firstWhere((t) => t.contains('position'));
      // "focuser  −0.7 °C since AF" would read as a −0.7 °C focuser.
      if (legend.contains('since AF')) {
        expect(legend, contains('focuser 12.0 °C'));
      }
      expect(legend, contains('focuser'));
    });

    testWidgets('no readings: says so, without an autofocus note over it',
        (tester) async {
      final vm = NightSeriesVm(
        lines: const <SeriesLineVm>[],
        markers: <SeriesMarker>[
          SeriesMarker(NightFixtures.at(23, 10), SeriesMarkerKind.autofocus),
        ],
      );
      await pumpCenter(
        tester,
        <Override>[
          ...centerOverrides(NightFixtures.running()),
          nightTemperatureSeriesProvider.overrideWithValue(vm),
        ],
        child: const SessionChartsRow(),
        size: const Size(1200, 120),
      );
      expect(find.text('No readings yet'), findsOneWidget);
      expect(find.textContaining('AF 23:10'), findsNothing);
    });

    testWidgets('a focuser without a probe uses the sensor temperature',
        (tester) async {
      final base = NightFixtures.temperatureSeries();
      final vm = NightSeriesVm(
        lines: <SeriesLineVm>[
          for (final line in base.lines)
            if (line.id != NightSeriesId.focuserTemp) line,
        ],
        markers: base.markers,
        from: base.from,
        to: base.to,
      );
      await pumpCenter(
        tester,
        <Override>[
          ...centerOverrides(NightFixtures.running()),
          nightTemperatureSeriesProvider.overrideWithValue(vm),
        ],
        child: const SessionChartsRow(),
        size: const Size(1200, 120),
      );
      final temp = tester.widget<SeriesChart>(find.byType(SeriesChart).at(3));
      expect(temp.lines.single.points.first.$2, -10);
      // A flat line gets a 2 °C scale instead of a magnified one.
      expect(temp.lines.single.maxY! - temp.lines.single.minY!, 2);
      expect(_allText(tester), contains('sensor'));
    });
  });
}
