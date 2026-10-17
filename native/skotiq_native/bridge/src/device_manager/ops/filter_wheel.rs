//! Filter wheel operations dispatcher.
//!
//! Methods in this module are an additional impl block on `DeviceManager`
//! using Rust's split-impl-block feature. Behavior is identical to the
//! previous monolithic `devices.rs`.
//!
//! # `as`-cast policy
//!
//! Filter wheels physically have ≤ 16 slots; every numeric cast in this
//! module is therefore bounded:
//! - **i32 position ↔ f64** (line 67): INDI wire is f64; i32 → f64 exact.
//! - **i32 position - 1** (line 132): 1-based INDI position to 0-based.
//!   Position is ≥ 1 (set elsewhere via INDI driver advertisement).
//! - **usize → i32 filter count** (lines 242, 253, 272): real slot count
//!   ≤ 16, fits i32 trivially.
//! - **usize → i32 filter index** (line 323): same bound — index < count.

use crate::device::*;
use crate::device_manager::DeviceManager;
use crate::dispatch::DeviceOpError;
use skotiq_indi::IndiFilterWheel;
// Windows: trait must be in scope so ASCOM wrapper guards resolve its methods.
#[cfg(windows)]
use skotiq_native::traits::NativeFilterWheel;

impl DeviceManager {
    // Filter wheel control

