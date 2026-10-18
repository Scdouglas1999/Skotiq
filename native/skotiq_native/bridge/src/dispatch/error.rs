//! Structured error type for the internal device-dispatch + device-manager
//! ops layer.
//!
//! The FFI boundary (`crate::api::*`) is typed: every public function returns
//! `Result<_, SkotiqError>`. `DeviceOpError` carries the same structure
//! through the internal device plumbing in `crate::dispatch::*` and
//! `crate::device_manager::ops::*`, where a bare `String` would flatten what
//! callers need for programmatic recovery — *which* device failed, *what
//! category* of failure it was (not-connected vs. invalid-parameter vs. timeout
//! vs. unsupported), and whether retrying could plausibly help.
//!
//! What Dart sees is fixed by two rules:
//!
//! * Every `DeviceOpError` variant's `Display` is the wire string, so the
//!   message text is a contract, not an implementation detail.
//! * `From<DeviceOpError> for SkotiqError` maps to
//!   `SkotiqError::OperationFailed(self.to_string())`, except for the
//!   variants forwarded structurally (see the FFI edge mapping below).
//!
//! Both directions of `String` conversion exist so sub-helpers that return
//! `Result<_, String>` (the Alpaca trait methods, the `sim_gate` connection
//! gates, INDI client errors) keep flowing through `?`: `From<String>` lands in
//! [`DeviceOpError::Message`], and `From<DeviceOpError> for String` lets a
//! `String`-typed caller compile.

use crate::error::SkotiqError;
use thiserror::Error;

/// Structured failure for an internal device operation (dispatch + ops layer).
///
/// Each variant carries enough context to classify the failure programmatically
/// without re-parsing a message string:
/// * the device id, where one is in scope;
/// * an optional underlying source message / vendor code;
/// * a category that [`DeviceOpError::is_retryable`] keys off.
///
/// `Display` is contractually identical to the legacy `format!` strings so the
/// message that reaches Dart (via `SkotiqError::OperationFailed`) does not
/// change.
#[derive(Error, Debug, Clone)]
pub enum DeviceOpError {
    /// The device id was not present in the manager's device map.
    ///
    /// Legacy string: `"Device not found: {id}"`.
    #[error("Device not found: {0}")]
    DeviceNotFound(String),

    /// A driver-specific handle for the device was not connected. `detail` is
    /// the exact legacy phrasing (it varies per driver, e.g.
    /// `"ASCOM mount not connected"`, `"Alpaca mount {id} not connected"`,
    /// `"INDI client not connected for {key}"`), so `Display` just renders it.
    #[error("{detail}")]
    NotConnected {
        /// Device id when known (the simulator/driver-bare messages omit it).
        device_id: Option<String>,
        /// The exact not-connected message for this driver arm.
        detail: String,
    },

    /// A device id failed to parse / was malformed for its driver.
    ///
    /// Legacy strings: `"Invalid INDI device ID format: {id}"`,
    /// `"Invalid INDI device ID"`, `"Invalid port number"`, etc. — preserved
    /// verbatim in `detail`.
    #[error("{detail}")]
    InvalidDeviceId { detail: String },

    /// A caller-supplied parameter was invalid or out of range.
    ///
    /// Legacy strings: `"Invalid direction: {dir}"`,
    /// `"Switch index {i} out of range ..."`, etc.
    #[error("{detail}")]
    InvalidParameter { detail: String },

    /// The operation is not supported by this device / driver.
    ///
    /// Legacy strings: `"Alt/Az slew is not supported for native serial mounts"`,
    /// `"Find home is not supported for native serial mounts"`, the simulator
    /// "devices are disabled" message, etc.
    #[error("{detail}")]
    Unsupported { detail: String },

