//! An ASCOM dome (`IDomeV3`) over COM. What a status read means is decided by
//! `skotiq_device::ascom::dome`, the same as for an Alpaca dome.

use super::sta_device::{driver_error, sta_accessory, StaDevice};
use crate::device_capabilities::DomeCapabilities;
use crate::device_manager::accessory::{dome_capabilities, Dome};
use crate::device_manager::handle::device_error;
use crate::dispatch::DeviceOpError;
use crate::error::SkotiqError;
use crate::timeout_ops::Timeouts;
use async_trait::async_trait;
use skotiq_ascom::AscomDome;
use skotiq_device::ascom::dome::{self, DomeMembers};
use skotiq_device::ascom::ShutterStatus;
use skotiq_device::{DomeDriver, DomeState, DriverError};

pub struct AscomDomeWrapper {
    device: StaDevice<AscomDome>,
}

impl AscomDomeWrapper {
    pub fn new(prog_id: String) -> Result<Self, String> {
        let (device, ()) = StaDevice::new("Dome", move || AscomDome::new(&prog_id), |_| ())?;
        Ok(Self { device })
    }

    pub async fn connect(&self) -> Result<(), DeviceOpError> {
        self.device
            .run("connect", Timeouts::connection(), |d| d.connect())
            .await
    }

    async fn read<T: Send + 'static>(
        &self,
        member: &str,
        call: impl FnOnce(&mut AscomDome) -> skotiq_ascom::AscomResult<T> + Send + 'static,
    ) -> Result<T, DriverError> {
        self.device
            .run(member, Timeouts::property_read(), call)
            .await
            .map_err(driver_error)
    }
}

sta_accessory!(AscomDomeWrapper);

#[async_trait]
impl DomeMembers for AscomDomeWrapper {
    async fn azimuth(&self) -> Result<f64, DriverError> {
        self.read("azimuth", |d| d.azimuth()).await
    }
    async fn altitude(&self) -> Result<f64, DriverError> {
        self.read("altitude", |d| d.altitude()).await
    }
    async fn at_home(&self) -> Result<bool, DriverError> {
        self.read("at_home", |d| d.at_home()).await
    }
    async fn at_park(&self) -> Result<bool, DriverError> {
        self.read("at_park", |d| d.at_park()).await
    }
    async fn shutter_status(&self) -> Result<ShutterStatus, DriverError> {
        self.read("shutter_status", |d| d.shutter_status())
            .await
            .map(ShutterStatus::from)
    }
    async fn slewing(&self) -> Result<bool, DriverError> {
        self.read("slewing", |d| d.slewing()).await
    }
    async fn slaved(&self) -> Result<bool, DriverError> {
        self.read("slaved", |d| d.slaved()).await
    }
    async fn can_find_home(&self) -> Result<bool, DriverError> {
        self.read("can_find_home", |d| d.can_find_home()).await
    }
    async fn can_park(&self) -> Result<bool, DriverError> {
        self.read("can_park", |d| d.can_park()).await
    }
    async fn can_set_altitude(&self) -> Result<bool, DriverError> {
        self.read("can_set_altitude", |d| d.can_set_altitude()).await
    }
    async fn can_set_azimuth(&self) -> Result<bool, DriverError> {
        self.read("can_set_azimuth", |d| d.can_set_azimuth()).await
    }
    async fn can_set_shutter(&self) -> Result<bool, DriverError> {
        self.read("can_set_shutter", |d| d.can_set_shutter()).await
    }
    async fn can_slave(&self) -> Result<bool, DriverError> {
        self.read("can_slave", |d| d.can_slave()).await
    }
    async fn can_sync_azimuth(&self) -> Result<bool, DriverError> {
        self.read("can_sync_azimuth", |d| d.can_sync_azimuth()).await
    }
}

#[async_trait]
impl DomeDriver for AscomDomeWrapper {
    async fn open_shutter(&self) -> Result<(), DriverError> {
        self.device
            .run("open_shutter", Timeouts::dome_shutter(), |d| d.open_shutter())
            .await
            .map_err(driver_error)
    }

    async fn close_shutter(&self) -> Result<(), DriverError> {
        self.device
            .run("close_shutter", Timeouts::dome_shutter(), |d| d.close_shutter())
            .await
            .map_err(driver_error)
    }

    async fn shutter_status(&self) -> Result<ShutterStatus, DriverError> {
        DomeMembers::shutter_status(self).await
    }

    async fn slew_to_azimuth(&self, azimuth_deg: f64) -> Result<(), DriverError> {
        let azimuth = dome::slew_azimuth(azimuth_deg)?;
        self.device
            .run("slew_to_azimuth", Timeouts::dome(), move |d| {
                d.slew_to_azimuth(azimuth)
            })
            .await
            .map_err(driver_error)
    }

    async fn abort_slew(&self) -> Result<(), DriverError> {
        self.device
            .run("abort_slew", Timeouts::dome(), |d| d.abort_slew())
            .await
            .map_err(driver_error)
    }

    async fn park(&self) -> Result<(), DriverError> {
        self.device
            .run("park", Timeouts::dome(), |d| d.park())
            .await
            .map_err(driver_error)
    }

    async fn find_home(&self) -> Result<(), DriverError> {
        self.device
            .run("find_home", Timeouts::find_home(), |d| d.find_home())
            .await
            .map_err(driver_error)
    }

    async fn set_slaved(&self, slaved: bool) -> Result<(), DriverError> {
        self.device
            .run("set_slaved", Timeouts::property_write(), move |d| {
                d.set_slaved(slaved)
            })
            .await
            .map_err(driver_error)
    }

    async fn status(&self) -> Result<DomeState, DriverError> {
        Ok(dome::report(self).await?.state)
    }
}

#[async_trait]
impl Dome for AscomDomeWrapper {
    async fn capabilities(&self, device_id: &str) -> Result<DomeCapabilities, SkotiqError> {
        let report = dome::report(self)
            .await
            .map_err(|e| SkotiqError::from(device_error(device_id, e)))?;
        Ok(dome_capabilities(report))
    }
}
