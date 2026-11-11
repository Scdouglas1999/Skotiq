//! The accessory driver traits over the ASCOM wrappers. Every call still goes
//! to the wrapper's command channel and runs on the STA worker.

use super::covercalibrator::AscomCoverCalibratorWrapper;
use super::dome::AscomDomeWrapper;
use super::rotator::AscomRotatorWrapper;
use super::safetymonitor::AscomSafetyMonitorWrapper;
use super::switch::AscomSwitchWrapper;
use super::weather::AscomObservingConditionsWrapper;
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
