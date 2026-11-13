//! The filter wheel behind its handle, once per protocol. Slots are 0-based.
//! The ASCOM filter wheel, over Alpaca or COM, is
//! [`super::ascom::AscomFilterWheel`].

use super::{closed, RigDriver, Slot};
use crate::api::devices::simulation::get_sim_filterwheel;
use crate::device_capabilities::FilterWheelCapabilities;
use crate::device_manager::ops::{sim_faults, sim_gate};
use crate::device_manager::identity::DeviceIdentity;
use crate::device_manager::DeviceManager;
use crate::dispatch::DeviceOpError;
use crate::error::SkotiqError;
use async_trait::async_trait;
use skotiq_device::{DriverError, FilterWheelDriver};
use std::time::Duration;

#[async_trait]
pub(crate) trait FilterWheel: RigDriver {
    /// Turns the wheel to `slot` and returns once it is there, as far as the
    /// protocol can tell.
    async fn move_to_slot(&self, slot: i32) -> Result<(), DeviceOpError>;

    async fn position(&self) -> Result<i32, DeviceOpError>;

    async fn is_moving(&self) -> Result<bool, DeviceOpError>;

    /// Whether the wheel is turning, for a caller that has just read
    /// `position`. ASCOM reports motion as position -1, so that one read
    /// answers both and the wheel is not asked twice.
    async fn is_moving_at(&self, _position: i32) -> Result<bool, DeviceOpError> {
        self.is_moving().await
    }

    /// The number of slots and their names.
    async fn config(&self) -> Result<(i32, Vec<String>), DeviceOpError>;

    /// Stores `names` in the wheel, slot 0 first.
    async fn set_names(&self, names: Vec<String>) -> Result<(), DeviceOpError>;

    /// The slots, their names and offsets, whether they can be renamed, and
    /// where the wheel is now.
    async fn capabilities(&self, device_id: &str) -> Result<FilterWheelCapabilities, SkotiqError>;
}

type Driver = dyn FilterWheelDriver + Send + Sync;

/// A filter wheel behind a [`FilterWheelDriver`]: a vendor SDK wheel or an
/// INDI wheel.
pub(crate) struct DriverFilterWheel {
    device_id: String,
    driver: Slot<Driver>,
    /// "Native" or "INDI", in messages.
    protocol: &'static str,
    /// The protocol inside a sentence: "native", "INDI".
    in_sentence: &'static str,
    /// What is said when the driver cannot store filter names.
    no_names: Option<&'static str>,
}

impl DriverFilterWheel {
    /// A vendor SDK wheel: the driver keeps state between calls, so it is
    /// reached one call at a time.
    pub(crate) fn vendor(device_id: &str, driver: Box<Driver>) -> Self {
        Self {
            device_id: device_id.to_string(),
            driver: Slot::held(driver),
            protocol: "Native",
            in_sentence: "native",
            no_names: None,
        }
    }

    pub(crate) fn indi(
        device_id: &str,
        client: std::sync::Arc<tokio::sync::RwLock<skotiq_indi::IndiClient>>,
        device_name: &str,
    ) -> Self {
        let device_name = device_name.to_string();
        Self {
            device_id: device_id.to_string(),
            driver: Slot::per_call(move || {
                Box::new(skotiq_indi::IndiFilterWheel::new(client.clone(), &device_name))
                    as Box<Driver>
            }),
            protocol: "INDI",
            in_sentence: "INDI",
            no_names: Some("INDI filter name setting is unavailable in this manager path"),
        }
    }

    fn not_connected(&self) -> DeviceOpError {
        DeviceOpError::not_connected(
            Some(self.device_id.clone()),
            format!("{} filter wheel not connected", self.protocol),
        )
    }
}

#[async_trait]
impl RigDriver for DriverFilterWheel {
    async fn disconnect(&self) -> Result<(), DriverError> {
        match self.driver.take().await {
            Some(mut wheel) => wheel.disconnect().await,
            None => Ok(()),
        }
    }

    async fn heartbeat(&self) -> Result<bool, String> {
        let Some(wheel) = self.driver.read().await else {
            return Ok(false);
        };
        wheel.heartbeat().await.map_err(|e| {
            format!(
                "{} filter wheel liveness probe failed: {}",
                self.protocol, e
            )
        })
    }

    async fn identity(&self) -> Option<DeviceIdentity> {
        let Slot::Held(_) = self.driver else {
            return None;
        };
        let driver = self.driver.read().await?;
        Some(DeviceManager::identity_from_device(&self.device_id, &*driver))
    }
}

