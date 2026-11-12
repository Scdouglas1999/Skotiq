//! What each connected accessory supports, read from its handle.
//!
//! A switch box and a cover calibrator answer through the operations of their
//! driver trait, so every protocol reports them the same way. A rotator, dome,
//! weather station and safety monitor report properties the operations do not
//! read (a rotator's reverse support, a dome's park support), so each of them
//! is a bridge trait over its `skotiq_device` driver trait with one
//! `capabilities` per protocol: Alpaca and INDI here, next to nothing else
//! because their operations live in their own crates; the simulators in
//! [`super::simulated`] and the ASCOM wrappers in `ascom_wrapper::accessory`,
//! next to their operations.

use crate::device::{CalibratorState, CoverState};
use crate::device_capabilities::{
    CoverCalibratorCapabilities, DomeCapabilities, RotatorCapabilities, SafetyMonitorCapabilities,
    ShutterStatus, SwitchCapabilities, SwitchInfo, WeatherCapabilities,
};
use crate::error::SkotiqError;
use async_trait::async_trait;
use skotiq_alpaca::{AlpacaDome, AlpacaObservingConditions, AlpacaRotator, AlpacaSafetyMonitor};
use skotiq_device::{
    CoverCalibratorDriver, DomeDriver, DriverError, RotatorDriver, SafetyMonitorDriver,
    SwitchDriver, WeatherDriver,
};
use skotiq_indi::names as indi;
use skotiq_indi::{
    IndiClient, IndiDome, IndiProperty, IndiRotator, IndiSafetyMonitor, IndiWeather,
};
use std::sync::Arc;
use tokio::sync::RwLock;

#[async_trait]
pub(crate) trait Rotator: RotatorDriver {
    async fn capabilities(&self, device_id: &str) -> Result<RotatorCapabilities, SkotiqError>;

    /// Degrees the mechanism is at, before any sync offset.
    async fn mechanical_position(&self) -> Result<f64, DriverError>;
}

/// The `IRotatorV4` properties beyond the [`RotatorDriver`] operations,
/// carried by Alpaca or COM. What they mean is decided once, in
/// [`ascom_rotator_capabilities`] and [`ascom_mechanical_position`].
#[async_trait]
pub(crate) trait AscomRotatorMembers: RotatorDriver {
    async fn interface_version(&self) -> Result<i32, DriverError>;
    async fn can_reverse(&self) -> Result<bool, DriverError>;
    async fn reverse(&self) -> Result<bool, DriverError>;
    /// Degrees.
    async fn step_size(&self) -> Result<f64, DriverError>;
    async fn ascom_mechanical_position(&self) -> Result<f64, DriverError>;
}

/// `Sync`, `MoveMechanical` and `MechanicalPosition` arrived with IRotatorV3;
/// a driver that does not say its version is taken as V1.
async fn ascom_rotator_version(rotator: &dyn AscomRotatorMembers) -> i32 {
    rotator.interface_version().await.unwrap_or(1)
}

/// Before IRotatorV3 there is no sync offset, so the mechanism is at
/// `Position`.
pub(crate) async fn ascom_mechanical_position(
    rotator: &dyn AscomRotatorMembers,
) -> Result<f64, DriverError> {
    if ascom_rotator_version(rotator).await >= 3 {
        rotator.ascom_mechanical_position().await
    } else {
        rotator.position().await
    }
}

/// An unanswered optional property means the feature is absent. `Reverse` is
/// read only where `CanReverse` says it exists, as NINA does. `Halt` and
/// `MoveAbsolute` are offered; a driver without them says so when called.
/// IRotator has no angle limits: positions wrap within 0-360.
pub(crate) async fn ascom_rotator_capabilities(
    rotator: &dyn AscomRotatorMembers,
) -> RotatorCapabilities {
    let version = ascom_rotator_version(rotator).await;
    let can_reverse = rotator.can_reverse().await.unwrap_or(false);
    RotatorCapabilities {
        can_reverse,
        reverse: can_reverse && rotator.reverse().await.unwrap_or(false),
        step_size: rotator.step_size().await.ok(),
        is_moving: rotator.is_moving().await.unwrap_or(false),
        mechanical_position: ascom_mechanical_position(rotator).await.ok(),
        position: rotator.position().await.ok(),
        can_move_absolute: true,
        can_halt: true,
        can_sync: version >= 3,
        min_angle_deg: None,
        max_angle_deg: None,
    }
}

