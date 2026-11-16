//! The escalation one frame's solve runs: the caller's radius around its
//! hint, then a wide one, then blind, all inside the operator's timeout.

use super::admission::acquire_solve_gate;
use crate::error::SkotiqError;
use skotiq_imaging::PlateSolveResult;
use std::time::{Duration, Instant};

const DEFAULT_SOLVER_TIMEOUT_SECS: u32 = 60;
const MAX_SOLVER_TIMEOUT_SECS: u32 = 3600;

pub(super) fn validate_solver_timeout(timeout_secs: Option<u32>) -> Result<u32, SkotiqError> {
    let timeout = timeout_secs.unwrap_or(DEFAULT_SOLVER_TIMEOUT_SECS);
    if timeout == 0 || timeout > MAX_SOLVER_TIMEOUT_SECS {
        return Err(SkotiqError::InvalidParameter(format!(
            "Plate-solve timeout must be between 1 and {MAX_SOLVER_TIMEOUT_SECS} seconds"
        )));
    }
    Ok(timeout)
}

/// The radius a hinted solve widens to before it gives up on the hint.
///
/// 30° is the whole pole region for a polar-alignment frame and far more than
/// any live pointing error, so a hint that is merely stale still lands inside
/// it. A hint that is wrong by more than this is not a hint.
pub(crate) const WIDE_SEARCH_RADIUS_DEG: f64 = 30.0;

/// Shortest rung worth starting. Below this the solver cannot finish and the
/// time is better spent reporting the failure.
const MIN_LADDER_RUNG_SECS: f64 = 3.0;

/// Share of the budget the hinted rungs may spend between them before the
/// blind rung gets the rest.
///
/// A hinted solve succeeds in seconds or not at all — the rig's failed hinted
/// attempts came back in about a second — so half is already far more than
/// they need, and reserving the other half means a stale hint never costs the
/// frame its blind solve.
const HINTED_BUDGET_FRACTION: f64 = 0.5;

/// Floor under the hinted rungs' share, so a short configured timeout still
/// gives the fast path a fair chance.
const MIN_HINTED_BUDGET_SECS: f64 = 15.0;

/// Below this there is no point starting the blind rung.
const MIN_BLIND_BUDGET_SECS: f64 = 10.0;

/// Smallest total budget a caller may configure.
const MIN_SOLVE_BUDGET_SECS: f64 = 5.0;

/// How far the async watchdog sits beyond the solver's own process timeouts.
///
/// Each rung hands the solver its own deadline, so the solver kills its child,
/// says "ASTAP timed out after N seconds" and releases the gate. This watchdog
/// is only for a solve that wedges somewhere other than the child process, so
/// it must fire strictly later — on the rig both fired at 30 s and one frame
/// was reported as two separate failures of itself.
const SOLVE_WATCHDOG_MARGIN_SECS: f64 = 5.0;

/// Where the telescope is thought to be, and how far around that to look.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct SolvePosition {
    /// Degrees, not hours.
    pub(crate) ra_degrees: f64,
    pub(crate) dec_degrees: f64,
    pub(crate) search_radius_deg: f64,
}

/// How one frame's budget is split between the hinted rungs and the blind one.
/// Seconds; `0.0` means "do not attempt".
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct SolveBudget {
    pub(crate) hinted_secs: f64,
    pub(crate) blind_secs: f64,
}

/// Split a frame's solve budget so the whole ladder fits inside it.
///
/// The operator configured a timeout for solving this frame and that is what
/// the frame is allowed to take. Running each rung for the full timeout would
/// silently triple it.
pub(crate) fn split_solve_budget(total_secs: f64, has_hint: bool) -> SolveBudget {
    let total = if total_secs.is_finite() {
        total_secs.clamp(MIN_SOLVE_BUDGET_SECS, f64::from(MAX_SOLVER_TIMEOUT_SECS))
    } else {
        f64::from(DEFAULT_SOLVER_TIMEOUT_SECS)
    };

    if !has_hint {
        return SolveBudget {
            hinted_secs: 0.0,
            blind_secs: total,
        };
    }

    let hinted = (total * HINTED_BUDGET_FRACTION)
        .max(MIN_HINTED_BUDGET_SECS)
        .min(total);
    let remaining = total - hinted;
    SolveBudget {
        hinted_secs: hinted,
        // A blind rung that cannot finish is worse than none: it spends the
        // operator's night to arrive at the same failure.
        blind_secs: if remaining >= MIN_BLIND_BUDGET_SECS {
            remaining
        } else {
            0.0
        },
    }
}

