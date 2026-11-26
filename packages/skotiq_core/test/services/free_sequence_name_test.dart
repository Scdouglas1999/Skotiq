// A plan saved for the first time takes a name no saved plan uses: three
// plans built for one target were all "NGC1313 Plan" in the library.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/sequence_summary.dart';

void main() {
  test('a free name is kept', () {
    expect(freeSequenceName('NGC1313 Plan', ['M31 Plan']), 'NGC1313 Plan');
  });

  test('a taken name gets the next number, ignoring case', () {
    expect(
      freeSequenceName('NGC1313 Plan', ['ngc1313 plan', 'NGC1313 Plan 2']),
      'NGC1313 Plan 3',
    );
  });
}
