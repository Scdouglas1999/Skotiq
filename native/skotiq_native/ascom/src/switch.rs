//! ASCOM Switch wrapper and batch status types.

use crate::com::ComDispatch;
use crate::error::AscomResult;
use crate::health::ConnectionHealth;

/// ASCOM Switch
pub struct Switch<D> {
    pub(crate) device: D,
}

#[cfg(windows)]
impl Switch<crate::windows::AscomDeviceConnection> {
    pub fn new(prog_id: &str) -> AscomResult<Self> {
        Ok(Self {
            device: crate::windows::AscomDeviceConnection::new(prog_id)?,
        })
    }
}

impl<D: ComDispatch> Switch<D> {
    /// Wrap a connection that already exists.
    pub fn over(device: D) -> Self {
        Self { device }
    }

    pub fn connect(&mut self) -> AscomResult<()> {
        self.device.connect()
    }

    pub fn disconnect(&mut self) -> AscomResult<()> {
        self.device.disconnect()
    }

    /// Query the underlying ASCOM driver for its current `Connected` state.
    ///
    /// Used by capability probes that must NOT kick an active UI connection:
    /// if the driver reports `Ok(true)`, the probe reuses the connection
    /// instead of opening/closing its own session.
    pub fn is_connected(&self) -> AscomResult<bool> {
        self.device.get("Connected")
    }

    pub fn name(&self) -> AscomResult<String> {
        self.device.get("Name")
    }

    /// Get the interface version number
    pub fn interface_version(&self) -> AscomResult<i32> {
        self.device.get("InterfaceVersion")
    }

    /// Get the driver version string
    pub fn driver_version(&self) -> AscomResult<String> {
        self.device.get("DriverVersion")
    }

    /// Get the driver info/description
    pub fn driver_info(&self) -> AscomResult<String> {
        self.device.get("DriverInfo")
    }

    /// Get the list of supported custom actions
    pub fn supported_actions(&self) -> AscomResult<Vec<String>> {
        self.device.get("SupportedActions")
    }

    pub fn max_switch(&self) -> AscomResult<i32> {
        self.device.get("MaxSwitch")
    }

    pub fn get_switch(&self, id: i32) -> AscomResult<bool> {
        self.device.call("GetSwitch", &[id.into()])
    }

    pub fn set_switch(&mut self, id: i32, state: bool) -> AscomResult<()> {
        self.device.call("SetSwitch", &[id.into(), state.into()])
    }

    pub fn get_switch_name(&self, id: i32) -> AscomResult<String> {
        self.device.call("GetSwitchName", &[id.into()])
    }

    pub fn get_switch_description(&self, id: i32) -> AscomResult<String> {
        self.device.call("GetSwitchDescription", &[id.into()])
    }

    pub fn get_switch_value(&self, id: i32) -> AscomResult<f64> {
        self.device.call("GetSwitchValue", &[id.into()])
    }

    pub fn set_switch_value(&mut self, id: i32, value: f64) -> AscomResult<()> {
        self.device
            .call("SetSwitchValue", &[id.into(), value.into()])
    }

    pub fn min_switch_value(&self, id: i32) -> AscomResult<f64> {
        self.device.call("MinSwitchValue", &[id.into()])
    }

    pub fn max_switch_value(&self, id: i32) -> AscomResult<f64> {
        self.device.call("MaxSwitchValue", &[id.into()])
    }

    pub fn switch_step(&self, id: i32) -> AscomResult<f64> {
        self.device.call("SwitchStep", &[id.into()])
    }

    pub fn can_write(&self, id: i32) -> AscomResult<bool> {
        self.device.call("CanWrite", &[id.into()])
    }

    // Batch property queries

    /// Get all switch channel telemetry in a single batch operation.
    ///
    /// Returns bool state, analog value, min/max, and step for switches `0..max_switch`.
    pub fn get_all_switch_states(&self) -> SwitchFullStatus {
        let max_switch = self.max_switch().ok();
        let mut channels = Vec::new();

        if let Some(max) = max_switch {
            for i in 0..max {
                channels.push(SwitchChannelState {
                    on: self.get_switch(i).ok(),
                    value: self.get_switch_value(i).ok(),
                    min_value: self.min_switch_value(i).ok(),
                    max_value: self.max_switch_value(i).ok(),
                    step: self.switch_step(i).ok(),
                });
            }
        }

        SwitchFullStatus {
            max_switch,
            channels,
        }
    }

