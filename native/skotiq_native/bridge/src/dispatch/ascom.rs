//! ASCOM (Windows COM) driver dispatch helpers.
//!
//! Methods in this module are additional impl blocks on `DeviceManager` and
//! provide ASCOM-only logic for `connect_*`, `query_*_api_version`, and
//! `perform_*_health_check`. They are invoked from the dispatcher methods in
//! `crate::device_manager`. No behavior or signature has changed relative to the
//! previous monolithic `devices.rs`.

use crate::device::*;
use crate::device_manager::DeviceManager;
#[cfg(windows)]
use crate::dispatch::device_common_metadata::{fetch_api_version, DeviceCommonMetadata};
// NativeDevice / NativeMount required so the trait methods `connect`,
// `disconnect`, `get_tracking` — which the ASCOM wrappers implement via the
// trait — are resolvable here.
#[cfg(windows)]
use skotiq_native::traits::{NativeDevice, NativeMount};
#[cfg(windows)]
use std::collections::HashMap;
#[cfg(windows)]
use std::sync::Arc;
#[cfg(windows)]
use tokio::sync::RwLock;

/// Whether interactive driver dialogs may be shown during connect. The decision
/// (headless ⇒ never) lives next to the STA worker that also force-closes any
/// rogue modal, so the gate and its enforcement stay in one place — B1: the
/// ASCOM connect must never block the appliance on an undismissable dialog.
#[cfg(windows)]
use crate::ascom_wrapper::sta_worker::interactive_dialogs_allowed;

/// Probe an ASCOM typed wrapper for its four ASCOM-Common identification
/// properties, releasing the per-type map lock before acquiring the
/// per-wrapper lock so other ops can interleave.
///
/// `not_found_label` is the human-readable role (e.g. `"camera"`) used in
/// the "not connected" error message; the per-arm strings in the original
/// `query_ascom_api_version` differed only in this label so it's the only
/// per-arm parameter required.
///
/// Returns `Err` only when the device is absent from the typed storage map
/// (hard "not connected" signal). Optional-property failures inside the
/// connected wrapper are masked per the silent-fallback contract documented
/// in [`crate::dispatch::device_common_metadata`].
///
/// This helper is `#[cfg(windows)]`-gated because its only caller —
/// [`DeviceManager::query_ascom_api_version`] — is Windows-only.
#[cfg(windows)]
async fn probe_ascom_metadata<W>(
    map: &RwLock<HashMap<String, Arc<RwLock<W>>>>,
    device_id: &str,
    not_found_label: &str,
) -> Result<DeviceApiVersion, String>
where
    W: DeviceCommonMetadata + Send + Sync + 'static,
{
    // Clone the wrapper Arc out of the storage map so the map's RwLock is
    // released before the per-wrapper probe (which holds its own RwLock for
    // the duration of the four awaits). Mirrors the Alpaca pattern in
    // dispatch/alpaca.rs::query_alpaca_api_version.
    let wrapper_arc = {
        let map_guard = map.read().await;
        map_guard.get(device_id).cloned()
    };
    let wrapper_arc = wrapper_arc
        .ok_or_else(|| format!("ASCOM {} {} not connected", not_found_label, device_id))?;

    let guard = wrapper_arc.read().await;
    Ok(fetch_api_version(&*guard, device_id, DeviceApiVersion::from_ascom).await)
}

