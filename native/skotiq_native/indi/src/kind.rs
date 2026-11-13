//! What kind of device an INDI device is.
//!
//! A driver built on libindi says which interfaces it implements in
//! `DRIVER_INFO.DRIVER_INTERFACE`, and says it before the device is connected.
//! The properties that show a kind (`CCD_EXPOSURE`, `EQUATORIAL_EOD_COORD`, ...)
//! are only defined once the device is connected, which is usually after
//! Skotiq discovers it. So the interface decides when the driver publishes it;
//! the properties, then the device name, decide for drivers that do not.
//!
//! A driver can implement several interfaces (a camera with a built-in filter
//! wheel, a mount with a focuser port, a power box with a focuser port and a
//! sensor). Skotiq lists a device under one kind, the first that applies in
//! the order below.

use crate::protocol::names::*;
use crate::{IndiProperty, IndiPropertyType};
use skotiq_device::DeviceKind;

/// libindi's `DRIVER_INTERFACE` bits (`basedevice.h`).
mod interface {
    pub const TELESCOPE: u32 = 1 << 0;
    pub const CCD: u32 = 1 << 1;
    pub const GUIDER: u32 = 1 << 2;
    pub const FOCUSER: u32 = 1 << 3;
    pub const FILTER: u32 = 1 << 4;
    pub const DOME: u32 = 1 << 5;
    pub const WEATHER: u32 = 1 << 7;
    pub const DUSTCAP: u32 = 1 << 9;
    pub const LIGHTBOX: u32 = 1 << 10;
    pub const ROTATOR: u32 = 1 << 12;
    pub const AUX: u32 = 1 << 15;
    pub const OUTPUT: u32 = 1 << 16;
    pub const POWER: u32 = 1 << 18;
}

/// Interfaces to kinds, first match wins. A power box's switched outputs are
/// what it is for; its focuser port and sensors come after them. A plain
/// auxiliary device has only its switches for Skotiq to offer.
const BY_INTERFACE: [(u32, DeviceKind); 11] = [
    (interface::CCD, DeviceKind::Camera),
    (interface::TELESCOPE, DeviceKind::Mount),
    (interface::POWER | interface::OUTPUT, DeviceKind::Switch),
    (interface::FOCUSER, DeviceKind::Focuser),
    (interface::FILTER, DeviceKind::FilterWheel),
    (interface::DOME, DeviceKind::Dome),
    (interface::ROTATOR, DeviceKind::Rotator),
    (
        interface::DUSTCAP | interface::LIGHTBOX,
        DeviceKind::CoverCalibrator,
    ),
    (interface::WEATHER, DeviceKind::Weather),
    (interface::GUIDER, DeviceKind::Guider),
    (interface::AUX, DeviceKind::Switch),
];

/// Properties to kinds for a driver that does not publish its interfaces,
/// first match wins.
const BY_PROPERTY: [(&[&str], DeviceKind); 10] = [
    (
        &[CCD_EXPOSURE, CCD_INFO, CCD_FRAME, CCD1],
        DeviceKind::Camera,
    ),
    (
        &[
            EQUATORIAL_EOD_COORD,
            ON_COORD_SET,
            TELESCOPE_TRACK_MODE,
            TELESCOPE_MOTION_NS,
            TELESCOPE_MOTION_WE,
        ],
        DeviceKind::Mount,
    ),
    (
        &[ABS_FOCUS_POSITION, REL_FOCUS_POSITION, FOCUS_MOTION],
        DeviceKind::Focuser,
    ),
    (&[FILTER_SLOT, FILTER_NAME], DeviceKind::FilterWheel),
    (
        &[DOME_SHUTTER, DOME_MOTION, ABS_DOME_POSITION],
        DeviceKind::Dome,
    ),
    (&[ABS_ROTATOR_ANGLE, ROTATOR_ANGLE], DeviceKind::Rotator),
    (
        &[TELESCOPE_TIMED_GUIDE_NS, TELESCOPE_TIMED_GUIDE_WE],
        DeviceKind::Guider,
    ),
    (&[SAFETY_STATUS, AUX_SAFETY], DeviceKind::SafetyMonitor),
    (&[WEATHER_STATUS, WEATHER_PARAMETERS], DeviceKind::Weather),
    (
        &[
            CAP_PARK,
            FLAT_LIGHT_CONTROL,
            FLAT_LIGHT_INTENSITY,
            DUSTCAP_CONTROL,
            LIGHTBOX_BRIGHTNESS,
        ],
        DeviceKind::CoverCalibrator,
    ),
];

/// Words in a device name to kinds, first match wins. Filter wheels are often
/// named without "wheel": INDI's simulator is "Filter Simulator", ZWO's are
/// "... EFW".
const BY_NAME: [(&[&str], DeviceKind); 8] = [
    (&["TELESCOPE", "MOUNT"], DeviceKind::Mount),
    (&["CCD", "CAMERA"], DeviceKind::Camera),
    (&["FOCUSER"], DeviceKind::Focuser),
    (&["WHEEL", "FILTER", "EFW"], DeviceKind::FilterWheel),
    (&["ROTATOR"], DeviceKind::Rotator),
    (&["DOME"], DeviceKind::Dome),
    (&["WEATHER"], DeviceKind::Weather),
    (&["SAFETY"], DeviceKind::SafetyMonitor),
];

