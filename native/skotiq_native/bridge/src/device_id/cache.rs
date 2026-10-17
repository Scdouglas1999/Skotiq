use super::*;

/// Default cache capacity for parsed device IDs.
/// A typical astrophotography setup has 5-10 devices, so 64 provides
/// ample room for multiple sessions without excessive memory usage.
pub(crate) const DEFAULT_CACHE_CAPACITY: usize = 64;

/// Global cache for parsed device IDs with LRU eviction.
/// Thread-safe via Mutex, with atomic counters for metrics.
pub(crate) static DEVICE_ID_CACHE: std::sync::OnceLock<DeviceIdCache> = std::sync::OnceLock::new();

/// Cache metrics for monitoring hit rates and performance.
#[derive(Debug, Default)]
pub struct CacheMetrics {
    /// Number of cache hits
    pub(crate) hits: AtomicU64,
    /// Number of cache misses
    pub(crate) misses: AtomicU64,
    /// Number of entries evicted due to capacity
    pub(crate) evictions: AtomicU64,
}

impl CacheMetrics {
    /// Get the current number of cache hits
    pub fn hits(&self) -> u64 {
        self.hits.load(Ordering::Relaxed)
    }

    /// Get the current number of cache misses
    pub fn misses(&self) -> u64 {
        self.misses.load(Ordering::Relaxed)
    }

    /// Get the current number of evictions
    pub fn evictions(&self) -> u64 {
        self.evictions.load(Ordering::Relaxed)
    }

    /// Get the cache hit rate as a percentage (0.0 to 100.0)
    pub fn hit_rate(&self) -> f64 {
        // Why: hit/miss counters are u64 atomics; u64 →
        // f64 precision loss is bounded by the mantissa (53 bits) — for
        // hit-rate-as-percentage display, any imprecision past 10^15 cache
        // operations is invisible.
        let hits = self.hits() as f64;
        let total = hits + self.misses() as f64;
        if total == 0.0 {
            0.0
        } else {
            (hits / total) * 100.0
        }
    }

    /// Increment the hit counter
    pub(crate) fn record_hit(&self) {
        self.hits.fetch_add(1, Ordering::Relaxed);
    }

    /// Increment the miss counter
    pub(crate) fn record_miss(&self) {
        self.misses.fetch_add(1, Ordering::Relaxed);
    }

    /// Increment the eviction counter
    pub(crate) fn record_eviction(&self) {
        self.evictions.fetch_add(1, Ordering::Relaxed);
    }

    /// Reset all metrics (useful for testing)
    pub fn reset(&self) {
        self.hits.store(0, Ordering::Relaxed);
        self.misses.store(0, Ordering::Relaxed);
        self.evictions.store(0, Ordering::Relaxed);
    }
}

/// Thread-safe LRU cache for parsed device IDs.
pub struct DeviceIdCache {
    pub(crate) cache: Mutex<LruCache<String, ParsedDeviceId>>,
    pub(crate) metrics: CacheMetrics,
}

impl DeviceIdCache {
    /// Create a new cache with the specified capacity.
    ///
    /// Every `unwrap` in this type is panic-free by construction:
    ///
    /// * `NonZeroUsize::new(capacity).unwrap_or(...)` — a caller-supplied zero
    ///   capacity means "use `DEFAULT_CACHE_CAPACITY`" rather than a panic, and
    ///   the inner `unwrap()` reads that compile-time constant, which is
    ///   non-zero.
    /// * `self.cache.lock().unwrap_or_else(|e| e.into_inner())` (five sites) —
    ///   poison recovery. A panic while the lock was held can leave the LRU
    ///   inconsistent, but this cache is a pure optimisation around
    ///   `ParsedDeviceId::parse`, so the worst a recovered lock yields is a
    ///   stale entry, which every caller's `Option` already tolerates.
    pub(crate) fn new(capacity: usize) -> Self {
        let cap = NonZeroUsize::new(capacity)
            .unwrap_or(NonZeroUsize::new(DEFAULT_CACHE_CAPACITY).unwrap());
        Self {
            cache: Mutex::new(LruCache::new(cap)),
            metrics: CacheMetrics::default(),
        }
    }

