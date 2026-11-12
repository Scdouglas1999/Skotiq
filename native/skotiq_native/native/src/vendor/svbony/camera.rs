//! `SvbonyCamera` state, connect and disconnect.

use super::*;

/// How a frame is taken.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Capture {
    /// SVB_MODE_TRIG_SOFT: one frame per SVBSendSoftTrigger, as the INDI
    /// driver (svbony_base.cpp:170-220, 646-653) and NINA (SVBonySDK.cs:86,
    /// 250) take every exposure.
    SoftTrigger,
    /// SVB_MODE_NORMAL video, for an SDK or camera without soft triggering:
    /// the exposure is the next frame of the stream.
    FreeRunning,
}

#[derive(Debug)]
pub struct SvbonyCamera {
    pub(crate) camera_id: i32,
    pub(crate) core: CameraCore,
    pub(crate) serial_number: Option<String>,
    pub(crate) image_type: SvbImgType,
    pub(crate) image_buffer: Vec<u8>,
    pub(crate) controls: Controls,
    pub(crate) supported_bins: Vec<i32>,
    pub(crate) capture: Capture,
    /// The region SVBSetROIFormat last accepted.
    pub(crate) roi: Option<Roi>,
    /// A triggered frame has not been read (the exposure was aborted or its
    /// download failed). The SDK can still hand it out on the next read, which
    /// N.I.N.A. shipped a fix for ("sometimes showing the exposure before the
    /// latest one after a cancelled exposure"), so the next exposure drains it.
    pub(crate) unread_frame: bool,
}

impl SvbonyCamera {
    /// The SDK, held for this camera (see `sdk_loader::lock_scope`).
    pub(crate) async fn sdk(
        &self,
    ) -> Result<crate::vendor::sdk_loader::SdkGuard<SvbonySdk>, skotiq_device::DriverError> {
        use crate::vendor::sdk_loader::{device_key, lock_scope};
        SvbonySdk::slot()
            .lock_device(
                lock_scope(&skotiq_device::Vendor::Svbony),
                device_key(self.camera_id),
            )
            .await
    }

    pub fn new(camera_id: i32) -> Self {
        Self {
            camera_id,
            core: CameraCore::new(
                format!("svbony_{}", camera_id),
                format!("SVBony Camera {}", camera_id),
            ),
            serial_number: None,
            image_type: SvbImgType::Raw16,
            image_buffer: Vec::new(),
            controls: Controls::default(),
            supported_bins: vec![1],
            capture: Capture::SoftTrigger,
            roi: None,
            unread_frame: false,
        }
    }

    /// Read a control (takes the SDK lock).
    pub(crate) async fn control(&self, control: SvbControlType) -> Result<i64, DriverError> {
        self.core.require_connected()?;
        let sdk = SvbonySdk::lock().await?;
        read_control(&sdk, self.camera_id, control)
    }

    /// Write a control and return what the camera holds afterwards, under a
    /// lock the caller holds.
    pub(crate) fn set_and_read_back(
        &self,
        sdk: &SvbonySdk,
        control: SvbControlType,
        value: i64,
    ) -> Result<i64, DriverError> {
        write_control(sdk, self.camera_id, control as c_int, value)?;
        match read_control(sdk, self.camera_id, control) {
            Ok(actual) => {
                if actual != value {
                    tracing::info!(
                        "SVBony {}: {} {} is outside the camera's range; it holds {}",
                        self.core.name,
                        control_name(control as c_int),
                        value,
                        actual
                    );
                }
                Ok(actual)
            }
            Err(e) => {
                tracing::warn!(
                    "SVBony {}: the {} could not be read back after setting it to {} ({})",
                    self.core.name,
                    control_name(control as c_int),
                    value,
                    e
                );
                Ok(value)
            }
        }
    }

    /// The region for a bin and subframe, checked against the camera.
    pub(crate) fn roi_for(
        &self,
        bin_x: i32,
        bin_y: i32,
        subframe: Option<&SubFrame>,
    ) -> Result<Roi, DriverError> {
        // SVBony bins both axes alike.
        let bin = bin_x.min(bin_y);
        if !self.supported_bins.contains(&bin) {
            return Err(DriverError::InvalidParameter(format!(
                "{} bins {:?}; bin {} was requested",
                self.core.name, self.supported_bins, bin
            )));
        }
        Roi::for_frame(
            self.core.sensor_info.width,
            self.core.sensor_info.height,
            bin,
            subframe,
            self.core.sensor_info.color,
        )
    }

