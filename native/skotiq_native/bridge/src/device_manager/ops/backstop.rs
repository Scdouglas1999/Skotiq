//! Backstop poll: a change made outside Skotiq still reaches every UI.
//!
//! Every command Skotiq sends publishes its own event (see `state_events`).
//! A focuser turned with its hand controller, a wheel moved from the vendor's
//! app or a rotator moved by another program publishes nothing, so the host
//! UI kept the old value for good and a linked client caught up only on its
//! 30 s re-read. Every [`BACKSTOP_INTERVAL`] this reads each connected
//! focuser, filter wheel and rotator once and, when the reading differs from
//! the last one published for that device, publishes the event a command
//! would have (`FocuserMoveCompleted`, `FilterChanged`,
//! `RotatorMoveCompleted`). The host and its clients apply those as they
//! apply a command's.
//!
//! It stays out of the way of commands: a device with a command in flight, a
//! long operation (an autofocus move) or a moving reading is skipped, and a
//! reading taken while a command started or ended is thrown away, because
//! that command published the change itself. While a camera is downloading
//! on a shared USB bus nothing is read at all, the same rule the heartbeat
//! follows.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::device::{ConnectionState, DeviceType};
use crate::device_manager::policy::policy;
use crate::device_manager::DeviceManager;
use crate::event::EquipmentEvent;

/// How often the backstop reads the devices. Slow on purpose: it repairs a
/// change nobody announced, it does not track motion.
pub(crate) const BACKSTOP_INTERVAL: Duration = Duration::from_secs(10);

/// Longest a single backstop read may take before the device is skipped for
/// this round.
const BACKSTOP_READ_TIMEOUT: Duration = Duration::from_secs(5);

/// Rotator angles closer than this are the same reading (driver rounding).
const ROTATOR_SAME_DEG: f64 = 0.05;

/// The last sensor temperature and cooler power published per camera, and
/// when.
pub(crate) type PublishedTemperatures =
    Mutex<HashMap<String, (f64, Option<f64>, std::time::Instant)>>;

/// What the backstop compares: the state a command's end event carries.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) enum Reading {
    Focuser(i32),
    Filter(i32),
    Rotator(f64),
}

impl Reading {
    fn same_as(self, other: Reading) -> bool {
        match (self, other) {
            (Reading::Rotator(a), Reading::Rotator(b)) => (a - b).abs() < ROTATOR_SAME_DEG,
            (a, b) => a == b,
        }
    }

    /// The reading an end-of-move event carries, for the events that have one.
    pub(crate) fn of_event(event: &EquipmentEvent) -> Option<(&str, Reading)> {
        match event {
            EquipmentEvent::FocuserMoveCompleted {
                device_id,
                position,
            } => Some((device_id, Reading::Focuser(*position))),
            EquipmentEvent::FilterChanged {
                device_id,
                position,
                ..
            } => Some((device_id, Reading::Filter(*position))),
            EquipmentEvent::RotatorMoveCompleted { device_id, angle } => {
                Some((device_id, Reading::Rotator(*angle)))
            }
            _ => None,
        }
    }
}

#[derive(Debug, Default, Clone, Copy)]
struct Activity {
    /// Commands for the device running now.
    in_flight: u32,
    /// Bumped when a command starts and when it ends.
    generation: u64,
    /// The last reading published for the device, by a command or by the
    /// backstop.
    known: Option<Reading>,
}

/// Commands in flight per device. See the module docs.
#[derive(Default)]
pub(crate) struct CommandActivity {
    inner: Arc<Mutex<HashMap<String, Activity>>>,
}

/// Marks a command for one device as running until dropped, including on an
/// early return or an error.
pub(crate) struct CommandGuard {
    inner: Arc<Mutex<HashMap<String, Activity>>>,
    device_id: String,
}

impl Drop for CommandGuard {
    fn drop(&mut self) {
        let mut map = self.inner.lock().unwrap_or_else(|p| p.into_inner());
        let entry = map.entry(self.device_id.clone()).or_default();
        entry.in_flight = entry.in_flight.saturating_sub(1);
        entry.generation = entry.generation.wrapping_add(1);
    }
}

impl CommandActivity {
    /// Mark a command for `device_id` as running until the guard drops.
    pub(crate) fn begin(&self, device_id: &str) -> CommandGuard {
        let mut map = self.inner.lock().unwrap_or_else(|p| p.into_inner());
        let entry = map.entry(device_id.to_string()).or_default();
        entry.in_flight += 1;
        entry.generation = entry.generation.wrapping_add(1);
        CommandGuard {
            inner: self.inner.clone(),
            device_id: device_id.to_string(),
        }
    }

    /// Commands in flight and the generation, for one device.
    pub(crate) fn snapshot(&self, device_id: &str) -> (u32, u64) {
        let map = self.inner.lock().unwrap_or_else(|p| p.into_inner());
        map.get(device_id)
            .map_or((0, 0), |a| (a.in_flight, a.generation))
    }

    /// Record the reading an event just published for `device_id`.
    pub(crate) fn record(&self, device_id: &str, reading: Reading) {
        let mut map = self.inner.lock().unwrap_or_else(|p| p.into_inner());
        map.entry(device_id.to_string()).or_default().known = Some(reading);
    }

