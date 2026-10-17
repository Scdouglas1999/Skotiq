//! ASCOM Camera (ICameraV*) wrapper and batch status types.

use windows::Win32::System::Com::{DISPATCH_PROPERTYGET, DISPPARAMS};

use super::connection::AscomDeviceConnection;
use super::health::ConnectionHealth;
use super::variant::{extract_safearray_i32, OwnedVariant};

/// ASCOM Camera
/// ASCOM Camera (ICameraV*).
///
/// Thread-affinity invariant: `AscomCamera` must not cross threads after
/// construction. Every method here ultimately calls a COM property/method on
/// `IDispatch`, and COM apartment threading requires those calls to execute on
/// the same STA thread that called `CoInitialize`. The bridge layer enforces
/// this by parking the `AscomCamera` inside a dedicated STA worker thread (see
/// `bridge/src/ascom_wrapper.rs`) and routing every operation through an mpsc
/// channel. Use `AscomCameraWrapper` for any cross-thread access.
pub struct AscomCamera {
    device: AscomDeviceConnection,
}

impl AscomCamera {
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

    /// Show the ASCOM driver setup dialog to let the user choose the device/config
    pub fn setup_dialog(&mut self) -> Result<(), String> {
        self.device.call_method_0("SetupDialog")
    }

    pub fn name(&self) -> Result<String, String> {
        self.device.get_string_property("Name")
    }

