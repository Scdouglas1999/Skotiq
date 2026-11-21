// A filter is colored by the band the filter-name rule reads in its name, the
// rule the run moves the wheel by: every spelling of one filter has one color.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_design/skotiq_design.dart';

void main() {
  test('every spelling of a band has its color', () {
    for (final (name, color) in [
      ('H', FilterColors.hydrogenAlpha),
      ('Hydrogen', FilterColors.hydrogenAlpha),
      ('H-alpha', FilterColors.hydrogenAlpha),
      ('Baader Ha 7nm', FilterColors.hydrogenAlpha),
      ('Nitrogen', FilterColors.nitrogen),
      ('Sulfur II', FilterColors.sulfur),
      ('ZWO R', FilterColors.red),
      ('Astronomik G', FilterColors.green),
      ('O3', FilterColors.oxygen),
      ('Luminance', FilterColors.luminance),
    ]) {
      expect(FilterColors.knownColor(name), color, reason: name);
    }
  });

  test('a bandwidth glued to the band keeps the band color', () {
    expect(FilterColors.knownColor('Ha7nm'), FilterColors.hydrogenAlpha);
    expect(FilterColors.knownColor('Baader Ha7nm'), FilterColors.hydrogenAlpha);
    expect(FilterColors.knownColor('OIII6.5nm'), FilterColors.oxygen);
  });

  test('a filter of several bands or of none has no color', () {
    for (final name in [
      'L-eXtreme',
      'L-Pro',
      'Ha/OIII',
      'UV/IR Cut',
      'Unfiltered',
      'Dark',
      'Hb',
      '',
    ]) {
      expect(FilterColors.knownColor(name), isNull, reason: name);
    }
  });
}
