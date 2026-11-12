//! The simulated camera. The camera itself is the simulator's state for the
//! device id; this handle holds none, so one built for an id that never went
//! through connect answers exactly as the connected one does, and the
//! simulator's own gate says whether the camera is connected.

use super::{Camera, ExposureAborts};
use crate::api::devices::simulation::get_sim_camera_for;
use crate::device_capabilities::DeviceCapabilities;
use crate::device_manager::rig::RigDriver;
use crate::dispatch::DeviceOpError;
use crate::error::SkotiqError;
use async_trait::async_trait;
use skotiq_device::{DriverError, ImageData, SubFrame};
use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};

pub(crate) struct SimCamera {
    device_id: String,
    aborts: Arc<ExposureAborts>,
}

impl SimCamera {
    pub(crate) fn new(device_id: &str) -> Self {
        // Per device id, like the camera's own state, so every handle of one
        // simulated camera announces and hears the same aborts.
        static ABORTS: OnceLock<Mutex<HashMap<String, Arc<ExposureAborts>>>> = OnceLock::new();
        let aborts = ABORTS
            .get_or_init(Default::default)
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .entry(device_id.to_string())
            .or_insert_with(|| Arc::new(ExposureAborts::new()))
            .clone();
        Self {
            device_id: device_id.to_string(),
            aborts,
        }
    }
}

#[async_trait]
impl RigDriver for SimCamera {
    async fn disconnect(&self) -> Result<(), DriverError> {
        get_sim_camera_for(&self.device_id)
            .write()
            .await
            .status
            .connected = false;
        tracing::info!("Simulator disconnected: id={} type=Camera", self.device_id);
        Ok(())
    }

    async fn heartbeat(&self) -> Result<bool, String> {
        Ok(get_sim_camera_for(&self.device_id)
            .read()
            .await
            .status
            .connected)
    }
}

#[async_trait]
impl Camera for SimCamera {
    fn aborts(&self) -> &ExposureAborts {
        &self.aborts
    }

    async fn start_exposure(
        &self,
        duration: f64,
        gain: Option<i32>,
        offset: Option<i32>,
        bin_x: i32,
        bin_y: i32,
        subframe: Option<SubFrame>,
        frame_type: skotiq_device::FrameType,
    ) -> Result<(), DeviceOpError> {
        let device_id = self.device_id.as_str();
        crate::device_manager::ops::sim_gate::require_camera_connected(device_id).await?;
        // Commit the requested settings to the singleton so the download
        // reports what this exposure was actually taken with. Skipping
        // this made the simulator answer with its defaults (gain 100 /
        // offset 10 / 1.0s) regardless of the request, so a simulated
        // run wrote FITS headers that contradicted the sequence — the
        // kind of disagreement that makes simulator testing worse than
        // no testing. `None` gain/offset still means "leave unchanged",
        // matching the real driver branches above.
        {
            // Starts the exposure CLOCK as well as recording the
            // duration: the simulator integrates for the time it was
            // asked for, so callers are paced the way real hardware
            // paces them.
            crate::api::devices::simulation::begin_sim_exposure_for(
                device_id,
                crate::api::devices::simulation::SimExposureRequest {
                    secs: duration,
                    frame_type,
                    subframe: subframe
                        .as_ref()
                        .map(|r| (r.start_x, r.start_y, r.width, r.height)),
                },
            )
            .await;
            let sim = crate::api::devices::simulation::get_sim_camera_for(device_id);
            let mut guard = sim.write().await;
            // A camera without the control ignores the request.
            if let Some(g) = gain.filter(|_| guard.status.can_set_gain) {
                guard.status.gain = g;
            }
            if let Some(o) = offset.filter(|_| guard.status.can_set_offset) {
                guard.status.offset = o;
            }
            guard.status.bin_x = bin_x;
            guard.status.bin_y = bin_y;
        }
        tracing::info!("camera_start_exposure: Simulator exposure started");
        Ok(())
    }

