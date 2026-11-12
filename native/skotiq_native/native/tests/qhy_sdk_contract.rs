//! The QHY driver against a fake `libqhyccd.so` that answers the way the
//! vendor SDK does (see `qhy_fake_sdk/libqhyccd.rs` for what that model rests
//! on).
//!
//! `qhy_driver_against_the_fake_sdk` builds the fake with rustc and runs the
//! `sdk_contract` tests in a child process that finds it on
//! `LD_LIBRARY_PATH`. They run one at a time because the SDK is process-wide.

#![cfg(target_os = "linux")]

use std::path::PathBuf;
use std::process::Command;

#[test]
fn qhy_driver_against_the_fake_sdk() {
    let out = std::env::temp_dir().join(format!("skotiq-qhy-fake-{}", std::process::id()));
    std::fs::create_dir_all(&out).expect("create fake SDK dir");
    let source = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/qhy_fake_sdk/libqhyccd.rs");
    let rustc = std::env::var("RUSTC").unwrap_or_else(|_| "rustc".to_string());
    let built = Command::new(rustc)
        .args(["--crate-type", "cdylib", "--edition", "2021", "-O", "-A", "warnings"])
        .arg(&source)
        .arg("-o")
        .arg(out.join("libqhyccd.so"))
        .output()
        .expect("run rustc for the fake QHY SDK");
    assert!(
        built.status.success(),
        "fake QHY SDK build failed:\n{}",
        String::from_utf8_lossy(&built.stderr)
    );
    let run = Command::new(std::env::current_exe().expect("test binary"))
        .args(["--ignored", "--test-threads", "1", "sdk_contract::"])
        .env("LD_LIBRARY_PATH", &out)
        .output()
        .expect("run the QHY contract tests");
    let _ = std::fs::remove_dir_all(&out);
    let report = format!(
        "{}{}",
        String::from_utf8_lossy(&run.stdout),
        String::from_utf8_lossy(&run.stderr)
    );
    assert!(run.status.success(), "QHY contract tests failed:\n{report}");
    assert!(
        !report.contains("running 0 tests"),
        "no QHY contract test ran:\n{report}"
    );
}

mod sdk_contract {
    use skotiq_device::{
        BayerPattern, CameraDriver, CameraState, DeviceDriver, DriverError, ExposureParams,
        FilterWheelDriver,
        FrameType, ImageData, ReadoutMode, SubFrame,
    };
    use skotiq_native::vendor::qhy;
    use std::time::{Duration, Instant};

    const COLOR_CMOS: u32 = 0;
    const LEGACY_CCD: u32 = 1;
    const GUIDE_CAM: u32 = 2;
    const IDS: [&str; 3] = [
        "QHY268C-FAKE0001",
        "QHY9S-FAKE0002",
        "QHY5III462C-FAKE0003",
    ];

    /// Keys of `FakeQhyGet`.
    mod key {
        pub const OPENS: u32 = 0;
        pub const INITS: u32 = 1;
        pub const CLOSES: u32 = 2;
        pub const CANCELS: u32 = 3;
        pub const OPEN: u32 = 4;
        pub const BITS: u32 = 5;
        pub const COOLER_WRITES: u32 = 7;
        pub const MANUAL_PWM: u32 = 9;
        pub const DEBAYER: u32 = 10;
        pub const SHUTTER_AT_START: u32 = 11;
        pub const STARTED_US: u32 = 12;
        pub const STARTED_BIN: u32 = 13;
        pub const STARTED_ROI_X: u32 = 14;
        pub const STARTED_ROI_Y: u32 = 15;
        pub const STARTED_ROI_W: u32 = 16;
        pub const STARTED_ROI_H: u32 = 17;
        pub const STARTED_GAIN: u32 = 18;
        pub const STARTED_OFFSET: u32 = 19;
        pub const EXPOSING: u32 = 20;
        pub const GAIN_NOW: u32 = 23;
    }

    struct Fake(libloading::Library);

    impl Fake {
        fn new() -> Self {
            // SAFETY: the fake is a plain Rust cdylib with no load-time code.
            let fake = Fake(unsafe { libloading::Library::new("libqhyccd.so") }.expect("fake SDK"));
            // SAFETY: FakeQhyReset takes no arguments.
            unsafe { fake.0.get::<unsafe extern "C" fn()>(b"FakeQhyReset\0").unwrap()() };
            fake
        }

