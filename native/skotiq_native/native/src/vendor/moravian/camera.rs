//! `MoravianCamera` state, connection and the exposure steps.
//!
//! Every step that talks to the camera is a plain function taking the
//! library's [`Api`], so the async trait methods only take the library's lock
//! and the tests can drive the same code against a stand-in table.

use super::*;
use std::time::{Duration, Instant};

pub struct MoravianCamera {
    pub(crate) library: Library,
    pub(crate) camera_id: u32,
    pub(crate) core: CameraCore,
    /// The initialized camera; null while disconnected.
    pub(crate) handle: SdkHandle<PCCamera>,
    pub(crate) serial: Option<String>,
    pub(crate) limits: Limits,
    /// Read mode names in index order.
    pub(crate) read_modes: Vec<String>,
    pub(crate) read_mode: Option<u32>,
    pub(crate) exposure: Option<Exposure>,
}

/// What the camera reported about itself at connect.
#[derive(Debug, Clone, Default)]
pub(crate) struct Limits {
    pub(crate) min_exposure_secs: f64,
    /// The largest gain register value, when the camera's gain can be set.
    pub(crate) max_gain: Option<u16>,
    pub(crate) asymmetric_binning: bool,
    /// The RGB cell at pixel (0, 0) of the full frame as the library delivers
    /// it; `None` for mono and for CMY/CMYG sensors.
    pub(crate) full_frame_cell: Option<BayerPattern>,
}

/// The exposure in progress.
#[derive(Debug)]
pub(crate) struct Exposure {
    pub(crate) roi: SdkRoi,
    pub(crate) open_shutter: bool,
    pub(crate) bayer: Option<BayerPattern>,
    pub(crate) started: Instant,
    /// Computer timing: when the end call returned.
    pub(crate) ended: std::sync::Mutex<Option<Instant>>,
}

impl Exposure {
    pub(crate) fn ended_at(&self) -> Option<Instant> {
        *self.ended.lock().unwrap_or_else(|e| e.into_inner())
    }
}

impl std::fmt::Debug for MoravianCamera {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MoravianCamera")
            .field("name", &self.core.name)
            .field("library", &self.library)
            .field("camera_id", &self.camera_id)
            .finish()
    }
}

impl MoravianCamera {
    pub fn new(library: Library, camera_id: u32) -> Self {
        Self {
            library,
            camera_id,
            core: CameraCore::new(
                format!("moravian_{}", camera_id),
                format!("Moravian Camera {}", camera_id),
                0.0,
            ),
            handle: SdkHandle(std::ptr::null_mut()),
            serial: None,
            limits: Limits::default(),
            read_modes: Vec::new(),
            read_mode: None,
            exposure: None,
        }
    }

    /// The camera a device address names: the bare camera id for libgxccd,
    /// `cx:<id>` or `gx:<id>` for the Windows drivers.
    pub fn from_address(address: &str) -> Result<Self, String> {
        let (library, id) = match address.split_once(':') {
            Some(("cx", id)) => (Library::CxUsb, id),
            Some(("gx", id)) => (Library::GxUsb, id),
            Some(_) => return Err(format!("Unknown Moravian camera address '{}'", address)),
            None => (Library::Gxccd, address),
        };
        let id = id
            .parse()
            .map_err(|_| format!("Invalid Moravian camera ID '{}'", address))?;
        Ok(Self::new(library, id))
    }

