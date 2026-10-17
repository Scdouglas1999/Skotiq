import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/first_light/first_light_format.dart';

void main() {
  group('describeFirstLightError', () {
    test('strips the difference-image seam envelope', () {
      expect(
        describeFirstLightError(
          Exception('boring'),
        ),
        'boring',
      );
    });

    test('strips a DifferenceImageSeamException prefix', () {
      expect(
        describeFirstLightError(
          'DifferenceImageSeamException: bridge call failed',
        ),
        'bridge call failed',
      );
    });

    test('leaves a bare message untouched', () {
      expect(describeFirstLightError('no template yet'), 'no template yet');
    });

    test('falls back to a readable label for an empty message', () {
      expect(describeFirstLightError(''), 'Unknown error.');
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