impl DeviceManager {
    /// Connect to an ASCOM device
    #[cfg(windows)]
    pub(crate) async fn connect_ascom(&self, info: &DeviceInfo) -> Result<(), String> {
        let prog_id = info
            .id
            .strip_prefix("ascom:")
            .ok_or_else(|| "Invalid ASCOM device ID".to_string())?;

        macro_rules! disconnect_existing_ascom {
            ($map:expr, $label:literal) => {{
                let old_wrapper = {
                    let mut map = $map.write().await;
                    map.remove(&info.id)
                };
                if let Some(old_wrapper) = old_wrapper {
                    let mut old = old_wrapper.write().await;
                    match old.disconnect().await {
                        Ok(()) => {
                            tracing::info!(
                                "Disconnected old ASCOM {} wrapper for {} before reconnect",
                                $label,
                                info.id
                            );
                        }
                        Err(error) => {
                            tracing::warn!(
                                "Failed to disconnect old ASCOM {} wrapper for {} before reconnect: {}",
                                $label,
                                info.id,
                                error
                            );
                        }
                    }
                }
            }};
        }

        match info.device_type {
            DeviceType::Camera => {
                use crate::ascom_wrapper::camera::AscomCameraWrapper;
                disconnect_existing_ascom!(self.ascom_cameras, "camera");
                let mut camera = AscomCameraWrapper::new(prog_id.to_string())?;
                // Let the operator pick the specific camera/config via the ASCOM
                // SetupDialog before connecting — but ONLY when one is present.
                // In headless mode the modal dialog has nobody to dismiss it and
                // would hang the connect forever (B1), so we skip it and rely on
                // the driver's saved configuration.
                if interactive_dialogs_allowed() {
                    camera.setup_dialog().await.map_err(|e| e.to_string())?;
                }
                camera.connect().await.map_err(|e| e.to_string())?;

                // Store in typed map for camera-specific operations, wrapped in Arc<RwLock>
                let mut ascom_cameras = self.ascom_cameras.write().await;
                ascom_cameras.insert(info.id.clone(), Arc::new(RwLock::new(camera)));
            }
            DeviceType::Mount => {
                use crate::ascom_wrapper::mount::AscomMountWrapper;
                disconnect_existing_ascom!(self.ascom_mounts, "mount");
                let mut mount = AscomMountWrapper::new(prog_id.to_string())?;
                mount.connect().await.map_err(|e| e.to_string())?;

                let mut ascom_mounts = self.ascom_mounts.write().await;
                ascom_mounts.insert(info.id.clone(), Arc::new(RwLock::new(mount)));
            }
            DeviceType::Focuser => {
                use crate::ascom_wrapper::focuser::AscomFocuserWrapper;
                disconnect_existing_ascom!(self.ascom_focusers, "focuser");
                let mut focuser = AscomFocuserWrapper::new(prog_id.to_string())?;
                focuser.connect().await.map_err(|e| e.to_string())?;

                let mut ascom_focusers = self.ascom_focusers.write().await;
                ascom_focusers.insert(info.id.clone(), Arc::new(RwLock::new(focuser)));
            }
            DeviceType::FilterWheel => {
                use crate::ascom_wrapper::filterwheel::AscomFilterWheelWrapper;

                disconnect_existing_ascom!(self.ascom_filter_wheels, "filter wheel");

                let mut fw = AscomFilterWheelWrapper::new(prog_id.to_string())?;
                fw.connect().await.map_err(|e| e.to_string())?;

                let mut ascom_filter_wheels = self.ascom_filter_wheels.write().await;
                ascom_filter_wheels.insert(info.id.clone(), Arc::new(RwLock::new(fw)));
            }
            DeviceType::Rotator => {
                use crate::ascom_wrapper::rotator::AscomRotatorWrapper;

                disconnect_existing_ascom!(self.ascom_rotators, "rotator");

                let mut rotator = AscomRotatorWrapper::new(prog_id.to_string())?;
                rotator.connect().await?;

                let mut ascom_rotators = self.ascom_rotators.write().await;
                ascom_rotators.insert(info.id.clone(), Arc::new(RwLock::new(rotator)));
            }
            DeviceType::Dome => {
                use crate::ascom_wrapper::dome::AscomDomeWrapper;
                disconnect_existing_ascom!(self.ascom_domes, "dome");
                let mut dome = AscomDomeWrapper::new(prog_id.to_string())?;
                dome.connect().await?;

                let mut ascom_domes = self.ascom_domes.write().await;
                ascom_domes.insert(info.id.clone(), Arc::new(RwLock::new(dome)));
            }
            DeviceType::Switch => {
                use crate::ascom_wrapper::switch::AscomSwitchWrapper;
                disconnect_existing_ascom!(self.ascom_switches, "switch");
                let mut sw = AscomSwitchWrapper::new(prog_id.to_string())?;
                sw.connect().await.map_err(|e| e.to_string())?;

                let mut ascom_switches = self.ascom_switches.write().await;
                ascom_switches.insert(info.id.clone(), Arc::new(RwLock::new(sw)));
            }
            DeviceType::Weather => {
                use crate::ascom_wrapper::weather::AscomObservingConditionsWrapper;

                disconnect_existing_ascom!(self.ascom_weather, "weather");

                let mut weather = AscomObservingConditionsWrapper::new(prog_id.to_string())?;
                weather.connect().await?;

                let mut ascom_weather = self.ascom_weather.write().await;
                ascom_weather.insert(info.id.clone(), Arc::new(RwLock::new(weather)));
            }
            DeviceType::SafetyMonitor => {
                use crate::ascom_wrapper::safetymonitor::AscomSafetyMonitorWrapper;

                disconnect_existing_ascom!(self.ascom_safety_monitors, "safety monitor");

                let mut safety = AscomSafetyMonitorWrapper::new(prog_id.to_string())?;
                safety.connect().await?;

                let mut ascom_safety_monitors = self.ascom_safety_monitors.write().await;
                ascom_safety_monitors.insert(info.id.clone(), Arc::new(RwLock::new(safety)));
            }
            DeviceType::CoverCalibrator => {
                use crate::ascom_wrapper::covercalibrator::AscomCoverCalibratorWrapper;
                disconnect_existing_ascom!(self.ascom_cover_calibrators, "cover calibrator");
                let mut cover_cal = AscomCoverCalibratorWrapper::new(prog_id.to_string())?;
                cover_cal.connect().await?;

                let mut ascom_cover_cals = self.ascom_cover_calibrators.write().await;
                ascom_cover_cals.insert(info.id.clone(), Arc::new(RwLock::new(cover_cal)));
            }
            _ => {
                return Err(format!(
                    "ASCOM {} is not supported in this DeviceManager path",
                    info.device_type.as_str()
                ));
            }
        }

        Ok(())
    }

