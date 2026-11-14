//! The gPhoto2 driver against an independent fake libgphoto2.
//!
//! The fake (`tests/fake_sdk_linux/gphoto2_independent.c`) was written from
//! libgphoto2 2.5.34 (its headers and the sources of the widget, abilities and
//! camera code and of the ptp2 camlib's config.c and library.c) and the INDI gphoto
//! driver, separately from the driver and from `gphoto2_fake_sdk.rs`. The fake
//! keeps its cameras in static state, so the tests run in one child process, one
//! at a time.

#![cfg(target_os = "linux")]

#[path = "fake_sdk_linux/harness.rs"]
mod harness;

use skotiq_device::{
    BayerPattern, CameraDriver, DeviceDriver, ExposureParams, FrameType, LongExposureNoiseReduction,
};
use skotiq_native::vendor::gphoto2::GPhoto2Camera;
use std::ffi::{c_char, c_int, CStr, CString};
use std::sync::OnceLock;

#[test]
fn gphoto2_driver_against_the_independent_fake() {
    harness::FakeSdk::build("gphoto2_independent", &[harness::GPHOTO2_INDEPENDENT])
        .run_ignored("", &[]);
}

struct Fake {
    _lib: libloading::Library,
    reset: unsafe extern "C" fn(),
    add: unsafe extern "C" fn(*const c_char, *const c_char, *const c_char) -> c_int,
    set: unsafe extern "C" fn(c_int, *const c_char, *const c_char) -> c_int,
    get: unsafe extern "C" fn(c_int, *const c_char) -> *const c_char,
    log: unsafe extern "C" fn() -> *const c_char,
    clear_log: unsafe extern "C" fn(),
}

fn fake() -> &'static Fake {
    static FAKE: OnceLock<Fake> = OnceLock::new();
    FAKE.get_or_init(|| {
        // SAFETY: the library is the C fake; each field's type matches the C declaration
        // of the symbol it is read from, and `_lib` lives in the same static as the
        // pointers, so the library stays loaded for as long as they can be called.
        unsafe {
            let lib = libloading::Library::new("libgphoto2.so")
                .expect("the independent fake libgphoto2.so must be on LD_LIBRARY_PATH");
            assert!(
                lib.get::<unsafe extern "C" fn()>(b"fake_reset\0").is_ok(),
                "libgphoto2.so on LD_LIBRARY_PATH is not the independent fake"
            );
            Fake {
                reset: *lib.get(b"fake_reset\0").unwrap(),
                add: *lib.get(b"fake_add_camera\0").unwrap(),
                set: *lib.get(b"fake_set\0").unwrap(),
                get: *lib.get(b"fake_get\0").unwrap(),
                log: *lib.get(b"fake_log\0").unwrap(),
                clear_log: *lib.get(b"fake_clear_log\0").unwrap(),
                _lib: lib,
            }
        }
    })
}

impl Fake {
    fn reset(&self) {
        // SAFETY: no arguments; the fake clears its static state.
        unsafe { (self.reset)() }
    }
    fn add(&self, maker: &str, model: &str, port: &str) -> i32 {
        let (maker, model, port) = (
            CString::new(maker).unwrap(),
            CString::new(model).unwrap(),
            CString::new(port).unwrap(),
        );
        // SAFETY: the strings are NUL-terminated and outlive the call, which copies them.
        unsafe { (self.add)(maker.as_ptr(), model.as_ptr(), port.as_ptr()) }
    }
    fn set(&self, body: i32, key: &str, value: &str) {
        let (key_c, value) = (CString::new(key).unwrap(), CString::new(value).unwrap());
        // SAFETY: `body` is an index `add` returned; the strings outlive the call.
        let r = unsafe { (self.set)(body, key_c.as_ptr(), value.as_ptr()) };
        assert_eq!(r, 0, "fake key {key}");
    }
    fn get(&self, body: i32, key: &str) -> String {
        let key = CString::new(key).unwrap();
        // SAFETY: `body` is an index `add` returned; the answer is a NUL-terminated
        // string in the fake's static storage, copied before the next call.
        unsafe { CStr::from_ptr((self.get)(body, key.as_ptr())) }
            .to_string_lossy()
            .into_owned()
    }
    fn log(&self) -> String {
        // SAFETY: the log is a static NUL-terminated buffer.
        unsafe { CStr::from_ptr((self.log)()) }
            .to_string_lossy()
            .into_owned()
    }
    fn clear_log(&self) {
        // SAFETY: no arguments.
        unsafe { (self.clear_log)() }
    }
}

fn run<F: std::future::Future>(f: F) -> F::Output {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_time()
        .build()
        .unwrap()
        .block_on(f)
}