#[async_trait]
impl FilterWheel for DriverFilterWheel {
    async fn move_to_slot(&self, slot: i32) -> Result<(), DeviceOpError> {
        let device_id = &self.device_id;
        self.driver
            .write()
            .await
            .ok_or_else(|| self.not_connected())?
            .move_to_position(slot)
            .await
            .map_err(|e| {
                DeviceOpError::caused_by(
                    Some(device_id.clone()),
                    format!(
                        "Failed to move {} filter wheel {} to slot {}: {}",
                        self.in_sentence, device_id, slot, e
                    ),
                    e,
                )
            })?;

        // Several vendor SDKs acknowledge the command before the motor
        // starts, and a ZWO EFW can return SDK success for a command that
        // never changes the encoder position. The move has succeeded only
        // once the wheel reads back the requested slot.
        super::ascom::wait_for_slot(
            self.protocol,
            device_id,
            slot,
            Duration::from_secs(60),
            || async {
                let wheel = self
                    .driver
                    .read()
                    .await
                    .ok_or_else(|| self.not_connected())?;
                wheel.get_position().await.map_err(|error| {
                    if closed(&error) {
                        self.not_connected()
                    } else {
                        DeviceOpError::from(error)
                    }
                })
            },
        )
        .await
    }

    async fn position(&self) -> Result<i32, DeviceOpError> {
        let wheel = self
            .driver
            .read()
            .await
            .ok_or_else(|| self.not_connected())?;
        wheel.get_position().await.map_err(DeviceOpError::from)
    }

    async fn is_moving(&self) -> Result<bool, DeviceOpError> {
        let wheel = self
            .driver
            .read()
            .await
            .ok_or_else(|| self.not_connected())?;
        wheel.is_moving().await.map_err(DeviceOpError::from)
    }

    /// A failed read is reported as one. An empty list instead would make the
    /// callers answer "filter not found in the wheel" for what is a
    /// connection problem.
    async fn config(&self) -> Result<(i32, Vec<String>), DeviceOpError> {
        let wheel = self
            .driver
            .read()
            .await
            .ok_or_else(|| self.not_connected())?;
        let names = wheel.get_filter_names().await.map_err(|e| {
            DeviceOpError::caused_by(
                Some(self.device_id.clone()),
                format!(
                    "Failed to read {} filter names for {}: {}",
                    self.in_sentence, self.device_id, e
                ),
                e,
            )
        })?;
        Ok((wheel.get_filter_count().await, names))
    }

    async fn set_names(&self, names: Vec<String>) -> Result<(), DeviceOpError> {
        let mut wheel = self
            .driver
            .write()
            .await
            .ok_or_else(|| self.not_connected())?;
        for (slot, name) in names.iter().enumerate() {
            // Why: a wheel has at most 16 slots; usize -> i32 is exact.
            wheel
                .set_filter_name(slot as i32, name.clone())
                .await
                .map_err(|e| match (&e, self.no_names) {
                    (DriverError::NotSupported, Some(sentence)) => {
                        tracing::warn!("filter_wheel_set_filter_names: {}", sentence);
                        DeviceOpError::unsupported(sentence)
                    }
                    _ => DeviceOpError::from(e),
                })?;
        }
        Ok(())
    }

    async fn capabilities(&self, device_id: &str) -> Result<FilterWheelCapabilities, SkotiqError> {
        let wheel = self.driver.read().await.ok_or_else(|| {
            SkotiqError::hardware_error(
                device_id,
                format!("{} filter wheel not connected", self.protocol),
            )
        })?;
        Ok(FilterWheelCapabilities {
            position_count: wheel.get_filter_count().await,
            current_position: wheel.get_position().await.ok(),
            // A wheel that keeps no labels (the ZWO EFW) refuses the read
            // on first connect; the app then labels the slots by number.
            filter_names: wheel.get_filter_names().await.unwrap_or_default(),
            // A busy SDK reads as a wheel at rest; the status poll corrects it.
            is_moving: wheel.is_moving().await.unwrap_or(false),
            can_set_filter_names: wheel.can_set_filter_names().await,
            ..Default::default()
        })
    }
}

/// The simulated filter wheel singleton.
///
/// Written with braces because the binding generator stops on a unit struct
/// that implements a trait of this crate.
pub(crate) struct SimFilterWheel {}

#[async_trait]
impl RigDriver for SimFilterWheel {
    async fn disconnect(&self) -> Result<(), DriverError> {
        get_sim_filterwheel().write().await.status.connected = false;
        Ok(())
    }

    async fn heartbeat(&self) -> Result<bool, String> {
        Ok(get_sim_filterwheel().read().await.status.connected)
    }
}

#[async_trait]
impl FilterWheel for SimFilterWheel {
    async fn move_to_slot(&self, slot: i32) -> Result<(), DeviceOpError> {
        // Injected driver errors fire before the connected gate; see
        // `sim_faults` for the key grammar.
        sim_faults::check("filterwheel.set_position")
            .await?;
        let mut fw = get_sim_filterwheel().write().await;
        if !fw.status.connected {
            return Err(DeviceOpError::not_connected(
                None,
                sim_gate::not_connected_filterwheel(),
            ));
        }
        // A stalled wheel accepts the move and never arrives: the command
        // returns `Ok` and `position` keeps reporting where the wheel is.
        // This is the failure that labels every later frame with the wrong
        // filter, invisible to a check that only looks at the return value.
        if sim_faults::is_stalled("filterwheel.set_position") {
            return Ok(());
        }
        fw.status.position = slot;
        Ok(())
    }

