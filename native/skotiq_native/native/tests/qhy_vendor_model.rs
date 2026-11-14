//! The QHY driver against `tests/qhy_vendor_model/libqhyccd.rs`, a software
//! camera written from the QHY SDK headers, the vendor library's binary and
//! the INDI and NINA drivers (see that file's header for what it enforces),
//! independently of `tests/qhy_fake_sdk`.
//!
//! `qhy_driver_against_the_vendor_model` builds the model with rustc and runs
//! each `vendor_model` test in its own child process that finds the model on
//! `LD_LIBRARY_PATH`: the SDK and the driver's camera sessions are
//! process-wide, so one failed test must not leave a session to the next.

#![cfg(target_os = "linux")]

#[path = "fake_sdk_linux/harness.rs"]
mod harness;

#[test]
fn qhy_driver_against_the_vendor_model() {
    harness::FakeSdk::build("qhy_vendor_model", &[harness::QHY_VENDOR_MODEL])
        .run_each("vendor_model::", &[]);
}

mod vendor_model {
    use skotiq_device::{BayerPattern, CameraDriver, CameraState, DeviceDriver, DriverError};
    use skotiq_device::{
        ExposureParams, FilterWheelDriver, FrameType, ImageData, ReadoutMode, SubFrame,
    };
    use skotiq_native::vendor::qhy::{self, QhyCamera, QhyFilterWheel};
    use std::ffi::{c_char, c_uint};
    use std::sync::OnceLock;
    use std::time::Duration;

    const COLOR_WITH_WHEEL: c_uint = 0;
    const CCD_WITH_SHUTTER: c_uint = 1;
    const UNCOOLED_COLOR: c_uint = 2;

    const COLOR_ID: &str = "QHY268C-1a2b3c";
    const CCD_ID: &str = "QHY9S-M-0077";
    const UNCOOLED_ID: &str = "QHY5III462C-9a";

    struct Model(libloading::Library);

