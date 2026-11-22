//! The last position Skotiq recorded for each focuser, filter wheel and
//! rotator, kept across app starts in `<data root>/device_positions.json`
//! (a file of its own: no database schema change). A connect compares what
//! the device reports with it.
//!
//! A position is recorded from every end-of-move event (a command's, and an
//! outside move the backstop poll caught) and from the read at each
//! connect. A device is keyed by its model and serial when the driver names
//! both, so a device that comes back at another id keeps its record, and by
//! its id otherwise.

use crate::device::DeviceType;
use crate::device_manager::identity::DeviceIdentity;
use crate::device_manager::ops::backstop::Reading;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;
use std::sync::Mutex;

const FILE_NAME: &str = "device_positions.json";

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "value", rename_all = "lowercase")]
enum Recorded {
    Focuser(i32),
    Filter(i32),
    Rotator(f64),
}

impl From<Reading> for Recorded {
    fn from(reading: Reading) -> Self {
        match reading {
            Reading::Focuser(steps) => Self::Focuser(steps),
            Reading::Filter(slot) => Self::Filter(slot),
            Reading::Rotator(angle) => Self::Rotator(angle),
        }
    }
}

impl From<Recorded> for Reading {
    fn from(recorded: Recorded) -> Self {
        match recorded {
            Recorded::Focuser(steps) => Self::Focuser(steps),
            Recorded::Filter(slot) => Self::Filter(slot),
            Recorded::Rotator(angle) => Self::Rotator(angle),
        }
    }
}

/// Where the record is kept.
#[derive(Debug)]
enum Keep {
    /// In memory only (tests, and a host that named no data root).
    InMemory,
    /// Under the data root, once the host has named it.
    UnderDataRoot,
    /// In this file.
    #[cfg(test)]
    At(PathBuf),
}

#[derive(Debug)]
struct Inner {
    keep: Keep,
    /// The file, once known, and whether it was read.
    file: Option<PathBuf>,
    loaded: bool,
    by_key: BTreeMap<String, Recorded>,
    key_of: HashMap<String, String>,
}

/// The recorded positions; see the module doc.
#[derive(Debug)]
pub(crate) struct Positions(Mutex<Inner>);

impl Default for Positions {
    fn default() -> Self {
        Self::keeping(Keep::InMemory)
    }
}

/// The key a device's record is kept under.
pub(crate) fn key(
    device_type: DeviceType,
    device_id: &str,
    identity: Option<&DeviceIdentity>,
) -> String {
    match identity {
        Some(DeviceIdentity {
            model: Some(model),
            serial_number: Some(serial),
            ..
        }) => format!("{}|{model}|{serial}", device_type.wire_name()),
        _ => format!("{}|{device_id}", device_type.wire_name()),
    }
}

impl Positions {
    fn keeping(keep: Keep) -> Self {
        Self(Mutex::new(Inner {
            keep,
            file: None,
            loaded: false,
            by_key: BTreeMap::new(),
            key_of: HashMap::new(),
        }))
    }

    /// From now on, kept under the host's data root (the manager the app
    /// runs; a test's manager keeps its record in memory).
    pub(crate) fn keep_under_data_root(&self) {
        let mut inner = self.0.lock().unwrap_or_else(|p| p.into_inner());
        inner.keep = Keep::UnderDataRoot;
        inner.loaded = false;
    }

    #[cfg(test)]
    pub(crate) fn at(file: PathBuf) -> Self {
        Self::keeping(Keep::At(file))
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        let mut inner = self.0.lock().unwrap_or_else(|p| p.into_inner());
        inner.load();
        inner
    }

    /// Key `device_id`'s record as [`key`] says, from now on.
    pub(crate) fn bind(&self, device_id: &str, key: String) {
        self.lock().key_of.insert(device_id.to_string(), key);
    }

    /// The position last recorded for `device_id`.
    pub(crate) fn last(&self, device_id: &str) -> Option<Reading> {
        let inner = self.lock();
        let key = inner.key_for(device_id)?;
        inner.by_key.get(&key).copied().map(Reading::from)
    }

    /// Record where `device_id` is now. Written to the file only when it
    /// changed.
    pub(crate) fn record(&self, device_id: &str, reading: Reading) {
        let mut inner = self.lock();
        let Some(key) = inner.key_for(device_id) else {
            return;
        };
        let recorded = Recorded::from(reading);
        if inner.by_key.get(&key) == Some(&recorded) {
            return;
        }
        inner.by_key.insert(key, recorded);
        inner.save();
    }
}

impl Inner {
    /// `None` until a connect bound the device's key: nothing is recorded
    /// for a device Skotiq has not connected.
    fn key_for(&self, device_id: &str) -> Option<String> {
        self.key_of.get(device_id).cloned()
    }

    fn load(&mut self) {
        if self.loaded {
            return;
        }
        self.file = match &self.keep {
            Keep::InMemory => None,
            Keep::UnderDataRoot => crate::data_root::root()
                .ok()
                .map(|root| root.join(FILE_NAME)),
            #[cfg(test)]
            Keep::At(file) => Some(file.clone()),
        };
        let Some(file) = &self.file else {
            // No data root yet: try again on the next use.
            return;
        };
        self.loaded = true;
        match std::fs::read_to_string(file) {
            Ok(raw) => match serde_json::from_str(&raw) {
                Ok(by_key) => self.by_key = by_key,
                Err(e) => tracing::warn!(
                    "{} is not a position record ({e}); starting a new one",
                    file.display()
                ),
            },
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => tracing::warn!("Could not read {}: {e}", file.display()),
        }
    }

    fn save(&self) {
        let Some(file) = &self.file else {
            return;
        };
        let written = serde_json::to_string_pretty(&self.by_key)
            .map_err(|e| e.to_string())
            .and_then(|json| {
                if let Some(dir) = file.parent() {
                    std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
                }
                std::fs::write(file, json).map_err(|e| e.to_string())
            });
        if let Err(e) = written {
            tracing::warn!("Could not write {}: {e}", file.display());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch() -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "skotiq-positions-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        dir.join(FILE_NAME)
    }

    #[test]
    fn a_recorded_position_is_there_after_a_restart() {
        let file = scratch();
        let identity = DeviceIdentity {
            model: Some("ZWO EAF".into()),
            serial_number: Some("1234".into()),
            sensor: None,
        };
        let key = key(DeviceType::Focuser, "native:zwo:eaf:0", Some(&identity));
        let first = Positions::at(file.clone());
        first.bind("native:zwo:eaf:0", key.clone());
        first.record("native:zwo:eaf:0", Reading::Focuser(15000));

        // The next start, with the focuser at another id.
        let next = Positions::at(file);
        next.bind("native:zwo:eaf:1", key);
        assert_eq!(next.last("native:zwo:eaf:1"), Some(Reading::Focuser(15000)));
    }

    #[test]
    fn nothing_is_recorded_for_a_device_with_no_key() {
        let positions = Positions::default();
        positions.record("wheel", Reading::Filter(2));
        assert_eq!(positions.last("wheel"), None);
    }
}
