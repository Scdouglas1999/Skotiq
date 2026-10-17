/// Tests for the FFI-boundary safe-cast helpers.
///
/// Verifies that:
/// - successful casts return the typed value
/// - failed casts throw a structured [CastFailureException] with context
/// - the helper does NOT silently fall back on type mismatch

library;

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/src/utils/safe_cast.dart';

void main() {
  group('safelyCast<T>', () {
    test('returns value when runtime type matches', () {
      expect(safelyCast<int>(42, context: 'test'), 42);
      expect(safelyCast<String>('hello', context: 'test'), 'hello');
    });

    test('throws CastFailureException when type does not match', () {
      expect(
        () => safelyCast<int>('not an int', context: 'unit.test["x"]'),
        throwsA(
          isA<CastFailureException>()
              .having((e) => e.context, 'context', 'unit.test["x"]')
              .having((e) => e.expectedType, 'expectedType', int),
        ),
      );
    });

    test('exception toString includes context and types', () {
      try {
        safelyCast<int>('oops', context: 'frame');
        fail('expected throw');
      } on CastFailureException catch (e) {
        final s = e.toString();
        expect(s, contains('frame'));
        expect(s, contains('int'));
        expect(s, contains('String'));
        expect(s, contains('oops'));
      }
    });
  });

  group('safelyCastOpt<T>', () {
    test('returns null when value is null', () {
      expect(safelyCastOpt<int>(null, context: 'test'), null);
    });

    test('returns value when non-null and types match', () {
      expect(safelyCastOpt<int>(7, context: 'test'), 7);
    });

    test('throws when non-null but type mismatches', () {
      expect(
        () => safelyCastOpt<int>('x', context: 'phd2.frame'),
        throwsA(
          isA<CastFailureException>().having(
            (e) => e.context,
            'context',
            'phd2.frame',
          ),
        ),
      );
    });
  });

  group('safelyCastDoubleOpt', () {
    test('accepts int and converts to double', () {
      final r = safelyCastDoubleOpt({'lat': 42}, 'lat', contextPrefix: 'ip');
      expect(r, 42.0);
    });

    test('accepts double as-is', () {
      final r = safelyCastDoubleOpt({'lat': 3.14}, 'lat', contextPrefix: 'ip');
      expect(r, 3.14);
    });

    test('returns null when key absent', () {
      expect(
        safelyCastDoubleOpt(<String, Object?>{}, 'lat', contextPrefix: 'ip'),
        null,
      );
    });

    test('throws when key present but wrong type', () {
      expect(
        () => safelyCastDoubleOpt(
          {'lat': 'not-a-number'},
          'lat',
          contextPrefix: 'ip',
        ),
        throwsA(
          isA<CastFailureException>().having(
            (e) => e.context,
            'context',
            'ip["lat"]',
          ),
        ),
      );
    });
  });

  group('safelyCastIntOpt', () {
    test('accepts int', () {
      expect(safelyCastIntOpt({'frame': 5}, 'frame', contextPrefix: 'phd2'), 5);
    });

    test('truncates double to int', () {
      expect(
        safelyCastIntOpt({'frame': 5.9}, 'frame', contextPrefix: 'phd2'),
        5,
      );
    });

    test('returns null when key absent', () {
      expect(
        safelyCastIntOpt(<String, Object?>{}, 'frame', contextPrefix: 'phd2'),
        null,
      );
    });

    test('throws when value is a string', () {
      expect(
        () =>
            safelyCastIntOpt({'frame': 'oops'}, 'frame', contextPrefix: 'phd2'),
        throwsA(
          isA<CastFailureException>().having(
            (e) => e.context,
            'context',
            'phd2["frame"]',
          ),
        ),
      );
    });
  });
}
