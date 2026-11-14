//! The ASCOM focuser and filter wheel, whichever transport carries them.
//!
//! Alpaca (HTTP) and COM (Windows) carry the same `IFocuser` and
//! `IFilterWheel` members. What each member means is decided here, once:
//!
//! - `Focuser.Absolute` false: the focuser has no `Position` (reading it
//!   raises NotImplemented) and `Move` takes a number of steps, at most
//!   `MaxIncrement` in one call. Skotiq counts positions itself from the
//!   middle of the travel at connect, as NINA does, so autofocus and the
//!   position display work as on an absolute focuser.
//! - `Focuser.Temperature` raising NotImplemented: the focuser has no sensor.
//! - `FilterWheel.Position` set starts the move and returns (IFilterWheelV3);
//!   `Position` reads -1 until the wheel is at a slot.
//! - `Names` and `FocusOffsets` have one entry per slot.
//!
//! Each transport implements [`FocuserMembers`] or [`FilterWheelMembers`] by
//! passing the call on, in its own words when it fails.

use super::RigDriver;
use crate::device_capabilities::types::{FilterWheelCapabilities, FocuserCapabilities};
use crate::dispatch::error::DeviceOpError;
use crate::error::SkotiqError;
use crate::timeout_ops::{focuser_move_with_timeout, Timeouts};
use async_trait::async_trait;
use skotiq_device::ascom::{optional, NotImplemented};
use skotiq_device::DriverError;
use std::sync::atomic::{AtomicI32, Ordering};
use std::time::Duration;
use tokio::time::Instant;

/// How often a focuser move is polled for its end.
const POLL: Duration = Duration::from_millis(200);

/// How often a turning filter wheel is read.
const WHEEL_POLL: Duration = Duration::from_millis(100);

/// What every ASCOM device answers besides its own members.
#[async_trait]
pub(crate) trait DeviceMembers: Send + Sync {
    /// Which transport carries the device ("Alpaca", "ASCOM"), for messages.
    fn protocol(&self) -> &'static str;

    async fn disconnect(&self) -> Result<(), DriverError>;

    /// `Connected`, read without retries.
    async fn connected(&self) -> Result<bool, DeviceOpError>;
}

/// The `IFocuserV4` members.
#[async_trait]
pub(crate) trait FocuserMembers: DeviceMembers {
    async fn absolute(&self) -> Result<bool, DeviceOpError>;
    async fn position(&self) -> Result<i32, DeviceOpError>;
    async fn is_moving(&self) -> Result<bool, DeviceOpError>;
    async fn max_step(&self) -> Result<i32, DeviceOpError>;
    async fn max_increment(&self) -> Result<i32, DeviceOpError>;
    /// Microns.
    async fn step_size(&self) -> Result<f64, DeviceOpError>;
    async fn temp_comp_available(&self) -> Result<bool, DeviceOpError>;
    async fn temp_comp(&self) -> Result<bool, DeviceOpError>;
    /// Degrees Celsius.
    async fn temperature(&self) -> Result<f64, DeviceOpError>;
    /// `Move`: a position on an absolute focuser, a step count on a relative
    /// one.
    async fn move_to(&self, value: i32) -> Result<(), DeviceOpError>;
    async fn halt(&self) -> Result<(), DeviceOpError>;
}

/// The `IFilterWheelV3` members.
#[async_trait]
pub(crate) trait FilterWheelMembers: DeviceMembers {
    /// The slot, 0-based, or -1 while the wheel turns.
    async fn position(&self) -> Result<i32, DeviceOpError>;
    async fn set_position(&self, slot: i32) -> Result<(), DeviceOpError>;
    async fn names(&self) -> Result<Vec<String>, DeviceOpError>;
    async fn focus_offsets(&self) -> Result<Vec<i32>, DeviceOpError>;
}

impl NotImplemented for DeviceOpError {
    fn is_not_implemented(&self) -> bool {
        matches!(self, DeviceOpError::Unsupported { .. })
    }
}

