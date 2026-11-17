//! Reopening a camera, and the camera state a reopen restores.
//!
//! A camera whose USB path drops for a few seconds can come back with a
//! broken session: the ZWO SDK keeps answering status reads on the old
//! handle while every exposure fails, until the camera is closed and opened
//! again (rig, 2026-11-16). The run's camera retry asks for that reopen
//! ([`DeviceManager::reopen_camera_after`]); the operator does the same with
//! Disconnect and Connect. Both go through the one connection path, and every
//! connect of a camera Skotiq held before restores what it held, cooler first
//! ([`DeviceManager::restore_camera_state`]), so the sensor does not warm
//! while the camera is reopened.

use crate::device::{DeviceInfo, DeviceType};
use crate::device_manager::{DeviceManager, HeldCameraState};
use crate::event::equipment::{EquipmentEvent, EventSeverity};
use std::time::Duration;

/// How long after a device appeared on or left the bus a failed exposure is
/// taken as a broken session, whatever the driver's words. Covers a long
/// exposure that was running when the bus changed.
const BUS_CHANGE_SUSPECT_WINDOW: Duration = Duration::from_secs(15 * 60);

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

    /// Close and reopen `camera_id` when `error`, the failure of its last
    /// exposure, means its session is broken: the vendor's words say so, or
    /// a device came or went on the bus recently. `Ok(true)` when it was
    /// reopened, `Ok(false)` when the failure does not call for it.
    pub(crate) async fn reopen_camera_after(
        &self,
        camera_id: &str,
        error: &str,
    ) -> Result<bool, String> {
        let bus_changed = crate::hotplug::bus_changed_within(BUS_CHANGE_SUSPECT_WINDOW);
        if !skotiq_native::camera_session_broken(error) && !bus_changed {
            return Ok(false);
        }
        tracing::warn!(
            "Camera {camera_id} exposure failed with \"{error}\"{}; closing and reopening the camera",
            if bus_changed {
                " after a device change on the bus"
            } else {
                ""
            }
        );
        self.reopen_camera(camera_id).await.map(|()| true)
    }

    /// Disconnect and connect `camera_id` through the normal paths, keeping
    /// its auto-reconnect setting. The connect restores its held state.
    pub(crate) async fn reopen_camera(&self, camera_id: &str) -> Result<(), String> {
        let auto_reconnect = self
            .devices
            .read()
            .await
            .get(camera_id)
            .map(|dev| dev.auto_reconnect)
            .ok_or_else(|| format!("Device not found: {camera_id}"))?;
        if let Err(e) = self.disconnect_device(camera_id).await {
            tracing::warn!("Reopen of {camera_id}: closing it reported {e}; opening it anyway");
        }
        let connected = self.connect_device(camera_id).await;
        self.set_auto_reconnect(camera_id, auto_reconnect).await;
        connected
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
                Some(dev) => (dev.desired_cooler, dev.held_camera_state.unwrap_or_default()),
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
