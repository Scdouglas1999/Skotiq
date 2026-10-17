use super::*;

/// A 16-bit transfer of a sub-16-bit ADC must publish the left-justified
/// container ceiling, because the QHY SDK zero-pads the *low* bits.
#[test]
fn container_max_adu_accounts_for_low_zero_padding() {
    // 12-bit ADC (QHY183/QHY294 class) in 16-bit transfer: 4095 << 4
    assert_eq!(container_max_adu(16, Some(12), true), 65520);
    // 14-bit ADC: 16383 << 2
    assert_eq!(container_max_adu(16, Some(14), true), 65532);
    // 10-bit ADC: 1023 << 6
    assert_eq!(container_max_adu(16, Some(10), true), 65472);
    // A genuinely 16-bit ADC (QHY268/QHY600 class) needs no shift.
    assert_eq!(container_max_adu(16, Some(16), true), 65535);
}

/// Whatever ceiling we publish must fit the container and land on the sample
/// grid the ADC produces — a 12-bit ADC left-justified into 16 bits can only
/// emit multiples of 16.
#[test]
fn container_max_adu_is_a_reachable_sample() {
    for actual_bits in 1..=16u32 {
        let max = container_max_adu(16, Some(actual_bits), true);
        assert!(
            max <= u32::from(u16::MAX),
            "actual_bits {actual_bits} produced {max}, outside the 16-bit container"
        );
        let step = 1u32 << (16 - actual_bits);
        assert_eq!(
            max % step,
            0,
            "actual_bits {actual_bits}: {max} is not a multiple of the {step}-ADU sample step"
        );
    }
}

/// When `OutputDataAlignment` reports low alignment (return value 0), the
/// ADC range *is* the reachable ceiling and must not be shifted.
#[test]
fn container_max_adu_honours_low_alignment() {
    assert_eq!(container_max_adu(16, Some(12), false), 4095);
    assert_eq!(container_max_adu(16, Some(14), false), 16383);
    assert_eq!(container_max_adu(16, Some(16), false), 65535);
}

/// An unavailable `OutputDataActualBits` query must fall back to the
/// container ceiling, never to 0 — a 0 ceiling would tell every
/// percent-of-full-scale consumer the camera cannot produce any signal.
#[test]
fn container_max_adu_unknown_precision_falls_back_to_container() {
    assert_eq!(container_max_adu(16, None, true), 65535);
    assert_eq!(container_max_adu(16, None, false), 65535);
    // A reported precision at least as wide as the container is also a
    // no-op, and an out-of-range one must not shift by a negative amount.
    assert_eq!(container_max_adu(16, Some(0), true), 65535);
    assert_eq!(container_max_adu(16, Some(32), true), 65535);
}

/// The 8-bit transfer mode is a genuine byte container: the SDK takes the
/// high bits, so the ceiling is 255 regardless of ADC precision. Publishing
/// the 16-bit ceiling there would overstate a frame 257x.
#[test]
fn container_max_adu_eight_bit_transfer_is_a_byte_container() {
    assert_eq!(container_max_adu(8, Some(12), true), 255);
    assert_eq!(container_max_adu(8, None, true), 255);
}

/// An unpopulated GetQHYCCDChipInfo `bpp` (0) must not be read as a 1-bit
/// sensor — a ceiling of 1 is the same "camera cannot produce any signal"
/// failure as a ceiling of 0.
#[test]
fn container_max_adu_unpopulated_container_width_falls_back_to_sixteen() {
    assert_eq!(container_max_adu(0, None, true), 65535);
    assert_eq!(container_max_adu(0, Some(12), true), 65520);
    assert_eq!(container_max_adu(99, None, true), 65535);
}

/// A fresh camera must assume the 16-bit container it is about to negotiate,
/// with unknown ADC precision and the SDK-documented high alignment — i.e.
/// the full container ceiling, never 0.
#[test]
fn new_camera_publishes_the_container_ceiling_before_probing() {
    let cam = QhyCamera::new("test".to_string());
    assert_eq!(cam.output_container_bits, 16);
    assert_eq!(cam.actual_output_bits, None);
    assert!(cam.output_high_aligned);
    assert_eq!(
        container_max_adu(
            cam.output_container_bits,
            cam.actual_output_bits,
            cam.output_high_aligned
        ),
        65535
    );
}

