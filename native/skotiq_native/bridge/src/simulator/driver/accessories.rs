//! The accessory driver traits over the simulator singletons.
//!
//! A simulated device refuses with the same error a real arm would, so each
//! failure is a [`DeviceOpError`] carried through [`DriverError::Backend`]
//! and handed back unchanged by the ops layer.
//!
//! A simulator's capabilities take what the simulator models (a rotator's
//! reverse support, a dome's shutter) from its state; the live readings that
//! share the capability structs are fixed values the capability cache
//! replaces with live ones on its next read.

use crate::device::{DomeStatus, ShutterState};
use crate::device_capabilities::types::{
    DomeCapabilities, RotatorCapabilities, SafetyMonitorCapabilities, WeatherCapabilities,
};
use crate::device_manager::accessory::{Dome, Rotator, SafetyMonitor, Weather};
use crate::dispatch::error::DeviceOpError;
use crate::error::SkotiqError;
use crate::simulator as sim;
use crate::simulator::cover_calibrator::get_sim_cover_calibrator;
use crate::simulator::environment::{get_sim_dome, get_sim_safety_monitor, get_sim_weather};
use crate::simulator::gate;
use crate::simulator::rotator::get_sim_rotator;
use crate::simulator::switch::get_sim_switch;
use async_trait::async_trait;
use skotiq_device::ascom::{CalibratorStatus, CoverStatus, ShutterStatus};
use skotiq_device::{
    AccessoryDriver, CoverCalibratorDriver, CoverCalibratorState, DomeDriver, DomeState,
    DriverError, RotatorDriver, SafetyMonitorDriver, SwitchDriver, WeatherDriver, WeatherReadings,
};

fn refuse(error: impl Into<DeviceOpError>) -> DriverError {
    DriverError::Backend(Box::new(error.into()))
}

pub(crate) struct SimDome {
    pub(crate) device_id: String,
}

impl SimDome {
    fn not_connected(&self) -> DriverError {
        refuse(DeviceOpError::not_connected(
            Some(self.device_id.clone()),
            "Simulator dome not connected",
        ))
    }

    /// Applies `change` to the connected dome's status.
    async fn command(&self, change: impl FnOnce(&mut DomeStatus)) -> Result<(), DriverError> {
        let mut dome = get_sim_dome().write().await;
        if !dome.status.connected {
            return Err(self.not_connected());
        }
        change(&mut dome.status);
        Ok(())
    }

    async fn read(&self) -> Result<DomeStatus, DriverError> {
        let dome = get_sim_dome().read().await;
        if !dome.status.connected {
            return Err(self.not_connected());
        }
        Ok(dome.status.clone())
    }
}

#[async_trait]
impl AccessoryDriver for SimDome {
    async fn disconnect(&self) -> Result<(), DriverError> {
        get_sim_dome().write().await.status.connected = false;
        Ok(())
    }

    async fn heartbeat(&self) -> Result<(), DriverError> {
        self.read().await.map(|_| ())
    }
}

#[async_trait]
impl DomeDriver for SimDome {
    async fn open_shutter(&self) -> Result<(), DriverError> {
        self.command(|s| {
            s.shutter_status = ShutterState::Open;
            s.at_park = false;
        })
        .await
    }

    async fn close_shutter(&self) -> Result<(), DriverError> {
        self.command(|s| s.shutter_status = ShutterState::Closed)
            .await
    }

    async fn shutter_status(&self) -> Result<ShutterStatus, DriverError> {
        Ok(match self.read().await?.shutter_status {
            ShutterState::Open => ShutterStatus::Open,
            ShutterState::Closed => ShutterStatus::Closed,
            ShutterState::Opening => ShutterStatus::Opening,
            ShutterState::Closing => ShutterStatus::Closing,
            ShutterState::Error | ShutterState::Unknown => ShutterStatus::Error,
        })
    }

