//! Native (vendor SDK) driver dispatch helpers.
//!
//! Methods in this module are additional impl blocks on `DeviceManager` and
//! provide native-SDK-only connect logic. Invoked from the dispatcher methods
//! in `crate::device_manager`. No behavior or signature has changed relative to the
//! previous monolithic `devices.rs`.

use crate::device::*;
use crate::device_manager::DeviceManager;
use skotiq_native::catalog::{self, NativeHandle, OpenRequest};
#[allow(unused_imports)] // Trait methods on `dyn Native*` handles require these in scope.
use skotiq_native::traits::{
    NativeCamera, NativeDevice, NativeFilterWheel, NativeFocuser, NativeMount,
};

impl DeviceManager {
    /// Connect to a Native device
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
        let handle = family
            .open(OpenRequest {
                address,
                name: &info.name,
            })
            .await
            .map_err(|e| e.to_string())?;

        match (handle, info.device_type) {
            (NativeHandle::Camera(mut camera), DeviceType::Camera) => {
                camera.connect().await.map_err(|e| e.to_string())?;
                self.native_cameras
                    .write()
                    .await
                    .insert(info.id.clone(), camera);
                tracing::info!("Connected to native camera: {}", info.name);
            }
            (NativeHandle::Focuser(mut focuser), _) => {
                focuser.connect().await.map_err(|e| e.to_string())?;
                self.native_focusers
                    .write()
                    .await
                    .insert(info.id.clone(), focuser);
                tracing::info!("Connected to native focuser: {}", info.name);
            }
            (NativeHandle::FilterWheel(mut filterwheel), _) => {
                // Close the previous instance first so its SDK handle is
                // not left open behind the new one.
                if let Some(mut old_fw) = self.native_filter_wheels.write().await.remove(&info.id) {
                    let _ = old_fw.disconnect().await;
                    tracing::info!("Disconnected old native filter wheel for {}", info.id);
                }
                filterwheel.connect().await.map_err(|e| e.to_string())?;
                self.native_filter_wheels
                    .write()
                    .await
                    .insert(info.id.clone(), filterwheel);
                tracing::info!("Connected to native filter wheel: {}", info.name);
            }
            (NativeHandle::Mount(mut mount), _) => {
                // Release the port held by any earlier instance of this mount. A
                // heartbeat loss marks the mount Error but leaves its driver in
                // `native_mounts` with the serial port open, and serial ports open
                // exclusively, so the reconnection loop's connect failed "busy"
                // against Skotiq's own handle on every attempt. The old
                // instance is dropped, not disconnected: disconnect() sends a
                // stop-slew, and recovering a link must not halt a mount that may
                // be slewing or tracking perfectly well.
                if let Some(stale) = self.native_mounts.write().await.remove(&info.id) {
                    drop(stale);
                    tracing::info!("Released the previous native mount handle for {}", info.id);
                }
                mount.connect().await.map_err(|e| e.to_string())?;
                self.native_mounts
                    .write()
                    .await
                    .insert(info.id.clone(), mount);
                tracing::info!("Connected to native mount: {}", info.name);
            }
            // A camera registered as another kind of device (a guide camera
            // as a guider) is held as a plain device.
            (NativeHandle::Camera(camera), _) => {
                let mut device: Box<dyn NativeDevice> = camera;
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

        match device_type {
            DeviceType::Camera => {
                let cameras = self.native_cameras.read().await;
                let camera = cameras.get(device_id).ok_or_else(|| {
                    format!(
                        "Native camera {} not registered in device manager",
                        device_id
                    )
                })?;
                if !camera.is_connected() {
                    return Ok(false);
                }
                camera
                    .get_temperature()
                    .await
                    .map(|_| true)
                    .map_err(|e| format!("Native camera liveness probe failed: {}", e))
            }
            DeviceType::Mount => {
                let mounts = self.native_mounts.read().await;
                let mount = mounts.get(device_id).ok_or_else(|| {
                    format!(
                        "Native mount {} not registered in device manager",
                        device_id
                    )
                })?;
                if !mount.is_connected() {
                    return Ok(false);
                }
                mount
                    .get_tracking()
                    .await
                    .map(|_| true)
                    .map_err(|e| format!("Native mount liveness probe failed: {}", e))
            }
            DeviceType::Focuser => {
                // Single probe; the retry for transient focuser/wheel failures
                // lives in the perform_health_check wrapper (driver parity).
                let focusers = self.native_focusers.read().await;
                let focuser = focusers.get(device_id).ok_or_else(|| {
                    format!(
                        "Native focuser {} not registered in device manager",
                        device_id
                    )
                })?;
                if !focuser.is_connected() {
                    return Ok(false);
                }
                focuser
                    .get_position()
                    .await
                    .map(|_| true)
                    .map_err(|e| format!("Native focuser liveness probe failed: {}", e))
            }
            DeviceType::FilterWheel => {
                let wheels = self.native_filter_wheels.read().await;
                let wheel = wheels.get(device_id).ok_or_else(|| {
                    format!(
                        "Native filter wheel {} not registered in device manager",
                        device_id
                    )
                })?;
                if !wheel.is_connected() {
                    return Ok(false);
                }
                wheel
                    .get_position()
                    .await
                    .map(|_| true)
                    .map_err(|e| format!("Native filter wheel liveness probe failed: {}", e))
            }
            other => {
                let devices = self.native_devices.read().await;
                let device = devices.get(device_id).ok_or_else(|| {
                    format!(
                        "Native device {} (type {:?}) not registered in device manager",
                        device_id, other
                    )
                })?;
                Ok(device.is_connected())
            }
        }
    }
}
