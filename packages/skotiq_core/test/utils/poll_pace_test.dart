import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/utils.dart';

void main() {
  tearDown(() => PollPace.multiplier = 1);

  test('stretch scales by the pace and refuses a pace below 1', () {
    expect(
      PollPace.stretch(const Duration(seconds: 10)),
      const Duration(seconds: 10),
    );
    PollPace.multiplier = 3;
    expect(
      PollPace.stretch(const Duration(seconds: 10)),
      const Duration(seconds: 30),
    );
    expect(() => PollPace.multiplier = 0, throwsArgumentError);
    expect(PollPace.multiplier, 3);
  });

  test('a paced timer takes a new pace from its next tick', () {
    fakeAsync((async) {
      final ticks = <Duration>[];
      final timer = pacedPeriodicTimer(
        const Duration(seconds: 10),
        () => ticks.add(async.elapsed),
      );

      async.elapse(const Duration(seconds: 20));
      expect(ticks, const [Duration(seconds: 10), Duration(seconds: 20)]);

      PollPace.multiplier = 3;
      async.elapse(const Duration(seconds: 60));
      // The wait already running ends at 30 s; the next one is paced.
      expect(ticks.last, const Duration(seconds: 60));
      expect(ticks, hasLength(4));

      timer.cancel();
      expect(timer.isActive, isFalse);
      async.elapse(const Duration(minutes: 5));
      expect(ticks, hasLength(4));
    });
  });

  test('a tick that throws does not end a paced timer', () {
    fakeAsync((async) {
      var ticks = 0;
      final errors = <Object>[];
      runZonedGuarded(() {
        pacedPeriodicTimer(const Duration(seconds: 1), () {
          ticks++;
          throw StateError('tick failed');
        });
      }, (error, _) => errors.add(error));

      async.elapse(const Duration(seconds: 3));
      expect(ticks, 3);
      expect(errors, hasLength(3));
    });
  });

  test('the shared poll engine waits at the device pace', () {
    fakeAsync((async) {
      PollPace.multiplier = 3;
      final fetchedAt = <Duration>[];
      var value = 0;
      final subscription = resilientDistinctPoll<int>(
        fetch: () async {
          fetchedAt.add(async.elapsed);
          return value++;
        },
        unchanged: (a, b) => a == b,
        interval: const Duration(seconds: 10),
      ).listen((_) {});

      async.elapse(const Duration(seconds: 65));
      expect(fetchedAt, const [
        Duration.zero,
        Duration(seconds: 30),
        Duration(seconds: 60),
      ]);
      subscription.cancel();
    });
  });
}
