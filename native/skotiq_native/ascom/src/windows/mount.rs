//! ASCOM Mount (Telescope) wrapper and batch status types.

use super::connection::AscomDeviceConnection;
use super::health::ConnectionHealth;

/// ASCOM Mount (Telescope).
///
/// Thread-affinity invariant: see `AscomCamera`. All COM calls must run on
/// the STA thread that called `CoInitialize`; cross-thread access goes via
/// `AscomMountWrapper` which channels every command onto a dedicated worker.
pub struct AscomMount {
    device: AscomDeviceConnection,
}

impl AscomMount {
    pub fn new(prog_id: &str) -> Result<Self, String> {
        Ok(Self {
            device: AscomDeviceConnection::new(prog_id)?,
        })
    }

    pub fn connect(&mut self) -> Result<(), String> {
        self.device.connect()
    }

    pub fn disconnect(&mut self) -> Result<(), String> {
        self.device.disconnect()
    }

    pub fn name(&self) -> Result<String, String> {
        self.device.get_string_property("Name")
    }

    /// Get the interface version number
    pub fn interface_version(&self) -> Result<i32, String> {
        self.device.get_int_property("InterfaceVersion")
    }

    /// Get the driver version string
    pub fn driver_version(&self) -> Result<String, String> {
        self.device.get_string_property("DriverVersion")
    }

    /// Get the driver info/description
    pub fn driver_info(&self) -> Result<String, String> {
        self.device.get_string_property("DriverInfo")
    }

    /// Get the list of supported custom actions
    pub fn supported_actions(&self) -> Result<Vec<String>, String> {
        self.device.get_string_array_property("SupportedActions")
    }

    pub fn right_ascension(&self) -> Result<f64, String> {
        self.device.get_double_property("RightAscension")
    }

    pub fn target_right_ascension(&self) -> Result<f64, String> {
        self.device.get_double_property("TargetRightAscension")
    }

    pub fn set_target_right_ascension(&mut self, ra_hours: f64) -> Result<(), String> {
        self.device
            .set_double_property("TargetRightAscension", ra_hours)
    }

    pub fn declination(&self) -> Result<f64, String> {
        self.device.get_double_property("Declination")
    }

    pub fn target_declination(&self) -> Result<f64, String> {
        self.device.get_double_property("TargetDeclination")
    }

    pub fn set_target_declination(&mut self, dec_degrees: f64) -> Result<(), String> {
        self.device
            .set_double_property("TargetDeclination", dec_degrees)
    }

    pub fn altitude(&self) -> Result<f64, String> {
        self.device.get_double_property("Altitude")
    }

    pub fn azimuth(&self) -> Result<f64, String> {
        self.device.get_double_property("Azimuth")
    }

    pub fn side_of_pier(&self) -> Result<i32, String> {
        self.device.get_int_property("SideOfPier")
    }

    pub fn sidereal_time(&self) -> Result<f64, String> {
        self.device.get_double_property("SiderealTime")
    }

    pub fn site_latitude(&self) -> Result<f64, String> {
        self.device.get_double_property("SiteLatitude")
    }

    pub fn set_site_latitude(&mut self, latitude_degrees: f64) -> Result<(), String> {
        self.device
            .set_double_property("SiteLatitude", latitude_degrees)
    }

    pub fn site_longitude(&self) -> Result<f64, String> {
        self.device.get_double_property("SiteLongitude")
    }

    pub fn set_site_longitude(&mut self, longitude_degrees: f64) -> Result<(), String> {
        self.device
            .set_double_property("SiteLongitude", longitude_degrees)
    }

    pub fn site_elevation(&self) -> Result<f64, String> {
        self.device.get_double_property("SiteElevation")
    }

    pub fn set_site_elevation(&mut self, elevation_meters: f64) -> Result<(), String> {
        self.device
            .set_double_property("SiteElevation", elevation_meters)
    }

    /// UTCDate as an OLE Automation date (days since 1899-12-30).
    pub fn utc_date(&self) -> Result<f64, String> {
        self.device.get_date_property("UTCDate")
    }

    /// Set UTCDate from an OLE Automation date (days since 1899-12-30).
    pub fn set_utc_date(&mut self, utc_date: f64) -> Result<(), String> {
        self.device.set_date_property("UTCDate", utc_date)
    }

    pub fn does_refraction(&self) -> Result<bool, String> {
        self.device.get_bool_property("DoesRefraction")
    }

    pub fn set_does_refraction(&mut self, enabled: bool) -> Result<(), String> {
        self.device.set_bool_property("DoesRefraction", enabled)
    }

    pub fn tracking(&self) -> Result<bool, String> {
        self.device.get_bool_property("Tracking")
    }

    pub fn set_tracking(&mut self, tracking: bool) -> Result<(), String> {
        self.device.set_bool_property("Tracking", tracking)
    }

    pub fn slewing(&self) -> Result<bool, String> {
        self.device.get_bool_property("Slewing")
    }

    pub fn at_park(&self) -> Result<bool, String> {
        self.device.get_bool_property("AtPark")
    }

    pub fn at_home(&self) -> Result<bool, String> {
        self.device.get_bool_property("AtHome")
    }

    pub fn can_park(&self) -> Result<bool, String> {
        self.device.get_bool_property("CanPark")
    }

    /// Check if mount can find home position
    pub fn can_find_home(&self) -> Result<bool, String> {
        self.device.get_bool_property("CanFindHome")
    }

