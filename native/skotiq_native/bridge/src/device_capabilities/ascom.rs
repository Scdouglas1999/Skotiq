//! What an ASCOM mount's own capability read means for the app.

use crate::device_capabilities::types::MountCapabilities;

/// What an ASCOM mount's own capability read means for the app.
pub(crate) fn mount_capabilities_from_ascom(
    ascom_caps: crate::ascom_wrapper::mount::AscomMountCapabilities,
) -> MountCapabilities {
    MountCapabilities {
        can_slew: ascom_caps.can_slew,
        can_slew_async: ascom_caps.can_slew_async,
        can_sync: ascom_caps.can_sync,
        can_park: ascom_caps.can_park,
        can_unpark: ascom_caps.can_unpark,
        can_set_park: ascom_caps.can_set_park,
        can_pulse_guide: ascom_caps.can_pulse_guide,
        can_set_tracking: ascom_caps.can_set_tracking,
        can_find_home: ascom_caps.can_find_home,
        can_move_axis: ascom_caps.can_move_axis_primary || ascom_caps.can_move_axis_secondary,
        is_equatorial: ascom_caps.is_equatorial,
        axis_count: if ascom_caps.can_move_axis_secondary {
            2
        } else {
            1
        },
        // Why: ASCOM ITelescopeV3.PulseGuide accepts any non-negative duration
        // and the spec defines no min/max guide-pulse property, so the wrapper
        // cannot report a range. None = "range unknown" (no artificial clamp).
        min_pulse_guide_ms: None,
        max_pulse_guide_ms: None,
        ..Default::default()
    }
}
