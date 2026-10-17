//! Cover calibrator operations dispatcher.
//!
//! Methods in this module are an additional impl block on `DeviceManager`
//! using Rust's split-impl-block feature. Behavior is identical to the
//! previous monolithic `devices.rs`.
//!
//! # `as`-cast policy
//!
//! - **i32 brightness → f64 INDI wire** (line 201): exact widening.
//! - **i32 state → i32** (lines 275, 327, 489, 490): these are no-op
//!   widenings around enum discriminant extraction (CoverState /
//!   CalibratorState are small {0..5} enums per ASCOM ICoverCalibratorV1).
//! - **i32 brightness → i32** (line 409): no-op widening; brightness is
//!   already i32 in the ASCOM API.
//!
//! # `unwrap_or` policy
//!
//! Every `unwrap_or` / `unwrap_or_else` in this file is a property-read
//! failure on the ICoverCalibrator interface (ASCOM/Alpaca) or its INDI
//! switch equivalent. Each site logs via `warn!` with the device id +
//! error message AND falls back to the documented "unknown" sentinel:
//!
//!   * `cover_state` / `calibrator_state` → `4` (the ASCOM "Unknown" enum
//!     value). The UI renders these as a yellow "?" badge.
//!   * `brightness` → `0` (the off state — safe for night-time imaging).
//!   * `max_brightness` → `255` (the ASCOM default; the brightness slider
//!     UI then renders 0-255 instead of a calibrator-specific scale).
//!
//! Each substitution carries a `warn!` naming the device and the failed
//! read, so a placeholder is never mistaken for a reading.
//!
//! # Simulator arm
//!
//! Every `DriverType::Simulator` arm delegates to
//! [`crate::api::devices::simulation`], which owns the lid's travel and the
//! panel's warm-up. It is deliberately NOT a set of `Ok(constant)` returns:
//! `wait_for_cover_state` and `wait_for_calibrator_state` in the sequencer poll
//! until the device reports the state they want, so a cover that reported
//! `Open` on the same call that commanded it would let both waits return before
//! real hardware had begun moving — and the timeout, the halt path and the
//! `Error` state would never be reached at all.

use crate::api::devices::simulation as sim;
use crate::device::*;
use crate::device_manager::DeviceManager;
use crate::dispatch::DeviceOpError;
use tracing::warn;

