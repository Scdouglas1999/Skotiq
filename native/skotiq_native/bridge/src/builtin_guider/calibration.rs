use crate::builtin_guider::config::{Vec2, GUIDE_MAX_MATCH_DISTANCE_PX};
use crate::builtin_guider::loop_runner::{capture_guide_frame_with_retries, resolve_devices};
use crate::builtin_guider::metrics::{
    choose_lock_star, guide_reference_weight, lock_on, measure_offset, nearest_star,
    select_reference_stars,
};
use crate::builtin_guider::state::{
    state, BuiltinGuiderState, GuideCalibration, GuideFrame, GuideReferenceStar,
};
use crate::device_manager::get_device_manager;
use crate::error::SkotiqError;
use skotiq_imaging::DetectedStar;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::RwLock;

pub(crate) async fn calibrate_mount_response(
    controller: Arc<RwLock<BuiltinGuiderState>>,
) -> Result<GuideCalibration, SkotiqError> {
    let baseline = capture_guide_frame_with_retries().await?;
    {
        let mut guard = controller.write().await;
        lock_on(
            &mut guard,
            &baseline,
            choose_lock_star(&baseline.stars, None, None),
        );
        guard.last_frame = Some(baseline.clone());
    }

    let east = calibrate_axis_response("east", "west", &baseline).await?;
    // After the RA round-trip the scope is back near baseline. Recapture so the
    // Dec calibration measures from the current position (RA backlash/PE during
    // the RA round-trip would otherwise contaminate the Dec baseline).
    let dec_baseline = capture_guide_frame_with_retries().await?;
    let (north, dec_backlash_ms) = calibrate_dec_response("north", "south", &dec_baseline).await?;

    let config = controller.read().await.config.clone();
    let pulse_ms = config.calibration_ms as f64;
    let calibration = build_calibration(east, north, pulse_ms, dec_backlash_ms)?;

    if (calibration.orthogonality_deg - 90.0).abs() > 25.0 {
        tracing::warn!(
            "Built-in guider calibration axes are non-orthogonal ({:.1}°); guiding will still \
             apply the full 2x2 solve but accuracy may be degraded",
            calibration.orthogonality_deg
        );
    }
    if dec_backlash_ms > 0.0 {
        tracing::info!(
            "Built-in guider measured Dec backlash of {:.0}ms",
            dec_backlash_ms
        );
    }

    // Lock where the star is now, as PHD2 does: the pulses never bring it back
    // exactly, and tracking drifts while the legs run, so a lock chosen before
    // calibration starts guiding off by that whole drift.
    let settled = capture_guide_frame_with_retries().await?;
    {
        let mut guard = controller.write().await;
        lock_on(
            &mut guard,
            &settled,
            choose_lock_star(&settled.stars, None, None),
        );
        guard.last_frame = Some(settled);
    }

    Ok(calibration)
}

/// Pure construction of the calibration model from the two measured axis-response
/// vectors. Validates non-singularity, derives the inter-axis angle, and carries
/// the measured Dec backlash. Separate from [`calibrate_mount_response`] so the
/// calibration math (angles/rates/orthogonality/backlash plumbing) is unit
/// testable without driving a mount.
pub(crate) fn build_calibration(
    east: Vec2,
    north: Vec2,
    pulse_ms: f64,
    dec_backlash_ms: f64,
) -> Result<GuideCalibration, SkotiqError> {
    let determinant = east.x * north.y - east.y * north.x;
    if determinant.abs() < 1e-3 {
        return Err(SkotiqError::OperationFailed(
            "Built-in guider calibration is singular; mount pulse responses were not distinct"
                .to_string(),
        ));
    }

    // Angle between the RA and Dec response vectors, in [0, 180].
    let dot = east.x * north.x + east.y * north.y;
    let mag = east.magnitude() * north.magnitude();
    let orthogonality_deg = if mag > 1e-9 {
        (dot / mag).clamp(-1.0, 1.0).acos().to_degrees()
    } else {
        90.0
    };

    Ok(GuideCalibration {
        east,
        north,
        pulse_ms,
        dec_backlash_ms: dec_backlash_ms.max(0.0),
        orthogonality_deg,
    })
}

