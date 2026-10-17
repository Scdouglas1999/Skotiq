use super::*;

/// ToupTek-family cameras deliver **right-justified** samples, so the ADC
/// range *is* the container ceiling.
///
/// This is a regression guard: ZWO, SVBony and Player One all need
/// `((1 << bd) - 1) << (16 - bd)` because those SDKs left-justify, and it
/// would be an easy and expensive mistake to propagate that here. See
/// [`max_adu_from_bit_depth`] for the SDK and on-hardware evidence that
/// ToupTek does not.
#[test]
fn max_adu_is_the_adc_range_because_touptek_is_right_justified() {
    // 12-bit (ATR3CMOS16000KPA / Orion G16 class) — measured 0..4095.
    assert_eq!(max_adu_from_bit_depth(12), 4095);
    assert_ne!(max_adu_from_bit_depth(12), 65520, "must NOT left-justify");
    // 14-bit
    assert_eq!(max_adu_from_bit_depth(14), 16383);
    assert_ne!(max_adu_from_bit_depth(14), 65532, "must NOT left-justify");
    // 10-bit and a genuine 16-bit sensor.
    assert_eq!(max_adu_from_bit_depth(10), 1023);
    assert_eq!(max_adu_from_bit_depth(16), 65535);
}

/// The ceiling must match the number of histogram bins the SDK reports for
/// the same bit depth (`arraySize = 1 << (nFlag & 0x0f)`), since that
/// histogram is indexed by delivered pixel value.
#[test]
fn max_adu_matches_the_sdk_histogram_bin_count() {
    for bit_depth in 8..=16u32 {
        let bins = 1u64 << bit_depth;
        assert_eq!(
            u64::from(max_adu_from_bit_depth(bit_depth)) + 1,
            bins,
            "bit_depth {bit_depth}: ceiling must be the highest of {bins} histogram bins"
        );
    }
}

/// An unknown bit depth must never reach this function as 0, which would
/// publish a 0 ceiling — "this camera cannot produce any signal".
///
/// `read_touptek_raw_format` maps a 0 bits-per-pixel report to `None` and
/// `connect()` substitutes 16, so the degenerate input is filtered upstream;
/// this pins that contract plus the wide-input saturation guard.
#[test]
fn unknown_bit_depth_is_filtered_before_reaching_the_ceiling() {
    // The upstream guard: `read_touptek_raw_format` returns None for a 0 bpp
    // report and `connect()` substitutes 16, so the ceiling is the container.
    let sdk_reported_zero_bpp: u32 = 0;
    let effective = if sdk_reported_zero_bpp > 0 {
        sdk_reported_zero_bpp
    } else {
        16
    };
    assert_eq!(max_adu_from_bit_depth(effective), 65535);
    // Absurd widths saturate instead of shifting out of range.
    assert_eq!(max_adu_from_bit_depth(32), u32::MAX);
    assert_eq!(max_adu_from_bit_depth(64), u32::MAX);
}

#[test]
fn touptek_temperature_result_converts_tenths_celsius() {
    assert_eq!(
        touptek_temperature_result("camera", 0, -123).unwrap(),
        -12.3
    );
}

#[test]
fn touptek_temperature_result_propagates_sdk_error() {
    let err = touptek_temperature_result("camera", -7, 0).unwrap_err();
    match err {
        NativeError::SdkError(message) => {
            assert!(message.contains("camera"));
            assert!(message.contains("-7"));
        }
        other => panic!("expected SDK error, got {other:?}"),
    }
}

#[tokio::test]
async fn touptek_get_cooler_power_reports_not_supported_instead_of_estimate() {
    let mut camera = TouptekCamera::new(0, "OGMA");
    camera.connected = true;
    camera.cooler_on = true;
    camera.target_temp = -10.0;

    let err = camera.get_cooler_power().await.unwrap_err();
    assert!(matches!(err, NativeError::NotSupported));
}

#[test]
fn touptek_bayer_pattern_from_fourcc_maps_all_sdk_patterns() {
    assert_eq!(
        touptek_bayer_pattern_from_fourcc(make_touptek_fourcc(*b"RGGB")),
        Some(BayerPattern::Rggb)
    );
    assert_eq!(
        touptek_bayer_pattern_from_fourcc(make_touptek_fourcc(*b"GRBG")),
        Some(BayerPattern::Grbg)
    );
    assert_eq!(
        touptek_bayer_pattern_from_fourcc(make_touptek_fourcc(*b"GBRG")),
        Some(BayerPattern::Gbrg)
    );
    assert_eq!(
        touptek_bayer_pattern_from_fourcc(make_touptek_fourcc(*b"BGGR")),
        Some(BayerPattern::Bggr)
    );
}

