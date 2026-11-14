//! The FLI drivers against an independent model of libfli written from the
//! vendor's own sources (libfli.h, libfli.c, libfli-camera-usb.c,
//! libfli-filter-focuser.c), not from the driver (`tests/fake_sdk/libfli_model.c`).
//! The model logs every call to `$FLI_MODEL_LOG`.

#![cfg(target_os = "linux")]

#[path = "fake_sdk_linux/harness.rs"]
mod harness;

use skotiq_device::{CameraDriver, DeviceDriver, FilterWheelDriver, FocuserDriver};
use skotiq_device::{ExposureParams, FrameType, ImageData, SubFrame};
use skotiq_native::vendor::fli::{FliCamera, FliFilterWheel, FliFocuser};
use std::time::{Duration, Instant};

#[test]
fn fli_drivers_against_the_libfli_model() {
    let fake = harness::FakeSdk::build("fli_model", &[harness::FLI_MODEL]);
    let log = fake.dir().join("calls.log");
    fake.run_ignored("", &[("FLI_MODEL_LOG", log.to_str().unwrap())]);
}

fn log() -> Vec<String> {
    let path = std::env::var("FLI_MODEL_LOG").expect("FLI_MODEL_LOG");
    std::fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .map(str::to_string)
        .collect()
}

fn clear_log() {
    let path = std::env::var("FLI_MODEL_LOG").expect("FLI_MODEL_LOG");
    let _ = std::fs::write(path, "");
}

fn calls(name: &str) -> Vec<String> {
    log()
        .into_iter()
        .filter(|line| line.starts_with(name))
        .collect()
}

fn params(
    duration_secs: f64,
    bin: i32,
    subframe: Option<SubFrame>,
    kind: FrameType,
) -> ExposureParams {
    ExposureParams {
        duration_secs,
        gain: None,
        offset: None,
        bin_x: bin,
        bin_y: bin,
        subframe,
        readout_mode: None,
        frame_type: kind,
    }
}

