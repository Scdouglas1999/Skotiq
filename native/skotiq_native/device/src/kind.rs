//! The kinds of device Skotiq drives.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum DeviceKind {
    Camera,
    Mount,
    Focuser,
    FilterWheel,
    Guider,
    Dome,
    Rotator,
    Weather,
    SafetyMonitor,
    Switch,
    CoverCalibrator,
}

impl DeviceKind {
    pub const ALL: [DeviceKind; 11] = [
        DeviceKind::Camera,
        DeviceKind::Mount,
        DeviceKind::Focuser,
        DeviceKind::FilterWheel,
        DeviceKind::Guider,
        DeviceKind::Dome,
        DeviceKind::Rotator,
        DeviceKind::Weather,
        DeviceKind::SafetyMonitor,
        DeviceKind::Switch,
        DeviceKind::CoverCalibrator,
    ];
}

#[cfg(test)]
mod all_list_tests {
    #[test]
    fn all_names_every_variant() {
        skotiq_wire_fixtures::assert_lists_every_variant!(
            super::DeviceKind::ALL,
            [
                super::DeviceKind::Camera,
                super::DeviceKind::Mount,
                super::DeviceKind::Focuser,
                super::DeviceKind::FilterWheel,
                super::DeviceKind::Guider,
                super::DeviceKind::Dome,
                super::DeviceKind::Rotator,
                super::DeviceKind::Weather,
                super::DeviceKind::SafetyMonitor,
                super::DeviceKind::Switch,
                super::DeviceKind::CoverCalibrator
            ]
        );
    }
}
