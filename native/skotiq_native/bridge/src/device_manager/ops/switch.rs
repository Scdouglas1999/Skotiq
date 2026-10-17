//! Switch device operations dispatcher.
//!
//! Methods in this module are an additional impl block on `DeviceManager`
//! using Rust's split-impl-block feature. Behavior is identical to the
//! previous monolithic `devices.rs`.
//!
//! # Simulator arm
//!
//! Every `DriverType::Simulator` arm delegates to
//! [`crate::api::devices::simulation`], which models a powerbox: switched
//! outputs, PWM dew channels and read-only voltage/current sensors. The
//! read-only channels are why it is not a bag of writable booleans — with
//! everything writable, `switch_can_write` could only ever answer `true` and
//! the UI's read-only rendering would ship unexercised.

use crate::api::devices::simulation as sim;
use crate::device::*;
use crate::device_manager::DeviceManager;
use crate::dispatch::DeviceOpError;

impl DeviceManager {
    // INDI switch helpers

    // indi_get_all_switches / indi_get_switch_at moved to
    // `crate::dispatch::indi`; call sites use `self.indi_*` unchanged.

    // Switch control

    /// Get the number of switches exposed by a switch device
    pub async fn switch_get_max(&self, device_id: &str) -> Result<i32, DeviceOpError> {
        let devices = self.devices.read().await;
        let info = devices
            .get(device_id)
            .map(|d| d.info.clone())
            .ok_or_else(|| DeviceOpError::device_not_found(device_id))?;

        match info.driver_type {
            DriverType::Ascom => {
                #[cfg(windows)]
                {
                    let switches = self.ascom_switches.read().await;
                    if let Some(sw) = switches.get(device_id) {
                        let sw = sw.read().await;
                        return sw.get_max_switch().await.map_err(DeviceOpError::driver);
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("ASCOM switch {} not found", device_id),
                ))
            }
            DriverType::Alpaca => {
                let switches = self.alpaca_switches.read().await;
                if let Some(sw) = switches.get(device_id) {
                    return sw.max_switch().await.map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca switch {} not found", device_id),
                ))
            }
            DriverType::Indi => {
                // INDI switches use named properties -- enumerate and count them
                let switches = self.indi_get_all_switches(device_id).await?;
                // Why: INDI switch counts are tiny (a
                // power-box has ≤ a dozen outputs); usize → i32 SAFE for
                // any realistic device.
                Ok(i32::try_from(switches.len()).unwrap_or(i32::MAX))
            }
            DriverType::Native => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                format!("Native switch {} not found", device_id),
            )),
            DriverType::Simulator => sim::sim_switch_count().await.map_err(DeviceOpError::from),
        }
    }

    /// Get the boolean state of a switch
    pub async fn switch_get_state(
        &self,
        device_id: &str,
        switch_id: i32,
    ) -> Result<bool, DeviceOpError> {
        let devices = self.devices.read().await;
        let info = devices
            .get(device_id)
            .map(|d| d.info.clone())
            .ok_or_else(|| DeviceOpError::device_not_found(device_id))?;

        match info.driver_type {
            DriverType::Ascom => {
                #[cfg(windows)]
                {
                    let switches = self.ascom_switches.read().await;
                    if let Some(sw) = switches.get(device_id) {
                        let sw = sw.read().await;
                        return sw
                            .get_switch(switch_id)
                            .await
                            .map_err(DeviceOpError::driver);
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("ASCOM switch {} not found", device_id),
                ))
            }
            DriverType::Alpaca => {
                let switches = self.alpaca_switches.read().await;
                if let Some(sw) = switches.get(device_id) {
                    return sw
                        .get_switch(switch_id)
                        .await
                        .map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca switch {} not found", device_id),
                ))
            }
            DriverType::Indi => {
                let sw = self.indi_get_switch_at(device_id, switch_id).await?;
                Ok(sw.state)
            }
            DriverType::Native => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                format!("Native switch {} not found", device_id),
            )),
            DriverType::Simulator => sim::sim_switch_read(switch_id)
                .await
                .map(|reading| reading.state)
                .map_err(DeviceOpError::from),
        }
    }

    /// Set the boolean state of a switch
    pub async fn switch_set_state(
        &self,
        device_id: &str,
        switch_id: i32,
        state: bool,
    ) -> Result<(), DeviceOpError> {
        let devices = self.devices.read().await;
        let info = devices
            .get(device_id)
            .map(|d| d.info.clone())
            .ok_or_else(|| DeviceOpError::device_not_found(device_id))?;

        match info.driver_type {
            DriverType::Ascom => {
                #[cfg(windows)]
                {
                    let switches = self.ascom_switches.read().await;
                    if let Some(sw) = switches.get(device_id) {
                        let mut sw = sw.write().await;
                        return sw
                            .set_switch(switch_id, state)
                            .await
                            .map_err(DeviceOpError::driver);
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("ASCOM switch {} not found", device_id),
                ))
            }
            DriverType::Alpaca => {
                let switches = self.alpaca_switches.read().await;
                if let Some(sw) = switches.get(device_id) {
                    return sw
                        .set_switch(switch_id, state)
                        .await
                        .map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca switch {} not found", device_id),
                ))
            }
            DriverType::Indi => {
                let sw = self.indi_get_switch_at(device_id, switch_id).await?;
                if !sw.writable {
                    return Err(DeviceOpError::unsupported(format!(
                        "INDI switch '{}' / '{}' is read-only",
                        sw.property_name, sw.element_name
                    )));
                }
                let (host, port, device_name) = Self::parse_indi_device_id(device_id)?;
                let server_key = format!("{}:{}", host, port);
                let clients = self.indi_clients.read().await;
                if let Some(client) = clients.get(&server_key) {
                    let switch_dev =
                        skotiq_indi::IndiSwitchDevice::new(client.clone(), &device_name);
                    return switch_dev
                        .set_switch_state(&sw.property_name, &sw.element_name, state)
                        .await
                        .map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "INDI switch device not connected",
                ))
            }
            DriverType::Native => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                format!("Native switch {} not found", device_id),
            )),
            DriverType::Simulator => sim::sim_switch_write_state(switch_id, state)
                .await
                .map_err(DeviceOpError::from),
        }
    }

    /// Get the name of a switch
    pub async fn switch_get_name(
        &self,
        device_id: &str,
        switch_id: i32,
    ) -> Result<String, DeviceOpError> {
        let devices = self.devices.read().await;
        let info = devices
            .get(device_id)
            .map(|d| d.info.clone())
            .ok_or_else(|| DeviceOpError::device_not_found(device_id))?;

        match info.driver_type {
            DriverType::Ascom => {
                #[cfg(windows)]
                {
                    let switches = self.ascom_switches.read().await;
                    if let Some(sw) = switches.get(device_id) {
                        let sw = sw.read().await;
                        return sw
                            .get_switch_name(switch_id)
                            .await
                            .map_err(DeviceOpError::driver);
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("ASCOM switch {} not found", device_id),
                ))
            }
            DriverType::Alpaca => {
                let switches = self.alpaca_switches.read().await;
                if let Some(sw) = switches.get(device_id) {
                    return sw
                        .get_switch_name(switch_id)
                        .await
                        .map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca switch {} not found", device_id),
                ))
            }
            DriverType::Indi => {
                let sw = self.indi_get_switch_at(device_id, switch_id).await?;
                Ok(sw.element_name.clone())
            }
            DriverType::Native => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                format!("Native switch {} not found", device_id),
            )),
            DriverType::Simulator => sim::sim_switch_read(switch_id)
                .await
                .map(|reading| reading.name)
                .map_err(DeviceOpError::from),
        }
    }

    /// Get the description of a switch
    pub async fn switch_get_description(
        &self,
        device_id: &str,
        switch_id: i32,
    ) -> Result<String, DeviceOpError> {
        let devices = self.devices.read().await;
        let info = devices
            .get(device_id)
            .map(|d| d.info.clone())
            .ok_or_else(|| DeviceOpError::device_not_found(device_id))?;

        match info.driver_type {
            DriverType::Ascom => {
                #[cfg(windows)]
                {
                    let switches = self.ascom_switches.read().await;
                    if let Some(sw) = switches.get(device_id) {
                        let sw = sw.read().await;
                        return sw
                            .get_switch_description(switch_id)
                            .await
                            .map_err(DeviceOpError::driver);
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("ASCOM switch {} not found", device_id),
                ))
            }
            DriverType::Alpaca => {
                let switches = self.alpaca_switches.read().await;
                if let Some(sw) = switches.get(device_id) {
                    return sw
                        .get_switch_description(switch_id)
                        .await
                        .map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca switch {} not found", device_id),
                ))
            }
            DriverType::Indi => {
                let sw = self.indi_get_switch_at(device_id, switch_id).await?;
                // For INDI, description is "property_name / label"
                Ok(format!("{} / {}", sw.property_name, sw.label))
            }
            DriverType::Native => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                format!("Native switch {} not found", device_id),
            )),
            DriverType::Simulator => sim::sim_switch_read(switch_id)
                .await
                .map(|reading| reading.description)
                .map_err(DeviceOpError::from),
        }
    }

    /// Get the numeric value of a switch
    pub async fn switch_get_value(
        &self,
        device_id: &str,
        switch_id: i32,
    ) -> Result<f64, DeviceOpError> {
        let devices = self.devices.read().await;
        let info = devices
            .get(device_id)
            .map(|d| d.info.clone())
            .ok_or_else(|| DeviceOpError::device_not_found(device_id))?;

        match info.driver_type {
            DriverType::Ascom => {
                #[cfg(windows)]
                {
                    let switches = self.ascom_switches.read().await;
                    if let Some(sw) = switches.get(device_id) {
                        let sw = sw.read().await;
                        return sw
                            .get_switch_value(switch_id)
                            .await
                            .map_err(DeviceOpError::driver);
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("ASCOM switch {} not found", device_id),
                ))
            }
            DriverType::Alpaca => {
                let switches = self.alpaca_switches.read().await;
                if let Some(sw) = switches.get(device_id) {
                    return sw
                        .get_switch_value(switch_id)
                        .await
                        .map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca switch {} not found", device_id),
                ))
            }
            DriverType::Indi => {
                let sw = self.indi_get_switch_at(device_id, switch_id).await?;
                // INDI switches can have associated number values (e.g., PWM duty cycle)
                let (host, port, device_name) = Self::parse_indi_device_id(device_id)
                    .map_err(DeviceOpError::invalid_device_id)?;
                let server_key = format!("{host}:{port}");
                let clients = self.indi_clients.read().await;
                if let Some(client) = clients.get(&server_key) {
                    let switch_dev =
                        skotiq_indi::IndiSwitchDevice::new(client.clone(), &device_name);
                    if let Some(val) = switch_dev
                        .get_switch_value(&sw.property_name, &sw.element_name)
                        .await
                    {
                        return Ok(val);
                    }
                    // If no numeric value, return 1.0 for on, 0.0 for off
                    return Ok(if sw.state { 1.0 } else { 0.0 });
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "INDI switch device not connected",
                ))
            }
            DriverType::Native => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                format!("Native switch {} not found", device_id),
            )),
            DriverType::Simulator => sim::sim_switch_read(switch_id)
                .await
                .map(|reading| reading.value)
                .map_err(DeviceOpError::from),
        }
    }

    /// Set the numeric value of a switch
    pub async fn switch_set_value(
        &self,
        device_id: &str,
        switch_id: i32,
        value: f64,
    ) -> Result<(), DeviceOpError> {
        let devices = self.devices.read().await;
        let info = devices
            .get(device_id)
            .map(|d| d.info.clone())
            .ok_or_else(|| DeviceOpError::device_not_found(device_id))?;

        match info.driver_type {
            DriverType::Ascom => {
                #[cfg(windows)]
                {
                    let switches = self.ascom_switches.read().await;
                    if let Some(sw) = switches.get(device_id) {
                        let mut sw = sw.write().await;
                        return sw
                            .set_switch_value(switch_id, value)
                            .await
                            .map_err(DeviceOpError::driver);
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("ASCOM switch {} not found", device_id),
                ))
            }
            DriverType::Alpaca => {
                let switches = self.alpaca_switches.read().await;
                if let Some(sw) = switches.get(device_id) {
                    return sw
                        .set_switch_value(switch_id, value)
                        .await
                        .map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca switch {} not found", device_id),
                ))
            }
            DriverType::Indi => {
                let sw = self.indi_get_switch_at(device_id, switch_id).await?;
                if !sw.writable {
                    return Err(DeviceOpError::unsupported(format!(
                        "INDI switch '{}' / '{}' is read-only",
                        sw.property_name, sw.element_name
                    )));
                }
                let (host, port, device_name) = Self::parse_indi_device_id(device_id)?;
                let server_key = format!("{}:{}", host, port);
                let clients = self.indi_clients.read().await;
                if let Some(client) = clients.get(&server_key) {
                    let switch_dev =
                        skotiq_indi::IndiSwitchDevice::new(client.clone(), &device_name);
                    return switch_dev
                        .set_switch_value(&sw.property_name, &sw.element_name, value)
                        .await
                        .map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "INDI switch device not connected",
                ))
            }
            DriverType::Native => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                format!("Native switch {} not found", device_id),
            )),
            DriverType::Simulator => sim::sim_switch_write_value(switch_id, value)
                .await
                .map_err(DeviceOpError::from),
        }
    }

    /// Get the minimum value for a switch
    pub async fn switch_get_min_value(
        &self,
        device_id: &str,
        switch_id: i32,
    ) -> Result<f64, DeviceOpError> {
        let devices = self.devices.read().await;
        let info = devices
            .get(device_id)
            .map(|d| d.info.clone())
            .ok_or_else(|| DeviceOpError::device_not_found(device_id))?;

        match info.driver_type {
            DriverType::Ascom => {
                #[cfg(windows)]
                {
                    let switches = self.ascom_switches.read().await;
                    if let Some(sw) = switches.get(device_id) {
                        let sw = sw.read().await;
                        return sw
                            .get_min_switch_value(switch_id)
                            .await
                            .map_err(DeviceOpError::driver);
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("ASCOM switch {} not found", device_id),
                ))
            }
            DriverType::Alpaca => {
                let switches = self.alpaca_switches.read().await;
                if let Some(sw) = switches.get(device_id) {
                    return sw
                        .min_switch_value(switch_id)
                        .await
                        .map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca switch {} not found", device_id),
                ))
            }
            DriverType::Indi => {
                // INDI boolean switches have min 0.0
                Ok(0.0)
            }
            DriverType::Native => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                format!("Native switch {} not found", device_id),
            )),
            DriverType::Simulator => sim::sim_switch_read(switch_id)
                .await
                .map(|reading| reading.min)
                .map_err(DeviceOpError::from),
        }
    }

    /// Get the maximum value for a switch
    pub async fn switch_get_max_value(
        &self,
        device_id: &str,
        switch_id: i32,
    ) -> Result<f64, DeviceOpError> {
        let devices = self.devices.read().await;
        let info = devices
            .get(device_id)
            .map(|d| d.info.clone())
            .ok_or_else(|| DeviceOpError::device_not_found(device_id))?;

        match info.driver_type {
            DriverType::Ascom => {
                #[cfg(windows)]
                {
                    let switches = self.ascom_switches.read().await;
                    if let Some(sw) = switches.get(device_id) {
                        let sw = sw.read().await;
                        return sw
                            .get_max_switch_value(switch_id)
                            .await
                            .map_err(DeviceOpError::driver);
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("ASCOM switch {} not found", device_id),
                ))
            }
            DriverType::Alpaca => {
                let switches = self.alpaca_switches.read().await;
                if let Some(sw) = switches.get(device_id) {
                    return sw
                        .max_switch_value(switch_id)
                        .await
                        .map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca switch {} not found", device_id),
                ))
            }
            DriverType::Indi => {
                // INDI boolean switches have max 1.0
                Ok(1.0)
            }
            DriverType::Native => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                format!("Native switch {} not found", device_id),
            )),
            DriverType::Simulator => sim::sim_switch_read(switch_id)
                .await
                .map(|reading| reading.max)
                .map_err(DeviceOpError::from),
        }
    }

    /// Check if a switch can be written to
    pub async fn switch_can_write(
        &self,
        device_id: &str,
        switch_id: i32,
    ) -> Result<bool, DeviceOpError> {
        let devices = self.devices.read().await;
        let info = devices
            .get(device_id)
            .map(|d| d.info.clone())
            .ok_or_else(|| DeviceOpError::device_not_found(device_id))?;

        match info.driver_type {
            DriverType::Ascom => {
                #[cfg(windows)]
                {
                    let switches = self.ascom_switches.read().await;
                    if let Some(sw) = switches.get(device_id) {
                        let sw = sw.read().await;
                        return sw.can_write(switch_id).await.map_err(DeviceOpError::driver);
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("ASCOM switch {} not found", device_id),
                ))
            }
            DriverType::Alpaca => {
                let switches = self.alpaca_switches.read().await;
                if let Some(sw) = switches.get(device_id) {
                    return sw.can_write(switch_id).await.map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca switch {} not found", device_id),
                ))
            }
            DriverType::Indi => {
                let sw = self.indi_get_switch_at(device_id, switch_id).await?;
                Ok(sw.writable)
            }
            DriverType::Native => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                format!("Native switch {} not found", device_id),
            )),
            DriverType::Simulator => sim::sim_switch_read(switch_id)
                .await
                .map(|reading| reading.writable)
                .map_err(DeviceOpError::from),
        }
    }
}

