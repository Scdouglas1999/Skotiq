//! Focuser operations dispatcher.
//!
//! Methods in this module are an additional impl block on `DeviceManager`
//! using Rust's split-impl-block feature. Behavior is identical to the
//! previous monolithic `devices.rs`.

use crate::device::*;
use crate::device_manager::DeviceManager;
use crate::dispatch::DeviceOpError;
use crate::error::NightshadeError;
use crate::timeout_ops::{focuser_move_with_timeout, with_timeout_str, Timeouts};
use tracing::warn;
// Windows: trait must be in scope so ASCOM wrapper guards resolve its methods.
#[cfg(windows)]
use nightshade_native::traits::NativeFocuser;

impl DeviceManager {
    // Focuser control

    pub async fn focuser_move_abs(
        &self,
        device_id: &str,
        position: i32,
    ) -> Result<(), DeviceOpError> {
        let devices = self.devices.read().await;
        let info = devices
            .get(device_id)
            .map(|d| d.info.clone())
            .ok_or_else(|| DeviceOpError::device_not_found(device_id))?;
        drop(devices);

        // Suppress this focuser's heartbeat while the move runs. The ASCOM move
        // holds the focuser write lock (and the single STA COM thread) for the
        // whole move, so a heartbeat status read issued mid-move blocks or is
        // rejected by the driver and gets miscounted as a failure — the cause
        // of focuser disconnects during autofocus. The guard clears the marker
        // when this function returns (success, error, or panic).
        let _op = self.begin_operation(device_id);

        match info.driver_type {
            DriverType::Ascom => {
                #[cfg(windows)]
                {
                    let focusers = self.ascom_focusers.read().await;
                    if let Some(focuser) = focusers.get(device_id) {
                        let mut focuser = focuser.write().await;
                        return focuser_move_with_timeout(
                            async {
                                focuser
                                    .move_to(position)
                                    .await
                                    .map_err(|e| NightshadeError::OperationFailed(e.to_string()))
                            },
                            device_id,
                            position,
                            None,
                            1,
                        )
                        .await
                        .map_err(|e| {
                            DeviceOpError::hardware(
                                Some(device_id.to_string()),
                                format!(
                                    "Failed to move ASCOM focuser {} to position {}: {}",
                                    device_id, position, e
                                ),
                            )
                        });
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "ASCOM focuser not connected",
                ))
            }
            DriverType::Native => {
                let mut native_focusers = self.native_focusers.write().await;
                if let Some(focuser) = native_focusers.get_mut(device_id) {
                    return focuser_move_with_timeout(
                        async {
                            focuser
                                .move_to(position)
                                .await
                                .map_err(|e| NightshadeError::OperationFailed(e.to_string()))
                        },
                        device_id,
                        position,
                        None,
                        1,
                    )
                    .await
                    .map_err(|e| {
                        DeviceOpError::hardware(
                            Some(device_id.to_string()),
                            format!(
                                "Failed to move native focuser {} to position {}: {}",
                                device_id, position, e
                            ),
                        )
                    });
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "Native focuser not connected",
                ))
            }
            DriverType::Alpaca => {
                let alpaca_focusers = self.alpaca_focusers.read().await;
                if let Some(focuser) = alpaca_focusers.get(device_id) {
                    return focuser_move_with_timeout(
                        async {
                            focuser
                                .move_to_typed(position)
                                .await
                                .map_err(|e| NightshadeError::OperationFailed(e.to_string()))
                        },
                        device_id,
                        position,
                        None,
                        1,
                    )
                    .await
                    .map_err(|e| {
                        DeviceOpError::hardware(
                            Some(device_id.to_string()),
                            format!(
                                "Failed to move Alpaca focuser {} to position {}: {}",
                                device_id, position, e
                            ),
                        )
                    });
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "Alpaca focuser not connected",
                ))
            }
            DriverType::Indi => {
                // Parse INDI device ID: indi:host:port:device_name
                if let Ok((host, port, device_name)) = Self::parse_indi_device_id(device_id) {
                    let server_key = format!("{host}:{port}");

                    let clients = self.indi_clients.read().await;
                    if let Some(client) = clients.get(&server_key) {
                        let focuser =
                            nightshade_indi::IndiFocuser::new(client.clone(), &device_name);
                        return focuser_move_with_timeout(
                            async {
                                focuser
                                    .move_to(position)
                                    .await
                                    .map_err(|e| NightshadeError::OperationFailed(e.to_string()))
                            },
                            device_id,
                            position,
                            None,
                            1,
                        )
                        .await
                        .map_err(|e| {
                            DeviceOpError::hardware(
                                Some(device_id.to_string()),
                                format!(
                                    "Failed to move INDI focuser {} to position {}: {}",
                                    device_name, position, e
                                ),
                            )
                        });
                    }
                    return Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        format!("INDI client not connected for {}", server_key),
                    ));
                }
                Err(DeviceOpError::invalid_device_id(
                    "Invalid INDI device ID format",
                ))
            }
            DriverType::Simulator => {
                use crate::device_manager::ops::sim_faults;
                sim_faults::check("focuser.move")
                    .await
                    .map_err(|e| DeviceOpError::driver(e))?;
                let f = crate::api::devices::simulation::get_sim_focuser();
                let mut f = f.write().await;
                if !f.status.connected {
                    return Err(DeviceOpError::not_connected(
                        None,
                        crate::device_manager::ops::sim_gate::not_connected_focuser(),
                    ));
                }
                // Backlash: the mechanism lands short of the commanded position
                // when reversing direction. An autofocus routine that trusts
                // the commanded position instead of re-reading the reached one
                // fits its V-curve against positions the focuser was never at,
                // which is why the curve minimum can be real and the resulting
                // focus still wrong.
                let reached = match sim_faults::backlash_steps("focuser.move") {
                    Some(backlash) if backlash != 0 => {
                        let reversing = position < f.status.position;
                        if reversing {
                            position + backlash
                        } else {
                            position - backlash
                        }
                    }
                    _ => position,
                };
                // A stalled focuser accepts the move and stays put.
                if sim_faults::is_stalled("focuser.move") {
                    return Ok(());
                }
                if let Some(replay) = crate::sim_replay::armed() {
                    replay.note_focuser_move(f.status.position, reached);
                }
                f.status.position = reached;
                Ok(())
            }
        }
    }

    pub async fn focuser_move_rel(&self, device_id: &str, steps: i32) -> Result<(), DeviceOpError> {
        let devices = self.devices.read().await;
        let info = devices
            .get(device_id)
            .map(|d| d.info.clone())
            .ok_or_else(|| DeviceOpError::device_not_found(device_id))?;
        drop(devices);

        // See focuser_move_abs: suppress the heartbeat for the move's duration
        // so a status read contended with the move is not miscounted as a
        // heartbeat failure.
        let _op = self.begin_operation(device_id);

        match info.driver_type {
            DriverType::Ascom => {
                #[cfg(windows)]
                {
                    let focusers = self.ascom_focusers.read().await;
                    if let Some(focuser) = focusers.get(device_id) {
                        let mut focuser = focuser.write().await;
                        return with_timeout_str(
                            async {
                                focuser
                                    .move_relative(steps)
                                    .await
                                    .map_err(|e| e.to_string())
                            },
                            Timeouts::focuser_move(),
                            device_id,
                            "move_relative",
                        )
                        .await
                        .map_err(DeviceOpError::driver);
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "ASCOM focuser not connected",
                ))
            }
            DriverType::Native => {
                let mut native_focusers = self.native_focusers.write().await;
                if let Some(focuser) = native_focusers.get_mut(device_id) {
                    return with_timeout_str(
                        async {
                            focuser
                                .move_relative(steps)
                                .await
                                .map_err(|e| e.to_string())
                        },
                        Timeouts::focuser_move(),
                        device_id,
                        "move_relative",
                    )
                    .await
                    .map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "Native focuser not connected",
                ))
            }
            DriverType::Alpaca => {
                // Alpaca focusers only support absolute positioning, so we compute target position
                let alpaca_focusers = self.alpaca_focusers.read().await;
                if let Some(focuser) = alpaca_focusers.get(device_id) {
                    let current_position = focuser.position().await?;
                    let target_position = current_position + steps;
                    return focuser_move_with_timeout(
                        async {
                            focuser
                                .move_to_typed(target_position)
                                .await
                                .map_err(|e| NightshadeError::OperationFailed(e.to_string()))
                        },
                        device_id,
                        target_position,
                        Some(current_position),
                        1,
                    )
                    .await
                    .map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "Alpaca focuser not connected",
                ))
            }
            DriverType::Indi => {
                // Parse INDI device ID: indi:host:port:device_name
                if let Ok((host, port, device_name)) = Self::parse_indi_device_id(device_id) {
                    let server_key = format!("{host}:{port}");

                    let clients = self.indi_clients.read().await;
                    if let Some(client) = clients.get(&server_key) {
                        let focuser =
                            nightshade_indi::IndiFocuser::new(client.clone(), &device_name);
                        return with_timeout_str(
                            async {
                                focuser
                                    .move_relative(steps)
                                    .await
                                    .map_err(|e| e.to_string())
                            },
                            Timeouts::focuser_move(),
                            device_id,
                            "move_relative",
                        )
                        .await
                        .map_err(DeviceOpError::driver);
                    }
                    return Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        format!("INDI client not connected for {}", server_key),
                    ));
                }
                Err(DeviceOpError::invalid_device_id(
                    "Invalid INDI device ID format",
                ))
            }
            DriverType::Simulator => {
                let f = crate::api::devices::simulation::get_sim_focuser();
                let mut f = f.write().await;
                if !f.status.connected {
                    return Err(DeviceOpError::not_connected(
                        None,
                        crate::device_manager::ops::sim_gate::not_connected_focuser(),
                    ));
                }
                f.status.position += steps;
                Ok(())
            }
        }
    }

    pub async fn focuser_halt(&self, device_id: &str) -> Result<(), DeviceOpError> {
        let devices = self.devices.read().await;
        let info = devices
            .get(device_id)
            .map(|d| d.info.clone())
            .ok_or_else(|| DeviceOpError::device_not_found(device_id))?;
        drop(devices);

        match info.driver_type {
            DriverType::Ascom => {
                #[cfg(windows)]
                {
                    let focusers = self.ascom_focusers.read().await;
                    if let Some(focuser) = focusers.get(device_id) {
                        let mut focuser = focuser.write().await;
                        return focuser.halt().await.map_err(DeviceOpError::driver);
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "ASCOM focuser not connected",
                ))
            }
            DriverType::Native => {
                let mut native_focusers = self.native_focusers.write().await;
                if let Some(focuser) = native_focusers.get_mut(device_id) {
                    return focuser.halt().await.map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "Native focuser not connected",
                ))
            }
            DriverType::Alpaca => {
                let alpaca_focusers = self.alpaca_focusers.read().await;
                if let Some(focuser) = alpaca_focusers.get(device_id) {
                    return focuser.halt().await.map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "Alpaca focuser not connected",
                ))
            }
            DriverType::Indi => {
                // Parse INDI device ID: indi:host:port:device_name
                if let Ok((host, port, device_name)) = Self::parse_indi_device_id(device_id) {
                    let server_key = format!("{host}:{port}");

                    let clients = self.indi_clients.read().await;
                    if let Some(client) = clients.get(&server_key) {
                        let focuser =
                            nightshade_indi::IndiFocuser::new(client.clone(), &device_name);
                        return focuser.abort_motion().await.map_err(DeviceOpError::driver);
                    }
                    return Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        format!("INDI client not connected for {}", server_key),
                    ));
                }
                Err(DeviceOpError::invalid_device_id(
                    "Invalid INDI device ID format",
                ))
            }
            DriverType::Simulator => {
                let f = crate::api::devices::simulation::get_sim_focuser();
                let mut f = f.write().await;
                if !f.status.connected {
                    return Err(DeviceOpError::not_connected(
                        None,
                        crate::device_manager::ops::sim_gate::not_connected_focuser(),
                    ));
                }
                f.status.moving = false;
                Ok(())
            }
        }
    }

    pub async fn focuser_get_position(&self, device_id: &str) -> Result<i32, DeviceOpError> {
        let devices = self.devices.read().await;
        let info = devices
            .get(device_id)
            .map(|d| d.info.clone())
            .ok_or_else(|| DeviceOpError::device_not_found(device_id))?;

        match info.driver_type {
            DriverType::Ascom => {
                #[cfg(windows)]
                {
                    let focusers = self.ascom_focusers.read().await;
                    if let Some(focuser) = focusers.get(device_id) {
                        let focuser = focuser.read().await;
                        return focuser.get_position().await.map_err(DeviceOpError::driver);
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "ASCOM focuser not connected",
                ))
            }
            DriverType::Native => {
                let native_focusers = self.native_focusers.read().await;
                if let Some(focuser) = native_focusers.get(device_id) {
                    return focuser.get_position().await.map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "Native focuser not connected",
                ))
            }
            DriverType::Alpaca => {
                let alpaca_focusers = self.alpaca_focusers.read().await;
                if let Some(focuser) = alpaca_focusers.get(device_id) {
                    return focuser.position().await.map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "Alpaca focuser not connected",
                ))
            }
            DriverType::Indi => {
                // Parse INDI device ID: indi:host:port:device_name
                if let Ok((host, port, device_name)) = Self::parse_indi_device_id(device_id) {
                    let server_key = format!("{host}:{port}");

                    let clients = self.indi_clients.read().await;
                    if let Some(client) = clients.get(&server_key) {
                        let focuser =
                            nightshade_indi::IndiFocuser::new(client.clone(), &device_name);
                        return focuser.get_position().await.map_err(DeviceOpError::driver);
                    }
                    return Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        format!("INDI client not connected for {}", server_key),
                    ));
                }
                Err(DeviceOpError::invalid_device_id(
                    "Invalid INDI device ID format",
                ))
            }
            DriverType::Simulator => {
                let sim = crate::device_manager::ops::sim_gate::read_focuser_status().await?;
                Ok(sim.position)
            }
        }
    }

    pub async fn focuser_is_moving(&self, device_id: &str) -> Result<bool, DeviceOpError> {
        let devices = self.devices.read().await;
        let info = devices
            .get(device_id)
            .map(|d| d.info.clone())
            .ok_or_else(|| DeviceOpError::device_not_found(device_id))?;

        match info.driver_type {
            DriverType::Ascom => {
                #[cfg(windows)]
                {
                    let focusers = self.ascom_focusers.read().await;
                    if let Some(focuser) = focusers.get(device_id) {
                        let focuser = focuser.read().await;
                        return focuser.is_moving().await.map_err(DeviceOpError::driver);
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "ASCOM focuser not connected",
                ))
            }
            DriverType::Native => {
                let native_focusers = self.native_focusers.read().await;
                if let Some(focuser) = native_focusers.get(device_id) {
                    return focuser.is_moving().await.map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "Native focuser not connected",
                ))
            }
            DriverType::Alpaca => {
                let alpaca_focusers = self.alpaca_focusers.read().await;
                if let Some(focuser) = alpaca_focusers.get(device_id) {
                    return focuser.is_moving().await.map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "Alpaca focuser not connected",
                ))
            }
            DriverType::Indi => {
                // Parse INDI device ID: indi:host:port:device_name
                if let Ok((host, port, device_name)) = Self::parse_indi_device_id(device_id) {
                    let server_key = format!("{host}:{port}");

                    let clients = self.indi_clients.read().await;
                    if let Some(client) = clients.get(&server_key) {
                        let focuser =
                            nightshade_indi::IndiFocuser::new(client.clone(), &device_name);
                        return Ok(focuser.is_moving().await);
                    }
                    return Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        format!("INDI client not connected for {}", server_key),
                    ));
                }
                Err(DeviceOpError::invalid_device_id(
                    "Invalid INDI device ID format",
                ))
            }
            DriverType::Simulator => {
                let sim = crate::device_manager::ops::sim_gate::read_focuser_status().await?;
                Ok(sim.moving)
            }
        }
    }

    pub async fn focuser_is_absolute(&self, device_id: &str) -> Result<bool, DeviceOpError> {
        let devices = self.devices.read().await;
        let info = devices
            .get(device_id)
            .map(|d| d.info.clone())
            .ok_or_else(|| DeviceOpError::device_not_found(device_id))?;
        drop(devices);

        match info.driver_type {
            DriverType::Ascom => {
                #[cfg(windows)]
                {
                    let focusers = self.ascom_focusers.read().await;
                    if let Some(focuser) = focusers.get(device_id) {
                        let focuser = focuser.read().await;
                        return focuser.is_absolute().await.map_err(DeviceOpError::driver);
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "ASCOM focuser not connected",
                ))
            }
            DriverType::Native => Ok(true),
            DriverType::Alpaca => {
                let alpaca_focusers = self.alpaca_focusers.read().await;
                if let Some(focuser) = alpaca_focusers.get(device_id) {
                    return focuser.absolute().await.map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "Alpaca focuser not connected",
                ))
            }
            DriverType::Indi => {
                // Parse INDI device ID: indi:host:port:device_name
                if let Ok((host, port, device_name)) = Self::parse_indi_device_id(device_id) {
                    let server_key = format!("{host}:{port}");

                    let clients = self.indi_clients.read().await;
                    if let Some(client) = clients.get(&server_key) {
                        let client = client.read().await;
                        return Ok(client
                            .get_property_state(&device_name, "ABS_FOCUS_POSITION")
                            .await
                            .is_some());
                    }
                    return Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        format!("INDI client not connected for {}", server_key),
                    ));
                }
                Err(DeviceOpError::invalid_device_id(
                    "Invalid INDI device ID format",
                ))
            }
            DriverType::Simulator => {
                let sim = crate::device_manager::ops::sim_gate::read_focuser_status().await?;
                Ok(sim.is_absolute)
            }
        }
    }

    pub async fn focuser_get_temp(&self, device_id: &str) -> Result<Option<f64>, DeviceOpError> {
        let devices = self.devices.read().await;
        let info = devices
            .get(device_id)
            .map(|d| d.info.clone())
            .ok_or_else(|| DeviceOpError::device_not_found(device_id))?;

        match info.driver_type {
            DriverType::Ascom => {
                #[cfg(windows)]
                {
                    let focusers = self.ascom_focusers.read().await;
                    if let Some(focuser) = focusers.get(device_id) {
                        let focuser = focuser.read().await;
                        return focuser
                            .get_temperature()
                            .await
                            .map_err(DeviceOpError::driver);
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "ASCOM focuser not connected",
                ))
            }
            DriverType::Native => {
                let native_focusers = self.native_focusers.read().await;
                if let Some(focuser) = native_focusers.get(device_id) {
                    return focuser
                        .get_temperature()
                        .await
                        .map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "Native focuser not connected",
                ))
            }
            DriverType::Alpaca => {
                let alpaca_focusers = self.alpaca_focusers.read().await;
                if let Some(focuser) = alpaca_focusers.get(device_id) {
                    // Alpaca temperature() returns f64, wrap in Some for consistency
                    return focuser
                        .temperature()
                        .await
                        .map(Some)
                        .map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "Alpaca focuser not connected",
                ))
            }
            DriverType::Indi => {
                // Parse INDI device ID: indi:host:port:device_name
                if let Ok((host, port, device_name)) = Self::parse_indi_device_id(device_id) {
                    let server_key = format!("{host}:{port}");

                    let clients = self.indi_clients.read().await;
                    if let Some(client) = clients.get(&server_key) {
                        let focuser =
                            nightshade_indi::IndiFocuser::new(client.clone(), &device_name);
                        // Temperature might not be available on all focusers.
                        // Distinguish "this focuser has no temperature sensor"
                        // (a legitimate Ok(None)) from "the read FAILED" — the
                        // latter must NOT be masked as 'no sensor' or
                        // temperature compensation silently disables for the
                        // night. INDI advertises FOCUS_TEMPERATURE only when the
                        // device actually has the sensor.
                        match focuser.get_temperature().await {
                            Ok(temp) => return Ok(Some(temp)),
                            Err(e) => {
                                let has_sensor = client
                                    .read()
                                    .await
                                    .has_property(&device_name, "FOCUS_TEMPERATURE")
                                    .await;
                                if has_sensor {
                                    return Err(DeviceOpError::driver(format!(
                                        "INDI focuser {} advertises a temperature sensor but the read failed: {}",
                                        device_name, e
                                    )));
                                }
                                return Ok(None); // genuinely no temperature sensor
                            }
                        }
                    }
                    return Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        format!("INDI client not connected for {}", server_key),
                    ));
                }
                Err(DeviceOpError::invalid_device_id(
                    "Invalid INDI device ID format",
                ))
            }
            DriverType::Simulator => {
                let sim = crate::device_manager::ops::sim_gate::read_focuser_status().await?;
                Ok(sim.temperature)
            }
        }
    }

    pub async fn focuser_get_details(&self, device_id: &str) -> Result<(i32, f64), DeviceOpError> {
        let devices = self.devices.read().await;
        let info = devices
            .get(device_id)
            .map(|d| d.info.clone())
            .ok_or_else(|| DeviceOpError::device_not_found(device_id))?;

        match info.driver_type {
            DriverType::Ascom => {
                #[cfg(windows)]
                {
                    let focusers = self.ascom_focusers.read().await;
                    if let Some(focuser) = focusers.get(device_id) {
                        let focuser = focuser.read().await;
                        return Ok((focuser.get_max_position(), focuser.get_step_size()));
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "ASCOM focuser not connected",
                ))
            }
            DriverType::Native => {
                let native_focusers = self.native_focusers.read().await;
                if let Some(focuser) = native_focusers.get(device_id) {
                    return Ok((focuser.get_max_position(), focuser.get_step_size()));
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "Native focuser not connected",
                ))
            }
            DriverType::Alpaca => {
                let alpaca_focusers = self.alpaca_focusers.read().await;
                if let Some(focuser) = alpaca_focusers.get(device_id) {
                    let max_step = focuser.max_step().await?;
                    let step_size = match focuser.step_size().await {
                        Ok(s) => s,
                        Err(e) => {
                            warn!("Failed to read Alpaca focuser step_size for {}: {}. Using default 1.0.", device_id, e);
                            1.0
                        }
                    };
                    return Ok((max_step, step_size));
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "Alpaca focuser not connected",
                ))
            }
            DriverType::Indi => {
                // Parse INDI device ID: indi:host:port:device_name
                if let Ok((host, port, device_name)) = Self::parse_indi_device_id(device_id) {
                    let server_key = format!("{host}:{port}");

                    let clients = self.indi_clients.read().await;
                    if let Some(client) = clients.get(&server_key) {
                        let client = client.read().await;

                        // Try to get max position from FOCUS_MAX property (common INDI standard)
                        // If unavailable, report unknown (0) instead of inventing a fake limit.
                        let max_position = match client
                            .get_number(&device_name, "FOCUS_MAX", "FOCUS_MAX_VALUE")
                            .await
                        {
                            // Why: INDI wire is f64 but
                            // FOCUS_MAX is a step count physically ≤ ~200k
                            // for any real focuser. Rust 1.45+ saturating
                            // f64 → i32 catches an out-of-range driver bug
                            // by reporting i32::MAX (which the UI displays
                            // as "max step out of range" anyway).
                            Some(v) => v as i32,
                            None => {
                                warn!(
                                    "Failed to read INDI focuser max position for {}: property not available. Reporting unknown max position.",
                                    device_id
                                );
                                0
                            }
                        };

                        // Step size is not universally standardized in INDI
                        // Report unknown (0.0) when unavailable rather than assuming 1.0.
                        let step_size = match client
                            .get_number(&device_name, "FOCUS_STEP", "FOCUS_STEP_VALUE")
                            .await
                        {
                            Some(s) => s,
                            None => {
                                warn!(
                                    "Failed to read INDI focuser step size for {}: property not available. Reporting unknown step size.",
                                    device_id
                                );
                                0.0
                            }
                        };

                        return Ok((max_position, step_size));
                    }
                    return Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        format!("INDI client not connected for {}", server_key),
                    ));
                }
                Err(DeviceOpError::invalid_device_id(
                    "Invalid INDI device ID format",
                ))
            }
            DriverType::Simulator => {
                let sim = crate::device_manager::ops::sim_gate::read_focuser_status().await?;
                Ok((sim.max_position, sim.step_size))
            }
        }
    }
}
