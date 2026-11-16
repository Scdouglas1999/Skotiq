//! One solver process at a time, and one solve per frame.

use crate::error::SkotiqError;
use skotiq_imaging::PlateSolveResult;
use std::collections::HashMap;
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};
use tokio::sync::Mutex;

/// Process-wide admission gate shared by UI, headless HTTP, sequencer, and
/// recovery callers. External solvers write sibling `.ini`/`.wcs` artifacts;
/// allowing overlapping runs can mix or delete another solve's result.
static PLATE_SOLVE_GATE: OnceLock<Mutex<()>> = OnceLock::new();

fn plate_solve_gate() -> &'static Mutex<()> {
    PLATE_SOLVE_GATE.get_or_init(|| Mutex::new(()))
}

/// Solves currently running, keyed by the frame they are solving.
///
/// The admission gate above serialises solves; it does not stop two callers from
/// solving the *same frame twice in a row*, and a second blind solve throws away
/// the position hint the first caller had. One frame has one answer, so the
/// second caller waits for the first caller's result instead of launching a
/// solver of its own.
type SolveOutcome = Result<PlateSolveResult, String>;
type SolveBroadcast = tokio::sync::broadcast::Sender<Arc<SolveOutcome>>;
static IN_FLIGHT_SOLVES: OnceLock<std::sync::Mutex<HashMap<String, SolveBroadcast>>> =
    OnceLock::new();

fn in_flight_solves() -> &'static std::sync::Mutex<HashMap<String, SolveBroadcast>> {
    IN_FLIGHT_SOLVES.get_or_init(|| std::sync::Mutex::new(HashMap::new()))
}

/// What a caller brings to a solve of the same frame.
///
/// Coalescing alone leaves *which* caller leads a race, and the two are not
/// interchangeable: on a real rig a blind ASTAP run costs tens of seconds
/// against a few for a hinted one, and it is the run that can lock onto the
/// wrong field. The hinted caller therefore always leads, so no solve pays the
/// blind cost while a good position hint sits unused in the other caller.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(super) enum SolvePreference {
    /// The caller knows roughly where the telescope is pointing (and/or the
    /// field scale). Always leads.
    Hinted,
    /// The caller knows nothing about the field. Yields the lead briefly so a
    /// hinted caller for the same frame can take it.
    Blind,
}

/// How long a blind caller waits for a hinted caller to claim the same frame.
///
/// The two live requests for one snapshot arrived 4 ms and 11 ms apart. This is
/// an order of magnitude above that and an order of magnitude below the cost it
/// avoids; a blind solve that really is alone pays it once and is otherwise
/// unaffected.
const BLIND_YIELD_WINDOW: Duration = Duration::from_millis(150);
const BLIND_YIELD_POLL: Duration = Duration::from_millis(5);

fn solve_in_flight(key: &str) -> bool {
    in_flight_solves()
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .contains_key(key)
}

/// Removes the in-flight entry even if the solve future is dropped or panics,
/// so one abandoned solve cannot wedge every later solve of that frame.
struct InFlightGuard(String);

impl Drop for InFlightGuard {
    fn drop(&mut self) {
        if let Ok(mut map) = in_flight_solves().lock() {
            map.remove(&self.0);
        }
    }
}

