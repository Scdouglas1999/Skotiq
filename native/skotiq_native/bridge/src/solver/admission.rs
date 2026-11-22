//! One solve per frame.

use crate::error::SkotiqError;
use skotiq_imaging::PlateSolveResult;
use std::collections::HashMap;
use std::sync::{Arc, OnceLock, Weak};
use std::time::Duration;
use tokio::sync::{watch, Mutex};

/// Solves currently running, keyed by the frame they are solving.
///
/// The solver gate (`skotiq_platesolve::acquire_solve_gate`) serializes
/// solves; it does not stop two callers from solving the *same frame twice in
/// a row*, and a second blind solve throws away
/// the position hint the first caller had. One frame has one answer, so the
/// second caller waits for the first caller's result instead of launching a
/// solver of its own.
type SolveOutcome = Result<PlateSolveResult, String>;
type SolveRegistry = std::sync::Mutex<HashMap<String, Weak<FrameSolve>>>;
static IN_FLIGHT_SOLVES: OnceLock<SolveRegistry> = OnceLock::new();

fn in_flight_solves() -> &'static SolveRegistry {
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

/// Each caller retains its frame's answer, including a blind caller waiting
/// to offer the lead. The registry itself never keeps an abandoned frame alive.
struct FrameSolve {
    key: String,
    leader: Mutex<()>,
    answer: watch::Sender<Option<SolveOutcome>>,
    yield_until: Option<tokio::time::Instant>,
}

impl FrameSolve {
    fn join(key: String, preference: SolvePreference) -> Arc<Self> {
        let mut map = in_flight_solves()
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(active) = map.get(&key).and_then(Weak::upgrade) {
            return active;
        }
        let (answer, _) = watch::channel(None);
        let active = Arc::new(Self {
            key: key.clone(),
            leader: Mutex::new(()),
            answer,
            yield_until: (preference == SolvePreference::Blind)
                .then(|| tokio::time::Instant::now() + BLIND_YIELD_WINDOW),
        });
        map.insert(key, Arc::downgrade(&active));
        active
    }

    fn retire(&self) {
        let mut map = in_flight_solves()
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        // A slow follower can drop after a fresh solve has claimed the same path.
        if map
            .get(&self.key)
            .is_some_and(|flight| std::ptr::eq(flight.as_ptr(), self))
        {
            map.remove(&self.key);
        }
    }
}

