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

use std::collections::BTreeMap;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::time::{Duration, Instant};

use skotiq_imaging::read_fits;
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

/// Upper bound on tracked render ids.
///
/// A live render releases its id when it finishes, so this bounds only the
/// pre-armed entries a caller creates by cancelling renders that never start.
/// The cap is enforced by evicting stale pre-arms, never by refusing work: see
/// [`make_room`].
pub(crate) const MAX_TRACKED_RENDERS: usize = 32;

/// How long an unclaimed pre-arm is kept before the registry may drop it.
///
/// A pre-arm exists for the window between a cancellation and the render
/// reaching Rust — sub-second in practice. Minutes of grace is far more than
/// that window needs, and an entry older than this belongs to a render that is
/// never coming: the dawn autopilot cancels queued jobs that never render, and
/// the editor cancels ids that race their own completion.
const PREARM_TTL: Duration = Duration::from_secs(300);

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
            "the Darkroom operation registry did not build: {reason}"
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

    let (image_data, header) = read_fits(path).map_err(|e| {
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

/// One tracked render id: the flag the engine polls, plus whether a render is
/// executing under it.
///
/// The two are separate because a cancellation may be **pre-armed** — requested
/// before the render reaches Rust — and a pre-arm must be distinguishable from a
/// render in flight.
struct RenderEntry {
    cancel: Arc<AtomicBool>,
    live: AtomicBool,
    /// When this id entered the registry, so a pre-arm nothing ever claims can
    /// be aged out. A live render is never evicted by age; its token removes it
    /// on drop.
    armed_at: Instant,
}

impl RenderEntry {
    fn new() -> Self {
        Self {
            cancel: Arc::new(AtomicBool::new(false)),
            live: AtomicBool::new(false),
            armed_at: Instant::now(),
        }
    }

    fn is_live(&self) -> bool {
        self.live.load(Ordering::Relaxed)
    }
}

static CANCEL_REGISTRY: OnceLock<Mutex<BTreeMap<String, Arc<RenderEntry>>>> = OnceLock::new();

/// The cancellation registry, recovering a poisoned lock: the contents are two
/// atomics with no invariant to break, and refusing to unlock would make every
/// later render unstoppable.
fn cancel_registry() -> MutexGuard<'static, BTreeMap<String, Arc<RenderEntry>>> {
    let lock = CANCEL_REGISTRY.get_or_init(|| Mutex::new(BTreeMap::new()));
    match lock.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    }
}

/// Make room for one more id, dropping expired and then oldest pre-arms.
///
/// Returns `false` only when every tracked id is a render executing right now —
/// the one case where nothing may be dropped, since evicting a live entry would
/// hand a running render a flag no cancellation can reach.
///
/// A cancellation aimed at a render that never starts leaves a pre-arm behind,
/// and nothing else removes one: [`RenderCancelToken`]'s drop only fires for an
/// id a render actually claimed. Without this the cap is a permanent ceiling —
/// past 32 late cancels every subsequent render and export is refused until the
/// process restarts — so the registry ages pre-arms out and, when it must,
/// gives the oldest one's slot to the new work rather than refusing it.
fn make_room(map: &mut BTreeMap<String, Arc<RenderEntry>>) -> bool {
    let now = Instant::now();
    map.retain(|_, entry| entry.is_live() || now.duration_since(entry.armed_at) < PREARM_TTL);
    if map.len() < MAX_TRACKED_RENDERS {
        return true;
    }
    let oldest = map
        .iter()
        .filter(|(_, entry)| !entry.is_live())
        .min_by_key(|(_, entry)| entry.armed_at)
        .map(|(id, _)| id.clone());
    match oldest {
        Some(id) => {
            map.remove(&id);
            true
        }
        None => false,
    }
}

/// A render's cancellation flag, held for the render's lifetime.
///
/// Dropping the token releases the render id, so a later render may reuse it and
/// a later cancellation starts from a clean flag.
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct RenderCancelToken {
    /// `None` for a render with no id — never cancellable.
    render_id: Option<String>,
    flag: Arc<AtomicBool>,
    entry: Option<Arc<RenderEntry>>,
}

