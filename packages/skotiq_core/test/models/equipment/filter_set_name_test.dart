import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';

void main() {
  test(
    'a known set is named by its letters, whatever the filter spellings',
    () {
      expect(filterSetName(['L', 'R', 'G', 'B']), 'LRGB');
      expect(filterSetName(['Lum', 'Red', 'Green', 'Blue']), 'LRGB');
      expect(filterSetName(['Ha', 'L', 'R', 'G', 'B']), 'HaLRGB');
      expect(filterSetName(['Ha 7nm', 'OIII 7nm', 'SII 7nm']), 'SHO');
      expect(filterSetName(['SII', 'Ha', 'OIII']), 'SHO');
      expect(filterSetName(['Ha', 'OIII']), 'HOO');
    },
  );

  test(
    'a set with no common name, a repeat or a multi-band filter has none',
    () {
      expect(filterSetName(['L', 'Ha']), isNull);
      expect(filterSetName(['L', 'R', 'G', 'B', 'L']), isNull);
      expect(filterSetName(['L-eXtreme', 'SII']), isNull);
      expect(filterSetName(['Dark']), isNull);
      expect(filterSetName(const []), isNull);
    },
  );
}