/// The simulated powerbox, driven the way the app drives a real one.
///
/// Everything goes through discovery, `connect_device` and the real
/// `DeviceManager` methods rather than the simulator helpers, so the test
/// cannot pass against zero discoverable devices.
#[cfg(test)]
mod simulator_tests {
    use crate::api::devices::simulation::{reset_sim_switch, sim_singleton_test_lock};
    use crate::api::discovery::api_discover_devices;
    use crate::api::get_device_manager;
    use crate::device::{DeviceType, DriverType};
    use crate::device_manager::DeviceManager;
    use std::sync::Arc;
    use std::time::Duration;

    /// Channel indices of the simulated powerbox, mirroring `simulation.rs`.
    const QUAD_OUTPUT: i32 = 0;
    const DEW_HEATER_A: i32 = 3;
    const INPUT_VOLTAGE: i32 = 5;
    const TOTAL_CURRENT: i32 = 6;

    async fn connect_simulated_switch() -> (String, Arc<DeviceManager>) {
        reset_sim_switch().await;
        let devices = api_discover_devices(DeviceType::Switch)
            .await
            .expect("switch discovery should succeed");
        let info = devices
            .into_iter()
            .find(|d| d.driver_type == DriverType::Simulator)
            .expect(
                "discovery returned no simulated switch: power-switch flows cannot be exercised \
                 without hardware",
            );

        let device_id = info.id.clone();
        let manager = get_device_manager();
        manager.register_device(info, false).await;
        manager
            .connect_device(&device_id)
            .await
            .expect("the simulated switch should connect");
        (device_id, manager.clone())
    }