impl DeviceManager {
    async fn indi_cover_calibrator(
        &self,
        device_id: &str,
    ) -> Result<skotiq_indi::IndiCoverCalibrator, DeviceOpError> {
        let (host, port, device_name) = Self::parse_indi_device_id(device_id)?;
        let server_key = format!("{}:{}", host, port);
        let clients = self.indi_clients.read().await;
        let client = clients.get(&server_key).cloned();
        drop(clients);

        client
            .map(|client| skotiq_indi::IndiCoverCalibrator::new(client, &device_name))
            .ok_or_else(|| {
                DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "INDI cover calibrator not connected",
                )
            })
    }

    // Cover calibrator control

    /// Open cover calibrator cover
    pub async fn cover_calibrator_open_cover(&self, device_id: &str) -> Result<(), DeviceOpError> {
        let driver_type = {
            let devices = self.devices.read().await;
            devices.get(device_id).map(|d| d.info.driver_type.clone())
        };

        match driver_type {
            Some(DriverType::Alpaca) => {
                let cover_cals = self.alpaca_cover_calibrators.read().await;
                if let Some(cover_cal) = cover_cals.get(device_id) {
                    return cover_cal.open_cover().await.map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca cover calibrator {} not found", device_id),
                ))
            }
            #[cfg(windows)]
            Some(DriverType::Ascom) => {
                let cover_cals = self.ascom_cover_calibrators.read().await;
                if let Some(cover_cal) = cover_cals.get(device_id) {
                    let mut locked = cover_cal.write().await;
                    return locked.open_cover().await.map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("ASCOM cover calibrator {} not found", device_id),
                ))
            }
            Some(DriverType::Indi) => {
                let cover_cal = self.indi_cover_calibrator(device_id).await?;
                cover_cal.open_cover().await.map_err(DeviceOpError::driver)
            }
            Some(DriverType::Native) => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                format!("Native cover calibrator {} not found", device_id),
            )),
            Some(DriverType::Simulator) => {
                sim::sim_cover_move(true).await.map_err(DeviceOpError::from)
            }
            _ => Err(DeviceOpError::unsupported(
                "Cover calibrator not supported for this driver type",
            )),
        }
    }

    /// Close cover calibrator cover
    pub async fn cover_calibrator_close_cover(&self, device_id: &str) -> Result<(), DeviceOpError> {
        let driver_type = {
            let devices = self.devices.read().await;
            devices.get(device_id).map(|d| d.info.driver_type.clone())
        };

        match driver_type {
            Some(DriverType::Alpaca) => {
                let cover_cals = self.alpaca_cover_calibrators.read().await;
                if let Some(cover_cal) = cover_cals.get(device_id) {
                    return cover_cal.close_cover().await.map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca cover calibrator {} not found", device_id),
                ))
            }
            #[cfg(windows)]
            Some(DriverType::Ascom) => {
                let cover_cals = self.ascom_cover_calibrators.read().await;
                if let Some(cover_cal) = cover_cals.get(device_id) {
                    let mut locked = cover_cal.write().await;
                    return locked.close_cover().await.map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("ASCOM cover calibrator {} not found", device_id),
                ))
            }
            Some(DriverType::Indi) => {
                let cover_cal = self.indi_cover_calibrator(device_id).await?;
                cover_cal.close_cover().await.map_err(DeviceOpError::driver)
            }
            Some(DriverType::Native) => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                format!("Native cover calibrator {} not found", device_id),
            )),
            Some(DriverType::Simulator) => sim::sim_cover_move(false)
                .await
                .map_err(DeviceOpError::from),
            _ => Err(DeviceOpError::unsupported(
                "Cover calibrator not supported for this driver type",
            )),
        }
    }

    /// Halt cover calibrator cover movement
    pub async fn cover_calibrator_halt_cover(&self, device_id: &str) -> Result<(), DeviceOpError> {
        let driver_type = {
            let devices = self.devices.read().await;
            devices.get(device_id).map(|d| d.info.driver_type.clone())
        };

        match driver_type {
            Some(DriverType::Alpaca) => {
                let cover_cals = self.alpaca_cover_calibrators.read().await;
                if let Some(cover_cal) = cover_cals.get(device_id) {
                    return cover_cal.halt_cover().await.map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca cover calibrator {} not found", device_id),
                ))
            }
            #[cfg(windows)]
            Some(DriverType::Ascom) => {
                let cover_cals = self.ascom_cover_calibrators.read().await;
                if let Some(cover_cal) = cover_cals.get(device_id) {
                    let mut locked = cover_cal.write().await;
                    return locked.halt_cover().await.map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("ASCOM cover calibrator {} not found", device_id),
                ))
            }
            Some(DriverType::Indi) => {
                let cover_cal = self.indi_cover_calibrator(device_id).await?;
                cover_cal.halt_cover().await.map_err(DeviceOpError::driver)
            }
            Some(DriverType::Native) => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                format!("Native cover calibrator {} not found", device_id),
            )),
            Some(DriverType::Simulator) => sim::sim_cover_halt().await.map_err(DeviceOpError::from),
            _ => Err(DeviceOpError::unsupported(
                "Cover calibrator not supported for this driver type",
            )),
        }
    }

    /// Turn on cover calibrator light
    pub async fn cover_calibrator_calibrator_on(
        &self,
        device_id: &str,
        brightness: i32,
    ) -> Result<(), DeviceOpError> {
        let driver_type = {
            let devices = self.devices.read().await;
            devices.get(device_id).map(|d| d.info.driver_type.clone())
        };

        match driver_type {
            Some(DriverType::Alpaca) => {
                let cover_cals = self.alpaca_cover_calibrators.read().await;
                if let Some(cover_cal) = cover_cals.get(device_id) {
                    return cover_cal
                        .calibrator_on(brightness)
                        .await
                        .map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca cover calibrator {} not found", device_id),
                ))
            }
            #[cfg(windows)]
            Some(DriverType::Ascom) => {
                let cover_cals = self.ascom_cover_calibrators.read().await;
                if let Some(cover_cal) = cover_cals.get(device_id) {
                    let mut locked = cover_cal.write().await;
                    return locked
                        .calibrator_on(brightness)
                        .await
                        .map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("ASCOM cover calibrator {} not found", device_id),
                ))
            }
            Some(DriverType::Indi) => {
                let cover_cal = self.indi_cover_calibrator(device_id).await?;
                cover_cal
                    .calibrator_on(brightness)
                    .await
                    .map_err(DeviceOpError::driver)
            }
            Some(DriverType::Native) => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                format!("Native cover calibrator {} not found", device_id),
            )),
            Some(DriverType::Simulator) => sim::sim_calibrator_on(brightness)
                .await
                .map_err(DeviceOpError::from),
            _ => Err(DeviceOpError::unsupported(
                "Cover calibrator not supported for this driver type",
            )),
        }
    }

    /// Turn off cover calibrator light
    pub async fn cover_calibrator_calibrator_off(
        &self,
        device_id: &str,
    ) -> Result<(), DeviceOpError> {
        let driver_type = {
            let devices = self.devices.read().await;
            devices.get(device_id).map(|d| d.info.driver_type.clone())
        };

        match driver_type {
            Some(DriverType::Alpaca) => {
                let cover_cals = self.alpaca_cover_calibrators.read().await;
                if let Some(cover_cal) = cover_cals.get(device_id) {
                    return cover_cal
                        .calibrator_off()
                        .await
                        .map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca cover calibrator {} not found", device_id),
                ))
            }
            #[cfg(windows)]
            Some(DriverType::Ascom) => {
                let cover_cals = self.ascom_cover_calibrators.read().await;
                if let Some(cover_cal) = cover_cals.get(device_id) {
                    let mut locked = cover_cal.write().await;
                    return locked.calibrator_off().await.map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("ASCOM cover calibrator {} not found", device_id),
                ))
            }
            Some(DriverType::Indi) => {
                let cover_cal = self.indi_cover_calibrator(device_id).await?;
                cover_cal
                    .calibrator_off()
                    .await
                    .map_err(DeviceOpError::driver)
            }
            Some(DriverType::Native) => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                format!("Native cover calibrator {} not found", device_id),
            )),
            Some(DriverType::Simulator) => {
                sim::sim_calibrator_off().await.map_err(DeviceOpError::from)
            }
            _ => Err(DeviceOpError::unsupported(
                "Cover calibrator not supported for this driver type",
            )),
        }
    }

    /// Get cover calibrator cover state
    /// Returns: 0=NotPresent, 1=Closed, 2=Moving, 3=Open, 4=Unknown, 5=Error
    pub async fn cover_calibrator_get_cover_state(
        &self,
        device_id: &str,
    ) -> Result<i32, DeviceOpError> {
        let driver_type = {
            let devices = self.devices.read().await;
            devices.get(device_id).map(|d| d.info.driver_type.clone())
        };

        match driver_type {
            Some(DriverType::Alpaca) => {
                let cover_cals = self.alpaca_cover_calibrators.read().await;
                if let Some(cover_cal) = cover_cals.get(device_id) {
                    let state = cover_cal.cover_state().await?;
                    return Ok(state as i32);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca cover calibrator {} not found", device_id),
                ))
            }
            #[cfg(windows)]
            Some(DriverType::Ascom) => {
                let cover_cals = self.ascom_cover_calibrators.read().await;
                if let Some(cover_cal) = cover_cals.get(device_id) {
                    let locked = cover_cal.read().await;
                    return locked.cover_state().await.map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("ASCOM cover calibrator {} not found", device_id),
                ))
            }
            Some(DriverType::Indi) => {
                let cover_cal = self.indi_cover_calibrator(device_id).await?;
                Ok(cover_cal.get_cover_state().await.to_i32())
            }
            Some(DriverType::Native) => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                format!("Native cover calibrator {} not found", device_id),
            )),
            Some(DriverType::Simulator) => sim::sim_cover_status()
                .await
                .map(|status| status.cover_state.to_i32())
                .map_err(DeviceOpError::from),
            _ => Err(DeviceOpError::unsupported(
                "Cover calibrator not supported for this driver type",
            )),
        }
    }

    /// Get cover calibrator calibrator state
    /// Returns: 0=NotPresent, 1=Off, 2=NotReady, 3=Ready, 4=Unknown, 5=Error
    pub async fn cover_calibrator_get_calibrator_state(
        &self,
        device_id: &str,
    ) -> Result<i32, DeviceOpError> {
        let driver_type = {
            let devices = self.devices.read().await;
            devices.get(device_id).map(|d| d.info.driver_type.clone())
        };

        match driver_type {
            Some(DriverType::Alpaca) => {
                let cover_cals = self.alpaca_cover_calibrators.read().await;
                if let Some(cover_cal) = cover_cals.get(device_id) {
                    let state = cover_cal.calibrator_state().await?;
                    return Ok(state as i32);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca cover calibrator {} not found", device_id),
                ))
            }
            #[cfg(windows)]
            Some(DriverType::Ascom) => {
                let cover_cals = self.ascom_cover_calibrators.read().await;
                if let Some(cover_cal) = cover_cals.get(device_id) {
                    let locked = cover_cal.read().await;
                    return locked
                        .calibrator_state()
                        .await
                        .map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("ASCOM cover calibrator {} not found", device_id),
                ))
            }
            Some(DriverType::Indi) => {
                let cover_cal = self.indi_cover_calibrator(device_id).await?;
                Ok(cover_cal.get_calibrator_state().await.to_i32())
            }
            Some(DriverType::Native) => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                format!("Native cover calibrator {} not found", device_id),
            )),
            Some(DriverType::Simulator) => sim::sim_cover_status()
                .await
                .map(|status| status.calibrator_state.to_i32())
                .map_err(DeviceOpError::from),
            _ => Err(DeviceOpError::unsupported(
                "Cover calibrator not supported for this driver type",
            )),
        }
    }

    /// Get cover calibrator brightness
    pub async fn cover_calibrator_get_brightness(
        &self,
        device_id: &str,
    ) -> Result<i32, DeviceOpError> {
        let driver_type = {
            let devices = self.devices.read().await;
            devices.get(device_id).map(|d| d.info.driver_type.clone())
        };

        match driver_type {
            Some(DriverType::Alpaca) => {
                let cover_cals = self.alpaca_cover_calibrators.read().await;
                if let Some(cover_cal) = cover_cals.get(device_id) {
                    return cover_cal.brightness().await.map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca cover calibrator {} not found", device_id),
                ))
            }
            #[cfg(windows)]
            Some(DriverType::Ascom) => {
                let cover_cals = self.ascom_cover_calibrators.read().await;
                if let Some(cover_cal) = cover_cals.get(device_id) {
                    let locked = cover_cal.read().await;
                    return locked.brightness().await.map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("ASCOM cover calibrator {} not found", device_id),
                ))
            }
            Some(DriverType::Indi) => {
                let cover_cal = self.indi_cover_calibrator(device_id).await?;
                cover_cal
                    .get_brightness()
                    .await
                    .map_err(DeviceOpError::driver)
            }
            Some(DriverType::Native) => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                format!("Native cover calibrator {} not found", device_id),
            )),
            Some(DriverType::Simulator) => sim::sim_cover_status()
                .await
                .map(|status| status.brightness)
                .map_err(DeviceOpError::from),
            _ => Err(DeviceOpError::unsupported(
                "Cover calibrator not supported for this driver type",
            )),
        }
    }

    /// Get cover calibrator max brightness
    pub async fn cover_calibrator_get_max_brightness(
        &self,
        device_id: &str,
    ) -> Result<i32, DeviceOpError> {
        let driver_type = {
            let devices = self.devices.read().await;
            devices.get(device_id).map(|d| d.info.driver_type.clone())
        };

        match driver_type {
            Some(DriverType::Alpaca) => {
                let cover_cals = self.alpaca_cover_calibrators.read().await;
                if let Some(cover_cal) = cover_cals.get(device_id) {
                    return cover_cal
                        .max_brightness()
                        .await
                        .map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca cover calibrator {} not found", device_id),
                ))
            }
            #[cfg(windows)]
            Some(DriverType::Ascom) => {
                let cover_cals = self.ascom_cover_calibrators.read().await;
                if let Some(cover_cal) = cover_cals.get(device_id) {
                    let locked = cover_cal.read().await;
                    return locked.max_brightness().await.map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("ASCOM cover calibrator {} not found", device_id),
                ))
            }
            Some(DriverType::Indi) => {
                let cover_cal = self.indi_cover_calibrator(device_id).await?;
                cover_cal
                    .get_max_brightness()
                    .await
                    .map_err(DeviceOpError::driver)
            }
            Some(DriverType::Native) => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                format!("Native cover calibrator {} not found", device_id),
            )),
            Some(DriverType::Simulator) => sim::sim_cover_status()
                .await
                .map(|status| status.max_brightness)
                .map_err(DeviceOpError::from),
            _ => Err(DeviceOpError::unsupported(
                "Cover calibrator not supported for this driver type",
            )),
        }
    }

    /// Get cover calibrator status (combined state)
    pub async fn cover_calibrator_get_status(
        &self,
        device_id: &str,
    ) -> Result<CoverCalibratorStatus, DeviceOpError> {
        let driver_type = {
            let devices = self.devices.read().await;
            devices.get(device_id).map(|d| d.info.driver_type.clone())
        };

        match driver_type {
            Some(DriverType::Alpaca) => {
                let cover_cals = self.alpaca_cover_calibrators.read().await;
                let Some(cover_cal) = cover_cals.get(device_id) else {
                    return Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        format!("Alpaca cover calibrator {} not found", device_id),
                    ));
                };

                let status = cover_cal.get_status().await?;
                let max_brightness = cover_cal.max_brightness().await.unwrap_or_else(|e| {
                    warn!(
                        "Failed to read cover calibrator max_brightness for {}: {}. Using default 255.",
                        device_id, e
                    );
                    255
                });

                Ok(CoverCalibratorStatus {
                    connected: true,
                    cover_state: CoverState::from_i32(status.cover_state as i32),
                    calibrator_state: CalibratorState::from_i32(status.calibrator_state as i32),
                    brightness: status.brightness.unwrap_or(0),
                    max_brightness,
                })
            }
            #[cfg(windows)]
            Some(DriverType::Ascom) => {
                let cover_cals = self.ascom_cover_calibrators.read().await;
                let Some(cover_cal) = cover_cals.get(device_id) else {
                    return Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        format!("ASCOM cover calibrator {} not found", device_id),
                    ));
                };

                let locked = cover_cal.read().await;
                let cover_state_raw = locked.cover_state().await.unwrap_or_else(|e| {
                    warn!(
                        "Failed to read cover calibrator cover_state for {}: {}. Using Unknown (4).",
                        device_id, e
                    );
                    4
                });
                let calibrator_state_raw = locked.calibrator_state().await.unwrap_or_else(|e| {
                    warn!(
                        "Failed to read cover calibrator calibrator_state for {}: {}. Using Unknown (4).",
                        device_id, e
                    );
                    4
                });
                let brightness = locked.brightness().await.unwrap_or_else(|e| {
                    warn!(
                        "Failed to read cover calibrator brightness for {}: {}. Using default 0.",
                        device_id, e
                    );
                    0
                });

                Ok(CoverCalibratorStatus {
                    connected: true,
                    cover_state: CoverState::from_i32(cover_state_raw),
                    calibrator_state: CalibratorState::from_i32(calibrator_state_raw),
                    brightness,
                    max_brightness: locked.cached_max_brightness(),
                })
            }
            Some(DriverType::Indi) => {
                let cover_state_raw = match self.cover_calibrator_get_cover_state(device_id).await {
                    Ok(s) => s,
                    Err(e) => {
                        warn!(
                            "Failed to read cover calibrator cover_state for {}: {}. Using Unknown (4).",
                            device_id, e
                        );
                        4
                    }
                };
                let calibrator_state_raw = match self
                    .cover_calibrator_get_calibrator_state(device_id)
                    .await
                {
                    Ok(s) => s,
                    Err(e) => {
                        warn!(
                                "Failed to read cover calibrator calibrator_state for {}: {}. Using Unknown (4).",
                                device_id, e
                            );
                        4
                    }
                };
                let brightness = self
                    .cover_calibrator_get_brightness(device_id)
                    .await
                    .unwrap_or_else(|e| {
                        warn!(
                            "Failed to read cover calibrator brightness for {}: {}. Using default 0.",
                            device_id, e
                        );
                        0
                    });
                let max_brightness = self
                    .cover_calibrator_get_max_brightness(device_id)
                    .await
                    .unwrap_or_else(|e| {
                        warn!(
                            "Failed to read cover calibrator max_brightness for {}: {}. Using default 255.",
                            device_id, e
                        );
                        255
                    });

                Ok(CoverCalibratorStatus {
                    connected: true,
                    cover_state: CoverState::from_i32(cover_state_raw),
                    calibrator_state: CalibratorState::from_i32(calibrator_state_raw),
                    brightness,
                    max_brightness,
                })
            }
            Some(DriverType::Native) => {
                let cover_state_raw = match self.cover_calibrator_get_cover_state(device_id).await {
                    Ok(s) => s,
                    Err(e) => {
                        warn!(
                            "Failed to read native cover calibrator cover_state for {}: {}. Using Unknown (4).",
                            device_id, e
                        );
                        4
                    }
                };
                let calibrator_state_raw = match self
                    .cover_calibrator_get_calibrator_state(device_id)
                    .await
                {
                    Ok(s) => s,
                    Err(e) => {
                        warn!(
                            "Failed to read native cover calibrator calibrator_state for {}: {}. Using Unknown (4).",
                            device_id, e
                        );
                        4
                    }
                };
                let brightness = self
                    .cover_calibrator_get_brightness(device_id)
                    .await
                    .unwrap_or_else(|e| {
                        warn!(
                            "Failed to read native cover calibrator brightness for {}: {}. Using default 0.",
                            device_id, e
                        );
                        0
                    });
                let max_brightness = self
                    .cover_calibrator_get_max_brightness(device_id)
                    .await
                    .unwrap_or_else(|e| {
                        warn!(
                            "Failed to read native cover calibrator max_brightness for {}: {}. Using default 255.",
                            device_id, e
                        );
                        255
                    });

                Ok(CoverCalibratorStatus {
                    connected: true,
                    cover_state: CoverState::from_i32(cover_state_raw),
                    calibrator_state: CalibratorState::from_i32(calibrator_state_raw),
                    brightness,
                    max_brightness,
                })
            }
            Some(DriverType::Simulator) => {
                sim::sim_cover_status().await.map_err(DeviceOpError::from)
            }
            _ => Err(DeviceOpError::unsupported(
                "Cover calibrator not supported for this driver type",
            )),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::device_manager::ManagedDevice;
    use crate::state::AppState;
    use std::time::Duration;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    fn build_cover_info(id: &str) -> DeviceInfo {
        DeviceInfo {
            id: id.to_string(),
            name: "FlatMaster".to_string(),
            device_type: DeviceType::CoverCalibrator,
            driver_type: DriverType::Indi,
            description: "Test INDI cover calibrator".to_string(),
            driver_version: "1.0".to_string(),
            serial_number: None,
            unique_id: None,
            display_name: "FlatMaster".to_string(),
        }
    }

    async fn connect_fake_cover(
        xml: &'static str,
    ) -> (
        std::sync::Arc<DeviceManager>,
        String,
        tokio::sync::oneshot::Receiver<String>,
        tokio::task::JoinHandle<()>,
    ) {
        let manager = DeviceManager::new(AppState::new());
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind fake INDI cover server");
        let port = listener.local_addr().expect("read listener address").port();
        let device_id = format!("indi:127.0.0.1:{}:FlatMaster", port);

        manager.devices.write().await.insert(
            device_id.clone(),
            ManagedDevice {
                info: build_cover_info(&device_id),
                connection_state: ConnectionState::Connected,
                last_error: None,
                reconnect_attempts: 0,
                auto_reconnect: false,
                last_successful_comm: None,
                heartbeat_active: false,
                api_version: None,
                desired_cooler: None,
                desired_tracking: None,
            },
        );

        let (command_tx, command_rx) = tokio::sync::oneshot::channel();
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.expect("accept INDI client");
            let mut buf = vec![0_u8; 4096];
            let _ = socket
                .read(&mut buf)
                .await
                .expect("read initial getProperties");
            socket.write_all(xml.as_bytes()).await.expect("write XML");

            loop {
                buf.fill(0);
                let n = socket.read(&mut buf).await.expect("read cover command");
                if n == 0 {
                    break;
                }
                let command = String::from_utf8_lossy(&buf[..n]).to_string();
                if command.contains("<newSwitchVector")
                    && command.contains("name=\"LIGHTBOX_CONTROL\"")
                {
                    let _ = command_tx.send(command);
                    break;
                }
            }
        });

        let timeout_config = skotiq_indi::IndiTimeoutConfig {
            connection_timeout_secs: 1,
            ..Default::default()
        };
        let mut client =
            skotiq_indi::IndiClient::with_timeout_config("127.0.0.1", Some(port), timeout_config);
        client.connect().await.expect("connect fake INDI client");

        manager.indi_clients.write().await.insert(
            format!("127.0.0.1:{}", port),
            std::sync::Arc::new(tokio::sync::RwLock::new(client)),
        );

        wait_for_lightbox_property(&manager, &device_id).await;
        (manager, device_id, command_rx, server)
    }

    async fn wait_for_lightbox_property(manager: &DeviceManager, device_id: &str) {
        let (host, port, _device_name) =
            DeviceManager::parse_indi_device_id(device_id).expect("test id is a valid INDI id");
        let server_key = format!("{host}:{port}");
        let deadline = tokio::time::Instant::now() + Duration::from_secs(2);

        loop {
            let client = {
                let clients = manager.indi_clients.read().await;
                clients.get(&server_key).cloned()
            }
            .expect("fake INDI client should be registered");

            if client
                .read()
                .await
                .has_property("FlatMaster", "LIGHTBOX_CONTROL")
                .await
            {
                break;
            }

            assert!(
                tokio::time::Instant::now() < deadline,
                "fake INDI LIGHTBOX_CONTROL property was not parsed in time"
            );
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }

    #[tokio::test]
    async fn indi_cover_open_uses_lightbox_control_fallback() {
        let xml = r#"
<defSwitchVector device="FlatMaster" name="LIGHTBOX_CONTROL" state="Ok" perm="rw" rule="OneOfMany">
  <defSwitch name="OPEN">Off</defSwitch>
  <defSwitch name="CLOSE">On</defSwitch>
</defSwitchVector>
"#;
        let (manager, device_id, command_rx, server) = connect_fake_cover(xml).await;

        manager
            .cover_calibrator_open_cover(&device_id)
            .await
            .expect("LIGHTBOX_CONTROL OPEN should be accepted");

        let command = tokio::time::timeout(Duration::from_secs(2), command_rx)
            .await
            .expect("fake INDI server should receive LIGHTBOX_CONTROL command")
            .expect("fake INDI server should send observed command");
        assert!(
            command.contains("<oneSwitch name=\"OPEN\">On</oneSwitch>"),
            "open command should turn LIGHTBOX OPEN on: {}",
            command
        );
        assert!(
            command.contains("<oneSwitch name=\"CLOSE\">Off</oneSwitch>"),
            "open command should turn LIGHTBOX CLOSE off: {}",
            command
        );
        server.await.expect("fake INDI server should finish");
    }

    #[tokio::test]
    async fn indi_cover_state_reads_lightbox_control() {
        let xml = r#"
<defSwitchVector device="FlatMaster" name="LIGHTBOX_CONTROL" state="Ok" perm="rw" rule="OneOfMany">
  <defSwitch name="OPEN">On</defSwitch>
  <defSwitch name="CLOSE">Off</defSwitch>
</defSwitchVector>
"#;
        let (manager, device_id, _command_rx, server) = connect_fake_cover(xml).await;

        let state = manager
            .cover_calibrator_get_cover_state(&device_id)
            .await
            .expect("LIGHTBOX_CONTROL state should be readable");

        assert_eq!(state, 3);
        drop(manager);
        server.abort();
    }
}

