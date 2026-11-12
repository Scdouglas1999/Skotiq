//! The accessory driver traits over the Alpaca clients.

use crate::{
    AlpacaCoverCalibrator, AlpacaDome, AlpacaObservingConditions, AlpacaRotator,
    AlpacaSafetyMonitor, AlpacaSwitch,
};
use async_trait::async_trait;
use skotiq_device::ascom::{CalibratorStatus, CoverStatus, ShutterStatus};
use skotiq_device::{
    AccessoryDriver, CoverCalibratorDriver, CoverCalibratorState, DomeDriver, DomeState,
    DriverError, RotatorDriver, SafetyMonitorDriver, SwitchDriver, WeatherDriver, WeatherReadings,
};

/// The probe is either the quick unretried read (`heartbeat`) or the device's
/// `Connected` property, where `false` means the device is gone (`connected`).
macro_rules! alpaca_probe {
    (heartbeat, $device:ty, $this:ident) => {{
        <$device>::heartbeat($this).await?;
        Ok(())
    }};
    (connected, $device:ty, $this:ident) => {{
        if <$device>::is_connected($this).await? {
            Ok(())
        } else {
            Err(DriverError::NotConnected)
        }
    }};
}

macro_rules! alpaca_accessory {
    ($device:ty, $probe:ident) => {
        #[async_trait]
        impl AccessoryDriver for $device {
            async fn disconnect(&self) -> Result<(), DriverError> {
                Ok(<$device>::disconnect(self).await?)
            }

            async fn heartbeat(&self) -> Result<(), DriverError> {
                alpaca_probe!($probe, $device, self)
            }
        }
    };
}

alpaca_accessory!(AlpacaDome, connected);
alpaca_accessory!(AlpacaRotator, connected);
alpaca_accessory!(AlpacaSwitch, connected);
alpaca_accessory!(AlpacaObservingConditions, connected);
alpaca_accessory!(AlpacaSafetyMonitor, heartbeat);
alpaca_accessory!(AlpacaCoverCalibrator, connected);

/// A capability read the dome status cannot do without, worded with the
/// capability that failed. A failure of a named kind (not connected, timeout)
/// stays that kind.
fn capability(name: &str, err: crate::AlpacaError) -> DriverError {
    let detail = format!("Failed to query Alpaca dome {name}: {err}");
    match DriverError::from(err) {
        DriverError::Backend(_) => DriverError::Backend(detail.into()),
        DriverError::Timeout(_) => DriverError::Timeout(detail),
        kind => kind,
    }
}

#[async_trait]
impl DomeDriver for AlpacaDome {
    async fn open_shutter(&self) -> Result<(), DriverError> {
        Ok(AlpacaDome::open_shutter(self).await?)
    }

    async fn close_shutter(&self) -> Result<(), DriverError> {
        Ok(AlpacaDome::close_shutter(self).await?)
    }

    async fn shutter_status(&self) -> Result<ShutterStatus, DriverError> {
        Ok(AlpacaDome::shutter_status(self).await?)
    }

    async fn slew_to_azimuth(&self, azimuth_deg: f64) -> Result<(), DriverError> {
        Ok(AlpacaDome::slew_to_azimuth(self, azimuth_deg).await?)
    }

    async fn abort_slew(&self) -> Result<(), DriverError> {
        Ok(AlpacaDome::abort_slew(self).await?)
    }

    async fn park(&self) -> Result<(), DriverError> {
        Ok(AlpacaDome::park(self).await?)
    }

    async fn find_home(&self) -> Result<(), DriverError> {
        Ok(AlpacaDome::find_home(self).await?)
    }

    async fn set_slaved(&self, slaved: bool) -> Result<(), DriverError> {
        Ok(AlpacaDome::set_slaved(self, slaved).await?)
    }

    async fn status(&self) -> Result<DomeState, DriverError> {
        let status = self.get_status().await?;
        let can_set_altitude = self
            .can_set_altitude()
            .await
            .map_err(|e| capability("can_set_altitude", e))?;
        let can_set_azimuth = self
            .can_set_azimuth()
            .await
            .map_err(|e| capability("can_set_azimuth", e))?;
        let can_set_shutter = self
            .can_set_shutter()
            .await
            .map_err(|e| capability("can_set_shutter", e))?;
        let can_slave = self
            .can_slave()
            .await
            .map_err(|e| capability("can_slave", e))?;
        Ok(DomeState {
            azimuth: status.azimuth,
            altitude: status.altitude,
            shutter: Some(status.shutter_status),
            slewing: status.slewing,
            at_home: status.at_home,
            at_park: status.at_park,
            can_set_altitude,
            can_set_azimuth,
            can_set_shutter,
            can_slave,
            slaved: status.slaved,
        })
    }
}