    async fn release_simulated_switch(manager: &Arc<DeviceManager>, device_id: &str) {
        manager
            .disconnect_device(device_id)
            .await
            .expect("the simulated switch should disconnect cleanly");
    }

    /// Sleep past the device's own status-poll latency so a commanded change is
    /// visible. Deliberately explicit at every call site: needing it IS the
    /// behaviour under test.
    async fn wait_for_settle() {
        tokio::time::sleep(Duration::from_millis(400)).await;
    }

    /// A powerbox exposes read-only sensor channels. If every channel were
    /// writable, `switch_can_write` could only ever answer `true` and both the
    /// read-only UI rendering and the driver's refusal would ship unexercised.
    #[tokio::test]
    async fn read_only_sensor_channels_refuse_writes() {
        let _serialized = sim_singleton_test_lock().lock().await;
        let (device_id, manager) = connect_simulated_switch().await;

        assert!(
            manager
                .switch_can_write(&device_id, QUAD_OUTPUT)
                .await
                .expect("can_write for the switched bank"),
            "the switched 12V bank must be writable"
        );
        assert!(
            !manager
                .switch_can_write(&device_id, INPUT_VOLTAGE)
                .await
                .expect("can_write for the voltage sensor"),
            "a voltage sensor advertised itself as writable"
        );

        let err = manager
            .switch_set_value(&device_id, INPUT_VOLTAGE, 12.0)
            .await
            .expect_err("writing a read-only sensor must be refused");
        assert!(
            err.to_string().contains("read-only"),
            "the refusal must say why: {err}"
        );

        release_simulated_switch(&manager, &device_id).await;
    }