    async fn is_exposure_complete(&self) -> Result<bool, DeviceOpError> {
        let device_id = self.device_id.as_str();
        // Complete only once the requested integration time has
        // elapsed, so the simulator paces a capture loop the way a real
        // camera does (see `SIM_EXPOSURE_START`). Refuse the call when
        // not connected, so callers can distinguish "nothing to expose"
        // from "no camera attached".
        crate::device_manager::ops::sim_gate::require_camera_connected(device_id).await?;
        Ok(crate::api::devices::simulation::sim_exposure_is_complete(device_id).await)
    }

    async fn stop_exposure(&self) -> Result<(), DeviceOpError> {
        let device_id = self.device_id.as_str();
        crate::device_manager::ops::sim_gate::require_camera_connected(device_id).await?;
        // Release a caller polling for completion, but remember that the
        // frame was abandoned: a download afterwards has nothing to
        // hand back and must say so.
        crate::api::devices::simulation::abort_sim_exposure(device_id).await;
        Ok(())
    }

    async fn read_frame(&self) -> Result<ImageData, DeviceOpError> {
        let device_id = self.device_id.as_str();
        // Project gain/offset/bin/temperature from the singleton so a
        // simulated download reflects whatever the test or UI
        // configured via set_gain / set_offset / set_binning /
        // set_cooler, and take the frame geometry from the SAME sensor
        // declaration the camera advertised.
        let sim = crate::device_manager::ops::sim_gate::read_camera_status(device_id).await?;
        let request =
            crate::device_manager::ops::sim_gate::read_camera_last_exposure(device_id).await?;
        // Claim the finished frame, which both refuses a download the
        // camera cannot honestly satisfy and returns it to idle so a
        // caller that polls completion afterwards is not told to keep
        // waiting. Ungated, this synthesized a full frame stamped with
        // the requested EXPTIME mid-exposure and after an abort, so a
        // cancelled or raced capture still produced a saved light frame.
        crate::api::devices::simulation::take_sim_exposure_for_download(device_id)
            .await
            .map_err(|detail| DeviceOpError::hardware(Some(device_id.to_string()), detail))?;
        // Synthetic download: an electron-domain frame whose star PSF
        // tracks focuser defocus, painting the sky the mount is actually
        // on. `crate::sim_capture` is the single renderer for this path
        // and for the Imaging screen's manual capture, so a simulated
        // frame is plate-solvable however it was taken.
        let frame = crate::sim_capture::render_sim_frame(crate::sim_capture::SimCaptureRequest {
            exposure_secs: request.secs,
            sensor_width: sim.sensor_width.max(1),
            sensor_height: sim.sensor_height.max(1),
            pixel_size_um: sim.pixel_size_x,
            gain: sim.gain,
            offset: sim.offset,
            bin_x: sim.bin_x.max(1) as u32,
            bin_y: sim.bin_y.max(1) as u32,
            subframe: request.subframe,
            frame_type: request.frame_type,
            max_adu: sim.max_adu.clamp(1, u32::from(u16::MAX)) as u16,
            optics: crate::sim_capture::SimOptics::for_camera(device_id),
        })
        .await;
        let (width, height) = (frame.width, frame.height);
        Ok(ImageData {
            width,
            height,
            data: frame.data,
            bits_per_pixel: 16,
            bayer_pattern: None,
            metadata: skotiq_device::ImageMetadata {
                exposure_time: request.secs,
                gain: sim.gain,
                offset: sim.offset,
                bin_x: sim.bin_x,
                bin_y: sim.bin_y,
                temperature: sim.sensor_temp,
                timestamp: chrono::Utc::now(),
                subframe: request.subframe.map(|(start_x, start_y, width, height)| {
                    skotiq_device::SubFrame {
                        start_x,
                        start_y,
                        width,
                        height,
                    }
                }),
                readout_mode: None,
                vendor_data: skotiq_device::VendorFeatures::default(),
                camera_file: None,
            },
        })
    }

