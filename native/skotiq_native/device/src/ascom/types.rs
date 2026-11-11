//! Value types of the ASCOM standard, with the numeric values ASCOM assigns.
//!
//! These are the ASCOM enumerations as they travel on the wire (an `Int32`
//! over COM, a JSON number over Alpaca). Conversions to the protocol-neutral
//! device vocabulary live with that vocabulary.

use serde::Deserialize;

/// Builds the typed value a transport hands out from the value an ASCOM
/// member carries on the wire.
pub trait FromWire<W> {
    fn from_wire(wire: W) -> Self;
}

impl<T: From<i32>> FromWire<i32> for T {
    fn from_wire(wire: i32) -> Self {
        T::from(wire)
    }
}

impl<T: From<i32>> FromWire<Vec<i32>> for Vec<T> {
    fn from_wire(wire: Vec<i32>) -> Self {
        wire.into_iter().map(T::from).collect()
    }
}

/// `ASCOM.DeviceInterface.PierSide`
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PierSide {
    East = 0,
    West = 1,
    Unknown = -1,
}

impl From<i32> for PierSide {
    fn from(value: i32) -> Self {
        match value {
            0 => PierSide::East,
            1 => PierSide::West,
            _ => PierSide::Unknown,
        }
    }
}

impl std::fmt::Display for PierSide {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PierSide::East => write!(f, "East"),
            PierSide::West => write!(f, "West"),
            PierSide::Unknown => write!(f, "Unknown"),
        }
    }
}

/// `ASCOM.DeviceInterface.DriveRates`
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DriveRate {
    Sidereal = 0,
    Lunar = 1,
    Solar = 2,
    King = 3,
}

impl From<i32> for DriveRate {
    fn from(value: i32) -> Self {
        match value {
            0 => DriveRate::Sidereal,
            1 => DriveRate::Lunar,
            2 => DriveRate::Solar,
            3 => DriveRate::King,
            _ => DriveRate::Sidereal,
        }
    }
}

impl std::fmt::Display for DriveRate {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DriveRate::Sidereal => write!(f, "Sidereal"),
            DriveRate::Lunar => write!(f, "Lunar"),
            DriveRate::Solar => write!(f, "Solar"),
            DriveRate::King => write!(f, "King"),
        }
    }
}

/// `ASCOM.DeviceInterface.AlignmentModes`
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AlignmentMode {
    AltAz = 0,
    Polar = 1,
    GermanPolar = 2,
}

impl From<i32> for AlignmentMode {
    fn from(value: i32) -> Self {
        match value {
            0 => AlignmentMode::AltAz,
            1 => AlignmentMode::Polar,
            2 => AlignmentMode::GermanPolar,
            _ => AlignmentMode::AltAz,
        }
    }
}

/// `ASCOM.DeviceInterface.TelescopeAxes`
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TelescopeAxis {
    Primary = 0,
    Secondary = 1,
    Tertiary = 2,
}

impl TelescopeAxis {
    pub fn as_i32(self) -> i32 {
        self as i32
    }
}

/// One element of `ITelescope.AxisRates`: a range of rates in degrees per
/// second the axis can move at.
#[derive(Debug, Clone, Copy, PartialEq, Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct AxisRate {
    pub minimum: f64,
    pub maximum: f64,
}

/// `ASCOM.DeviceInterface.ShutterState`
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ShutterStatus {
    Open = 0,
    Closed = 1,
    Opening = 2,
    Closing = 3,
    Error = 4,
}

impl From<i32> for ShutterStatus {
    fn from(value: i32) -> Self {
        match value {
            0 => ShutterStatus::Open,
            1 => ShutterStatus::Closed,
            2 => ShutterStatus::Opening,
            3 => ShutterStatus::Closing,
            _ => ShutterStatus::Error,
        }
    }
}