    /// Give the SDK the region, under a lock the caller holds, and record what
    /// frames will cover. Capture must be stopped for SVBSetROIFormat.
    pub(crate) fn apply_roi(
        &mut self,
        sdk: &SvbonySdk,
        roi: Roi,
        subframe_requested: bool,
    ) -> Result<(), DriverError> {
        if self.roi != Some(roi) {
            stop_capture(sdk, self.camera_id);
            // SAFETY: the camera is open; all arguments are plain integers.
            let result = unsafe {
                (sdk.set_roi_format)(
                    self.camera_id,
                    roi.start_x,
                    roi.start_y,
                    roi.width,
                    roi.height,
                    roi.bin,
                )
            };
            check(result, "set the readout region")?;
            self.roi = Some(roi);
        }
        self.core.bin_x = roi.bin;
        self.core.bin_y = roi.bin;
        self.core.subframe = subframe_requested.then(|| roi.subframe());
        Ok(())
    }

    /// Everything connect sets up after SVBOpenCamera, under its lock.
    fn configure(&mut self, sdk: &SvbonySdk) -> Result<(), DriverError> {
        // SAFETY: SvbCameraProperty is `#[repr(C)]` POD; zeroed is a valid value for the SDK to overwrite.
        let mut prop: SvbCameraProperty = unsafe { std::mem::zeroed() };
        // SAFETY: the camera is open; `&mut prop` is a valid out-pointer laid out as SVB_CAMERA_PROPERTY.
        let result = unsafe { (sdk.get_camera_property)(self.camera_id, &mut prop) };
        check(result, "read the camera's properties")?;

        // SAFETY: SvbCameraPropertyEx is `#[repr(C)]` POD; zeroed is a valid value.
        let mut prop_ex: SvbCameraPropertyEx = unsafe { std::mem::zeroed() };
        // SAFETY: the camera is open; `&mut prop_ex` is a valid out-pointer laid out as SVB_CAMERA_PROPERTY_EX.
        let property_ex_result =
            unsafe { (sdk.get_camera_property_ex)(self.camera_id, &mut prop_ex) };
        if SvbError::from_i32(property_ex_result) != SvbError::Success {
            // prop_ex keeps its zeroed seed, so cooling and the guide port are
            // published as absent for the session; name the query that took
            // them away.
            tracing::warn!(
                "SVBony camera {}: SVBGetCameraPropertyEx failed ({:?}); cooling and ST4 guiding are reported as unsupported for this session",
                self.camera_id,
                SvbError::from_i32(property_ex_result)
            );
        }

        self.controls = Controls::read(sdk, self.camera_id)?;

        self.image_type = SvbImgType::preferred(&prop.supported_video_format).ok_or_else(|| {
            DriverError::SdkError(format!(
                "{} offers no 8- or 16-bit raw or mono output Skotiq can read (SVB_IMG_TYPE codes {:?})",
                self.core.name, prop.supported_video_format
            ))
        })?;
        // SAFETY: the camera is open; the format is one the camera listed.
        let result =
            unsafe { (sdk.set_output_image_type)(self.camera_id, self.image_type as c_int) };
        check(
            result,
            &format!("select the {:?} output format", self.image_type),
        )?;

        self.capture = select_capture(sdk, self.camera_id);

        for control in self.controls.reset_at_connect() {
            if let Err(e) =
                write_control(sdk, self.camera_id, control.control_type, control.default)
            {
                tracing::debug!(
                    "SVBony {}: the {} kept its value ({})",
                    self.core.name,
                    control_name(control.control_type),
                    e
                );
            }
        }

        let width = u32::try_from(prop.max_width).map_err(|_| {
            DriverError::SdkError(format!(
                "SVBony reported invalid sensor width: {}",
                prop.max_width
            ))
        })?;
        let height = u32::try_from(prop.max_height).map_err(|_| {
            DriverError::SdkError(format!(
                "SVBony reported invalid sensor height: {}",
                prop.max_height
            ))
        })?;
        let bit_depth = u32::try_from(prop.max_bit_depth).map_err(|_| {
            DriverError::SdkError(format!(
                "SVBony reported invalid bit_depth: {}",
                prop.max_bit_depth
            ))
        })?;
        // SupportedBins ends at the first 0 (SVBCameraSDK.h).
        self.supported_bins = prop
            .supported_bins
            .iter()
            .copied()
            .take_while(|&bin| bin > 0)
            .collect();
        if self.supported_bins.is_empty() {
            self.supported_bins = vec![1];
        }
        let max_bin = self.supported_bins.iter().copied().max().unwrap_or(1);

        // SVB_CAMERA_PROPERTY carries no pixel size; SVBGetSensorPixelSize is
        // the only source (svbony_base.cpp:760 queries it the same way).
        let mut pixel_size: f32 = 0.0;
        // SAFETY: the camera is open; `&mut pixel_size` is a valid f32 out-pointer.
        let result = unsafe { (sdk.get_sensor_pixel_size)(self.camera_id, &mut pixel_size) };
        if SvbError::from_i32(result) != SvbError::Success {
            // 0.0 becomes the FITS XPIXSZ card and every image-scale hint; name
            // the failure so a 0 um sensor is traceable to this query.
            tracing::warn!(
                "SVBony camera {}: SVBGetSensorPixelSize failed ({:?}); pixel size is reported as unknown (0.0 um) for this session",
                self.camera_id,
                SvbError::from_i32(result)
            );
        }

        let is_color = prop.is_color_cam != 0;
        self.core.sensor_info = SensorInfo {
            width,
            height,
            pixel_size_x: f64::from(pixel_size),
            pixel_size_y: f64::from(pixel_size),
            max_adu: container_max_adu(self.image_type, bit_depth),
            bit_depth,
            color: is_color,
            bayer_pattern: (is_color && self.image_type.is_mosaic())
                .then(|| bayer_from_asi_index(prop.bayer_pattern)),
            saturation_adu: None,
        };

        self.core.capabilities = CameraCapabilities {
            // Cooling is SVB_CAMERA_PROPERTY_EX.bSupportControlTemp (svbony_base.cpp:621).
            can_cool: prop_ex.b_support_control_temp != 0,
            can_set_gain: self.controls.has(SvbControlType::Gain),
            can_set_offset: self.controls.has(SvbControlType::BlackLevel),
            can_set_binning: max_bin > 1,
            can_subframe: true,
            // SVBony cameras are CMOS with no mechanical shutter, and
            // SVB_CAMERA_PROPERTY exposes no such field to read.
            has_shutter: false,
            has_guider_port: prop_ex.b_support_pulse_guide != 0,
            max_bin_x: max_bin,
            max_bin_y: max_bin,
            supports_readout_modes: false,
        };

        self.roi = None;
        let full_frame = Roi::for_frame(width, height, 1, None, is_color)?;
        self.apply_roi(sdk, full_frame, false)
    }

