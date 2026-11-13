//! The Darkroom's process-global state: the operation registry, the render
//! cache, the base-master pyramid cache, and the render cancellation flags.
//!
//! # Why the Darkroom holds process state when post-session holds none
//!
//! The post-session pipeline is stateless per call so it can run beside the live
//! stacker. The Darkroom is the opposite shape: an editor drags a parameter and
//! re-renders the same recipe over the same master tens of times a second, and
//! the whole point of the step-boundary cache is that the work below the edited
//! step is *not* repeated. A cache that lived per call would never hit. The
//! state here is therefore the cache, the registry it renders with, and the
//! flags a render polls — never a half-finished image.
//!
//! # Lock order
//!
//! The base-cache lock is never held while the render-cache lock is held.
//! [`base_pyramid`] takes and releases the base lock before its caller takes the
//! render lock, so the two can never deadlock against each other.
//!
//! # Serialisation
//!
//! One render holds the render-cache lock for its duration, so renders run one
//! at a time. That is the shared-cache contract, not an accident: two renders
//! interleaving inserts against one budget would evict each other's boundaries.
//!
//! # Byte budgets
//!
//! Both caches are byte-budgeted and evict least-recently-used entries first.
//! Eviction changes only how much work a render repeats; it never changes
//! pixels.

use crate::run_cancel::CancelRegistry;
use std::collections::BTreeMap;
use std::path::Path;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};

use skotiq_imaging::read_frame;
use skotiq_imaging::recipe::{
    ImagePyramid, OpImage, OpRegistry, RenderCache, DEFAULT_CACHE_CAPACITY_BYTES,
};

/// The render cache's byte budget: the engine's own default, 512 MiB of step
/// boundaries. One number governs both the engine's tests and this surface, so
/// a boundary that fits in one fits in the other.
pub(crate) const RENDER_CACHE_CAPACITY_BYTES: usize = DEFAULT_CACHE_CAPACITY_BYTES;

/// The base-master cache's byte budget: 512 MiB of pyramids.
///
/// A 4k x 3k mono F32 master is 48 MB and its pyramid about 64 MB, so this holds
/// roughly eight open masters — an A/B session over two filters with room to
/// spare — before the least recently rendered one is dropped and re-read.
pub(crate) const BASE_CACHE_CAPACITY_BYTES: usize = 512 * 1024 * 1024;

// ---------------------------------------------------------------------------
// Operation registry
// ---------------------------------------------------------------------------

/// The registry every Darkroom call renders with, built once.
static REGISTRY: OnceLock<Result<OpRegistry, String>> = OnceLock::new();

/// The built-in operation registry.
///
/// A registry that fails to build is a duplicate or zero-version registration —
/// a programming mistake in [`skotiq_imaging::recipe::registry::builtin_ops`]
/// — and every call reports it rather than rendering with a partial op set.
pub(crate) fn registry() -> Result<&'static OpRegistry, String> {
    match REGISTRY.get_or_init(|| OpRegistry::builtin().map_err(|e| e.to_string())) {
        Ok(built) => Ok(built),
        Err(reason) => Err(format!(
            "the Darkroom's processing steps could not be loaded: {reason}"
        )),
    }
}

// ---------------------------------------------------------------------------
// Render cache
// ---------------------------------------------------------------------------

/// The step-boundary cache shared by every render.
static RENDER_CACHE: OnceLock<Mutex<RenderCache>> = OnceLock::new();

/// The render cache, taking the lock and recovering it if a panic poisoned it.
///
/// A poisoned lock means a render panicked partway through. The entries it had
/// already inserted are complete boundaries, but the panic itself is unexplained
/// state, so recovery drops them: a re-render costs time, while a boundary from
/// a panicking run would be served as truth forever.
pub(crate) fn render_cache() -> MutexGuard<'static, RenderCache> {
    let lock =
        RENDER_CACHE.get_or_init(|| Mutex::new(RenderCache::new(RENDER_CACHE_CAPACITY_BYTES)));
    match lock.lock() {
        Ok(guard) => guard,
        Err(poisoned) => {
            tracing::warn!(
                "Darkroom render cache mutex was poisoned (a previous render panicked); recovering and dropping its boundaries"
            );
            let mut guard = poisoned.into_inner();
            guard.clear();
            guard
        }
    }
}

