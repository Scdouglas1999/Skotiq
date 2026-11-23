//! Following a device that came back at another position on the bus.
//!
//! Device ids are positions (`native:zwo:1` is an SDK enumeration index), so a
//! camera that re-enumerates after a hub drop can come back at another id
//! (rig, Nov 8 2026: `native:zwo:1` came back as `native:zwo:0`). The
//! reconnect at the old id is then refused, by the identity check or because
//! the SDK no longer lists it, or runs out of attempts. The device is looked
//! for in a fresh enumeration of its own driver, by serial or model, and
//! connected where it is. Two devices that both match are never guessed
//! between: the device stays lost and the operator is told.
//!
//! A run keeps the ids it started with. The manager records where each
//! followed device went ([`DeviceManager::current_id`]), and the run's device
//! calls go there. An id stops leading elsewhere once a device is connected
//! at it again, and the id it led to stops being followed once a device that
//! is not the one that moved is connected there.

use crate::device::DeviceInfo;
use crate::device_manager::identity::{same_model, DeviceIdentity};
use crate::device_manager::DeviceManager;
use crate::event::bus::EventPayload;
use crate::event::correlation::create_event_auto_id;
use crate::event::equipment::{EventCategory, EventSeverity};
use crate::event::system::SystemEvent;
use std::collections::{HashMap, HashSet};

/// A device that left an id and was connected at `to`, as it was identified
/// when it was found there.
#[derive(Debug, Clone)]
pub(crate) struct Moved {
    to: String,
    identity: DeviceIdentity,
}

/// [`Moved`] by the id the device left.
pub(crate) type MovedDevices = std::sync::Mutex<HashMap<String, Moved>>;

/// Whether a device identified as `seen` is the one that moved, identified
/// as `moved`: the same serial when both have one, else the same model. A
/// side that says nothing is no evidence of another device.
fn is_moved_device(seen: &DeviceIdentity, moved: &DeviceIdentity) -> bool {
    match (&seen.serial_number, &moved.serial_number) {
        (Some(seen), Some(moved)) => seen == moved,
        _ => match (&seen.model, &moved.model) {
            (Some(seen), Some(moved)) => same_model(seen, moved),
            _ => true,
        },
    }
}

/// Where a device that left its id is now.
#[derive(Debug)]
pub(crate) enum Found {
    Nowhere,
    At(DeviceInfo),
    /// More than one listed device matches: these ids.
    Ambiguous(Vec<String>),
    /// The one device that matches is at an id another device of this
    /// manager holds (two devices traded places): not connected there.
    Taken(String),
}

/// The listed device that is `wanted`, the device last seen at `old` (or
/// the model the caller expects there). A device of the same type and
/// driver at another id whose serial is `wanted`'s; when either side has no
/// serial, whose model is. One at an id in `registered` is [`Found::Taken`]:
/// that id belongs to another device, whose record must not be reused.
pub(crate) fn find_moved(
    old: &DeviceInfo,
    wanted: &DeviceIdentity,
    listed: &[DeviceInfo],
    registered: &HashSet<String>,
) -> Found {
    let matches: Vec<&DeviceInfo> = listed
        .iter()
        .filter(|d| {
            d.id != old.id && d.device_type == old.device_type && d.driver_type == old.driver_type
        })
        .filter(
            |d| match (wanted.serial_number.as_deref(), d.serial_number.as_deref()) {
                (Some(want), Some(has)) => want == has,
                _ => wanted.model.as_deref().is_some_and(|model| {
                    same_model(&d.name, model) || same_model(&d.display_name, model)
                }),
            },
        )
        .collect();
    match matches.as_slice() {
        [] => Found::Nowhere,
        [one] if registered.contains(&one.id) => Found::Taken(one.id.clone()),
        [one] => Found::At((*one).clone()),
        several => Found::Ambiguous(several.iter().map(|d| d.id.clone()).collect()),
    }
}

impl DeviceManager {
    /// Tell the operator something, as a system notification (the app's
    /// notice and the night log).
    pub(crate) fn notify(&self, level: &str, title: &str, message: &str) {
        let severity = match level {
            "warning" => EventSeverity::Warning,
            "error" => EventSeverity::Error,
            _ => EventSeverity::Info,
        };
        self.app_state.publish_event(create_event_auto_id(
            severity,
            EventCategory::System,
            EventPayload::System(SystemEvent::Notification {
                title: title.to_string(),
                message: message.to_string(),
                level: level.to_string(),
                explicit_transports: None,
            }),
        ));
    }

