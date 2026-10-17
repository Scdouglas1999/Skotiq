use super::*;

/// Median of a slice (sorted copy). Empty slice -> 0.0.
pub(crate) fn median(values: &[f64]) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    let mut sorted = values.to_vec();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let mid = sorted.len() / 2;
    if sorted.len() % 2 == 0 {
        (sorted[mid - 1] + sorted[mid]) / 2.0
    } else {
        sorted[mid]
    }
}

/// Robust, mass-weighted guide offset.
///
/// The aggregate offset is the SIGMA-CLIPPED, flux/SNR-WEIGHTED mean of the
/// per-star displacements: per-star distances from the median displacement are
/// scaled by 1.4826·MAD into a sigma-equivalent, and any star beyond
/// [`GUIDE_OUTLIER_SIGMA`] is dropped before the weighted mean is taken. This
/// makes a single star that jumps (cloud edge, cosmic ray, misassociation) not
/// move the reported offset.
///
/// Clipping only engages with at least [`GUIDE_MIN_STARS_FOR_CLIP`] matched
/// stars; below that (down to a single star) it degrades gracefully to the plain
/// weighted mean so the guider keeps running on a sparse field. Returns `None`
/// only when no reference matched at all.
pub(crate) fn measure_offset(
    reference_stars: &[GuideReferenceStar],
    current_stars: &[DetectedStar],
    desired_offset: Vec2,
) -> Option<Vec2> {
    let displacements = matched_displacements(reference_stars, current_stars, desired_offset);
    robust_weighted_offset(&displacements)
}

/// Compute the sigma-clipped, weighted-mean offset from a set of matched per-star
/// displacements. Factored out of [`measure_offset`] so the tests can exercise
/// the robust-centroid math directly without constructing detection lists.
pub(crate) fn robust_weighted_offset(displacements: &[StarDisplacement]) -> Option<Vec2> {
    if displacements.is_empty() {
        return None;
    }

    // Sigma-clip on displacement magnitude relative to the median, but only when
    // we have enough samples for the spread estimate to be meaningful.
    let kept: Vec<&StarDisplacement> = if displacements.len() >= GUIDE_MIN_STARS_FOR_CLIP {
        let mags: Vec<f64> = displacements.iter().map(|d| d.delta.magnitude()).collect();
        let med = median(&mags);
        let abs_dev: Vec<f64> = mags.iter().map(|m| (m - med).abs()).collect();
        let mad = median(&abs_dev);
        let mut sigma = mad * MAD_TO_SIGMA;
        // Robustness fallback: MAD collapses to ~0 when a majority of stars share
        // an identical displacement (a clean field with one outlier — the common
        // "one star jumped" case, and what synthetic tests produce). In that
        // degenerate case fall back to the standard deviation about the median so
        // the lone outlier is still clipped.
        if sigma <= 1e-9 {
            let n = mags.len() as f64;
            let var = abs_dev.iter().map(|d| d * d).sum::<f64>() / n;
            sigma = var.sqrt();
        }
        if sigma > 1e-9 {
            let cutoff = GUIDE_OUTLIER_SIGMA * sigma;
            let kept: Vec<&StarDisplacement> = displacements
                .iter()
                .zip(mags.iter())
                .filter(|(_, &m)| (m - med).abs() <= cutoff)
                .map(|(d, _)| d)
                .collect();
            // Never clip everything away; if the cutoff was pathologically tight
            // keep the full set.
            if kept.is_empty() {
                displacements.iter().collect()
            } else {
                kept
            }
        } else {
            // All displacements essentially identical: nothing to clip.
            displacements.iter().collect()
        }
    } else {
        displacements.iter().collect()
    };

    let mut weighted_x = 0.0;
    let mut weighted_y = 0.0;
    let mut total_weight = 0.0;
    for d in kept {
        weighted_x += d.delta.x * d.weight;
        weighted_y += d.delta.y * d.weight;
        total_weight += d.weight;
    }
    if total_weight <= 0.0 {
        return None;
    }
    Some(Vec2 {
        x: weighted_x / total_weight,
        y: weighted_y / total_weight,
    })
}