#[async_trait]
pub(crate) trait Dome: DomeDriver {
    async fn capabilities(&self, device_id: &str) -> Result<DomeCapabilities, SkotiqError>;
}

#[async_trait]
pub(crate) trait Weather: WeatherDriver {
    async fn capabilities(&self, device_id: &str) -> Result<WeatherCapabilities, SkotiqError>;
}

#[async_trait]
pub(crate) trait SafetyMonitor: SafetyMonitorDriver {
    async fn capabilities(&self, device_id: &str)
        -> Result<SafetyMonitorCapabilities, SkotiqError>;
}

/// Every channel of a switch box, read through the operations that drive it.
///
/// A channel property the driver refuses to answer gets the reading a
/// channel without it has: an unnamed channel is called by its index, an
/// unreadable range is 0..1 (a plain on/off switch), and a channel whose
/// writability is unknown is read-only, so nothing is written to it before
/// the user has seen it.
pub(crate) async fn switch_capabilities(switch: &dyn SwitchDriver) -> SwitchCapabilities {
    let count = switch.count().await.unwrap_or(0);
    let mut switches = Vec::new();
    for index in 0..count {
        let min_value = switch.min_value(index).await.unwrap_or(0.0);
        let max_value = switch.max_value(index).await.unwrap_or(1.0);
        switches.push(SwitchInfo {
            index,
            name: switch
                .switch_name(index)
                .await
                .unwrap_or_else(|_| format!("Switch {}", index)),
            description: switch.switch_description(index).await.unwrap_or_default(),
            is_boolean: (min_value == 0.0 && max_value == 1.0) || min_value == max_value,
            min_value,
            max_value,
            // No protocol reports a step through the switch operations.
            step: 1.0,
            can_write: switch.can_write(index).await.unwrap_or(false),
            value: switch.value(index).await.unwrap_or(0.0),
        });
    }
    SwitchCapabilities {
        switch_count: count,
        switches,
    }
}

/// A cover calibrator's cover, panel and brightness, read through the
/// operations that drive it. A missing maximum brightness is 0: a cover-only
/// device has no brightness levels.
pub(crate) async fn cover_calibrator_capabilities(
    device: &dyn CoverCalibratorDriver,
) -> CoverCalibratorCapabilities {
    let cover_state = device
        .cover_status()
        .await
        .ok()
        .map(|s| CoverState::from_i32(s as i32));
    let calibrator_state = device
        .calibrator_status()
        .await
        .ok()
        .map(|s| CalibratorState::from_i32(s as i32));
    CoverCalibratorCapabilities {
        max_brightness: device.max_brightness().await.unwrap_or(0),
        cover_present: cover_state.is_some_and(|s| s != CoverState::NotPresent),
        calibrator_present: calibrator_state.is_some_and(|s| s != CalibratorState::NotPresent),
        cover_state,
        calibrator_state,
        brightness: device.brightness().await.ok(),
    }
}

// Alpaca. The `unwrap_or` defaults below are what the ASCOM interface means
// when a driver does not implement an optional property: the feature is
// absent, the device is not in that state.

#[async_trait]
impl AscomRotatorMembers for AlpacaRotator {
    async fn interface_version(&self) -> Result<i32, DriverError> {
        Ok(AlpacaRotator::interface_version(self).await?)
    }
    async fn can_reverse(&self) -> Result<bool, DriverError> {
        Ok(AlpacaRotator::can_reverse(self).await?)
    }
    async fn reverse(&self) -> Result<bool, DriverError> {
        Ok(AlpacaRotator::reverse(self).await?)
    }
    async fn step_size(&self) -> Result<f64, DriverError> {
        Ok(AlpacaRotator::step_size(self).await?)
    }
    async fn ascom_mechanical_position(&self) -> Result<f64, DriverError> {
        Ok(AlpacaRotator::mechanical_position(self).await?)
    }
}

#[async_trait]
impl Rotator for AlpacaRotator {
    async fn capabilities(&self, _device_id: &str) -> Result<RotatorCapabilities, SkotiqError> {
        Ok(ascom_rotator_capabilities(self).await)
    }

    async fn mechanical_position(&self) -> Result<f64, DriverError> {
        ascom_mechanical_position(self).await
    }
}

