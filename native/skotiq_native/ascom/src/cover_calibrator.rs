//! ASCOM Cover Calibrator wrapper and batch status types.

use crate::com::ComDispatch;
use crate::error::AscomResult;
use crate::health::ConnectionHealth;

/// ASCOM Cover Calibrator
pub struct CoverCalibrator<D> {
    pub(crate) device: D,
}

#[cfg(windows)]
impl CoverCalibrator<crate::windows::AscomDeviceConnection> {
    pub fn new(prog_id: &str) -> AscomResult<Self> {
        Ok(Self {
            device: crate::windows::AscomDeviceConnection::new(prog_id)?,
        })
    }
}

impl<D: ComDispatch> CoverCalibrator<D> {
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

    pub fn cover_state(&self) -> AscomResult<i32> {
        self.device.get("CoverState")
    }

    pub fn calibrator_state(&self) -> AscomResult<i32> {
        self.device.get("CalibratorState")
    }

    pub fn brightness(&self) -> AscomResult<i32> {
        self.device.get("Brightness")
    }

    pub fn set_brightness(&mut self, brightness: i32) -> AscomResult<()> {
        self.device.put("Brightness", brightness)
    }

    pub fn max_brightness(&self) -> AscomResult<i32> {
        self.device.get("MaxBrightness")
    }

    pub fn open_cover(&mut self) -> AscomResult<()> {
        self.device.call("OpenCover", &[])
    }

    pub fn close_cover(&mut self) -> AscomResult<()> {
        self.device.call("CloseCover", &[])
    }

    pub fn halt_cover(&mut self) -> AscomResult<()> {
        self.device.call("HaltCover", &[])
    }

    pub fn calibrator_on(&mut self, brightness: i32) -> AscomResult<()> {
        self.device.call("CalibratorOn", &[brightness.into()])
    }

    pub fn calibrator_off(&mut self) -> AscomResult<()> {
        self.device.call("CalibratorOff", &[])
    }

    // Batch property queries

    /// Get complete cover calibrator status in a single batch operation
    pub fn get_full_status(&self) -> CoverCalibratorFullStatus {
        CoverCalibratorFullStatus {
            cover_state: self.cover_state().ok(),
            calibrator_state: self.calibrator_state().ok(),
            brightness: self.brightness().ok(),
            max_brightness: self.max_brightness().ok(),
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

/// Full cover calibrator status
#[derive(Debug, Clone, Default)]
pub struct CoverCalibratorFullStatus {
    /// Cover state (0=NotPresent, 1=Closed, 2=Moving, 3=Open, 4=Unknown, 5=Error)
    pub cover_state: Option<i32>,
    /// Calibrator state (0=NotPresent, 1=Off, 2=NotReady, 3=Ready, 4=Unknown, 5=Error)
    pub calibrator_state: Option<i32>,
    pub brightness: Option<i32>,
    pub max_brightness: Option<i32>,
}

/// `CalibratorOn` must pass an `EXCEPINFO` to `IDispatch::Invoke`. Without it
/// a flat panel that refuses a brightness — the usual reason a flat sequence
/// stalls — can only say `0x80020009`.
#[cfg(all(test, windows))]
mod excepinfo_tests {
    use super::*;
    use crate::windows::connection::excepinfo_recovery_tests::{connection, Excuse};

    #[test]
    fn a_refused_calibrator_brightness_says_why() {
        let (device, _) = connection(
            Excuse::Spoken {
                source: "ASCOM.FlatPanel.CoverCalibrator",
                description: "Brightness 5000 exceeds MaxBrightness",
                scode: 0x8004_0402_u32 as i32,
            },
            false,
        );
        let mut panel = CoverCalibrator { device };

        let err = panel.calibrator_on(5000).unwrap_err().to_string();

        assert!(
            err.contains("Brightness 5000 exceeds MaxBrightness"),
            "CalibratorOn dropped the driver's description: {err}"
        );
        assert!(
            !err.contains("Exception occurred"),
            "fell back to the bare HRESULT: {err}"
        );
    }
}