    async fn capture_preview(&self) -> Result<Vec<u8>, DeviceOpError> {
        Err(DeviceOpError::unsupported(
            crate::device_manager::ops::sim_gate::unsupported_simulator_device("camera preview"),
        ))
    }

    async fn status(&self) -> Result<crate::device::CameraStatus, DeviceOpError> {
        let device_id = self.device_id.as_str();
        crate::device_manager::ops::sim_gate::read_camera_status(device_id).await
    }

    async fn recommended_settings(
        &self,
    ) -> Result<skotiq_device::CameraRecommendedSettings, DeviceOpError> {
        Ok(skotiq_device::CameraRecommendedSettings::default())
    }

    async fn set_gain(&self, gain: i32) -> Result<(), DeviceOpError> {
        let device_id = self.device_id.as_str();
        // Mutate the singleton so a subsequent `camera_get_status` /
        // `camera_download_image` reflects the new gain. A real driver
        // wouldn't silently drop the value; the simulator must not
        // either.
        let cam = crate::api::devices::simulation::get_sim_camera_for(device_id);
        let mut cam = cam.write().await;
        if !cam.status.connected {
            return Err(DeviceOpError::not_connected(
                None,
                crate::device_manager::ops::sim_gate::not_connected_camera(),
            ));
        }
        if !cam.status.can_set_gain {
            return Err(DeviceOpError::unsupported(
                "This simulated camera has no gain control",
            ));
        }
        cam.status.gain = gain;
        Ok(())
    }

    async fn set_offset(&self, offset: i32) -> Result<(), DeviceOpError> {
        let device_id = self.device_id.as_str();
        let cam = crate::api::devices::simulation::get_sim_camera_for(device_id);
        let mut cam = cam.write().await;
        if !cam.status.connected {
            return Err(DeviceOpError::not_connected(
                None,
                crate::device_manager::ops::sim_gate::not_connected_camera(),
            ));
        }
        if !cam.status.can_set_offset {
            return Err(DeviceOpError::unsupported(
                "This simulated camera has no offset control",
            ));
        }
        cam.status.offset = offset;
        Ok(())
    }

    async fn set_binning(&self, bin_x: i32, bin_y: i32) -> Result<(), DeviceOpError> {
        let device_id = self.device_id.as_str();
        let cam = crate::api::devices::simulation::get_sim_camera_for(device_id);
        let mut cam = cam.write().await;
        if !cam.status.connected {
            return Err(DeviceOpError::not_connected(
                None,
                crate::device_manager::ops::sim_gate::not_connected_camera(),
            ));
        }
        cam.status.bin_x = bin_x;
        cam.status.bin_y = bin_y;
        Ok(())
    }

    async fn set_readout_mode(&self, _mode_index: i32) -> Result<(), DeviceOpError> {
        // `SimulatedCamera::status` has no readout-mode field and the
        // simulator advertises no readout modes, so there is no index
        // to select and nothing a read-back could contradict. Reporting
        // success would leave the caller believing a mode was applied.
        Err(DeviceOpError::unsupported(
            "Simulated cameras do not support readout modes",
        ))
    }

    async fn set_cooler(
        &self,
        enabled: bool,
        target_temp: Option<f64>,
    ) -> Result<(), DeviceOpError> {
        let device_id = self.device_id.as_str();
        let cam = crate::api::devices::simulation::get_sim_camera_for(device_id);
        let mut cam = cam.write().await;
        if !cam.status.connected {
            return Err(DeviceOpError::not_connected(
                None,
                crate::device_manager::ops::sim_gate::not_connected_camera(),
            ));
        }
        cam.status.cooler_on = Some(enabled);
        if let Some(t) = target_temp {
            cam.status.target_temp = Some(t);
        }
        Ok(())
    }

    async fn capabilities(&self, device_id: &str) -> Result<DeviceCapabilities, SkotiqError> {
        let parsed = crate::device_id::parse_device_id_cached(device_id)?;
        crate::device_capabilities::get_simulator_capabilities(&parsed).await
    }
}
