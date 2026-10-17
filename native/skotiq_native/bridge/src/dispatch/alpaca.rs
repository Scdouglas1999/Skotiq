//! Alpaca (HTTP) driver dispatch helpers.
//!
//! Methods in this module are additional impl blocks on `DeviceManager` and
//! provide Alpaca-only logic for `connect_*`, `query_*_api_version`, and
//! `perform_*_health_check`. They are invoked from the dispatcher methods in
//! `crate::device_manager`. No behavior or signature has changed relative to the
//! previous monolithic `devices.rs`.

use crate::device::*;
use crate::device_manager::DeviceManager;
use crate::dispatch::device_common_metadata::fetch_api_version;
use std::sync::Arc;

impl DeviceManager {
    /// Connect to an Alpaca device
    pub(crate) async fn connect_alpaca(&self, info: &DeviceInfo) -> Result<(), String> {
        use crate::device_id::{parse_device_id_cached, ConnectionInfo};
        use skotiq_alpaca::*;

        let parsed = parse_device_id_cached(&info.id)
            .map_err(|e| format!("Invalid Alpaca device ID '{}': {}", info.id, e))?;

        let (base_url, device_number) = match parsed.connection_info {
            ConnectionInfo::Alpaca {
                base_url,
                device_num,
                ..
            } => (base_url, device_num),
            _ => {
                return Err(format!(
                    "Device ID '{}' is not an Alpaca device (got {:?})",
                    info.id, parsed.driver_type
                ));
            }
        };

        match info.device_type {
            DeviceType::Camera => {
                let camera = AlpacaCamera::from_server(&base_url, device_number);
                camera.connect().await?;
                // Store for later use
                let mut alpaca_cameras = self.alpaca_cameras.write().await;
                alpaca_cameras.insert(info.id.clone(), Arc::new(camera));
            }
            DeviceType::Mount => {
                let telescope = AlpacaTelescope::from_server(&base_url, device_number);
                telescope.connect().await?;
                // Store for later use
                let mut alpaca_mounts = self.alpaca_mounts.write().await;
                alpaca_mounts.insert(info.id.clone(), Arc::new(telescope));
            }
            DeviceType::Focuser => {
                let focuser = AlpacaFocuser::from_server(&base_url, device_number);
                focuser.connect().await?;
                // Store for later use
                let mut alpaca_focusers = self.alpaca_focusers.write().await;
                alpaca_focusers.insert(info.id.clone(), Arc::new(focuser));
            }
            DeviceType::FilterWheel => {
                let fw = AlpacaFilterWheel::from_server(&base_url, device_number);
                fw.connect().await?;
                // Store for later use
                let mut alpaca_filter_wheels = self.alpaca_filter_wheels.write().await;
                alpaca_filter_wheels.insert(info.id.clone(), Arc::new(fw));
            }
            DeviceType::Rotator => {
                let rotator = AlpacaRotator::from_server(&base_url, device_number);
                rotator.connect().await?;
                // Store for later use
                let mut alpaca_rotators = self.alpaca_rotators.write().await;
                alpaca_rotators.insert(info.id.clone(), Arc::new(rotator));
            }
            DeviceType::Dome => {
                let dome = AlpacaDome::from_server(&base_url, device_number);
                dome.connect().await?;
                // Store for later use
                let mut alpaca_domes = self.alpaca_domes.write().await;
                alpaca_domes.insert(info.id.clone(), Arc::new(dome));
            }
            DeviceType::Weather => {
                let weather = AlpacaObservingConditions::from_server(&base_url, device_number);
                weather.connect().await?;
                // Store for later use
                let mut alpaca_weather = self.alpaca_weather.write().await;
                alpaca_weather.insert(info.id.clone(), Arc::new(weather));
            }
            DeviceType::SafetyMonitor => {
                let safety = AlpacaSafetyMonitor::from_server(&base_url, device_number);
                safety.connect().await?;
                // Store for later use
                let mut alpaca_safety = self.alpaca_safety_monitors.write().await;
                alpaca_safety.insert(info.id.clone(), Arc::new(safety));
            }
            DeviceType::Switch => {
                let switch = AlpacaSwitch::from_server(&base_url, device_number);
                switch.connect().await?;
                // Store for later use
                let mut alpaca_switches = self.alpaca_switches.write().await;
                alpaca_switches.insert(info.id.clone(), Arc::new(switch));
            }
            DeviceType::CoverCalibrator => {
                let cover_cal = AlpacaCoverCalibrator::from_server(&base_url, device_number);
                cover_cal.connect().await?;
                // Store for later use
                let mut alpaca_cover_cals = self.alpaca_cover_calibrators.write().await;
                alpaca_cover_cals.insert(info.id.clone(), Arc::new(cover_cal));
            }
            _ => {
                return Err(format!(
                    "Alpaca {} is not supported in this DeviceManager path",
                    info.device_type.as_str()
                ));
            }
        }

        Ok(())
    }

