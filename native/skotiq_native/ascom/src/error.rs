//! The error every ASCOM COM call returns.
//!
//! The `Display` text of each variant is what the bridge logs and what parts
//! of the app and its tests match on (`Failed to call method StartExposure`,
//! the `0x8004....` code a driver writes into its exception), so the wording
//! is part of the interface.

use crate::com::{ComKind, Dispatch};

#[derive(Debug, Clone, PartialEq)]
pub enum AscomError {
    /// COM could not be initialized on the calling thread.
    ComInit { cause: String },
    /// The ProgID has no registered class.
    ClassNotRegistered { prog_id: String, cause: String },
    /// The driver's COM object could not be created.
    CreateFailed { prog_id: String, cause: String },
    /// The driver has no member with this name.
    UnknownMember { member: String, cause: String },
    /// The driver refused or failed the call. `cause` is the driver's own
    /// account when it gave one, otherwise the HRESULT text; `code` is the
    /// error code it raised (an ASCOM exception's `scode`), otherwise the
    /// HRESULT.
    Invoke {
        dispatch: Dispatch,
        member: String,
        cause: String,
        code: Option<i32>,
    },
    /// The driver answered with a VARIANT that does not hold the expected type.
    UnexpectedType {
        dispatch: Dispatch,
        member: String,
        expected: ComKind,
        /// The VARIANT type tag the driver returned.
        vt: u16,
        detail: Option<String>,
    },
    /// The driver accepted `Connected = true` but never reported it back.
    /// Carries the operator-facing message from `connect_verify`.
    NotOnline(String),
    /// The caller passed a value ASCOM cannot take.
    InvalidArgument(String),
    /// The camera's image array could not be read.
    ImageArray(String),
    /// A failure with the name of the operation it happened in.
    Context {
        context: &'static str,
        source: Box<AscomError>,
    },
}

/// `ISwitch` methods and `CalibratorOn` have always reported a failure without
/// the word "method" ("Failed to call GetSwitch: ...", "GetSwitch did not
/// return a bool"), unlike every other method. The texts are kept as operators
/// and log searches know them.
const TERSE_METHODS: &[&str] = &[
    "GetSwitch",
    "SetSwitch",
    "GetSwitchName",
    "GetSwitchDescription",
    "GetSwitchValue",
    "SetSwitchValue",
    "MinSwitchValue",
    "MaxSwitchValue",
    "SwitchStep",
    "CanWrite",
    "CalibratorOn",
];

fn is_terse(member: &str) -> bool {
    TERSE_METHODS.contains(&member)
}

impl std::fmt::Display for AscomError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            AscomError::ComInit { cause } => write!(f, "Failed to initialize COM: {cause}"),
            AscomError::ClassNotRegistered { prog_id, cause } => {
                write!(f, "Failed to get CLSID for {prog_id}: {cause}")
            }
            AscomError::CreateFailed { prog_id, cause } => {
                write!(f, "Failed to create COM object {prog_id}: {cause}")
            }
            AscomError::UnknownMember { member, cause } => {
                write!(f, "Failed to get DISPID for {member}: {cause}")
            }
            AscomError::Invoke {
                dispatch,
                member,
                cause,
                ..
            } => match dispatch {
                Dispatch::Get => write!(f, "Failed to get property {member}: {cause}"),
                Dispatch::Put => write!(f, "Failed to set property {member}: {cause}"),
                Dispatch::Method if is_terse(member) => {
                    write!(f, "Failed to call {member}: {cause}")
                }
                Dispatch::Method => write!(f, "Failed to call method {member}: {cause}"),
            },
            AscomError::UnexpectedType {
                dispatch,
                member,
                expected,
                vt,
                detail,
            } => {
                let detail = detail.as_deref().unwrap_or("");
                match (dispatch, expected) {
                    (Dispatch::Method, ComKind::Bool) if is_terse(member) => {
                        write!(f, "{member} did not return a bool")
                    }
                    (Dispatch::Method, ComKind::Bstr) if is_terse(member) => {
                        write!(f, "{member} did not return a string")
                    }
                    (Dispatch::Method, _) if is_terse(member) => {
                        write!(f, "{member} did not return a number")
                    }
                    (Dispatch::Method, ComKind::Bool) => {
                        write!(f, "Method {member} did not return a boolean")
                    }
                    (Dispatch::Method, ComKind::Bstr) => {
                        write!(f, "Method {member} did not return a string")
                    }
                    (Dispatch::Method, _) => write!(f, "Method {member} did not return a number"),
                    (_, ComKind::Bstr) => write!(f, "Property {member} is not a string"),
                    (_, ComKind::BstrArray) => {
                        write!(f, "Property {member} is not a string array: {detail}")
                    }
                    (_, ComKind::I4Array) => {
                        write!(f, "Property {member} is not an int array: {detail}")
                    }
                    (_, ComKind::Bool) => write!(f, "Property {member} is not a bool"),
                    (_, ComKind::R8) => write!(f, "Property {member} is not a double"),
                    (_, ComKind::Date) => write!(f, "Property {member} is not a VT_DATE"),
                    (_, ComKind::I4) => {
                        write!(f, "Property {member} is not an int (VARIANT type={vt})")
                    }
                    (_, ComKind::Void) => write!(f, "Property {member} returned a value"),
                }
            }
            AscomError::NotOnline(message)
            | AscomError::InvalidArgument(message)
            | AscomError::ImageArray(message) => write!(f, "{message}"),
            AscomError::Context { context, source } => write!(f, "{context}: {source}"),
        }
    }
}

