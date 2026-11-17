//! Reopening a device whose session broke, and the camera state a reopen
//! restores.
//!
//! A power box or hub that drops for a few seconds leaves the devices behind
//! it on broken sessions (rig, 2026-11-16). The ZWO camera kept answering
//! status reads on the old handle while every exposure failed; the ZWO filter
//! wheel and focuser answered "Device disconnected". Closing and opening each
//! again brought it back. [`DeviceManager::reopen_after`] owns that rule: the
//! run's camera retry, the filter wheel and focuser moves, and the heartbeat
//! all ask it, and it reopens through the normal connection path.
//!
//! A reopen is not a loss of the device. It does not announce the device as
//! disconnected, so nothing that reacts to a lost camera or mount (the app
//! pauses a run for one) fires for it; it announces the connect as usual.
//! Every connect of a camera Skotiq held before restores what it held, cooler
//! first ([`DeviceManager::restore_camera_state`]). A reopened wheel or
//! focuser has its slot or position read again, never set.

use crate::device::{DeviceInfo, DeviceType};
use crate::device_manager::{DeviceManager, HeldCameraState};
use crate::event::equipment::{EquipmentEvent, EventSeverity};
use std::collections::HashMap;
use std::sync::{Arc, Mutex as StdMutex, OnceLock};
use std::time::Duration;

/// How long after a device appeared on or left the bus a failure is taken as
/// a broken session. Covers a long exposure that was running when the bus
/// changed.
const BUS_CHANGE_SUSPECT_WINDOW: Duration = Duration::from_secs(15 * 60);

/// One reopen at a time per device: the heartbeat and a move can both find a
/// wheel gone at once.
fn reopen_lock(device_id: &str) -> Arc<tokio::sync::Mutex<()>> {
    static LOCKS: OnceLock<StdMutex<HashMap<String, Arc<tokio::sync::Mutex<()>>>>> =
        OnceLock::new();
    LOCKS
        .get_or_init(Default::default)
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .entry(device_id.to_string())
        .or_default()
        .clone()
}

/// Ask for [`DeviceManager::reopen_after`] on a task of its own, for a
/// caller the reopen ends (the device's heartbeat). The reopens run on one
/// worker the requests reach by channel, so the heartbeat's future does not
/// hold the connect that starts a heartbeat.
pub(crate) fn reopen_in_background(manager: Arc<DeviceManager>, device_id: String, error: String) {
    type Request = (Arc<DeviceManager>, String, String);
    static WORKER: OnceLock<tokio::sync::mpsc::UnboundedSender<Request>> = OnceLock::new();
    let sender = WORKER.get_or_init(|| {
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<Request>();
        tokio::spawn(async move {
            while let Some((manager, device_id, error)) = rx.recv().await {
                if let Err(e) = manager.reopen_after(&device_id, &error).await {
                    tracing::warn!("Reopen of {device_id} failed: {e}");
                }
            }
        });
        tx
    });
    let _ = sender.send((manager, device_id, error));
}

/// Whether a failure's words say the device is gone.
fn says_disconnected(error: &str) -> bool {
    let error = error.to_ascii_lowercase();
    error.contains("disconnected") || error.contains("not connected")
}

impl DeviceManager {
    /// Update what `device_id` is recorded as holding. A write only when it
    /// changes: status reads come several times a second during a run.
    pub(crate) async fn hold_camera_state(
        &self,
        device_id: &str,
        update: impl FnOnce(&mut HeldCameraState),
    ) {
        let current = {
            let devices = self.devices.read().await;
            match devices.get(device_id) {
                Some(dev) if dev.info.device_type == DeviceType::Camera => {
                    dev.held_camera_state.unwrap_or_default()
                }
                _ => return,
            }
        };
        let mut next = current;
        update(&mut next);
        if next == current {
            return;
        }
        if let Some(dev) = self.devices.write().await.get_mut(device_id) {
            dev.held_camera_state = Some(next);
        }
    }

