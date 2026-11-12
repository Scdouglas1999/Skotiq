//! The ASCOM device interfaces: every member of each device kind, once.
//!
//! The statement syntax is described in [`super::members`]. Parameter order is
//! the positional order of the COM method; the quoted names are the ASCOM
//! names, which Alpaca uses for paths (lower case) and parameters.

/// Members every ASCOM device has.
#[macro_export]
macro_rules! ascom_common_members {
    ($callback:ident) => {
        $crate::ascom_members! { $callback;
            get name() -> String = "Name";
            get description() -> String = "Description";
            get driver_version() -> String = "DriverVersion";
            get driver_info() -> String = "DriverInfo";
            get interface_version() -> i32 = "InterfaceVersion";
            get supported_actions() -> Vec<String> = "SupportedActions";
            call setup_dialog() = "SetupDialog" [com_only];
        }
    };
}

/// `ISafetyMonitor`
#[macro_export]
macro_rules! ascom_safety_monitor_members {
    ($callback:ident) => {
        $crate::ascom_members! { $callback;
            get is_safe() -> bool = "IsSafe";
        }
    };
}

/// `ISwitchV2`
#[macro_export]
macro_rules! ascom_switch_members {
    ($callback:ident) => {
        $crate::ascom_members! { $callback;
            get max_switch() -> i32 = "MaxSwitch";
            call get_switch(id: i32 = "Id") -> bool = "GetSwitch";
            call set_switch(id: i32 = "Id", state: bool = "State") = "SetSwitch";
            call get_switch_name(id: i32 = "Id") -> String = "GetSwitchName";
            call set_switch_name(id: i32 = "Id", name: &str = "Name") = "SetSwitchName";
            call get_switch_description(id: i32 = "Id") -> String = "GetSwitchDescription";
            call get_switch_value(id: i32 = "Id") -> f64 = "GetSwitchValue";
            call set_switch_value(id: i32 = "Id", value: f64 = "Value") = "SetSwitchValue";
            call min_switch_value(id: i32 = "Id") -> f64 = "MinSwitchValue";
            call max_switch_value(id: i32 = "Id") -> f64 = "MaxSwitchValue";
            call switch_step(id: i32 = "Id") -> f64 = "SwitchStep";
            call can_write(id: i32 = "Id") -> bool = "CanWrite";
        }
    };
}

/// `IObservingConditions`
#[macro_export]
macro_rules! ascom_observing_conditions_members {
    ($callback:ident) => {
        $crate::ascom_members! { $callback;
            get cloud_cover() -> f64 = "CloudCover";
            get dew_point() -> f64 = "DewPoint";
            get humidity() -> f64 = "Humidity";
            get pressure() -> f64 = "Pressure";
            get rain_rate() -> f64 = "RainRate";
            get sky_brightness() -> f64 = "SkyBrightness";
            get sky_quality() -> f64 = "SkyQuality";
            get sky_temperature() -> f64 = "SkyTemperature";
            get star_fwhm() -> f64 = "StarFWHM";
            get temperature() -> f64 = "Temperature";
            get wind_direction() -> f64 = "WindDirection";
            get wind_gust() -> f64 = "WindGust";
            get wind_speed() -> f64 = "WindSpeed";
            get average_period() -> f64 = "AveragePeriod";
            set set_average_period(period: f64) = "AveragePeriod";
            get time_since_last_update(sensor: &str = "SensorName") -> f64 = "TimeSinceLastUpdate";
            get sensor_description(sensor: &str = "SensorName") -> String = "SensorDescription";
            call refresh() = "Refresh";
        }
    };
}

/// `ICoverCalibratorV1`
#[macro_export]
macro_rules! ascom_cover_calibrator_members {
    ($callback:ident) => {
        $crate::ascom_members! { $callback;
            get cover_state() -> i32 as $crate::ascom::CoverStatus = "CoverState";
            get calibrator_state() -> i32 as $crate::ascom::CalibratorStatus = "CalibratorState";
            get brightness() -> i32 = "Brightness";
            set set_brightness(brightness: i32) = "Brightness";
            get max_brightness() -> i32 = "MaxBrightness";
            call open_cover() = "OpenCover" [long];
            call close_cover() = "CloseCover" [long];
            call halt_cover() = "HaltCover";
            call calibrator_on(brightness: i32 = "Brightness") = "CalibratorOn";
            call calibrator_off() = "CalibratorOff";
        }
    };
}

