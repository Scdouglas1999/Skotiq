//! The ZWO drivers against the fake SDKs that model ASICamera2.h, EAF_focuser.h
//! and EFW_filter.h (`ASI_FAKE_SDK`, `EAF_FAKE_SDK`, `EFW_FAKE_SDK` in
//! `native_driver_tests.rs`).
//!
//! The tests share one loaded SDK and the fakes' environment switches, so they
//! run in one process, one at a time:
//!
//! ```sh
//! python3 native/tests/fake_sdk_linux/build_fakes.py /tmp/fakes
//! cargo test --release -p skotiq_native --test zwo_fake_sdk --no-run
//! LD_LIBRARY_PATH=/tmp/fakes/zwo <test binary> --ignored --test-threads 1
//! ```

#![cfg(unix)]

use skotiq_device::SubFrame;
use skotiq_device::{BayerPattern, CameraDriver, DeviceDriver, DriverError};
use skotiq_device::{ExposureParams, FilterWheelDriver, FocuserDriver, FrameType, ImageData};
use skotiq_native::vendor::zwo::{self, ZwoCamera, ZwoFilterWheel, ZwoFocuser};

const COOLED_MONO: i32 = 0;
const UNCOOLED_COLOR: i32 = 1;
const EIGHT_BIT_MONO: i32 = 2;

fn exposure(duration_secs: f64, bin: i32, subframe: Option<SubFrame>) -> ExposureParams {
    ExposureParams {
        duration_secs,
        gain: Some(100),
        offset: Some(20),
        bin_x: bin,
        bin_y: bin,
        subframe,
        readout_mode: None,
        frame_type: FrameType::Light,
    }
}

fn roi(start_x: u32, start_y: u32, width: u32, height: u32) -> SubFrame {
    SubFrame {
        start_x,
        start_y,
        width,
        height,
    }
}

async fn connected(camera_id: i32) -> ZwoCamera {
    let mut camera = ZwoCamera::new(camera_id);
    camera.connect().await.expect("connect");
    camera
}

async fn take(camera: &mut ZwoCamera, params: ExposureParams) -> ImageData {
    camera.start_exposure(params).await.expect("start exposure");
    assert!(camera.is_exposure_complete().await.expect("poll"));
    camera.download_image().await.expect("download")
}

/// The fake's pixels hold `1000 + 256 * row + column` of the binned sensor grid.
fn sensor_origin(frame: &ImageData) -> (u32, u32) {
    let value = u32::from(frame.data[0]) - 1000;
    (value % 256, value / 256)
}

#[tokio::test]
#[ignore = "needs the ZWO fake SDKs on LD_LIBRARY_PATH (see the file header)"]
async fn a_focuser_connects_from_a_saved_profile_before_any_scan() {
    // Runs first (libtest orders tests by name): nothing has called EAFGetNum yet.
    let mut focuser = ZwoFocuser::new(0);
    focuser.connect().await.expect("connect");
    assert_eq!(focuser.get_max_position().await, 60_000);
    focuser.disconnect().await.unwrap();
}

#[tokio::test]
#[ignore = "needs the ZWO fake SDKs on LD_LIBRARY_PATH (see the file header)"]
async fn a_wheel_connects_while_it_is_still_counting_its_slots() {
    let mut wheel = ZwoFilterWheel::new(0);
    wheel.connect().await.expect("connect");
    assert_eq!(wheel.get_filter_count().await, 7);
    wheel.disconnect().await.unwrap();
}

#[tokio::test]
#[ignore = "needs the ZWO fake SDKs on LD_LIBRARY_PATH (see the file header)"]
async fn binning_is_limited_to_the_bins_the_camera_lists() {
    let mut color = connected(UNCOOLED_COLOR).await;
    assert_eq!(color.capabilities().max_bin_x, 2);
    let refused = color.start_exposure(exposure(1.0, 4, None)).await;
    match refused {
        Err(DriverError::InvalidParameter(message)) => {
            assert!(message.contains("1, 2"), "{message}")
        }
        other => panic!("bin 4 on a camera that bins 1 and 2: {other:?}"),
    }
    color.disconnect().await.unwrap();

    let mut mono = connected(COOLED_MONO).await;
    assert_eq!(mono.capabilities().max_bin_x, 4);
    assert!(matches!(
        mono.start_exposure(exposure(1.0, 3, None)).await,
        Err(DriverError::InvalidParameter(_))
    ));
    assert!(matches!(
        mono.set_binning(2, 1).await,
        Err(DriverError::InvalidParameter(_))
    ));
    let binned = take(&mut mono, exposure(1.0, 4, None)).await;
    assert_eq!((binned.width, binned.height), (16, 12));
    mono.disconnect().await.unwrap();
}