/// The simulated flat panel, driven the way the app drives a real one.
///
/// These go the long way round — `api_discover_devices` for the id,
/// `connect_device` to open it, then `skotiq_sequencer::DeviceOps` for
/// every operation — because that is the whole path the sequencer's
/// `OpenCover` and `CalibratorOn` nodes take. Calling `sim_cover_move`
/// directly keeps passing even when the device is never discoverable, never
/// connectable, or the `DriverType::Simulator` arm is gone.
#[cfg(test)]
mod simulator_tests {
    use crate::api::devices::simulation::sim_singleton_test_lock;
    use crate::api::discovery::api_discover_devices;
    use crate::api::get_device_manager;
    use crate::device::{DeviceType, DriverType};
    use skotiq_sequencer::DeviceOps;
    use std::sync::Arc;
    use std::time::{Duration, Instant};

    /// ASCOM `CoverState` / `CalibratorState` discriminants, spelled out because
    /// that is what the sequencer's `wait_for_cover_state` compares against.
    const COVER_CLOSED: i32 = 1;
    const COVER_MOVING: i32 = 2;
    const COVER_OPEN: i32 = 3;
    const COVER_UNKNOWN: i32 = 4;
    const COVER_ERROR: i32 = 5;
    const CALIBRATOR_OFF: i32 = 1;
    const CALIBRATOR_NOT_READY: i32 = 2;
    const CALIBRATOR_READY: i32 = 3;

