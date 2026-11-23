import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:test/test.dart';

void main() {
  test('every type parses back from its display name in any case', () {
    for (final type in DsoType.values) {
      expect(DsoType.parse(type.displayName), type, reason: type.name);
      expect(DsoType.parse(type.displayName.toUpperCase()), type);
      expect(DsoType.parse('  ${type.displayName} '), type);
    }
  });

  test('OpenNGC and SIMBAD codes parse to their types', () {
    for (final MapEntry(:key, :value) in kOpenNgcTypeCodes.entries) {
      expect(DsoType.parse(key), value, reason: key);
    }
    for (final MapEntry(:key, :value) in kSimbadTypeCodes.entries) {
      expect(DsoType.parse(key), value, reason: key);
    }
  });

  test('free text and empty values name no type', () {
    for (final text in [null, '', '  ', 'Emission/Reflection Nebula', 'neb']) {
      expect(DsoType.parse(text), isNull, reason: '$text');
    }
  });

  test('a type gives the light its display name reads as', () {
    for (final type in DsoType.values) {
      expect(type.light, targetLight(type.displayName), reason: type.name);
    }
  });
}