    /// The sensor channels are derived from what is switched on, not stored.
    /// A constant current reading is a dial wired to nothing: it looks alive
    /// while responding to no action the app takes.
    #[tokio::test]
    async fn total_current_follows_what_is_switched_on() {
        let _serialized = sim_singleton_test_lock().lock().await;
        let (device_id, manager) = connect_simulated_switch().await;

        let read_current = || async {
            manager
                .switch_get_value(&device_id, TOTAL_CURRENT)
                .await
                .expect("current sensor should be readable")
        };
        let read_voltage = || async {
            manager
                .switch_get_value(&device_id, INPUT_VOLTAGE)
                .await
                .expect("voltage sensor should be readable")
        };

        let loaded_amps = read_current().await;
        let loaded_volts = read_voltage().await;

        manager
            .switch_set_state(&device_id, QUAD_OUTPUT, false)
            .await
            .expect("switching the bank off should be accepted");
        wait_for_settle().await;

        let idle_amps = read_current().await;
        assert!(
            idle_amps < loaded_amps,
            "switching the 12V bank off left the reported draw at {idle_amps}A \
             (was {loaded_amps}A) — the sensor is not wired to anything"
        );
        assert!(
            read_voltage().await > loaded_volts,
            "supply voltage did not recover when the load was removed"
        );

        // Dew heaters are a proportional load, so duty cycle has to move the
        // draw too — not just the on/off outputs.
        manager
            .switch_set_value(&device_id, DEW_HEATER_A, 100.0)
            .await
            .expect("dew heater duty should be settable");
        wait_for_settle().await;
        assert!(
            read_current().await > idle_amps + 1.0,
            "a dew heater at full duty added no measurable current"
        );

        release_simulated_switch(&manager, &device_id).await;
    }

