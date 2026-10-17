// Unit coverage: the public pairing mint endpoints carry an endpoint rate
// limit (keyed off the socket peer by the middleware), and the in-memory
// paired-session-token map is bounded with LRU-on-write eviction.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/headless_api/auth_policy.dart';
import 'package:skotiq_desktop/headless_api/route_metadata.dart';
import 'package:skotiq_desktop/headless_api_server.dart';

void main() {
  group('pairing endpoint rate limits', () {
    test('start / verify / lan-claim have an endpoint rate limit', () {
      for (final path in const [
        '/api/pairing/start',
        '/api/pairing/verify',
        '/api/pairing/lan-claim',
      ]) {
        final limit = endpointRateLimitFor(method: 'POST', path: path);
        expect(
          limit,
          isNotNull,
          reason: '$path must carry an endpoint rate limit',
        );
        expect(limit!.maxRequests, defaultControlRateLimitMaxRequests);
        expect(limit.window, defaultControlRateLimitWindow);
      }
    });

    test('the legacy endpoint limiter blocks a pairing-start flood', () {
      final now = DateTime(2026, 6, 27, 1);
      final limiter = EndpointRateLimiter(now: () => now);

      for (var i = 0; i < defaultControlRateLimitMaxRequests; i++) {
        final decision = limiter.check(
          clientKey: '203.0.113.7',
          method: 'POST',
          path: '/api/pairing/start',
        );
        expect(decision.allowed, isTrue, reason: 'request $i should pass');
      }

      final blocked = limiter.check(
        clientKey: '203.0.113.7',
        method: 'POST',
        path: '/api/pairing/start',
      );
      expect(blocked.allowed, isFalse);
      expect(blocked.retryAfterSeconds, greaterThan(0));

      // A different socket peer is unaffected (per-client keying preserved).
      final otherClient = limiter.check(
        clientKey: '198.51.100.4',
        method: 'POST',
        path: '/api/pairing/start',
      );
      expect(otherClient.allowed, isTrue);
    });
  });

  group('BoundedTokenGrantMap', () {
    final control = HeadlessAuthGrant.fromCoarse(HeadlessTokenScope.control);
    test('evicts the least-recently-written entry past the cap', () {
      final map = BoundedTokenGrantMap(maxEntries: 3);
      map['a'] = control;
      map['b'] = control;
      map['c'] = control;
      expect(map.length, 3);

      // Inserting a fourth distinct key evicts the oldest ('a').
      map['d'] = control;
      expect(map.length, 3);
      expect(map.containsKey('a'), isFalse);
      expect(map.containsKey('d'), isTrue);
    });

    test('re-writing a key refreshes its recency so it survives eviction', () {
      final map = BoundedTokenGrantMap(maxEntries: 3);
      map['a'] = control;
      map['b'] = control;
      map['c'] = control;

      // Touch 'a' so it becomes the most-recently-written; insertion order is
      // now b, c, a. The next insert must evict 'b', not 'a'.
      map['a'] = HeadlessAuthGrant.admin();
      map['d'] = control;

      expect(map.length, 3);
      expect(map.containsKey('a'), isTrue);
      expect(map['a']!.isAdmin, isTrue);
      expect(map.containsKey('b'), isFalse);
    });

    test('stays bounded under a flood of distinct tokens', () {
      final map = BoundedTokenGrantMap(maxEntries: 8);
      for (var i = 0; i < 10000; i++) {
        map['token-$i'] = control;
        expect(map.length, lessThanOrEqualTo(8));
      }
      expect(map.length, 8);
      // The most recent insert is always retained.
      expect(map.containsKey('token-9999'), isTrue);
    });
  });
}
