//! Quirk Type Definitions
//!
//! Every variant here has at least one entry in the database and one reader in
//! a driver. Add a variant together with both.

#[derive(Debug, Clone, PartialEq)]
pub enum Quirk {
    Temperature(TemperatureQuirk),
    /// Position-related quirks (for focusers, filter wheels, rotators)
    Position(PositionQuirk),
    Timing(TimingQuirk),
    Discovery(DiscoveryQuirk),
    Camera(CameraQuirk),
}

#[derive(Debug, Clone, PartialEq)]
pub enum TemperatureQuirk {
    /// First temperature read after connect is unreliable
    ///
    /// Some cameras (notably some ZWO models) report incorrect temperature
    /// on the first read after connecting. The caller should read twice
    /// and discard the first value.
    SkipFirstRead,

    /// Temperature reading requires a delay after requesting
    ///
    /// Some devices need time between requesting temperature and reading it
    RequiresDelayMs(u64),
}

/// Quirks related to position reporting (focusers, filter wheels, rotators)
#[derive(Debug, Clone, PartialEq)]
pub enum PositionQuirk {
    /// Position may be reported incorrectly immediately after a move
    ///
    /// Some filter wheels report the wrong position right after moving.
    /// Wait this many milliseconds before trusting the reported position.
    DelayAfterMoveMs(u64),

    /// Focuser step size in microns (real, mechanical travel per motor step).
    ///
    /// SDKs that don't expose this value force a hardcoded fallback in vendor code.
    /// Without the correct per-model value, the focus model's micron axis is wrong
    /// for every focuser whose gear ratio differs from the default. Values must come
    /// from the vendor's published mechanical spec, not from a guess.
    FocuserStepSizeMicrons(f64),
}

#[derive(Debug, Clone, PartialEq)]
pub enum TimingQuirk {
    /// Delay required after connecting before other operations
    DelayAfterConnect(u64),
}

#[derive(Debug, Clone, PartialEq)]
pub enum DiscoveryQuirk {
    /// Discovery can hang - use this timeout in milliseconds
    DiscoveryTimeoutMs(u64),
}

#[derive(Debug, Clone, PartialEq)]
pub enum CameraQuirk {
    /// Cooler has limited range
    CoolerRange { min_temp: f64, max_temp: f64 },
}

impl Quirk {
    pub fn description(&self) -> String {
        match self {
            Quirk::Temperature(t) => match t {
                TemperatureQuirk::SkipFirstRead => "First temperature read unreliable".to_string(),
                TemperatureQuirk::RequiresDelayMs(ms) => {
                    format!("Temperature read requires {}ms delay", ms)
                }
            },
            Quirk::Position(p) => match p {
                PositionQuirk::DelayAfterMoveMs(ms) => {
                    format!("{}ms delay after move", ms)
                }
                PositionQuirk::FocuserStepSizeMicrons(um) => {
                    format!("Focuser step size: {} um/step", um)
                }
            },
            Quirk::Timing(t) => match t {
                TimingQuirk::DelayAfterConnect(ms) => format!("{}ms delay after connect", ms),
            },
            Quirk::Discovery(d) => match d {
                DiscoveryQuirk::DiscoveryTimeoutMs(ms) => format!("Discovery timeout: {}ms", ms),
            },
            Quirk::Camera(c) => match c {
                CameraQuirk::CoolerRange { min_temp, max_temp } => {
                    format!("Cooler range: {} to {}", min_temp, max_temp)
                }
            },
        }
    }

    pub fn category(&self) -> &'static str {
        match self {
            Quirk::Temperature(_) => "Temperature",
            Quirk::Position(_) => "Position",
            Quirk::Timing(_) => "Timing",
            Quirk::Discovery(_) => "Discovery",
            Quirk::Camera(_) => "Camera",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_quirk_description() {
        let quirk = Quirk::Temperature(TemperatureQuirk::RequiresDelayMs(10));
        assert!(quirk.description().contains("10"));

        let quirk = Quirk::Camera(CameraQuirk::CoolerRange {
            min_temp: -40.0,
            max_temp: 30.0,
        });
        assert!(quirk.description().contains("-40"));
    }

    #[test]
    fn test_quirk_category() {
        let quirk = Quirk::Temperature(TemperatureQuirk::SkipFirstRead);
        assert_eq!(quirk.category(), "Temperature");

        let quirk = Quirk::Timing(TimingQuirk::DelayAfterConnect(200));
        assert_eq!(quirk.category(), "Timing");
    }
}