    async fn slew_to_azimuth(&self, azimuth_deg: f64) -> Result<(), DriverError> {
        if !azimuth_deg.is_finite() || !(0.0..360.0).contains(&azimuth_deg) {
            return Err(refuse(DeviceOpError::invalid_parameter(
                "Dome azimuth must be finite and in [0, 360)",
            )));
        }
        self.command(|s| {
            s.azimuth = azimuth_deg;
            s.at_home = azimuth_deg == 0.0;
            s.at_park = false;
        })
        .await
    }

    async fn abort_slew(&self) -> Result<(), DriverError> {
        self.command(|s| {
            s.slewing = false;
            s.shutter_status = match s.shutter_status {
                ShutterState::Opening => ShutterState::Closed,
                ShutterState::Closing => ShutterState::Open,
                state => state,
            };
        })
        .await
    }

    async fn park(&self) -> Result<(), DriverError> {
        self.command(|s| {
            s.azimuth = 0.0;
            s.at_home = true;
            s.at_park = true;
        })
        .await
    }

    async fn find_home(&self) -> Result<(), DriverError> {
        self.command(|s| {
            s.azimuth = 0.0;
            s.at_home = true;
            s.at_park = false;
        })
        .await
    }

    async fn set_slaved(&self, slaved: bool) -> Result<(), DriverError> {
        self.command(|s| s.is_slaved = slaved).await
    }

    async fn status(&self) -> Result<DomeState, DriverError> {
        let s = self.read().await?;
        Ok(DomeState {
            azimuth: s.azimuth,
            altitude: s.altitude,
            shutter: match s.shutter_status {
                ShutterState::Open => Some(ShutterStatus::Open),
                ShutterState::Closed => Some(ShutterStatus::Closed),
                ShutterState::Opening => Some(ShutterStatus::Opening),
                ShutterState::Closing => Some(ShutterStatus::Closing),
                ShutterState::Error => Some(ShutterStatus::Error),
                ShutterState::Unknown => None,
            },
            slewing: s.slewing,
            at_home: s.at_home,
            at_park: s.at_park,
            can_set_altitude: s.can_set_altitude,
            can_set_azimuth: s.can_set_azimuth,
            can_set_shutter: s.can_set_shutter,
            can_slave: s.can_slave,
            slaved: s.is_slaved,
        })
    }
}

#[async_trait]
impl Dome for SimDome {
    async fn capabilities(&self, _device_id: &str) -> Result<DomeCapabilities, SkotiqError> {
        let s = get_sim_dome().read().await.status.clone();
        Ok(DomeCapabilities {
            can_set_azimuth: s.can_set_azimuth,
            can_park: true,
            can_find_home: true,
            can_set_shutter: s.can_set_shutter,
            can_sync_azimuth: true,
            azimuth: Some(0.0),
            slewing: false,
            at_home: true,
            at_park: false,
            shutter_status: Some(crate::device_capabilities::types::ShutterStatus::Closed),
            can_slave: s.can_slave,
            slaved: false,
            can_abort: true,
        })
    }
}

/// Written with braces because the binding generator stops on a unit struct
/// that implements a trait of this crate.
pub(crate) struct SimRotator {}

impl SimRotator {
    /// Applies `change` to the connected rotator's status.
    async fn command(
        &self,
        change: impl FnOnce(&mut crate::device::RotatorStatus),
    ) -> Result<(), DriverError> {
        let mut rotator = get_sim_rotator().write().await;
        if !rotator.status.connected {
            return Err(refuse(DeviceOpError::not_connected(
                None,
                gate::not_connected_rotator(),
            )));
        }
        change(&mut rotator.status);
        Ok(())
    }

    async fn read(&self) -> Result<crate::device::RotatorStatus, DriverError> {
        gate::read_rotator_status().await.map_err(refuse)
    }
}

#[async_trait]
impl AccessoryDriver for SimRotator {
    async fn disconnect(&self) -> Result<(), DriverError> {
        get_sim_rotator().write().await.status.connected = false;
        Ok(())
    }