/// Run `solve` for `file_path`, or — if that exact frame is already being
/// solved — wait for the running solve and return its result.
///
/// `label` names the caller in the log so the two callers of a coalesced pair
/// are identifiable afterwards; that log line is the only way the double-solve
/// showed up at all.
pub(super) async fn coalesced_solve<F, Fut>(
    file_path: &str,
    label: &str,
    preference: SolvePreference,
    solve: F,
) -> Result<PlateSolveResult, SkotiqError>
where
    F: FnOnce() -> Fut,
    Fut: std::future::Future<Output = Result<PlateSolveResult, SkotiqError>>,
{
    // Canonicalise so `./frame.fits` and `/tmp/frame.fits` are one frame. A
    // path that cannot be canonicalised (not yet written, odd mount) keys on
    // its own spelling rather than failing the solve.
    let key = std::fs::canonicalize(file_path)
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_else(|_| file_path.to_string());

    // A blind caller offers the lead to a hinted caller for the same frame
    // before claiming it. Nothing is skipped either way: whoever leads,
    // exactly one solver runs and both callers get its answer.
    if preference == SolvePreference::Blind && !solve_in_flight(&key) {
        let deadline = Instant::now() + BLIND_YIELD_WINDOW;
        let mut yielded = false;
        while Instant::now() < deadline {
            tokio::time::sleep(BLIND_YIELD_POLL).await;
            if solve_in_flight(&key) {
                yielded = true;
                break;
            }
        }
        if yielded {
            tracing::info!(
                "Plate solve ({label}): a hinted solve of {key} took the lead; \
                 waiting for it rather than solving blind"
            );
        }
    }

    let (leader_tx, follower_rx) = {
        let mut map = in_flight_solves()
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        match map.get(&key) {
            Some(tx) => (None, Some(tx.subscribe())),
            None => {
                let (tx, _rx) = tokio::sync::broadcast::channel(1);
                map.insert(key.clone(), tx.clone());
                (Some(tx), None)
            }
        }
    };

    if let Some(mut rx) = follower_rx {
        tracing::info!(
            "Plate solve ({label}): {key} is already being solved; waiting for that \
             result instead of starting a second solver process"
        );
        match rx.recv().await {
            Ok(outcome) => return (*outcome).clone().map_err(SkotiqError::OperationFailed),
            Err(e) => {
                tracing::warn!(
                    "Plate solve ({label}): the solve of {key} we were waiting on ended \
                     without publishing a result ({e}); solving it here instead"
                );
                return solve().await;
            }
        }
    }

    let _guard = InFlightGuard(key);
    let result = solve().await;
    if let Some(tx) = leader_tx {
        // Publish before the guard removes the entry: a follower that is
        // already subscribed gets the answer, and any caller arriving after
        // this starts a fresh solve.
        let _ = tx.send(Arc::new(result.clone().map_err(|e| e.to_string())));
    }
    result
}

/// Take the admission gate, saying so when the caller has to wait.
///
/// A solve that queues behind another solve looks, from the outside, exactly
/// like a slow solve. Naming the wait is what turns "the solver is slow"
/// into "two callers are solving at once".
pub(super) async fn acquire_solve_gate(label: &str) -> tokio::sync::MutexGuard<'static, ()> {
    let gate = plate_solve_gate();
    match gate.try_lock() {
        Ok(guard) => guard,
        Err(_) => {
            let waited = Instant::now();
            let guard = gate.lock().await;
            tracing::info!(
                "Plate solve ({label}): waited {:.1}s for another solve to finish \
                 (one solver process at a time)",
                waited.elapsed().as_secs_f64()
            );
            guard
        }
    }
}

/// One frame, one solve.
#[cfg(test)]
mod tests {
    use super::{coalesced_solve, SolvePreference};
    use crate::error::SkotiqError;
    use skotiq_imaging::PlateSolveResult;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    fn result_at(ra: f64) -> PlateSolveResult {
        PlateSolveResult {
            success: true,
            ra,
            pixel_scale: 1.29,
            ..PlateSolveResult::default()
        }
    }

    /// The live shape: two callers hit the same snapshot 4 ms apart and two
    /// `astap_cli` processes ran at once, the second one blind. The second
    /// caller now waits for the first caller's answer.
    #[tokio::test]
    async fn two_callers_on_one_frame_run_one_solver() {
        let runs = Arc::new(AtomicUsize::new(0));
        let path = "/tmp/skotiq-coalesce-one-frame.fits";

        let solve = |runs: Arc<AtomicUsize>| async move {
            runs.fetch_add(1, Ordering::SeqCst);
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
            Ok::<_, SkotiqError>(result_at(42.0))
        };

        let (first, second) = tokio::join!(
            coalesced_solve(path, "near", SolvePreference::Hinted, || solve(
                runs.clone()
            )),
            async {
                // The follower arrives while the leader is still solving.
                tokio::time::sleep(std::time::Duration::from_millis(5)).await;
                coalesced_solve(path, "blind", SolvePreference::Blind, || {
                    solve(runs.clone())
                })
                .await
            }
        );

        assert_eq!(runs.load(Ordering::SeqCst), 1, "a second solver ran");
        assert_eq!(first.unwrap().ra, 42.0);
        assert_eq!(
            second.unwrap().ra,
            42.0,
            "the follower must get the leader's answer, not a blind re-solve"
        );
    }

