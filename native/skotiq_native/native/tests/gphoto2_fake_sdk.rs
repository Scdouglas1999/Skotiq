//! The gPhoto2 driver against the fake libgphoto2 (`tests/fake_sdk/gphoto2.rs`),
//! which answers like libgphoto2 2.5 for a Canon EOS, a Nikon Z, a Sony A7 and
//! a Fujifilm X-T5, each capture holding a real raw file of its maker.
//!
//! The tests share one loaded library and its bodies, so they run in one
//! process, one at a time:
//!
//! ```sh
//! python3 native/tests/fake_sdk_linux/build_fakes.py /tmp/fakes
//! cargo test --release -p skotiq_native --test gphoto2_fake_sdk --no-run
//! SKOTIQ_RAW_SAMPLES=<raw samples> LD_LIBRARY_PATH=/tmp/fakes/gphoto2 \
//!     <test binary> --ignored --test-threads 1
//! ```
//!
//! `SKOTIQ_RAW_SAMPLES` is the folder of public raw samples that
//! imaging/tests/camera_raw.rs reads.

#![cfg(unix)]

use skotiq_device::{
    BayerPattern, CameraDriver, CameraState, DeviceDriver, ExposureParams, FrameType, ImageData,
};
use skotiq_native::vendor::gphoto2::{detect_gphoto2_cameras, GPhoto2Camera};
use std::ffi::{c_char, c_int, CStr, CString};
use std::time::{Duration, Instant};

const CANON: &str = "Canon EOS 6d Mark II";
const NIKON: &str = "Nikon Z6_2";
const SONY: &str = "Sony Alpha-A7 III (PC Control)";
const FUJI: &str = "Fuji Fujifilm X-T5";
const CANON_PORT: &str = "usb:001,004";
const NIKON_PORT: &str = "usb:001,007";
const SONY_PORT: &str = "usb:002,003";
const FUJI_PORT: &str = "usb:003,002";

/// The fake's control functions.
struct Fake {
    lib: libloading::Library,
}

fn c(s: &str) -> CString {
    CString::new(s).unwrap()
}

impl Fake {
    /// The fake, emptied. Panics when the library on the loader path is not
    /// the fake, before any driver call can reach a real libgphoto2.
    fn new() -> Self {
        // SAFETY: loads the library the driver loads; the fake has no
        // initializers.
        let lib = unsafe { libloading::Library::new("libgphoto2.so") }.expect("libgphoto2.so");
        let fake = Fake { lib };
        // SAFETY: fake_gp_reset takes no arguments.
        unsafe {
            fake.lib
                .get::<unsafe extern "C" fn()>(b"fake_gp_reset\0")
                .expect(
                    "the fake libgphoto2 must be first on LD_LIBRARY_PATH (see this file's header)",
                )()
        };
        fake
    }

    fn sample(name: &str) -> String {
        let dir =
            std::env::var("SKOTIQ_RAW_SAMPLES").expect("SKOTIQ_RAW_SAMPLES names the raw samples");
        format!("{dir}/{name}")
    }

    fn attach(&self, model: &str, port: &str) {
        let sample = match model {
            CANON => "canon_1000d.cr2",
            NIKON => "nikon_d40_lossy12.nef",
            SONY => "sony_a7m4_lossy.arw",
            _ => "fuji_xt1_xtrans.raf",
        };
        // SAFETY: the signature fake_gp_attach is defined with; the strings
        // outlive the call.
        let ret =
            unsafe {
                self.lib
                .get::<unsafe extern "C" fn(*const c_char, *const c_char, *const c_char) -> c_int>(
                    b"fake_gp_attach\0",
                )
                .unwrap()(c(model).as_ptr(), c(port).as_ptr(), c(&Self::sample(sample)).as_ptr())
            };
        assert_eq!(ret, 0, "attach {model}");
    }

    /// Unplug (`None`) or plug back in on a new port.
    fn replug(&self, port: &str, new_port: Option<&str>) {
        // SAFETY: as defined by the fake; the strings outlive the call.
        unsafe {
            self.lib
                .get::<unsafe extern "C" fn(*const c_char, *const c_char)>(b"fake_gp_replug\0")
                .unwrap()(c(port).as_ptr(), c(new_port.unwrap_or("")).as_ptr())
        }
    }