    /// ASCOM `ISwitchV2` derives the boolean from the value: a channel reads
    /// `true` only when its value is in the upper half of its range. A dew
    /// heater at 30% is therefore `false`, and an app that trusts its own
    /// "I turned it on" flag will disagree with the hardware.
    #[tokio::test]
    async fn the_boolean_state_is_derived_from_the_value() {
        let _serialized = sim_singleton_test_lock().lock().await;
        let (device_id, manager) = connect_simulated_switch().await;

        manager
            .switch_set_value(&device_id, DEW_HEATER_A, 30.0)
            .await
            .expect("30% duty should be accepted");
        wait_for_settle().await;
        assert!(
            !manager
                .switch_get_state(&device_id, DEW_HEATER_A)
                .await
                .expect("dew heater state"),
            "a dew heater at 30% reported itself on"
        );

        manager
            .switch_set_value(&device_id, DEW_HEATER_A, 80.0)
            .await
            .expect("80% duty should be accepted");
        wait_for_settle().await;
        assert!(
            manager
                .switch_get_state(&device_id, DEW_HEATER_A)
                .await
                .expect("dew heater state"),
            "a dew heater at 80% reported itself off"
        );

        // And the boolean setter is defined in the same terms: off means the
        // channel's minimum, not a private flag left beside a stale value.
        manager
            .switch_set_state(&device_id, DEW_HEATER_A, false)
            .await
            .expect("turning the heater off should be accepted");
        wait_for_settle().await;
        let value = manager
            .switch_get_value(&device_id, DEW_HEATER_A)
            .await
            .expect("dew heater value");
        assert!(
            value.abs() < f64::EPSILON,
            "turning the channel off left its value at {value}"
        );

        release_simulated_switch(&manager, &device_id).await;
    }

