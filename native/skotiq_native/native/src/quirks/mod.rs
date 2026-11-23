//! Known device quirks and the workarounds drivers apply for them.
//!
//! A quirk is a fact about a model or a vendor's devices that its SDK does
//! not report: a first reading to throw away, a settle after connect, a
//! travel per step. The table is in [`database`]; a driver asks it with its
//! own vendor, kind and model name and applies what comes back.

mod database;
mod types;

pub use database::quirks_for;
pub use types::*;

use crate::catalog;
use skotiq_device::{DeviceKind, Vendor};

/// The quirks of the device a native id names, for showing them to the user.
/// The model is read from the id's address, so an id that carries only a
/// position in the scan (`native:zwo:0`) gets the rows that apply to every
/// model of its family.
pub fn get_quirks_for_device(device_id: &str) -> Vec<Quirk> {
    match catalog::family_of_id(device_id) {
        Some((family, address)) => quirks_for(&(family.vendor)(), family.kind, address),
        None => Vec::new(),
    }
}

/// [`get_quirks_for_device`], plus the rows for the `model` the driver
/// reported, looked up in the family and kind the id names: an id carries a
/// scan position, not the model name model rows are keyed on.
pub fn get_quirks_for_device_model(device_id: &str, model: Option<&str>) -> Vec<Quirk> {
    let Some((family, address)) = catalog::family_of_id(device_id) else {
        return Vec::new();
    };
    let vendor = (family.vendor)();
    let mut quirks = quirks_for(&vendor, family.kind, address);
    for quirk in model.map_or_else(Vec::new, |model| quirks_for(&vendor, family.kind, model)) {
        if !quirks.contains(&quirk) {
            quirks.push(quirk);
        }
    }
    quirks
}

/// Vendor-wide quirks, applying to every device from that vendor.
pub fn get_quirks_for_vendor(vendor: &Vendor) -> Vec<Quirk> {
    database::get_vendor_quirks(vendor)
}

/// The settle a device needs before a temperature read can be trusted.
pub fn get_temperature_delay_ms(vendor: &Vendor, kind: DeviceKind, model: &str) -> Option<u64> {
    quirks_for(vendor, kind, model)
        .into_iter()
        .find_map(|quirk| match quirk {
            Quirk::Temperature(TemperatureQuirk::RequiresDelayMs(ms)) => Some(ms),
            _ => None,
        })
}

/// Whether the first temperature read after connect must be discarded.
pub fn should_skip_first_temperature_read(vendor: &Vendor, kind: DeviceKind, model: &str) -> bool {
    quirks_for(vendor, kind, model)
        .iter()
        .any(|q| matches!(q, Quirk::Temperature(TemperatureQuirk::SkipFirstRead)))
}

/// The cooler set-point range declared for a camera, in degrees Celsius.
pub fn get_cooler_range(vendor: &Vendor, model: &str) -> Option<(f64, f64)> {
    quirks_for(vendor, DeviceKind::Camera, model)
        .into_iter()
        .find_map(|quirk| match quirk {
            Quirk::Camera(CameraQuirk::CoolerRange { min_temp, max_temp }) => {
                Some((min_temp, max_temp))
            }
            _ => None,
        })
}

/// Microns of travel per motor step, for a focuser whose SDK does not say.
/// `None`: the SDK is expected to supply it, or the caller reports that the
/// step size is unknown.
pub fn get_focuser_step_size_um(vendor: &Vendor, model: &str) -> Option<f64> {
    quirks_for(vendor, DeviceKind::Focuser, model)
        .into_iter()
        .find_map(|quirk| match quirk {
            Quirk::Position(PositionQuirk::FocuserStepSizeMicrons(um)) => Some(um),
            _ => None,
        })
}

/// How long after a move a device may still report its previous position.
pub fn get_position_delay_after_move_ms(
    vendor: &Vendor,
    kind: DeviceKind,
    model: &str,
) -> Option<u64> {
    quirks_for(vendor, kind, model)
        .into_iter()
        .find_map(|quirk| match quirk {
            Quirk::Position(PositionQuirk::DelayAfterMoveMs(ms)) => Some(ms),
            _ => None,
        })
}

