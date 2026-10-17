import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('delayToNextBoundary', () {
    test('waits out the remainder of the current second', () {
      final base = DateTime.utc(2026, 9, 1, 12, 0, 0);

      expect(
        delayToNextBoundary(
          const Duration(seconds: 1),
          now: base.add(const Duration(milliseconds: 250)),
        ),
        const Duration(milliseconds: 750),
      );
      expect(
        delayToNextBoundary(
          const Duration(seconds: 1),
          now: base.add(const Duration(milliseconds: 900)),
        ),
        const Duration(milliseconds: 100),
      );
    });

    test('a full period on an exact boundary — never a zero-delay spin', () {
      expect(
        delayToNextBoundary(
          const Duration(seconds: 1),
          now: DateTime.utc(2026, 9, 1, 12, 0, 0),
        ),
        const Duration(seconds: 1),
      );
    });

    test('aligns longer cadences to their own boundary', () {
      expect(
        delayToNextBoundary(
          const Duration(seconds: 30),
          now: DateTime.utc(2026, 9, 1, 12, 0, 10),
        ),
        const Duration(seconds: 20),
      );
    });

    test(
      'the property that matters: clocks armed at ANY two moments in the same '
      'period aim at the SAME instant — that is what lets Flutter coalesce '
      'them into one frame instead of one frame each',
      () {
        const period = Duration(seconds: 1);
        final base = DateTime.utc(2026, 9, 1, 12, 0, 0);
        final target = base.add(period);

        for (var ms = 0; ms < 1000; ms += 37) {
          final armedAt = base.add(Duration(milliseconds: ms));
          expect(
            armedAt.add(delayToNextBoundary(period, now: armedAt)),
            target,
            reason: 'a clock armed at +${ms}ms aimed somewhere else',
          );
        }
      },
    );
  });

  group('AlignedTicker', () {
    // fakeAsync moves timers but not DateTime.now, so the ticker is driven off
    // a virtual clock that follows the fake elapsed time. Alignment is about
    // *which instant* a tick lands on, so the clock has to be the fake one.
    DateTime Function() virtualClock(FakeAsync async, DateTime epoch) {
      return () => epoch.add(async.elapsed);
    }

    test(
      'clocks armed 400 ms apart tick together rather than on two phases',
      () {
        fakeAsync((async) {
          // Start deliberately off-boundary so alignment has work to do.
          final epoch = DateTime.utc(2026, 9, 1, 12, 0, 0, 120);
          final now = virtualClock(async, epoch);

          final first = <Duration>[];
          final second = <Duration>[];

          final a = AlignedTicker(
            const Duration(seconds: 1),
            () => first.add(async.elapsed),
            now: now,
          );

          async.elapse(const Duration(milliseconds: 400));

          final b = AlignedTicker(
            const Duration(seconds: 1),
            () => second.add(async.elapsed),
            now: now,
          );

          async.elapse(const Duration(seconds: 5));

          expect(first, isNotEmpty);
          expect(second, isNotEmpty);
          for (final tick in second) {
            expect(
              first,
              contains(tick),
              reason:
                  'the second clock ticked at $tick, which the first did '
                  'not share — two phases means two frames a second. '
                  'first=$first second=$second',
            );
          }

          a.cancel();
          b.cancel();
        });
      },
    );

    test('ticks once per period', () {
      fakeAsync((async) {
        final epoch = DateTime.utc(2026, 9, 1, 12, 0, 0, 120);
        var ticks = 0;
        final ticker = AlignedTicker(
          const Duration(seconds: 1),
          () => ticks++,
          now: virtualClock(async, epoch),
        );

        async.elapse(const Duration(seconds: 10));

        expect(ticks, inInclusiveRange(9, 10));
        ticker.cancel();
      });
    });

    test('cancel stops the ticks and is safe to repeat', () {
      fakeAsync((async) {
        final epoch = DateTime.utc(2026, 9, 1, 12, 0, 0, 120);
        var ticks = 0;
        final ticker = AlignedTicker(
          const Duration(seconds: 1),
          () => ticks++,
          now: virtualClock(async, epoch),
        );

        async.elapse(const Duration(seconds: 3));
        expect(ticks, greaterThan(0));
        final settled = ticks;

        ticker.cancel();
        ticker.cancel();
        expect(ticker.isActive, isFalse);

        async.elapse(const Duration(seconds: 5));
        expect(ticks, settled, reason: 'a cancelled ticker kept ticking');
      });
    });
  });
}