async fn heartbeat(device: &dyn DeviceMembers, device_id: &str) -> Result<bool, String> {
    match device.connected().await {
        Ok(connected) => Ok(connected),
        Err(e) => {
            tracing::debug!(
                "{} {} heartbeat failed: {}",
                device.protocol(),
                device_id,
                e
            );
            Ok(false)
        }
    }
}

/// Polls `read` until it answers `slot` or `limit` passes. A read that fails
/// is retried, unless it says the wheel was closed.
pub(super) async fn wait_for_slot<F, Fut>(
    protocol: &str,
    device_id: &str,
    slot: i32,
    limit: Duration,
    mut read: F,
) -> Result<(), DeviceOpError>
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = Result<i32, DeviceOpError>>,
{
    let deadline = Instant::now() + limit;
    let mut last_position = None;
    loop {
        match read().await {
            Ok(current) if current == slot => return Ok(()),
            Ok(current) => last_position = Some(current),
            Err(error @ DeviceOpError::NotConnected { .. }) => return Err(error),
            Err(error) => tracing::warn!(
                "{} filter wheel {} readback failed while moving to {}: {}",
                protocol,
                device_id,
                slot,
                error
            ),
        }
        if Instant::now() >= deadline {
            return Err(DeviceOpError::hardware(
                Some(device_id.to_string()),
                format!(
                    "{} filter wheel {} did not reach slot {} within {}s (last position: {:?})",
                    protocol,
                    device_id,
                    slot,
                    limit.as_secs(),
                    last_position
                ),
            ));
        }
        tokio::time::sleep(WHEEL_POLL).await;
    }
}

/// An ASCOM focuser over `M`.
pub(crate) struct AscomFocuser<M> {
    device_id: String,
    members: M,
    absolute: bool,
    max_step: i32,
    max_increment: i32,
    step_size: Option<f64>,
    /// A relative focuser's position as Skotiq counts it.
    counted_position: AtomicI32,
}

impl<M: FocuserMembers> AscomFocuser<M> {
    /// Reads what does not change while the focuser is connected: whether it
    /// is absolute, its travel and its step. `Absolute` decides what `Move`
    /// means, so a focuser that cannot answer it is not opened.
    pub(crate) async fn open(device_id: &str, members: M) -> Result<Self, DeviceOpError> {
        let protocol = members.protocol();
        let absolute = match members.absolute().await {
            Ok(absolute) => absolute,
            Err(e) => {
                if let Err(close) = members.disconnect().await {
                    tracing::warn!("{protocol} focuser {device_id}: disconnect failed: {close}");
                }
                return Err(DeviceOpError::caused_by(
                    Some(device_id.to_string()),
                    format!(
                        "{protocol} focuser {device_id} did not say whether it is an absolute                          or a relative focuser (Absolute: {e}), so Skotiq cannot tell what a                          move would do"
                    ),
                    e,
                ));
            }
        };
        let max_step = members.max_step().await.unwrap_or_else(|e| {
            tracing::warn!(
                "{protocol} focuser {device_id}: MaxStep could not be read ({e}); \
                 its travel is unknown"
            );
            0
        });
        // ConformU: MaxIncrement is at least 1 and at most MaxStep.
        let no_limit = if max_step > 0 { max_step } else { i32::MAX };
        let max_increment = match members.max_increment().await {
            Ok(increment) if increment >= 1 => increment,
            Ok(increment) => {
                tracing::warn!(
                    "{protocol} focuser {device_id}: MaxIncrement {increment} is not a step \
                     count; moves are limited to MaxStep"
                );
                no_limit
            }
            Err(e) => {
                tracing::warn!(
                    "{protocol} focuser {device_id}: MaxIncrement could not be read ({e}); \
                     moves are limited to MaxStep"
                );
                no_limit
            }
        };
        let step_size = optional(members.step_size().await).unwrap_or_else(|e| {
            tracing::warn!("{protocol} focuser {device_id}: StepSize could not be read ({e})");
            None
        });
        if !absolute {
            tracing::info!(
                "{protocol} focuser {device_id} is a relative focuser: positions are counted \
                 from {} at connect",
                max_step / 2
            );
        }
        Ok(Self {
            device_id: device_id.to_string(),
            members,
            absolute,
            max_step,
            max_increment,
            step_size,
            counted_position: AtomicI32::new(max_step / 2),
        })
    }