/// Append a frame's total RMS to the rolling history (capped length), for
/// adaptive dither sizing.
pub(crate) async fn push_rms_sample(controller: &Arc<RwLock<BuiltinGuiderState>>, rms: f64) {
    if !rms.is_finite() {
        return;
    }
    let mut guard = controller.write().await;
    guard.rms_history.push(rms);
    let len = guard.rms_history.len();
    if len > RMS_HISTORY_LEN {
        guard.rms_history.drain(0..len - RMS_HISTORY_LEN);
    }
}

/// Root-mean-square of each axis over a window of per-axis errors, plus the
/// combined total.
///
/// Returns `(rms_ra, rms_dec, rms_total)`. An empty window yields all zeros,
/// matching [`BuiltinGuideStatus::default`] — "no measurement yet" rather than a
/// fabricated one. `rms_total` is the quadrature sum of the two axis RMS values,
/// which is identical to the RMS of the per-frame magnitudes and is what PHD2
/// reports, so the two guiders' numbers are directly comparable.
pub(crate) fn axis_rms(samples: &[Vec2]) -> (f64, f64, f64) {
    if samples.is_empty() {
        return (0.0, 0.0, 0.0);
    }
    let n = samples.len() as f64;
    let sum_sq_x: f64 = samples.iter().map(|s| s.x * s.x).sum();
    let sum_sq_y: f64 = samples.iter().map(|s| s.y * s.y).sum();
    let rms_ra = (sum_sq_x / n).sqrt();
    let rms_dec = (sum_sq_y / n).sqrt();
    (
        rms_ra,
        rms_dec,
        (rms_ra * rms_ra + rms_dec * rms_dec).sqrt(),
    )
}

/// Append a per-axis arcsec error sample, capped to the rolling window.
pub(crate) fn push_arcsec_sample(samples: &mut Vec<Vec2>, sample: Vec2) {
    if !sample.x.is_finite() || !sample.y.is_finite() {
        return;
    }
    samples.push(sample);
    let len = samples.len();
    if len > RMS_HISTORY_LEN {
        samples.drain(0..len - RMS_HISTORY_LEN);
    }
}

/// Mean of the recent RMS history, or `None` when no samples yet.
pub(crate) fn recent_rms(history: &[f64]) -> Option<f64> {
    if history.is_empty() {
        None
    } else {
        Some(history.iter().sum::<f64>() / history.len() as f64)
    }
}

/// Update each reference star's `last_residual` from its matched detection on
/// the current frame. Mirrors the matching done in [`measure_offset`] but per
/// star (no flux weighting): the residual is the vector from the star's
/// expected position to its nearest detected centroid. Stars with no match this
/// frame keep their previous residual (the per-star UI shows the last good
/// value rather than flicking to "—").
pub(crate) fn record_per_star_residuals(
    reference_stars: &mut [GuideReferenceStar],
    current_stars: &[DetectedStar],
    desired_offset: Vec2,
) {
    for reference in reference_stars.iter_mut() {
        let expected = Vec2 {
            x: reference.x + desired_offset.x,
            y: reference.y + desired_offset.y,
        };
        if let Some(star) = nearest_star(current_stars, expected, GUIDE_MAX_MATCH_DISTANCE_PX) {
            reference.last_residual = Some(Vec2 {
                x: star.x - expected.x,
                y: star.y - expected.y,
            });
        }
    }
}

pub(crate) fn guide_reference_weight(reference: &GuideReferenceStar) -> f64 {
    let flux_weight = reference.flux.max(1.0).sqrt();
    let snr_weight = reference.snr.max(1.0);
    let weight = flux_weight * snr_weight;
    if weight.is_finite() && weight > 0.0 {
        weight
    } else {
        1.0
    }
}

