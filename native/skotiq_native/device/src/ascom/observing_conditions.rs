//! How an ASCOM weather station (`IObservingConditionsV2`) is read, the same
//! over COM and Alpaca.
//!
//! A sensor the station does not have raises `PropertyNotImplemented`, so it
//! reads as absent. Any other failure (the station is not connected, does not
//! answer, or reports a fault) fails the whole read: a station that cannot be
//! read must not look like a station without sensors.

use super::optional;
use crate::{DriverError, WeatherReadings};
use async_trait::async_trait;

/// One `IObservingConditionsV2` sensor property. The ASCOM name is also the
/// `SensorName` that `SensorDescription` and `TimeSinceLastUpdate` take.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Sensor {
    CloudCover,
    DewPoint,
    Humidity,
    Pressure,
    RainRate,
    SkyBrightness,
    SkyQuality,
    SkyTemperature,
    StarFwhm,
    Temperature,
    WindDirection,
    WindGust,
    WindSpeed,
}

impl Sensor {
    pub const ALL: [Sensor; 13] = [
        Sensor::CloudCover,
        Sensor::DewPoint,
        Sensor::Humidity,
        Sensor::Pressure,
        Sensor::RainRate,
        Sensor::SkyBrightness,
        Sensor::SkyQuality,
        Sensor::SkyTemperature,
        Sensor::StarFwhm,
        Sensor::Temperature,
        Sensor::WindDirection,
        Sensor::WindGust,
        Sensor::WindSpeed,
    ];

    pub fn ascom_name(self) -> &'static str {
        match self {
            Sensor::CloudCover => "CloudCover",
            Sensor::DewPoint => "DewPoint",
            Sensor::Humidity => "Humidity",
            Sensor::Pressure => "Pressure",
            Sensor::RainRate => "RainRate",
            Sensor::SkyBrightness => "SkyBrightness",
            Sensor::SkyQuality => "SkyQuality",
            Sensor::SkyTemperature => "SkyTemperature",
            Sensor::StarFwhm => "StarFWHM",
            Sensor::Temperature => "Temperature",
            Sensor::WindDirection => "WindDirection",
            Sensor::WindGust => "WindGust",
            Sensor::WindSpeed => "WindSpeed",
        }
    }
}

/// The `IObservingConditionsV2` properties a read uses, in the transport's
/// own calls.
#[async_trait]
pub trait ObservingConditionsMembers: Send + Sync {
    /// The sensor's current value, in the unit ASCOM defines for it.
    async fn sensor(&self, sensor: Sensor) -> Result<f64, DriverError>;

    /// Hours over which the station averages its readings; 0 for
    /// instantaneous values.
    async fn average_period(&self) -> Result<f64, DriverError>;
}

/// Every sensor the station has, read once; `None` for one it does not have.
pub async fn sensors(
    station: &dyn ObservingConditionsMembers,
) -> Result<Vec<(Sensor, Option<f64>)>, DriverError> {
    let mut values = Vec::with_capacity(Sensor::ALL.len());
    for sensor in Sensor::ALL {
        values.push((sensor, optional(station.sensor(sensor).await)?));
    }
    Ok(values)
}

/// What [`crate::WeatherDriver::readings`] answers for an ASCOM station.
pub async fn readings(
    station: &dyn ObservingConditionsMembers,
) -> Result<WeatherReadings, DriverError> {
    let mut readings = WeatherReadings::default();
    for (sensor, value) in sensors(station).await? {
        match sensor {
            Sensor::CloudCover => readings.cloud_cover = value,
            Sensor::DewPoint => readings.dew_point = value,
            Sensor::Humidity => readings.humidity = value,
            Sensor::Pressure => readings.pressure = value,
            Sensor::RainRate => readings.rain_rate = value,
            Sensor::SkyQuality => readings.sky_quality = value,
            Sensor::SkyTemperature => readings.sky_temperature = value,
            Sensor::Temperature => readings.temperature = value,
            Sensor::WindDirection => readings.wind_direction = value,
            Sensor::WindSpeed => readings.wind_speed = value,
            Sensor::SkyBrightness | Sensor::StarFwhm | Sensor::WindGust => {}
        }
    }
    Ok(readings)
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Station {
        has: &'static [Sensor],
        fault: Option<Sensor>,
    }

    #[async_trait]
    impl ObservingConditionsMembers for Station {
        async fn sensor(&self, sensor: Sensor) -> Result<f64, DriverError> {
            if self.fault == Some(sensor) {
                return Err(DriverError::NotConnected);
            }
            if self.has.contains(&sensor) {
                Ok(12.5)
            } else {
                Err(DriverError::NotSupported)
            }
        }

        async fn average_period(&self) -> Result<f64, DriverError> {
            Ok(0.0)
        }
    }

    #[tokio::test]
    async fn sensors_the_station_lacks_are_absent() {
        let readings = readings(&Station {
            has: &[Sensor::Temperature, Sensor::Humidity],
            fault: None,
        })
        .await
        .expect("readings");
        assert_eq!(readings.temperature, Some(12.5));
        assert_eq!(readings.humidity, Some(12.5));
        assert_eq!(readings.pressure, None);
        assert_eq!(readings.cloud_cover, None);
    }

    #[tokio::test]
    async fn a_station_that_cannot_be_read_is_not_a_station_without_sensors() {
        let result = readings(&Station {
            has: &[Sensor::Temperature, Sensor::Humidity],
            fault: Some(Sensor::Humidity),
        })
        .await;
        assert!(matches!(result, Err(DriverError::NotConnected)));
    }
}