#[tokio::test]
#[ignore = "needs the ZWO fake SDKs on LD_LIBRARY_PATH (see the file header)"]
async fn an_exposure_longer_than_the_camera_takes_is_refused_not_shortened() {
    let mut camera = connected(COOLED_MONO).await;
    assert_eq!(
        camera.get_exposure_range().await.unwrap(),
        Some((0.000001, 60.0))
    );
    match camera.start_exposure(exposure(120.0, 1, None)).await {
        Err(DriverError::InvalidParameter(message)) => assert!(message.contains("60"), "{message}"),
        other => panic!("a 120 s request on a camera that exposes up to 60 s: {other:?}"),
    }
    let frame = take(&mut camera, exposure(60.0, 1, None)).await;
    assert_eq!(frame.metadata.exposure_time, 60.0);
    camera.disconnect().await.unwrap();
}

#[tokio::test]
#[ignore = "needs the ZWO fake SDKs on LD_LIBRARY_PATH (see the file header)"]
async fn a_subframe_is_read_where_the_frame_says_it_was() {
    let mut mono = connected(COOLED_MONO).await;
    // The SDK takes widths in multiples of 8 and heights in multiples of 2.
    let frame = take(&mut mono, exposure(1.0, 1, Some(roi(3, 5, 21, 9)))).await;
    assert_eq!((frame.width, frame.height), (16, 8));
    assert_eq!(sensor_origin(&frame), (3, 5));
    let applied = frame.metadata.subframe.clone().expect("subframe recorded");
    assert_eq!(
        (
            applied.start_x,
            applied.start_y,
            applied.width,
            applied.height
        ),
        (3, 5, 16, 8)
    );

    // Past the right edge of the 64-pixel sensor.
    assert!(matches!(
        mono.start_exposure(exposure(1.0, 1, Some(roi(56, 0, 16, 8))))
            .await,
        Err(DriverError::InvalidParameter(_))
    ));

    // A full frame after a subframe is the whole sensor again.
    let full = take(&mut mono, exposure(1.0, 1, None)).await;
    assert_eq!((full.width, full.height), (64, 48));
    assert_eq!(sensor_origin(&full), (0, 0));
    assert!(full.metadata.subframe.is_none());
    mono.disconnect().await.unwrap();
}

#[tokio::test]
#[ignore = "needs the ZWO fake SDKs on LD_LIBRARY_PATH (see the file header)"]
async fn a_color_subframe_starts_on_the_cell_its_bayer_pattern_names() {
    let mut color = connected(UNCOOLED_COLOR).await;
    let frame = take(&mut color, exposure(1.0, 1, Some(roi(3, 5, 21, 9)))).await;
    assert_eq!(sensor_origin(&frame), (2, 4));
    assert_eq!(frame.bayer_pattern, Some(BayerPattern::Rggb));
    let applied = frame.metadata.subframe.clone().expect("subframe recorded");
    assert_eq!((applied.start_x, applied.start_y), (2, 4));
    color.disconnect().await.unwrap();
}

#[tokio::test]
#[ignore = "needs the ZWO fake SDKs on LD_LIBRARY_PATH (see the file header)"]
async fn a_color_frame_names_the_pattern_the_camera_delivered() {
    let mut color = connected(UNCOOLED_COLOR).await;

    std::env::set_var("FAKE_ASI_MONO_BIN", "1");
    let mono_binned = take(&mut color, exposure(1.0, 2, None)).await;
    let unbinned = take(&mut color, exposure(1.0, 1, None)).await;
    std::env::remove_var("FAKE_ASI_MONO_BIN");
    assert_eq!(mono_binned.bayer_pattern, None);
    assert_eq!(unbinned.bayer_pattern, Some(BayerPattern::Rggb));

    for (flip, pattern) in [
        ("1", BayerPattern::Grbg),
        ("2", BayerPattern::Gbrg),
        ("3", BayerPattern::Bggr),
    ] {
        std::env::set_var("FAKE_ASI_FLIP", flip);
        let frame = take(&mut color, exposure(1.0, 1, None)).await;
        assert_eq!(frame.bayer_pattern, Some(pattern), "flip {flip}");
    }
    std::env::remove_var("FAKE_ASI_FLIP");
    color.disconnect().await.unwrap();
}

#[tokio::test]
#[ignore = "needs the ZWO fake SDKs on LD_LIBRARY_PATH (see the file header)"]
async fn a_wheel_unplugged_while_connected_and_replaced_is_seen_as_the_new_wheel() {
    let mut wheel = ZwoFilterWheel::new(0);
    wheel.connect().await.expect("connect");
    std::env::set_var("FAKE_EFW_REMOVED", "1");
    let _ = wheel.disconnect().await;
    std::env::remove_var("FAKE_EFW_REMOVED");
    std::env::set_var("FAKE_EFW_SLOTS", "5");
    let wheels = zwo::discover_filter_wheels().await.expect("discovery");
    std::env::remove_var("FAKE_EFW_SLOTS");
    assert_eq!(wheels.len(), 1);
    assert_eq!(wheels[0].slot_count, 5);
}

