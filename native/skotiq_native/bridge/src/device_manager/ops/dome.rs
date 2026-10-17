//! Dome operations dispatcher.
//!
//! Methods in this module are an additional impl block on `DeviceManager`
//! using Rust's split-impl-block feature. Behavior is identical to the
//! previous monolithic `devices.rs`.
//!
//! # `unwrap_or` policy
//!
//! Every `unwrap_or(false)` in this file probes an INDI / ASCOM optional
//! switch (`DOME_SHUTTER/SHUTTER_OPEN`, `DOME_AUTOSYNC/ENABLE`, …). The
//! ASCOM-Alpaca and INDI specifications both treat undeclared switches as
//! "feature not exposed"; treating the absence as `false` is the documented
//! cross-driver mapping used by the equipment-compatibility matrix UI.
//! Hard connection failures (driver not found, device disconnected) still
//! return `Err(String)` from the outer dispatch helper.

use crate::device::*;
use crate::device_manager::DeviceManager;
use crate::dispatch::DeviceOpError;
#[cfg(windows)]
use tracing::warn;

impl DeviceManager {
    // Dome control

    /// Open dome shutter
    pub async fn dome_open_shutter(&self, device_id: &str) -> Result<(), DeviceOpError> {
        let driver_type = {
            let devices = self.devices.read().await;
            devices.get(device_id).map(|d| d.info.driver_type.clone())
        };

        match driver_type {
            Some(DriverType::Alpaca) => {
                let domes = self.alpaca_domes.read().await;
                if let Some(dome) = domes.get(device_id) {
                    return dome.open_shutter().await.map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca dome {} not found", device_id),
                ))
            }
            Some(DriverType::Ascom) => {
                #[cfg(windows)]
                {
                    let domes = self.ascom_domes.read().await;
                    if let Some(dome) = domes.get(device_id) {
                        let dome_guard = dome.read().await;
                        return dome_guard.open_shutter().await.map_err(|e| {
                            DeviceOpError::hardware(
                                Some(device_id.to_string()),
                                format!(
                                    "Failed to open ASCOM dome shutter on {}: {}",
                                    device_id, e
                                ),
                            )
                        });
                    }
                    Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        format!("ASCOM dome {} not found", device_id),
                    ))
                }
                #[cfg(not(windows))]
                Err(DeviceOpError::unsupported(
                    "ASCOM not supported on this platform",
                ))
            }
            Some(DriverType::Indi) => {
                let (host, port, device_name) = Self::parse_indi_device_id(device_id)
                    .map_err(DeviceOpError::invalid_device_id)?;
                let server_key = format!("{host}:{port}");

                let clients = self.indi_clients.read().await;
                if let Some(client) = clients.get(&server_key) {
                    let mut locked = client.write().await;
                    return locked
                        .set_switch(&device_name, "DOME_SHUTTER", "SHUTTER_OPEN", true)
                        .await
                        .map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "INDI dome not connected",
                ))
            }
            Some(DriverType::Native) => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                "Native dome not connected",
            )),
            Some(DriverType::Simulator) => {
                let mut dome = crate::api::devices::simulation::get_sim_dome()
                    .write()
                    .await;
                if !dome.status.connected {
                    return Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        "Simulator dome not connected",
                    ));
                }
                dome.status.shutter_status = ShutterState::Open;
                dome.status.at_park = false;
                Ok(())
            }
            None => Err(DeviceOpError::device_not_found(device_id)),
        }
    }

    /// Close dome shutter
    pub async fn dome_close_shutter(&self, device_id: &str) -> Result<(), DeviceOpError> {
        let driver_type = {
            let devices = self.devices.read().await;
            devices.get(device_id).map(|d| d.info.driver_type.clone())
        };

        match driver_type {
            Some(DriverType::Alpaca) => {
                let domes = self.alpaca_domes.read().await;
                if let Some(dome) = domes.get(device_id) {
                    return dome.close_shutter().await.map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca dome {} not found", device_id),
                ))
            }
            Some(DriverType::Ascom) => {
                #[cfg(windows)]
                {
                    let domes = self.ascom_domes.read().await;
                    if let Some(dome) = domes.get(device_id) {
                        let dome_guard = dome.read().await;
                        return dome_guard.close_shutter().await.map_err(|e| {
                            DeviceOpError::hardware(
                                Some(device_id.to_string()),
                                format!(
                                    "Failed to close ASCOM dome shutter on {}: {}",
                                    device_id, e
                                ),
                            )
                        });
                    }
                    Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        format!("ASCOM dome {} not found", device_id),
                    ))
                }
                #[cfg(not(windows))]
                Err(DeviceOpError::unsupported(
                    "ASCOM not supported on this platform",
                ))
            }
            Some(DriverType::Indi) => {
                let (host, port, device_name) = Self::parse_indi_device_id(device_id)
                    .map_err(DeviceOpError::invalid_device_id)?;
                let server_key = format!("{host}:{port}");

                let clients = self.indi_clients.read().await;
                if let Some(client) = clients.get(&server_key) {
                    let mut locked = client.write().await;
                    return locked
                        .set_switch(&device_name, "DOME_SHUTTER", "SHUTTER_CLOSE", true)
                        .await
                        .map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "INDI dome not connected",
                ))
            }
            Some(DriverType::Native) => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                "Native dome not connected",
            )),
            Some(DriverType::Simulator) => {
                let mut dome = crate::api::devices::simulation::get_sim_dome()
                    .write()
                    .await;
                if !dome.status.connected {
                    return Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        "Simulator dome not connected",
                    ));
                }
                dome.status.shutter_status = ShutterState::Closed;
                Ok(())
            }
            None => Err(DeviceOpError::device_not_found(device_id)),
        }
    }

    /// Slew dome to azimuth
    pub async fn dome_slew_to_azimuth(
        &self,
        device_id: &str,
        azimuth: f64,
    ) -> Result<(), DeviceOpError> {
        let driver_type = {
            let devices = self.devices.read().await;
            devices.get(device_id).map(|d| d.info.driver_type.clone())
        };

        match driver_type {
            Some(DriverType::Alpaca) => {
                let domes = self.alpaca_domes.read().await;
                if let Some(dome) = domes.get(device_id) {
                    return dome
                        .slew_to_azimuth(azimuth)
                        .await
                        .map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca dome {} not found", device_id),
                ))
            }
            Some(DriverType::Indi) => {
                let (host, port, device_name) = Self::parse_indi_device_id(device_id)
                    .map_err(DeviceOpError::invalid_device_id)?;
                let server_key = format!("{host}:{port}");

                let clients = self.indi_clients.read().await;
                if let Some(client) = clients.get(&server_key) {
                    let mut locked = client.write().await;
                    // INDI domes reject ABS_DOME_POSITION moves while parked, and
                    // Skotiq exposes no standalone unpark route — domes commonly
                    // boot parked, so without this a parked INDI dome could never be
                    // slewed. A slew request implies "move the dome", so unpark first
                    // when parked. UNPARK failures are non-fatal (driver may not gate
                    // moves on park state); the subsequent set_number is the source of
                    // truth for whether the slew succeeded.
                    let parked = locked
                        .get_switch(&device_name, "DOME_PARK", "PARK")
                        .await
                        .unwrap_or(false);
                    if parked {
                        let _ = locked
                            .set_switch(&device_name, "DOME_PARK", "UNPARK", true)
                            .await;
                        tokio::time::sleep(std::time::Duration::from_millis(500)).await;
                    }
                    return locked
                        .set_number(
                            &device_name,
                            "ABS_DOME_POSITION",
                            "DOME_ABSOLUTE_POSITION",
                            azimuth,
                        )
                        .await
                        .map_err(|e| {
                            DeviceOpError::hardware(
                                Some(device_id.to_string()),
                                format!(
                                    "Failed to slew INDI dome {} to azimuth {:.2}: {}",
                                    device_name, azimuth, e
                                ),
                            )
                        });
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "INDI dome not connected",
                ))
            }
            Some(DriverType::Ascom) => {
                #[cfg(windows)]
                {
                    let domes = self.ascom_domes.read().await;
                    if let Some(dome) = domes.get(device_id) {
                        let dome_guard = dome.read().await;
                        return dome_guard
                            .slew_to_azimuth(azimuth)
                            .await
                            .map_err(DeviceOpError::driver);
                    }
                    Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        format!("ASCOM dome {} not found", device_id),
                    ))
                }
                #[cfg(not(windows))]
                Err(DeviceOpError::unsupported(
                    "ASCOM not supported on this platform",
                ))
            }
            Some(DriverType::Native) => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                "Native dome not connected",
            )),
            Some(DriverType::Simulator) => {
                if !azimuth.is_finite() || !(0.0..360.0).contains(&azimuth) {
                    return Err(DeviceOpError::invalid_parameter(
                        "Dome azimuth must be finite and in [0, 360)",
                    ));
                }
                let mut dome = crate::api::devices::simulation::get_sim_dome()
                    .write()
                    .await;
                if !dome.status.connected {
                    return Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        "Simulator dome not connected",
                    ));
                }
                dome.status.azimuth = azimuth;
                dome.status.at_home = azimuth == 0.0;
                dome.status.at_park = false;
                Ok(())
            }
            None => Err(DeviceOpError::device_not_found(device_id)),
        }
    }

    /// Get dome azimuth
    pub async fn dome_get_azimuth(&self, device_id: &str) -> Result<f64, DeviceOpError> {
        let driver_type = {
            let devices = self.devices.read().await;
            devices.get(device_id).map(|d| d.info.driver_type.clone())
        };

        match driver_type {
            Some(DriverType::Alpaca) => {
                let domes = self.alpaca_domes.read().await;
                if let Some(dome) = domes.get(device_id) {
                    return dome.azimuth().await.map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca dome {} not found", device_id),
                ))
            }
            Some(DriverType::Indi) => {
                let (host, port, device_name) = Self::parse_indi_device_id(device_id)
                    .map_err(DeviceOpError::invalid_device_id)?;
                let server_key = format!("{host}:{port}");

                let clients = self.indi_clients.read().await;
                if let Some(client) = clients.get(&server_key) {
                    let locked = client.read().await;
                    if let Some(az) = locked
                        .get_number(&device_name, "ABS_DOME_POSITION", "DOME_ABSOLUTE_POSITION")
                        .await
                    {
                        return Ok(az);
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "INDI dome not connected",
                ))
            }
            Some(DriverType::Ascom) => {
                #[cfg(windows)]
                {
                    let domes = self.ascom_domes.read().await;
                    if let Some(dome) = domes.get(device_id) {
                        let dome_guard = dome.read().await;
                        return dome_guard.azimuth().await.map_err(DeviceOpError::driver);
                    }
                    Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        format!("ASCOM dome {} not found", device_id),
                    ))
                }
                #[cfg(not(windows))]
                Err(DeviceOpError::unsupported(
                    "ASCOM not supported on this platform",
                ))
            }
            Some(DriverType::Native) => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                "Native dome not connected",
            )),
            Some(DriverType::Simulator) => {
                let dome = crate::api::devices::simulation::get_sim_dome().read().await;
                if !dome.status.connected {
                    return Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        "Simulator dome not connected",
                    ));
                }
                Ok(dome.status.azimuth)
            }
            None => Err(DeviceOpError::device_not_found(device_id)),
        }
    }

    /// Get dome shutter status
    pub async fn dome_get_shutter_status(&self, device_id: &str) -> Result<i32, DeviceOpError> {
        let driver_type = {
            let devices = self.devices.read().await;
            devices.get(device_id).map(|d| d.info.driver_type.clone())
        };

        match driver_type {
            Some(DriverType::Alpaca) => {
                let domes = self.alpaca_domes.read().await;
                if let Some(dome) = domes.get(device_id) {
                    let status = dome.shutter_status().await?;
                    // Why: `ShutterState` is a C-like
                    // ASCOM enum with values {0..4} (Open, Closed, Opening,
                    // Closing, Error); `as i32` extracts the discriminant.
                    return Ok(status as i32);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca dome {} not found", device_id),
                ))
            }
            Some(DriverType::Ascom) => {
                #[cfg(windows)]
                {
                    let domes = self.ascom_domes.read().await;
                    if let Some(dome) = domes.get(device_id) {
                        let dome_guard = dome.read().await;
                        return dome_guard
                            .shutter_status()
                            .await
                            .map_err(DeviceOpError::driver);
                    }
                    Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        format!("ASCOM dome {} not found", device_id),
                    ))
                }
                #[cfg(not(windows))]
                Err(DeviceOpError::unsupported(
                    "ASCOM not supported on this platform",
                ))
            }
            Some(DriverType::Indi) => {
                let (host, port, device_name) = Self::parse_indi_device_id(device_id)
                    .map_err(DeviceOpError::invalid_device_id)?;
                let server_key = format!("{host}:{port}");

                let clients = self.indi_clients.read().await;
                if let Some(client) = clients.get(&server_key) {
                    let locked = client.read().await;
                    let shutter_open = locked
                        .get_switch(&device_name, "DOME_SHUTTER", "SHUTTER_OPEN")
                        .await;
                    let shutter_close = locked
                        .get_switch(&device_name, "DOME_SHUTTER", "SHUTTER_CLOSE")
                        .await;
                    let shutter_busy = locked.is_property_busy(&device_name, "DOME_SHUTTER").await;

                    return Ok(match (shutter_open, shutter_close, shutter_busy) {
                        (Some(true), Some(false), true) => 2,  // Opening
                        (Some(false), Some(true), true) => 3,  // Closing
                        (Some(true), Some(false), false) => 0, // Open
                        (Some(false), Some(true), false) => 1, // Closed
                        _ => 4,                                // Unknown/Error
                    });
                }
                Ok(4) // Unknown/Error
            }
            Some(DriverType::Native) => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                "Native dome not connected",
            )),
            Some(DriverType::Simulator) => {
                let dome = crate::api::devices::simulation::get_sim_dome().read().await;
                if !dome.status.connected {
                    return Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        "Simulator dome not connected",
                    ));
                }
                Ok(match dome.status.shutter_status {
                    ShutterState::Open => 0,
                    ShutterState::Closed => 1,
                    ShutterState::Opening => 2,
                    ShutterState::Closing => 3,
                    ShutterState::Error => 4,
                    ShutterState::Unknown => 5,
                })
            }
            None => Err(DeviceOpError::device_not_found(device_id)),
        }
    }

    /// Park dome
    pub async fn dome_park(&self, device_id: &str) -> Result<(), DeviceOpError> {
        let driver_type = {
            let devices = self.devices.read().await;
            devices.get(device_id).map(|d| d.info.driver_type.clone())
        };

        match driver_type {
            Some(DriverType::Alpaca) => {
                let domes = self.alpaca_domes.read().await;
                if let Some(dome) = domes.get(device_id) {
                    return dome.park().await.map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca dome {} not found", device_id),
                ))
            }
            Some(DriverType::Ascom) => {
                #[cfg(windows)]
                {
                    let domes = self.ascom_domes.read().await;
                    if let Some(dome) = domes.get(device_id) {
                        let dome_guard = dome.read().await;
                        return dome_guard.park().await.map_err(DeviceOpError::driver);
                    }
                    Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        format!("ASCOM dome {} not found", device_id),
                    ))
                }
                #[cfg(not(windows))]
                Err(DeviceOpError::unsupported(
                    "ASCOM not supported on this platform",
                ))
            }
            Some(DriverType::Indi) => {
                let (host, port, device_name) = Self::parse_indi_device_id(device_id)
                    .map_err(DeviceOpError::invalid_device_id)?;
                let server_key = format!("{host}:{port}");

                let clients = self.indi_clients.read().await;
                if let Some(client) = clients.get(&server_key) {
                    let mut locked = client.write().await;
                    return locked
                        .set_switch(&device_name, "DOME_PARK", "PARK", true)
                        .await
                        .map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "INDI dome not connected",
                ))
            }
            Some(DriverType::Native) => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                "Native dome not connected",
            )),
            Some(DriverType::Simulator) => {
                let mut dome = crate::api::devices::simulation::get_sim_dome()
                    .write()
                    .await;
                if !dome.status.connected {
                    return Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        "Simulator dome not connected",
                    ));
                }
                dome.status.azimuth = 0.0;
                dome.status.at_home = true;
                dome.status.at_park = true;
                Ok(())
            }
            None => Err(DeviceOpError::device_not_found(device_id)),
        }
    }

    /// Check if dome is slewing
    pub async fn dome_is_slewing(&self, device_id: &str) -> Result<bool, DeviceOpError> {
        let driver_type = {
            let devices = self.devices.read().await;
            devices.get(device_id).map(|d| d.info.driver_type.clone())
        };

        match driver_type {
            Some(DriverType::Alpaca) => {
                let domes = self.alpaca_domes.read().await;
                if let Some(dome) = domes.get(device_id) {
                    return dome.slewing().await.map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca dome {} not found", device_id),
                ))
            }
            Some(DriverType::Ascom) => {
                #[cfg(windows)]
                {
                    let domes = self.ascom_domes.read().await;
                    if let Some(dome) = domes.get(device_id) {
                        let dome_guard = dome.read().await;
                        return dome_guard.slewing().await.map_err(DeviceOpError::driver);
                    }
                    Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        format!("ASCOM dome {} not found", device_id),
                    ))
                }
                #[cfg(not(windows))]
                Err(DeviceOpError::unsupported(
                    "ASCOM not supported on this platform",
                ))
            }
            Some(DriverType::Indi) => {
                let (host, port, device_name) = Self::parse_indi_device_id(device_id)
                    .map_err(DeviceOpError::invalid_device_id)?;
                let server_key = format!("{host}:{port}");

                let clients = self.indi_clients.read().await;
                if let Some(client) = clients.get(&server_key) {
                    let locked = client.read().await;
                    let az_busy = locked
                        .is_property_busy(&device_name, "ABS_DOME_POSITION")
                        .await;
                    let shutter_busy = locked.is_property_busy(&device_name, "DOME_SHUTTER").await;
                    return Ok(az_busy || shutter_busy);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "INDI dome not connected",
                ))
            }
            Some(DriverType::Native) => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                "Native dome not connected",
            )),
            Some(DriverType::Simulator) => {
                let dome = crate::api::devices::simulation::get_sim_dome().read().await;
                if !dome.status.connected {
                    return Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        "Simulator dome not connected",
                    ));
                }
                Ok(dome.status.slewing)
            }
            None => Err(DeviceOpError::device_not_found(device_id)),
        }
    }

    /// Get comprehensive dome status
    pub async fn dome_get_status(
        &self,
        device_id: &str,
    ) -> Result<crate::device::DomeStatus, DeviceOpError> {
        let driver_type = {
            let devices = self.devices.read().await;
            devices.get(device_id).map(|d| d.info.driver_type.clone())
        };

        match driver_type {
            Some(DriverType::Alpaca) => {
                let domes = self.alpaca_domes.read().await;
                if let Some(dome) = domes.get(device_id) {
                    // Get status from Alpaca dome
                    let alpaca_status = dome.get_status().await?;

                    // Query capabilities
                    let can_set_altitude = dome.can_set_altitude().await.map_err(|e| {
                        DeviceOpError::hardware(
                            Some(device_id.to_string()),
                            format!(
                                "Failed to query Alpaca dome can_set_altitude for {}: {}",
                                device_id, e
                            ),
                        )
                    })?;
                    let can_set_azimuth = dome.can_set_azimuth().await.map_err(|e| {
                        DeviceOpError::hardware(
                            Some(device_id.to_string()),
                            format!(
                                "Failed to query Alpaca dome can_set_azimuth for {}: {}",
                                device_id, e
                            ),
                        )
                    })?;
                    let can_set_shutter = dome.can_set_shutter().await.map_err(|e| {
                        DeviceOpError::hardware(
                            Some(device_id.to_string()),
                            format!(
                                "Failed to query Alpaca dome can_set_shutter for {}: {}",
                                device_id, e
                            ),
                        )
                    })?;
                    let can_slave = dome.can_slave().await.map_err(|e| {
                        DeviceOpError::hardware(
                            Some(device_id.to_string()),
                            format!(
                                "Failed to query Alpaca dome can_slave for {}: {}",
                                device_id, e
                            ),
                        )
                    })?;

                    return Ok(crate::device::DomeStatus {
                        connected: true,
                        azimuth: alpaca_status.azimuth,
                        altitude: alpaca_status.altitude,
                        shutter_status: match alpaca_status.shutter_status {
                            skotiq_alpaca::ShutterStatus::Open => crate::device::ShutterState::Open,
                            skotiq_alpaca::ShutterStatus::Closed => {
                                crate::device::ShutterState::Closed
                            }
                            skotiq_alpaca::ShutterStatus::Opening => {
                                crate::device::ShutterState::Opening
                            }
                            skotiq_alpaca::ShutterStatus::Closing => {
                                crate::device::ShutterState::Closing
                            }
                            skotiq_alpaca::ShutterStatus::Error => {
                                crate::device::ShutterState::Error
                            }
                        },
                        slewing: alpaca_status.slewing,
                        at_home: alpaca_status.at_home,
                        at_park: alpaca_status.at_park,
                        can_set_altitude,
                        can_set_azimuth,
                        can_set_shutter,
                        can_slave,
                        is_slaved: alpaca_status.slaved,
                    });
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca dome {} not found", device_id),
                ))
            }
            Some(DriverType::Ascom) => {
                #[cfg(windows)]
                {
                    let domes = self.ascom_domes.read().await;
                    if let Some(dome) = domes.get(device_id) {
                        let dome_guard = dome.read().await;

                        // Query all dome properties from ASCOM driver
                        let shutter_status_code = match dome_guard.shutter_status().await {
                            Ok(s) => s,
                            Err(e) => {
                                warn!("Failed to read ASCOM dome shutter_status for {}: {}. Using error code 4.", device_id, e);
                                4 // Error state
                            }
                        };
                        let slewing = dome_guard.slewing().await.map_err(|e| {
                            DeviceOpError::hardware(
                                Some(device_id.to_string()),
                                format!(
                                    "Failed to read ASCOM dome slewing for {}: {}",
                                    device_id, e
                                ),
                            )
                        })?;
                        let at_park = dome_guard.at_park().await.map_err(|e| {
                            DeviceOpError::hardware(
                                Some(device_id.to_string()),
                                format!(
                                    "Failed to read ASCOM dome at_park for {}: {}",
                                    device_id, e
                                ),
                            )
                        })?;

                        // Map ASCOM shutter status codes to ShutterState
                        let shutter_status = match shutter_status_code {
                            0 => crate::device::ShutterState::Open,
                            1 => crate::device::ShutterState::Closed,
                            2 => crate::device::ShutterState::Opening,
                            3 => crate::device::ShutterState::Closing,
                            4 => crate::device::ShutterState::Error,
                            _ => crate::device::ShutterState::Unknown,
                        };

                        return Ok(crate::device::DomeStatus {
                            connected: true,
                            azimuth: 0.0,   // ASCOM domes don't always expose azimuth
                            altitude: None, // ASCOM domes typically don't have altitude
                            shutter_status,
                            slewing,
                            at_home: false, // ASCOM dome interface doesn't have at_home
                            at_park,
                            can_set_altitude: false,
                            can_set_azimuth: false, // Could query CanSetAzimuth if needed
                            can_set_shutter: true,  // All ASCOM domes have shutter control
                            can_slave: false,
                            is_slaved: false,
                        });
                    }
                    Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        format!("ASCOM dome {} not found", device_id),
                    ))
                }
                #[cfg(not(windows))]
                Err(DeviceOpError::unsupported(
                    "ASCOM not supported on this platform",
                ))
            }
            Some(DriverType::Indi) => {
                let (host, port, device_name) = Self::parse_indi_device_id(device_id)?;
                let server_key = format!("{}:{}", host, port);

                let clients = self.indi_clients.read().await;
                if let Some(client) = clients.get(&server_key) {
                    let locked = client.read().await;

                    let azimuth = locked
                        .get_number(&device_name, "ABS_DOME_POSITION", "DOME_ABSOLUTE_POSITION")
                        .await
                        .ok_or_else(|| {
                            DeviceOpError::hardware(
                                Some(device_id.to_string()),
                                format!("Failed to read INDI dome azimuth for {}", device_id),
                            )
                        })?;
                    let can_set_azimuth = true;

                    let shutter_open = locked
                        .get_switch(&device_name, "DOME_SHUTTER", "SHUTTER_OPEN")
                        .await;
                    let shutter_close = locked
                        .get_switch(&device_name, "DOME_SHUTTER", "SHUTTER_CLOSE")
                        .await;
                    let shutter_busy = locked.is_property_busy(&device_name, "DOME_SHUTTER").await;

                    let shutter_status = match (shutter_open, shutter_close, shutter_busy) {
                        (Some(true), Some(false), true) => crate::device::ShutterState::Opening,
                        (Some(false), Some(true), true) => crate::device::ShutterState::Closing,
                        (Some(true), Some(false), false) => crate::device::ShutterState::Open,
                        (Some(false), Some(true), false) => crate::device::ShutterState::Closed,
                        _ => crate::device::ShutterState::Unknown,
                    };

                    let azimuth_busy = locked
                        .is_property_busy(&device_name, "ABS_DOME_POSITION")
                        .await;
                    let slewing = azimuth_busy || shutter_busy;

                    let at_home = locked
                        .get_switch(&device_name, "DOME_GOTO", "DOME_HOME")
                        .await
                        .unwrap_or(false);
                    let at_park = locked
                        .get_switch(&device_name, "DOME_PARK", "PARK")
                        .await
                        .unwrap_or(false)
                        || locked
                            .get_switch(&device_name, "DOME_GOTO", "DOME_PARK")
                            .await
                            .unwrap_or(false);

                    let can_set_shutter = shutter_open.is_some() || shutter_close.is_some();

                    let autosync_enable = locked
                        .get_switch(&device_name, "DOME_AUTOSYNC", "DOME_AUTOSYNC_ENABLE")
                        .await;
                    let autosync_disable = locked
                        .get_switch(&device_name, "DOME_AUTOSYNC", "DOME_AUTOSYNC_DISABLE")
                        .await;
                    let can_slave = autosync_enable.is_some() || autosync_disable.is_some();
                    let is_slaved = autosync_enable.unwrap_or(false);

                    return Ok(crate::device::DomeStatus {
                        connected: true,
                        azimuth,
                        altitude: None,
                        shutter_status,
                        slewing,
                        at_home,
                        at_park,
                        can_set_altitude: false,
                        can_set_azimuth,
                        can_set_shutter,
                        can_slave,
                        is_slaved,
                    });
                }

                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "INDI dome not connected",
                ))
            }
            Some(DriverType::Native) => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                "Native dome not connected",
            )),
            Some(DriverType::Simulator) => {
                let dome = crate::api::devices::simulation::get_sim_dome().read().await;
                if !dome.status.connected {
                    return Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        "Simulator dome not connected",
                    ));
                }
                Ok(dome.status.clone())
            }
            None => Err(DeviceOpError::device_not_found(device_id)),
        }
    }

    /// Enable or disable dome slaving to the mount
    pub async fn dome_set_slaved(
        &self,
        device_id: &str,
        slaved: bool,
    ) -> Result<(), DeviceOpError> {
        let driver_type = {
            let devices = self.devices.read().await;
            devices.get(device_id).map(|d| d.info.driver_type.clone())
        };

        match driver_type {
            Some(DriverType::Alpaca) => {
                let domes = self.alpaca_domes.read().await;
                if let Some(dome) = domes.get(device_id) {
                    return dome.set_slaved(slaved).await.map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca dome {} not found", device_id),
                ))
            }
            Some(DriverType::Ascom) => {
                #[cfg(windows)]
                {
                    let domes = self.ascom_domes.read().await;
                    if let Some(dome) = domes.get(device_id) {
                        let dome_guard = dome.read().await;
                        return dome_guard
                            .set_slaved(slaved)
                            .await
                            .map_err(DeviceOpError::driver);
                    }
                    Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        format!("ASCOM dome {} not found", device_id),
                    ))
                }
                #[cfg(not(windows))]
                Err(DeviceOpError::unsupported(
                    "ASCOM not supported on this platform",
                ))
            }
            Some(DriverType::Indi) => {
                let (host, port, device_name) = Self::parse_indi_device_id(device_id)
                    .map_err(DeviceOpError::invalid_device_id)?;
                let server_key = format!("{host}:{port}");

                let clients = self.indi_clients.read().await;
                if let Some(client) = clients.get(&server_key) {
                    let mut locked = client.write().await;
                    if slaved {
                        return locked
                            .set_switch(&device_name, "DOME_AUTOSYNC", "DOME_AUTOSYNC_ENABLE", true)
                            .await
                            .map_err(DeviceOpError::driver);
                    }
                    return locked
                        .set_switch(&device_name, "DOME_AUTOSYNC", "DOME_AUTOSYNC_DISABLE", true)
                        .await
                        .map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "INDI dome not connected",
                ))
            }
            Some(DriverType::Native) => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                "Native dome not connected",
            )),
            Some(DriverType::Simulator) => {
                let mut dome = crate::api::devices::simulation::get_sim_dome()
                    .write()
                    .await;
                if !dome.status.connected {
                    return Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        "Simulator dome not connected",
                    ));
                }
                dome.status.is_slaved = slaved;
                Ok(())
            }
            None => Err(DeviceOpError::device_not_found(device_id)),
        }
    }

    /// Send dome to home position
    pub async fn dome_find_home(&self, device_id: &str) -> Result<(), DeviceOpError> {
        let driver_type = {
            let devices = self.devices.read().await;
            devices.get(device_id).map(|d| d.info.driver_type.clone())
        };

        match driver_type {
            Some(DriverType::Alpaca) => {
                let domes = self.alpaca_domes.read().await;
                if let Some(dome) = domes.get(device_id) {
                    return dome.find_home().await.map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca dome {} not found", device_id),
                ))
            }
            Some(DriverType::Ascom) => {
                #[cfg(windows)]
                {
                    let domes = self.ascom_domes.read().await;
                    if let Some(dome) = domes.get(device_id) {
                        let dome_guard = dome.read().await;
                        return dome_guard.find_home().await.map_err(DeviceOpError::driver);
                    }
                    Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        format!("ASCOM dome {} not found", device_id),
                    ))
                }
                #[cfg(not(windows))]
                Err(DeviceOpError::unsupported(
                    "ASCOM not supported on this platform",
                ))
            }
            Some(DriverType::Indi) => {
                let (host, port, device_name) = Self::parse_indi_device_id(device_id)
                    .map_err(DeviceOpError::invalid_device_id)?;
                let server_key = format!("{host}:{port}");

                let clients = self.indi_clients.read().await;
                if let Some(client) = clients.get(&server_key) {
                    let mut locked = client.write().await;
                    return locked
                        .set_switch(&device_name, "DOME_GOTO", "DOME_HOME", true)
                        .await
                        .map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "INDI dome not connected",
                ))
            }
            Some(DriverType::Native) => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                "Native dome not connected",
            )),
            Some(DriverType::Simulator) => {
                let mut dome = crate::api::devices::simulation::get_sim_dome()
                    .write()
                    .await;
                if !dome.status.connected {
                    return Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        "Simulator dome not connected",
                    ));
                }
                dome.status.azimuth = 0.0;
                dome.status.at_home = true;
                dome.status.at_park = false;
                Ok(())
            }
            None => Err(DeviceOpError::device_not_found(device_id)),
        }
    }

    /// Abort dome slew / shutter motion
    pub async fn dome_abort_slew(&self, device_id: &str) -> Result<(), DeviceOpError> {
        let driver_type = {
            let devices = self.devices.read().await;
            devices.get(device_id).map(|d| d.info.driver_type.clone())
        };

        match driver_type {
            Some(DriverType::Alpaca) => {
                let domes = self.alpaca_domes.read().await;
                if let Some(dome) = domes.get(device_id) {
                    return dome.abort_slew().await.map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca dome {} not found", device_id),
                ))
            }
            Some(DriverType::Ascom) => {
                #[cfg(windows)]
                {
                    let domes = self.ascom_domes.read().await;
                    if let Some(dome) = domes.get(device_id) {
                        let dome_guard = dome.read().await;
                        return dome_guard.abort_slew().await.map_err(DeviceOpError::driver);
                    }
                    Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        format!("ASCOM dome {} not found", device_id),
                    ))
                }
                #[cfg(not(windows))]
                Err(DeviceOpError::unsupported(
                    "ASCOM not supported on this platform",
                ))
            }
            Some(DriverType::Indi) => {
                let (host, port, device_name) = Self::parse_indi_device_id(device_id)
                    .map_err(DeviceOpError::invalid_device_id)?;
                let server_key = format!("{host}:{port}");

                let clients = self.indi_clients.read().await;
                if let Some(client) = clients.get(&server_key) {
                    let mut locked = client.write().await;
                    return locked
                        .set_switch(&device_name, "DOME_ABORT_MOTION", "ABORT", true)
                        .await
                        .map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "INDI dome not connected",
                ))
            }
            Some(DriverType::Native) => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                "Native dome not connected",
            )),
            Some(DriverType::Simulator) => {
                let mut dome = crate::api::devices::simulation::get_sim_dome()
                    .write()
                    .await;
                if !dome.status.connected {
                    return Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        "Simulator dome not connected",
                    ));
                }
                dome.status.slewing = false;
                dome.status.shutter_status = match dome.status.shutter_status {
                    ShutterState::Opening => ShutterState::Closed,
                    ShutterState::Closing => ShutterState::Open,
                    state => state,
                };
                Ok(())
            }
            None => Err(DeviceOpError::device_not_found(device_id)),
        }
    }
}