    /// The session on the open camera.
    pub(crate) fn session<'a>(&self, api: &'a dyn Api) -> Session<'a> {
        debug_assert_eq!(api.library(), self.library);
        // SAFETY: callers hold the connected check; while connected `handle`
        // is the live handle `api.initialize` returned for this camera's
        // library, released only by `close`.
        unsafe { Session::new(api, self.handle.0) }
    }

    /// The error for a failed call: the camera's disconnection when it says
    /// it is gone, else the library's reason.
    pub(crate) fn failure(&self, session: &Session<'_>, doing: &str) -> DriverError {
        if session.boolean(GBP_CONNECTED) == Some(false) {
            tracing::warn!(
                "Moravian camera '{}' is no longer connected ({} failed)",
                self.core.name,
                doing
            );
            return DriverError::Disconnected;
        }
        let reason = session.last_error();
        tracing::error!(
            "Moravian camera '{}': {} failed: {}",
            self.core.name,
            doing,
            reason
        );
        DriverError::SdkError(format!(
            "Moravian camera '{}' could not {}: {}",
            self.core.name, doing, reason
        ))
    }

    /// Initialize the camera and read what it is.
    pub(crate) fn open(&mut self, api: &dyn Api) -> Result<(), DriverError> {
        let handle = api.initialize(self.camera_id).ok_or_else(|| {
            DriverError::SdkError(format!(
                "Moravian camera {} could not be opened through {}: it is unplugged, its USB driver is not installed, or another program (SIPS, NINA, an INDI server) has it open",
                self.camera_id,
                self.library.file_name()
            ))
        })?;
        self.handle = SdkHandle(handle);
        let read = self.describe(api);
        if let Err(error) = read {
            self.session(api).release();
            self.handle = SdkHandle(std::ptr::null_mut());
            return Err(error);
        }
        self.core.connected = true;
        self.core.state = CameraState::Idle;
        discovery::remember_open(self);
        tracing::info!(
            "Connected to Moravian camera: {} ({}x{}, serial {}, read mode {:?}, gain {})",
            self.core.name,
            self.core.sensor_info.width,
            self.core.sensor_info.height,
            self.serial.as_deref().unwrap_or("not reported"),
            self.read_mode.and_then(|m| self.read_modes.get(m as usize)),
            match self.limits.max_gain {
                Some(max) => format!("0..{}", max),
                None => "fixed".to_string(),
            }
        );
        Ok(())
    }

    fn describe(&mut self, api: &dyn Api) -> Result<(), DriverError> {
        let session = self.session(api);
        if let Some(name) = session
            .string(GSP_CAMERA_DESCRIPTION)
            .filter(|n| !n.is_empty())
        {
            self.core.name = name;
        }
        self.serial = session.string(GSP_CAMERA_SERIAL).filter(|s| !s.is_empty());

        let integer = |index: c_int, what: &str| {
            session
                .integer(index)
                .ok_or_else(|| self.failure(&session, &format!("report its {}", what)))
        };
        let width = integer(GIP_CHIP_W, "sensor width")?;
        let height = integer(GIP_CHIP_D, "sensor height")?;
        let pixel_w = integer(GIP_PIXEL_W, "pixel width")?;
        let pixel_d = integer(GIP_PIXEL_D, "pixel height")?;
        let max_bin_x = integer(GIP_MAX_BINNING_X, "largest horizontal binning")?;
        let max_bin_y = integer(GIP_MAX_BINNING_Y, "largest vertical binning")?;
        if width <= 0 || height <= 0 || pixel_w <= 0 || pixel_d <= 0 {
            return Err(DriverError::SdkError(format!(
                "Moravian camera '{}' reported a {}x{} sensor of {}x{} nm pixels",
                self.core.name, width, height, pixel_w, pixel_d
            )));
        }
        let flag = |index: c_int| session.boolean(index).unwrap_or(false);

        // The read mode first: the full-scale value depends on it (gxccd.h:282).
        self.read_modes = (0..32)
            .map_while(|index| session.read_mode_name(index))
            .enumerate()
            .map(|(index, name)| {
                if name.is_empty() {
                    format!("Mode {}", index)
                } else {
                    name
                }
            })
            .collect();
        self.read_mode = None;
        if !self.read_modes.is_empty() {
            let default = session
                .integer(GIP_DEFAULT_READ_MODE)
                .and_then(|m| u32::try_from(m).ok())
                .filter(|m| (*m as usize) < self.read_modes.len())
                .unwrap_or(0);
            if session.set_read_mode(default) {
                self.read_mode = Some(default);
            } else {
                tracing::warn!(
                    "Moravian camera '{}' refused its default read mode {}: {}",
                    self.core.name,
                    default,
                    session.last_error()
                );
            }
        }
        if !session.set_binning(1, 1) {
            tracing::warn!(
                "Moravian camera '{}' refused 1x1 binning at connect: {}",
                self.core.name,
                session.last_error()
            );
        }

        self.limits = Limits {
            min_exposure_secs: session
                .integer(GIP_MINIMAL_EXPOSURE)
                .filter(|us| *us > 0)
                .map_or(0.0, |us| f64::from(us) / 1_000_000.0),
            // GBP_GAIN only says the camera reports its e-/ADU (gxccd.h:240); the
            // gain can be set when it has a register range (mi_ccd.cpp:198).
            max_gain: session
                .integer(GIP_MAX_GAIN)
                .filter(|max| *max > 0)
                .map(|max| u16::try_from(max).unwrap_or(u16::MAX)),
            asymmetric_binning: flag(GBP_ASYMMETRIC_BINNING),
            full_frame_cell: flag(GBP_RGB)
                .then(|| delivered_bayer(flag(GBP_DEBAYER_X_ODD), flag(GBP_DEBAYER_Y_ODD))),
        };
        let max_adu = full_scale(&session).unwrap_or(65535);
        let width = width as u32;
        let height = height as u32;
        self.core.sensor_info = SensorInfo {
            width,
            height,
            pixel_size_x: f64::from(pixel_w) / 1000.0,
            pixel_size_y: f64::from(pixel_d) / 1000.0,
            max_adu,
            bit_depth: bits_for(max_adu),
            color: flag(GBP_RGB) || flag(GBP_CMY) || flag(GBP_CMYG),
            bayer_pattern: self
                .limits
                .full_frame_cell
                .map(|cell| frame_bayer(cell, api.bottom_up(), height, 0, 0)),
        };
        let max_bin_x = max_bin_x.max(1);
        let max_bin_y = max_bin_y.max(1);
        self.core.capabilities = CameraCapabilities {
            can_cool: flag(GBP_COOLER),
            can_set_gain: self.limits.max_gain.is_some(),
            can_set_offset: false,
            can_set_binning: max_bin_x > 1 || max_bin_y > 1,
            can_subframe: flag(GBP_SUB_FRAME),
            has_shutter: flag(GBP_SHUTTER),
            has_guider_port: flag(GBP_GUIDE),
            max_bin_x,
            max_bin_y,
            supports_readout_modes: self.read_modes.len() > 1,
        };
        self.core.bin_x = 1;
        self.core.bin_y = 1;
        self.core.subframe = None;
        Ok(())
    }

    /// Release the camera, ending an exposure first (NINA's Disconnect).
    pub(crate) fn close(&mut self, api: &dyn Api) {
        if self.exposure.is_some() {
            self.abort(api);
        }
        self.session(api).release();
        discovery::forget_open(self);
        self.handle = SdkHandle(std::ptr::null_mut());
        self.core.connected = false;
        self.core.state = CameraState::Idle;
        self.core.exposure_started_at = None;
        tracing::info!("Disconnected from Moravian camera: {}", self.core.name);
    }

    pub(crate) fn status(&self, api: &dyn Api) -> Result<CameraStatus, DriverError> {
        let session = self.session(api);
        // The one reading that says whether the camera is still there
        // (gxccd.h:223); NINA's Connected is this flag.
        if session.boolean(GBP_CONNECTED) == Some(false) {
            tracing::warn!(
                "Moravian camera '{}' reports it is no longer connected",
                self.core.name
            );
            return Err(DriverError::Disconnected);
        }
        let exposure_remaining = (self.core.state == CameraState::Exposing)
            .then_some(self.core.exposure_started_at)
            .flatten()
            .map(|started| {
                (self.core.exposure_duration - started.elapsed().as_secs_f64()).max(0.0)
            });
        Ok(CameraStatus {
            state: self.core.state,
            sensor_temp: session.value(GV_CHIP_TEMPERATURE).map(f64::from),
            cooler_power: cooler_percent(&session),
            target_temp: Some(self.core.cooler().target_c),
            cooler_on: self.core.cooler().enabled,
            gain: self.core.gain,
            offset: self.core.offset,
            bin_x: self.core.bin_x,
            bin_y: self.core.bin_y,
            exposure_remaining,
        })
    }

    /// Apply this frame's binning, gain and region, and start it. Returns at
    /// once: the camera (or, for computer timing, `poll_complete`) ends it.
    pub(crate) fn begin(
        &mut self,
        api: &dyn Api,
        params: &ExposureParams,
    ) -> Result<(), DriverError> {
        if self.exposure.is_some() {
            return Err(DriverError::SdkError(format!(
                "Moravian camera '{}' is already exposing",
                self.core.name
            )));
        }
        let caps = &self.core.capabilities;
        let (bin_x, bin_y) = (params.bin_x, params.bin_y);
        if bin_x < 1 || bin_y < 1 || bin_x > caps.max_bin_x || bin_y > caps.max_bin_y {
            return Err(DriverError::InvalidParameter(format!(
                "Moravian camera '{}' bins from 1x1 to {}x{}, not {}x{}",
                self.core.name, caps.max_bin_x, caps.max_bin_y, bin_x, bin_y
            )));
        }
        if bin_x != bin_y && !self.limits.asymmetric_binning {
            return Err(DriverError::InvalidParameter(format!(
                "Moravian camera '{}' cannot bin {}x{}: its horizontal and vertical binning must match",
                self.core.name, bin_x, bin_y
            )));
        }
        if params.subframe.is_some() && !caps.can_subframe {
            return Err(DriverError::InvalidParameter(format!(
                "Moravian camera '{}' cannot read a subframe",
                self.core.name
            )));
        }
        if !params.duration_secs.is_finite() || params.duration_secs < 0.0 {
            return Err(DriverError::InvalidParameter(format!(
                "exposure time {} s is not valid",
                params.duration_secs
            )));
        }
        let roi = sdk_roi(
            self.core.sensor_info.width,
            self.core.sensor_info.height,
            bin_x as u32,
            bin_y as u32,
            params.subframe.as_ref(),
            api.bottom_up(),
        )
        .map_err(|reason| {
            DriverError::InvalidParameter(format!(
                "Moravian camera '{}': {}",
                self.core.name, reason
            ))
        })?;

        let session = self.session(api);
        if !session.set_binning(bin_x as u32, bin_y as u32) {
            return Err(self.failure(&session, &format!("set {}x{} binning", bin_x, bin_y)));
        }
        if let Some(gain) = params.gain {
            self.apply_gain(&session, gain)?;
        }
        if let Some(name) = params.readout_mode.as_deref() {
            self.apply_read_mode_named(&session, name)?;
        }
        // Read only after the read mode and binning are set (gxccd.h:282).
        if let Some(max_adu) = full_scale(&session) {
            self.core.sensor_info.max_adu = max_adu;
            self.core.sensor_info.bit_depth = bits_for(max_adu);
        }

        let seconds = if params.duration_secs < self.limits.min_exposure_secs {
            tracing::info!(
                "Moravian camera '{}': {} s is below its shortest exposure; exposing {} s",
                self.core.name,
                params.duration_secs,
                self.limits.min_exposure_secs
            );
            self.limits.min_exposure_secs
        } else {
            params.duration_secs
        };
        let open_shutter = params.frame_type.opens_shutter();
        let bayer = (bin_x == 1 && bin_y == 1)
            .then_some(self.limits.full_frame_cell)
            .flatten()
            .map(|cell| {
                let (x, y) = params
                    .subframe
                    .as_ref()
                    .map_or((0, 0), |sf| (sf.start_x, sf.start_y));
                frame_bayer(cell, api.bottom_up(), self.core.sensor_info.height, x, y)
            });

        let started = match api.timing() {
            Timing::Camera => session.start_exposure(seconds, open_shutter, roi),
            Timing::Computer => session.begin_exposure(open_shutter),
        };
        if !started {
            return Err(self.failure(&session, &format!("start a {} s exposure", seconds)));
        }
        let now = Instant::now();
        self.exposure = Some(Exposure {
            roi,
            open_shutter,
            bayer,
            started: now,
            ended: std::sync::Mutex::new(None),
        });
        self.core.bin_x = bin_x;
        self.core.bin_y = bin_y;
        self.core.subframe = params.subframe.clone();
        self.core.exposure_duration = seconds;
        self.core.exposure_started_at = Some(now);
        self.core.state = CameraState::Exposing;
        tracing::info!(
            "Started {} s {} exposure on Moravian camera '{}' ({}x{} at {}x{} binning)",
            seconds,
            params.frame_type.as_str(),
            self.core.name,
            roi.w,
            roi.h,
            bin_x,
            bin_y
        );
        Ok(())
    }

    /// Whether the frame can be read. Asks the camera only once the exposure
    /// time has passed (gxccd.h:397-403). For computer timing this is where
    /// the exposure is ended.
    pub(crate) fn poll_complete(&self, api: &dyn Api) -> Result<bool, DriverError> {
        let Some(exposure) = &self.exposure else {
            return Ok(true);
        };
        if exposure.started.elapsed().as_secs_f64() < self.core.exposure_duration {
            return Ok(false);
        }
        let session = self.session(api);
        match api.timing() {
            Timing::Camera => session
                .image_ready()
                .ok_or_else(|| self.failure(&session, "report whether the frame is ready")),
            Timing::Computer => {
                self.end_computer_timed(&session, exposure)?;
                Ok(true)
            }
        }
    }

    /// End a computer-timed exposure once; the frame is then read with `get_image`.
    fn end_computer_timed(
        &self,
        session: &Session<'_>,
        exposure: &Exposure,
    ) -> Result<(), DriverError> {
        let mut ended = exposure.ended.lock().unwrap_or_else(|e| e.into_inner());
        if ended.is_none() {
            if !session.end_exposure(exposure.open_shutter, false) {
                return Err(self.failure(session, "end the exposure"));
            }
            *ended = Some(Instant::now());
        }
        Ok(())
    }

    /// Read the frame of an exposure whose image is ready (camera timing) or
    /// whose time has passed (computer timing).
    pub(crate) fn read_frame(&mut self, api: &dyn Api) -> Result<ImageData, DriverError> {
        let Some(exposure) = &self.exposure else {
            return Err(DriverError::SdkError(format!(
                "Moravian camera '{}' has no exposure to download",
                self.core.name
            )));
        };
        let session = self.session(api);
        let (width, height) = (exposure.roi.w as u32, exposure.roi.h as u32);
        let mut pixels = vec![0u16; width as usize * height as usize];
        self.core.state = CameraState::Downloading;
        let (read, exposure_time) = match api.timing() {
            Timing::Camera => (session.read_image(&mut pixels), self.core.exposure_duration),
            Timing::Computer => {
                self.end_computer_timed(&session, exposure)?;
                // The frame was exposed from the begin call to the end call.
                let open = exposure
                    .ended_at()
                    .map_or(self.core.exposure_duration, |ended| {
                        ended.duration_since(exposure.started).as_secs_f64()
                    });
                (session.get_image(exposure.roi, &mut pixels), open)
            }
        };
        let bayer = exposure.bayer;
        if !read {
            let error = self.failure(&session, "download the frame");
            self.exposure = None;
            self.core.exposure_started_at = None;
            self.core.state = CameraState::Error;
            return Err(error);
        }
        if api.bottom_up() {
            mirror_vertical_u16(&mut pixels, width as usize, height as usize);
        }
        let temperature = session.value(GV_CHIP_TEMPERATURE).map(f64::from);
        self.exposure = None;
        self.core.exposure_started_at = None;
        self.core.state = CameraState::Idle;
        Ok(Frame {
            temperature,
            exposure_time,
            readout_mode: self.read_mode_name(),
            ..self.core.frame(
                width,
                height,
                pixels,
                self.core.sensor_info.bit_depth,
                bayer,
            )
        }
        .into_image())
    }

    /// Stop the exposure and discard its frame.
    pub(crate) fn abort(&mut self, api: &dyn Api) {
        if let Some(exposure) = self.exposure.take() {
            let session = self.session(api);
            let stopped = match api.timing() {
                Timing::Camera => session.abort_exposure(false),
                Timing::Computer => {
                    exposure.ended_at().is_some()
                        || session.end_exposure(exposure.open_shutter, true)
                }
            };
            if !stopped {
                tracing::warn!(
                    "Moravian camera '{}' did not confirm the abort: {}",
                    self.core.name,
                    session.last_error()
                );
            }
            tracing::info!("Aborted exposure on Moravian camera '{}'", self.core.name);
        }
        self.core.state = CameraState::Idle;
        self.core.exposure_started_at = None;
    }

    pub(crate) fn apply_gain(
        &mut self,
        session: &Session<'_>,
        gain: i32,
    ) -> Result<(), DriverError> {
        let Some(max) = self.limits.max_gain else {
            // A CCD: the gain is fixed, so a frame's gain request has nothing to
            // change (the Atik and FLI drivers do the same).
            tracing::debug!(
                "Moravian camera '{}' has a fixed gain; gain {} not applied",
                self.core.name,
                gain
            );
            return Ok(());
        };
        let register = u16::try_from(gain)
            .ok()
            .filter(|g| *g <= max)
            .ok_or_else(|| {
                DriverError::InvalidParameter(format!(
                    "Moravian camera '{}' takes gain 0 to {}, not {}",
                    self.core.name, max, gain
                ))
            })?;
        match session.set_gain(register) {
            Some(true) => {
                self.core.gain = gain;
                Ok(())
            }
            Some(false) => Err(self.failure(session, &format!("set gain {}", gain))),
            None => Err(DriverError::NotSupported),
        }
    }

    pub(crate) fn apply_read_mode(
        &mut self,
        session: &Session<'_>,
        index: u32,
    ) -> Result<(), DriverError> {
        if index as usize >= self.read_modes.len() {
            return Err(DriverError::InvalidParameter(format!(
                "Moravian camera '{}' has {} read modes, not mode {}",
                self.core.name,
                self.read_modes.len(),
                index
            )));
        }
        if !session.set_read_mode(index) {
            return Err(self.failure(session, &format!("set read mode {}", index)));
        }
        self.read_mode = Some(index);
        Ok(())
    }

    fn apply_read_mode_named(
        &mut self,
        session: &Session<'_>,
        name: &str,
    ) -> Result<(), DriverError> {
        let index = self
            .read_modes
            .iter()
            .position(|mode| mode.eq_ignore_ascii_case(name))
            .ok_or_else(|| {
                DriverError::InvalidParameter(format!(
                    "Moravian camera '{}' has no read mode '{}' (it has {})",
                    self.core.name,
                    name,
                    self.read_modes.join(", ")
                ))
            })?;
        self.apply_read_mode(session, index as u32)
    }

    pub(crate) fn read_mode_name(&self) -> Option<String> {
        self.read_mode
            .and_then(|mode| self.read_modes.get(mode as usize))
            .cloned()
    }

    pub(crate) fn cooler(
        &mut self,
        api: &dyn Api,
        enabled: bool,
        target: Option<f64>,
    ) -> Result<(), DriverError> {
        let session = self.session(api);
        if enabled {
            // Setting a temperature is what switches cooling on; without a named
            // set-point the one this driver holds is kept.
            let target = target.unwrap_or(self.core.cooler().target_c);
            if !session.set_temperature(target as c_float) {
                return Err(self.failure(&session, &format!("set the cooler to {:.1} C", target)));
            }
            self.core.update_cooler(|cooler| {
                cooler.enabled = true;
                cooler.target_c = target;
            });
            tracing::info!("Moravian cooler on: target {} C", target);
        } else {
            if !session.set_temperature(TEMP_COOLER_OFF) {
                return Err(self.failure(&session, "turn the cooler off"));
            }
            self.core.update_cooler(|cooler| cooler.enabled = false);
            tracing::info!("Moravian cooler off");
        }
        Ok(())
    }

    /// Wait for the frame of the exposure in progress and read it.
    pub(crate) async fn wait_and_read(&mut self) -> Result<ImageData, DriverError> {
        let remaining = self
            .exposure
            .as_ref()
            .map(|e| self.core.exposure_duration - e.started.elapsed().as_secs_f64())
            .unwrap_or(0.0);
        if remaining > 0.0 {
            tokio::time::sleep(Duration::from_secs_f64(remaining)).await;
        }
        let deadline = Instant::now() + Duration::from_secs(READOUT_TIMEOUT_SECS);
        loop {
            let sdk = self.library.lock().await?;
            let ready = match self.poll_complete(sdk.api()) {
                Ok(ready) => ready,
                Err(error) => {
                    self.abort(sdk.api());
                    self.core.state = CameraState::Error;
                    return Err(error);
                }
            };
            if ready {
                return self.read_frame(sdk.api());
            }
            drop(sdk);
            if Instant::now() >= deadline {
                let sdk = self.library.lock().await?;
                self.abort(sdk.api());
                self.core.state = CameraState::Error;
                return Err(DriverError::Timeout(format!(
                    "Moravian camera '{}' did not finish reading the frame within {} s of the exposure's end",
                    self.core.name, READOUT_TIMEOUT_SECS
                )));
            }
            tokio::time::sleep(Duration::from_millis(READOUT_POLL_MS)).await;
        }
    }
}