/// `IRotatorV3`
#[macro_export]
macro_rules! ascom_rotator_members {
    ($callback:ident) => {
        $crate::ascom_members! { $callback;
            get position() -> f64 = "Position";
            get mechanical_position() -> f64 = "MechanicalPosition";
            get target_position() -> f64 = "TargetPosition";
            get step_size() -> f64 = "StepSize";
            get is_moving() -> bool = "IsMoving";
            get can_reverse() -> bool = "CanReverse";
            get reverse() -> bool = "Reverse";
            set set_reverse(reverse: bool) = "Reverse";
            call move_relative(offset: f64 = "Position") = "Move";
            call move_absolute(position: f64 = "Position") = "MoveAbsolute";
            call move_mechanical(position: f64 = "Position") = "MoveMechanical";
            call halt() = "Halt";
            call sync(position: f64 = "Position") = "Sync";
        }
    };
}

/// `IFilterWheelV2`
#[macro_export]
macro_rules! ascom_filter_wheel_members {
    ($callback:ident) => {
        $crate::ascom_members! { $callback;
            get position() -> i32 = "Position" [com_wrapped(read_position)];
            set set_position(position: i32) = "Position" [com_wrapped(write_position)];
            get names() -> Vec<String> = "Names";
            get focus_offsets() -> Vec<i32> = "FocusOffsets";
        }
    };
}

/// `IFocuserV3`
#[macro_export]
macro_rules! ascom_focuser_members {
    ($callback:ident) => {
        $crate::ascom_members! { $callback;
            get position() -> i32 = "Position";
            get max_step() -> i32 = "MaxStep";
            get max_increment() -> i32 = "MaxIncrement";
            get step_size() -> f64 = "StepSize";
            get is_moving() -> bool = "IsMoving";
            get absolute() -> bool = "Absolute";
            get temp_comp_available() -> bool = "TempCompAvailable";
            get temp_comp() -> bool = "TempComp";
            set set_temp_comp(enabled: bool) = "TempComp";
            get temperature() -> f64 = "Temperature";
            call move_to(position: i32 = "Position") = "Move" [long];
            call halt() = "Halt";
        }
    };
}

/// `IDomeV2`
#[macro_export]
macro_rules! ascom_dome_members {
    ($callback:ident) => {
        $crate::ascom_members! { $callback;
            get altitude() -> f64 = "Altitude";
            get azimuth() -> f64 = "Azimuth";
            get at_home() -> bool = "AtHome";
            get at_park() -> bool = "AtPark";
            get shutter_status() -> i32 as $crate::ascom::ShutterStatus = "ShutterStatus";
            get slewing() -> bool = "Slewing";
            get slaved() -> bool = "Slaved";
            set set_slaved(slaved: bool) = "Slaved" [com_wrapped(write_slaved)];
            get can_find_home() -> bool = "CanFindHome";
            get can_park() -> bool = "CanPark";
            get can_set_altitude() -> bool = "CanSetAltitude";
            get can_set_azimuth() -> bool = "CanSetAzimuth";
            get can_set_shutter() -> bool = "CanSetShutter";
            get can_slave() -> bool = "CanSlave";
            get can_sync_azimuth() -> bool = "CanSyncAzimuth";
            call abort_slew() = "AbortSlew";
            call close_shutter() = "CloseShutter" [long];
            call find_home() = "FindHome" [very_long];
            call open_shutter() = "OpenShutter" [long];
            call park() = "Park" [long];
            call set_park() = "SetPark";
            call slew_to_altitude(altitude: f64 = "Altitude") = "SlewToAltitude" [long];
            call slew_to_azimuth(azimuth: f64 = "Azimuth") = "SlewToAzimuth" [very_long];
            call sync_to_azimuth(azimuth: f64 = "Azimuth") = "SyncToAzimuth";
        }
    };
}

