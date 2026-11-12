//! The Touptek driver against the fake ToupTek-family SDK (`TOUPTEK_FAKE_SDK` in
//! `tests/native_driver_tests.rs`), which models the SDK as its header and manual
//! describe it. Each test checks one thing a ToupTek, Altair, OGMA, Omegon or
//! Risingcam owner relies on. The fake must come first on the loader path:
//! `tests/fake_sdk_linux/run_touptek_checks.sh` builds it and runs these.

#![cfg(unix)]

use skotiq_device::{CameraDriver, DeviceDriver, DriverError, ExposureParams, FrameType};
use skotiq_device::{ImageData, SubFrame};
use skotiq_native::vendor::touptek::{self, TouptekCamera};
use std::time::Duration;

const COOLED_COLOR: usize = 0;
const UNCOOLED_MONO: usize = 1;
const EIGHT_BIT_MONO: usize = 2;

async fn connected(index: usize) -> TouptekCamera {
    touptek::discover_devices_for_brand("OGMA")
        .await
        .expect("the fake SDK is on the loader path");
    let mut camera = TouptekCamera::new(index, "OGMA");
    camera.connect().await.expect("connect");
    camera
}

fn exposure(duration_secs: f64, bin: i32, subframe: Option<SubFrame>) -> ExposureParams {
    ExposureParams {
        duration_secs,
        gain: None,
        offset: None,
        bin_x: bin,
        bin_y: bin,
        subframe,
        readout_mode: None,
        frame_type: FrameType::Light,
    }
}

