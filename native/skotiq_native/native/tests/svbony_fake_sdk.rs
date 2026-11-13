//! The SVBony driver against the fake SVBCameraSDK in `tests/fake_sdk/svbony.rs`.
//!
//! The SDK is a process-wide library found on the loader path, so each scenario
//! runs in its own child process of this test binary with the fake first on
//! `LD_LIBRARY_PATH` and the camera model chosen by environment variables.

#![cfg(target_os = "linux")]

#[path = "fake_sdk_linux/harness.rs"]
mod harness;

use skotiq_device::{
    BayerPattern, CameraDriver, DeviceDriver, DriverError, ExposureParams, FrameType, ImageData,
    SubFrame,
};
use skotiq_native::vendor::svbony::SvbonyCamera;
use std::ffi::{c_int, c_long};
use std::path::Path;
use std::sync::OnceLock;
use std::time::Duration;

const LIBRARY: &str = "libSVBCameraSDK.so";

fn fake_sdk() -> &'static harness::FakeSdk {
    static FAKE: OnceLock<harness::FakeSdk> = OnceLock::new();
    FAKE.get_or_init(|| harness::FakeSdk::build("svbony", &[harness::SVBONY]))
}

fn run_scenario(name: &str, env: &[(&str, &str)]) {
    let fake = fake_sdk();
    let dir = fake.dir().to_str().expect("a UTF-8 temp path");
    let env: Vec<(&str, &str)> = [("SVBONY_FAKE_SDK_DIR", dir)]
        .into_iter()
        .chain(env.iter().copied())
        .collect();
    fake.run_one(&format!("scenario::{name}"), &env);
}

#[test]
fn a_cooled_color_camera_takes_triggered_frames_labelled_as_taken() {
    run_scenario("cooled_color_camera", &[]);
}

#[test]
fn a_monochrome_camera_that_offers_only_luma_connects_and_exposes() {
    run_scenario("monochrome_luma_camera", &[("FAKE_SVB_MODEL", "mono")]);
}

#[test]
fn a_camera_connects_at_its_default_gain_and_offset() {
    run_scenario("default_gain_and_offset", &[]);
}

#[test]
fn a_failed_download_leaves_the_camera_ready_for_the_next_exposure() {
    run_scenario("failed_download", &[("FAKE_SVB_FAIL_FRAME", "1")]);
}

#[test]
fn a_camera_that_cannot_trigger_exposes_from_its_video_stream() {
    run_scenario("free_running_camera", &[("FAKE_SVB_NO_TRIGGER", "1")]);
}

/// The fake's own view of the camera, through the same loaded library.
struct Fake(libloading::Library);

impl Fake {
    fn open() -> Self {
        let dir = std::env::var_os("SVBONY_FAKE_SDK_DIR").expect("run by the parent test");
        // SAFETY: the fake SDK built by this test; loading it runs no initializer.
        Self(unsafe { libloading::Library::new(Path::new(&dir).join(LIBRARY)) }.expect("load fake"))
    }

    fn control(&self, control_type: c_int) -> c_long {
        // SAFETY: FakeSvbControl has this signature in tests/fake_sdk/svbony.rs.
        unsafe {
            let f = self
                .0
                .get::<unsafe extern "C" fn(c_int) -> c_long>(b"FakeSvbControl\0")
                .unwrap();
            f(control_type)
        }
    }

    fn mode(&self) -> c_int {
        // SAFETY: FakeSvbMode has this signature in tests/fake_sdk/svbony.rs.
        unsafe {
            self.0
                .get::<unsafe extern "C" fn() -> c_int>(b"FakeSvbMode\0")
                .unwrap()()
        }
    }

    fn triggers(&self) -> c_int {
        // SAFETY: FakeSvbTriggers has this signature in tests/fake_sdk/svbony.rs.
        unsafe {
            self.0
                .get::<unsafe extern "C" fn() -> c_int>(b"FakeSvbTriggers\0")
                .unwrap()()
        }
    }
}

