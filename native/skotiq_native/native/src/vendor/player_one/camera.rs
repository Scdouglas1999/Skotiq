//! `PlayerOneCamera` state and inherent helpers.

use super::*;

#[derive(Debug)]
pub struct PlayerOneCamera {
    pub(crate) camera_id: i32,
    /// The properties the SDK reported after the camera was opened.
    pub(crate) camera_info: Option<POACameraProperties>,
    /// `core.gain`/`core.offset` are the last values this driver applied or read
    /// back successfully: the fallback for the frame metadata (FITS GAIN/OFFSET)
    /// when a POAGetConfig read fails on a frame we already hold. `core.cooler`
    /// is the fallback when `POA_COOLER`/`POA_TARGET_TEMP` cannot be read back.
    /// `core.bin_x`/`core.subframe` are the geometry the camera reported back
    /// after it was last set. `core.name` is the model once connected.
    pub(crate) core: CameraCore,
    pub(crate) image_format: POAImgFormat,
    /// Whether `core.bin_x`/`core.subframe` were read back from this open camera.
    pub(crate) geometry_applied: bool,
}

/// The bin factors the camera lists (`bins`, ended by 0), smallest first.
fn listed_bins(info: &POACameraProperties) -> Vec<i32> {
    info.bins
        .iter()
        .copied()
        .take_while(|&bin| bin != 0)
        .filter(|&bin| bin > 0)
        .collect()
}

fn player_one_capabilities(info: &POACameraProperties) -> CameraCapabilities {
    let max_bin = listed_bins(info).into_iter().max().unwrap_or(1);
    CameraCapabilities {
        can_cool: info.is_has_cooler != 0,
        can_set_gain: true,
        can_set_offset: true,
        can_set_binning: max_bin > 1,
        can_subframe: true,
        has_shutter: false,
        has_guider_port: info.is_has_st4_port != 0,
        max_bin_x: max_bin,
        max_bin_y: max_bin,
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
        saturation_adu: None,
    }
}

/// The longest exposure `POA_EXPOSURE` takes, in microseconds
/// (PlayerOneCamera.h: "range:[10 - 2000000000]"). SDK builds with `POA_EXP`
/// take up to 7200 s.
const LONGEST_MICROSECOND_EXPOSURE: f64 = 2_000_000_000.0;

/// A subframe in the camera's binned pixels.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Roi {
    pub(crate) x: c_int,
    pub(crate) y: c_int,
    pub(crate) width: c_int,
    pub(crate) height: c_int,
}

impl Roi {
    fn subframe(self) -> SubFrame {
        // The SDK reported these back; it never reports negative ones.
        let unsigned = |v: c_int| u32::try_from(v).unwrap_or(0);
        SubFrame {
            start_x: unsigned(self.x),
            start_y: unsigned(self.y),
            width: unsigned(self.width),
            height: unsigned(self.height),
        }
    }
}

/// The ROI the SDK will take for `subframe` on a `max_width` x `max_height`
/// binned sensor: the width a multiple of 4 and the height of 2
/// (PlayerOneCamera.h, POASetImageSize) and an even start, which SDK 3.10.1
/// makes of every start (POACamera::SetImgStartPixel) and which keeps a color
/// frame on the Bayer cell its header names. `None` is the whole binned sensor.
pub(crate) fn roi_for(
    subframe: Option<&SubFrame>,
    max_width: c_int,
    max_height: c_int,
) -> Result<Roi, DriverError> {
    let Some(sf) = subframe else {
        return Ok(Roi {
            x: 0,
            y: 0,
            width: max_width & !3,
            height: max_height & !1,
        });
    };
    let fits = u64::from(sf.start_x) + u64::from(sf.width) <= max_width.max(0) as u64
        && u64::from(sf.start_y) + u64::from(sf.height) <= max_height.max(0) as u64;
    let to_int = |v: u32| c_int::try_from(v).ok();
    let roi = match (
        to_int(sf.start_x),
        to_int(sf.start_y),
        to_int(sf.width),
        to_int(sf.height),
    ) {
        (Some(x), Some(y), Some(width), Some(height)) if fits => Roi {
            x: x & !1,
            y: y & !1,
            width: width & !3,
            height: height & !1,
        },
        _ => {
            return Err(DriverError::InvalidParameter(format!(
                "subframe {}x{} at ({}, {}) does not fit the {}x{} binned sensor",
                sf.width, sf.height, sf.start_x, sf.start_y, max_width, max_height
            )))
        }
    };
    if roi.width == 0 || roi.height == 0 {
        return Err(DriverError::InvalidParameter(format!(
            "subframe {}x{} is smaller than the 4x2 pixels a Player One camera reads out",
            sf.width, sf.height
        )));
    }
    Ok(roi)
}