    /// The device is connected and the operation is supported, but the device
    /// is in a state that refuses it right now (a parked mount asked to home).
    /// The operator has to change that state first; retrying unchanged cannot
    /// succeed.
    #[error("{detail}")]
    InvalidState {
        /// Device id the refusal is about.
        device_id: String,
        /// What is wrong and what to do about it.
        detail: String,
    },

    /// A hardware / SDK / protocol call failed. `detail` carries the full
    /// legacy message (which frequently embeds the device id and the
    /// underlying driver error), so `Display` renders it verbatim.
    #[error("{detail}")]
    Hardware {
        /// Device id when the legacy message scoped the failure to one.
        device_id: Option<String>,
        /// Full legacy failure message (often `"Failed to … {id}: {source}"`).
        detail: String,
    },

    /// One-off message that does not fit a category. Used for sub-helper
    /// errors that arrive as a bare `String` (Alpaca trait results, INDI
    /// client errors, sim-gate gates) where re-classifying would risk
    /// changing the user-visible wording.
    #[error("{0}")]
    Message(String),
}

impl DeviceOpError {
    /// `"Device not found: {id}"` — the canonical lookup-miss error.
    pub(crate) fn device_not_found(device_id: impl Into<String>) -> Self {
        DeviceOpError::DeviceNotFound(device_id.into())
    }

    /// Driver handle absent. `detail` is the exact legacy phrasing for the arm.
    pub(crate) fn not_connected(device_id: Option<String>, detail: impl Into<String>) -> Self {
        DeviceOpError::NotConnected {
            device_id,
            detail: detail.into(),
        }
    }

    /// Malformed / unparseable device id.
    pub(crate) fn invalid_device_id(detail: impl Into<String>) -> Self {
        DeviceOpError::InvalidDeviceId {
            detail: detail.into(),
        }
    }

    /// Invalid caller parameter.
    pub(crate) fn invalid_parameter(detail: impl Into<String>) -> Self {
        DeviceOpError::InvalidParameter {
            detail: detail.into(),
        }
    }

    /// Operation unsupported on this device / driver.
    pub(crate) fn unsupported(detail: impl Into<String>) -> Self {
        DeviceOpError::Unsupported {
            detail: detail.into(),
        }
    }

    /// Device state refuses the operation until the operator changes it.
    pub(crate) fn invalid_state(device_id: impl Into<String>, detail: impl Into<String>) -> Self {
        DeviceOpError::InvalidState {
            device_id: device_id.into(),
            detail: detail.into(),
        }
    }

    /// Hardware / SDK / protocol failure carrying the full legacy message.
    pub(crate) fn hardware(device_id: Option<String>, detail: impl Into<String>) -> Self {
        DeviceOpError::Hardware {
            device_id,
            detail: detail.into(),
        }
    }

    /// Classify a bare driver/SDK error string (the common
    /// `.map_err(|e| e.to_string())` site) as a [`DeviceOpError::Hardware`]
    /// without a device id. The id is usually already inside the driver's own
    /// message, so `None` keeps the wording exact while still marking the
    /// failure category as hardware, and therefore retryable, for programmatic
    /// recovery.
    pub(crate) fn driver(detail: impl std::fmt::Display) -> Self {
        DeviceOpError::Hardware {
            device_id: None,
            detail: detail.to_string(),
        }
    }

    /// The device id this failure is scoped to, when known: the typed accessor
    /// retry and reconnect logic uses instead of re-parsing messages.
    #[allow(dead_code)]
    pub(crate) fn device_id(&self) -> Option<&str> {
        match self {
            DeviceOpError::DeviceNotFound(id) => Some(id),
            DeviceOpError::NotConnected { device_id, .. }
            | DeviceOpError::Hardware { device_id, .. } => device_id.as_deref(),
            DeviceOpError::InvalidState { device_id, .. } => Some(device_id),
            DeviceOpError::InvalidDeviceId { .. }
            | DeviceOpError::InvalidParameter { .. }
            | DeviceOpError::Unsupported { .. }
            | DeviceOpError::Message(_) => None,
        }
    }

