//! The Player One drivers against the fake SDK that models PlayerOneCamera.h and
//! PlayerOnePW.h (`tests/fake_sdk/player_one.rs`, `player_one_pw.rs`). The tests
//! share one loaded SDK, so they run in one child process, one at a time.

#![cfg(target_os = "linux")]

#[path = "fake_sdk_linux/harness.rs"]
mod harness;

use skotiq_device::{CameraDriver, CameraState, DeviceDriver, DriverError, FilterWheelDriver};
use skotiq_device::{ExposureParams, FrameType, ImageData, SubFrame};
use skotiq_native::vendor::player_one::{self, PlayerOneCamera, PlayerOneFilterWheel};
use std::time::Duration;

#[test]
fn player_one_drivers_against_the_fake_sdk() {
    harness::FakeSdk::build("player_one", &[harness::PLAYER_ONE, harness::PLAYER_ONE_PW])
        .run_ignored("", &[]);
}

const COOLED_MONO: i32 = 101;
const UNCOOLED_COLOR: i32 = 202;
const WHEEL: i32 = 77;

fn exposure(duration_secs: f64, bin: i32, subframe: Option<SubFrame>) -> ExposureParams {
    ExposureParams {
        duration_secs,
        gain: Some(120),
        offset: Some(30),
        bin_x: bin,
        bin_y: bin,
        subframe,
        readout_mode: None,
        frame_type: FrameType::Light,
    }
}

/// A camera connected the way the app does after a device search.
async fn connected(camera_id: i32) -> PlayerOneCamera {
    player_one::discover_devices().await.expect("discovery");
    let mut camera = PlayerOneCamera::new(camera_id);
    camera.connect().await.expect("connect");
    camera
}

