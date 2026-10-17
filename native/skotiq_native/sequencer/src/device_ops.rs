//! Device Operations Trait
//!
//! This module defines the interface for device operations that the sequencer needs.
//! The actual implementation is provided by the bridge crate.

use async_trait::async_trait;
use std::sync::Arc;

/// Result type for device operations
pub type DeviceResult<T> = Result<T, String>;

/// Error text every guider op returns when the rig simply has no guider.
///
/// The bridge produces this from `ok_or_else` on the "which guider is active?"
/// lookup, so it means "nothing to do", not "the operation failed". Callers that
/// escalate device errors to the operator must special-case it: a rig imaging
/// unguided is a normal configuration, and reporting it as a failure buries the
/// real problem under noise.
pub const NO_GUIDER_CONFIGURED: &str = "No active guider configured";

/// Whether [`DeviceResult`] error text is the benign "this rig has no guider"
/// marker rather than a real guider failure.
pub fn is_no_guider_configured(error: &str) -> bool {
    error.contains(NO_GUIDER_CONFIGURED)
}

/// Image data returned from camera
#[derive(Debug, Clone)]
pub struct ImageData {
    pub width: u32,
    pub height: u32,
    pub data: Vec<u16>,
    pub bits_per_pixel: u32,
    pub exposure_secs: f64,
    pub gain: Option<i32>,
    pub offset: Option<i32>,
    pub temperature: Option<f64>,
    pub filter: Option<String>,
    pub timestamp: i64,
    /// Sensor type: "Monochrome" or "Color"
    pub sensor_type: Option<String>,
    /// Bayer pattern offset (X, Y) - determines actual pattern based on offsets
    pub bayer_offset: Option<(i32, i32)>,
}

/// Binned-pixel camera ROI used for one exposure.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CameraSubframe {
    pub start_x: u32,
    pub start_y: u32,
    pub width: u32,
    pub height: u32,
}

/// Plate solve result
#[derive(Debug, Clone)]
pub struct PlateSolveResult {
    pub ra_degrees: f64,
    pub dec_degrees: f64,
    pub pixel_scale: f64,
    pub rotation: f64,
    pub success: bool,
}

/// Guiding status
#[derive(Debug, Clone)]
pub struct GuidingStatus {
    pub is_guiding: bool,
    pub rms_ra: f64,
    pub rms_dec: f64,
    pub rms_total: f64,
}

/// Guiding calibration snapshot, surfaced for post-start quality checks.
///
/// Both axis angles are in degrees and may be `None` if the underlying
/// driver does not expose them (the older Alpaca-only path, for example).
/// When present, the absolute difference between them should sit close to
/// 90° on a well-calibrated mount; the executor uses this to catch silent
/// "looks calibrated but axes are wrong" failures (P3-7).
#[derive(Debug, Clone)]
pub struct GuidingCalibration {
    pub is_calibrated: bool,
    pub ra_angle_deg: Option<f64>,
    pub dec_angle_deg: Option<f64>,
}

/// Trait defining all device operations needed by the sequencer
///
/// This trait is implemented by the bridge to provide actual device control.
/// The sequencer calls these methods without knowing the implementation details.
#[async_trait]
pub trait DeviceOps: Send + Sync {
    // Mount operations

    /// Slew mount to coordinates (RA in hours, Dec in degrees)
    async fn mount_slew_to_coordinates(
        &self,
        mount_id: &str,
        ra_hours: f64,
        dec_degrees: f64,
    ) -> DeviceResult<()>;

    /// Abort mount slew
    async fn mount_abort_slew(&self, mount_id: &str) -> DeviceResult<()>;

    /// Get current mount coordinates (returns RA hours, Dec degrees)
    async fn mount_get_coordinates(&self, mount_id: &str) -> DeviceResult<(f64, f64)>;

    /// Express a J2000 target in the SAME frame [`mount_get_coordinates`]
    /// reports for this mount, so a commanded position can be compared against
    /// a read-back one.
    ///
    /// The two are not interchangeable. Catalogue and plate-solve coordinates
    /// are J2000, but real mounts want coordinates of date, so the device layer
    /// precesses everything it SENDS (slew, sync) and deliberately leaves
    /// everything it READS in the mount's own frame — the hour-angle maths
    /// depends on of-date RA. In 2026 those frames are ~22' apart, which is far
    /// outside any sane slew tolerance, so comparing one to the other reports a
    /// perfectly good slew as a miss.
    ///
    /// Identity by default: the test doubles store exactly what they are given.
    /// The real device layer overrides it, and so does the simulator behind
    /// it, which is an of-date mount too (`epoch::SimMountFrame` in the bridge).
    async fn mount_readback_frame(
        &self,
        _mount_id: &str,
        ra_hours: f64,
        dec_degrees: f64,
    ) -> DeviceResult<(f64, f64)> {
        Ok((ra_hours, dec_degrees))
    }

    /// The inverse of [`Self::mount_readback_frame`]: express a position this
    /// mount READ BACK in J2000, for anything that records or compares it as a
    /// catalogue coordinate — the FITS `RA`/`DEC` cards and the
    /// `captured_images` pointing columns, which stackers, solvers and the
    /// Library all read as J2000.
    ///
    /// Hour-angle and altitude maths want the of-date read-back itself; convert
    /// only what is stored or matched against catalogues. Identity by default.
    async fn mount_readback_to_j2000(
        &self,
        _mount_id: &str,
        ra_hours: f64,
        dec_degrees: f64,
    ) -> DeviceResult<(f64, f64)> {
        Ok((ra_hours, dec_degrees))
    }

    /// Sync mount to coordinates
    async fn mount_sync(&self, mount_id: &str, ra_hours: f64, dec_degrees: f64)
        -> DeviceResult<()>;

    /// Park the mount
    async fn mount_park(&self, mount_id: &str) -> DeviceResult<()>;

    /// Unpark the mount
    async fn mount_unpark(&self, mount_id: &str) -> DeviceResult<()>;

    /// Check if mount is slewing
    async fn mount_is_slewing(&self, mount_id: &str) -> DeviceResult<bool>;

    /// Check if mount is parked
    async fn mount_is_parked(&self, mount_id: &str) -> DeviceResult<bool>;

    /// Check if mount can perform a meridian flip
    /// Returns true if mount supports flipping, false otherwise
    async fn mount_can_flip(&self, mount_id: &str) -> DeviceResult<bool>;

    /// Get the side of the pier the mount is currently on
    async fn mount_side_of_pier(&self, mount_id: &str) -> DeviceResult<crate::meridian::PierSide>;

    /// Get tracking status
    async fn mount_is_tracking(&self, mount_id: &str) -> DeviceResult<bool>;

    /// Set tracking on/off
    async fn mount_set_tracking(&self, mount_id: &str, enabled: bool) -> DeviceResult<()>;

    // Camera operations

    /// Start an exposure and return the image data
    async fn camera_start_exposure(
        &self,
        camera_id: &str,
        duration_secs: f64,
        gain: Option<i32>,
        offset: Option<i32>,
        bin_x: i32,
        bin_y: i32,
    ) -> DeviceResult<ImageData>;

    /// Start an exposure of a specific frame type and return the image data.
    ///
    /// `frame_type` is the sequencer's frame-type string ("Light"/"Dark"/"Flat"/
    /// "Bias"/"DarkFlat", case-insensitive). It drives mechanical-shutter behavior
    /// for dark/bias frames on cameras with a shutter (Moravian, FLI, some CCDs):
    /// dark/bias must be exposed with the shutter CLOSED to exclude light.
    ///
    /// The default delegates to `camera_start_exposure`, treating every frame as
    /// shutter-open — so implementations that don't drive shuttered hardware (test
    /// doubles, simulators, the guider) need not override it.
    // Wide by design: this is the compatibility rung above `camera_start_exposure`
    // (itself 7 params), so it must mirror that signature plus `frame_type` for the
    // default delegation to work. Bundling into a params struct here would force the
    // whole three-method ladder and every implementor/caller to change with no
    // clarity gained.
    #[allow(clippy::too_many_arguments)]
    async fn camera_start_exposure_with_frame_type(
        &self,
        camera_id: &str,
        duration_secs: f64,
        gain: Option<i32>,
        offset: Option<i32>,
        bin_x: i32,
        bin_y: i32,
        frame_type: &str,
    ) -> DeviceResult<ImageData> {
        let _ = frame_type;
        self.camera_start_exposure(camera_id, duration_secs, gain, offset, bin_x, bin_y)
            .await
    }

    /// Start an exposure with the complete per-frame acquisition contract.
    ///
    /// The default keeps existing implementations source-compatible while
    /// failing closed if a caller asks an implementation that has not opted
    /// into ROI support to crop a frame.
    // Wide by design: top rung of the same compatibility ladder, so it carries the
    // full per-frame acquisition contract and delegates down by forwarding each
    // parameter unchanged. See the note on `camera_start_exposure_with_frame_type`.
    #[allow(clippy::too_many_arguments)]
    async fn camera_start_exposure_configured(
        &self,
        camera_id: &str,
        duration_secs: f64,
        gain: Option<i32>,
        offset: Option<i32>,
        bin_x: i32,
        bin_y: i32,
        subframe: Option<CameraSubframe>,
        frame_type: &str,
    ) -> DeviceResult<ImageData> {
        if subframe.is_some() {
            return Err("Camera subframes are not supported by this device backend".to_string());
        }
        self.camera_start_exposure_with_frame_type(
            camera_id,
            duration_secs,
            gain,
            offset,
            bin_x,
            bin_y,
            frame_type,
        )
        .await
    }

    /// Abort current exposure
    async fn camera_abort_exposure(&self, camera_id: &str) -> DeviceResult<()>;