    fn move_failed(&self, target: i32, error: impl Into<DeviceOpError>) -> DeviceOpError {
        let error = error.into();
        DeviceOpError::caused_by(
            Some(self.device_id.clone()),
            format!(
                "Failed to move {} focuser {} to position {}: {}",
                self.members.protocol(),
                self.device_id,
                target,
                error
            ),
            error,
        )
    }

    async fn send_move(&self, value: i32, from: Option<i32>) -> Result<(), SkotiqError> {
        focuser_move_with_timeout(
            async { self.members.move_to(value).await.map_err(SkotiqError::from) },
            &self.device_id,
            value,
            from,
            1,
        )
        .await
    }

    /// A relative focuser takes at most `MaxIncrement` steps per `Move`, and
    /// the next `Move` only once it is at rest.
    async fn move_relative_focuser(&self, steps: i32) -> Result<(), DeviceOpError> {
        let target = self.counted_position.load(Ordering::SeqCst) + steps;
        let mut remaining = steps;
        while remaining != 0 {
            let chunk = remaining.clamp(-self.max_increment, self.max_increment);
            self.send_move(chunk, None)
                .await
                .map_err(|e| self.move_failed(target, e))?;
            self.counted_position.fetch_add(chunk, Ordering::SeqCst);
            remaining -= chunk;
            if remaining != 0 {
                self.wait_at_rest()
                    .await
                    .map_err(|e| self.move_failed(target, e))?;
            }
        }
        Ok(())
    }

    async fn wait_at_rest(&self) -> Result<(), DeviceOpError> {
        let deadline = Instant::now() + Timeouts::focuser_move();
        while self.members.is_moving().await? {
            if Instant::now() >= deadline {
                return Err(DeviceOpError::Timeout {
                    device_id: Some(self.device_id.clone()),
                    detail: format!(
                        "{} focuser {} still moving after {:?}",
                        self.members.protocol(),
                        self.device_id,
                        Timeouts::focuser_move()
                    ),
                });
            }
            tokio::time::sleep(POLL).await;
        }
        Ok(())
    }
}

#[async_trait]
impl<M: FocuserMembers> RigDriver for AscomFocuser<M> {
    async fn disconnect(&self) -> Result<(), DriverError> {
        self.members.disconnect().await
    }

    async fn heartbeat(&self) -> Result<bool, String> {
        heartbeat(&self.members, &self.device_id).await
    }
}

#[async_trait]
impl<M: FocuserMembers> super::focuser::Focuser for AscomFocuser<M> {
    async fn move_to(&self, position: i32) -> Result<(), DeviceOpError> {
        if !self.absolute {
            let steps = position - self.counted_position.load(Ordering::SeqCst);
            return self.move_relative_focuser(steps).await;
        }
        self.send_move(position, None)
            .await
            .map_err(|e| self.move_failed(position, e))
    }

    async fn move_by(&self, steps: i32) -> Result<(), DeviceOpError> {
        if !self.absolute {
            return self.move_relative_focuser(steps).await;
        }
        let current = self.members.position().await?;
        let target = current + steps;
        self.send_move(target, Some(current))
            .await
            .map_err(|e| self.move_failed(target, e))
    }

    async fn halt(&self) -> Result<(), DeviceOpError> {
        self.members.halt().await
    }

    async fn position(&self) -> Result<i32, DeviceOpError> {
        if self.absolute {
            self.members.position().await
        } else {
            Ok(self.counted_position.load(Ordering::SeqCst))
        }
    }

    async fn is_moving(&self) -> Result<bool, DeviceOpError> {
        self.members.is_moving().await
    }

    async fn is_absolute(&self) -> Result<bool, DeviceOpError> {
        Ok(self.absolute)
    }

    async fn temperature(&self) -> Result<Option<f64>, DeviceOpError> {
        optional(self.members.temperature().await)
    }

