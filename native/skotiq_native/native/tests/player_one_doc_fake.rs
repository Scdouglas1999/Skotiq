//! The Player One drivers against `fixtures/player_one_doc_fake.c`, a fake SDK written from
//! PlayerOneCamera.h and PlayerOnePW.h alone and compiled against those headers, kept apart
//! from the fake in `native_driver_tests.rs` that was written alongside the driver.
//!
//! The headers ship in indi-3rdparty (`libplayerone/`). The tests share one loaded SDK, so
//! they run in one process, one at a time:
//!
//! ```sh
//! cc -shared -fPIC -O1 -I<indi-3rdparty>/libplayerone \
//!     native/tests/fixtures/player_one_doc_fake.c -o /tmp/poa/libPlayerOneCamera.so -lpthread
//! ln -sf libPlayerOneCamera.so /tmp/poa/libPlayerOnePW.so
//! cargo test --release -p skotiq_native --test player_one_doc_fake --no-run
//! FAKE_PW_HOMING_MS=800 LD_LIBRARY_PATH=/tmp/poa <test binary> --ignored --test-threads 1
//! ```

#![cfg(target_os = "linux")]

use skotiq_device::{CameraDriver, DeviceDriver, DriverError, ExposureParams, FilterWheelDriver, SubFrame};
use skotiq_native::vendor::player_one::{self, PlayerOneCamera, PlayerOneFilterWheel};
use std::ffi::{c_char, c_int, CStr};
use std::sync::OnceLock;
use std::time::{Duration, Instant};

const COLOR_ID: i32 = 7;
const MONO_ID: i32 = 3;
const NEEDS_FAKE: &str = "needs the document-based Player One fake on LD_LIBRARY_PATH (see the file header)";

struct Fake {
    log: unsafe extern "C" fn() -> *const c_char,
    clear_log: unsafe extern "C" fn(),
    overlaps: unsafe extern "C" fn() -> c_int,
    format: unsafe extern "C" fn(c_int) -> c_int,
    exposing: unsafe extern "C" fn(c_int) -> c_int,
    alias: unsafe extern "C" fn(c_int, *mut c_char, c_int) -> c_int,
    _library: libloading::Library,
}

/// The fake's own controls, from the same library the driver loads.
fn fake() -> &'static Fake {
    static FAKE: OnceLock<Fake> = OnceLock::new();
    FAKE.get_or_init(|| {
        // SAFETY: the library is the C fake; every symbol below has the signature given,
        // and `_library` keeps it loaded for as long as the pointers live.
        unsafe {
            let library = libloading::Library::new("libPlayerOneCamera.so").expect(NEEDS_FAKE);
            Fake {
                log: *library.get(b"fake_poa_log\0").expect("fake_poa_log"),
                clear_log: *library.get(b"fake_poa_clear_log\0").expect("fake_poa_clear_log"),
                overlaps: *library.get(b"fake_poa_overlaps\0").expect("fake_poa_overlaps"),
                format: *library.get(b"fake_poa_format\0").expect("fake_poa_format"),
                exposing: *library.get(b"fake_poa_exposing\0").expect("fake_poa_exposing"),
                alias: *library.get(b"fake_pw_alias\0").expect("fake_pw_alias"),
                _library: library,
            }
        }
    })
}

impl Fake {
    fn log(&self) -> Vec<String> {
        // SAFETY: the fake returns its NUL-terminated log buffer.
        let text = unsafe { CStr::from_ptr((self.log)()) }.to_string_lossy().into_owned();
        text.lines().map(str::to_string).collect()
    }
    fn clear(&self) {
        // SAFETY: no arguments.
        unsafe { (self.clear_log)() }
    }
    fn overlaps(&self) -> i32 {
        // SAFETY: no arguments.
        unsafe { (self.overlaps)() }
    }
    fn alias(&self, position: i32) -> String {
        let mut buf = [0 as c_char; 64];
        // SAFETY: buf is 64 bytes, longer than any alias the fake stores.
        let n = unsafe { (self.alias)(position, buf.as_mut_ptr(), 64) };
        assert!(n >= 0);
        // SAFETY: the fake NUL-terminates what it copies.
        unsafe { CStr::from_ptr(buf.as_ptr()) }.to_string_lossy().into_owned()
    }
    fn calls(&self, prefix: &str) -> Vec<String> {
        self.log().into_iter().filter(|line| line.starts_with(prefix)).collect()
    }
}

