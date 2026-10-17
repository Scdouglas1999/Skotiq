// Real unit coverage for the per-token [TokenBucketRateLimiter] contracts that
// the broader route_metadata suite does not pin: the GRADUAL (proportional)
// refill math and the LRU eviction bound. Both are load-bearing — the refill
// rate is what keeps a phone dashboard from being throttled mid-poll, and the
// eviction bound is the memory guarantee for an unbounded set of paired tokens.
//
// Each test drives the production limiter directly with an injected clock so it
// is deterministic, and asserts behaviour that FAILS if the production formula
// or eviction policy regresses (no tautologies).

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/headless_api/route_metadata.dart';

void main() {
  group('TokenBucketRateLimiter — refill + eviction contracts', () {
    test('refills PROPORTIONALLY to elapsed time, not all-or-nothing', () {
      // 10 tokens, refilling 10/sec. Drain the bucket, then advance exactly
      // half the refill period: the contract is that HALF the tokens (5) come
      // back — not zero (period not yet elapsed) and not all 10.
      var now = DateTime.utc(2026, 1, 1);
      final limiter = TokenBucketRateLimiter(
        configByClass: const {
          TokenRouteClass.read: TokenBucketConfig(
            capacity: 10,
            refillTokens: 10,
            refillPeriod: Duration(seconds: 1),
          ),
        },
        now: () => now,
      );

      RateLimitDecision consume() =>
          limiter.tryConsume(tokenId: 'tok', routeClass: TokenRouteClass.read);

      // Drain the full bucket at t0.
      for (var i = 0; i < 10; i++) {
        expect(consume().allowed, isTrue, reason: 'initial token $i');
      }
      expect(consume().allowed, isFalse, reason: 'bucket is empty at t0');

      // Advance HALF a period → exactly 5 tokens refill.
      now = now.add(const Duration(milliseconds: 500));
      for (var i = 0; i < 5; i++) {
        expect(
          consume().allowed,
          isTrue,
          reason: 'proportional refill should grant token $i of 5',
        );
      }
      // The 6th must fail — only the proportional 5 came back, not the full 10.
      expect(
        consume().allowed,
        isFalse,
        reason: 'a half-period refill must grant HALF the capacity, no more',
      );
    });

    test('evicts the least-recently-used bucket past maxBuckets', () {
      // Fix the clock so refill never confounds the eviction observation.
      final now = DateTime.utc(2026, 1, 1);
      final limiter = TokenBucketRateLimiter(
        configByClass: const {
          TokenRouteClass.read: TokenBucketConfig(
            capacity: 2,
            refillTokens: 2,
            refillPeriod: Duration(seconds: 1),
          ),
        },
        now: () => now,
        maxBuckets: 2,
      );

      RateLimitDecision consume(String tok) =>
          limiter.tryConsume(tokenId: tok, routeClass: TokenRouteClass.read);

      // Drain tokA's bucket completely (it is now the coldest entry).
      expect(consume('tokA').allowed, isTrue);
      expect(consume('tokA').allowed, isTrue);
      expect(
        consume('tokA').allowed,
        isFalse,
        reason: 'tokA is drained while its bucket persists',
      );

      // Touch two OTHER tokens. The table now holds {tokA(drained), tokB},
      // then inserting tokC overflows maxBuckets=2 and evicts the LRU (tokA).
      expect(consume('tokB').allowed, isTrue);
      expect(consume('tokC').allowed, isTrue);

      // tokA's bucket was evicted, so it is recreated at FULL capacity: the
      // next consume succeeds (it would be DENIED if the drained bucket had
      // survived). This is the observable proof of eviction.
      expect(
        consume('tokA').allowed,
        isTrue,
        reason: 'an evicted bucket is recreated full, not resurrected drained',
      );
    });
  });
}