/// The settle a device needs after connecting, in milliseconds.
pub fn get_connect_delay_ms(vendor: &Vendor, kind: DeviceKind, model: &str) -> Option<u64> {
    quirks_for(vendor, kind, model)
        .into_iter()
        .find_map(|quirk| match quirk {
            Quirk::Timing(TimingQuirk::DelayAfterConnect(delay_ms)) => Some(delay_ms),
            _ => None,
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A discovered EAF is `native:zwo:eaf:0`. Its step-size row is keyed on the model name.
    #[test]
    fn a_reported_model_is_looked_up_in_the_family_the_id_names() {
        let step = Quirk::Position(PositionQuirk::FocuserStepSizeMicrons(0.7));
        let quirks = get_quirks_for_device_model("native:zwo:eaf:0", Some("ZWO EAF-S"));
        assert!(quirks.contains(&step), "{quirks:?}");
        assert!(!get_quirks_for_device("native:zwo:ZWO EAF-S").contains(&step));
        assert_eq!(
            get_quirks_for_device_model("native:zwo:0", None),
            get_quirks_for_device("native:zwo:0")
        );
        assert!(get_quirks_for_device_model("sim_camera_1", Some("ZWO EAF-S")).is_empty());
    }

    #[test]
    fn a_quirk_the_id_and_the_model_share_is_listed_once() {
        let quirks = get_quirks_for_device_model("native:zwo:efw:0", Some("ZWO EFW"));
        let wheel = Quirk::Position(PositionQuirk::DelayAfterMoveMs(500));
        assert_eq!(
            quirks.iter().filter(|q| **q == wheel).count(),
            1,
            "{quirks:?}"
        );
    }

    #[test]
    fn a_reader_gets_the_value_of_its_own_sort_of_quirk() {
        assert_eq!(
            get_temperature_delay_ms(&Vendor::PlayerOne, DeviceKind::Camera, "Poseidon-M"),
            Some(50)
        );
        assert!(should_skip_first_temperature_read(
            &Vendor::Zwo,
            DeviceKind::Camera,
            "ZWO ASI294MC Pro"
        ));
        assert_eq!(
            get_cooler_range(&Vendor::Qhy, "QHY268M-123"),
            Some((-35.0, 25.0))
        );
        assert_eq!(
            get_position_delay_after_move_ms(&Vendor::Zwo, DeviceKind::FilterWheel, "EFW"),
            Some(500)
        );
        assert_eq!(
            get_connect_delay_ms(&Vendor::Zwo, DeviceKind::Camera, "ZWO ASI533MC Pro"),
            Some(200)
        );
        assert_eq!(
            get_connect_delay_ms(&Vendor::Zwo, DeviceKind::Camera, "ZWO ASI294MC Pro"),
            None,
            "no row, no settle"
        );
    }

    /// Discovery writes an accessory's id with the family token
    /// (`native:zwo_efw:0`).
    #[test]
    fn an_id_as_discovery_writes_it_finds_its_familys_quirks() {
        let delay = |id: &str| {
            get_quirks_for_device(id).into_iter().find_map(|q| match q {
                Quirk::Position(PositionQuirk::DelayAfterMoveMs(ms)) => Some(ms),
                _ => None,
            })
        };
        assert_eq!(delay("native:zwo_efw:0"), Some(500));
        assert_eq!(delay("native:zwo:efw:0"), Some(500));
        assert_eq!(delay("native:zwo:0"), None, "a camera is not a wheel");
        assert!(!get_quirks_for_device("native:zwo:ZWO ASI294MC Pro").is_empty());
        assert!(get_quirks_for_device("alpaca:10.0.0.5:camera:0").is_empty());
        assert!(get_quirks_for_device("not an id").is_empty());
    }
}