    /// Discover, register and connect the simulated panel, returning its id and
    /// the sequencer-facing ops handle the instruction nodes use.
    async fn connect_simulated_panel() -> (String, Arc<dyn DeviceOps>) {
        crate::api::devices::simulation::reset_sim_cover_calibrator().await;
        let devices = api_discover_devices(DeviceType::CoverCalibrator)
            .await
            .expect("cover calibrator discovery should succeed");
        let info = devices
            .into_iter()
            .find(|d| d.driver_type == DriverType::Simulator)
            .expect(
                "discovery returned no simulated cover calibrator: flat-panel flows cannot be \
                 exercised without hardware",
            );

        let device_id = info.id.clone();
        let manager = get_device_manager();
        manager.register_device(info, false).await;
        manager
            .connect_device(&device_id)
            .await
            .expect("the simulated cover calibrator should connect");

        (
            device_id,
            crate::unified_device_ops::create_unified_device_ops(),
        )
    }

    async fn release_simulated_panel(device_id: &str) {
        let _ = get_device_manager().disconnect_device(device_id).await;
    }

    /// Poll `cover_state` the way `wait_for_cover_state` does, recording every
    /// distinct state seen so the test can assert on the path, not just the
    /// destination.
    async fn poll_cover_until(
        ops: &Arc<dyn DeviceOps>,
        device_id: &str,
        target: i32,
        timeout: Duration,
    ) -> Vec<i32> {
        let start = Instant::now();
        let mut seen: Vec<i32> = Vec::new();
        loop {
            let state = ops
                .cover_calibrator_get_cover_state(device_id)
                .await
                .expect("cover state should be readable");
            if seen.last() != Some(&state) {
                seen.push(state);
            }
            if state == target || start.elapsed() > timeout {
                return seen;
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
    }

    /// The lid must be observed MOVING before it is open. A cover that reported
    /// `Open` on the same poll that commanded it would let `wait_for_cover_state`
    /// return before real hardware had begun to move, so every wait, timeout and
    /// progress readout in the flat path would ship unexercised.
    #[tokio::test]
    async fn simulated_cover_is_seen_moving_before_it_is_open() {
        let _serialized = sim_singleton_test_lock().lock().await;
        let (device_id, ops) = connect_simulated_panel().await;

        assert_eq!(
            ops.cover_calibrator_get_cover_state(&device_id)
                .await
                .expect("initial cover state"),
            COVER_CLOSED,
            "a flat panel starts the night closed"
        );

        ops.cover_calibrator_open_cover(&device_id)
            .await
            .expect("open cover should be accepted");
        assert_eq!(
            ops.cover_calibrator_get_cover_state(&device_id)
                .await
                .expect("cover state right after the command"),
            COVER_MOVING,
            "the cover finished travelling before the command returned"
        );

        let path = poll_cover_until(&ops, &device_id, COVER_OPEN, Duration::from_secs(10)).await;
        assert_eq!(
            path.last(),
            Some(&COVER_OPEN),
            "the cover never reached Open: {path:?}"
        );
        assert!(
            path.contains(&COVER_MOVING),
            "the cover jumped straight to Open without ever reporting Moving: {path:?}"
        );

        release_simulated_panel(&device_id).await;
    }

    /// Halting mid-travel must leave the cover reporting `Unknown`. It is
    /// genuinely neither open nor closed, and `wait_for_cover_state` then times
    /// out rather than being told a comfortable lie — which is what a real
    /// controller does after `HaltCover`.
    #[tokio::test]
    async fn halting_mid_travel_reports_unknown_not_closed() {
        let _serialized = sim_singleton_test_lock().lock().await;
        let (device_id, ops) = connect_simulated_panel().await;

        ops.cover_calibrator_open_cover(&device_id)
            .await
            .expect("open cover should be accepted");
        tokio::time::sleep(Duration::from_millis(300)).await;
        ops.cover_calibrator_halt_cover(&device_id)
            .await
            .expect("halt should be accepted");

        let halted = ops
            .cover_calibrator_get_cover_state(&device_id)
            .await
            .expect("cover state after halt");
        assert_eq!(
            halted, COVER_UNKNOWN,
            "a cover stopped part-way reported {halted} instead of Unknown"
        );

        // And the position it stopped at is real: closing from half-open takes
        // less than a full traverse, so the lid cannot have been silently
        // teleported back to an endstop.
        ops.cover_calibrator_close_cover(&device_id)
            .await
            .expect("close should be accepted");
        let path = poll_cover_until(&ops, &device_id, COVER_CLOSED, Duration::from_secs(10)).await;
        assert_eq!(path.last(), Some(&COVER_CLOSED), "path: {path:?}");

        release_simulated_panel(&device_id).await;
    }

    /// A jammed lid is the failure that costs a flat sequence. The command still
    /// succeeds — that is what makes it hard — and the controller only reports
    /// `Error` once its own move timeout expires. Without this the `Error` arm of
    /// `wait_for_cover_state` is unreachable without hardware.
    #[tokio::test]
    async fn a_jammed_cover_is_reported_rather_than_silently_never_arriving() {
        use crate::device_manager::ops::sim_faults::{self, Effect, FaultSpec, Trigger};

        let _serialized = sim_singleton_test_lock().lock().await;
        sim_faults::clear_all();
        let (device_id, ops) = connect_simulated_panel().await;

        sim_faults::arm(
            "covercalibrator.cover",
            FaultSpec::new(Trigger::Always, Effect::Stall),
        );
        ops.cover_calibrator_open_cover(&device_id)
            .await
            .expect("a stalled mechanism still ACCEPTS the command");

        let path = poll_cover_until(&ops, &device_id, COVER_ERROR, Duration::from_secs(15)).await;
        assert!(
            !path.contains(&COVER_OPEN),
            "a stalled cover reported itself Open: {path:?}"
        );
        assert_eq!(
            path.last(),
            Some(&COVER_ERROR),
            "the controller never gave up on the jammed lid: {path:?}"
        );

        sim_faults::clear_all();
        release_simulated_panel(&device_id).await;
    }

    /// The panel must pass through `NotReady` before `Ready`. That state exists
    /// because a flat taken before an EL panel settles is at the wrong level;
    /// if the simulator jumped straight to `Ready`, the wait in
    /// `execute_calibrator_on` would be a no-op.
    #[tokio::test]
    async fn calibrator_settles_through_not_ready_and_reports_the_brightness_it_reached() {
        let _serialized = sim_singleton_test_lock().lock().await;
        let (device_id, ops) = connect_simulated_panel().await;

        assert_eq!(
            ops.cover_calibrator_get_calibrator_state(&device_id)
                .await
                .expect("initial calibrator state"),
            CALIBRATOR_OFF
        );

        let max = ops
            .cover_calibrator_get_max_brightness(&device_id)
            .await
            .expect("max brightness");
        ops.cover_calibrator_calibrator_on(&device_id, max)
            .await
            .expect("calibrator on should be accepted");
        assert_eq!(
            ops.cover_calibrator_get_calibrator_state(&device_id)
                .await
                .expect("calibrator state right after the command"),
            CALIBRATOR_NOT_READY,
            "the panel claimed to be stable the instant it was switched on"
        );
        assert!(
            ops.cover_calibrator_get_brightness(&device_id)
                .await
                .expect("brightness while settling")
                < max,
            "the panel reported full output before it had ramped there"
        );

        let start = Instant::now();
        while ops
            .cover_calibrator_get_calibrator_state(&device_id)
            .await
            .expect("calibrator state")
            != CALIBRATOR_READY
        {
            assert!(
                start.elapsed() < Duration::from_secs(10),
                "the panel never became Ready"
            );
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
        assert_eq!(
            ops.cover_calibrator_get_brightness(&device_id)
                .await
                .expect("settled brightness"),
            max,
            "a Ready panel must be at the level it was asked for"
        );

        ops.cover_calibrator_calibrator_off(&device_id)
            .await
            .expect("calibrator off should be accepted");
        let start = Instant::now();
        while ops
            .cover_calibrator_get_calibrator_state(&device_id)
            .await
            .expect("calibrator state")
            != CALIBRATOR_OFF
        {
            assert!(
                start.elapsed() < Duration::from_secs(10),
                "the panel never went Off"
            );
            tokio::time::sleep(Duration::from_millis(25)).await;
        }

        release_simulated_panel(&device_id).await;
    }

    /// ASCOM requires a brightness outside `0..=MaxBrightness` to be rejected.
    /// Clamping instead would hide the app sending a 0-100 percentage to a
    /// 0-255 panel: the flats would simply come out at the wrong level and
    /// nothing would say so.
    #[tokio::test]
    async fn an_out_of_range_brightness_is_refused_rather_than_clamped() {
        let _serialized = sim_singleton_test_lock().lock().await;
        let (device_id, ops) = connect_simulated_panel().await;

        let max = ops
            .cover_calibrator_get_max_brightness(&device_id)
            .await
            .expect("max brightness");
        let err = ops
            .cover_calibrator_calibrator_on(&device_id, max + 1)
            .await
            .expect_err("a brightness above the panel's ceiling must be refused");
        assert!(
            err.to_string().contains("outside"),
            "the refusal must say what was wrong with the value: {err}"
        );
        assert_eq!(
            ops.cover_calibrator_get_calibrator_state(&device_id)
                .await
                .expect("calibrator state"),
            CALIBRATOR_OFF,
            "a refused command still turned the panel on"
        );

        ops.cover_calibrator_calibrator_on(&device_id, -1)
            .await
            .expect_err("a negative brightness must be refused");

        release_simulated_panel(&device_id).await;
    }

    /// A disconnected simulator must fail loudly rather than answering with
    /// synthetic state — the same gate every other simulator device has.
    #[tokio::test]
    async fn a_disconnected_panel_refuses_to_answer() {
        let _serialized = sim_singleton_test_lock().lock().await;
        let (device_id, ops) = connect_simulated_panel().await;
        release_simulated_panel(&device_id).await;

        let err = ops
            .cover_calibrator_get_cover_state(&device_id)
            .await
            .expect_err("a disconnected panel must not report a cover state");
        assert!(
            err.to_string().contains("not connected"),
            "the error must name the disconnection: {err}"
        );
    }
}