/// The ceiling must agree with the pipeline's own saturation threshold
/// (`skotiq_imaging::fits` uses 65024, documented as "4064 << 4").
#[test]
fn container_max_adu_agrees_with_pipeline_saturation_threshold() {
    const PIPELINE_SATURATION_THRESHOLD: u32 = 65024;
    let twelve_bit_ceiling = container_max_adu(16, Some(12), true);
    assert!(
        PIPELINE_SATURATION_THRESHOLD < twelve_bit_ceiling,
        "12-bit ceiling {twelve_bit_ceiling} is below the pipeline saturation threshold"
    );
    // The ADC range alone can never reach the threshold, so a driver that
    // published it would make saturation undetectable on a 12-bit QHY.
    let adc_range_only = |bits: u32| (1u32 << bits) - 1;
    assert!(adc_range_only(12) < PIPELINE_SATURATION_THRESHOLD);
}

/// get_status must reflect the locally-tracked cooler state
/// after a successful set_cooler, not hardcode `cooler_on: false`.
///
/// The QHY SDK is not loaded in unit tests, so we cannot drive set_cooler
/// end-to-end through the SDK call path. Instead we exercise the read
/// side directly: mutate the tracked fields the same way set_cooler does
/// after a successful SDK round-trip, then assert get_status surfaces them.
#[tokio::test]
async fn get_status_reflects_tracked_cooler_state() {
    let mut cam = QhyCamera::new("TEST-COOLER".to_string());
    // Pretend connect/load_camera_info already succeeded.
    cam.connected = true;
    cam.has_cooler = true;

    // Baseline: never-set cooler is reported as off.
    let status = cam.get_status().await.expect("get_status should succeed");
    assert!(!status.cooler_on, "default cooler_on must be false");
    assert_eq!(status.target_temp, None, "default target_temp must be None");

    // Simulate a successful set_cooler(true, -10.0) commit.
    cam.cooler_on = true;
    cam.cooler_target_c = Some(-10.0);

    let status = cam.get_status().await.expect("get_status should succeed");
    assert!(
        status.cooler_on,
        "get_status must reflect tracked cooler_on=true"
    );
    assert_eq!(
        status.target_temp,
        Some(-10.0),
        "get_status must reflect tracked target temperature"
    );

    // Simulate a successful set_cooler(false, _) commit.
    cam.cooler_on = false;
    cam.cooler_target_c = None;

    let status = cam.get_status().await.expect("get_status should succeed");
    assert!(!status.cooler_on, "get_status must reflect cooler_on=false");
    assert_eq!(status.target_temp, None);
}

/// "no silent fallbacks": if the SDK call inside
/// set_cooler fails, the tracked state must NOT advance — otherwise the
/// dashboard would lie that the cooler is on while the hardware is cold-off.
#[tokio::test]
async fn set_cooler_propagates_sdk_failure_without_mutating_state() {
    let mut cam = QhyCamera::new("TEST-NO-SDK".to_string());
    cam.connected = true;
    cam.has_cooler = true;
    // handle is None and the QHY SDK is not loaded in tests, so
    // set_control_async fails at QhySdk::get() with SdkNotLoaded.

    let result = cam.set_cooler(true, Some(-15.0)).await;
    assert!(
        result.is_err(),
        "set_cooler must propagate SDK errors, not swallow them"
    );

    // State must not have advanced.
    assert!(
        !cam.cooler_on,
        "cooler_on must remain false after a failed set_cooler"
    );
    assert_eq!(
        cam.cooler_target_c, None,
        "cooler_target_c must remain unset after a failed set_cooler"
    );
}

/// Guard rail: set_cooler on a disconnected camera must return
/// NotConnected and leave tracked state alone.
#[tokio::test]
async fn set_cooler_rejects_disconnected_camera() {
    let mut cam = QhyCamera::new("TEST-DISCONNECTED".to_string());
    // connected stays false.

    let result = cam.set_cooler(true, Some(-10.0)).await;
    assert!(matches!(result, Err(NativeError::NotConnected)));
    assert!(!cam.cooler_on);
    assert_eq!(cam.cooler_target_c, None);
}

/// Guard rail: set_cooler on a camera without a cooler must return
/// NotSupported and leave tracked state alone.
#[tokio::test]
async fn set_cooler_rejects_camera_without_cooler() {
    let mut cam = QhyCamera::new("TEST-NO-COOLER".to_string());
    cam.connected = true;
    // has_cooler stays false (e.g. a non-cooled QHY model).

    let result = cam.set_cooler(true, Some(-10.0)).await;
    assert!(matches!(result, Err(NativeError::NotSupported)));
    assert!(!cam.cooler_on);
    assert_eq!(cam.cooler_target_c, None);
}