    /// Whether `error`, a failure of `device_id`, means its session is
    /// broken and a reopen is the cure:
    ///
    /// * a camera: the vendor's words say so (`camera_session_broken`), or a
    ///   device came or went on the bus recently;
    /// * a filter wheel or focuser: it says it is disconnected, and a device
    ///   came or went on the bus recently.
    pub(crate) async fn wants_reopen(&self, device_id: &str, error: &str) -> bool {
        let Some(device_type) = self
            .devices
            .read()
            .await
            .get(device_id)
            .map(|dev| dev.info.device_type)
        else {
            return false;
        };
        let bus_changed = crate::hotplug::bus_changed_within(BUS_CHANGE_SUSPECT_WINDOW);
        match device_type {
            DeviceType::Camera => skotiq_native::camera_session_broken(error) || bus_changed,
            DeviceType::FilterWheel | DeviceType::Focuser => {
                bus_changed && says_disconnected(error)
            }
            _ => false,
        }
    }

    /// Close and reopen `device_id` when `error` calls for it
    /// ([`Self::wants_reopen`]). `Ok(true)` when the device was reopened, by
    /// this call or by one that held the reopen while this one waited;
    /// `Ok(false)` when the failure does not call for it.
    pub(crate) async fn reopen_after(&self, device_id: &str, error: &str) -> Result<bool, String> {
        if !self.wants_reopen(device_id, error).await {
            return Ok(false);
        }
        let lock = reopen_lock(device_id);
        let Ok(_reopening) = lock.try_lock() else {
            // Another caller is reopening it: wait for that one.
            let _done = lock.lock().await;
            return Ok(self.answers_now(device_id).await);
        };
        tracing::warn!(
            "{device_id} failed with \"{error}\"; closing and reopening it{}",
            if crate::hotplug::bus_changed_within(BUS_CHANGE_SUSPECT_WINDOW) {
                " (a device changed on the bus recently)"
            } else {
                ""
            }
        );
        self.reopen_device(device_id).await.map(|()| true)
    }

    /// Close `device_id` without announcing it lost, and connect it through
    /// the normal path, keeping its auto-reconnect setting. The connect
    /// restores a camera's held state and reads a wheel's slot and a
    /// focuser's position.
    pub(crate) async fn reopen_device(&self, device_id: &str) -> Result<(), String> {
        let auto_reconnect = self
            .devices
            .read()
            .await
            .get(device_id)
            .map(|dev| dev.auto_reconnect)
            .ok_or_else(|| format!("Device not found: {device_id}"))?;
        if let Err(e) = self.close_device(device_id, false).await {
            tracing::warn!("Reopen of {device_id}: closing it reported {e}; opening it anyway");
        }
        let connected = self.connect_device(device_id).await;
        self.set_auto_reconnect(device_id, auto_reconnect).await;
        connected
    }

    /// Read where a wheel, focuser or rotator that was just connected is.
    /// Only a read: a reconnect never moves one.
    pub(crate) async fn read_position_after_connect(&self, info: &DeviceInfo) {
        let id = &info.id;
        match info.device_type {
            DeviceType::FilterWheel => match self.filter_wheel_get_position(id).await {
                Ok(slot) => tracing::info!("Filter wheel {id} connected at slot {slot}"),
                Err(e) => tracing::warn!("Filter wheel {id} connected; its slot read failed: {e}"),
            },
            DeviceType::Focuser => match self.focuser_get_position(id).await {
                Ok(position) => tracing::info!("Focuser {id} connected at position {position}"),
                Err(e) => tracing::warn!("Focuser {id} connected; its position read failed: {e}"),
            },
            _ => {}
        }
    }

    /// After a device came or went on the bus, a device the reconnection
    /// loop gave up on gets its attempts back: a hub that takes minutes to
    /// power up outlasts them.
    pub(crate) async fn retry_lost_devices(&self) {
        let mut devices = self.devices.write().await;
        for dev in devices.values_mut() {
            if dev.connection_state == crate::device::ConnectionState::Error && dev.auto_reconnect {
                dev.reconnect_attempts = 0;
            }
        }
    }