impl PlayerOneCamera {
    /// The SDK, held for this camera (see `sdk_loader::lock_scope`).
    pub(crate) async fn sdk(
        &self,
    ) -> Result<crate::vendor::sdk_loader::SdkGuard<PoaSdk>, skotiq_device::DriverError> {
        use crate::vendor::sdk_loader::{device_key, lock_scope};
        PoaSdk::slot()
            .lock_device(
                lock_scope(&skotiq_device::Vendor::PlayerOne),
                device_key(self.camera_id),
            )
            .await
    }

    pub fn new(camera_id: i32) -> Self {
        Self {
            camera_id,
            camera_info: None,
            core: CameraCore::new(
                format!("native:playerone:{}", camera_id),
                format!("native:playerone:{}", camera_id),
            ),
            image_format: POAImgFormat::Raw16,
            geometry_applied: false,
        }
    }

    /// Asks the SDK to scan the USB bus and checks the camera id is among the
    /// cameras found. The SDK knows no camera before a scan (a profile connects
    /// at startup without one), and a camera plugged back in may have a new id.
    pub(crate) fn find_in_scan(&self, sdk: &PoaSdk) -> Result<(), DriverError> {
        // SAFETY: POAGetCameraCount takes no arguments.
        let count = unsafe { (sdk.get_camera_count)() };
        for index in 0..count {
            // SAFETY: POACameraProperties is `#[repr(C)]` POD; zeroed is a valid out buffer.
            let mut info: POACameraProperties = unsafe { std::mem::zeroed() };
            // SAFETY: `index` is in [0, count); `&mut info` is a valid out-pointer.
            let result = unsafe { (sdk.get_camera_properties)(index, &mut info) };
            if result == 0 && info.camera_id == self.camera_id {
                return Ok(());
            }
        }
        Err(DriverError::InvalidDevice(format!(
            "Player One camera {} is not on the USB bus ({} Player One camera(s) found); \
             check the cable and search for devices again",
            self.camera_id, count
        )))
    }

    /// Reads the camera's properties. Called once the camera is open: the SDK
    /// fills the serial number for an open camera.
    pub(crate) fn load_camera_info(&mut self, sdk: &PoaSdk) -> Result<(), DriverError> {
        // SAFETY: POACameraProperties is `#[repr(C)]` and contains only POD fields (c_char arrays, c_int, f64) — all valid bit-patterns. Zero-initialization is the well-defined empty state before the SDK overwrites it.
        let mut info: POACameraProperties = unsafe { std::mem::zeroed() };
        // SAFETY: `self.camera_id` is the open camera; `&mut info` is a valid stack out-pointer to a `#[repr(C)]` POACameraProperties; POAGetCameraPropertiesByID writes only into the out-pointer.
        let result = unsafe { (sdk.get_camera_properties_by_id)(self.camera_id, &mut info) };
        check_poa_error(result, "GetCameraProperties")?;

        self.core.capabilities = player_one_capabilities(&info);
        self.core.sensor_info = player_one_sensor_info(&info);
        self.camera_info = Some(info);
        self.core.name = self.camera_name();
        Ok(())
    }

    pub(crate) fn camera_name(&self) -> String {
        if let Some(info) = &self.camera_info {
            safe_cstr_to_string(info.camera_model_name.as_ptr(), 256)
        } else {
            format!("Player One Camera {}", self.camera_id)
        }
    }

    pub(crate) fn serial(&self) -> Option<String> {
        let info = self.camera_info.as_ref()?;
        let serial = safe_cstr_to_string(info.sn.as_ptr(), info.sn.len());
        let serial = serial.trim();
        (!serial.is_empty()).then(|| serial.to_string())
    }

