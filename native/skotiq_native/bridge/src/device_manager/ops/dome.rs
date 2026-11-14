//! Dome operations.

use crate::device::{DeviceType, DomeStatus, ShutterState};
use crate::device_manager::handle::device_error;
use crate::device_manager::DeviceManager;
use crate::dispatch::error::DeviceOpError;
use skotiq_device::ascom::ShutterStatus;

use crate::device_manager::ops::state_events::property;

impl DeviceManager {
    // Dome commands publish the command the dome accepted (see
    // `state_events`); the dome status polling reports when it arrives.

    pub async fn dome_open_shutter(&self, device_id: &str) -> Result<(), DeviceOpError> {
        self.dome_open_shutter_dispatch(device_id).await?;
        self.publish_dome(device_id, property::DOME_SHUTTER, "open".to_string());
        Ok(())
    }

    pub async fn dome_close_shutter(&self, device_id: &str) -> Result<(), DeviceOpError> {
        self.dome_close_shutter_dispatch(device_id).await?;
        self.publish_dome(device_id, property::DOME_SHUTTER, "close".to_string());
        Ok(())
    }

    /// Slew the dome to an azimuth in degrees.
    pub async fn dome_slew_to_azimuth(
        &self,
        device_id: &str,
        azimuth: f64,
    ) -> Result<(), DeviceOpError> {
        self.dome_slew_to_azimuth_dispatch(device_id, azimuth)
            .await?;
        self.publish_dome(device_id, property::DOME_SLEW, azimuth.to_string());
        Ok(())
    }

    pub async fn dome_park(&self, device_id: &str) -> Result<(), DeviceOpError> {
        self.dome_park_dispatch(device_id).await?;
        self.publish_dome(device_id, property::DOME_PARK, String::new());
        Ok(())
    }

    /// Slave the dome to the mount, or release it.
    pub async fn dome_set_slaved(
        &self,
        device_id: &str,
        slaved: bool,
    ) -> Result<(), DeviceOpError> {
        self.dome_set_slaved_dispatch(device_id, slaved).await?;
        self.publish_dome(device_id, property::DOME_SLAVED, slaved.to_string());
        Ok(())
    }

    /// Send the dome to its home position.
    pub async fn dome_find_home(&self, device_id: &str) -> Result<(), DeviceOpError> {
        self.dome_find_home_dispatch(device_id).await?;
        self.publish_dome(device_id, property::DOME_HOME, String::new());
        Ok(())
    }

    /// Stop any dome motion.
    pub async fn dome_abort_slew(&self, device_id: &str) -> Result<(), DeviceOpError> {
        self.dome_abort_slew_dispatch(device_id).await?;
        self.publish_dome(device_id, property::DOME_ABORT, String::new());
        Ok(())
    }

    fn publish_dome(&self, device_id: &str, property: &str, value: String) {
        self.publish_property_changed(DeviceType::Dome, device_id, property, value);
    }
}

impl DeviceManager {
    async fn dome_open_shutter_dispatch(&self, device_id: &str) -> Result<(), DeviceOpError> {
        self.dome(device_id)
            .await?
            .open_shutter()
            .await
            .map_err(|e| device_error(device_id, e))
    }

    async fn dome_close_shutter_dispatch(&self, device_id: &str) -> Result<(), DeviceOpError> {
        self.dome(device_id)
            .await?
            .close_shutter()
            .await
            .map_err(|e| device_error(device_id, e))
    }

    async fn dome_slew_to_azimuth_dispatch(
        &self,
        device_id: &str,
        azimuth: f64,
    ) -> Result<(), DeviceOpError> {
        self.dome(device_id)
            .await?
            .slew_to_azimuth(azimuth)
            .await
            .map_err(|e| device_error(device_id, e))
    }

    async fn dome_park_dispatch(&self, device_id: &str) -> Result<(), DeviceOpError> {
        self.dome(device_id)
            .await?
            .park()
            .await
            .map_err(|e| device_error(device_id, e))
    }

    async fn dome_set_slaved_dispatch(
        &self,
        device_id: &str,
        slaved: bool,
    ) -> Result<(), DeviceOpError> {
        self.dome(device_id)
            .await?
            .set_slaved(slaved)
            .await
            .map_err(|e| device_error(device_id, e))
    }

    async fn dome_find_home_dispatch(&self, device_id: &str) -> Result<(), DeviceOpError> {
        self.dome(device_id)
            .await?
            .find_home()
            .await
            .map_err(|e| device_error(device_id, e))
    }

    async fn dome_abort_slew_dispatch(&self, device_id: &str) -> Result<(), DeviceOpError> {
        self.dome(device_id)
            .await?
            .abort_slew()
            .await
            .map_err(|e| device_error(device_id, e))
    }

    /// The ASCOM `ShutterState` number.
    pub async fn dome_get_shutter_status(&self, device_id: &str) -> Result<i32, DeviceOpError> {
        let status = self
            .dome(device_id)
            .await?
            .shutter_status()
            .await
            .map_err(|e| device_error(device_id, e))?;
        Ok(status as i32)
    }

    pub async fn dome_get_status(&self, device_id: &str) -> Result<DomeStatus, DeviceOpError> {
        let state = self
            .dome(device_id)
            .await?
            .status()
            .await
            .map_err(|e| device_error(device_id, e))?;
        Ok(DomeStatus {
            connected: true,
            azimuth: state.azimuth,
            altitude: state.altitude,
            shutter_status: match state.shutter {
                Some(ShutterStatus::Open) => ShutterState::Open,
                Some(ShutterStatus::Closed) => ShutterState::Closed,
                Some(ShutterStatus::Opening) => ShutterState::Opening,
                Some(ShutterStatus::Closing) => ShutterState::Closing,
                Some(ShutterStatus::Error) => ShutterState::Error,
                None => ShutterState::Unknown,
            },
            slewing: state.slewing,
            at_home: state.at_home,
            at_park: state.at_park,
            can_set_altitude: state.can_set_altitude,
            can_set_azimuth: state.can_set_azimuth,
            can_set_shutter: state.can_set_shutter,
            can_slave: state.can_slave,
            is_slaved: state.slaved,
        })
    }
}
