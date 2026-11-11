//! ASCOM Dome wrapper and batch status types.

use crate::com::ComDispatch;
use crate::error::{AscomError, AscomResult};
use crate::health::ConnectionHealth;

/// ASCOM Dome
pub struct Dome<D> {
    pub(crate) device: D,
}

#[cfg(windows)]
impl Dome<crate::windows::AscomDeviceConnection> {
    pub fn new(prog_id: &str) -> AscomResult<Self> {
        Ok(Self {
            device: crate::windows::AscomDeviceConnection::new(prog_id)?,
        })
    }
}

impl<D: ComDispatch> Dome<D> {
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

    /// Open the dome shutter
    pub fn open_shutter(&self) -> AscomResult<()> {
        self.device.call("OpenShutter", &[])
    }

    /// Close the dome shutter
    pub fn close_shutter(&self) -> AscomResult<()> {
        self.device.call("CloseShutter", &[])
    }

    /// Park the dome
    pub fn park(&self) -> AscomResult<()> {
        self.device.call("Park", &[])
    }

    /// Get shutter status (0=Open, 1=Closed, 2=Opening, 3=Closing, 4=Error)
    pub fn shutter_status(&self) -> AscomResult<i32> {
        self.device.get("ShutterStatus")
    }

    /// Check if dome is at park position
    pub fn at_park(&self) -> AscomResult<bool> {
        self.device.get("AtPark")
    }

    /// Check if dome is slewing
    pub fn slewing(&self) -> AscomResult<bool> {
        self.device.get("Slewing")
    }

    /// Get the dome azimuth in degrees
    pub fn azimuth(&self) -> AscomResult<f64> {
        self.device.get("Azimuth")
    }

    /// Slew dome to the specified azimuth in degrees
    pub fn slew_to_azimuth(&self, azimuth: f64) -> AscomResult<()> {
        self.device.call("SlewToAzimuth", &[azimuth.into()])
    }

    /// Abort current dome slew
    pub fn abort_slew(&self) -> AscomResult<()> {
        self.device.call("AbortSlew", &[])
    }

    /// Find the dome home position
    pub fn find_home(&self) -> AscomResult<()> {
        self.device.call("FindHome", &[])
    }

    /// Enable or disable slaving to the mount
    pub fn set_slaved(&self, slaved: bool) -> AscomResult<()> {
        self.device
            .put("Slaved", slaved)
            .map_err(|e| AscomError::Context {
                context: "Failed to set ASCOM dome Slaved",
                source: Box::new(e),
            })
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
    pub fn heartbeat(&self) -> AscomResult<()> {
        self.device.heartbeat()
    }

    /// Get connection health status
    pub fn get_health(&self) -> ConnectionHealth {
        self.device.health()
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
