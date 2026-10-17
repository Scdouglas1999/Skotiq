//! Per-client jitter PRNG used by the reconnect backoff.

use super::*;

/// Shared, per-`IndiClient` PRNG handle.
///
/// Why: jitter must be uncorrelated between clients. A process-global PRNG
/// seeded from system time on first use (the previous design) collapsed to a
/// shared sequence the moment two clients raced through `get_or_init`, which
/// defeats jitter when many clients reconnect simultaneously against the same
/// INDI server. Wrapping `fastrand::Rng` in `Arc<StdMutex<...>>` lets us clone
/// the handle into the supervised-reader task while keeping per-instance state.
pub(super) type JitterRng = Arc<StdMutex<fastrand::Rng>>;

/// Build a unique-per-instance jitter PRNG.
///
/// Why: seeding from `host:port` + creation-time nanoseconds + a process-local
/// monotonic counter guarantees two clients constructed in the same wall-clock
/// nanosecond (e.g. two reconnect supervisors spawned from the same future)
/// still receive distinct streams. Without the counter, identical hostnames
/// constructed back-to-back could collide on coarse clocks.
pub(super) fn make_jitter_rng(host: &str, port: u16) -> JitterRng {
    use std::time::SystemTime;

    static INSTANCE_COUNTER: AtomicU64 = AtomicU64::new(0);

    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    host.hash(&mut hasher);
    port.hash(&mut hasher);
    let host_hash = hasher.finish();

    let now_nanos = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        // Why: u128 nanos since Unix epoch -> u64. u64::MAX nanos = ~584 years
        // from epoch (year 2554), so any wall clock before that is lossless.
        // After year 2554 the saturating cast becomes ID-seed jitter, which
        // the comment below explicitly notes is not load-bearing for uniqueness.
        .map(|d| d.as_nanos() as u64)
        // Why: `SystemTime::duration_since(UNIX_EPOCH)` only fails for
        // pre-1970 clocks. Zero is acceptable for ID-seeding because the per-process
        // counter and the host-hash already make the seed unique; the timestamp is
        // anti-collision jitter, not a correctness invariant.
        .unwrap_or(0);

    let counter = INSTANCE_COUNTER.fetch_add(1, Ordering::Relaxed);

    // Why: rotate before XOR so identical hosts in the same nanosecond still
    // diverge via the per-process counter — otherwise XOR of equal halves
    // cancels and the seed collapses to the counter alone.
    let seed = host_hash ^ now_nanos.rotate_left(17) ^ counter.wrapping_mul(0x9E37_79B9_7F4A_7C15);

    Arc::new(StdMutex::new(fastrand::Rng::with_seed(seed)))
}

/// Pull a uniform `[0.0, 1.0)` value from a `JitterRng`, falling back to a
/// fresh local PRNG if the mutex is poisoned.
///
/// Why: poisoning means a previous holder panicked while holding the lock; we
/// must not silently return a constant (the previous static-state design
/// effectively did that on race losers), but we also must not panic and drop
/// the reconnect loop. A fresh `fastrand::Rng::new()` is process-seeded and
/// still yields an uncorrelated value for the current call.
pub(super) fn jitter_sample(rng: &JitterRng) -> f64 {
    match rng.lock() {
        Ok(mut guard) => guard.f64(),
        Err(poisoned) => {
            tracing::warn!("INDI jitter RNG mutex poisoned; using fresh PRNG for this sample");
            // Recover the inner Rng so subsequent calls continue using the
            // per-instance stream instead of permanently degrading.
            let mut guard = poisoned.into_inner();
            *guard = fastrand::Rng::new();
            guard.f64()
        }
    }
}