    fn set(&self, port: &str, key: &str, value: &str) {
        // SAFETY: as defined by the fake; the strings outlive the call.
        unsafe {
            self.lib
                .get::<unsafe extern "C" fn(*const c_char, *const c_char, *const c_char)>(
                    b"fake_gp_set\0",
                )
                .unwrap()(c(port).as_ptr(), c(key).as_ptr(), c(value).as_ptr())
        }
    }

    fn text(&self, symbol: &[u8], args: &[&str]) -> String {
        let args: Vec<CString> = args.iter().map(|a| c(a)).collect();
        // SAFETY: each symbol takes as many C strings as passed here and
        // returns a NUL-terminated string the fake leaks.
        let ptr = unsafe {
            match args.len() {
                0 => self
                    .lib
                    .get::<unsafe extern "C" fn() -> *const c_char>(symbol)
                    .unwrap()(),
                1 => self
                    .lib
                    .get::<unsafe extern "C" fn(*const c_char) -> *const c_char>(symbol)
                    .unwrap()(args[0].as_ptr()),
                _ => self
                    .lib
                    .get::<unsafe extern "C" fn(*const c_char, *const c_char) -> *const c_char>(
                        symbol,
                    )
                    .unwrap()(args[0].as_ptr(), args[1].as_ptr()),
            }
        };
        // SAFETY: see above.
        unsafe { CStr::from_ptr(ptr) }
            .to_string_lossy()
            .into_owned()
    }

    fn value(&self, port: &str, widget: &str) -> String {
        self.text(b"fake_gp_value\0", &[port, widget])
    }

    /// The exposures the body made: "timed 30", "bulb 1.503".
    fn made(&self, port: &str) -> Vec<String> {
        self.text(b"fake_gp_made\0", &[port])
            .lines()
            .map(str::to_string)
            .collect()
    }

    fn trace(&self) -> String {
        self.text(b"fake_gp_trace\0", &[])
    }

    fn files_left(&self, port: &str) -> i32 {
        // SAFETY: as defined by the fake; the string outlives the call.
        unsafe {
            self.lib
                .get::<unsafe extern "C" fn(*const c_char) -> c_int>(b"fake_gp_files\0")
                .unwrap()(c(port).as_ptr())
        }
    }
}

fn exposure(seconds: f64, iso: Option<i32>) -> ExposureParams {
    ExposureParams {
        duration_secs: seconds,
        bin_x: 1,
        bin_y: 1,
        gain: iso,
        offset: None,
        subframe: None,
        readout_mode: None,
        frame_type: FrameType::Light,
    }
}

async fn connected(index: usize, model: &str, port: &str) -> GPhoto2Camera {
    let mut camera = GPhoto2Camera::new(index, model, port);
    camera
        .connect()
        .await
        .unwrap_or_else(|e| panic!("connect {model}: {e}"));
    camera
}

