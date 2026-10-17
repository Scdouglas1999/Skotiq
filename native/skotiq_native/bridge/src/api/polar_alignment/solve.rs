use super::*;

// How a polar-alignment frame is plate solved.
//
// Every frame in this feature is taken within ~30° of the celestial pole with
// the mount pointing where the mount says it points. That is a position hint,
// and it is the difference between an ASTAP run that searches one cone of sky
// and one that searches all of it: on the owner's rig a hinted capture solves
// in ~5 s while the same field solved blind took 26.5 s on a good night and
// blew through a 30 s budget on a bad one. The pointing model is unaligned
// during polar alignment — that is the whole point of running it — so the hint
// carries a deliberately generous search radius instead of the 5° a
// centring solve uses, and a hinted attempt that fails still falls back to the
// blind solve that used to be the only path.

/// Search radius for a polar-alignment hinted solve, in degrees.
///
/// The measurement points sit [`POLE_REGION_OFFSET_DEG`] from the pole, so a
/// radius of the same size covers the entire pole region the run can be
/// pointing at even if the mount's idea of its own position is wrong by the
/// full width of that region. A polar-aligned-by-eyeball mount is typically
/// off by a degree or two; this absorbs an unsynced one.
pub(crate) const POLAR_SOLVE_SEARCH_RADIUS_DEG: f64 = POLE_REGION_OFFSET_DEG;

/// Largest `-r` ASTAP accepts: half the sky, measured from the hint, is every
/// direction there is. Anything beyond it is a blind solve wearing a hint.
pub(crate) const ASTAP_MAX_SEARCH_RADIUS_DEG: f64 = 180.0;

/// Per-frame solve budget when the caller does not specify one.
///
/// 30 s was the old default and it failed on the owner's laptop against a
/// full-resolution blind solve. 90 s covers the hinted rungs, the blind one
/// behind them, and the margin ASTAP needs to report its own timeout.
pub(crate) const DEFAULT_POLAR_SOLVE_TIMEOUT_SECS: f64 = 90.0;

/// Frames wider than this on their long side are downsampled for the solve.
///
/// ASTAP needs stars, not pixels. A 4656 x 3520 frame carries several times
/// the stars a solve uses, and halving each axis quarters the pixels ASTAP has
/// to search through.
const POLAR_DOWNSAMPLE_LONG_SIDE_PX: u32 = 3000;

/// The ASTAP `-z` factor meaning "read the frame as it is".
const NO_DOWNSAMPLE: u32 = 1;

/// The mount's own idea of where it is pointing, ready to hand to a solver.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct PolarSolveHint {
    /// Degrees, `[0, 360)` — the unit `plate_solve_near_scaled` takes.
    pub(crate) ra_degrees: f64,
    /// Degrees, `[-90, 90]`.
    pub(crate) dec_degrees: f64,
    /// Degrees.
    pub(crate) search_radius_deg: f64,
}

/// Build a solve hint from a mount status report.
///
/// `ra_hours` is the unit [`MountStatus::right_ascension`] is in; the solver
/// wants degrees. Returns `None` for a report that cannot be a position — a
/// NaN from a driver that failed to read the axis, or a declination outside
/// the sphere — because a confidently wrong hint costs more than no hint: it
/// sends ASTAP to search a cone the field is not in, and only then falls back.
pub(crate) fn polar_solve_hint_from_mount(
    ra_hours: f64,
    dec_degrees: f64,
) -> Option<PolarSolveHint> {
    if !ra_hours.is_finite() || !dec_degrees.is_finite() {
        return None;
    }
    if !(-90.0..=90.0).contains(&dec_degrees) {
        return None;
    }
    Some(PolarSolveHint {
        ra_degrees: (ra_hours.rem_euclid(24.0)) * 15.0,
        dec_degrees,
        search_radius_deg: POLAR_SOLVE_SEARCH_RADIUS_DEG.clamp(0.0, ASTAP_MAX_SEARCH_RADIUS_DEG),
    })
}