    pub async fn filter_wheel_set_position(
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

        match info.driver_type {
            DriverType::Ascom => {
                #[cfg(windows)]
                {
                    let wheels = self.ascom_filter_wheels.read().await;
                    if let Some(wheel) = wheels.get(device_id) {
                        let mut wheel = wheel.write().await;
                        return wheel.move_to_position(position).await.map_err(|e| {
                            DeviceOpError::hardware(
                                Some(device_id.to_string()),
                                format!(
                                    "Failed to move ASCOM filter wheel {} to slot {}: {}",
                                    device_id, position, e
                                ),
                            )
                        });
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "ASCOM filter wheel not connected",
                ))
            }
            DriverType::Native => {
                let mut native_filter_wheels = self.native_filter_wheels.write().await;
                if let Some(wheel) = native_filter_wheels.get_mut(device_id) {
                    wheel.move_to_position(position).await.map_err(|e| {
                        DeviceOpError::hardware(
                            Some(device_id.to_string()),
                            format!(
                                "Failed to move native filter wheel {} to slot {}: {}",
                                device_id, position, e
                            ),
                        )
                    })?;

                    // Several vendor SDKs acknowledge the command before the
                    // motor starts. More importantly, a ZWO EFW can return SDK
                    // success for a command that never changes the encoder
                    // position. Do not report success until physical readback
                    // reaches the requested slot.
                    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(60);
                    let mut last_position = None;
                    loop {
                        match wheel.get_position().await {
                            Ok(current) if current == position => return Ok(()),
                            Ok(current) => last_position = Some(current),
                            Err(error) => {
                                tracing::warn!(
                                    "Native filter wheel {} readback failed while moving to {}: {}",
                                    device_id,
                                    position,
                                    error
                                );
                            }
                        }
                        if tokio::time::Instant::now() >= deadline {
                            return Err(DeviceOpError::hardware(
                                Some(device_id.to_string()),
                                format!(
                                    "Native filter wheel {} did not reach slot {} within 60s (last position: {:?})",
                                    device_id, position, last_position
                                ),
                            ));
                        }
                        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "Native filter wheel not connected",
                ))
            }
            DriverType::Alpaca => {
                let wheels = self.alpaca_filter_wheels.read().await;
                if let Some(wheel) = wheels.get(device_id) {
                    return wheel
                        .set_position(position)
                        .await
                        .map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca filter wheel {} not found", device_id),
                ))
            }
            DriverType::Indi => {
                // Parse INDI device ID: indi:host:port:device_name
                let (host, port, device_name) = Self::parse_indi_device_id(device_id)
                    .map_err(DeviceOpError::invalid_device_id)?;
                let server_key = format!("{host}:{port}");

                let clients = self.indi_clients.read().await;
                if let Some(client) = clients.get(&server_key) {
                    let wheel = IndiFilterWheel::new(client.clone(), &device_name);
                    return wheel.set_position(position).await.map_err(|e| {
                        DeviceOpError::hardware(
                            Some(device_id.to_string()),
                            format!(
                                "Failed to set INDI filter wheel {} to slot {}: {}",
                                device_name, position, e
                            ),
                        )
                    });
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "INDI filter wheel not connected",
                ))
            }
            DriverType::Simulator => {
                use crate::device_manager::ops::sim_faults;
                // Injected driver errors fire before the connected gate; see
                // `sim_faults` for the key grammar.
                sim_faults::check("filterwheel.set_position")
                    .await
                    .map_err(|e| DeviceOpError::driver(e))?;
                let fw = crate::api::devices::simulation::get_sim_filterwheel();
                let mut fw = fw.write().await;
                if !fw.status.connected {
                    return Err(DeviceOpError::not_connected(
                        None,
                        crate::device_manager::ops::sim_gate::not_connected_filterwheel(),
                    ));
                }
                // A stalled wheel ACCEPTS the move and never arrives: the
                // command returns `Ok` and `position` keeps reporting where the
                // wheel actually is. This is the failure that silently labels
                // every subsequent frame with the wrong filter, and it is
                // invisible to any check that only looks at the return value.
                if sim_faults::is_stalled("filterwheel.set_position") {
                    return Ok(());
                }
                fw.status.position = position;
                Ok(())
            }
        }
    }

    pub async fn filter_wheel_get_position(&self, device_id: &str) -> Result<i32, DeviceOpError> {
        let driver_type = {
            let devices = self.devices.read().await;
            let info = devices
                .get(device_id)
                .map(|d| d.info.clone())
                .ok_or_else(|| DeviceOpError::device_not_found(device_id))?;
            info.driver_type
        }; // devices lock dropped here before acquiring other locks

        match driver_type {
            DriverType::Ascom => {
                #[cfg(windows)]
                {
                    let wheels = self.ascom_filter_wheels.read().await;
                    if let Some(wheel) = wheels.get(device_id) {
                        let wheel = wheel.read().await;
                        return wheel.get_position().await.map_err(DeviceOpError::driver);
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "ASCOM filter wheel not connected",
                ))
            }
            DriverType::Native => {
                let native_filter_wheels = self.native_filter_wheels.read().await;
                if let Some(wheel) = native_filter_wheels.get(device_id) {
                    return wheel.get_position().await.map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "Native filter wheel not connected",
                ))
            }
            DriverType::Alpaca => {
                let wheels = self.alpaca_filter_wheels.read().await;
                if let Some(wheel) = wheels.get(device_id) {
                    return wheel.position().await.map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca filter wheel {} not found", device_id),
                ))
            }
            DriverType::Indi => {
                // Parse INDI device ID: indi:host:port:device_name
                let (host, port, device_name) = Self::parse_indi_device_id(device_id)
                    .map_err(DeviceOpError::invalid_device_id)?;
                let server_key = format!("{host}:{port}");

                let clients = self.indi_clients.read().await;
                if let Some(client) = clients.get(&server_key) {
                    let wheel = IndiFilterWheel::new(client.clone(), &device_name);
                    return wheel.get_position().await.map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "INDI filter wheel not connected",
                ))
            }
            DriverType::Simulator => {
                let sim = crate::device_manager::ops::sim_gate::read_filterwheel_status().await?;
                Ok(sim.position)
            }
        }
    }

    /// Resolve motion state for a background poll that already read Position.
    ///
    /// ASCOM defines `Position == -1` as the in-motion signal, so one Position
    /// read supplies both values. Keeping that read single is important for
    /// drivers such as the ZWO EFW ASCOM driver, where Position can be an
    /// expensive or persistently failing COM property in headless sessions.
    /// Other driver families retain their dedicated motion query.
    pub async fn filter_wheel_poll_is_moving(
        &self,
        device_id: &str,
        position: i32,
    ) -> Result<bool, DeviceOpError> {
        let driver_type = {
            let devices = self.devices.read().await;
            let info = devices
                .get(device_id)
                .map(|d| d.info.clone())
                .ok_or_else(|| DeviceOpError::device_not_found(device_id))?;
            info.driver_type
        };

        if matches!(driver_type, DriverType::Ascom) {
            Ok(position == -1)
        } else {
            self.filter_wheel_is_moving(device_id).await
        }
    }

    pub async fn filter_wheel_is_moving(&self, device_id: &str) -> Result<bool, DeviceOpError> {
        let driver_type = {
            let devices = self.devices.read().await;
            let info = devices
                .get(device_id)
                .map(|d| d.info.clone())
                .ok_or_else(|| DeviceOpError::device_not_found(device_id))?;
            info.driver_type
        }; // devices lock dropped here

        match driver_type {
            DriverType::Ascom => {
                #[cfg(windows)]
                {
                    let wheels = self.ascom_filter_wheels.read().await;
                    if let Some(wheel) = wheels.get(device_id) {
                        let wheel = wheel.read().await;
                        return wheel.is_moving().await.map_err(DeviceOpError::driver);
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "ASCOM filter wheel not connected",
                ))
            }
            DriverType::Native => {
                let native_filter_wheels = self.native_filter_wheels.read().await;
                if let Some(wheel) = native_filter_wheels.get(device_id) {
                    return wheel.is_moving().await.map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "Native filter wheel not connected",
                ))
            }
            DriverType::Alpaca => {
                let wheels = self.alpaca_filter_wheels.read().await;
                if let Some(wheel) = wheels.get(device_id) {
                    // Alpaca filter wheels return -1 for position when moving
                    let pos = wheel.position().await?;
                    return Ok(pos == -1);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca filter wheel {} not found", device_id),
                ))
            }
            DriverType::Indi => {
                // Parse INDI device ID: indi:host:port:device_name
                let (host, port, device_name) = Self::parse_indi_device_id(device_id)
                    .map_err(DeviceOpError::invalid_device_id)?;
                let server_key = format!("{host}:{port}");

                let clients = self.indi_clients.read().await;
                if let Some(client) = clients.get(&server_key) {
                    let locked = client.read().await;
                    // INDI uses property busy state to indicate movement
                    return Ok(locked.is_property_busy(&device_name, "FILTER_SLOT").await);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "INDI filter wheel not connected",
                ))
            }
            DriverType::Simulator => {
                let sim = crate::device_manager::ops::sim_gate::read_filterwheel_status().await?;
                Ok(sim.moving)
            }
        }
    }

    pub async fn filter_wheel_get_config(
        &self,
        device_id: &str,
    ) -> Result<(i32, Vec<String>), DeviceOpError> {
        tracing::debug!(
            "filter_wheel_get_config: Looking up device_id='{}'",
            device_id
        );

        let devices = self.devices.read().await;
        let device_keys: Vec<_> = devices.keys().collect();
        tracing::debug!(
            "filter_wheel_get_config: Available devices in registry: {:?}",
            device_keys
        );

        let info = devices
            .get(device_id)
            .map(|d| d.info.clone())
            .ok_or_else(|| DeviceOpError::device_not_found(device_id))?;
        tracing::debug!(
            "filter_wheel_get_config: Found device with driver_type={:?}",
            info.driver_type
        );
        drop(devices); // Release the lock before async operations

        match info.driver_type {
            DriverType::Ascom => {
                #[cfg(windows)]
                {
                    let wheels = self.ascom_filter_wheels.read().await;
                    let ascom_keys: Vec<_> = wheels.keys().collect();
                    tracing::debug!(
                        "filter_wheel_get_config: Looking for '{}' in ascom_filter_wheels: {:?}",
                        device_id,
                        ascom_keys
                    );

                    if let Some(wheel) = wheels.get(device_id) {
                        let wheel = wheel.read().await;
                        let names = wheel
                            .get_filter_names()
                            .await
                            .map_err(DeviceOpError::driver)?;
                        let count = names.len() as i32;
                        return Ok((count, names));
                    }
                    tracing::error!("filter_wheel_get_config: ASCOM filter wheel '{}' not found in ascom_filter_wheels map!", device_id);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "ASCOM filter wheel not connected",
                ))
            }
            DriverType::Alpaca => {
                let wheels = self.alpaca_filter_wheels.read().await;
                if let Some(wheel) = wheels.get(device_id) {
                    let names = wheel.names().await?;
                    let count = names.len() as i32;
                    return Ok((count, names));
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca filter wheel {} not found", device_id),
                ))
            }
            DriverType::Indi => {
                // Parse INDI device ID: indi:host:port:device_name
                if let Ok((host, port, device_name)) = Self::parse_indi_device_id(device_id) {
                    let server_key = format!("{host}:{port}");

                    let clients = self.indi_clients.read().await;
                    if let Some(client) = clients.get(&server_key) {
                        let wheel = IndiFilterWheel::new(client.clone(), &device_name);
                        // Report a read failure as a read failure. Collapsing it to
                        // an empty list made the CALLERS misdiagnose it: they answer
                        // "Filter 'Ha' not found in the connected wheel" (or "no
                        // configured name for position N"), sending the operator off
                        // to reconfigure their filter wheel when the actual problem
                        // is the INDI connection. The failure was already loud —
                        // just attributed to the wrong cause.
                        let names = wheel.get_names().await.map_err(|e| {
                            DeviceOpError::hardware(
                                Some(device_id.to_string()),
                                format!(
                                    "Failed to read INDI filter names for {}: {}",
                                    device_name, e
                                ),
                            )
                        })?;
                        let count = names.len() as i32;
                        return Ok((count, names));
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "INDI filter wheel not connected",
                ))
            }
            DriverType::Native => {
                let native_filter_wheels = self.native_filter_wheels.read().await;
                let native_keys: Vec<_> = native_filter_wheels.keys().collect();
                tracing::debug!(
                    "filter_wheel_get_config: Looking for '{}' in native_filter_wheels: {:?}",
                    device_id,
                    native_keys
                );

                if let Some(wheel) = native_filter_wheels.get(device_id) {
                    let count = wheel.get_filter_count();
                    let names = wheel
                        .get_filter_names()
                        .await
                        .map_err(DeviceOpError::driver)?;
                    // debug, not info: filter status is POLLED continuously by
                    // the dashboard/companions, so an INFO per call is pure spam.
                    tracing::debug!(
                        "filter_wheel_get_config: Returning {} filter names: {:?}",
                        count,
                        names
                    );
                    return Ok((count, names));
                }
                // debug, not error: querying a wheel that is not (or no longer)
                // connected is a normal state, the typed `not_connected` error
                // below is what reports it, and ERROR here floods the log every
                // poll cycle for as long as the wheel stays disconnected.
                tracing::debug!(
                    "filter_wheel_get_config: Native filter wheel '{}' not in native_filter_wheels map (not connected)",
                    device_id
                );
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "Native filter wheel not connected",
                ))
            }
            DriverType::Simulator => {
                let sim = crate::device_manager::ops::sim_gate::read_filterwheel_status().await?;
                Ok((sim.filter_count, sim.filter_names))
            }
        }
    }

    /// Set filter names on a filter wheel.
    /// This pushes user-defined filter names from the equipment profile to the hardware driver.
    pub async fn filter_wheel_set_filter_names(
        &self,
        device_id: &str,
        names: Vec<String>,
    ) -> Result<(), DeviceOpError> {
        let devices = self.devices.read().await;
        let info = devices
            .get(device_id)
            .map(|d| d.info.clone())
            .ok_or_else(|| DeviceOpError::device_not_found(device_id))?;
        drop(devices);

        tracing::info!(
            "filter_wheel_set_filter_names: Setting filter names for '{}': {:?}",
            device_id,
            names
        );

        match info.driver_type {
            DriverType::Native => {
                let mut native_filter_wheels = self.native_filter_wheels.write().await;
                if let Some(wheel) = native_filter_wheels.get_mut(device_id) {
                    for (i, name) in names.iter().enumerate() {
                        wheel
                            .set_filter_name(i as i32, name.clone())
                            .await
                            .map_err(DeviceOpError::driver)?;
                    }
                    tracing::info!(
                        "filter_wheel_set_filter_names: Successfully set {} filter names",
                        names.len()
                    );
                    return Ok(());
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "Native filter wheel not connected",
                ))
            }
            DriverType::Ascom => {
                // ASCOM filter names are typically stored in the driver's configuration
                // Many ASCOM drivers don't support programmatic name setting
                let msg = "ASCOM filter names are managed by the driver and cannot be set programmatically";
                tracing::warn!("filter_wheel_set_filter_names: {}", msg);
                Err(DeviceOpError::unsupported(msg))
            }
            DriverType::Alpaca => {
                // Alpaca filter names are typically read-only from the driver
                let msg = "Alpaca filter names are read-only and cannot be set programmatically";
                tracing::warn!("filter_wheel_set_filter_names: {}", msg);
                Err(DeviceOpError::unsupported(msg))
            }
            DriverType::Indi => {
                // INDI filter names can be set via FILTER_NAME property
                let msg = "INDI filter name setting is unavailable in this manager path";
                tracing::warn!("filter_wheel_set_filter_names: {}", msg);
                Err(DeviceOpError::unsupported(msg))
            }
            DriverType::Simulator => {
                let fw = crate::api::devices::simulation::get_sim_filterwheel();
                let mut fw = fw.write().await;
                if !fw.status.connected {
                    return Err(DeviceOpError::not_connected(
                        None,
                        crate::device_manager::ops::sim_gate::not_connected_filterwheel(),
                    ));
                }
                // Only overwrite up to the existing slot count — matches the
                // simulator-side semantics in
                // `api::devices::simulation::api_filterwheel_set_filter_names`.
                let count = fw.status.filter_names.len().min(names.len());
                for (i, name) in names.iter().take(count).enumerate() {
                    fw.status.filter_names[i] = name.clone();
                }
                Ok(())
            }
        }
    }
}
