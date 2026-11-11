//! What the run knows about the target it is on.

use super::part::state_part;

state_part! {
    /// The current target and everything derived from it. Cleared as a whole
    /// when a fresh run starts (see [`super::TriggerState::clear_target_state`]);
    /// a resumed run keeps the target its checkpoint recorded.
    pub struct TargetState, checkpointed as TargetSnapshot {
        persisted {
            /// Target name for the current meridian flip tracking
            pub current_target_name: Option<String>,
            /// Target RA in degrees
            pub target_ra: Option<f64>,
            /// Target Dec in degrees
            pub target_dec: Option<f64>,
            pub current_altitude: Option<f64>,
            /// Hour angle of the ACTIVE TARGET in hours, signed and normalized to
            /// `[-12, +12]`: negative is east of the meridian (not yet transited),
            /// positive is west of it.
            ///
            /// Written by the executor's monitor loop from the target's own RA and the
            /// observer longitude — never from the mount's reported pointing. Those two
            /// are the same number only while the mount is actually tracking the
            /// target, and the gap between them is not a rounding difference: a mount
            /// parked at its home position (RA 0h on every simulator, and on plenty of
            /// drivers) reads whatever the local sidereal time happens to be, so a run
            /// whose first target was 1.5h EAST of the meridian was flipped 1.5 ms
            /// after it started, before the first slew, on the strength of the parked
            /// mount's +2.6h. The trigger is about the target's transit; the target's
            /// own coordinates are the only honest input to it.
            pub current_hour_angle: Option<f64>,
            /// RA in degrees
            pub last_plate_solve_ra: Option<f64>,
            /// Dec in degrees
            pub last_plate_solve_dec: Option<f64>,
            /// arcsec per pixel
            pub last_plate_solve_pixel_scale: Option<f64>,
        }
        transient {
            /// The star the run's guiding settled on for the current target. A star
            /// selected later on the same field is compared with it. Cleared when
            /// the target changes.
            pub guide_star_reference: Option<crate::GuideStarQuality>,
        }
    }
}
