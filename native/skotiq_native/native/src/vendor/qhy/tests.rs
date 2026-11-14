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
    let info = QhyCamera::new("test".to_string()).get_sensor_info();
    assert_eq!(info.max_adu, 65535);
    assert_eq!(info.bit_depth, 16);
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

/// "no silent fallbacks": if the SDK call inside
/// set_cooler fails, the tracked state must NOT advance — otherwise the
/// dashboard would lie that the cooler is on while the hardware is cold-off.
#[tokio::test]
async fn set_cooler_propagates_sdk_failure_without_mutating_state() {
    let mut cam = QhyCamera::new("TEST-NO-SDK".to_string());
    cam.core.connected = true;
    cam.core.capabilities.can_cool = true;
    // handle is None and the QHY SDK is not loaded in tests, so
    // set_control_async fails at QhySdk::lock() with SdkNotInstalled.

    let result = cam.set_cooler(true, Some(-15.0)).await;
    assert!(
        result.is_err(),
        "set_cooler must propagate SDK errors, not swallow them"
    );

    // State must not have advanced.
    assert_eq!(
        cam.core.cooler(),
        crate::camera_core::CoolerState::UNKNOWN,
        "the cooler must stay unknown after a failed set_cooler"
    );
}

/// Guard rail: set_cooler on a disconnected camera must return
/// NotConnected and leave tracked state alone.
#[tokio::test]
async fn set_cooler_rejects_disconnected_camera() {
    let mut cam = QhyCamera::new("TEST-DISCONNECTED".to_string());
    // connected stays false.

    let result = cam.set_cooler(true, Some(-10.0)).await;
    assert!(matches!(result, Err(DriverError::NotConnected)));
    assert_eq!(cam.core.cooler(), crate::camera_core::CoolerState::UNKNOWN);
}

/// Guard rail: set_cooler on a camera without a cooler must return
/// NotSupported and leave tracked state alone.
#[tokio::test]
async fn set_cooler_rejects_camera_without_cooler() {
    let mut cam = QhyCamera::new("TEST-NO-COOLER".to_string());
    cam.core.connected = true;
    // has_cooler stays false (e.g. a non-cooled QHY model).

    let result = cam.set_cooler(true, Some(-10.0)).await;
    assert!(matches!(result, Err(DriverError::NotSupported)));
    assert_eq!(cam.core.cooler(), crate::camera_core::CoolerState::UNKNOWN);
}

#[test]
fn bayer_ids_are_named_as_indi_and_nina_name_them() {
    assert_eq!(bayer_from_id(1), Some(BayerPattern::Gbrg));
    assert_eq!(bayer_from_id(2), Some(BayerPattern::Grbg));
    assert_eq!(bayer_from_id(3), Some(BayerPattern::Bggr));
    assert_eq!(bayer_from_id(4), Some(BayerPattern::Rggb));
    assert_eq!(bayer_from_id(0), None);
    assert_eq!(bayer_from_id(QHYCCD_ERROR), None);
}

#[test]
fn a_window_moved_by_an_odd_pixel_sees_the_neighbouring_pattern() {
    use BayerPattern::*;
    for pattern in [Rggb, Grbg, Gbrg, Bggr] {
        assert_eq!(shifted_bayer(pattern, 0, 0), pattern);
        assert_eq!(shifted_bayer(pattern, 2, 4), pattern);
        assert_eq!(shifted_bayer(shifted_bayer(pattern, 1, 0), 1, 0), pattern);
        assert_eq!(shifted_bayer(shifted_bayer(pattern, 0, 1), 0, 1), pattern);
    }
    assert_eq!(shifted_bayer(Rggb, 1, 0), Grbg);
    assert_eq!(shifted_bayer(Rggb, 0, 1), Gbrg);
    assert_eq!(shifted_bayer(Rggb, 1, 1), Bggr);
    assert_eq!(shifted_bayer(Gbrg, 1, 0), Bggr);
    assert_eq!(shifted_bayer(Gbrg, 0, 1), Rggb);
}

#[test]
fn only_unbinned_color_frames_carry_a_pattern() {
    let sub = SubFrame {
        start_x: 3,
        start_y: 0,
        width: 10,
        height: 10,
    };
    assert_eq!(
        frame_bayer(Some(BayerPattern::Rggb), 1, None),
        Some(BayerPattern::Rggb)
    );
    assert_eq!(
        frame_bayer(Some(BayerPattern::Rggb), 1, Some(&sub)),
        Some(BayerPattern::Grbg)
    );
    assert_eq!(frame_bayer(Some(BayerPattern::Rggb), 2, None), None);
    assert_eq!(frame_bayer(None, 1, Some(&sub)), None);
}

fn area(x: u32, y: u32, width: u32, height: u32) -> Area {
    Area {
        x,
        y,
        width,
        height,
    }
}

