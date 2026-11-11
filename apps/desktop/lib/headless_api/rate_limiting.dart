/// Rate-limit budgets and the two limiters: the per-endpoint sliding window
/// and the per-token bucket.
library;

import 'path_classification.dart';

const Duration defaultControlRateLimitWindow = Duration(minutes: 1);
const int defaultControlRateLimitMaxRequests = 60;
const int highRiskControlRateLimitMaxRequests = 12;

class EndpointRateLimit {
  final int maxRequests;
  final Duration window;

  const EndpointRateLimit({required this.maxRequests, required this.window});
}

class RateLimitDecision {
  final bool allowed;
  final int maxRequests;
  final int retryAfterSeconds;

  /// which bucket — endpoint window or per-token route-class — produced
  /// this decision. `endpoint` is the legacy sliding-window check tied to a
  /// (clientKey, method, path) triple; `token-<class>` is the new token-
  /// bucket gate keyed by (tokenId, routeClass). Surfaced so 429 responses
  /// can name the bucket that tripped and the operator can tell whether the
  /// throttle came from "you've called this endpoint too often" or "your
  /// token used its read budget across many endpoints".
  final String bucket;

  const RateLimitDecision({
    required this.allowed,
    required this.maxRequests,
    required this.retryAfterSeconds,
    this.bucket = 'endpoint',
  });
}

/// per-token route class. NAT collapses many phones onto a single
/// public IP, so an IP-keyed rate limit either treats every device behind
/// the NAT as one client (DoS by neighbour) or wastes the gate entirely.
/// Keying the bucket on the authenticated token + a coarse route class
/// gives every token its own budget while still throttling pathological
/// callers within that token's session.
enum TokenRouteClass {
  /// Read-only state pulls (GET). 60 req/s allows a phone dashboard to
  /// poll status, devices, sequencer state, etc. at ~1 Hz across a dozen
  /// endpoints without bumping the limit.
  read,

  /// State-changing operations (POST/PUT/PATCH/DELETE). 20 req/s
  /// accommodates batched device-connect-on-startup and rapid sequence
  /// edits while still rate-limiting destructive bursts.
  write,

  /// JPEG live-view frames (`/api/camera/live-view/frame`). 30 req/s
  /// covers the design upper bound of ~10 fps with retry headroom.
  liveView,

  /// Full image downloads (`/api/images/.../download`, raw FITS pulls).
  /// 5 req/s — these are multi-MB transfers and the bottleneck is the
  /// disk + network, not the CPU, so we keep a tight ceiling.
  imageDownload,
}

/// Default per-second budgets for each token route class. Held in a
/// separate const so tests can override them via [TokenBucketRateLimiter]'s
/// `configForClass` injection point without having to monkey-patch the
/// router.
const Map<TokenRouteClass, TokenBucketConfig> defaultTokenBucketConfigs = {
  TokenRouteClass.read: TokenBucketConfig(
    capacity: 60,
    refillTokens: 60,
    refillPeriod: Duration(seconds: 1),
  ),
  TokenRouteClass.write: TokenBucketConfig(
    capacity: 20,
    refillTokens: 20,
    refillPeriod: Duration(seconds: 1),
  ),
  TokenRouteClass.liveView: TokenBucketConfig(
    capacity: 30,
    refillTokens: 30,
    refillPeriod: Duration(seconds: 1),
  ),
  TokenRouteClass.imageDownload: TokenBucketConfig(
    capacity: 5,
    refillTokens: 5,
    refillPeriod: Duration(seconds: 1),
  ),
};

/// Classify a request to its [TokenRouteClass]. Live-view frames and
/// image downloads take precedence over the read/write split because they
/// have their own (tighter) budgets.
TokenRouteClass tokenRouteClassFor({
  required String method,
  required String path,
}) {
  final normalizedPath = path.startsWith('/') ? path : '/$path';
  final normalizedMethod = method.toUpperCase();
  // Live-view frames are the highest-throughput endpoint and must not
  // share a bucket with cheap state polls.
  if (normalizedPath == '/api/camera/live-view/frame') {
    return TokenRouteClass.liveView;
  }
  // WebRTC live-view signalling endpoints share the
  // live-view bucket because the SSE candidate stream + ICE POSTs
  // burst during session setup (potentially many candidates per
  // second on a complex network) and we don't want a paired phone
  // bringing up a fresh peer connection to exhaust its `read`
  // budget mid-handshake. The actual JPEG datachannel traffic
  // doesn't pass through this gate (it's WebRTC, not HTTP), so the
  // bucket only governs the signalling overhead.
  if (normalizedPath.startsWith('/api/webrtc/live-view/')) {
    return TokenRouteClass.liveView;
  }
  // Multi-MB transfers: image download + raw image bytes + binary FITS
  // pull. They live in their own (tightest) bucket.
  if (normalizedPath.startsWith('/api/images/') &&
      normalizedPath.endsWith('/download')) {
    return TokenRouteClass.imageDownload;
  }
  if (normalizedPath == '/api/imaging/raw-data' ||
      (normalizedPath.startsWith('/api/calibration/') &&
          normalizedPath.endsWith('/download')) ||
      (normalizedPath.startsWith('/api/backup/') &&
          normalizedPath.endsWith('/download')) ||
      (normalizedPath.startsWith('/api/logs/files/') &&
          normalizedPath.endsWith('/download'))) {
    return TokenRouteClass.imageDownload;
  }
  if (normalizedMethod == 'GET' || normalizedMethod == 'HEAD') {
    return TokenRouteClass.read;
  }
  return TokenRouteClass.write;
}

