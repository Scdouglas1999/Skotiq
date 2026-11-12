//! ASCOM Observing Conditions wrapper and batch status types.

use crate::com::ComDispatch;

com_device!(ObservingConditions);

impl<D: ComDispatch> ObservingConditions<D> {
    skotiq_device::ascom_observing_conditions_members!(com_member);

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
}

#[derive(Debug, Clone, Default)]
pub struct WeatherStatus {
    pub temperature: Option<f64>,
    pub humidity: Option<f64>,
    pub dew_point: Option<f64>,
    pub pressure: Option<f64>,
}

#[derive(Debug, Clone, Default)]
pub struct WindStatus {
    pub wind_speed: Option<f64>,
    pub wind_gust: Option<f64>,
    pub wind_direction: Option<f64>,
}

#[derive(Debug, Clone, Default)]
pub struct SkyStatus {
    pub cloud_cover: Option<f64>,
    pub sky_brightness: Option<f64>,
    pub sky_quality: Option<f64>,
    pub sky_temperature: Option<f64>,
    pub star_fwhm: Option<f64>,
    pub rain_rate: Option<f64>,
}

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