#[async_trait]
impl RotatorDriver for AlpacaRotator {
    async fn move_absolute(&self, position_deg: f64) -> Result<(), DriverError> {
        Ok(AlpacaRotator::move_absolute(self, position_deg).await?)
    }

    async fn position(&self) -> Result<f64, DriverError> {
        Ok(AlpacaRotator::position(self).await?)
    }

    async fn is_moving(&self) -> Result<bool, DriverError> {
        Ok(AlpacaRotator::is_moving(self).await?)
    }

    async fn halt(&self) -> Result<(), DriverError> {
        Ok(AlpacaRotator::halt(self).await?)
    }

    async fn sync(&self, position_deg: f64) -> Result<(), DriverError> {
        Ok(AlpacaRotator::sync(self, position_deg).await?)
    }

    async fn set_reverse(&self, reverse: bool) -> Result<(), DriverError> {
        Ok(AlpacaRotator::set_reverse(self, reverse).await?)
    }
}

#[async_trait]
impl SwitchDriver for AlpacaSwitch {
    async fn count(&self) -> Result<i32, DriverError> {
        Ok(self.max_switch().await?)
    }

    async fn switch_name(&self, index: i32) -> Result<String, DriverError> {
        Ok(self.get_switch_name(index).await?)
    }

    async fn switch_description(&self, index: i32) -> Result<String, DriverError> {
        Ok(self.get_switch_description(index).await?)
    }

    async fn can_write(&self, index: i32) -> Result<bool, DriverError> {
        Ok(AlpacaSwitch::can_write(self, index).await?)
    }

    async fn state(&self, index: i32) -> Result<bool, DriverError> {
        Ok(self.get_switch(index).await?)
    }

    async fn set_state(&self, index: i32, on: bool) -> Result<(), DriverError> {
        Ok(self.set_switch(index, on).await?)
    }

    async fn value(&self, index: i32) -> Result<f64, DriverError> {
        Ok(self.get_switch_value(index).await?)
    }

    async fn set_value(&self, index: i32, value: f64) -> Result<(), DriverError> {
        Ok(self.set_switch_value(index, value).await?)
    }

    async fn min_value(&self, index: i32) -> Result<f64, DriverError> {
        Ok(self.min_switch_value(index).await?)
    }

    async fn max_value(&self, index: i32) -> Result<f64, DriverError> {
        Ok(self.max_switch_value(index).await?)
    }
}

#[async_trait]
impl WeatherDriver for AlpacaObservingConditions {
    /// A sensor the station does not have, or one that fails to read, is
    /// `None`; the station itself answering is what the heartbeat checks.
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
impl SafetyMonitorDriver for AlpacaSafetyMonitor {
    async fn is_safe(&self) -> Result<bool, DriverError> {
        Ok(AlpacaSafetyMonitor::is_safe(self).await?)
    }
}

#[async_trait]
impl CoverCalibratorDriver for AlpacaCoverCalibrator {
    async fn open_cover(&self) -> Result<(), DriverError> {
        Ok(AlpacaCoverCalibrator::open_cover(self).await?)
    }

    async fn close_cover(&self) -> Result<(), DriverError> {
        Ok(AlpacaCoverCalibrator::close_cover(self).await?)
    }

    async fn halt_cover(&self) -> Result<(), DriverError> {
        Ok(AlpacaCoverCalibrator::halt_cover(self).await?)
    }

    async fn cover_status(&self) -> Result<CoverStatus, DriverError> {
        Ok(self.cover_state().await?)
    }

    async fn calibrator_on(&self, brightness: i32) -> Result<(), DriverError> {
        Ok(AlpacaCoverCalibrator::calibrator_on(self, brightness).await?)
    }

    async fn calibrator_off(&self) -> Result<(), DriverError> {
        Ok(AlpacaCoverCalibrator::calibrator_off(self).await?)
    }

    async fn calibrator_status(&self) -> Result<CalibratorStatus, DriverError> {
        Ok(self.calibrator_state().await?)
    }

    async fn brightness(&self) -> Result<i32, DriverError> {
        Ok(AlpacaCoverCalibrator::brightness(self).await?)
    }

    async fn max_brightness(&self) -> Result<i32, DriverError> {
        Ok(AlpacaCoverCalibrator::max_brightness(self).await?)
    }

    async fn status(&self) -> Result<CoverCalibratorState, DriverError> {
        let status = self.get_status().await?;
        let max_brightness = AlpacaCoverCalibrator::max_brightness(self)
            .await
            .unwrap_or_else(|e| {
                tracing::warn!(
                    "Failed to read cover calibrator max_brightness at {}: {}. Using default 255.",
                    self.base_url(),
                    e
                );
                255
            });
        Ok(CoverCalibratorState {
            cover: status.cover_state,
            calibrator: status.calibrator_state,
            brightness: status.brightness.unwrap_or(0),
            max_brightness,
        })
    }
}
