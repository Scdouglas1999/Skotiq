import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('SimbadResolver.buildTapQuery', () {
    test('interpolates the uppercased name into the exact-match clause', () {
      final query = SimbadResolver.buildTapQuery('m31');
      expect(query.contains("main_id = 'M31'"), isTrue);
      expect(query.contains("main_id LIKE '%M31%'"), isTrue);
    });

    test('does not emit the literal interpolation token', () {
      final query = SimbadResolver.buildTapQuery('ngc7000');
      expect(query.contains(r'${'), isFalse);
      expect(query.contains('name.toUpperCase()'), isFalse);
    });
  });
}