/// Calibrate the Dec axis and measure first-reversal backlash.
///
/// Pulses Dec+ twice (to establish the forward rate past any initial slack),
/// then reverses to Dec- and measures the FIRST reverse-pulse response. The
/// shortfall of that first reverse displacement versus the established
/// per-pulse forward rate is the backlash dead-band: the gear took up slack
/// before the scope moved, so it travelled less than a clean pulse would. The
/// backlash is reported in equivalent pulse-milliseconds (`shortfall_px /
/// rate_px_per_ms`).
pub(crate) async fn calibrate_dec_response(
    positive_direction: &str,
    negative_direction: &str,
    baseline: &GuideFrame,
) -> Result<(Vec2, f64), SkotiqError> {
    let (_, mount_id) = resolve_devices().await?;
    let config = state().read().await.config.clone();
    let refs = select_reference_stars(&baseline.stars, baseline.image.width, baseline.image.height);

    // --- Forward leg: at least two pulses to get past initial slack, then on
    // until the star has clearly moved; the rate is the per-pulse average.
    let leg = pulse_until_moved(&mount_id, positive_direction, &refs, &config, 2).await;
    let (fwd_offset, fwd_pulses, fwd_frame) = match leg {
        Ok(leg) => leg,
        Err(failure) => {
            // Back toward the start where the mount allows; the leg's own error is
            // the one reported.
            if let Err(back) = pulse_repeatedly(
                &mount_id,
                negative_direction,
                failure.walk_back_pulses(),
                &config,
            )
            .await
            {
                tracing::warn!(
                    "Calibration could not pulse back {negative_direction} after a failed leg: {back}"
                );
            }
            return Err(failure.error);
        }
    };
    let north = fwd_offset.scaled(1.0 / f64::from(fwd_pulses));

    if north.magnitude() < 0.2 {
        return Err(SkotiqError::OperationFailed(format!(
            "Calibration response on {positive_direction} axis was too small ({:.3}px/pulse)",
            north.magnitude()
        )));
    }

    // --- Reverse leg: one pulse, measure the first-reversal response.
    let refs_after_fwd = select_reference_stars(
        &fwd_frame.stars,
        fwd_frame.image.width,
        fwd_frame.image.height,
    );
    pulse_repeatedly(&mount_id, negative_direction, 1, &config).await?;
    let rev_frame = capture_guide_frame_with_retries().await?;
    // A failed reverse star match must not be fed to the estimator as "the mount
    // did not move". Work the arithmetic: reverse_first = (0,0) makes
    // reverse_travel 0, so shortfall == fwd_mag and the result is EXACTLY
    // pulse_ms — the maximum plausible backlash, indistinguishable from a
    // genuinely sloppy mount. That value is then added to every Dec direction
    // reversal for the rest of the session (see the `reversing` branch in the
    // correction path), causing gross Dec overshoot from one lost star.
    //
    // Unlike the forward leg this is not fatal: the forward leg establishes the
    // guide RATE and calibration is worthless without it, whereas backlash is an
    // optional refinement. So degrade to "unmeasured" (0 = no compensation,
    // which is the same behaviour as a mount that was never characterised)
    // rather than aborting an otherwise-good calibration — but say so loudly.
    let rev_offset = measure_offset(&refs_after_fwd, &rev_frame.stars, Vec2::default());
    let dec_backlash_ms = match rev_offset {
        Some(offset) => estimate_dec_backlash_ms(north, offset, config.calibration_ms as f64),
        None => {
            tracing::warn!(
                "Built-in guider: Dec calibration reverse star match failed; leaving Dec \
                 backlash UNMEASURED (no compensation) rather than inferring a full-pulse \
                 backlash from a lost star."
            );
            0.0
        }
    };

    // Restore toward baseline: the forward leg moved `fwd_pulses`, the
    // backlash probe reversed one.
    pulse_repeatedly(
        &mount_id,
        negative_direction,
        fwd_pulses.saturating_sub(1),
        &config,
    )
    .await?;

    Ok((north, dec_backlash_ms))
}