    /// After a reconnect at `old_id` was refused or used up its attempts:
    /// find the device that was there and connect it where it is now. The
    /// new id takes over the old one's auto-reconnect and what the device
    /// held; the old id is no longer retried. `Some(new id)` when it
    /// connected there.
    pub(crate) async fn follow_moved_device(&self, old_id: &str) -> Option<String> {
        let (old, auto_reconnect) = {
            let devices = self.devices.read().await;
            let dev = devices.get(old_id)?;
            (dev.info.clone(), dev.auto_reconnect)
        };
        let observed = self.observed_identities.read().await.get(old_id).cloned();
        let expected = self
            .expected_models
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .get(old_id)
            .cloned();
        // The model the caller expects at the id wins over the one last seen
        // there, which after a re-enumeration may be another device's.
        let wanted = DeviceIdentity {
            model: expected.or_else(|| observed.as_ref().and_then(|seen| seen.model.clone())),
            serial_number: observed.and_then(|seen| seen.serial_number),
            sensor: None,
        };
        if wanted.serial_number.is_none() && wanted.model.is_none() {
            tracing::info!("{old_id} was never identified; not looking for it at another id");
            return None;
        }

        crate::discovery::forget().await;
        let listed =
            match crate::discovery::scan_devices_for_pair(old.device_type, old.driver_type).await {
                Ok(listed) => listed,
                Err(e) => {
                    tracing::warn!("Could not list devices to look for {old_id}: {e}");
                    return None;
                }
            };
        let registered: HashSet<String> = self.devices.read().await.keys().cloned().collect();

        let what = wanted.describe();
        let noun = old.device_type.noun();
        let found = match find_moved(&old, &wanted, &listed, &registered) {
            Found::Taken(id) => {
                let message = format!(
                    "{what} left {old_id} and is listed at {id}, the id of another device \
                     Skotiq knows (the two may have traded places). Skotiq does not reuse \
                     that id; connect the {noun} by hand."
                );
                tracing::warn!("{message}");
                self.notify(
                    "warning",
                    &format!("The {noun} was not reconnected"),
                    &message,
                );
                return None;
            }
            Found::Nowhere => {
                tracing::info!("{what} is not listed at another id; {old_id} stays lost");
                return None;
            }
            Found::Ambiguous(ids) => {
                let message = format!(
                    "{what} left {old_id}, and {} devices match it ({}). Skotiq does not \
                     guess between them; connect the right one by hand.",
                    ids.len(),
                    ids.join(", ")
                );
                tracing::warn!("{message}");
                self.notify(
                    "warning",
                    &format!("The {noun} was not reconnected"),
                    &message,
                );
                return None;
            }
            Found::At(found) => found,
        };

        let new_id = found.id.clone();
        self.register_device(found, auto_reconnect).await;
        self.carry_held_state(old_id, &new_id).await;
        if let Err(e) = self
            .connect_device_expecting(&new_id, wanted.model.as_deref())
            .await
        {
            tracing::warn!("{what} is listed at {new_id}, but it did not connect there: {e}");
            return None;
        }
        self.set_auto_reconnect(&new_id, auto_reconnect).await;
        self.set_auto_reconnect(old_id, false).await;
        self.record_move(old_id, &new_id, wanted.clone());
        let message = format!("{what} came back at {new_id} (it was {old_id}); connected there.");
        tracing::info!("{message}");
        self.notify(
            "info",
            &format!("The {noun} was found at a new id"),
            &message,
        );
        Some(new_id)
    }

    /// Where the device last known at `device_id` is now: the id it was
    /// followed to, else `device_id` itself.
    pub(crate) fn current_id(&self, device_id: &str) -> String {
        self.moved
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .get(device_id)
            .map_or_else(|| device_id.to_string(), |moved| moved.to.clone())
    }

    /// The device that left `from`, identified as `identity`, is connected
    /// at `to`. An id that led to `from` leads to `to` now.
    fn record_move(&self, from: &str, to: &str, identity: DeviceIdentity) {
        let mut moved = self.moved.lock().unwrap_or_else(|p| p.into_inner());
        for earlier in moved.values_mut().filter(|earlier| earlier.to == from) {
            earlier.to = to.to_string();
        }
        moved.insert(
            from.to_string(),
            Moved {
                to: to.to_string(),
                identity,
            },
        );
    }

    /// A device identified as `seen` connected at `device_id`. The id is its
    /// own again, and an id that led here leads here only while this is the
    /// device that moved.
    pub(crate) fn forget_moves_at(&self, device_id: &str, seen: &DeviceIdentity) {
        let mut moved = self.moved.lock().unwrap_or_else(|p| p.into_inner());
        moved.remove(device_id);
        moved.retain(|from, earlier| {
            let kept = earlier.to != device_id || is_moved_device(seen, &earlier.identity);
            if !kept {
                tracing::info!(
                    "{device_id} now holds {}, not the device that left {from} for it; \
                     {from} is no longer followed there",
                    seen.describe()
                );
            }
            kept
        });
    }