    /// The bin factor for a `bin_x` x `bin_y` request: Player One bins both axes
    /// alike and only by the factors the camera lists.
    pub(crate) fn supported_bin(&self, bin_x: i32, bin_y: i32) -> Result<i32, DriverError> {
        let info = self.camera_info.as_ref().ok_or(DriverError::NotConnected)?;
        let bins = listed_bins(info);
        let listed = if bins.is_empty() { vec![1] } else { bins };
        if bin_x == bin_y && listed.contains(&bin_x) {
            return Ok(bin_x);
        }
        let names: Vec<String> = listed.iter().map(|b| format!("{b}x{b}")).collect();
        Err(DriverError::InvalidParameter(format!(
            "{} bins {}, not {}x{}",
            self.camera_name(),
            names.join(", "),
            bin_x,
            bin_y
        )))
    }

    /// Sets the camera to `bin` and `subframe` (binned pixels, `None` for the
    /// whole sensor) unless it already is there, then records the geometry
    /// the camera reports back, which is what its frames will be.
    pub(crate) fn apply_geometry(
        &mut self,
        sdk: &PoaSdk,
        bin: i32,
        subframe: Option<&SubFrame>,
    ) -> Result<(), DriverError> {
        let info = self.camera_info.as_ref().ok_or(DriverError::NotConnected)?;
        let wanted = roi_for(subframe, info.max_width / bin, info.max_height / bin)?;
        let current = self
            .core
            .subframe
            .as_ref()
            .map(|sf| (sf.start_x, sf.start_y, sf.width, sf.height));
        let wanted_subframe = subframe.map(|_| {
            let sf = wanted.subframe();
            (sf.start_x, sf.start_y, sf.width, sf.height)
        });
        if self.core.bin_x == bin && current == wanted_subframe && self.geometry_applied {
            return Ok(());
        }
        // Until the read-back below succeeds the camera's geometry is unknown.
        self.geometry_applied = false;

        // Bin first: it rescales the ROI and its start (PlayerOneCamera.h,
        // POASetImageBin). Then the size, which re-centers the ROI in SDK 3.10.1
        // (POACamera::SetImgSize), and the start last.
        check_poa_error(
            // SAFETY: the camera is open; all three calls take the id and ints by value.
            unsafe { (sdk.set_image_bin)(self.camera_id, bin) },
            "SetImageBin",
        )?;
        check_poa_error(
            // SAFETY: as above.
            unsafe { (sdk.set_image_size)(self.camera_id, wanted.width, wanted.height) },
            "SetImageSize",
        )?;
        check_poa_error(
            // SAFETY: as above.
            unsafe { (sdk.set_image_start_pos)(self.camera_id, wanted.x, wanted.y) },
            "SetImageStartPos",
        )?;

        let (mut applied_bin, mut x, mut y, mut width, mut height) = (0, 0, 0, 0, 0);
        check_poa_error(
            // SAFETY: the camera is open; every out-pointer is a valid stack c_int.
            unsafe { (sdk.get_image_bin)(self.camera_id, &mut applied_bin) },
            "GetImageBin",
        )?;
        check_poa_error(
            // SAFETY: as above.
            unsafe { (sdk.get_image_start_pos)(self.camera_id, &mut x, &mut y) },
            "GetImageStartPos",
        )?;
        check_poa_error(
            // SAFETY: as above.
            unsafe { (sdk.get_image_size)(self.camera_id, &mut width, &mut height) },
            "GetImageSize",
        )?;
        let applied = Roi {
            x,
            y,
            width,
            height,
        };
        if applied_bin != bin || applied != wanted {
            tracing::warn!(
                "Player One {}: asked for bin {} {:?}, the camera took bin {} {:?}",
                self.core.device_id,
                bin,
                wanted,
                applied_bin,
                applied
            );
        }
        self.core.bin_x = applied_bin;
        self.core.bin_y = applied_bin;
        self.core.subframe = subframe.map(|_| applied.subframe());
        self.geometry_applied = true;
        Ok(())
    }