        fn get(&self, camera: u32, key: u32) -> f64 {
            // SAFETY: signature as exported by the fake.
            unsafe {
                self.0
                    .get::<unsafe extern "C" fn(u32, u32) -> f64>(b"FakeQhyGet\0")
                    .unwrap()(camera, key)
            }
        }

        fn set(&self, camera: u32, key: u32, value: f64) {
            // SAFETY: signature as exported by the fake.
            unsafe {
                self.0
                    .get::<unsafe extern "C" fn(u32, u32, f64)>(b"FakeQhySet\0")
                    .unwrap()(camera, key, value)
            }
        }

        fn plug(&self, camera: u32, plugged: bool) {
            // SAFETY: signature as exported by the fake.
            unsafe {
                self.0
                    .get::<unsafe extern "C" fn(u32, bool)>(b"FakeQhyPlug\0")
                    .unwrap()(camera, plugged)
            }
        }
    }

    async fn connected(camera: u32) -> qhy::QhyCamera {
        let found = qhy::discover_devices().await.expect("discovery");
        assert!(found.iter().any(|d| d.camera_id == IDS[camera as usize]));
        let mut cam = qhy::QhyCamera::new(IDS[camera as usize].to_string());
        cam.connect().await.expect("connect");
        cam
    }

    fn params(seconds: f64, bin: i32, subframe: Option<SubFrame>, frame: FrameType) -> ExposureParams {
        ExposureParams {
            duration_secs: seconds,
            gain: Some(55),
            offset: Some(9),
            bin_x: bin,
            bin_y: bin,
            subframe,
            readout_mode: None,
            frame_type: frame,
        }
    }

