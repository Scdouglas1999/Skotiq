//! The accessory driver traits, and what each accessory supports, over the
//! ASCOM wrappers. Every call still goes to the wrapper's command channel and
//! runs on the STA worker.

use super::covercalibrator::AscomCoverCalibratorWrapper;
use super::dome::AscomDomeWrapper;
use super::rotator::AscomRotatorWrapper;
use super::safetymonitor::AscomSafetyMonitorWrapper;
use super::switch::AscomSwitchWrapper;
use super::weather::AscomObservingConditionsWrapper;
use crate::device_capabilities::{
    DomeCapabilities, RotatorCapabilities, SafetyMonitorCapabilities,
    ShutterStatus as CapabilityShutter, WeatherCapabilities,
};
use crate::device_manager::accessory::{Dome, Rotator, SafetyMonitor, Weather};
use crate::error::SkotiqError;
use async_trait::async_trait;
use skotiq_device::ascom::{CalibratorStatus, CoverStatus, ShutterStatus};
use skotiq_device::{
    AccessoryDriver, CoverCalibratorDriver, CoverCalibratorState, DomeDriver, DomeState,
    DriverError, RotatorDriver, SafetyMonitorDriver, SwitchDriver, WeatherDriver, WeatherReadings,
};
use tracing::warn;

fn com(error: String) -> DriverError {
    DriverError::Backend(error.into())
}

/// `$probe` is the wrapper's cheapest read, which the heartbeat sends.
macro_rules! ascom_accessory {
    ($wrapper:ty, $probe:ident) => {
        #[async_trait]
        impl AccessoryDriver for $wrapper {
            async fn disconnect(&self) -> Result<(), DriverError> {
                <$wrapper>::disconnect(self).await.map_err(com)
            }

            async fn heartbeat(&self) -> Result<(), DriverError> {
                <$wrapper>::$probe(self).await.map(|_| ()).map_err(com)
            }
        }
    };
}

ascom_accessory!(AscomDomeWrapper, heartbeat);
ascom_accessory!(AscomRotatorWrapper, position);
ascom_accessory!(AscomSwitchWrapper, interface_version);
ascom_accessory!(AscomObservingConditionsWrapper, interface_version);
ascom_accessory!(AscomSafetyMonitorWrapper, is_safe);
ascom_accessory!(AscomCoverCalibratorWrapper, cover_state);

#[async_trait]
impl DomeDriver for AscomDomeWrapper {
    async fn open_shutter(&self) -> Result<(), DriverError> {
        AscomDomeWrapper::open_shutter(self).await.map_err(com)
    }

    async fn close_shutter(&self) -> Result<(), DriverError> {
        AscomDomeWrapper::close_shutter(self).await.map_err(com)
    }

    async fn shutter_status(&self) -> Result<ShutterStatus, DriverError> {
        AscomDomeWrapper::shutter_status(self)
            .await
            .map(ShutterStatus::from)
            .map_err(com)
    }

    async fn slew_to_azimuth(&self, azimuth_deg: f64) -> Result<(), DriverError> {
        AscomDomeWrapper::slew_to_azimuth(self, azimuth_deg)
            .await
            .map_err(com)
    }

    async fn abort_slew(&self) -> Result<(), DriverError> {
        AscomDomeWrapper::abort_slew(self).await.map_err(com)
    }

    async fn park(&self) -> Result<(), DriverError> {
        AscomDomeWrapper::park(self).await.map_err(com)
    }

    async fn find_home(&self) -> Result<(), DriverError> {
        AscomDomeWrapper::find_home(self).await.map_err(com)
    }

    async fn set_slaved(&self, slaved: bool) -> Result<(), DriverError> {
        AscomDomeWrapper::set_slaved(self, slaved)
            .await
            .map_err(com)
    }

