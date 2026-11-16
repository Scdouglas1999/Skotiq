//! A frame that names no gain or offset is taken at what is stated for the
//! camera (its profile's defaults), never at what an earlier frame left on
//! the camera.
//!
//! The rig, 2026-11-15: a manual frame at gain 600, 2x2, then a run. Its
//! centering frames came out 69.7 % clipped with no stars and its autofocus
//! frames found none, while its lights (which name their gain) were fine.
//! Here the same order runs the sequencer's own Center and Autofocus against
//! the host's camera path, with the defaults stated through the host API the
//! app calls.

use crate::api::devices::camera::api_camera_state_frame_defaults;
use crate::device::{DeviceInfo, DeviceType, DriverType};
use crate::device_manager::get_device_manager;
use skotiq_device::{
    CameraCapabilities, CameraDriver, CameraState, CameraStatus, DeviceDriver, DriverError,
    ExposureParams, ImageData as DeviceImageData, ImageMetadata, ReadoutMode, SensorInfo, SubFrame,
    Vendor, VendorFeatures,
};
use skotiq_sequencer::{
    AutofocusConfig, CenterConfig, ExposureRequest, InstructionContext, NullDeviceOps, RunShared,
    SharedDeviceOps,
};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

/// What one frame was taken at.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct TakenAt {
    gain: i32,
    offset: i32,
    bin: (i32, i32),
}

/// A camera's sensor settings, which stay as the last frame set them, and
/// the frames taken.
#[derive(Debug)]
struct Sensor {
    gain: i32,
    offset: i32,
    frames: Vec<TakenAt>,
    /// Raised when a frame starts, to end the step that asked for it.
    stop_after_frame: Option<Arc<AtomicBool>>,
}

#[derive(Debug)]
struct SettingsCamera {
    id: String,
    sensor: Arc<Mutex<Sensor>>,
}

#[async_trait::async_trait]
impl DeviceDriver for SettingsCamera {
    fn id(&self) -> &str {
        &self.id
    }

    fn name(&self) -> &str {
        "Settings Camera"
    }

    fn vendor(&self) -> Vendor {
        Vendor::Other("Test".to_string())
    }

    fn is_connected(&self) -> bool {
        true
    }

    async fn connect(&mut self) -> Result<(), DriverError> {
        Ok(())
    }

    async fn disconnect(&mut self) -> Result<(), DriverError> {
        Ok(())
    }
}

#[async_trait::async_trait]
impl CameraDriver for SettingsCamera {
    fn capabilities(&self) -> CameraCapabilities {
        CameraCapabilities {
            can_set_gain: true,
            can_set_offset: true,
            ..CameraCapabilities::default()
        }
    }

    async fn get_status(&self) -> Result<CameraStatus, DriverError> {
        let sensor = self.sensor.lock().unwrap();
        Ok(CameraStatus {
            state: CameraState::Idle,
            sensor_temp: None,
            cooler_power: None,
            target_temp: None,
            cooler_on: Some(false),
            gain: sensor.gain,
            offset: sensor.offset,
            bin_x: 1,
            bin_y: 1,
            exposure_remaining: None,
        })
    }

    async fn start_exposure(&mut self, params: ExposureParams) -> Result<(), DriverError> {
        let mut sensor = self.sensor.lock().unwrap();
        if let Some(gain) = params.gain {
            sensor.gain = gain;
        }
        if let Some(offset) = params.offset {
            sensor.offset = offset;
        }
        let taken = TakenAt {
            gain: sensor.gain,
            offset: sensor.offset,
            bin: (params.bin_x, params.bin_y),
        };
        sensor.frames.push(taken);
        if let Some(stop) = &sensor.stop_after_frame {
            stop.store(true, Ordering::Relaxed);
        }
        Ok(())
    }

    async fn abort_exposure(&mut self) -> Result<(), DriverError> {
        Ok(())
    }

    async fn is_exposure_complete(&self) -> Result<bool, DriverError> {
        Ok(true)
    }

    async fn download_image(&mut self) -> Result<DeviceImageData, DriverError> {
        let sensor = self.sensor.lock().unwrap();
        let (bin_x, bin_y) = sensor.frames.last().map_or((1, 1), |frame| frame.bin);
        Ok(DeviceImageData {
            width: 64,
            height: 64,
            data: vec![1000; 64 * 64],
            bits_per_pixel: 16,
            bayer_pattern: None,
            metadata: ImageMetadata {
                exposure_time: 1.0,
                gain: sensor.gain,
                offset: sensor.offset,
                bin_x,
                bin_y,
                temperature: None,
                timestamp: chrono::Utc::now(),
                subframe: None,
                readout_mode: None,
                vendor_data: VendorFeatures::default(),
                camera_file: None,
            },
        })
    }

