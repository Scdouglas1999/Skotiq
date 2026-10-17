use super::*;

// Mount motion for polar alignment: the slew-to-pole preamble
// (start_from_current = false) and the RA-only rotation between the three
// measurement points. Both wait for the mount to actually settle and both
// honour cancel/supersede by aborting the mount before returning.

/// Max wall-clock for the pole-region slew to settle before we abort + fail.
pub(crate) const POLE_SLEW_TIMEOUT_SECS: u64 = 120;
/// Fallback settle wait when the driver cannot report `slewing`.
pub(crate) const POLE_SLEW_SETTLE_SECS: u64 = 8;
/// How far from the true pole the pole-region target sits, in degrees. 30° puts
/// the scope at the outer edge of the classic TPPA region (≈30° around the
/// pole) while keeping the 3-point rotation-arc geometry well conditioned
/// (cos 60° = 0.5 of the RA step projects onto the sky, versus a near-degenerate
/// projection right at the pole).
pub(crate) const POLE_REGION_OFFSET_DEG: f64 = 30.0;

/// Outcome of a polar-alignment mount move (pole preamble or rotation step).
pub(crate) enum SlewOutcome {
    /// The mount reached and settled on the target.
    Settled,
    /// The user cancelled during the slew (the mount was aborted).
    Cancelled,
    /// A newer run took over during the slew (the mount was aborted).
    Superseded,
}

/// Compute the "slew to pole region" target `(ra_hours, dec_degrees)`.
///
/// The target sits on the local meridian (RA == LST, i.e. hour angle 0) so it
/// culminates — highest above the horizon, least atmosphere, best for plate
/// solving — and [`POLE_REGION_OFFSET_DEG`] from the celestial pole toward the
/// equator so the subsequent three-point RA arc keeps good geometry. Northern
/// observers point at +Dec, southern at −Dec.
///
/// Pure and deterministic given `(lst_hours, is_north)` so it can be unit
/// tested without hardware.
pub(crate) fn pole_region_target(lst_hours: f64, is_north: bool) -> (f64, f64) {
    let ra_hours = lst_hours.rem_euclid(24.0);
    let dec_degrees = if is_north {
        90.0 - POLE_REGION_OFFSET_DEG
    } else {
        -90.0 + POLE_REGION_OFFSET_DEG
    };
    (ra_hours, dec_degrees)
}

/// Slew the mount to the pole region and wait — with abort ordering — until the
/// motion actually settles.
///
/// Ordering guarantees (adversarially important): a cancellation or supersession
/// observed *while slewing* issues `mount_abort_slew` BEFORE returning, so the
/// mount is commanded to stop before the caller settles/idles. A driver that
/// cannot report `slewing` falls back to a bounded fixed settle rather than
/// spinning. A hard timeout also aborts and fails truthfully — it never reports
/// the slew as done early.
pub(crate) async fn slew_to_pole_region(
    mount_id: &str,
    is_north: bool,
    longitude_deg: f64,
    generation: u64,
) -> Result<SlewOutcome, String> {
    use skotiq_sequencer::meridian::{julian_day, local_sidereal_time};

    let now = chrono::Utc::now();
    let jd = julian_day(&now);
    let lst = local_sidereal_time(jd, longitude_deg);
    let (target_ra_h, target_dec) = pole_region_target(lst, is_north);

    emit_polar_status(
        &format!(
            "Slewing to pole region (RA {:.2}h, Dec {:.0}°)...",
            target_ra_h, target_dec
        ),
        "measuring",
        0,
    );

    let device_ops = create_unified_device_ops();

    // Honour a cancel/supersede that arrives before the slew is even issued.
    match polar_loop_control(generation) {
        PolarLoopControl::Continue => {}
        PolarLoopControl::Superseded => return Ok(SlewOutcome::Superseded),
        PolarLoopControl::Cancelled => return Ok(SlewOutcome::Cancelled),
    }

    device_ops
        .mount_slew_to_coordinates(mount_id, target_ra_h, target_dec)
        .await
        .map_err(|e| format!("Failed to slew to pole region: {}", e))?;

    wait_for_slew_settle(&*device_ops, mount_id, generation, "reach the pole region").await
}

