import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/utils/retryable_once.dart';

void main() {
  test('calls share one run, and a success is kept', () async {
    var runs = 0;
    final gate = Completer<int>();
    final once = RetryableOnce<int>(() {
      runs++;
      return gate.future;
    });
    final a = once();
    final b = once();
    gate.complete(7);
    expect(await a, 7);
    expect(await b, 7);
    expect(await once(), 7);
    expect(runs, 1);
  });

  test('a failure is forgotten and the next call runs again', () async {
    var runs = 0;
    final once = RetryableOnce<int>(() async {
      runs++;
      if (runs == 1) throw StateError('first');
      return runs;
    });
    await expectLater(once(), throwsStateError);
    expect(once.current, isNull);
    expect(await once(), 2);
    expect(runs, 2);
  });
}