fn exposure(duration_secs: f64, bin: i32, subframe: Option<SubFrame>) -> ExposureParams {
    ExposureParams {
        duration_secs,
        gain: Some(44),
        offset: Some(7),
        bin_x: bin,
        bin_y: bin,
        subframe,
        readout_mode: None,
        frame_type: FrameType::Light,
    }
}

async fn take(camera: &mut SvbonyCamera, params: ExposureParams) -> Result<ImageData, DriverError> {
    camera.start_exposure(params).await?;
    while !camera.is_exposure_complete().await? {
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    camera.download_image().await
}

mod scenario {
    use super::*;

    #[tokio::test]
    #[ignore = "run in a child process by its parent test, with the fake SDK on the loader path"]
    async fn cooled_color_camera() {
        let fake = Fake::open();
        // A saved profile connects without a discovery scan first.
        let mut camera = SvbonyCamera::new(0);
        camera.connect().await.expect("connect");
        assert_eq!(camera.name(), "SVBONY SV405CC");
        assert_eq!(camera.serial_number().as_deref(), Some("SV405CC-FAKE-01"));
        assert_eq!(fake.mode(), 1, "soft-trigger mode");
        // Gamma, flip and bad pixel correction left by another program are back
        // at their defaults.
        assert_eq!(
            (fake.control(2), fake.control(7), fake.control(18)),
            (100, 0, 0)
        );

        let sensor = camera.get_sensor_info();
        assert_eq!(sensor.bayer_pattern, Some(BayerPattern::Rggb));
        assert_eq!((sensor.bit_depth, sensor.max_adu), (14, 65532));
        assert_eq!(
            camera.get_exposure_range().await.unwrap(),
            Some((0.000032, 1000.0))
        );
        assert_eq!(
            camera.get_cooler_temp_range().await.unwrap(),
            Some((-40.0, 30.0))
        );
        assert!(camera.capabilities().can_cool);

        // Bin 2 of 48 x 30 is 24 x 15; the SDK takes 24 x 14.
        let frame = take(&mut camera, exposure(0.01, 2, None))
            .await
            .expect("bin 2 frame");
        assert_eq!((frame.width, frame.height), (24, 14));
        assert_eq!(frame.data.len(), 24 * 14);
        assert!(frame.data.iter().all(|&px| px == 1001), "frame 1");
        assert_eq!(frame.metadata.exposure_time, 0.01);
        assert_eq!((frame.metadata.gain, frame.metadata.offset), (44, 7));
        assert_eq!((frame.metadata.bin_x, frame.metadata.bin_y), (2, 2));
        assert_eq!(frame.metadata.temperature, Some(-9.5));

        // An aborted exposure's frame is not the next frame.
        camera
            .start_exposure(exposure(10.0, 1, None))
            .await
            .expect("start");
        camera.abort_exposure().await.expect("abort");
        let frame = take(&mut camera, exposure(0.01, 1, None))
            .await
            .expect("frame after abort");
        assert!(
            frame.data.iter().all(|&px| px == 1003),
            "frame 3, not the aborted frame 2"
        );

        // Longer than the camera exposes: refused before anything is sent.
        let triggers = fake.triggers();
        assert!(matches!(
            camera.start_exposure(exposure(1200.0, 1, None)).await,
            Err(DriverError::InvalidParameter(_))
        ));
        assert_eq!(fake.triggers(), triggers);

        // Shorter than the camera exposes: labelled with what it exposed.
        let frame = take(&mut camera, exposure(0.0, 1, None))
            .await
            .expect("bias");
        assert_eq!(frame.metadata.exposure_time, 0.000032);

        // A subframe is aligned the way the SDK requires and labelled as read.
        let subframe = SubFrame {
            start_x: 3,
            start_y: 3,
            width: 17,
            height: 9,
        };
        let frame = take(&mut camera, exposure(0.01, 1, Some(subframe)))
            .await
            .expect("subframe");
        assert_eq!((frame.width, frame.height), (16, 8));
        let applied = frame.metadata.subframe.expect("subframe recorded");
        assert_eq!(
            (
                applied.start_x,
                applied.start_y,
                applied.width,
                applied.height
            ),
            (2, 2, 16, 8)
        );

        camera
            .set_cooler(true, Some(-10.04))
            .await
            .expect("cooler on");
        assert_eq!((fake.control(14), fake.control(15)), (1, -100));
        camera
            .set_cooler(true, Some(-55.0))
            .await
            .expect("cooler below its range");
        let status = camera.get_status().await.expect("status");
        assert_eq!(status.target_temp, Some(-40.0));
        assert_eq!(status.cooler_on, Some(true));
        assert_eq!(status.cooler_power, Some(37.0));

        camera.disconnect().await.expect("disconnect");
        // The cooler kept running and is reported as running after a reconnect.
        let mut camera = SvbonyCamera::new(0);
        camera.connect().await.expect("reconnect");
        let status = camera.get_status().await.expect("status after reconnect");
        assert_eq!(status.cooler_on, Some(true));
        assert_eq!(status.target_temp, Some(-40.0));
    }

    #[tokio::test]
    #[ignore = "run in a child process by its parent test, with the fake SDK on the loader path"]
    async fn monochrome_luma_camera() {
        let mut camera = SvbonyCamera::new(0);
        camera
            .connect()
            .await
            .expect("connect a Y8/Y16-only camera");
        let sensor = camera.get_sensor_info();
        assert!(!sensor.color);
        assert_eq!(sensor.bayer_pattern, None);
        assert!(!camera.capabilities().can_cool);
        assert_eq!(camera.get_temperature().await.expect("thermometer"), 21.5);

        let frame = take(&mut camera, exposure(0.01, 1, None))
            .await
            .expect("frame");
        assert_eq!((frame.width, frame.height), (40, 30));
        assert_eq!(frame.bits_per_pixel, 12);
        assert!(frame.data.iter().all(|&px| px == 1001), "16-bit luma frame");
        assert_eq!(frame.bayer_pattern, None);
        assert_eq!(frame.metadata.temperature, Some(21.5));
    }

    #[tokio::test]
    #[ignore = "run in a child process by its parent test, with the fake SDK on the loader path"]
    async fn default_gain_and_offset() {
        let fake = Fake::open();
        let mut camera = SvbonyCamera::new(0);
        camera.connect().await.expect("connect");
        // Connect zeroes gain and offset for the SV305M Pro carry-over; an exposure
        // that leaves them to the camera then needs the defaults, not 0 (an offset
        // of 0 clips the bias).
        assert_eq!((fake.control(0), fake.control(13)), (120, 10));
        assert_eq!(camera.get_gain().await.expect("gain"), 120);
        assert_eq!(camera.get_offset().await.expect("offset"), 10);
        let frame = take(
            &mut camera,
            ExposureParams {
                gain: None,
                offset: None,
                ..exposure(0.01, 1, None)
            },
        )
        .await
        .expect("frame at the camera's own gain and offset");
        assert_eq!((frame.metadata.gain, frame.metadata.offset), (120, 10));
    }

    #[tokio::test]
    #[ignore = "run in a child process by its parent test, with the fake SDK on the loader path"]
    async fn failed_download() {
        let mut camera = SvbonyCamera::new(0);
        camera.connect().await.expect("connect");
        assert!(take(&mut camera, exposure(0.01, 1, None)).await.is_err());
        let frame = take(&mut camera, exposure(0.01, 2, None))
            .await
            .expect("the next exposure, with a new readout region");
        assert!(frame.data.iter().all(|&px| px == 1002));
    }

    #[tokio::test]
    #[ignore = "run in a child process by its parent test, with the fake SDK on the loader path"]
    async fn free_running_camera() {
        let fake = Fake::open();
        let mut camera = SvbonyCamera::new(0);
        camera.connect().await.expect("connect");
        assert_eq!(fake.mode(), 0, "video mode");
        let frame = take(&mut camera, exposure(0.01, 1, None))
            .await
            .expect("frame");
        assert_eq!((frame.width, frame.height), (48, 30));
        assert_eq!(fake.triggers(), 0);
    }
}
