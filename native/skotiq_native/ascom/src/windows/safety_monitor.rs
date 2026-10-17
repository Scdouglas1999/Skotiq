//! ASCOM Safety Monitor wrapper and batch status types.

use super::connection::AscomDeviceConnection;
use super::health::ConnectionHealth;

/// ASCOM Safety Monitor
pub struct AscomSafetyMonitor {
    device: AscomDeviceConnection,
}

impl AscomSafetyMonitor {
    pub fn new(prog_id: &str) -> Result<Self, String> {
        Ok(Self {
            device: AscomDeviceConnection::new(prog_id)?,
        })
    }

    pub fn connect(&mut self) -> Result<(), String> {
        self.device.connect()
    }

    pub fn disconnect(&mut self) -> Result<(), String> {
        self.device.disconnect()
    }

    /// Query the underlying ASCOM driver for its current `Connected` state.
    ///
    /// Used by capability probes that must NOT kick an active UI connection:
    /// if the driver reports `Ok(true)`, the probe reuses the connection
    /// instead of opening/closing its own session.
    pub fn is_connected(&self) -> Result<bool, String> {
        self.device.is_connected()
    }

    pub fn name(&self) -> Result<String, String> {
        self.device.get_string_property("Name")
    }

    /// Get the interface version number
    pub fn interface_version(&self) -> Result<i32, String> {
        self.device.get_int_property("InterfaceVersion")
    }

    /// Get the driver version string
    pub fn driver_version(&self) -> Result<String, String> {
        self.device.get_string_property("DriverVersion")
    }

    /// Get the driver info/description
    pub fn driver_info(&self) -> Result<String, String> {
        self.device.get_string_property("DriverInfo")
    }

    /// Get the list of supported custom actions
    pub fn supported_actions(&self) -> Result<Vec<String>, String> {
        self.device.get_string_array_property("SupportedActions")
    }

    pub fn is_safe(&self) -> Result<bool, String> {
        self.device.get_bool_property("IsSafe")
    }

    // Batch property queries

    /// Get complete safety monitor status in a single batch operation
    pub fn get_full_status(&self) -> Result<SafetyMonitorFullStatus, String> {
        SafetyMonitorFullStatus::from_is_safe_result(self.is_safe())
    }

    /// Perform a heartbeat check to verify device is still responding
    pub fn heartbeat(&self) -> Result<(), String> {
        self.device.heartbeat()
    }

    /// Get connection health status
    pub fn get_health(&self) -> ConnectionHealth {
        self.device.get_health()
    }
}

/// Full safety monitor status
#[derive(Debug, Clone, Default)]
pub struct SafetyMonitorFullStatus {
    pub is_safe: Option<bool>,
}

impl SafetyMonitorFullStatus {
    fn from_is_safe_result(is_safe: Result<bool, String>) -> Result<Self, String> {
        Ok(Self {
            is_safe: Some(is_safe?),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::SafetyMonitorFullStatus;

    #[test]
    fn full_status_preserves_is_safe_value() {
        let status = SafetyMonitorFullStatus::from_is_safe_result(Ok(true))
            .expect("successful IsSafe query should build status");

        assert_eq!(status.is_safe, Some(true));
    }

    #[test]
    fn full_status_propagates_is_safe_error() {
        let err = SafetyMonitorFullStatus::from_is_safe_result(Err(
            "ASCOM IsSafe COM failure".to_string()
        ))
        .expect_err("IsSafe failures must not be swallowed into None");

        assert!(
            err.contains("ASCOM IsSafe COM failure"),
            "full status should return the original driver error: {}",
            err
        );
    }
}
