//! ASCOM Dome wrapper and batch status types.

use super::connection::AscomDeviceConnection;
use super::health::ConnectionHealth;

/// ASCOM Dome
pub struct AscomDome {
    device: AscomDeviceConnection,
}

impl AscomDome {
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

    /// Open the dome shutter
    pub fn open_shutter(&self) -> Result<(), String> {
        self.device.call_method("OpenShutter")
    }

    /// Close the dome shutter
    pub fn close_shutter(&self) -> Result<(), String> {
        self.device.call_method("CloseShutter")
    }

    /// Park the dome
    pub fn park(&self) -> Result<(), String> {
        self.device.call_method("Park")
    }

    /// Get shutter status (0=Open, 1=Closed, 2=Opening, 3=Closing, 4=Error)
    pub fn shutter_status(&self) -> Result<i32, String> {
        self.device.get_int_property("ShutterStatus")
    }

    /// Check if dome is at park position
    pub fn at_park(&self) -> Result<bool, String> {
        self.device.get_bool_property("AtPark")
    }

    /// Check if dome is slewing
    pub fn slewing(&self) -> Result<bool, String> {
        self.device.get_bool_property("Slewing")
    }

    /// Get the dome azimuth in degrees
    pub fn azimuth(&self) -> Result<f64, String> {
        self.device.get_double_property("Azimuth")
    }

    /// Slew dome to the specified azimuth in degrees
    pub fn slew_to_azimuth(&self, azimuth: f64) -> Result<(), String> {
        self.device.call_method_1_double("SlewToAzimuth", azimuth)
    }

    /// Abort current dome slew
    pub fn abort_slew(&self) -> Result<(), String> {
        self.device.call_method("AbortSlew")
    }

    /// Find the dome home position
    pub fn find_home(&self) -> Result<(), String> {
        self.device.call_method("FindHome")
    }

    /// Enable or disable slaving to the mount
    pub fn set_slaved(&self, slaved: bool) -> Result<(), String> {
        self.device
            .set_bool_property("Slaved", slaved)
            .map_err(|e| format!("Failed to set ASCOM dome Slaved: {}", e))
    }

    // Batch property queries

    /// Get complete dome status in a single batch operation
    pub fn get_full_status(&self) -> DomeFullStatus {
        DomeFullStatus {
            shutter_status: self.shutter_status().ok(),
            azimuth: self.azimuth().ok(),
            slewing: self.slewing().ok(),
            at_park: self.at_park().ok(),
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

/// Full dome status
#[derive(Debug, Clone, Default)]
pub struct DomeFullStatus {
    /// Shutter status (0=Open, 1=Closed, 2=Opening, 3=Closing, 4=Error)
    pub shutter_status: Option<i32>,
    pub azimuth: Option<f64>,
    pub slewing: Option<bool>,
    pub at_park: Option<bool>,
}