    /// Run `op` on `device_id`; when it fails in a way that calls for a
    /// reopen, reopen the device and run it once more. A move the run makes
    /// right after a hub dropped then lands instead of failing first.
    pub(crate) async fn with_reopen<T, F, Fut>(
        &self,
        device_id: &str,
        op: F,
    ) -> Result<T, crate::dispatch::error::DeviceOpError>
    where
        F: Fn() -> Fut,
        Fut: std::future::Future<Output = Result<T, crate::dispatch::error::DeviceOpError>>,
    {
        let error = match op().await {
            Ok(value) => return Ok(value),
            Err(error) => error,
        };
        match self.reopen_after(device_id, &error.to_string()).await {
            Ok(true) => op().await,
            Ok(false) => Err(error),
            Err(reopen_error) => {
                tracing::warn!("Reopen of {device_id} failed: {reopen_error}");
                Err(error)
            }
        }
    }

    /// A cooler switched off just before the camera is disconnected was
    /// switched off for the disconnect (the app does that so a driver-side
    /// cooler does not run on unattended); what the camera holds for its next
    /// connect is the cooler it ran before.
    pub(crate) async fn keep_cooler_through_disconnect(&self, device_id: &str) {
        const FOR_THE_DISCONNECT: Duration = Duration::from_secs(60);
        let mut devices = self.devices.write().await;
        let Some(dev) = devices.get_mut(device_id) else {
            return;
        };
        let Some(held) = dev.held_camera_state.as_mut() else {
            return;
        };
        if let Some((at, running)) = held.cooler_off.take() {
            if at.elapsed() <= FOR_THE_DISCONNECT {
                dev.desired_cooler = Some(running);
            }
        }
    }

    /// Put back on a camera that was just connected what it held before:
    /// first the cooler, on at its set-point, then gain and offset. Nothing
    /// for a camera this app has not held; a cooler that was off is left
    /// off. The cooler is commanded by set-point only: ZWO's
    /// `ASI_COOLER_POWER_PERC` is read only, as cooler power is in ASCOM,
    /// Alpaca and INDI, and QHY's manual PWM replaces the set-point loop
    /// rather than starting it. Switching the cooler on at its set-point
    /// resumes the camera's own loop within seconds.
    ///
    /// The cooler state commanded through Skotiq wins over the last read:
    /// a camera that lost power can read its cooler off before it is
    /// reopened. A failed restore is reported and does not fail the connect.
    pub(crate) async fn restore_camera_state(&self, info: &DeviceInfo) {
        let device_id = &info.id;
        let (commanded, held) = {
            let devices = self.devices.read().await;
            match devices.get(device_id) {
                Some(dev) => (
                    dev.desired_cooler,
                    dev.held_camera_state.unwrap_or_default(),
                ),
                None => return,
            }
        };
        let cooler = match commanded {
            Some((on, target)) => Some((on, target.or(held.target_temp))),
            None => held.cooler_on.map(|on| (on, held.target_temp)),
        };

        let mut failures = Vec::new();
        if let Some((true, target)) = cooler {
            tracing::info!(
                "Restoring camera {device_id} cooler: on, set-point {target:?} C (it ran at {:?} % \
                 power; the camera sets its own power)",
                held.cooler_power
            );
            if let Err(e) = self.camera_set_cooler(device_id, true, target).await {
                failures.push(format!("cooler: {e}"));
            }
        }
        if let Some(gain) = held.gain {
            if let Err(e) = self.camera_set_gain(device_id, gain).await {
                failures.push(format!("gain {gain}: {e}"));
            }
        }
        if let Some(offset) = held.offset {
            if let Err(e) = self.camera_set_offset(device_id, offset).await {
                failures.push(format!("offset {offset}: {e}"));
            }
        }
        if failures.is_empty() {
            return;
        }
        let message = format!(
            "Reconnected, but could not restore the camera's {}",
            failures.join("; ")
        );
        tracing::warn!("{device_id}: {message}");
        self.app_state.publish_equipment_event(
            EquipmentEvent::Error {
                device_type: info.device_type.as_str().to_string(),
                device_id: device_id.clone(),
                message,
            },
            EventSeverity::Warning,
        );
    }
}
