//! ASCOM Camera (ICameraV*) wrapper and batch status types.

use crate::com::ComDispatch;
use crate::error::{AscomError, AscomResult};
use crate::health::ConnectionHealth;

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
pub struct Camera<D> {
    pub(crate) device: D,
}

#[cfg(windows)]
impl Camera<crate::windows::AscomDeviceConnection> {
    pub fn new(prog_id: &str) -> AscomResult<Self> {
        Ok(Self {
            device: crate::windows::AscomDeviceConnection::new(prog_id)?,
        })
    }
}

impl<D: ComDispatch> Camera<D> {
    /// Wrap a connection that already exists.
    pub fn over(device: D) -> Self {
        Self { device }
    }

    pub fn connect(&mut self) -> AscomResult<()> {
        self.device.connect()
    }

    pub fn disconnect(&mut self) -> AscomResult<()> {
        self.device.disconnect()
    }

    /// Show the ASCOM driver setup dialog to let the user choose the device/config
    pub fn setup_dialog(&mut self) -> AscomResult<()> {
        self.device.call("SetupDialog", &[])
    }

    pub fn name(&self) -> AscomResult<String> {
        self.device.get("Name")
    }

    pub fn description(&self) -> AscomResult<String> {
        self.device.get("Description")
    }

    /// Get the interface version number
    pub fn interface_version(&self) -> AscomResult<i32> {
        self.device.get("InterfaceVersion")
    }

    /// Get the driver version string
    pub fn driver_version(&self) -> AscomResult<String> {
        self.device.get("DriverVersion")
    }

    /// Get the driver info/description
    pub fn driver_info(&self) -> AscomResult<String> {
        self.device.get("DriverInfo")
    }

    /// Get the list of supported custom actions
    pub fn supported_actions(&self) -> AscomResult<Vec<String>> {
        self.device.get("SupportedActions")
    }

    pub fn camera_x_size(&self) -> AscomResult<i32> {
        self.device.get("CameraXSize")
    }

    pub fn camera_y_size(&self) -> AscomResult<i32> {
        self.device.get("CameraYSize")
    }

    pub fn pixel_size_x(&self) -> AscomResult<f64> {
        self.device.get("PixelSizeX")
    }

    pub fn pixel_size_y(&self) -> AscomResult<f64> {
        self.device.get("PixelSizeY")
    }

    pub fn max_bin_x(&self) -> AscomResult<i32> {
        self.device.get("MaxBinX")
    }

    pub fn max_bin_y(&self) -> AscomResult<i32> {
        self.device.get("MaxBinY")
    }

    pub fn bin_x(&self) -> AscomResult<i32> {
        self.device.get("BinX")
    }

    pub fn bin_y(&self) -> AscomResult<i32> {
        self.device.get("BinY")
    }

    pub fn set_bin_x(&mut self, value: i32) -> AscomResult<()> {
        self.device.put("BinX", value)
    }

    pub fn set_bin_y(&mut self, value: i32) -> AscomResult<()> {
        self.device.put("BinY", value)
    }

    pub fn can_set_ccd_temperature(&self) -> AscomResult<bool> {
        self.device.get("CanSetCCDTemperature")
    }

    pub fn ccd_temperature(&self) -> AscomResult<f64> {
        self.device.get("CCDTemperature")
    }

    pub fn set_ccd_temperature(&mut self, temp: f64) -> AscomResult<()> {
        self.device.put("SetCCDTemperature", temp)
    }

    pub fn cooler_on(&self) -> AscomResult<bool> {
        self.device.get("CoolerOn")
    }

    pub fn set_cooler_on(&mut self, on: bool) -> AscomResult<()> {
        self.device.put("CoolerOn", on)
    }

    pub fn cooler_power(&self) -> AscomResult<f64> {
        self.device.get("CoolerPower")
    }

    pub fn gain(&self) -> AscomResult<i32> {
        self.device.get("Gain")
    }

    pub fn set_gain(&mut self, gain: i32) -> AscomResult<()> {
        self.device.put("Gain", gain)
    }

    pub fn offset(&self) -> AscomResult<i32> {
        self.device.get("Offset")
    }

    pub fn set_offset(&mut self, offset: i32) -> AscomResult<()> {
        self.device.put("Offset", offset)
    }

    pub fn camera_state(&self) -> AscomResult<i32> {
        self.device.get("CameraState")
    }