    fn known(&self, device_id: &str) -> Option<Reading> {
        let map = self.inner.lock().unwrap_or_else(|p| p.into_inner());
        map.get(device_id).and_then(|a| a.known)
    }

    /// Forget a device that is no longer connected, so a later connect
    /// starts from its own first reading.
    fn forget_except(&self, connected: &[String]) {
        let mut map = self.inner.lock().unwrap_or_else(|p| p.into_inner());
        map.retain(|id, a| a.in_flight > 0 || connected.iter().any(|c| c == id));
    }
}

/// Whether the backstop task runs for this process.
static BACKSTOP_STARTED: AtomicBool = AtomicBool::new(false);

impl DeviceManager {
    /// Start the backstop poll once per process. Called when a focuser,
    /// filter wheel or rotator connects; with none connected each round
    /// reads nothing.
    pub(crate) fn ensure_backstop_poll(&self) {
        if BACKSTOP_STARTED.swap(true, Ordering::SeqCst) {
            return;
        }
        let Ok(runtime) = crate::ensure_runtime() else {
            BACKSTOP_STARTED.store(false, Ordering::SeqCst);
            return;
        };
        runtime.handle().spawn(async move {
            // The task outlives the call, so it reads through the
            // process-wide manager, as the heartbeat tasks do.
            let manager = crate::device_manager::get_device_manager().clone();
            loop {
                tokio::time::sleep(BACKSTOP_INTERVAL).await;
                manager.backstop_round().await;
            }
        });
    }

    /// One backstop round over every connected focuser, filter wheel and
    /// rotator.
    pub(crate) async fn backstop_round(&self) {
        let devices: Vec<(String, DeviceType)> = {
            let devices = self.devices.read().await;
            devices
                .iter()
                .filter(|(_, d)| d.connection_state == ConnectionState::Connected)
                .filter(|(_, d)| policy(d.info.device_type).backstop_polled)
                .map(|(id, d)| (id.clone(), d.info.device_type))
                .collect()
        };
        let ids: Vec<String> = devices.iter().map(|(id, _)| id.clone()).collect();
        self.command_activity.forget_except(&ids);
        if self.is_usb_contended() {
            return;
        }
        for (device_id, device_type) in devices {
            self.backstop_check(&device_id, device_type).await;
        }
    }

    async fn backstop_check(&self, device_id: &str, device_type: DeviceType) {
        let (in_flight, generation) = self.command_activity.snapshot(device_id);
        if in_flight > 0 || self.is_operation_active(device_id) {
            return;
        }
        let read = tokio::time::timeout(
            BACKSTOP_READ_TIMEOUT,
            self.backstop_read(device_id, device_type),
        )
        .await;
        let Ok(Some(reading)) = read else {
            return;
        };
        // A command that started or ended during the read published its own
        // result; this reading may predate it.
        if self.command_activity.snapshot(device_id) != (0, generation) {
            return;
        }
        match self.command_activity.known(device_id) {
            Some(known) if known.same_as(reading) => {}
            Some(_) => self.publish_backstop(device_id, reading).await,
            // The first reading after a connect is what the connect already
            // reported; it becomes the baseline.
            None => self.command_activity.record(device_id, reading),
        }
    }

    /// The device's settled state, or `None` while it moves or cannot be read.
    async fn backstop_read(&self, device_id: &str, device_type: DeviceType) -> Option<Reading> {
        match device_type {
            DeviceType::Focuser => {
                if self.focuser_is_moving(device_id).await.ok()? {
                    return None;
                }
                self.focuser_get_position(device_id)
                    .await
                    .ok()
                    .map(Reading::Focuser)
            }
            DeviceType::FilterWheel => {
                // Wheels report -1 while the slot is changing.
                let position = self.filter_wheel_get_position(device_id).await.ok()?;
                (position >= 0).then_some(Reading::Filter(position))
            }
            DeviceType::Rotator => {
                if self.rotator_is_moving(device_id).await.ok()? {
                    return None;
                }
                self.rotator_get_position(device_id)
                    .await
                    .ok()
                    .map(Reading::Rotator)
            }
            _ => None,
        }
    }

    async fn publish_backstop(&self, device_id: &str, reading: Reading) {
        tracing::info!(
            "Backstop: {} changed outside Skotiq, now {:?}",
            device_id,
            reading
        );
        let event = match reading {
            Reading::Focuser(position) => EquipmentEvent::FocuserMoveCompleted {
                device_id: device_id.to_string(),
                position,
            },
            Reading::Filter(position) => {
                let names = self
                    .filter_wheel_get_config(device_id)
                    .await
                    .map(|(_, names)| names)
                    .unwrap_or_default();
                EquipmentEvent::FilterChanged {
                    device_id: device_id.to_string(),
                    position,
                    filter_name: crate::filter_matching::filter_slot_name(&names, position),
                }
            }
            Reading::Rotator(angle) => EquipmentEvent::RotatorMoveCompleted {
                device_id: device_id.to_string(),
                angle,
            },
        };
        self.publish_state_event(event);
    }
}

#[cfg(test)]
#[path = "backstop_tests.rs"]
mod tests;