    fn model() -> &'static Model {
        static MODEL: OnceLock<Model> = OnceLock::new();
        MODEL.get_or_init(|| {
            // SAFETY: the same library the driver loads; its initializers have no side effects.
            Model(
                unsafe { libloading::Library::new("libqhyccd.so") }
                    .expect("the QHY model on LD_LIBRARY_PATH"),
            )
        })
    }

    impl Model {
        fn reset(&self, which: c_uint) {
            // SAFETY: model_reset(c_uint) is defined by the model library.
            unsafe {
                self.0
                    .get::<unsafe extern "C" fn(c_uint)>(b"model_reset\0")
                    .unwrap()(which)
            }
        }

        fn text(&self, faults: bool) -> String {
            let mut buf = vec![0 as c_char; 1 << 20];
            // SAFETY: model_log writes at most `len` bytes, NUL included.
            unsafe {
                self.0
                    .get::<unsafe extern "C" fn(bool, *mut c_char, usize) -> usize>(b"model_log\0")
                    .unwrap()(faults, buf.as_mut_ptr(), buf.len());
                std::ffi::CStr::from_ptr(buf.as_ptr())
                    .to_string_lossy()
                    .into_owned()
            }
        }

        fn log(&self) -> String {
            self.text(false)
        }

        fn faults(&self) -> String {
            self.text(true)
        }

        fn clear_log(&self) {
            // SAFETY: model_clear_log() takes no arguments.
            unsafe {
                self.0
                    .get::<unsafe extern "C" fn()>(b"model_clear_log\0")
                    .unwrap()()
            }
        }

        fn status(&self) -> Status {
            let mut v = [0.0f64; 12];
            // SAFETY: model_status writes 12 doubles.
            unsafe {
                self.0
                    .get::<unsafe extern "C" fn(*mut f64)>(b"model_status\0")
                    .unwrap()(v.as_mut_ptr())
            }
            Status {
                opens: v[0] as u32,
                closes: v[1] as u32,
                open: v[2] != 0.0,
                gain: v[4],
                offset: v[5],
                bits: v[6] as u32,
                read_mode: v[7] as u32,
                longest_setpoint_gap_ms: v[8],
                regulation_lapsed: v[9] != 0.0,
                cooler_mode: v[10] as u32,
                cooler_target: v[11],
            }
        }

        fn assert_no_faults(&self) {
            let faults = self.faults();
            assert!(faults.is_empty(), "the camera model saw faults:\n{faults}");
        }
    }

    #[derive(Debug)]
    struct Status {
        opens: u32,
        closes: u32,
        open: bool,
        gain: f64,
        offset: f64,
        bits: u32,
        read_mode: u32,
        longest_setpoint_gap_ms: f64,
        regulation_lapsed: bool,
        cooler_mode: u32,
        cooler_target: f64,
    }

    fn params(
        seconds: f64,
        bin: i32,
        subframe: Option<SubFrame>,
        frame_type: FrameType,
    ) -> ExposureParams {
        ExposureParams {
            duration_secs: seconds,
            gain: None,
            offset: None,
            bin_x: bin,
            bin_y: bin,
            subframe,
            readout_mode: None,
            frame_type,
        }
    }

    fn light(seconds: f64, bin: i32, subframe: Option<SubFrame>) -> ExposureParams {
        params(seconds, bin, subframe, FrameType::Light)
    }

    fn sub(start_x: u32, start_y: u32, width: u32, height: u32) -> SubFrame {
        SubFrame {
            start_x,
            start_y,
            width,
            height,
        }
    }

    async fn connected(which: c_uint, id: &str) -> QhyCamera {
        model().reset(which);
        let mut camera = QhyCamera::new(id.to_string());
        camera.connect().await.expect("connect");
        camera
    }

    async fn take(camera: &mut QhyCamera, p: ExposureParams) -> ImageData {
        let seconds = p.duration_secs;
        camera.start_exposure(p).await.expect("start exposure");
        tokio::time::sleep(Duration::from_secs_f64(seconds)).await;
        while !camera.is_exposure_complete().await.expect("poll") {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        camera.download_image().await.expect("download")
    }

    /// The model's pixels carry their unbinned sensor column and row (mod 256).
    fn sensor_origin(frame: &ImageData) -> (u32, u32) {
        let v = u32::from(frame.data[0]);
        (v & 0xFF, v >> 8)
    }

    #[tokio::test]
    #[ignore = "run by qhy_driver_against_the_vendor_model"]
    async fn a_color_camera_frames_its_imaging_area_and_names_the_sdk_bayer_pattern() {
        let mut camera = connected(COLOR_WITH_WHEEL, COLOR_ID).await;
        let info = camera.get_sensor_info();
        assert_eq!(
            (info.width, info.height),
            (600, 460),
            "the effective area, not the chip"
        );
        assert_eq!(
            info.bayer_pattern,
            Some(BayerPattern::Rggb.into()),
            "BAYER_RG"
        );
        let log = model().log();
        assert!(log.contains("SetQHYCCDDebayerOnOff(false)"), "{log}");
        assert!(log.contains("SetQHYCCDBitsMode(16)"), "{log}");

        model().clear_log();
        camera.start_exposure(light(0.4, 1, None)).await.unwrap();
        assert!(
            !camera.is_exposure_complete().await.unwrap(),
            "a 0.4 s exposure is not over at once"
        );
        let status = camera.get_status().await.unwrap();
        assert_eq!(status.state, CameraState::Exposing);
        assert!(status
            .exposure_remaining
            .is_some_and(|r| r > 0.0 && r <= 0.4));
        tokio::time::sleep(Duration::from_millis(450)).await;
        assert!(camera.is_exposure_complete().await.unwrap());
        let frame = camera.download_image().await.unwrap();
        assert_eq!((frame.width, frame.height), (600, 460));
        assert_eq!(
            sensor_origin(&frame),
            (16, 8),
            "the frame starts at the effective area"
        );
        assert_eq!(frame.bayer_pattern, Some(BayerPattern::Rggb.into()));
        let log = model().log();
        assert!(
            log.contains("ExpQHYCCDSingleFrame 400000us bin 1 window 16,8 600x460"),
            "{log}"
        );
        camera.disconnect().await.unwrap();
        model().assert_no_faults();
    }

    #[tokio::test]
    #[ignore = "run by qhy_driver_against_the_vendor_model"]
    async fn binned_and_subframed_windows_read_the_right_sensor_pixels() {
        let mut camera = connected(COLOR_WITH_WHEEL, COLOR_ID).await;

        let frame = take(&mut camera, light(0.05, 2, None)).await;
        assert_eq!((frame.width, frame.height), (300, 230));
        assert_eq!(sensor_origin(&frame), (16, 8));
        assert_eq!(
            frame.bayer_pattern, None,
            "a binned color frame is no mosaic (NINA)"
        );

        let frame = take(&mut camera, light(0.05, 1, Some(sub(3, 2, 100, 50)))).await;
        assert_eq!((frame.width, frame.height), (100, 50));
        assert_eq!(sensor_origin(&frame), (19, 10));
        assert_eq!(
            frame.bayer_pattern,
            Some(BayerPattern::Grbg.into()),
            "RGGB seen one column on"
        );

        let frame = take(&mut camera, light(0.05, 2, Some(sub(5, 5, 50, 40)))).await;
        assert_eq!((frame.width, frame.height), (50, 40));
        assert_eq!(
            sensor_origin(&frame),
            (26, 18),
            "binned subframe origin (8+5, 4+5) x 2"
        );

        let frame = take(&mut camera, light(0.05, 1, None)).await;
        assert_eq!(
            (frame.width, frame.height),
            (600, 460),
            "back to the whole imaging area"
        );

        let too_big = camera
            .start_exposure(light(0.05, 2, Some(sub(0, 0, 301, 10))))
            .await;
        assert!(
            matches!(too_big, Err(DriverError::InvalidParameter(_))),
            "{too_big:?}"
        );
        camera.disconnect().await.unwrap();
        model().assert_no_faults();
    }

    #[tokio::test]
    #[ignore = "run by qhy_driver_against_the_vendor_model"]
    async fn the_cooler_keeps_regulating_through_an_exposure_and_turns_off_with_zero_power() {
        let mut camera = connected(COLOR_WITH_WHEEL, COLOR_ID).await;
        camera.set_cooler(true, Some(-10.0)).await.unwrap();
        let frame = take(&mut camera, light(3.5, 1, None)).await;
        assert_eq!(frame.width, 600);
        tokio::time::sleep(Duration::from_secs(2)).await;
        let model_status = model().status();
        assert_eq!(
            (model_status.cooler_mode, model_status.cooler_target),
            (1, -10.0)
        );
        assert!(!model_status.regulation_lapsed, "{model_status:?}");
        assert!(
            model_status.longest_setpoint_gap_ms < 1600.0,
            "{model_status:?}"
        );
        let power = camera.get_cooler_power().await.unwrap();
        assert!(
            (power - 50.0).abs() < 1e-6,
            "CURPWM 127.5 of 255 is 50 %, got {power}"
        );
        let status = camera.get_status().await.unwrap();
        assert_eq!(status.cooler_on, Some(true));
        assert_eq!(status.target_temp, Some(-10.0));
        assert!(status.sensor_temp.is_some());

        camera.set_cooler(false, None).await.unwrap();
        assert_eq!(
            model().status().cooler_mode,
            0,
            "CONTROL_MANULPWM 0 switches the TEC off"
        );
        let log_len = model().log().len();
        tokio::time::sleep(Duration::from_millis(2500)).await;
        let later = model().log();
        assert!(
            !later[log_len..].contains("SetQHYCCDParam(18,"),
            "no set-point after the cooler is off"
        );
        camera.disconnect().await.unwrap();
        model().assert_no_faults();
    }

    #[tokio::test]
    #[ignore = "run by qhy_driver_against_the_vendor_model"]
    async fn a_camera_without_thermometer_or_wheel_says_so() {
        let mut camera = connected(UNCOOLED_COLOR, UNCOOLED_ID).await;
        assert!(!camera.capabilities().can_cool);
        assert!(matches!(
            camera.get_temperature().await,
            Err(DriverError::NotSupported)
        ));
        let status = camera.get_status().await.unwrap();
        assert_eq!(status.sensor_temp, None);
        assert_eq!(status.cooler_power, None);
        assert_eq!(
            camera.get_sensor_info().bayer_pattern,
            Some(BayerPattern::Gbrg.into()),
            "BAYER_GB"
        );
        let frame = take(&mut camera, light(0.05, 1, None)).await;
        assert_eq!(
            frame.bits_per_pixel, 16,
            "a camera that powers up at 8 bits is put at 16"
        );

        let wheels = qhy::discover_filter_wheels().await.unwrap();
        assert!(
            wheels.is_empty(),
            "a CFW port that counts 255 slots has no wheel"
        );
        let mut wheel = QhyFilterWheel::new(UNCOOLED_ID.to_string());
        assert!(matches!(
            wheel.connect().await,
            Err(DriverError::DeviceNotFound(_))
        ));
        assert!(
            model().status().open,
            "the failed wheel left the camera open"
        );
        let frame = take(&mut camera, light(0.05, 1, None)).await;
        assert_eq!(frame.width, 320);
        camera.disconnect().await.unwrap();
        assert!(!model().status().open);
        model().assert_no_faults();
    }

    #[tokio::test]
    #[ignore = "run by qhy_driver_against_the_vendor_model"]
    async fn darks_close_the_shutter_and_a_read_directly_camera_is_read_at_once() {
        let mut camera = connected(CCD_WITH_SHUTTER, CCD_ID).await;
        assert!(camera.capabilities().has_shutter);

        model().clear_log();
        camera
            .start_exposure(params(0.6, 2, None, FrameType::Dark))
            .await
            .unwrap();
        assert!(
            camera.is_exposure_complete().await.unwrap(),
            "QHYCCD_READ_DIRECTLY: read just after the start (qhyccderr.h)"
        );
        let frame = camera.download_image().await.unwrap();
        assert_eq!((frame.width, frame.height), (195, 148));
        let log = model().log();
        assert!(
            log.contains("shutter Some(1)"),
            "MACHANICALSHUTTER_CLOSE for a dark:\n{log}"
        );

        model().clear_log();
        camera
            .start_exposure(params(0.2, 1, None, FrameType::Light))
            .await
            .unwrap();
        camera.download_image().await.unwrap();
        let log = model().log();
        assert!(
            log.contains("shutter Some(2)") || log.contains("shutter Some(0)"),
            "a light frame opens (NINA) or frees (INDI) the shutter:\n{log}"
        );
        camera.disconnect().await.unwrap();
        model().assert_no_faults();
    }

    #[tokio::test]
    #[ignore = "run by qhy_driver_against_the_vendor_model"]
    async fn a_read_mode_change_keeps_gain_offset_bits_and_cooling() {
        let mut camera = connected(COLOR_WITH_WHEEL, COLOR_ID).await;
        camera.set_gain(70).await.unwrap();
        camera.set_offset(40).await.unwrap();
        camera.set_cooler(true, Some(-5.0)).await.unwrap();
        let modes = camera.get_readout_modes().await.unwrap();
        assert_eq!(modes.len(), 2);
        camera.set_readout_mode(&modes[1]).await.unwrap();
        let s = model().status();
        assert_eq!(
            (s.read_mode, s.gain, s.offset, s.bits),
            (1, 70.0, 40.0, 16),
            "{s:?}"
        );
        assert_eq!((s.cooler_mode, s.cooler_target), (1, -5.0), "{s:?}");
        let frame = take(&mut camera, light(0.05, 1, None)).await;
        assert_eq!(
            frame.metadata.readout_mode.as_deref(),
            Some("High Gain Mode")
        );
        assert_eq!(frame.metadata.gain, 70);
        camera.disconnect().await.unwrap();
        model().assert_no_faults();
    }

    #[tokio::test]
    #[ignore = "run by qhy_driver_against_the_vendor_model"]
    async fn after_a_read_mode_change_the_gain_reported_is_the_one_the_camera_uses() {
        let mut camera = connected(COLOR_WITH_WHEEL, COLOR_ID).await;
        assert_eq!(camera.get_status().await.unwrap().gain, 0);
        let mode = ReadoutMode {
            name: "High Gain Mode".into(),
            description: String::new(),
            index: 1,
            gain_min: None,
            gain_max: None,
            offset_min: None,
            offset_max: None,
        };
        camera.set_readout_mode(&mode).await.unwrap();
        let s = model().status();
        assert_eq!(
            (s.gain, s.offset),
            (56.0, 20.0),
            "the new mode's own defaults"
        );
        let status = camera.get_status().await.unwrap();
        assert_eq!(
            (status.gain, status.offset),
            (56, 20),
            "status after the mode change"
        );
        let frame = take(&mut camera, light(0.05, 1, None)).await;
        assert_eq!(
            (frame.metadata.gain, frame.metadata.offset),
            (56, 20),
            "frame header"
        );
        camera.disconnect().await.unwrap();
        model().assert_no_faults();
    }

    #[tokio::test]
    #[ignore = "run by qhy_driver_against_the_vendor_model"]
    async fn the_wheel_and_the_camera_share_one_open_camera() {
        let mut camera = connected(COLOR_WITH_WHEEL, COLOR_ID).await;
        camera.start_exposure(light(1.5, 1, None)).await.unwrap();

        let wheels = qhy::discover_filter_wheels().await.unwrap();
        assert_eq!(wheels.len(), 1);
        assert_eq!(wheels[0].slot_count, 7);
        let mut wheel = QhyFilterWheel::new(COLOR_ID.to_string());
        wheel.connect().await.expect("wheel connect");
        assert_eq!(wheel.get_filter_count().await, 7);

        tokio::time::sleep(Duration::from_millis(1600)).await;
        let frame = camera
            .download_image()
            .await
            .expect("the exposure survived the wheel");
        assert_eq!(frame.width, 600);
        assert_eq!(model().status().opens, 1);

        wheel.move_to_position(3).await.unwrap();
        assert_eq!(wheel.get_position().await.unwrap(), 3);
        assert!(!wheel.is_moving().await.unwrap());
        assert!(model().log().contains("CFW order 3"));

        camera.disconnect().await.unwrap();
        assert!(model().status().open, "the wheel still holds the camera");
        wheel.move_to_position(0).await.unwrap();
        assert_eq!(wheel.get_position().await.unwrap(), 0);

        let mut camera = QhyCamera::new(COLOR_ID.to_string());
        camera.connect().await.unwrap();
        take(&mut camera, light(0.05, 1, None)).await;
        wheel.disconnect().await.unwrap();
        assert!(model().status().open, "the camera still holds it");
        camera.disconnect().await.unwrap();
        let s = model().status();
        assert_eq!((s.open, s.opens, s.closes), (false, 1, 1), "{s:?}");
        model().assert_no_faults();
    }

    #[tokio::test]
    #[ignore = "run by qhy_driver_against_the_vendor_model"]
    async fn an_aborted_exposure_is_not_read_and_the_next_one_works() {
        let mut camera = connected(COLOR_WITH_WHEEL, COLOR_ID).await;
        camera.start_exposure(light(2.0, 1, None)).await.unwrap();
        tokio::time::sleep(Duration::from_millis(200)).await;
        camera.abort_exposure().await.unwrap();
        assert_eq!(camera.get_status().await.unwrap().state, CameraState::Idle);
        assert!(camera.download_image().await.is_err());
        let frame = take(&mut camera, light(0.1, 1, None)).await;
        assert_eq!(frame.width, 600);
        camera.disconnect().await.unwrap();
        model().assert_no_faults();
    }

    #[tokio::test]
    #[ignore = "run by qhy_driver_against_the_vendor_model"]
    async fn disconnecting_during_an_exposure_ends_it() {
        let mut camera = connected(COLOR_WITH_WHEEL, COLOR_ID).await;
        camera.start_exposure(light(2.0, 1, None)).await.unwrap();
        camera.disconnect().await.unwrap();
        let s = model().status();
        assert_eq!((s.open, s.closes), (false, 1));
        let mut camera = QhyCamera::new(COLOR_ID.to_string());
        camera.connect().await.unwrap();
        let frame = take(&mut camera, light(0.05, 1, None)).await;
        assert_eq!(frame.width, 600);
        camera.disconnect().await.unwrap();
        model().assert_no_faults();
    }
}
