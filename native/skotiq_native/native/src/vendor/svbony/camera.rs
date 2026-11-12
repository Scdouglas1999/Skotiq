//! `SvbonyCamera` state, inherent helpers and `DeviceDriver`.

use super::*;

#[derive(Debug)]
pub struct SvbonyCamera {
    pub(crate) camera_id: i32,
    pub(crate) core: CameraCore,
    pub(crate) image_type: SvbImgType,
    pub(crate) image_buffer: Vec<u8>,
}

impl SvbonyCamera {
    pub fn new(camera_id: i32) -> Self {
        Self {
            camera_id,
            core: CameraCore::new(
                format!("svbony_{}", camera_id),
                format!("SVBony Camera {}", camera_id),
            ),
            image_type: SvbImgType::Raw16,
            image_buffer: Vec::new(),
        }
    }

    /// Get control value under a lock the caller already holds
    pub(crate) fn get_control_value(
        &self,
        sdk: &SvbonySdk,
        control_type: SvbControlType,
    ) -> Result<i64, DriverError> {
        self.core.require_connected()?;
        let mut value: c_long = 0;
        let mut is_auto: c_int = 0;
        // SAFETY: `self.camera_id` was validated by SVBOpenCamera in `connect`; `&mut value` and `&mut is_auto` are valid stack out-pointers to POD types; `control_type as c_int` enumerates a SvbControlType discriminant per SVBCameraSDK.h.
        let result = unsafe {
            (sdk.get_control_value)(
                self.camera_id,
                control_type as c_int,
                &mut value,
                &mut is_auto,
            )
        };
        if SvbError::from_i32(result) != SvbError::Success {
            return Err(SvbError::from_i32(result).to_native_error("get control value"));
        }
        // Why: c_long -> i64 is widening on every Tier 1 target (LP64: c_long is i64;
        // LLP64 Windows: c_long is i32). Value range is preserved.
        Ok(value as i64)
    }

    /// Get control value (async - takes the SDK lock)
    pub(crate) async fn get_control_value_async(
        &self,
        control_type: SvbControlType,
    ) -> Result<i64, DriverError> {
        self.core.require_connected()?;
        let sdk = SvbonySdk::lock().await?;
        let mut value: c_long = 0;
        let mut is_auto: c_int = 0;
        // SAFETY: `self.camera_id` was validated by SVBOpenCamera in `connect`; `&mut value` and `&mut is_auto` are valid stack out-pointers to POD types; `control_type as c_int` enumerates a SvbControlType discriminant per SVBCameraSDK.h.
        let result = unsafe {
            (sdk.get_control_value)(
                self.camera_id,
                control_type as c_int,
                &mut value,
                &mut is_auto,
            )
        };
        if SvbError::from_i32(result) != SvbError::Success {
            return Err(SvbError::from_i32(result).to_native_error("get control value"));
        }
        // Why: c_long -> i64 is widening on every Tier 1 target. Range is preserved.
        Ok(value as i64)
    }

    /// Set control value under a lock the caller already holds
    pub(crate) fn set_control_value(
        &self,
        sdk: &SvbonySdk,
        control_type: SvbControlType,
        value: i64,
    ) -> Result<(), DriverError> {
        self.core.require_connected()?;
        // SAFETY: `self.camera_id` is the camera ID validated by SVBOpenCamera in `connect`; SVBSetControlValue takes all-POD arguments (c_int/c_long/c_int) with no out-pointers.
        let result = unsafe {
            (sdk.set_control_value)(self.camera_id, control_type as c_int, value as c_long, 0)
        };
        if SvbError::from_i32(result) != SvbError::Success {
            return Err(SvbError::from_i32(result).to_native_error("set control value"));
        }
        Ok(())
    }

    /// Set control value (async - takes the SDK lock)
    pub(crate) async fn set_control_value_async(
        &self,
        control_type: SvbControlType,
        value: i64,
    ) -> Result<(), DriverError> {
        self.core.require_connected()?;
        let sdk = SvbonySdk::lock().await?;
        // SAFETY: `self.camera_id` is the camera ID validated by SVBOpenCamera in `connect`; SVBSetControlValue takes all-POD arguments (c_int/c_long/c_int) with no out-pointers.
        let result = unsafe {
            (sdk.set_control_value)(self.camera_id, control_type as c_int, value as c_long, 0)
        };
        if SvbError::from_i32(result) != SvbError::Success {
            return Err(SvbError::from_i32(result).to_native_error("set control value"));
        }
        Ok(())
    }

    /// Get the min/max range for a control type (async - takes the SDK lock)
    pub(crate) async fn get_control_range_async(
        &self,
        target_type: SvbControlType,
    ) -> Result<(i64, i64), DriverError> {
        let (min, max, _default) = self.get_control_caps_async(target_type).await?;
        Ok((min, max))
    }