/// Read the mount's position for a solve hint, or `None` when it cannot say.
///
/// A driver that cannot report a position is not an error for the run: polar
/// alignment solved blind before this existed and still does whenever the
/// answer is `None`.
pub(crate) async fn read_polar_solve_hint(mount_id: &str) -> Option<PolarSolveHint> {
    match get_device_manager().mount_get_status(mount_id).await {
        Ok(status) => {
            let hint = polar_solve_hint_from_mount(status.right_ascension, status.declination);
            if hint.is_none() {
                tracing::warn!(
                    "Polar alignment: mount reported an unusable position \
                     (RA {:?} h, Dec {:?}°); solving blind",
                    status.right_ascension,
                    status.declination
                );
            }
            hint
        }
        Err(e) => {
            tracing::warn!(
                "Polar alignment: could not read the mount position for a solve hint ({}); \
                 solving blind",
                e
            );
            None
        }
    }
}

/// The ASTAP `-z` downsample factor for a polar-alignment frame.
///
/// Binning and downsampling compound: a 4x4 frame halved again is a sixteenth
/// of the sensor in each axis, which throws away the faint stars the solve
/// depends on. So a frame that was already binned in hardware is solved as it
/// is, and only an unbinned oversized frame is downsampled.
///
/// This does not touch the scale hint. ASTAP's `-fov` is the angular height of
/// the field, and the field is the same field however many pixels ASTAP reads
/// it at — see `build_astap_args`, which derives `-fov` from the frame's own
/// NAXIS2 and never consults the downsample factor.
pub(crate) fn polar_solve_downsample(width_px: u32, height_px: u32, binning: i32) -> u32 {
    if binning >= 2 {
        return NO_DOWNSAMPLE;
    }
    if width_px.max(height_px) > POLAR_DOWNSAMPLE_LONG_SIDE_PX {
        2
    } else {
        NO_DOWNSAMPLE
    }
}

