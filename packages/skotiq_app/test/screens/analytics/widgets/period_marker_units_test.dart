// One card must not state the same period in three units.
//
// Observed: on one scroll of Period Analysis the same detected period read
// "20.0 min" in the headline and detail table, "P=0.014d" on the Lomb-Scargle
// periodogram and "P=0.33h" on the BLS spectrum. Cross-checking the peak
// against the result meant doing arithmetic.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/widgets/period_analysis_panel.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  const twentyMinutesInDays = 20.0 / (24.0 * 60.0);

  test('both chart markers read like the headline', () {
    final headline = formatPeriodLabel(twentyMinutesInDays);
    expect(headline, '20.0 min');

    expect(blsPeakLabel(twentyMinutesInDays), 'P=$headline');
    expect(
      periodogramPeakLabel(1.0 / twentyMinutesInDays),
      'P=$headline',
      reason: 'the periodogram axis is frequency, but its marker annotates a '
          'PERIOD and has to match the result it points at',
    );
  });

  test('the shared formatter escalates minutes -> hours -> days', () {
    expect(formatPeriodLabel(20.0 / 1440.0), '20.0 min');
    expect(formatPeriodLabel(8.0 / 24.0), '8.00 hr');
    expect(formatPeriodLabel(3.25), '3.2500 d');
  });

  test('a sub-day BLS peak is no longer printed in bare hours', () {
    // The 20-minute peak must not be reported in hours (0.33h).
    expect(blsPeakLabel(twentyMinutesInDays), isNot(contains('h')));
    expect(
        periodogramPeakLabel(1.0 / twentyMinutesInDays), isNot(endsWith('d')));
  });

  // Both peak markers are painted onto a canvas, so the panel is pumped over
  // a real analysis and each spectrum's marker is read from the chart it
  // hands to the painter.
  testWidgets('the painted peak markers read like the headline',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 3000);
    addTearDown(tester.view.reset);

    // A 20-minute variable sampled every 90 s for two hours.
    final start = DateTime.utc(2026, 8, 1, 9);
    final curve = List.generate(80, (i) {
      final t = 90.0 * i;
      return LightCurvePoint(
        timestamp: start.add(Duration(seconds: 90 * i)),
        flux: 1000,
        differentialMagnitude: 0.05 * math.sin(2 * math.pi * t / 1200),
        snr: 120,
        uncertainty: 0.008,
      );
    });
    final result = const PeriodAnalysisService().analyze(
      points: curve,
      minPeriodDays: 0.01,
      maxPeriodDays: 0.0823,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          periodAnalysisProvider.overrideWith(
            () => _PresetAnalysis(PeriodAnalysisState(result: result)),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Builder(
            builder: (context) => Scaffold(
              body: SingleChildScrollView(
                child: PeriodAnalysisPanel(
                  colors: SkotiqColors.of(context),
                  lightCurve: curve,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    String marker(String seriesLabel) => tester
        .widgetList<SkotiqChart>(find.byType(SkotiqChart))
        .singleWhere((c) => c.series.any((s) => s.label == seriesLabel))
        .rules
        .single
        .label!;

    final lsPeriod = formatPeriodLabel(result.lombScargle.bestPeriod);
    expect(lsPeriod, endsWith('min'));
    expect(marker('Power'), 'P=$lsPeriod');
    expect(
      marker('SR'),
      'P=${formatPeriodLabel(result.bls.bestPeriod)}',
    );
  });
}

class _PresetAnalysis extends PeriodAnalysisNotifier {
  _PresetAnalysis(this._state);
  final PeriodAnalysisState _state;

  @override
  PeriodAnalysisState build() => _state;
}
