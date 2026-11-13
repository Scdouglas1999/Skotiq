//! Native (vendor SDK) driver dispatch helpers.
//!
//! Methods in this module are additional impl blocks on `DeviceManager` and
//! provide native-SDK-only connect logic. Invoked from the dispatcher methods
//! in `crate::device_manager`. No behavior or signature has changed relative to the
//! previous monolithic `devices.rs`.

use crate::device::*;
use crate::device_manager::handle::DeviceHandle;
use crate::device_manager::rig::camera::VendorCamera;
use crate::device_manager::rig::filter_wheel::VendorFilterWheel;
use crate::device_manager::rig::focuser::VendorFocuser;
use crate::device_manager::rig::mount::DriverMount;
use crate::device_manager::DeviceManager;
#[allow(unused_imports)] // Trait methods on `dyn Native*` handles require these in scope.
use skotiq_device::{CameraDriver, DeviceDriver, LongExposureNoiseReduction, MountDriver};
use skotiq_native::catalog::{self, NativeHandle, OpenRequest};
use std::sync::Arc;

impl DeviceManager {
    pub(crate) async fn connect_native(&self, info: &DeviceInfo) -> Result<(), String> {
        // Parse device ID: native:vendor:id
        let parts: Vec<&str> = info.id.split(':').collect();
        if parts.len() < 3 {
            return Err("Invalid native device ID format".to_string());
        }

        let vendor = parts[1];

        if info.device_type == DeviceType::Guider && vendor == "builtin_guider" {
            crate::builtin_guider::connect().await.map_err(|e| {
                let message = format!("Failed to connect built-in guider: {}", e);
                tracing::warn!("{}", message);
                message
            })?;
            tracing::info!("Connected to built-in multi-star guider");
            return Ok(());
        }

        let kind = skotiq_device::DeviceKind::from(info.device_type);
        let noun = match kind {
            skotiq_device::DeviceKind::Camera => "camera ",
            skotiq_device::DeviceKind::Focuser => "focuser ",
            skotiq_device::DeviceKind::FilterWheel => "filter wheel ",
            skotiq_device::DeviceKind::Mount => "mount ",
            _ => "",
        };
        let family = catalog::family(vendor, kind)
            .ok_or_else(|| format!("Unknown native {}vendor: {}", noun, vendor))?;
        let address = info
            .id
            .splitn(3, ':')
            .nth(2)
            .ok_or("Invalid native device ID format")?;
        let site: skotiq_device::SiteSource = Arc::new(|| {
            let location = crate::api::get_state()
                .get_observer_location()
                .ok()
                .flatten()?;
            Some(skotiq_device::MountSiteInfo {
                latitude_deg: location.latitude,
                longitude_deg: location.longitude,
                elevation_m: Some(location.elevation),
            })
        });
        let handle = family
            .open(OpenRequest {
                address,
                name: &info.name,
                site,
            })
            .await
            .map_err(|e| e.to_string())?;

        match (handle, info.device_type) {
            (NativeHandle::Camera(mut camera), DeviceType::Camera) => {
                camera.connect().await.map_err(|e| e.to_string())?;
                self.tell_long_exposure_noise_reduction(
                    &info.name,
                    camera.long_exposure_noise_reduction(),
                );
                self.handles.insert(
                    &info.id,
                    DeviceHandle::Camera(Arc::new(VendorCamera::new(&info.id, camera))),
                );
                tracing::info!("Connected to native camera: {}", info.name);
            }
            (NativeHandle::Focuser(mut focuser), _) => {
                focuser.connect().await.map_err(|e| e.to_string())?;
                self.handles.insert(
                    &info.id,
                    DeviceHandle::Focuser(Arc::new(VendorFocuser::new(&info.id, focuser))),
                );
                tracing::info!("Connected to native focuser: {}", info.name);
            }
            (NativeHandle::FilterWheel(mut filterwheel), _) => {
                // Close the previous instance first so its SDK handle is
                // not left open behind the new one.
                if let Some(old) = self.handles.remove(&info.id) {
                    let _ = old.disconnect().await;
                    tracing::info!("Disconnected old native filter wheel for {}", info.id);
                }
                filterwheel.connect().await.map_err(|e| e.to_string())?;
                self.handles.insert(
                    &info.id,
                    DeviceHandle::FilterWheel(Arc::new(VendorFilterWheel::new(
                        &info.id,
                        filterwheel,
                    ))),
                );
                tracing::info!("Connected to native filter wheel: {}", info.name);
            }
            (NativeHandle::Mount(mut mount), _) => {
                // Release the port held by any earlier instance of this mount. A
                // heartbeat loss marks the mount Error but leaves its driver
                // with the serial port open, and serial ports open exclusively,
                // so the reconnection loop's connect failed "busy" against
                // Skotiq's own handle on every attempt. The old instance is
                // released, not disconnected: disconnect() sends a stop-slew,
                // and recovering a link must not halt a mount that may be
                // slewing or tracking perfectly well.
                if let Some(DeviceHandle::Mount(stale)) = self.handles.remove(&info.id) {
                    stale.release().await;
                    tracing::info!("Released the previous native mount handle for {}", info.id);
                }
                mount.connect().await.map_err(|e| e.to_string())?;
                self.handles.insert(
                    &info.id,
                    DeviceHandle::Mount(Arc::new(DriverMount::vendor(&info.id, mount))),
                );
                tracing::info!("Connected to native mount: {}", info.name);
            }
            // A camera registered as another kind of device (a guide camera
            // as a guider) is held as a plain device.
            (NativeHandle::Camera(camera), _) => {
                let mut device: Box<dyn DeviceDriver> = camera;
                device.connect().await.map_err(|e| e.to_string())?;
                self.native_devices
                    .write()
                    .await
                    .insert(info.id.clone(), device);
                tracing::info!("Connected to native device: {}", info.name);
            }
        }
        Ok(())
    }

