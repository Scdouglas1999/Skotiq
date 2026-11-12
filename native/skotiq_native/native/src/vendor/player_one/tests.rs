use super::*;

/// `max_adu` must be the RAW16 container ceiling, not the ADC range.
///
/// `(1 << bit_depth) - 1` is the ADC range and is 16x too small for a 12-bit
/// Player One (Mars/Neptune/Uranus/Ceres/
/// Artemis class). PlayerOneCamera.h:51 documents the delivered RAW16 sample
/// range as `[0, 65535]` while :137 documents `bitDepth` as the "ADC depth
/// of CMOS sensor" — two different quantities.
#[test]
pub(crate) fn raw16_container_max_adu_accounts_for_left_justification() {
    // 12-bit ADC (IMX462/IMX464/IMX294 class): 4095 << 4
    assert_eq!(raw16_container_max_adu(12), 65520);
    // 14-bit ADC: 16383 << 2
    assert_eq!(raw16_container_max_adu(14), 65532);
    // 10-bit ADC: 1023 << 6
    assert_eq!(raw16_container_max_adu(10), 65472);
    // A genuinely 16-bit ADC (IMX455/IMX571 class) needs no shift.
    assert_eq!(raw16_container_max_adu(16), 65535);
}

/// Whatever ceiling we publish must be a value a `u16` sample can actually
/// hold, and must land on the sample grid the ADC produces — a 12-bit ADC
/// left-justified into 16 bits can only emit multiples of 16.
#[test]
pub(crate) fn raw16_container_max_adu_is_a_reachable_u16_sample() {
    for bit_depth in 1..=16u32 {
        let max = raw16_container_max_adu(bit_depth);
        assert!(
            max <= u32::from(u16::MAX),
            "bit_depth {bit_depth} produced {max}, outside the u16 container"
        );
        let step = 1u32 << (16 - bit_depth.min(16));
        assert_eq!(
            max % step,
            0,
            "bit_depth {bit_depth}: {max} is not a multiple of the {step}-ADU sample step"
        );
    }
}

/// An unpopulated / nonsensical `bitDepth` must fall back to the container
/// ceiling, never to 0 — a 0 ceiling would tell every percent-of-full-scale
/// consumer that the camera cannot produce any signal at all, and a plain
/// `(1 << bit_depth) - 1` overflows for `bit_depth >= 32`.
#[test]
pub(crate) fn raw16_container_max_adu_unknown_bit_depth_falls_back_to_container() {
    assert_eq!(raw16_container_max_adu(0), 65535);
    assert_eq!(raw16_container_max_adu(32), 65535);
    assert_eq!(raw16_container_max_adu(u32::MAX), 65535);
}

/// The ceiling must agree with the pipeline's own saturation threshold.
///
/// `skotiq_imaging::fits` uses `saturation_threshold: 65024` documented
/// as "4064 << 4" — 99.2% of a left-justified 12-bit ceiling. That threshold
/// is unreachable under a `(1 << 12) - 1 = 4095` ceiling, which is what makes
/// flat calibration impossible.
#[test]
pub(crate) fn raw16_container_max_adu_agrees_with_pipeline_saturation_threshold() {
    const PIPELINE_SATURATION_THRESHOLD: u32 = 65024;
    let twelve_bit_ceiling = raw16_container_max_adu(12);
    assert!(
        PIPELINE_SATURATION_THRESHOLD < twelve_bit_ceiling,
        "12-bit ceiling {twelve_bit_ceiling} is below the pipeline saturation threshold"
    );
    // The formula this replaced published the ADC range, which can never
    // reach the threshold — so saturation was undetectable on a 12-bit ASI-
    // class sensor, and a 50% flat target was below the camera's bias floor.
    let old_adc_range_formula = |bits: u32| (1u32 << bits) - 1;
    assert!(old_adc_range_formula(12) < PIPELINE_SATURATION_THRESHOLD);
}

/// Before the camera answers or is set, nothing is known of its cooler: a
/// failed read-back then reports unknown, not off at an invented set-point.
#[test]
pub(crate) fn cooler_state_starts_unknown() {
    let cam = PlayerOneCamera::new(0);
    let snap = cam.core.cooler();
    assert_eq!((snap.enabled, snap.target_c), (None, None));
}

/// After a successful `set_cooler(true, target)` write, an immediate
/// `get_status` must surface `cooler_on == true` and the target temp.
///
/// We exercise the same code path the production `set_cooler` uses to
/// update `core.cooler` (after the SDK accepted the change) and the same
/// fallback path `get_status` uses when the SDK read-back is unavailable:
/// the cached cooler state is the floor, so a failed read-back can never
/// report the cooler as off.
#[test]
pub(crate) fn set_cooler_then_status_reports_enabled() {
    let cam = PlayerOneCamera::new(0);

    assert_eq!(cam.core.cooler().enabled, None);

    // Simulate the post-SDK-success update that `set_cooler` performs.
    cam.core.update_cooler(|cooler| {
        cooler.enabled = Some(true);
        cooler.target_c = Some(-10.0);
    });

    // Read back via the same path `get_status` uses when the SDK
    // read-back is unavailable.
    let snap = cam.core.cooler();
    assert_eq!(
        snap.enabled,
        Some(true),
        "cooler_on must reflect the last set_cooler call"
    );
    assert_eq!(snap.target_c, Some(-10.0));
}