/// Human-readable name used in 429 bodies + log lines. Aligns with the
/// task spec wording (`read`, `write`, `live-view`, `image-download`).
String tokenRouteClassName(TokenRouteClass cls) {
  switch (cls) {
    case TokenRouteClass.read:
      return 'read';
    case TokenRouteClass.write:
      return 'write';
    case TokenRouteClass.liveView:
      return 'live-view';
    case TokenRouteClass.imageDownload:
      return 'image-download';
  }
}

/// Configuration for a single token-bucket. The bucket holds at most
/// [capacity] tokens and refills [refillTokens] every [refillPeriod].
class TokenBucketConfig {
  final int capacity;
  final int refillTokens;
  final Duration refillPeriod;

  const TokenBucketConfig({
    required this.capacity,
    required this.refillTokens,
    required this.refillPeriod,
  });

  /// Tokens added per microsecond. Computed lazily by the limiter; held as
  /// a method (not a getter) to keep the type a const-friendly value type.
  double refillPerMicrosecond() => refillTokens / refillPeriod.inMicroseconds;
}

/// token-bucket rate limiter keyed by `(tokenId, route_class)`.
///
/// In-memory only — counters reset on server restart. Memory bound: one
/// bucket per (token × class) pair, evicted by LRU once the table exceeds
/// [maxBuckets]. Default [maxBuckets] (8192) holds 2048 tokens at four
/// classes each, well past any realistic paired-device count.
class TokenBucketRateLimiter {
  final Map<TokenRouteClass, TokenBucketConfig> _configByClass;
  final DateTime Function() _now;
  final int maxBuckets;

  // Linked-map preserves insertion order, which we use as a poor-man's LRU:
  // every touch removes-and-reinserts the entry so the front of the map is
  // the coldest bucket we'll evict next.
  final _buckets = <String, _TokenBucketState>{};

  TokenBucketRateLimiter({
    Map<TokenRouteClass, TokenBucketConfig>? configByClass,
    DateTime Function()? now,
    this.maxBuckets = 8192,
  }) : _configByClass = configByClass ?? defaultTokenBucketConfigs,
       _now = now ?? DateTime.now;

  /// Look up the configuration for a class. Returns the default config if
  /// the caller-supplied map omitted it (defensive — every class should
  /// have an entry but a partial override should still produce a valid
  /// decision rather than a null deref).
  TokenBucketConfig configFor(TokenRouteClass cls) {
    return _configByClass[cls] ?? defaultTokenBucketConfigs[cls]!;
  }

  /// Attempt to consume one token from `(tokenId, routeClass)`'s bucket.
  /// Returns a decision indicating whether the request is allowed plus
  /// the [Duration] until the next token becomes available on a denial.
  RateLimitDecision tryConsume({
    required String tokenId,
    required TokenRouteClass routeClass,
  }) {
    final config = configFor(routeClass);
    final key = '$tokenId|${tokenRouteClassName(routeClass)}';
    final now = _now();
    var state = _buckets.remove(key);
    state ??= _TokenBucketState(
      tokens: config.capacity.toDouble(),
      lastRefillMicros: now.microsecondsSinceEpoch,
    );

    // Refill based on wall-clock elapsed. Why microsecond resolution: at
    // 60 req/s the per-token interval is ~16.6 ms, so millisecond math
    // would round trips into 0 and starve the bucket between two close
    // requests. Microseconds give us the precision the budget needs.
    final elapsedMicros = now.microsecondsSinceEpoch - state.lastRefillMicros;
    if (elapsedMicros > 0) {
      final added = elapsedMicros * config.refillPerMicrosecond();
      state.tokens = (state.tokens + added).clamp(
        0.0,
        config.capacity.toDouble(),
      );
      state.lastRefillMicros = now.microsecondsSinceEpoch;
    }

    final bucketName = 'token-${tokenRouteClassName(routeClass)}';

    if (state.tokens < 1.0) {
      // How long until tokens >= 1? deficit / refill-rate.
      final deficit = 1.0 - state.tokens;
      final refillRate = config.refillPerMicrosecond();
      final retryMicros = refillRate > 0
          ? (deficit / refillRate).ceil()
          : config.refillPeriod.inMicroseconds;
      // Re-insert at the back of the LRU.
      _buckets[key] = state;
      _evictIfOverCapacity();
      final retrySeconds = (retryMicros / 1000000).ceil();
      return RateLimitDecision(
        allowed: false,
        maxRequests: config.capacity,
        retryAfterSeconds: retrySeconds < 1 ? 1 : retrySeconds,
        bucket: bucketName,
      );
    }

    state.tokens -= 1.0;
    _buckets[key] = state;
    _evictIfOverCapacity();
    return RateLimitDecision(
      allowed: true,
      maxRequests: config.capacity,
      retryAfterSeconds: 0,
      bucket: bucketName,
    );
  }

