//! ASCOM Filter Wheel wrapper and batch status types.

use crate::com::ComDispatch;
use crate::error::AscomResult;
use crate::health::ConnectionHealth;

/// ASCOM Filter Wheel
pub struct FilterWheel<D> {
    pub(crate) device: D,
}

#[cfg(windows)]
impl FilterWheel<crate::windows::AscomDeviceConnection> {
    pub fn new(prog_id: &str) -> AscomResult<Self> {
        Ok(Self {
            device: crate::windows::AscomDeviceConnection::new(prog_id)?,
        })
    }
}

impl<D: ComDispatch> FilterWheel<D> {
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
        let pos = self.device.get("Position");
        tracing::info!("ASCOM FilterWheel.Position returned: {:?}", pos);
        pos
    }

    pub fn set_position(&mut self, position: i32) -> AscomResult<()> {
        tracing::info!("ASCOM FilterWheel.SetPosition({})", position);
        self.device.put("Position", position)
    }

    pub fn names(&self) -> AscomResult<Vec<String>> {
        self.device.get("Names")
    }

    /// Per-filter focus offsets in focuser steps (IFilterWheelV2 `FocusOffsets`).
    pub fn focus_offsets(&self) -> AscomResult<Vec<i32>> {
        self.device.get("FocusOffsets")
    }

    // Batch property queries

    /// Get complete filter wheel status in a single batch operation
    pub fn get_full_status(&self) -> FilterWheelFullStatus {
        FilterWheelFullStatus {
            position: self.position().ok(),
            names: self.names().ok(),
            focus_offsets: self.focus_offsets().ok(),
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

/// Full filter wheel status
#[derive(Debug, Clone, Default)]
pub struct FilterWheelFullStatus {
    pub position: Option<i32>,
    pub names: Option<Vec<String>>,
    pub focus_offsets: Option<Vec<i32>>,
}

#[cfg(test)]
mod tests {
    use super::FilterWheelFullStatus;

    #[test]
    fn full_status_carries_focus_offsets_when_present() {
        let status = FilterWheelFullStatus {
            position: Some(2),
            names: Some(vec!["L".into(), "R".into(), "G".into()]),
            focus_offsets: Some(vec![0, 120, 240]),
        };

        assert_eq!(
            status.focus_offsets.as_deref(),
            Some([0, 120, 240].as_slice())
        );
        assert_eq!(status.names.as_ref().map(Vec::len), Some(3));
    }

    #[test]
    fn full_status_leaves_focus_offsets_none_on_read_failure() {
        let status = FilterWheelFullStatus {
            position: Some(0),
            names: Some(vec!["Ha".into()]),
            focus_offsets: None,
        };

        assert!(status.focus_offsets.is_none());
    }
}
