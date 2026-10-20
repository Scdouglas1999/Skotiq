// The chart row: the three session charts with data-built labels during a
// run, the guide chart in pixels or (with a known scale) arcseconds, and the
// before-the-run cards.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/center/session_charts_row.dart';
import 'package:skotiq_app/screens/night_control/data/session/guide_series_provider.dart';
import 'package:skotiq_app/screens/night_control/night_control_contracts.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

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
      MetricVm(label: NightText('nightSessionGuideTotal'), value: '0.29 px'),
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
  testWidgets('during a run: three charts with labels built from the data',
      (tester) async {
    final handle = tester.ensureSemantics();
    await pumpCenter(
      tester,
      centerOverrides(NightFixtures.running(), guideSeries: _guideInPixels()),
      child: const SessionChartsRow(),
      size: const Size(744, 120),
    );
    expect(find.byType(SeriesChart), findsNWidgets(3));
    expect(find.text('HFR · stars'), findsOneWidget);
    expect(find.text('87 frames'), findsOneWidget);
    expect(find.text('Guiding'), findsOneWidget);
    expect(find.text('Temperature · focus'), findsOneWidget);

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
    expect(find.text('error in px'), findsOneWidget);
    final text = _allText(tester);
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
    expect(find.text('error in arcsec'), findsOneWidget);
    expect(find.text('error in px'), findsNothing);
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
    expect(find.byType(SeriesChart), findsNWidgets(2));
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
}
