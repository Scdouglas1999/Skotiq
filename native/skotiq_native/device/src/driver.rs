//! The per-device-type driver traits.
//!
//! One connected device is one value behind one of these traits, whichever
//! protocol reaches it (vendor SDK, serial, ASCOM COM, Alpaca, INDI, simulator).
//!
//! The camera, mount, focuser and filter wheel traits take `&mut self` for
//! commands because the vendor drivers keep state between calls.
//!
//! The accessory traits (dome, rotator, switch, weather, safety monitor, cover
//! calibrator) take `&self` throughout: every backend behind them (Alpaca,
//! INDI, the ASCOM wrappers, the simulator) is a client of something that
//! keeps the state elsewhere, so one value is shared by every caller.

use crate::ascom::{CalibratorStatus, CoverStatus, ShutterStatus};
use crate::camera::*;
use crate::error::DriverError;
use crate::mount::*;
use crate::vendor::Vendor;
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use std::fmt::Debug;

/// Common interface for all native devices
#[async_trait]
pub trait DeviceDriver: Send + Sync + Debug {
    fn id(&self) -> &str;

    /// Get the device name/model
    fn name(&self) -> &str;

    fn vendor(&self) -> Vendor;

    /// Hardware serial number, when the vendor SDK exposes one for THIS unit.
    ///
    /// This is the only thing a vendor SDK offers that survives a replug: every
    /// `native:{vendor}:{n}` id is an enumeration index, so `n` re-binds to a
    /// different physical device whenever USB re-orders. A serial is what lets
    /// the app notice that.
    ///
    /// Defaults to `None`, and returning `None` is a legitimate answer — plenty
    /// of hardware genuinely has no readable serial (the ASI1600MM-Cool on the
    /// reference rig answers `ASI_ERROR_GENERAL_ERROR` to `ASIGetSerialNumber`
    /// while the ASI178MM beside it returns one). Callers must therefore treat
    /// a serial as a bonus discriminator and fall back to the model/geometry
    /// fingerprint. Never synthesise a stand-in value here: a fabricated serial
    /// is worse than an absent one, because identity checks trust it.
    fn serial_number(&self) -> Option<String> {
        None
    }

    fn is_connected(&self) -> bool;

    async fn connect(&mut self) -> Result<(), DriverError>;

    async fn disconnect(&mut self) -> Result<(), DriverError>;
}

/// A camera driver's way to give up the frame read in flight, used from
/// outside the call that is running it.
///
/// [`CameraDriver::download_image`] takes `&mut self`, so while it runs nobody
/// can call [`CameraDriver::abort_exposure`]. A driver whose read is a loop of
/// short SDK calls (waiting for the frame, grabbing it row by row) hands one
/// of these out; after `request` the read ends at its next step with an
/// error and leaves the camera ready for `abort_exposure`.
pub trait ExposureAbort: Send + Sync {
    /// Returns at once: it sets what the read checks between SDK calls, or
    /// makes the one SDK call the vendor documents as safe beside a read.
    fn request(&self);
}

/// Native camera device interface
///
/// This trait provides all camera operations that native drivers must implement.
/// Similar to NINA's ICameraDevice interface.
///
/// `heartbeat`, `report` and `describe` are whole operations with a default
/// body made of the single calls. A protocol that answers them with its own
/// set of requests (Alpaca, INDI) overrides them; such a driver is a client of
/// a server that keeps the state, cheap to clone, and every clone is the same
/// camera.
#[async_trait]
pub trait CameraDriver: DeviceDriver {
    /// Whether automatic recovery may release or replace this driver.
    /// A camera holding the only copy of a failed download can require the
    /// owner to retrieve it first. Check before teardown, even after a lost
    /// connection. An explicit disconnect after retrieval clears the old
    /// driver so a subsequent connect can open a fresh one.
    fn check_automatic_reconnect(&self) -> Result<(), DriverError> {
        Ok(())
    }

