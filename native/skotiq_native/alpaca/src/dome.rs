//! Alpaca Dome API implementation

use crate::AlpacaError;
use skotiq_device::ascom::ShutterStatus;

alpaca_device!(AlpacaDome, Dome);

impl AlpacaDome {
    skotiq_device::ascom_dome_members!(alpaca_member);

    /// Get comprehensive dome status
    pub async fn get_status(&self) -> Result<DomeStatus, AlpacaError> {
        let (shutter_status, azimuth, altitude, slewing, at_home, at_park, slaved) = tokio::join!(
            self.shutter_status(),
            self.azimuth(),
            self.altitude(),
            self.slewing(),
            self.at_home(),
            self.at_park(),
            self.slaved()
        );

        Ok(DomeStatus {
            shutter_status: shutter_status?,
            azimuth: azimuth?,
            altitude: altitude.ok(),
            slewing: slewing?,
            at_home: at_home?,
            at_park: at_park?,
            slaved: slaved?,
        })
    }
}

#[derive(Debug, Clone)]
pub struct DomeStatus {
    pub shutter_status: ShutterStatus,
    pub azimuth: f64,
    pub altitude: Option<f64>,
    pub slewing: bool,
    pub at_home: bool,
    pub at_park: bool,
    pub slaved: bool,
}
