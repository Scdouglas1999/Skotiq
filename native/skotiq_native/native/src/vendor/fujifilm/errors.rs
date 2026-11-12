//! What a failed X SDK call means for the caller and the person at the
//! telescope. Error codes from XAPI.h (`XSDK_GetErrorNumber`).

use skotiq_device::DriverError;

pub(crate) const XSDK_ERRCODE_NOERR: i32 = 0x0000_0000;
pub(crate) const XSDK_ERRCODE_SEQUENCE: i32 = 0x0000_1001;
pub(crate) const XSDK_ERRCODE_PARAM: i32 = 0x0000_1002;
pub(crate) const XSDK_ERRCODE_INVALID_CAMERA: i32 = 0x0000_1003;
pub(crate) const XSDK_ERRCODE_LOADLIB: i32 = 0x0000_1004;
pub(crate) const XSDK_ERRCODE_UNSUPPORTED: i32 = 0x0000_1005;
pub(crate) const XSDK_ERRCODE_BUSY: i32 = 0x0000_1006;
pub(crate) const XSDK_ERRCODE_AF_TIMEOUT: i32 = 0x0000_1007;
pub(crate) const XSDK_ERRCODE_SHOOT_ERROR: i32 = 0x0000_1008;
pub(crate) const XSDK_ERRCODE_FRAME_FULL: i32 = 0x0000_1009;
pub(crate) const XSDK_ERRCODE_STANDBY: i32 = 0x0000_1010;
pub(crate) const XSDK_ERRCODE_NODRIVER: i32 = 0x0000_1011;
pub(crate) const XSDK_ERRCODE_NO_MODEL_MODULE: i32 = 0x0000_1012;
pub(crate) const XSDK_ERRCODE_API_NOTFOUND: i32 = 0x0000_1013;
pub(crate) const XSDK_ERRCODE_API_MISMATCH: i32 = 0x0000_1014;
pub(crate) const XSDK_ERRCODE_INVALID_USBMODE: i32 = 0x0000_1015;
pub(crate) const XSDK_ERRCODE_FORCEMODE_BUSY: i32 = 0x0000_1016;
pub(crate) const XSDK_ERRCODE_RUNNING_OTHER_FUNCTION: i32 = 0x0000_1017;
pub(crate) const XSDK_ERRCODE_COMMUNICATION: i32 = 0x0000_2001;
pub(crate) const XSDK_ERRCODE_TIMEOUT: i32 = 0x0000_2002;
pub(crate) const XSDK_ERRCODE_COMBINATION: i32 = 0x0000_2003;
pub(crate) const XSDK_ERRCODE_WRITEERROR: i32 = 0x0000_2004;
pub(crate) const XSDK_ERRCODE_CARDFULL: i32 = 0x0000_2005;
pub(crate) const XSDK_ERRCODE_HARDWARE: i32 = 0x0000_3001;
pub(crate) const XSDK_ERRCODE_INTERNAL: i32 = 0x0000_9001;
pub(crate) const XSDK_ERRCODE_MEMFULL: i32 = 0x0000_9002;
pub(crate) const XSDK_ERRCODE_UNKNOWN: i32 = 0x0000_9100;

/// The SDK documents these as states that clear once the camera finishes what
/// it is doing, so a call that failed with one is worth repeating.
pub(crate) fn is_busy(err_code: i32) -> bool {
    matches!(
        err_code,
        XSDK_ERRCODE_BUSY | XSDK_ERRCODE_FORCEMODE_BUSY | XSDK_ERRCODE_RUNNING_OTHER_FUNCTION
    )
}