    /// An unknown step size is 0.
    async fn travel(&self) -> Result<(i32, f64), DeviceOpError> {
        Ok((self.max_step, self.step_size.unwrap_or(0.0)))
    }

    /// A live property the driver does not answer is reported absent, or as
    /// the focuser at rest. `Halt` is a required method, so halt is offered.
    async fn capabilities(&self, _device_id: &str) -> Result<FocuserCapabilities, SkotiqError> {
        let members = &self.members;
        let temp_comp_available = members.temp_comp_available().await.unwrap_or(false);
        Ok(FocuserCapabilities {
            max_position: self.max_step,
            max_increment: self.max_increment,
            step_size: self.step_size,
            absolute: self.absolute,
            temp_comp_available,
            temp_comp: temp_comp_available && members.temp_comp().await.unwrap_or(false),
            temperature: members.temperature().await.ok(),
            is_moving: members.is_moving().await.unwrap_or(false),
            position: super::focuser::Focuser::position(self).await.ok(),
            can_halt: true,
            ..Default::default()
        })
    }
}

/// How long a filter change may take before it counts as failed.
const WHEEL_ARRIVAL: Duration = Duration::from_secs(60);

/// An ASCOM filter wheel over `M`.
pub(crate) struct AscomFilterWheel<M> {
    device_id: String,
    members: M,
}

impl<M: FilterWheelMembers> AscomFilterWheel<M> {
    pub(crate) fn new(device_id: &str, members: M) -> Self {
        Self {
            device_id: device_id.to_string(),
            members,
        }
    }
}

#[async_trait]
impl<M: FilterWheelMembers> RigDriver for AscomFilterWheel<M> {
    async fn disconnect(&self) -> Result<(), DriverError> {
        self.members.disconnect().await
    }

    async fn heartbeat(&self) -> Result<bool, String> {
        heartbeat(&self.members, &self.device_id).await
    }
}

#[async_trait]
impl<M: FilterWheelMembers> super::filter_wheel::FilterWheel for AscomFilterWheel<M> {
    async fn move_to_slot(&self, slot: i32) -> Result<(), DeviceOpError> {
        let protocol = self.members.protocol();
        let device_id = &self.device_id;
        self.members.set_position(slot).await.map_err(|e| {
            DeviceOpError::caused_by(
                Some(device_id.clone()),
                format!(
                    "Failed to move {} filter wheel {} to slot {}: {}",
                    protocol, device_id, slot, e
                ),
                e,
            )
        })?;
        wait_for_slot(protocol, device_id, slot, WHEEL_ARRIVAL, || {
            self.members.position()
        })
        .await
    }

    async fn position(&self) -> Result<i32, DeviceOpError> {
        self.members.position().await
    }

    async fn is_moving(&self) -> Result<bool, DeviceOpError> {
        Ok(self.members.position().await? == -1)
    }

    /// A Position read answers both: -1 is a wheel in motion. That read can
    /// be slow or persistently failing on COM (the ZWO EFW driver in a
    /// headless session), so it is not repeated.
    async fn is_moving_at(&self, position: i32) -> Result<bool, DeviceOpError> {
        Ok(position == -1)
    }

    async fn config(&self) -> Result<(i32, Vec<String>), DeviceOpError> {
        let names = self.members.names().await?;
        Ok((slot_count(&names), names))
    }

    async fn set_names(&self, _names: Vec<String>) -> Result<(), DeviceOpError> {
        let msg = format!(
            "{} filter names are kept by the driver and cannot be set from Skotiq",
            self.members.protocol()
        );
        tracing::warn!("filter_wheel_set_filter_names: {}", msg);
        Err(DeviceOpError::unsupported(msg))
    }