/// The radii a hinted solve tries, in order.
///
/// A caller who already asked for the wide radius (or wider) does not get the
/// same solve run twice.
pub(crate) fn ladder_radii(requested_deg: f64) -> Vec<f64> {
    if !requested_deg.is_finite() || requested_deg <= 0.0 {
        return vec![WIDE_SEARCH_RADIUS_DEG];
    }
    if requested_deg >= WIDE_SEARCH_RADIUS_DEG {
        return vec![requested_deg];
    }
    vec![requested_deg, WIDE_SEARCH_RADIUS_DEG]
}

/// Run the escalation ladder for one frame: the caller's radius, then
/// [`WIDE_SEARCH_RADIUS_DEG`], then blind.
///
/// Uncoalesced on purpose: it runs INSIDE [`super::admission::coalesced_solve`],
/// which holds the frame's single-flight entry for the whole ladder.
pub(super) async fn solve_ladder(
    file_path: &str,
    hint: Option<SolvePosition>,
    timeout_secs: Option<u32>,
    scale_arcsec_per_px: Option<f64>,
    downsample: Option<u32>,
) -> Result<PlateSolveResult, SkotiqError> {
    // Without a solver every rung fails the same way at once; the answer is
    // that there is none, not a list of searches that never ran.
    if !skotiq_platesolve::is_solver_available() {
        return Ok(empty_solve_result(skotiq_platesolve::NO_SOLVER_GUIDANCE));
    }
    let total = f64::from(validate_solver_timeout(timeout_secs)?);
    let budget = split_solve_budget(total, hint.is_some());
    let watchdog = Duration::from_secs_f64(total + SOLVE_WATCHDOG_MARGIN_SECS);

    let ladder = async {
        let mut tried: Vec<String> = Vec::new();
        let mut last: Option<PlateSolveResult> = None;

        if let Some(hint) = hint {
            let deadline = Instant::now() + Duration::from_secs_f64(budget.hinted_secs);
            for radius in ladder_radii(hint.search_radius_deg) {
                let remaining = deadline
                    .saturating_duration_since(Instant::now())
                    .as_secs_f64();
                if remaining < MIN_LADDER_RUNG_SECS {
                    break;
                }
                let rung = SolvePosition {
                    search_radius_deg: radius,
                    ..hint
                };
                let result = solve_once(
                    file_path,
                    Some(rung),
                    rung_timeout(remaining),
                    scale_arcsec_per_px,
                    downsample,
                )
                .await?;
                if result.success {
                    tracing::info!(
                        "Plate solve: solved within {:.0}° of RA {:.2}°, Dec {:.2}° in {:.1}s",
                        radius,
                        hint.ra_degrees,
                        hint.dec_degrees,
                        result.solve_time_secs
                    );
                    return Ok(result);
                }
                tracing::warn!(
                    "Plate solve: no solution within {:.0}° of RA {:.2}°, Dec {:.2}° ({}); escalating",
                    radius,
                    hint.ra_degrees,
                    hint.dec_degrees,
                    result.error.as_deref().unwrap_or("no solution found")
                );
                tried.push(format!("{radius:.0}° around the hint"));
                last = Some(result);
            }
        }

        if budget.blind_secs >= MIN_LADDER_RUNG_SECS {
            let result = solve_once(
                file_path,
                None,
                rung_timeout(budget.blind_secs),
                scale_arcsec_per_px,
                downsample,
            )
            .await?;
            if result.success {
                tracing::info!(
                    "Plate solve: solved BLIND in {:.1}s after {} hinted attempt(s)",
                    result.solve_time_secs,
                    tried.len()
                );
                return Ok(result);
            }
            tried.push("a blind solve".to_string());
            last = Some(result);
        }

        // Everything failed. The operator gets the list, because a bare "plate
        // solve failed" against a stale hint reads as "solving is broken".
        let mut result = last.unwrap_or_else(|| empty_solve_result("No solve was attempted"));
        result.success = false;
        result.error = Some(match hint {
            Some(hint) => format!(
                "No solution found for this frame. Tried {} near RA {:.2}°, Dec {:.2}°.",
                tried.join(", then "),
                hint.ra_degrees,
                hint.dec_degrees
            ),
            None => format!(
                "No solution found for this frame. Tried {}.",
                tried.join(", then ")
            ),
        });
        Ok(result)
    };

    match tokio::time::timeout(watchdog, ladder).await {
        Ok(result) => result,
        Err(_) => Err(SkotiqError::OperationFailed(format!(
            "Plate solve did not return within {:.0} seconds",
            watchdog.as_secs_f64()
        ))),
    }
}

/// Seconds a rung hands the solver as its own process timeout: the rung's whole
/// remaining budget, so the solver — not a watchdog racing it — decides the
/// attempt is over, kills the child and says so.
fn rung_timeout(secs: f64) -> u32 {
    secs.ceil().clamp(1.0, f64::from(MAX_SOLVER_TIMEOUT_SECS)) as u32
}

