//! ASCOM Focuser wrapper and batch status types.

use super::connection::AscomDeviceConnection;
use super::health::ConnectionHealth;

/// ASCOM Focuser
pub struct AscomFocuser {
    device: AscomDeviceConnection,
}

impl AscomFocuser {
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

    pub fn position(&self) -> Result<i32, String> {
        self.device.get_int_property("Position")
    }

    pub fn max_step(&self) -> Result<i32, String> {
        self.device.get_int_property("MaxStep")
    }

    pub fn max_increment(&self) -> Result<i32, String> {
        self.device.get_int_property("MaxIncrement")
    }

    pub fn step_size(&self) -> Result<f64, String> {
        self.device.get_double_property("StepSize")
    }

    pub fn is_moving(&self) -> Result<bool, String> {
        self.device.get_bool_property("IsMoving")
    }

    pub fn absolute(&self) -> Result<bool, String> {
        self.device.get_bool_property("Absolute")
    }

    pub fn temp_comp(&self) -> Result<bool, String> {
        self.device.get_bool_property("TempComp")
    }

    pub fn set_temp_comp(&mut self, value: bool) -> Result<(), String> {
        self.device.set_bool_property("TempComp", value)
    }

    pub fn temp_comp_available(&self) -> Result<bool, String> {
        self.device.get_bool_property("TempCompAvailable")
    }

    pub fn temperature(&self) -> Result<f64, String> {
        self.device.get_double_property("Temperature")
    }

    pub fn move_to(&mut self, position: i32) -> Result<(), String> {
        self.device.call_method_1_int("Move", position)
    }

    pub fn halt(&mut self) -> Result<(), String> {
        self.device.call_method("Halt")
    }

    // Batch property queries

    /// Get focuser capabilities in a single batch operation
    pub fn get_capabilities(&self) -> FocuserCapabilities {
        FocuserCapabilities {
            absolute: self.absolute().ok(),
            max_step: self.max_step().ok(),
            max_increment: self.max_increment().ok(),
            step_size: self.step_size().ok(),
            temp_comp_available: self.temp_comp_available().ok(),
        }
    }

    /// Get complete focuser status in a single batch operation
    pub fn get_full_status(&self) -> FocuserFullStatus {
        FocuserFullStatus {
            position: self.position().ok(),
            is_moving: self.is_moving().ok(),
            temperature: self.temperature().ok(),
            temp_comp: self.temp_comp().ok(),
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

/// Focuser capabilities
#[derive(Debug, Clone, Default)]
pub struct FocuserCapabilities {
    pub absolute: Option<bool>,
    pub max_step: Option<i32>,
    pub max_increment: Option<i32>,
    pub step_size: Option<f64>,
    pub temp_comp_available: Option<bool>,
}

/// Full focuser status
#[derive(Debug, Clone, Default)]
pub struct FocuserFullStatus {
    pub position: Option<i32>,
    pub is_moving: Option<bool>,
    pub temperature: Option<f64>,
    pub temp_comp: Option<bool>,
}
