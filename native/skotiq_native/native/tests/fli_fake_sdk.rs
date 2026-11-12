//! The FLI drivers against the fake libfli (`FLI_FAKE_SDK` in
//! `native_driver_tests.rs`), which answers the way libfli does where the
//! driver depends on it. Each test checks what the camera was told and what
//! the app was told back.
//!
//! Run: build the fakes with `tests/fake_sdk_linux/build_fakes.py <dir>`, then
//! `LD_LIBRARY_PATH=<dir>/fli cargo test --release -p skotiq_native --test fli_fake_sdk -- --ignored --test-threads 1`.

#![cfg(unix)]

use skotiq_device::{
    CameraDriver, DeviceDriver, ExposureParams, FocuserDriver, FrameType, SubFrame,
};
use skotiq_native::vendor::fli;
use skotiq_native::vendor::serial_link::sanitize_port_name;
use std::ffi::{c_double, c_long};
use std::time::Duration;

/// The tests share the fake's state and its environment switches.
static SERIAL: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

const SWITCHES: [&str; 4] = [
    "SK_FLI_KERNEL_NAMES",
    "SK_FLI_STATUS_UNKNOWN",
    "SK_FLI_GRAB_ERROR",
    "SK_FLI_UNPLUGGED",
];

fn switches(on: &[&str]) {
    for name in SWITCHES {
        if on.contains(&name) {
            std::env::set_var(name, "1");
        } else {
            std::env::remove_var(name);
        }
    }
}

/// The fake's record of what the camera was last told.
struct Fake(libloading::Library);

impl Fake {
    fn open() -> Self {
        // SAFETY: the fake libfli has no initializers; it is the library the driver loaded.
        Fake(
            unsafe { libloading::Library::new("libfli.so") }
                .expect("fake libfli on LD_LIBRARY_PATH"),
        )
    }

    fn image_area(&self) -> [c_long; 4] {
        let mut out = [0 as c_long; 4];
        // SAFETY: FakeFliLastImageArea writes four c_longs.
        unsafe {
            let f: libloading::Symbol<unsafe extern "C" fn(*mut c_long) -> c_long> =
                self.0.get(b"FakeFliLastImageArea\0").unwrap();
            f(out.as_mut_ptr());
        }
        out
    }

    fn exposure_ms(&self) -> c_long {
        // SAFETY: a no-argument getter.
        unsafe {
            let f: libloading::Symbol<extern "C" fn() -> c_long> =
                self.0.get(b"FakeFliLastExposureMs\0").unwrap();
            f()
        }
    }

    fn setpoint(&self) -> c_double {
        // SAFETY: a no-argument getter.
        unsafe {
            let f: libloading::Symbol<extern "C" fn() -> c_double> =
                self.0.get(b"FakeFliLastSetpoint\0").unwrap();
            f()
        }
    }

    fn cancels(&self) -> c_long {
        // SAFETY: a no-argument getter.
        unsafe {
            let f: libloading::Symbol<extern "C" fn() -> c_long> =
                self.0.get(b"FakeFliCancelCount\0").unwrap();
            f()
        }
    }
}

