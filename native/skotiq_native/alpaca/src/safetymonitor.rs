//! Alpaca Safety Monitor API implementation
//!
//! The Safety Monitor interface provides a way to check if observing conditions
//! are safe for operation. This is typically used to check weather conditions,
//! power status, or other safety-critical parameters.

use crate::AlpacaError;

alpaca_device!(AlpacaSafetyMonitor, SafetyMonitor);

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
}
