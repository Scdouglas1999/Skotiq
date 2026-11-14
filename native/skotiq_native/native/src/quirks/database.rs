//! The built-in table of device quirks.
//!
//! A row names who it applies to: a vendor, optionally one kind of device,
//! optionally a word its model name contains. A driver asks with its own
//! vendor, kind and the model name its SDK reports; nothing here reads a
//! device id.
//!
//! To add a quirk, add a row with the source of the value (firmware version,
//! SDK bug, published spec) and a reader in the driver.

use super::types::*;
use skotiq_device::{DeviceKind, Vendor};

struct Row {
    vendor: Vendor,
    /// `None`: every kind of device the vendor makes.
    kind: Option<DeviceKind>,
    /// A word the model name contains, in any case. `None`: every model.
    model: Option<&'static str>,
    quirks: &'static [Quirk],
}

impl Row {
    fn applies_to(&self, vendor: &Vendor, kind: DeviceKind, model: &str) -> bool {
        self.vendor == *vendor
            && self.kind.is_none_or(|k| k == kind)
            && self
                .model
                .is_none_or(|word| model.to_lowercase().contains(&word.to_lowercase()))
    }

    fn is_vendor_wide(&self) -> bool {
        self.kind.is_none() && self.model.is_none()
    }
}

/// Rows are read in order and a reader takes the first quirk of the sort it
/// wants, so a narrower model word stands before a wider one (EAF-S before
/// EAF).
const ROWS: &[Row] = &[
    // User reports: the first temperature read after connect is wrong.
    Row {
        vendor: Vendor::Zwo,
        kind: Some(DeviceKind::Camera),
        model: Some("ASI294"),
        quirks: &[Quirk::Temperature(TemperatureQuirk::SkipFirstRead)],
    },
    // User reports of connection timing problems.
    Row {
        vendor: Vendor::Zwo,
        kind: Some(DeviceKind::Camera),
        model: Some("ASI533"),
        quirks: &[Quirk::Timing(TimingQuirk::DelayAfterConnect(200))],
    },
    // An EFW may report the previous slot right after a move (user reports
    // and forum discussions).
    Row {
        vendor: Vendor::Zwo,
        kind: Some(DeviceKind::FilterWheel),
        model: None,
        quirks: &[Quirk::Position(PositionQuirk::DelayAfterMoveMs(500))],
    },
    // The EAF SDK does not report travel per step; the values are ZWO's
    // published gear ratios. EAF-S: compact, 7:1 reduction.
    Row {
        vendor: Vendor::Zwo,
        kind: Some(DeviceKind::Focuser),
        model: Some("EAF-S"),
        quirks: &[Quirk::Position(PositionQuirk::FocuserStepSizeMicrons(0.7))],
    },
    // EAF-2: second generation, finer reduction stage.
    Row {
        vendor: Vendor::Zwo,
        kind: Some(DeviceKind::Focuser),
        model: Some("EAF-2"),
        quirks: &[Quirk::Position(PositionQuirk::FocuserStepSizeMicrons(1.5))],
    },
    Row {
        vendor: Vendor::Zwo,
        kind: Some(DeviceKind::Focuser),
        model: Some("EAF"),
        quirks: &[Quirk::Position(PositionQuirk::FocuserStepSizeMicrons(8.0))],
    },
    // The QHY scan can hang; `vendor::qhy` gives it up after this long.
    Row {
        vendor: Vendor::Qhy,
        kind: None,
        model: None,
        quirks: &[Quirk::Discovery(DiscoveryQuirk::DiscoveryTimeoutMs(10000))],
    },
    // User reports.
    Row {
        vendor: Vendor::Qhy,
        kind: Some(DeviceKind::Camera),
        model: Some("QHY268"),
        quirks: &[
            Quirk::Camera(CameraQuirk::CoolerRange {
                min_temp: -35.0,
                max_temp: 25.0,
            }),
            Quirk::Temperature(TemperatureQuirk::RequiresDelayMs(100)),
        ],
    },
    Row {
        vendor: Vendor::PlayerOne,
        kind: None,
        model: None,
        quirks: &[Quirk::Temperature(TemperatureQuirk::RequiresDelayMs(50))],
    },
    // The first control read after the camera is configured can return stale
    // values without a short settle (empirical reports; the SDK documents no
    // grace period).
    Row {
        vendor: Vendor::Svbony,
        kind: None,
        model: None,
        quirks: &[Quirk::Timing(TimingQuirk::DelayAfterConnect(100))],
    },
    // Atik One series.
    Row {
        vendor: Vendor::Atik,
        kind: Some(DeviceKind::Camera),
        model: Some("One"),
        quirks: &[Quirk::Camera(CameraQuirk::CoolerRange {
            min_temp: -40.0,
            max_temp: 20.0,
        })],
    },
    // OGMA cameras (AP26CC, AP55CC) enumerate before their FX3 USB bridge
    // has settled, and a stream started at once shows a band of row noise on
    // about one start in five. 150 ms is the long end of the settle OGMA's
    // community timing notes suggest. The other brands of the Touptek SDK
    // family start cleanly, so the row names the brand: the driver asks with
    // the brand in front of the model name.
    Row {
        vendor: Vendor::Touptek,
        kind: Some(DeviceKind::Camera),
        model: Some("ogma"),
        quirks: &[Quirk::Timing(TimingQuirk::DelayAfterConnect(150))],
    },
];