    /// A real controller reports state from its own status poll, so a read
    /// issued straight after a write returns the PREVIOUS value. That race is
    /// where "toggle, re-read, watch the control snap back" bugs live, and an
    /// instantly-applied write can never produce it.
    #[tokio::test]
    async fn a_write_is_not_visible_until_the_device_polls() {
        let _serialized = sim_singleton_test_lock().lock().await;
        let (device_id, manager) = connect_simulated_switch().await;

        let before = manager
            .switch_get_state(&device_id, QUAD_OUTPUT)
            .await
            .expect("initial bank state");
        manager
            .switch_set_state(&device_id, QUAD_OUTPUT, !before)
            .await
            .expect("toggling the bank should be accepted");

        assert_eq!(
            manager
                .switch_get_state(&device_id, QUAD_OUTPUT)
                .await
                .expect("bank state immediately after the write"),
            before,
            "the commanded state appeared before the device had polled for it"
        );

        wait_for_settle().await;
        assert_eq!(
            manager
                .switch_get_state(&device_id, QUAD_OUTPUT)
                .await
                .expect("bank state after settling"),
            !before,
            "the commanded state never landed"
        );

        release_simulated_switch(&manager, &device_id).await;
    }

    /// An index outside `0..MaxSwitch` and a value outside a channel's range are
    /// both errors, not clamps. Clamping is how an app's off-by-one iteration or
    /// a percent-vs-volts mix-up survives a whole test suite.
    #[tokio::test]
    async fn out_of_range_indices_and_values_are_refused() {
        let _serialized = sim_singleton_test_lock().lock().await;
        let (device_id, manager) = connect_simulated_switch().await;

        let count = manager
            .switch_get_max(&device_id)
            .await
            .expect("switch count should be readable");
        assert!(count > 0, "the simulated powerbox exposes no channels");

        manager
            .switch_get_state(&device_id, count)
            .await
            .expect_err("one past the last channel must be refused");
        manager
            .switch_get_state(&device_id, -1)
            .await
            .expect_err("a negative index must be refused");
        // ... and every index the device advertises must actually resolve.
        for id in 0..count {
            manager
                .switch_get_name(&device_id, id)
                .await
                .unwrap_or_else(|e| panic!("advertised channel {id} is unreadable: {e}"));
        }

        let max = manager
            .switch_get_max_value(&device_id, DEW_HEATER_A)
            .await
            .expect("dew heater ceiling");
        manager
            .switch_set_value(&device_id, DEW_HEATER_A, max + 1.0)
            .await
            .expect_err("a duty cycle above the channel's ceiling must be refused");

        release_simulated_switch(&manager, &device_id).await;
    }

    /// A disconnected simulator must fail loudly rather than answering with
    /// synthetic state.
    #[tokio::test]
    async fn a_disconnected_switch_refuses_to_answer() {
        let _serialized = sim_singleton_test_lock().lock().await;
        let (device_id, manager) = connect_simulated_switch().await;
        release_simulated_switch(&manager, &device_id).await;

        let err = manager
            .switch_get_max(&device_id)
            .await
            .expect_err("a disconnected switch must not report a channel count");
        assert!(
            err.to_string().contains("not connected"),
            "the error must name the disconnection: {err}"
        );
    }
}