    /// Whether retrying the same operation could plausibly succeed.
    ///
    /// Mirrors `SkotiqError::is_recoverable`'s classification: not-connected
    /// and hardware/communication failures may be transient (the device can be
    /// reconnected or the SDK call re-issued), whereas invalid parameters,
    /// unsupported operations, and malformed ids will fail identically on
    /// retry. A device-not-found is treated as non-retryable (the caller must
    /// reconnect/rediscover, not blindly retry the op).
    ///
    /// Part of the structured-recovery API this refactor exists to enable; see
    /// [`DeviceOpError::device_id`] for why it is not yet wired to a caller.
    #[allow(dead_code)]
    pub(crate) fn is_retryable(&self) -> bool {
        matches!(
            self,
            DeviceOpError::NotConnected { .. } | DeviceOpError::Hardware { .. }
        )
    }
}

/// Bare strings from sub-helpers (Alpaca trait methods, INDI client errors,
/// the `sim_gate` connection gates) land here so `?` keeps working without
/// reclassifying — and without changing their wording.
impl From<String> for DeviceOpError {
    fn from(s: String) -> Self {
        DeviceOpError::Message(s)
    }
}

impl From<&str> for DeviceOpError {
    fn from(s: &str) -> Self {
        DeviceOpError::Message(s.to_string())
    }
}

/// INDI protocol errors propagated via bare `?` from `IndiClient` calls.
///
/// The legacy code path returned `Result<_, String>` and relied on
/// `From<IndiError> for String` (the INDI crate's own conversion) when a
/// `?`-propagated `IndiError` crossed into a `String`-typed function. To keep
/// those `?` sites compiling — and the surfaced message byte-identical — we
/// reproduce that exact string (`e.to_string()`) but classify it as a
/// [`DeviceOpError::Hardware`] (INDI failures are protocol/comm failures, i.e.
/// retryable). The device id is not in scope at the trait-error boundary, so
/// it is left `None`; the INDI message already names the property that failed.
/// Classify a vendor-SDK error instead of flattening it to `Hardware`.
///
/// [`DeviceOpError::driver`] takes `impl Display`, so every native driver
/// failure — including the ones the SDK layer had *already* classified —
/// collapsed into `Hardware { .. }`, which
/// `From<DeviceOpError> for SkotiqError` then renders as
/// `OperationFailed`, which the HTTP layer answers as a generic 500.
/// Observed on the live rig against a real ZWO ASI1600MM-Cool whose own
/// capabilities report `readoutModes: []`:
///   POST /api/camera/readoutMode {"modeIndex":0}
///     -> 500 {"error":"internal_error","message":"Operation not supported"}
/// The driver said "not supported", the HTTP layer already knows how to
/// answer that (501), and only this conversion lost the category — while
/// also inviting retry-on-5xx clients to retry a call that can never work.
///
/// Use `.map_err(DeviceOpError::from)` at native-driver call sites in place
/// of `.map_err(DeviceOpError::driver)`. Everything that is genuinely a
/// hardware/SDK fault still becomes `Hardware`, so 500 remains the answer
/// for real faults.
impl From<skotiq_native::NativeError> for DeviceOpError {
    fn from(e: skotiq_native::NativeError) -> Self {
        use skotiq_native::NativeError as N;
        let detail = e.to_string();
        match e {
            N::NotSupported => DeviceOpError::Unsupported { detail },
            N::InvalidParameter(_) => DeviceOpError::InvalidParameter { detail },
            N::InvalidDevice(_) => DeviceOpError::InvalidDeviceId { detail },
            N::DeviceNotFound(id) => DeviceOpError::DeviceNotFound(id),
            N::NotConnected | N::Disconnected => DeviceOpError::NotConnected {
                device_id: None,
                detail,
            },
            // SdkError / SdkNotLoaded / the timeout family / anything else is
            // a genuine hardware or host fault.
            _ => DeviceOpError::Hardware {
                device_id: None,
                detail,
            },
        }
    }
}

