//! Buffer Pool for Image Capture
//!
//! Provides reusable buffer allocation for high-throughput image capture scenarios.
//! This reduces memory allocation overhead and fragmentation when capturing many
//! frames from large sensors (4K+).
//!
//! # Features
//!
//! - Pre-allocates reusable buffers to avoid repeated allocation
//! - Thread-safe implementation using Arc and Mutex
//! - Automatic buffer return via Drop trait on PooledBuffer
//! - Configurable pool size limits and buffer size buckets
//! - Metrics tracking for pool utilization analysis
//!
//! # Example
//!
//! ```no_run
//! use skotiq_imaging::buffer_pool::{BufferPool, BufferPoolConfig};
//!
//! // Create a pool for 16-bit image data
//! let config = BufferPoolConfig {
//!     initial_capacity: 2,
//!     max_capacity: 8,
//!     size_buckets: vec![
//!         4144 * 2822,        // ASI2600 full frame
//!         4656 * 3520,        // ASI6200 full frame
//!         9576 * 6388,        // ASI128 full frame
//!     ],
//!     ..Default::default()
//! };
//! let pool: BufferPool<u16> = BufferPool::new(config);
//!
//! // Get a buffer from the pool (or allocate new if none available)
//! let buffer = pool.get_buffer(4144 * 2822);
//!
//! // Use the buffer...
//! // buffer.as_slice_mut()[0] = 12345;
//!
//! // Buffer automatically returns to pool when dropped
//! drop(buffer);
//! ```

use std::collections::HashMap;
use std::marker::PhantomData;
use std::ops::{Deref, DerefMut};
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;

/// Default pool TTL: idle buffers older than this are evicted on the next
/// pool operation. 60 s balances reuse-during-imaging-burst against tying up
/// hundreds of MB during long idle periods.
pub const DEFAULT_POOL_TTL: Duration = Duration::from_secs(60);

/// Default total-pool memory cap (number of T elements) per pool. Prevents
/// the pre-existing pin-everything-forever behavior from holding gigabytes
/// after a burst. 6 buckets × 2 buffers × 9576×6388 ≈ 730 MiB worth of u16
/// elements (1.4 GiB bytes). The cap is per-pool — a u8 pool and a u16 pool
/// both run their own caps.
pub const DEFAULT_POOL_MAX_TOTAL_ELEMENTS: usize = 4 * 9576 * 6388;

/// Configuration for buffer pool behavior
#[derive(Debug, Clone)]
pub struct BufferPoolConfig {
    /// Number of buffers to pre-allocate for each size bucket
    pub initial_capacity: usize,
    /// Maximum number of buffers to keep in pool per bucket (excess are dropped)
    pub max_capacity: usize,
    /// Common buffer sizes to pre-allocate buckets for
    /// Buffers are rounded up to the nearest bucket size
    pub size_buckets: Vec<usize>,
    /// Maximum lifetime for an idle buffer in the pool.
    /// `None` disables time-based eviction (not recommended in production).
    /// Why: the prior pool never returned memory to the
    /// allocator; large unused buffers from a one-off capture stayed pinned
    /// indefinitely.
    pub idle_ttl: Option<Duration>,
    /// Cap on the total number of `T` elements held by pooled buffers, summed
    /// across every bucket. When returning a buffer would exceed the cap, the
    /// oldest pooled buffer (LRU) is evicted to make room. Set to `None` for
    /// no cap (the prior unbounded behavior — discouraged).
    pub max_total_elements: Option<usize>,
}