/// The error for an SDK call that did not return `XSDK_COMPLETE`. `action`
/// says what the driver was doing ("setting the shutter speed"). A failed call
/// is an error even when the SDK has no error number for it.
pub(crate) fn sdk_failure(action: &str, api_code: i32, err_code: i32) -> DriverError {
    let say = |what: &str| format!("Fujifilm camera: {action} failed: {what}");
    match err_code {
        XSDK_ERRCODE_INVALID_CAMERA => DriverError::NotConnected,
        XSDK_ERRCODE_COMMUNICATION => DriverError::Disconnected,
        XSDK_ERRCODE_UNSUPPORTED | XSDK_ERRCODE_API_NOTFOUND => DriverError::NotSupported,
        XSDK_ERRCODE_PARAM => DriverError::InvalidParameter(say("the camera rejected the value")),
        XSDK_ERRCODE_COMBINATION => DriverError::InvalidParameter(say(
            "the camera refused it in its current mode. Set the exposure mode to M, the \
             shutter speed dial to T and the ISO dial to a fixed value (not A)",
        )),
        XSDK_ERRCODE_TIMEOUT => DriverError::Timeout(say("the camera did not answer")),
        XSDK_ERRCODE_AF_TIMEOUT => DriverError::Timeout(say(
            "autofocus did not finish. Set the focus mode switch to M",
        )),
        code => DriverError::SdkError(say(&match code {
            XSDK_ERRCODE_NOERR => format!("the SDK gave no reason (API 0x{api_code:04X})"),
            XSDK_ERRCODE_SEQUENCE => "the camera was not ready for this command".to_string(),
            c if is_busy(c) => "the camera is busy".to_string(),
            XSDK_ERRCODE_SHOOT_ERROR => "the camera could not take the picture".to_string(),
            XSDK_ERRCODE_FRAME_FULL => "the camera's image buffer is full".to_string(),
            XSDK_ERRCODE_STANDBY => {
                "the camera is in standby. Wake it, and turn off its auto power off".to_string()
            }
            XSDK_ERRCODE_NODRIVER | XSDK_ERRCODE_LOADLIB => {
                "a Fujifilm SDK library could not be loaded. Reinstall Skotiq".to_string()
            }
            XSDK_ERRCODE_NO_MODEL_MODULE => {
                "the SDK has no module for this camera model (FF####API.dll)".to_string()
            }
            XSDK_ERRCODE_API_MISMATCH => {
                "the camera firmware does not match the SDK. Update the camera firmware".to_string()
            }
            XSDK_ERRCODE_INVALID_USBMODE => {
                "the camera is not in tethered shooting mode. Set its PC CONNECTION MODE to \
                 USB TETHER SHOOTING AUTO"
                    .to_string()
            }
            XSDK_ERRCODE_WRITEERROR => "the camera could not write to its memory card".to_string(),
            XSDK_ERRCODE_CARDFULL => "the camera's memory card is full".to_string(),
            XSDK_ERRCODE_HARDWARE => "the camera reported a hardware fault".to_string(),
            XSDK_ERRCODE_INTERNAL | XSDK_ERRCODE_MEMFULL | XSDK_ERRCODE_UNKNOWN => {
                format!("internal SDK error 0x{code:04X}")
            }
            other => format!("SDK error 0x{other:04X} (API 0x{api_code:04X})"),
        })),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_failed_call_without_an_error_number_is_still_an_error() {
        let error = sdk_failure("starting the exposure", 0x0201, XSDK_ERRCODE_NOERR);
        assert!(
            matches!(&error, DriverError::SdkError(m) if m.contains("starting the exposure")),
            "{error:?}"
        );
    }

    #[test]
    fn a_usb_communication_failure_reads_as_a_disconnect() {
        assert!(matches!(
            sdk_failure("reading the image", 0, XSDK_ERRCODE_COMMUNICATION),
            DriverError::Disconnected
        ));
        assert!(matches!(
            sdk_failure("reading the image", 0, XSDK_ERRCODE_INVALID_CAMERA),
            DriverError::NotConnected
        ));
    }

    #[test]
    fn settings_the_camera_refuses_say_how_to_set_the_dials() {
        let error = sdk_failure("setting the shutter speed", 0, XSDK_ERRCODE_COMBINATION);
        assert!(
            matches!(&error, DriverError::InvalidParameter(m) if m.contains("dial to T")),
            "{error:?}"
        );
        let error = sdk_failure("connecting", 0, XSDK_ERRCODE_INVALID_USBMODE);
        assert!(
            error.to_string().contains("USB TETHER SHOOTING AUTO"),
            "{error}"
        );
    }

    #[test]
    fn the_three_documented_busy_states_are_retried() {
        assert!(is_busy(XSDK_ERRCODE_BUSY));
        assert!(is_busy(XSDK_ERRCODE_FORCEMODE_BUSY));
        assert!(is_busy(XSDK_ERRCODE_RUNNING_OTHER_FUNCTION));
        assert!(!is_busy(XSDK_ERRCODE_COMBINATION));
    }

    #[test]
    fn the_error_numbers_match_xapi_h() {
        assert_eq!(XSDK_ERRCODE_SEQUENCE, 0x1001);
        assert_eq!(XSDK_ERRCODE_AF_TIMEOUT, 0x1007);
        assert_eq!(XSDK_ERRCODE_FORCEMODE_BUSY, 0x1016);
        assert_eq!(XSDK_ERRCODE_RUNNING_OTHER_FUNCTION, 0x1017);
        assert_eq!(XSDK_ERRCODE_COMMUNICATION, 0x2001);
        assert_eq!(XSDK_ERRCODE_COMBINATION, 0x2003);
        assert_eq!(XSDK_ERRCODE_CARDFULL, 0x2005);
        assert_eq!(XSDK_ERRCODE_UNKNOWN, 0x9100);
    }
}
