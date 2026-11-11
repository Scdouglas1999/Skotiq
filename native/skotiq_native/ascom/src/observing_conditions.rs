//! ASCOM Observing Conditions wrapper and batch status types.

use crate::com::ComDispatch;
use crate::error::AscomResult;
use crate::health::ConnectionHealth;

/// ASCOM Observing Conditions
pub struct ObservingConditions<D> {
    pub(crate) device: D,
}

#[cfg(windows)]
impl ObservingConditions<crate::windows::AscomDeviceConnection> {
    pub fn new(prog_id: &str) -> AscomResult<Self> {
        Ok(Self {
            device: crate::windows::AscomDeviceConnection::new(prog_id)?,
        })
    }
}

impl<D: ComDispatch> ObservingConditions<D> {
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

    pub fn cloud_cover(&self) -> AscomResult<f64> {
        self.device.get("CloudCover")
    }

    pub fn dew_point(&self) -> AscomResult<f64> {
        self.device.get("DewPoint")
    }

    pub fn humidity(&self) -> AscomResult<f64> {
        self.device.get("Humidity")
    }

    pub fn pressure(&self) -> AscomResult<f64> {
        self.device.get("Pressure")
    }

    pub fn rain_rate(&self) -> AscomResult<f64> {
        self.device.get("RainRate")
    }

    pub fn sky_brightness(&self) -> AscomResult<f64> {
        self.device.get("SkyBrightness")
    }

    pub fn sky_quality(&self) -> AscomResult<f64> {
        self.device.get("SkyQuality")
    }

    pub fn sky_temperature(&self) -> AscomResult<f64> {
        self.device.get("SkyTemperature")
    }

    pub fn star_fwhm(&self) -> AscomResult<f64> {
        self.device.get("StarFWHM")
    }

    pub fn temperature(&self) -> AscomResult<f64> {
        self.device.get("Temperature")
    }

    pub fn wind_direction(&self) -> AscomResult<f64> {
        self.device.get("WindDirection")
    }

    pub fn wind_gust(&self) -> AscomResult<f64> {
        self.device.get("WindGust")
    }

    pub fn wind_speed(&self) -> AscomResult<f64> {
        self.device.get("WindSpeed")
    }

    /// Force the driver to refresh sensor readings (IObservingConditions `Refresh`).
    pub fn refresh(&self) -> AscomResult<()> {
        self.device.call("Refresh", &[])
    }

    /// Averaging period in hours (IObservingConditions `AveragePeriod`).
    pub fn average_period(&self) -> AscomResult<f64> {
        self.device.get("AveragePeriod")
    }

    /// Set averaging period in hours (IObservingConditions `AveragePeriod` write).
    pub fn set_average_period(&mut self, period: f64) -> AscomResult<()> {
        self.device.put("AveragePeriod", period)
    }

    /// Seconds since the named sensor was last updated (`TimeSinceLastUpdate`).
    pub fn time_since_last_update(&self, property_name: &str) -> AscomResult<f64> {
        self.device
            .get_indexed("TimeSinceLastUpdate", &[property_name.into()])
    }

    /// Human-readable description for a sensor (`SensorDescription`).
    pub fn sensor_description(&self, property_name: &str) -> AscomResult<String> {
        self.device
            .get_indexed("SensorDescription", &[property_name.into()])
    }

    // Batch property queries

    /// Get weather conditions in a single batch operation
    pub fn get_weather_status(&self) -> WeatherStatus {
        WeatherStatus {
            temperature: self.temperature().ok(),
            humidity: self.humidity().ok(),
            dew_point: self.dew_point().ok(),
            pressure: self.pressure().ok(),
        }
    }

    /// Get wind conditions in a single batch operation
    pub fn get_wind_status(&self) -> WindStatus {
        WindStatus {
            wind_speed: self.wind_speed().ok(),
            wind_gust: self.wind_gust().ok(),
            wind_direction: self.wind_direction().ok(),
        }
    }

    /// Get sky conditions in a single batch operation
    pub fn get_sky_status(&self) -> SkyStatus {
        SkyStatus {
            cloud_cover: self.cloud_cover().ok(),
            sky_brightness: self.sky_brightness().ok(),
            sky_quality: self.sky_quality().ok(),
            sky_temperature: self.sky_temperature().ok(),
            star_fwhm: self.star_fwhm().ok(),
            rain_rate: self.rain_rate().ok(),
        }
    }

    /// Get complete observing conditions status in a single batch operation
    pub fn get_full_status(&self) -> ObservingConditionsFullStatus {
        ObservingConditionsFullStatus {
            weather: self.get_weather_status(),
            wind: self.get_wind_status(),
            sky: self.get_sky_status(),
            average_period: self.average_period().ok(),
            temperature_age_secs: self.time_since_last_update("Temperature").ok(),
            humidity_age_secs: self.time_since_last_update("Humidity").ok(),
            temperature_description: self.sensor_description("Temperature").ok(),
            humidity_description: self.sensor_description("Humidity").ok(),
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

/// Weather status
#[derive(Debug, Clone, Default)]
pub struct WeatherStatus {
    pub temperature: Option<f64>,
    pub humidity: Option<f64>,
    pub dew_point: Option<f64>,
    pub pressure: Option<f64>,
}

/// Wind status
#[derive(Debug, Clone, Default)]
pub struct WindStatus {
    pub wind_speed: Option<f64>,
    pub wind_gust: Option<f64>,
    pub wind_direction: Option<f64>,
}

/// Sky status
#[derive(Debug, Clone, Default)]
pub struct SkyStatus {
    pub cloud_cover: Option<f64>,
    pub sky_brightness: Option<f64>,
    pub sky_quality: Option<f64>,
    pub sky_temperature: Option<f64>,
    pub star_fwhm: Option<f64>,
    pub rain_rate: Option<f64>,
}

/// Full observing conditions status
#[derive(Debug, Clone, Default)]
pub struct ObservingConditionsFullStatus {
    pub weather: WeatherStatus,
    pub wind: WindStatus,
    pub sky: SkyStatus,
    pub average_period: Option<f64>,
    pub temperature_age_secs: Option<f64>,
    pub humidity_age_secs: Option<f64>,
    pub temperature_description: Option<String>,
    pub humidity_description: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::{ObservingConditionsFullStatus, SkyStatus, WeatherStatus, WindStatus};

    #[test]
    fn full_status_carries_staleness_metadata() {
        let status = ObservingConditionsFullStatus {
            weather: WeatherStatus {
                temperature: Some(12.5),
                humidity: Some(55.0),
                ..Default::default()
            },
            wind: WindStatus::default(),
            sky: SkyStatus::default(),
            average_period: Some(5.0),
            temperature_age_secs: Some(2.0),
            humidity_age_secs: Some(3.5),
            temperature_description: Some("Ambient probe".into()),
            humidity_description: Some("RH sensor".into()),
        };

        assert_eq!(status.average_period, Some(5.0));
        assert_eq!(status.temperature_age_secs, Some(2.0));
        assert_eq!(
            status.temperature_description.as_deref(),
            Some("Ambient probe")
        );
    }
}
