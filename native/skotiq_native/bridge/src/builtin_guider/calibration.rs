use super::*;

pub(crate) async fn calibrate_mount_response(
    controller: Arc<RwLock<BuiltinGuiderState>>,
) -> Result<GuideCalibration, SkotiqError> {
    let baseline = capture_guide_frame().await?;
    {
        let mut guard = controller.write().await;
        guard.reference_stars =
            select_reference_stars(&baseline.stars, baseline.image.width, baseline.image.height);
        guard.manual_lock = choose_lock_star(&baseline.stars, None, None).map(|star| Vec2 {
            x: star.x,
            y: star.y,
        });
        update_snapshot_from_frame(&mut guard, &baseline, 50);
        guard.last_frame = Some(baseline.clone());
    }

    let east = calibrate_axis_response("east", "west", &baseline).await?;
    // After the RA round-trip the scope is back near baseline. Recapture so the
    // Dec calibration measures from the current position (RA backlash/PE during
    // the RA round-trip would otherwise contaminate the Dec baseline).
    let dec_baseline = capture_guide_frame().await?;
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
    let device_manager = get_device_manager();
    let refs = select_reference_stars(&baseline.stars, baseline.image.width, baseline.image.height);

    // --- Forward leg: two pulses to get past initial slack and establish rate.
    for _ in 0..2 {
        device_manager
            .mount_pulse_guide(
                &mount_id,
                positive_direction.to_string(),
                config.calibration_ms,
            )
            .await
            .map_err(SkotiqError::from)?;
        tokio::time::sleep(Duration::from_millis(config.settle_sleep_ms)).await;
    }
    let fwd_frame = capture_guide_frame().await?;
    let fwd_offset = measure_offset(&refs, &fwd_frame.stars, Vec2::default()).ok_or_else(|| {
        SkotiqError::OperationFailed("Dec calibration forward star match failed".to_string())
    })?;
    // Per-pulse forward response (two pulses were issued).
    let north = Vec2 {
        x: fwd_offset.x / 2.0,
        y: fwd_offset.y / 2.0,
    };

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
    device_manager
        .mount_pulse_guide(
            &mount_id,
            negative_direction.to_string(),
            config.calibration_ms,
        )
        .await
        .map_err(SkotiqError::from)?;
    tokio::time::sleep(Duration::from_millis(config.settle_sleep_ms)).await;
    let rev_frame = capture_guide_frame().await?;
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

    // Restore toward baseline: issue a second reverse pulse so we end roughly
    // where we started (the forward leg moved two pulses, we have reversed one).
    device_manager
        .mount_pulse_guide(
            &mount_id,
            negative_direction.to_string(),
            config.calibration_ms,
        )
        .await
        .map_err(SkotiqError::from)?;
    tokio::time::sleep(Duration::from_millis(config.settle_sleep_ms)).await;

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
    let device_manager = get_device_manager();

    device_manager
        .mount_pulse_guide(
            &mount_id,
            positive_direction.to_string(),
            config.calibration_ms,
        )
        .await
        .map_err(SkotiqError::from)?;
    tokio::time::sleep(Duration::from_millis(config.settle_sleep_ms)).await;
    let moved_frame = capture_guide_frame().await?;
    let offset = measure_offset(
        &select_reference_stars(&baseline.stars, baseline.image.width, baseline.image.height),
        &moved_frame.stars,
        Vec2::default(),
    )
    .ok_or_else(|| SkotiqError::OperationFailed("Calibration star match failed".to_string()))?;

    device_manager
        .mount_pulse_guide(
            &mount_id,
            negative_direction.to_string(),
            config.calibration_ms,
        )
        .await
        .map_err(SkotiqError::from)?;
    tokio::time::sleep(Duration::from_millis(config.settle_sleep_ms)).await;

    if offset.magnitude() < 0.2 {
        return Err(SkotiqError::OperationFailed(format!(
            "Calibration response on {} axis was too small ({:.3}px)",
            positive_direction,
            offset.magnitude()
        )));
    }

    Ok(offset)
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
