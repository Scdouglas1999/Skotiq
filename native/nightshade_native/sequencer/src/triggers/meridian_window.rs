//! The meridian-flip window test — one implementation for every caller that
//! has to answer "does this target need a flip right now?".
//!
//! The question has exactly two inputs: the TARGET's signed hour angle and the
//! mount's reported pier side. It was previously answered by four hand-written
//! copies of the same `match` (the `MinutesPastMeridian` arm, the
//! `HourAngleThreshold` arm, `TriggerState::meridian_flip_status`, and the
//! exposure gate's "mirror the trigger's own logic exactly" comment), which is
//! how the sign convention drifts: any one of them can be edited east-of-
//! meridian-permissive on its own.

use crate::PierSide;

/// Whether the mount is still on the side of the pier that a flip would move
/// it OFF — i.e. whether a flip is meaningful at all right now.
///
/// `hour_angle_hours` is the hour angle of the TARGET, signed and normalized
/// to `[-12, +12]` by [`crate::meridian::hour_angle`]: NEGATIVE is east of the
/// meridian (the target has not transited yet), positive is west of it.
///
/// Two rules, in this order:
///
///  1. **An east target never flips.** A German equatorial approaching the
///     meridian from the east is already in the configuration it needs; a flip
///     there swings the tube through half a turn for nothing, and every
///     post-flip step (re-centre, refocus, guider settle) runs against a
///     target that will not transit for hours. This rule is unconditional and
///     is checked FIRST, so no pier-side reading can talk the decision into
///     firing east of transit. In particular it is never softened into an
///     `abs()` test, which would make the trigger quiet only near transit and
///     fire on everything far enough east.
///  2. **Pier East is the post-flip side.** A mount that already reports
///     `pierEast` has flipped (or started the night on that side) and must not
///     flip again; `has_flipped_this_target` covers the same ground for the
///     run that performed the flip, and this covers a resume that did not.
///
/// `Unknown` — the reading a simulator and many legacy mounts give — is NOT
/// treated as evidence of anything. It falls through to the signed hour-angle
/// rule alone, which is the honest reading: the flip design's decisive input
/// is where the target is, and pier side only ever SUPPRESSES a flip that the
/// hour angle would otherwise justify. Unknown therefore neither blocks a
/// genuine past-the-meridian flip nor manufactures one east of transit.
///
/// A non-finite hour angle (no location, degenerate coordinates) is treated as
/// "cannot evaluate" and never fires.
pub fn on_pre_flip_side(hour_angle_hours: f64, pier_side: Option<PierSide>) -> bool {
    if !hour_angle_hours.is_finite() || hour_angle_hours <= 0.0 {
        return false;
    }
    !matches!(pier_side, Some(PierSide::East))
}

/// Whether the configured flip window is open: the target is past the meridian
/// on the pre-flip side ([`on_pre_flip_side`]) AND has been past it by at
/// least `threshold_hours`.
///
/// The threshold is inclusive — a trigger configured for "5 minutes past the
/// meridian" fires AT five minutes, not one tick later.
pub fn flip_window_open(
    hour_angle_hours: f64,
    pier_side: Option<PierSide>,
    threshold_hours: f64,
) -> bool {
    on_pre_flip_side(hour_angle_hours, pier_side) && hour_angle_hours >= threshold_hours
}

