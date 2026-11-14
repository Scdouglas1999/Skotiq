use super::*;

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
    let roi = roi_for(Some(&subframe(3, 3, 101, 51)), 3096, 2080).unwrap();
    assert_eq!(
        roi,
        Roi {
            x: 2,
            y: 2,
            width: 100,
            height: 50
        }
    );
    // The binned full frame of a 6248 x 4176 sensor at bin 3.
    let full = roi_for(None, 6248 / 3, 4176 / 3).unwrap();
    assert_eq!(
        (full.x, full.y, full.width, full.height),
        (0, 0, 2080, 1392)
    );
}

/// SDK 3.10.1 makes every start even (POACamera::SetImgStartPixel), mono
/// sensors included, and a color ROI on an odd pixel would shift the frame's
/// Bayer cell away from the BAYERPAT the camera's pattern writes.
#[test]
pub(crate) fn a_roi_starts_on_an_even_pixel() {
    let roi = roi_for(Some(&subframe(5, 7, 64, 32)), 1920, 1080).unwrap();
    assert_eq!((roi.x, roi.y), (4, 6));
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
                roi_for(Some(&request), 1920, 1080),
                Err(DriverError::InvalidParameter(_))
            ),
            "{request:?}"
        );
    }
}

/// POA_ERROR_INVALID_INDEX and POA_ERROR_INVALID_ID on an open camera or
/// wheel were a generic device error, so a USB drop never started the
/// reconnect; before the device is opened they still say the id is wrong.
#[test]
fn an_id_the_sdk_dropped_reads_as_disconnected_on_an_open_device() {
    for code in [1, 2] {
        assert!(matches!(
            check_open_poa_error(code, "GetCameraState"),
            Err(DriverError::Disconnected)
        ));
        assert!(matches!(
            check_open_poa_pw_error(code, "get current filter position"),
            Err(DriverError::Disconnected)
        ));
        assert!(matches!(
            check_poa_error(code, "OpenCamera"),
            Err(DriverError::InvalidDevice(_))
        ));
        assert!(matches!(
            check_poa_pw_error(code, "open filter wheel"),
            Err(DriverError::InvalidDevice(_))
        ));
    }
    assert!(check_open_poa_error(0, "GetCameraState").is_ok());
    assert!(matches!(
        check_open_poa_error(3, "POASetConfig"),
        Err(DriverError::InvalidParameter(_))
    ));
}
