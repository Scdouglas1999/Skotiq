use super::*;

/// Why a simulated device refused an operation.
///
/// A category rather than a formatted string for the same reason
/// [`crate::dispatch::DeviceOpError`] is an enum: the ops layer has to pick
/// `not_connected` vs `invalid_parameter` vs `driver`, and doing that by
/// matching on message text is how the wrong error class ships.
#[derive(Debug, Clone, PartialEq, Eq)]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) enum SimDeviceError {
    /// The singleton's `connected` flag is false — nothing was ever opened.
    NotConnected(String),
    /// The caller asked for something the device cannot represent: a switch
    /// index that does not exist, a value outside a channel's range, a write to
    /// a read-only channel. Real ASCOM drivers raise `InvalidValueException` /
    /// `MethodNotImplementedException` here rather than quietly clamping.
    InvalidParameter(String),
    /// An injected driver fault; see [`crate::device_manager::ops::sim_faults`].
    Driver(String),
}

impl std::fmt::Display for SimDeviceError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SimDeviceError::NotConnected(m)
            | SimDeviceError::InvalidParameter(m)
            | SimDeviceError::Driver(m) => f.write_str(m),
        }
    }
}

/// Preserve the category across the ops boundary.
///
/// Flattening everything to `DeviceOpError::driver` would mark a rejected
/// brightness or a bad switch index as a hardware failure, which
/// `DeviceOpError::is_retryable` then tells the app to retry — forever, since
/// the caller's argument is not going to get better on its own. The device id
/// is left `None` to match the other simulator arms (`ops/filter_wheel.rs`),
/// whose messages already name the simulated device type rather than an id.
impl From<SimDeviceError> for crate::dispatch::DeviceOpError {
    fn from(err: SimDeviceError) -> Self {
        use crate::dispatch::DeviceOpError;
        match err {
            SimDeviceError::NotConnected(m) => DeviceOpError::not_connected(None, m),
            SimDeviceError::InvalidParameter(m) => DeviceOpError::invalid_parameter(m),
            SimDeviceError::Driver(m) => DeviceOpError::driver(m),
        }
    }
}

/// Consult the fault registry, mapping a fired fault onto [`SimDeviceError`].
pub(crate) async fn sim_fault(key: &str) -> Result<(), SimDeviceError> {
    crate::device_manager::ops::sim_faults::check(key)
        .await
        .map_err(SimDeviceError::Driver)
}

/// A mechanism travelling from one value to another over a known time.
///
/// Shared by the cover's lid and the panel's brightness because both have the
/// same property that matters here: the value a caller reads mid-flight is
/// somewhere in between, not the commanded endpoint. Modelled as a start
/// instant plus a duration (like `SimSlew`) rather than a per-tick integrator
/// so there is no "first read establishes the baseline" hazard — the motion is
/// fully determined by the command that started it.
#[derive(Debug, Clone, Copy)]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct SimRamp {
    pub(crate) start: Instant,
    pub(crate) duration_secs: f64,
    pub(crate) from: f64,
    pub(crate) to: f64,
}

impl SimRamp {
    pub(crate) fn fraction(&self) -> f64 {
        if self.duration_secs <= 0.0 {
            return 1.0;
        }
        (self.start.elapsed().as_secs_f64() / self.duration_secs).clamp(0.0, 1.0)
    }

    pub(crate) fn value(&self) -> f64 {
        self.from + (self.to - self.from) * self.fraction()
    }

    pub(crate) fn is_complete(&self) -> bool {
        self.fraction() >= 1.0
    }
}