    async fn capabilities(&self, device_id: &str) -> Result<FilterWheelCapabilities, SkotiqError> {
        let protocol = self.members.protocol();
        // A failed Names read is not a wheel without filters: a 0-slot wheel
        // makes the scheduler reject every filtered target. COM Names is one
        // of the reads that intermittently throws 0x80020009 headless.
        let filter_names = self.members.names().await.map_err(|e| {
            SkotiqError::connection_failed(
                device_id,
                format!("Failed to read {protocol} filter wheel names: {e}"),
            )
        })?;
        // No offsets only loses per-filter focus compensation, so the read
        // goes on, but says so: it looks the same as a wheel with none set.
        let focus_offsets = match self.members.focus_offsets().await {
            Ok(offsets) => offsets,
            Err(e) => {
                tracing::warn!(
                    "{protocol} filter wheel {device_id}: focus-offset read failed ({e}); \
                     per-filter focus compensation will be skipped for this wheel."
                );
                Vec::new()
            }
        };
        let position = self.members.position().await.ok();
        Ok(FilterWheelCapabilities {
            position_count: slot_count(&filter_names),
            current_position: position.filter(|&slot| slot >= 0),
            is_moving: position == Some(-1),
            filter_names,
            focus_offsets,
            ..Default::default()
        })
    }
}

/// `Names` has one entry per slot.
fn slot_count(names: &[String]) -> i32 {
    i32::try_from(names.len()).unwrap_or(i32::MAX)
}

// Alpaca.

#[async_trait]
impl DeviceMembers for skotiq_alpaca::AlpacaFocuser {
    fn protocol(&self) -> &'static str {
        "Alpaca"
    }
    async fn disconnect(&self) -> Result<(), DriverError> {
        Ok(skotiq_alpaca::AlpacaFocuser::disconnect(self).await?)
    }
    async fn connected(&self) -> Result<bool, DeviceOpError> {
        Ok(self.validate_connection().await?)
    }
}

#[async_trait]
impl FocuserMembers for skotiq_alpaca::AlpacaFocuser {
    async fn absolute(&self) -> Result<bool, DeviceOpError> {
        Ok(skotiq_alpaca::AlpacaFocuser::absolute(self).await?)
    }
    async fn position(&self) -> Result<i32, DeviceOpError> {
        Ok(skotiq_alpaca::AlpacaFocuser::position(self).await?)
    }
    async fn is_moving(&self) -> Result<bool, DeviceOpError> {
        Ok(skotiq_alpaca::AlpacaFocuser::is_moving(self).await?)
    }
    async fn max_step(&self) -> Result<i32, DeviceOpError> {
        Ok(skotiq_alpaca::AlpacaFocuser::max_step(self).await?)
    }
    async fn max_increment(&self) -> Result<i32, DeviceOpError> {
        Ok(skotiq_alpaca::AlpacaFocuser::max_increment(self).await?)
    }
    async fn step_size(&self) -> Result<f64, DeviceOpError> {
        Ok(skotiq_alpaca::AlpacaFocuser::step_size(self).await?)
    }
    async fn temp_comp_available(&self) -> Result<bool, DeviceOpError> {
        Ok(skotiq_alpaca::AlpacaFocuser::temp_comp_available(self).await?)
    }
    async fn temp_comp(&self) -> Result<bool, DeviceOpError> {
        Ok(skotiq_alpaca::AlpacaFocuser::temp_comp(self).await?)
    }
    async fn temperature(&self) -> Result<f64, DeviceOpError> {
        Ok(skotiq_alpaca::AlpacaFocuser::temperature(self).await?)
    }
    async fn move_to(&self, value: i32) -> Result<(), DeviceOpError> {
        Ok(skotiq_alpaca::AlpacaFocuser::move_to(self, value).await?)
    }
    async fn halt(&self) -> Result<(), DeviceOpError> {
        Ok(skotiq_alpaca::AlpacaFocuser::halt(self).await?)
    }
}

#[async_trait]
impl DeviceMembers for skotiq_alpaca::AlpacaFilterWheel {
    fn protocol(&self) -> &'static str {
        "Alpaca"
    }
    async fn disconnect(&self) -> Result<(), DriverError> {
        Ok(skotiq_alpaca::AlpacaFilterWheel::disconnect(self).await?)
    }
    async fn connected(&self) -> Result<bool, DeviceOpError> {
        Ok(self.validate_connection().await?)
    }
}