/// Signed per-axis correction demand (milliseconds) that was computed but not
/// issued because it was shorter than `min_pulse_ms`, carried into the next
/// frame.
///
/// Why this exists: `min_pulse_ms` (75 ms by default) is a property of the
/// MOUNT — the shortest pulse it will honour — while `min_move_px` (0.15 px) is
/// the guider's declared noise floor. Discarding every sub-minimum pulse turned
/// the mount limit into the real dead band, and it is much larger: with a
/// typical calibration of ~1.5 px per 250 ms pulse and 0.7 aggressiveness, a
/// 75 ms floor means any error under ~0.6 px was never corrected at all. Under
/// a one-directional drift (periodic error, imperfect polar alignment, or the
/// simulator's constant 0.05 px/s) a proportional loop with that dead band
/// parks at a standing offset: the guide graph sawtooths entirely on one side of
/// zero and the bullseye scatter never leaves one quadrant, so the user cannot
/// read drift direction, backlash or oscillation from either display.
///
/// Carrying the demand instead of dropping it keeps every ISSUED pulse at or
/// above the mount's minimum while letting sustained sub-minimum error
/// accumulate until one honourable pulse cancels it. Symmetric noise cancels
/// itself because the debt is signed, and anything below `min_move_px` clears
/// the debt outright, so noise still cannot accumulate into a pulse.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub(crate) struct PulseDebt {
    pub(crate) ra_ms: f64,
    pub(crate) dec_ms: f64,
}

/// A single computed pulse command for one axis: signed milliseconds (sign =
/// direction) after aggressiveness, min-move, max-clamp, and (for Dec) backlash
/// compensation. `None` means "no pulse" (below min-move, or still short of the
/// mount's minimum pulse — in which case the demand is carried in [`Self::debt`]).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub(crate) struct AxisPulse {
    pub(crate) ra_ms: Option<f64>,
    pub(crate) dec_ms: Option<f64>,
    /// The Dec direction this correction commands, if any — recorded so the next
    /// correction can detect a reversal and avoid re-paying backlash.
    pub(crate) new_dec_direction: Option<DecDirection>,
    /// Demand to carry into the next frame (zero on an axis that just pulsed or
    /// that is quieter than the noise floor).
    pub(crate) debt: PulseDebt,
}

/// Pure correction math: convert a measured guide `offset` (pixels) into signed
/// per-axis pulse durations using the calibration model.
///
/// Steps: invert the 2×2 calibration to get RA/Dec pulse-ms that would null the
/// offset; apply per-axis aggressiveness; drop the axis when the corresponding
/// offset component is below `min_move_px` (noise floor); clamp magnitude to
/// `[min_pulse_ms, max_pulse_ms]` (dropping sub-min pulses); and, on a Dec
/// direction reversal versus `last_dec_direction`, add the calibrated backlash
/// dead-band to the Dec pulse so the first reverse pulse actually moves the
/// scope.
///
/// Extracted as a pure function so aggressiveness, clamps, and backlash
/// compensation are unit-testable without a mount.
pub(crate) fn compute_pulse_durations(
    calibration: GuideCalibration,
    offset: Vec2,
    config: &GuiderConfig,
    last_dec_direction: Option<DecDirection>,
    debt: PulseDebt,
) -> AxisPulse {
    let determinant =
        calibration.east.x * calibration.north.y - calibration.east.y * calibration.north.x;
    if determinant.abs() < 1e-6 {
        return AxisPulse::default();
    }

    // Solve for the pulse scales (in units of one calibration pulse) that move
    // the scope by `-offset`, then convert to milliseconds.
    let target = Vec2 {
        x: -offset.x,
        y: -offset.y,
    };
    let east_scale =
        (target.x * calibration.north.y - target.y * calibration.north.x) / determinant;
    let north_scale = (calibration.east.x * target.y - calibration.east.y * target.x) / determinant;

    let ra_ms_raw = east_scale * calibration.pulse_ms * config.ra_aggressiveness;
    let dec_ms_raw = north_scale * calibration.pulse_ms * config.dec_aggressiveness;

    // Project the measured offset onto each calibration axis so the min-move
    // threshold is evaluated in the axis frame (matches how the correction is
    // applied), not the raw pixel x/y.
    let ra_axis_move = project_offset(offset, calibration.east);
    let dec_axis_move = project_offset(offset, calibration.north);

    // --- Dec backlash compensation on direction reversal.
    //
    // The backlash term is a one-shot addition that only makes sense on a pulse
    // that is actually issued, so it is passed as a `bonus` rather than folded
    // into the carried demand: folding it in would re-add it on every frame the
    // pulse stayed below the mount minimum (the reversal is only recorded once a
    // pulse fires) and the debt would run away.
    let dec_demand = dec_ms_raw + debt.dec_ms;
    let new_dec_direction = if dec_demand >= 0.0 {
        DecDirection::North
    } else {
        DecDirection::South
    };
    let reversing = last_dec_direction
        .map(|prev| prev != new_dec_direction)
        .unwrap_or(true); // first-ever Dec pulse pays backlash once
    let dec_backlash_bonus =
        if reversing && calibration.dec_backlash_ms > 0.0 && dec_demand.abs() >= 1e-9 {
            let sign = if dec_demand >= 0.0 { 1.0 } else { -1.0 };
            sign * calibration.dec_backlash_ms
        } else {
            0.0
        };

    let (ra_ms, ra_debt) = resolve_axis_pulse(ra_ms_raw, ra_axis_move, debt.ra_ms, 0.0, config);
    let (dec_ms, dec_debt) = resolve_axis_pulse(
        dec_ms_raw,
        dec_axis_move,
        debt.dec_ms,
        dec_backlash_bonus,
        config,
    );

    AxisPulse {
        ra_ms,
        dec_ms,
        new_dec_direction: dec_ms.map(|_| new_dec_direction),
        debt: PulseDebt {
            ra_ms: ra_debt,
            dec_ms: dec_debt,
        },
    }
}

