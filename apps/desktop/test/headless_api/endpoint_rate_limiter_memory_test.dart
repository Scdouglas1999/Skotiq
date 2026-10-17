import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/headless_api/route_metadata.dart';

/// `EndpointRateLimiter` keys on `(clientKey, method, concrete path)`, and
/// several rate-limited prefixes are parametric — every distinct
/// `/api/coimaging/sessions/<id>/contribute` mints its own entry. Its sibling
/// `TokenBucketRateLimiter` has carried an LRU cap since it was written; this
/// one had none, so an unattended run leaked one entry per session id forever.
///
/// The proof is the same shape the sibling's eviction test uses: a bucket that
/// was evicted comes back fresh, so a previously-blocked key is allowed again.
void main() {
  group('EndpointRateLimiter memory bound', () {
    final now = DateTime(2026, 5, 5, 1);

    String contributePath(Object id) =>
        '/api/coimaging/sessions/$id/contribute';

    test('evicts the least-recently-used key past maxEntries', () {
      final limiter = EndpointRateLimiter(now: () => now, maxEntries: 2);

      bool post(String path) => limiter
          .check(clientKey: 'client-a', method: 'POST', path: path)
          .allowed;

      final seed = contributePath('seed');
      for (var i = 0; i < highRiskControlRateLimitMaxRequests; i++) {
        expect(post(seed), isTrue);
      }
      expect(post(seed), isFalse, reason: 'seed is blocked while it persists');

      // Two other keys overflow maxEntries=2 and evict the coldest (seed).
      expect(post(contributePath('b')), isTrue);
      expect(post(contributePath('c')), isTrue);

      expect(
        post(seed),
        isTrue,
        reason: 'an evicted key is recreated empty, not resurrected blocked',
      );
    });

    test('the default cap bounds a long unattended run', () {
      final limiter = EndpointRateLimiter(now: () => now);

      bool post(String path) => limiter
          .check(clientKey: 'client-a', method: 'POST', path: path)
          .allowed;

      final seed = contributePath('seed');
      for (var i = 0; i < highRiskControlRateLimitMaxRequests; i++) {
        expect(post(seed), isTrue);
      }
      expect(post(seed), isFalse);

      // One night of a collaborative run: a fresh session id per contribute.
      for (var i = 0; i < defaultEndpointRateLimiterMaxEntries + 100; i++) {
        post(contributePath(i));
      }

      expect(
        post(seed),
        isTrue,
        reason: 'the seed entry must have been evicted, not retained forever',
      );
    });

    test('a hot key survives eviction pressure from cold ones', () {
      final limiter = EndpointRateLimiter(now: () => now, maxEntries: 4);

      bool post(String path) => limiter
          .check(clientKey: 'client-a', method: 'POST', path: path)
          .allowed;

      final hot = contributePath('hot');
      var allowed = 0;
      for (var i = 0; i < highRiskControlRateLimitMaxRequests; i++) {
        if (post(hot)) allowed++;
        // Three cold keys per hot touch: more than maxEntries, so the table
        // turns over completely between touches of `hot`.
        post(contributePath('cold-$i-1'));
        post(contributePath('cold-$i-2'));
        post(contributePath('cold-$i-3'));
      }

      expect(allowed, highRiskControlRateLimitMaxRequests);
      expect(
        post(hot),
        isFalse,
        reason: 'the limit on a continuously-used key must still bite',
      );
    });
  });
}