/// The largest pixel value the camera delivers in its current read mode and binning.
pub(crate) fn full_scale(session: &Session<'_>) -> Option<u32> {
    session
        .integer(GIP_MAX_PIXEL_VALUE)
        .and_then(|v| u32::try_from(v).ok())
        .filter(|v| *v > 0)
}

/// Cooler power in percent to 0.1; the libraries report a fraction
/// (gxccd.h:323-324, mi_ccd.cpp:969).
pub(crate) fn cooler_percent(session: &Session<'_>) -> Option<f64> {
    session
        .value(GV_POWER_UTILIZATION)
        .map(|fraction| (f64::from(fraction) * 1000.0).round() / 10.0)
}

#[async_trait]
impl DeviceDriver for MoravianCamera {
    fn id(&self) -> &str {
        &self.core.device_id
    }

    fn name(&self) -> &str {
        &self.core.name
    }

    fn vendor(&self) -> Vendor {
        Vendor::Moravian
    }

    fn serial_number(&self) -> Option<String> {
        self.serial.clone()
    }

    fn is_connected(&self) -> bool {
        self.core.connected
    }

    async fn connect(&mut self) -> Result<(), DriverError> {
        if self.core.connected {
            return Ok(());
        }
        let sdk = self.library.lock().await?;
        self.open(sdk.api())
    }

    async fn disconnect(&mut self) -> Result<(), DriverError> {
        if !self.core.connected {
            return Ok(());
        }
        let sdk = self.library.lock().await?;
        self.close(sdk.api());
        Ok(())
    }
}
