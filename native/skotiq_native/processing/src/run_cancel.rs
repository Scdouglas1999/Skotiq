//! Admission and cancellation for long synchronous runs keyed by the caller's
//! id (a post-session run, a Darkroom render).
//!
//! Such a run is one FFI descent with no await point to cancel and no task to
//! abort, so stopping it needs a flag its loops read. A [`CancelRegistry`]
//! keeps one flag per run id: a run claims its id for as long as it executes,
//! a cancellation aimed at one id can never stop another, and a cancellation
//! that arrives before its run reaches Rust is **pre-armed** and stops that
//! run at its first check. A run started without an id is not cancellable.

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

/// Upper bound on tracked ids per registry.
///
/// A run releases its id when it ends, so this bounds only the pre-arms left
/// by cancelling runs that never start. The cap is kept by dropping stale
/// pre-arms, never by refusing work: see [`make_room`].
pub(crate) const MAX_TRACKED: usize = 32;

/// How long an unclaimed pre-arm is kept before the registry may drop it.
///
/// A pre-arm exists for the window between a cancellation and its run
/// reaching Rust, which is sub-second. An entry older than this belongs to a
/// run that is never coming: safing cancels queued jobs that never start, and
/// an editor cancels ids that race their own completion.
const PREARM_TTL: Duration = Duration::from_secs(300);

/// One tracked id: the flag its run polls, and whether a run is executing
/// under it. A pre-arm is an entry that is not live.
struct Entry {
    cancel: Arc<AtomicBool>,
    live: AtomicBool,
    /// When the id entered the registry, so a pre-arm nothing claims ages out.
    armed_at: Instant,
}

impl Entry {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            cancel: Arc::new(AtomicBool::new(false)),
            live: AtomicBool::new(false),
            armed_at: Instant::now(),
        })
    }

    fn is_live(&self) -> bool {
        self.live.load(Ordering::Relaxed)
    }
}

type Entries = BTreeMap<String, Arc<Entry>>;

