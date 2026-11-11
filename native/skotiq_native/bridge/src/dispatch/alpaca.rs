//! Alpaca (HTTP) driver dispatch helpers.
//!
//! Methods in this module are additional impl blocks on `DeviceManager` and
//! provide Alpaca-only logic for `connect_*` and `perform_*_health_check`. They are invoked from the dispatcher methods in
//! `crate::device_manager`. No behavior or signature has changed relative to the
//! previous monolithic `devices.rs`.

use crate::device::*;
use crate::device_manager::handle::DeviceHandle;
use crate::device_manager::DeviceManager;
use crate::dispatch::error::DeviceOpError;
use std::sync::Arc;

/// Alpaca errors propagated with `?` keep the text the wrappers used to hand
/// over as a `String`, in the same uncategorized variant.
impl From<skotiq_alpaca::AlpacaError> for DeviceOpError {
    fn from(e: skotiq_alpaca::AlpacaError) -> Self {
        DeviceOpError::Message(e.to_string())
    }
}

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
                let mut alpaca_cameras = self.alpaca_cameras.write().await;
                alpaca_cameras.insert(info.id.clone(), Arc::new(camera));
            }
            DeviceType::Mount => {
                let telescope = AlpacaTelescope::from_server(&base_url, device_number);
                telescope.connect().await?;
                let mut alpaca_mounts = self.alpaca_mounts.write().await;
                alpaca_mounts.insert(info.id.clone(), Arc::new(telescope));
            }
            DeviceType::Focuser => {
                let focuser = AlpacaFocuser::from_server(&base_url, device_number);
                focuser.connect().await?;
                let mut alpaca_focusers = self.alpaca_focusers.write().await;
                alpaca_focusers.insert(info.id.clone(), Arc::new(focuser));
            }
            DeviceType::FilterWheel => {
                let fw = AlpacaFilterWheel::from_server(&base_url, device_number);
                fw.connect().await?;
                let mut alpaca_filter_wheels = self.alpaca_filter_wheels.write().await;
                alpaca_filter_wheels.insert(info.id.clone(), Arc::new(fw));
            }
            DeviceType::Rotator => {
                let rotator = AlpacaRotator::from_server(&base_url, device_number);
                rotator.connect().await?;
                self.handles
                    .insert(&info.id, DeviceHandle::Rotator(Arc::new(rotator)));
            }
            DeviceType::Dome => {
                let dome = AlpacaDome::from_server(&base_url, device_number);
                dome.connect().await?;
                self.handles
                    .insert(&info.id, DeviceHandle::Dome(Arc::new(dome)));
            }
            DeviceType::Weather => {
                let weather = AlpacaObservingConditions::from_server(&base_url, device_number);
                weather.connect().await?;
                self.handles
                    .insert(&info.id, DeviceHandle::Weather(Arc::new(weather)));
            }
            DeviceType::SafetyMonitor => {
                let safety = AlpacaSafetyMonitor::from_server(&base_url, device_number);
                safety.connect().await?;
                self.handles
                    .insert(&info.id, DeviceHandle::SafetyMonitor(Arc::new(safety)));
            }
            DeviceType::Switch => {
                let switch = AlpacaSwitch::from_server(&base_url, device_number);
                switch.connect().await?;
                self.handles
                    .insert(&info.id, DeviceHandle::Switch(Arc::new(switch)));
            }
            DeviceType::CoverCalibrator => {
                let cover_cal = AlpacaCoverCalibrator::from_server(&base_url, device_number);
                cover_cal.connect().await?;
                self.handles
                    .insert(&info.id, DeviceHandle::CoverCalibrator(Arc::new(cover_cal)));
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
            _ => Err(format!(
                "No Alpaca heartbeat implementation for device {} ({:?})",
                device_id, device_type
            )),
        }
    }
}
