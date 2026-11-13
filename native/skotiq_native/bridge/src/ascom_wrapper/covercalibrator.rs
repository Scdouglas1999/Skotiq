//! An ASCOM cover calibrator (`ICoverCalibratorV2`) over COM. What a status
//! read means is decided by `skotiq_device::ascom::cover_calibrator`, the
//! same as for an Alpaca one.

use crate::ascom_wrapper::sta_device::{driver_error, sta_accessory, StaDevice};
use crate::dispatch::error::DeviceOpError;
use crate::timeout_ops::Timeouts;
use async_trait::async_trait;
use skotiq_ascom::{AscomCoverCalibrator, AscomResult};
use skotiq_device::ascom::{cover_calibrator, CalibratorStatus, CoverStatus};
use skotiq_device::{CoverCalibratorDriver, CoverCalibratorState, DriverError};
use std::time::Duration;

pub struct AscomCoverCalibratorWrapper {
    device: StaDevice<AscomCoverCalibrator>,
}

impl AscomCoverCalibratorWrapper {
    pub fn new(prog_id: String) -> Result<Self, String> {
        let (device, ()) = StaDevice::new(
            "CoverCalibrator",
            move || AscomCoverCalibrator::new(&prog_id),
            |_| (),
        )?;
        Ok(Self { device })
    }

    pub async fn connect(&self) -> Result<(), DeviceOpError> {
        self.device
            .run("connect", Timeouts::connection(), |d| d.connect())
            .await
    }

    async fn call<T: Send + 'static>(
        &self,
        member: &str,
        timeout: Duration,
        call: impl FnOnce(&mut AscomCoverCalibrator) -> AscomResult<T> + Send + 'static,
    ) -> Result<T, DriverError> {
        self.device
            .run(member, timeout, call)
            .await
            .map_err(driver_error)
    }
}

sta_accessory!(AscomCoverCalibratorWrapper);

#[async_trait]
impl CoverCalibratorDriver for AscomCoverCalibratorWrapper {
    async fn open_cover(&self) -> Result<(), DriverError> {
        self.call("open_cover", Timeouts::cover_calibrator(), |d| d.open_cover())
            .await
    }

    async fn close_cover(&self) -> Result<(), DriverError> {
        self.call("close_cover", Timeouts::cover_calibrator(), |d| {
            d.close_cover()
        })
        .await
    }

    async fn halt_cover(&self) -> Result<(), DriverError> {
        self.call("halt_cover", Timeouts::property_write(), |d| d.halt_cover())
            .await
    }

    async fn cover_status(&self) -> Result<CoverStatus, DriverError> {
        self.call("cover_state", Timeouts::property_read(), |d| d.cover_state())
            .await
            .map(CoverStatus::from)
    }

    async fn calibrator_on(&self, brightness: i32) -> Result<(), DriverError> {
        self.call("calibrator_on", Timeouts::property_write(), move |d| {
            d.calibrator_on(brightness)
        })
        .await
    }

    async fn calibrator_off(&self) -> Result<(), DriverError> {
        self.call("calibrator_off", Timeouts::property_write(), |d| {
            d.calibrator_off()
        })
        .await
    }

    async fn calibrator_status(&self) -> Result<CalibratorStatus, DriverError> {
        self.call("calibrator_state", Timeouts::property_read(), |d| {
            d.calibrator_state()
        })
        .await
        .map(CalibratorStatus::from)
    }

    async fn brightness(&self) -> Result<i32, DriverError> {
        self.call("brightness", Timeouts::property_read(), |d| d.brightness())
            .await
    }

    async fn max_brightness(&self) -> Result<i32, DriverError> {
        self.call("max_brightness", Timeouts::property_read(), |d| {
            d.max_brightness()
        })
        .await
    }

    async fn status(&self) -> Result<CoverCalibratorState, DriverError> {
        cover_calibrator::state(self).await
    }
}