    /// Get alignment mode (0=AltAz, 1=Polar, 2=GermanPolar)
    pub fn alignment_mode(&self) -> Result<i32, String> {
        self.device.get_int_property("AlignmentMode")
    }

    pub fn can_unpark(&self) -> Result<bool, String> {
        self.device.get_bool_property("CanUnpark")
    }

    pub fn can_slew(&self) -> Result<bool, String> {
        self.device.get_bool_property("CanSlew")
    }

    pub fn can_slew_async(&self) -> Result<bool, String> {
        self.device.get_bool_property("CanSlewAsync")
    }

    pub fn can_sync(&self) -> Result<bool, String> {
        self.device.get_bool_property("CanSync")
    }

    pub fn can_set_tracking(&self) -> Result<bool, String> {
        self.device.get_bool_property("CanSetTracking")
    }

    pub fn park(&mut self) -> Result<(), String> {
        self.device.call_method("Park")
    }

    pub fn unpark(&mut self) -> Result<(), String> {
        self.device.call_method("Unpark")
    }

    pub fn abort_slew(&mut self) -> Result<(), String> {
        self.device.call_method("AbortSlew")
    }

    pub fn find_home(&mut self) -> Result<(), String> {
        self.device.call_method("FindHome")
    }

    pub fn slew_to_coordinates_async(&mut self, ra: f64, dec: f64) -> Result<(), String> {
        self.device
            .call_method_2_double("SlewToCoordinatesAsync", ra, dec)
    }

    pub fn slew_to_coordinates(&mut self, ra: f64, dec: f64) -> Result<(), String> {
        self.device
            .call_method_2_double("SlewToCoordinates", ra, dec)
    }

    pub fn sync_to_coordinates(&mut self, ra: f64, dec: f64) -> Result<(), String> {
        self.device
            .call_method_2_double("SyncToCoordinates", ra, dec)
    }

    pub fn slew_to_alt_az_async(&mut self, alt: f64, az: f64) -> Result<(), String> {
        self.device
            .call_method_2_double("SlewToAltAzAsync", az, alt)
    }

    pub fn can_pulse_guide(&self) -> Result<bool, String> {
        self.device.get_bool_property("CanPulseGuide")
    }

    pub fn is_pulse_guiding(&self) -> Result<bool, String> {
        self.device.get_bool_property("IsPulseGuiding")
    }

    pub fn pulse_guide(&mut self, direction: i32, duration_ms: u32) -> Result<(), String> {
        // Why: ASCOM ITelescopeV3.PulseGuide takes a 32-bit
        // signed milliseconds value (COM IDL signed long). PHD2 and other
        // guide controllers never request >32s pulses but a buggy upstream
        // could overflow i32::MAX (~24.8 days). Reject explicitly instead of
        // wrapping into a negative duration that ASCOM drivers interpret as
        // "the opposite direction" silently.
        let duration_i32 = i32::try_from(duration_ms).map_err(|_| {
            format!(
                "PulseGuide duration_ms {} exceeds i32::MAX; ASCOM PulseGuide \
                 caps at ~24.8 days. This indicates an upstream guider bug.",
                duration_ms
            )
        })?;
        self.device
            .call_method_2_int("PulseGuide", direction, duration_i32)
    }

    pub fn guide_rate_right_ascension(&self) -> Result<f64, String> {
        self.device.get_double_property("GuideRateRightAscension")
    }

    pub fn guide_rate_declination(&self) -> Result<f64, String> {
        self.device.get_double_property("GuideRateDeclination")
    }

    pub fn set_guide_rate_right_ascension(&mut self, rate: f64) -> Result<(), String> {
        self.device
            .set_double_property("GuideRateRightAscension", rate)
    }

    pub fn set_guide_rate_declination(&mut self, rate: f64) -> Result<(), String> {
        self.device
            .set_double_property("GuideRateDeclination", rate)
    }

    /// Get the current tracking rate (0=Sidereal, 1=Lunar, 2=Solar, 3=King)
    pub fn tracking_rate(&self) -> Result<i32, String> {
        self.device.get_int_property("TrackingRate")
    }

    /// Set the tracking rate (0=Sidereal, 1=Lunar, 2=Solar, 3=King)
    pub fn set_tracking_rate(&mut self, rate: i32) -> Result<(), String> {
        self.device.set_int_property("TrackingRate", rate)
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
    pub fn can_move_axis(&self, axis: i32) -> Result<bool, String> {
        // Validate axis parameter
        if !(0..=2).contains(&axis) {
            return Err(format!(
                "Invalid axis {}: must be 0 (Primary), 1 (Secondary), or 2 (Tertiary)",
                axis
            ));
        }

        // Call the ASCOM CanMoveAxis method with the axis parameter
        // CanMoveAxis is a method that takes a TelescopeAxes enum and returns a Boolean
        self.device
            .call_method_1_int_return_bool("CanMoveAxis", axis)
    }

    /// Move an axis at the specified rate (degrees/second)
    /// axis: 0=RA/Azimuth (primary), 1=Dec/Altitude (secondary)
    /// rate: degrees per second (positive = N/E, negative = S/W), 0 to stop
    pub fn move_axis(&mut self, axis: i32, rate: f64) -> Result<(), String> {
        self.device.call_method_int_double("MoveAxis", axis, rate)
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
    pub fn heartbeat(&self) -> Result<(), String> {
        self.device.heartbeat()
    }

    /// Get connection health status
    pub fn get_health(&self) -> ConnectionHealth {
        self.device.get_health()
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