    async fn heartbeat(&self) -> Result<(), DriverError> {
        if get_sim_rotator().read().await.status.connected {
            Ok(())
        } else {
            Err(DriverError::NotConnected)
        }
    }
}

#[async_trait]
impl RotatorDriver for SimRotator {
    async fn move_absolute(&self, position_deg: f64) -> Result<(), DriverError> {
        self.command(|s| {
            s.position = position_deg;
            s.mechanical_position = position_deg;
        })
        .await
    }

    async fn position(&self) -> Result<f64, DriverError> {
        Ok(self.read().await?.position)
    }

    async fn is_moving(&self) -> Result<bool, DriverError> {
        Ok(self.read().await?.moving)
    }

    async fn halt(&self) -> Result<(), DriverError> {
        self.command(|s| {
            s.moving = false;
            s.is_moving = false;
        })
        .await
    }

    async fn sync(&self, position_deg: f64) -> Result<(), DriverError> {
        self.command(|s| {
            s.position = position_deg;
            s.mechanical_position = position_deg;
        })
        .await
    }

    /// The simulated rotator accepts a reverse request only when it says it
    /// can reverse, and does not model the reversed direction.
    async fn set_reverse(&self, _reverse: bool) -> Result<(), DriverError> {
        let rotator = get_sim_rotator().read().await;
        if !rotator.status.connected {
            return Err(refuse(DeviceOpError::not_connected(
                None,
                gate::not_connected_rotator(),
            )));
        }
        if rotator.status.can_reverse {
            Ok(())
        } else {
            Err(refuse(DeviceOpError::unsupported(
                "Simulator rotator does not support reverse",
            )))
        }
    }
}

#[async_trait]
impl Rotator for SimRotator {
    async fn capabilities(&self, _device_id: &str) -> Result<RotatorCapabilities, SkotiqError> {
        let can_reverse = get_sim_rotator().read().await.status.can_reverse;
        Ok(RotatorCapabilities {
            can_reverse,
            reverse: false,
            step_size: Some(0.1),
            is_moving: false,
            mechanical_position: Some(0.0),
            position: Some(0.0),
            can_move_absolute: true,
            can_halt: true,
            can_sync: true,
            min_angle_deg: Some(0.0),
            max_angle_deg: Some(360.0),
        })
    }

    async fn mechanical_position(&self) -> Result<f64, DriverError> {
        Ok(self.read().await?.mechanical_position)
    }
}

pub(crate) struct SimSwitch;

#[async_trait]
impl AccessoryDriver for SimSwitch {
    async fn disconnect(&self) -> Result<(), DriverError> {
        get_sim_switch().write().await.connected = false;
        Ok(())
    }

    async fn heartbeat(&self) -> Result<(), DriverError> {
        if get_sim_switch().read().await.connected {
            Ok(())
        } else {
            Err(DriverError::NotConnected)
        }
    }
}

#[async_trait]
impl SwitchDriver for SimSwitch {
    async fn count(&self) -> Result<i32, DriverError> {
        sim::switch::sim_switch_count().await.map_err(refuse)
    }

    async fn switch_name(&self, index: i32) -> Result<String, DriverError> {
        Ok(sim::switch::sim_switch_read(index)
            .await
            .map_err(refuse)?
            .name)
    }

    async fn switch_description(&self, index: i32) -> Result<String, DriverError> {
        Ok(sim::switch::sim_switch_read(index)
            .await
            .map_err(refuse)?
            .description)
    }

    async fn can_write(&self, index: i32) -> Result<bool, DriverError> {
        Ok(sim::switch::sim_switch_read(index)
            .await
            .map_err(refuse)?
            .writable)
    }

    async fn state(&self, index: i32) -> Result<bool, DriverError> {
        Ok(sim::switch::sim_switch_read(index)
            .await
            .map_err(refuse)?
            .state)
    }