/// A failed result with nothing measured in it, for the case where no solver
/// ever ran.
pub(super) fn empty_solve_result(error: &str) -> PlateSolveResult {
    PlateSolveResult {
        success: false,
        error: Some(error.to_string()),
        ..PlateSolveResult::default()
    }
}

/// One run of the solver on `file_path`: near `position` when there is one,
/// else blind, told the field scale either way.
async fn solve_once(
    file_path: &str,
    position: Option<SolvePosition>,
    timeout_secs: u32,
    scale_arcsec_per_px: Option<f64>,
    downsample: Option<u32>,
) -> Result<PlateSolveResult, SkotiqError> {
    let label = match position {
        Some(hint) => {
            tracing::info!(
                "Plate solving near RA:{:.2}°, Dec:{:.2}°: {}",
                hint.ra_degrees,
                hint.dec_degrees,
                file_path
            );
            "near"
        }
        None => {
            tracing::info!("Blind plate solving: {}", file_path);
            "blind"
        }
    };
    let _solve_guard = acquire_solve_gate(label).await;

    let path = std::path::Path::new(file_path);
    if !path.exists() {
        return Err(SkotiqError::IoError(format!(
            "File not found: {}",
            file_path
        )));
    }

    // External solvers are blocking subprocesses: off the async runtime, with
    // the timeout passed to the process runner, which kills and reaps the
    // child on expiry.
    let owned_path = path.to_path_buf();
    tokio::task::spawn_blocking(move || match position {
        Some(hint) => skotiq_platesolve::solve_near_with_timeout(
            &owned_path,
            hint.ra_degrees,
            hint.dec_degrees,
            hint.search_radius_deg,
            timeout_secs,
            scale_arcsec_per_px,
            downsample,
        ),
        None => skotiq_platesolve::blind_solve_with_timeout(
            &owned_path,
            timeout_secs,
            scale_arcsec_per_px,
            downsample,
        ),
    })
    .await
    .map_err(|error| SkotiqError::OperationFailed(format!("Plate-solve task failed: {error}")))
}