    async fn set_cooler(
        &mut self,
        _enabled: bool,
        _target_temp: Option<f64>,
    ) -> Result<(), DriverError> {
        Ok(())
    }

    async fn get_temperature(&self) -> Result<f64, DriverError> {
        Err(DriverError::NotSupported)
    }

    async fn get_cooler_power(&self) -> Result<f64, DriverError> {
        Err(DriverError::NotSupported)
    }

    async fn set_gain(&mut self, gain: i32) -> Result<(), DriverError> {
        self.sensor.lock().unwrap().gain = gain;
        Ok(())
    }

    async fn get_gain(&self) -> Result<i32, DriverError> {
        Ok(self.sensor.lock().unwrap().gain)
    }

    async fn set_offset(&mut self, offset: i32) -> Result<(), DriverError> {
        self.sensor.lock().unwrap().offset = offset;
        Ok(())
    }

    async fn get_offset(&self) -> Result<i32, DriverError> {
        Ok(self.sensor.lock().unwrap().offset)
    }

    async fn set_binning(&mut self, _bin_x: i32, _bin_y: i32) -> Result<(), DriverError> {
        Ok(())
    }

    async fn get_binning(&self) -> Result<(i32, i32), DriverError> {
        Ok((1, 1))
    }

    async fn set_subframe(&mut self, _subframe: Option<SubFrame>) -> Result<(), DriverError> {
        Ok(())
    }

    fn get_sensor_info(&self) -> SensorInfo {
        SensorInfo {
            width: 64,
            height: 64,
            pixel_size_x: 3.8,
            pixel_size_y: 3.8,
            max_adu: 65535,
            bit_depth: 16,
            color: false,
            bayer_pattern: None,
            saturation_adu: None,
        }
    }

    async fn get_readout_modes(&self) -> Result<Vec<ReadoutMode>, DriverError> {
        Ok(Vec::new())
    }

    async fn set_readout_mode(&mut self, _mode: &ReadoutMode) -> Result<(), DriverError> {
        Ok(())
    }

    async fn get_vendor_features(&self) -> Result<VendorFeatures, DriverError> {
        Ok(VendorFeatures::default())
    }

    async fn get_gain_range(&self) -> Result<(i32, i32), DriverError> {
        Ok((0, 600))
    }

    async fn get_offset_range(&self) -> Result<(i32, i32), DriverError> {
        Ok((0, 100))
    }
}

/// The host's camera path for the camera; a null device layer for the rest
/// of the rig.
struct Rig {
    host: SharedDeviceOps,
    rest: NullDeviceOps,
}

skotiq_sequencer::forward_device_ops!(Rig => host: CameraOps);
skotiq_sequencer::forward_device_ops!(Rig => rest: MountOps, FocuserOps, FilterWheelOps, RotatorOps, GuiderOps, DomeOps, CoverCalibratorOps, SafetyOps, PlateSolveOps, FrameStoreOps, OperatorNotifyOps, ConnectionOps, SiteOps);

/// The rig's ASI1600 after a manual frame at gain 600, offset 21, 2x2, with
/// its profile (gain 139, offset 21) stated as the app states it.
async fn camera_left_at_gain_600(device_id: &str) -> Arc<Mutex<Sensor>> {
    let sensor = Arc::new(Mutex::new(Sensor {
        gain: 139,
        offset: 21,
        frames: Vec::new(),
        stop_after_frame: None,
    }));
    let mgr = get_device_manager();
    mgr.register_device(
        DeviceInfo {
            id: device_id.to_string(),
            name: "Settings Camera".to_string(),
            device_type: DeviceType::Camera,
            driver_type: DriverType::Native,
            description: "Settings camera".to_string(),
            driver_version: "test".to_string(),
            serial_number: None,
            unique_id: None,
            display_name: "Settings Camera".to_string(),
        },
        false,
    )
    .await;
    mgr.hold_vendor_camera(
        device_id,
        Box::new(SettingsCamera {
            id: device_id.to_string(),
            sensor: sensor.clone(),
        }),
    );
    api_camera_state_frame_defaults(device_id.to_string(), Some(139), Some(21), None);
    crate::api::imaging::camera_start_exposure_opt(
        device_id.to_string(),
        0.01,
        Some(600),
        Some(21),
        2,
        2,
    )
    .await
    .expect("manual frame");
    assert_eq!(
        sensor.lock().unwrap().frames,
        [TakenAt {
            gain: 600,
            offset: 21,
            bin: (2, 2)
        }]
    );
    sensor.lock().unwrap().frames.clear();
    sensor
}