    /// Get full `(min, max, default)` caps for a control (takes the SDK lock).
    ///
    /// SVBony's `SvbControlCaps` includes a per-control `default_value` field
    /// (matching ZWO's layout). For the Gain control this is the value SVBony's
    /// firmware reports as the recommended starting point — surfaced here so
    /// the bridge can present a unity-gain recommendation when available.
    pub(crate) async fn get_control_caps_async(
        &self,
        target_type: SvbControlType,
    ) -> Result<(i64, i64, i64), DriverError> {
        self.core.require_connected()?;
        let sdk = SvbonySdk::lock().await?;

        let mut num_controls: c_int = 0;
        // SAFETY: `self.camera_id` validated by SVBOpenCamera; `&mut num_controls` is a valid stack out-pointer to a c_int.
        let result = unsafe { (sdk.get_num_of_controls)(self.camera_id, &mut num_controls) };
        if SvbError::from_i32(result) != SvbError::Success {
            return Err(SvbError::from_i32(result).to_native_error("get num of controls"));
        }

        for i in 0..num_controls {
            // SAFETY: SvbControlCaps is `#[repr(C)]` POD (c_char arrays, c_int, c_long) — all valid bit-patterns. Zero-init is the well-defined empty state before SVBGetControlCaps overwrites it.
            let mut caps: SvbControlCaps = unsafe { std::mem::zeroed() };
            // SAFETY: `self.camera_id` validated; `i` is in [0, num_controls) per the loop bound (which is the contract for SVBGetControlCaps's index parameter); `&mut caps` is a valid stack out-pointer to a `#[repr(C)]` SvbControlCaps.
            let result = unsafe { (sdk.get_control_caps)(self.camera_id, i, &mut caps) };
            if SvbError::from_i32(result) == SvbError::Success
                && caps.control_type == target_type as c_int
            {
                // Why: caps.min_value/max_value/default_value are c_long; widening
                // to i64 is value-preserving on every Tier 1 target
                // (LP64: c_long == i64; LLP64 Windows: i32 -> i64).
                return Ok((
                    caps.min_value as i64,
                    caps.max_value as i64,
                    caps.default_value as i64,
                ));
            }
        }

        Err(DriverError::NotSupported)
    }
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

    fn is_connected(&self) -> bool {
        self.core.connected
    }

