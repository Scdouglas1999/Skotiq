//! ASCOM Focuser wrapper and batch status types.

use crate::com::ComDispatch;
use crate::error::AscomResult;
use crate::health::ConnectionHealth;

/// ASCOM Focuser
pub struct Focuser<D> {
    pub(crate) device: D,
}

#[cfg(windows)]
impl Focuser<crate::windows::AscomDeviceConnection> {
    pub fn new(prog_id: &str) -> AscomResult<Self> {
        Ok(Self {
            device: crate::windows::AscomDeviceConnection::new(prog_id)?,
        })
    }
}

impl<D: ComDispatch> Focuser<D> {
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

    pub fn position(&self) -> AscomResult<i32> {
        self.device.get("Position")
    }

    pub fn max_step(&self) -> AscomResult<i32> {
        self.device.get("MaxStep")
    }

    pub fn max_increment(&self) -> AscomResult<i32> {
        self.device.get("MaxIncrement")
    }

    pub fn step_size(&self) -> AscomResult<f64> {
        self.device.get("StepSize")
    }

    pub fn is_moving(&self) -> AscomResult<bool> {
        self.device.get("IsMoving")
    }

    pub fn absolute(&self) -> AscomResult<bool> {
        self.device.get("Absolute")
    }

    pub fn temp_comp(&self) -> AscomResult<bool> {
        self.device.get("TempComp")
    }

    pub fn set_temp_comp(&mut self, value: bool) -> AscomResult<()> {
        self.device.put("TempComp", value)
    }

    pub fn temp_comp_available(&self) -> AscomResult<bool> {
        self.device.get("TempCompAvailable")
    }

    pub fn temperature(&self) -> AscomResult<f64> {
        self.device.get("Temperature")
    }

    pub fn move_to(&mut self, position: i32) -> AscomResult<()> {
        self.device.call("Move", &[position.into()])
    }

    pub fn halt(&mut self) -> AscomResult<()> {
        self.device.call("Halt", &[])
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
    pub fn heartbeat(&self) -> AscomResult<()> {
        self.device.heartbeat()
    }

    /// Get connection health status
    pub fn get_health(&self) -> ConnectionHealth {
        self.device.health()
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
