//! A reconnect keeps the operating state a device had at its last
//! disconnect and moves nothing (owner, 2026-11-22: "If a user disconnects a
//! hardware device and then reconnects, it should pick up the state it was
//! in on last disconnect... whatever position or state they're in on connect
//! should be kept, just leave them there").
//!
//! A mount's tracking is what it last read (or was last commanded): one that
//! stopped tracking by itself, at its limit or by a hand controller, holds
//! that. A reconnect that finds a mount that was tracking come back without
//! tracking switches tracking on at the rate it had, and never slews, parks,
//! unparks or homes it. A mount that comes back tracking is left tracking. A
//! first connect, with nothing held, adopts what the mount reports. A camera keeps
//! its cooler, gain and offset ([`DeviceManager::restore_camera_state`]).

use crate::device::{ConnectionState, DeviceInfo, MountStatus};
use crate::device_manager::{DeviceManager, HeldTracking};
use crate::event::equipment::{EquipmentEvent, EventSeverity};

impl DeviceManager {
    /// Record what a status read says the mount's tracking is, while it is
    /// connected and not slewing (a slew's tracking is the slew's). A write
    /// only when it changes: the mount is read every second or two.
    pub(crate) async fn hold_mount_tracking(&self, device_id: &str, status: &MountStatus) {
        if status.slewing {
            return;
        }
        let observed = |previous: Option<HeldTracking>| HeldTracking {
            tracking: status.tracking,
            rate: status.tracking_rate.or(previous.and_then(|held| held.rate)),
            at_home: status.at_home,
        };
        let current = {
            let devices = self.devices.read().await;
            match devices.get(device_id) {
                Some(dev) if dev.connection_state == ConnectionState::Connected => {
                    dev.held_tracking
                }
                _ => return,
            }
        };
        let next = observed(current);
        if current == Some(next) {
            return;
        }
        if let Some(dev) = self.devices.write().await.get_mut(device_id) {
            dev.held_tracking = Some(next);
        }
    }

    /// After a connect: a mount that was tracking at its last disconnect
    /// (`held`) and came back without tracking tracks again, at the rate it
    /// had. Nothing for a first connect, or for a mount that was not
    /// tracking: whatever it does now is left as it is. Tracking is not
    /// switched on for a parked or slewing mount, or for one that came back at
    /// home though it was not at home before (it lost its position).
    pub(crate) async fn keep_mount_tracking(&self, info: &DeviceInfo, held: Option<HeldTracking>) {
        let device_id = &info.id;
        let Some(held) = held.filter(|held| held.tracking) else {
            return;
        };
        let status = match self.mount_get_status(device_id).await {
            Ok(status) => status,
            Err(e) => {
                tracing::warn!("{device_id} reconnected; its tracking could not be read: {e}");
                self.hold_again(device_id, held).await;
                return;
            }
        };
        let rate = held
            .rate
            .filter(|rate| status.tracking_rate != Some(*rate) && status.can_set_tracking_rate)
            .and_then(|rate| rate.to_wire());
        if status.tracking {
            if let Some(wire) = rate {
                self.set_rate_back(device_id, wire).await;
            }
            return;
        }
        let why_not = if status.parked {
            Some("it is parked")
        } else if status.slewing {
            Some("it is slewing")
        } else if status.at_home == Some(true) && held.at_home != Some(true) {
            Some("it came back at home, so it may have lost its position")
        } else {
            None
        };
        if let Some(why) = why_not {
            tracing::info!("{device_id} reconnected; tracking stays off: {why}");
            if why.contains("home") {
                self.notify(
                    "warning",
                    "Mount tracking not resumed",
                    &format!(
                        "{} was tracking before it disconnected, but {why}. Tracking stays \
                         off; check the mount and start tracking by hand.",
                        info.shown_name()
                    ),
                );
            }
            return;
        }
        if let Some(wire) = rate {
            self.set_rate_back(device_id, wire).await;
        }
        match held.rate {
            Some(rate) => tracing::info!(
                "{device_id} reconnected not tracking; it was tracking at the {rate:?} rate, so \
                 tracking resumes"
            ),
            None => tracing::info!(
                "{device_id} reconnected not tracking; it was tracking, so tracking resumes"
            ),
        }
        match self.mount_set_tracking(device_id, true).await {
            Ok(()) => self.notify(
                "info",
                "Mount tracking resumed",
                &format!(
                    "{} came back without tracking; it was tracking before, so it tracks again.",
                    info.shown_name()
                ),
            ),
            Err(e) => {
                self.tracking_not_kept(info, &e.to_string());
                self.hold_again(device_id, held).await;
            }
        }
    }

    async fn set_rate_back(&self, device_id: &str, wire: i32) {
        if let Err(e) = self.mount_set_tracking_rate(device_id, wire).await {
            tracing::warn!("{device_id} reconnected; its tracking rate was not set back: {e}");
        }
    }

    /// The tracking it held stays held when it could not be put back: the
    /// read just after the connect recorded what the mount reports.
    async fn hold_again(&self, device_id: &str, held: HeldTracking) {
        if let Some(dev) = self.devices.write().await.get_mut(device_id) {
            dev.held_tracking = Some(held);
        }
    }

    fn tracking_not_kept(&self, info: &DeviceInfo, error: &str) {
        tracing::warn!(
            "{}: reconnected, but its tracking was not set back: {error}",
            info.id
        );
        self.app_state.publish_equipment_event(
            EquipmentEvent::Error {
                device_type: info.device_type.as_str().to_string(),
                device_id: info.id.clone(),
                message: format!("Reconnected but could not restore mount tracking: {error}"),
            },
            EventSeverity::Warning,
        );
    }
}