const CANON: &str = "Canon:EOS 6D";
const CANON_DETECTED: &str = "Canon EOS 6D";
const NIKON: &str = "Nikon:DSC D850";
const NIKON_DETECTED: &str = "Nikon DSC D850";

fn params(seconds: f64, iso: Option<i32>) -> ExposureParams {
    ExposureParams {
        duration_secs: seconds,
        gain: iso,
        offset: None,
        bin_x: 1,
        bin_y: 1,
        subframe: None,
        readout_mode: None,
        frame_type: FrameType::Light,
    }
}

async fn connected(model: &str, port: &str) -> GPhoto2Camera {
    let mut camera = GPhoto2Camera::new(0, model, port);
    camera.connect().await.expect("connect");
    camera
}

async fn expose(
    camera: &mut GPhoto2Camera,
    seconds: f64,
    iso: Option<i32>,
) -> skotiq_device::ImageData {
    camera
        .start_exposure(params(seconds, iso))
        .await
        .expect("start");
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    while !camera.is_exposure_complete().await.unwrap() {
        assert!(
            std::time::Instant::now() < deadline,
            "exposure never completed"
        );
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    camera.download_image().await.expect("download")
}

#[test]
#[ignore = "run by gphoto2_driver_against_the_independent_fake"]
fn each_of_two_bodies_opens_on_its_own_port() {
    let f = fake();
    f.reset();
    f.add("canon", CANON, "usb:001,005");
    let second = f.add("canon", CANON, "usb:001,006");
    run(async {
        let camera = connected(CANON_DETECTED, "usb:001,006").await;
        assert!(f.log().contains("port='usb:001,006' -> 1"), "{}", f.log());
        assert_eq!(camera.serial_number().as_deref(), Some("SN00002"));
        let _ = second;
    });
}

#[test]
#[ignore = "run by gphoto2_driver_against_the_independent_fake"]
fn a_replugged_body_is_found_on_its_new_port() {
    let f = fake();
    f.reset();
    f.add("canon", CANON, "usb:002,009");
    run(async {
        connected(CANON_DETECTED, "usb:001,005").await;
        assert!(f.log().contains("port='usb:002,009' -> 0"), "{}", f.log());
    });
}

#[test]
#[ignore = "run by gphoto2_driver_against_the_independent_fake"]
fn the_gain_is_the_body_iso_read_at_connect_and_its_own_list() {
    let f = fake();
    f.reset();
    let body = f.add("canon", CANON, "usb:001,005");
    f.set(body, "iso", "800");
    run(async {
        let mut camera = connected(CANON_DETECTED, "usb:001,005").await;
        assert_eq!(camera.get_gain().await.unwrap(), 800);
        assert_eq!(camera.get_status().await.unwrap().gain, 800);
        let speeds = camera.get_iso_speeds().await.unwrap();
        assert_eq!(speeds.first(), Some(&100));
        assert_eq!(speeds.last(), Some(&25600));
        assert!(!speeds.contains(&0), "Auto ISO is no speed");
        assert!(camera.capabilities().can_set_gain);
        assert!(!camera.capabilities().can_cool);
        assert_eq!(camera.get_gain_range().await.unwrap(), (100, 25600));

        camera.set_gain(1600).await.unwrap();
        assert_eq!(f.get(body, "iso"), "1600");
        assert_eq!(camera.get_gain().await.unwrap(), 1600);
        // 900 lies nearer 1000 than 800 by ratio.
        camera.set_gain(900).await.unwrap();
        assert_eq!(f.get(body, "iso"), "1000");
        assert_eq!(camera.get_gain().await.unwrap(), 1000);
    });
}

#[test]
#[ignore = "run by gphoto2_driver_against_the_independent_fake"]
fn long_exposure_noise_reduction_is_switched_off_at_connect() {
    let f = fake();
    f.reset();
    let body = f.add("nikon", NIKON, "usb:001,007");
    f.set(body, "longexpnr", "On");
    run(async {
        let camera = connected(NIKON_DETECTED, "usb:001,007").await;
        assert_eq!(f.get(body, "longexpnr"), "Off");
        assert_eq!(
            camera.long_exposure_noise_reduction(),
            LongExposureNoiseReduction::Off
        );
    });
    f.reset();
    let body = f.add("nikon", NIKON, "usb:001,007");
    f.set(body, "longexpnr", "On");
    f.set(body, "longexpnr_stuck", "1");
    run(async {
        let camera = connected(NIKON_DETECTED, "usb:001,007").await;
        assert_eq!(
            camera.long_exposure_noise_reduction(),
            LongExposureNoiseReduction::StaysOn
        );
    });
}

#[test]
#[ignore = "run by gphoto2_driver_against_the_independent_fake"]
fn a_timed_frame_records_the_speed_and_iso_the_camera_used() {
    let f = fake();
    f.reset();
    let body = f.add("canon", CANON, "usb:001,005");
    run(async {
        let mut camera = connected(CANON_DETECTED, "usb:001,005").await;
        let frame = expose(&mut camera, 0.5, Some(1600)).await;
        assert_eq!(f.get(body, "format"), "RAW", "a body on JPEG is set to RAW");
        assert_eq!(f.get(body, "shutter"), "0.5");
        assert!(
            (frame.metadata.exposure_time - 0.5).abs() < 1e-6,
            "{}",
            frame.metadata.exposure_time
        );
        assert_eq!(frame.metadata.gain, 1600);
        assert_eq!(frame.bayer_pattern, Some(BayerPattern::Rggb.into()));
        assert_eq!((frame.width, frame.height), (64, 48));
        assert_eq!(camera.get_sensor_info().pixel_size_x, 6.54);
        assert!(f.log().contains("capture 0.5"), "{}", f.log());
        assert!(!f.log().contains("eosremoterelease=Press"), "{}", f.log());
    });
}

#[test]
#[ignore = "run by gphoto2_driver_against_the_independent_fake"]
fn a_sub_second_request_between_speeds_takes_the_nearest_speed_not_bulb() {
    let f = fake();
    f.reset();
    let body = f.add("canon", CANON, "usb:001,005");
    run(async {
        let mut camera = connected(CANON_DETECTED, "usb:001,005").await;
        let frame = expose(&mut camera, 0.7, None).await;
        let shutter = f.get(body, "shutter");
        assert!(shutter == "0.6" || shutter == "0.8", "{shutter}");
        let speed: f64 = shutter.parse().unwrap();
        assert!(
            (frame.metadata.exposure_time - speed).abs() < 1e-4,
            "{}",
            frame.metadata.exposure_time
        );
        assert_eq!(frame.metadata.gain, 800, "the frame records the body's ISO");
    });
}

#[test]
#[ignore = "run by gphoto2_driver_against_the_independent_fake"]
fn canon_bulb_presses_and_releases_eosremoterelease_and_records_the_open_time() {
    let f = fake();
    f.reset();
    let body = f.add("canon", CANON, "usb:001,005");
    run(async {
        let mut camera = connected(CANON_DETECTED, "usb:001,005").await;
        f.clear_log();
        let frame = expose(&mut camera, 1.5, None).await;
        let log = f.log();
        assert_eq!(f.get(body, "shutter"), "bulb");
        let press = log.find("set eosremoterelease=Press Full MF").expect(&log);
        let release = log.find("set eosremoterelease=Release\n").expect(&log);
        assert!(press < release);
        assert!(
            !log.contains("capture "),
            "bulb takes no timed capture: {log}"
        );
        let t = frame.metadata.exposure_time;
        assert!((1.45..1.8).contains(&t), "{t}");
    });
}

#[test]
#[ignore = "run by gphoto2_driver_against_the_independent_fake"]
fn nikon_bulb_uses_the_bulb_toggle_with_shutterspeed2_on_bulb() {
    let f = fake();
    f.reset();
    let body = f.add("nikon", NIKON, "usb:001,007");
    f.set(body, "format", "NEF (Raw)");
    run(async {
        let mut camera = connected(NIKON_DETECTED, "usb:001,007").await;
        f.clear_log();
        let frame = expose(&mut camera, 1.2, Some(400)).await;
        let log = f.log();
        assert!(log.contains("set shutterspeed2=Bulb"), "{log}");
        assert!(
            log.contains("set bulb=1") && log.contains("set bulb=0"),
            "{log}"
        );
        assert_eq!(frame.metadata.gain, 400);
        let t = frame.metadata.exposure_time;
        assert!((1.15..1.5).contains(&t), "{t}");
        assert_eq!(camera.get_sensor_info().pixel_size_x, 4.35);
    });
}

#[test]
#[ignore = "run by gphoto2_driver_against_the_independent_fake"]
fn nikon_shutterspeed2_fractions_are_read_as_seconds() {
    let f = fake();
    f.reset();
    let body = f.add("nikon", NIKON, "usb:001,007");
    f.set(body, "format", "NEF (Raw)");
    run(async {
        let mut camera = connected(NIKON_DETECTED, "usb:001,007").await;
        let frame = expose(&mut camera, 1.3, None).await;
        assert_eq!(f.get(body, "shutter"), "13/10");
        assert!((frame.metadata.exposure_time - 1.3).abs() < 1e-6);
        assert_eq!(
            camera.get_exposure_range().await.unwrap(),
            Some((1.0 / 8000.0, 3600.0))
        );
    });
}

#[test]
#[ignore = "run by gphoto2_driver_against_the_independent_fake"]
fn a_frame_kept_on_the_memory_card_stays_there() {
    let f = fake();
    f.reset();
    let body = f.add("canon", CANON, "usb:001,005");
    f.set(body, "target", "Memory card");
    run(async {
        let mut camera = connected(CANON_DETECTED, "usb:001,005").await;
        let frame = expose(&mut camera, 0.5, None).await;
        let kept = frame.metadata.camera_file.as_ref().unwrap();
        assert!(kept.file_name.ends_with(".CR2"), "{}", kept.file_name);
        assert!(
            f.log()
                .contains("file_get /store_00020001/DCIM/100CANON/IMG_0001.CR2"),
            "{}",
            f.log()
        );
        // INDI keeps a card frame unless told to delete it (gphoto_driver.cpp:1008-1022,
        // handle_sdcard_image defaults to SAVE_IMAGE): the card is the owner's copy.
        let files = f.get(body, "files");
        assert!(files.contains("IMG_0001.CR2"), "{files}");
    });
}

#[test]
#[ignore = "run by gphoto2_driver_against_the_independent_fake"]
fn a_frame_in_the_camera_memory_is_deleted_after_it_is_read() {
    let f = fake();
    f.reset();
    let body = f.add("canon", CANON, "usb:001,005");
    run(async {
        let mut camera = connected(CANON_DETECTED, "usb:001,005").await;
        expose(&mut camera, 0.5, None).await;
        assert!(
            f.log().contains("file_delete //capt0000.cr2"),
            "{}",
            f.log()
        );
        assert_eq!(f.get(body, "files"), "");
    });
}

#[test]
#[ignore = "run by gphoto2_driver_against_the_independent_fake"]
fn a_body_with_no_pure_raw_reads_the_raw_of_its_raw_and_jpeg_pair() {
    let f = fake();
    f.reset();
    let body = f.add("canon", CANON, "usb:001,005");
    f.set(body, "format", "RAW + Large Fine JPEG");
    f.set(body, "jpeg_first", "1");
    f.set(body, "no_pure_raw", "1");
    run(async {
        let mut camera = connected(CANON_DETECTED, "usb:001,005").await;
        let frame = expose(&mut camera, 0.5, None).await;
        assert!((frame.metadata.exposure_time - 0.5).abs() < 1e-4);
        let log = f.log();
        assert!(log.contains("file_get //capt0001.cr2"), "{log}");
        assert!(
            !log.contains("file_get //capt0000.jpg"),
            "the JPEG is not decoded: {log}"
        );
        assert_eq!(
            f.get(body, "files"),
            "",
            "both files left the camera memory"
        );
    });
}

#[test]
#[ignore = "run by gphoto2_driver_against_the_independent_fake"]
fn a_long_request_with_no_bulb_in_the_mode_says_to_turn_the_dial() {
    let f = fake();
    f.reset();
    let body = f.add("canon", CANON, "usb:001,005");
    f.set(body, "no_bulb_choice", "1");
    run(async {
        let mut camera = connected(CANON_DETECTED, "usb:001,005").await;
        let err = camera.start_exposure(params(45.0, None)).await.unwrap_err();
        assert!(format!("{err}").contains("mode dial"), "{err}");
        assert_eq!(f.get(body, "bulb_open"), "0");
    });
}

#[test]
#[ignore = "run by gphoto2_driver_against_the_independent_fake"]
fn an_aborted_bulb_frame_is_closed_and_discarded() {
    let f = fake();
    f.reset();
    let body = f.add("canon", CANON, "usb:001,005");
    f.set(body, "format", "RAW");
    run(async {
        let mut camera = connected(CANON_DETECTED, "usb:001,005").await;
        // 7 s is no Canon speed (6 and 8 are), so it is a bulb frame.
        camera.start_exposure(params(7.0, None)).await.unwrap();
        assert_eq!(f.get(body, "bulb_open"), "1");
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        camera.abort_exposure().await.unwrap();
        assert_eq!(f.get(body, "bulb_open"), "0");
        assert_eq!(f.get(body, "files"), "");
        assert!(camera.is_exposure_complete().await.unwrap());
    });
}

#[test]
#[ignore = "run by gphoto2_driver_against_the_independent_fake"]
fn a_body_unplugged_between_frames_fails_its_next_exposure_in_words() {
    let f = fake();
    f.reset();
    let body = f.add("canon", CANON, "usb:001,005");
    run(async {
        let mut camera = connected(CANON_DETECTED, "usb:001,005").await;
        f.set(body, "attached", "0");
        let err = camera.start_exposure(params(0.5, None)).await.unwrap_err();
        assert!(!format!("{err}").is_empty());
    });
}