    #[cfg(not(windows))]
    pub(crate) async fn connect_ascom(&self, _info: &DeviceInfo) -> Result<(), String> {
        Err("ASCOM is only available on Windows".to_string())
    }

    /// Query API version for an ASCOM device (Windows only).
    ///
    /// The per-device-type fan-out below selects the correct typed storage
    /// map (`ascom_cameras`, `ascom_mounts`, …); the actual ASCOM-Common
    /// metadata probe (`InterfaceVersion` / `DriverVersion` / `DriverInfo` /
    /// `SupportedActions`) is centralized in
    /// [`crate::dispatch::device_common_metadata::fetch_api_version`] via the
    /// [`DeviceCommonMetadata`] trait — see that module for the silent-fallback
    /// contract and the `tracing::warn!` instrumentation
    /// that surfaces discarded `supported_actions` errors. The closure
    /// argument `DeviceApiVersion::from_ascom` is the only thing that
    /// distinguishes this from the Alpaca-side query.
    ///
    /// # Silent-fallback contract
    ///
    /// * Legacy ASCOM drivers raise `PropertyNotImplementedException`
    ///   (HRESULT `0x80040400`) for optional properties; the helper maps
    ///   `interface_version` failure to `1` (ASCOM V1 baseline) and the two
    ///   description strings to `None` (UI renders as "Unknown").
    /// * `supported_actions` is documented as ASCOM V2+ optional; the helper
    ///   defaults to an empty `Vec` and emits a `tracing::warn!` so the
    ///   discarded error is observable in logs.
    ///
    /// Device-absence (registry miss) remains a hard `Err` via the per-arm
    /// `probe_ascom_metadata` call; silent fallbacks only mask
    /// optional-property failures, never the device-not-connected signal.
    #[cfg(windows)]
    pub async fn query_ascom_api_version(
        &self,
        device_id: &str,
    ) -> Result<DeviceApiVersion, String> {
        // Get the device info
        let device_info = {
            let devices = self.devices.read().await;
            devices.get(device_id).map(|d| d.info.clone())
        };

        let info = device_info.ok_or_else(|| format!("Device not found: {}", device_id))?;

        if info.driver_type != DriverType::Ascom {
            return Err(format!("Device {} is not an ASCOM device", device_id));
        }

        // The 10-arm fan-out below differs only in (a) which typed storage map
        // we read from and (b) the human-readable role label embedded in the
        // "not connected" error message. The four-property probe body is
        // identical and lives in `fetch_api_version<T: DeviceCommonMetadata>`
        // — see `crate::dispatch::device_common_metadata`.
        let version = match info.device_type {
            DeviceType::Camera => {
                probe_ascom_metadata(&self.ascom_cameras, device_id, "camera").await?
            }
            DeviceType::Mount => {
                probe_ascom_metadata(&self.ascom_mounts, device_id, "mount").await?
            }
            DeviceType::Focuser => {
                probe_ascom_metadata(&self.ascom_focusers, device_id, "focuser").await?
            }
            DeviceType::FilterWheel => {
                probe_ascom_metadata(&self.ascom_filter_wheels, device_id, "filter wheel").await?
            }
            DeviceType::Dome => probe_ascom_metadata(&self.ascom_domes, device_id, "dome").await?,
            DeviceType::Switch => {
                probe_ascom_metadata(&self.ascom_switches, device_id, "switch").await?
            }
            DeviceType::CoverCalibrator => {
                probe_ascom_metadata(&self.ascom_cover_calibrators, device_id, "cover calibrator")
                    .await?
            }
            DeviceType::Rotator => {
                probe_ascom_metadata(&self.ascom_rotators, device_id, "rotator").await?
            }
            DeviceType::SafetyMonitor => {
                probe_ascom_metadata(&self.ascom_safety_monitors, device_id, "safety monitor")
                    .await?
            }
            DeviceType::Weather => {
                probe_ascom_metadata(&self.ascom_weather, device_id, "observing conditions").await?
            }
            _ => {
                return Err(format!(
                    "Unsupported ASCOM device type: {:?}",
                    info.device_type
                ));
            }
        };

        // Cache the version
        self.set_device_api_version(device_id, version.clone())
            .await;
        tracing::info!(
            "Queried API version for {}: interface_version={:?}, driver_version={:?}",
            device_id,
            version.interface_version,
            version.driver_version
        );

        Ok(version)
    }