    /// Perform a heartbeat check to verify device is still responding
    pub fn heartbeat(&self) -> AscomResult<()> {
        self.device.heartbeat()
    }

    /// Get connection health status
    pub fn get_health(&self) -> ConnectionHealth {
        self.device.health()
    }
}

/// Per-channel switch telemetry (ISwitchV2).
#[derive(Debug, Clone, Default, PartialEq)]
pub struct SwitchChannelState {
    pub on: Option<bool>,
    pub value: Option<f64>,
    pub min_value: Option<f64>,
    pub max_value: Option<f64>,
    pub step: Option<f64>,
}

/// Full switch status
#[derive(Debug, Clone, Default)]
pub struct SwitchFullStatus {
    pub max_switch: Option<i32>,
    pub channels: Vec<SwitchChannelState>,
}

#[cfg(test)]
mod tests {
    use super::{SwitchChannelState, SwitchFullStatus};

    #[test]
    fn channel_state_holds_pwm_fields() {
        let channel = SwitchChannelState {
            on: Some(true),
            value: Some(0.75),
            min_value: Some(0.0),
            max_value: Some(1.0),
            step: Some(0.05),
        };

        assert_eq!(channel.value, Some(0.75));
        assert_eq!(channel.step, Some(0.05));
    }

    #[test]
    fn full_status_aligns_channel_count_with_max_switch() {
        let status = SwitchFullStatus {
            max_switch: Some(2),
            channels: vec![
                SwitchChannelState {
                    on: Some(false),
                    value: Some(0.0),
                    min_value: Some(0.0),
                    max_value: Some(100.0),
                    step: Some(5.0),
                },
                SwitchChannelState {
                    on: Some(true),
                    value: Some(50.0),
                    min_value: Some(0.0),
                    max_value: Some(100.0),
                    step: Some(5.0),
                },
            ],
        };

        assert_eq!(status.max_switch, Some(2));
        assert_eq!(status.channels.len(), 2);
        assert_eq!(status.channels[1].value, Some(50.0));
    }
}

/// All ten `ISwitch` members must pass an `EXCEPINFO` to `IDispatch::Invoke`.
/// A switch powers the mount and the dew heaters, so "why did the port refuse"
/// is exactly the sentence an operator needs.
#[cfg(all(test, windows))]
mod excepinfo_tests {
    use super::*;
    use crate::windows::connection::excepinfo_recovery_tests::{connection, Excuse};

    fn refusing_switch() -> Switch<crate::windows::AscomDeviceConnection> {
        let (device, _) = connection(
            Excuse::Spoken {
                source: "ASCOM.PegasusAstro.UPBv2.Switch",
                description: "Switch 3 is read-only",
                scode: 0x8004_0403_u32 as i32,
            },
            false,
        );
        Switch { device }
    }

    #[test]
    fn a_refused_switch_write_says_why() {
        let mut sw = refusing_switch();

        for (label, err) in [
            ("SetSwitch", sw.set_switch(3, true).unwrap_err().to_string()),
            (
                "SetSwitchValue",
                sw.set_switch_value(3, 1.0).unwrap_err().to_string(),
            ),
        ] {
            assert!(
                err.contains("Switch 3 is read-only"),
                "{label} dropped the driver's description: {err}"
            );
            assert!(
                !err.contains("Exception occurred"),
                "{label} fell back to the bare HRESULT: {err}"
            );
        }
    }

    #[test]
    fn a_refused_switch_read_says_why() {
        let sw = refusing_switch();

        for (label, err) in [
            ("GetSwitch", sw.get_switch(3).unwrap_err().to_string()),
            (
                "GetSwitchName",
                sw.get_switch_name(3).unwrap_err().to_string(),
            ),
            (
                "GetSwitchValue",
                sw.get_switch_value(3).unwrap_err().to_string(),
            ),
            ("CanWrite", sw.can_write(3).unwrap_err().to_string()),
        ] {
            assert!(
                err.contains("Switch 3 is read-only"),
                "{label} dropped the driver's description: {err}"
            );
        }
    }
}