    async fn position(&self) -> Result<i32, DeviceOpError> {
        Ok(sim_gate::read_filterwheel_status().await?.position)
    }

    async fn is_moving(&self) -> Result<bool, DeviceOpError> {
        Ok(sim_gate::read_filterwheel_status().await?.moving)
    }

    async fn config(&self) -> Result<(i32, Vec<String>), DeviceOpError> {
        let sim = sim_gate::read_filterwheel_status().await?;
        Ok((sim.filter_count, sim.filter_names))
    }

    /// Names past the wheel's slot count are dropped, as
    /// `api::devices::simulation::api_filterwheel_set_filter_names` does.
    async fn set_names(&self, names: Vec<String>) -> Result<(), DeviceOpError> {
        let mut fw = get_sim_filterwheel().write().await;
        if !fw.status.connected {
            return Err(DeviceOpError::not_connected(
                None,
                sim_gate::not_connected_filterwheel(),
            ));
        }
        let count = fw.status.filter_names.len().min(names.len());
        for (slot, name) in names.into_iter().take(count).enumerate() {
            fw.status.filter_names[slot] = name;
        }
        Ok(())
    }

    /// The slots and names the simulated wheel turns between; where it is
    /// now is left to the live readings, as the capability cache refreshes
    /// them.
    async fn capabilities(&self, _device_id: &str) -> Result<FilterWheelCapabilities, SkotiqError> {
        let sim = get_sim_filterwheel().read().await.status.clone();
        Ok(FilterWheelCapabilities {
            position_count: sim.filter_count,
            filter_names: sim.filter_names,
            focus_offsets: vec![0, 10, 20, 30, 100, 120, 140],
            can_set_filter_names: true,
            can_set_focus_offsets: true,
            ..Default::default()
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use skotiq_device::{DeviceDriver, Vendor};
    use std::sync::Arc;

    /// A vendor wheel that accepts a move and stays at slot 1.
    #[derive(Debug)]
    struct StuckWheel {
        connected: bool,
    }

    #[async_trait]
    impl DeviceDriver for StuckWheel {
        fn id(&self) -> &str {
            "native:test:0"
        }

        fn name(&self) -> &str {
            "Stuck wheel"
        }

        fn vendor(&self) -> Vendor {
            Vendor::Zwo
        }

        fn is_connected(&self) -> bool {
            self.connected
        }

        async fn connect(&mut self) -> Result<(), DriverError> {
            self.connected = true;
            Ok(())
        }

        async fn disconnect(&mut self) -> Result<(), DriverError> {
            self.connected = false;
            Ok(())
        }
    }

    #[async_trait]
    impl FilterWheelDriver for StuckWheel {
        async fn move_to_position(&mut self, _position: i32) -> Result<(), DriverError> {
            Ok(())
        }

        async fn get_position(&self) -> Result<i32, DriverError> {
            if self.connected {
                Ok(1)
            } else {
                Err(DriverError::NotConnected)
            }
        }

        async fn is_moving(&self) -> Result<bool, DriverError> {
            Ok(false)
        }

        async fn get_filter_count(&self) -> i32 {
            7
        }

        async fn get_filter_names(&self) -> Result<Vec<String>, DriverError> {
            Ok(Vec::new())
        }

        async fn set_filter_name(
            &mut self,
            _position: i32,
            _name: String,
        ) -> Result<(), DriverError> {
            Ok(())
        }
    }

    #[tokio::test]
    async fn a_vendor_wheel_is_read_and_closed_while_a_move_waits_for_arrival() {
        let wheel = Arc::new(DriverFilterWheel::vendor(
            "native:test:0",
            Box::new(StuckWheel { connected: true }),
        ));
        let moving = tokio::spawn({
            let wheel = wheel.clone();
            async move { wheel.move_to_slot(3).await }
        });
        tokio::time::sleep(Duration::from_millis(250)).await;
        assert!(
            !moving.is_finished(),
            "the move waits for the wheel to arrive"
        );

        let read = tokio::time::timeout(Duration::from_millis(500), wheel.position()).await;
        assert!(
            matches!(read, Ok(Ok(1))),
            "a read does not wait for the move: {read:?}"
        );
        assert_eq!(wheel.heartbeat().await, Ok(true));

        tokio::time::timeout(Duration::from_millis(500), wheel.disconnect())
            .await
            .expect("a disconnect does not wait for the move")
            .expect("disconnect");
        let ended = tokio::time::timeout(Duration::from_secs(2), moving)
            .await
            .expect("the move ends once the wheel is closed")
            .expect("move task");
        assert!(
            matches!(ended, Err(DeviceOpError::NotConnected { .. })),
            "{ended:?}"
        );
    }
}