async fn take(camera: &mut FliCamera, params: ExposureParams) -> ImageData {
    camera.start_exposure(params).await.expect("start exposure");
    for _ in 0..400 {
        if camera.is_exposure_complete().await.expect("poll") {
            return camera.download_image().await.expect("download");
        }
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    panic!("the frame never became ready");
}

async fn camera(path: &str) -> FliCamera {
    let mut camera = FliCamera::new(path.to_string());
    camera.connect().await.expect("connect");
    camera
}

/// libfli.h FLIOpen takes the FLIList file name with the device kind ORed
/// into the USB domain; FLIGetPixelSize answers meters on a ProLine
/// (libfli-camera-usb.c:368), and the visible area starts past the overscan.
#[tokio::test]
#[ignore = "run by fli_drivers_against_the_libfli_model"]
async fn a_proline_opens_by_its_list_name_and_reports_microns_and_its_visible_size() {
    clear_log();
    let camera = camera("FLI-0101").await;
    assert_eq!(calls("FLIOpen")[0], "FLIOpen FLI-0101 0x102");
    let info = camera.get_sensor_info();
    assert_eq!((info.width, info.height), (3056, 3056));
    assert_eq!((info.pixel_size_x, info.pixel_size_y), (12.0, 12.0));
    assert_eq!(camera.name(), "PL09000");
    assert_eq!(camera.serial_number().as_deref(), Some("PL0123456"));
}

/// libfli.c FLISetImageArea: ul absolute and unbinned, lr = ul + binned size;
/// the bins are set first because libfli-camera-usb.c:700 derives the row
/// width from the bin it holds when the area is set.
#[tokio::test]
#[ignore = "run by fli_drivers_against_the_libfli_model"]
async fn a_binned_subframe_asks_for_the_documented_area_and_reads_those_pixels() {
    let mut camera = camera("FLI-0101").await;
    clear_log();
    let sub = SubFrame {
        start_x: 100,
        start_y: 50,
        width: 200,
        height: 100,
    };
    let frame = take(&mut camera, params(0.05, 2, Some(sub), FrameType::Light)).await;
    let lines = log();
    let hbin = lines
        .iter()
        .position(|l| l == "FLISetHBin 2")
        .expect("hbin");
    let vbin = lines
        .iter()
        .position(|l| l == "FLISetVBin 2")
        .expect("vbin");
    let area = lines
        .iter()
        .position(|l| l.starts_with("FLISetImageArea 120 54 220 104"))
        .unwrap_or_else(|| panic!("image area: {lines:?}"));
    assert!(hbin < area && vbin < area, "bins after the area: {lines:?}");
    assert_eq!((frame.width, frame.height), (100, 50));
    // Pixel 0 of a row holds its absolute sensor y, the rest their x.
    assert_eq!(frame.data[0], 54);
    assert_eq!(frame.data[1], 122);
    assert_eq!(frame.data[100], 56);
    assert!(lines.contains(&"FLIGrabRow width 100".to_string()));
    assert!(lines.contains(&"FLIGrabRow rows 50".to_string()));
    assert!(lines.contains(&"FLISetFrameType 0".to_string()));
}

/// The frame type keeps the shutter closed for darks and bias frames
/// (libfli.c FLISetFrameType); milliseconds are rounded, not truncated.
#[tokio::test]
#[ignore = "run by fli_drivers_against_the_libfli_model"]
async fn darks_close_the_shutter_and_the_exposure_time_is_rounded_to_milliseconds() {
    let mut camera = camera("FLI-0101").await;
    clear_log();
    let dark = take(&mut camera, params(0.0016, 4, None, FrameType::Dark)).await;
    assert_eq!(calls("FLISetFrameType"), ["FLISetFrameType 1"]);
    assert_eq!(calls("FLISetExposureTime"), ["FLISetExposureTime 2"]);
    assert_eq!(dark.metadata.exposure_time, 0.002);
    clear_log();
    take(&mut camera, params(0.0, 4, None, FrameType::Bias)).await;
    assert_eq!(calls("FLISetFrameType"), ["FLISetFrameType 1"]);
    assert_eq!(calls("FLISetExposureTime"), ["FLISetExposureTime 0"]);
    clear_log();
    take(&mut camera, params(0.0299, 4, None, FrameType::Flat)).await;
    assert_eq!(calls("FLISetFrameType"), ["FLISetFrameType 0"]);
    assert_eq!(calls("FLISetExposureTime"), ["FLISetExposureTime 30"]);
}

/// A MaxCam leaves FLIGetDeviceStatus at 0xffffffff (libfli-camera-usb.c:2575),
/// data-ready bit included; INDI fli_ccd.cpp TimerHit then waits for the time
/// left to reach zero.
#[tokio::test]
#[ignore = "run by fli_drivers_against_the_libfli_model"]
async fn a_camera_without_a_status_is_not_ready_before_its_exposure_ends() {
    let mut camera = camera("FLI-0102").await;
    assert_eq!(camera.get_sensor_info().pixel_size_x, 20.0, "table microns");
    camera
        .start_exposure(params(0.3, 1, None, FrameType::Light))
        .await
        .expect("start");
    assert!(!camera.is_exposure_complete().await.expect("poll"));
    tokio::time::sleep(Duration::from_millis(350)).await;
    assert!(camera.is_exposure_complete().await.expect("poll"));
    let frame = camera.download_image().await.expect("download");
    assert_eq!((frame.width, frame.height), (1280, 1024));
    assert_eq!(
        frame.data[1], 5,
        "row starts at visible x 4, pixel 1 is x 5"
    );
}

/// FLIGetCoolerPower is -EFAULT on a MaxCam (libfli-camera-usb.c:2529); the
/// status still answers. There is no cooler off in libfli: off is a warm
/// set-point (NINA FLICamera.CoolerOn).
#[tokio::test]
#[ignore = "run by fli_drivers_against_the_libfli_model"]
async fn the_cooler_takes_set_points_and_a_missing_power_reading_is_not_a_failure() {
    let maxcam = camera("FLI-0102").await;
    let status = maxcam.get_status().await.expect("status");
    assert_eq!(status.cooler_power, None);
    assert_eq!(status.sensor_temp, Some(-5.5));
    let mut proline = camera("FLI-0101").await;
    assert_eq!(
        proline.get_status().await.expect("status").cooler_power,
        Some(42.0)
    );
    clear_log();
    proline.set_cooler(true, Some(-20.0)).await.expect("on");
    proline.set_cooler(false, None).await.expect("off");
    proline.set_cooler(true, None).await.expect("on again");
    assert_eq!(
        calls("FLISetTemperature"),
        [
            "FLISetTemperature -20.00",
            "FLISetTemperature 40.00",
            "FLISetTemperature -20.00"
        ]
    );
}

/// A failed row: NINA FLICamera.DownloadExposure cancels the frame so the
/// camera is ready for the next one, and the next exposure works.
#[tokio::test]
#[ignore = "run by fli_drivers_against_the_libfli_model"]
async fn a_failed_download_cancels_the_frame_and_the_next_one_works() {
    let mut camera = camera("FLI-0101").await;
    std::env::set_var("FLI_MODEL_FAIL_ROW", "5");
    clear_log();
    camera
        .start_exposure(params(0.01, 8, None, FrameType::Light))
        .await
        .expect("start");
    tokio::time::sleep(Duration::from_millis(30)).await;
    assert!(camera.is_exposure_complete().await.expect("poll"));
    let error = camera.download_image().await.expect_err("row 5 fails");
    assert!(format!("{error}").contains("row 6"), "{error}");
    assert!(!calls("FLICancelExposure").is_empty());
    std::env::remove_var("FLI_MODEL_FAIL_ROW");
    let frame = take(&mut camera, params(0.01, 8, None, FrameType::Light)).await;
    assert_eq!((frame.width, frame.height), (382, 382));
}

/// The Linux kernel driver names devices /dev/fliusbN; the id carries it with
/// '/' replaced. libfli's knowndev table has a 0.0 pixel pitch for CCD47-10:
/// the camera connects and its pitch reads as unknown (0.0, which no frame
/// header or solver hint takes).
#[tokio::test]
#[ignore = "run by fli_drivers_against_the_libfli_model"]
async fn a_kernel_driver_device_with_no_pitch_opens_from_its_id() {
    clear_log();
    let mut camera = FliCamera::new("_dev_fliusb0".to_string());
    camera
        .connect()
        .await
        .expect("a body with no pitch still connects");
    assert!(calls("FLIOpen").contains(&"FLIOpen /dev/fliusb0 0x102".to_string()));
    let info = camera.get_sensor_info();
    assert_eq!((info.pixel_size_x, info.pixel_size_y), (0.0, 0.0));
    assert_eq!((info.width, info.height), (1056, 1027));
    let frame = take(&mut camera, params(0.01, 2, None, FrameType::Light)).await;
    assert_eq!((frame.width, frame.height), (528, 513));
}

/// libfli-filter-focuser.c fli_stepmotor takes signed relative steps; the
/// travel is FLIGetFocuserExtent (INDI fli_pdf.cpp MoveAbsFocuser).
#[tokio::test]
#[ignore = "run by fli_drivers_against_the_libfli_model"]
async fn the_focuser_moves_by_the_difference_and_stays_inside_its_travel() {
    let mut focuser = FliFocuser::new("FLI-0201".to_string());
    focuser.connect().await.expect("connect");
    assert_eq!(focuser.get_max_position().await, 7000);
    assert_eq!(focuser.get_position().await.expect("pos"), 3000);
    clear_log();
    focuser.move_to(2500).await.expect("move");
    assert_eq!(calls("FLIStepMotorAsync"), ["FLIStepMotorAsync -500"]);
    assert!(focuser.is_moving().await.expect("moving"));
    let deadline = Instant::now() + Duration::from_secs(5);
    while focuser.is_moving().await.expect("moving") {
        assert!(Instant::now() < deadline, "the 500-step move never ended");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert_eq!(focuser.get_position().await.expect("pos"), 2500);
    assert!(focuser.move_to(7001).await.is_err());
    assert!(focuser.move_relative(-2501).await.is_err());
    focuser.move_relative(4500).await.expect("to the end");
    assert_eq!(focuser.get_temperature().await.expect("temp"), None);
}

/// Slots are 0-based (INDI fli_cfw.cpp SelectFilter subtracts one) and the
/// move blocks; slot names come from the firmware.
#[tokio::test]
#[ignore = "run by fli_drivers_against_the_libfli_model"]
async fn the_wheel_moves_to_zero_based_slots_and_names_them() {
    let mut wheel = FliFilterWheel::new("FLI-0301".to_string());
    wheel.connect().await.expect("connect");
    assert_eq!(wheel.get_filter_count().await, 7);
    eprintln!(
        "position before the first move: {:?}",
        wheel.get_position().await
    );
    clear_log();
    wheel.move_to_position(3).await.expect("move");
    assert_eq!(calls("FLISetFilterPos"), ["FLISetFilterPos 3"]);
    assert_eq!(wheel.get_position().await.expect("pos"), 3);
    assert!(!wheel.is_moving().await.expect("moving"));
    assert!(wheel.move_to_position(7).await.is_err());
    let names = wheel.get_filter_names().await.expect("names");
    assert_eq!(names, ["L", "R", "G", "B", "Ha", "Filter 6", "OIII"]);
}

/// libfli.h FLI_FILTER_POSITION_UNKNOWN (0xff): newer CFW firmware reads the
/// slot from the wheel (libfli-filter-focuser.c fli_getfilterpos), so a wheel
/// that has not found a slot answers 0xff. It is no slot; the driver reports
/// it as -1, the unknown position older wheels answer before their first move.
#[tokio::test]
#[ignore = "run by fli_drivers_against_the_libfli_model"]
async fn a_wheel_that_has_not_found_a_slot_reports_an_unknown_position() {
    let mut wheel = FliFilterWheel::new("FLI-0302".to_string());
    wheel.connect().await.expect("connect");
    assert_eq!(wheel.get_position().await.expect("pos"), -1);
    wheel.move_to_position(4).await.expect("move");
    assert_eq!(wheel.get_position().await.expect("pos"), 4);
}

async fn focuser(path: &str) -> FliFocuser {
    let mut focuser = FliFocuser::new(path.to_string());
    focuser.connect().await.expect("connect");
    focuser
}

/// The halt is the non-waiting 0-step move (libfli-filter-focuser.c
/// fli_stepmotor), and the driver then reads the steps left until none are.
#[tokio::test]
#[ignore = "run by fli_drivers_against_the_libfli_model"]
async fn a_halt_stops_the_focuser_where_it_is() {
    let mut focuser = focuser("FLI-0201").await;
    focuser.move_to(0).await.expect("move");
    tokio::time::sleep(Duration::from_millis(50)).await;
    clear_log();
    focuser.halt().await.expect("halt");
    assert_eq!(calls("FLIStepMotor"), ["FLIStepMotorAsync 0"]);
    assert!(!focuser.is_moving().await.expect("moving"));
    let stopped = focuser.get_position().await.expect("pos");
    assert!(stopped > 0 && stopped < 3000, "stopped at {stopped}");
    focuser.move_to(3000).await.expect("back");
}

/// While a halted focuser coasts to rest, the other FLI devices are not held
/// up: libfli's blocking FLIStepMotor would keep the SDK lock for the coast.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "run by fli_drivers_against_the_libfli_model"]
async fn a_coasting_focuser_does_not_hold_up_the_camera() {
    let camera = camera("FLI-0101").await;
    let mut focuser = focuser("FLI-0202").await;
    focuser.move_to(7000).await.expect("move");
    tokio::time::sleep(Duration::from_millis(50)).await;
    let status = tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(50)).await;
        let started = Instant::now();
        camera.get_status().await.expect("status");
        started.elapsed()
    });
    let started = Instant::now();
    focuser.halt().await.expect("halt");
    let halt_took = started.elapsed();
    let status_took = status.await.expect("status task");
    assert!(
        halt_took >= Duration::from_millis(350),
        "halt returned before the focuser stopped: {halt_took:?}"
    );
    assert!(
        status_took < Duration::from_millis(100),
        "the camera waited {status_took:?} on the halt"
    );
    assert!(!focuser.is_moving().await.expect("moving"));
    focuser.move_to(0).await.expect("back");
}

/// A focuser that does not stop within the halt's time limit is reported in
/// words, with the steps it still had to go.
#[tokio::test]
#[ignore = "run by fli_drivers_against_the_libfli_model"]
async fn a_focuser_that_will_not_stop_is_reported_after_the_time_limit() {
    let mut focuser = focuser("FLI-0203").await;
    focuser.move_to(7000).await.expect("move");
    let started = Instant::now();
    let error = focuser.halt().await.expect_err("it keeps moving");
    let took = started.elapsed();
    assert!(
        took >= Duration::from_secs(5) && took < Duration::from_secs(6),
        "{took:?}"
    );
    let text = error.to_string();
    assert!(
        text.contains("was told to stop but was still moving 5 s later"),
        "{text}"
    );
}