    /// Perform health check for ASCOM devices (Windows only)
    #[cfg(windows)]
    pub(crate) async fn perform_ascom_health_check(
        &self,
        device_id: &str,
        device_type: &DeviceType,
    ) -> Result<bool, String> {
        match device_type {
            DeviceType::Camera => {
                let cameras = self.ascom_cameras.read().await;
                if let Some(camera) = cameras.get(device_id) {
                    match camera.read().await.heartbeat().await {
                        Ok(health) => {
                            let is_healthy = matches!(
                                health,
                                crate::ascom_wrapper::camera::CameraConnectionHealth::Healthy
                                    | crate::ascom_wrapper::camera::CameraConnectionHealth::Unknown
                            );
                            tracing::trace!("ASCOM camera {} heartbeat: {:?}", device_id, health);
                            Ok(is_healthy)
                        }
                        Err(e) => {
                            tracing::debug!("ASCOM camera {} heartbeat failed: {:?}", device_id, e);
                            Ok(false)
                        }
                    }
                } else {
                    Err(format!("ASCOM camera {} not found", device_id))
                }
            }
            DeviceType::Mount => {
                let mounts = self.ascom_mounts.read().await;
                if let Some(mount) = mounts.get(device_id) {
                    // Send a lightweight COM command through the worker thread to verify
                    // the mount is actually responding, not just reading an AtomicBool flag
                    let mount_guard = mount.read().await;
                    match mount_guard.get_tracking().await {
                        Ok(_) => {
                            tracing::trace!("ASCOM mount {} heartbeat: healthy", device_id,);
                            Ok(true)
                        }
                        Err(e) => {
                            tracing::debug!("ASCOM mount {} heartbeat failed: {:?}", device_id, e);
                            Ok(false)
                        }
                    }
                } else {
                    Err(format!("ASCOM mount {} not found", device_id))
                }
            }
            DeviceType::Focuser => {
                // Single probe; the retry for transient focuser/wheel failures
                // lives in the perform_health_check wrapper (driver parity).
                let focusers = self.ascom_focusers.read().await;
                if let Some(focuser) = focusers.get(device_id) {
                    match focuser.read().await.heartbeat().await {
                        Ok(()) => {
                            tracing::trace!("ASCOM focuser {} heartbeat: healthy", device_id);
                            Ok(true)
                        }
                        Err(e) => {
                            tracing::debug!(
                                "ASCOM focuser {} heartbeat failed: {:?}",
                                device_id,
                                e
                            );
                            Ok(false)
                        }
                    }
                } else {
                    Err(format!("ASCOM focuser {} not found", device_id))
                }
            }
            DeviceType::FilterWheel => {
                let filter_wheels = self.ascom_filter_wheels.read().await;
                if let Some(fw) = filter_wheels.get(device_id) {
                    match fw.read().await.heartbeat().await {
                        Ok(()) => {
                            tracing::trace!("ASCOM filter wheel {} heartbeat: healthy", device_id);
                            Ok(true)
                        }
                        Err(e) => {
                            tracing::debug!(
                                "ASCOM filter wheel {} heartbeat failed: {:?}",
                                device_id,
                                e
                            );
                            Ok(false)
                        }
                    }
                } else {
                    Err(format!("ASCOM filter wheel {} not found", device_id))
                }
            }
            DeviceType::Dome => {
                let domes = self.ascom_domes.read().await;
                if let Some(dome) = domes.get(device_id) {
                    match dome.read().await.heartbeat().await {
                        Ok(()) => {
                            tracing::trace!("ASCOM dome {} heartbeat: healthy", device_id);
                            Ok(true)
                        }
                        Err(e) => {
                            tracing::debug!("ASCOM dome {} heartbeat failed: {:?}", device_id, e);
                            Ok(false)
                        }
                    }
                } else {
                    Err(format!("ASCOM dome {} not found", device_id))
                }
            }
            DeviceType::SafetyMonitor => {
                let safety_monitors = self.ascom_safety_monitors.read().await;
                if let Some(safety) = safety_monitors.get(device_id) {
                    // IsSafe is a mandatory ISafetyMonitor property; reading it is a
                    // live COM round-trip that both confirms the driver is responding
                    // and exercises the actual safety-reporting path. Without this arm
                    // the heartbeat always failed ("No ASCOM heartbeat implementation"),
                    // which is what drove the JustAHub safety-monitor error flood.
                    match safety.read().await.is_safe().await {
                        Ok(_) => {
                            tracing::trace!(
                                "ASCOM safety monitor {} heartbeat: healthy",
                                device_id
                            );
                            Ok(true)
                        }
                        Err(e) => {
                            tracing::debug!(
                                "ASCOM safety monitor {} heartbeat failed: {:?}",
                                device_id,
                                e
                            );
                            Ok(false)
                        }
                    }
                } else {
                    Err(format!("ASCOM safety monitor {} not found", device_id))
                }
            }
            DeviceType::Rotator => {
                let rotators = self.ascom_rotators.read().await;
                if let Some(rotator) = rotators.get(device_id) {
                    // Position is a mandatory IRotatorV3 property.
                    match rotator.read().await.position().await {
                        Ok(_) => {
                            tracing::trace!("ASCOM rotator {} heartbeat: healthy", device_id);
                            Ok(true)
                        }
                        Err(e) => {
                            tracing::debug!(
                                "ASCOM rotator {} heartbeat failed: {:?}",
                                device_id,
                                e
                            );
                            Ok(false)
                        }
                    }
                } else {
                    Err(format!("ASCOM rotator {} not found", device_id))
                }
            }
            DeviceType::CoverCalibrator => {
                let cover_cals = self.ascom_cover_calibrators.read().await;
                if let Some(cover_cal) = cover_cals.get(device_id) {
                    // CoverState is a mandatory ICoverCalibratorV1 property (it returns
                    // NotPresent rather than throwing when no cover is fitted).
                    match cover_cal.read().await.cover_state().await {
                        Ok(_) => {
                            tracing::trace!(
                                "ASCOM cover calibrator {} heartbeat: healthy",
                                device_id
                            );
                            Ok(true)
                        }
                        Err(e) => {
                            tracing::debug!(
                                "ASCOM cover calibrator {} heartbeat failed: {:?}",
                                device_id,
                                e
                            );
                            Ok(false)
                        }
                    }
                } else {
                    Err(format!("ASCOM cover calibrator {} not found", device_id))
                }
            }
            DeviceType::Weather => {
                let weather = self.ascom_weather.read().await;
                if let Some(w) = weather.get(device_id) {
                    // Every ObservingConditions sensor is optional and may throw
                    // PropertyNotImplemented, so probe InterfaceVersion — a mandatory
                    // IAscomDriver member — for a live COM round-trip that never
                    // depends on an unimplemented sensor.
                    match w.read().await.interface_version().await {
                        Ok(_) => {
                            tracing::trace!("ASCOM weather {} heartbeat: healthy", device_id);
                            Ok(true)
                        }
                        Err(e) => {
                            tracing::debug!(
                                "ASCOM weather {} heartbeat failed: {:?}",
                                device_id,
                                e
                            );
                            Ok(false)
                        }
                    }
                } else {
                    Err(format!("ASCOM weather {} not found", device_id))
                }
            }
            DeviceType::Switch => {
                let switches = self.ascom_switches.read().await;
                if let Some(sw) = switches.get(device_id) {
                    // No mandatory scalar count is exposed on the wrapper, so probe
                    // InterfaceVersion — a mandatory IAscomDriver member — for liveness.
                    match sw.read().await.interface_version().await {
                        Ok(_) => {
                            tracing::trace!("ASCOM switch {} heartbeat: healthy", device_id);
                            Ok(true)
                        }
                        Err(e) => {
                            tracing::debug!("ASCOM switch {} heartbeat failed: {:?}", device_id, e);
                            Ok(false)
                        }
                    }
                } else {
                    Err(format!("ASCOM switch {} not found", device_id))
                }
            }
            _ => Err(format!(
                "No ASCOM heartbeat implementation for device {} ({:?})",
                device_id, device_type
            )),
        }
    }
}