    /// What the driver keeps of the camera's abilities from its connect. A
    /// client of a server keeps nothing and answers through
    /// [`CameraDriver::describe`] and [`CameraDriver::report`].
    fn capabilities(&self) -> CameraCapabilities;

    /// What the camera can do and how its sensor is built, in one
    /// operation. A range or list the camera does not publish is absent.
    async fn describe(&self) -> CameraDescription {
        CameraDescription {
            capabilities: self.capabilities(),
            sensor: self.get_sensor_info(),
            gain_range: self.get_gain_range().await.ok(),
            offset_range: self.get_offset_range().await.ok(),
            iso_speeds: self.get_iso_speeds().await.unwrap_or_default(),
            readout_modes: self.get_readout_modes().await.unwrap_or_default(),
            cooler_temp_range: self.get_cooler_temp_range().await.ok().flatten(),
            exposure_range: self.get_exposure_range().await.ok().flatten(),
            can_abort_exposure: true,
            can_stop_exposure: false,
            can_asymmetric_bin: false,
            sensor_type: None,
        }
    }

    /// Whether the camera still answers. `Ok(false)`: it says it is not
    /// connected. `Err`: the probe failed.
    ///
    /// The default reads the status, because every camera answers it; a
    /// body without a thermometer (every DSLR and mirrorless camera)
    /// answers a temperature read "not supported".
    async fn heartbeat(&self) -> Result<bool, DriverError> {
        if !self.is_connected() {
            return Ok(false);
        }
        self.get_status().await.map(|_| true)
    }

    /// Everything a status poll shows, in one operation.
    async fn report(&self) -> Result<CameraReport, DriverError> {
        let status = self.get_status().await?;
        let capabilities = self.capabilities();
        Ok(CameraReport {
            status,
            sensor: self.get_sensor_info(),
            can_cool: capabilities.can_cool,
            can_set_gain: capabilities.can_set_gain,
            can_set_offset: capabilities.can_set_offset,
        })
    }

    /// See [`ExposureAbort`]. `None` for a driver whose frame read is a
    /// single SDK call: an abort then reaches the camera when that call
    /// returns.
    fn exposure_abort(&self) -> Option<std::sync::Arc<dyn ExposureAbort>> {
        None
    }

    async fn get_status(&self) -> Result<CameraStatus, DriverError>;

    async fn start_exposure(&mut self, params: ExposureParams) -> Result<(), DriverError>;

    async fn abort_exposure(&mut self) -> Result<(), DriverError>;

    async fn is_exposure_complete(&self) -> Result<bool, DriverError>;

    async fn download_image(&mut self) -> Result<ImageData, DriverError>;

    /// Set cooler state and, optionally, the target temperature.
    ///
    /// `target_temp == None` means *the caller did not name a setpoint* —
    /// implementations must leave the driver's existing setpoint alone rather
    /// than substituting one. Turning a cooler off needs no setpoint at all, and
    /// inventing one both pushes a temperature the operator never asked for and
    /// fails outright on cameras that reject a set-temperature write.
    async fn set_cooler(
        &mut self,
        enabled: bool,
        target_temp: Option<f64>,
    ) -> Result<(), DriverError>;

    async fn get_temperature(&self) -> Result<f64, DriverError>;

    /// Get cooler power percentage
    async fn get_cooler_power(&self) -> Result<f64, DriverError>;

    async fn set_gain(&mut self, gain: i32) -> Result<(), DriverError>;

    async fn get_gain(&self) -> Result<i32, DriverError>;

    async fn set_offset(&mut self, offset: i32) -> Result<(), DriverError>;

    async fn get_offset(&self) -> Result<i32, DriverError>;

    async fn set_binning(&mut self, bin_x: i32, bin_y: i32) -> Result<(), DriverError>;

    async fn get_binning(&self) -> Result<(i32, i32), DriverError>;

    async fn set_subframe(&mut self, subframe: Option<SubFrame>) -> Result<(), DriverError>;

