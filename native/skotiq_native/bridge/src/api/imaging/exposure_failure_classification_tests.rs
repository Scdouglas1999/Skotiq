use super::classify_exposure_failure;
use crate::error::SkotiqError;
use crate::unified_device_ops::IMAGE_VALIDATION_FAILED_PREFIX;

/// Verbatim validation message from a ZWO ASI1600MM-Cool exposed in daylight:
/// the operator's exposure to fix, so it must classify as 422, not 500.
const SATURATED: &str = "Image is completely saturated (min value 65224 >= 65024) - significantly reduce exposure time or gain";

#[test]
fn validation_rejection_becomes_exposure_failed() {
    let err = classify_exposure_failure(
        "native:zwo:0",
        format!("{IMAGE_VALIDATION_FAILED_PREFIX}{SATURATED}"),
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
        // Near-miss: the marker must be a prefix, not a substring.
        "wrapped: Image validation failed: something",
    ] {
        match classify_exposure_failure("native:zwo:0", raw.to_string()) {
            SkotiqError::OperationFailed(msg) => assert_eq!(msg, raw),
            other => panic!("expected OperationFailed for {raw:?}, got {other:?}"),
        }
    }
}

/// DATE-OBS must be when the shutter OPENED.
///
/// It was sampled with `Utc::now()` while building the header, which runs
/// after readout, so every sequenced frame recorded a DATE-OBS late by
/// exactly its own EXPTIME -- measured live as a 30 s exposure starting
/// 14:04:37 and claiming 14:05:09. Photometry, occultation timing and
/// astrometry all read DATE-OBS as the start, so this silently shifted
/// every measurement by half to one exposure length.
#[test]
fn date_obs_is_the_exposure_start_not_the_readout_time() {
    use chrono::TimeZone;

    let started = chrono::Utc
        .with_ymd_and_hms(2026, 8, 1, 14, 4, 37)
        .single()
        .expect("valid instant");

    let mut ctx = skotiq_sequencer::scheduling::FrameContext::new_light(
        "session".to_string(),
        1,
        1,
        30.0,
        1,
    );
    ctx.exposure_started_at = Some(started);

    let header = crate::FitsWriteHeaderRich::from_frame_context(&ctx);

    assert_eq!(
        header.capture_timestamp, "2026-08-01T14:04:37",
        "DATE-OBS must be the start of the exposure"
    );
    assert!(
        !header.capture_timestamp.starts_with("2026-08-01T14:05"),
        "DATE-OBS must not be the readout time (start + EXPTIME)"
    );
}

/// A frame whose start time was never recorded must not silently claim the
/// current clock as its observation time without that being obvious.
#[test]
fn date_obs_without_a_recorded_start_falls_back_to_now() {
    let ctx = skotiq_sequencer::scheduling::FrameContext::new_light(
        "session".to_string(),
        1,
        1,
        5.0,
        1,
    );
    assert!(ctx.exposure_started_at.is_none());

    let header = crate::FitsWriteHeaderRich::from_frame_context(&ctx);
    let now = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%S").to_string();
    assert_eq!(
        header.capture_timestamp[..13],
        now[..13],
        "fallback should be the current hour, not an empty or sentinel value"
    );
}

#[test]
fn empty_validation_reason_still_classifies() {
    // `validation.errors.join("; ")` can only be empty if the error list was
    // empty, but the classifier must not depend on the reason being present.
    match classify_exposure_failure(
        "ascom:ASCOM.Simulator.Camera",
        IMAGE_VALIDATION_FAILED_PREFIX.to_string(),
    ) {
        SkotiqError::ExposureFailed { camera_id, reason } => {
            assert_eq!(camera_id, "ascom:ASCOM.Simulator.Camera");
            assert!(reason.is_empty());
        }
        other => panic!("expected ExposureFailed, got {other:?}"),
    }
}