// ---------------------------------------------------------------------------
// Base-master pyramid cache
// ---------------------------------------------------------------------------

/// One cached base master: the pyramid built from it and the file identity it
/// was read from.
struct BaseEntry {
    pyramid: Arc<ImagePyramid>,
    /// `modified-nanos|length` of the file at read time.
    identity: String,
    bytes: usize,
    last_used: u64,
}

/// Pyramids keyed by master path.
///
/// Hidden from the bridge: the derived `Default` would otherwise be published as
/// a Dart-callable constructor for an internal cache.
#[derive(Default)]
#[flutter_rust_bridge::frb(ignore)]
struct BaseCache {
    entries: BTreeMap<String, BaseEntry>,
    used_bytes: usize,
    tick: u64,
}

impl BaseCache {
    /// Evict least-recently-used entries until the budget is met. Ties break on
    /// path order, so eviction is reproducible.
    fn evict_to_capacity(&mut self) {
        while self.used_bytes > BASE_CACHE_CAPACITY_BYTES {
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

static BASE_CACHE: OnceLock<Mutex<BaseCache>> = OnceLock::new();

/// The base cache, taking the lock and recovering it if a panic poisoned it.
/// The entries are whole pyramids inserted under the lock, so recovery keeps
/// them.
fn base_cache() -> MutexGuard<'static, BaseCache> {
    let lock = BASE_CACHE.get_or_init(|| Mutex::new(BaseCache::default()));
    match lock.lock() {
        Ok(guard) => guard,
        Err(poisoned) => {
            tracing::warn!(
                "Darkroom base-master cache mutex was poisoned (a previous read panicked); recovering"
            );
            poisoned.into_inner()
        }
    }
}

/// A cause an operator can read, guaranteed non-empty and free of bytes that do
/// not survive the trip.
///
/// Every failure here crosses the FFI as a Rust `String` and lands in the night
/// report as the sentence that says why a master produced no draft. A cause
/// carrying a NUL byte — what a torn write leaves in a FITS header — does not
/// survive that crossing: the whole string arrives empty and the report tells
/// the operator a master failed without telling them why. Control bytes are
/// escaped rather than dropped, so the cause stays both readable and true, and
/// a cause that carries no text at all is named as carrying none rather than
/// passed on blank.
pub(crate) fn readable_cause(cause: impl std::fmt::Display) -> String {
    let text = cause.to_string();
    let mut out = String::with_capacity(text.len());
    for ch in text.chars() {
        let code = ch as u32;
        if code < 0x20 || code == 0x7f {
            out.push_str(&format!("\\x{code:02x}"));
        } else {
            out.push(ch);
        }
    }
    if out.trim().is_empty() {
        return "the underlying error carried no message".to_string();
    }
    out
}

/// The file identity a cached pyramid is valid for: modification time and
/// length.
fn file_identity(path: &Path) -> Result<String, String> {
    let meta = std::fs::metadata(path)
        .map_err(|e| format!("cannot read '{}': {}", path.display(), readable_cause(e)))?;
    let modified = meta
        .modified()
        .map_err(|e| {
            format!(
                "cannot read the modification time of '{}': {}",
                path.display(),
                readable_cause(e)
            )
        })?
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|e| {
            format!(
                "the modification time of '{}' predates the epoch: {}",
                path.display(),
                readable_cause(e)
            )
        })?;
    Ok(format!("{}|{}", modified.as_nanos(), meta.len()))
}

/// A master's pyramid together with the identity of the bytes it was built from.
///
/// The identity travels with the pyramid because the step-boundary key needs it:
/// keyed on the recipe's `baseMasterRef` alone, two renders of one recipe over
/// two different masters of the same geometry share a cache entry, and the
/// second request is served the first master's pixels under its own path. The
/// path *and* the file identity are both in the string, so neither a different
/// master nor the same path rewritten can be mistaken for a boundary already
/// computed.
pub(crate) struct LoadedMaster {
    /// The pyramid built from the master.
    pub(crate) pyramid: Arc<ImagePyramid>,
    /// The path read, its modification time and its length.
    pub(crate) identity: String,
}

/// The pyramid for the master at `path`, reading and building it on a miss.
///
/// The cache is keyed by path and validated against the file's modification time
/// and length. A file that changed under a path invalidates far more than this
/// cache: a changed base clears the whole render cache as well, so no boundary
/// computed from the old bytes survives under a key the new bytes could reach.
pub(crate) fn base_pyramid(path: &Path) -> Result<LoadedMaster, String> {
    let identity = file_identity(path)?;
    let key = path.to_string_lossy().to_string();
    let render_identity = format!("{key}|{identity}");

    let stale = {
        let mut cache = base_cache();
        cache.tick = cache.tick.saturating_add(1);
        let tick = cache.tick;
        match cache.entries.get_mut(&key) {
            Some(entry) if entry.identity == identity => {
                entry.last_used = tick;
                return Ok(LoadedMaster {
                    pyramid: Arc::clone(&entry.pyramid),
                    identity: render_identity,
                });
            }
            Some(_) => {
                if let Some(entry) = cache.entries.remove(&key) {
                    cache.used_bytes = cache.used_bytes.saturating_sub(entry.bytes);
                }
                true
            }
            None => false,
        }
    };
    if stale {
        tracing::info!(
            "Darkroom base master '{}' changed on disk; dropping every cached render boundary",
            path.display()
        );
        render_cache().clear();
    }

    let (image_data, header) = read_frame(path).map_err(|e| {
        format!(
            "cannot read '{}' as FITS: {}",
            path.display(),
            readable_cause(e)
        )
    })?;
    let base = OpImage::from_image_data(&image_data, header).map_err(|e| {
        format!(
            "'{}' is not renderable: {}",
            path.display(),
            readable_cause(e)
        )
    })?;
    let pyramid = Arc::new(ImagePyramid::build(Arc::new(base)).map_err(|e| {
        format!(
            "cannot build a preview pyramid for '{}': {}",
            path.display(),
            readable_cause(e)
        )
    })?);

    let bytes = pyramid.byte_size();
    let mut cache = base_cache();
    cache.tick = cache.tick.saturating_add(1);
    let tick = cache.tick;
    if bytes <= BASE_CACHE_CAPACITY_BYTES {
        if let Some(previous) = cache.entries.remove(&key) {
            cache.used_bytes = cache.used_bytes.saturating_sub(previous.bytes);
        }
        cache.entries.insert(
            key,
            BaseEntry {
                pyramid: Arc::clone(&pyramid),
                identity,
                bytes,
                last_used: tick,
            },
        );
        cache.used_bytes = cache.used_bytes.saturating_add(bytes);
        cache.evict_to_capacity();
    }
    Ok(LoadedMaster {
        pyramid,
        identity: render_identity,
    })
}

// ---------------------------------------------------------------------------
// Catalogue identity
// ---------------------------------------------------------------------------
//
// There is no catalogue bookkeeping here, and that is a guarantee rather than an
// omission: `OpContext::identity` folds `PhotometryCatalog::identity` into every
// step-boundary key, so a render given a different star list computes its own
// boundaries instead of being served the previous list's colours. Clearing the
// render cache when the photometry changes is therefore redundant — it throws
// away boundaries that are still correct for the list that produced them.

// ---------------------------------------------------------------------------
// Render cancellation
// ---------------------------------------------------------------------------

/// The cancellation flags of Darkroom renders and exports, keyed by render id.
pub(crate) static RENDERS: CancelRegistry = CancelRegistry::new("darkroom render");
