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
use crate::device_capabilities::types::{
    CoverCalibratorCapabilities, DomeCapabilities, RotatorCapabilities, SafetyMonitorCapabilities,
    ShutterStatus, SwitchCapabilities, SwitchInfo, WeatherCapabilities,
};
use crate::device_manager::handle::device_error;
use crate::error::SkotiqError;
use async_trait::async_trait;
use skotiq_alpaca::{AlpacaDome, AlpacaObservingConditions, AlpacaRotator, AlpacaSafetyMonitor};
use skotiq_device::ascom::dome::DomeReport;
use skotiq_device::ascom::observing_conditions::{ObservingConditionsMembers, Sensor};
use skotiq_device::ascom::{
    dome as ascom_dome, observing_conditions as ascom_weather, optional as ascom_optional,
    ShutterStatus as AscomShutter,
};
use skotiq_device::{
    CoverCalibratorDriver, DomeDriver, DriverError, RotatorDriver, SafetyMonitorDriver,
    SwitchDriver, WeatherDriver,
};
use skotiq_indi::{
    names as indi, IndiClient, IndiDome, IndiProperty, IndiRotator, IndiSafetyMonitor, IndiWeather,
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
/// a driver that explicitly lacks InterfaceVersion is V1.
async fn ascom_rotator_version(rotator: &dyn AscomRotatorMembers) -> Result<i32, DriverError> {
    Ok(ascom_optional(rotator.interface_version().await)?.unwrap_or(1))
}

/// Before IRotatorV3 there is no sync offset, so the mechanism is at
/// `Position`.
pub(crate) async fn ascom_mechanical_position(
    rotator: &dyn AscomRotatorMembers,
) -> Result<f64, DriverError> {
    if ascom_rotator_version(rotator).await? >= 3 {
        rotator.ascom_mechanical_position().await
    } else {
        rotator.position().await
    }
}

/// An explicitly unsupported optional property means the feature is absent.
/// `Reverse` is read only where `CanReverse` says it exists. `Halt` and
/// `MoveAbsolute` are offered; a driver without them says so when called.
/// IRotator has no angle limits: positions wrap within 0-360.
pub(crate) async fn ascom_rotator_capabilities(
    rotator: &dyn AscomRotatorMembers,
) -> Result<RotatorCapabilities, DriverError> {
    let version = ascom_rotator_version(rotator).await?;
    let can_reverse = ascom_optional(rotator.can_reverse().await)?.unwrap_or(false);
    Ok(RotatorCapabilities {
        can_reverse,
        reverse: can_reverse && rotator.reverse().await?,
        step_size: rotator.step_size().await.ok(),
        is_moving: rotator.is_moving().await?,
        mechanical_position: ascom_mechanical_position(rotator).await.ok(),
        position: rotator.position().await.ok(),
        can_move_absolute: true,
        can_halt: true,
        can_sync: version >= 3,
        min_angle_deg: None,
        max_angle_deg: None,
    })
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
/// Explicitly unsupported ranges use the on/off interface's 0..1 in steps
/// of 1. A read failure remains a failure, so an analog channel is never
/// presented as an on/off port because its range was temporarily unreadable.
/// Before CanWrite existed, every switch was writable; other CanWrite
/// failures keep a channel read-only.
pub(crate) async fn switch_capabilities(
    switch: &dyn SwitchDriver,
) -> Result<SwitchCapabilities, DriverError> {
    let count = switch.count().await?;
    let mut switches = Vec::new();
    for index in 0..count {
        let min_value = ascom_optional(switch.min_value(index).await)?.unwrap_or(0.0);
        let max_value = ascom_optional(switch.max_value(index).await)?.unwrap_or(1.0);
        let step = ascom_optional(switch.step(index).await)?.unwrap_or(1.0);
        let value = match switch.value(index).await {
            Ok(value) => value,
            Err(DriverError::NotSupported) => {
                if switch.state(index).await? {
                    1.0
                } else {
                    0.0
                }
            }
            Err(error) => return Err(error),
        };
        let can_write = match switch.can_write(index).await {
            Ok(can_write) => can_write,
            Err(DriverError::NotSupported) => true,
            Err(_) => false,
        };
        switches.push(SwitchInfo {
            index,
            name: switch
                .switch_name(index)
                .await
                .unwrap_or_else(|_| format!("Switch {}", index)),
            description: switch.switch_description(index).await.unwrap_or_default(),
            // Two values, off and on, make a switch rather than a gauge or a
            // dial.
            is_boolean: max_value <= min_value || (max_value - min_value - step).abs() < 1e-9,
            min_value,
            max_value,
            step,
            can_write,
            value,
        });
    }
    Ok(SwitchCapabilities {
        switch_count: count,
        switches,
    })
}

/// The value a switch is sent for `requested`: the nearest whole number of
/// steps above its minimum, which is all `SetSwitchValue` accepts. A value
/// outside the range goes out as asked, for the switch to refuse in its own
/// words.
pub(crate) fn switch_value_on_step(requested: f64, min: f64, max: f64, step: f64) -> f64 {
    if !(requested >= min && requested <= max && step.is_finite() && step > 0.0) {
        return requested;
    }
    let mut steps = ((requested - min) / step).round();
    if min + steps * step > max + 1e-9 {
        steps = ((max - min) / step + 1e-9).floor();
    }
    let on_step = min + steps * step;
    // Whole steps of a decimal step (0.1) are not exact in binary; round off
    // the last bits so the driver sees 0.3, not 0.30000000000000004.
    (on_step * 1e9).round() / 1e9
}

/// A cover calibrator's cover, panel and brightness, read through the
/// operations that drive it. Explicitly unsupported maximum brightness is 0:
/// a cover-only device has no brightness levels. Other read failures propagate.
pub(crate) async fn cover_calibrator_capabilities(
    device: &dyn CoverCalibratorDriver,
) -> Result<CoverCalibratorCapabilities, DriverError> {
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
    Ok(CoverCalibratorCapabilities {
        max_brightness: ascom_optional(device.max_brightness().await)?.unwrap_or(0),
        cover_present: cover_state.is_some_and(|s| s != CoverState::NotPresent),
        calibrator_present: calibrator_state.is_some_and(|s| s != CalibratorState::NotPresent),
        cover_state,
        calibrator_state,
        brightness: device.brightness().await.ok(),
    })
}

// Alpaca. The rotator follows `ascom_rotator_capabilities` above, the dome
// and weather station the rules of `skotiq_device::ascom`; the COM wrappers
// use the same ones.

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
    async fn capabilities(&self, device_id: &str) -> Result<RotatorCapabilities, SkotiqError> {
        ascom_rotator_capabilities(self)
            .await
            .map_err(|e| device_error(device_id, e).into())
    }

    async fn mechanical_position(&self) -> Result<f64, DriverError> {
        ascom_mechanical_position(self).await
    }
}

#[async_trait]
impl Dome for AlpacaDome {
    async fn capabilities(&self, device_id: &str) -> Result<DomeCapabilities, SkotiqError> {
        let report = ascom_dome::report(self)
            .await
            .map_err(|e| SkotiqError::from(device_error(device_id, e)))?;
        Ok(dome_capabilities(report))
    }
}

#[async_trait]
impl Weather for AlpacaObservingConditions {
    async fn capabilities(&self, device_id: &str) -> Result<WeatherCapabilities, SkotiqError> {
        weather_capabilities(self)
            .await
            .map_err(|e| SkotiqError::from(device_error(device_id, e)))
    }
}

#[async_trait]
impl SafetyMonitor for AlpacaSafetyMonitor {
    async fn capabilities(
        &self,
        device_id: &str,
    ) -> Result<SafetyMonitorCapabilities, SkotiqError> {
        Ok(SafetyMonitorCapabilities {
            is_safe: SafetyMonitorDriver::is_safe(self)
                .await
                .map_err(|e| SkotiqError::from(device_error(device_id, e)))?,
            safety_description: None,
        })
    }
}

/// An ASCOM dome's capabilities, over either transport.
pub(crate) fn dome_capabilities(report: DomeReport) -> DomeCapabilities {
    let state = report.state;
    DomeCapabilities {
        can_set_azimuth: state.can_set_azimuth,
        can_park: report.can_park,
        can_find_home: report.can_find_home,
        can_set_shutter: state.can_set_shutter,
        can_sync_azimuth: report.can_sync_azimuth,
        azimuth: report.azimuth,
        slewing: state.slewing,
        at_home: state.at_home,
        at_park: state.at_park,
        shutter_status: state.shutter.map(|s| match s {
            AscomShutter::Open => ShutterStatus::Open,
            AscomShutter::Closed => ShutterStatus::Closed,
            AscomShutter::Opening => ShutterStatus::Opening,
            AscomShutter::Closing => ShutterStatus::Closing,
            AscomShutter::Error => ShutterStatus::Unknown,
        }),
        can_slave: state.can_slave,
        slaved: state.slaved,
        // AbortSlew is mandatory in IDomeV3.
        can_abort: true,
    }
}

/// An ASCOM weather station's sensors, over either transport: a sensor is
/// present when reading it does not raise `NotImplemented`.
pub(crate) async fn weather_capabilities(
    station: &dyn ObservingConditionsMembers,
) -> Result<WeatherCapabilities, DriverError> {
    let present: Vec<Sensor> = ascom_weather::sensors(station)
        .await?
        .into_iter()
        .filter_map(|(sensor, value)| value.map(|_| sensor))
        .collect();
    let has = |sensor| present.contains(&sensor);
    Ok(WeatherCapabilities {
        has_cloud_cover: has(Sensor::CloudCover),
        has_dew_point: has(Sensor::DewPoint),
        has_humidity: has(Sensor::Humidity),
        has_pressure: has(Sensor::Pressure),
        has_rain_rate: has(Sensor::RainRate),
        has_sky_brightness: has(Sensor::SkyBrightness),
        has_sky_quality: has(Sensor::SkyQuality),
        has_sky_temperature: has(Sensor::SkyTemperature),
        has_seeing: has(Sensor::StarFwhm),
        has_temperature: has(Sensor::Temperature),
        has_wind_direction: has(Sensor::WindDirection),
        has_wind_gust: has(Sensor::WindGust),
        has_wind_speed: has(Sensor::WindSpeed),
        average_period: ascom_optional(station.average_period().await)?,
    })
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

#[cfg(test)]
mod tests {
    use super::*;
    use skotiq_device::AccessoryDriver;

    #[derive(Default)]
    struct SyncedRotator {
        fail_on: Option<&'static str>,
        unsupported: bool,
    }

    impl SyncedRotator {
        fn check(&self, member: &str) -> Result<(), DriverError> {
            if self.fail_on != Some(member) {
                Ok(())
            } else if self.unsupported {
                Err(DriverError::NotSupported)
            } else {
                Err(DriverError::SdkError(format!("{member} read failed")))
            }
        }
    }

    #[async_trait]
    impl AccessoryDriver for SyncedRotator {
        async fn disconnect(&self) -> Result<(), DriverError> {
            Ok(())
        }
        async fn heartbeat(&self) -> Result<(), DriverError> {
            Ok(())
        }
    }

    #[async_trait]
    impl RotatorDriver for SyncedRotator {
        async fn move_absolute(&self, _position_deg: f64) -> Result<(), DriverError> {
            Ok(())
        }
        async fn position(&self) -> Result<f64, DriverError> {
            Ok(45.0)
        }
        async fn is_moving(&self) -> Result<bool, DriverError> {
            self.check("IsMoving")?;
            Ok(true)
        }
        async fn halt(&self) -> Result<(), DriverError> {
            Ok(())
        }
        async fn sync(&self, _position_deg: f64) -> Result<(), DriverError> {
            Ok(())
        }
        async fn set_reverse(&self, _reverse: bool) -> Result<(), DriverError> {
            Ok(())
        }
    }

    #[async_trait]
    impl AscomRotatorMembers for SyncedRotator {
        async fn interface_version(&self) -> Result<i32, DriverError> {
            self.check("InterfaceVersion")?;
            Ok(4)
        }
        async fn can_reverse(&self) -> Result<bool, DriverError> {
            self.check("CanReverse")?;
            Ok(true)
        }
        async fn reverse(&self) -> Result<bool, DriverError> {
            self.check("Reverse")?;
            Ok(true)
        }
        async fn step_size(&self) -> Result<f64, DriverError> {
            Ok(0.1)
        }
        async fn ascom_mechanical_position(&self) -> Result<f64, DriverError> {
            Ok(10.0)
        }
    }

    #[tokio::test]
    async fn unreadable_rotator_version_does_not_substitute_synced_position_for_mechanical() {
        assert_eq!(
            ascom_mechanical_position(&SyncedRotator::default())
                .await
                .unwrap(),
            10.0
        );
        let rotator = SyncedRotator {
            fail_on: Some("InterfaceVersion"),
            unsupported: false,
        };
        assert!(ascom_mechanical_position(&rotator).await.is_err());
        let v1 = SyncedRotator {
            unsupported: true,
            ..rotator
        };
        assert_eq!(ascom_mechanical_position(&v1).await.unwrap(), 45.0);
    }

    #[tokio::test]
    async fn rotator_read_failures_do_not_report_unsupported_disabled_or_stopped() {
        for member in ["InterfaceVersion", "CanReverse", "Reverse", "IsMoving"] {
            let rotator = SyncedRotator {
                fail_on: Some(member),
                unsupported: false,
            };
            let error = ascom_rotator_capabilities(&rotator).await.unwrap_err();
            assert!(error.to_string().contains(member), "{member}: {error}");
        }
        let rotator = SyncedRotator {
            fail_on: Some("CanReverse"),
            unsupported: true,
        };
        let caps = ascom_rotator_capabilities(&rotator).await.unwrap();
        assert!(!caps.can_reverse && !caps.reverse);
        assert!(caps.can_sync && caps.is_moving);
    }

    struct Panel {
        has_panel: bool,
    }

    #[async_trait]
    impl AccessoryDriver for Panel {
        async fn disconnect(&self) -> Result<(), DriverError> {
            Ok(())
        }
        async fn heartbeat(&self) -> Result<(), DriverError> {
            Ok(())
        }
    }

    #[async_trait]
    impl CoverCalibratorDriver for Panel {
        async fn open_cover(&self) -> Result<(), DriverError> {
            Ok(())
        }
        async fn close_cover(&self) -> Result<(), DriverError> {
            Ok(())
        }
        async fn halt_cover(&self) -> Result<(), DriverError> {
            Ok(())
        }
        async fn cover_status(&self) -> Result<skotiq_device::ascom::CoverStatus, DriverError> {
            Ok(skotiq_device::ascom::CoverStatus::NotPresent)
        }
        async fn calibrator_on(&self, _brightness: i32) -> Result<(), DriverError> {
            Ok(())
        }
        async fn calibrator_off(&self) -> Result<(), DriverError> {
            Ok(())
        }
        async fn calibrator_status(
            &self,
        ) -> Result<skotiq_device::ascom::CalibratorStatus, DriverError> {
            Ok(skotiq_device::ascom::CalibratorStatus::Off)
        }
        async fn brightness(&self) -> Result<i32, DriverError> {
            Ok(0)
        }
        async fn max_brightness(&self) -> Result<i32, DriverError> {
            if self.has_panel {
                Err(DriverError::SdkError("brightness read failed".to_string()))
            } else {
                Err(DriverError::NotSupported)
            }
        }
        async fn status(&self) -> Result<skotiq_device::CoverCalibratorState, DriverError> {
            Err(DriverError::NotSupported)
        }
    }

    #[tokio::test]
    async fn unreadable_brightness_limit_is_not_a_zero_brightness_range() {
        let panel = Panel { has_panel: true };
        let error = cover_calibrator_capabilities(&panel).await.unwrap_err();
        assert!(
            error.to_string().contains("brightness read failed"),
            "{error}"
        );
        let cover_only = Panel { has_panel: false };
        assert_eq!(
            cover_calibrator_capabilities(&cover_only)
                .await
                .unwrap()
                .max_brightness,
            0
        );
    }

    /// Channel 0: an `ISwitchV1` switch (nothing but name and state).
    /// Channel 1: a dew heater, 0 to 1 in steps of 0.01.
    /// Channel 2: a power port, 0 to 1 in steps of 1.
    #[derive(Default)]
    struct PowerBox {
        fail_on: Option<&'static str>,
        on: bool,
    }

    impl PowerBox {
        fn check(&self, member: &str) -> Result<(), DriverError> {
            if self.fail_on == Some(member) {
                Err(DriverError::SdkError(format!("{member} read failed")))
            } else {
                Ok(())
            }
        }
    }

    #[async_trait]
    impl AccessoryDriver for PowerBox {
        async fn disconnect(&self) -> Result<(), DriverError> {
            Ok(())
        }
        async fn heartbeat(&self) -> Result<(), DriverError> {
            Ok(())
        }
    }

    #[async_trait]
    impl SwitchDriver for PowerBox {
        async fn count(&self) -> Result<i32, DriverError> {
            self.check("count")?;
            Ok(3)
        }
        async fn switch_name(&self, index: i32) -> Result<String, DriverError> {
            Ok(format!("Port {index}"))
        }
        async fn switch_description(&self, _index: i32) -> Result<String, DriverError> {
            Err(DriverError::NotSupported)
        }
        async fn can_write(&self, index: i32) -> Result<bool, DriverError> {
            if index == 0 {
                Err(DriverError::NotSupported)
            } else {
                Ok(true)
            }
        }
        async fn state(&self, _index: i32) -> Result<bool, DriverError> {
            self.check("state")?;
            Ok(self.on)
        }
        async fn set_state(&self, _index: i32, _on: bool) -> Result<(), DriverError> {
            Ok(())
        }
        async fn value(&self, index: i32) -> Result<f64, DriverError> {
            self.check("value")?;
            if index == 0 {
                Err(DriverError::NotSupported)
            } else {
                Ok(0.0)
            }
        }
        async fn set_value(&self, _index: i32, _value: f64) -> Result<(), DriverError> {
            Ok(())
        }
        async fn min_value(&self, index: i32) -> Result<f64, DriverError> {
            self.check("min_value")?;
            if index == 0 {
                Err(DriverError::NotSupported)
            } else {
                Ok(0.0)
            }
        }
        async fn max_value(&self, index: i32) -> Result<f64, DriverError> {
            self.check("max_value")?;
            if index == 0 {
                Err(DriverError::NotSupported)
            } else {
                Ok(1.0)
            }
        }
        async fn step(&self, index: i32) -> Result<f64, DriverError> {
            self.check("step")?;
            match index {
                0 => Err(DriverError::NotSupported),
                1 => Ok(0.01),
                _ => Ok(1.0),
            }
        }
    }

    #[tokio::test]
    async fn switch_channels_are_read_as_the_ascom_interface_defines_them() {
        let caps = switch_capabilities(&PowerBox::default()).await.unwrap();
        let [v1, heater, port] = caps.switches.as_slice() else {
            panic!("three channels: {:?}", caps.switches);
        };
        // A V1 switch has no CanWrite and every one of them is writable.
        assert!(v1.can_write && v1.is_boolean && v1.step == 1.0);
        // A 0..1 heater in steps of 0.01 is a dial, not an on/off switch.
        assert!(!heater.is_boolean, "{heater:?}");
        assert_eq!(heater.step, 0.01);
        assert!(port.is_boolean, "{port:?}");
    }

    #[tokio::test]
    async fn switch_read_failures_do_not_create_a_boolean_port_or_an_off_value() {
        for member in ["count", "min_value", "max_value", "step", "value", "state"] {
            let error = switch_capabilities(&PowerBox {
                fail_on: Some(member),
                on: true,
            })
            .await
            .unwrap_err();
            assert!(error.to_string().contains(member), "{member}: {error}");
        }
        let caps = switch_capabilities(&PowerBox {
            on: true,
            ..Default::default()
        })
        .await
        .unwrap();
        assert_eq!(
            caps.switches[0].value, 1.0,
            "V1 switches read their real boolean state"
        );
    }

    #[test]
    fn a_switch_value_goes_out_on_a_step() {
        assert_eq!(switch_value_on_step(33.0, 0.0, 100.0, 10.0), 30.0);
        assert_eq!(switch_value_on_step(36.0, 0.0, 100.0, 10.0), 40.0);
        assert_eq!(switch_value_on_step(0.3, 0.0, 1.0, 0.1), 0.3);
        assert_eq!(switch_value_on_step(0.304, 0.0, 1.0, 0.01), 0.3);
        assert_eq!(switch_value_on_step(-4.0, -20.0, 30.0, 0.5), -4.0);
        assert_eq!(switch_value_on_step(99.0, 0.0, 100.0, 15.0), 90.0);
        // Out of range or without a usable step: as asked.
        assert_eq!(switch_value_on_step(130.0, 0.0, 100.0, 10.0), 130.0);
        assert_eq!(switch_value_on_step(0.37, 0.0, 1.0, 0.0), 0.37);
    }
}