    async fn take(cam: &mut qhy::QhyCamera, p: ExposureParams) -> ImageData {
        cam.start_exposure(p).await.expect("start exposure");
        let deadline = Instant::now() + Duration::from_secs(10);
        while !cam.is_exposure_complete().await.expect("exposure status") {
            assert!(Instant::now() < deadline, "exposure never completed");
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        cam.download_image().await.expect("download")
    }

    fn roi(x: u32, y: u32, width: u32, height: u32) -> Option<SubFrame> {
        Some(SubFrame {
            start_x: x,
            start_y: y,
            width,
            height,
        })
    }

    #[tokio::test(flavor = "multi_thread")]
    #[ignore = "run by qhy_driver_against_the_fake_sdk"]
    async fn color_frames_carry_the_sdk_bayer_pattern() {
        let fake = Fake::new();
        let mut cam = connected(COLOR_CMOS).await;
        let sensor = cam.get_sensor_info();
        assert!(sensor.color);
        assert_eq!(sensor.bayer_pattern, Some(BayerPattern::Gbrg), "BAYER_GB is GBRG");
        assert_eq!(fake.get(COLOR_CMOS, key::DEBAYER), 0.0, "SDK debayering off");

        let frame = take(&mut cam, params(0.01, 1, None, FrameType::Light)).await;
        assert_eq!(frame.bayer_pattern, Some(BayerPattern::Gbrg));
        let frame = take(&mut cam, params(0.01, 1, roi(1, 0, 16, 8), FrameType::Light)).await;
        assert_eq!(frame.bayer_pattern, Some(BayerPattern::Bggr), "odd x start");
        let frame = take(&mut cam, params(0.01, 1, roi(2, 1, 16, 8), FrameType::Light)).await;
        assert_eq!(frame.bayer_pattern, Some(BayerPattern::Rggb), "odd y start");
        let frame = take(&mut cam, params(0.01, 2, None, FrameType::Light)).await;
        assert_eq!(frame.bayer_pattern, None, "a binned color frame is not a mosaic");
        cam.disconnect().await.unwrap();

        let mut guide = connected(GUIDE_CAM).await;
        assert_eq!(guide.get_sensor_info().bayer_pattern, Some(BayerPattern::Rggb));
        guide.disconnect().await.unwrap();

        let mut mono = connected(LEGACY_CCD).await;
        let sensor = mono.get_sensor_info();
        assert!(!sensor.color);
        assert_eq!(sensor.bayer_pattern, None);
        mono.disconnect().await.unwrap();
    }

    #[tokio::test(flavor = "multi_thread")]
    #[ignore = "run by qhy_driver_against_the_fake_sdk"]
    async fn each_exposure_applies_its_binning_and_subframe() {
        let fake = Fake::new();
        let mut cam = connected(COLOR_CMOS).await;
        let sensor = cam.get_sensor_info();
        assert_eq!((sensor.width, sensor.height), (72, 56), "the effective area, no overscan");

        let frame = take(&mut cam, params(0.01, 2, None, FrameType::Light)).await;
        assert_eq!(fake.get(COLOR_CMOS, key::STARTED_BIN), 2.0);
        assert_eq!(
            [
                key::STARTED_ROI_X,
                key::STARTED_ROI_Y,
                key::STARTED_ROI_W,
                key::STARTED_ROI_H
            ]
            .map(|k| fake.get(COLOR_CMOS, k)),
            [2.0, 1.0, 36.0, 28.0]
        );
        assert_eq!((frame.width, frame.height), (36, 28));
        assert_eq!((frame.metadata.bin_x, frame.metadata.bin_y), (2, 2));
        assert_eq!(frame.data.len(), 36 * 28);

        let frame = take(&mut cam, params(0.01, 1, roi(10, 6, 20, 12), FrameType::Light)).await;
        assert_eq!(
            [
                key::STARTED_ROI_X,
                key::STARTED_ROI_Y,
                key::STARTED_ROI_W,
                key::STARTED_ROI_H
            ]
            .map(|k| fake.get(COLOR_CMOS, k)),
            [14.0, 8.0, 20.0, 12.0]
        );
        assert_eq!((frame.width, frame.height), (20, 12));
        assert_eq!((frame.metadata.bin_x, frame.metadata.bin_y), (1, 1));
        let sub = frame.metadata.subframe.expect("subframe recorded");
        assert_eq!((sub.start_x, sub.start_y, sub.width, sub.height), (10, 6, 20, 12));
        assert_eq!(frame.metadata.exposure_time, 0.01);
        assert_eq!((frame.metadata.gain, frame.metadata.offset), (55, 9));
        assert_eq!(fake.get(COLOR_CMOS, key::STARTED_GAIN), 55.0);
        assert_eq!(fake.get(COLOR_CMOS, key::STARTED_OFFSET), 9.0);
        assert_eq!(fake.get(COLOR_CMOS, key::STARTED_US), 10_000.0);

        let frame = take(&mut cam, params(0.01, 1, None, FrameType::Light)).await;
        assert_eq!((frame.width, frame.height), (72, 56));
        assert!(frame.metadata.subframe.is_none());

        let outside = cam
            .start_exposure(params(0.01, 1, roi(60, 50, 20, 12), FrameType::Light))
            .await;
        assert!(matches!(outside, Err(DriverError::InvalidParameter(_))), "{outside:?}");
        let unsupported = cam.start_exposure(params(0.01, 5, None, FrameType::Light)).await;
        assert!(matches!(unsupported, Err(DriverError::InvalidParameter(_))), "{unsupported:?}");
        cam.disconnect().await.unwrap();
    }

    #[tokio::test(flavor = "multi_thread")]
    #[ignore = "run by qhy_driver_against_the_fake_sdk"]
    async fn an_exposure_is_complete_only_after_its_duration() {
        let fake = Fake::new();
        let mut cam = connected(COLOR_CMOS).await;
        let started = Instant::now();
        cam.start_exposure(params(0.6, 1, None, FrameType::Light))
            .await
            .unwrap();
        assert!(!cam.is_exposure_complete().await.unwrap());
        let status = cam.get_status().await.unwrap();
        assert_eq!(status.state, CameraState::Exposing);
        assert!(status.exposure_remaining.is_some_and(|left| left > 0.3), "{status:?}");
        while !cam.is_exposure_complete().await.unwrap() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        assert!(started.elapsed() >= Duration::from_millis(590));
        let downloading = Instant::now();
        let frame = cam.download_image().await.unwrap();
        assert!(downloading.elapsed() < Duration::from_millis(300));
        assert_eq!(frame.metadata.exposure_time, 0.6);
        assert_eq!(fake.get(COLOR_CMOS, key::EXPOSING), 0.0);
        assert_eq!(cam.get_status().await.unwrap().state, CameraState::Idle);

        cam.start_exposure(params(5.0, 1, None, FrameType::Light))
            .await
            .unwrap();
        cam.abort_exposure().await.unwrap();
        assert_eq!(fake.get(COLOR_CMOS, key::EXPOSING), 0.0);
        assert_eq!(cam.get_status().await.unwrap().state, CameraState::Idle);
        cam.disconnect().await.unwrap();
    }

    #[tokio::test(flavor = "multi_thread")]
    #[ignore = "run by qhy_driver_against_the_fake_sdk"]
    async fn dark_and_bias_frames_close_the_mechanical_shutter() {
        let fake = Fake::new();
        let mut cam = connected(LEGACY_CCD).await;
        assert!(cam.capabilities().has_shutter);
        take(&mut cam, params(0.05, 1, None, FrameType::Dark)).await;
        assert_eq!(fake.get(LEGACY_CCD, key::SHUTTER_AT_START), 1.0, "closed");
        take(&mut cam, params(0.05, 1, None, FrameType::Light)).await;
        assert_eq!(fake.get(LEGACY_CCD, key::SHUTTER_AT_START), 2.0, "free");
        take(&mut cam, params(0.05, 1, None, FrameType::Bias)).await;
        assert_eq!(fake.get(LEGACY_CCD, key::SHUTTER_AT_START), 1.0, "closed");
        // This camera asks for a 200 ms pause after a bin change instead of
        // answering success; that is not a failure.
        let frame = take(&mut cam, params(0.05, 2, None, FrameType::Flat)).await;
        assert_eq!((frame.width, frame.height), (20, 15));
        assert_eq!(fake.get(LEGACY_CCD, key::SHUTTER_AT_START), 2.0, "free");
        cam.disconnect().await.unwrap();
    }

    #[tokio::test(flavor = "multi_thread")]
    #[ignore = "run by qhy_driver_against_the_fake_sdk"]
    async fn the_cooler_turns_off_and_reports_its_power_in_percent() {
        let fake = Fake::new();
        let mut cam = connected(COLOR_CMOS).await;
        cam.set_cooler(true, Some(-10.0)).await.unwrap();
        fake.set(COLOR_CMOS, 1, 255.0);
        assert_eq!(cam.get_cooler_power().await.unwrap(), 100.0);
        fake.set(COLOR_CMOS, 1, 51.0);
        let status = cam.get_status().await.unwrap();
        assert_eq!(status.cooler_power, Some(20.0));
        assert!(status.cooler_on);
        assert_eq!(status.target_temp, Some(-10.0));

        cam.set_cooler(false, None).await.expect("cooler off");
        assert_eq!(fake.get(COLOR_CMOS, key::MANUAL_PWM), 0.0);
        assert!(!cam.get_status().await.unwrap().cooler_on);
        cam.disconnect().await.unwrap();
    }

    #[tokio::test(flavor = "multi_thread")]
    #[ignore = "run by qhy_driver_against_the_fake_sdk"]
    async fn the_cooler_setpoint_is_sent_every_second_while_cooling() {
        let fake = Fake::new();
        let mut cam = connected(COLOR_CMOS).await;
        cam.set_cooler(true, Some(-10.0)).await.unwrap();
        let first = fake.get(COLOR_CMOS, key::COOLER_WRITES);
        tokio::time::sleep(Duration::from_millis(2600)).await;
        let later = fake.get(COLOR_CMOS, key::COOLER_WRITES);
        assert!(later >= first + 2.0, "{first} -> {later}");

        cam.set_cooler(false, None).await.unwrap();
        let stopped = fake.get(COLOR_CMOS, key::COOLER_WRITES);
        tokio::time::sleep(Duration::from_millis(1500)).await;
        assert_eq!(fake.get(COLOR_CMOS, key::COOLER_WRITES), stopped);

        cam.set_cooler(true, Some(-5.0)).await.unwrap();
        cam.disconnect().await.unwrap();
        let after_disconnect = fake.get(COLOR_CMOS, key::COOLER_WRITES);
        tokio::time::sleep(Duration::from_millis(1500)).await;
        assert_eq!(fake.get(COLOR_CMOS, key::COOLER_WRITES), after_disconnect);
    }

    #[tokio::test(flavor = "multi_thread")]
    #[ignore = "run by qhy_driver_against_the_fake_sdk"]
    async fn a_camera_without_a_thermometer_reports_no_temperature() {
        let _fake = Fake::new();
        let mut cam = connected(GUIDE_CAM).await;
        assert_eq!(cam.get_status().await.unwrap().sensor_temp, None);
        assert!(cam.get_temperature().await.is_err());
        let frame = take(&mut cam, params(0.01, 1, None, FrameType::Light)).await;
        assert_eq!(frame.metadata.temperature, None);
        cam.disconnect().await.unwrap();

        let mut cooled = connected(COLOR_CMOS).await;
        assert_eq!(cooled.get_status().await.unwrap().sensor_temp, Some(-9.25));
        cooled.disconnect().await.unwrap();
    }

    #[tokio::test(flavor = "multi_thread")]
    #[ignore = "run by qhy_driver_against_the_fake_sdk"]
    async fn the_filter_wheel_shares_the_cameras_session() {
        let fake = Fake::new();
        let mut cam = connected(COLOR_CMOS).await;
        assert_eq!(fake.get(COLOR_CMOS, key::INITS), 1.0);
        let mut wheel = qhy::QhyFilterWheel::new(IDS[0].to_string());
        wheel.connect().await.expect("wheel connect");
        assert_eq!(fake.get(COLOR_CMOS, key::INITS), 1.0, "the wheel must not re-initialize the camera");
        assert_eq!(fake.get(COLOR_CMOS, key::BITS), 16.0);
        assert_eq!(wheel.get_filter_count(), 7);
        wheel.move_to_position(3).await.expect("wheel move");
        assert_eq!(wheel.get_position().await.unwrap(), 3);

        cam.start_exposure(params(0.5, 1, None, FrameType::Light))
            .await
            .unwrap();
        let wheels = qhy::discover_filter_wheels().await.expect("wheel discovery");
        let ids: Vec<&str> = wheels.iter().map(|w| w.camera_id.as_str()).collect();
        assert_eq!(ids, vec![IDS[0]], "only the camera with a wheel attached");
        assert_eq!(wheels[0].slot_count, 7);
        assert_eq!(fake.get(COLOR_CMOS, key::EXPOSING), 1.0, "discovery must not end the exposure");
        assert_eq!(fake.get(COLOR_CMOS, key::CANCELS), 0.0);

        wheel.disconnect().await.unwrap();
        assert_eq!(fake.get(COLOR_CMOS, key::OPEN), 1.0, "the camera keeps its handle");
        while !cam.is_exposure_complete().await.unwrap() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        let frame = cam.download_image().await.expect("frame after the wheel left");
        assert_eq!((frame.width, frame.height), (72, 56));
        cam.disconnect().await.unwrap();
        assert_eq!(fake.get(COLOR_CMOS, key::OPEN), 0.0);
        assert_eq!(fake.get(COLOR_CMOS, key::CLOSES), 1.0);

        // The other order: the wheel first, then the camera.
        let mut wheel = qhy::QhyFilterWheel::new(IDS[0].to_string());
        wheel.connect().await.unwrap();
        let mut cam = qhy::QhyCamera::new(IDS[0].to_string());
        cam.connect().await.unwrap();
        assert_eq!(fake.get(COLOR_CMOS, key::INITS), 2.0, "one initialization per session");
        assert_eq!(fake.get(COLOR_CMOS, key::BITS), 16.0);
        cam.disconnect().await.unwrap();
        assert_eq!(fake.get(COLOR_CMOS, key::OPEN), 1.0, "the wheel keeps its handle");
        assert_eq!(wheel.get_position().await.unwrap(), 3);
        wheel.disconnect().await.unwrap();
        assert_eq!(fake.get(COLOR_CMOS, key::OPEN), 0.0);
        assert_eq!(fake.get(COLOR_CMOS, key::OPENS), 2.0);
    }

    #[tokio::test(flavor = "multi_thread")]
    #[ignore = "run by qhy_driver_against_the_fake_sdk"]
    async fn a_cfw_port_without_a_wheel_is_not_a_filter_wheel() {
        let _fake = Fake::new();
        let wheels = qhy::discover_filter_wheels().await.expect("wheel discovery");
        assert!(wheels.iter().all(|w| w.camera_id != IDS[1]), "slot count 255 means no wheel");
        let mut wheel = qhy::QhyFilterWheel::new(IDS[1].to_string());
        assert!(wheel.connect().await.is_err());
        assert!(!wheel.is_connected());
    }

    #[tokio::test(flavor = "multi_thread")]
    #[ignore = "run by qhy_driver_against_the_fake_sdk"]
    async fn a_read_mode_change_keeps_the_bit_depth_gain_and_offset() {
        let fake = Fake::new();
        let mut cam = connected(COLOR_CMOS).await;
        take(&mut cam, params(0.01, 1, None, FrameType::Light)).await;
        let modes = cam.get_readout_modes().await.unwrap();
        assert_eq!(modes.len(), 2);
        let high_gain: ReadoutMode = modes[1].clone();
        cam.set_readout_mode(&high_gain).await.unwrap();
        assert_eq!(fake.get(COLOR_CMOS, key::BITS), 16.0);
        assert_eq!(fake.get(COLOR_CMOS, key::GAIN_NOW), 55.0);
        let frame = take(
            &mut cam,
            ExposureParams {
                gain: None,
                offset: None,
                ..params(0.01, 1, None, FrameType::Light)
            },
        )
        .await;
        assert_eq!(frame.bits_per_pixel, 16);
        assert_eq!((frame.metadata.gain, frame.metadata.offset), (55, 9));
        assert_eq!(fake.get(COLOR_CMOS, key::STARTED_GAIN), 55.0);
        assert_eq!(fake.get(COLOR_CMOS, key::STARTED_OFFSET), 9.0);
        cam.disconnect().await.unwrap();
    }

    #[tokio::test(flavor = "multi_thread")]
    #[ignore = "run by qhy_driver_against_the_fake_sdk"]
    async fn settings_outside_the_camera_range_are_refused() {
        let _fake = Fake::new();
        let mut ccd = connected(LEGACY_CCD).await;
        assert_eq!(ccd.get_exposure_range().await.unwrap(), Some((0.001, 3600.0)));
        let short = ccd.start_exposure(params(0.0005, 1, None, FrameType::Light)).await;
        assert!(matches!(short, Err(DriverError::InvalidParameter(_))), "{short:?}");
        let gain = ccd
            .start_exposure(ExposureParams {
                gain: Some(150),
                ..params(0.01, 1, None, FrameType::Light)
            })
            .await;
        assert!(matches!(gain, Err(DriverError::InvalidParameter(_))), "{gain:?}");
        assert!(matches!(ccd.set_offset(300).await, Err(DriverError::InvalidParameter(_))));
        ccd.disconnect().await.unwrap();

        let mut guide = connected(GUIDE_CAM).await;
        let long = guide.start_exposure(params(700.0, 1, None, FrameType::Light)).await;
        assert!(matches!(long, Err(DriverError::InvalidParameter(_))), "{long:?}");
        guide.disconnect().await.unwrap();
    }

    #[tokio::test(flavor = "multi_thread")]
    #[ignore = "run by qhy_driver_against_the_fake_sdk"]
    async fn a_replugged_camera_connects_without_a_new_search() {
        let fake = Fake::new();
        let mut cam = connected(COLOR_CMOS).await;
        cam.disconnect().await.unwrap();
        fake.plug(COLOR_CMOS, false);
        let unplugged = cam.connect().await;
        assert!(unplugged.is_err());
        assert!(!cam.is_connected());
        fake.plug(COLOR_CMOS, true);
        cam.connect().await.expect("connect after the camera came back");
        cam.disconnect().await.unwrap();
    }

    #[tokio::test(flavor = "multi_thread")]
    #[ignore = "run by qhy_driver_against_the_fake_sdk"]
    async fn a_tripped_sensor_power_protection_is_reported() {
        let fake = Fake::new();
        fake.set(COLOR_CMOS, 0, 9.0);
        let mut cam = qhy::QhyCamera::new(IDS[0].to_string());
        qhy::discover_devices().await.unwrap();
        let refused = cam.connect().await;
        assert!(
            matches!(&refused, Err(DriverError::SdkError(text)) if text.contains("power")),
            "{refused:?}"
        );
        assert_eq!(fake.get(COLOR_CMOS, key::OPEN), 0.0);
    }
}