#[async_trait]
impl Dome for AlpacaDome {
    async fn capabilities(&self, _device_id: &str) -> Result<DomeCapabilities, SkotiqError> {
        let shutter_status = AlpacaDome::shutter_status(self)
            .await
            .ok()
            .map(|s| match s {
                skotiq_alpaca::ShutterStatus::Open => ShutterStatus::Open,
                skotiq_alpaca::ShutterStatus::Closed => ShutterStatus::Closed,
                skotiq_alpaca::ShutterStatus::Opening => ShutterStatus::Opening,
                skotiq_alpaca::ShutterStatus::Closing => ShutterStatus::Closing,
                skotiq_alpaca::ShutterStatus::Error => ShutterStatus::Unknown,
            });
        Ok(DomeCapabilities {
            can_set_azimuth: self.can_set_azimuth().await.unwrap_or(false),
            can_park: self.can_park().await.unwrap_or(false),
            can_find_home: self.can_find_home().await.unwrap_or(false),
            can_set_shutter: self.can_set_shutter().await.unwrap_or(false),
            can_sync_azimuth: self.can_sync_azimuth().await.unwrap_or(false),
            azimuth: self.azimuth().await.ok(),
            slewing: self.slewing().await.unwrap_or(false),
            at_home: self.at_home().await.unwrap_or(false),
            at_park: self.at_park().await.unwrap_or(false),
            shutter_status,
            can_slave: self.can_slave().await.unwrap_or(false),
            slaved: self.slaved().await.unwrap_or(false),
            can_abort: true,
        })
    }
}

#[async_trait]
impl Weather for AlpacaObservingConditions {
    /// A sensor the station does not have answers with an error.
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
            // Seeing (StarFWHM) is not read over Alpaca.
            has_seeing: false,
            has_temperature: self.temperature().await.is_ok(),
            has_wind_direction: self.wind_direction().await.is_ok(),
            has_wind_gust: self.wind_gust().await.is_ok(),
            has_wind_speed: self.wind_speed().await.is_ok(),
            average_period: self.average_period().await.ok(),
        })
    }
}

#[async_trait]
impl SafetyMonitor for AlpacaSafetyMonitor {
    async fn capabilities(
        &self,
        _device_id: &str,
    ) -> Result<SafetyMonitorCapabilities, SkotiqError> {
        Ok(SafetyMonitorCapabilities {
            // A monitor that cannot be read is never reported safe.
            is_safe: AlpacaSafetyMonitor::is_safe(self).await.unwrap_or(false),
            safety_description: None,
        })
    }
}

// INDI. A capability is the presence of the standard property that drives
// it; the live values come from the shared server connection.

async fn indi_properties(client: &Arc<RwLock<IndiClient>>, device_name: &str) -> Vec<IndiProperty> {
    client.read().await.get_properties(device_name).await
}

fn has(properties: &[IndiProperty], name: &str) -> bool {
    properties.iter().any(|p| p.name == name)
}

#[async_trait]
impl Rotator for IndiRotator {
    async fn capabilities(&self, _device_id: &str) -> Result<RotatorCapabilities, SkotiqError> {
        let device_name = self.device_name();
        let properties = indi_properties(self.client(), device_name).await;
        let has_abs_angle = has(&properties, indi::ABS_ROTATOR_ANGLE);
        // The absolute angle is ABS_ROTATOR_ANGLE/ANGLE, the legacy one
        // ROTATOR_ANGLE/ANGLE; the position and its limits come from the one
        // the driver published.
        let angle_property = if has_abs_angle {
            indi::ABS_ROTATOR_ANGLE
        } else {
            indi::ROTATOR_ANGLE
        };
        let (position, limits) = {
            let client = self.client().read().await;
            (
                client
                    .get_number(device_name, angle_property, indi::ANGLE)
                    .await,
                client
                    .get_number_limits(device_name, angle_property, indi::ANGLE)
                    .await,
            )
        };
        Ok(RotatorCapabilities {
            can_reverse: has(&properties, indi::ROTATOR_REVERSE),
            // The reverse state, step size and motion are read live by the
            // rotator's status, not reported here.
            reverse: false,
            step_size: None,
            is_moving: false,
            // One angle: mechanical and sky position coincide until a sync
            // offset is applied.
            mechanical_position: position,
            position,
            can_move_absolute: has_abs_angle,
            can_halt: has(&properties, indi::ROTATOR_ABORT_MOTION),
            can_sync: has(&properties, indi::SYNC_ROTATOR_ANGLE),
            min_angle_deg: limits.as_ref().and_then(|l| l.min),
            max_angle_deg: limits.as_ref().and_then(|l| l.max),
        })
    }