/// Signed projection of a pixel offset onto a calibration axis vector, giving the
/// offset component along that axis in pixels.
pub(crate) fn project_offset(offset: Vec2, axis: Vec2) -> f64 {
    let mag = axis.magnitude();
    if mag < 1e-9 {
        return 0.0;
    }
    (offset.x * axis.x + offset.y * axis.y) / mag
}

/// Resolve one axis: apply min-move (pixels along the axis), fold in any carried
/// [`PulseDebt`], apply the min/max pulse clamps, and report what remains owed.
///
/// Returns `(pulse_to_issue, debt_to_carry)`:
///   * axis quieter than `min_move_px` -> `(None, 0.0)`; the error is inside the
///     declared noise floor, so nothing is owed and any carried demand is
///     forgotten (this is what stops noise accumulating into a pulse).
///   * demand shorter than the mount's `min_pulse_ms` -> `(None, demand)`; the
///     correction is carried instead of discarded, so a sustained error is not
///     permanently ignored just because each frame's share is small.
///   * otherwise -> `(Some(signed clamped pulse), 0.0)`.
///
/// `bonus_ms` is added only when deciding/issuing the pulse (Dec backlash) and is
/// never carried in the debt.
pub(crate) fn resolve_axis_pulse(
    pulse_ms: f64,
    axis_move_px: f64,
    debt_ms: f64,
    bonus_ms: f64,
    config: &GuiderConfig,
) -> (Option<f64>, f64) {
    if axis_move_px.abs() < config.min_move_px {
        return (None, 0.0);
    }
    let demand = pulse_ms + debt_ms;
    let issue = demand + bonus_ms;
    if issue.abs() < config.min_pulse_ms {
        // Bound the carry so a pathological config (min_pulse above max_pulse,
        // an axis that can never fire) cannot integrate without limit.
        return (
            None,
            demand.clamp(-config.max_pulse_ms, config.max_pulse_ms),
        );
    }
    let clamped = issue.abs().clamp(config.min_pulse_ms, config.max_pulse_ms);
    (Some(if issue >= 0.0 { clamped } else { -clamped }), 0.0)
}