    pub fn image_ready(&self) -> AscomResult<bool> {
        self.device.get("ImageReady")
    }

    /// ASCOM `PercentCompleted` (0..100). Per the ICameraV3 spec the property
    /// is only valid while CameraState is in {Exposing, Reading, Downloading};
    /// drivers may raise `InvalidOperationException` outside that window.
    /// Callers should treat any error as "not currently reporting" rather than
    /// a hard failure.
    pub fn percent_completed(&self) -> AscomResult<i32> {
        self.device.get("PercentCompleted")
    }

    pub fn start_exposure(&mut self, duration: f64, light: bool) -> AscomResult<()> {
        self.device
            .call("StartExposure", &[duration.into(), light.into()])
    }

    pub fn abort_exposure(&mut self) -> AscomResult<()> {
        self.device.call("AbortExposure", &[])
    }

    pub fn stop_exposure(&mut self) -> AscomResult<()> {
        self.device.call("StopExposure", &[])
    }

    /// Get the image array from the camera
    /// Returns (pixel_data, dim1_size, dim2_size)
    /// Extracts the SAFEARRAY from the ASCOM ImageArray property
    pub fn image_array(&self) -> AscomResult<(Vec<i32>, usize, usize)> {
        // The download keeps its own failure wording, and reports a reply it
        // cannot read with the array reader's own description.
        self.device.get("ImageArray").map_err(|e| match e {
            AscomError::Invoke { cause, .. } => {
                AscomError::ImageArray(format!("Failed to get ImageArray property: {cause}"))
            }
            AscomError::UnexpectedType {
                detail: Some(detail),
                ..
            } => AscomError::ImageArray(detail),
            other => other,
        })
    }

    pub fn readout_modes(&self) -> AscomResult<Vec<String>> {
        self.device.get("ReadoutModes")
    }

    pub fn set_readout_mode(&mut self, mode: i32) -> AscomResult<()> {
        self.device.put("ReadoutMode", mode)
    }

    pub fn sensor_type(&self) -> AscomResult<i32> {
        self.device.get("SensorType")
    }

    pub fn bayer_offset_x(&self) -> AscomResult<i32> {
        self.device.get("BayerOffsetX")
    }

    pub fn bayer_offset_y(&self) -> AscomResult<i32> {
        self.device.get("BayerOffsetY")
    }

    pub fn start_x(&self) -> AscomResult<i32> {
        self.device.get("StartX")
    }

    pub fn start_y(&self) -> AscomResult<i32> {
        self.device.get("StartY")
    }

    pub fn num_x(&self) -> AscomResult<i32> {
        self.device.get("NumX")
    }

    pub fn num_y(&self) -> AscomResult<i32> {
        self.device.get("NumY")
    }

    pub fn set_start_x(&mut self, value: i32) -> AscomResult<()> {
        self.device.put("StartX", value)
    }

    pub fn set_start_y(&mut self, value: i32) -> AscomResult<()> {
        self.device.put("StartY", value)
    }

    pub fn set_num_x(&mut self, value: i32) -> AscomResult<()> {
        self.device.put("NumX", value)
    }

    pub fn set_num_y(&mut self, value: i32) -> AscomResult<()> {
        self.device.put("NumY", value)
    }

    pub fn can_abort_exposure(&self) -> AscomResult<bool> {
        self.device.get("CanAbortExposure")
    }

    pub fn can_stop_exposure(&self) -> AscomResult<bool> {
        self.device.get("CanStopExposure")
    }

    /// Check if camera has a mechanical shutter
    pub fn has_shutter(&self) -> AscomResult<bool> {
        self.device.get("HasShutter")
    }

    /// Get the sensor name
    pub fn sensor_name(&self) -> AscomResult<String> {
        self.device.get("SensorName")
    }

    /// Get the maximum ADU value (determines bit depth)
    pub fn max_adu(&self) -> AscomResult<i32> {
        self.device.get("MaxADU")
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
    pub fn heartbeat(&self) -> AscomResult<()> {
        self.device.heartbeat()
    }

    /// Get connection health status
    pub fn get_health(&self) -> ConnectionHealth {
        self.device.health()
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
#[cfg(all(test, windows))]
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
        let camera = Camera { device };

        let err = camera.image_array().unwrap_err().to_string();

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
