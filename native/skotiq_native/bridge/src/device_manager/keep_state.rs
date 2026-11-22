//! A reconnect keeps the operating state a device had at its last
//! disconnect and moves nothing (owner, 2026-11-22: "If a user disconnects a
//! hardware device and then reconnects, it should pick up the state it was
//! in on last disconnect... whatever position or state they're in on connect
//! should be kept, just leave them there").
//!
//! A mount's tracking is what it last read (or was last commanded): one that
//! stopped tracking by itself, at its limit or by a hand controller, holds
//! that. A reconnect that finds the mount tracking otherwise sets it back,
//! at the rate it had, and never slews, parks, unparks or homes it. A first
//! connect, with nothing held, adopts what the mount reports. A camera keeps
//! its cooler, gain and offset ([`DeviceManager::restore_camera_state`]).

use crate::device::{ConnectionState, DeviceInfo, MountStatus};
use crate::device_manager::{DeviceManager, HeldTracking};
use crate::event::equipment::{EquipmentEvent, EventSeverity};

impl DeviceManager {
    /// Record what a status read says the mount's tracking is, while it is
    /// connected. A write only when it changes: the mount is read every
    /// second or two.
    pub(crate) async fn hold_mount_tracking(&self, device_id: &str, status: &MountStatus) {
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

    /// After a connect: set the mount's tracking back to `held`, what it was
    /// at its last disconnect, when it reports otherwise. Nothing for a first
    /// connect. Tracking is not switched on for a parked or slewing mount, or
    /// for one that came back at home though it was not at home before (it
    /// lost its position).
    pub(crate) async fn keep_mount_tracking(&self, info: &DeviceInfo, held: Option<HeldTracking>) {
        let device_id = &info.id;
        let Some(held) = held else {
            return;
        };
        let status = match self.mount_get_status(device_id).await {
            Ok(status) => status,
            Err(e) => {
                tracing::warn!("{device_id} reconnected; its tracking could not be read: {e}");
                return;
            }
        };
        if !held.tracking {
            if status.tracking {
                tracing::info!("{device_id} reconnected tracking; it was not, so tracking stops");
                if let Err(e) = self.mount_set_tracking(device_id, false).await {
                    self.tracking_not_kept(info, &e.to_string());
                }
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
        let rate = held
            .rate
            .filter(|rate| status.tracking_rate != Some(*rate) && status.can_set_tracking_rate);
        if let Some(wire) = rate.and_then(|rate| rate.to_wire()) {
            if let Err(e) = self.mount_set_tracking_rate(device_id, wire).await {
                tracing::warn!("{device_id} reconnected; its tracking rate was not set back: {e}");
            }
        }
        if status.tracking {
            return;
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
            Err(e) => self.tracking_not_kept(info, &e.to_string()),
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