    /// Set cooler state and target temperature
    async fn camera_set_cooler(
        &self,
        camera_id: &str,
        enabled: bool,
        target_temp: f64,
    ) -> DeviceResult<()>;

    /// Get current sensor temperature
    async fn camera_get_temperature(&self, camera_id: &str) -> DeviceResult<f64>;

    /// Get cooler power percentage
    async fn camera_get_cooler_power(&self, camera_id: &str) -> DeviceResult<f64>;

    /// The camera's UNBINNED pixel pitch in microns, as `(x, y)`.
    ///
    /// `Ok(None)` means the driver does not report one, and the FITS writer
    /// then omits `XPIXSZ`/`YPIXSZ` rather than guessing. Defaulted so a
    /// `DeviceOps` that has no camera (test doubles, the null ops) does not
    /// have to answer; the bridge implementations override it.
    async fn camera_get_pixel_size_um(&self, _camera_id: &str) -> DeviceResult<Option<(f64, f64)>> {
        Ok(None)
    }

    /// How the app knows this camera — the driver-reported name, with whatever
    /// serial or unique id it has to tell two identical models apart.
    ///
    /// Fills FITS `INSTRUME` when no equipment profile names a camera. Without
    /// it a sequenced frame says nothing at all about which camera took it,
    /// and on a two-camera rig the sensor geometry is the only clue — so the
    /// keyword every stacker and archive groups by is the one keyword absent.
    /// This is the driver's answer, not a profile the operator has to have
    /// remembered to fill in.
    ///
    /// `Ok(None)` means the id is not a connected camera or has no name worth
    /// recording, and the writer then omits `INSTRUME` rather than inventing
    /// one. Defaulted so test doubles and the null ops need not answer.
    async fn camera_get_model(&self, _camera_id: &str) -> DeviceResult<Option<String>> {
        Ok(None)
    }

    // Focuser operations

    /// Move focuser to absolute position
    async fn focuser_move_to(&self, focuser_id: &str, position: i32) -> DeviceResult<()>;

    /// Get current focuser position
    async fn focuser_get_position(&self, focuser_id: &str) -> DeviceResult<i32>;

    /// Check if focuser is moving
    async fn focuser_is_moving(&self, focuser_id: &str) -> DeviceResult<bool>;

    /// Get focuser temperature (if available)
    async fn focuser_get_temperature(&self, focuser_id: &str) -> DeviceResult<Option<f64>>;

    /// Halt focuser movement
    async fn focuser_halt(&self, focuser_id: &str) -> DeviceResult<()>;

    // Filter wheel operations

    /// Set filter wheel position by index (1-based)
    async fn filterwheel_set_position(&self, fw_id: &str, position: i32) -> DeviceResult<()>;

    /// Get current filter wheel position
    async fn filterwheel_get_position(&self, fw_id: &str) -> DeviceResult<i32>;

    /// Get filter names
    async fn filterwheel_get_names(&self, fw_id: &str) -> DeviceResult<Vec<String>>;

    /// Set filter by name (returns position used)
    async fn filterwheel_set_filter_by_name(&self, fw_id: &str, name: &str) -> DeviceResult<i32>;

    // Rotator operations

    /// Move rotator to angle (degrees)
    async fn rotator_move_to(&self, rotator_id: &str, angle: f64) -> DeviceResult<()>;

    /// Move rotator by relative amount
    async fn rotator_move_relative(&self, rotator_id: &str, delta: f64) -> DeviceResult<()>;

    /// Get current rotator angle
    async fn rotator_get_angle(&self, rotator_id: &str) -> DeviceResult<f64>;

    /// Halt rotator movement
    async fn rotator_halt(&self, rotator_id: &str) -> DeviceResult<()>;

    // Guiding / PHD2 operations

    /// Start dithering
    async fn guider_dither(
        &self,
        pixels: f64,
        settle_pixels: f64,
        settle_time: f64,
        settle_timeout: f64,
        ra_only: bool,
    ) -> DeviceResult<()>;

    /// Get guiding status
    async fn guider_get_status(&self) -> DeviceResult<GuidingStatus>;

    /// Get calibration data for the active guider. Returns Err if the driver
    /// cannot report calibration (older Alpaca, etc.) — callers should treat
    /// that as "validation unavailable", not as a calibration failure.
    async fn guider_get_calibration(&self) -> DeviceResult<GuidingCalibration> {
        Err("guider_get_calibration not supported by this driver".to_string())
    }

    /// Start guiding
    async fn guider_start(
        &self,
        settle_pixels: f64,
        settle_time: f64,
        settle_timeout: f64,
    ) -> DeviceResult<()>;

    /// Make the guider drop the star it had and pick one afresh from a new
    /// frame. Called before every start of guiding the run makes, because the
    /// field may have changed since the guider last selected a star; an Err
    /// means no star was found. A guider that selects its own star on every
    /// start keeps this default.
    async fn guider_select_fresh_star(&self) -> DeviceResult<()> {
        Ok(())
    }

    /// Stop guiding
    async fn guider_stop(&self) -> DeviceResult<()>;

    // Plate solving

    /// Plate solve an image
    async fn plate_solve(
        &self,
        image_data: &ImageData,
        hint_ra: Option<f64>,
        hint_dec: Option<f64>,
        hint_scale: Option<f64>,
    ) -> DeviceResult<PlateSolveResult>;

    // Image saving

    /// Save image as FITS file.
    ///
    /// Image Grading: the per-frame metadata bundle is the
    /// [`FrameContext`](crate::scheduling::FrameContext) carried from
    /// `expose.rs`. It supersedes the previous 4-field call signature
    /// (target_name, filter, RA, Dec) — the FITS writer extracts every
    /// relevant keyword (target identification, plate-solve coords,
    /// telemetry, mosaic panel, observer/site info, equipment ID) from
    /// the context. See `bridge/src/api/imaging.rs::api_save_fits_file`
    /// for the keyword list.
    async fn save_fits(
        &self,
        image_data: &ImageData,
        file_path: &str,
        frame_ctx: &crate::scheduling::FrameContext,
    ) -> DeviceResult<()>;

    // Notifications

    /// Send a notification.
    ///
    /// `explicit_transports`, when `Some`, carries
    /// per-NotificationNode override transport names (NotificationTransportKind
    /// from the Dart side, serialised as strings). Bridge implementations emit
    /// this field on the user-visible event so `NotificationRouter` can route
    /// to the user-picked transports instead of the matrix's `custom` rule.
    async fn send_notification(
        &self,
        level: &str,
        title: &str,
        message: &str,
        explicit_transports: Option<&[String]>,
    ) -> DeviceResult<()>;

    // Utility

    /// Query whether a specific device id is currently connected.
    ///
    /// The sequencer recovery loop uses this after a device-disconnect
    /// failure to wait for the bridge/device-manager reconnect path before
    /// resuming the failed instruction.
    async fn device_is_connected(&self, device_id: &str) -> DeviceResult<bool> {
        let _ = device_id;
        Err("device_is_connected not supported by this driver".to_string())
    }

    /// Actively (re)connect a device by id.
    ///
    /// The recovery loop calls this on a device-disconnect cause so it
    /// initiates a reconnect rather than only polling `device_is_connected`.
    /// Camera/focuser/filter-wheel default to `auto_reconnect = false`, so the
    /// background reconnection loop never retries them — without an active
    /// connect the recovery budget would be burned reporting "still
    /// disconnected". Default impl is a no-op error so drivers that do not
    /// support reconnection fall back to passive polling.
    async fn connect_device(&self, device_id: &str) -> DeviceResult<()> {
        let _ = device_id;
        Err("connect_device not supported by this driver".to_string())
    }

    /// Calculate current altitude of a target (returns degrees)
    fn calculate_altitude(&self, ra_hours: f64, dec_degrees: f64, lat: f64, lon: f64) -> f64;

    /// Get observer location
    fn get_observer_location(&self) -> Option<(f64, f64)>;

    // Polar alignment

    /// Send polar alignment update
    async fn polar_align_update(
        &self,
        result: &crate::polar_align::PolarAlignResult,
    ) -> DeviceResult<()>;

    // Dome operations

    /// Device id of the dome to command when the sequencer's execution context
    /// carries no dome role assignment.
    ///
    /// The executor's dome/cover-calibrator role slots are filled only by
    /// `SequenceExecutor::set_dome` / `set_cover_calibrator`, and the Dart
    /// runtime-config path never calls them — its `sequencerSetDevices` contract
    /// carries camera, mount, focuser, filter wheel and rotator only. The device
    /// layer is the only component that knows what is actually connected, so it
    /// answers the question, on the same "resolve the active device for me"
    /// contract `safety_is_safe(None)` uses.
    ///
    /// The default `None` means "this ops layer cannot enumerate devices"
    /// (`NullDeviceOps`, test doubles), which preserves the explicit
    /// "no dome connected" instruction failure.
    async fn active_dome_id(&self) -> Option<String> {
        None
    }

    /// Open dome shutter
    async fn dome_open(&self, dome_id: &str) -> DeviceResult<()>;

    /// Close dome shutter
    async fn dome_close(&self, dome_id: &str) -> DeviceResult<()>;

    /// Park dome
    async fn dome_park(&self, dome_id: &str) -> DeviceResult<()>;

    /// Get dome status (shutter status)
    async fn dome_get_shutter_status(&self, dome_id: &str) -> DeviceResult<String>;

    // Safety monitor / weather operations

    /// Check if conditions are safe for observing
    /// Returns true if safe, false if unsafe.
    /// Returns Err when safety status cannot be determined (missing device, driver error, etc.).
    async fn safety_is_safe(&self, safety_id: Option<&str>) -> DeviceResult<bool>;

