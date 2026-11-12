//! The filter wheel behind its handle, once per protocol. Slots are 0-based.

use super::{closed, Exclusive, RigDriver};
use crate::api::devices::simulation::get_sim_filterwheel;
use crate::device_capabilities::FilterWheelCapabilities;
use crate::device_manager::ops::{sim_faults, sim_gate};
use crate::dispatch::DeviceOpError;
use crate::error::SkotiqError;
use async_trait::async_trait;
use skotiq_alpaca::AlpacaFilterWheel;
use skotiq_device::{DriverError, FilterWheelDriver};
use skotiq_indi::names as indi;
use skotiq_indi::IndiFilterWheel;
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

/// A vendor SDK filter wheel.
pub(crate) struct VendorFilterWheel {
    device_id: String,
    driver: Exclusive<Box<dyn FilterWheelDriver + Send + Sync>>,
}

impl VendorFilterWheel {
    pub(crate) fn new(device_id: &str, driver: Box<dyn FilterWheelDriver + Send + Sync>) -> Self {
        Self {
            device_id: device_id.to_string(),
            driver: Exclusive::new(driver),
        }
    }

    fn not_connected(&self) -> DeviceOpError {
        DeviceOpError::not_connected(
            Some(self.device_id.clone()),
            "Native filter wheel not connected",
        )
    }
}

#[async_trait]
impl RigDriver for VendorFilterWheel {
    async fn disconnect(&self) -> Result<(), DriverError> {
        self.driver.write().await.disconnect().await
    }

    async fn heartbeat(&self) -> Result<bool, String> {
        let wheel = self.driver.read().await;
        if !wheel.is_connected() {
            return Ok(false);
        }
        wheel
            .get_position()
            .await
            .map(|_| true)
            .map_err(|e| format!("Native filter wheel liveness probe failed: {}", e))
    }
}

