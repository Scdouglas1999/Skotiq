//! `PlayerOneCamera` state and inherent helpers.

use super::*;

#[derive(Debug)]
pub struct PlayerOneCamera {
    pub(crate) camera_id: i32,
    pub(crate) camera_info: Option<POACameraProperties>,
    /// `core.gain`/`core.offset` are the last values this driver applied or read
    /// back successfully: the fallback for the frame metadata (FITS GAIN/OFFSET)
    /// when a POAGetConfig read fails on a frame we already hold. `core.cooler`
    /// is the fallback when `POA_COOLER`/`POA_TARGET_TEMP` cannot be read back.
    /// `core.name` is the device id: the SDK's model name is only logged.
    pub(crate) core: CameraCore,
    pub(crate) image_format: POAImgFormat,
}

fn player_one_capabilities(info: &POACameraProperties) -> CameraCapabilities {
    CameraCapabilities {
        can_cool: info.is_has_cooler != 0,
        can_set_gain: true,
        can_set_offset: true,
        can_set_binning: true,
        can_subframe: true,
        has_shutter: false,
        has_guider_port: info.is_has_st4_port != 0,
        max_bin_x: 4,
        max_bin_y: 4,
        supports_readout_modes: false,
    }
}

fn player_one_sensor_info(info: &POACameraProperties) -> SensorInfo {
    // max_width/max_height/bit_depth are c_int sensor properties; they are never
    // negative for a real camera, and a negative one reads as 0 because this
    // description has no error path.
    SensorInfo {
        width: u32::try_from(info.max_width).unwrap_or(0),
        height: u32::try_from(info.max_height).unwrap_or(0),
        pixel_size_x: info.pixel_size,
        pixel_size_y: info.pixel_size,
        // `max_adu` is the pixel-container full scale, NOT the ADC range:
        // connect() hard-fails unless POASetImageFormat(Raw16) succeeds, so every
        // frame this driver delivers is a 16-bit container whose samples span
        // [0, 65535]. See [`raw16_container_max_adu`] and the `SensorInfo::max_adu`
        // contract.
        max_adu: raw16_container_max_adu(u32::try_from(info.bit_depth).unwrap_or(0)),
        bit_depth: u32::try_from(info.bit_depth).unwrap_or(0),
        color: info.is_color_camera != 0,
        bayer_pattern: (info.is_color_camera != 0)
            .then(|| bayer_from_asi_index(info.bayer_pattern)),
    }
}

impl PlayerOneCamera {
    pub fn new(camera_id: i32) -> Self {
        Self {
            camera_id,
            camera_info: None,
            core: CameraCore::new(
                format!("native:playerone:{}", camera_id),
                format!("native:playerone:{}", camera_id),
            ),
            image_format: POAImgFormat::Raw16,
        }
    }

    pub(crate) fn load_camera_info(&mut self, sdk: &PoaSdk) -> Result<(), DriverError> {
        // SAFETY: POACameraProperties is `#[repr(C)]` and contains only POD fields (c_char arrays, c_int, f64) — all valid bit-patterns. Zero-initialization is the well-defined empty state before the SDK overwrites it.
        let mut info: POACameraProperties = unsafe { std::mem::zeroed() };
        // SAFETY: caller holds &mut self so `self.camera_id` is valid; `&mut info` is a valid stack out-pointer to a `#[repr(C)]` POACameraProperties; POAGetCameraPropertiesByID reads metadata only and writes only into the out-pointer.
        let result = unsafe { (sdk.get_camera_properties_by_id)(self.camera_id, &mut info) };
        check_poa_error(result, "GetCameraProperties")?;

        self.core.capabilities = player_one_capabilities(&info);
        self.core.sensor_info = player_one_sensor_info(&info);
        self.camera_info = Some(info);
        Ok(())
    }

    pub(crate) fn camera_name(&self) -> String {
        if let Some(info) = &self.camera_info {
            safe_cstr_to_string(info.camera_model_name.as_ptr(), 256)
        } else {
            format!("Player One Camera {}", self.camera_id)
        }
    }