    /// The SDK's attribute record for `control` (its real min/max/default and
    /// whether it can be written), under a lock the caller already holds.
    /// `NotSupported` when this SDK build cannot answer or the camera has no
    /// such control.
    pub(crate) fn config_attributes(
        &self,
        sdk: &PoaSdk,
        control: POAConfig,
    ) -> Result<POAConfigAttributes, DriverError> {
        let Some(get_attributes) = sdk.get_config_attributes_by_config_id else {
            tracing::warn!(
                "Player One SDK build exports no POAGetConfigAttributesByConfigID; \
                 bounds for control {:?} are unavailable",
                control
            );
            return Err(DriverError::NotSupported);
        };

        // SAFETY: POAConfigAttributes is `#[repr(C)]` over c_int fields, POD unions and
        // char arrays; the all-zero bit pattern is valid for every one of them.
        let mut attributes: POAConfigAttributes = unsafe { std::mem::zeroed() };
        // SAFETY: the caller holds the SDK lock; `self.camera_id` is the open camera checked by the caller; `&mut attributes` is a valid out-pointer to the `#[repr(C)]` struct the SDK fills.
        let result = unsafe { get_attributes(self.camera_id, control as c_int, &mut attributes) };
        if result == POA_ERROR_INVALID_CONFIG {
            return Err(DriverError::NotSupported);
        }
        check_poa_error(result, "POAGetConfigAttributesByConfigID")?;
        Ok(attributes)
    }