pub(crate) async fn apply_guide_correction(
    calibration: GuideCalibration,
    offset: Vec2,
    controller: &Arc<RwLock<BuiltinGuiderState>>,
) -> Result<(), SkotiqError> {
    let (config, last_dec, debt) = {
        let guard = controller.read().await;
        (
            guard.config.clone(),
            guard.last_dec_direction,
            guard.pulse_debt,
        )
    };

    let plan = compute_pulse_durations(calibration, offset, &config, last_dec, debt);

    // Record the carried demand before issuing pulses: a mount error mid-plan
    // must not leave the debt describing a correction that was never attempted.
    if plan.debt != debt {
        controller.write().await.pulse_debt = plan.debt;
    }

    if let Some(ra_ms) = plan.ra_ms {
        pulse_axis("east", "west", ra_ms, &config).await?;
    }
    if let Some(dec_ms) = plan.dec_ms {
        pulse_axis("north", "south", dec_ms, &config).await?;
    }
    if let Some(dir) = plan.new_dec_direction {
        controller.write().await.last_dec_direction = Some(dir);
    }
    Ok(())
}

/// Issue a single mount pulse for an already-computed signed duration. The
/// duration has already passed min-move/min-pulse gating in
/// [`compute_pulse_durations`]; this only resolves direction and rounds to ms.
pub(crate) async fn pulse_axis(
    positive_direction: &str,
    negative_direction: &str,
    pulse_ms: f64,
    config: &GuiderConfig,
) -> Result<(), SkotiqError> {
    let magnitude = pulse_ms.abs();
    let (_, mount_id) = resolve_devices().await?;
    let duration = magnitude
        .clamp(config.min_pulse_ms, config.max_pulse_ms)
        .round() as u32;
    let direction = if pulse_ms >= 0.0 {
        positive_direction
    } else {
        negative_direction
    };
    get_device_manager()
        .mount_pulse_guide(&mount_id, direction.to_string(), duration)
        .await
        .map_err(SkotiqError::from)
}

pub(crate) async fn apply_settle_state(
    controller: Arc<RwLock<BuiltinGuiderState>>,
    rms_total: f64,
) -> Result<(), SkotiqError> {
    let mut guard = controller.write().await;
    // The spec belongs to the episode, not to the loop: a dither installs its
    // own settle tolerance, and judging its settle by the tolerance captured at
    // `start_guiding` reported "settled" at a threshold the caller never asked
    // for.
    let SettleSpec {
        pixels: settle_pixels,
        time: settle_time,
        timeout: settle_timeout,
    } = guard.settle_spec;

    // Settling is an episode someone asked for — the first settle after
    // calibration, or a dither's. Guiding that has already settled is guiding,
    // so there is nothing here to advance and nothing to announce. Without this
    // gate the loop re-armed on the first in-tolerance frame after every
    // completed settle and published `Settling` again within a frame of each
    // `Settled`, so the guider read `Settling` forever; the re-armed timeout
    // could also fail the loop task over a session that was guiding perfectly.
    if !guard.settling {
        return Ok(());
    }

    // Check if the overall settle timeout has been exceeded
    if let Some(timeout_deadline) = guard.settle_timeout_deadline {
        if Instant::now() >= timeout_deadline {
            guard.settle_deadline = None;
            guard.settle_timeout_deadline = None;
            guard.settling = false;
            // A dither that will not settle is a failed dither, not a failed
            // guiding session: roll it back and keep guiding. Returning `Err`
            // here fails the loop task, which stops guiding and reports the
            // guider disconnected.
            if guard.dither_pending {
                abandon_dither(&mut guard);
                drop(guard);
                tracing::warn!(
                    "Built-in guider abandoned a dither: settle timeout exceeded ({:.0}s) with \
                     RMS {:.2}px above threshold {:.2}px; rolled back and continuing to guide",
                    settle_timeout,
                    rms_total,
                    settle_pixels,
                );
                return Ok(());
            }
            return Err(SkotiqError::OperationFailed(format!(
                "Settle timeout exceeded ({:.0}s) during guide settle; guiding RMS {:.2}px still above threshold {:.2}px",
                settle_timeout, rms_total, settle_pixels,
            )));
        }
    }

    if rms_total <= settle_pixels {
        match guard.settle_deadline {
            Some(deadline) if Instant::now() >= deadline => {
                guard.settle_deadline = None;
                guard.settle_timeout_deadline = None;
                guard.settling = false;
                if guard.dither_pending {
                    guard.dither_pending = false;
                    get_state()
                        .publish_guiding_event(GuidingEvent::DitherCompleted, EventSeverity::Info);
                }
                get_state().publish_guiding_event(
                    GuidingEvent::Settled { rms: rms_total },
                    EventSeverity::Info,
                );
            }
            None => {
                guard.settle_deadline =
                    Some(Instant::now() + Duration::from_secs_f64(settle_time.max(0.1)));
                // If no timeout deadline is set yet, arm one now
                if guard.settle_timeout_deadline.is_none() {
                    let timeout_secs = settle_timeout.max(settle_time + 1.0);
                    guard.settle_timeout_deadline =
                        Some(Instant::now() + Duration::from_secs_f64(timeout_secs));
                }
                get_state().publish_guiding_event(GuidingEvent::Settling, EventSeverity::Info);
            }
            _ => {}
        }
    } else {
        // RMS exceeded threshold, reset the settle timer (but keep the timeout deadline)
        guard.settle_deadline = None;
    }

    Ok(())
}