    /// Read humidity percentage (0-100) from the weather/observatory device.
    ///
    /// Returns `Ok(Some(value))` when the device reports humidity, `Ok(None)`
    /// when humidity is genuinely not supported by the connected weather
    /// device, and `Err(_)` when the query failed (driver error, no device
    /// configured, etc.). The trigger monitor uses this to feed the
    /// `HumidityThreshold` trigger; an `Err` result is logged and the trigger
    /// state is left unchanged so a stale-but-known reading does not get
    /// overwritten by a transient driver hiccup.
    ///
    /// Default implementation returns `Ok(None)` so existing DeviceOps
    /// implementations that do not know about humidity continue to compile.
    /// Real implementations should override this.
    async fn weather_get_humidity(&self, weather_id: Option<&str>) -> DeviceResult<Option<f64>> {
        let _ = weather_id;
        Ok(None)
    }

    // Image analysis

    /// Calculate median HFR from an image
    async fn calculate_image_hfr(&self, image_data: &ImageData) -> DeviceResult<Option<f64>>;

    /// Detect stars and return their HFRs (returns x, y, hfr tuples)
    async fn detect_stars_in_image(
        &self,
        image_data: &ImageData,
    ) -> DeviceResult<Vec<(f64, f64, f64)>>;

    /// Measure the per-frame median star eccentricity (0.0 = round,
    /// →1.0 = trailed/elongated).
    ///
    /// Returns `Ok(None)` when the metric cannot be honestly measured for
    /// this frame (no stars, or too few reliable stars to form a stable
    /// median). This feeds `FrameMetrics.eccentricity`, which the grading
    /// gate treats as "unknown — do not reject". The default implementation
    /// returns `Ok(None)`; the real backend (`UnifiedDeviceOps`) overrides
    /// it to run the shape-moment detector. Callers MUST distinguish a real
    /// `Some(ecc)` from `None` so a configured eccentricity gate is never
    /// silently bypassed.
    async fn measure_frame_eccentricity(
        &self,
        image_data: &ImageData,
    ) -> DeviceResult<Option<f64>> {
        let _ = image_data;
        Ok(None)
    }

    // Cover calibrator (flat panel / dust cover) operations

    /// Device id of the cover calibrator (flat panel) to command when the
    /// sequencer's execution context carries no cover-calibrator role
    /// assignment. See [`DeviceOps::active_dome_id`] for why the fallback is
    /// needed and why the default is `None`.
    async fn active_cover_calibrator_id(&self) -> Option<String> {
        None
    }

    /// Open the cover (unpark dust cap)
    async fn cover_calibrator_open_cover(&self, device_id: &str) -> DeviceResult<()>;

    /// Close the cover (park dust cap)
    async fn cover_calibrator_close_cover(&self, device_id: &str) -> DeviceResult<()>;

    /// Halt cover movement
    async fn cover_calibrator_halt_cover(&self, device_id: &str) -> DeviceResult<()>;

    /// Turn on the calibrator (flat panel light) at specified brightness
    async fn cover_calibrator_calibrator_on(
        &self,
        device_id: &str,
        brightness: i32,
    ) -> DeviceResult<()>;

    /// Turn off the calibrator (flat panel light)
    async fn cover_calibrator_calibrator_off(&self, device_id: &str) -> DeviceResult<()>;

    /// Get current cover state (0=NotPresent, 1=Closed, 2=Moving, 3=Open, 4=Unknown, 5=Error)
    async fn cover_calibrator_get_cover_state(&self, device_id: &str) -> DeviceResult<i32>;

    /// Get current calibrator state (0=NotPresent, 1=Off, 2=NotReady, 3=Ready, 4=Unknown, 5=Error)
    async fn cover_calibrator_get_calibrator_state(&self, device_id: &str) -> DeviceResult<i32>;

    /// Get current brightness level
    async fn cover_calibrator_get_brightness(&self, device_id: &str) -> DeviceResult<i32>;

    /// Get maximum brightness level
    async fn cover_calibrator_get_max_brightness(&self, device_id: &str) -> DeviceResult<i32>;
}

/// Shared device operations handle
pub type SharedDeviceOps = Arc<dyn DeviceOps>;

/// A null implementation for testing without real devices
pub struct NullDeviceOps;

#[async_trait]
impl DeviceOps for NullDeviceOps {
    async fn mount_slew_to_coordinates(
        &self,
        _mount_id: &str,
        ra: f64,
        dec: f64,
    ) -> DeviceResult<()> {
        tracing::info!("[NULL] Slew to RA={:.4}h, Dec={:.4}°", ra, dec);
        tokio::time::sleep(std::time::Duration::from_secs(3)).await;
        Ok(())
    }

    async fn mount_abort_slew(&self, _mount_id: &str) -> DeviceResult<()> {
        tracing::info!("[NULL] Aborting mount slew");
        Ok(())
    }

    async fn mount_get_coordinates(&self, _mount_id: &str) -> DeviceResult<(f64, f64)> {
        Ok((12.0, 45.0))
    }

    async fn mount_sync(&self, _mount_id: &str, _ra: f64, _dec: f64) -> DeviceResult<()> {
        Ok(())
    }

    async fn mount_park(&self, _mount_id: &str) -> DeviceResult<()> {
        tracing::info!("[NULL] Parking mount");
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
        Ok(())
    }

    async fn mount_unpark(&self, _mount_id: &str) -> DeviceResult<()> {
        tracing::info!("[NULL] Unparking mount");
        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
        Ok(())
    }

    async fn mount_is_slewing(&self, _mount_id: &str) -> DeviceResult<bool> {
        Ok(false)
    }

    async fn mount_is_parked(&self, _mount_id: &str) -> DeviceResult<bool> {
        Ok(false)
    }

    async fn mount_can_flip(&self, _mount_id: &str) -> DeviceResult<bool> {
        tracing::info!("[NULL] Mount supports flipping");
        Ok(true)
    }

    async fn mount_side_of_pier(&self, _mount_id: &str) -> DeviceResult<crate::meridian::PierSide> {
        Ok(crate::meridian::PierSide::East)
    }

    async fn mount_is_tracking(&self, _mount_id: &str) -> DeviceResult<bool> {
        Ok(true)
    }

    async fn mount_set_tracking(&self, _mount_id: &str, enabled: bool) -> DeviceResult<()> {
        tracing::info!("[NULL] Set tracking: {}", enabled);
        Ok(())
    }

    async fn camera_start_exposure(
        &self,
        _camera_id: &str,
        duration_secs: f64,
        gain: Option<i32>,
        offset: Option<i32>,
        _bin_x: i32,
        _bin_y: i32,
    ) -> DeviceResult<ImageData> {
        tracing::info!("[NULL] Starting {:.1}s exposure", duration_secs);
        tokio::time::sleep(std::time::Duration::from_secs_f64(duration_secs)).await;

        Ok(ImageData {
            width: 4144,
            height: 2822,
            data: vec![0u16; 4144 * 2822],
            bits_per_pixel: 16,
            exposure_secs: duration_secs,
            gain,
            offset,
            temperature: Some(-10.0),
            filter: None,
            timestamp: chrono::Utc::now().timestamp(),
            sensor_type: Some("Monochrome".to_string()), // Default to Mono
            bayer_offset: None,                          // No Bayer pattern for mono
        })
    }

    async fn camera_abort_exposure(&self, _camera_id: &str) -> DeviceResult<()> {
        Ok(())
    }

    async fn camera_set_cooler(
        &self,
        _camera_id: &str,
        enabled: bool,
        target: f64,
    ) -> DeviceResult<()> {
        tracing::info!("[NULL] Cooler: enabled={}, target={}°C", enabled, target);
        Ok(())
    }

    async fn camera_get_temperature(&self, _camera_id: &str) -> DeviceResult<f64> {
        Ok(-10.0)
    }

    async fn camera_get_cooler_power(&self, _camera_id: &str) -> DeviceResult<f64> {
        Ok(50.0)
    }

    async fn focuser_move_to(&self, _focuser_id: &str, position: i32) -> DeviceResult<()> {
        tracing::info!("[NULL] Moving focuser to {}", position);
        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
        Ok(())
    }

    async fn focuser_get_position(&self, _focuser_id: &str) -> DeviceResult<i32> {
        Ok(25000)
    }

    async fn focuser_is_moving(&self, _focuser_id: &str) -> DeviceResult<bool> {
        Ok(false)
    }

    async fn focuser_get_temperature(&self, _focuser_id: &str) -> DeviceResult<Option<f64>> {
        Ok(Some(15.0))
    }

    async fn focuser_halt(&self, _focuser_id: &str) -> DeviceResult<()> {
        tracing::info!("[NULL] Halting focuser");
        Ok(())
    }

    async fn filterwheel_set_position(&self, _fw_id: &str, position: i32) -> DeviceResult<()> {
        tracing::info!("[NULL] Setting filter to position {}", position);
        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
        Ok(())
    }

    async fn filterwheel_get_position(&self, _fw_id: &str) -> DeviceResult<i32> {
        Ok(1)
    }

    async fn filterwheel_get_names(&self, _fw_id: &str) -> DeviceResult<Vec<String>> {
        Ok(vec![
            "L".into(),
            "R".into(),
            "G".into(),
            "B".into(),
            "Ha".into(),
            "OIII".into(),
            "SII".into(),
        ])
    }

    async fn filterwheel_set_filter_by_name(&self, _fw_id: &str, name: &str) -> DeviceResult<i32> {
        let pos = match name.to_uppercase().as_str() {
            "L" | "LUMINANCE" => 1,
            "R" | "RED" => 2,
            "G" | "GREEN" => 3,
            "B" | "BLUE" => 4,
            "HA" | "H-ALPHA" => 5,
            "OIII" | "O3" => 6,
            "SII" | "S2" => 7,
            _ => 1,
        };
        self.filterwheel_set_position(_fw_id, pos).await?;
        Ok(pos)
    }