    /// Native driver liveness probe for the heartbeat loop (FB-).
    ///
    /// Uses a lightweight SDK read per device class instead of the in-process
    /// `connected` flag, which can stay true after USB unplug.
    pub(crate) async fn perform_native_health_check(
        &self,
        device_id: &str,
        device_type: &DeviceType,
    ) -> Result<bool, String> {
        if device_id == crate::builtin_guider::device_id() {
            let connected = crate::builtin_guider::is_connected().await;
            return Ok(connected);
        }

        let devices = self.native_devices.read().await;
        let device = devices.get(device_id).ok_or_else(|| {
            format!(
                "Native device {} (type {:?}) not registered in device manager",
                device_id, device_type
            )
        })?;
        Ok(device.is_connected())
    }
}

/// What the user is told at connect about a camera's long exposure noise
/// reduction, or `None` when there is nothing to do.
pub(crate) fn long_exposure_noise_reduction_notice(
    camera_name: &str,
    state: LongExposureNoiseReduction,
) -> Option<String> {
    const WHY: &str = "With it on, the camera takes a dark frame after every exposure, \
                       so each frame takes twice as long and is calibrated by the camera.";
    match state {
        LongExposureNoiseReduction::NotApplicable | LongExposureNoiseReduction::Off => None,
        LongExposureNoiseReduction::StaysOn => Some(format!(
            "{camera_name} has long exposure noise reduction on, and the camera did not let \
             Skotiq turn it off. {WHY} Turn it off in the camera's menu."
        )),
        LongExposureNoiseReduction::Unreachable => Some(format!(
            "Skotiq cannot reach the long exposure noise reduction setting of {camera_name}. \
             If it is on, turn it off in the camera's menu. {WHY}"
        )),
    }
}

impl DeviceManager {
    /// Tell the user once, as the camera connects, when its long exposure
    /// noise reduction may still be on.
    fn tell_long_exposure_noise_reduction(
        &self,
        camera_name: &str,
        state: LongExposureNoiseReduction,
    ) {
        let Some(message) = long_exposure_noise_reduction_notice(camera_name, state) else {
            return;
        };
        tracing::warn!("{}", message);
        self.app_state.publish_event(crate::event::create_event_auto_id(
            crate::event::EventSeverity::Warning,
            crate::event::EventCategory::Equipment,
            crate::event::EventPayload::System(crate::event::SystemEvent::Notification {
                title: "Camera noise reduction".to_string(),
                message,
                level: "warning".to_string(),
                explicit_transports: None,
            }),
        ));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn noise_reduction_is_told_only_when_it_may_still_be_on() {
        for quiet in [
            LongExposureNoiseReduction::NotApplicable,
            LongExposureNoiseReduction::Off,
        ] {
            assert_eq!(long_exposure_noise_reduction_notice("X-T5", quiet), None);
        }
        let stays_on =
            long_exposure_noise_reduction_notice("X-T5", LongExposureNoiseReduction::StaysOn)
                .expect("told");
        assert!(stays_on.starts_with("X-T5 has long exposure noise reduction on"));
        assert!(stays_on.contains("Turn it off in the camera's menu."));
        let unreachable = long_exposure_noise_reduction_notice(
            "Canon EOS 6D",
            LongExposureNoiseReduction::Unreachable,
        )
        .expect("told");
        assert!(unreachable.contains("cannot reach the long exposure noise reduction setting"));
        assert!(unreachable.contains("Canon EOS 6D"));
    }
}