impl std::fmt::Display for ShutterStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ShutterStatus::Open => write!(f, "Open"),
            ShutterStatus::Closed => write!(f, "Closed"),
            ShutterStatus::Opening => write!(f, "Opening"),
            ShutterStatus::Closing => write!(f, "Closing"),
            ShutterStatus::Error => write!(f, "Error"),
        }
    }
}

/// `ASCOM.DeviceInterface.CoverStatus`
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CoverStatus {
    NotPresent = 0,
    Closed = 1,
    Moving = 2,
    Open = 3,
    Unknown = 4,
    Error = 5,
}

impl From<i32> for CoverStatus {
    fn from(value: i32) -> Self {
        match value {
            0 => CoverStatus::NotPresent,
            1 => CoverStatus::Closed,
            2 => CoverStatus::Moving,
            3 => CoverStatus::Open,
            4 => CoverStatus::Unknown,
            _ => CoverStatus::Error,
        }
    }
}

impl std::fmt::Display for CoverStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CoverStatus::NotPresent => write!(f, "Not Present"),
            CoverStatus::Closed => write!(f, "Closed"),
            CoverStatus::Moving => write!(f, "Moving"),
            CoverStatus::Open => write!(f, "Open"),
            CoverStatus::Unknown => write!(f, "Unknown"),
            CoverStatus::Error => write!(f, "Error"),
        }
    }
}

/// `ASCOM.DeviceInterface.CalibratorStatus`
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CalibratorStatus {
    NotPresent = 0,
    Off = 1,
    NotReady = 2,
    Ready = 3,
    Unknown = 4,
    Error = 5,
}

impl From<i32> for CalibratorStatus {
    fn from(value: i32) -> Self {
        match value {
            0 => CalibratorStatus::NotPresent,
            1 => CalibratorStatus::Off,
            2 => CalibratorStatus::NotReady,
            3 => CalibratorStatus::Ready,
            4 => CalibratorStatus::Unknown,
            _ => CalibratorStatus::Error,
        }
    }
}

impl std::fmt::Display for CalibratorStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CalibratorStatus::NotPresent => write!(f, "Not Present"),
            CalibratorStatus::Off => write!(f, "Off"),
            CalibratorStatus::NotReady => write!(f, "Not Ready"),
            CalibratorStatus::Ready => write!(f, "Ready"),
            CalibratorStatus::Unknown => write!(f, "Unknown"),
            CalibratorStatus::Error => write!(f, "Error"),
        }
    }
}

/// `ASCOM.DeviceInterface.CameraStates`
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CameraState {
    Idle = 0,
    Waiting = 1,
    Exposing = 2,
    Reading = 3,
    Download = 4,
    Error = 5,
}

impl From<i32> for CameraState {
    fn from(value: i32) -> Self {
        match value {
            0 => CameraState::Idle,
            1 => CameraState::Waiting,
            2 => CameraState::Exposing,
            3 => CameraState::Reading,
            4 => CameraState::Download,
            _ => CameraState::Error,
        }
    }
}

impl std::fmt::Display for CameraState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CameraState::Idle => write!(f, "Idle"),
            CameraState::Waiting => write!(f, "Waiting"),
            CameraState::Exposing => write!(f, "Exposing"),
            CameraState::Reading => write!(f, "Reading"),
            CameraState::Download => write!(f, "Downloading"),
            CameraState::Error => write!(f, "Error"),
        }
    }
}

/// `ASCOM.DeviceInterface.SensorType`
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SensorType {
    Monochrome = 0,
    Color = 1,
    RGGB = 2,
    CMYG = 3,
    CMYG2 = 4,
    LRGB = 5,
}

impl From<i32> for SensorType {
    fn from(value: i32) -> Self {
        match value {
            0 => SensorType::Monochrome,
            1 => SensorType::Color,
            2 => SensorType::RGGB,
            3 => SensorType::CMYG,
            4 => SensorType::CMYG2,
            5 => SensorType::LRGB,
            _ => SensorType::Monochrome,
        }
    }
}
