import 'package:flutter_test/flutter_test.dart';

/// Basic sanity tests to verify test infrastructure is working
void main() {
  group('Test Infrastructure', () {
    test('tests can run', () {
      expect(1 + 1, 2);
    });

    test('strings work', () {
      const message = 'Hello, tests!';
      expect(message, contains('tests'));
    });

    test('lists work', () {
      final numbers = [1, 2, 3, 4, 5];
      expect(numbers.length, 5);
      expect(numbers.first, 1);
      expect(numbers.last, 5);
    });

    test('maps work', () {
      final data = {'key1': 'value1', 'key2': 'value2'};
      expect(data['key1'], 'value1');
      expect(data.keys.length, 2);
    });

    test('async tests work', () async {
      final result = await Future.value(42);
      expect(result, 42);
    });
  });

  group('Basic Dart Features', () {
    test('exceptions can be caught', () {
      expect(() => throw Exception('test'), throwsException);
    });

    test('futures complete', () async {
      final future = Future.delayed(
        const Duration(milliseconds: 10),
        () => 'completed',
      );
      final result = await future;
      expect(result, 'completed');
    });

    test('closures work', () {
      var counter = 0;
      void increment() => counter++;

      increment();
      increment();
      expect(counter, 2);
    });
  });
}