/// Whether a flip the trigger requested is still due when its turn comes to
/// run.
///
/// A flip action waits for the imaging train like every camera-driving
/// action, and the mount can move while it waits. The case that forced this:
/// at a target change the trigger saw the NEW target's hour angle (west of the
/// meridian) against the pier side the mount still had on the OLD target, and
/// requested a flip; the next target's Center node then slewed there and
/// landed on the post-flip side, and the queued flip would have slewed again
/// and failed with "pier side did not change". Re-asked with the pier side
/// read after the wait, the question has the right answer.
///
/// Only the window-based methods are re-evaluated; the tracking-limit
/// methods answer from the mount's own limit state, which a wait does not
/// make stale in the same way.
pub fn flip_still_due(
    config: &crate::MeridianFlipConfig,
    hour_angle_hours: Option<f64>,
    pier_side: Option<PierSide>,
) -> bool {
    let threshold_hours = match config.trigger_method {
        crate::MeridianTriggerMethod::MinutesPastMeridian => config.minutes_past_meridian / 60.0,
        crate::MeridianTriggerMethod::HourAngleThreshold => config.hour_angle_threshold,
        _ => return true,
    };
    hour_angle_hours.is_some_and(|ha| flip_window_open(ha, pier_side, threshold_hours))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The target-change case: requested on the old pointing's pier side,
    /// run after the next target's slew put the mount on the post-flip side.
    #[test]
    fn a_flip_queued_before_the_target_slew_is_not_due_after_it() {
        let config = crate::MeridianFlipConfig::default();
        let west_target_ha = Some(3.0);
        assert!(flip_still_due(
            &config,
            west_target_ha,
            Some(PierSide::West)
        ));
        assert!(!flip_still_due(
            &config,
            west_target_ha,
            Some(PierSide::East)
        ));
        assert!(!flip_still_due(&config, None, Some(PierSide::West)));
        assert!(!flip_still_due(&config, Some(-0.5), Some(PierSide::West)));
    }

    const EVERY_PIER_SIDE: [Option<PierSide>; 4] = [
        None,
        Some(PierSide::Unknown),
        Some(PierSide::West),
        Some(PierSide::East),
    ];

    /// The live defect this module exists to close: a target 1.5h EAST of the
    /// meridian was flipped, with the pier side reported as `Unknown`. No pier
    /// side may make an east target fire, at any threshold — including the
    /// zero threshold, which is the most permissive configuration the UI
    /// offers.
    #[test]
    fn an_east_target_never_fires_on_any_pier_side() {
        for pier in EVERY_PIER_SIDE {
            for ha in [-1.5, -0.5, -0.001, -11.9] {
                assert!(
                    !on_pre_flip_side(ha, pier),
                    "HA {ha}h is east of the meridian; pier {pier:?} must not make it pre-flip"
                );
                for threshold_hours in [0.0, 5.0 / 60.0, 0.5] {
                    assert!(
                        !flip_window_open(ha, pier, threshold_hours),
                        "HA {ha}h east of the meridian fired at threshold {threshold_hours}h \
                         with pier {pier:?}"
                    );
                }
            }
        }
    }

    /// `abs()` is the shape the defect would take if it came back: quiet near
    /// transit, firing on anything far enough east. Pin the asymmetry.
    #[test]
    fn the_window_is_signed_not_symmetric() {
        let threshold = 5.0 / 60.0;
        assert!(flip_window_open(0.2, Some(PierSide::Unknown), threshold));
        assert!(!flip_window_open(-0.2, Some(PierSide::Unknown), threshold));
    }

    #[test]
    fn a_west_target_inside_the_window_fires_unless_already_flipped() {
        // 0.02h = 1.2 minutes past the meridian, against a 1-minute window.
        let threshold = 1.0 / 60.0;
        assert!(flip_window_open(0.02, None, threshold));
        assert!(flip_window_open(0.02, Some(PierSide::Unknown), threshold));
        assert!(flip_window_open(0.02, Some(PierSide::West), threshold));
        // pierEast is the side a flip LANDS on: already flipped, never again.
        assert!(!flip_window_open(0.02, Some(PierSide::East), threshold));
    }

    #[test]
    fn a_west_target_short_of_the_window_waits() {
        // 4.9 minutes past, 5-minute window.
        let threshold = 5.0 / 60.0;
        assert!(on_pre_flip_side(4.9 / 60.0, Some(PierSide::West)));
        assert!(!flip_window_open(
            4.9 / 60.0,
            Some(PierSide::West),
            threshold
        ));
    }

    /// The boundary is inclusive, and the same arithmetic on both sides so the
    /// documented "fires AT the threshold" is not a floating-point coin flip.
    #[test]
    fn the_threshold_boundary_is_inclusive() {
        let threshold = 5.0 / 60.0;
        assert!(flip_window_open(
            5.0 / 60.0,
            Some(PierSide::West),
            threshold
        ));
    }

    /// Zero hour angle is the meridian itself, not past it. The flip config's
    /// threshold is what decides how long after transit to wait, and a target
    /// exactly at transit has waited zero minutes — but the pre-flip-side test
    /// must still refuse it outright, because "at the meridian" is where an
    /// un-flipped mount is allowed to be.
    #[test]
    fn transit_itself_is_not_past_the_meridian() {
        assert!(!on_pre_flip_side(0.0, Some(PierSide::West)));
        assert!(!flip_window_open(0.0, Some(PierSide::West), 0.0));
    }

    /// An unmeasurable hour angle must not fire. NaN comparisons are all
    /// false, so a naive `ha >= threshold` would already refuse — but a naive
    /// `!(ha < threshold)` would fire, and that is one edit away.
    #[test]
    fn a_non_finite_hour_angle_never_fires() {
        for ha in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
            assert!(!on_pre_flip_side(ha, Some(PierSide::West)));
            assert!(!flip_window_open(ha, Some(PierSide::West), 0.0));
        }
    }
}
