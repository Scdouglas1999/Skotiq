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