    /// Read a writable integer control's `[min, max]` from the SDK's own attribute
    /// table, so the bounds offered to the user are the camera's and not a model
    /// average. Reports `NotSupported` when this SDK build cannot answer or the
    /// camera declares the control unwritable.
    pub(crate) async fn config_int_bounds(
        &self,
        control: POAConfig,
    ) -> Result<(i32, i32), DriverError> {
        let sdk = PoaSdk::installed()?;
        // Unlocked on purpose: this reads whether the optional symbol was
        // resolved when the library loaded and calls nothing. The call itself
        // happens below, under the lock.
        let Some(get_attributes) = sdk.unlocked().get_config_attributes_by_config_id else {
            tracing::warn!(
                "Player One SDK build exports no POAGetConfigAttributesByConfigID; \
                 bounds for control {:?} are unavailable",
                control
            );
            return Err(DriverError::NotSupported);
        };

        let _sdk = sdk.lock().await;
        // SAFETY: POAConfigAttributes is `#[repr(C)]` over c_int fields, POD unions and
        // char arrays; the all-zero bit pattern is valid for every one of them.
        let mut attributes: POAConfigAttributes = unsafe { std::mem::zeroed() };
        // SAFETY: `_sdk` holds the SDK lock for this call; `self.camera_id` is the open camera checked by the caller; `&mut attributes` is a valid out-pointer to the `#[repr(C)]` struct the SDK fills.
        let result = unsafe { get_attributes(self.camera_id, control as c_int, &mut attributes) };
        check_poa_error(result, "POAGetConfigAttributesByConfigID")?;

        if attributes.is_writable == POA_FALSE {
            return Err(DriverError::NotSupported);
        }
        if attributes.value_type != POAValueType::Int as c_int {
            return Err(DriverError::SdkError(format!(
                "Player One control {:?} reports value type {}, not VAL_INT",
                control, attributes.value_type
            )));
        }

        // SAFETY: the SDK reported VAL_INT above, so both bounds hold the int variant
        // of the POAConfigValue union.
        let (min, max) = unsafe {
            (
                attributes.min_value.int_value,
                attributes.max_value.int_value,
            )
        };
        // c_long is i64 on LP64 *nix and i32 on Windows (LLP64), so a direct
        // `i32::try_from` is a real range check on one and a useless conversion
        // the lint rejects on the other. Widening first gives one shape that is
        // honest on both — the same round-trip `fli_c_long_to_i32` uses.
        let narrow = |value: c_long| {
            #[allow(clippy::unnecessary_cast)] // identity on Windows, widening on *nix
            let widened: i64 = value as i64;
            i32::try_from(widened).map_err(|_| {
                DriverError::SdkError(format!(
                    "Player One control {:?} reported bound {} outside i32",
                    control, value
                ))
            })
        };
        Ok((narrow(min)?, narrow(max)?))
    }

    /// Get a control value as integer, taking the SDK lock for the call.
    pub(crate) async fn get_control_int_async(
        &self,
        control: POAConfig,
    ) -> Result<c_long, DriverError> {
        let sdk = PoaSdk::lock().await?;
        let mut value = POAConfigValue::default();
        let mut is_auto: POABool = POA_FALSE;
        // SAFETY: `self.camera_id` was assigned at construction and is the camera ID parameter passed to POAGetConfig; `&mut value` and `&mut is_auto` are valid stack out-pointers to POD `#[repr(C)]` types.
        let result =
            unsafe { (sdk.get_config)(self.camera_id, control as c_int, &mut value, &mut is_auto) };
        check_poa_error(result, "POAGetConfig")?;
        // SAFETY: POAConfigValue is a `#[repr(C)]` union; we asked the SDK for an integer control via this typed wrapper (callers use this only for VAL_INT controls per PlayerOneCamera.h), so reading `int_value` matches the variant written by the SDK above.
        Ok(unsafe { value.int_value })
    }

    /// Get a control value as integer under a lock the caller already holds.
    pub(crate) fn get_control_int(
        &self,
        sdk: &PoaSdk,
        control: POAConfig,
    ) -> Result<c_long, DriverError> {
        let mut value = POAConfigValue::default();
        let mut is_auto: POABool = POA_FALSE;
        // SAFETY: out-pointers are valid stack POD references.
        let result =
            unsafe { (sdk.get_config)(self.camera_id, control as c_int, &mut value, &mut is_auto) };
        check_poa_error(result, "POAGetConfig")?;
        // SAFETY: integer variant of the POAConfigValue union — only called for VAL_INT controls (POA_GAIN/OFFSET/COOLER_POWER/etc.) per PlayerOneCamera.h, matching the union variant the SDK wrote.
        Ok(unsafe { value.int_value })
    }

