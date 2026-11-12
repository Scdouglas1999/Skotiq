//! An ASCOM switch box (`ISwitchV3`) over COM. Its channels are read by
//! `device_manager::accessory::switch_capabilities`, the same as every
//! switch's.

use super::sta_device::{driver_error, sta_accessory, StaDevice};
use crate::dispatch::DeviceOpError;
use crate::timeout_ops::Timeouts;
use async_trait::async_trait;
use skotiq_ascom::{AscomResult, AscomSwitch};
use skotiq_device::{DriverError, SwitchDriver};

pub struct AscomSwitchWrapper {
    device: StaDevice<AscomSwitch>,
}

impl AscomSwitchWrapper {
    pub fn new(prog_id: String) -> Result<Self, String> {
        let (device, ()) = StaDevice::new("Switch", move || AscomSwitch::new(&prog_id), |_| ())?;
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
        call: impl FnOnce(&mut AscomSwitch) -> AscomResult<T> + Send + 'static,
    ) -> Result<T, DriverError> {
        self.device
            .run(member, Timeouts::property_read(), call)
            .await
            .map_err(driver_error)
    }

    async fn write(
        &self,
        member: &str,
        call: impl FnOnce(&mut AscomSwitch) -> AscomResult<()> + Send + 'static,
    ) -> Result<(), DriverError> {
        self.device
            .run(member, Timeouts::property_write(), call)
            .await
            .map_err(driver_error)
    }
}

sta_accessory!(AscomSwitchWrapper);

#[async_trait]
impl SwitchDriver for AscomSwitchWrapper {
    async fn count(&self) -> Result<i32, DriverError> {
        self.read("max_switch", |d| d.max_switch()).await
    }

    async fn switch_name(&self, index: i32) -> Result<String, DriverError> {
        self.read("get_switch_name", move |d| d.get_switch_name(index))
            .await
    }

    async fn switch_description(&self, index: i32) -> Result<String, DriverError> {
        self.read("get_switch_description", move |d| {
            d.get_switch_description(index)
        })
        .await
    }

    async fn can_write(&self, index: i32) -> Result<bool, DriverError> {
        self.read("can_write", move |d| d.can_write(index)).await
    }

    async fn state(&self, index: i32) -> Result<bool, DriverError> {
        self.read("get_switch", move |d| d.get_switch(index)).await
    }

    async fn set_state(&self, index: i32, on: bool) -> Result<(), DriverError> {
        self.write("set_switch", move |d| d.set_switch(index, on))
            .await
    }

    async fn value(&self, index: i32) -> Result<f64, DriverError> {
        self.read("get_switch_value", move |d| d.get_switch_value(index))
            .await
    }

    async fn set_value(&self, index: i32, value: f64) -> Result<(), DriverError> {
        self.write("set_switch_value", move |d| {
            d.set_switch_value(index, value)
        })
        .await
    }

    async fn min_value(&self, index: i32) -> Result<f64, DriverError> {
        self.read("min_switch_value", move |d| d.min_switch_value(index))
            .await
    }

    async fn max_value(&self, index: i32) -> Result<f64, DriverError> {
        self.read("max_switch_value", move |d| d.max_switch_value(index))
            .await
    }

    async fn step(&self, index: i32) -> Result<f64, DriverError> {
        self.read("switch_step", move |d| d.switch_step(index)).await
    }
}