    /// Coalescing alone leaves the lead to a race, and the caller that leads is
    /// the one whose hints the solver gets. A blind lead throws away a good
    /// position hint and runs the slow, mis-lockable blind path instead.
    #[tokio::test]
    async fn a_hinted_caller_leads_even_when_the_blind_one_arrives_first() {
        let runs = Arc::new(AtomicUsize::new(0));
        let path = "/tmp/skotiq-coalesce-hint-wins.fits";

        // Each closure reports WHICH caller ran the solver, via the RA.
        let solve = |runs: Arc<AtomicUsize>, ra: f64| async move {
            runs.fetch_add(1, Ordering::SeqCst);
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
            Ok::<_, SkotiqError>(result_at(ra))
        };

        let (blind, hinted) = tokio::join!(
            coalesced_solve(path, "blind", SolvePreference::Blind, || solve(
                runs.clone(),
                1.0
            )),
            async {
                // The live pair arrived 4-11 ms apart.
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
                coalesced_solve(path, "near", SolvePreference::Hinted, || {
                    solve(runs.clone(), 2.0)
                })
                .await
            }
        );

        assert_eq!(runs.load(Ordering::SeqCst), 1, "two solvers ran");
        assert_eq!(
            hinted.unwrap().ra,
            2.0,
            "the hinted caller must be the one that runs the solver"
        );
        assert_eq!(
            blind.unwrap().ra,
            2.0,
            "the blind caller takes the hinted answer"
        );
    }

    /// The blind caller must not wait forever for a hinted caller that never
    /// comes — the common case is a blind solve that is genuinely alone.
    #[tokio::test]
    async fn a_lone_blind_caller_still_solves() {
        let runs = Arc::new(AtomicUsize::new(0));
        let path = "/tmp/skotiq-coalesce-lone-blind.fits";
        let solve = |runs: Arc<AtomicUsize>| async move {
            runs.fetch_add(1, Ordering::SeqCst);
            Ok::<_, SkotiqError>(result_at(9.0))
        };

        let started = std::time::Instant::now();
        let result = coalesced_solve(path, "blind", SolvePreference::Blind, || {
            solve(runs.clone())
        })
        .await;

        assert_eq!(runs.load(Ordering::SeqCst), 1);
        assert_eq!(result.unwrap().ra, 9.0);
        assert!(
            started.elapsed() < std::time::Duration::from_millis(1000),
            "the yield window must be a short offer, not a stall"
        );
    }

    /// Coalescing is per frame, not a global one-solve-per-process rule.
    #[tokio::test]
    async fn two_frames_still_get_two_solves() {
        let runs = Arc::new(AtomicUsize::new(0));
        let solve = |runs: Arc<AtomicUsize>| async move {
            runs.fetch_add(1, Ordering::SeqCst);
            Ok::<_, SkotiqError>(result_at(1.0))
        };

        let _ = coalesced_solve(
            "/tmp/skotiq-coalesce-a.fits",
            "near",
            SolvePreference::Hinted,
            || solve(runs.clone()),
        )
        .await;
        let _ = coalesced_solve(
            "/tmp/skotiq-coalesce-b.fits",
            "near",
            SolvePreference::Hinted,
            || solve(runs.clone()),
        )
        .await;

        assert_eq!(runs.load(Ordering::SeqCst), 2);
    }

    /// A finished solve must release its frame, or the first solve of a file
    /// would be the only solve of that file for the life of the process —
    /// re-solving after a re-point would silently return the old answer.
    #[tokio::test]
    async fn a_finished_solve_releases_its_frame() {
        let runs = Arc::new(AtomicUsize::new(0));
        let path = "/tmp/skotiq-coalesce-sequential.fits";
        let solve = |runs: Arc<AtomicUsize>| async move {
            runs.fetch_add(1, Ordering::SeqCst);
            Ok::<_, SkotiqError>(result_at(7.0))
        };

        let _ = coalesced_solve(path, "near", SolvePreference::Hinted, || {
            solve(runs.clone())
        })
        .await;
        let _ = coalesced_solve(path, "near", SolvePreference::Hinted, || {
            solve(runs.clone())
        })
        .await;

        assert_eq!(runs.load(Ordering::SeqCst), 2);
    }
}