    /// Reads the shutter, slewing and at-park only; the azimuth, home and
    /// capabilities are reported as fixed values. A shutter that cannot be
    /// read is reported as `Error` with a warning.
    async fn status(&self) -> Result<DomeState, DriverError> {
        let shutter_code = AscomDomeWrapper::shutter_status(self)
            .await
            .unwrap_or_else(|e| {
                warn!(
                    "Failed to read ASCOM dome shutter_status: {}. Using error code 4.",
                    e
                );
                4
            });
        let slewing = self
            .slewing()
            .await
            .map_err(|e| com(format!("Failed to read ASCOM dome slewing: {}", e)))?;
        let at_park = self
            .at_park()
            .await
            .map_err(|e| com(format!("Failed to read ASCOM dome at_park: {}", e)))?;
        Ok(DomeState {
            azimuth: 0.0,
            altitude: None,
            shutter: (0..=4).contains(&shutter_code).then(|| shutter_code.into()),
            slewing,
            at_home: false,
            at_park,
            can_set_altitude: false,
            can_set_azimuth: false,
            can_set_shutter: true,
            can_slave: false,
            slaved: false,
        })
    }
}

#[async_trait]
impl RotatorDriver for AscomRotatorWrapper {
    async fn move_absolute(&self, position_deg: f64) -> Result<(), DriverError> {
        AscomRotatorWrapper::move_absolute(self, position_deg)
            .await
            .map_err(com)
    }

    async fn position(&self) -> Result<f64, DriverError> {
        AscomRotatorWrapper::position(self).await.map_err(com)
    }

    async fn is_moving(&self) -> Result<bool, DriverError> {
        AscomRotatorWrapper::is_moving(self).await.map_err(com)
    }

    async fn halt(&self) -> Result<(), DriverError> {
        AscomRotatorWrapper::halt(self).await.map_err(com)
    }

    async fn sync(&self, position_deg: f64) -> Result<(), DriverError> {
        AscomRotatorWrapper::sync(self, position_deg)
            .await
            .map_err(com)
    }

    async fn set_reverse(&self, reverse: bool) -> Result<(), DriverError> {
        AscomRotatorWrapper::set_reverse(self, reverse)
            .await
            .map_err(com)
    }
}

#[async_trait]
impl SwitchDriver for AscomSwitchWrapper {
    async fn count(&self) -> Result<i32, DriverError> {
        self.get_max_switch().await.map_err(com)
    }

    async fn switch_name(&self, index: i32) -> Result<String, DriverError> {
        self.get_switch_name(index).await.map_err(com)
    }

    async fn switch_description(&self, index: i32) -> Result<String, DriverError> {
        self.get_switch_description(index).await.map_err(com)
    }

    async fn can_write(&self, index: i32) -> Result<bool, DriverError> {
        AscomSwitchWrapper::can_write(self, index)
            .await
            .map_err(com)
    }

    async fn state(&self, index: i32) -> Result<bool, DriverError> {
        self.get_switch(index).await.map_err(com)
    }

    async fn set_state(&self, index: i32, on: bool) -> Result<(), DriverError> {
        self.set_switch(index, on).await.map_err(com)
    }

    async fn value(&self, index: i32) -> Result<f64, DriverError> {
        self.get_switch_value(index).await.map_err(com)
    }

    async fn set_value(&self, index: i32, value: f64) -> Result<(), DriverError> {
        self.set_switch_value(index, value).await.map_err(com)
    }

    async fn min_value(&self, index: i32) -> Result<f64, DriverError> {
        self.get_min_switch_value(index).await.map_err(com)
    }

    async fn max_value(&self, index: i32) -> Result<f64, DriverError> {
        self.get_max_switch_value(index).await.map_err(com)
    }
}