async fn disconnect(device_id: &str) {
    let mgr = get_device_manager();
    mgr.unregister_device(device_id).await;
    mgr.handles.remove(device_id);
    let _ = crate::api::imaging::api_clear_device_image(device_id.to_string()).await;
}

/// A run's step on the rig whose first frame ends it.
fn step_on(device_id: &str, sensor: &Arc<Mutex<Sensor>>) -> InstructionContext {
    let cancel = Arc::new(AtomicBool::new(false));
    sensor.lock().unwrap().stop_after_frame = Some(cancel.clone());
    let ops: SharedDeviceOps = Arc::new(Rig {
        host: super::create_unified_device_ops(),
        rest: NullDeviceOps,
    });
    let mut run = RunShared::new(ops);
    run.rig.camera_id = Some(device_id.to_string());
    run.rig.mount_id = Some("mount-1".to_string());
    run.rig.focuser_id = Some("focuser-1".to_string());
    let mut ctx = InstructionContext::new(run, cancel);
    ctx.target_name = Some("M1".to_string());
    ctx.target_ra = Some(5.575);
    ctx.target_dec = Some(22.01);
    ctx
}

const PROFILE_GAIN_UNBINNED: TakenAt = TakenAt {
    gain: 139,
    offset: 21,
    bin: (1, 1),
};

#[tokio::test]
async fn a_runs_centering_frame_takes_the_profile_gain_not_the_manual_frames() {
    let device_id = "native:frame_defaults_center";
    let sensor = camera_left_at_gain_600(device_id).await;
    let ctx = step_on(device_id, &sensor);
    let config = CenterConfig {
        max_attempts: 1,
        exposure_duration: 0.01,
        ..CenterConfig::default()
    };

    skotiq_sequencer::execute_center(&config, &ctx, None).await;

    let frames = sensor.lock().unwrap().frames.clone();
    disconnect(device_id).await;
    assert_eq!(frames.first(), Some(&PROFILE_GAIN_UNBINNED), "{frames:?}");
}

#[tokio::test]
async fn a_runs_autofocus_frame_takes_the_profile_gain_not_the_manual_frames() {
    let device_id = "native:frame_defaults_autofocus";
    let sensor = camera_left_at_gain_600(device_id).await;
    let ctx = step_on(device_id, &sensor);
    let config = AutofocusConfig {
        exposure_duration: 0.01,
        steps_out: 1,
        exposures_per_point: 1,
        focuser_settle_time_ms: 0,
        ..AutofocusConfig::default()
    };

    skotiq_sequencer::execute_autofocus(&config, &ctx, None).await;

    let frames = sensor.lock().unwrap().frames.clone();
    disconnect(device_id).await;
    assert_eq!(frames.first(), Some(&PROFILE_GAIN_UNBINNED), "{frames:?}");
}

/// The request the post-flip recenter, the flip's nearby recovery and the
/// recovery frame after an outside mount move each make: duration only.
#[tokio::test]
async fn a_frame_that_names_only_its_length_takes_the_profile_gain() {
    let device_id = "native:frame_defaults_recenter";
    let sensor = camera_left_at_gain_600(device_id).await;

    super::create_unified_device_ops()
        .camera_start_exposure(ExposureRequest::new(device_id, 0.01))
        .await
        .expect("recenter frame");

    let frames = sensor.lock().unwrap().frames.clone();
    disconnect(device_id).await;
    assert_eq!(frames, [PROFILE_GAIN_UNBINNED]);
}

/// A frame that names its gain and offset is taken at them: the Imaging
/// panel's frames and a run's lights.
#[tokio::test]
async fn a_frame_that_names_its_gain_takes_it() {
    let device_id = "native:frame_defaults_named";
    let sensor = camera_left_at_gain_600(device_id).await;

    super::create_unified_device_ops()
        .camera_start_exposure(
            ExposureRequest::new(device_id, 0.01)
                .gain(Some(76))
                .offset(Some(15)),
        )
        .await
        .expect("light frame");

    let frames = sensor.lock().unwrap().frames.clone();
    disconnect(device_id).await;
    assert_eq!(
        frames,
        [TakenAt {
            gain: 76,
            offset: 15,
            bin: (1, 1)
        }]
    );
}