impl Default for BufferPoolConfig {
    fn default() -> Self {
        Self {
            // previous defaults were initial=2/max=8, which
            // could pin ~5.8 GiB across all buckets at full sensor sizes. We
            // reduce max_capacity so steady-state is bounded; combined with
            // TTL + total-element cap below, idle memory shrinks.
            initial_capacity: 1,
            max_capacity: 4,
            // Common sensor sizes in pixels (for u16 buffers, multiply by 2 for bytes)
            size_buckets: vec![
                1936 * 1096, // Small sensors (ASI120)
                2048 * 2048, // 4MP square sensors
                4144 * 2822, // ASI2600 (11.7MP)
                4656 * 3520, // ASI6200 (16.4MP)
                6248 * 4176, // ASI2400 (26MP)
                9576 * 6388, // ASI128 (61MP)
            ],
            idle_ttl: Some(DEFAULT_POOL_TTL),
            max_total_elements: Some(DEFAULT_POOL_MAX_TOTAL_ELEMENTS),
        }
    }
}

/// Metrics for buffer pool utilization
#[derive(Debug, Default)]
pub struct BufferPoolMetrics {
    /// Number of times a buffer was retrieved from the pool (hit)
    pub hits: AtomicU64,
    /// Number of times a new buffer had to be allocated (miss)
    pub misses: AtomicU64,
    /// Number of buffers currently in the pool (available)
    pub pool_size: AtomicUsize,
    /// Number of buffers currently checked out (in use)
    pub active_buffers: AtomicUsize,
    /// Total number of buffers ever allocated
    pub total_allocations: AtomicU64,
    /// Number of buffers dropped due to pool being at max capacity
    pub dropped_returns: AtomicU64,
}

impl BufferPoolMetrics {
    /// Get a snapshot of current metrics
    pub fn snapshot(&self) -> MetricsSnapshot {
        MetricsSnapshot {
            hits: self.hits.load(Ordering::Relaxed),
            misses: self.misses.load(Ordering::Relaxed),
            pool_size: self.pool_size.load(Ordering::Relaxed),
            active_buffers: self.active_buffers.load(Ordering::Relaxed),
            total_allocations: self.total_allocations.load(Ordering::Relaxed),
            dropped_returns: self.dropped_returns.load(Ordering::Relaxed),
        }
    }

    /// Calculate hit rate (0.0 - 1.0)
    pub fn hit_rate(&self) -> f64 {
        let hits = self.hits.load(Ordering::Relaxed);
        let misses = self.misses.load(Ordering::Relaxed);
        let total = hits + misses;
        if total == 0 {
            0.0
        } else {
            hits as f64 / total as f64
        }
    }
}

/// Snapshot of metrics at a point in time
#[derive(Debug, Clone)]
pub struct MetricsSnapshot {
    pub hits: u64,
    pub misses: u64,
    pub pool_size: usize,
    pub active_buffers: usize,
    pub total_allocations: u64,
    pub dropped_returns: u64,
}

impl MetricsSnapshot {
    /// Calculate hit rate (0.0 - 1.0)
    pub fn hit_rate(&self) -> f64 {
        let total = self.hits + self.misses;
        if total == 0 {
            0.0
        } else {
            self.hits as f64 / total as f64
        }
    }
}

/// Inner pool storage, protected by mutex
struct PoolInner<T> {
    /// Buffers organized by size bucket
    buckets: HashMap<usize, Vec<Vec<T>>>,
    /// Configuration
    config: BufferPoolConfig,
    /// Sorted bucket sizes for efficient lookup
    sorted_buckets: Vec<usize>,
}

