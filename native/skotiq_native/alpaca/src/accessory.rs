//! The accessory driver traits over the Alpaca clients.

use crate::{
    AlpacaCoverCalibrator, AlpacaDome, AlpacaObservingConditions, AlpacaRotator,
    AlpacaSafetyMonitor, AlpacaSwitch,
};
use async_trait::async_trait;
use skotiq_device::ascom::dome::{self, DomeMembers};
use skotiq_device::ascom::observing_conditions::{self, ObservingConditionsMembers, Sensor};
use skotiq_device::ascom::{cover_calibrator, CalibratorStatus, CoverStatus, ShutterStatus};
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
alpaca_accessory!(AlpacaSafetyMonitor, connected);
alpaca_accessory!(AlpacaCoverCalibrator, connected);

/// Implements a member trait of `skotiq_device::ascom` by calling the
/// generated Alpaca member of the same name.
macro_rules! alpaca_members {
    ($trait:path, $device:ty { $($name:ident -> $ret:ty;)* }) => {
        #[async_trait]
        impl $trait for $device {
            $(
                async fn $name(&self) -> Result<$ret, DriverError> {
                    Ok(<$device>::$name(self).await?)
                }
            )*
        }
    };
}

alpaca_members!(DomeMembers, AlpacaDome {
    azimuth -> f64;
    altitude -> f64;
    at_home -> bool;
    at_park -> bool;
    shutter_status -> ShutterStatus;
    slewing -> bool;
    slaved -> bool;
    can_find_home -> bool;
    can_park -> bool;
    can_set_altitude -> bool;
    can_set_azimuth -> bool;
    can_set_shutter -> bool;
    can_slave -> bool;
    can_sync_azimuth -> bool;
});

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
        Ok(AlpacaDome::slew_to_azimuth(self, dome::slew_azimuth(azimuth_deg)?).await?)
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
        Ok(dome::report(self).await?.state)
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

    async fn step(&self, index: i32) -> Result<f64, DriverError> {
        Ok(self.switch_step(index).await?)
    }
}

#[async_trait]
impl ObservingConditionsMembers for AlpacaObservingConditions {
    async fn sensor(&self, sensor: Sensor) -> Result<f64, DriverError> {
        Ok(match sensor {
            Sensor::CloudCover => self.cloud_cover().await,
            Sensor::DewPoint => self.dew_point().await,
            Sensor::Humidity => self.humidity().await,
            Sensor::Pressure => self.pressure().await,
            Sensor::RainRate => self.rain_rate().await,
            Sensor::SkyBrightness => self.sky_brightness().await,
            Sensor::SkyQuality => self.sky_quality().await,
            Sensor::SkyTemperature => self.sky_temperature().await,
            Sensor::StarFwhm => self.star_fwhm().await,
            Sensor::Temperature => self.temperature().await,
            Sensor::WindDirection => self.wind_direction().await,
            Sensor::WindGust => self.wind_gust().await,
            Sensor::WindSpeed => self.wind_speed().await,
        }?)
    }

    async fn average_period(&self) -> Result<f64, DriverError> {
        Ok(AlpacaObservingConditions::average_period(self).await?)
    }
}

#[async_trait]
impl WeatherDriver for AlpacaObservingConditions {
    async fn readings(&self) -> Result<WeatherReadings, DriverError> {
        observing_conditions::readings(self).await
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
        cover_calibrator::state(self).await
    }
}