    async fn rotator_move_to(&self, _rotator_id: &str, angle: f64) -> DeviceResult<()> {
        tracing::info!("[NULL] Rotating to {}°", angle);
        tokio::time::sleep(std::time::Duration::from_secs(3)).await;
        Ok(())
    }

    async fn rotator_move_relative(&self, rotator_id: &str, delta: f64) -> DeviceResult<()> {
        let current = self.rotator_get_angle(rotator_id).await?;
        self.rotator_move_to(rotator_id, current + delta).await
    }

    async fn rotator_get_angle(&self, _rotator_id: &str) -> DeviceResult<f64> {
        Ok(0.0)
    }

    async fn rotator_halt(&self, _rotator_id: &str) -> DeviceResult<()> {
        tracing::info!("[NULL] Halting rotator");
        Ok(())
    }

    async fn guider_dither(
        &self,
        pixels: f64,
        settle_pixels: f64,
        settle_time: f64,
        _settle_timeout: f64,
        _ra_only: bool,
    ) -> DeviceResult<()> {
        tracing::info!(
            "[NULL] Dithering {} pixels, settle <{} px in {}s",
            pixels,
            settle_pixels,
            settle_time
        );
        tokio::time::sleep(std::time::Duration::from_secs_f64(settle_time.min(5.0))).await;
        Ok(())
    }

    async fn guider_get_status(&self) -> DeviceResult<GuidingStatus> {
        Ok(GuidingStatus {
            is_guiding: true,
            rms_ra: 0.5,
            rms_dec: 0.4,
            rms_total: 0.64,
        })
    }

    async fn guider_get_calibration(&self) -> DeviceResult<GuidingCalibration> {
        // Synthetic well-calibrated mount (axes 90° apart) so simulation
        // mode doesn't fail post-start validation.
        Ok(GuidingCalibration {
            is_calibrated: true,
            ra_angle_deg: Some(0.0),
            dec_angle_deg: Some(90.0),
        })
    }

    async fn guider_start(
        &self,
        _settle_pixels: f64,
        settle_time: f64,
        _settle_timeout: f64,
    ) -> DeviceResult<()> {
        tracing::info!("[NULL] Starting guiding");
        tokio::time::sleep(std::time::Duration::from_secs_f64(settle_time.min(5.0))).await;
        Ok(())
    }

    async fn guider_stop(&self) -> DeviceResult<()> {
        tracing::info!("[NULL] Stopping guiding");
        Ok(())
    }

    async fn plate_solve(
        &self,
        _image_data: &ImageData,
        hint_ra: Option<f64>,
        hint_dec: Option<f64>,
        _hint_scale: Option<f64>,
    ) -> DeviceResult<PlateSolveResult> {
        tracing::info!("[NULL] Plate solving");
        tokio::time::sleep(std::time::Duration::from_secs(3)).await;
        let ra_degrees = hint_ra.ok_or_else(|| {
            "NullDeviceOps plate_solve requires hint_ra in simulation mode".to_string()
        })?;
        let dec_degrees = hint_dec.ok_or_else(|| {
            "NullDeviceOps plate_solve requires hint_dec in simulation mode".to_string()
        })?;

        Ok(PlateSolveResult {
            ra_degrees,
            dec_degrees,
            pixel_scale: 1.5,
            rotation: 0.0,
            success: true,
        })
    }

    async fn save_fits(
        &self,
        _image_data: &ImageData,
        file_path: &str,
        frame_ctx: &crate::scheduling::FrameContext,
    ) -> DeviceResult<()> {
        tracing::info!(
            "[NULL] Saving FITS to {} ({})",
            file_path,
            frame_ctx.log_label()
        );
        Ok(())
    }

    async fn send_notification(
        &self,
        level: &str,
        title: &str,
        message: &str,
        explicit_transports: Option<&[String]>,
    ) -> DeviceResult<()> {
        match explicit_transports {
            Some(t) if !t.is_empty() => tracing::info!(
                "[NOTIFICATION][{}] {}: {} (transports: {})",
                level,
                title,
                message,
                t.join(",")
            ),
            _ => tracing::info!("[NOTIFICATION][{}] {}: {}", level, title, message),
        }
        Ok(())
    }

    fn calculate_altitude(&self, ra_hours: f64, dec_degrees: f64, lat: f64, lon: f64) -> f64 {
        let now = chrono::Utc::now();
        let jd = crate::node::julian_day(&now);
        let lst_hours = crate::node::local_sidereal_time(jd, lon);

        let mut ha_hours = lst_hours - ra_hours;
        while ha_hours > 12.0 {
            ha_hours -= 24.0;
        }
        while ha_hours < -12.0 {
            ha_hours += 24.0;
        }

        let ha_rad = (ha_hours * 15.0).to_radians();
        let dec_rad = dec_degrees.to_radians();
        let lat_rad = lat.to_radians();

        let sin_alt = lat_rad.sin() * dec_rad.sin() + lat_rad.cos() * dec_rad.cos() * ha_rad.cos();
        sin_alt.clamp(-1.0, 1.0).asin().to_degrees()
    }

    fn get_observer_location(&self) -> Option<(f64, f64)> {
        None
    }

    async fn polar_align_update(
        &self,
        result: &crate::polar_align::PolarAlignResult,
    ) -> DeviceResult<()> {
        tracing::info!("[NULL] Polar Align Update: {:?}", result);
        Ok(())
    }

    async fn dome_open(&self, _dome_id: &str) -> DeviceResult<()> {
        tracing::info!("[NULL] Opening dome shutter");
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
        Ok(())
    }

    async fn dome_close(&self, _dome_id: &str) -> DeviceResult<()> {
        tracing::info!("[NULL] Closing dome shutter");
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
        Ok(())
    }

    async fn dome_park(&self, _dome_id: &str) -> DeviceResult<()> {
        tracing::info!("[NULL] Parking dome");
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
        Ok(())
    }

    async fn dome_get_shutter_status(&self, _dome_id: &str) -> DeviceResult<String> {
        Ok("Open".to_string())
    }

    async fn safety_is_safe(&self, _safety_id: Option<&str>) -> DeviceResult<bool> {
        // Tests using NullDeviceOps need WeatherUnsafe to never fire; returning
        // true unconditionally is the simplest contract for that.
        tracing::info!("[NULL] Safety check: safe");
        Ok(true)
    }

    async fn calculate_image_hfr(&self, _image_data: &ImageData) -> DeviceResult<Option<f64>> {
        // Stub returns a plausible random HFR (1.5–3.0 px) so autofocus tests
        // get a varying curve to fit, exercising the V-curve solver without
        // requiring a real star detector.
        use rand::Rng;
        let mut rng = rand::thread_rng();
        let hfr = rng.gen_range(1.5..3.0);
        tracing::debug!("[NULL] Calculated HFR: {:.2}", hfr);
        Ok(Some(hfr))
    }

    async fn detect_stars_in_image(
        &self,
        _image_data: &ImageData,
    ) -> DeviceResult<Vec<(f64, f64, f64)>> {
        // Synthesize a randomized star field so MIN_STAR_COUNT-style validation
        // in tests sees a non-trivial detector output.
        use rand::Rng;
        let mut rng = rand::thread_rng();
        let num_stars = rng.gen_range(10..50);
        let stars: Vec<(f64, f64, f64)> = (0..num_stars)
            .map(|_| {
                let x = rng.gen_range(100.0..4000.0);
                let y = rng.gen_range(100.0..2700.0);
                let hfr = rng.gen_range(1.5..3.0);
                (x, y, hfr)
            })
            .collect();
        tracing::debug!("[NULL] Detected {} stars", stars.len());
        Ok(stars)
    }

    async fn cover_calibrator_open_cover(&self, _device_id: &str) -> DeviceResult<()> {
        tracing::info!("[NULL] Opening cover");
        tokio::time::sleep(std::time::Duration::from_secs(3)).await;
        Ok(())
    }

    async fn cover_calibrator_close_cover(&self, _device_id: &str) -> DeviceResult<()> {
        tracing::info!("[NULL] Closing cover");
        tokio::time::sleep(std::time::Duration::from_secs(3)).await;
        Ok(())
    }

    async fn cover_calibrator_halt_cover(&self, _device_id: &str) -> DeviceResult<()> {
        tracing::info!("[NULL] Halting cover");
        Ok(())
    }

    async fn cover_calibrator_calibrator_on(
        &self,
        _device_id: &str,
        brightness: i32,
    ) -> DeviceResult<()> {
        tracing::info!("[NULL] Turning calibrator on at brightness {}", brightness);
        tokio::time::sleep(std::time::Duration::from_millis(500)).await;
        Ok(())
    }

    async fn cover_calibrator_calibrator_off(&self, _device_id: &str) -> DeviceResult<()> {
        tracing::info!("[NULL] Turning calibrator off");
        Ok(())
    }

    async fn cover_calibrator_get_cover_state(&self, _device_id: &str) -> DeviceResult<i32> {
        // ASCOM CoverState::Open == 3; the pre-flip cover check treats
        // anything ≠ Closed as "ok to slew", so Open is the safe stub default.
        Ok(3)
    }

    async fn cover_calibrator_get_calibrator_state(&self, _device_id: &str) -> DeviceResult<i32> {
        // ASCOM CalibratorState::Ready == 3 — the "no-wait" state, so the flat
        // wizard does not loop waiting for the panel to warm up in tests.
        Ok(3)
    }

    async fn cover_calibrator_get_brightness(&self, _device_id: &str) -> DeviceResult<i32> {
        Ok(128)
    }

    async fn cover_calibrator_get_max_brightness(&self, _device_id: &str) -> DeviceResult<i32> {
        Ok(255)
    }
}

