//! Polled cancellation for the post-session pipeline.
//!
//! A post-session call is a single synchronous FFI descent: once Dart has
//! entered [`api_integrate_session`] there is no await point to cancel and no
//! task to abort. Safing therefore needs a flag the native loops read, which is
//! the one piece of shared state this module owns — the pipeline itself stays
//! stateless per call.
//!
//! Tokens are keyed by the caller's run id so a cancellation aimed at one run
//! can never stop the next one. A run started without a run id is not
//! cancellable, and says so rather than pretending otherwise.
//!
//! Cancellation is checked at every stage boundary and inside the per-frame
//! loops, and always **before** the master is written. Once the master exists on
//! disk the run finishes normally: reporting a cancelled run while a complete
//! master sits beside it would misdescribe what is on disk.

use super::*;
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};

/// Upper bound on tracked run ids.
///
/// A live run removes itself when it finishes, so this only bounds the pre-armed
/// entries a caller can create by cancelling runs that never start. Past the
/// cap, cancelling an unknown id is an explicit error rather than an unbounded
/// leak.
const MAX_TRACKED_RUNS: usize = 32;

/// The `kind` discriminator every cancelled post-session call carries.
pub(crate) const CANCELLED_KIND: &str = "cancelled";

/// One tracked run id: its cancellation flag, plus whether a call is currently
/// executing under it.
///
/// The two are separate because a cancellation may be **pre-armed** — requested
/// before the run reaches Rust — and a pre-arm must be distinguishable from a
/// run in flight.
struct RunEntry {
    cancel: AtomicBool,
    live: AtomicBool,
}

/// Cancellation state for in-flight (and pre-armed) post-session runs.
///
/// A `BTreeMap` keeps the key order fixed; nothing here touches pixels, but the
/// same no-`HashMap`-ordering rule keeps status output and eviction stable.
static CANCEL_REGISTRY: OnceLock<Mutex<BTreeMap<String, Arc<RunEntry>>>> = OnceLock::new();

/// The registry, taking the lock and recovering it if a panic poisoned it: the
/// contents are two atomics with no invariant to break, and refusing to unlock
/// would make every later run unstoppable.
fn registry() -> MutexGuard<'static, BTreeMap<String, Arc<RunEntry>>> {
    let lock = CANCEL_REGISTRY.get_or_init(|| Mutex::new(BTreeMap::new()));
    match lock.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    }
}

/// The typed outcome a cancelled run returns as its `Err` payload: the JSON
/// encoding of this struct, so a caller decodes it instead of matching on prose.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct CancelledOutcome {
    /// Always [`CANCELLED_KIND`].
    pub(crate) kind: String,
    pub(crate) run_id: String,
    /// The pipeline stage the run stopped at, from the same vocabulary the
    /// integration progress events publish.
    pub(crate) stage: String,
    /// Frames finished in that stage when it is a per-frame loop.
    pub(crate) frames_done: Option<u32>,
    pub(crate) frames_total: Option<u32>,
}

/// A run's cancellation flag, held for the run's lifetime.
///
/// Dropping the token releases the run id, so a later run may reuse it and a
/// later cancellation starts from a clean flag.
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct RunCancelToken {
    /// `None` for a run with no run id — never cancellable.
    run_id: Option<String>,
    entry: Option<Arc<RunEntry>>,
}

impl RunCancelToken {
    /// Claim `run_id` for this call and take its flag. A blank id yields an
    /// inert token: a caller that supplies no id has no handle to cancel by.
    ///
    /// A pre-armed flag is adopted as-is, so a run whose cancellation arrived
    /// first stops at its very first check instead of running to completion.
    /// A run id already in flight is refused — two concurrent runs sharing one
    /// id could not be cancelled independently, and the first to finish would
    /// release the other's flag.
    pub(crate) fn register(run_id: &str) -> Result<Self, String> {
        let id = run_id.trim();
        if id.is_empty() {
            return Ok(Self {
                run_id: None,
                entry: None,
            });
        }
        let mut map = registry();
        let entry = match map.get(id) {
            Some(existing) => {
                if existing.live.load(Ordering::Relaxed) {
                    return Err(format!("post-session run '{id}' is already in flight"));
                }
                existing.clone()
            }
            None => {
                if map.len() >= MAX_TRACKED_RUNS {
                    return Err(format!(
                        "cannot track run '{id}': {MAX_TRACKED_RUNS} post-session run ids are already tracked"
                    ));
                }
                let entry = Arc::new(RunEntry {
                    cancel: AtomicBool::new(false),
                    live: AtomicBool::new(false),
                });
                map.insert(id.to_string(), entry.clone());
                entry
            }
        };
        entry.live.store(true, Ordering::Relaxed);
        Ok(Self {
            run_id: Some(id.to_string()),
            entry: Some(entry),
        })
    }