    async fn connect(&mut self) -> Result<(), DriverError> {
        if self.core.connected {
            return Ok(());
        }

        let svb = SvbonySdk::installed()?;
        let sdk = svb.lock().await;

        // SAFETY: `self.camera_id` was supplied by SvbonyCamera::new (originating from SvbCameraInfo populated by SVBGetCameraInfo during discover_devices); SVBOpenCamera is the contractual handle-acquisition entry point.
        let result = unsafe { (sdk.open_camera)(self.camera_id) };
        if SvbError::from_i32(result) != SvbError::Success {
            return Err(SvbError::from_i32(result).to_native_error("open camera"));
        }

        // SAFETY: SvbCameraProperty is `#[repr(C)]` POD (c_long/c_int arrays, f64, f32) — all valid bit-patterns. Zero-init is the well-defined empty state before the SDK overwrites it.
        let mut prop: SvbCameraProperty = unsafe { std::mem::zeroed() };
        // SAFETY: `self.camera_id` valid (just opened above); `&mut prop` is a valid stack out-pointer to a `#[repr(C)]` SvbCameraProperty.
        let result = unsafe { (sdk.get_camera_property)(self.camera_id, &mut prop) };
        if SvbError::from_i32(result) != SvbError::Success {
            // SAFETY: `self.camera_id` is the just-opened camera being torn down on error path. SVBCloseCamera is the contractual release entry point.
            unsafe { (sdk.close_camera)(self.camera_id) };
            return Err(SvbError::from_i32(result).to_native_error("get camera property"));
        }

        // SAFETY: SvbCameraPropertyEx is `#[repr(C)]` POD (c_int and c_int arrays) — all valid bit-patterns. Zero-init is the well-defined empty state.
        let mut prop_ex: SvbCameraPropertyEx = unsafe { std::mem::zeroed() };
        // SAFETY: `self.camera_id` valid; `&mut prop_ex` is a valid stack out-pointer to a `#[repr(C)]` SvbCameraPropertyEx. Failure is tolerated (older firmware may not support EX) — caller logs nothing and falls through with zeroed defaults.
        let property_ex_result =
            unsafe { (sdk.get_camera_property_ex)(self.camera_id, &mut prop_ex) };
        if SvbError::from_i32(property_ex_result) != SvbError::Success {
            // prop_ex keeps its zeroed seed, so `can_cool` and `has_guider_port` are
            // published as false for the session and set_cooler/pulse-guide are refused.
            // That is the safe direction, but on a cooled camera it is a capability the
            // operator will look for — name the query that took it away.
            tracing::warn!(
                "SVBony camera {}: SVBGetCameraPropertyEx failed ({:?}); cooling and ST4 guiding are reported as unsupported for this session",
                self.camera_id,
                SvbError::from_i32(property_ex_result)
            );
        }

        let mut max_bin = 1;
        for bin in prop.supported_bins.iter() {
            if *bin > 0 {
                max_bin = (*bin).max(max_bin);
            }
        }

        self.core.capabilities = CameraCapabilities {
            // Cooling is reported by SVB_CAMERA_PROPERTY_EX.bSupportControlTemp —
            // there is no IsCoolerCam field in SVB_CAMERA_PROPERTY; reading a
            // `prop.is_cooler_cam` there returns uninitialized stack (always
            // false), leaving cooled SV405CC/SV605MC/CC unregulated. Matches
            // svbony_base.cpp.
            can_cool: prop_ex.b_support_control_temp != 0,
            can_set_gain: true,
            can_set_offset: true,
            can_set_binning: max_bin > 1,
            can_subframe: true,
            // SVBony cameras are CMOS with no mechanical shutter, and SVB_CAMERA_PROPERTY
            // exposes no such field to read.
            has_shutter: false,
            has_guider_port: prop_ex.b_support_pulse_guide != 0,
            max_bin_x: max_bin,
            max_bin_y: max_bin,
            supports_readout_modes: false,
        };

        let is_color = prop.is_color_cam != 0;
        let bayer_pattern = if is_color {
            Some(bayer_from_asi_index(prop.bayer_pattern))
        } else {
            None
        };

        // Why: max_width/max_height are c_long (positive sensor dimensions, <= ~16k on
        // SVBony hardware). Use try_into to fail closed on negative or absurd values.
        let width_u32 = u32::try_from(prop.max_width).map_err(|_| {
            DriverError::SdkError(format!(
                "SVBony reported invalid sensor width: {}",
                prop.max_width
            ))
        })?;
        let height_u32 = u32::try_from(prop.max_height).map_err(|_| {
            DriverError::SdkError(format!(
                "SVBony reported invalid sensor height: {}",
                prop.max_height
            ))
        })?;
        let bit_depth_u32 = u32::try_from(prop.max_bit_depth).map_err(|_| {
            DriverError::SdkError(format!(
                "SVBony reported invalid bit_depth: {}",
                prop.max_bit_depth
            ))
        })?;
        // SVB_CAMERA_PROPERTY carries no pixel size; query it separately (µm).
        // Failure → 0.0 (unknown); the reference (svbony_base.cpp:760) queries the
        // same way.
        let pixel_size_um = {
            let mut px: f32 = 0.0;
            // SAFETY: `self.camera_id` valid; `&mut px` is a valid f32 out-pointer.
            let result = unsafe { (sdk.get_sensor_pixel_size)(self.camera_id, &mut px) };
            if SvbError::from_i32(result) != SvbError::Success {
                // 0.0 propagates into SensorInfo.pixel_size_x/y, which is what the
                // FITS XPIXSZ card and every image-scale hint are built from. Name
                // the failure so a 0 um sensor is traceable to this query instead of
                // looking like a real reading.
                tracing::warn!(
                    "SVBony camera {}: SVBGetSensorPixelSize failed ({:?}); pixel size is reported as unknown (0.0 um) for this session",
                    self.camera_id,
                    SvbError::from_i32(result)
                );
            }
            f64::from(px)
        };
        self.core.sensor_info = SensorInfo {
            width: width_u32,
            height: height_u32,
            pixel_size_x: pixel_size_um,
            pixel_size_y: pixel_size_um,
            // Provisional: the container ceiling depends on the output image
            // type, which connect() negotiates a few statements below. It is
            // recomputed there via [`container_max_adu`] once `self.image_type`
            // is known. `bit_depth` is the sensor's ADC precision (SVBony SDK
            // changelog v1.12.7) and is a different quantity — see the
            // `SensorInfo::max_adu` contract.
            max_adu: container_max_adu(self.image_type, bit_depth_u32),
            bit_depth: bit_depth_u32,
            color: is_color,
            bayer_pattern,
        };

        // SAFETY: SvbCameraInfo is `#[repr(C)]` POD; zero-init is the well-defined empty state.
        let mut info: SvbCameraInfo = unsafe { std::mem::zeroed() };
        // SAFETY: `&mut info` is a valid stack out-pointer; index 0 is a probe to verify the SDK is responsive before iterating.
        if unsafe { (sdk.get_camera_info)(&mut info, 0) } == 0 {
            // SAFETY: SVBGetNumOfConnectedCameras takes no arguments and returns a plain c_int count.
            let count = unsafe { (sdk.get_num_of_connected_cameras)() };
            for i in 0..count {
                // SAFETY: SvbCameraInfo is `#[repr(C)]` POD; zero-init is the well-defined empty state.
                let mut check_info: SvbCameraInfo = unsafe { std::mem::zeroed() };
                // SAFETY: `i` is in [0, count) per the loop bound (which is the contract for SVBGetCameraInfo's index parameter); `&mut check_info` is a valid stack out-pointer to a `#[repr(C)]` SvbCameraInfo.
                if unsafe { (sdk.get_camera_info)(&mut check_info, i) } == 0
                    && check_info.camera_id == self.camera_id
                {
                    // SAFETY: SVBGetCameraInfo populated `check_info.friendly_name` as a NUL-terminated C string inside a [c_char; 32] buffer per SVBCameraSDK.h; the pointer is valid for the duration of this stack `check_info` value.
                    self.core.name = unsafe { CStr::from_ptr(check_info.friendly_name.as_ptr()) }
                        .to_string_lossy()
                        .to_string();
                    break;
                }
            }
        }

        // Set default image type (16-bit RAW)
        // SAFETY: `self.camera_id` valid (just opened above); `SvbImgType::Raw16 as c_int` is a stable discriminant from SVBCameraSDK.h enum SVB_IMG_TYPE.
        let result =
            unsafe { (sdk.set_output_image_type)(self.camera_id, SvbImgType::Raw16 as c_int) };
        self.image_type = if SvbError::from_i32(result) == SvbError::Success {
            SvbImgType::Raw16
        } else {
            tracing::warn!("Could not set 16-bit output, trying 8-bit");
            // SAFETY: `self.camera_id` valid; `SvbImgType::Raw8 as c_int` is a stable discriminant from SVBCameraSDK.h. Fallback path when Raw16 is unsupported by this model.
            let fallback_result =
                unsafe { (sdk.set_output_image_type)(self.camera_id, SvbImgType::Raw8 as c_int) };
            if SvbError::from_i32(fallback_result) != SvbError::Success {
                // SAFETY: the camera was opened above and neither
                // supported RAW format could be configured, so close before failing.
                unsafe { (sdk.close_camera)(self.camera_id) };
                return Err(SvbError::from_i32(fallback_result)
                    .to_native_error("set 8-bit output image type"));
            }
            SvbImgType::Raw8
        };
        // The output image type is what determines the pixel container, so the
        // published ceiling has to be recomputed now that it is settled: RAW16
        // left-justifies the sensor bits into 16 bits (ceiling 65520 for a
        // 12-bit sensor), while the RAW8 fallback above caps every sample at
        // 255. See [`container_max_adu`].
        self.core.sensor_info.max_adu =
            container_max_adu(self.image_type, self.core.sensor_info.bit_depth);
        self.core.connected = true;
        self.core.state = CameraState::Idle;

        // Drop the SDK lock before applying the post-open settle. Control reads
        // performed before this delay can return stale firmware values.
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

        // Reacquire the SDK lock before the initial control reads.
        let sdk = svb.lock().await;

        // Read initial gain/offset after the firmware settle.
        // Why: SVBony gain/offset values are small non-negative integers (range 0..=720
        // for gain on current SDKs) returned as i64. `as i32` saturating truncation is
        // safe in this range. We don't propagate errors here and keep the default 0
        // fallback for connect-time setup.
        if let Ok(gain) = self.get_control_value(&sdk, SvbControlType::Gain) {
            self.core.gain = gain as i32;
        }
        if let Ok(offset) = self.get_control_value(&sdk, SvbControlType::BlackLevel) {
            self.core.offset = offset as i32;
        }

        tracing::info!(
            "Connected to SVBony camera: {} ({}x{})",
            self.core.name,
            self.core.sensor_info.width,
            self.core.sensor_info.height
        );

        Ok(())
    }

    async fn disconnect(&mut self) -> Result<(), DriverError> {
        if !self.core.connected {
            return Ok(());
        }

        let sdk = SvbonySdk::lock().await?;

        // SAFETY: `self.camera_id` valid until we close below; SVBStopVideoCapture takes a single c_int and is idempotent per SDK docs.
        let _ = unsafe { (sdk.stop_video_capture)(self.camera_id) };

        // SAFETY: `self.camera_id` valid (handle was opened in connect()). SVBCloseCamera is the contractual release for SVBOpenCamera.
        let result = unsafe { (sdk.close_camera)(self.camera_id) };
        if SvbError::from_i32(result) != SvbError::Success {
            return Err(SvbError::from_i32(result).to_native_error("close camera"));
        }

        self.core.connected = false;
        self.core.state = CameraState::Idle;
        tracing::info!("Disconnected from SVBony camera: {}", self.core.name);
        Ok(())
    }
}