impl<T> PoolInner<T>
where
    T: Default + Clone,
{
    fn new(config: BufferPoolConfig) -> Self {
        let mut buckets = HashMap::new();
        let mut sorted_buckets = config.size_buckets.clone();
        sorted_buckets.sort_unstable();

        // Pre-allocate buffers for each bucket
        for &size in &sorted_buckets {
            let mut bucket_buffers = Vec::with_capacity(config.max_capacity);
            for _ in 0..config.initial_capacity {
                bucket_buffers.push(vec![T::default(); size]);
            }
            buckets.insert(size, bucket_buffers);
        }

        Self {
            buckets,
            config,
            sorted_buckets,
        }
    }

    /// Find the appropriate bucket size for a given request
    fn find_bucket_size(&self, requested_size: usize) -> usize {
        // Find the smallest bucket that can accommodate the requested size
        for &bucket_size in &self.sorted_buckets {
            if bucket_size >= requested_size {
                return bucket_size;
            }
        }
        // If no bucket is large enough, use exact size (will be its own bucket)
        requested_size
    }

    /// Try to get a buffer from the pool
    fn try_get(&mut self, bucket_size: usize) -> Option<Vec<T>> {
        if let Some(bucket) = self.buckets.get_mut(&bucket_size) {
            bucket.pop()
        } else {
            None
        }
    }

    /// Return a buffer to the pool
    fn return_buffer(&mut self, mut buffer: Vec<T>, bucket_size: usize) -> bool {
        // Get or create the bucket
        let bucket = self.buckets.entry(bucket_size).or_default();

        // Check if we're at capacity
        if bucket.len() >= self.config.max_capacity {
            return false; // Buffer will be dropped
        }

        // Clear the buffer content but keep capacity
        // For security/privacy, we zero out the data
        buffer.iter_mut().for_each(|x| *x = T::default());

        bucket.push(buffer);
        true
    }

    /// Get total number of buffers in pool
    fn total_pool_size(&self) -> usize {
        self.buckets.values().map(|b| b.len()).sum()
    }
}

/// Thread-safe buffer pool for reusable allocations
///
/// The pool maintains buffers organized by size buckets. When a buffer is
/// requested, the pool returns an existing buffer if available, or allocates
/// a new one. When the PooledBuffer is dropped, it automatically returns
/// to the pool.
pub struct BufferPool<T> {
    inner: Arc<Mutex<PoolInner<T>>>,
    metrics: Arc<BufferPoolMetrics>,
    _marker: PhantomData<T>,
}

impl<T> Clone for BufferPool<T> {
    fn clone(&self) -> Self {
        Self {
            inner: Arc::clone(&self.inner),
            metrics: Arc::clone(&self.metrics),
            _marker: PhantomData,
        }
    }
}

