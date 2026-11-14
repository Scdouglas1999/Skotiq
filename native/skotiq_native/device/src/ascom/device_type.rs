//! The device types the ASCOM standard defines.

use crate::DeviceKind;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum AscomDeviceType {
    Camera,
    CoverCalibrator,
    Dome,
    FilterWheel,
    Focuser,
    ObservingConditions,
    Rotator,
    SafetyMonitor,
    Switch,
    Telescope,
}

struct Row {
    device_type: AscomDeviceType,
    kind: DeviceKind,
    name: &'static str,
    alpaca_path: &'static str,
    label: &'static str,
}

const fn row(
    device_type: AscomDeviceType,
    kind: DeviceKind,
    name: &'static str,
    alpaca_path: &'static str,
    label: &'static str,
) -> Row {
    Row {
        device_type,
        kind,
        name,
        alpaca_path,
        label,
    }
}

const TYPES: [Row; 10] = [
    row(
        AscomDeviceType::Camera,
        DeviceKind::Camera,
        "Camera",
        "camera",
        "Camera",
    ),
    row(
        AscomDeviceType::CoverCalibrator,
        DeviceKind::CoverCalibrator,
        "CoverCalibrator",
        "covercalibrator",
        "Cover Calibrator",
    ),
    row(
        AscomDeviceType::Dome,
        DeviceKind::Dome,
        "Dome",
        "dome",
        "Dome",
    ),
    row(
        AscomDeviceType::FilterWheel,
        DeviceKind::FilterWheel,
        "FilterWheel",
        "filterwheel",
        "Filter Wheel",
    ),
    row(
        AscomDeviceType::Focuser,
        DeviceKind::Focuser,
        "Focuser",
        "focuser",
        "Focuser",
    ),
    row(
        AscomDeviceType::ObservingConditions,
        DeviceKind::Weather,
        "ObservingConditions",
        "observingconditions",
        "Observing Conditions",
    ),
    row(
        AscomDeviceType::Rotator,
        DeviceKind::Rotator,
        "Rotator",
        "rotator",
        "Rotator",
    ),
    row(
        AscomDeviceType::SafetyMonitor,
        DeviceKind::SafetyMonitor,
        "SafetyMonitor",
        "safetymonitor",
        "Safety Monitor",
    ),
    row(
        AscomDeviceType::Switch,
        DeviceKind::Switch,
        "Switch",
        "switch",
        "Switch",
    ),
    row(
        AscomDeviceType::Telescope,
        DeviceKind::Mount,
        "Telescope",
        "telescope",
        "Telescope",
    ),
];

impl AscomDeviceType {
    fn row(self) -> &'static Row {
        // Every variant has a row; `every_type_has_one_row` holds that.
        TYPES
            .iter()
            .find(|row| row.device_type == self)
            .unwrap_or(&TYPES[0])
    }

    /// The standard's name for the type: the key drivers register under on
    /// Windows.
    pub fn name(self) -> &'static str {
        self.row().name
    }

    /// The device-type segment of an Alpaca URL.
    pub fn alpaca_path(self) -> &'static str {
        self.row().alpaca_path
    }

    /// The type as shown to the user.
    pub fn label(self) -> &'static str {
        self.row().label
    }

    pub fn kind(self) -> DeviceKind {
        self.row().kind
    }

    /// The type named `name`, in any case. An Alpaca server lists its devices
    /// by the standard's name.
    pub fn from_name(name: &str) -> Option<Self> {
        TYPES
            .iter()
            .find(|row| row.name.eq_ignore_ascii_case(name))
            .map(|row| row.device_type)
    }

    /// The ASCOM type for a kind of device. `None` for a guider: ASCOM has
    /// no guider interface.
    pub fn of_kind(kind: DeviceKind) -> Option<Self> {
        TYPES
            .iter()
            .find(|row| row.kind == kind)
            .map(|row| row.device_type)
    }
}

impl std::fmt::Display for AscomDeviceType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.label())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ALL: [AscomDeviceType; 10] = [
        AscomDeviceType::Camera,
        AscomDeviceType::CoverCalibrator,
        AscomDeviceType::Dome,
        AscomDeviceType::FilterWheel,
        AscomDeviceType::Focuser,
        AscomDeviceType::ObservingConditions,
        AscomDeviceType::Rotator,
        AscomDeviceType::SafetyMonitor,
        AscomDeviceType::Switch,
        AscomDeviceType::Telescope,
    ];

    #[test]
    fn every_type_has_one_row() {
        for device_type in ALL {
            let rows = TYPES.iter().filter(|r| r.device_type == device_type);
            assert_eq!(rows.count(), 1, "{device_type:?}");
            assert_eq!(device_type.alpaca_path(), device_type.name().to_lowercase());
            assert_eq!(
                AscomDeviceType::from_name(device_type.name()),
                Some(device_type)
            );
            assert_eq!(
                AscomDeviceType::from_name(device_type.alpaca_path()),
                Some(device_type)
            );
            assert_eq!(
                AscomDeviceType::of_kind(device_type.kind()),
                Some(device_type)
            );
        }
    }

    #[test]
    fn ascom_has_no_guider_and_unknown_names_are_refused() {
        assert_eq!(AscomDeviceType::of_kind(DeviceKind::Guider), None);
        assert_eq!(AscomDeviceType::from_name("video"), None);
        assert_eq!(AscomDeviceType::Telescope.kind(), DeviceKind::Mount);
        assert_eq!(
            AscomDeviceType::ObservingConditions.kind(),
            DeviceKind::Weather
        );
    }
}