    async fn set_state(&self, index: i32, on: bool) -> Result<(), DriverError> {
        sim::switch::sim_switch_write_state(index, on)
            .await
            .map_err(refuse)
    }

    async fn value(&self, index: i32) -> Result<f64, DriverError> {
        Ok(sim::switch::sim_switch_read(index)
            .await
            .map_err(refuse)?
            .value)
    }

    async fn set_value(&self, index: i32, value: f64) -> Result<(), DriverError> {
        sim::switch::sim_switch_write_value(index, value)
            .await
            .map_err(refuse)
    }

    async fn min_value(&self, index: i32) -> Result<f64, DriverError> {
        Ok(sim::switch::sim_switch_read(index)
            .await
            .map_err(refuse)?
            .min)
    }

    async fn max_value(&self, index: i32) -> Result<f64, DriverError> {
        Ok(sim::switch::sim_switch_read(index)
            .await
            .map_err(refuse)?
            .max)
    }

    async fn step(&self, index: i32) -> Result<f64, DriverError> {
        Ok(sim::switch::sim_switch_read(index)
            .await
            .map_err(refuse)?
            .step)
    }
}

pub(crate) struct SimWeather {
    pub(crate) device_id: String,
}

#[async_trait]
impl AccessoryDriver for SimWeather {
    async fn disconnect(&self) -> Result<(), DriverError> {
        get_sim_weather().write().await.connected = false;
        Ok(())
    }

    async fn heartbeat(&self) -> Result<(), DriverError> {
        self.readings().await.map(|_| ())
    }
}

#[async_trait]
impl WeatherDriver for SimWeather {
    async fn readings(&self) -> Result<WeatherReadings, DriverError> {
        let weather = get_sim_weather().read().await;
        if !weather.connected {
            return Err(refuse(DeviceOpError::not_connected(
                Some(self.device_id.clone()),
                "Simulator weather device not connected",
            )));
        }
        let c = &weather.conditions;
        Ok(WeatherReadings {
            cloud_cover: c.cloud_cover,
            dew_point: c.dew_point,
            humidity: c.humidity,
            pressure: c.pressure,
            rain_rate: c.rain_rate,
            sky_quality: c.sky_quality,
            sky_temperature: c.sky_temperature,
            temperature: c.temperature,
            wind_direction: c.wind_direction,
            wind_speed: c.wind_speed,
        })
    }
}

/// Every reading the simulated station has.
#[async_trait]
impl Weather for SimWeather {
    async fn capabilities(&self, _device_id: &str) -> Result<WeatherCapabilities, SkotiqError> {
        Ok(WeatherCapabilities {
            has_cloud_cover: true,
            has_dew_point: true,
            has_humidity: true,
            has_pressure: true,
            has_rain_rate: true,
            has_sky_brightness: true,
            has_sky_quality: true,
            has_sky_temperature: true,
            has_seeing: true,
            has_temperature: true,
            has_wind_direction: true,
            has_wind_gust: true,
            has_wind_speed: true,
            average_period: Some(60.0),
        })
    }
}

pub(crate) struct SimSafetyMonitor {
    pub(crate) device_id: String,
}

#[async_trait]
impl AccessoryDriver for SimSafetyMonitor {
    async fn disconnect(&self) -> Result<(), DriverError> {
        get_sim_safety_monitor().write().await.status.connected = false;
        Ok(())
    }

    /// Reads the connection only: an injected `safetymonitor.status` fault is
    /// for the next safety read, and a heartbeat must not use it up.
    async fn heartbeat(&self) -> Result<(), DriverError> {
        if get_sim_safety_monitor().read().await.status.connected {
            Ok(())
        } else {
            Err(self.not_connected())
        }
    }
}

impl SimSafetyMonitor {
    fn not_connected(&self) -> DriverError {
        refuse(DeviceOpError::not_connected(
            Some(self.device_id.clone()),
            "Simulator safety monitor not connected",
        ))
    }
}