async fn take(camera: &mut GPhoto2Camera, params: ExposureParams) -> ImageData {
    camera.start_exposure(params).await.expect("start exposure");
    while !camera.is_exposure_complete().await.expect("poll") {
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    camera.download_image().await.expect("download")
}

fn bulb_seconds(made: &str) -> f64 {
    made.strip_prefix("bulb ")
        .unwrap_or_else(|| panic!("not a bulb exposure: {made}"))
        .parse()
        .unwrap()
}

/// What the sample a body hands out records: exposure seconds and ISO.
fn recorded(sample: &str) -> (Option<f64>, Option<f32>) {
    let frame =
        skotiq_imaging::read_raw_bytes(&std::fs::read(Fake::sample(sample)).unwrap()).unwrap();
    (frame.metadata.exposure_seconds, frame.metadata.iso)
}

#[tokio::test]
#[ignore = "needs the fake libgphoto2 on LD_LIBRARY_PATH"]
async fn two_attached_bodies_each_open_as_themselves() {
    let fake = Fake::new();
    fake.attach(CANON, CANON_PORT);
    fake.attach(NIKON, NIKON_PORT);
    let found = detect_gphoto2_cameras();
    assert_eq!(found.len(), 2);

    // As the app opens a body from a scan: by its address, under a name
    // made from its id.
    let address = found[1].device_id.strip_prefix("native:gphoto2:").unwrap();
    let mut nikon = GPhoto2Camera::from_address(address, &format!("gPhoto2 {address}")).unwrap();
    nikon
        .connect()
        .await
        .expect("connect the Nikon by its address");
    assert_eq!(nikon.name(), NIKON);
    let canon = connected(0, CANON, CANON_PORT).await;
    let trace = fake.trace();
    assert!(
        trace.contains(&format!("init {NIKON_PORT} as Some(\"{NIKON}\")")),
        "{trace}"
    );
    assert!(
        trace.contains(&format!("init {CANON_PORT} as Some(\"{CANON}\")")),
        "{trace}"
    );
    assert_eq!(nikon.serial_number().as_deref(), Some("6012345"));
    assert_eq!(canon.serial_number().as_deref(), Some("072022001234"));

    take(&mut nikon, exposure(1.0, None)).await;
    assert_eq!(fake.made(NIKON_PORT), ["timed 1"]);
    assert!(fake.made(CANON_PORT).is_empty(), "the Canon took no frame");
}

#[tokio::test]
#[ignore = "needs the fake libgphoto2 on LD_LIBRARY_PATH"]
async fn a_replugged_body_connects_on_its_new_port() {
    let fake = Fake::new();
    fake.attach(NIKON, NIKON_PORT);
    let mut nikon = connected(0, NIKON, NIKON_PORT).await;
    nikon.disconnect().await.unwrap();
    fake.replug(NIKON_PORT, Some("usb:001,012"));

    // The device as the profile remembers it: the port it had.
    let mut again = connected(0, NIKON, NIKON_PORT).await;
    take(&mut again, exposure(1.0, None)).await;
    assert!(
        fake.trace().contains("init usb:001,012"),
        "{}",
        fake.trace()
    );
}

#[tokio::test]
#[ignore = "needs the fake libgphoto2 on LD_LIBRARY_PATH"]
async fn an_unplugged_body_is_noticed_while_idle() {
    let fake = Fake::new();
    fake.attach(NIKON, NIKON_PORT);
    let nikon = connected(0, NIKON, NIKON_PORT).await;
    fake.replug(NIKON_PORT, None);
    let status = nikon.get_status().await;
    assert!(status.is_err(), "status of an unplugged camera: {status:?}");
}

#[tokio::test]
#[ignore = "needs the fake libgphoto2 on LD_LIBRARY_PATH"]
async fn an_exposure_between_shutter_speeds_is_bulb_for_the_request() {
    let fake = Fake::new();
    fake.attach(CANON, CANON_PORT);
    let mut canon = connected(0, CANON, CANON_PORT).await;
    // 1.5 s lies between the body's 1.3 and 1.6.
    let frame = take(&mut canon, exposure(1.5, Some(1600))).await;

    let made = fake.made(CANON_PORT);
    assert_eq!(made.len(), 1, "{made:?}");
    let open = bulb_seconds(&made[0]);
    assert!((open - 1.5).abs() < 0.2, "held open {open} s");
    assert!(
        (frame.metadata.exposure_time - open).abs() < 0.05,
        "EXPTIME {} for a shutter open {open} s",
        frame.metadata.exposure_time
    );
    let trace = fake.trace();
    assert!(trace.contains("set shutterspeed=bulb"), "{trace}");
    assert!(trace.contains("set eosremoterelease=Press Full"), "{trace}");
    assert_eq!(fake.value(CANON_PORT, "iso"), "1600");
    assert_eq!(
        fake.value(CANON_PORT, "imageformat"),
        "RAW",
        "RAW is forced"
    );
    assert_eq!(
        fake.files_left(CANON_PORT),
        0,
        "the frame in the camera's memory is deleted"
    );
}

#[tokio::test]
#[ignore = "needs the fake libgphoto2 on LD_LIBRARY_PATH"]
async fn a_timed_frame_records_the_exposure_and_iso_the_camera_made() {
    let fake = Fake::new();
    fake.attach(CANON, CANON_PORT);
    // The body is on Auto ISO and Skotiq leaves the ISO alone.
    let mut canon = connected(0, CANON, CANON_PORT).await;
    let frame = take(&mut canon, exposure(30.0, None)).await;
    assert_eq!(fake.made(CANON_PORT), ["timed 30"]);

    let (seconds, iso) = recorded("canon_1000d.cr2");
    assert_eq!(
        Some(frame.metadata.exposure_time),
        seconds,
        "the raw file's own record"
    );
    assert_eq!(
        Some(frame.metadata.gain),
        iso.map(|i| i.round() as i32),
        "the raw file's ISO"
    );
}

#[tokio::test]
#[ignore = "needs the fake libgphoto2 on LD_LIBRARY_PATH"]
async fn a_nikon_reads_its_seconds_speeds_and_holds_bulb_with_its_toggle() {
    let fake = Fake::new();
    fake.attach(NIKON, NIKON_PORT);
    let mut nikon = connected(0, NIKON, NIKON_PORT).await;
    assert_eq!(fake.value(NIKON_PORT, "longexpnr"), "Off");
    assert_eq!(
        nikon.get_exposure_range().await.unwrap(),
        Some((0.00025, 3600.0))
    );

    take(&mut nikon, exposure(2.0, None)).await;
    take(&mut nikon, exposure(1.5, None)).await;
    let made = fake.made(NIKON_PORT);
    assert_eq!(made[0], "timed 2");
    assert!((bulb_seconds(&made[1]) - 1.5).abs() < 0.2, "{made:?}");
    let trace = fake.trace();
    assert!(trace.contains("set shutterspeed2=2"), "{trace}");
    assert!(trace.contains("set shutterspeed2=Bulb"), "{trace}");
    assert!(
        trace.contains("set bulb=1") && trace.contains("set bulb=0"),
        "{trace}"
    );
    assert_eq!(fake.value(NIKON_PORT, "imagequality"), "NEF (Raw)");
    // On the card the frames are deleted after they are read, as before.
    assert_eq!(fake.files_left(NIKON_PORT), 0);
}

#[tokio::test]
#[ignore = "needs the fake libgphoto2 on LD_LIBRARY_PATH"]
async fn a_raw_and_jpeg_body_hands_over_its_raw_file() {
    let fake = Fake::new();
    fake.attach(CANON, CANON_PORT);
    fake.set(CANON_PORT, "imageformat", "RAW + Large Fine JPEG");
    fake.set(CANON_PORT, "lock", "imageformat");
    fake.set(CANON_PORT, "jpeg_first", "1");
    let mut canon = connected(0, CANON, CANON_PORT).await;
    let frame = take(&mut canon, exposure(1.0, None)).await;
    let file = frame.metadata.camera_file.expect("camera file");
    assert!(file.file_name.ends_with(".CR2"), "{}", file.file_name);
    assert_eq!(fake.files_left(CANON_PORT), 0, "the JPEG is deleted too");
}

#[tokio::test]
#[ignore = "needs the fake libgphoto2 on LD_LIBRARY_PATH"]
async fn a_body_in_a_mode_without_bulb_refuses_a_bulb_exposure() {
    let fake = Fake::new();
    fake.attach(CANON, CANON_PORT);
    fake.set(CANON_PORT, "autoexposuremode", "AV");
    let mut canon = connected(0, CANON, CANON_PORT).await;
    let err = canon
        .start_exposure(exposure(45.0, None))
        .await
        .unwrap_err();
    assert!(err.to_string().contains("mode dial"), "{err}");
    assert!(
        fake.made(CANON_PORT).is_empty(),
        "no frame of another length"
    );
}

#[tokio::test]
#[ignore = "needs the fake libgphoto2 on LD_LIBRARY_PATH"]
async fn an_aborted_exposure_leaves_no_frame_behind() {
    let fake = Fake::new();
    fake.attach(CANON, CANON_PORT);
    let mut canon = connected(0, CANON, CANON_PORT).await;

    canon.start_exposure(exposure(1.0, None)).await.unwrap();
    canon
        .abort_exposure()
        .await
        .expect("abort a timed exposure");
    assert_eq!(fake.files_left(CANON_PORT), 0);

    canon.start_exposure(exposure(3.0, None)).await.unwrap();
    tokio::time::sleep(Duration::from_millis(300)).await;
    canon.abort_exposure().await.expect("abort bulb");
    assert_eq!(fake.files_left(CANON_PORT), 0);

    let frame = take(&mut canon, exposure(1.0, None)).await;
    assert_eq!(
        frame.metadata.camera_file.unwrap().file_name,
        "IMG_0003.CR2"
    );
}

#[tokio::test]
#[ignore = "needs the fake libgphoto2 on LD_LIBRARY_PATH"]
async fn a_stray_file_from_an_earlier_capture_is_not_taken_as_the_frame() {
    let fake = Fake::new();
    fake.attach(CANON, CANON_PORT);
    let mut canon = connected(0, CANON, CANON_PORT).await;
    fake.set(CANON_PORT, "stray", "1");
    let frame = take(&mut canon, exposure(1.2, None)).await;
    assert_eq!(
        frame.metadata.camera_file.unwrap().file_name,
        "IMG_0002.CR2"
    );
    assert_eq!(
        fake.files_left(CANON_PORT),
        0,
        "the stray file in memory is deleted"
    );
}

#[tokio::test]
#[ignore = "needs the fake libgphoto2 on LD_LIBRARY_PATH"]
async fn a_busy_camera_is_asked_again() {
    let fake = Fake::new();
    fake.attach(CANON, CANON_PORT);
    let mut canon = connected(0, CANON, CANON_PORT).await;
    fake.set(CANON_PORT, "busy", "2");
    take(&mut canon, exposure(1.0, Some(800))).await;
    assert_eq!(fake.value(CANON_PORT, "iso"), "800");
}

#[tokio::test]
#[ignore = "needs the fake libgphoto2 on LD_LIBRARY_PATH"]
async fn a_timed_capture_leaves_the_caller_free_and_resets_a_sony_session() {
    let fake = Fake::new();
    fake.attach(SONY, SONY_PORT);
    fake.set(SONY_PORT, "realtime", "1");
    let mut sony = connected(0, SONY, SONY_PORT).await;
    let started = Instant::now();
    sony.start_exposure(exposure(2.0, None)).await.unwrap();
    assert!(
        started.elapsed() < Duration::from_millis(500),
        "start waited {:?}",
        started.elapsed()
    );
    let status = sony.get_status().await.unwrap();
    assert_eq!(status.state, CameraState::Exposing);
    assert!(status.exposure_remaining.unwrap() > 1.0);
    while !sony.is_exposure_complete().await.unwrap() {
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    sony.download_image().await.unwrap();
    assert!(
        fake.trace().contains(&format!("exit {SONY_PORT}")),
        "{}",
        fake.trace()
    );
}

#[tokio::test]
#[ignore = "needs the fake libgphoto2 on LD_LIBRARY_PATH"]
async fn a_fujifilm_xt5_takes_timed_and_bulb_frames() {
    let fake = Fake::new();
    fake.attach(FUJI, FUJI_PORT);
    let mut fuji = connected(0, FUJI, FUJI_PORT).await;
    assert_eq!(
        fuji.get_iso_speeds().await.unwrap(),
        [100, 200, 400, 800, 1600, 3200, 6400, 12800]
    );
    assert_eq!(fuji.get_sensor_info().pixel_size_x, 3.04);
    assert_eq!(
        fuji.get_exposure_range().await.unwrap(),
        Some((1.0 / 8000.0, 3600.0))
    );

    let frame = take(&mut fuji, exposure(1.0 / 250.0, Some(800))).await;
    take(&mut fuji, exposure(1.5, None)).await;
    let made = fake.made(FUJI_PORT);
    assert_eq!(made[0], "timed 0.004");
    assert!((bulb_seconds(&made[1]) - 1.5).abs() < 0.2, "{made:?}");
    assert_eq!(fake.value(FUJI_PORT, "imagequality"), "RAW");
    assert!(matches!(frame.bayer_pattern, Some(BayerPattern::XTrans(_))));
    let info = fuji.get_sensor_info();
    assert_eq!(
        (info.width, info.height),
        (frame.width, frame.height),
        "the frame's own size"
    );
    assert!(matches!(info.bayer_pattern, Some(BayerPattern::XTrans(_))));
}