    /// Gain, offset and the cooler as the camera holds them, after the
    /// post-connect settle. A cooler left running stays reported as running.
    fn read_settings(&mut self, sdk: &SvbonySdk) {
        if let Ok(gain) = read_control(sdk, self.camera_id, SvbControlType::Gain) {
            self.core.gain = gain as i32;
        }
        if let Ok(offset) = read_control(sdk, self.camera_id, SvbControlType::BlackLevel) {
            self.core.offset = offset as i32;
        }
        if self.core.capabilities.can_cool {
            if let Ok(enabled) = read_control(sdk, self.camera_id, SvbControlType::CoolerEnable) {
                self.core
                    .update_cooler(|cooler| cooler.enabled = Some(enabled != 0));
            }
            if let Ok(target) = read_control(sdk, self.camera_id, SvbControlType::TargetTemperature)
            {
                self.core
                    .update_cooler(|cooler| cooler.target_c = Some(target as f64 / 10.0));
            }
        }
    }
}

/// Stop capture, under a lock the caller holds. SVBStopVideoCapture "will
/// return success if already stopped" (SVBCameraSDK.h).
pub(crate) fn stop_capture(sdk: &SvbonySdk, camera_id: c_int) {
    // SAFETY: the camera is open; the argument is a plain integer.
    let result = unsafe { (sdk.stop_video_capture)(camera_id) };
    if SvbError::from_i32(result) != SvbError::Success {
        tracing::debug!(
            "SVBony camera {}: SVBStopVideoCapture answered {:?}",
            camera_id,
            SvbError::from_i32(result)
        );
    }
}

/// Put the camera in soft-trigger mode, or in free-running video when the SDK
/// or the camera cannot trigger. The mode is kept in the camera between
/// programs, so it is always set.
fn select_capture(sdk: &SvbonySdk, camera_id: c_int) -> Capture {
    let (Some(set_mode), Some(_)) = (sdk.set_camera_mode, sdk.send_soft_trigger) else {
        tracing::warn!(
            "SVBony camera {}: this SVBony SDK cannot trigger single frames; exposures are taken from the video stream",
            camera_id
        );
        return Capture::FreeRunning;
    };
    // SAFETY: the camera is open and not capturing; the mode is an SVB_CAMERA_MODE value.
    let result = unsafe { set_mode(camera_id, SvbCameraMode::SoftTrigger as c_int) };
    if SvbError::from_i32(result) == SvbError::Success {
        return Capture::SoftTrigger;
    }
    tracing::warn!(
        "SVBony camera {}: soft-trigger mode refused ({:?}); exposures are taken from the video stream",
        camera_id,
        SvbError::from_i32(result)
    );
    // SAFETY: as above.
    let result = unsafe { set_mode(camera_id, SvbCameraMode::Normal as c_int) };
    if SvbError::from_i32(result) != SvbError::Success {
        tracing::warn!(
            "SVBony camera {}: video mode refused as well ({:?})",
            camera_id,
            SvbError::from_i32(result)
        );
    }
    Capture::FreeRunning
}