#[async_trait]
impl FilterWheel for VendorFilterWheel {
    async fn move_to_slot(&self, slot: i32) -> Result<(), DeviceOpError> {
        let device_id = &self.device_id;
        self.driver
            .write()
            .await
            .move_to_position(slot)
            .await
            .map_err(|e| {
                DeviceOpError::hardware(
                    Some(device_id.clone()),
                    format!(
                        "Failed to move native filter wheel {} to slot {}: {}",
                        device_id, slot, e
                    ),
                )
            })?;

        // Several vendor SDKs acknowledge the command before the motor
        // starts, and a ZWO EFW can return SDK success for a command that
        // never changes the encoder position. The move has succeeded only
        // once the wheel reads back the requested slot.
        let deadline = tokio::time::Instant::now() + Duration::from_secs(60);
        let mut last_position = None;
        loop {
            let read = self.driver.read().await.get_position().await;
            match read {
                Ok(current) if current == slot => return Ok(()),
                Ok(current) => last_position = Some(current),
                Err(error) if closed(&error) => return Err(self.not_connected()),
                Err(error) => {
                    tracing::warn!(
                        "Native filter wheel {} readback failed while moving to {}: {}",
                        device_id,
                        slot,
                        error
                    );
                }
            }
            if tokio::time::Instant::now() >= deadline {
                return Err(DeviceOpError::hardware(
                    Some(device_id.clone()),
                    format!(
                        "Native filter wheel {} did not reach slot {} within 60s (last position: {:?})",
                        device_id, slot, last_position
                    ),
                ));
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    }

    async fn position(&self) -> Result<i32, DeviceOpError> {
        self.driver
            .read()
            .await
            .get_position()
            .await
            .map_err(DeviceOpError::driver)
    }

    async fn is_moving(&self) -> Result<bool, DeviceOpError> {
        self.driver
            .read()
            .await
            .is_moving()
            .await
            .map_err(DeviceOpError::driver)
    }

    async fn config(&self) -> Result<(i32, Vec<String>), DeviceOpError> {
        let wheel = self.driver.read().await;
        let count = wheel.get_filter_count();
        let names = wheel
            .get_filter_names()
            .await
            .map_err(DeviceOpError::driver)?;
        Ok((count, names))
    }

    async fn set_names(&self, names: Vec<String>) -> Result<(), DeviceOpError> {
        let mut wheel = self.driver.write().await;
        for (slot, name) in names.iter().enumerate() {
            // Why: a wheel has at most 16 slots; usize -> i32 is exact.
            wheel
                .set_filter_name(slot as i32, name.clone())
                .await
                .map_err(DeviceOpError::driver)?;
        }
        Ok(())
    }

    async fn capabilities(&self, _device_id: &str) -> Result<FilterWheelCapabilities, SkotiqError> {
        // Vendor SDKs that keep no filter labels (the ZWO EFW) refuse the read
        // on first connect; the app then labels the slots by number.
        let filter_names = self
            .driver
            .read()
            .await
            .get_filter_names()
            .await
            .unwrap_or_default();
        let current_position = self.driver.read().await.get_position().await.ok();
        // A busy SDK reads as a wheel at rest; the status poll corrects it.
        let is_moving = self.driver.read().await.is_moving().await.unwrap_or(false);
        let position_count = self.driver.read().await.get_filter_count();
        Ok(FilterWheelCapabilities {
            position_count,
            current_position,
            filter_names,
            is_moving,
            // `FilterWheelDriver` requires `set_filter_name`: every vendor
            // wheel can be renamed (a ZWO EFW keeps the names it is given).
            can_set_filter_names: true,
            ..Default::default()
        })
    }
}

/// An ASCOM filter wheel. Every call is a command on the wrapper's channel,
/// run by the STA worker.
#[cfg(windows)]
pub(crate) struct AscomWheel {
    device_id: String,
    driver: Exclusive<crate::ascom_wrapper::filterwheel::AscomFilterWheelWrapper>,
}

#[cfg(windows)]
impl AscomWheel {
    pub(crate) fn new(
        device_id: &str,
        wrapper: crate::ascom_wrapper::filterwheel::AscomFilterWheelWrapper,
    ) -> Self {
        Self {
            device_id: device_id.to_string(),
            driver: Exclusive::new(wrapper),
        }
    }
}

#[cfg(windows)]
#[async_trait]
impl RigDriver for AscomWheel {
    async fn disconnect(&self) -> Result<(), DriverError> {
        use skotiq_device::DeviceDriver;
        self.driver.write().await.disconnect().await
    }

    async fn heartbeat(&self) -> Result<bool, String> {
        match self.driver.read().await.heartbeat().await {
            Ok(()) => {
                tracing::trace!("ASCOM filter wheel {} heartbeat: healthy", self.device_id);
                Ok(true)
            }
            Err(e) => {
                tracing::debug!(
                    "ASCOM filter wheel {} heartbeat failed: {:?}",
                    self.device_id,
                    e
                );
                Ok(false)
            }
        }
    }
}

#[cfg(windows)]
#[async_trait]
impl FilterWheel for AscomWheel {
    async fn move_to_slot(&self, slot: i32) -> Result<(), DeviceOpError> {
        let device_id = &self.device_id;
        let mut wheel = self.driver.write().await;
        wheel.move_to_position(slot).await.map_err(|e| {
            DeviceOpError::hardware(
                Some(device_id.clone()),
                format!(
                    "Failed to move ASCOM filter wheel {} to slot {}: {}",
                    device_id, slot, e
                ),
            )
        })
    }

    async fn position(&self) -> Result<i32, DeviceOpError> {
        let wheel = self.driver.read().await;
        wheel.get_position().await.map_err(DeviceOpError::driver)
    }

    async fn is_moving(&self) -> Result<bool, DeviceOpError> {
        let wheel = self.driver.read().await;
        wheel.is_moving().await.map_err(DeviceOpError::driver)
    }

    /// One Position read supplies both values; that read can be an expensive
    /// or persistently failing COM property (the ZWO EFW driver in a headless
    /// session), so it is not repeated.
    async fn is_moving_at(&self, position: i32) -> Result<bool, DeviceOpError> {
        Ok(position == -1)
    }

    async fn config(&self) -> Result<(i32, Vec<String>), DeviceOpError> {
        let wheel = self.driver.read().await;
        let names = wheel
            .get_filter_names()
            .await
            .map_err(DeviceOpError::driver)?;
        let count = names.len() as i32;
        Ok((count, names))
    }

    async fn set_names(&self, _names: Vec<String>) -> Result<(), DeviceOpError> {
        let msg = "ASCOM filter names are managed by the driver and cannot be set programmatically";
        tracing::warn!("filter_wheel_set_filter_names: {}", msg);
        Err(DeviceOpError::unsupported(msg))
    }

    async fn capabilities(&self, device_id: &str) -> Result<FilterWheelCapabilities, SkotiqError> {
        // A failed Names read is not a wheel without filters: a 0-slot wheel
        // makes the scheduler reject every filtered target. ASCOM Names is
        // one of the reads that intermittently throws 0x80020009 headless.
        let filter_names = self
            .driver
            .read()
            .await
            .get_filter_names()
            .await
            .map_err(|e| SkotiqError::connection_failed(device_id, e.to_string()))?;
        // An empty list is a wheel without custom names; it still has the
        // slots the driver reports.
        let slot_count = self.driver.read().await.get_filter_count();
        let current_position = self.driver.read().await.get_position().await.ok();
        Ok(FilterWheelCapabilities {
            position_count: if filter_names.is_empty() {
                slot_count
            } else {
                i32::try_from(filter_names.len()).unwrap_or(i32::MAX)
            },
            current_position,
            filter_names,
            focus_offsets: Vec::new(),
            can_set_focus_offsets: false,
            ..Default::default()
        })
    }
}

#[async_trait]
impl RigDriver for AlpacaFilterWheel {
    async fn disconnect(&self) -> Result<(), DriverError> {
        Ok(AlpacaFilterWheel::disconnect(self).await?)
    }

    async fn heartbeat(&self) -> Result<bool, String> {
        match AlpacaFilterWheel::heartbeat(self).await {
            Ok(rtt_ms) => {
                tracing::trace!("Alpaca filter wheel heartbeat: {}ms RTT", rtt_ms);
                Ok(true)
            }
            Err(e) => {
                tracing::debug!("Alpaca filter wheel heartbeat failed: {}", e);
                Ok(false)
            }
        }
    }
}

#[async_trait]
impl FilterWheel for AlpacaFilterWheel {
    async fn move_to_slot(&self, slot: i32) -> Result<(), DeviceOpError> {
        self.set_position(slot).await.map_err(DeviceOpError::driver)
    }

    async fn position(&self) -> Result<i32, DeviceOpError> {
        AlpacaFilterWheel::position(self)
            .await
            .map_err(DeviceOpError::driver)
    }

    /// Alpaca reports motion as position -1.
    async fn is_moving(&self) -> Result<bool, DeviceOpError> {
        Ok(AlpacaFilterWheel::position(self).await? == -1)
    }

    async fn config(&self) -> Result<(i32, Vec<String>), DeviceOpError> {
        let names = self.names().await?;
        let count = names.len() as i32;
        Ok((count, names))
    }

    async fn set_names(&self, _names: Vec<String>) -> Result<(), DeviceOpError> {
        let msg = "Alpaca filter names are read-only and cannot be set programmatically";
        tracing::warn!("filter_wheel_set_filter_names: {}", msg);
        Err(DeviceOpError::unsupported(msg))
    }

    async fn capabilities(&self, device_id: &str) -> Result<FilterWheelCapabilities, SkotiqError> {
        // A failed Names read is not a wheel without filters: a 0-slot wheel
        // makes the scheduler reject every filtered target. An empty list
        // that the wheel did answer is passed on as it is.
        let filter_names = self.names().await.map_err(|e| {
            SkotiqError::connection_failed(
                device_id,
                format!("Failed to read Alpaca filter wheel names: {e}"),
            )
        })?;
        // No offsets only loses per-filter focus compensation, so the read
        // goes on, but says so: it looks the same as a wheel with none set.
        let focus_offsets = match self.focus_offsets().await {
            Ok(offsets) => offsets,
            Err(e) => {
                tracing::warn!(
                    "Alpaca filter wheel {}: focus-offset read failed ({}); per-filter \
                     focus compensation will be skipped for this wheel.",
                    device_id,
                    e
                );
                Vec::new()
            }
        };
        Ok(FilterWheelCapabilities {
            position_count: filter_names.len() as i32,
            current_position: AlpacaFilterWheel::position(self).await.ok(),
            filter_names,
            focus_offsets,
            // Alpaca has no IsMoving for a wheel; motion is position -1.
            is_moving: false,
            ..Default::default()
        })
    }
}

/// An INDI filter wheel on its server's shared connection.
pub(crate) struct IndiWheel {
    device_id: String,
    wheel: IndiFilterWheel,
}

impl IndiWheel {
    pub(crate) fn new(device_id: &str, wheel: IndiFilterWheel) -> Self {
        Self {
            device_id: device_id.to_string(),
            wheel,
        }
    }
}

#[async_trait]
impl RigDriver for IndiWheel {
    async fn disconnect(&self) -> Result<(), DriverError> {
        Ok(self.wheel.disconnect().await?)
    }

    async fn heartbeat(&self) -> Result<bool, String> {
        self.wheel.check().await.map_err(|e| e.to_string())
    }
}

#[async_trait]
impl FilterWheel for IndiWheel {
    async fn move_to_slot(&self, slot: i32) -> Result<(), DeviceOpError> {
        self.wheel.move_to_position(slot).await.map_err(|e| {
            DeviceOpError::hardware(
                Some(self.device_id.clone()),
                format!(
                    "Failed to set INDI filter wheel {} to slot {}: {}",
                    self.wheel.device_name(),
                    slot,
                    e
                ),
            )
        })
    }

    async fn position(&self) -> Result<i32, DeviceOpError> {
        self.wheel
            .get_position()
            .await
            .map_err(DeviceOpError::driver)
    }

    async fn is_moving(&self) -> Result<bool, DeviceOpError> {
        Ok(self.wheel.is_moving().await)
    }

    /// A failed read is reported as one. An empty list instead would make the
    /// callers answer "filter not found in the wheel" for what is a
    /// connection problem.
    async fn config(&self) -> Result<(i32, Vec<String>), DeviceOpError> {
        let names = self.wheel.get_names().await.map_err(|e| {
            DeviceOpError::hardware(
                Some(self.device_id.clone()),
                format!(
                    "Failed to read INDI filter names for {}: {}",
                    self.wheel.device_name(),
                    e
                ),
            )
        })?;
        let count = names.len() as i32;
        Ok((count, names))
    }

    async fn set_names(&self, _names: Vec<String>) -> Result<(), DeviceOpError> {
        let msg = "INDI filter name setting is unavailable in this manager path";
        tracing::warn!("filter_wheel_set_filter_names: {}", msg);
        Err(DeviceOpError::unsupported(msg))
    }

    /// The slot count is the FILTER_SLOT range when the driver publishes
    /// one, otherwise the number of names.
    async fn capabilities(&self, _device_id: &str) -> Result<FilterWheelCapabilities, SkotiqError> {
        use skotiq_indi::IndiPermission;
        let device_name = self.wheel.device_name();
        let filter_names = self.wheel.get_names().await.unwrap_or_default();
        let (slot_limits, name_property_writable) = {
            let client = self.wheel.client().read().await;
            let limits = client
                .get_number_limits(device_name, indi::FILTER_SLOT, indi::FILTER_SLOT_VALUE)
                .await;
            let writable = client
                .get_properties(device_name)
                .await
                .iter()
                .find(|p| p.name == indi::FILTER_NAME)
                .is_some_and(|p| {
                    matches!(
                        p.perm,
                        IndiPermission::WriteOnly | IndiPermission::ReadWrite
                    )
                });
            (limits, writable)
        };
        let position_count = slot_limits
            .and_then(|limits| match (limits.min, limits.max) {
                // A whole number of slots, so the cast is exact.
                (Some(min), Some(max)) if max >= min => Some((max - min + 1.0).round() as i32),
                _ => None,
            })
            .or_else(|| i32::try_from(filter_names.len()).ok())
            .unwrap_or(0);
        Ok(FilterWheelCapabilities {
            position_count,
            current_position: self.wheel.get_position().await.ok(),
            filter_names,
            focus_offsets: Vec::new(),
            is_moving: self.wheel.is_moving().await,
            can_set_filter_names: name_property_writable,
            can_set_focus_offsets: false,
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
            .await
            .map_err(DeviceOpError::driver)?;
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

        fn get_filter_count(&self) -> i32 {
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
        let wheel = Arc::new(VendorFilterWheel::new(
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
