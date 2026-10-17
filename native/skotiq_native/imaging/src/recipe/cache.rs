//! The per-step-boundary intermediate cache.
//!
//! A cache entry holds the image as it stands after a prefix of the recipe. The
//! key is that prefix's canonical form, so editing step `N` changes the key of
//! every boundary from `N` onward and leaves boundaries below `N` reachable —
//! invalidation falls out of the key rather than being tracked separately.
//!
//! Disabled steps are absent from the key: toggling a step off returns to the
//! key the stack had before the step existed, so a disable/enable cycle costs no
//! re-render below the toggle.
//!
//! The key is the canonical prefix string itself, not a digest of it. A digest
//! collision would serve one recipe's pixels for another's, and the strings are
//! kilobytes at most.
//!
//! The key also carries [`OpContext::identity`], so attaching a photometric
//! catalogue or a different plate solve invalidates the boundaries that
//! depended on it. A catalogue contributes its contents through
//! [`PhotometryCatalog::identity`](super::model::PhotometryCatalog::identity),
//! not merely its presence: a handle that gains stars keys differently, so a
//! caller that reloads catalogue data needs no [`RenderCache::clear`] to keep
//! one star list's colours out of another's render.

use std::collections::BTreeMap;
use std::sync::Arc;

use super::model::{fingerprint_hex, OpContext, OpImage, Recipe};
use super::render::StepReport;

/// The identity of one step boundary: base pixels, render context, and the
/// enabled prefix that produced the image.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct CacheKey(String);

impl CacheKey {
    /// The key for the boundary after applying steps `0..=upto` of `recipe` to
    /// `base` under `ctx`, where `base_identity` names the master the caller
    /// actually read.
    ///
    /// The base's geometry is part of the key: a preview level and a full render
    /// share a `baseMasterRef`, and mixing their caches would serve a
    /// half-resolution image to a full-resolution export.
    ///
    /// `base_identity` is part of it for the same reason at one remove. A
    /// recipe's `baseMasterRef` says which master it was *authored* on, not
    /// which one this render is reading, and nothing stops a caller replaying a
    /// recipe over another master: two masters of the same geometry would then
    /// share every boundary, and the second request would be served the first
    /// master's pixels under its own path. Both are in the key, so a render is
    /// resumed only from a boundary computed over the same recipe lineage *and*
    /// the same bytes. A caller that names no master supplies an empty identity,
    /// which keys distinctly from every caller that names one.
    pub fn for_prefix(
        recipe: &Recipe,
        base_identity: &str,
        base: &OpImage,
        ctx: &OpContext,
        upto: usize,
    ) -> Self {
        Self(format!(
            "v{}|{}|{}|{}x{}x{}|{}|{}",
            super::model::RECIPE_SCHEMA_VERSION,
            recipe.base_master_ref,
            base_identity,
            base.width(),
            base.height(),
            base.channels(),
            ctx.identity(),
            recipe.canonical_prefix(upto),
        ))
    }

    /// The key's text.
    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// A 32-hex-digit digest of the key, for log lines and `HISTORY` cards.
    pub fn fingerprint(&self) -> String {
        fingerprint_hex(self.0.as_bytes())
    }
}

/// One cached step boundary: the image plus what the engine reported about the
/// steps that produced it.
///
/// The reports travel with the image because a cache hit skips the steps that
/// produced it: without them, a render served from cache could not say which
/// step was skipped and why.
#[derive(Debug, Clone)]
struct CacheEntry {
    image: Arc<OpImage>,
    reports: Arc<Vec<StepReport>>,
    bytes: usize,
    last_used: u64,
}

/// The default cache budget: 512 MiB of intermediates.
pub const DEFAULT_CACHE_CAPACITY_BYTES: usize = 512 * 1024 * 1024;

/// A byte-budgeted store of step-boundary images, evicting least-recently-used
/// entries first.
///
/// Eviction changes only how much work a render repeats. A cache hit and a cache
/// miss produce the same pixels, and the determinism tests assert exactly that.
#[derive(Debug)]
pub struct RenderCache {
    entries: BTreeMap<CacheKey, CacheEntry>,
    capacity_bytes: usize,
    used_bytes: usize,
    tick: u64,
    hits: u64,
    misses: u64,
}