#[async_trait]
impl WeatherDriver for AscomObservingConditionsWrapper {
    /// A sensor the station does not have, or one that fails to read, is
    /// `None`.
    async fn readings(&self) -> Result<WeatherReadings, DriverError> {
        Ok(WeatherReadings {
            temperature: self.temperature().await.ok(),
            humidity: self.humidity().await.ok(),
            pressure: self.pressure().await.ok(),
            cloud_cover: self.cloud_cover().await.ok(),
            dew_point: self.dew_point().await.ok(),
            wind_speed: self.wind_speed().await.ok(),
            wind_direction: self.wind_direction().await.ok(),
            sky_quality: self.sky_quality().await.ok(),
            sky_temperature: self.sky_temperature().await.ok(),
            rain_rate: self.rain_rate().await.ok(),
        })
    }
}

#[async_trait]
impl SafetyMonitorDriver for AscomSafetyMonitorWrapper {
    async fn is_safe(&self) -> Result<bool, DriverError> {
        AscomSafetyMonitorWrapper::is_safe(self).await.map_err(com)
    }
}

#[async_trait]
impl CoverCalibratorDriver for AscomCoverCalibratorWrapper {
    async fn open_cover(&self) -> Result<(), DriverError> {
        AscomCoverCalibratorWrapper::open_cover(self)
            .await
            .map_err(com)
    }

    async fn close_cover(&self) -> Result<(), DriverError> {
        AscomCoverCalibratorWrapper::close_cover(self)
            .await
            .map_err(com)
    }

    async fn halt_cover(&self) -> Result<(), DriverError> {
        AscomCoverCalibratorWrapper::halt_cover(self)
            .await
            .map_err(com)
    }

    async fn cover_status(&self) -> Result<CoverStatus, DriverError> {
        self.cover_state().await.map(CoverStatus::from).map_err(com)
    }

    async fn calibrator_on(&self, brightness: i32) -> Result<(), DriverError> {
        AscomCoverCalibratorWrapper::calibrator_on(self, brightness)
            .await
            .map_err(com)
    }

    async fn calibrator_off(&self) -> Result<(), DriverError> {
        AscomCoverCalibratorWrapper::calibrator_off(self)
            .await
            .map_err(com)
    }

    async fn calibrator_status(&self) -> Result<CalibratorStatus, DriverError> {
        self.calibrator_state()
            .await
            .map(CalibratorStatus::from)
            .map_err(com)
    }

    async fn brightness(&self) -> Result<i32, DriverError> {
        AscomCoverCalibratorWrapper::brightness(self)
            .await
            .map_err(com)
    }

    async fn max_brightness(&self) -> Result<i32, DriverError> {
        AscomCoverCalibratorWrapper::max_brightness(self)
            .await
            .map_err(com)
    }

    /// A state that cannot be read is `Unknown`, a brightness 0, each with a
    /// warning; the maximum is the one read when the wrapper was built.
    async fn status(&self) -> Result<CoverCalibratorState, DriverError> {
        let cover = self.cover_state().await.unwrap_or_else(|e| {
            warn!(
                "Failed to read cover calibrator cover_state: {}. Using Unknown (4).",
                e
            );
            4
        });
        let calibrator = self.calibrator_state().await.unwrap_or_else(|e| {
            warn!(
                "Failed to read cover calibrator calibrator_state: {}. Using Unknown (4).",
                e
            );
            4
        });
        let brightness = AscomCoverCalibratorWrapper::brightness(self)
            .await
            .unwrap_or_else(|e| {
                warn!(
                    "Failed to read cover calibrator brightness: {}. Using default 0.",
                    e
                );
                0
            });
        Ok(CoverCalibratorState {
            cover: cover.into(),
            calibrator: calibrator.into(),
            brightness,
            max_brightness: self.cached_max_brightness(),
        })
    }
}

// What each wrapper supports, read through its own COM object on the STA
// worker. The `unwrap_or` defaults are what the ASCOM interface means when a
// driver does not implement an optional property: the feature is absent, the
// device is not in that state.