impl From<skotiq_indi::IndiError> for DeviceOpError {
    fn from(e: skotiq_indi::IndiError) -> Self {
        DeviceOpError::Hardware {
            device_id: None,
            detail: e.to_string(),
        }
    }
}

/// FFI edge mapping. Most variants render through `Display` into
/// `SkotiqError::OperationFailed`; not-connected and device-not-found are
/// forwarded structurally, because the headless API maps the bridge error enum
/// to an HTTP status (`_httpStatusForBackendError`: notConnected -> 409,
/// deviceNotFound -> 404, ... orElse -> 500). Collapsed into `OperationFailed`
/// they answer 500 `internal_error`, and a 5xx on a device precondition invites
/// the client to auto-retry straight back into the serial bus.
///
/// Message compatibility: `DeviceNotFound` renders identically in both enums
/// (`"Device not found: {id}"`). The not-connected arm reads `"Device not
/// connected: {id}"`, which keeps the `not connected` substring the Dart
/// classifiers key on (`SkotiqError.fromString`,
/// `skotiq_exception.dart`) and additionally names the device.
impl From<DeviceOpError> for SkotiqError {
    fn from(e: DeviceOpError) -> Self {
        match e {
            DeviceOpError::DeviceNotFound(id) => SkotiqError::DeviceNotFound(id),
            DeviceOpError::NotConnected { device_id, detail } => {
                // Prefer the id (clean "Device not connected: <id>"); fall back
                // to the driver's own phrasing for the arms that omit it.
                SkotiqError::NotConnected(device_id.unwrap_or(detail))
            }
            // The HTTP layer already knows what to do with these categories
            // (`_httpStatusForBackendError` maps `notSupported` -> 501 and
            // `invalidParameter`/`invalidDeviceId` -> 400), and the driver has
            // already classified the failure — an unsupported readout mode or a
            // 9x9 binning request cannot succeed on retry, so answering 500
            // would invite a retry-on-5xx client to reissue it forever.
            // `Hardware` and `Message` stay `OperationFailed`: they are genuine
            // 500s, and re-shaping them would change wording that Dart string
            // classifiers key on for no status-code gain.
            DeviceOpError::Unsupported { detail } => SkotiqError::NotSupported {
                device_id: String::new(),
                operation: detail,
            },
            DeviceOpError::InvalidParameter { detail } => SkotiqError::InvalidParameter(detail),
            // A state conflict, not a fault: the HTTP layer answers
            // `deviceBusy` with 409, which is what tells a client "change the
            // device's state, then ask again" rather than "retry later".
            DeviceOpError::InvalidState { device_id, detail } => SkotiqError::DeviceBusy {
                device_id,
                current_operation: detail,
            },
            DeviceOpError::InvalidDeviceId { detail } => SkotiqError::InvalidDeviceId {
                device_id: String::new(),
                reason: detail,
            },
            other => SkotiqError::OperationFailed(other.to_string()),
        }
    }
}

