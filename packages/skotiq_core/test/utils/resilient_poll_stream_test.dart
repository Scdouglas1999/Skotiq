import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 1));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for polling');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

void main() {
  test(
    'unchanged poll cancels promptly and stops scheduling fetches',
    () async {
      var calls = 0;
      final firstValue = Completer<void>();
      final subscription =
          resilientDistinctPoll<int>(
            fetch: () async {
              calls++;
              return 7;
            },
            unchanged: (previous, next) => previous == next,
            interval: const Duration(milliseconds: 5),
          ).listen((value) {
            expect(value, 7);
            if (!firstValue.isCompleted) firstValue.complete();
          });

      await firstValue.future;
      await _waitUntil(() => calls >= 3);
      await subscription.cancel().timeout(const Duration(milliseconds: 100));
      final callsAtCancel = calls;
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(calls, callsAtCancel);
    },
  );
}