impl Drop for FrameSolve {
    fn drop(&mut self) {
        self.retire();
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

    let frame = FrameSolve::join(key, preference);
    if let (SolvePreference::Blind, Some(deadline)) = (preference, frame.yield_until) {
        let mut answer = frame.answer.subscribe();
        // A fast hinted solve may finish before this caller is scheduled
        // again. The retained answer ends the offer early in that case.
        // Both publication and expiry proceed to the election below, where the
        // answer is checked under the same lock used to choose a replacement.
        let wait = tokio::time::timeout_at(deadline, answer.wait_for(Option::is_some)).await;
        if let Ok(Err(error)) = wait {
            return Err(SkotiqError::OperationFailed(format!(
                "Plate-solve result channel closed for {}: {error}",
                frame.key
            )));
        }
    }

    // Dropping an interrupted leader releases this lock. Exactly one waiter
    // can replace it, and every waiter checks for a completed answer first.
    let _leader = frame.leader.lock().await;
    if let Some(outcome) = frame.answer.borrow().as_ref() {
        tracing::info!(
            "Plate solve ({label}): using the shared answer for {}",
            frame.key
        );
        return outcome.clone().map_err(SkotiqError::OperationFailed);
    }
    let result = solve().await;
    frame
        .answer
        .send_replace(Some(result.clone().map_err(|error| error.to_string())));
    // A later, independent call must solve again, even when an earlier caller
    // has not yet resumed to collect its copy of this answer.
    frame.retire();
    result
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
        let runs = AtomicUsize::new(0);
        let finish = tokio::sync::Notify::new();
        let path = "/tmp/skotiq-coalesce-one-frame.fits";
        let solve = || async {
            runs.fetch_add(1, Ordering::SeqCst);
            finish.notified().await;
            Ok(result_at(42.0))
        };
        let mut first = Box::pin(coalesced_solve(
            path,
            "near",
            SolvePreference::Hinted,
            solve,
        ));
        let mut second = Box::pin(coalesced_solve(
            path,
            "blind",
            SolvePreference::Blind,
            || async {
                runs.fetch_add(1, Ordering::SeqCst);
                Ok(result_at(1.0))
            },
        ));
        assert!(futures::poll!(&mut first).is_pending());
        assert!(futures::poll!(&mut second).is_pending());
        finish.notify_waiters();
        let (first, second) = tokio::join!(first, second);

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
        let runs = AtomicUsize::new(0);
        let finish = tokio::sync::Notify::new();
        let path = "/tmp/skotiq-coalesce-hint-wins.fits";
        let mut blind = Box::pin(coalesced_solve(
            path,
            "blind",
            SolvePreference::Blind,
            || async {
                runs.fetch_add(1, Ordering::SeqCst);
                Ok(result_at(1.0))
            },
        ));
        let mut hinted = Box::pin(coalesced_solve(
            path,
            "near",
            SolvePreference::Hinted,
            || async {
                runs.fetch_add(1, Ordering::SeqCst);
                finish.notified().await;
                Ok(result_at(2.0))
            },
        ));
        assert!(futures::poll!(&mut blind).is_pending());
        assert!(futures::poll!(&mut hinted).is_pending());
        finish.notify_waiters();
        let (blind, hinted) = tokio::join!(blind, hinted);

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

    #[tokio::test]
    async fn a_fast_hinted_solve_reaches_a_blind_caller_still_in_its_yield_window() {
        let key = "skotiq-coalesce-fast-hint.fits";
        let mut blind = Box::pin(coalesced_solve(
            key,
            "blind",
            SolvePreference::Blind,
            || async {
                panic!("the blind caller missed the hinted result during its yield window");
            },
        ));
        assert!(futures::poll!(&mut blind).is_pending());
        let hinted = coalesced_solve(key, "near", SolvePreference::Hinted, || async {
            Ok(result_at(42.0))
        })
        .await
        .unwrap();

        // This later request began after the hinted solve returned. The blind
        // caller still belongs to the earlier solve, even across this new one.
        let finish = tokio::sync::Notify::new();
        let mut fresh = Box::pin(coalesced_solve(
            key,
            "later",
            SolvePreference::Hinted,
            || async {
                finish.notified().await;
                Ok(result_at(7.0))
            },
        ));
        assert!(futures::poll!(&mut fresh).is_pending());
        assert_eq!(hinted.ra, 42.0);
        assert_eq!(blind.await.unwrap().ra, 42.0);
        // Dropping the last caller of the old solve must leave the new one registered.
        let mut follower = Box::pin(coalesced_solve(
            key,
            "later follower",
            SolvePreference::Hinted,
            || async {
                panic!("the earlier solve removed the new registration");
            },
        ));
        assert!(futures::poll!(&mut follower).is_pending());
        finish.notify_waiters();
        let (fresh, follower) = tokio::join!(fresh, follower);
        assert_eq!(fresh.unwrap().ra, 7.0);
        assert_eq!(follower.unwrap().ra, 7.0);
    }

    #[tokio::test]
    async fn a_follower_arriving_during_publication_gets_the_finished_result() {
        let key = "skotiq-coalesce-published.fits";
        let frame = super::FrameSolve::join(key.into(), SolvePreference::Hinted);
        // Freeze publication just before the leader retires the entry.
        frame.answer.send_replace(Some(Ok(result_at(42.0))));
        let mut follower = Box::pin(coalesced_solve(
            key,
            "follower",
            SolvePreference::Hinted,
            || async {
                panic!("a published solve is still available");
            },
        ));
        let std::task::Poll::Ready(result) = futures::poll!(&mut follower) else {
            panic!("a late subscriber missed the published answer");
        };
        assert_eq!(result.unwrap().ra, 42.0);
    }

    #[tokio::test]
    async fn interrupted_leader_is_replaced_once_for_all_waiting_callers() {
        let path = "skotiq-coalesce-interrupted.fits";
        let mut interrupted = Box::pin(coalesced_solve(
            path,
            "interrupted",
            SolvePreference::Hinted,
            std::future::pending,
        ));
        assert!(futures::poll!(&mut interrupted).is_pending());

        let runs = AtomicUsize::new(0);
        let finish = tokio::sync::Notify::new();
        let wait = || {
            coalesced_solve(path, "waiting", SolvePreference::Hinted, || async {
                runs.fetch_add(1, Ordering::SeqCst);
                finish.notified().await;
                Ok(result_at(7.0))
            })
        };
        let mut first = Box::pin(wait());
        let mut second = Box::pin(wait());
        assert!(futures::poll!(&mut first).is_pending());
        assert!(futures::poll!(&mut second).is_pending());
        drop(interrupted);
        assert!(futures::poll!(&mut first).is_pending());
        assert!(futures::poll!(&mut second).is_pending());
        finish.notify_waiters();
        let (first, second) = tokio::join!(first, second);
        assert_eq!(runs.load(Ordering::SeqCst), 1);
        assert_eq!(first.unwrap().ra, 7.0);
        assert_eq!(second.unwrap().ra, 7.0);
    }

    #[tokio::test]
    async fn cancelling_the_only_blind_caller_retires_its_pending_frame() {
        let key = "skotiq-coalesce-pending-blind.fits";
        let mut blind = Box::pin(coalesced_solve(
            key,
            "blind",
            SolvePreference::Blind,
            std::future::pending,
        ));
        assert!(futures::poll!(&mut blind).is_pending());
        assert!(super::in_flight_solves().lock().unwrap().contains_key(key));
        drop(blind);
        assert!(!super::in_flight_solves().lock().unwrap().contains_key(key));
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
