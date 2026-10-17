/// Fixed-window per-identity rate limiter, mirroring the headless server's
/// per-token throttle. Keyed by the authenticated token hash (or the peer
/// address for unauthenticated routes), it caps requests per window and is the
/// hub's first-line defense against a single contributor flooding the fusion
/// pipeline.
class RateLimiter {
  RateLimiter({
    this.maxRequests = 120,
    this.window = const Duration(minutes: 1),
  });

  /// Maximum requests permitted per [window] per identity.
  final int maxRequests;
  final Duration window;

  final Map<String, _Bucket> _buckets = <String, _Bucket>{};

  /// Returns true if a request from [identity] is allowed now, consuming one
  /// token from its window. Returns false (and does not consume) once the cap
  /// is hit until the window rolls over.
  bool allow(String identity, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final bucket = _buckets[identity];
    if (bucket == null || at.isAfter(bucket.windowEnd)) {
      _buckets[identity] = _Bucket(windowEnd: at.add(window), count: 1);
      return true;
    }
    if (bucket.count >= maxRequests) return false;
    bucket.count++;
    return true;
  }

  /// Seconds until [identity]'s window resets (for a Retry-After header).
  int retryAfterSeconds(String identity, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final bucket = _buckets[identity];
    if (bucket == null) return 0;
    final secs = bucket.windowEnd.difference(at).inSeconds;
    return secs < 0 ? 0 : secs;
  }

  /// Drop expired buckets so the map does not grow without bound. Safe to call
  /// periodically; a no-op for active identities.
  void sweep({DateTime? now}) {
    final at = now ?? DateTime.now();
    _buckets.removeWhere((_, b) => at.isAfter(b.windowEnd));
  }
}

class _Bucket {
  _Bucket({required this.windowEnd, required this.count});
  DateTime windowEnd;
  int count;
}

/// Per-account failed-login throttle, independent of the shared IP/token
/// [RateLimiter]. The IP limiter caps total request volume; it does NOT stop a
/// credential-stuffing attacker who rotates source addresses (or sits behind a
/// NAT/proxy that shares one address with legitimate users) from hammering a
/// single account's password. This counts *failed* logins per account and
/// temporarily locks the account out after [maxFailures] within [window],
/// regardless of where the attempts come from.
///
/// A successful login clears the account's counter via [recordSuccess], so a
/// legitimate user who mistypes once then succeeds is never penalized.
class LoginThrottle {
  LoginThrottle({
    this.maxFailures = 5,
    this.window = const Duration(minutes: 15),
    this.lockout = const Duration(minutes: 15),
  });

  /// Failed attempts within [window] before the account is locked.
  final int maxFailures;

  /// Sliding window over which failures accumulate.
  final Duration window;

  /// How long an account stays locked once [maxFailures] is reached.
  final Duration lockout;

  final Map<String, _LoginState> _states = <String, _LoginState>{};

  /// Whether [accountKey] is currently locked out. Identify the account by a
  /// stable key (the submitted public key) so the lock applies even when the
  /// key does not resolve to a real account — that prevents an attacker probing
  /// many guesses for one key from learning whether it exists by timing.
  bool isLocked(String accountKey, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final state = _states[accountKey];
    if (state == null) return false;
    final until = state.lockedUntil;
    return until != null && at.isBefore(until);
  }

  /// Seconds until [accountKey]'s lockout expires (for a Retry-After header).
  int retryAfterSeconds(String accountKey, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final until = _states[accountKey]?.lockedUntil;
    if (until == null) return 0;
    final secs = until.difference(at).inSeconds;
    return secs < 0 ? 0 : secs;
  }

  /// Record a failed login for [accountKey]. Returns true if this failure
  /// pushed the account into a locked state.
  bool recordFailure(String accountKey, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final state = _states.putIfAbsent(accountKey, _LoginState.new);
    // Reset the failure window if the last failure was long enough ago.
    if (state.windowStart == null ||
        at.isAfter(state.windowStart!.add(window))) {
      state.windowStart = at;
      state.failures = 0;
    }
    state.failures++;
    if (state.failures >= maxFailures) {
      state.lockedUntil = at.add(lockout);
      return true;
    }
    return false;
  }

  /// Clear [accountKey]'s failure state after a successful authentication.
  void recordSuccess(String accountKey) {
    _states.remove(accountKey);
  }

  /// Drop stale state so the map does not grow without bound.
  void sweep({DateTime? now}) {
    final at = now ?? DateTime.now();
    _states.removeWhere((_, s) {
      final lockExpired = s.lockedUntil == null || at.isAfter(s.lockedUntil!);
      final windowExpired =
          s.windowStart == null || at.isAfter(s.windowStart!.add(window));
      return lockExpired && windowExpired;
    });
  }
}

class _LoginState {
  DateTime? windowStart;
  int failures = 0;
  DateTime? lockedUntil;
}