/// Estimate Dec backlash (in pulse-ms) from the per-pulse forward response and
/// the measured first-reversal response, given the calibration pulse width.
///
/// The first reverse pulse travels less than a clean pulse by the dead band the
/// gear takes up. We project the reverse displacement onto the (negated) forward
/// axis to get the effective reverse travel, compute the shortfall versus the
/// clean per-pulse magnitude, and convert that pixel shortfall back to ms using
/// the forward rate. A negative/zero shortfall means no measurable backlash.
pub(crate) fn estimate_dec_backlash_ms(
    forward_per_pulse: Vec2,
    reverse_first: Vec2,
    pulse_ms: f64,
) -> f64 {
    let fwd_mag = forward_per_pulse.magnitude();
    if fwd_mag < 1e-6 || pulse_ms <= 0.0 {
        return 0.0;
    }
    // Unit vector along the reverse (negative-forward) direction.
    let inv = 1.0 / fwd_mag;
    let rx = -forward_per_pulse.x * inv;
    let ry = -forward_per_pulse.y * inv;
    // Effective reverse travel along the axis (projection).
    let reverse_travel = reverse_first.x * rx + reverse_first.y * ry;
    let shortfall = fwd_mag - reverse_travel;
    if shortfall <= 0.0 {
        return 0.0;
    }
    let rate_px_per_ms = fwd_mag / pulse_ms;
    if rate_px_per_ms <= 0.0 {
        return 0.0;
    }
    (shortfall / rate_px_per_ms).max(0.0)
}

pub(crate) async fn calibrate_axis_response(
    positive_direction: &str,
    negative_direction: &str,
    baseline: &GuideFrame,
) -> Result<Vec2, SkotiqError> {
    let (_, mount_id) = resolve_devices().await?;
    let config = state().read().await.config.clone();
    let refs = select_reference_stars(&baseline.stars, baseline.image.width, baseline.image.height);
    let leg = pulse_until_moved(&mount_id, positive_direction, &refs, &config, 1).await;
    // Walk back the way the leg came, whatever happened to its measurement.
    let pulses = match &leg {
        Ok((_, pulses, _)) => *pulses,
        Err(failure) => failure.walk_back_pulses(),
    };
    pulse_repeatedly(&mount_id, negative_direction, pulses, &config).await?;
    let (travel, pulses, _) = leg.map_err(|failure| failure.error)?;
    let offset = travel.scaled(1.0 / f64::from(pulses));

    if offset.magnitude() < 0.2 / f64::from(pulses) {
        return Err(SkotiqError::OperationFailed(format!(
            "Calibration response on {} axis was too small ({:.3}px over {} pulses)",
            positive_direction,
            travel.magnitude(),
            pulses
        )));
    }

    Ok(offset)
}

/// A calibration leg pulses at least this many times and stops once the star
/// has moved [`CALIBRATION_TARGET_PX`], or after [`CALIBRATION_MAX_PULSES`].
///
/// One 250 ms pulse moves the star about as far as seeing does between two
/// frames (about 2 arcseconds at half sidereal rate), so a single-pulse leg
/// measured a direction that was as much noise as motion: the simulator's
/// calibration came out 44 degrees off perpendicular. The rate is the
/// per-pulse average over the whole leg.
pub(crate) const CALIBRATION_MIN_PULSES: u32 = 3;
pub(crate) const CALIBRATION_MAX_PULSES: u32 = 16;
pub(crate) const CALIBRATION_TARGET_PX: f64 = 8.0;