/// `ITelescopeV3`
#[macro_export]
macro_rules! ascom_telescope_members {
    ($callback:ident) => {
        $crate::ascom_members! { $callback;
            get alignment_mode() -> i32 = "AlignmentMode";
            get aperture_area() -> f64 = "ApertureArea";
            get aperture_diameter() -> f64 = "ApertureDiameter";
            get focal_length() -> f64 = "FocalLength";
            get equatorial_system() -> i32 = "EquatorialSystem";

            get right_ascension() -> f64 = "RightAscension";
            get declination() -> f64 = "Declination";
            get altitude() -> f64 = "Altitude";
            get azimuth() -> f64 = "Azimuth";
            get sidereal_time() -> f64 = "SiderealTime";
            get_date utc_date() = "UTCDate";
            set_date set_utc_date(utc_date) = "UTCDate";

            get target_right_ascension() -> f64 = "TargetRightAscension";
            set set_target_right_ascension(ra_hours: f64) = "TargetRightAscension";
            get target_declination() -> f64 = "TargetDeclination";
            set set_target_declination(dec_degrees: f64) = "TargetDeclination";

            get slewing() -> bool = "Slewing";
            get tracking() -> bool = "Tracking";
            set set_tracking(tracking: bool) = "Tracking";
            get tracking_rate() -> i32 as $crate::ascom::DriveRate = "TrackingRate";
            set set_tracking_rate(rate: i32 as $crate::ascom::DriveRate) = "TrackingRate";
            get tracking_rates() -> Vec<i32> as Vec<$crate::ascom::DriveRate> = "TrackingRates" [alpaca_only];
            get at_home() -> bool = "AtHome";
            get at_park() -> bool = "AtPark";
            get side_of_pier() -> i32 as $crate::ascom::PierSide = "SideOfPier";
            set set_side_of_pier(side: i32 as $crate::ascom::PierSide) = "SideOfPier";
            call destination_side_of_pier(ra: f64 = "RightAscension", dec: f64 = "Declination")
                -> i32 as $crate::ascom::PierSide = "DestinationSideOfPier";
            get does_refraction() -> bool = "DoesRefraction";
            set set_does_refraction(enabled: bool) = "DoesRefraction";

            get site_latitude() -> f64 = "SiteLatitude";
            set set_site_latitude(latitude_degrees: f64) = "SiteLatitude";
            get site_longitude() -> f64 = "SiteLongitude";
            set set_site_longitude(longitude_degrees: f64) = "SiteLongitude";
            get site_elevation() -> f64 = "SiteElevation";
            set set_site_elevation(elevation_meters: f64) = "SiteElevation";

            get can_find_home() -> bool = "CanFindHome";
            get can_park() -> bool = "CanPark";
            get can_unpark() -> bool = "CanUnpark";
            get can_set_park() -> bool = "CanSetPark";
            get can_slew() -> bool = "CanSlew";
            get can_slew_async() -> bool = "CanSlewAsync";
            get can_slew_alt_az() -> bool = "CanSlewAltAz";
            get can_slew_alt_az_async() -> bool = "CanSlewAltAzAsync";
            get can_sync() -> bool = "CanSync";
            get can_sync_alt_az() -> bool = "CanSyncAltAz";
            get can_set_tracking() -> bool = "CanSetTracking";
            get can_pulse_guide() -> bool = "CanPulseGuide";
            get can_set_guide_rates() -> bool = "CanSetGuideRates";
            get can_set_right_ascension_rate() -> bool = "CanSetRightAscensionRate";
            get can_set_declination_rate() -> bool = "CanSetDeclinationRate";
            call can_move_axis(axis: i32 = "Axis") -> bool = "CanMoveAxis"
                [com_wrapped(can_move_axis_unchecked)];
            call axis_rates_for_axis(axis: i32 = "Axis") -> Vec<$crate::ascom::AxisRate> = "AxisRates"
                [alpaca_only];

            get guide_rate_right_ascension() -> f64 = "GuideRateRightAscension";
            set set_guide_rate_right_ascension(rate: f64) = "GuideRateRightAscension";
            get guide_rate_declination() -> f64 = "GuideRateDeclination";
            set set_guide_rate_declination(rate: f64) = "GuideRateDeclination";
            get is_pulse_guiding() -> bool = "IsPulseGuiding";

            call abort_slew() = "AbortSlew";
            call find_home() = "FindHome" [long];
            call park() = "Park" [long];
            call unpark() = "Unpark";
            call set_park() = "SetPark";
            call slew_to_coordinates(ra: f64 = "RightAscension", dec: f64 = "Declination")
                = "SlewToCoordinates" [long];
            call slew_to_coordinates_async(ra: f64 = "RightAscension", dec: f64 = "Declination")
                = "SlewToCoordinatesAsync";
            call slew_to_target() = "SlewToTarget" [long];
            call slew_to_target_async() = "SlewToTargetAsync";
            call slew_to_alt_az(az: f64 = "Azimuth", alt: f64 = "Altitude")
                = "SlewToAltAz" [long, rust_args_reversed];
            call slew_to_alt_az_async(az: f64 = "Azimuth", alt: f64 = "Altitude")
                = "SlewToAltAzAsync" [rust_args_reversed];
            call sync_to_coordinates(ra: f64 = "RightAscension", dec: f64 = "Declination")
                = "SyncToCoordinates";
            call sync_to_target() = "SyncToTarget";
            call sync_to_alt_az(az: f64 = "Azimuth", alt: f64 = "Altitude")
                = "SyncToAltAz" [rust_args_reversed];
            call pulse_guide(direction: i32 = "Direction", duration_ms: i32 = "Duration")
                = "PulseGuide" [com_wrapped(pulse_guide_i32)];
            call move_axis(axis: i32 = "Axis", rate: f64 = "Rate") = "MoveAxis";
        }
    };
}