/// An SV305M Pro closed with an offset above 0 takes that offset as its new
/// zero at the next open, and lower offsets clip (NINA SVBonySDK.cs:54-77).
/// NINA opens the camera, sets gain and offset to 0 and closes it again before
/// every connect; so does Skotiq. Best effort: if this open fails, the real
/// one below reports why.
fn clear_offset_from_last_session(sdk: &SvbonySdk, camera_id: c_int) {
    // SAFETY: `camera_id` comes from the SDK's camera list read just before.
    if unsafe { (sdk.open_camera)(camera_id) } != SvbError::Success as c_int {
        return;
    }
    for control in [SvbControlType::Gain, SvbControlType::BlackLevel] {
        let _ = write_control(sdk, camera_id, control as c_int, 0);
    }
    // SAFETY: the camera was opened above.
    unsafe { (sdk.close_camera)(camera_id) };
}

#[async_trait]
impl DeviceDriver for SvbonyCamera {
    fn id(&self) -> &str {
        &self.core.device_id
    }

    fn name(&self) -> &str {
        &self.core.name
    }

    fn vendor(&self) -> Vendor {
        Vendor::Svbony
    }

    fn serial_number(&self) -> Option<String> {
        self.serial_number.clone()
    }

    fn is_connected(&self) -> bool {
        self.core.connected
    }

    async fn connect(&mut self) -> Result<(), DriverError> {
        if self.core.connected {
            return Ok(());
        }

        let svb = SvbonySdk::installed()?;
        let sdk = svb.lock().await;

        // A saved profile connects before any discovery ran in this process;
        // the SDK only knows the CameraID after listing the cameras.
        let listed = listed_cameras(&sdk);
        let camera = listed
            .iter()
            .find(|c| c.camera_id == self.camera_id)
            .ok_or_else(|| {
                DriverError::DeviceNotFound(format!(
                    "SVBony camera {} is not connected (the SVBony SDK lists {} camera(s)); check its USB cable, or search for devices again",
                    self.camera_id,
                    listed.len()
                ))
            })?;
        if !camera.name.is_empty() {
            self.core.name = camera.name.clone();
        }
        self.serial_number = camera.serial_number.clone();

        clear_offset_from_last_session(&sdk, self.camera_id);

        // SAFETY: `camera_id` is in the SDK's camera list read above.
        let result = unsafe { (sdk.open_camera)(self.camera_id) };
        if SvbError::from_i32(result) != SvbError::Success {
            return Err(match SvbError::from_i32(result) {
                SvbError::CameraRemoved => DriverError::Disconnected,
                error => DriverError::SdkError(format!(
                    "{} could not be opened ({:?}). Close any other program using it (SharpCap, NINA, PHD2, ASCOM drivers) and try again",
                    self.core.name, error
                )),
            });
        }

        if let Err(e) = self.configure(&sdk) {
            // SAFETY: the camera was opened above and is released on this failure path.
            unsafe { (sdk.close_camera)(self.camera_id) };
            return Err(e);
        }
        self.core.connected = true;
        self.core.state = CameraState::Idle;
        self.unread_frame = false;

        // Control reads right after configuring can return stale firmware
        // values; the settle runs without the SDK lock.
        drop(sdk);
        let quirk_lookup_id = format!("native:svbony:{}", self.core.name);
        if let Some(delay_ms) = crate::quirks::get_connect_delay_ms(&quirk_lookup_id) {
            tracing::debug!(
                "Applying DelayAfterConnect quirk: sleeping {}ms before reading controls from {}",
                delay_ms,
                self.core.name
            );
            tokio::time::sleep(std::time::Duration::from_millis(delay_ms)).await;
        }
        let sdk = svb.lock().await;
        self.read_settings(&sdk);

        tracing::info!(
            "Connected to SVBony camera: {} ({}x{}, {:?}, {:?})",
            self.core.name,
            self.core.sensor_info.width,
            self.core.sensor_info.height,
            self.image_type,
            self.capture
        );

        Ok(())
    }

    async fn disconnect(&mut self) -> Result<(), DriverError> {
        if !self.core.connected {
            return Ok(());
        }

        let sdk = SvbonySdk::lock().await?;
        stop_capture(&sdk, self.camera_id);
        // SAFETY: the camera was opened in connect(). SVBCloseCamera is the
        // release for SVBOpenCamera and succeeds on a closed camera.
        let result = unsafe { (sdk.close_camera)(self.camera_id) };

        // The handle is gone either way (a camera unplugged answers
        // SVB_ERROR_INVALID_ID), so the next connect starts clean.
        self.core.connected = false;
        self.core.state = CameraState::Idle;
        self.core.exposure_started_at = None;
        self.roi = None;
        check(result, "close the camera")?;
        tracing::info!("Disconnected from SVBony camera: {}", self.core.name);
        Ok(())
    }
}