/// Whether a calibration leg has moved far enough after `pulses` pulses.
pub(crate) fn calibration_leg_done(pulses: u32, travel_px: f64, min_pulses: u32) -> bool {
    pulses >= CALIBRATION_MAX_PULSES
        || (pulses >= min_pulses.max(CALIBRATION_MIN_PULSES) && travel_px >= CALIBRATION_TARGET_PX)
}

/// A calibration leg that ended before it was done: the pulses it had sent
/// and why it stopped.
pub(crate) struct LegFailure {
    pub(crate) pulses_sent: u32,
    pub(crate) error: SkotiqError,
}

impl LegFailure {
    /// How many pulses the walk back toward the start sends.
    pub(crate) fn walk_back_pulses(&self) -> u32 {
        self.pulses_sent
    }
}

/// Pulse `direction` until [`calibration_leg_done`], measuring after each
/// pulse. Returns the total displacement, the pulses sent and the last frame.
async fn pulse_until_moved(
    mount_id: &str,
    direction: &str,
    refs: &[GuideReferenceStar],
    config: &crate::builtin_guider::config::GuiderConfig,
    min_pulses: u32,
) -> Result<(Vec2, u32, GuideFrame), LegFailure> {
    drive_leg(
        direction,
        min_pulses,
        || pulse_repeatedly(mount_id, direction, 1, config),
        |travel| async move {
            let frame = capture_guide_frame_with_retries().await?;
            // Look for each star where the leg has carried it so far: matched
            // against where it started, a star several pixels along is often
            // nearer a neighbour's old place than its own.
            Ok((measure_offset(refs, &frame.stars, travel), frame))
        },
    )
    .await
}

/// The pulse loop of a calibration leg: `pulse` sends one pulse, and
/// `measure(travel)` takes a frame and returns how far the stars moved past
/// `travel` (none when they cannot be matched) with that frame.
async fn drive_leg<F, Pulse, PulseDone, Measure, Measured>(
    direction: &str,
    min_pulses: u32,
    mut pulse: Pulse,
    mut measure: Measure,
) -> Result<(Vec2, u32, F), LegFailure>
where
    Pulse: FnMut() -> PulseDone,
    PulseDone: std::future::Future<Output = Result<(), SkotiqError>>,
    Measure: FnMut(Vec2) -> Measured,
    Measured: std::future::Future<Output = Result<(Option<Vec2>, F), SkotiqError>>,
{
    let mut pulses = 0;
    let mut travel = Vec2::default();
    let failed = |pulses_sent: u32| move |error: SkotiqError| LegFailure { pulses_sent, error };
    loop {
        pulse().await.map_err(failed(pulses))?;
        pulses += 1;
        let (step, frame) = measure(travel).await.map_err(failed(pulses))?;
        let step = step.ok_or_else(|| LegFailure {
            pulses_sent: pulses,
            error: SkotiqError::OperationFailed(format!(
                "Calibration star match failed after {pulses} {direction} pulses"
            )),
        })?;
        travel = Vec2 {
            x: travel.x + step.x,
            y: travel.y + step.y,
        };
        if calibration_leg_done(pulses, travel.magnitude(), min_pulses) {
            return Ok((travel, pulses, frame));
        }
    }
}

async fn pulse_repeatedly(
    mount_id: &str,
    direction: &str,
    count: u32,
    config: &crate::builtin_guider::config::GuiderConfig,
) -> Result<(), SkotiqError> {
    for _ in 0..count {
        get_device_manager()
            .mount_pulse_guide(mount_id, direction.to_string(), config.calibration_ms)
            .await
            .map_err(SkotiqError::from)?;
        tokio::time::sleep(Duration::from_millis(config.settle_sleep_ms)).await;
    }
    Ok(())
}