async fn wait_until_exposed(camera: &TouptekCamera) {
    for _ in 0..200 {
        if camera.is_exposure_complete().await.expect("exposure state") {
            return;
        }
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    panic!("the exposure never completed");
}

async fn take(camera: &mut TouptekCamera, params: ExposureParams) -> ImageData {
    camera.start_exposure(params).await.expect("start exposure");
    wait_until_exposed(camera).await;
    camera.download_image().await.expect("download")
}

fn at(image: &ImageData, x: u32, y: u32) -> u32 {
    u32::from(image.data[(y * image.width + x) as usize])
}

#[tokio::test]
#[ignore = "needs the fake ToupTek SDK on LD_LIBRARY_PATH: tests/fake_sdk_linux/run_touptek_checks.sh"]
async fn filter_wheels_and_focusers_on_the_sdk_are_not_listed_as_cameras() {
    let devices = touptek::discover_devices_for_brand("OGMA").await.unwrap();
    let names: Vec<&str> = devices.iter().map(|d| d.name.as_str()).collect();
    assert_eq!(names, ["OGMA AP26CC", "OGMA GP2000M", "OGMA GP130M8"]);
}

#[tokio::test]
#[ignore = "needs the fake ToupTek SDK on LD_LIBRARY_PATH: tests/fake_sdk_linux/run_touptek_checks.sh"]
async fn a_camera_without_a_thermometer_answers_the_status_read() {
    let mut camera = connected(UNCOOLED_MONO).await;
    let status = camera
        .get_status()
        .await
        .expect("the status read is the heartbeat; it must not need a thermometer");
    assert_eq!(status.sensor_temp, None);
    assert!(matches!(
        camera.get_temperature().await,
        Err(DriverError::NotSupported)
    ));
    let frame = take(&mut camera, exposure(0.01, 1, None)).await;
    assert_eq!(frame.metadata.temperature, None);
    camera.disconnect().await.unwrap();
}

#[tokio::test]
#[ignore = "needs the fake ToupTek SDK on LD_LIBRARY_PATH: tests/fake_sdk_linux/run_touptek_checks.sh"]
async fn frames_record_the_sensor_temperature() {
    let mut camera = connected(COOLED_COLOR).await;
    camera.set_cooler(true, Some(-12.5)).await.unwrap();
    let frame = take(&mut camera, exposure(0.01, 1, None)).await;
    assert_eq!(frame.metadata.temperature, Some(-12.5));
    camera.disconnect().await.unwrap();
}

#[tokio::test]
#[ignore = "needs the fake ToupTek SDK on LD_LIBRARY_PATH: tests/fake_sdk_linux/run_touptek_checks.sh"]
async fn the_bit_depth_is_the_one_the_frames_are_read_out_in() {
    let mut camera = connected(COOLED_COLOR).await;
    let sensor = camera.get_sensor_info();
    assert_eq!((sensor.bit_depth, sensor.max_adu), (12, 4095));
    let frame = take(&mut camera, exposure(0.01, 1, None)).await;
    assert_eq!(frame.bits_per_pixel, 12);
    camera.disconnect().await.unwrap();
}

#[tokio::test]
#[ignore = "needs the fake ToupTek SDK on LD_LIBRARY_PATH: tests/fake_sdk_linux/run_touptek_checks.sh"]
async fn an_eight_bit_camera_delivers_its_own_pixels() {
    let mut camera = connected(EIGHT_BIT_MONO).await;
    let sensor = camera.get_sensor_info();
    assert_eq!((sensor.bit_depth, sensor.max_adu), (8, 255));
    let frame = take(&mut camera, exposure(0.01, 1, None)).await;
    assert_eq!((frame.width, frame.height), (32, 24));
    assert_eq!(frame.data.len(), 32 * 24);
    assert!(
        frame.data.iter().all(|&v| v <= 255),
        "8-bit samples read as 16-bit pairs"
    );
    assert!(at(&frame, 0, 23) > at(&frame, 0, 0), "rows in sensor order");
    camera.disconnect().await.unwrap();
}

#[tokio::test]
#[ignore = "needs the fake ToupTek SDK on LD_LIBRARY_PATH: tests/fake_sdk_linux/run_touptek_checks.sh"]
async fn the_offset_reaches_the_camera_and_the_frame_records_it() {
    let mut camera = connected(COOLED_COLOR).await;
    assert!(camera.capabilities().can_set_offset);
    assert_eq!(camera.get_offset_range().await.unwrap(), (0, 31 * 16));
    let frame = take(
        &mut camera,
        ExposureParams {
            offset: Some(9),
            ..exposure(0.01, 1, None)
        },
    )
    .await;
    assert_eq!(frame.metadata.offset, 9);
    assert_eq!(camera.get_offset().await.unwrap(), 9);
    camera.disconnect().await.unwrap();

    let mut camera = connected(UNCOOLED_MONO).await;
    assert!(!camera.capabilities().can_set_offset);
    let frame = take(
        &mut camera,
        ExposureParams {
            offset: Some(9),
            ..exposure(0.01, 1, None)
        },
    )
    .await;
    assert_eq!(
        frame.metadata.offset, 0,
        "the camera has no black level to set"
    );
    camera.disconnect().await.unwrap();
}

#[tokio::test]
#[ignore = "needs the fake ToupTek SDK on LD_LIBRARY_PATH: tests/fake_sdk_linux/run_touptek_checks.sh"]
async fn a_binned_subframe_covers_the_requested_part_of_the_sensor() {
    let mut camera = connected(COOLED_COLOR).await;
    let full = take(&mut camera, exposure(0.01, 1, None)).await;
    // Binned coordinates: (4, 2) at bin 2 is sensor pixel (8, 4).
    let roi = SubFrame {
        start_x: 4,
        start_y: 2,
        width: 16,
        height: 16,
    };
    let binned = take(&mut camera, exposure(0.01, 2, Some(roi))).await;
    assert_eq!((binned.width, binned.height), (16, 16));
    // The fake's pixels grow by one per frame; a 2x2 cell is the sum of four.
    let cell = at(&full, 8, 4) + at(&full, 9, 4) + at(&full, 8, 5) + at(&full, 9, 5);
    assert_eq!(at(&binned, 0, 0), cell + 4);
    let reported = binned.metadata.subframe.expect("subframe recorded");
    assert_eq!(
        (
            reported.start_x,
            reported.start_y,
            reported.width,
            reported.height
        ),
        (4, 2, 16, 16)
    );
    camera.disconnect().await.unwrap();
}

#[tokio::test]
#[ignore = "needs the fake ToupTek SDK on LD_LIBRARY_PATH: tests/fake_sdk_linux/run_touptek_checks.sh"]
async fn a_subframe_the_sensor_cannot_read_is_widened_and_reported_as_read() {
    let mut camera = connected(COOLED_COLOR).await;
    let roi = SubFrame {
        start_x: 3,
        start_y: 3,
        width: 10,
        height: 10,
    };
    let frame = take(&mut camera, exposure(0.01, 1, Some(roi))).await;
    assert_eq!((frame.width, frame.height), (16, 16));
    let reported = frame.metadata.subframe.expect("subframe recorded");
    assert_eq!(
        (
            reported.start_x,
            reported.start_y,
            reported.width,
            reported.height
        ),
        (2, 2, 16, 16)
    );
    camera.disconnect().await.unwrap();
}

#[tokio::test]
#[ignore = "needs the fake ToupTek SDK on LD_LIBRARY_PATH: tests/fake_sdk_linux/run_touptek_checks.sh"]
async fn the_exposure_time_is_the_one_the_sensor_ran() {
    let mut camera = connected(COOLED_COLOR).await;
    assert_eq!(
        camera.get_exposure_range().await.unwrap(),
        Some((0.00001, 3600.0))
    );
    // The fake's sensor runs whole 15 us lines: 10 ms is 666 lines, 9.99 ms.
    let frame = take(&mut camera, exposure(0.01, 1, None)).await;
    assert!((frame.metadata.exposure_time - 0.00999).abs() < 1e-9);
    let err = camera
        .start_exposure(exposure(4000.0, 1, None))
        .await
        .expect_err("longer than the camera allows");
    assert!(err.to_string().contains("3600"), "{err}");
    camera.disconnect().await.unwrap();
}

#[tokio::test]
#[ignore = "needs the fake ToupTek SDK on LD_LIBRARY_PATH: tests/fake_sdk_linux/run_touptek_checks.sh"]
async fn the_cooler_state_is_the_cameras_own() {
    let mut camera = connected(COOLED_COLOR).await;
    // The SDK opens a cooled camera with its cooler on, aiming at the model default (0 C here).
    let status = camera.get_status().await.unwrap();
    assert_eq!(status.cooler_on, Some(true));
    assert_eq!(status.target_temp, Some(0.0));
    assert_eq!(status.cooler_power, Some(50.0));
    assert_eq!(camera.get_cooler_power().await.unwrap(), 50.0);
    assert_eq!(
        camera.get_cooler_temp_range().await.unwrap(),
        Some((-50.0, 30.0))
    );
    camera.set_cooler(false, None).await.unwrap();
    let status = camera.get_status().await.unwrap();
    assert_eq!(status.cooler_on, Some(false));
    assert_eq!(status.cooler_power, Some(0.0));
    camera.disconnect().await.unwrap();
}

#[tokio::test]
#[ignore = "needs the fake ToupTek SDK on LD_LIBRARY_PATH: tests/fake_sdk_linux/run_touptek_checks.sh"]
async fn an_abandoned_frame_is_never_delivered_as_the_next_one() {
    let mut camera = connected(COOLED_COLOR).await;
    let first = take(&mut camera, exposure(0.01, 1, None)).await;
    // Exposed and read out, then the run cancels before downloading it.
    camera
        .start_exposure(exposure(0.01, 1, None))
        .await
        .unwrap();
    wait_until_exposed(&camera).await;
    camera.abort_exposure().await.unwrap();
    let third = take(&mut camera, exposure(0.01, 1, None)).await;
    assert_eq!(
        at(&third, 0, 0),
        at(&first, 0, 0) + 2,
        "got the abandoned frame"
    );
    camera.disconnect().await.unwrap();
}

#[tokio::test]
#[ignore = "needs the fake ToupTek SDK on LD_LIBRARY_PATH: tests/fake_sdk_linux/run_touptek_checks.sh"]
async fn frames_are_top_row_first_where_the_sdk_defaults_to_upside_down() {
    // The Windows SDK delivers rows bottom first unless told otherwise.
    std::env::set_var("SK_TOUPTEK_UPSIDE_DOWN", "1");
    let mut camera = connected(COOLED_COLOR).await;
    let full = take(&mut camera, exposure(0.01, 1, None)).await;
    assert!(
        at(&full, 0, 59) > at(&full, 0, 0),
        "rows arrived bottom first"
    );
    let roi = SubFrame {
        start_x: 8,
        start_y: 4,
        width: 16,
        height: 16,
    };
    let part = take(&mut camera, exposure(0.01, 1, Some(roi))).await;
    assert_eq!(at(&part, 0, 0), at(&full, 8, 4) + 1);
    camera.disconnect().await.unwrap();
    std::env::remove_var("SK_TOUPTEK_UPSIDE_DOWN");
}

#[tokio::test]
#[ignore = "needs the fake ToupTek SDK on LD_LIBRARY_PATH: tests/fake_sdk_linux/run_touptek_checks.sh"]
async fn the_camera_reports_its_serial_number() {
    let mut camera = connected(COOLED_COLOR).await;
    assert_eq!(camera.serial_number().as_deref(), Some("OGMA-COOLED-0001"));
    camera.disconnect().await.unwrap();
}