fn light(duration_secs: f64, bin: i32, subframe: Option<SubFrame>) -> ExposureParams {
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

async fn wait_for_frame(camera: &fli::FliCamera, limit: Duration) -> bool {
    let start = std::time::Instant::now();
    while start.elapsed() < limit {
        if camera
            .is_exposure_complete()
            .await
            .expect("exposure status")
        {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    false
}

async fn connected_camera() -> fli::FliCamera {
    let cameras = fli::discover_cameras().await.expect("discover");
    let mut camera = fli::FliCamera::new(sanitize_port_name(&cameras[0].device_path));
    camera.connect().await.expect("connect");
    camera
}

/// The catalog builds the driver from the id's address, which holds the
/// file name with `/` replaced: FLI's Linux driver names `/dev/fliusb0`
/// arrived at FLIOpen as `_dev_fliusb0`, so no FLI device could connect.
#[tokio::test]
#[ignore = "needs the fake libfli on LD_LIBRARY_PATH"]
async fn devices_listed_under_linux_driver_names_connect() {
    let _guard = SERIAL.lock().await;
    switches(&["SK_FLI_KERNEL_NAMES"]);

    let cameras = fli::discover_cameras().await.unwrap();
    assert_eq!(cameras[0].device_path, "/dev/fliusb0");
    let mut camera = fli::FliCamera::new(sanitize_port_name("/dev/fliusb0"));
    camera.connect().await.expect("camera connects from its id");
    assert_eq!(camera.serial_number().as_deref(), Some("PL0001"));
    camera.disconnect().await.unwrap();

    let mut focuser = fli::FliFocuser::new(sanitize_port_name("/dev/fliusb1"));
    focuser
        .connect()
        .await
        .expect("focuser connects from its id");
    assert_eq!(focuser.serial_number().as_deref(), Some("PDF0002"));
    focuser.disconnect().await.unwrap();

    let mut wheel = fli::FliFilterWheel::new(sanitize_port_name("/dev/fliusb2"));
    wheel.connect().await.expect("wheel connects from its id");
    assert_eq!(wheel.serial_number().as_deref(), Some("CFW0003"));
    wheel.disconnect().await.unwrap();

    let mut missing = fli::FliCamera::new("_dev_fliusb7".to_string());
    let error = missing.connect().await.unwrap_err().to_string();
    assert!(error.contains("not attached"), "{error}");
    switches(&[]);
}

/// USB cameras answer FLIGetPixelSize in meters.
#[tokio::test]
#[ignore = "needs the fake libfli on LD_LIBRARY_PATH"]
async fn pixel_size_is_in_microns() {
    let _guard = SERIAL.lock().await;
    switches(&[]);
    let mut camera = connected_camera().await;
    let sensor = camera.get_sensor_info();
    assert_eq!((sensor.pixel_size_x, sensor.pixel_size_y), (9.0, 9.0));
    camera.disconnect().await.unwrap();
}

/// FLISetImageArea's lower-right corner is the upper-left plus the binned
/// size; the fake refuses a readout past the sensor, as the unbinned corner
/// asked for at bin 2.
#[tokio::test]
#[ignore = "needs the fake libfli on LD_LIBRARY_PATH"]
async fn binned_frames_ask_for_the_binned_area() {
    let _guard = SERIAL.lock().await;
    switches(&[]);
    let fake = Fake::open();
    let mut camera = connected_camera().await;

    camera
        .start_exposure(light(0.01, 2, None))
        .await
        .expect("bin 2 full frame");
    assert_eq!(fake.image_area(), [0, 0, 32, 24]);
    assert!(wait_for_frame(&camera, Duration::from_secs(2)).await);
    let image = camera.download_image().await.unwrap();
    assert_eq!((image.width, image.height), (32, 24));
    // The fake's pixel is 1000 + y * 64 + x at the sensor position it read.
    assert_eq!(&image.data[..3], &[1000, 1002, 1004]);
    assert_eq!(image.data[32], 1000 + 2 * 64);

    let subframe = SubFrame {
        start_x: 8,
        start_y: 4,
        width: 16,
        height: 8,
    };
    camera
        .start_exposure(light(0.01, 2, Some(subframe)))
        .await
        .expect("bin 2 subframe");
    assert_eq!(fake.image_area(), [8, 4, 16, 8]);
    assert!(wait_for_frame(&camera, Duration::from_secs(2)).await);
    let image = camera.download_image().await.unwrap();
    assert_eq!((image.width, image.height), (8, 4));
    assert_eq!(image.data[0], 1000 + 4 * 64 + 8);

    // set_binning alone keeps the area in step with the binning.
    camera.set_subframe(None).await.unwrap();
    camera.set_binning(4, 4).await.unwrap();
    assert_eq!(fake.image_area(), [0, 0, 16, 12]);

    assert!(camera.start_exposure(light(0.01, 17, None)).await.is_err());
    camera.disconnect().await.unwrap();
}

/// A camera that cannot report its status answers all ones, data-ready bit
/// included: the frame is read only when no exposure time is left.
#[tokio::test]
#[ignore = "needs the fake libfli on LD_LIBRARY_PATH"]
async fn camera_without_status_waits_out_the_exposure() {
    let _guard = SERIAL.lock().await;
    switches(&["SK_FLI_STATUS_UNKNOWN"]);
    let mut camera = connected_camera().await;

    let started = std::time::Instant::now();
    camera.start_exposure(light(0.3, 1, None)).await.unwrap();
    assert!(!camera.is_exposure_complete().await.unwrap());
    assert!(wait_for_frame(&camera, Duration::from_secs(3)).await);
    assert!(started.elapsed() >= Duration::from_millis(290));
    let image = camera
        .download_image()
        .await
        .expect("frame after the exposure");
    assert_eq!((image.width, image.height), (64, 48));
    camera.disconnect().await.unwrap();
    switches(&[]);
}

/// The frame records the milliseconds the camera was given.
#[tokio::test]
#[ignore = "needs the fake libfli on LD_LIBRARY_PATH"]
async fn exposure_time_is_what_the_camera_was_given() {
    let _guard = SERIAL.lock().await;
    switches(&[]);
    let fake = Fake::open();
    let mut camera = connected_camera().await;

    // 2.01 * 1000 is 2009.9999999999998 in floating point.
    camera.start_exposure(light(2.01, 1, None)).await.unwrap();
    assert_eq!(fake.exposure_ms(), 2010);
    camera.abort_exposure().await.unwrap();

    camera.start_exposure(light(0.0123, 1, None)).await.unwrap();
    assert_eq!(fake.exposure_ms(), 12);
    assert!(wait_for_frame(&camera, Duration::from_secs(2)).await);
    let image = camera.download_image().await.unwrap();
    assert_eq!(image.metadata.exposure_time, 0.012);
    camera.disconnect().await.unwrap();
}

/// A failed row read discards the frame in the camera, and the next
/// exposure works.
#[tokio::test]
#[ignore = "needs the fake libfli on LD_LIBRARY_PATH"]
async fn failed_download_discards_the_frame() {
    let _guard = SERIAL.lock().await;
    switches(&[]);
    let fake = Fake::open();
    let mut camera = connected_camera().await;

    camera.start_exposure(light(0.01, 1, None)).await.unwrap();
    assert!(wait_for_frame(&camera, Duration::from_secs(2)).await);
    let cancels = fake.cancels();
    switches(&["SK_FLI_GRAB_ERROR"]);
    let error = camera.download_image().await.unwrap_err().to_string();
    assert!(error.contains("row 1 of 48"), "{error}");
    assert_eq!(fake.cancels(), cancels + 1);
    switches(&[]);

    camera.start_exposure(light(0.01, 1, None)).await.unwrap();
    assert!(wait_for_frame(&camera, Duration::from_secs(2)).await);
    assert!(camera.download_image().await.is_ok());
    camera.disconnect().await.unwrap();
}

/// The heartbeat reads the status: an unplugged camera must fail it.
#[tokio::test]
#[ignore = "needs the fake libfli on LD_LIBRARY_PATH"]
async fn unplugged_camera_fails_its_status() {
    let _guard = SERIAL.lock().await;
    switches(&[]);
    let mut camera = connected_camera().await;
    assert!(camera.get_status().await.is_ok());
    switches(&["SK_FLI_UNPLUGGED"]);
    let error = camera.get_status().await.unwrap_err().to_string();
    assert!(error.contains("stopped answering"), "{error}");
    switches(&[]);
    camera.disconnect().await.unwrap();
}

/// "Off" parks the set-point where the cooler stops working.
#[tokio::test]
#[ignore = "needs the fake libfli on LD_LIBRARY_PATH"]
async fn cooler_off_parks_the_setpoint() {
    let _guard = SERIAL.lock().await;
    switches(&[]);
    let fake = Fake::open();
    let mut camera = connected_camera().await;
    camera.set_cooler(true, Some(-20.0)).await.unwrap();
    assert_eq!(fake.setpoint(), -20.0);
    camera.set_cooler(false, None).await.unwrap();
    assert_eq!(fake.setpoint(), 40.0);
    camera.disconnect().await.unwrap();
}

/// libfli cannot read the cooler back: a camera Skotiq connects to while it
/// still cools from an earlier session reports its cooler unknown, never off,
/// with the power the camera reports. Once set, the state is what was set, and
/// cooling without a set-point is refused rather than given an invented one.
#[tokio::test]
#[ignore = "needs the fake libfli on LD_LIBRARY_PATH"]
async fn a_cooler_libfli_cannot_read_is_unknown_until_set() {
    let _guard = SERIAL.lock().await;
    switches(&[]);
    let mut earlier = connected_camera().await;
    earlier.set_cooler(true, Some(-20.0)).await.unwrap();
    earlier.disconnect().await.unwrap();

    let mut camera = connected_camera().await;
    let status = camera.get_status().await.unwrap();
    assert_eq!((status.cooler_on, status.target_temp), (None, None));
    assert_eq!(status.cooler_power, Some(42.0));
    assert!(matches!(
        camera.set_cooler(true, None).await,
        Err(skotiq_device::DriverError::InvalidParameter(_))
    ));

    camera.set_cooler(true, Some(-15.0)).await.unwrap();
    let status = camera.get_status().await.unwrap();
    assert_eq!(
        (status.cooler_on, status.target_temp),
        (Some(true), Some(-15.0))
    );
    camera.set_cooler(true, None).await.unwrap();
    camera.set_cooler(false, None).await.unwrap();
    assert_eq!(camera.get_status().await.unwrap().cooler_on, Some(false));
    camera.disconnect().await.unwrap();
}

/// A focuser target outside its travel is refused before it is sent.
#[tokio::test]
#[ignore = "needs the fake libfli on LD_LIBRARY_PATH"]
async fn focuser_refuses_targets_outside_its_travel() {
    let _guard = SERIAL.lock().await;
    switches(&[]);
    let focusers = fli::discover_focusers().await.unwrap();
    let mut focuser = fli::FliFocuser::new(focusers[0].device_path.clone());
    focuser.connect().await.unwrap();
    let start = focuser.get_position().await.unwrap();
    assert!(focuser.move_to(-5).await.is_err());
    assert!(focuser.move_to(50001).await.is_err());
    assert_eq!(focuser.get_position().await.unwrap(), start);
    focuser.move_to(1234).await.unwrap();
    assert_eq!(focuser.get_position().await.unwrap(), 1234);
    focuser.disconnect().await.unwrap();
}