    /// Get a cached entry, updating LRU order.
    /// Returns a clone of the cached value if found.
    pub(crate) fn get(&self, key: &str) -> Option<ParsedDeviceId> {
        let mut cache = self.cache.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(value) = cache.get(key) {
            self.metrics.record_hit();
            Some(value.clone())
        } else {
            self.metrics.record_miss();
            None
        }
    }

    /// Insert a new entry, potentially evicting the LRU entry.
    pub(crate) fn put(&self, key: String, value: ParsedDeviceId) {
        let mut cache = self.cache.lock().unwrap_or_else(|e| e.into_inner());
        // Check if we're at capacity and will evict
        if cache.len() >= cache.cap().get() && !cache.contains(&key) {
            self.metrics.record_eviction();
        }
        cache.put(key, value);
    }

    /// Remove a specific entry from the cache.
    /// Useful when a device is disconnected or configuration changes.
    pub fn invalidate(&self, key: &str) {
        let mut cache = self.cache.lock().unwrap_or_else(|e| e.into_inner());
        cache.pop(key);
    }

    /// Clear all cached entries.
    pub fn clear(&self) {
        let mut cache = self.cache.lock().unwrap_or_else(|e| e.into_inner());
        cache.clear();
    }

    /// Get the current number of entries in the cache.
    pub fn len(&self) -> usize {
        let cache = self.cache.lock().unwrap_or_else(|e| e.into_inner());
        cache.len()
    }

    /// Check if the cache is empty.
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Get a reference to the cache metrics.
    pub fn metrics(&self) -> &CacheMetrics {
        &self.metrics
    }
}

/// Get the global device ID cache, initializing it if necessary.
pub(crate) fn get_cache() -> &'static DeviceIdCache {
    DEVICE_ID_CACHE.get_or_init(|| DeviceIdCache::new(DEFAULT_CACHE_CAPACITY))
}

/// Parse a device ID with caching.
///
/// The primary entry point for parsing device IDs: a cache hit returns a clone of
/// the stored parse, a miss parses and stores it.
pub fn parse_device_id_cached(device_id: &str) -> Result<ParsedDeviceId, SkotiqError> {
    let cache = get_cache();

    // Check cache first
    if let Some(cached) = cache.get(device_id) {
        tracing::trace!("Device ID cache hit: {}", device_id);
        return Ok(cached);
    }

    // Cache miss - parse and store
    tracing::trace!("Device ID cache miss: {}", device_id);
    let parsed = ParsedDeviceId::parse(device_id)?;
    cache.put(device_id.to_string(), parsed.clone());
    Ok(parsed)
}

/// Get current cache statistics.
///
/// Returns a snapshot of cache metrics including hits, misses, and evictions.
pub fn get_device_id_cache_stats() -> DeviceIdCacheStats {
    let cache = get_cache();
    DeviceIdCacheStats {
        size: cache.len(),
        hits: cache.metrics().hits(),
        misses: cache.metrics().misses(),
        evictions: cache.metrics().evictions(),
        hit_rate: cache.metrics().hit_rate(),
    }
}

/// Invalidate a specific device ID from the cache.
///
/// Call this when a device is disconnected or its configuration changes.
pub fn invalidate_device_id_cache(device_id: &str) {
    get_cache().invalidate(device_id);
    tracing::debug!("Invalidated device ID cache entry: {}", device_id);
}

/// Clear the entire device ID cache.
///
/// Call this when switching profiles or during cleanup.
pub fn clear_device_id_cache() {
    get_cache().clear();
    tracing::debug!("Cleared device ID cache");
}

/// Reset cache metrics (primarily for testing).
pub fn reset_device_id_cache_metrics() {
    get_cache().metrics().reset();
}

/// Snapshot of cache statistics.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceIdCacheStats {
    /// Current number of entries in the cache
    pub size: usize,
    /// Total number of cache hits
    pub hits: u64,
    /// Total number of cache misses
    pub misses: u64,
    /// Total number of evictions
    pub evictions: u64,
    /// Cache hit rate as a percentage (0.0 to 100.0)
    pub hit_rate: f64,
}

impl std::fmt::Display for DeviceIdCacheStats {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "DeviceIdCache {{ size: {}, hits: {}, misses: {}, evictions: {}, hit_rate: {:.1}% }}",
            self.size, self.hits, self.misses, self.evictions, self.hit_rate
        )
    }
}