  void _evictIfOverCapacity() {
    while (_buckets.length > maxBuckets) {
      _buckets.remove(_buckets.keys.first);
    }
  }

  /// Test helper: drop all state.
  void clear() {
    _buckets.clear();
  }

  /// Test helper: current token level for a key (useful for asserting
  /// refill behaviour without driving the public path).
  double? tokensFor({
    required String tokenId,
    required TokenRouteClass routeClass,
  }) {
    final key = '$tokenId|${tokenRouteClassName(routeClass)}';
    return _buckets[key]?.tokens;
  }
}

class _TokenBucketState {
  double tokens;
  int lastRefillMicros;
  _TokenBucketState({required this.tokens, required this.lastRefillMicros});
}

/// Ceiling on tracked `(client, method, path)` keys. Matches
/// [TokenBucketRateLimiter.maxBuckets]: far past any legitimate fan-out, and
/// small enough that the table cannot grow without bound over a long
/// unattended run.
const int defaultEndpointRateLimiterMaxEntries = 8192;

/// Sliding-window limiter keyed by `(clientKey, method, concrete path)`.
///
/// Several rate-limited prefixes are parametric (`/api/mosaic/`,
/// `/api/coimaging/`), so a long collaborative run mints a fresh key per
/// session id. Entries are therefore evicted LRU past [maxEntries], the same
/// way [TokenBucketRateLimiter] bounds its buckets. Eviction resets a key's
/// window, but reaching the cap takes [maxEntries] distinct paths from one
/// peer, and the per-token bucket limiter — which keys on the token rather
/// than the path — is what actually bounds a hostile client.
class EndpointRateLimiter {
  final DateTime Function() _now;
  final int maxEntries;

  // Insertion order doubles as the LRU order: every touch removes and
  // reinserts, so the front of the map is the coldest key.
  final _requestsByKey = <String, List<DateTime>>{};

  EndpointRateLimiter({
    DateTime Function()? now,
    this.maxEntries = defaultEndpointRateLimiterMaxEntries,
  }) : _now = now ?? DateTime.now;

  RateLimitDecision check({
    required String clientKey,
    required String method,
    required String path,
  }) {
    final limit = endpointRateLimitFor(method: method, path: path);
    if (limit == null) {
      return const RateLimitDecision(
        allowed: true,
        maxRequests: 0,
        retryAfterSeconds: 0,
      );
    }

    final now = _now();
    final key = '$clientKey ${method.toUpperCase()} $path';
    final cutoff = now.subtract(limit.window);
    final requests = _requestsByKey.remove(key) ?? <DateTime>[];
    requests.removeWhere((timestamp) => !timestamp.isAfter(cutoff));

    if (requests.length >= limit.maxRequests) {
      final oldest = requests.first;
      final retryAfter = oldest.add(limit.window).difference(now);
      _retain(key, requests);
      return RateLimitDecision(
        allowed: false,
        maxRequests: limit.maxRequests,
        retryAfterSeconds: retryAfter.inSeconds < 1 ? 1 : retryAfter.inSeconds,
      );
    }

    requests.add(now);
    _retain(key, requests);
    return RateLimitDecision(
      allowed: true,
      maxRequests: limit.maxRequests,
      retryAfterSeconds: 0,
    );
  }

  /// Reinsert at the back of the LRU, then trim. A key whose window has
  /// fully expired carries no state worth holding, so it is dropped outright
  /// rather than waiting its turn to be evicted.
  void _retain(String key, List<DateTime> requests) {
    if (requests.isEmpty) return;
    _requestsByKey[key] = requests;
    while (_requestsByKey.length > maxEntries) {
      _requestsByKey.remove(_requestsByKey.keys.first);
    }
  }

  void clear() {
    _requestsByKey.clear();
  }
}
