//! ASCOM Mount (Telescope) wrapper and batch status types.

use crate::com::ComDispatch;
use crate::error::{AscomError, AscomResult};
use crate::health::ConnectionHealth;

/// ASCOM Mount (Telescope).
///
/// Thread-affinity invariant: see `AscomCamera`. All COM calls must run on
/// the STA thread that called `CoInitialize`; cross-thread access goes via
/// `AscomMountWrapper` which channels every command onto a dedicated worker.
pub struct Mount<D> {
    pub(crate) device: D,
}

#[cfg(windows)]
impl Mount<crate::windows::AscomDeviceConnection> {
    pub fn new(prog_id: &str) -> AscomResult<Self> {
        Ok(Self {
            device: crate::windows::AscomDeviceConnection::new(prog_id)?,
        })
    }
}

impl<D: ComDispatch> Mount<D> {
    /// Wrap a connection that already exists.
    pub fn over(device: D) -> Self {
        Self { device }
    }

    pub fn connect(&mut self) -> AscomResult<()> {
        self.device.connect()
    }

    pub fn disconnect(&mut self) -> AscomResult<()> {
        self.device.disconnect()
    }

    pub fn name(&self) -> AscomResult<String> {
        self.device.get("Name")
    }

    /// Get the interface version number
    pub fn interface_version(&self) -> AscomResult<i32> {
        self.device.get("InterfaceVersion")
    }

    /// Get the driver version string
    pub fn driver_version(&self) -> AscomResult<String> {
        self.device.get("DriverVersion")
    }

    /// Get the driver info/description
    pub fn driver_info(&self) -> AscomResult<String> {
        self.device.get("DriverInfo")
    }

    /// Get the list of supported custom actions
    pub fn supported_actions(&self) -> AscomResult<Vec<String>> {
        self.device.get("SupportedActions")
    }

    pub fn right_ascension(&self) -> AscomResult<f64> {
        self.device.get("RightAscension")
    }

    pub fn target_right_ascension(&self) -> AscomResult<f64> {
        self.device.get("TargetRightAscension")
    }

    pub fn set_target_right_ascension(&mut self, ra_hours: f64) -> AscomResult<()> {
        self.device.put("TargetRightAscension", ra_hours)
    }

    pub fn declination(&self) -> AscomResult<f64> {
        self.device.get("Declination")
    }

    pub fn target_declination(&self) -> AscomResult<f64> {
        self.device.get("TargetDeclination")
    }

    pub fn set_target_declination(&mut self, dec_degrees: f64) -> AscomResult<()> {
        self.device.put("TargetDeclination", dec_degrees)
    }

    pub fn altitude(&self) -> AscomResult<f64> {
        self.device.get("Altitude")
    }

    pub fn azimuth(&self) -> AscomResult<f64> {
        self.device.get("Azimuth")
    }

    pub fn side_of_pier(&self) -> AscomResult<i32> {
        self.device.get("SideOfPier")
    }

    pub fn sidereal_time(&self) -> AscomResult<f64> {
        self.device.get("SiderealTime")
    }

    pub fn site_latitude(&self) -> AscomResult<f64> {
        self.device.get("SiteLatitude")
    }

    pub fn set_site_latitude(&mut self, latitude_degrees: f64) -> AscomResult<()> {
        self.device.put("SiteLatitude", latitude_degrees)
    }

    pub fn site_longitude(&self) -> AscomResult<f64> {
        self.device.get("SiteLongitude")
    }

    pub fn set_site_longitude(&mut self, longitude_degrees: f64) -> AscomResult<()> {
        self.device.put("SiteLongitude", longitude_degrees)
    }

    pub fn site_elevation(&self) -> AscomResult<f64> {
        self.device.get("SiteElevation")
    }

    pub fn set_site_elevation(&mut self, elevation_meters: f64) -> AscomResult<()> {
        self.device.put("SiteElevation", elevation_meters)
    }

    /// UTCDate as an OLE Automation date (days since 1899-12-30).
    pub fn utc_date(&self) -> AscomResult<f64> {
        self.device
            .get::<crate::com::OleDate>("UTCDate")
            .map(|date| date.0)
    }

    /// Set UTCDate from an OLE Automation date (days since 1899-12-30).
    pub fn set_utc_date(&mut self, utc_date: f64) -> AscomResult<()> {
        self.device.put("UTCDate", crate::com::OleDate(utc_date))
    }

    pub fn does_refraction(&self) -> AscomResult<bool> {
        self.device.get("DoesRefraction")
    }

    pub fn set_does_refraction(&mut self, enabled: bool) -> AscomResult<()> {
        self.device.put("DoesRefraction", enabled)
    }

    pub fn tracking(&self) -> AscomResult<bool> {
        self.device.get("Tracking")
    }

    pub fn set_tracking(&mut self, tracking: bool) -> AscomResult<()> {
        self.device.put("Tracking", tracking)
    }

    pub fn slewing(&self) -> AscomResult<bool> {
        self.device.get("Slewing")
    }

    pub fn at_park(&self) -> AscomResult<bool> {
        self.device.get("AtPark")
    }

    pub fn at_home(&self) -> AscomResult<bool> {
        self.device.get("AtHome")
    }

    pub fn can_park(&self) -> AscomResult<bool> {
        self.device.get("CanPark")
    }

    /// Check if mount can find home position
    pub fn can_find_home(&self) -> AscomResult<bool> {
        self.device.get("CanFindHome")
    }

    /// Check if the current position can be stored as the park position
    pub fn can_set_park(&self) -> AscomResult<bool> {
        self.device.get("CanSetPark")
    }