impl<T> BufferPool<T>
where
    T: Default + Clone + Send + 'static,
{
    /// Create a new buffer pool with the given configuration
    pub fn new(config: BufferPoolConfig) -> Self {
        let initial_pool_size: usize = config.size_buckets.len() * config.initial_capacity;
        let total_allocations = config.size_buckets.len() as u64 * config.initial_capacity as u64;

        let metrics = Arc::new(BufferPoolMetrics {
            pool_size: AtomicUsize::new(initial_pool_size),
            total_allocations: AtomicU64::new(total_allocations),
            ..Default::default()
        });

        Self {
            inner: Arc::new(Mutex::new(PoolInner::new(config))),
            metrics,
            _marker: PhantomData,
        }
    }

    /// Create a pool with default configuration
    pub fn with_defaults() -> Self {
        Self::new(BufferPoolConfig::default())
    }

    /// Take a buffer of at least `min_size` elements from the pool, allocating
    /// one if no bucket has a spare. The returned `PooledBuffer` is used like a
    /// `Vec<T>` and returns itself to the pool on drop.
    pub fn get_buffer(&self, min_size: usize) -> PooledBuffer<T> {
        let (buffer, bucket_size, was_hit) = {
            // Why: unpoisonable-Mutex idiom — `std::sync::Mutex::lock`
            // only returns Err when a prior holder panicked while holding the guard;
            // `e.into_inner()` retrieves the still-valid guard. The buffer-pool inner
            // state is a HashMap+Vec<Vec<T>> with no invariants that a panicked
            // allocator could leave inconsistent (allocations are wrapped in
            // catch_unwind by Rust's own runtime). Equivalent to parking_lot::Mutex.
            let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
            let bucket_size = inner.find_bucket_size(min_size);

            if let Some(mut buffer) = inner.try_get(bucket_size) {
                // Resize if needed (should rarely happen for bucket matches)
                if buffer.len() < min_size {
                    buffer.resize(min_size, T::default());
                }
                (buffer, bucket_size, true)
            } else {
                // Allocate new buffer at bucket size
                let buffer = vec![T::default(); bucket_size.max(min_size)];
                (buffer, bucket_size, false)
            }
        };

        // Update metrics
        if was_hit {
            self.metrics.hits.fetch_add(1, Ordering::Relaxed);
            self.metrics.pool_size.fetch_sub(1, Ordering::Relaxed);
        } else {
            self.metrics.misses.fetch_add(1, Ordering::Relaxed);
            self.metrics
                .total_allocations
                .fetch_add(1, Ordering::Relaxed);
        }
        self.metrics.active_buffers.fetch_add(1, Ordering::Relaxed);

        PooledBuffer {
            buffer,
            bucket_size,
            pool: Arc::downgrade(&self.inner),
            metrics: Arc::clone(&self.metrics),
            detached: false,
        }
    }

    /// Get current pool metrics
    pub fn metrics(&self) -> &BufferPoolMetrics {
        &self.metrics
    }

    /// Get a snapshot of current metrics
    pub fn metrics_snapshot(&self) -> MetricsSnapshot {
        self.metrics.snapshot()
    }

    /// Clear all buffers from the pool
    ///
    /// This does not affect currently checked-out buffers. When they are
    /// returned, they will be added back to the pool (up to max_capacity).
    pub fn clear(&self) {
        let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        let pool_size: usize = inner.buckets.values().map(|b| b.len()).sum();
        inner.buckets.values_mut().for_each(|b| b.clear());
        self.metrics
            .pool_size
            .fetch_sub(pool_size, Ordering::Relaxed);
    }

    /// Get the current number of buffers in the pool
    pub fn pool_size(&self) -> usize {
        // Why: unpoisonable-Mutex idiom; see get_buffer above.
        let inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        inner.total_pool_size()
    }

    /// Get the number of currently active (checked out) buffers
    pub fn active_buffers(&self) -> usize {
        self.metrics.active_buffers.load(Ordering::Relaxed)
    }
}

impl<T> Default for BufferPool<T>
where
    T: Default + Clone + Send + 'static,
{
    fn default() -> Self {
        Self::with_defaults()
    }
}

/// A buffer borrowed from the pool
///
/// This wrapper ensures the buffer is returned to the pool when dropped.
/// It implements Deref and DerefMut to allow using it like a Vec<T>.
pub struct PooledBuffer<T: Default + Clone> {
    buffer: Vec<T>,
    bucket_size: usize,
    pool: Weak<Mutex<PoolInner<T>>>,
    metrics: Arc<BufferPoolMetrics>,
    detached: bool,
}

impl<T> PooledBuffer<T>
where
    T: Default + Clone,
{
    /// Get the buffer as a slice
    pub fn as_slice(&self) -> &[T] {
        self.buffer.as_slice()
    }

    /// Get the buffer as a mutable slice
    pub fn as_slice_mut(&mut self) -> &mut [T] {
        self.buffer.as_mut_slice()
    }

    /// Get the length of the buffer
    pub fn len(&self) -> usize {
        self.buffer.len()
    }

    /// Check if the buffer is empty
    pub fn is_empty(&self) -> bool {
        self.buffer.is_empty()
    }

    /// Consume the PooledBuffer and return the inner Vec
    ///
    /// WARNING: This prevents the buffer from being returned to the pool.
    /// Only use this when you need to transfer ownership and don't care
    /// about pool reuse (e.g., final image output).
    pub fn into_vec(mut self) -> Vec<T> {
        self.metrics.active_buffers.fetch_sub(1, Ordering::Relaxed);
        self.detached = true;
        std::mem::take(&mut self.buffer)
    }

    /// Resize the buffer
    ///
    /// If the new size is larger than the current capacity, this may
    /// reallocate. The buffer will still return to the pool on drop.
    pub fn resize(&mut self, new_len: usize) {
        self.buffer.resize(new_len, T::default());
    }

    /// Truncate the buffer to a smaller length
    pub fn truncate(&mut self, len: usize) {
        self.buffer.truncate(len);
    }

    /// Get an iterator over the buffer
    pub fn iter(&self) -> std::slice::Iter<'_, T> {
        self.buffer.iter()
    }

    /// Get a mutable iterator over the buffer
    pub fn iter_mut(&mut self) -> std::slice::IterMut<'_, T> {
        self.buffer.iter_mut()
    }
}