/// Result of a park-with-retry attempt.
///
/// `attempts_made` counts the total invocations of `mount_park` (the initial
/// attempt plus retries), so callers can include the count in failure messages
/// surfaced to the operator.
#[derive(Debug, Clone)]
pub struct ParkRetryResult {
    /// Whether the mount was successfully parked.
    pub success: bool,
    /// Total number of park-call attempts made (initial + retries).
    pub attempts_made: u32,
    /// Last error reported by `mount_park`, present iff `success == false`.
    pub last_error: Option<String>,
}

/// Try to park the mount, retrying with a fixed delay between attempts.
///
/// The single source of truth for park retries, shared by the executor's
/// `RecoveryAction::ParkAndAbort` and `Recovery::ParkAndAbort` in `node.rs`,
/// so both report a park failure specifically in their failure events.
///
/// `max_retries` counts attempts AFTER the initial call — `0` means try once —
/// so the total number of park calls is `1 + max_retries`. `retry_delay_secs`
/// is slept with `tokio::time::sleep` so the caller's runtime cancellation
/// still works.
pub async fn try_park_with_retry(
    device_ops: &SharedDeviceOps,
    mount_id: &str,
    max_retries: u32,
    retry_delay_secs: f64,
) -> ParkRetryResult {
    let total_attempts = max_retries.saturating_add(1);
    let mut last_error: Option<String> = None;

    for attempt in 1..=total_attempts {
        // Stop the axes before asking for the park. Some mounts refuse a park
        // while slewing (`meridian_flip_executor` already aborts first for
        // exactly this reason); this helper is the safety-abort path, so a park
        // issued mid-slew must not be allowed to fail all of its attempts and
        // leave the mount unparked. Best-effort: drivers that do not implement
        // abort, or that reject it when idle, still get their park attempt.
        if let Err(e) = device_ops.mount_abort_slew(mount_id).await {
            tracing::debug!(
                "mount_abort_slew({}) before park attempt {} failed: {} — parking anyway",
                mount_id,
                attempt,
                e
            );
        }
        match device_ops.mount_park(mount_id).await {
            Ok(()) => {
                if attempt == 1 {
                    tracing::info!("mount_park({}) succeeded on initial attempt", mount_id);
                } else {
                    tracing::info!(
                        "mount_park({}) succeeded on attempt {}/{}",
                        mount_id,
                        attempt,
                        total_attempts
                    );
                }
                return ParkRetryResult {
                    success: true,
                    attempts_made: attempt,
                    last_error: None,
                };
            }
            Err(e) => {
                tracing::error!(
                    "mount_park({}) FAILED on attempt {}/{}: {}",
                    mount_id,
                    attempt,
                    total_attempts,
                    e
                );
                last_error = Some(e);
                if attempt < total_attempts && retry_delay_secs > 0.0 {
                    tokio::time::sleep(std::time::Duration::from_secs_f64(
                        retry_delay_secs.max(0.0),
                    ))
                    .await;
                }
            }
        }
    }

    tracing::error!(
        "mount_park({}) exhausted {} attempt{}; last error: {:?}. \
         Mount may be in an unsafe position!",
        mount_id,
        total_attempts,
        if total_attempts == 1 { "" } else { "s" },
        last_error
    );
    ParkRetryResult {
        success: false,
        attempts_made: total_attempts,
        last_error,
    }
}

/// Outcome of a [`park_and_close_safe_state`] sweep.
///
/// Each field captures the result of one safe-state step so the caller can
/// word its own event-stream message while the *sequence of device calls*
/// itself is centralised. A `None` cover/dome error
/// means "that device was absent or closed cleanly"; `Some(err)` means the
/// close was attempted and the driver returned an error.
#[derive(Debug, Clone)]
pub struct SafeStateOutcome {
    /// Park result, present iff a `mount_id` was supplied. `None` means no
    /// mount was configured, so the caller should surface its own
    /// "cannot park" message.
    pub park: Option<ParkRetryResult>,
    /// Error returned by `cover_calibrator_close_cover`, if a cover was
    /// configured and the close failed.
    pub cover_close_error: Option<String>,
    /// Error returned by `dome_close`, if a dome was configured and the
    /// close failed.
    pub dome_close_error: Option<String>,
}

/// Drive the rig into a SAFE end-state: park the mount, then close the
/// flat-panel cover, then close the dome shutter — in that order.
///
/// This is the single source of truth for the "abandon the rig safely"
/// sequence that fires from three executor paths:
///   1. `RecoveryAction::ParkAndAbort` (weather/safety trigger termination),
///   2. recovery loop give-up (attempts/time budget exhausted), and
///   3. meridian-flip `AbortAndPark` failure handling.
///
/// Why the strict order: parking first stops the OTA tracking toward a limit /
/// the Sun at dawn; closing the cover before the dome protects the optics; the
/// dome shutter closes last so the scope is never left exposed under an open
/// roof. Leaving any of these undone re-exposes the rig to the exact condition
/// (rain / cloud / dawn) that triggered the safe-state in the first place.
///
/// Each step is best-effort and independent: a park failure does NOT skip the
/// cover/dome closes (the roof must close even if the mount is stuck). The
/// returned [`SafeStateOutcome`] reports every step so the caller can emit its
/// own operator-facing error events.
///
/// # Arguments
/// * `device_ops` - Shared device operations handle.
/// * `mount_id` - The mount to park, or `None` if no mount is configured.
/// * `cover_id` - The cover-calibrator to close, or `None`.
/// * `dome_id` - The dome to close, or `None`.
/// * `park_max_retries` / `park_retry_delay_secs` - forwarded to
///   [`try_park_with_retry`]; the give-up path passes 2 retries, the
///   ParkAndAbort path 1.
pub async fn park_and_close_safe_state(
    device_ops: &SharedDeviceOps,
    mount_id: Option<&str>,
    cover_id: Option<&str>,
    dome_id: Option<&str>,
    park_max_retries: u32,
    park_retry_delay_secs: f64,
) -> SafeStateOutcome {
    let park = match mount_id {
        Some(id) => {
            Some(try_park_with_retry(device_ops, id, park_max_retries, park_retry_delay_secs).await)
        }
        None => None,
    };

    let cover_close_error = match cover_id {
        Some(id) => device_ops.cover_calibrator_close_cover(id).await.err(),
        None => None,
    };

    // Closing the dome is the most safety-critical step of the sweep: it is the
    // last barrier between the optics and the open sky. Issuing `dome_close` and
    // returning would report the rig "safe" while the shutter sits jammed
    // half-open, so the close is followed by polling the shutter until it
    // confirms "Closed" (bounded timeout, mirroring
    // `instructions::wait_for_dome_shutter_state`). Any outcome that is not a
    // confirmed Closed records a `dome_close_error`, which the give-up path
    // surfaces to the operator.
    let dome_close_error = match dome_id {
        Some(id) => match device_ops.dome_close(id).await {
            Err(e) => Some(e),
            Ok(()) => verify_dome_closed(device_ops, id).await.err(),
        },
        None => None,
    };

    SafeStateOutcome {
        park,
        cover_close_error,
        dome_close_error,
    }
}

/// Maximum time to wait for the dome shutter to confirm `Closed` during the
/// unattended safe-state sweep. Mirrors `DOME_SHUTTER_TIMEOUT_SECS` in
/// `instructions.rs` (observatory shutters are slow: 30–90 s is typical).
const SAFE_STATE_DOME_CLOSE_TIMEOUT_SECS: f64 = 120.0;