    /// Get a control value as float, taking the SDK lock for the call.
    pub(crate) async fn get_control_float_async(
        &self,
        control: POAConfig,
    ) -> Result<f64, DriverError> {
        let sdk = PoaSdk::lock().await?;
        let mut value = POAConfigValue::default();
        let mut is_auto: POABool = POA_FALSE;
        // SAFETY: out-pointers `&mut value` and `&mut is_auto` are valid stack POD references; called only for VAL_FLOAT controls (POA_TEMPERATURE/POA_EGAIN) per PlayerOneCamera.h.
        let result =
            unsafe { (sdk.get_config)(self.camera_id, control as c_int, &mut value, &mut is_auto) };
        check_poa_error(result, "POAGetConfig")?;
        // SAFETY: float variant of POAConfigValue — only called for VAL_FLOAT controls (POA_TEMPERATURE/POA_EGAIN), matching the union variant the SDK wrote.
        Ok(unsafe { value.float_value })
    }

    /// Get a control value as float under a lock the caller already holds.
    pub(crate) fn get_control_float(
        &self,
        sdk: &PoaSdk,
        control: POAConfig,
    ) -> Result<f64, DriverError> {
        let mut value = POAConfigValue::default();
        let mut is_auto: POABool = POA_FALSE;
        // SAFETY: out-pointers are valid stack POD references.
        let result =
            unsafe { (sdk.get_config)(self.camera_id, control as c_int, &mut value, &mut is_auto) };
        check_poa_error(result, "POAGetConfig")?;
        // SAFETY: float variant of POAConfigValue — only used for VAL_FLOAT controls (POA_TEMPERATURE/POA_EGAIN), matching the variant the SDK wrote.
        Ok(unsafe { value.float_value })
    }

    /// Get a control value as bool under a lock the caller already holds.
    pub(crate) fn get_control_bool(
        &self,
        sdk: &PoaSdk,
        control: POAConfig,
    ) -> Result<bool, DriverError> {
        let mut value = POAConfigValue::default();
        let mut is_auto: POABool = POA_FALSE;
        // SAFETY: out-pointers are valid stack POD references.
        let result =
            unsafe { (sdk.get_config)(self.camera_id, control as c_int, &mut value, &mut is_auto) };
        check_poa_error(result, "POAGetConfig")?;
        // SAFETY: bool variant of POAConfigValue — only used for VAL_BOOL controls (POA_COOLER/POA_HEATER/etc.) per PlayerOneCamera.h, matching the variant the SDK wrote.
        Ok(unsafe { value.bool_value } != POA_FALSE)
    }

    /// Set an integer control value, taking the SDK lock for the call.
    pub(crate) async fn set_control_int_async(
        &mut self,
        control: POAConfig,
        value: c_long,
        auto: bool,
    ) -> Result<(), DriverError> {
        let sdk = PoaSdk::lock().await?;
        let config_value = POAConfigValue { int_value: value };
        // SAFETY: config_value is a `#[repr(C)]` union initialized via the int_value variant and passed by-value to a VAL_INT control — POASetConfig reads the appropriate variant based on the control type per PlayerOneCamera.h.
        let result = unsafe {
            (sdk.set_config)(
                self.camera_id,
                control as c_int,
                config_value,
                if auto { POA_TRUE } else { POA_FALSE },
            )
        };
        check_poa_error(result, "POASetConfig")
    }

    /// Set an integer control value under a lock the caller already holds.
    pub(crate) fn set_control_int(
        &mut self,
        sdk: &PoaSdk,
        control: POAConfig,
        value: c_long,
        auto: bool,
    ) -> Result<(), DriverError> {
        let config_value = POAConfigValue { int_value: value };
        // SAFETY: config_value is `#[repr(C)]` union initialized via int_value for VAL_INT controls.
        let result = unsafe {
            (sdk.set_config)(
                self.camera_id,
                control as c_int,
                config_value,
                if auto { POA_TRUE } else { POA_FALSE },
            )
        };
        check_poa_error(result, "POASetConfig")
    }

    /// Set a boolean control value under a lock the caller already holds.
    pub(crate) fn set_control_bool(
        &mut self,
        sdk: &PoaSdk,
        control: POAConfig,
        value: bool,
        auto: bool,
    ) -> Result<(), DriverError> {
        let config_value = POAConfigValue {
            bool_value: if value { POA_TRUE } else { POA_FALSE },
        };
        // SAFETY: config_value is a `#[repr(C)]` union initialized via bool_value for VAL_BOOL controls (e.g. POA_COOLER).
        let result = unsafe {
            (sdk.set_config)(
                self.camera_id,
                control as c_int,
                config_value,
                if auto { POA_TRUE } else { POA_FALSE },
            )
        };
        check_poa_error(result, "POASetConfig")
    }
}