impl std::error::Error for AscomError {}

pub type AscomResult<T> = Result<T, AscomError>;

/// COM's own "not implemented" (`E_NOTIMPL`), which some drivers raise in place
/// of ASCOM's `NotImplementedException`.
const E_NOTIMPL: i32 = 0x8000_4001_u32 as i32;

/// The kind of failure an ASCOM error names. A failure of no particular kind
/// stays the protocol's own error, for its wording.
impl From<AscomError> for skotiq_device::DriverError {
    fn from(err: AscomError) -> Self {
        use skotiq_device::DriverError;
        match err.kind() {
            Some(kind) => kind,
            None => DriverError::Backend(Box::new(err)),
        }
    }
}

impl AscomError {
    fn kind(&self) -> Option<skotiq_device::DriverError> {
        use skotiq_device::DriverError;
        match self {
            AscomError::Invoke {
                code: Some(E_NOTIMPL),
                ..
            }
            | AscomError::UnknownMember { .. } => Some(DriverError::NotSupported),
            AscomError::Invoke {
                code: Some(code),
                cause,
                ..
            } => skotiq_device::ascom::classify_error_number(*code, cause),
            AscomError::InvalidArgument(message) => {
                Some(DriverError::InvalidParameter(message.clone()))
            }
            AscomError::Context { source, .. } => source.kind(),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn invoke(dispatch: Dispatch, member: &str) -> String {
        AscomError::Invoke {
            dispatch,
            member: member.to_string(),
            cause: "cause".to_string(),
            code: None,
        }
        .to_string()
    }

    #[test]
    fn invoke_failures_keep_their_wording() {
        assert_eq!(
            invoke(Dispatch::Get, "Gain"),
            "Failed to get property Gain: cause"
        );
        assert_eq!(
            invoke(Dispatch::Put, "SetCCDTemperature"),
            "Failed to set property SetCCDTemperature: cause"
        );
        assert_eq!(
            invoke(Dispatch::Method, "StartExposure"),
            "Failed to call method StartExposure: cause"
        );
        assert_eq!(
            invoke(Dispatch::Method, "SetSwitch"),
            "Failed to call SetSwitch: cause"
        );
    }

    #[test]
    fn ascom_errors_reach_drivers_as_the_failure_they_name() {
        use skotiq_device::DriverError;

        let raised = |code: u32| AscomError::Invoke {
            dispatch: Dispatch::Method,
            member: "SlewToCoordinatesAsync".to_string(),
            cause: "said the driver".to_string(),
            code: Some(code as i32),
        };
        assert!(matches!(
            DriverError::from(raised(0x8004_0407)),
            DriverError::NotConnected
        ));
        assert!(matches!(
            DriverError::from(raised(0x8004_0400)),
            DriverError::NotSupported
        ));
        assert!(matches!(
            DriverError::from(raised(0x8000_4001)),
            DriverError::NotSupported
        ));
        assert!(matches!(
            DriverError::from(raised(0x8004_0401)),
            DriverError::InvalidParameter(cause) if cause == "said the driver"
        ));
        assert!(matches!(
            DriverError::from(AscomError::Context {
                context: "Failed to slew ASCOM mount",
                source: Box::new(raised(0x8004_0407)),
            }),
            DriverError::NotConnected
        ));

        let parked = DriverError::from(raised(0x8004_0408));
        assert!(matches!(parked, DriverError::Backend(_)));
        assert_eq!(
            parked.to_string(),
            "Failed to call method SlewToCoordinatesAsync: said the driver"
        );
    }

    #[test]
    fn context_prefixes_the_inner_failure() {
        let err = AscomError::Context {
            context: "Failed to set ASCOM dome Slaved",
            source: Box::new(AscomError::Invoke {
                dispatch: Dispatch::Put,
                member: "Slaved".to_string(),
                cause: "cause".to_string(),
                code: None,
            }),
        };
        assert_eq!(
            err.to_string(),
            "Failed to set ASCOM dome Slaved: Failed to set property Slaved: cause"
        );
    }
}