async fn take(camera: &mut PlayerOneCamera, params: ExposureParams) -> ImageData {
    camera.start_exposure(params).await.expect("start exposure");
    for _ in 0..100 {
        if camera.is_exposure_complete().await.expect("poll") {
            return camera.download_image().await.expect("download");
        }
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    panic!("the frame never became ready");
}

#[tokio::test]
#[ignore = "run by player_one_drivers_against_the_fake_sdk"]
async fn a_camera_connects_without_a_scan_first_and_names_its_model_and_serial() {
    // A profile connects at startup by the saved id; nothing has scanned yet.
    // Runs first: libtest orders tests by name.
    let mut camera = PlayerOneCamera::new(COOLED_MONO);
    camera.connect().await.expect("connect");
    assert_eq!(camera.name(), "Skotiq Fake Poseidon-M Pro");
    assert_eq!(camera.serial_number().as_deref(), Some("POA-COOLED-0001"));
    camera.disconnect().await.unwrap();
}

#[tokio::test]
#[ignore = "run by player_one_drivers_against_the_fake_sdk"]
async fn frames_follow_one_another_and_the_camera_is_idle_between_them() {
    let mut camera = connected(COOLED_MONO).await;
    for _ in 0..3 {
        let frame = take(&mut camera, exposure(0.5, 1, None)).await;
        assert_eq!((frame.width, frame.height), (64, 48));
        let status = camera.get_status().await.unwrap();
        assert_eq!(status.state, CameraState::Idle);
    }
    camera.disconnect().await.unwrap();
}

#[tokio::test]
#[ignore = "run by player_one_drivers_against_the_fake_sdk"]
async fn the_requested_binning_and_subframe_are_what_the_frame_is_and_says() {
    let mut camera = connected(COOLED_MONO).await;

    let binned = take(&mut camera, exposure(0.5, 2, None)).await;
    assert_eq!((binned.width, binned.height), (32, 24));
    assert_eq!((binned.metadata.bin_x, binned.metadata.bin_y), (2, 2));
    assert!(binned.metadata.subframe.is_none());

    // Binned-pixel ROI; the width is cut to the SDK's multiple of 4.
    let roi = SubFrame {
        start_x: 4,
        start_y: 2,
        width: 14,
        height: 8,
    };
    let sub = take(&mut camera, exposure(0.5, 2, Some(roi))).await;
    assert_eq!((sub.width, sub.height), (12, 8));
    let applied = sub.metadata.subframe.expect("subframe recorded");
    assert_eq!(
        (
            applied.start_x,
            applied.start_y,
            applied.width,
            applied.height
        ),
        (4, 2, 12, 8)
    );

    let full = take(&mut camera, exposure(0.5, 1, None)).await;
    assert_eq!((full.width, full.height), (64, 48));
    assert_eq!((full.metadata.bin_x, full.metadata.bin_y), (1, 1));
    assert!(full.metadata.subframe.is_none());

    for bin in [3, 99] {
        let refused = camera.start_exposure(exposure(0.5, bin, None)).await;
        assert!(
            matches!(refused, Err(DriverError::InvalidParameter(_))),
            "bin {bin}: {refused:?}"
        );
    }
    camera.disconnect().await.unwrap();
}

#[tokio::test]
#[ignore = "run by player_one_drivers_against_the_fake_sdk"]
async fn a_color_subframe_starts_on_the_bayer_cell_the_header_names() {
    let mut camera = connected(UNCOOLED_COLOR).await;
    let roi = SubFrame {
        start_x: 5,
        start_y: 3,
        width: 16,
        height: 8,
    };
    let frame = take(&mut camera, exposure(0.5, 1, Some(roi))).await;
    let applied = frame.metadata.subframe.expect("subframe recorded");
    assert_eq!((applied.start_x, applied.start_y), (4, 2));
    assert_eq!(frame.bayer_pattern, Some(skotiq_device::BayerPattern::Bggr));
    camera.disconnect().await.unwrap();
}

#[tokio::test]
#[ignore = "run by player_one_drivers_against_the_fake_sdk"]
async fn exposures_beyond_the_microsecond_control_run_for_their_full_length() {
    let mut camera = connected(COOLED_MONO).await;
    camera
        .start_exposure(exposure(3000.0, 1, None))
        .await
        .expect("a 3000 s exposure is within the camera's 7200 s");
    camera.abort_exposure().await.unwrap();

    let frame = take(&mut camera, exposure(1.25, 1, None)).await;
    assert_eq!(frame.metadata.exposure_time, 1.25);
    assert_eq!(
        camera.get_exposure_range().await.unwrap(),
        Some((0.00001, 7200.0))
    );
    assert!(matches!(
        camera.start_exposure(exposure(7201.0, 1, None)).await,
        Err(DriverError::InvalidParameter(_))
    ));
    camera.disconnect().await.unwrap();
}

#[tokio::test]
#[ignore = "run by player_one_drivers_against_the_fake_sdk"]
async fn the_cooler_takes_the_nearest_whole_degree_and_publishes_its_range() {
    let mut camera = connected(COOLED_MONO).await;
    camera.set_cooler(true, Some(-12.6)).await.unwrap();
    assert_eq!(camera.get_status().await.unwrap().target_temp, Some(-13.0));
    assert_eq!(
        camera.get_cooler_temp_range().await.unwrap(),
        Some((-50.0, 30.0))
    );
    camera.disconnect().await.unwrap();
}

#[tokio::test]
#[ignore = "run by player_one_drivers_against_the_fake_sdk"]
async fn the_wheel_reports_moving_instead_of_failing_and_keeps_its_names() {
    let mut wheel = PlayerOneFilterWheel::new(WHEEL);
    wheel
        .connect()
        .await
        .expect("connect waits out the homing turn");
    assert_eq!(wheel.get_position().await.unwrap(), 0);

    wheel.move_to_position(3).await.unwrap();
    assert_eq!(wheel.get_position().await.unwrap(), -1);
    assert!(wheel.is_moving().await.unwrap());
    let mut arrived = false;
    for _ in 0..10 {
        if wheel.get_position().await.unwrap() == 3 {
            arrived = true;
            break;
        }
    }
    assert!(arrived);

    wheel.set_filter_name(3, "Ha".to_string()).await.unwrap();
    assert_eq!(wheel.get_filter_names().await.unwrap()[3], "Ha");
    wheel.disconnect().await.unwrap();
}

#[tokio::test]
#[ignore = "run by player_one_drivers_against_the_fake_sdk"]
async fn sensor_modes_are_offered_and_the_frame_names_the_one_it_used() {
    let mut camera = connected(COOLED_MONO).await;
    assert!(camera.capabilities().supports_readout_modes);
    let modes = camera.get_readout_modes().await.unwrap();
    let names: Vec<&str> = modes.iter().map(|m| m.name.as_str()).collect();
    assert_eq!(names, ["Normal", "LowNoise"]);
    camera.set_readout_mode(&modes[1]).await.unwrap();
    let frame = take(&mut camera, exposure(0.5, 1, None)).await;
    assert_eq!(frame.metadata.readout_mode.as_deref(), Some("LowNoise"));
    camera.disconnect().await.unwrap();

    let mut guide = connected(UNCOOLED_COLOR).await;
    assert!(!guide.capabilities().supports_readout_modes);
    assert!(guide.get_readout_modes().await.unwrap().is_empty());
    let frame = take(&mut guide, exposure(0.5, 1, None)).await;
    assert_eq!(frame.metadata.readout_mode, None);
    guide.disconnect().await.unwrap();
}
