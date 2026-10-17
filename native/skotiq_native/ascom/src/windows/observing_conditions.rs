//! ASCOM Observing Conditions wrapper and batch status types.

use super::connection::AscomDeviceConnection;
use super::health::ConnectionHealth;

/// ASCOM Observing Conditions
pub struct AscomObservingConditions {
    device: AscomDeviceConnection,
}

impl AscomObservingConditions {
    pub fn new(prog_id: &str) -> Result<Self, String> {
        Ok(Self {
            device: AscomDeviceConnection::new(prog_id)?,
        })
    }

    pub fn connect(&mut self) -> Result<(), String> {
        self.device.connect()
    }

    pub fn disconnect(&mut self) -> Result<(), String> {
        self.device.disconnect()
    }

    /// Query the underlying ASCOM driver for its current `Connected` state.
    ///
    /// Used by capability probes that must NOT kick an active UI connection:
    /// if the driver reports `Ok(true)`, the probe reuses the connection
    /// instead of opening/closing its own session.
    pub fn is_connected(&self) -> Result<bool, String> {
        self.device.is_connected()
    }

    pub fn name(&self) -> Result<String, String> {
        self.device.get_string_property("Name")
    }

    /// Get the interface version number
    pub fn interface_version(&self) -> Result<i32, String> {
        self.device.get_int_property("InterfaceVersion")
    }

    /// Get the driver version string
    pub fn driver_version(&self) -> Result<String, String> {
        self.device.get_string_property("DriverVersion")
    }

    /// Get the driver info/description
    pub fn driver_info(&self) -> Result<String, String> {
        self.device.get_string_property("DriverInfo")
    }

    /// Get the list of supported custom actions
    pub fn supported_actions(&self) -> Result<Vec<String>, String> {
        self.device.get_string_array_property("SupportedActions")
    }

    pub fn cloud_cover(&self) -> Result<f64, String> {
        self.device.get_double_property("CloudCover")
    }

    pub fn dew_point(&self) -> Result<f64, String> {
        self.device.get_double_property("DewPoint")
    }

    pub fn humidity(&self) -> Result<f64, String> {
        self.device.get_double_property("Humidity")
    }

    pub fn pressure(&self) -> Result<f64, String> {
        self.device.get_double_property("Pressure")
    }

    pub fn rain_rate(&self) -> Result<f64, String> {
        self.device.get_double_property("RainRate")
    }

    pub fn sky_brightness(&self) -> Result<f64, String> {
        self.device.get_double_property("SkyBrightness")
    }

    pub fn sky_quality(&self) -> Result<f64, String> {
        self.device.get_double_property("SkyQuality")
    }

    pub fn sky_temperature(&self) -> Result<f64, String> {
        self.device.get_double_property("SkyTemperature")
    }

    pub fn star_fwhm(&self) -> Result<f64, String> {
        self.device.get_double_property("StarFWHM")
    }

    pub fn temperature(&self) -> Result<f64, String> {
        self.device.get_double_property("Temperature")
    }

    pub fn wind_direction(&self) -> Result<f64, String> {
        self.device.get_double_property("WindDirection")
    }

    pub fn wind_gust(&self) -> Result<f64, String> {
        self.device.get_double_property("WindGust")
    }

    pub fn wind_speed(&self) -> Result<f64, String> {
        self.device.get_double_property("WindSpeed")
    }

    /// Force the driver to refresh sensor readings (IObservingConditions `Refresh`).
    pub fn refresh(&self) -> Result<(), String> {
        self.device.call_method("Refresh")
    }

    /// Averaging period in hours (IObservingConditions `AveragePeriod`).
    pub fn average_period(&self) -> Result<f64, String> {
        self.device.get_double_property("AveragePeriod")
    }

    /// Set averaging period in hours (IObservingConditions `AveragePeriod` write).
    pub fn set_average_period(&mut self, period: f64) -> Result<(), String> {
        self.device.set_double_property("AveragePeriod", period)
    }

    /// Seconds since the named sensor was last updated (`TimeSinceLastUpdate`).
    pub fn time_since_last_update(&self, property_name: &str) -> Result<f64, String> {
        self.device
            .get_double_property_indexed("TimeSinceLastUpdate", property_name)
    }

    /// Human-readable description for a sensor (`SensorDescription`).
    pub fn sensor_description(&self, property_name: &str) -> Result<String, String> {
        self.device
            .get_string_property_indexed("SensorDescription", property_name)
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
    pub fn heartbeat(&self) -> Result<(), String> {
        self.device.heartbeat()
    }

    /// Get connection health status
    pub fn get_health(&self) -> ConnectionHealth {
        self.device.get_health()
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
