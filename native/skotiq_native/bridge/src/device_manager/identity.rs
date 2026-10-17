//! Device identity read back from a live driver after connect.
//!
//! # Why this module exists
//!
//! Every transport Skotiq speaks addresses devices by **position**, not by
//! identity:
//!
//! * native vendor SDKs: `native:zwo:1` is the ASI SDK's enumeration index.
//!   `ASIGetCameraProperty(&info, i)` returns `info.CameraID == i`, so the
//!   "resolve the stable CameraID" loop in `ZwoCamera::load_camera_info` is
//!   re-deriving the index it was given.
//! * ASCOM: `ASCOM.ASICamera2.Camera` is a driver **slot**. Which body answers
//!   it depends on what is plugged in.
//!
//! Measured on the reference rig (two ZWO cameras, ASI SDK 1.40) the native
//! index re-ordered across a replug:
//!
//! | id | before | after |
//! |---|---|---|
//! | `native:zwo:0` | ZWO ASI178MM | ZWO ASI1600MM-Cool |
//! | `native:zwo:1` | ZWO ASI1600MM-Cool | ZWO ASI178MM |
//!
//! A run started on `native:zwo:1` believing it was the 1600 captured the whole
//! session on the 178MM. Nothing in the app noticed, because all three things
//! that could have revealed it were absent: the id did not change, the
//! displayed name was derived from the id rather than the driver, and the
//! capabilities were never re-read.
//!
//! # What this module does about it
//!
//! [`DeviceIdentity`] is what a driver says about itself once it is open. The
//! device manager records it on the first successful connect and compares it on
//! every subsequent connect for the same id. A contradiction means the id now
//! points at different hardware, which is refused rather than imaged.
//!
//! # Why identity is a fingerprint and not just a serial
//!
//! A serial would be ideal, and the ASI SDK does expose one — but not for every
//! body. On the reference rig `ASIGetSerialNumber` succeeds for the ASI178MM and
//! answers `ASI_ERROR_GENERAL_ERROR` for the ASI1600MM-Cool, which is the
//! owner's primary imaging camera. A serial-only scheme would therefore protect
//! the camera that matters least. So identity is layered: serial when the
//! hardware offers one, and otherwise the model name plus the sensor geometry,
//! which is what actually differs between two bodies a user is likely to
//! confuse (4656x3520 @ 3.80um vs 3096x2080 @ 2.40um for exactly the pair
//! above).

use crate::device::DeviceInfo;

/// Marker phrase carried by the connect error raised when a device id has
/// re-bound to different hardware.
///
/// `connect_device_internal` matches on it for one reason: releasing the wrong
/// device trips the same reconnect-cancel token a user disconnect trips, and
/// without this marker the identity error would be rewritten as
/// [`RECONNECT_CANCELED_MSG`](super::connection::RECONNECT_CANCELED_MSG) and
/// then suppressed by the reconnection loop. The string is part of that
/// contract; change it in one place only.
pub(crate) const IDENTITY_CONFLICT_MARKER: &str = "is no longer the same hardware";

/// What a driver reports about itself once it is connected.
///
/// Every field is optional because transports differ in what they will answer,
/// and an absent field is never treated as a mismatch — only two *present* and
/// *different* values are. That asymmetry is deliberate: a driver that starts
/// reporting a serial after an SDK upgrade must not read as a swapped camera.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct DeviceIdentity {
    /// Model as the driver states it, e.g. `ZWO ASI1600MM-Cool`.
    pub model: Option<String>,
    /// Hardware serial, when the unit has one.
    pub serial_number: Option<String>,
    /// Sensor geometry fingerprint, e.g. `4656x3520@3.80um`. See
    /// [`DeviceIdentity::sensor_fingerprint`].
    pub sensor: Option<String>,
}

impl DeviceIdentity {
    /// Build the sensor fingerprint used for the `sensor` field.
    ///
    /// Returns `None` for a zero-sized sensor: an unpopulated cache reads as
    /// `0x0@0.00um`, and comparing that against a real geometry would report a
    /// swap on every driver that is simply slow to fill its cache.
    pub fn sensor_fingerprint(width: u32, height: u32, pixel_size_um: f64) -> Option<String> {
        if width == 0 || height == 0 {
            return None;
        }
        Some(format!("{}x{}@{:.2}um", width, height, pixel_size_um))
    }

    /// True when the driver told us nothing we can identify it by.
    ///
    /// Callers skip the identity gate entirely in this case rather than
    /// recording an empty baseline that would match anything later.
    pub fn is_empty(&self) -> bool {
        self.model.is_none() && self.serial_number.is_none() && self.sensor.is_none()
    }