#[async_trait]
impl Rotator for AscomRotatorWrapper {
    async fn capabilities(&self, _device_id: &str) -> Result<RotatorCapabilities, SkotiqError> {
        // CanReverse and Sync arrived in IRotatorV3; a driver that does not
        // say its version is taken as V1.
        let is_v3 = AscomRotatorWrapper::interface_version(self)
            .await
            .unwrap_or(0)
            >= 3;
        Ok(RotatorCapabilities {
            can_reverse: is_v3,
            reverse: false,
            step_size: None,
            is_moving: AscomRotatorWrapper::is_moving(self)
                .await
                .unwrap_or(false),
            mechanical_position: self.mechanical_position().await.ok(),
            position: AscomRotatorWrapper::position(self).await.ok(),
            can_move_absolute: true,
            can_halt: true,
            can_sync: is_v3,
            // IRotatorV3 has no angle limits: positions wrap within 0-360.
            min_angle_deg: None,
            max_angle_deg: None,
        })
    }
}

#[async_trait]
impl Dome for AscomDomeWrapper {
    async fn capabilities(&self, _device_id: &str) -> Result<DomeCapabilities, SkotiqError> {
        let shutter_status = AscomDomeWrapper::shutter_status(self)
            .await
            .ok()
            .map(|s| match s {
                0 => CapabilityShutter::Open,
                1 => CapabilityShutter::Closed,
                2 => CapabilityShutter::Opening,
                3 => CapabilityShutter::Closing,
                _ => CapabilityShutter::Unknown,
            });
        let azimuth = self.azimuth().await.ok();
        let at_park = self.at_park().await;
        Ok(DomeCapabilities {
            // A dome that does not answer CanSetAzimuth but reports its
            // azimuth is offered as one that can be turned.
            can_set_azimuth: self.can_set_azimuth().await.unwrap_or(azimuth.is_some()),
            can_park: at_park.is_ok(),
            can_find_home: false,
            can_set_shutter: shutter_status.is_some(),
            can_sync_azimuth: false,
            azimuth,
            slewing: self.slewing().await.unwrap_or(false),
            at_home: false,
            at_park: at_park.unwrap_or(false),
            shutter_status,
            can_slave: false,
            slaved: false,
            can_abort: true,
        })
    }
}

#[async_trait]
impl Weather for AscomObservingConditionsWrapper {
    /// A sensor the station does not have throws PropertyNotImplemented.
    async fn capabilities(&self, _device_id: &str) -> Result<WeatherCapabilities, SkotiqError> {
        Ok(WeatherCapabilities {
            has_cloud_cover: self.cloud_cover().await.is_ok(),
            has_dew_point: self.dew_point().await.is_ok(),
            has_humidity: self.humidity().await.is_ok(),
            has_pressure: self.pressure().await.is_ok(),
            has_rain_rate: self.rain_rate().await.is_ok(),
            has_sky_brightness: self.sky_brightness().await.is_ok(),
            has_sky_quality: self.sky_quality().await.is_ok(),
            has_sky_temperature: self.sky_temperature().await.is_ok(),
            has_seeing: self.star_fwhm().await.is_ok(),
            has_temperature: self.temperature().await.is_ok(),
            has_wind_direction: self.wind_direction().await.is_ok(),
            has_wind_gust: self.wind_gust().await.is_ok(),
            has_wind_speed: self.wind_speed().await.is_ok(),
            average_period: None,
        })
    }
}

#[async_trait]
impl SafetyMonitor for AscomSafetyMonitorWrapper {
    async fn capabilities(
        &self,
        _device_id: &str,
    ) -> Result<SafetyMonitorCapabilities, SkotiqError> {
        Ok(SafetyMonitorCapabilities {
            // A monitor that cannot be read is never reported safe.
            is_safe: AscomSafetyMonitorWrapper::is_safe(self)
                .await
                .unwrap_or(false),
            safety_description: self.driver_info().await.ok(),
        })
    }
}