/// Decide whether a detected star is usable as a guide reference. Rejects
/// saturated cores (clipped centroid), too-faint stars (noisy displacement),
/// elongated/blended detections (centroid walks with seeing, not the mount), and
/// stars too close to the frame edge (partial PSF + first to leave under field
/// rotation). `width`/`height` are the guide-frame dimensions in pixels; when
/// both are 0 the edge check is skipped (e.g. unit tests that work in star-space).
pub(crate) fn is_usable_reference(star: &DetectedStar, width: u32, height: u32) -> bool {
    if star.snr < GUIDE_MIN_REFERENCE_SNR {
        return false;
    }
    if star.peak >= GUIDE_SATURATION_PEAK_ADU {
        return false;
    }
    if star.eccentricity > GUIDE_MAX_REFERENCE_ECCENTRICITY {
        return false;
    }
    if !star.x.is_finite() || !star.y.is_finite() {
        return false;
    }
    if width > 0 && height > 0 {
        let w = width as f64;
        let h = height as f64;
        if star.x < GUIDE_EDGE_MARGIN_PX
            || star.y < GUIDE_EDGE_MARGIN_PX
            || star.x > w - GUIDE_EDGE_MARGIN_PX
            || star.y > h - GUIDE_EDGE_MARGIN_PX
        {
            return false;
        }
    }
    true
}

/// Select up to [`GUIDE_MAX_TRACKED_STARS`] guide references from a detected-star
/// list. Input is assumed brightest-first (callers sort by flux). Stars are
/// filtered by [`is_usable_reference`] and spaced at least
/// [`GUIDE_MIN_STAR_SEPARATION_PX`] apart so two detections of a blended pair are
/// not both tracked. `width`/`height` are the frame dimensions for edge rejection.
pub(crate) fn select_reference_stars(
    stars: &[DetectedStar],
    width: u32,
    height: u32,
) -> Vec<GuideReferenceStar> {
    let mut selected = Vec::new();
    for star in stars {
        if selected.len() >= GUIDE_MAX_TRACKED_STARS {
            break;
        }
        if !is_usable_reference(star, width, height) {
            continue;
        }
        let is_far_enough = selected.iter().all(|existing: &GuideReferenceStar| {
            let dx = existing.x - star.x;
            let dy = existing.y - star.y;
            (dx * dx + dy * dy).sqrt() >= GUIDE_MIN_STAR_SEPARATION_PX
        });
        if is_far_enough {
            selected.push(GuideReferenceStar {
                x: star.x,
                y: star.y,
                flux: star.flux,
                snr: star.snr,
                last_residual: None,
            });
        }
    }
    selected
}

pub(crate) fn choose_lock_star<'a>(
    stars: &'a [DetectedStar],
    preferred: Option<Vec2>,
    fallback: Option<Vec2>,
) -> Option<&'a DetectedStar> {
    let target = preferred.or(fallback);
    match target {
        Some(target_pos) => nearest_star(stars, target_pos, GUIDE_MAX_MATCH_DISTANCE_PX * 2.0)
            .or_else(|| stars.first()),
        None => stars.first(),
    }
}