/// Lets a `Result<_, String>` caller keep compiling: a `DeviceOpError` renders
/// to its `Display` wire string.
impl From<DeviceOpError> for String {
    fn from(e: DeviceOpError) -> Self {
        e.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn display_matches_legacy_strings() {
        assert_eq!(
            DeviceOpError::device_not_found("ascom:Foo").to_string(),
            "Device not found: ascom:Foo"
        );
        assert_eq!(
            DeviceOpError::not_connected(None, "ASCOM mount not connected").to_string(),
            "ASCOM mount not connected"
        );
        assert_eq!(
            DeviceOpError::invalid_parameter("Invalid direction: up").to_string(),
            "Invalid direction: up"
        );
    }

    #[test]
    fn ffi_mapping_preserves_operation_failed_string() {
        let err = DeviceOpError::hardware(
            Some("alpaca:host:0:1".to_string()),
            "Failed to park Alpaca mount: boom",
        );
        let mapped: SkotiqError = err.into();
        match mapped {
            SkotiqError::OperationFailed(s) => {
                assert_eq!(s, "Failed to park Alpaca mount: boom");
            }
            other => panic!("expected OperationFailed, got {other:?}"),
        }
    }

    /// A not-connected device is a caller precondition, not a server fault.
    /// The headless API turns `NotConnected` into HTTP 409; while this mapping
    /// collapsed to `OperationFailed`, every equipment endpoint answered 500
    /// for a merely-disconnected device (reproduced on the rig against a real
    /// mount) and remote clients treat 5xx as retryable.
    #[test]
    fn ffi_mapping_forwards_not_connected_structurally() {
        let err = DeviceOpError::not_connected(
            Some("ascom:ASCOM.PegasusAstroNYX101.Telescope".to_string()),
            "ASCOM mount not connected",
        );
        let mapped: SkotiqError = err.into();
        match mapped {
            SkotiqError::NotConnected(id) => {
                assert_eq!(id, "ascom:ASCOM.PegasusAstroNYX101.Telescope");
                // The Dart-side classifiers key on this substring.
                assert!(SkotiqError::NotConnected(id)
                    .to_string()
                    .to_lowercase()
                    .contains("not connected"));
            }
            other => panic!("expected NotConnected, got {other:?}"),
        }
    }

    /// The driver-bare arms omit the id; keep their own phrasing as the payload
    /// so the message still says which subsystem is down.
    #[test]
    fn ffi_mapping_not_connected_without_id_keeps_driver_detail() {
        let err = DeviceOpError::not_connected(None, "INDI client not connected for ccd");
        let mapped: SkotiqError = err.into();
        match mapped {
            SkotiqError::NotConnected(detail) => {
                assert_eq!(detail, "INDI client not connected for ccd");
            }
            other => panic!("expected NotConnected, got {other:?}"),
        }
    }

    /// `DeviceNotFound` renders identically in both enums, so forwarding it
    /// changes the HTTP status (500 -> 404) without changing the wire message.
    #[test]
    fn ffi_mapping_device_not_found_is_message_identical() {
        let op_err = DeviceOpError::device_not_found("ascom:Foo");
        let legacy = op_err.to_string();
        let mapped: SkotiqError = op_err.into();
        match mapped {
            SkotiqError::DeviceNotFound(_) => {
                assert_eq!(mapped.to_string(), legacy);
                assert_eq!(mapped.to_string(), "Device not found: ascom:Foo");
            }
            other => panic!("expected DeviceNotFound, got {other:?}"),
        }
    }

    #[test]
    fn string_roundtrips_through_message_variant() {
        let from_helper: DeviceOpError = "boom from sub-helper".to_string().into();
        assert_eq!(from_helper.to_string(), "boom from sub-helper");
        let back: String = from_helper.into();
        assert_eq!(back, "boom from sub-helper");
    }

    #[test]
    fn retryable_classification() {
        assert!(DeviceOpError::not_connected(None, "x not connected").is_retryable());
        assert!(DeviceOpError::hardware(None, "sdk boom").is_retryable());
        assert!(!DeviceOpError::invalid_parameter("bad").is_retryable());
        assert!(!DeviceOpError::unsupported("nope").is_retryable());
        assert!(!DeviceOpError::device_not_found("x").is_retryable());
    }

    #[test]
    fn device_id_extraction() {
        assert_eq!(
            DeviceOpError::device_not_found("d1").device_id(),
            Some("d1")
        );
        assert_eq!(
            DeviceOpError::hardware(Some("d2".to_string()), "boom").device_id(),
            Some("d2")
        );
        assert_eq!(DeviceOpError::invalid_parameter("bad").device_id(), None);
    }
}