    /// Get alignment mode (0=AltAz, 1=Polar, 2=GermanPolar)
    pub fn alignment_mode(&self) -> AscomResult<i32> {
        self.device.get("AlignmentMode")
    }

    pub fn can_unpark(&self) -> AscomResult<bool> {
        self.device.get("CanUnpark")
    }

    pub fn can_slew(&self) -> AscomResult<bool> {
        self.device.get("CanSlew")
    }

    pub fn can_slew_async(&self) -> AscomResult<bool> {
        self.device.get("CanSlewAsync")
    }

    pub fn can_sync(&self) -> AscomResult<bool> {
        self.device.get("CanSync")
    }

    pub fn can_set_tracking(&self) -> AscomResult<bool> {
        self.device.get("CanSetTracking")
    }

    pub fn park(&mut self) -> AscomResult<()> {
        self.device.call("Park", &[])
    }

    pub fn unpark(&mut self) -> AscomResult<()> {
        self.device.call("Unpark", &[])
    }

    pub fn abort_slew(&mut self) -> AscomResult<()> {
        self.device.call("AbortSlew", &[])
    }

    pub fn find_home(&mut self) -> AscomResult<()> {
        self.device.call("FindHome", &[])
    }

    pub fn set_park(&mut self) -> AscomResult<()> {
        self.device.call("SetPark", &[])
    }

    pub fn slew_to_coordinates_async(&mut self, ra: f64, dec: f64) -> AscomResult<()> {
        self.device
            .call("SlewToCoordinatesAsync", &[ra.into(), dec.into()])
    }

    pub fn slew_to_coordinates(&mut self, ra: f64, dec: f64) -> AscomResult<()> {
        self.device
            .call("SlewToCoordinates", &[ra.into(), dec.into()])
    }

    pub fn sync_to_coordinates(&mut self, ra: f64, dec: f64) -> AscomResult<()> {
        self.device
            .call("SyncToCoordinates", &[ra.into(), dec.into()])
    }

    pub fn slew_to_alt_az_async(&mut self, alt: f64, az: f64) -> AscomResult<()> {
        self.device
            .call("SlewToAltAzAsync", &[az.into(), alt.into()])
    }

    pub fn can_pulse_guide(&self) -> AscomResult<bool> {
        self.device.get("CanPulseGuide")
    }

    pub fn is_pulse_guiding(&self) -> AscomResult<bool> {
        self.device.get("IsPulseGuiding")
    }

    pub fn pulse_guide(&mut self, direction: i32, duration_ms: u32) -> AscomResult<()> {
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
        self.device
            .call("PulseGuide", &[direction.into(), duration_i32.into()])
    }

    pub fn guide_rate_right_ascension(&self) -> AscomResult<f64> {
        self.device.get("GuideRateRightAscension")
    }

    pub fn guide_rate_declination(&self) -> AscomResult<f64> {
        self.device.get("GuideRateDeclination")
    }

    pub fn set_guide_rate_right_ascension(&mut self, rate: f64) -> AscomResult<()> {
        self.device.put("GuideRateRightAscension", rate)
    }

    pub fn set_guide_rate_declination(&mut self, rate: f64) -> AscomResult<()> {
        self.device.put("GuideRateDeclination", rate)
    }

    /// Get the current tracking rate (0=Sidereal, 1=Lunar, 2=Solar, 3=King)
    pub fn tracking_rate(&self) -> AscomResult<i32> {
        self.device.get("TrackingRate")
    }

    /// Set the tracking rate (0=Sidereal, 1=Lunar, 2=Solar, 3=King)
    pub fn set_tracking_rate(&mut self, rate: i32) -> AscomResult<()> {
        self.device.put("TrackingRate", rate)
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
        // Validate axis parameter
        if !(0..=2).contains(&axis) {
            return Err(AscomError::InvalidArgument(format!(
                "Invalid axis {}: must be 0 (Primary), 1 (Secondary), or 2 (Tertiary)",
                axis
            )));
        }

        // Call the ASCOM CanMoveAxis method with the axis parameter
        // CanMoveAxis is a method that takes a TelescopeAxes enum and returns a Boolean
        self.device.call("CanMoveAxis", &[axis.into()])
    }

    /// Move an axis at the specified rate (degrees/second)
    /// axis: 0=RA/Azimuth (primary), 1=Dec/Altitude (secondary)
    /// rate: degrees per second (positive = N/E, negative = S/W), 0 to stop
    pub fn move_axis(&mut self, axis: i32, rate: f64) -> AscomResult<()> {
        self.device.call("MoveAxis", &[axis.into(), rate.into()])
    }

    // Batch property queries

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
            // Query CanMoveAxis for primary and secondary axes
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

    /// Perform a heartbeat check to verify device is still responding
    pub fn heartbeat(&self) -> AscomResult<()> {
        self.device.heartbeat()
    }

    /// Get connection health status
    pub fn get_health(&self) -> ConnectionHealth {
        self.device.health()
    }
}

/// Mount position status
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

/// Mount motion status
#[derive(Debug, Clone, Default)]
pub struct MountMotionStatus {
    pub slewing: Option<bool>,
    pub tracking: Option<bool>,
    pub tracking_rate: Option<i32>,
    pub at_home: Option<bool>,
    pub at_park: Option<bool>,
    pub is_pulse_guiding: Option<bool>,
}

/// Mount guide rates
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

/// Mount capabilities
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

/// Full mount status
#[derive(Debug, Clone, Default)]
pub struct MountFullStatus {
    pub position: MountPositionStatus,
    pub motion: MountMotionStatus,
    pub guide_rates: MountGuideRates,
    pub site: MountSiteStatus,
}