#[tokio::test]
#[ignore = "needs the ZWO fake SDKs on LD_LIBRARY_PATH (see the file header)"]
async fn a_camera_without_16_bit_readout_connects_in_8_bit() {
    let mut camera = connected(EIGHT_BIT_MONO).await;
    let sensor = camera.get_sensor_info();
    assert_eq!((sensor.bit_depth, sensor.max_adu), (8, 255 << 8));
    let frame = take(&mut camera, exposure(1.0, 1, None)).await;
    assert_eq!((frame.width, frame.height), (32, 16));
    assert_eq!(frame.bits_per_pixel, 8);
    // 1000 + 256 * 0 + 1, low byte, scaled to the 16-bit container.
    assert_eq!(frame.data[1], ((1001u16) & 0xff) << 8);
    camera.disconnect().await.unwrap();
}

/// `ASI_TARGET_TEMP` and `ASI_COOLER_ON` in `ASIControlType`.
const TARGET_TEMP: &str = "16";
const COOLER_ON: &str = "17";

/// A camera whose cooler cannot be read back may still be cooling from an
/// earlier session, so its cooler is unknown until this connection sets it,
/// never "off at -10 C".
#[tokio::test]
#[ignore = "needs the ZWO fake SDKs on LD_LIBRARY_PATH (see the file header)"]
async fn a_cooler_that_cannot_be_read_back_is_unknown_until_it_is_set() {
    let mut camera = connected(COOLED_MONO).await;
    std::env::set_var("FAKE_ASI_UNREADABLE", format!("{TARGET_TEMP},{COOLER_ON}"));
    let before = camera.get_status().await;
    let set = camera.set_cooler(true, Some(-15.0)).await;
    let after = camera.get_status().await;
    std::env::remove_var("FAKE_ASI_UNREADABLE");
    let before = before.expect("status");
    set.expect("cooler on");
    let after = after.expect("status");
    assert_eq!((before.cooler_on, before.target_temp), (None, None));
    assert_eq!((after.cooler_on, after.target_temp), (Some(true), Some(-15.0)));
    camera.disconnect().await.unwrap();
}

#[tokio::test]
#[ignore = "needs the ZWO fake SDKs on LD_LIBRARY_PATH (see the file header)"]
async fn a_camera_unplugged_while_connected_reads_as_disconnected() {
    let mut camera = connected(COOLED_MONO).await;
    std::env::set_var("FAKE_ASI_GONE", "1");
    let status = camera.get_status().await;
    let started = camera.start_exposure(exposure(1.0, 1, None)).await;
    let mut absent = ZwoCamera::new(COOLED_MONO);
    let reconnect = absent.connect().await;
    std::env::remove_var("FAKE_ASI_GONE");
    assert!(
        matches!(status, Err(DriverError::Disconnected)),
        "{status:?}"
    );
    assert!(
        matches!(started, Err(DriverError::Disconnected)),
        "{started:?}"
    );
    // Not there when a connect looks for it: a wrong id, not a lost camera.
    assert!(
        matches!(reconnect, Err(DriverError::InvalidDevice(_))),
        "{reconnect:?}"
    );
    camera.disconnect().await.unwrap();
}

#[tokio::test]
#[ignore = "needs the ZWO fake SDKs on LD_LIBRARY_PATH (see the file header)"]
async fn a_focuser_unplugged_while_connected_reads_as_disconnected() {
    let mut focuser = ZwoFocuser::new(0);
    focuser.connect().await.expect("connect");
    std::env::set_var("FAKE_EAF_GONE", "1");
    let position = focuser.get_position().await;
    let moved = focuser.move_to(2_000).await;
    std::env::remove_var("FAKE_EAF_GONE");
    assert!(
        matches!(position, Err(DriverError::Disconnected)),
        "{position:?}"
    );
    assert!(matches!(moved, Err(DriverError::Disconnected)), "{moved:?}");
    focuser.disconnect().await.unwrap();
}

#[tokio::test]
#[ignore = "needs the ZWO fake SDKs on LD_LIBRARY_PATH (see the file header)"]
async fn a_wheel_unplugged_while_connected_reads_as_disconnected() {
    let mut wheel = ZwoFilterWheel::new(0);
    wheel.connect().await.expect("connect");
    std::env::set_var("FAKE_EFW_GONE", "1");
    let position = wheel.get_position().await;
    let moved = wheel.move_to_position(2).await;
    std::env::remove_var("FAKE_EFW_GONE");
    assert!(
        matches!(position, Err(DriverError::Disconnected)),
        "{position:?}"
    );
    assert!(matches!(moved, Err(DriverError::Disconnected)), "{moved:?}");
    wheel.disconnect().await.unwrap();
}