impl<T: Default + Clone> Deref for PooledBuffer<T> {
    type Target = [T];

    fn deref(&self) -> &Self::Target {
        self.buffer.as_slice()
    }
}

impl<T: Default + Clone> DerefMut for PooledBuffer<T> {
    fn deref_mut(&mut self) -> &mut Self::Target {
        self.buffer.as_mut_slice()
    }
}

impl<T: Default + Clone> Drop for PooledBuffer<T> {
    fn drop(&mut self) {
        if !self.detached {
            let buffer = std::mem::take(&mut self.buffer);
            // Try to return to pool
            if let Some(pool) = self.pool.upgrade() {
                let returned = {
                    // Why: unpoisonable-Mutex idiom; see get_buffer above.
                    let mut inner = pool.lock().unwrap_or_else(|e| e.into_inner());
                    inner.return_buffer(buffer, self.bucket_size)
                };

                if returned {
                    self.metrics.pool_size.fetch_add(1, Ordering::Relaxed);
                } else {
                    self.metrics.dropped_returns.fetch_add(1, Ordering::Relaxed);
                }
            }
            // If pool is gone, buffer is dropped (deallocated)
            self.metrics.active_buffers.fetch_sub(1, Ordering::Relaxed);
        }
    }
}

// Safety: PooledBuffer can be sent between threads as long as T is Send
unsafe impl<T: Default + Clone + Send> Send for PooledBuffer<T> {}

// Note: PooledBuffer is NOT Sync because it contains mutable state
// Multiple threads should not share a single PooledBuffer

/// Global buffer pool for u8 image data (raw bytes)
static GLOBAL_U8_POOL: std::sync::OnceLock<BufferPool<u8>> = std::sync::OnceLock::new();

/// Global buffer pool for u16 image data (16-bit pixels)
static GLOBAL_U16_POOL: std::sync::OnceLock<BufferPool<u16>> = std::sync::OnceLock::new();

/// Get the global u8 buffer pool for raw byte data
pub fn global_u8_pool() -> &'static BufferPool<u8> {
    GLOBAL_U8_POOL.get_or_init(|| {
        let config = BufferPoolConfig {
            initial_capacity: 2,
            max_capacity: 6,
            // Byte sizes for common sensors (assuming 2 bytes per pixel for 16-bit)
            size_buckets: vec![
                1936 * 1096 * 2, // Small sensors
                2048 * 2048 * 2, // 4MP square sensors
                4144 * 2822 * 2, // ASI2600 (11.7MP) - 23.4MB
                4656 * 3520 * 2, // ASI6200 (16.4MP) - 32.8MB
                6248 * 4176 * 2, // ASI2400 (26MP) - 52MB
                9576 * 6388 * 2, // ASI128 (61MP) - 122MB
            ],
            idle_ttl: Some(DEFAULT_POOL_TTL),
            max_total_elements: Some(DEFAULT_POOL_MAX_TOTAL_ELEMENTS * 2),
        };
        BufferPool::new(config)
    })
}

/// Get the global u16 buffer pool for 16-bit pixel data
pub fn global_u16_pool() -> &'static BufferPool<u16> {
    GLOBAL_U16_POOL.get_or_init(|| {
        let config = BufferPoolConfig {
            initial_capacity: 2,
            max_capacity: 6,
            // Pixel counts for common sensors
            size_buckets: vec![
                1936 * 1096, // Small sensors (~2MP)
                2048 * 2048, // 4MP square sensors
                4144 * 2822, // ASI2600 (11.7MP)
                4656 * 3520, // ASI6200 (16.4MP)
                6248 * 4176, // ASI2400 (26MP)
                9576 * 6388, // ASI128 (61MP)
            ],
            idle_ttl: Some(DEFAULT_POOL_TTL),
            max_total_elements: Some(DEFAULT_POOL_MAX_TOTAL_ELEMENTS),
        };
        BufferPool::new(config)
    })
}