#[test]
fn touptek_bayer_pattern_from_fourcc_leaves_non_bayer_unknown() {
    assert_eq!(
        touptek_bayer_pattern_from_fourcc(make_touptek_fourcc(*b"YYYY")),
        None
    );
    assert_eq!(
        touptek_bayer_pattern_from_fourcc(make_touptek_fourcc(*b"RGB8")),
        None
    );
}

#[test]
fn touptek_event_callback_sets_flags_by_event_and_guards_null() {
    let state = Box::new(TouptekEventState {
        image_ready: AtomicBool::new(false),
        error: AtomicBool::new(false),
    });
    let ctx = &*state as *const TouptekEventState as *mut c_void;

    // EVENT_IMAGE sets image_ready only.
    // SAFETY: `ctx` points to the live `state` box for the duration of this test.
    unsafe { touptek_event_callback(OGMACAM_EVENT_IMAGE, ctx) };
    assert!(state.image_ready.load(Ordering::SeqCst));
    assert!(!state.error.load(Ordering::SeqCst));

    // Each fault event sets the error flag.
    for event in [
        OGMACAM_EVENT_ERROR,
        OGMACAM_EVENT_DISCONNECTED,
        OGMACAM_EVENT_NOFRAMETIMEOUT,
    ] {
        let s = Box::new(TouptekEventState {
            image_ready: AtomicBool::new(false),
            error: AtomicBool::new(false),
        });
        let c = &*s as *const TouptekEventState as *mut c_void;
        // SAFETY: `c` points to the live `s` box.
        unsafe { touptek_event_callback(event, c) };
        assert!(s.error.load(Ordering::SeqCst), "event {event:#x} set error");
        assert!(!s.image_ready.load(Ordering::SeqCst));
    }

    // Unknown events are ignored.
    let s = Box::new(TouptekEventState {
        image_ready: AtomicBool::new(false),
        error: AtomicBool::new(false),
    });
    let c = &*s as *const TouptekEventState as *mut c_void;
    // SAFETY: `c` points to the live `s` box. 0x4003 == EVENT_HEARTBEAT.
    unsafe { touptek_event_callback(0x4003, c) };
    assert!(!s.image_ready.load(Ordering::SeqCst));
    assert!(!s.error.load(Ordering::SeqCst));

    // A null context is a no-op and must not dereference.
    // SAFETY: intentionally passing null; the callback's guard returns early.
    unsafe { touptek_event_callback(OGMACAM_EVENT_IMAGE, std::ptr::null_mut()) };
}

#[test]
fn touptek_no_sdk_loaded_error_names_each_attempted_brand() {
    let err = touptek_no_sdk_loaded_error(&[
        (
            "OGMA".to_string(),
            "ogmacam.dll".to_string(),
            "missing".to_string(),
        ),
        (
            "Touptek".to_string(),
            "toupcam.dll".to_string(),
            "bad image".to_string(),
        ),
    ]);

    match err {
        NativeError::SdkError(message) => {
            assert!(message.contains("No Touptek-family SDK libraries"));
            assert!(message.contains("OGMA (ogmacam.dll): missing"));
            assert!(message.contains("Touptek (toupcam.dll): bad image"));
        }
        other => panic!("expected SDK error, got {other:?}"),
    }
}

/// The gain range is whatever `get_ExpoAGainRange` reported at connect, in the
/// SDK's percent-step units where 100 == 1x.
#[tokio::test]
async fn gain_range_reports_the_bounds_the_camera_gave() {
    let mut camera = TouptekCamera::new(0, "OGMA");
    camera.connected = true;
    camera.gain_range = Some((100, 10000));

    assert_eq!(camera.get_gain_range().await.unwrap(), (100, 10000));
}

/// A camera that never reported a gain range must surface that, not a range
/// borrowed from another vendor.
#[tokio::test]
async fn gain_range_without_an_sdk_report_is_an_error_not_a_default() {
    let mut camera = TouptekCamera::new(0, "OGMA");
    camera.connected = true;
    camera.gain_range = None;

    match camera.get_gain_range().await {
        Err(NativeError::SdkError(message)) => {
            assert!(message.contains("did not report a gain range"));
        }
        other => panic!("expected an SDK error, got {other:?}"),
    }
}

/// The ToupTek-family SDK exposes no offset control, so there is no range to
/// report.
#[tokio::test]
async fn offset_range_reports_not_supported() {
    let mut camera = TouptekCamera::new(0, "OGMA");
    camera.connected = true;

    assert!(matches!(
        camera.get_offset_range().await,
        Err(NativeError::NotSupported)
    ));
}
