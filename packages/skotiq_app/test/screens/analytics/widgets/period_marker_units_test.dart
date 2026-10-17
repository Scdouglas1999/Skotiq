// One card must not state the same period in three units.
//
// Observed: on one scroll of Period Analysis the same detected period read
// "20.0 min" in the headline and detail table, "P=0.014d" on the Lomb-Scargle
// periodogram and "P=0.33h" on the BLS spectrum. Cross-checking the peak
// against the result meant doing arithmetic.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/widgets/period_analysis_panel.dart';

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

  // The three tests above only exercise the formatters. Both peak markers are
  // painted onto a canvas by private CustomPainters, so no widget test can read
  // the string back: reverting either painter to its own inline
  // '${(p * 24).toStringAsFixed(2)}h' would restore the exact reported defect
  // with every assertion above still green. These guards pin the call sites.
  group('the painters route their peak marker through the shared formatter',
      () {
    String painterSource(String name) {
      final file = File(
          'lib/screens/analytics/widgets/period_analysis_panel/$name.dart');
      expect(file.existsSync(), isTrue,
          reason: 'painter moved; repoint this guard at its new path');
      return file.readAsStringSync();
    }

    test('BLS spectrum marker calls blsPeakLabel', () {
      final source = painterSource('bls_spectrum_painter');
      expect(source, contains('blsPeakLabel(bestPeriod)'));
      // Nothing in the painter may build a peak annotation of its own.
      expect(source.contains("'P="), isFalse,
          reason: 'the marker text must come from blsPeakLabel, not an inline '
              'unit conversion');
    });

    test('Lomb-Scargle marker calls periodogramPeakLabel', () {
      final source = painterSource('periodogram_painter');
      expect(source, contains('periodogramPeakLabel(bestFrequency)'));
      expect(source.contains("'P="), isFalse,
          reason: 'the marker text must come from periodogramPeakLabel, not an '
              'inline unit conversion');
    });
  });
}