impl Default for RenderCache {
    fn default() -> Self {
        Self::new(DEFAULT_CACHE_CAPACITY_BYTES)
    }
}

impl RenderCache {
    /// A cache holding at most `capacity_bytes` of pixel data.
    pub fn new(capacity_bytes: usize) -> Self {
        Self {
            entries: BTreeMap::new(),
            capacity_bytes,
            used_bytes: 0,
            tick: 0,
            hits: 0,
            misses: 0,
        }
    }

    /// A cache that never evicts. Used by tests and by a bounded batch render
    /// whose whole stack is known to fit.
    pub fn unbounded() -> Self {
        Self::new(usize::MAX)
    }

    /// A cache that stores nothing. Every render against it recomputes every
    /// step, which is what the cache-miss half of the determinism harness needs.
    pub fn disabled() -> Self {
        Self::new(0)
    }

    /// The entry for `key`, counting a hit or a miss.
    pub fn get(&mut self, key: &CacheKey) -> Option<(Arc<OpImage>, Arc<Vec<StepReport>>)> {
        self.tick = self.tick.saturating_add(1);
        let tick = self.tick;
        match self.entries.get_mut(key) {
            Some(entry) => {
                entry.last_used = tick;
                self.hits = self.hits.saturating_add(1);
                Some((Arc::clone(&entry.image), Arc::clone(&entry.reports)))
            }
            None => {
                self.misses = self.misses.saturating_add(1);
                None
            }
        }
    }

    /// Whether `key` is present, without touching the hit/miss counters or the
    /// recency order.
    pub fn contains(&self, key: &CacheKey) -> bool {
        self.entries.contains_key(key)
    }

    /// Store a step boundary. An image larger than the whole budget is not
    /// stored, so one oversized intermediate cannot evict the entire cache.
    pub fn insert(&mut self, key: CacheKey, image: Arc<OpImage>, reports: Arc<Vec<StepReport>>) {
        let bytes = image.byte_size();
        if bytes > self.capacity_bytes {
            return;
        }
        self.tick = self.tick.saturating_add(1);
        if let Some(previous) = self.entries.remove(&key) {
            self.used_bytes = self.used_bytes.saturating_sub(previous.bytes);
        }
        self.entries.insert(
            key,
            CacheEntry {
                image,
                reports,
                bytes,
                last_used: self.tick,
            },
        );
        self.used_bytes = self.used_bytes.saturating_add(bytes);
        self.evict_to_capacity();
    }

    /// Drop every entry. Counters survive so a caller can report cache
    /// behaviour across a session.
    pub fn clear(&mut self) {
        self.entries.clear();
        self.used_bytes = 0;
    }

    /// Number of stored boundaries.
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// Whether nothing is stored.
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Bytes of pixel data currently stored.
    pub fn used_bytes(&self) -> usize {
        self.used_bytes
    }

    /// The byte budget.
    pub fn capacity_bytes(&self) -> usize {
        self.capacity_bytes
    }

    /// Lookups served from the cache.
    pub fn hits(&self) -> u64 {
        self.hits
    }

    /// Lookups that had to be computed.
    pub fn misses(&self) -> u64 {
        self.misses
    }

    /// Zero the hit/miss counters.
    pub fn reset_stats(&mut self) {
        self.hits = 0;
        self.misses = 0;
    }

    /// Evict least-recently-used entries until the budget is met. Ties break on
    /// key order, so eviction is reproducible.
    fn evict_to_capacity(&mut self) {
        while self.used_bytes > self.capacity_bytes {
            let victim = self
                .entries
                .iter()
                .min_by(|(a_key, a), (b_key, b)| {
                    a.last_used.cmp(&b.last_used).then_with(|| a_key.cmp(b_key))
                })
                .map(|(key, _)| key.clone());
            match victim {
                Some(key) => {
                    if let Some(entry) = self.entries.remove(&key) {
                        self.used_bytes = self.used_bytes.saturating_sub(entry.bytes);
                    }
                }
                None => break,
            }
        }
    }
}

#[cfg(test)]
#[path = "cache_tests.rs"]
mod cache_tests;