    /// Human-readable summary for log lines and operator-facing errors.
    pub fn describe(&self) -> String {
        let mut parts = Vec::new();
        if let Some(model) = &self.model {
            parts.push(model.clone());
        }
        if let Some(serial) = &self.serial_number {
            parts.push(format!("serial {}", serial));
        }
        if let Some(sensor) = &self.sensor {
            parts.push(sensor.clone());
        }
        if parts.is_empty() {
            "unidentified device".to_string()
        } else {
            parts.join(", ")
        }
    }

    /// Compare against the identity last observed for the same device id.
    ///
    /// `Some(reason)` means the id has re-bound to different hardware; the
    /// string names both sides so the operator can see which camera they
    /// actually got. `None` means "no evidence of a swap" — which includes the
    /// case where the two identities simply have no field in common.
    ///
    /// Precedence is strongest-evidence-first:
    ///
    /// 1. **Serials that match end the comparison as a match.** Same physical
    ///    unit; a model string that changed formatting across a driver update
    ///    is not a swap.
    /// 2. **Serials that differ are a swap**, whatever else agrees.
    /// 3. **Sensor geometry that differs is a swap.** This is the check that
    ///    catches the ASCOM driver-slot re-bind, where the ProgID and the
    ///    generic name are identical for both bodies.
    /// 4. **Model names that differ are a swap**, compared case-insensitively
    ///    and trimmed so whitespace or casing churn is not mistaken for one.
    pub fn conflict_with(&self, previous: &DeviceIdentity) -> Option<String> {
        if let (Some(now), Some(before)) = (&self.serial_number, &previous.serial_number) {
            if now == before {
                return None;
            }
            return Some(format!("serial number changed from {} to {}", before, now));
        }

        if let (Some(now), Some(before)) = (&self.sensor, &previous.sensor) {
            if now != before {
                return Some(format!("sensor changed from {} to {}", before, now));
            }
        }

        if let (Some(now), Some(before)) = (&self.model, &previous.model) {
            if !now.trim().eq_ignore_ascii_case(before.trim()) {
                return Some(format!("model changed from {} to {}", before, now));
            }
        }

        None
    }

