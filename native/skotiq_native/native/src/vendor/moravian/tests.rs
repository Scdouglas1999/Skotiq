use super::*;

#[tokio::test]
async fn moravian_offset_write_reports_not_supported_without_mutating_cache() {
    let mut camera = MoravianCamera::new(0);
    camera.current_offset = 7;

    let err = camera.set_offset(22).await.unwrap_err();

    assert!(matches!(err, NativeError::NotSupported));
    assert_eq!(camera.current_offset, 7);
}

#[tokio::test]
async fn moravian_gain_write_reports_not_supported_without_mutating_cache() {
    let mut camera = MoravianCamera::new(0);
    camera.connected = true;
    camera.capabilities.can_set_gain = false;
    camera.current_gain = 11;

    let err = camera.set_gain(42).await.unwrap_err();

    assert!(matches!(err, NativeError::NotSupported));
    assert_eq!(camera.current_gain, 11);
}

// ROI / bin math

#[test]
pub(crate) fn full_frame_roi_has_zero_origin_and_full_binned_size() {
    // Full frame (no subframe): origin (0,0), y-flip collapses to fy=0.
    let roi = compute_binned_roi(4032, 2688, 1, 1, None).unwrap();
    assert_eq!(
        roi,
        BinnedRoi {
            x: 0,
            y: 0,
            w: 4032,
            h: 2688
        }
    );
}

#[test]
pub(crate) fn full_frame_roi_binned_divides_by_bin() {
    let roi = compute_binned_roi(4032, 2688, 2, 2, None).unwrap();
    assert_eq!(
        roi,
        BinnedRoi {
            x: 0,
            y: 0,
            w: 2016,
            h: 1344
        }
    );
}

#[test]
pub(crate) fn subframe_roi_flips_y_origin_bottom_up() {
    // Sensor 100x100, bin 1, top-down subframe at (10,20) size 30x40.
    // Bottom-up y origin = 100 - 20 - 40 = 40.
    let roi = compute_binned_roi(100, 100, 1, 1, Some((10, 20, 30, 40))).unwrap();
    assert_eq!(
        roi,
        BinnedRoi {
            x: 10,
            y: 40,
            w: 30,
            h: 40
        }
    );
}

#[test]
pub(crate) fn subframe_roi_binned_origin_and_flip() {
    // Sensor 100x100, bin 2. Top-down subframe (unbinned) at (20,40) size 40x20.
    // Binned: x=10, y_top=20, w=20, h=10; full_bh=50; fy = 50 - 20 - 10 = 20.
    let roi = compute_binned_roi(100, 100, 2, 2, Some((20, 40, 40, 20))).unwrap();
    assert_eq!(
        roi,
        BinnedRoi {
            x: 10,
            y: 20,
            w: 20,
            h: 10
        }
    );
}

#[test]
pub(crate) fn subframe_top_row_maps_to_correct_bottom_up_region() {
    // A subframe starting at the very top (y=0) must map to the top of the
    // bottom-up frame: fy = H - 0 - h = H - h.
    let roi = compute_binned_roi(64, 48, 1, 1, Some((0, 0, 64, 10))).unwrap();
    assert_eq!(roi.y, 48 - 10);
}

#[test]
pub(crate) fn roi_rejects_out_of_bounds_subframe() {
    // Extends past the right edge.
    assert!(compute_binned_roi(100, 100, 1, 1, Some((80, 0, 40, 10))).is_err());
    // Extends past the bottom edge.
    assert!(compute_binned_roi(100, 100, 1, 1, Some((0, 80, 10, 40))).is_err());
}

#[test]
pub(crate) fn roi_rejects_zero_binning() {
    assert!(compute_binned_roi(100, 100, 0, 1, None).is_err());
    assert!(compute_binned_roi(100, 100, 1, 0, None).is_err());
}

// Orientation

#[test]
pub(crate) fn mirror_vertical_reverses_row_order() {
    // width=2, height=3: rows [0,1] [2,3] [4,5] -> [4,5] [2,3] [0,1].
    let mut buf = vec![0u16, 1, 2, 3, 4, 5];
    mirror_vertical_u16(&mut buf, 2, 3);
    assert_eq!(buf, vec![4, 5, 2, 3, 0, 1]);
}

#[test]
pub(crate) fn mirror_vertical_even_height() {
    // width=3, height=2: rows [1,2,3] [4,5,6] -> [4,5,6] [1,2,3].
    let mut buf = vec![1u16, 2, 3, 4, 5, 6];
    mirror_vertical_u16(&mut buf, 3, 2);
    assert_eq!(buf, vec![4, 5, 6, 1, 2, 3]);
}

#[test]
pub(crate) fn mirror_vertical_is_involutive() {
    // Applying the flip twice returns the original image.
    let original = vec![9u16, 8, 7, 6, 5, 4, 3, 2, 1, 0, 11, 12];
    let mut buf = original.clone();
    mirror_vertical_u16(&mut buf, 4, 3);
    mirror_vertical_u16(&mut buf, 4, 3);
    assert_eq!(buf, original);
}

#[test]
pub(crate) fn mirror_vertical_ignores_undersized_buffer() {
    // Never panic / index OOB if the buffer is smaller than claimed dims.
    let mut buf = vec![1u16, 2, 3];
    mirror_vertical_u16(&mut buf, 4, 4);
    assert_eq!(buf, vec![1, 2, 3]);
}

// Bayer phase

#[test]
pub(crate) fn native_bayer_phase_table() {
    assert_eq!(native_bayer(false, false), BayerPattern::Rggb);
    assert_eq!(native_bayer(true, false), BayerPattern::Grbg);
    assert_eq!(native_bayer(false, true), BayerPattern::Gbrg);
    assert_eq!(native_bayer(true, true), BayerPattern::Bggr);
}

#[test]
pub(crate) fn flip_bayer_vertical_swaps_rows() {
    assert_eq!(flip_bayer_vertical(BayerPattern::Rggb), BayerPattern::Gbrg);
    assert_eq!(flip_bayer_vertical(BayerPattern::Gbrg), BayerPattern::Rggb);
    assert_eq!(flip_bayer_vertical(BayerPattern::Grbg), BayerPattern::Bggr);
    assert_eq!(flip_bayer_vertical(BayerPattern::Bggr), BayerPattern::Grbg);
}

#[test]
pub(crate) fn flip_bayer_vertical_is_involutive() {
    for p in [
        BayerPattern::Rggb,
        BayerPattern::Grbg,
        BayerPattern::Gbrg,
        BayerPattern::Bggr,
    ] {
        assert_eq!(flip_bayer_vertical(flip_bayer_vertical(p)), p);
    }
}

// Gain / offset bounds

/// The gX SDK publishes no gain bounds and the range differs between the CCD
/// and CMOS model lines, so the driver reports the absence.
#[tokio::test]
async fn moravian_gain_range_reports_not_supported() {
    let mut camera = MoravianCamera::new(0);
    camera.connected = true;

    assert!(matches!(
        camera.get_gain_range().await,
        Err(NativeError::NotSupported)
    ));
}

/// Same for offset.
#[tokio::test]
async fn moravian_offset_range_reports_not_supported() {
    let mut camera = MoravianCamera::new(0);
    camera.connected = true;

    assert!(matches!(
        camera.get_offset_range().await,
        Err(NativeError::NotSupported)
    ));
}
