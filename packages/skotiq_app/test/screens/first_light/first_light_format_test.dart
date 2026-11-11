import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/first_light/first_light_format.dart';
import 'package:skotiq_core/skotiq_core.dart' show userFacingError;

void main() {
  group('describeFirstLightError', () {
    test('strips the difference-image seam envelope', () {
      expect(
        userFacingError(Exception('boring')),
        'boring',
      );
    });

    test('strips a DifferenceImageSeamException prefix', () {
      expect(
        userFacingError('DifferenceImageSeamException: bridge call failed'),
        'bridge call failed',
      );
    });

    test('leaves a bare message untouched', () {
      expect(userFacingError('no template yet'), 'no template yet');
    });

    test('falls back to a readable label for an empty message', () {
      expect(userFacingError(''), 'Unknown error');
    });
  });

  group('firstLightErrorBody', () {
    // The live capture read "Could not load candidates / FormatException:
    // Invalid radix-10 number (at character 1) / tile-1 / ^" and nothing else.
    test('leads with a sentence about the data, not with the exception', () {
      final body = firstLightErrorBody(
        const FormatException('Invalid radix-10 number', 'tile-1', 0),
      );

      expect(body.split('\n').first, isNot(startsWith('FormatException')));
      expect(body, contains('untouched'));
      expect(
        body,
        contains('Invalid radix-10 number'),
        reason: 'support still needs the technical detail, just not first',
      );
    });
  });
}