    /// Query and cache API version for an Alpaca device.
    ///
    /// The per-device-type fan-out below selects the correct typed storage
    /// map (`alpaca_cameras`, `alpaca_mounts`, …); the actual ASCOM-Common
    /// metadata probe (`interface_version` / `driver_version` / `driver_info`
    /// / `supported_actions`) is centralized in
    /// [`crate::dispatch::device_common_metadata::fetch_api_version`] via the
    /// [`DeviceCommonMetadata`] trait — see that module for the silent-fallback
    /// contract and the `tracing::warn!` instrumentation
    /// that surfaces discarded `supported_actions` errors. The closure
    /// argument `DeviceApiVersion::from_alpaca` is the only thing that
    /// distinguishes this from the ASCOM-side query.
    ///
    /// [`DeviceCommonMetadata`]: crate::dispatch::device_common_metadata::DeviceCommonMetadata
    ///
    /// Connection failure (the device not being in the appropriate registry)
    /// is still a hard `Err` via the `None => return Err(...)` arms below —
    /// the trait helper only masks *optional-property* failures inside an
    /// otherwise-connected device, not device-absence.
    pub async fn query_alpaca_api_version(
        &self,
        device_id: &str,
    ) -> Result<DeviceApiVersion, String> {
        // Get the device info
        let device_info = {
            let devices = self.devices.read().await;
            devices.get(device_id).map(|d| d.info.clone())
        };

        let info = device_info.ok_or_else(|| format!("Device not found: {}", device_id))?;

        if info.driver_type != DriverType::Alpaca {
            return Err(format!("Device {} is not an Alpaca device", device_id));
        }

        // Query version info based on device type.
        //
        // The 10-arm fan-out below differs only in which typed storage map
        // we read from (`alpaca_cameras`, `alpaca_mounts`, …); the actual
        // ASCOM-Common probe body is identical across all arms and lives
        // in `fetch_api_version<T: AlpacaDeviceCommon>` — see
        // `crate::dispatch::alpaca_device_common`. Each arm holds the read
        // lock only long enough to clone an `Arc` so the probe RPCs run
        // without blocking writers.
        let version = match info.device_type {
            DeviceType::Camera => {
                let device = {
                    let map = self.alpaca_cameras.read().await;
                    map.get(device_id).cloned()
                };
                match device {
                    Some(d) => {
                        fetch_api_version(d.as_ref(), device_id, DeviceApiVersion::from_alpaca)
                            .await
                    }
                    None => return Err(format!("Alpaca camera {} not connected", device_id)),
                }
            }
            DeviceType::Mount => {
                let device = {
                    let map = self.alpaca_mounts.read().await;
                    map.get(device_id).cloned()
                };
                match device {
                    Some(d) => {
                        fetch_api_version(d.as_ref(), device_id, DeviceApiVersion::from_alpaca)
                            .await
                    }
                    None => return Err(format!("Alpaca mount {} not connected", device_id)),
                }
            }
            DeviceType::Focuser => {
                let device = {
                    let map = self.alpaca_focusers.read().await;
                    map.get(device_id).cloned()
                };
                match device {
                    Some(d) => {
                        fetch_api_version(d.as_ref(), device_id, DeviceApiVersion::from_alpaca)
                            .await
                    }
                    None => return Err(format!("Alpaca focuser {} not connected", device_id)),
                }
            }
            DeviceType::FilterWheel => {
                let device = {
                    let map = self.alpaca_filter_wheels.read().await;
                    map.get(device_id).cloned()
                };
                match device {
                    Some(d) => {
                        fetch_api_version(d.as_ref(), device_id, DeviceApiVersion::from_alpaca)
                            .await
                    }
                    None => return Err(format!("Alpaca filter wheel {} not connected", device_id)),
                }
            }
            DeviceType::Rotator => {
                let device = {
                    let map = self.alpaca_rotators.read().await;
                    map.get(device_id).cloned()
                };
                match device {
                    Some(d) => {
                        fetch_api_version(d.as_ref(), device_id, DeviceApiVersion::from_alpaca)
                            .await
                    }
                    None => return Err(format!("Alpaca rotator {} not connected", device_id)),
                }
            }
            DeviceType::Dome => {
                let device = {
                    let map = self.alpaca_domes.read().await;
                    map.get(device_id).cloned()
                };
                match device {
                    Some(d) => {
                        fetch_api_version(d.as_ref(), device_id, DeviceApiVersion::from_alpaca)
                            .await
                    }
                    None => return Err(format!("Alpaca dome {} not connected", device_id)),
                }
            }
            DeviceType::SafetyMonitor => {
                let device = {
                    let map = self.alpaca_safety_monitors.read().await;
                    map.get(device_id).cloned()
                };
                match device {
                    Some(d) => {
                        fetch_api_version(d.as_ref(), device_id, DeviceApiVersion::from_alpaca)
                            .await
                    }
                    None => {
                        return Err(format!("Alpaca safety monitor {} not connected", device_id))
                    }
                }
            }
            DeviceType::Switch => {
                let device = {
                    let map = self.alpaca_switches.read().await;
                    map.get(device_id).cloned()
                };
                match device {
                    Some(d) => {
                        fetch_api_version(d.as_ref(), device_id, DeviceApiVersion::from_alpaca)
                            .await
                    }
                    None => return Err(format!("Alpaca switch {} not connected", device_id)),
                }
            }
            DeviceType::CoverCalibrator => {
                let device = {
                    let map = self.alpaca_cover_calibrators.read().await;
                    map.get(device_id).cloned()
                };
                match device {
                    Some(d) => {
                        fetch_api_version(d.as_ref(), device_id, DeviceApiVersion::from_alpaca)
                            .await
                    }
                    None => {
                        return Err(format!(
                            "Alpaca cover calibrator {} not connected",
                            device_id
                        ))
                    }
                }
            }
            DeviceType::Weather => {
                let device = {
                    let map = self.alpaca_weather.read().await;
                    map.get(device_id).cloned()
                };
                match device {
                    Some(d) => {
                        fetch_api_version(d.as_ref(), device_id, DeviceApiVersion::from_alpaca)
                            .await
                    }
                    None => {
                        return Err(format!(
                            "Alpaca observing conditions {} not connected",
                            device_id
                        ))
                    }
                }
            }
            _ => {
                return Err(format!(
                    "Unsupported Alpaca device type: {:?}",
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

    /// Perform health check for Alpaca devices.
    pub(crate) async fn perform_alpaca_health_check(
        &self,
        device_id: &str,
        device_type: &DeviceType,
    ) -> Result<bool, String> {
        match device_type {
            DeviceType::Camera => {
                let cameras = self.alpaca_cameras.read().await;
                if let Some(camera) = cameras.get(device_id) {
                    match camera.heartbeat().await {
                        Ok(rtt_ms) => {
                            tracing::trace!(
                                "Alpaca camera {} heartbeat: {}ms RTT",
                                device_id,
                                rtt_ms
                            );
                            Ok(true)
                        }
                        Err(e) => {
                            tracing::debug!("Alpaca camera {} heartbeat failed: {}", device_id, e);
                            Ok(false)
                        }
                    }
                } else {
                    Err(format!("Alpaca camera {} not found", device_id))
                }
            }
            DeviceType::Mount => {
                let mounts = self.alpaca_mounts.read().await;
                if let Some(mount) = mounts.get(device_id) {
                    match mount.heartbeat().await {
                        Ok(rtt_ms) => {
                            tracing::trace!(
                                "Alpaca mount {} heartbeat: {}ms RTT",
                                device_id,
                                rtt_ms
                            );
                            Ok(true)
                        }
                        Err(e) => {
                            tracing::debug!("Alpaca mount {} heartbeat failed: {}", device_id, e);
                            Ok(false)
                        }
                    }
                } else {
                    Err(format!("Alpaca mount {} not found", device_id))
                }
            }
            DeviceType::Focuser => {
                let focusers = self.alpaca_focusers.read().await;
                if let Some(focuser) = focusers.get(device_id) {
                    match focuser.heartbeat().await {
                        Ok(rtt_ms) => {
                            tracing::trace!(
                                "Alpaca focuser {} heartbeat: {}ms RTT",
                                device_id,
                                rtt_ms
                            );
                            Ok(true)
                        }
                        Err(e) => {
                            tracing::debug!("Alpaca focuser {} heartbeat failed: {}", device_id, e);
                            Ok(false)
                        }
                    }
                } else {
                    Err(format!("Alpaca focuser {} not found", device_id))
                }
            }
            DeviceType::FilterWheel => {
                let filter_wheels = self.alpaca_filter_wheels.read().await;
                if let Some(fw) = filter_wheels.get(device_id) {
                    match fw.heartbeat().await {
                        Ok(rtt_ms) => {
                            tracing::trace!(
                                "Alpaca filter wheel {} heartbeat: {}ms RTT",
                                device_id,
                                rtt_ms
                            );
                            Ok(true)
                        }
                        Err(e) => {
                            tracing::debug!(
                                "Alpaca filter wheel {} heartbeat failed: {}",
                                device_id,
                                e
                            );
                            Ok(false)
                        }
                    }
                } else {
                    Err(format!("Alpaca filter wheel {} not found", device_id))
                }
            }
            DeviceType::Rotator => {
                let rotators = self.alpaca_rotators.read().await;
                if let Some(rotator) = rotators.get(device_id) {
                    match rotator.heartbeat().await {
                        Ok(rtt_ms) => {
                            tracing::trace!(
                                "Alpaca rotator {} heartbeat: {}ms RTT",
                                device_id,
                                rtt_ms
                            );
                            Ok(true)
                        }
                        Err(e) => {
                            tracing::debug!("Alpaca rotator {} heartbeat failed: {}", device_id, e);
                            Ok(false)
                        }
                    }
                } else {
                    Err(format!("Alpaca rotator {} not found", device_id))
                }
            }
            DeviceType::SafetyMonitor => {
                let safety_monitors = self.alpaca_safety_monitors.read().await;
                if let Some(sm) = safety_monitors.get(device_id) {
                    match sm.heartbeat().await {
                        Ok(rtt_ms) => {
                            tracing::trace!(
                                "Alpaca safety monitor {} heartbeat: {}ms RTT",
                                device_id,
                                rtt_ms
                            );
                            Ok(true)
                        }
                        Err(e) => {
                            tracing::debug!(
                                "Alpaca safety monitor {} heartbeat failed: {}",
                                device_id,
                                e
                            );
                            Ok(false)
                        }
                    }
                } else {
                    Err(format!("Alpaca safety monitor {} not found", device_id))
                }
            }
            DeviceType::Dome => {
                let domes = self.alpaca_domes.read().await;
                if let Some(dome) = domes.get(device_id) {
                    match dome.is_connected().await {
                        Ok(connected) => {
                            tracing::trace!(
                                "Alpaca dome {} heartbeat: connected={}",
                                device_id,
                                connected
                            );
                            Ok(connected)
                        }
                        Err(e) => {
                            tracing::debug!("Alpaca dome {} heartbeat failed: {}", device_id, e);
                            Ok(false)
                        }
                    }
                } else {
                    Err(format!("Alpaca dome {} not found", device_id))
                }
            }
            DeviceType::Weather => {
                let weather = self.alpaca_weather.read().await;
                if let Some(dev) = weather.get(device_id) {
                    match dev.is_connected().await {
                        Ok(connected) => {
                            tracing::trace!(
                                "Alpaca weather {} heartbeat: connected={}",
                                device_id,
                                connected
                            );
                            Ok(connected)
                        }
                        Err(e) => {
                            tracing::debug!("Alpaca weather {} heartbeat failed: {}", device_id, e);
                            Ok(false)
                        }
                    }
                } else {
                    Err(format!("Alpaca weather {} not found", device_id))
                }
            }
            DeviceType::Switch => {
                let switches = self.alpaca_switches.read().await;
                if let Some(sw) = switches.get(device_id) {
                    match sw.is_connected().await {
                        Ok(connected) => {
                            tracing::trace!(
                                "Alpaca switch {} heartbeat: connected={}",
                                device_id,
                                connected
                            );
                            Ok(connected)
                        }
                        Err(e) => {
                            tracing::debug!("Alpaca switch {} heartbeat failed: {}", device_id, e);
                            Ok(false)
                        }
                    }
                } else {
                    Err(format!("Alpaca switch {} not found", device_id))
                }
            }
            DeviceType::CoverCalibrator => {
                let cover_cals = self.alpaca_cover_calibrators.read().await;
                if let Some(cc) = cover_cals.get(device_id) {
                    match cc.is_connected().await {
                        Ok(connected) => {
                            tracing::trace!(
                                "Alpaca cover calibrator {} heartbeat: connected={}",
                                device_id,
                                connected
                            );
                            Ok(connected)
                        }
                        Err(e) => {
                            tracing::debug!(
                                "Alpaca cover calibrator {} heartbeat failed: {}",
                                device_id,
                                e
                            );
                            Ok(false)
                        }
                    }
                } else {
                    Err(format!("Alpaca cover calibrator {} not found", device_id))
                }
            }
            _ => Err(format!(
                "No Alpaca heartbeat implementation for device {} ({:?})",
                device_id, device_type
            )),
        }
    }
}