/// Poll the dome shutter after a `dome_close` until it confirms `Closed`, or
/// return `Err` describing why the close could NOT be confirmed.
///
/// This mirrors `instructions::wait_for_dome_shutter_state` but is intentionally
/// STRICTER for the abandon-the-rig sweep: where the per-instruction path
/// tolerates a roll-off roof that cannot report shutter position (it degrades
/// loudly and proceeds), this path treats a never-confirmed close as unsafe.
/// When the rig is being abandoned for the night, "the roof might be open" is
/// not an acceptable end-state — the operator must be told.
///
/// * A read error (driver fault / disconnect) → unsafe (cannot verify).
/// * A definite state that never reaches `Closed` within the timeout → a real
///   motor/jam failure → unsafe.
/// * The dome never reports a definite state (cannot report position) →
///   unconfirmed → unsafe for this sweep.
async fn verify_dome_closed(device_ops: &SharedDeviceOps, dome_id: &str) -> Result<(), String> {
    const POLL_SECS: f64 = 2.0;
    let mut elapsed = 0.0_f64;
    let mut saw_definite_state = false;

    loop {
        match device_ops.dome_get_shutter_status(dome_id).await {
            Ok(status) => {
                if status == "Closed" {
                    return Ok(());
                }
                if status == "Open"
                    || status == "Closed"
                    || status == "Opening"
                    || status == "Closing"
                {
                    saw_definite_state = true;
                }
            }
            Err(e) => {
                return Err(format!(
                    "could not read dome '{}' shutter status to confirm Closed: {} — \
                     scope may be exposed",
                    dome_id, e
                ));
            }
        }

        if elapsed >= SAFE_STATE_DOME_CLOSE_TIMEOUT_SECS {
            if saw_definite_state {
                return Err(format!(
                    "dome '{}' shutter did not reach Closed within {:.0}s — \
                     shutter may be jammed; scope may be exposed",
                    dome_id, SAFE_STATE_DOME_CLOSE_TIMEOUT_SECS
                ));
            }
            return Err(format!(
                "dome '{}' shutter status never reported a definite state — \
                 cannot confirm the roof is closed; scope may be exposed",
                dome_id
            ));
        }

        tokio::time::sleep(std::time::Duration::from_secs_f64(POLL_SECS)).await;
        elapsed += POLL_SECS;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU32, Ordering};
    use std::sync::Arc as StdArc;

    /// A DeviceOps wrapper that fails `mount_park` a configurable number of
    /// times before succeeding. Used by the retry-helper tests.
    struct FlakyParkOps {
        inner: StdArc<NullDeviceOps>,
        fail_count: AtomicU32,
        attempts: AtomicU32,
        fail_forever: bool,
        /// Models the driver class that rejects a park while the axes are still
        /// turning (ASCOM `InvalidOperationException`, INDI property reject).
        /// `mount_abort_slew` is the only thing that clears it.
        slewing: std::sync::atomic::AtomicBool,
    }

    impl FlakyParkOps {
        fn new(fail_count: u32, fail_forever: bool) -> Self {
            Self {
                inner: StdArc::new(NullDeviceOps),
                fail_count: AtomicU32::new(fail_count),
                attempts: AtomicU32::new(0),
                fail_forever,
                slewing: std::sync::atomic::AtomicBool::new(false),
            }
        }

        /// A mount that is mid-slew when the safety park arrives.
        fn slewing() -> Self {
            let ops = Self::new(0, false);
            ops.slewing.store(true, Ordering::SeqCst);
            ops
        }

        fn attempts(&self) -> u32 {
            self.attempts.load(Ordering::SeqCst)
        }
    }

    #[async_trait]
    impl DeviceOps for FlakyParkOps {
        // Only mount_park and mount_abort_slew are overridden; every other
        // method delegates to NullDeviceOps.
        async fn mount_abort_slew(&self, _mount_id: &str) -> DeviceResult<()> {
            self.slewing.store(false, Ordering::SeqCst);
            Ok(())
        }

        async fn mount_park(&self, mount_id: &str) -> DeviceResult<()> {
            self.attempts.fetch_add(1, Ordering::SeqCst);
            if self.slewing.load(Ordering::SeqCst) {
                return Err(format!("{} cannot park while slewing", mount_id));
            }
            if self.fail_forever {
                return Err(format!("simulated park failure for {}", mount_id));
            }
            let remaining = self.fail_count.load(Ordering::SeqCst);
            if remaining > 0 {
                self.fail_count.fetch_sub(1, Ordering::SeqCst);
                return Err(format!(
                    "simulated park failure for {} ({} failures remaining)",
                    mount_id, remaining
                ));
            }
            Ok(())
        }

        // === delegating methods ===
        async fn mount_slew_to_coordinates(&self, id: &str, ra: f64, dec: f64) -> DeviceResult<()> {
            self.inner.mount_slew_to_coordinates(id, ra, dec).await
        }
        async fn mount_get_coordinates(&self, id: &str) -> DeviceResult<(f64, f64)> {
            self.inner.mount_get_coordinates(id).await
        }
        async fn mount_sync(&self, id: &str, ra: f64, dec: f64) -> DeviceResult<()> {
            self.inner.mount_sync(id, ra, dec).await
        }
        async fn mount_unpark(&self, id: &str) -> DeviceResult<()> {
            self.inner.mount_unpark(id).await
        }
        async fn mount_is_slewing(&self, id: &str) -> DeviceResult<bool> {
            self.inner.mount_is_slewing(id).await
        }
        async fn mount_is_parked(&self, id: &str) -> DeviceResult<bool> {
            self.inner.mount_is_parked(id).await
        }
        async fn mount_can_flip(&self, id: &str) -> DeviceResult<bool> {
            self.inner.mount_can_flip(id).await
        }
        async fn mount_side_of_pier(&self, id: &str) -> DeviceResult<crate::meridian::PierSide> {
            self.inner.mount_side_of_pier(id).await
        }
        async fn mount_is_tracking(&self, id: &str) -> DeviceResult<bool> {
            self.inner.mount_is_tracking(id).await
        }
        async fn mount_set_tracking(&self, id: &str, enabled: bool) -> DeviceResult<()> {
            self.inner.mount_set_tracking(id, enabled).await
        }
        async fn camera_start_exposure(
            &self,
            id: &str,
            d: f64,
            g: Option<i32>,
            o: Option<i32>,
            bx: i32,
            by: i32,
        ) -> DeviceResult<ImageData> {
            self.inner.camera_start_exposure(id, d, g, o, bx, by).await
        }
        async fn camera_abort_exposure(&self, id: &str) -> DeviceResult<()> {
            self.inner.camera_abort_exposure(id).await
        }
        async fn camera_set_cooler(&self, id: &str, e: bool, t: f64) -> DeviceResult<()> {
            self.inner.camera_set_cooler(id, e, t).await
        }
        async fn camera_get_temperature(&self, id: &str) -> DeviceResult<f64> {
            self.inner.camera_get_temperature(id).await
        }
        async fn camera_get_cooler_power(&self, id: &str) -> DeviceResult<f64> {
            self.inner.camera_get_cooler_power(id).await
        }
        async fn focuser_move_to(&self, id: &str, p: i32) -> DeviceResult<()> {
            self.inner.focuser_move_to(id, p).await
        }
        async fn focuser_get_position(&self, id: &str) -> DeviceResult<i32> {
            self.inner.focuser_get_position(id).await
        }
        async fn focuser_is_moving(&self, id: &str) -> DeviceResult<bool> {
            self.inner.focuser_is_moving(id).await
        }
        async fn focuser_get_temperature(&self, id: &str) -> DeviceResult<Option<f64>> {
            self.inner.focuser_get_temperature(id).await
        }
        async fn focuser_halt(&self, id: &str) -> DeviceResult<()> {
            self.inner.focuser_halt(id).await
        }
        async fn filterwheel_set_position(&self, id: &str, p: i32) -> DeviceResult<()> {
            self.inner.filterwheel_set_position(id, p).await
        }
        async fn filterwheel_get_position(&self, id: &str) -> DeviceResult<i32> {
            self.inner.filterwheel_get_position(id).await
        }
        async fn filterwheel_get_names(&self, id: &str) -> DeviceResult<Vec<String>> {
            self.inner.filterwheel_get_names(id).await
        }
        async fn filterwheel_set_filter_by_name(&self, id: &str, n: &str) -> DeviceResult<i32> {
            self.inner.filterwheel_set_filter_by_name(id, n).await
        }
        async fn rotator_move_to(&self, id: &str, a: f64) -> DeviceResult<()> {
            self.inner.rotator_move_to(id, a).await
        }
        async fn rotator_move_relative(&self, id: &str, d: f64) -> DeviceResult<()> {
            self.inner.rotator_move_relative(id, d).await
        }
        async fn rotator_get_angle(&self, id: &str) -> DeviceResult<f64> {
            self.inner.rotator_get_angle(id).await
        }
        async fn rotator_halt(&self, id: &str) -> DeviceResult<()> {
            self.inner.rotator_halt(id).await
        }
        async fn guider_dither(
            &self,
            p: f64,
            sp: f64,
            st: f64,
            sto: f64,
            ra: bool,
        ) -> DeviceResult<()> {
            self.inner.guider_dither(p, sp, st, sto, ra).await
        }
        async fn guider_get_status(&self) -> DeviceResult<GuidingStatus> {
            self.inner.guider_get_status().await
        }
        async fn guider_start(&self, sp: f64, st: f64, sto: f64) -> DeviceResult<()> {
            self.inner.guider_start(sp, st, sto).await
        }
        async fn guider_stop(&self) -> DeviceResult<()> {
            self.inner.guider_stop().await
        }
        async fn plate_solve(
            &self,
            d: &ImageData,
            ra: Option<f64>,
            dec: Option<f64>,
            s: Option<f64>,
        ) -> DeviceResult<PlateSolveResult> {
            self.inner.plate_solve(d, ra, dec, s).await
        }
        async fn save_fits(
            &self,
            d: &ImageData,
            f: &str,
            ctx: &crate::scheduling::FrameContext,
        ) -> DeviceResult<()> {
            self.inner.save_fits(d, f, ctx).await
        }
        async fn send_notification(
            &self,
            l: &str,
            t: &str,
            m: &str,
            x: Option<&[String]>,
        ) -> DeviceResult<()> {
            self.inner.send_notification(l, t, m, x).await
        }
        fn calculate_altitude(&self, r: f64, d: f64, la: f64, lo: f64) -> f64 {
            self.inner.calculate_altitude(r, d, la, lo)
        }
        fn get_observer_location(&self) -> Option<(f64, f64)> {
            self.inner.get_observer_location()
        }
        async fn polar_align_update(
            &self,
            r: &crate::polar_align::PolarAlignResult,
        ) -> DeviceResult<()> {
            self.inner.polar_align_update(r).await
        }
        async fn dome_open(&self, id: &str) -> DeviceResult<()> {
            self.inner.dome_open(id).await
        }
        async fn dome_close(&self, id: &str) -> DeviceResult<()> {
            self.inner.dome_close(id).await
        }
        async fn dome_park(&self, id: &str) -> DeviceResult<()> {
            self.inner.dome_park(id).await
        }
        async fn dome_get_shutter_status(&self, id: &str) -> DeviceResult<String> {
            self.inner.dome_get_shutter_status(id).await
        }
        async fn safety_is_safe(&self, id: Option<&str>) -> DeviceResult<bool> {
            self.inner.safety_is_safe(id).await
        }
        async fn calculate_image_hfr(&self, d: &ImageData) -> DeviceResult<Option<f64>> {
            self.inner.calculate_image_hfr(d).await
        }
        async fn detect_stars_in_image(&self, d: &ImageData) -> DeviceResult<Vec<(f64, f64, f64)>> {
            self.inner.detect_stars_in_image(d).await
        }
        async fn measure_frame_eccentricity(&self, d: &ImageData) -> DeviceResult<Option<f64>> {
            self.inner.measure_frame_eccentricity(d).await
        }
        async fn cover_calibrator_open_cover(&self, id: &str) -> DeviceResult<()> {
            self.inner.cover_calibrator_open_cover(id).await
        }
        async fn cover_calibrator_close_cover(&self, id: &str) -> DeviceResult<()> {
            self.inner.cover_calibrator_close_cover(id).await
        }
        async fn cover_calibrator_halt_cover(&self, id: &str) -> DeviceResult<()> {
            self.inner.cover_calibrator_halt_cover(id).await
        }
        async fn cover_calibrator_calibrator_on(&self, id: &str, b: i32) -> DeviceResult<()> {
            self.inner.cover_calibrator_calibrator_on(id, b).await
        }
        async fn cover_calibrator_calibrator_off(&self, id: &str) -> DeviceResult<()> {
            self.inner.cover_calibrator_calibrator_off(id).await
        }
        async fn cover_calibrator_get_cover_state(&self, id: &str) -> DeviceResult<i32> {
            self.inner.cover_calibrator_get_cover_state(id).await
        }
        async fn cover_calibrator_get_calibrator_state(&self, id: &str) -> DeviceResult<i32> {
            self.inner.cover_calibrator_get_calibrator_state(id).await
        }
        async fn cover_calibrator_get_brightness(&self, id: &str) -> DeviceResult<i32> {
            self.inner.cover_calibrator_get_brightness(id).await
        }
        async fn cover_calibrator_get_max_brightness(&self, id: &str) -> DeviceResult<i32> {
            self.inner.cover_calibrator_get_max_brightness(id).await
        }
    }

    /// A DeviceOps wrapper that accepts `dome_close` (returns Ok) but reports a
    /// configurable shutter status forever — used to prove the safe-state sweep
    /// VERIFIES the shutter actually reached Closed rather than trusting the
    /// fire-and-forget close. `mount_park`, `dome_close`, and
    /// `cover_calibrator_close_cover` all succeed so the dome step is the only
    /// variable under test.
    struct StuckShutterOps {
        inner: StdArc<NullDeviceOps>,
        /// Status returned by every `dome_get_shutter_status` poll. Set to
        /// "Open" to simulate a jam (definite state, never Closed) or "Unknown"
        /// to simulate a roof that cannot report position.
        shutter_status: String,
        /// When true, every `dome_get_shutter_status` poll returns Err to
        /// simulate a driver fault / disconnect during verification.
        read_fails: bool,
    }

    impl StuckShutterOps {
        fn new(shutter_status: &str, read_fails: bool) -> Self {
            Self {
                inner: StdArc::new(NullDeviceOps),
                shutter_status: shutter_status.to_string(),
                read_fails,
            }
        }
    }

    #[async_trait]
    impl DeviceOps for StuckShutterOps {
        async fn dome_close(&self, _id: &str) -> DeviceResult<()> {
            // The command is "accepted" — exactly the deceptive case: the
            // driver says OK while the shutter never actually closes.
            Ok(())
        }
        async fn dome_get_shutter_status(&self, _id: &str) -> DeviceResult<String> {
            if self.read_fails {
                return Err("simulated shutter-status read failure".to_string());
            }
            Ok(self.shutter_status.clone())
        }
        // Park + cover close cleanly so the dome is the only failing step.
        async fn mount_park(&self, _id: &str) -> DeviceResult<()> {
            Ok(())
        }
        async fn cover_calibrator_close_cover(&self, _id: &str) -> DeviceResult<()> {
            Ok(())
        }

        // === delegating methods ===
        async fn mount_slew_to_coordinates(&self, id: &str, ra: f64, dec: f64) -> DeviceResult<()> {
            self.inner.mount_slew_to_coordinates(id, ra, dec).await
        }
        async fn mount_abort_slew(&self, id: &str) -> DeviceResult<()> {
            self.inner.mount_abort_slew(id).await
        }
        async fn mount_get_coordinates(&self, id: &str) -> DeviceResult<(f64, f64)> {
            self.inner.mount_get_coordinates(id).await
        }
        async fn mount_sync(&self, id: &str, ra: f64, dec: f64) -> DeviceResult<()> {
            self.inner.mount_sync(id, ra, dec).await
        }
        async fn mount_unpark(&self, id: &str) -> DeviceResult<()> {
            self.inner.mount_unpark(id).await
        }
        async fn mount_is_slewing(&self, id: &str) -> DeviceResult<bool> {
            self.inner.mount_is_slewing(id).await
        }
        async fn mount_is_parked(&self, id: &str) -> DeviceResult<bool> {
            self.inner.mount_is_parked(id).await
        }
        async fn mount_can_flip(&self, id: &str) -> DeviceResult<bool> {
            self.inner.mount_can_flip(id).await
        }
        async fn mount_side_of_pier(&self, id: &str) -> DeviceResult<crate::meridian::PierSide> {
            self.inner.mount_side_of_pier(id).await
        }
        async fn mount_is_tracking(&self, id: &str) -> DeviceResult<bool> {
            self.inner.mount_is_tracking(id).await
        }
        async fn mount_set_tracking(&self, id: &str, enabled: bool) -> DeviceResult<()> {
            self.inner.mount_set_tracking(id, enabled).await
        }
        async fn camera_start_exposure(
            &self,
            id: &str,
            d: f64,
            g: Option<i32>,
            o: Option<i32>,
            bx: i32,
            by: i32,
        ) -> DeviceResult<ImageData> {
            self.inner.camera_start_exposure(id, d, g, o, bx, by).await
        }
        async fn camera_abort_exposure(&self, id: &str) -> DeviceResult<()> {
            self.inner.camera_abort_exposure(id).await
        }
        async fn camera_set_cooler(&self, id: &str, e: bool, t: f64) -> DeviceResult<()> {
            self.inner.camera_set_cooler(id, e, t).await
        }
        async fn camera_get_temperature(&self, id: &str) -> DeviceResult<f64> {
            self.inner.camera_get_temperature(id).await
        }
        async fn camera_get_cooler_power(&self, id: &str) -> DeviceResult<f64> {
            self.inner.camera_get_cooler_power(id).await
        }
        async fn focuser_move_to(&self, id: &str, p: i32) -> DeviceResult<()> {
            self.inner.focuser_move_to(id, p).await
        }
        async fn focuser_get_position(&self, id: &str) -> DeviceResult<i32> {
            self.inner.focuser_get_position(id).await
        }
        async fn focuser_is_moving(&self, id: &str) -> DeviceResult<bool> {
            self.inner.focuser_is_moving(id).await
        }
        async fn focuser_get_temperature(&self, id: &str) -> DeviceResult<Option<f64>> {
            self.inner.focuser_get_temperature(id).await
        }
        async fn focuser_halt(&self, id: &str) -> DeviceResult<()> {
            self.inner.focuser_halt(id).await
        }
        async fn filterwheel_set_position(&self, id: &str, p: i32) -> DeviceResult<()> {
            self.inner.filterwheel_set_position(id, p).await
        }
        async fn filterwheel_get_position(&self, id: &str) -> DeviceResult<i32> {
            self.inner.filterwheel_get_position(id).await
        }
        async fn filterwheel_get_names(&self, id: &str) -> DeviceResult<Vec<String>> {
            self.inner.filterwheel_get_names(id).await
        }
        async fn filterwheel_set_filter_by_name(&self, id: &str, n: &str) -> DeviceResult<i32> {
            self.inner.filterwheel_set_filter_by_name(id, n).await
        }
        async fn rotator_move_to(&self, id: &str, a: f64) -> DeviceResult<()> {
            self.inner.rotator_move_to(id, a).await
        }
        async fn rotator_move_relative(&self, id: &str, d: f64) -> DeviceResult<()> {
            self.inner.rotator_move_relative(id, d).await
        }
        async fn rotator_get_angle(&self, id: &str) -> DeviceResult<f64> {
            self.inner.rotator_get_angle(id).await
        }
        async fn rotator_halt(&self, id: &str) -> DeviceResult<()> {
            self.inner.rotator_halt(id).await
        }
        async fn guider_dither(
            &self,
            p: f64,
            sp: f64,
            st: f64,
            sto: f64,
            ra: bool,
        ) -> DeviceResult<()> {
            self.inner.guider_dither(p, sp, st, sto, ra).await
        }
        async fn guider_get_status(&self) -> DeviceResult<GuidingStatus> {
            self.inner.guider_get_status().await
        }
        async fn guider_start(&self, sp: f64, st: f64, sto: f64) -> DeviceResult<()> {
            self.inner.guider_start(sp, st, sto).await
        }
        async fn guider_stop(&self) -> DeviceResult<()> {
            self.inner.guider_stop().await
        }
        async fn plate_solve(
            &self,
            d: &ImageData,
            ra: Option<f64>,
            dec: Option<f64>,
            s: Option<f64>,
        ) -> DeviceResult<PlateSolveResult> {
            self.inner.plate_solve(d, ra, dec, s).await
        }
        async fn save_fits(
            &self,
            d: &ImageData,
            f: &str,
            ctx: &crate::scheduling::FrameContext,
        ) -> DeviceResult<()> {
            self.inner.save_fits(d, f, ctx).await
        }
        async fn send_notification(
            &self,
            l: &str,
            t: &str,
            m: &str,
            x: Option<&[String]>,
        ) -> DeviceResult<()> {
            self.inner.send_notification(l, t, m, x).await
        }
        fn calculate_altitude(&self, r: f64, d: f64, la: f64, lo: f64) -> f64 {
            self.inner.calculate_altitude(r, d, la, lo)
        }
        fn get_observer_location(&self) -> Option<(f64, f64)> {
            self.inner.get_observer_location()
        }
        async fn polar_align_update(
            &self,
            r: &crate::polar_align::PolarAlignResult,
        ) -> DeviceResult<()> {
            self.inner.polar_align_update(r).await
        }
        async fn dome_open(&self, id: &str) -> DeviceResult<()> {
            self.inner.dome_open(id).await
        }
        async fn dome_park(&self, id: &str) -> DeviceResult<()> {
            self.inner.dome_park(id).await
        }
        async fn safety_is_safe(&self, id: Option<&str>) -> DeviceResult<bool> {
            self.inner.safety_is_safe(id).await
        }
        async fn calculate_image_hfr(&self, d: &ImageData) -> DeviceResult<Option<f64>> {
            self.inner.calculate_image_hfr(d).await
        }
        async fn detect_stars_in_image(&self, d: &ImageData) -> DeviceResult<Vec<(f64, f64, f64)>> {
            self.inner.detect_stars_in_image(d).await
        }
        async fn measure_frame_eccentricity(&self, d: &ImageData) -> DeviceResult<Option<f64>> {
            self.inner.measure_frame_eccentricity(d).await
        }
        async fn cover_calibrator_open_cover(&self, id: &str) -> DeviceResult<()> {
            self.inner.cover_calibrator_open_cover(id).await
        }
        async fn cover_calibrator_halt_cover(&self, id: &str) -> DeviceResult<()> {
            self.inner.cover_calibrator_halt_cover(id).await
        }
        async fn cover_calibrator_calibrator_on(&self, id: &str, b: i32) -> DeviceResult<()> {
            self.inner.cover_calibrator_calibrator_on(id, b).await
        }
        async fn cover_calibrator_calibrator_off(&self, id: &str) -> DeviceResult<()> {
            self.inner.cover_calibrator_calibrator_off(id).await
        }
        async fn cover_calibrator_get_cover_state(&self, id: &str) -> DeviceResult<i32> {
            self.inner.cover_calibrator_get_cover_state(id).await
        }
        async fn cover_calibrator_get_calibrator_state(&self, id: &str) -> DeviceResult<i32> {
            self.inner.cover_calibrator_get_calibrator_state(id).await
        }
        async fn cover_calibrator_get_brightness(&self, id: &str) -> DeviceResult<i32> {
            self.inner.cover_calibrator_get_brightness(id).await
        }
        async fn cover_calibrator_get_max_brightness(&self, id: &str) -> DeviceResult<i32> {
            self.inner.cover_calibrator_get_max_brightness(id).await
        }
    }

    /// The unattended safe-state sweep VERIFIES the dome shutter actually
    /// reached Closed: a shutter that accepts the close command but jams
    /// half-open (reports "Open" forever) must record a `dome_close_error`,
    /// otherwise the rig is reported safe while the scope sits under an open
    /// roof.
    #[tokio::test(start_paused = true)]
    async fn park_and_close_safe_state_reports_unsafe_on_jammed_shutter() {
        let ops: SharedDeviceOps = Arc::new(StuckShutterOps::new("Open", false));
        let outcome = park_and_close_safe_state(
            &ops,
            Some("mount-1"),
            Some("cover-1"),
            Some("dome-1"),
            1,
            0.0,
        )
        .await;
        assert!(
            outcome.dome_close_error.is_some(),
            "a shutter that never reaches Closed must record a dome_close_error"
        );
        assert!(
            outcome
                .dome_close_error
                .as_deref()
                .unwrap()
                .contains("jammed")
                || outcome
                    .dome_close_error
                    .as_deref()
                    .unwrap()
                    .contains("did not reach Closed"),
            "the error must explain the shutter never closed: {:?}",
            outcome.dome_close_error
        );
        // The park + cover steps still succeeded — only the dome is unsafe.
        assert!(outcome.park.as_ref().map(|p| p.success).unwrap_or(false));
        assert!(outcome.cover_close_error.is_none());
    }

    /// A roof that can never report shutter position (every poll "Unknown")
    /// is also reported unsafe by the sweep — for an abandoned rig, "the roof
    /// might be open" is not an acceptable end-state. (The per-instruction
    /// path tolerates this and proceeds; the abandon sweep is intentionally
    /// stricter.)
    #[tokio::test(start_paused = true)]
    async fn park_and_close_safe_state_reports_unsafe_on_unconfirmable_shutter() {
        let ops: SharedDeviceOps = Arc::new(StuckShutterOps::new("Unknown", false));
        let outcome = park_and_close_safe_state(&ops, None, None, Some("dome-1"), 1, 0.0).await;
        assert!(
            outcome.dome_close_error.is_some(),
            "an unconfirmable shutter must record a dome_close_error"
        );
    }

    /// A shutter-status read fault during verification is also unsafe — we
    /// cannot confirm Closed, so we must not claim safety.
    #[tokio::test(start_paused = true)]
    async fn park_and_close_safe_state_reports_unsafe_when_shutter_read_fails() {
        let ops: SharedDeviceOps = Arc::new(StuckShutterOps::new("", true));
        let outcome = park_and_close_safe_state(&ops, None, None, Some("dome-1"), 1, 0.0).await;
        assert!(outcome.dome_close_error.is_some());
    }

    /// Control: a healthy shutter that reaches Closed records NO
    /// dome_close_error — the verification must not flag a working dome.
    #[tokio::test(start_paused = true)]
    async fn park_and_close_safe_state_healthy_shutter_reports_no_error() {
        let ops: SharedDeviceOps = Arc::new(StuckShutterOps::new("Closed", false));
        let outcome = park_and_close_safe_state(
            &ops,
            Some("mount-1"),
            Some("cover-1"),
            Some("dome-1"),
            1,
            0.0,
        )
        .await;
        assert!(
            outcome.dome_close_error.is_none(),
            "a healthy shutter that reaches Closed must not record an error: {:?}",
            outcome.dome_close_error
        );
        assert!(outcome.park.as_ref().is_some_and(|p| p.success));
        assert!(outcome.cover_close_error.is_none());
    }

    #[tokio::test]
    async fn try_park_with_retry_succeeds_first_attempt() {
        let ops: SharedDeviceOps = Arc::new(FlakyParkOps::new(0, false));
        let result = try_park_with_retry(&ops, "mount-1", 3, 0.0).await;
        assert!(result.success);
        assert_eq!(result.attempts_made, 1);
        assert!(result.last_error.is_none());
    }

    #[tokio::test]
    async fn try_park_with_retry_recovers_after_retries() {
        let ops_concrete = Arc::new(FlakyParkOps::new(2, false));
        let ops: SharedDeviceOps = ops_concrete.clone();
        let result = try_park_with_retry(&ops, "mount-1", 3, 0.0).await;
        assert!(result.success, "should succeed after 2 failures");
        assert_eq!(result.attempts_made, 3);
        assert_eq!(ops_concrete.attempts(), 3);
        assert!(result.last_error.is_none());
    }

    #[tokio::test]
    async fn try_park_with_retry_gives_up_after_exhausting_attempts() {
        let ops_concrete = Arc::new(FlakyParkOps::new(0, true));
        let ops: SharedDeviceOps = ops_concrete.clone();
        let result = try_park_with_retry(&ops, "mount-1", 2, 0.0).await;
        assert!(!result.success);
        // max_retries=2 means total 3 attempts (initial + 2 retries).
        assert_eq!(result.attempts_made, 3);
        assert_eq!(ops_concrete.attempts(), 3);
        assert!(result.last_error.is_some());
    }

    #[tokio::test]
    async fn try_park_with_retry_zero_retries_means_one_attempt() {
        let ops_concrete = Arc::new(FlakyParkOps::new(0, true));
        let ops: SharedDeviceOps = ops_concrete.clone();
        let result = try_park_with_retry(&ops, "mount-1", 0, 0.0).await;
        assert!(!result.success);
        assert_eq!(result.attempts_made, 1);
        assert_eq!(ops_concrete.attempts(), 1);
    }

    /// The safety park must stop the axes before it asks for the park.
    ///
    /// This is the emergency-park path (weather abort, recovery
    /// `ParkAndAbort`), and it is routinely reached with a slew in flight.
    /// Mounts that refuse a park while slewing therefore rejected every
    /// attempt and the mount was left unparked — `meridian_flip_executor`
    /// already aborts first for exactly this reason, this path did not.
    /// Zero retries so the abort, not a lucky retry, is what makes it succeed.
    #[tokio::test]
    async fn try_park_with_retry_stops_the_slew_before_parking() {
        let ops_concrete = Arc::new(FlakyParkOps::slewing());
        let ops: SharedDeviceOps = ops_concrete.clone();
        let result = try_park_with_retry(&ops, "mount-1", 0, 0.0).await;
        assert!(
            result.success,
            "a mount that refuses a park while slewing was left unparked by the \
             safety-park path: {:?}",
            result.last_error
        );
        assert_eq!(result.attempts_made, 1);
    }
}

#[cfg(test)]
mod no_guider_marker_tests {
    use super::*;

    /// The marker is matched by TEXT across crate boundaries (the bridge builds
    /// it, the sequencer classifies it), so it is worth pinning: a reworded
    /// message would silently turn every unguided abort back into a critical
    /// "failed to stop guiding" alert, and every unguided dither back into a
    /// fail-closed sequence abort.
    #[test]
    fn recognises_the_no_guider_marker_and_nothing_else() {
        assert!(is_no_guider_configured(NO_GUIDER_CONFIGURED));
        assert!(is_no_guider_configured(&format!(
            "Operation failed: {NO_GUIDER_CONFIGURED}"
        )));
        // Real guider failures must stay loud.
        assert!(!is_no_guider_configured("Guide star lost"));
        assert!(!is_no_guider_configured("PHD2 connection refused"));
        assert!(!is_no_guider_configured("Settle timed out after 120s"));
    }
}
