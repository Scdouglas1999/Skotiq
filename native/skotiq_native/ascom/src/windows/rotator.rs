//! ASCOM Rotator wrapper and batch status types.

use super::connection::AscomDeviceConnection;
use super::health::ConnectionHealth;

/// ASCOM Rotator
pub struct AscomRotator {
    device: AscomDeviceConnection,
}

impl AscomRotator {
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

    pub fn position(&self) -> Result<f64, String> {
        self.device.get_double_property("Position")
    }

    pub fn mechanical_position(&self) -> Result<f64, String> {
        self.device.get_double_property("MechanicalPosition")
    }

    pub fn is_moving(&self) -> Result<bool, String> {
        self.device.get_bool_property("IsMoving")
    }

    /// Whether the rotator can reverse direction (IRotatorV3 `CanReverse`).
    pub fn can_reverse(&self) -> Result<bool, String> {
        self.device.get_bool_property("CanReverse")
    }

    /// Current reverse setting (IRotatorV3 `Reverse`).
    pub fn reverse(&self) -> Result<bool, String> {
        self.device.get_bool_property("Reverse")
    }

    /// Set reverse direction (IRotatorV3 `Reverse` write).
    pub fn set_reverse(&mut self, reverse: bool) -> Result<(), String> {
        self.device.set_bool_property("Reverse", reverse)
    }

    /// Target position in degrees (IRotatorV3 `TargetPosition`).
    pub fn target_position(&self) -> Result<f64, String> {
        self.device.get_double_property("TargetPosition")
    }

    /// Minimum step size in degrees (IRotatorV3 `StepSize`).
    pub fn step_size(&self) -> Result<f64, String> {
        self.device.get_double_property("StepSize")
    }

    pub fn move_to(&mut self, position: f64) -> Result<(), String> {
        self.device.call_method_1_double("Move", position)
    }

    pub fn move_absolute(&mut self, position: f64) -> Result<(), String> {
        self.device.call_method_1_double("MoveAbsolute", position)
    }

    pub fn halt(&mut self) -> Result<(), String> {
        self.device.call_method("Halt")
    }

    /// Sync the reported position to the supplied angle without rotating the
    /// hardware. Why a thin wrapper: ASCOM IRotatorV3 exposes `Sync(Position)`
    /// which adjusts the offset between the mechanical encoder and the
    /// reported sky angle — the same primitive plate-solve "sync to image PA"
    /// needs.
    pub fn sync(&mut self, position: f64) -> Result<(), String> {
        self.device.call_method_1_double("Sync", position)
    }

    // Batch property queries

    /// Get complete rotator status in a single batch operation
    pub fn get_full_status(&self) -> RotatorFullStatus {
        RotatorFullStatus {
            name: self.name().ok(),
            position: self.position().ok(),
            mechanical_position: self.mechanical_position().ok(),
            target_position: self.target_position().ok(),
            step_size: self.step_size().ok(),
            is_moving: self.is_moving().ok(),
            can_reverse: self.can_reverse().ok(),
            reverse: self.reverse().ok(),
        }
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

/// Full rotator status
#[derive(Debug, Clone, Default)]
pub struct RotatorFullStatus {
    pub name: Option<String>,
    pub position: Option<f64>,
    pub mechanical_position: Option<f64>,
    pub target_position: Option<f64>,
    pub step_size: Option<f64>,
    pub is_moving: Option<bool>,
    pub can_reverse: Option<bool>,
    pub reverse: Option<bool>,
}

#[cfg(test)]
mod tests {
    use super::RotatorFullStatus;

    #[test]
    fn full_status_includes_v3_fields() {
        let status = RotatorFullStatus {
            name: Some("Field Rotator".into()),
            position: Some(45.0),
            mechanical_position: Some(44.5),
            target_position: Some(90.0),
            step_size: Some(0.1),
            is_moving: Some(true),
            can_reverse: Some(true),
            reverse: Some(false),
        };

        assert_eq!(status.name.as_deref(), Some("Field Rotator"));
        assert_eq!(status.target_position, Some(90.0));
        assert_eq!(status.step_size, Some(0.1));
        assert_eq!(status.can_reverse, Some(true));
        assert_eq!(status.reverse, Some(false));
    }
}