/// `ICameraV4`. `ImageArray` is transferred by hand-written code in each
/// transport; what the members mean is decided in [`super::camera`].
#[macro_export]
macro_rules! ascom_camera_members {
    ($callback:ident) => {
        $crate::ascom_members! { $callback;
            get camera_x_size() -> i32 = "CameraXSize";
            get camera_y_size() -> i32 = "CameraYSize";
            get pixel_size_x() -> f64 = "PixelSizeX";
            get pixel_size_y() -> f64 = "PixelSizeY";
            get max_adu() -> i32 = "MaxADU";
            get sensor_type() -> i32 = "SensorType";
            get sensor_name() -> String = "SensorName";
            get bayer_offset_x() -> i32 = "BayerOffsetX";
            get bayer_offset_y() -> i32 = "BayerOffsetY";

            get max_bin_x() -> i32 = "MaxBinX";
            get max_bin_y() -> i32 = "MaxBinY";
            get bin_x() -> i32 = "BinX";
            get bin_y() -> i32 = "BinY";
            set set_bin_x(value: i32) = "BinX";
            set set_bin_y(value: i32) = "BinY";

            get can_set_ccd_temperature() -> bool = "CanSetCCDTemperature";
            get can_get_cooler_power() -> bool = "CanGetCoolerPower";
            get ccd_temperature() -> f64 = "CCDTemperature";
            get ccd_temperature_setpoint() -> f64 = "SetCCDTemperature";
            set set_ccd_temperature(temp: f64) = "SetCCDTemperature";
            get cooler_on() -> bool = "CoolerOn";
            set set_cooler_on(on: bool) = "CoolerOn";
            get cooler_power() -> f64 = "CoolerPower";
            get heat_sink_temperature() -> f64 = "HeatSinkTemperature";

            get gain() -> i32 = "Gain";
            set set_gain(gain: i32) = "Gain";
            get gain_min() -> i32 = "GainMin";
            get gain_max() -> i32 = "GainMax";
            get gains() -> Vec<String> = "Gains";
            get offset() -> i32 = "Offset";
            set set_offset(offset: i32) = "Offset";
            get offset_min() -> i32 = "OffsetMin";
            get offset_max() -> i32 = "OffsetMax";
            get offsets() -> Vec<String> = "Offsets";

            get camera_state() -> i32 as $crate::ascom::CameraState = "CameraState";
            get image_ready() -> bool = "ImageReady";
            get is_pulse_guiding() -> bool = "IsPulseGuiding";
            get percent_completed() -> i32 = "PercentCompleted";
            get exposure_min() -> f64 = "ExposureMin";
            get exposure_max() -> f64 = "ExposureMax";
            call start_exposure(duration: f64 = "Duration", light: bool = "Light") = "StartExposure";
            call abort_exposure() = "AbortExposure";
            call stop_exposure() = "StopExposure";
            call pulse_guide(direction: i32 = "Direction", duration_ms: i32 = "Duration") = "PulseGuide";

            get readout_mode() -> i32 = "ReadoutMode";
            set set_readout_mode(mode: i32) = "ReadoutMode";
            get readout_modes() -> Vec<String> = "ReadoutModes";

            get start_x() -> i32 = "StartX";
            get start_y() -> i32 = "StartY";
            get num_x() -> i32 = "NumX";
            get num_y() -> i32 = "NumY";
            set set_start_x(value: i32) = "StartX";
            set set_start_y(value: i32) = "StartY";
            set set_num_x(value: i32) = "NumX";
            set set_num_y(value: i32) = "NumY";

            get last_exposure_start_time() -> String = "LastExposureStartTime";
            get last_exposure_duration() -> f64 = "LastExposureDuration";

            get can_abort_exposure() -> bool = "CanAbortExposure";
            get can_stop_exposure() -> bool = "CanStopExposure";
            get can_asymmetric_bin() -> bool = "CanAsymmetricBin";
            get can_pulse_guide() -> bool = "CanPulseGuide";
            get can_fast_readout() -> bool = "CanFastReadout";
            get has_shutter() -> bool = "HasShutter";
        }
    };
}