    /// Overwrite the placeholder fields of a registered [`DeviceInfo`] with what
    /// the driver actually reported.
    ///
    /// `DeviceInfo` is first built by `api::connection::device_info_from_id`,
    /// which can only derive a name from the id string — that is where
    /// `native:zwo:1` becomes the name `ZWO 1` and
    /// `ascom:ASCOM.ASICamera2.Camera` becomes `ASICamera2 Camera`. Those are
    /// placeholders standing in until the device is open; this replaces them
    /// with the truth.
    ///
    /// Only non-empty observations are applied, so a transport that answers
    /// nothing leaves the placeholder intact rather than blanking the UI.
    pub fn apply_to(&self, info: &mut DeviceInfo) {
        if let Some(model) = self.model.as_ref().filter(|m| !m.trim().is_empty()) {
            info.name = model.clone();
            info.display_name = match &self.serial_number {
                Some(serial) => format!("{} ({})", model, serial),
                None => model.clone(),
            };
        }
        if let Some(serial) = self.serial_number.as_ref().filter(|s| !s.trim().is_empty()) {
            info.serial_number = Some(serial.clone());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::device::{DeviceType, DriverType};

    fn info_named(name: &str) -> DeviceInfo {
        DeviceInfo {
            id: "native:zwo:1".to_string(),
            name: name.to_string(),
            device_type: DeviceType::Camera,
            driver_type: DriverType::Native,
            description: "Native zwo driver".to_string(),
            driver_version: "Native".to_string(),
            serial_number: None,
            unique_id: None,
            display_name: name.to_string(),
        }
    }

    /// The reference-rig swap: `native:zwo:1` was the 1600, came back as the
    /// 178. Neither body reports a serial the other can be compared against
    /// (the 1600 reports none at all), so geometry has to carry the check.
    #[test]
    fn detects_the_live_rig_camera_swap_by_geometry() {
        let before = DeviceIdentity {
            model: Some("ZWO ASI1600MM-Cool".to_string()),
            serial_number: None,
            sensor: DeviceIdentity::sensor_fingerprint(4656, 3520, 3.8),
        };
        let after = DeviceIdentity {
            model: Some("ZWO ASI178MM".to_string()),
            serial_number: Some("3520810329000900".to_string()),
            sensor: DeviceIdentity::sensor_fingerprint(3096, 2080, 2.4),
        };

        let conflict = after.conflict_with(&before).expect("swap must be detected");
        assert!(
            conflict.contains("4656x3520@3.80um") && conflict.contains("3096x2080@2.40um"),
            "conflict must name both sensors, got: {conflict}"
        );
    }

    /// The ASCOM driver-slot re-bind. This is the exact shape the ASCOM probe
    /// produces — geometry only, no model and no serial — because the wrapper's
    /// `name()` is the ProgID rather than anything the driver said, and an
    /// unconnected `ASCOM.ASICamera2.Camera` answers the generic
    /// `"ASI Camera (1)"` for both bodies anyway. Geometry has to carry it.
    #[test]
    fn detects_ascom_slot_rebind_from_geometry_alone() {
        let before = DeviceIdentity {
            model: None,
            serial_number: None,
            sensor: DeviceIdentity::sensor_fingerprint(4656, 3520, 3.8),
        };
        let after = DeviceIdentity {
            model: None,
            serial_number: None,
            sensor: DeviceIdentity::sensor_fingerprint(3096, 2080, 2.4),
        };

        let conflict = after
            .conflict_with(&before)
            .expect("an ASCOM slot re-bind must be detected from geometry alone");
        assert!(conflict.contains("sensor changed"), "{conflict}");
    }

    #[test]
    fn matching_serial_outranks_a_reworded_model() {
        let before = DeviceIdentity {
            model: Some("ZWO ASI178MM".to_string()),
            serial_number: Some("3520810329000900".to_string()),
            sensor: DeviceIdentity::sensor_fingerprint(3096, 2080, 2.4),
        };
        let after = DeviceIdentity {
            model: Some("ASI178MM".to_string()),
            serial_number: Some("3520810329000900".to_string()),
            sensor: DeviceIdentity::sensor_fingerprint(3096, 2080, 2.4),
        };

        assert_eq!(after.conflict_with(&before), None);
    }

    #[test]
    fn differing_serial_is_a_swap_even_when_the_model_matches() {
        let before = DeviceIdentity {
            model: Some("ZWO ASI178MM".to_string()),
            serial_number: Some("aaaa".to_string()),
            sensor: DeviceIdentity::sensor_fingerprint(3096, 2080, 2.4),
        };
        let after = DeviceIdentity {
            serial_number: Some("bbbb".to_string()),
            ..before.clone()
        };

        assert!(after
            .conflict_with(&before)
            .expect("differing serials are a swap")
            .contains("serial number changed"));
    }

    /// A driver that gains a serial across an SDK upgrade is the same camera.
    #[test]
    fn newly_reported_serial_is_not_a_swap() {
        let before = DeviceIdentity {
            model: Some("ZWO ASI178MM".to_string()),
            serial_number: None,
            sensor: DeviceIdentity::sensor_fingerprint(3096, 2080, 2.4),
        };
        let after = DeviceIdentity {
            serial_number: Some("3520810329000900".to_string()),
            ..before.clone()
        };

        assert_eq!(after.conflict_with(&before), None);
    }

    #[test]
    fn model_casing_and_padding_are_not_a_swap() {
        let before = DeviceIdentity {
            model: Some("ZWO ASI178MM".to_string()),
            ..Default::default()
        };
        let after = DeviceIdentity {
            model: Some("  zwo asi178mm ".to_string()),
            ..Default::default()
        };

        assert_eq!(after.conflict_with(&before), None);
    }

    /// An unpopulated sensor cache must not read as a swap.
    #[test]
    fn zero_sized_sensor_yields_no_fingerprint() {
        assert_eq!(DeviceIdentity::sensor_fingerprint(0, 0, 0.0), None);
        assert_eq!(DeviceIdentity::sensor_fingerprint(3096, 0, 2.4), None);
    }

    #[test]
    fn empty_identity_is_reported_empty() {
        assert!(DeviceIdentity::default().is_empty());
        assert!(!DeviceIdentity {
            model: Some("ZWO ASI178MM".to_string()),
            ..Default::default()
        }
        .is_empty());
    }

    /// The placeholder name derived from the id is replaced by the driver's.
    #[test]
    fn apply_to_replaces_the_id_derived_placeholder_name() {
        let mut info = info_named("ZWO 1");
        DeviceIdentity {
            model: Some("ZWO ASI178MM".to_string()),
            serial_number: Some("3520810329000900".to_string()),
            sensor: DeviceIdentity::sensor_fingerprint(3096, 2080, 2.4),
        }
        .apply_to(&mut info);

        assert_eq!(info.name, "ZWO ASI178MM");
        assert_eq!(info.display_name, "ZWO ASI178MM (3520810329000900)");
        assert_eq!(info.serial_number.as_deref(), Some("3520810329000900"));
    }

    #[test]
    fn apply_to_leaves_the_placeholder_when_the_driver_says_nothing() {
        let mut info = info_named("ZWO 1");
        DeviceIdentity::default().apply_to(&mut info);

        assert_eq!(info.name, "ZWO 1");
        assert_eq!(info.display_name, "ZWO 1");
    }
}