/// What an INDI device has published so far that tells its kind.
#[derive(Debug, Clone)]
pub struct IndiDeviceDescription {
    pub name: String,
    /// `DRIVER_INFO.DRIVER_INTERFACE`; `None` until the driver sends it, and
    /// for drivers that do not publish it. `0` (libindi's "general") is
    /// kept as published and tells nothing.
    pub interface: Option<u32>,
    pub properties: Vec<IndiProperty>,
}

impl IndiDeviceDescription {
    /// The kind Skotiq lists the device as, `None` for a device Skotiq does
    /// not drive.
    ///
    /// Without a published interface, a device that shows no kind by its
    /// properties or name but has any switch property is offered as a switch
    /// device. Every INDI device has the CONNECTION switch, so that comes last.
    pub fn kind(&self) -> Option<DeviceKind> {
        if let Some(interface) = self.interface.filter(|bits| *bits != 0) {
            return BY_INTERFACE
                .iter()
                .find(|(bits, _)| interface & bits != 0)
                .map(|(_, kind)| *kind);
        }
        self.kind_by_property()
            .or_else(|| self.kind_by_name())
            .or_else(|| {
                self.properties
                    .iter()
                    .any(|p| p.property_type == IndiPropertyType::Switch)
                    .then_some(DeviceKind::Switch)
            })
    }

    /// Whether waiting for more definitions would not change the kind: the
    /// driver published its interfaces (then nothing else it defines before
    /// it is connected counts), or a property or the name already shows a
    /// kind.
    pub fn is_settled(&self) -> bool {
        self.interface.is_some()
            || self.kind_by_property().is_some()
            || self.kind_by_name().is_some()
    }

    fn kind_by_property(&self) -> Option<DeviceKind> {
        BY_PROPERTY
            .iter()
            .find(|(names, _)| {
                self.properties
                    .iter()
                    .any(|p| names.contains(&p.name.as_str()))
            })
            .map(|(_, kind)| *kind)
    }

    fn kind_by_name(&self) -> Option<DeviceKind> {
        let name = self.name.to_uppercase();
        BY_NAME
            .iter()
            .find(|(words, _)| words.iter().any(|word| name.contains(word)))
            .map(|(_, kind)| *kind)
    }
}

/// The properties `device` has defined on `client`. A device defines them
/// one by one after it connects, so an empty list is waited on for up to a
/// second.
pub(crate) async fn defined_properties(
    client: &std::sync::Arc<tokio::sync::RwLock<crate::IndiClient>>,
    device: &str,
) -> Vec<IndiProperty> {
    let started = std::time::Instant::now();
    loop {
        let properties = client.read().await.get_properties(device).await;
        if !properties.is_empty() || started.elapsed() >= std::time::Duration::from_secs(1) {
            return properties;
        }
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{IndiPermission, IndiPropertyState};

    fn property(name: &str, property_type: IndiPropertyType) -> IndiProperty {
        IndiProperty {
            device: "dev".to_string(),
            name: name.to_string(),
            label: name.to_string(),
            group: String::new(),
            property_type,
            state: IndiPropertyState::Idle,
            perm: IndiPermission::ReadWrite,
            elements: Vec::new(),
            switch_rule: None,
        }
    }

    fn device(name: &str, interface: Option<u32>, properties: &[&str]) -> IndiDeviceDescription {
        IndiDeviceDescription {
            name: name.to_string(),
            interface,
            properties: properties
                .iter()
                .map(|p| property(p, IndiPropertyType::Number))
                .chain([property(CONNECTION, IndiPropertyType::Switch)])
                .collect(),
        }
    }

    #[test]
    fn name_prefers_mount_over_an_embedded_camera_word() {
        assert_eq!(
            device("Avalon Mount Camera Mount", None, &[]).kind(),
            Some(DeviceKind::Mount)
        );
        assert_eq!(
            device("ASI294MM Camera", None, &[]).kind(),
            Some(DeviceKind::Camera)
        );
    }

    #[test]
    fn name_finds_filter_wheels_without_the_word_wheel() {
        assert_eq!(
            device("Filter Simulator", None, &[]).kind(),
            Some(DeviceKind::FilterWheel)
        );
        assert_eq!(
            device("ASI EFW", None, &[]).kind(),
            Some(DeviceKind::FilterWheel)
        );
    }

    #[test]
    fn the_connection_switch_does_not_hide_the_name() {
        let mount = device("Telescope Simulator", None, &[]);
        assert_eq!(mount.kind(), Some(DeviceKind::Mount));
        assert!(mount.is_settled());
    }

    #[test]
    fn a_device_with_only_switches_and_no_telling_name_is_a_switch_device() {
        let device = device("Pegasus Powerbox", None, &[]);
        assert_eq!(device.kind(), Some(DeviceKind::Switch));
        assert!(!device.is_settled());
    }

    #[test]
    fn a_published_interface_outranks_properties_and_name() {
        assert_eq!(
            device(
                "Weather Simulator",
                Some(interface::WEATHER),
                &[SAFETY_STATUS]
            )
            .kind(),
            Some(DeviceKind::Weather)
        );
    }

    #[test]
    fn an_interface_skotiq_does_not_drive_lists_nothing() {
        let gps = device("GPS Simulator", Some(1 << 6), &[]);
        assert_eq!(gps.kind(), None);
        assert!(gps.is_settled());
    }

    #[test]
    fn the_general_interface_tells_nothing() {
        let device = device("SQM Simulator", Some(0), &[]);
        assert_eq!(device.kind(), Some(DeviceKind::Switch));
        assert!(device.is_settled());
    }
}