#[async_trait]
impl FilterWheelMembers for skotiq_alpaca::AlpacaFilterWheel {
    async fn position(&self) -> Result<i32, DeviceOpError> {
        Ok(skotiq_alpaca::AlpacaFilterWheel::position(self).await?)
    }
    async fn set_position(&self, slot: i32) -> Result<(), DeviceOpError> {
        Ok(skotiq_alpaca::AlpacaFilterWheel::set_position(self, slot).await?)
    }
    async fn names(&self) -> Result<Vec<String>, DeviceOpError> {
        Ok(skotiq_alpaca::AlpacaFilterWheel::names(self).await?)
    }
    async fn focus_offsets(&self) -> Result<Vec<i32>, DeviceOpError> {
        Ok(skotiq_alpaca::AlpacaFilterWheel::focus_offsets(self).await?)
    }
}

// COM. Every call is one command on the wrapper's channel, run by the STA
// worker; the wrapper's lock is held for that one call (see `Exclusive`).

#[cfg(windows)]
mod com {
    use super::super::Exclusive;
    use super::{DeviceMembers, FilterWheelMembers, FocuserMembers};
    use crate::ascom_wrapper::filterwheel::AscomFilterWheelWrapper;
    use crate::ascom_wrapper::focuser::AscomFocuserWrapper;
    use crate::dispatch::error::DeviceOpError;
    use async_trait::async_trait;
    use skotiq_device::DriverError;

    #[async_trait]
    impl DeviceMembers for Exclusive<AscomFocuserWrapper> {
        fn protocol(&self) -> &'static str {
            "ASCOM"
        }
        async fn disconnect(&self) -> Result<(), DriverError> {
            Ok(self.write().await.disconnect().await?)
        }
        async fn connected(&self) -> Result<bool, DeviceOpError> {
            self.read().await.connected().await
        }
    }

    #[async_trait]
    impl FocuserMembers for Exclusive<AscomFocuserWrapper> {
        async fn absolute(&self) -> Result<bool, DeviceOpError> {
            self.read().await.absolute().await
        }
        async fn position(&self) -> Result<i32, DeviceOpError> {
            self.read().await.position().await
        }
        async fn is_moving(&self) -> Result<bool, DeviceOpError> {
            self.read().await.is_moving().await
        }
        async fn max_step(&self) -> Result<i32, DeviceOpError> {
            self.read().await.max_step().await
        }
        async fn max_increment(&self) -> Result<i32, DeviceOpError> {
            self.read().await.max_increment().await
        }
        async fn step_size(&self) -> Result<f64, DeviceOpError> {
            self.read().await.step_size().await
        }
        async fn temp_comp_available(&self) -> Result<bool, DeviceOpError> {
            self.read().await.temp_comp_available().await
        }
        async fn temp_comp(&self) -> Result<bool, DeviceOpError> {
            self.read().await.temp_comp().await
        }
        async fn temperature(&self) -> Result<f64, DeviceOpError> {
            self.read().await.temperature().await
        }
        async fn move_to(&self, value: i32) -> Result<(), DeviceOpError> {
            self.write().await.move_to(value).await
        }
        async fn halt(&self) -> Result<(), DeviceOpError> {
            self.write().await.halt().await
        }
    }

    #[async_trait]
    impl DeviceMembers for Exclusive<AscomFilterWheelWrapper> {
        fn protocol(&self) -> &'static str {
            "ASCOM"
        }
        async fn disconnect(&self) -> Result<(), DriverError> {
            Ok(self.write().await.disconnect().await?)
        }
        async fn connected(&self) -> Result<bool, DeviceOpError> {
            self.read().await.connected().await
        }
    }

    #[async_trait]
    impl FilterWheelMembers for Exclusive<AscomFilterWheelWrapper> {
        async fn position(&self) -> Result<i32, DeviceOpError> {
            self.read().await.position().await
        }
        async fn set_position(&self, slot: i32) -> Result<(), DeviceOpError> {
            self.write().await.set_position(slot).await
        }
        async fn names(&self) -> Result<Vec<String>, DeviceOpError> {
            self.read().await.names().await
        }
        async fn focus_offsets(&self) -> Result<Vec<i32>, DeviceOpError> {
            self.read().await.focus_offsets().await
        }
    }
}

