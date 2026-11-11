//! The result every device operation returns.

/// Result type for device operations
pub type DeviceResult<T> = Result<T, String>;

/// Error text every guider op returns when the rig simply has no guider.
///
/// The bridge produces this from `ok_or_else` on the "which guider is active?"
/// lookup, so it means "nothing to do", not "the operation failed". Callers that
/// escalate device errors to the operator must special-case it: a rig imaging
/// unguided is a normal configuration, and reporting it as a failure buries the
/// real problem under noise.
pub const NO_GUIDER_CONFIGURED: &str = "No active guider configured";

/// Error text a safety poll returns on a rig with no safety monitor or weather
/// device: a configuration, not a failed reading.
pub const NO_SAFETY_DEVICE_CONFIGURED: &str =
    "No safety monitor or weather device configured for sequencer safety checks";

/// Whether a safety-poll error is the "this rig has no safety device" marker.
pub fn is_no_safety_device_configured(error: &str) -> bool {
    error.contains(NO_SAFETY_DEVICE_CONFIGURED)
}

/// Error text the default homing operations return when a backend has not
/// implemented them.
pub const HOMING_UNSUPPORTED: &str = "Homing is not supported by this device backend";

/// Whether [`DeviceResult`] error text is the benign "this rig has no guider"
/// marker rather than a real guider failure.
pub fn is_no_guider_configured(error: &str) -> bool {
    error.contains(NO_GUIDER_CONFIGURED)
}
