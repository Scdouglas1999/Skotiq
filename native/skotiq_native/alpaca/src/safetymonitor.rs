//! Alpaca Safety Monitor API implementation
//!
//! The Safety Monitor interface provides a way to check if observing conditions
//! are safe for operation. This is typically used to check weather conditions,
//! power status, or other safety-critical parameters.

use crate::AlpacaError;

/// Safety monitor status aggregate for parallel status query
#[derive(Debug, Clone)]
pub struct SafetyMonitorStatus {
    pub connected: bool,
    pub is_safe: bool,
}

/// Safety monitor device information
#[derive(Debug, Clone)]
pub struct SafetyMonitorInfo {
    pub name: String,
    pub description: String,
    pub driver_version: String,
    pub driver_info: String,
    pub interface_version: i32,
}

alpaca_device!(
    /// Alpaca Safety Monitor client
    AlpacaSafetyMonitor,
    SafetyMonitor
);

impl AlpacaSafetyMonitor {
    skotiq_device::ascom_safety_monitor_members!(alpaca_member);

    // ASCOM common methods, implemented by every device

    /// Invoke a device-specific action
    ///
    /// # Arguments
    /// * `action_name` - The name of the action to invoke
    /// * `action_parameters` - Optional parameters for the action
    pub async fn action(
        &self,
        action_name: &str,
        action_parameters: &str,
    ) -> Result<String, AlpacaError> {
        self.client
            .put(
                "action",
                &[("Action", action_name), ("Parameters", action_parameters)],
            )
            .await
    }

    /// Send a command directly to the device
    ///
    /// # Arguments
    /// * `command` - The command string to send
    /// * `raw` - If true, the command is sent without interpretation
    pub async fn command_string(&self, command: &str, raw: bool) -> Result<String, AlpacaError> {
        self.client
            .put(
                "commandstring",
                &[("Command", command), ("Raw", &raw.to_string())],
            )
            .await
    }

    /// Send a blind command to the device (no response expected)
    ///
    /// # Arguments
    /// * `command` - The command string to send
    /// * `raw` - If true, the command is sent without interpretation
    pub async fn command_blind(&self, command: &str, raw: bool) -> Result<(), AlpacaError> {
        self.client
            .put(
                "commandblind",
                &[("Command", command), ("Raw", &raw.to_string())],
            )
            .await
    }

    /// Send a command and expect a boolean response
    ///
    /// # Arguments
    /// * `command` - The command string to send
    /// * `raw` - If true, the command is sent without interpretation
    pub async fn command_bool(&self, command: &str, raw: bool) -> Result<bool, AlpacaError> {
        self.client
            .put(
                "commandbool",
                &[("Command", command), ("Raw", &raw.to_string())],
            )
            .await
    }

    // Parallel status methods

    /// Get comprehensive safety monitor status in a single parallel query
    pub async fn get_status(&self) -> Result<SafetyMonitorStatus, AlpacaError> {
        let (connected, is_safe) = tokio::join!(self.is_connected(), self.is_safe(),);

        Ok(SafetyMonitorStatus {
            connected: connected?,
            is_safe: is_safe?,
        })
    }

    /// Get device information in a single parallel query
    pub async fn get_info(&self) -> Result<SafetyMonitorInfo, AlpacaError> {
        let (name, description, driver_version, driver_info, interface_version) = tokio::join!(
            self.name(),
            self.description(),
            self.driver_version(),
            self.driver_info(),
            self.interface_version(),
        );

        // Why: the four mandatory ASCOM identification
        // properties (`name`, `description`, `driverversion`, `interfaceversion`)
        // propagate via `?` — if any is missing the whole device-info read
        // fails. `driverinfo` is the only optional descriptor (ASCOM common
        // property `IDriverInfo.DriverInfo`); the spec lets drivers return
        // empty or omit it entirely, so the audit-flagged silent fallback to
        // an empty string here is the SPEC-MANDATED behavior. This is the
        // SafetyMonitor info-string only, NOT the IsSafe state (see
        // `is_safe_typed` above — that one fail-CLOSES via `?`).
        Ok(SafetyMonitorInfo {
            name: name?,
            description: description?,
            driver_version: driver_version?,
            driver_info: driver_info.unwrap_or_default(),
            interface_version: interface_version?,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_safety_monitor_status_struct() {
        let status = SafetyMonitorStatus {
            connected: true,
            is_safe: true,
        };
        assert!(status.connected);
        assert!(status.is_safe);
    }

    #[test]
    fn test_safety_monitor_info_struct() {
        let info = SafetyMonitorInfo {
            name: "Test Monitor".to_string(),
            description: "A test safety monitor".to_string(),
            driver_version: "1.0.0".to_string(),
            driver_info: "Test driver".to_string(),
            interface_version: 1,
        };
        assert_eq!(info.name, "Test Monitor");
        assert_eq!(info.interface_version, 1);
    }
}