    /// The sensor as the driver keeps it from its connect; see
    /// [`CameraDriver::capabilities`].
    fn get_sensor_info(&self) -> SensorInfo;

    /// Get available readout modes (vendor-specific)
    async fn get_readout_modes(&self) -> Result<Vec<ReadoutMode>, DriverError>;

    /// Set readout mode (vendor-specific)
    async fn set_readout_mode(&mut self, mode: &ReadoutMode) -> Result<(), DriverError>;

    /// Get vendor-specific features (e.g., QHY sensor chamber readings)
    async fn get_vendor_features(&self) -> Result<VendorFeatures, DriverError>;

    /// Get the valid range for gain setting.
    ///
    /// Returns (min_gain, max_gain) tuple.
    /// If the camera does not support gain adjustment, returns Err(NotSupported).
    async fn get_gain_range(&self) -> Result<(i32, i32), DriverError>;

    /// The ISO speeds a DSLR or mirrorless body offers, lowest first: the
    /// camera's own list including the extended speeds it offers, without
    /// Auto ISO. Empty for a camera whose sensitivity is a gain number.
    ///
    /// A camera that lists ISO speeds takes and reports its gain as the ISO
    /// number itself (ASCOM's "gain value" mode, as the owner's FujiCOM driver
    /// settled on), so `GAIN` means ISO for every DSLR frame whatever the
    /// body's list, and [`Self::get_gain_range`] is the lowest and highest
    /// speed.
    async fn get_iso_speeds(&self) -> Result<Vec<i32>, DriverError> {
        Ok(Vec::new())
    }

    /// What the driver found and did about the body's long exposure noise
    /// reduction when it connected.
    fn long_exposure_noise_reduction(&self) -> LongExposureNoiseReduction {
        LongExposureNoiseReduction::NotApplicable
    }

    /// Get the valid range for offset/black level setting.
    ///
    /// Returns (min_offset, max_offset) tuple.
    /// If the camera does not support offset adjustment, returns Err(NotSupported).
    async fn get_offset_range(&self) -> Result<(i32, i32), DriverError>;

    /// Query the camera SDK for manufacturer-recommended gain/offset values.
    ///
    /// Returns a [`CameraRecommendedSettings`] populated with whatever the
    /// vendor SDK actually exposes:
    /// - `unity_gain`: gain value where the sensor reads 1 e-/ADU, if the SDK
    ///   reports it (ZWO publishes the default gain control caps, QHY exposes
    ///   `DefaultGain` as a dedicated control ID, SVBony provides control
    ///   default values).
    /// - `hcg_gain`: high-conversion-gain transition point, if exposed.
    /// - `default_offset`: manufacturer-recommended offset.
    ///
    /// The default implementation returns an empty
    /// [`CameraRecommendedSettings`] (all fields `None`) — this is the honest
    /// answer for vendors whose SDK does not expose these values. Drivers that
    /// CAN query them override this method.
    ///
    /// # Errors
    ///
    /// Returns `Err` only when the SDK call genuinely failed (e.g. camera
    /// disconnected mid-query). A camera that doesn't expose any recommended
    /// settings should return `Ok` with an empty struct — never fabricate a
    /// value.
    async fn get_recommended_settings(&self) -> Result<CameraRecommendedSettings, DriverError> {
        Ok(CameraRecommendedSettings::default())
    }

    /// Query the regulated-cooling temperature range the sensor's TEC can
    /// achieve, as `(min_temp_c, max_temp_c)`.
    ///
    /// `Ok(Some((min, max)))` only when the vendor SDK publishes the achievable
    /// setpoint range — ZWO exposes the `ASI_TARGET_TEMP` control's min/max caps
    /// and overrides this default. `Ok(None)` for the many cameras that report
    /// cooling support but no achievable range, so the UI shows the setpoint
    /// field unclamped. `Err` is reserved for a genuine SDK failure such as a
    /// disconnect mid-query.
    async fn get_cooler_temp_range(&self) -> Result<Option<(f64, f64)>, DriverError> {
        Ok(None)
    }

