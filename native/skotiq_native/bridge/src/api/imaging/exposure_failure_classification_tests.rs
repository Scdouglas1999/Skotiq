use super::classify_exposure_failure;
use crate::error::SkotiqError;
use skotiq_sequencer::DeviceError;

/// Verbatim validation message from a ZWO ASI1600MM-Cool exposed in daylight:
/// the operator's exposure to fix, so it must classify as 422, not 500.
const SATURATED: &str = "Image is completely saturated (min value 65224 >= 65024) - significantly reduce exposure time or gain";

#[test]
fn validation_rejection_becomes_exposure_failed() {
    let err = classify_exposure_failure(
        "native:zwo:0",
        DeviceError::InvalidFrame(SATURATED.to_string()),
    );

    match err {
        SkotiqError::ExposureFailed { camera_id, reason } => {
            assert_eq!(camera_id, "native:zwo:0");
            // The actionable reason must survive intact — it is what the
            // operator reads to know what to change.
            assert_eq!(reason, SATURATED);
        }
        other => panic!("expected ExposureFailed, got {other:?}"),
    }
}

#[test]
fn driver_faults_stay_operation_failed() {
    // Anything that is not a validation rejection must keep mapping to
    // OperationFailed so real faults still answer HTTP 500.
    for raw in [
        "SDK error: Failed to call method StartExposure",
        "Device not connected: native:zwo:0",
        "Exposure cancelled",
        // Near-miss: a driver's text that reads like a validation rejection
        // is still a driver fault.
        "wrapped: Image validation failed: something",
        "Image validation failed: something",
    ] {
        match classify_exposure_failure("native:zwo:0", DeviceError::from(raw)) {
            SkotiqError::OperationFailed(msg) => assert_eq!(msg, raw),
            other => panic!("expected OperationFailed for {raw:?}, got {other:?}"),
        }
    }
}

#[test]
fn empty_validation_reason_still_classifies() {
    // `validation.errors.join("; ")` can only be empty if the error list was
    // empty, but the classifier must not depend on the reason being present.
    match classify_exposure_failure(
        "ascom:ASCOM.Simulator.Camera",
        DeviceError::InvalidFrame(String::new()),
    ) {
        SkotiqError::ExposureFailed { camera_id, reason } => {
            assert_eq!(camera_id, "ascom:ASCOM.Simulator.Camera");
            assert!(reason.is_empty());
        }
        other => panic!("expected ExposureFailed, got {other:?}"),
    }
}