impl RenderCancelToken {
    /// Claim `render_id` for this call and take its flag. A blank id yields an
    /// inert token carrying a flag nothing else can raise: a caller that
    /// supplies no id has no handle to cancel by.
    ///
    /// A pre-armed flag is adopted as-is, so a render whose cancellation arrived
    /// first stops at its very first check. An id already in flight is refused —
    /// two concurrent renders sharing one id could not be cancelled
    /// independently, and the first to finish would release the other's flag.
    pub(crate) fn register(render_id: &str) -> Result<Self, String> {
        let id = render_id.trim();
        if id.is_empty() {
            return Ok(Self {
                render_id: None,
                flag: Arc::new(AtomicBool::new(false)),
                entry: None,
            });
        }
        let mut map = cancel_registry();
        let entry = match map.get(id) {
            Some(existing) => {
                if existing.live.load(Ordering::Relaxed) {
                    return Err(format!("darkroom render '{id}' is already in flight"));
                }
                Arc::clone(existing)
            }
            None => {
                if !make_room(&mut map) {
                    return Err(format!(
                        "cannot track render '{id}': {MAX_TRACKED_RENDERS} darkroom renders are in flight"
                    ));
                }
                let entry = Arc::new(RenderEntry::new());
                map.insert(id.to_string(), Arc::clone(&entry));
                entry
            }
        };
        entry.live.store(true, Ordering::Relaxed);
        let flag = Arc::clone(&entry.cancel);
        Ok(Self {
            render_id: Some(id.to_string()),
            flag,
            entry: Some(entry),
        })
    }

    /// The render id this token answers for, or `""` when the render is
    /// untracked.
    pub(crate) fn render_id(&self) -> &str {
        self.render_id.as_deref().unwrap_or("")
    }

    /// The flag the engine and every operation poll.
    pub(crate) fn flag(&self) -> Arc<AtomicBool> {
        Arc::clone(&self.flag)
    }

    /// Whether cancellation has been requested for this render.
    pub(crate) fn is_cancelled(&self) -> bool {
        self.flag.load(Ordering::Relaxed)
    }
}

impl Drop for RenderCancelToken {
    fn drop(&mut self) {
        let Some(id) = self.render_id.as_deref() else {
            return;
        };
        if let Some(entry) = self.entry.as_ref() {
            entry.live.store(false, Ordering::Relaxed);
        }
        cancel_registry().remove(id);
    }
}

/// Outcome of one cancellation op: the flag state after it ran.
pub(crate) struct CancelOpOutcome {
    /// `true` when a render is executing under this id right now.
    pub(crate) running: bool,
    /// The render's cancellation flag after the op.
    pub(crate) cancel_requested: bool,
}

/// Request cancellation of `render_id`, pre-arming an id that has not started.
pub(crate) fn request_cancel(render_id: &str) -> Result<CancelOpOutcome, String> {
    let mut map = cancel_registry();
    let running = map
        .get(render_id)
        .is_some_and(|e| e.live.load(Ordering::Relaxed));
    let entry = match map.get(render_id) {
        Some(existing) => Arc::clone(existing),
        None => {
            if !make_room(&mut map) {
                return Err(format!(
                    "cannot pre-arm cancellation for '{render_id}': {MAX_TRACKED_RENDERS} darkroom renders are in flight"
                ));
            }
            // Pre-arm: safing can fire before the render reaches Rust, and a
            // request that lands in that window is still honoured.
            let entry = Arc::new(RenderEntry::new());
            map.insert(render_id.to_string(), Arc::clone(&entry));
            entry
        }
    };
    entry.cancel.store(true, Ordering::Relaxed);
    Ok(CancelOpOutcome {
        running,
        cancel_requested: true,
    })
}

/// Read whether `render_id` is in flight and whether cancellation is requested.
pub(crate) fn cancel_status(render_id: &str) -> CancelOpOutcome {
    let map = cancel_registry();
    let entry = map.get(render_id);
    CancelOpOutcome {
        running: entry.is_some_and(|e| e.live.load(Ordering::Relaxed)),
        cancel_requested: entry.is_some_and(|e| e.cancel.load(Ordering::Relaxed)),
    }
}

/// Drop a pre-armed cancellation for `render_id`.
///
/// Only a pre-arm may be dropped. Clearing a live render's flag would silently
/// resurrect a render the operator already stopped.
pub(crate) fn clear_cancel(render_id: &str) -> Result<CancelOpOutcome, String> {
    let mut map = cancel_registry();
    let running = map
        .get(render_id)
        .is_some_and(|e| e.live.load(Ordering::Relaxed));
    if running {
        return Err(format!(
            "darkroom render '{render_id}' is in flight; clear only drops a pre-armed cancellation"
        ));
    }
    map.remove(render_id);
    Ok(CancelOpOutcome {
        running: false,
        cancel_requested: false,
    })
}