    /// Shortest and longest exposure the sensor accepts, in SECONDS.
    ///
    /// Same contract as [`Self::get_cooler_temp_range`]: `Ok(None)` when the
    /// driver does not publish a range, `Err` only on a genuine SDK failure. The
    /// ZWO SDK reports it via `ASIGetControlCaps` for `ASI_EXPOSURE`. With the
    /// range absent, `CameraCapabilities.exposure_min`/`exposure_max` are null
    /// and no client can reject an out-of-range exposure before submitting it —
    /// the request then fails late inside the SDK instead of up front, naming
    /// the limit it violated.
    ///
    /// Implementations MUST convert from their SDK's native unit (ZWO reports
    /// microseconds) and MUST NOT narrow through `i32` on the way — a 2000 s
    /// maximum is 2_000_000_000 µs, within a hair of `i32::MAX` and an outright
    /// overflow for cameras that allow longer.
    async fn get_exposure_range(&self) -> Result<Option<(f64, f64)>, DriverError> {
        Ok(None)
    }

    /// Capture a live-view / preview frame as JPEG bytes when the driver supports it.
    async fn capture_preview(&self) -> Result<Vec<u8>, DriverError> {
        Err(DriverError::NotSupported)
    }
}

/// A mount.
///
/// The methods are of two sorts. The first are single exchanges with the
/// mount (a goto, a coordinate read). The second are whole operations
/// (`status`, `heartbeat`, `site_abilities`, `can_park`) with a default body
/// made of the first sort, in the order a serial mount is asked. A protocol
/// that answers an operation with its own set of requests (Alpaca, INDI)
/// overrides it.
///
/// Commands take `&mut self` because a serial driver keeps state between
/// calls. A client of a server that keeps the state (Alpaca, INDI)
/// implements the trait on a value that is cheap to clone, and every clone
/// is the same mount.
#[async_trait]
pub trait MountDriver: DeviceDriver {
    /// Whether the mount still answers. `Ok(false)`: it says it is not
    /// connected. `Err`: the probe failed.
    ///
    /// The default reads the coordinates, which always crosses the wire: a
    /// serial driver answers some states from memory, and a mount that had
    /// gone silent would still pass.
    async fn heartbeat(&self) -> Result<bool, DriverError> {
        if !self.is_connected() {
            return Ok(false);
        }
        self.get_coordinates().await.map(|_| true)
    }

    /// Starts a goto (RA in hours, Dec in degrees) and returns once the
    /// mount has taken the command.
    async fn slew_to_coordinates(
        &mut self,
        ra_hours: f64,
        dec_degrees: f64,
    ) -> Result<(), DriverError>;

    /// Starts a goto to an altitude and azimuth in degrees.
    async fn slew_to_alt_az(
        &mut self,
        _altitude_deg: f64,
        _azimuth_deg: f64,
    ) -> Result<(), DriverError> {
        Err(DriverError::NotSupported)
    }

    async fn get_coordinates(&self) -> Result<(f64, f64), DriverError>;

    async fn sync_to_coordinates(
        &mut self,
        ra_hours: f64,
        dec_degrees: f64,
    ) -> Result<(), DriverError>;

    async fn park(&mut self) -> Result<(), DriverError>;

    async fn unpark(&mut self) -> Result<(), DriverError>;

    async fn is_slewing(&self) -> Result<bool, DriverError>;

    async fn is_parked(&self) -> Result<bool, DriverError>;

    /// Whether the mount can park. The default asks for the park state: a
    /// protocol without one answers `NotSupported`.
    async fn can_park(&self) -> Result<bool, DriverError> {
        match self.is_parked().await {
            Ok(_) => Ok(true),
            Err(DriverError::NotSupported) => Ok(false),
            Err(e) => Err(e),
        }
    }

    /// Sends a guide pulse and returns when it is over.
    async fn pulse_guide(
        &mut self,
        direction: GuideDirection,
        duration_ms: u32,
    ) -> Result<(), DriverError>;