/// One reference star's matched per-frame displacement plus its weight, the raw
/// material for the robust centroid.
#[derive(Clone, Copy)]
pub(crate) struct StarDisplacement {
    pub(crate) delta: Vec2,
    pub(crate) weight: f64,
}

/// Match each reference star to its nearest detection on the current frame and
/// return the per-star displacement (`detected - expected`) with its weight.
/// Unmatched references (star lost behind cloud / off-edge under rotation) are
/// simply omitted, which is what lets the guider tolerate individual star loss.
pub(crate) fn matched_displacements(
    reference_stars: &[GuideReferenceStar],
    current_stars: &[DetectedStar],
    desired_offset: Vec2,
) -> Vec<StarDisplacement> {
    let mut out = Vec::with_capacity(reference_stars.len());
    for reference in reference_stars {
        let expected = Vec2 {
            x: reference.x + desired_offset.x,
            y: reference.y + desired_offset.y,
        };
        if let Some(star) = nearest_star(current_stars, expected, GUIDE_MAX_MATCH_DISTANCE_PX) {
            out.push(StarDisplacement {
                delta: Vec2 {
                    x: star.x - expected.x,
                    y: star.y - expected.y,
                },
                weight: guide_reference_weight(reference),
            });
        }
    }
    out
}

#[cfg(test)]
mod calibration_leg_tests {
    use super::*;

    #[test]
    fn a_leg_never_stops_on_one_pulse() {
        assert!(!calibration_leg_done(1, 20.0, 1));
        assert!(!calibration_leg_done(2, 20.0, 1));
        assert!(calibration_leg_done(3, 20.0, 1));
    }

    #[test]
    fn a_leg_goes_on_until_the_star_has_clearly_moved() {
        assert!(!calibration_leg_done(5, 2.0, 1));
        assert!(calibration_leg_done(5, CALIBRATION_TARGET_PX, 1));
    }

    /// A leg that fails at pulse `fail_at`, by losing its star or its frame,
    /// or whose next pulse is refused.
    async fn leg_failing_at(fail_at: u32, how: &str) -> LegFailure {
        let sent = std::cell::Cell::new(0u32);
        let pulses = &sent;
        let step = Vec2 { x: 0.5, y: 0.0 };
        let leg = drive_leg(
            "north",
            1,
            || {
                let refused = how == "pulse" && pulses.get() == fail_at;
                async move {
                    if refused {
                        Err(SkotiqError::OperationFailed("pulse refused".into()))
                    } else {
                        pulses.set(pulses.get() + 1);
                        Ok(())
                    }
                }
            },
            |_| {
                let here = pulses.get() == fail_at;
                async move {
                    match (here, how) {
                        (true, "star") => Ok((None, ())),
                        (true, "frame") => {
                            Err(SkotiqError::OperationFailed("download failed".into()))
                        }
                        _ => Ok((Some(step), ())),
                    }
                }
            },
        )
        .await;
        let failure = leg.expect_err("the leg fails");
        assert_eq!(failure.pulses_sent, sent.get(), "{how} at {fail_at}");
        failure
    }

    /// A leg that fails part way walks back the pulses it sent, not a full leg:
    /// a full leg would leave the mount up to 15 pulses past where it started.
    #[tokio::test]
    async fn a_failed_leg_walks_back_only_the_pulses_it_sent() {
        for fail_at in [1, 4, CALIBRATION_MAX_PULSES - 1] {
            assert_eq!(
                leg_failing_at(fail_at, "star").await.walk_back_pulses(),
                fail_at
            );
            assert_eq!(
                leg_failing_at(fail_at, "frame").await.walk_back_pulses(),
                fail_at
            );
            assert_eq!(
                leg_failing_at(fail_at, "pulse").await.walk_back_pulses(),
                fail_at
            );
        }
    }

    #[test]
    fn a_leg_that_barely_moves_still_ends() {
        assert!(calibration_leg_done(CALIBRATION_MAX_PULSES, 0.5, 1));
    }
}