    /// The raw (encoder) angle where the driver publishes one, otherwise the
    /// one angle it has.
    async fn mechanical_position(&self) -> Result<f64, DriverError> {
        match self.get_mechanical_position().await {
            Ok(angle) => Ok(angle),
            Err(_) => RotatorDriver::position(self).await,
        }
    }
}

#[async_trait]
impl Dome for IndiDome {
    async fn capabilities(&self, _device_id: &str) -> Result<DomeCapabilities, SkotiqError> {
        let device_name = self.device_name();
        let properties = indi_properties(self.client(), device_name).await;
        // Home and park both go through DOME_GOTO (DOME_HOME / DOME_PARK);
        // unpark also uses the DOME_PARK switch.
        let has_goto = has(&properties, indi::DOME_GOTO);

        let client = self.client().read().await;
        let azimuth = client
            .get_number(
                device_name,
                indi::ABS_DOME_POSITION,
                indi::DOME_ABSOLUTE_POSITION,
            )
            .await;
        let shutter_open = client
            .get_switch(device_name, indi::DOME_SHUTTER, indi::SHUTTER_OPEN)
            .await;
        let shutter_close = client
            .get_switch(device_name, indi::DOME_SHUTTER, indi::SHUTTER_CLOSE)
            .await;
        let shutter_busy = client
            .is_property_busy(device_name, indi::DOME_SHUTTER)
            .await;
        let shutter_status = match (shutter_open, shutter_close, shutter_busy) {
            (Some(true), Some(false), true) => Some(ShutterStatus::Opening),
            (Some(false), Some(true), true) => Some(ShutterStatus::Closing),
            (Some(true), Some(false), false) => Some(ShutterStatus::Open),
            (Some(false), Some(true), false) => Some(ShutterStatus::Closed),
            _ => None,
        };
        let at_home = client
            .get_switch(device_name, indi::DOME_GOTO, indi::DOME_HOME)
            .await
            .unwrap_or(false);
        let at_park = client
            .get_switch(device_name, indi::DOME_PARK, indi::PARK)
            .await
            .unwrap_or(false)
            || client
                .get_switch(device_name, indi::DOME_GOTO, indi::DOME_PARK)
                .await
                .unwrap_or(false);
        let slewing = client
            .is_property_busy(device_name, indi::ABS_DOME_POSITION)
            .await
            || shutter_busy;
        let slaved = client
            .get_switch(device_name, indi::DOME_AUTOSYNC, indi::DOME_AUTOSYNC_ENABLE)
            .await
            .unwrap_or(false);
        drop(client);

        Ok(DomeCapabilities {
            can_set_azimuth: has(&properties, indi::ABS_DOME_POSITION),
            can_park: has_goto || has(&properties, indi::DOME_PARK),
            can_find_home: has_goto,
            can_set_shutter: has(&properties, indi::DOME_SHUTTER),
            // INDI has no standard sync-azimuth property.
            can_sync_azimuth: false,
            azimuth,
            slewing,
            at_home,
            at_park,
            shutter_status,
            can_slave: has(&properties, indi::DOME_AUTOSYNC),
            slaved,
            can_abort: has(&properties, indi::DOME_ABORT_MOTION),
        })
    }
}

fn indi_unsupported(device_id: &str) -> SkotiqError {
    SkotiqError::not_supported(
        device_id,
        "Could not determine INDI device type from properties",
    )
}

#[async_trait]
impl Weather for IndiWeather {
    async fn capabilities(&self, device_id: &str) -> Result<WeatherCapabilities, SkotiqError> {
        Err(indi_unsupported(device_id))
    }
}

#[async_trait]
impl SafetyMonitor for IndiSafetyMonitor {
    async fn capabilities(
        &self,
        device_id: &str,
    ) -> Result<SafetyMonitorCapabilities, SkotiqError> {
        Err(indi_unsupported(device_id))
    }
}