#[cfg(test)]
mod tests {
    use super::super::admission::{coalesced_solve, SolvePreference};
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering as AtomicOrdering};

    /// A stale hint is the common case, not the exceptional one: the manual
    /// solve button hinted from coordinates hours old and ASTAP said "No
    /// solution found!" inside a second. Widening has to happen before the
    /// operator is told solving is broken.
    #[test]
    fn a_narrow_hint_widens_before_it_gives_up() {
        assert_eq!(ladder_radii(5.0), vec![5.0, WIDE_SEARCH_RADIUS_DEG]);
    }

    /// A caller who already asked for the wide radius does not pay for the
    /// same search twice — polar alignment asks for exactly this.
    #[test]
    fn a_hint_that_is_already_wide_is_not_searched_twice() {
        assert_eq!(ladder_radii(WIDE_SEARCH_RADIUS_DEG), vec![30.0]);
        assert_eq!(ladder_radii(45.0), vec![45.0]);
    }

    /// A radius of zero or nonsense is not a search instruction.
    #[test]
    fn a_meaningless_radius_falls_back_to_the_wide_one() {
        assert_eq!(ladder_radii(0.0), vec![WIDE_SEARCH_RADIUS_DEG]);
        assert_eq!(ladder_radii(-3.0), vec![WIDE_SEARCH_RADIUS_DEG]);
        assert_eq!(ladder_radii(f64::NAN), vec![WIDE_SEARCH_RADIUS_DEG]);
    }

    /// Every rung together must fit in the timeout the operator set. Running
    /// each for the full timeout would silently triple the frame's cost.
    #[test]
    fn the_whole_ladder_fits_inside_the_configured_timeout() {
        let budget = split_solve_budget(90.0, true);
        assert!(budget.hinted_secs > 0.0 && budget.blind_secs > 0.0);
        assert!(
            budget.hinted_secs + budget.blind_secs <= 90.0 + 1e-9,
            "{budget:?} outruns the operator's timeout"
        );
        assert!(
            budget.blind_secs >= 30.0,
            "the blind rung must still beat the 26.5s a blind solve took on the rig: {budget:?}"
        );
    }

    /// With no hint there is only the blind rung, so it gets everything.
    #[test]
    fn a_frame_with_no_hint_spends_the_whole_budget_solving_blind() {
        let budget = split_solve_budget(90.0, false);
        assert_eq!(budget.hinted_secs, 0.0);
        assert_eq!(budget.blind_secs, 90.0);
    }

    /// A short configured timeout still gives the fast path its floor, and
    /// refuses to start a blind rung that cannot finish in what is left.
    #[test]
    fn a_short_budget_keeps_the_hinted_floor_and_drops_a_hopeless_blind_rung() {
        let budget = split_solve_budget(20.0, true);
        assert_eq!(budget.hinted_secs, MIN_HINTED_BUDGET_SECS);
        assert_eq!(budget.blind_secs, 0.0);
    }

    /// A nonsense timeout from the wire cannot produce a zero-length rung.
    #[test]
    fn an_impossible_timeout_is_clamped_rather_than_obeyed() {
        let budget = split_solve_budget(0.0, true);
        assert!(budget.hinted_secs >= MIN_SOLVE_BUDGET_SECS);
        let budget = split_solve_budget(f64::NAN, false);
        assert_eq!(budget.blind_secs, f64::from(DEFAULT_SOLVER_TIMEOUT_SECS));
    }

    /// ASTAP owns each rung's deadline, so it kills its own child and says so
    /// instead of being abandoned by a watchdog that fired at the same second.
    #[test]
    fn astap_gets_the_rungs_whole_budget_and_the_watchdog_sits_behind_it() {
        let budget = split_solve_budget(90.0, false);
        assert_eq!(rung_timeout(budget.blind_secs), 90);
        assert!(
            f64::from(rung_timeout(budget.blind_secs)) >= budget.blind_secs,
            "ASTAP must not be killed before the rung gives up"
        );
        assert!(
            90.0 + SOLVE_WATCHDOG_MARGIN_SECS > f64::from(rung_timeout(budget.blind_secs)),
            "the watchdog must fire after ASTAP's own timeout, not with it"
        );
    }

    /// The escalation must live inside the single-flight entry, so a second
    /// caller waiting on the same frame gets the answer the ladder ENDED on
    /// rather than the rung it started with. Two callers, one ladder, one
    /// escalated result.
    #[tokio::test]
    async fn a_follower_receives_the_escalated_result_not_the_first_rung() {
        static RUNS: AtomicUsize = AtomicUsize::new(0);
        let path =
            std::env::temp_dir().join(format!("sk-ladder-coalesce-{}.fits", std::process::id()));
        std::fs::write(&path, b"not a real frame").expect("scratch file");
        let key = path.to_string_lossy().to_string();

        // Stands in for the ladder: slow enough that the second caller is a
        // follower, and it "escalates" from the first rung's failure to a
        // success only at the end.
        let ladder = |key: String| async move {
            coalesced_solve(&key, "test", SolvePreference::Hinted, || async {
                RUNS.fetch_add(1, AtomicOrdering::SeqCst);
                tokio::time::sleep(Duration::from_millis(50)).await;
                let mut escalated = empty_solve_result("first rung failed");
                escalated.success = true;
                escalated.error = None;
                escalated.ra = 42.0;
                Ok(escalated)
            })
            .await
        };

        let leader = tokio::spawn(ladder(key.clone()));
        tokio::time::sleep(Duration::from_millis(10)).await;
        let follower = tokio::spawn(ladder(key.clone()));

        let leader = leader.await.expect("leader").expect("leader result");
        let follower = follower.await.expect("follower").expect("follower result");

        assert_eq!(
            RUNS.load(AtomicOrdering::SeqCst),
            1,
            "the ladder must run once for one frame"
        );
        assert!(leader.success && follower.success);
        assert_eq!(
            follower.ra, 42.0,
            "the follower got a rung's answer instead of the ladder's"
        );

        let _ = std::fs::remove_file(&path);
    }

    /// With no solver installed nothing is tried, so the answer says there is
    /// no solver instead of listing searches that never ran.
    #[tokio::test]
    async fn a_frame_with_no_solver_installed_names_no_search() {
        if skotiq_platesolve::is_solver_available() {
            eprintln!("skipped: this machine has a plate solver installed");
            return;
        }
        let path =
            std::env::temp_dir().join(format!("sk-ladder-message-{}.fits", std::process::id()));
        std::fs::write(&path, b"not a real frame").expect("scratch file");

        let result = solve_ladder(
            &path.to_string_lossy(),
            Some(SolvePosition {
                ra_degrees: 341.84,
                dec_degrees: 58.13,
                search_radius_deg: 5.0,
            }),
            Some(30),
            None,
            None,
        )
        .await
        .expect("a failed solve is a result, not an error");

        assert!(!result.success);
        assert_eq!(
            result.error.as_deref(),
            Some(skotiq_platesolve::NO_SOLVER_GUIDANCE)
        );

        let _ = std::fs::remove_file(&path);
    }
}