    /// The run id this token answers for, or `""` when the run is untracked.
    pub(crate) fn run_id(&self) -> &str {
        self.run_id.as_deref().unwrap_or("")
    }

    /// Whether cancellation has been requested for this run.
    pub(crate) fn is_cancelled(&self) -> bool {
        self.entry
            .as_ref()
            .is_some_and(|e| e.cancel.load(Ordering::Relaxed))
    }

    /// `Err` carrying the encoded [`CancelledOutcome`] when this run has been
    /// cancelled, `Ok(())` otherwise. Called at every stage boundary and inside
    /// the per-frame loops.
    pub(crate) fn check(
        &self,
        stage: &str,
        frames_done: Option<u32>,
        frames_total: Option<u32>,
    ) -> Result<(), String> {
        if !self.is_cancelled() {
            return Ok(());
        }
        let outcome = CancelledOutcome {
            kind: CANCELLED_KIND.to_string(),
            run_id: self.run_id().to_string(),
            stage: stage.to_string(),
            frames_done,
            frames_total,
        };
        // The encoding cannot fail for this shape; if it somehow did, the run
        // must still stop, so fall back to the discriminator alone.
        Err(serde_json::to_string(&outcome).unwrap_or_else(|_| CANCELLED_KIND.to_string()))
    }
}

impl Drop for RunCancelToken {
    fn drop(&mut self) {
        let Some(id) = self.run_id.as_deref() else {
            return;
        };
        if let Some(entry) = self.entry.as_ref() {
            entry.live.store(false, Ordering::Relaxed);
        }
        registry().remove(id);
    }
}

/// Request for [`api_post_session_cancel`].
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct PostSessionCancelArgs {
    /// `"cancel"` (default) | `"status"` | `"clear"`.
    pub(crate) op: String,
    /// The run id the caller passed to the post-session entry point.
    pub(crate) run_id: String,
}

/// Response for [`api_post_session_cancel`].
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct PostSessionCancelResult {
    pub(crate) run_id: String,
    /// The op that ran.
    pub(crate) op: String,
    /// `true` when a post-session call is executing under this id right now.
    /// `false` after a `cancel` means the flag is pre-armed for a run that has
    /// not started (or has already finished) — not that the request was lost.
    pub(crate) running: bool,
    /// The run's cancellation flag after the op.
    pub(crate) cancel_requested: bool,
}

/// Dispatch one cancellation op. See [`api_post_session_cancel`].
pub(crate) fn post_session_cancel(
    args: PostSessionCancelArgs,
) -> Result<PostSessionCancelResult, String> {
    let id = args.run_id.trim();
    if id.is_empty() {
        return Err("runId is required".to_string());
    }
    let op = match args.op.trim() {
        "" => "cancel",
        other => other,
    };
    let mut map = registry();
    let live = map.get(id).is_some_and(|e| e.live.load(Ordering::Relaxed));

    let cancel_requested = match op {
        "cancel" => {
            let entry = match map.get(id) {
                Some(existing) => existing.clone(),
                None => {
                    if map.len() >= MAX_TRACKED_RUNS {
                        return Err(format!(
                            "cannot pre-arm cancellation for '{id}': {MAX_TRACKED_RUNS} run ids are already tracked"
                        ));
                    }
                    // Pre-arm: safing can fire before the run reaches Rust, and
                    // a request that lands in that window must still be honoured.
                    let entry = Arc::new(RunEntry {
                        cancel: AtomicBool::new(false),
                        live: AtomicBool::new(false),
                    });
                    map.insert(id.to_string(), entry.clone());
                    entry
                }
            };
            entry.cancel.store(true, Ordering::Relaxed);
            true
        }
        "status" => map
            .get(id)
            .is_some_and(|e| e.cancel.load(Ordering::Relaxed)),
        "clear" => {
            // Only a pre-arm may be dropped. Clearing a live run's flag would
            // silently resurrect a run the operator already stopped.
            if live {
                return Err(format!(
                    "run '{id}' is in flight; clear only drops a pre-armed cancellation"
                ));
            }
            map.remove(id);
            false
        }
        other => {
            return Err(format!(
                "unknown cancel op '{other}'; expected cancel/status/clear"
            ))
        }
    };

    Ok(PostSessionCancelResult {
        run_id: id.to_string(),
        op: op.to_string(),
        running: live,
        cancel_requested,
    })
}