#[test]
fn the_imaging_area_is_the_effective_area_when_it_fits_the_chip() {
    let chip = area(0, 0, 80, 60);
    assert_eq!(
        imaging_area(chip, Some(area(4, 2, 72, 56))),
        area(4, 2, 72, 56)
    );
    assert_eq!(imaging_area(chip, None), chip);
    assert_eq!(imaging_area(chip, Some(area(0, 0, 0, 0))), chip);
    assert_eq!(imaging_area(chip, Some(area(10, 0, 80, 60))), chip);
}

#[test]
fn readout_windows_are_binned_and_placed_in_the_imaging_area() {
    let imaging = area(4, 2, 72, 56);
    assert_eq!(readout_window(imaging, 1, None).unwrap(), imaging);
    assert_eq!(
        readout_window(imaging, 2, None).unwrap(),
        area(2, 1, 36, 28)
    );
    let sub = SubFrame {
        start_x: 10,
        start_y: 6,
        width: 20,
        height: 12,
    };
    assert_eq!(
        readout_window(imaging, 1, Some(&sub)).unwrap(),
        area(14, 8, 20, 12)
    );
    assert_eq!(
        readout_window(imaging, 2, Some(&sub)).unwrap(),
        area(12, 7, 20, 12)
    );
    let too_wide = SubFrame {
        start_x: 30,
        start_y: 0,
        width: 10,
        height: 10,
    };
    assert!(matches!(
        readout_window(imaging, 2, Some(&too_wide)),
        Err(DriverError::InvalidParameter(_))
    ));
    assert!(readout_window(imaging, 0, None).is_err());
}

#[test]
fn cooler_power_is_a_percentage_of_full_drive() {
    assert_eq!(cooler_percent(255.0, 255.0), Some(100.0));
    assert_eq!(cooler_percent(51.0, 255.0), Some(20.0));
    assert_eq!(cooler_percent(0.0, 255.0), Some(0.0));
    assert_eq!(cooler_percent(300.0, 255.0), None);
    assert_eq!(cooler_percent(QHYCCD_ERROR_VALUE, 255.0), None);
}

#[test]
fn the_sdk_error_value_is_no_reading() {
    assert_eq!(param_value(QHYCCD_ERROR_VALUE), None);
    assert_eq!(param_value(f64::NAN), None);
    assert_eq!(param_value(-9.25), Some(-9.25));
    assert_eq!(param_value(0.0), Some(0.0));
}

#[test]
fn only_the_codes_qhyccderr_defines_are_named() {
    assert!(check_qhy_error(QHYCCD_SUCCESS, "x").is_ok());
    assert!(matches!(
        check_qhy_error(QHYCCD_ERROR_DEVICELOSE, "x"),
        Err(DriverError::Disconnected)
    ));
    match check_qhy_error(QHYCCD_ERROR, "set the gain to 9") {
        Err(DriverError::SdkError(text)) => assert!(text.contains("did not set the gain to 9")),
        other => panic!("{other:?}"),
    }
    // 4 is QHYCCD_COLOR, a capability answer, not "disconnected".
    assert!(matches!(
        check_qhy_error(4, "x"),
        Err(DriverError::SdkError(_))
    ));
}

#[test]
fn ranges_the_camera_reports_are_enforced() {
    assert!(check_range(55.0, Some((0.0, 100.0)), "gain", |v| v.to_string()).is_ok());
    assert!(check_range(100.0, Some((0.0, 100.0)), "gain", |v| v.to_string()).is_ok());
    assert!(matches!(
        check_range(150.0, Some((0.0, 100.0)), "gain", |v| v.to_string()),
        Err(DriverError::InvalidParameter(_))
    ));
    assert!(check_range(1e12, None, "gain", |v| v.to_string()).is_ok());
}

#[test]
fn a_wheel_needs_one_to_sixteen_slots() {
    assert_eq!(parse_cfw_slot_count(7.0), Some(7));
    assert_eq!(parse_cfw_slot_count(16.0), Some(16));
    assert_eq!(parse_cfw_slot_count(255.0), None);
    assert_eq!(parse_cfw_slot_count(0.0), None);
    assert_eq!(parse_cfw_slot_count(QHYCCD_ERROR_VALUE), None);
    assert_eq!(parse_cfw_slot_count(6.5), None);
}

#[test]
fn wheel_status_characters_are_slots_or_still_turning() {
    assert_eq!(parse_cfw_position(f64::from(b'0')), Some(0));
    assert_eq!(parse_cfw_position(f64::from(b'9')), Some(9));
    assert_eq!(parse_cfw_position(f64::from(b'A')), Some(10));
    assert_eq!(parse_cfw_position(f64::from(b'f')), Some(15));
    assert_eq!(parse_cfw_position(f64::from(b'N')), None);
    assert_eq!(parse_cfw_position(QHYCCD_ERROR_VALUE), None);
    for slot in 0..16 {
        assert_eq!(parse_cfw_position(encode_cfw_position(slot)), Some(slot));
    }
}