#[async_trait]
impl SafetyMonitorDriver for SimSafetyMonitor {
    async fn is_safe(&self) -> Result<bool, DriverError> {
        use crate::simulator::faults;
        const FAULT_KEY: &str = "safetymonitor.status";
        if let Err(e) = faults::check(FAULT_KEY).await {
            // `unplug`: the monitor's cable or hub dropped.
            if faults::take_unplug(FAULT_KEY).is_some() {
                get_sim_safety_monitor().write().await.status.connected = false;
            }
            return Err(refuse(e));
        }
        let safety = get_sim_safety_monitor().read().await;
        if !safety.status.connected {
            return Err(self.not_connected());
        }
        Ok(safety.status.is_safe)
    }
}

/// Read from the simulator's state, not through `is_safe`, so a capability
/// read does not use up an injected `safetymonitor.status` fault. A monitor
/// that has dropped reads unsafe.
#[async_trait]
impl SafetyMonitor for SimSafetyMonitor {
    async fn capabilities(
        &self,
        _device_id: &str,
    ) -> Result<SafetyMonitorCapabilities, SkotiqError> {
        let monitor = get_sim_safety_monitor().read().await;
        let (is_safe, description) = if monitor.status.connected {
            (
                monitor.status.is_safe,
                if monitor.status.is_safe {
                    "Simulated conditions are safe"
                } else {
                    "Simulated conditions are unsafe"
                },
            )
        } else {
            (false, "Simulated safety monitor is not connected")
        };
        Ok(SafetyMonitorCapabilities {
            is_safe,
            safety_description: Some(description.to_string()),
        })
    }
}

pub(crate) struct SimCoverCalibrator;

#[async_trait]
impl AccessoryDriver for SimCoverCalibrator {
    async fn disconnect(&self) -> Result<(), DriverError> {
        get_sim_cover_calibrator().write().await.connected = false;
        Ok(())
    }

    async fn heartbeat(&self) -> Result<(), DriverError> {
        if get_sim_cover_calibrator().read().await.connected {
            Ok(())
        } else {
            Err(DriverError::NotConnected)
        }
    }
}

#[async_trait]
impl CoverCalibratorDriver for SimCoverCalibrator {
    async fn open_cover(&self) -> Result<(), DriverError> {
        sim::cover_calibrator::sim_cover_move(true)
            .await
            .map_err(refuse)
    }

    async fn close_cover(&self) -> Result<(), DriverError> {
        sim::cover_calibrator::sim_cover_move(false)
            .await
            .map_err(refuse)
    }

    async fn halt_cover(&self) -> Result<(), DriverError> {
        sim::cover_calibrator::sim_cover_halt()
            .await
            .map_err(refuse)
    }

    async fn cover_status(&self) -> Result<CoverStatus, DriverError> {
        Ok(self.status().await?.cover)
    }

    async fn calibrator_on(&self, brightness: i32) -> Result<(), DriverError> {
        sim::cover_calibrator::sim_calibrator_on(brightness)
            .await
            .map_err(refuse)
    }

    async fn calibrator_off(&self) -> Result<(), DriverError> {
        sim::cover_calibrator::sim_calibrator_off()
            .await
            .map_err(refuse)
    }

    async fn calibrator_status(&self) -> Result<CalibratorStatus, DriverError> {
        Ok(self.status().await?.calibrator)
    }

    async fn brightness(&self) -> Result<i32, DriverError> {
        Ok(self.status().await?.brightness)
    }

    async fn max_brightness(&self) -> Result<i32, DriverError> {
        Ok(self.status().await?.max_brightness)
    }

    async fn status(&self) -> Result<CoverCalibratorState, DriverError> {
        let status = sim::cover_calibrator::sim_cover_status()
            .await
            .map_err(refuse)?;
        Ok(CoverCalibratorState {
            cover: status.cover_state.to_i32().into(),
            calibrator: status.calibrator_state.to_i32().into(),
            brightness: status.brightness,
            max_brightness: status.max_brightness,
        })
    }
}