/// Writing `set_cooler(false, ...)` must clear the enabled flag — the
/// dashboard cannot get stuck reporting "cooler on" after warm-up.
#[test]
pub(crate) fn set_cooler_then_disable_reports_off() {
    let cam = PlayerOneCamera::new(0);

    cam.core.update_cooler(|cooler| {
        cooler.enabled = Some(true);
        cooler.target_c = Some(-15.0);
    });
    assert_eq!(cam.core.cooler().enabled, Some(true));

    cam.core.update_cooler(|cooler| {
        cooler.enabled = Some(false);
        cooler.target_c = Some(20.0);
    });

    let snap = cam.core.cooler();
    assert_eq!(snap.enabled, Some(false));
    assert_eq!(snap.target_c, Some(20.0));
}

/// `POAConfigAttributes` is hand-transcribed from PlayerOneCamera.h, and the
/// SDK writes the real gain/offset bounds into `min_value`/`max_value`. A field
/// added or reordered here reads the wrong eight bytes as a control bound, so
/// the layout is pinned against the header's field order.
#[test]
pub(crate) fn poa_config_attributes_matches_the_sdk_layout() {
    use std::mem::{align_of, size_of};

    // POABool x3, then POAConfig and POAValueType (both C enums == c_int).
    assert_eq!(
        std::mem::offset_of!(POAConfigAttributes, is_support_auto),
        0
    );
    assert_eq!(std::mem::offset_of!(POAConfigAttributes, is_writable), 4);
    assert_eq!(std::mem::offset_of!(POAConfigAttributes, is_readable), 8);
    assert_eq!(std::mem::offset_of!(POAConfigAttributes, config_id), 12);
    assert_eq!(std::mem::offset_of!(POAConfigAttributes, value_type), 16);

    // The three POAConfigValue unions are 8-aligned, so the header's implicit
    // 4 bytes of padding after `value_type` must be reproduced.
    assert_eq!(align_of::<POAConfigValue>(), 8);
    assert_eq!(size_of::<POAConfigValue>(), 8);
    assert_eq!(std::mem::offset_of!(POAConfigAttributes, max_value), 24);
    assert_eq!(std::mem::offset_of!(POAConfigAttributes, min_value), 32);
    assert_eq!(std::mem::offset_of!(POAConfigAttributes, default_value), 40);

    // char szConfName[64], szDescription[128], reserved[64].
    assert_eq!(std::mem::offset_of!(POAConfigAttributes, conf_name), 48);
    assert_eq!(std::mem::offset_of!(POAConfigAttributes, description), 112);
    assert_eq!(std::mem::offset_of!(POAConfigAttributes, reserved), 240);
    assert_eq!(size_of::<POAConfigAttributes>(), 304);
}

/// `VAL_INT` is the discriminant the gain and offset controls report, and
/// `config_int_bounds` reads the union's int variant only after matching it.
#[test]
pub(crate) fn poa_value_type_discriminants_match_the_header() {
    assert_eq!(POAValueType::Int as i32, 0);
    assert_eq!(POAValueType::Float as i32, 1);
    assert_eq!(POAValueType::Bool as i32, 2);
}

fn subframe(start_x: u32, start_y: u32, width: u32, height: u32) -> SubFrame {
    SubFrame {
        start_x,
        start_y,
        width,
        height,
    }
}

/// POASetImageSize takes widths in multiples of 4 and heights in multiples of
/// 2; the ROI the driver asks for is already one the SDK keeps as it is.
#[test]
pub(crate) fn a_roi_is_cut_to_the_sizes_the_sdk_takes() {
    let roi = roi_for(Some(&subframe(3, 3, 101, 51)), 3096, 2080, false).unwrap();
    assert_eq!(
        roi,
        Roi {
            x: 3,
            y: 3,
            width: 100,
            height: 50
        }
    );
    // The binned full frame of a 6248 x 4176 sensor at bin 3.
    let full = roi_for(None, 6248 / 3, 4176 / 3, false).unwrap();
    assert_eq!(
        (full.x, full.y, full.width, full.height),
        (0, 0, 2080, 1392)
    );
}

/// A color ROI starting on an odd pixel would shift the frame's Bayer cell
/// away from the BAYERPAT the camera's pattern writes.
#[test]
pub(crate) fn a_color_roi_starts_on_an_even_pixel() {
    let roi = roi_for(Some(&subframe(5, 7, 64, 32)), 1920, 1080, true).unwrap();
    assert_eq!((roi.x, roi.y), (4, 6));
    let mono = roi_for(Some(&subframe(5, 7, 64, 32)), 1920, 1080, false).unwrap();
    assert_eq!((mono.x, mono.y), (5, 7));
}

#[test]
pub(crate) fn a_roi_outside_the_binned_sensor_is_refused() {
    for request in [
        subframe(1900, 0, 64, 32),
        subframe(0, 0, 2, 32),
        subframe(u32::MAX, 0, 64, 32),
    ] {
        assert!(
            matches!(
                roi_for(Some(&request), 1920, 1080, false),
                Err(DriverError::InvalidParameter(_))
            ),
            "{request:?}"
        );
    }
}