    /// `device_id` is no longer known: it leads nowhere else, and nothing
    /// leads to it.
    pub(crate) fn forget_moves_of(&self, device_id: &str) {
        let mut moved = self.moved.lock().unwrap_or_else(|p| p.into_inner());
        moved.remove(device_id);
        moved.retain(|_, earlier| earlier.to != device_id);
    }

    /// What a connect restores, moved from `from` to `to`.
    async fn carry_held_state(&self, from: &str, to: &str) {
        let mut devices = self.devices.write().await;
        let Some(old) = devices.get(from).cloned() else {
            return;
        };
        if let Some(new) = devices.get_mut(to) {
            new.desired_cooler = new.desired_cooler.or(old.desired_cooler);
            new.held_camera_state = new.held_camera_state.or(old.held_camera_state);
            new.held_tracking = new.held_tracking.or(old.held_tracking);
        }
        drop(devices);
        self.carry_session(from, to);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::device::{DeviceType, DriverType};

    fn listed(id: &str, name: &str, serial: Option<&str>) -> DeviceInfo {
        DeviceInfo {
            id: id.to_string(),
            name: name.to_string(),
            device_type: DeviceType::Camera,
            driver_type: DriverType::Native,
            description: String::new(),
            driver_version: String::new(),
            serial_number: serial.map(str::to_string),
            unique_id: None,
            display_name: name.to_string(),
        }
    }

    /// The found ids, for comparing.
    fn ids(found: Found) -> Option<Vec<String>> {
        match found {
            Found::Nowhere | Found::Taken(_) => None,
            Found::At(device) => Some(vec![device.id]),
            Found::Ambiguous(ids) => Some(ids),
        }
    }

    fn wanted(model: &str, serial: Option<&str>) -> DeviceIdentity {
        DeviceIdentity {
            model: Some(model.to_string()),
            serial_number: serial.map(str::to_string),
            sensor: None,
        }
    }

    #[test]
    fn the_serial_decides_between_two_bodies_of_one_model() {
        let old = listed("native:zwo:1", "ZWO ASI2600MM Pro", None);
        let bus = [
            listed("native:zwo:0", "ZWO ASI2600MM Pro", Some("AAA")),
            listed("native:zwo:2", "ZWO ASI2600MM Pro", Some("BBB")),
        ];
        let found = find_moved(
            &old,
            &wanted("ZWO ASI2600MM Pro", Some("BBB")),
            &bus,
            &HashSet::new(),
        );
        assert!(matches!(&found, Found::At(_)));
        assert_eq!(ids(found), Some(vec!["native:zwo:2".to_string()]));
    }

    #[test]
    fn two_matches_by_model_are_never_guessed_between() {
        let old = listed("native:zwo:1", "ZWO ASI2600MM Pro", None);
        let bus = [
            listed("native:zwo:0", "ZWO ASI2600MM Pro", None),
            listed("native:zwo:2", "ZWO ASI2600MM Pro", None),
        ];
        let found = find_moved(
            &old,
            &wanted("ZWO ASI2600MM Pro", None),
            &bus,
            &HashSet::new(),
        );
        assert!(matches!(&found, Found::Ambiguous(_)));
        assert_eq!(
            ids(found),
            Some(vec!["native:zwo:0".to_string(), "native:zwo:2".to_string()])
        );
    }

    #[test]
    fn the_old_id_and_another_model_are_not_candidates() {
        let old = listed("native:zwo:1", "ZWO ASI2600MM Pro", None);
        let bus = [
            listed("native:zwo:1", "ZWO ASI2600MM Pro", None),
            listed("native:zwo:0", "ZWO ASI120MM Mini", None),
        ];
        let found = find_moved(
            &old,
            &wanted("ZWO ASI2600MM Pro", None),
            &bus,
            &HashSet::new(),
        );
        assert!(ids(found).is_none());
    }

    /// Two cameras that traded places: the one that matches sits at the
    /// other's id, which is not reused.
    #[test]
    fn a_match_at_another_known_devices_id_is_taken() {
        let old = listed("native:zwo:1", "ZWO ASI2600MM Pro", None);
        let bus = [listed("native:zwo:0", "ZWO ASI2600MM Pro", None)];
        let registered: HashSet<String> = ["native:zwo:0".to_string()].into();
        let found = find_moved(&old, &wanted("ZWO ASI2600MM Pro", None), &bus, &registered);
        assert!(matches!(found, Found::Taken(id) if id == "native:zwo:0"));
    }

    #[test]
    fn a_serial_that_differs_is_another_unit() {
        let old = listed("native:zwo:1", "ZWO ASI2600MM Pro", None);
        let bus = [listed("native:zwo:0", "ZWO ASI2600MM Pro", Some("AAA"))];
        let found = find_moved(
            &old,
            &wanted("ZWO ASI2600MM Pro", Some("BBB")),
            &bus,
            &HashSet::new(),
        );
        assert!(ids(found).is_none());
    }
}
