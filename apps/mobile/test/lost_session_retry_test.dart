// Losing the host must not be terminal.
//
// When the network drops, the app tears the session down after the 30 s grace
// period and shows "Connection to server lost. Please reconnect." Getting back
// from there is the retry path's job: the grace timer's callback is otherwise
// the end of the line, and the app sits on that screen even once the network
// returns — a cold start reconnects instantly from the same saved server and
// token, so the credentials are never what is missing.
//
// The retry path re-arms the same `_autoConnect()` entry point a cold start
// uses, on the backoff pinned below. These cases lock the schedule's shape: it
// must ramp (so a blip recovers in seconds), it must cap (so it never
// busy-polls), and it must never terminate (so an overnight outage still
// re-attaches).
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_mobile/main.dart';

void main() {
  group('lostSessionRetryDelay', () {
    test('ramps 5s, 10s, 20s, 30s so a short blip recovers quickly', () {
      expect(lostSessionRetryDelay(0), const Duration(seconds: 5));
      expect(lostSessionRetryDelay(1), const Duration(seconds: 10));
      expect(lostSessionRetryDelay(2), const Duration(seconds: 20));
      expect(lostSessionRetryDelay(3), const Duration(seconds: 30));
    });

    test('caps at 30s instead of backing off toward never', () {
      for (final attempt in [4, 10, 100, 100000]) {
        expect(
          lostSessionRetryDelay(attempt),
          const Duration(seconds: 30),
          reason:
              'attempt $attempt must still be scheduled 30s out — an app that '
              'stops watching the run is the bug this replaced',
        );
      }
    });

    test('never yields a zero or negative delay (no busy-retry loop)', () {
      for (var attempt = 0; attempt < 50; attempt++) {
        expect(
          lostSessionRetryDelay(attempt) > Duration.zero,
          isTrue,
          reason: 'attempt $attempt scheduled a non-positive delay',
        );
      }
    });

    test('is monotonically non-decreasing', () {
      var previous = lostSessionRetryDelay(0);
      for (var attempt = 1; attempt < 20; attempt++) {
        final current = lostSessionRetryDelay(attempt);
        expect(
          current >= previous,
          isTrue,
          reason: 'backoff went backwards at attempt $attempt',
        );
        previous = current;
      }
    });

    test('a defensive negative attempt still schedules a real retry', () {
      expect(lostSessionRetryDelay(-1), const Duration(seconds: 5));
    });
  });
}