fn params(seconds: f64, bin: i32, subframe: Option<SubFrame>) -> ExposureParams {
    ExposureParams {
        duration_secs: seconds,
        gain: None,
        offset: None,
        bin_x: bin,
        bin_y: bin,
        subframe,
        readout_mode: None,
        frame_type: Default::default(),
    }
}

async fn connected(id: i32) -> PlayerOneCamera {
    let found = player_one::discover_devices().await.expect("discovery");
    assert!(found.iter().any(|c| c.camera_id == id), "camera {id} discovered");
    let mut camera = PlayerOneCamera::new(id);
    camera.connect().await.expect("connect");
    camera
}

async fn take(camera: &mut PlayerOneCamera, p: ExposureParams) -> skotiq_device::ImageData {
    camera.start_exposure(p).await.expect("start");
    let deadline = Instant::now() + Duration::from_secs(10);
    while !camera.is_exposure_complete().await.expect("ready") {
        assert!(Instant::now() < deadline, "frame never ready");
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    camera.download_image().await.expect("download")
}

#[tokio::test]
#[ignore = "needs the document-based Player One fake on LD_LIBRARY_PATH (see the file header)"]
async fn discovery_uses_the_camera_id_not_the_index() {
    let found = player_one::discover_devices().await.expect("discovery");
    let ids: Vec<i32> = found.iter().map(|c| c.camera_id).collect();
    assert_eq!(ids, vec![COLOR_ID, MONO_ID]);
    assert_eq!(found[1].serial_number.as_deref(), Some("PO-FAKE-0003"));
    assert_eq!(found[0].name, "Uranus-C Pro");

    fake().clear();
    let mut camera = connected(MONO_ID).await;
    let opens = fake().calls("POAOpenCamera");
    assert_eq!(opens, vec![format!("POAOpenCamera({MONO_ID})")]);
    assert_eq!(fake().calls("POAInitCamera"), vec![format!("POAInitCamera({MONO_ID})")]);
    // RAW16 is what the driver unpacks, so it must be the format the camera holds.
    // SAFETY: plain int arguments.
    assert_eq!(unsafe { (fake().format)(MONO_ID) }, 1, "POA_RAW16");
    let info = camera.get_sensor_info();
    assert_eq!((info.width, info.height), (128, 96));
    assert!(!info.color);
    assert!((info.pixel_size_x - 2.9).abs() < 1e-9);
    camera.disconnect().await.expect("disconnect");
    assert_eq!(fake().overlaps(), 0);
}

#[tokio::test]
#[ignore = "needs the document-based Player One fake on LD_LIBRARY_PATH (see the file header)"]
async fn a_frame_is_one_single_shot_exposure_set_in_seconds() {
    let mut camera = connected(COLOR_ID).await;
    fake().clear();
    let frame = take(&mut camera, params(0.05, 1, None)).await;
    assert_eq!(fake().calls("POAStartExposure"), vec![format!("POAStartExposure({COLOR_ID},1)")]);
    // POA_EXP (31) is a double holding seconds.
    assert!(
        fake().calls("POASetConfig").contains(&format!("POASetConfig({COLOR_ID},31,0.05,0)")),
        "{:?}",
        fake().calls("POASetConfig")
    );
    assert!((frame.metadata.exposure_time - 0.05).abs() < 1e-9);
    assert_eq!((frame.width, frame.height), (128, 96));
    assert_eq!(frame.bayer_pattern, Some(skotiq_device::BayerPattern::Grbg));
    assert_eq!(frame.data.len(), 128 * 96);
    assert_eq!(frame.data[0], 0);
    assert_eq!(frame.data[129], (1 << 8) | 1);
    // The camera stopped after its frame, so the next start is accepted as it is.
    // SAFETY: plain int argument.
    assert_eq!(unsafe { (fake().exposing)(COLOR_ID) }, 0, "a single frame leaves the camera idle");
    fake().clear();
    take(&mut camera, params(0.02, 1, None)).await;
    assert!(fake().calls("POAStopExposure").is_empty(), "nothing left exposing to stop");

    // The download waits for the frame, however long the exposure.
    let waits = fake().calls("POAGetImageData");
    assert_eq!(waits.len(), 1);
    camera.disconnect().await.expect("disconnect");
    assert_eq!(fake().overlaps(), 0);
}

#[tokio::test]
#[ignore = "needs the document-based Player One fake on LD_LIBRARY_PATH (see the file header)"]
async fn bin_then_size_then_start_in_binned_pixels_and_the_frame_is_what_the_camera_took() {
    let mut camera = connected(COLOR_ID).await;
    fake().clear();
    let wanted = SubFrame {
        start_x: 11,
        start_y: 7,
        width: 30,
        height: 21,
    };
    let frame = take(&mut camera, params(0.01, 2, Some(wanted))).await;
    let geometry: Vec<String> = fake()
        .log()
        .into_iter()
        .filter(|l| l.starts_with("POASetImage"))
        .collect();
    assert_eq!(
        geometry,
        vec![
            format!("POASetImageBin({COLOR_ID},2)"),
            format!("POASetImageSize({COLOR_ID},28,20)"),
            format!("POASetImageStartPos({COLOR_ID},10,6)"),
        ],
        "a color frame starts on an even cell; width %4 and height %2 (POASetImageSize)"
    );
    assert_eq!((frame.width, frame.height), (28, 20));
    assert_eq!(frame.data[0], (6 << 8) | 10, "first sample comes from binned (10, 6)");
    assert_eq!((frame.metadata.bin_x, frame.metadata.bin_y), (2, 2));
    let sf = frame.metadata.subframe.expect("subframe recorded");
    assert_eq!((sf.start_x, sf.start_y, sf.width, sf.height), (10, 6, 28, 20));
    assert_eq!(camera.get_binning().await.unwrap(), (2, 2));

    // Back to the whole sensor at bin 1.
    let frame = take(&mut camera, params(0.01, 1, None)).await;
    assert_eq!((frame.width, frame.height), (128, 96));
    assert!(frame.metadata.subframe.is_none());

    // Binning the camera does not list, or unequal axes, is refused before any SDK call.
    fake().clear();
    assert!(matches!(
        camera.start_exposure(params(0.01, 5, None)).await,
        Err(DriverError::InvalidParameter(_))
    ));
    camera.start_exposure(params(0.01, 2, None)).await.expect("bin 2 is listed");
    camera.abort_exposure().await.expect("abort");
    assert_eq!(fake().calls("POAStopExposure"), vec![format!("POAStopExposure({COLOR_ID})")]);
    camera.disconnect().await.expect("disconnect");
    assert_eq!(fake().overlaps(), 0);
}

#[tokio::test]
#[ignore = "needs the document-based Player One fake on LD_LIBRARY_PATH (see the file header)"]
async fn exposure_gain_temperature_and_cooler_controls_have_the_header_types() {
    let mut camera = connected(COLOR_ID).await;
    assert_eq!(camera.get_exposure_range().await.unwrap(), Some((0.00001, 7200.0)));
    assert_eq!(camera.get_gain_range().await.unwrap(), (0, 600));
    assert_eq!(camera.get_offset_range().await.unwrap(), (0, 254));
    assert_eq!(camera.get_cooler_temp_range().await.unwrap(), Some((-50.0, 50.0)));
    assert_eq!(camera.get_temperature().await.unwrap(), -10.5);

    camera.set_gain(250).await.unwrap();
    assert_eq!(camera.get_gain().await.unwrap(), 250);
    camera.set_cooler(true, Some(-9.6)).await.unwrap();
    let status = camera.get_status().await.unwrap();
    assert!(status.cooler_on);
    assert_eq!(status.target_temp, Some(-10.0));
    assert_eq!(status.sensor_temp, Some(-10.5));
    assert_eq!(status.cooler_power, Some(42.0));
    assert_eq!(status.gain, 250);

    // A one-hour light frame is inside POA_EXP's range.
    camera.start_exposure(params(3600.0, 1, None)).await.expect("one-hour exposure");
    camera.abort_exposure().await.unwrap();
    camera.disconnect().await.unwrap();
    assert_eq!(fake().overlaps(), 0);
}

#[tokio::test]
#[ignore = "needs the document-based Player One fake on LD_LIBRARY_PATH (see the file header)"]
async fn the_wheel_homes_reads_minus_one_while_turning_and_keeps_names_as_given() {
    let homing = std::env::var("FAKE_PW_HOMING_MS")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(0);
    let mut camera = connected(COLOR_ID).await;
    let wheels = player_one::discover_filter_wheels().await.expect("wheel discovery");
    assert_eq!(wheels.len(), 1);
    assert_eq!((wheels[0].handle, wheels[0].position_count), (5, 7));
    assert_eq!(wheels[0].serial_number.as_deref(), Some("PW-FAKE-01"));

    let mut wheel = PlayerOneFilterWheel::new(wheels[0].handle);
    let started = Instant::now();
    let homing_wheel = tokio::spawn(async move {
        wheel.connect().await.expect("wheel connect");
        wheel
    });
    // The homing wait leaves the shared SDK lock free: a camera call goes through at once.
    tokio::time::sleep(Duration::from_millis(100)).await;
    let asked = Instant::now();
    camera.get_temperature().await.unwrap();
    assert!(asked.elapsed() < Duration::from_millis(250), "camera call waited {:?}", asked.elapsed());
    let mut wheel = homing_wheel.await.unwrap();
    assert!(
        started.elapsed() >= Duration::from_millis(homing),
        "connect returned before the {homing} ms homing turn ended"
    );
    assert_eq!(wheel.get_position().await.unwrap(), 0);
    assert!(!wheel.is_moving().await.unwrap());

    wheel.move_to_position(3).await.unwrap();
    assert_eq!(wheel.get_position().await.unwrap(), -1, "PW_ERROR_IS_MOVING reads -1");
    assert!(wheel.is_moving().await.unwrap());
    tokio::time::sleep(Duration::from_millis(400)).await;
    assert_eq!(wheel.get_position().await.unwrap(), 3);
    assert!(matches!(wheel.move_to_position(7).await, Err(DriverError::InvalidParameter(_))));

    wheel.set_filter_name(2, "Ha 7nm".to_string()).await.unwrap();
    assert_eq!(fake().alias(2), "Ha 7nm", "the SDK keeps exactly the bytes named by len");
    wheel.set_filter_name(4, "x".repeat(23)).await.unwrap();
    assert_eq!(fake().alias(4), "x".repeat(23));
    assert!(wheel.set_filter_name(5, "y".repeat(24)).await.is_err(), "len must be under 24");
    let names = wheel.get_filter_names().await.unwrap();
    assert_eq!(names.len(), 7);
    assert_eq!(names[2], "Ha 7nm");
    assert_eq!(names[4], "x".repeat(23));
    assert_eq!(names[0], "Filter 1");

    wheel.disconnect().await.unwrap();
    camera.disconnect().await.unwrap();
    assert_eq!(fake().overlaps(), 0);
}

#[tokio::test]
#[ignore = "needs the document-based Player One fake on LD_LIBRARY_PATH, run with FAKE_POA_NO_EXP=1"]
async fn an_sdk_without_poa_exp_takes_microseconds_up_to_2000_s() {
    assert_eq!(std::env::var("FAKE_POA_NO_EXP").as_deref(), Ok("1"), "{NEEDS_FAKE}");
    let mut camera = connected(COLOR_ID).await;
    assert_eq!(camera.get_exposure_range().await.unwrap(), Some((0.00001, 2000.0)));
    fake().clear();
    let frame = take(&mut camera, params(0.0125, 1, None)).await;
    assert!(
        fake().calls("POASetConfig").contains(&format!("POASetConfig({COLOR_ID},0,12500,0)")),
        "{:?}",
        fake().calls("POASetConfig")
    );
    assert!((frame.metadata.exposure_time - 0.0125).abs() < 1e-9);
    assert!(matches!(
        camera.start_exposure(params(2400.0, 1, None)).await,
        Err(DriverError::InvalidParameter(_))
    ));
    camera.disconnect().await.unwrap();
}