/// Every quirk of the device a driver describes with its vendor, its kind
/// and the model name its SDK reports.
pub fn quirks_for(vendor: &Vendor, kind: DeviceKind, model: &str) -> Vec<Quirk> {
    ROWS.iter()
        .filter(|row| row.applies_to(vendor, kind, model))
        .flat_map(|row| row.quirks.iter().cloned())
        .collect()
}

/// The quirks every device of `vendor` has, whatever its kind and model.
pub fn get_vendor_quirks(vendor: &Vendor) -> Vec<Quirk> {
    ROWS.iter()
        .filter(|row| row.vendor == *vendor && row.is_vendor_wide())
        .flat_map(|row| row.quirks.iter().cloned())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn connect_delay(quirks: &[Quirk]) -> Option<u64> {
        quirks.iter().find_map(|q| match q {
            Quirk::Timing(TimingQuirk::DelayAfterConnect(ms)) => Some(*ms),
            _ => None,
        })
    }

    #[test]
    fn a_model_word_matches_in_any_case() {
        let upper = quirks_for(&Vendor::Zwo, DeviceKind::Camera, "ZWO ASI294MC Pro");
        let lower = quirks_for(&Vendor::Zwo, DeviceKind::Camera, "zwo asi294mc pro");
        assert_eq!(
            upper,
            vec![Quirk::Temperature(TemperatureQuirk::SkipFirstRead)]
        );
        assert_eq!(upper, lower);
    }

    #[test]
    fn a_row_for_one_kind_leaves_the_vendors_other_devices_alone() {
        let wheel = quirks_for(&Vendor::Zwo, DeviceKind::FilterWheel, "EFW");
        assert_eq!(
            wheel,
            vec![Quirk::Position(PositionQuirk::DelayAfterMoveMs(500))]
        );
        assert!(quirks_for(&Vendor::Zwo, DeviceKind::Camera, "ZWO ASI178MM").is_empty());
        assert!(quirks_for(&Vendor::Zwo, DeviceKind::Mount, "AM5").is_empty());
    }

    #[test]
    fn the_narrower_focuser_model_comes_first() {
        let step = |model| {
            quirks_for(&Vendor::Zwo, DeviceKind::Focuser, model)
                .into_iter()
                .find_map(|q| match q {
                    Quirk::Position(PositionQuirk::FocuserStepSizeMicrons(um)) => Some(um),
                    _ => None,
                })
        };
        assert_eq!(step("EAF-S"), Some(0.7));
        assert_eq!(step("EAF-2"), Some(1.5));
        assert_eq!(step("EAF"), Some(8.0));
    }

    #[test]
    fn a_vendor_wide_row_reaches_every_kind_and_model() {
        assert_eq!(
            connect_delay(&quirks_for(&Vendor::Svbony, DeviceKind::Camera, "SV605CC")),
            Some(100)
        );
        assert!(get_vendor_quirks(&Vendor::Qhy)
            .iter()
            .any(|q| matches!(q, Quirk::Discovery(_))));
        assert!(
            get_vendor_quirks(&Vendor::Zwo).is_empty(),
            "a row for one kind or model is not vendor wide"
        );
    }

    #[test]
    fn the_ogma_settle_is_for_that_brand_of_the_touptek_family_only() {
        let delay = |model| connect_delay(&quirks_for(&Vendor::Touptek, DeviceKind::Camera, model));
        assert_eq!(delay("ogma AP26CC"), Some(150));
        assert_eq!(delay("OGMA AP55CC"), Some(150));
        assert_eq!(delay("altair Hypercam 26C"), None);
        assert_eq!(delay("touptek ATR3CMOS26000KPA"), None);
    }

    #[test]
    fn a_vendor_without_rows_has_no_quirks() {
        assert!(quirks_for(&Vendor::Ascom, DeviceKind::Camera, "Simulator").is_empty());
        assert!(quirks_for(&Vendor::Meade, DeviceKind::Mount, "OnStep").is_empty());
    }
}
