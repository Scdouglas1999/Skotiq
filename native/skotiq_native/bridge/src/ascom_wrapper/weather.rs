//! An ASCOM weather station (`IObservingConditionsV2`) over COM. What a read
//! means is decided by `skotiq_device::ascom::observing_conditions`, the same
//! as for an Alpaca station.

use super::sta_device::{driver_error, sta_accessory, StaDevice};
use crate::device_capabilities::WeatherCapabilities;
use crate::device_manager::accessory::{weather_capabilities, Weather};
use crate::device_manager::handle::device_error;
use crate::dispatch::DeviceOpError;
use crate::error::SkotiqError;
use crate::timeout_ops::Timeouts;
use async_trait::async_trait;
use skotiq_ascom::AscomObservingConditions;
use skotiq_device::ascom::observing_conditions::{self, ObservingConditionsMembers, Sensor};
use skotiq_device::{DriverError, WeatherDriver, WeatherReadings};

pub struct AscomObservingConditionsWrapper {
    device: StaDevice<AscomObservingConditions>,
}

impl AscomObservingConditionsWrapper {
    pub fn new(prog_id: String) -> Result<Self, String> {
        let (device, ()) = StaDevice::new(
            "Weather",
            move || AscomObservingConditions::new(&prog_id),
            |_| (),
        )?;
        Ok(Self { device })
    }

    pub async fn connect(&self) -> Result<(), DeviceOpError> {
        self.device
            .run("connect", Timeouts::connection(), |d| d.connect())
            .await
    }
}

sta_accessory!(AscomObservingConditionsWrapper);

#[async_trait]
impl ObservingConditionsMembers for AscomObservingConditionsWrapper {
    async fn sensor(&self, sensor: Sensor) -> Result<f64, DriverError> {
        self.device
            .run(sensor.ascom_name(), Timeouts::property_read(), move |d| {
                match sensor {
                    Sensor::CloudCover => d.cloud_cover(),
                    Sensor::DewPoint => d.dew_point(),
                    Sensor::Humidity => d.humidity(),
                    Sensor::Pressure => d.pressure(),
                    Sensor::RainRate => d.rain_rate(),
                    Sensor::SkyBrightness => d.sky_brightness(),
                    Sensor::SkyQuality => d.sky_quality(),
                    Sensor::SkyTemperature => d.sky_temperature(),
                    Sensor::StarFwhm => d.star_fwhm(),
                    Sensor::Temperature => d.temperature(),
                    Sensor::WindDirection => d.wind_direction(),
                    Sensor::WindGust => d.wind_gust(),
                    Sensor::WindSpeed => d.wind_speed(),
                }
            })
            .await
            .map_err(driver_error)
    }

    async fn average_period(&self) -> Result<f64, DriverError> {
        self.device
            .run("average_period", Timeouts::property_read(), |d| {
                d.average_period()
            })
            .await
            .map_err(driver_error)
    }
}

#[async_trait]
impl WeatherDriver for AscomObservingConditionsWrapper {
    async fn readings(&self) -> Result<WeatherReadings, DriverError> {
        observing_conditions::readings(self).await
    }
}

#[async_trait]
impl Weather for AscomObservingConditionsWrapper {
    async fn capabilities(&self, device_id: &str) -> Result<WeatherCapabilities, SkotiqError> {
        weather_capabilities(self)
            .await
            .map_err(|e| SkotiqError::from(device_error(device_id, e)))
    }
}