pub(crate) fn nearest_star(
    stars: &[DetectedStar],
    target: Vec2,
    max_distance: f64,
) -> Option<&DetectedStar> {
    stars
        .iter()
        .filter_map(|star| {
            let dx = star.x - target.x;
            let dy = star.y - target.y;
            let distance = (dx * dx + dy * dy).sqrt();
            if distance <= max_distance {
                Some((distance, star))
            } else {
                None
            }
        })
        .min_by(|(left_distance, _), (right_distance, _)| {
            left_distance
                .partial_cmp(right_distance)
                .unwrap_or(std::cmp::Ordering::Equal)
        })
        .map(|(_, star)| star)
}

pub(crate) fn update_snapshot_from_frame(
    state: &mut BuiltinGuiderState,
    frame: &GuideFrame,
    crop_size: u32,
) {
    let selected = choose_lock_star(
        &frame.stars,
        state.manual_lock,
        frame.stars.first().map(|star| Vec2 {
            x: star.x,
            y: star.y,
        }),
    );

    if let Some(star) = selected {
        let snapshot = crop_raw_u16_image(&frame.image, star, crop_size);
        state.last_snapshot = Some(GuideSnapshot {
            frame: frame.frame,
            width: snapshot.width,
            height: snapshot.height,
            pixels: snapshot.pixels,
            crop_origin_x: snapshot.crop_origin_x,
            crop_origin_y: snapshot.crop_origin_y,
            star_x: snapshot.star_x,
            star_y: snapshot.star_y,
        });
    }
}

pub(crate) struct RawCrop {
    pub(crate) width: u32,
    pub(crate) height: u32,
    pub(crate) pixels: Vec<u8>,
    pub(crate) crop_origin_x: i32,
    pub(crate) crop_origin_y: i32,
    pub(crate) star_x: f64,
    pub(crate) star_y: f64,
}

pub(crate) fn crop_raw_u16_image(
    image: &ImageData,
    star: &DetectedStar,
    crop_size: u32,
) -> RawCrop {
    let width = image.width as i32;
    let height = image.height as i32;
    let half = crop_size as i32 / 2;
    let center_x = star.x.round() as i32;
    let center_y = star.y.round() as i32;
    let x_start = (center_x - half).clamp(0, width.saturating_sub(1));
    let y_start = (center_y - half).clamp(0, height.saturating_sub(1));
    let x_end = (center_x + half).clamp(1, width);
    let y_end = (center_y + half).clamp(1, height);
    let crop_width = (x_end - x_start) as u32;
    let crop_height = (y_end - y_start) as u32;

    // Validate that the raw data buffer has even length (required for U16 pixel pairs)
    // and is large enough for the image dimensions claimed.
    let expected_data_len = (image.width as usize) * (image.height as usize) * 2;
    if image.data.len() < expected_data_len || image.data.len() % 2 != 0 {
        tracing::warn!(
            "crop_raw_u16_image: image data length {} does not match expected {} ({}x{} U16), \
             returning empty crop",
            image.data.len(),
            expected_data_len,
            image.width,
            image.height,
        );
        return RawCrop {
            width: 0,
            height: 0,
            pixels: Vec::new(),
            crop_origin_x: x_start,
            crop_origin_y: y_start,
            star_x: star.x - x_start as f64,
            star_y: star.y - y_start as f64,
        };
    }

    let mut pixels = Vec::with_capacity((crop_width * crop_height * 2) as usize);

    for y in y_start..y_end {
        for x in x_start..x_end {
            let index = ((y as u32 * image.width + x as u32) * 2) as usize;
            // Safe: we validated data length covers width*height*2 above,
            // and x/y are clamped within [0, width) / [0, height).
            pixels.push(image.data[index]);
            pixels.push(image.data[index + 1]);
        }
    }

    RawCrop {
        width: crop_width,
        height: crop_height,
        pixels,
        crop_origin_x: x_start,
        crop_origin_y: y_start,
        star_x: star.x - x_start as f64,
        star_y: star.y - y_start as f64,
    }
}