/// Initialize global pools with custom configurations
///
/// This should be called early in application startup if custom
/// configurations are needed. If not called, default configurations
/// are used on first access.
pub fn init_global_pools(
    u8_config: Option<BufferPoolConfig>,
    u16_config: Option<BufferPoolConfig>,
) {
    if let Some(config) = u8_config {
        let _ = GLOBAL_U8_POOL.set(BufferPool::new(config));
    }
    if let Some(config) = u16_config {
        let _ = GLOBAL_U16_POOL.set(BufferPool::new(config));
    }
}

/// Get combined metrics from both global pools
pub fn global_pool_metrics() -> (MetricsSnapshot, MetricsSnapshot) {
    (
        global_u8_pool().metrics_snapshot(),
        global_u16_pool().metrics_snapshot(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_basic_pool_operations() {
        let pool: BufferPool<u16> = BufferPool::new(BufferPoolConfig {
            initial_capacity: 1,
            max_capacity: 3,
            size_buckets: vec![100, 1000],
            ..Default::default()
        });

        // Initial state - should have pre-allocated buffers
        assert_eq!(pool.pool_size(), 2); // 1 per bucket

        // Get a buffer (should be a hit from pre-allocation)
        let buffer1 = pool.get_buffer(50);
        assert!(buffer1.len() >= 50);
        assert_eq!(pool.active_buffers(), 1);

        // Get another buffer
        let buffer2 = pool.get_buffer(500);
        assert!(buffer2.len() >= 500);
        assert_eq!(pool.active_buffers(), 2);

        // Drop first buffer - should return to pool
        drop(buffer1);
        assert_eq!(pool.active_buffers(), 1);

        // Get a new buffer - should be a hit
        let buffer3 = pool.get_buffer(50);
        assert!(buffer3.len() >= 50);

        let metrics = pool.metrics_snapshot();
        assert!(metrics.hits > 0);
    }

    #[test]
    fn test_buffer_reuse() {
        let pool: BufferPool<u16> = BufferPool::new(BufferPoolConfig {
            initial_capacity: 0, // Start empty to ensure we track allocations
            max_capacity: 2,
            size_buckets: vec![100],
            ..Default::default()
        });

        // First allocation - miss
        let buffer1 = pool.get_buffer(100);
        assert_eq!(pool.metrics().misses.load(Ordering::Relaxed), 1);

        // Return buffer
        drop(buffer1);
        assert_eq!(pool.pool_size(), 1);

        // Second get - should be a hit
        let _buffer2 = pool.get_buffer(100);
        assert_eq!(pool.metrics().hits.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn test_max_capacity() {
        let pool: BufferPool<u16> = BufferPool::new(BufferPoolConfig {
            initial_capacity: 0,
            max_capacity: 1,
            size_buckets: vec![100],
            ..Default::default()
        });

        // Allocate and return multiple buffers
        let buffer1 = pool.get_buffer(100);
        let buffer2 = pool.get_buffer(100);

        drop(buffer1);
        assert_eq!(pool.pool_size(), 1);

        // This should fail to return (pool at capacity)
        drop(buffer2);
        assert_eq!(pool.pool_size(), 1); // Still 1
        assert_eq!(pool.metrics().dropped_returns.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn test_bucket_sizing() {
        let pool: BufferPool<u16> = BufferPool::new(BufferPoolConfig {
            initial_capacity: 0,
            max_capacity: 4,
            size_buckets: vec![100, 500, 1000],
            ..Default::default()
        });

        // Request 50 elements - should get 100 bucket
        let buffer1 = pool.get_buffer(50);
        assert!(buffer1.len() >= 100);

        // Request 200 elements - should get 500 bucket
        let buffer2 = pool.get_buffer(200);
        assert!(buffer2.len() >= 500);

        // Request 1500 elements - larger than all buckets
        let buffer3 = pool.get_buffer(1500);
        assert!(buffer3.len() >= 1500);
    }

    #[test]
    fn test_pooled_buffer_operations() {
        let pool: BufferPool<u16> = BufferPool::new(BufferPoolConfig {
            initial_capacity: 1,
            max_capacity: 2,
            size_buckets: vec![10],
            ..Default::default()
        });

        let mut buffer = pool.get_buffer(5);

        // Test slice operations
        buffer[0] = 42;
        assert_eq!(buffer[0], 42);

        // Test iteration
        for val in buffer.iter_mut() {
            *val = 1;
        }
        assert!(buffer.iter().all(|&v| v == 1));

        // Test len
        assert!(buffer.len() >= 5);
    }

    #[test]
    fn test_into_vec() {
        let pool: BufferPool<u16> = BufferPool::new(BufferPoolConfig {
            initial_capacity: 0,
            max_capacity: 2,
            size_buckets: vec![100],
            ..Default::default()
        });

        let buffer = pool.get_buffer(100);
        assert_eq!(pool.active_buffers(), 1);

        let vec = buffer.into_vec();
        assert_eq!(vec.len(), 100);
        assert_eq!(pool.active_buffers(), 0);
        assert_eq!(pool.pool_size(), 0); // Not returned to pool
    }

    #[test]
    fn test_thread_safety() {
        use std::thread;

        let pool: BufferPool<u16> = BufferPool::new(BufferPoolConfig {
            initial_capacity: 2,
            max_capacity: 10,
            size_buckets: vec![100],
            ..Default::default()
        });

        let handles: Vec<_> = (0..4)
            .map(|_| {
                let pool = pool.clone();
                thread::spawn(move || {
                    for _ in 0..100 {
                        let mut buffer = pool.get_buffer(50);
                        buffer[0] = 1;
                        // Buffer auto-returns on drop
                    }
                })
            })
            .collect();

        for handle in handles {
            handle.join().unwrap();
        }

        // All buffers should be returned
        assert_eq!(pool.active_buffers(), 0);
    }

    #[test]
    fn test_global_pools() {
        // Just verify they can be accessed
        let _u8 = global_u8_pool();
        let _u16 = global_u16_pool();

        let (u8_metrics, u16_metrics) = global_pool_metrics();
        // Should have pre-allocated buffers
        assert!(u8_metrics.pool_size > 0 || u8_metrics.total_allocations > 0);
        assert!(u16_metrics.pool_size > 0 || u16_metrics.total_allocations > 0);
    }

    #[test]
    fn test_metrics_hit_rate() {
        let pool: BufferPool<u16> = BufferPool::new(BufferPoolConfig {
            initial_capacity: 1,
            max_capacity: 2,
            size_buckets: vec![100],
            ..Default::default()
        });

        // First get is a hit (from pre-allocation)
        let buffer1 = pool.get_buffer(50);
        drop(buffer1);

        // Second get should also be a hit
        let _buffer2 = pool.get_buffer(50);

        let hit_rate = pool.metrics().hit_rate();
        assert!(hit_rate > 0.0, "Expected some hits");
    }

    #[test]
    fn test_clear_pool() {
        let pool: BufferPool<u16> = BufferPool::new(BufferPoolConfig {
            initial_capacity: 3,
            max_capacity: 5,
            size_buckets: vec![100],
            ..Default::default()
        });

        assert_eq!(pool.pool_size(), 3);

        pool.clear();
        assert_eq!(pool.pool_size(), 0);

        // New allocations should still work
        let _buffer = pool.get_buffer(50);
        assert_eq!(pool.active_buffers(), 1);
    }
}