    /// Read a writable integer control's `[min, max]` from the SDK's own attribute
    /// table, so the bounds offered to the user are the camera's and not a model
    /// average. Reports `NotSupported` when this SDK build cannot answer or the
    /// camera declares the control unwritable.
    pub(crate) fn config_int_bounds(
        &self,
        sdk: &PoaSdk,
        control: POAConfig,
    ) -> Result<(i32, i32), DriverError> {
        let attributes = self.config_attributes(sdk, control)?;
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

    /// The exposure range in seconds: `POA_EXP` where the SDK has it, else
    /// `POA_EXPOSURE` in microseconds.
    pub(crate) fn exposure_bounds(&self, sdk: &PoaSdk) -> Result<Option<(f64, f64)>, DriverError> {
        match self.config_attributes(sdk, POAConfig::POA_EXP) {
            Ok(attributes) if attributes.value_type == POAValueType::Float as c_int => {
                // SAFETY: the SDK reported VAL_FLOAT, so the bounds hold the float variant.
                let bounds = unsafe {
                    (
                        attributes.min_value.float_value,
                        attributes.max_value.float_value,
                    )
                };
                return Ok(Some(bounds));
            }
            Ok(_) | Err(DriverError::NotSupported) => {}
            Err(e) => return Err(e),
        }
        match self.config_int_bounds(sdk, POAConfig::POA_EXPOSURE) {
            Ok((min, max)) => Ok(Some((f64::from(min) / 1e6, f64::from(max) / 1e6))),
            Err(DriverError::NotSupported) => Ok(None),
            Err(e) => Err(e),
        }
    }

    /// Sets the exposure time and returns the seconds the camera holds, which
    /// is what the frame records.
    ///
    /// `POA_EXP` (seconds, up to 7200 s) where the SDK has it; older SDK builds
    /// answer it `POA_ERROR_INVALID_CONFIG` and take whole microseconds in
    /// `POA_EXPOSURE`, up to 2000 s.
    pub(crate) fn set_exposure_time(
        &mut self,
        sdk: &PoaSdk,
        seconds: f64,
    ) -> Result<f64, DriverError> {
        if !seconds.is_finite() || seconds <= 0.0 {
            return Err(DriverError::InvalidParameter(format!(
                "exposure time must be a positive number of seconds, not {}",
                seconds
            )));
        }
        let model = self.camera_name();
        // The SDK takes a time outside the camera's range without an error and
        // exposes for the nearer bound (POACamera::SetExposure in SDK 3.10.1), so
        // a refusal has to come from here.
        match self.exposure_bounds(sdk) {
            Ok(Some((shortest, longest))) if !(shortest..=longest).contains(&seconds) => {
                return Err(DriverError::InvalidParameter(format!(
                    "{model} takes exposures from {shortest} s to {longest} s, not {seconds} s"
                )));
            }
            Ok(_) => {}
            Err(e) => tracing::warn!(
                "Player One {}: the exposure range could not be read ({}); the frame records \
                 the time the camera holds",
                self.core.device_id,
                e
            ),
        }
        let refused = |e: DriverError| match e {
            DriverError::InvalidParameter(_) => DriverError::InvalidParameter(format!(
                "{} does not take a {} s exposure",
                model, seconds
            )),
            other => other,
        };
        let value = POAConfigValue {
            float_value: seconds,
        };
        // SAFETY: the camera is open; POA_EXP is VAL_FLOAT and the union holds the float.
        let result = unsafe {
            (sdk.set_config)(
                self.camera_id,
                POAConfig::POA_EXP as c_int,
                value,
                POA_FALSE,
            )
        };
        if result != POA_ERROR_INVALID_CONFIG {
            check_poa_error(result, "POASetConfig(POA_EXP)").map_err(refused)?;
            return Ok(match self.get_control_float(sdk, POAConfig::POA_EXP) {
                Ok(held) => held,
                Err(e) => {
                    tracing::warn!(
                        "Player One {}: POA_EXP read-back failed ({}); recording the {} s set",
                        self.core.device_id,
                        e,
                        seconds
                    );
                    seconds
                }
            });
        }

        let microseconds = (seconds * 1e6).round();
        if microseconds > LONGEST_MICROSECOND_EXPOSURE {
            return Err(DriverError::InvalidParameter(format!(
                "this Player One SDK takes exposures up to {} s; a {} s exposure needs \
                 a newer Player One SDK",
                LONGEST_MICROSECOND_EXPOSURE / 1e6,
                seconds
            )));
        }
        // At most 2e9, inside a 32-bit C long.
        self.set_control_int(sdk, POAConfig::POA_EXPOSURE, microseconds as c_long, false)
            .map_err(refused)?;
        Ok(match self.get_control_int(sdk, POAConfig::POA_EXPOSURE) {
            Ok(held) => held as f64 / 1e6,
            Err(e) => {
                tracing::warn!(
                    "Player One {}: POA_EXPOSURE read-back failed ({}); recording the {} s set",
                    self.core.device_id,
                    e,
                    seconds
                );
                microseconds / 1e6
            }
        })
    }

    /// The camera's sensor modes (such as a low-noise mode), in the SDK's
    /// index order. Empty for a camera without a choice, or an SDK build that
    /// predates them.
    pub(crate) fn sensor_modes(&self, sdk: &PoaSdk) -> Result<Vec<ReadoutMode>, DriverError> {
        let (Some(get_count), Some(get_info)) =
            (sdk.get_sensor_mode_count, sdk.get_sensor_mode_info)
        else {
            return Ok(Vec::new());
        };
        let mut count: c_int = 0;
        check_poa_error(
            // SAFETY: the camera is open; `&mut count` is a valid out-pointer.
            unsafe { get_count(self.camera_id, &mut count) },
            "GetSensorModeCount",
        )?;
        let mut modes = Vec::new();
        for index in 0..count {
            // SAFETY: POASensorModeInfo is two char arrays; zeroed is a valid out buffer.
            let mut info: POASensorModeInfo = unsafe { std::mem::zeroed() };
            check_poa_error(
                // SAFETY: the camera is open; `index` is in [0, count); `&mut info` is a valid out-pointer.
                unsafe { get_info(self.camera_id, index, &mut info) },
                "GetSensorModeInfo",
            )?;
            modes.push(ReadoutMode {
                name: safe_cstr_to_string(info.name.as_ptr(), info.name.len()),
                description: safe_cstr_to_string(info.desc.as_ptr(), info.desc.len()),
                index,
                gain_min: None,
                gain_max: None,
                offset_min: None,
                offset_max: None,
            });
        }
        Ok(modes)
    }

    /// The name of the sensor mode the camera is in, for the frame's metadata.
    pub(crate) fn current_sensor_mode(&self, sdk: &PoaSdk) -> Option<String> {
        if !self.core.capabilities.supports_readout_modes {
            return None;
        }
        let get_mode = sdk.get_sensor_mode?;
        let mut index: c_int = 0;
        // SAFETY: the camera is open; `&mut index` is a valid out-pointer.
        if unsafe { get_mode(self.camera_id, &mut index) } != 0 {
            return None;
        }
        self.sensor_modes(sdk)
            .ok()?
            .into_iter()
            .find(|mode| mode.index == index)
            .map(|mode| mode.name)
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