/// Plate solve one polar-alignment frame.
///
/// `what` names the frame for the operator ("point 1", "the adjustment
/// frame"); `scale_arcsec_px` is the measured plate scale of the frame as
/// taken. The escalation — the mount's position at
/// [`POLAR_SOLVE_SEARCH_RADIUS_DEG`], then blind — and the budget that keeps
/// both inside the operator's timeout live in [`crate::api::plate_solve`], so
/// every solve in the app escalates the same way. This decides only what the
/// hint IS.
pub(crate) async fn solve_polar_frame(
    what: &str,
    file_path: &str,
    hint: Option<PolarSolveHint>,
    scale_arcsec_px: Option<f64>,
    downsample: u32,
    timeout_secs: f64,
) -> Result<crate::api::plate_solve::PlateSolveResult, String> {
    let budget = crate::api::plate_solve::split_solve_budget(timeout_secs, hint.is_some());
    let timeout = Some(timeout_secs.ceil().clamp(1.0, 3600.0) as u32);

    let result = match hint {
        Some(hint) => {
            tracing::info!(
                "Polar alignment {}: solving from the mount at RA {:.4}°, Dec {:.4}° \
                 (search radius {:.0}°, -z {}, {:.0}s hinted then {:.0}s blind)",
                what,
                hint.ra_degrees,
                hint.dec_degrees,
                hint.search_radius_deg,
                downsample,
                budget.hinted_secs,
                budget.blind_secs
            );
            crate::api::plate_solve::plate_solve_near_scaled(
                file_path.to_string(),
                hint.ra_degrees,
                hint.dec_degrees,
                hint.search_radius_deg,
                timeout,
                scale_arcsec_px,
                Some(downsample),
            )
            .await
        }
        None => {
            tracing::info!(
                "Polar alignment {}: the mount cannot say where it is pointing; solving blind \
                 (-z {}, {:.0}s)",
                what,
                downsample,
                budget.blind_secs
            );
            crate::api::plate_solve::plate_solve_blind_scaled(
                file_path.to_string(),
                timeout,
                scale_arcsec_px,
                Some(downsample),
            )
            .await
        }
    };

    match result {
        Ok(result) if result.success => {
            tracing::info!(
                "Polar alignment {}: solved RA {:.4}°, Dec {:.4}° in {:.1}s",
                what,
                result.ra,
                result.dec,
                result.solve_time_secs
            );
            Ok(result)
        }
        // The ladder's message already names every rung it tried, which is the
        // whole point of it — do not flatten that back into "solve failed".
        Ok(result) => Err(format!(
            "Plate solve failed for {}: {}",
            what,
            result.error.as_deref().unwrap_or("no solution found")
        )),
        Err(e) => Err(format!("Plate solve failed for {}: {:?}", what, e)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_mount_report_becomes_a_degrees_hint() {
        let hint = polar_solve_hint_from_mount(2.0, 58.27).expect("a finite report is a hint");
        assert!(
            (hint.ra_degrees - 30.0).abs() < 1e-9,
            "hours must become degrees"
        );
        assert!((hint.dec_degrees - 58.27).abs() < 1e-9);
    }

    /// A mount that has wrapped past 24 h (or reports a negative hour angle as
    /// RA) still names a real place in the sky.
    #[test]
    fn a_wrapped_right_ascension_folds_into_the_circle() {
        let hint = polar_solve_hint_from_mount(25.0, 0.0).expect("hint");
        assert!((hint.ra_degrees - 15.0).abs() < 1e-9);
        let hint = polar_solve_hint_from_mount(-1.0, 0.0).expect("hint");
        assert!((hint.ra_degrees - 345.0).abs() < 1e-9);
    }

    /// The radius is generous because the pointing model is unaligned — that
    /// is what the run is measuring — but it is never sent past what ASTAP
    /// accepts.
    #[test]
    fn the_search_radius_covers_the_pole_region_and_is_clamped() {
        let hint = polar_solve_hint_from_mount(6.0, 60.0).expect("hint");
        assert!(
            hint.search_radius_deg >= POLE_REGION_OFFSET_DEG,
            "the points sit {}° from the pole; a smaller radius can miss them",
            POLE_REGION_OFFSET_DEG
        );
        assert!(hint.search_radius_deg <= ASTAP_MAX_SEARCH_RADIUS_DEG);
    }

    /// A driver that cannot read its axes hands back NaN or nonsense. Blind is
    /// the honest answer; a fabricated hint sends ASTAP to the wrong cone.
    #[test]
    fn an_unusable_mount_report_produces_no_hint() {
        assert!(polar_solve_hint_from_mount(f64::NAN, 45.0).is_none());
        assert!(polar_solve_hint_from_mount(3.0, f64::NAN).is_none());
        assert!(polar_solve_hint_from_mount(3.0, 91.0).is_none());
        assert!(polar_solve_hint_from_mount(3.0, -91.0).is_none());
    }

    /// Tonight's frame: 4656 x 3520 unbinned.
    #[test]
    fn a_large_unbinned_frame_is_downsampled() {
        assert_eq!(polar_solve_downsample(4656, 3520, 1), 2);
    }

    /// Binning already threw away three quarters of the pixels; doing it again
    /// costs stars the solve needs.
    #[test]
    fn an_already_binned_frame_is_never_downsampled_again() {
        assert_eq!(polar_solve_downsample(4656, 3520, 2), NO_DOWNSAMPLE);
        assert_eq!(polar_solve_downsample(2328, 1760, 2), NO_DOWNSAMPLE);
        assert_eq!(polar_solve_downsample(1164, 880, 4), NO_DOWNSAMPLE);
    }

    /// A small sensor has no pixels to spare.
    #[test]
    fn a_small_unbinned_frame_is_left_alone() {
        assert_eq!(polar_solve_downsample(3000, 2000, 1), NO_DOWNSAMPLE);
        assert_eq!(polar_solve_downsample(1936, 1096, 1), NO_DOWNSAMPLE);
    }
}
