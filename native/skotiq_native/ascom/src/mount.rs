//! ASCOM Mount (Telescope) wrapper and batch status types.

use crate::com::ComDispatch;
use crate::error::{AscomError, AscomResult};

com_device!(
    /// ASCOM Mount (Telescope).
    ///
    /// Thread-affinity invariant: see `AscomCamera`. All COM calls must run on
    /// the STA thread that called `CoInitialize`; cross-thread access goes via
    /// `AscomMountWrapper` which channels every command onto a dedicated worker.
    Mount
);

impl<D: ComDispatch> Mount<D> {
    skotiq_device::ascom_telescope_members!(com_member);

    pub fn pulse_guide(&self, direction: i32, duration_ms: u32) -> AscomResult<()> {
        // Why: ASCOM ITelescopeV3.PulseGuide takes a 32-bit
        // signed milliseconds value (COM IDL signed long). PHD2 and other
        // guide controllers never request >32s pulses but a buggy upstream
        // could overflow i32::MAX (~24.8 days). Reject explicitly instead of
        // wrapping into a negative duration that ASCOM drivers interpret as
        // "the opposite direction" silently.
        let duration_i32 = i32::try_from(duration_ms).map_err(|_| {
            AscomError::InvalidArgument(format!(
                "PulseGuide duration_ms {} exceeds i32::MAX; ASCOM PulseGuide \
                 caps at ~24.8 days. This indicates an upstream guider bug.",
                duration_ms
            ))
        })?;
        self.pulse_guide_i32(direction, duration_i32)
    }

    /// Check if axis movement is supported (axis: 0=RA/Az, 1=Dec/Alt, 2=Tertiary)
    ///
    /// This properly calls the ASCOM CanMoveAxis(TelescopeAxes) method which returns
    /// a boolean indicating whether the specified axis can be moved.
    ///
    /// According to ASCOM standards:
    /// - Axis 0: Primary axis (RA for equatorial, Azimuth for alt-az)
    /// - Axis 1: Secondary axis (Dec for equatorial, Altitude for alt-az)
    /// - Axis 2: Tertiary axis (if present, e.g., rotator on some mounts)
    pub fn can_move_axis(&self, axis: i32) -> AscomResult<bool> {
        if !(0..=2).contains(&axis) {
            return Err(AscomError::InvalidArgument(format!(
                "Invalid axis {}: must be 0 (Primary), 1 (Secondary), or 2 (Tertiary)",
                axis
            )));
        }

        self.can_move_axis_unchecked(axis)
    }

    /// Get mount position in a single batch operation
    /// Returns current RA/Dec/Alt/Az coordinates
    pub fn get_position_status(&self) -> MountPositionStatus {
        MountPositionStatus {
            right_ascension: self.right_ascension().ok(),
            declination: self.declination().ok(),
            target_right_ascension: self.target_right_ascension().ok(),
            target_declination: self.target_declination().ok(),
            altitude: self.altitude().ok(),
            azimuth: self.azimuth().ok(),
            sidereal_time: self.sidereal_time().ok(),
            side_of_pier: self.side_of_pier().ok(),
        }
    }

    /// Get mount motion status in a single batch operation
    pub fn get_motion_status(&self) -> MountMotionStatus {
        MountMotionStatus {
            slewing: self.slewing().ok(),
            tracking: self.tracking().ok(),
            tracking_rate: self.tracking_rate().ok(),
            at_home: self.at_home().ok(),
            at_park: self.at_park().ok(),
            is_pulse_guiding: self.is_pulse_guiding().ok(),
        }
    }

    /// Get mount guiding configuration in a single batch operation
    pub fn get_guide_rates(&self) -> MountGuideRates {
        MountGuideRates {
            guide_rate_ra: self.guide_rate_right_ascension().ok(),
            guide_rate_dec: self.guide_rate_declination().ok(),
            can_pulse_guide: self.can_pulse_guide().ok(),
        }
    }

    /// Get mount site/time/refraction configuration in a single batch operation
    pub fn get_site_status(&self) -> MountSiteStatus {
        MountSiteStatus {
            site_latitude: self.site_latitude().ok(),
            site_longitude: self.site_longitude().ok(),
            site_elevation: self.site_elevation().ok(),
            utc_date: self.utc_date().ok(),
            does_refraction: self.does_refraction().ok(),
        }
    }

    /// Get mount capabilities in a single batch operation
    /// Use this to determine what operations are available
    pub fn get_capabilities(&self) -> MountCapabilities {
        MountCapabilities {
            can_slew: self.can_slew().ok(),
            can_slew_async: self.can_slew_async().ok(),
            can_sync: self.can_sync().ok(),
            can_set_tracking: self.can_set_tracking().ok(),
            can_park: self.can_park().ok(),
            can_unpark: self.can_unpark().ok(),
            can_pulse_guide: self.can_pulse_guide().ok(),
            can_move_axis_primary: self.can_move_axis(0).ok(),
            can_move_axis_secondary: self.can_move_axis(1).ok(),
        }
    }

    /// Get complete mount status in a single batch operation
    /// This is the most comprehensive status query for polling
    pub fn get_full_status(&self) -> MountFullStatus {
        MountFullStatus {
            position: self.get_position_status(),
            motion: self.get_motion_status(),
            guide_rates: self.get_guide_rates(),
            site: self.get_site_status(),
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct MountPositionStatus {
    pub right_ascension: Option<f64>,
    pub declination: Option<f64>,
    pub target_right_ascension: Option<f64>,
    pub target_declination: Option<f64>,
    pub altitude: Option<f64>,
    pub azimuth: Option<f64>,
    pub sidereal_time: Option<f64>,
    pub side_of_pier: Option<i32>,
}

#[derive(Debug, Clone, Default)]
pub struct MountMotionStatus {
    pub slewing: Option<bool>,
    pub tracking: Option<bool>,
    pub tracking_rate: Option<i32>,
    pub at_home: Option<bool>,
    pub at_park: Option<bool>,
    pub is_pulse_guiding: Option<bool>,
}

#[derive(Debug, Clone, Default)]
pub struct MountGuideRates {
    pub guide_rate_ra: Option<f64>,
    pub guide_rate_dec: Option<f64>,
    pub can_pulse_guide: Option<bool>,
}

/// Mount site/time/refraction configuration
#[derive(Debug, Clone, Default)]
pub struct MountSiteStatus {
    pub site_latitude: Option<f64>,
    pub site_longitude: Option<f64>,
    pub site_elevation: Option<f64>,
    /// OLE Automation date (days since 1899-12-30), matching ASCOM UTCDate.
    pub utc_date: Option<f64>,
    pub does_refraction: Option<bool>,
}

#[derive(Debug, Clone, Default)]
pub struct MountCapabilities {
    pub can_slew: Option<bool>,
    pub can_slew_async: Option<bool>,
    pub can_sync: Option<bool>,
    pub can_set_tracking: Option<bool>,
    pub can_park: Option<bool>,
    pub can_unpark: Option<bool>,
    pub can_pulse_guide: Option<bool>,
    pub can_move_axis_primary: Option<bool>,
    pub can_move_axis_secondary: Option<bool>,
}

#[derive(Debug, Clone, Default)]
pub struct MountFullStatus {
    pub position: MountPositionStatus,
    pub motion: MountMotionStatus,
    pub guide_rates: MountGuideRates,
    pub site: MountSiteStatus,
}