/// Wait — with abort ordering — until a commanded slew actually settles.
///
/// Ordering guarantees (adversarially important): a cancellation or supersession
/// observed *while slewing* issues `mount_abort_slew` BEFORE returning, so the
/// mount is commanded to stop before the caller settles/idles. A driver that
/// cannot report `slewing` falls back to a bounded fixed settle rather than
/// spinning. A hard timeout also aborts and fails truthfully — it never reports
/// the slew as done early. `what` names the move for the error text
/// ("reach the pole region", "rotate to point 2").
pub(crate) async fn wait_for_slew_settle(
    device_ops: &dyn skotiq_sequencer::DeviceOps,
    mount_id: &str,
    generation: u64,
    what: &str,
) -> Result<SlewOutcome, String> {
    // `mount_slew_to_coordinates` may return before the mount physically stops
    // (async drivers), so poll `slewing`.
    let deadline = Instant::now() + Duration::from_secs(POLE_SLEW_TIMEOUT_SECS);
    loop {
        match polar_loop_control(generation) {
            PolarLoopControl::Continue => {}
            PolarLoopControl::Superseded => {
                if let Err(e) = device_ops.mount_abort_slew(mount_id).await {
                    emit_polar_stop_refused("A newer run took over", "measuring", &e);
                }
                return Ok(SlewOutcome::Superseded);
            }
            PolarLoopControl::Cancelled => {
                if let Err(e) = device_ops.mount_abort_slew(mount_id).await {
                    emit_polar_stop_refused("Cancelled", "measuring", &e);
                }
                return Ok(SlewOutcome::Cancelled);
            }
        }

        match device_ops.mount_is_slewing(mount_id).await {
            Ok(false) => break, // settled
            Ok(true) => {}      // keep waiting
            Err(e) => {
                // Driver can't report slew state — do a bounded fixed settle
                // rather than busy-looping forever, then proceed.
                tracing::warn!(
                    "mount_is_slewing failed ({}); using {}s fixed settle",
                    e,
                    POLE_SLEW_SETTLE_SECS
                );
                tokio::time::sleep(Duration::from_secs(POLE_SLEW_SETTLE_SECS)).await;
                break;
            }
        }

        if Instant::now() >= deadline {
            // The abort is the only thing standing between a timed-out slew and
            // a mount that keeps driving, so its failure belongs in the error
            // the caller shows — not discarded behind the timeout message.
            let abort = device_ops.mount_abort_slew(mount_id).await;
            return Err(match abort {
                Ok(()) => format!(
                    "Timed out after {}s waiting for the mount to {}",
                    POLE_SLEW_TIMEOUT_SECS, what
                ),
                Err(e) => format!(
                    "Timed out after {}s waiting for the mount to {}, and \
                     the mount did not accept the stop command ({}) — it may still be slewing",
                    POLE_SLEW_TIMEOUT_SECS, what, e
                ),
            });
        }

        tokio::time::sleep(Duration::from_millis(500)).await;
    }

    // Short mechanical settle after motion stops before the next exposure.
    tokio::time::sleep(Duration::from_secs(1)).await;
    Ok(SlewOutcome::Settled)
}

// ---------------------------------------------------------------------------
// RA-only rotation between measurement points
// ---------------------------------------------------------------------------

/// Where the next measurement point is, in the MOUNT's own coordinate frame.
///
/// Three-point polar alignment measures how the sky rotates about the mount's
/// RA axis, so between points the mount must turn about that one axis and
/// nothing else: same mount declination, mount RA offset by the step. The
/// frame matters. Before alignment the mount's idea of where it points and the
/// plate-solved truth differ by the very error being measured (plus whatever
/// pointing error the model carries), so a target built from the *solved*
/// coordinates makes the mount "correct" that difference on the way — a move
/// in both axes that is not a rotation about the polar axis at all. Tonight's
/// rig did exactly that: it swung toward the pole in Dec instead of stepping
/// 10° in RA. Building the target from the mount's own reported position keeps
/// the move a pure RA step regardless of how far off the polar axis is.
///
/// `rotate_east` increases RA (the field moves east). RA wraps into `[0, 24)`.
/// Pure so it can be unit tested without hardware.
pub(crate) fn rotation_step_target(
    mount_ra_hours: f64,
    mount_dec_degrees: f64,
    step_degrees: f64,
    rotate_east: bool,
) -> (f64, f64) {
    let step_hours = step_degrees / 15.0;
    let ra_hours = if rotate_east {
        mount_ra_hours + step_hours
    } else {
        mount_ra_hours - step_hours
    };
    (ra_hours.rem_euclid(24.0), mount_dec_degrees)
}