    /// Stops a goto.
    async fn abort_slew(&mut self) -> Result<(), DriverError>;

    /// Moves an axis (0: RA or azimuth, 1: Dec or altitude) at `rate`
    /// degrees per second until it is sent rate 0.
    async fn move_axis(&mut self, _axis: i32, _rate: f64) -> Result<(), DriverError> {
        Err(DriverError::NotSupported)
    }

    async fn set_tracking(&mut self, enabled: bool) -> Result<(), DriverError>;

    async fn get_tracking(&self) -> Result<bool, DriverError>;

    /// Takes any rate [`MountDriver::tracking_rates`] lists.
    async fn set_tracking_rate(&mut self, rate: TrackingRate) -> Result<(), DriverError>;

    async fn get_tracking_rate(&self) -> Result<TrackingRate, DriverError>;

    /// The rates the mount can be set to track at; empty when its rate
    /// cannot be set.
    async fn tracking_rates(&self) -> Vec<TrackingRate> {
        Vec::new()
    }

    async fn can_slew(&self) -> bool;

    async fn can_sync(&self) -> bool;

    async fn can_pulse_guide(&self) -> bool;

    async fn get_side_of_pier(&self) -> Result<PierSide, DriverError>;

    async fn get_alt_az(&self) -> Result<(f64, f64), DriverError>;

    /// Get local sidereal time
    async fn get_sidereal_time(&self) -> Result<f64, DriverError>;

    /// Everything a status poll shows, in one operation.
    ///
    /// The coordinates, tracking and slewing are required: a failure of one
    /// fails the read. A park state the protocol does not have is `None`;
    /// any other failure of it fails the read. The rest are optional.
    async fn status(&self) -> Result<MountReadings, DriverError> {
        let (right_ascension, declination) = self.get_coordinates().await?;
        let tracking = self.get_tracking().await?;
        let slewing = self.is_slewing().await?;
        let parked = match self.is_parked().await {
            Ok(parked) => Some(parked),
            Err(DriverError::NotSupported) => None,
            Err(e) => return Err(e),
        };
        let side_of_pier = self.get_side_of_pier().await;
        let (altitude, azimuth) = match self.get_alt_az().await {
            Ok((altitude, azimuth)) => (Ok(altitude), Ok(azimuth)),
            Err(e) => {
                let again = match &e {
                    DriverError::NotSupported => DriverError::NotSupported,
                    other => DriverError::Backend(other.to_string().into()),
                };
                (Err(e), Err(again))
            }
        };
        let sidereal_time = self.get_sidereal_time().await;
        let at_home = self.at_home().await;
        let tracking_rate = self.get_tracking_rate().await;
        Ok(MountReadings {
            right_ascension,
            declination,
            tracking,
            slewing,
            parked,
            at_home,
            side_of_pier,
            altitude,
            azimuth,
            sidereal_time,
            tracking_rate,
            can_park: parked.is_some(),
            can_slew: self.can_slew().await,
            can_sync: self.can_sync().await,
            can_pulse_guide: self.can_pulse_guide().await,
            can_set_tracking_rate: !self.tracking_rates().await.is_empty(),
        })
    }

    /// What the mount can do, in one operation. The default asks the single
    /// questions a serial mount answers: whether it can park is whether it
    /// reports a park state, whether tracking can be switched is whether it
    /// reports tracking, and whether a goto can be stopped is whether it
    /// reports slewing.
    async fn describe(&self) -> MountDescription {
        let can_park = self.can_park().await.unwrap_or(false);
        let can_slew = self.can_slew().await;
        MountDescription {
            can_slew,
            can_slew_async: can_slew,
            can_sync: self.can_sync().await,
            can_park,
            can_unpark: can_park,
            can_set_park: self.can_set_park().await.unwrap_or(false),
            can_find_home: self.can_find_home().await.unwrap_or(false),
            can_pulse_guide: self.can_pulse_guide().await,
            can_set_tracking: self.get_tracking().await.is_ok(),
            tracking_rates: self.tracking_rates().await,
            can_abort_slew: self.is_slewing().await.is_ok(),
            is_equatorial: true,
            axis_count: 2,
            ..MountDescription::default()
        }
    }