    pub fn description(&self) -> Result<String, String> {
        self.device.get_string_property("Description")
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

    pub fn camera_x_size(&self) -> Result<i32, String> {
        self.device.get_int_property("CameraXSize")
    }

    pub fn camera_y_size(&self) -> Result<i32, String> {
        self.device.get_int_property("CameraYSize")
    }

    pub fn pixel_size_x(&self) -> Result<f64, String> {
        self.device.get_double_property("PixelSizeX")
    }

    pub fn pixel_size_y(&self) -> Result<f64, String> {
        self.device.get_double_property("PixelSizeY")
    }

    pub fn max_bin_x(&self) -> Result<i32, String> {
        self.device.get_int_property("MaxBinX")
    }

    pub fn max_bin_y(&self) -> Result<i32, String> {
        self.device.get_int_property("MaxBinY")
    }

    pub fn bin_x(&self) -> Result<i32, String> {
        self.device.get_int_property("BinX")
    }

    pub fn bin_y(&self) -> Result<i32, String> {
        self.device.get_int_property("BinY")
    }

    pub fn set_bin_x(&mut self, value: i32) -> Result<(), String> {
        self.device.set_int_property("BinX", value)
    }

    pub fn set_bin_y(&mut self, value: i32) -> Result<(), String> {
        self.device.set_int_property("BinY", value)
    }

    pub fn can_set_ccd_temperature(&self) -> Result<bool, String> {
        self.device.get_bool_property("CanSetCCDTemperature")
    }

    pub fn ccd_temperature(&self) -> Result<f64, String> {
        self.device.get_double_property("CCDTemperature")
    }

    pub fn set_ccd_temperature(&mut self, temp: f64) -> Result<(), String> {
        self.device.set_double_property("SetCCDTemperature", temp)
    }

    pub fn cooler_on(&self) -> Result<bool, String> {
        self.device.get_bool_property("CoolerOn")
    }

    pub fn set_cooler_on(&mut self, on: bool) -> Result<(), String> {
        self.device.set_bool_property("CoolerOn", on)
    }

    pub fn cooler_power(&self) -> Result<f64, String> {
        self.device.get_double_property("CoolerPower")
    }

    pub fn gain(&self) -> Result<i32, String> {
        self.device.get_int_property("Gain")
    }

    pub fn set_gain(&mut self, gain: i32) -> Result<(), String> {
        self.device.set_int_property("Gain", gain)
    }

    pub fn offset(&self) -> Result<i32, String> {
        self.device.get_int_property("Offset")
    }

    pub fn set_offset(&mut self, offset: i32) -> Result<(), String> {
        self.device.set_int_property("Offset", offset)
    }

    pub fn camera_state(&self) -> Result<i32, String> {
        self.device.get_int_property("CameraState")
    }

    pub fn image_ready(&self) -> Result<bool, String> {
        self.device.get_bool_property("ImageReady")
    }

    /// ASCOM `PercentCompleted` (0..100). Per the ICameraV3 spec the property
    /// is only valid while CameraState is in {Exposing, Reading, Downloading};
    /// drivers may raise `InvalidOperationException` outside that window.
    /// Callers should treat any error as "not currently reporting" rather than
    /// a hard failure.
    pub fn percent_completed(&self) -> Result<i32, String> {
        self.device.get_int_property("PercentCompleted")
    }

    pub fn start_exposure(&mut self, duration: f64, light: bool) -> Result<(), String> {
        self.device
            .call_method_2_double_bool("StartExposure", duration, light)
    }

    pub fn abort_exposure(&mut self) -> Result<(), String> {
        self.device.call_method("AbortExposure")
    }

    pub fn stop_exposure(&mut self) -> Result<(), String> {
        self.device.call_method("StopExposure")
    }

    /// Get the image array from the camera
    /// Returns (pixel_data, dim1_size, dim2_size)
    /// Extracts the SAFEARRAY from the ASCOM ImageArray property
    pub fn image_array(&self) -> Result<(Vec<i32>, usize, usize), String> {
        // SAFETY: DISPATCH_PROPERTYGET on the camera's `ImageArray` property —
        // empty DISPPARAMS, an `OwnedVariant` out-pointer, zeroed reserved GUID.
        // The SAFEARRAY extraction in `extract_safearray_i32` validates
        // dims/bounds and deep-copies into an owned `Vec<i32>` before any free.
        // The `OwnedVariant` guard then runs `VariantClear` on drop to release
        // the driver-returned SAFEARRAY (~96 MiB/frame) so it cannot leak.
        // Caller invariant: STA worker thread (also where the guard's
        // `VariantClear` runs).
        unsafe {
            let dispid = self.device.get_dispid("ImageArray")?;
            let mut result = OwnedVariant::empty();
            let params = DISPPARAMS::default();

            // Goes through `invoke_with_retry` rather than a hand-rolled
            // `dispatch.Invoke`: the hand-rolled call passed `None` for
            // `pExcepInfo`, so a driver that refused the download had its
            // sentence discarded and the operator got only
            // "Exception occurred. (0x80020009)" for a lost frame.
            self.device
                .invoke_with_retry(dispid, DISPATCH_PROPERTYGET, &params, Some(result.as_mut()))
                .map_err(|e| format!("Failed to get ImageArray property: {}", e))?;

            // Extract SAFEARRAY from VARIANT (deep-copies the pixels) before the
            // `OwnedVariant` guard drops and frees the source SAFEARRAY.
            extract_safearray_i32(result.get())
        }
    }

    pub fn readout_modes(&self) -> Result<Vec<String>, String> {
        self.device.get_string_array_property("ReadoutModes")
    }

    pub fn set_readout_mode(&mut self, mode: i32) -> Result<(), String> {
        self.device.set_int_property("ReadoutMode", mode)
    }

    pub fn sensor_type(&self) -> Result<i32, String> {
        self.device.get_int_property("SensorType")
    }

    pub fn bayer_offset_x(&self) -> Result<i32, String> {
        self.device.get_int_property("BayerOffsetX")
    }

    pub fn bayer_offset_y(&self) -> Result<i32, String> {
        self.device.get_int_property("BayerOffsetY")
    }

    pub fn start_x(&self) -> Result<i32, String> {
        self.device.get_int_property("StartX")
    }

    pub fn start_y(&self) -> Result<i32, String> {
        self.device.get_int_property("StartY")
    }

    pub fn num_x(&self) -> Result<i32, String> {
        self.device.get_int_property("NumX")
    }

    pub fn num_y(&self) -> Result<i32, String> {
        self.device.get_int_property("NumY")
    }

    pub fn set_start_x(&mut self, value: i32) -> Result<(), String> {
        self.device.set_int_property("StartX", value)
    }

    pub fn set_start_y(&mut self, value: i32) -> Result<(), String> {
        self.device.set_int_property("StartY", value)
    }

    pub fn set_num_x(&mut self, value: i32) -> Result<(), String> {
        self.device.set_int_property("NumX", value)
    }

    pub fn set_num_y(&mut self, value: i32) -> Result<(), String> {
        self.device.set_int_property("NumY", value)
    }

    pub fn can_abort_exposure(&self) -> Result<bool, String> {
        self.device.get_bool_property("CanAbortExposure")
    }

    pub fn can_stop_exposure(&self) -> Result<bool, String> {
        self.device.get_bool_property("CanStopExposure")
    }

    /// Check if camera has a mechanical shutter
    pub fn has_shutter(&self) -> Result<bool, String> {
        self.device.get_bool_property("HasShutter")
    }

    /// Get the sensor name
    pub fn sensor_name(&self) -> Result<String, String> {
        self.device.get_string_property("SensorName")
    }

    /// Get the maximum ADU value (determines bit depth)
    pub fn max_adu(&self) -> Result<i32, String> {
        self.device.get_int_property("MaxADU")
    }

    // Batch property queries

    /// Get thermal status in a single batch operation
    /// Returns (temperature, cooler_on, cooler_power, can_set_temperature)
    ///
    /// This is more efficient than calling each property individually when you
    /// need multiple thermal-related properties.
    pub fn get_thermal_status(&self) -> CameraThermalStatus {
        CameraThermalStatus {
            temperature: self.ccd_temperature().ok(),
            cooler_on: self.cooler_on().ok(),
            cooler_power: self.cooler_power().ok(),
            can_set_temperature: self.can_set_ccd_temperature().ok(),
        }
    }

    /// Get sensor configuration in a single batch operation
    /// Returns sensor dimensions, pixel sizes, and binning limits
    pub fn get_sensor_config(&self) -> CameraSensorConfig {
        CameraSensorConfig {
            width: self.camera_x_size().ok(),
            height: self.camera_y_size().ok(),
            pixel_size_x: self.pixel_size_x().ok(),
            pixel_size_y: self.pixel_size_y().ok(),
            max_bin_x: self.max_bin_x().ok(),
            max_bin_y: self.max_bin_y().ok(),
            sensor_type: self.sensor_type().ok(),
            bayer_offset_x: self.bayer_offset_x().ok(),
            bayer_offset_y: self.bayer_offset_y().ok(),
        }
    }

    /// Get current exposure settings in a single batch operation
    pub fn get_exposure_settings(&self) -> CameraExposureSettings {
        CameraExposureSettings {
            bin_x: self.bin_x().ok(),
            bin_y: self.bin_y().ok(),
            start_x: self.start_x().ok(),
            start_y: self.start_y().ok(),
            num_x: self.num_x().ok(),
            num_y: self.num_y().ok(),
            gain: self.gain().ok(),
            offset: self.offset().ok(),
        }
    }

    /// Get complete camera status in a single batch operation
    /// This is the most comprehensive status query
    pub fn get_full_status(&self) -> CameraFullStatus {
        CameraFullStatus {
            state: self.camera_state().ok(),
            image_ready: self.image_ready().ok(),
            // Why: PercentCompleted is only defined during an active exposure;
            // ignoring the error here (vs propagating) is correct because the
            // batch caller treats `None` as "no progress to report".
            percent_completed: self.percent_completed().ok(),
            thermal: self.get_thermal_status(),
            exposure_settings: self.get_exposure_settings(),
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

/// Thermal status for camera
#[derive(Debug, Clone, Default)]
pub struct CameraThermalStatus {
    pub temperature: Option<f64>,
    pub cooler_on: Option<bool>,
    pub cooler_power: Option<f64>,
    pub can_set_temperature: Option<bool>,
}

/// Sensor configuration for camera
#[derive(Debug, Clone, Default)]
pub struct CameraSensorConfig {
    pub width: Option<i32>,
    pub height: Option<i32>,
    pub pixel_size_x: Option<f64>,
    pub pixel_size_y: Option<f64>,
    pub max_bin_x: Option<i32>,
    pub max_bin_y: Option<i32>,
    pub sensor_type: Option<i32>,
    pub bayer_offset_x: Option<i32>,
    pub bayer_offset_y: Option<i32>,
}

/// Current exposure settings for camera
#[derive(Debug, Clone, Default)]
pub struct CameraExposureSettings {
    pub bin_x: Option<i32>,
    pub bin_y: Option<i32>,
    pub start_x: Option<i32>,
    pub start_y: Option<i32>,
    pub num_x: Option<i32>,
    pub num_y: Option<i32>,
    pub gain: Option<i32>,
    pub offset: Option<i32>,
}

/// Full camera status
#[derive(Debug, Clone, Default)]
pub struct CameraFullStatus {
    pub state: Option<i32>,
    pub image_ready: Option<bool>,
    /// ASCOM `PercentCompleted` (0..100) when the driver reports progress.
    /// `None` means the driver is not currently in an Exposing/Reading/
    /// Downloading state, or does not implement the property.
    pub percent_completed: Option<i32>,
    pub thermal: CameraThermalStatus,
    pub exposure_settings: CameraExposureSettings,
}

/// Cover for the frame download keeping the driver's explanation.
///
/// `image_array` hand-rolls its own `IDispatch::Invoke`, so these prove it
/// supplies `pExcepInfo` and the driver's message survives; without it a
/// refused download is a lost frame with no stated reason.
#[cfg(test)]
mod excepinfo_tests {
    use super::*;
    use crate::windows::connection::excepinfo_recovery_tests::{connection, Excuse};

    #[test]
    fn a_refused_image_download_says_why() {
        let (device, attempts) = connection(
            Excuse::Spoken {
                source: "ASCOM.ASICamera2",
                description: "ImageArray is not valid until an exposure has completed",
                scode: 0x8004_0400_u32 as i32,
            },
            false,
        );
        let camera = AscomCamera { device };

        let err = camera.image_array().unwrap_err();

        assert!(
            err.contains("ImageArray is not valid until an exposure has completed"),
            "the frame download dropped the driver's description: {err}"
        );
        assert!(err.contains("ASCOM.ASICamera2"), "{err}");
        assert!(
            !err.contains("Exception occurred"),
            "fell back to the bare HRESULT: {err}"
        );
        assert_eq!(
            attempts.load(std::sync::atomic::Ordering::SeqCst),
            3,
            "the download now shares the crate's transient-exception retry"
        );
    }
}