/// Fold an hour angle into `[-12, 12)` hours (negative = east of the meridian).
pub(crate) fn normalize_hour_angle(ha_hours: f64) -> f64 {
    (ha_hours + 12.0).rem_euclid(24.0) - 12.0
}

/// Would stepping from `ha_before` to `ha_after` (hours) carry the mount across
/// the meridian or the anti-meridian? Either crossing is where a German
/// equatorial performs a pier flip — a large move in both axes that ruins the
/// single-axis geometry the alignment depends on and is exactly the kind of
/// unexpected motion an operator standing at the mount does not want. The
/// step is assumed shorter than 12 h (real steps are a fraction of an hour).
pub(crate) fn step_crosses_meridian(ha_before_hours: f64, ha_after_hours: f64) -> bool {
    let before = normalize_hour_angle(ha_before_hours);
    let after = normalize_hour_angle(ha_after_hours);
    if (before - after).abs() > 12.0 {
        // Folding wrapped the value: the short path went through ±12 h.
        return true;
    }
    (before < 0.0) != (after < 0.0) && before != after
}

/// Local sidereal time for the rotation guard: the mount's own report when the
/// driver offers one, otherwise computed from the clock and site longitude.
fn sidereal_hours_for_rotation(status: &MountStatus, observer_longitude_deg: f64) -> f64 {
    if let Some(lst) = status.sidereal_time {
        return lst.rem_euclid(24.0);
    }
    use skotiq_sequencer::meridian::{julian_day, local_sidereal_time};
    let jd = julian_day(&chrono::Utc::now());
    local_sidereal_time(jd, observer_longitude_deg).rem_euclid(24.0)
}

/// Rotate the mount about its polar axis by `step_degrees` for the next
/// measurement point and wait for it to settle.
///
/// The target is built in the mount's frame (see [`rotation_step_target`]),
/// refused when the step would cross the meridian, and the settle wait shares
/// the pole preamble's abort ordering: cancel or supersede while moving stops
/// the mount before this returns.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn rotate_for_next_point(
    mount_id: &str,
    next_point: i32,
    step_degrees: f64,
    rotate_east: bool,
    observer_longitude_deg: f64,
    generation: u64,
    hold_dec_degrees: Option<f64>,
) -> Result<SlewOutcome, String> {
    let status = get_device_manager()
        .mount_get_status(mount_id)
        .await
        .map_err(|e| format!("Could not read the mount's position before rotating: {}", e))?;
    // `hold_dec_degrees` is the declination measured before the FIRST point,
    // held for the whole run so the three points share one small circle. See
    // the comment where the run reads it.
    let (target_ra_hours, target_dec) = rotation_step_target(
        status.right_ascension,
        hold_dec_degrees.unwrap_or(status.declination),
        step_degrees,
        rotate_east,
    );

    let lst = sidereal_hours_for_rotation(&status, observer_longitude_deg);
    let ha_before = normalize_hour_angle(lst - status.right_ascension);
    let ha_after = normalize_hour_angle(lst - target_ra_hours);
    if step_crosses_meridian(ha_before, ha_after) {
        return Err(format!(
            "Rotating {} by {:.0}° from hour angle {:+.2}h would carry the mount across the \
             meridian, where a German equatorial flips and moves both axes. Choose the other \
             rotation direction or a smaller step.",
            if rotate_east { "east" } else { "west" },
            step_degrees,
            ha_before
        ));
    }

    tracing::info!(
        "Polar alignment point {}: rotating {} {:.1}° in RA in the mount's frame \
         (mount RA {:.4}h -> {:.4}h, Dec {:.4}° held from the first point, mount now \
         reads Dec {:.4}°, HA {:+.2}h -> {:+.2}h)",
        next_point,
        if rotate_east { "east" } else { "west" },
        step_degrees,
        status.right_ascension,
        target_ra_hours,
        target_dec,
        status.declination,
        ha_before,
        ha_after
    );

    let device_ops = create_unified_device_ops();

    match polar_loop_control(generation) {
        PolarLoopControl::Continue => {}
        PolarLoopControl::Superseded => return Ok(SlewOutcome::Superseded),
        PolarLoopControl::Cancelled => return Ok(SlewOutcome::Cancelled),
    }

    device_ops
        .mount_slew_to_coordinates(mount_id, target_ra_hours, target_dec)
        .await
        .map_err(|e| format!("Failed to rotate to point {}: {}", next_point, e))?;

    wait_for_slew_settle(
        &*device_ops,
        mount_id,
        generation,
        &format!("rotate to point {}", next_point),
    )
    .await
}