    /// Read the site the mount is configured for.
    ///
    /// Defaults to `NotSupported`. A mount whose site cannot be read must say
    /// so: a fabricated site would be compared against the computer's and
    /// silently "agree".
    async fn get_site(&self) -> Result<MountSiteInfo, DriverError> {
        Err(DriverError::NotSupported)
    }

    /// Write the site into the mount.
    async fn set_site(&mut self, _site: MountSiteInfo) -> Result<(), DriverError> {
        Err(DriverError::NotSupported)
    }

    /// Read the mount's clock and UTC offset.
    async fn get_clock(&self) -> Result<MountClock, DriverError> {
        Err(DriverError::NotSupported)
    }

    /// Write the clock and UTC offset into the mount.
    async fn set_clock(&mut self, _clock: MountClock) -> Result<(), DriverError> {
        Err(DriverError::NotSupported)
    }

    /// Which of site and clock the mount can be read and written.
    ///
    /// The default probes: a serial protocol without the site commands
    /// answers `NotSupported` by not implementing them, and one that has
    /// them can write what it can read.
    async fn site_abilities(&self) -> Result<MountSiteAbilities, DriverError> {
        let can_read_site = !matches!(self.get_site().await, Err(DriverError::NotSupported));
        let can_read_time = !matches!(self.get_clock().await, Err(DriverError::NotSupported));
        Ok(MountSiteAbilities {
            can_read_site,
            can_write_site: can_read_site,
            can_read_time,
            can_write_time: can_read_time,
        })
    }

    /// Whether this mount has a home command [`MountDriver::find_home`] can
    /// send. Defaults to `false` alongside the `NotSupported` default of
    /// `find_home`, so the two can never disagree.
    async fn can_find_home(&self) -> Result<bool, DriverError> {
        Ok(false)
    }

    /// Send the mount to its mechanical home position.
    ///
    /// Defaults to `NotSupported` because most serial protocols have no home
    /// command at all. A mount that cannot home must SAY so — silently
    /// no-opping would report success while the mount never moved.
    async fn find_home(&mut self) -> Result<(), DriverError> {
        Err(DriverError::NotSupported)
    }

    /// Whether the mount is sitting at its home position.
    ///
    /// Same default and the same reason: `false` would be a fabricated
    /// answer, and the status layer distinguishes "unsupported" from "no".
    async fn at_home(&self) -> Result<bool, DriverError> {
        Err(DriverError::NotSupported)
    }

    /// Whether [`MountDriver::set_park`] can store the current position as
    /// the park position. Defaults to `false` alongside the `NotSupported`
    /// default of `set_park`.
    async fn can_set_park(&self) -> Result<bool, DriverError> {
        Ok(false)
    }

    /// Store the mount's current position as its park position.
    ///
    /// Defaults to `NotSupported`: most serial protocols park at a fixed or
    /// hand-controller-configured pose and have no command to move it.
    async fn set_park(&mut self) -> Result<(), DriverError> {
        Err(DriverError::NotSupported)
    }
}

/// Native focuser device interface
#[async_trait]
pub trait FocuserDriver: DeviceDriver {
    /// Whether the focuser still answers. `Ok(false)`: it says it is not
    /// connected. `Err`: the probe failed.
    async fn heartbeat(&self) -> Result<bool, DriverError> {
        if !self.is_connected() {
            return Ok(false);
        }
        self.get_position().await.map(|_| true)
    }

    /// Whether the focuser takes absolute positions.
    async fn is_absolute(&self) -> bool {
        true
    }

    /// Whether the focuser's own temperature compensation is switched on;
    /// `None` for a focuser without one.
    async fn temp_comp(&self) -> Option<bool> {
        None
    }