#[cfg(test)]
mod tests {
    use super::super::filter_wheel::FilterWheel;
    use super::super::focuser::Focuser;
    use super::*;
    use std::sync::Mutex;

    /// A focuser that moves the instant it is told and records every `Move`.
    #[derive(Default)]
    struct BenchFocuser {
        absolute: bool,
        max_step: i32,
        max_increment: i32,
        position: Mutex<i32>,
        moves: Mutex<Vec<i32>>,
        has_sensor: bool,
        sensor_fails: bool,
    }

    #[async_trait]
    impl DeviceMembers for BenchFocuser {
        fn protocol(&self) -> &'static str {
            "Bench"
        }
        async fn disconnect(&self) -> Result<(), DriverError> {
            Ok(())
        }
        async fn connected(&self) -> Result<bool, DeviceOpError> {
            Ok(true)
        }
    }

    #[async_trait]
    impl FocuserMembers for BenchFocuser {
        async fn absolute(&self) -> Result<bool, DeviceOpError> {
            Ok(self.absolute)
        }
        async fn position(&self) -> Result<i32, DeviceOpError> {
            if self.absolute {
                Ok(*self.position.lock().unwrap())
            } else {
                Err(DeviceOpError::unsupported("Position is not implemented"))
            }
        }
        async fn is_moving(&self) -> Result<bool, DeviceOpError> {
            Ok(false)
        }
        async fn max_step(&self) -> Result<i32, DeviceOpError> {
            Ok(self.max_step)
        }
        async fn max_increment(&self) -> Result<i32, DeviceOpError> {
            Ok(self.max_increment)
        }
        async fn step_size(&self) -> Result<f64, DeviceOpError> {
            Err(DeviceOpError::unsupported("StepSize is not implemented"))
        }
        async fn temp_comp_available(&self) -> Result<bool, DeviceOpError> {
            Ok(false)
        }
        async fn temp_comp(&self) -> Result<bool, DeviceOpError> {
            Ok(false)
        }
        async fn temperature(&self) -> Result<f64, DeviceOpError> {
            match (self.has_sensor, self.sensor_fails) {
                (false, _) => Err(DeviceOpError::unsupported("Temperature is not implemented")),
                (true, true) => Err(DeviceOpError::hardware(None, "sensor read failed")),
                (true, false) => Ok(4.5),
            }
        }
        async fn move_to(&self, value: i32) -> Result<(), DeviceOpError> {
            self.moves.lock().unwrap().push(value);
            if self.absolute {
                *self.position.lock().unwrap() = value;
            }
            Ok(())
        }
        async fn halt(&self) -> Result<(), DeviceOpError> {
            Ok(())
        }
    }

    #[tokio::test]
    async fn a_relative_focuser_is_sent_steps_in_increments_it_accepts() {
        let focuser = AscomFocuser::open(
            "bench",
            BenchFocuser {
                absolute: false,
                max_step: 10_000,
                max_increment: 300,
                ..Default::default()
            },
        )
        .await
        .unwrap();
        assert_eq!(focuser.position().await.unwrap(), 5_000);
        assert!(!focuser.is_absolute().await.unwrap());

        focuser.move_to(5_700).await.unwrap();
        assert_eq!(*focuser.members.moves.lock().unwrap(), vec![300, 300, 100]);
        assert_eq!(focuser.position().await.unwrap(), 5_700);

        focuser.move_by(-350).await.unwrap();
        assert_eq!(focuser.members.moves.lock().unwrap()[3..], [-300, -50]);
        assert_eq!(focuser.position().await.unwrap(), 5_350);

        let caps = focuser.capabilities("bench").await.unwrap();
        assert!(!caps.absolute);
        assert_eq!(caps.position, Some(5_350));
        assert_eq!(caps.step_size, None);
        assert_eq!(focuser.travel().await.unwrap(), (10_000, 0.0));
    }

    #[tokio::test]
    async fn an_absolute_focuser_is_sent_positions() {
        let focuser = AscomFocuser::open(
            "bench",
            BenchFocuser {
                absolute: true,
                max_step: 10_000,
                max_increment: 10_000,
                position: Mutex::new(1_000),
                ..Default::default()
            },
        )
        .await
        .unwrap();
        focuser.move_to(2_500).await.unwrap();
        focuser.move_by(-500).await.unwrap();
        assert_eq!(*focuser.members.moves.lock().unwrap(), vec![2_500, 2_000]);
        assert_eq!(focuser.position().await.unwrap(), 2_000);
    }

    #[tokio::test]
    async fn a_focuser_without_a_sensor_has_no_temperature_and_a_failing_sensor_is_an_error() {
        let without = AscomFocuser::open("bench", BenchFocuser::default())
            .await
            .unwrap();
        assert_eq!(without.temperature().await.unwrap(), None);

        let with = AscomFocuser::open(
            "bench",
            BenchFocuser {
                has_sensor: true,
                ..Default::default()
            },
        )
        .await
        .unwrap();
        assert_eq!(with.temperature().await.unwrap(), Some(4.5));

        let failing = AscomFocuser::open(
            "bench",
            BenchFocuser {
                has_sensor: true,
                sensor_fails: true,
                ..Default::default()
            },
        )
        .await
        .unwrap();
        assert!(failing.temperature().await.is_err());
    }

    /// A wheel that reads -1 for `turns` reads after a move, then the slot.
    #[derive(Default)]
    struct BenchWheel {
        slot: Mutex<i32>,
        turning: Mutex<u32>,
        turns: u32,
        names: Vec<String>,
    }

    #[async_trait]
    impl DeviceMembers for BenchWheel {
        fn protocol(&self) -> &'static str {
            "Bench"
        }
        async fn disconnect(&self) -> Result<(), DriverError> {
            Ok(())
        }
        async fn connected(&self) -> Result<bool, DeviceOpError> {
            Ok(true)
        }
    }

    #[async_trait]
    impl FilterWheelMembers for BenchWheel {
        async fn position(&self) -> Result<i32, DeviceOpError> {
            let mut turning = self.turning.lock().unwrap();
            if *turning > 0 {
                *turning -= 1;
                return Ok(-1);
            }
            Ok(*self.slot.lock().unwrap())
        }
        async fn set_position(&self, slot: i32) -> Result<(), DeviceOpError> {
            if !(0..self.names.len() as i32).contains(&slot) {
                return Err(DeviceOpError::InvalidParameter {
                    detail: format!("no slot {slot}"),
                });
            }
            *self.slot.lock().unwrap() = slot;
            *self.turning.lock().unwrap() = self.turns;
            Ok(())
        }
        async fn names(&self) -> Result<Vec<String>, DeviceOpError> {
            Ok(self.names.clone())
        }
        async fn focus_offsets(&self) -> Result<Vec<i32>, DeviceOpError> {
            Err(DeviceOpError::unsupported(
                "FocusOffsets is not implemented",
            ))
        }
    }

    #[tokio::test]
    async fn a_filter_change_returns_once_the_wheel_reads_the_slot() {
        let wheel = AscomFilterWheel::new(
            "bench",
            BenchWheel {
                turns: 3,
                names: ["L", "R", "G", "B"].map(String::from).to_vec(),
                ..Default::default()
            },
        );
        wheel.move_to_slot(2).await.unwrap();
        assert_eq!(
            *wheel.members.turning.lock().unwrap(),
            0,
            "polled through the -1 reads"
        );
        assert_eq!(wheel.position().await.unwrap(), 2);

        let error = wheel.move_to_slot(7).await.expect_err("no slot 7");
        assert!(
            matches!(error, DeviceOpError::InvalidParameter { .. }),
            "{error:?}"
        );

        *wheel.members.turning.lock().unwrap() = 1;
        let caps = wheel.capabilities("bench").await.unwrap();
        assert_eq!(caps.position_count, 4);
        assert_eq!(caps.current_position, None);
        assert!(caps.is_moving);
        assert!(caps.focus_offsets.is_empty());
    }
}