/// Makes room for one more id, dropping expired pre-arms and then the oldest
/// one. `false` only when every tracked id is a run executing right now:
/// evicting one of those would leave a running run with a flag no
/// cancellation can reach.
fn make_room(map: &mut Entries) -> bool {
    let now = Instant::now();
    map.retain(|_, entry| entry.is_live() || now.duration_since(entry.armed_at) < PREARM_TTL);
    if map.len() < MAX_TRACKED {
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

/// Whether a run is executing under an id, and whether its cancellation is
/// requested.
pub(crate) struct CancelState {
    pub(crate) running: bool,
    pub(crate) cancel_requested: bool,
}

/// The cancellation flags of one kind of run.
pub(crate) struct CancelRegistry {
    /// What the registry tracks, for its refusals ("darkroom render").
    noun: &'static str,
    entries: Mutex<Entries>,
}

impl CancelRegistry {
    pub(crate) const fn new(noun: &'static str) -> Self {
        Self {
            noun,
            entries: Mutex::new(BTreeMap::new()),
        }
    }

    /// The entries, recovered if a panic poisoned the lock: they are atomics
    /// with no invariant to break, and refusing to unlock would make every
    /// later run unstoppable.
    fn entries(&self) -> MutexGuard<'_, Entries> {
        self.entries
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Claims `id` for a run and takes its flag. A blank id gives a token
    /// nothing can cancel. A pre-armed flag is adopted as it is. An id already
    /// in flight is refused: two runs sharing one id could not be cancelled
    /// apart, and the first to end would release the other's flag.
    pub(crate) fn register(&'static self, id: &str) -> Result<CancelToken, String> {
        let id = id.trim();
        if id.is_empty() {
            return Ok(CancelToken {
                id: None,
                flag: Arc::new(AtomicBool::new(false)),
                claim: None,
            });
        }
        let noun = self.noun;
        let mut map = self.entries();
        let entry = match map.get(id) {
            Some(existing) => {
                if existing.is_live() {
                    return Err(format!("{noun} '{id}' is already in flight"));
                }
                Arc::clone(existing)
            }
            None => {
                if !make_room(&mut map) {
                    return Err(format!(
                        "cannot track {noun} '{id}': {MAX_TRACKED} {noun}s are in flight"
                    ));
                }
                let entry = Entry::new();
                map.insert(id.to_string(), Arc::clone(&entry));
                entry
            }
        };
        entry.live.store(true, Ordering::Relaxed);
        Ok(CancelToken {
            id: Some(id.to_string()),
            flag: Arc::clone(&entry.cancel),
            claim: Some((self, entry)),
        })
    }

    /// Requests cancellation of the run under `id`, pre-arming it when no run
    /// has claimed the id yet.
    pub(crate) fn request_cancel(&self, id: &str) -> Result<CancelState, String> {
        let mut map = self.entries();
        let entry = match map.get(id) {
            Some(existing) => Arc::clone(existing),
            None => {
                if !make_room(&mut map) {
                    return Err(format!(
                        "cannot pre-arm cancellation for '{id}': {MAX_TRACKED} {}s are in flight",
                        self.noun
                    ));
                }
                let entry = Entry::new();
                map.insert(id.to_string(), Arc::clone(&entry));
                entry
            }
        };
        entry.cancel.store(true, Ordering::Relaxed);
        Ok(CancelState {
            running: entry.is_live(),
            cancel_requested: true,
        })
    }

    pub(crate) fn status(&self, id: &str) -> CancelState {
        let map = self.entries();
        let entry = map.get(id);
        CancelState {
            running: entry.is_some_and(|e| e.is_live()),
            cancel_requested: entry.is_some_and(|e| e.cancel.load(Ordering::Relaxed)),
        }
    }

    /// Drops a pre-armed cancellation. Refused for a run in flight: clearing
    /// its flag would resurrect a run the operator already stopped.
    pub(crate) fn clear(&self, id: &str) -> Result<CancelState, String> {
        let mut map = self.entries();
        if map.get(id).is_some_and(|e| e.is_live()) {
            return Err(format!(
                "{} '{id}' is in flight; clear only drops a pre-armed cancellation",
                self.noun
            ));
        }
        map.remove(id);
        Ok(CancelState {
            running: false,
            cancel_requested: false,
        })
    }
}

/// A run's claim on its id, held for as long as the run executes. Dropping it
/// releases the id, so a later run may reuse it with a clean flag.
pub(crate) struct CancelToken {
    /// `None` for a run with no id.
    id: Option<String>,
    flag: Arc<AtomicBool>,
    claim: Option<(&'static CancelRegistry, Arc<Entry>)>,
}

impl CancelToken {
    /// The id the token answers for, `""` for a run without one.
    pub(crate) fn id(&self) -> &str {
        self.id.as_deref().unwrap_or("")
    }

    /// The flag, for an engine that polls it itself.
    pub(crate) fn flag(&self) -> Arc<AtomicBool> {
        Arc::clone(&self.flag)
    }

    pub(crate) fn is_cancelled(&self) -> bool {
        self.flag.load(Ordering::Relaxed)
    }
}

impl Drop for CancelToken {
    fn drop(&mut self) {
        let (Some(id), Some((registry, entry))) = (self.id.as_deref(), self.claim.as_ref()) else {
            return;
        };
        entry.live.store(false, Ordering::Relaxed);
        registry.entries().remove(id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    static RUNS: CancelRegistry = CancelRegistry::new("test run");

    #[test]
    fn a_live_run_owns_its_id_until_it_ends() {
        let token = RUNS.register("owned").expect("register");
        assert!(RUNS.register("owned").is_err());
        assert!(RUNS.clear("owned").is_err());

        let state = RUNS.request_cancel("owned").expect("cancel");
        assert!(state.running && state.cancel_requested);
        assert!(token.is_cancelled());

        drop(token);
        let reused = RUNS.register("owned").expect("the id is free again");
        assert!(!reused.is_cancelled());
    }

    #[test]
    fn a_cancel_before_the_run_stops_it_at_its_first_check() {
        let state = RUNS.request_cancel("early").expect("pre-arm");
        assert!(!state.running);
        let token = RUNS.register("early").expect("register");
        assert!(token.is_cancelled());
    }

    #[test]
    fn a_run_without_an_id_cannot_be_cancelled() {
        let token = RUNS.register("  ").expect("an id-less run still runs");
        assert_eq!(token.id(), "");
        assert!(!token.is_cancelled());
    }

    #[test]
    fn stale_pre_arms_give_way_to_new_work() {
        static FLOOD: CancelRegistry = CancelRegistry::new("flood run");
        for i in 0..MAX_TRACKED + 8 {
            FLOOD
                .request_cancel(&format!("never-{i}"))
                .expect("a late cancel is accepted past the cap");
        }
        let fresh = FLOOD.register("fresh").expect("a new run is admitted");
        assert!(!fresh.is_cancelled());
    }

    #[test]
    fn a_registry_of_live_runs_refuses_one_more() {
        static FULL: CancelRegistry = CancelRegistry::new("full run");
        let live: Vec<_> = (0..MAX_TRACKED)
            .map(|i| FULL.register(&format!("live-{i}")).expect("register"))
            .collect();
        assert!(FULL.register("one-more").is_err());
        assert!(FULL.request_cancel("unknown").is_err());
        drop(live);
        assert!(FULL.register("one-more").is_ok());
    }
}