    /// Move to absolute position
    async fn move_to(&mut self, position: i32) -> Result<(), DriverError>;

    /// Move relative by steps
    async fn move_relative(&mut self, steps: i32) -> Result<(), DriverError>;

    async fn get_position(&self) -> Result<i32, DriverError>;

    async fn is_moving(&self) -> Result<bool, DriverError>;

    /// Whether [`FocuserDriver::halt`] can stop a move under way. `false`
    /// for a focuser with no stop command, whose `halt` answers
    /// `NotSupported`.
    async fn can_halt(&self) -> bool {
        true
    }

    async fn halt(&mut self) -> Result<(), DriverError>;

    async fn get_temperature(&self) -> Result<Option<f64>, DriverError>;

    async fn get_max_position(&self) -> i32;

    async fn get_step_size(&self) -> f64;
}

/// Native filter wheel device interface
#[async_trait]
pub trait FilterWheelDriver: DeviceDriver {
    /// Whether the wheel still answers. `Ok(false)`: it says it is not
    /// connected. `Err`: the probe failed.
    async fn heartbeat(&self) -> Result<bool, DriverError> {
        if !self.is_connected() {
            return Ok(false);
        }
        self.get_position().await.map(|_| true)
    }

    /// Whether [`FilterWheelDriver::set_filter_name`] can store a name.
    async fn can_set_filter_names(&self) -> bool {
        true
    }

    /// Move to filter position (0-indexed)
    async fn move_to_position(&mut self, position: i32) -> Result<(), DriverError>;

    async fn get_position(&self) -> Result<i32, DriverError>;

    async fn is_moving(&self) -> Result<bool, DriverError>;

    async fn get_filter_count(&self) -> i32;

    async fn get_filter_names(&self) -> Result<Vec<String>, DriverError>;

    async fn set_filter_name(&mut self, position: i32, name: String) -> Result<(), DriverError>;
}

/// What every accessory driver answers besides its own operations.
#[async_trait]
pub trait AccessoryDriver: Send + Sync {
    async fn disconnect(&self) -> Result<(), DriverError>;

    /// One cheap call that fails when the device no longer answers.
    async fn heartbeat(&self) -> Result<(), DriverError>;
}

/// What a dome reports in one status read.
#[derive(Debug, Clone, PartialEq)]
pub struct DomeState {
    /// Degrees, north through east.
    pub azimuth: f64,
    /// Degrees above the horizon, for domes that report it.
    pub altitude: Option<f64>,
    /// `None` when the dome does not say.
    pub shutter: Option<ShutterStatus>,
    pub slewing: bool,
    pub at_home: bool,
    pub at_park: bool,
    pub can_set_altitude: bool,
    pub can_set_azimuth: bool,
    pub can_set_shutter: bool,
    pub can_slave: bool,
    /// Whether the dome follows the mount by itself.
    pub slaved: bool,
}

/// A dome or roll-off roof.
#[async_trait]
pub trait DomeDriver: AccessoryDriver {
    async fn open_shutter(&self) -> Result<(), DriverError>;

    async fn close_shutter(&self) -> Result<(), DriverError>;

    async fn shutter_status(&self) -> Result<ShutterStatus, DriverError>;

    /// Degrees, north through east.
    async fn slew_to_azimuth(&self, azimuth_deg: f64) -> Result<(), DriverError>;

    async fn abort_slew(&self) -> Result<(), DriverError>;

    async fn park(&self) -> Result<(), DriverError>;

    async fn find_home(&self) -> Result<(), DriverError>;

    /// Whether the dome follows the mount by itself.
    async fn set_slaved(&self, slaved: bool) -> Result<(), DriverError>;

    async fn status(&self) -> Result<DomeState, DriverError>;
}

/// A camera rotator.
#[async_trait]
pub trait RotatorDriver: AccessoryDriver {
    /// Degrees of sky position angle.
    async fn move_absolute(&self, position_deg: f64) -> Result<(), DriverError>;

    async fn position(&self) -> Result<f64, DriverError>;

    async fn is_moving(&self) -> Result<bool, DriverError>;

    async fn halt(&self) -> Result<(), DriverError>;

    /// Declares the current mechanical angle to be `position_deg` on the sky.
    async fn sync(&self, position_deg: f64) -> Result<(), DriverError>;

    async fn set_reverse(&self, reverse: bool) -> Result<(), DriverError>;
}

/// A box of switches and gauges (power ports, dew heaters, sensors).
#[async_trait]
pub trait SwitchDriver: AccessoryDriver {
    /// Number of switches; they are addressed `0..count`.
    async fn count(&self) -> Result<i32, DriverError>;

    async fn switch_name(&self, index: i32) -> Result<String, DriverError>;

    async fn switch_description(&self, index: i32) -> Result<String, DriverError>;

    async fn can_write(&self, index: i32) -> Result<bool, DriverError>;

    async fn state(&self, index: i32) -> Result<bool, DriverError>;

    async fn set_state(&self, index: i32, on: bool) -> Result<(), DriverError>;

    async fn value(&self, index: i32) -> Result<f64, DriverError>;

    async fn set_value(&self, index: i32, value: f64) -> Result<(), DriverError>;

    async fn min_value(&self, index: i32) -> Result<f64, DriverError>;

    async fn max_value(&self, index: i32) -> Result<f64, DriverError>;

    /// The smallest change of value the switch makes; a value written is a
    /// whole number of steps above `min_value`.
    async fn step(&self, index: i32) -> Result<f64, DriverError>;
}

/// What a weather station reports. A reading the station does not have is
/// `None`.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct WeatherReadings {
    /// Percent of sky covered.
    pub cloud_cover: Option<f64>,
    /// Degrees Celsius.
    pub dew_point: Option<f64>,
    /// Percent relative humidity.
    pub humidity: Option<f64>,
    /// Hectopascals at the station.
    pub pressure: Option<f64>,
    /// Millimetres per hour.
    pub rain_rate: Option<f64>,
    /// Magnitudes per square arc second.
    pub sky_quality: Option<f64>,
    /// Degrees Celsius.
    pub sky_temperature: Option<f64>,
    /// Degrees Celsius.
    pub temperature: Option<f64>,
    /// Degrees, north through east, the wind comes from.
    pub wind_direction: Option<f64>,
    /// Metres per second.
    pub wind_speed: Option<f64>,
}

#[async_trait]
pub trait WeatherDriver: AccessoryDriver {
    async fn readings(&self) -> Result<WeatherReadings, DriverError>;
}

#[async_trait]
pub trait SafetyMonitorDriver: AccessoryDriver {
    async fn is_safe(&self) -> Result<bool, DriverError>;
}

/// What a cover calibrator reports in one status read.
#[derive(Debug, Clone, PartialEq)]
pub struct CoverCalibratorState {
    pub cover: CoverStatus,
    pub calibrator: CalibratorStatus,
    pub brightness: i32,
    pub max_brightness: i32,
}

/// A dust cover, a flat panel, or both in one device.
#[async_trait]
pub trait CoverCalibratorDriver: AccessoryDriver {
    async fn open_cover(&self) -> Result<(), DriverError>;

    async fn close_cover(&self) -> Result<(), DriverError>;

    async fn halt_cover(&self) -> Result<(), DriverError>;

    async fn cover_status(&self) -> Result<CoverStatus, DriverError>;

    /// Lights the panel at `brightness`, between 0 and `max_brightness`.
    async fn calibrator_on(&self, brightness: i32) -> Result<(), DriverError>;

    async fn calibrator_off(&self) -> Result<(), DriverError>;

    async fn calibrator_status(&self) -> Result<CalibratorStatus, DriverError>;

    async fn brightness(&self) -> Result<i32, DriverError>;

    async fn max_brightness(&self) -> Result<i32, DriverError>;

    async fn status(&self) -> Result<CoverCalibratorState, DriverError>;
}
