//! The ToupTek-family driver against an independent fake of the toupcam SDK.
//!
//! The fake (`tests/fake_sdk_linux/touptek_independent.c`) was written from
//! `toupcam.h` 60.33015 and the INDI toupbase and NINA drivers, separately from
//! the driver and from `touptek_fake_sdk.rs`. Run with
//! `tests/fake_sdk_linux/run_touptek_independent.sh`.

#![cfg(target_os = "linux")]

use skotiq_device::{CameraDriver, DeviceDriver, ExposureParams, FrameType, SubFrame};
use skotiq_native::vendor::touptek::{discover_devices_for_brand, TouptekCamera};
use std::ffi::{c_char, c_int, c_longlong, c_uint, CStr, CString};
use std::sync::OnceLock;

const MONO: u64 = 0x10;
const ROI_HARDWARE: u64 = 0x8;
const TEC: u64 = 0x80;
const GETTEMPERATURE: u64 = 0x400;
const RAW12: u64 = 0x2000;
const TEC_ONOFF: u64 = 0x20000;
const TRIGGER_SOFTWARE: u64 = 0x80000;
const BLACKLEVEL: u64 = 0x400000;
const CG: u64 = 0x4000000;
const FILTERWHEEL: u64 = 0x0000_1000_0000_0000;

/// The flags of a cooled 12-bit mono astro camera as the real model table lists
/// them: no FLAG_BINSKIP_SUPPORTED (bin/skip resolutions), like almost every
/// ToupTek-family astro model.
const COOLED_MONO_12: u64 = MONO
    | ROI_HARDWARE
    | TEC
    | GETTEMPERATURE
    | RAW12
    | TEC_ONOFF
    | TRIGGER_SOFTWARE
    | BLACKLEVEL
    | CG;

struct Fake {
    _lib: libloading::Library,
    reset: unsafe extern "C" fn(),
    add: unsafe extern "C" fn(*const c_char, *const c_char, u64, c_uint, c_uint, c_int) -> c_int,
    set: unsafe extern "C" fn(c_int, *const c_char, c_longlong) -> c_int,
    get: unsafe extern "C" fn(c_int, *const c_char) -> c_int,
    log: unsafe extern "C" fn() -> *const c_char,
    clear_log: unsafe extern "C" fn(),
    fire: unsafe extern "C" fn(c_uint),
    pixel: unsafe extern "C" fn(c_uint, c_uint, c_int) -> c_uint,
}

fn fake() -> &'static Fake {
    static FAKE: OnceLock<Fake> = OnceLock::new();
    FAKE.get_or_init(|| {
        // SAFETY: the library is the C fake; each field's type matches the C declaration
        // of the symbol it is read from, and `_lib` lives in the same static as the
        // pointers, so the library stays loaded for as long as they can be called.
        unsafe {
            let lib = libloading::Library::new("libtoupcam.so")
                .expect("the independent fake libtoupcam.so must be on LD_LIBRARY_PATH");
            Fake {
                reset: *lib.get(b"FakeToup_reset\0").unwrap(),
                add: *lib.get(b"FakeToup_add\0").unwrap(),
                set: *lib.get(b"FakeToup_set\0").unwrap(),
                get: *lib.get(b"FakeToup_get\0").unwrap(),
                log: *lib.get(b"FakeToup_log\0").unwrap(),
                clear_log: *lib.get(b"FakeToup_clear_log\0").unwrap(),
                fire: *lib.get(b"FakeToup_fire\0").unwrap(),
                pixel: *lib.get(b"FakeToup_sensor_pixel\0").unwrap(),
                _lib: lib,
            }
        }
    })
}

impl Fake {
    fn camera(&self, flags: u64, width: u32, height: u32, max_bits: i32) -> i32 {
        // SAFETY: no arguments; the fake clears its state under its own lock.
        unsafe { (self.reset)() };
        self.add_camera("ATR585M", "tp-1", flags, width, height, max_bits)
    }
    fn add_camera(&self, name: &str, id: &str, flags: u64, w: u32, h: u32, bits: i32) -> i32 {
        let name = CString::new(name).unwrap();
        let id = CString::new(id).unwrap();
        // SAFETY: `name` and `id` are NUL-terminated and outlive the call, which copies them.
        // The fake does not bound-check its eight camera slots; `camera` resets it first, so
        // no test adds more than two.
        unsafe { (self.add)(name.as_ptr(), id.as_ptr(), flags, w, h, bits) }
    }
    fn set(&self, idx: i32, key: &str, value: i64) {
        let key_c = CString::new(key).unwrap();
        assert_eq!(
            // SAFETY: `key_c` is NUL-terminated and outlives the call; `idx` is a slot
            // index `add_camera` returned, which the fake indexes without a bound check.
            unsafe { (self.set)(idx, key_c.as_ptr(), value) },
            1,
            "fake key {key}"
        );
    }
    fn get(&self, idx: i32, key: &str) -> i32 {
        let key = CString::new(key).unwrap();
        // SAFETY: `key` is NUL-terminated and outlives the call; `idx` is a slot index
        // `add_camera` returned, which the fake indexes without a bound check.
        unsafe { (self.get)(idx, key.as_ptr()) }
    }
    fn log(&self) -> String {
        // SAFETY: the log is a static 1 MiB buffer that is never freed and that the fake
        // NUL-terminates after every append, so the scan ends inside it.
        unsafe { CStr::from_ptr((self.log)()) }
            .to_string_lossy()
            .into_owned()
    }
    fn clear_log(&self) {
        // SAFETY: no arguments; the fake truncates its log under its own lock.
        unsafe { (self.clear_log)() }
    }
    fn fire(&self, event: u32) {
        // SAFETY: the fake passes the event to the callback the driver registered, with the
        // context it registered, on this thread; tests fire only while that camera is
        // connected, so the context is alive. With no callback registered it does nothing.
        unsafe { (self.fire)(event) }
    }
    fn pixel(&self, row: u32, col: u32, bits: i32) -> u16 {
        // SAFETY: plain integer arguments; the fake only computes the pattern value.
        unsafe { (self.pixel)(row, col, bits) as u16 }
    }
}

fn run<F: std::future::Future>(f: F) -> F::Output {
    tokio::runtime::Builder::new_current_thread()
        .enable_time()
        .build()
        .unwrap()
        .block_on(f)
}

async fn connected() -> TouptekCamera {
    discover_devices_for_brand("Touptek")
        .await
        .expect("discovery");
    let mut camera = TouptekCamera::new(0, "Touptek");
    camera.connect().await.expect("connect");
    camera
}

fn exposure(bin: i32, subframe: Option<SubFrame>) -> ExposureParams {
    ExposureParams {
        duration_secs: 0.02,
        gain: None,
        offset: None,
        bin_x: bin,
        bin_y: bin,
        subframe,
        readout_mode: None,
        frame_type: FrameType::Light,
    }
}

async fn take(camera: &mut TouptekCamera, params: ExposureParams) -> skotiq_device::ImageData {
    camera.start_exposure(params).await.expect("start exposure");
    for _ in 0..500 {
        if camera.is_exposure_complete().await.unwrap() {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(5)).await;
    }
    camera.download_image().await.expect("download")
}

/// RAW, bit depth, trigger mode and row order are set before the stream starts
/// (INDI toupbase stops the camera around RAW and bit depth changes), and the
/// raw format is read after the bit depth is chosen.
#[test]
#[ignore = "needs the independent fake SDK on LD_LIBRARY_PATH"]
fn connect_sets_the_stream_up_before_it_starts() {
    let fake = fake();
    let cam = fake.camera(COOLED_MONO_12, 64, 48, 12);
    fake.set(cam, "upside_down", 1);
    fake.set(cam, "cg", 1);
    run(async {
        let mut camera = connected().await;
        let log = fake.log();
        let start = log
            .find("StartPullModeWithCallback")
            .expect("stream started");
        for option in [
            "put_Option 0x04 1",
            "put_Option 0x06 1",
            "put_Option 0x0b 1",
            "put_Option 0x23 0",
        ] {
            let at = log
                .find(option)
                .unwrap_or_else(|| panic!("{option} not sent:\n{log}"));
            assert!(at < start, "{option} sent after the stream started:\n{log}");
        }
        let depth = log.find("put_Option 0x06 1").unwrap();
        let format = log.rfind("get_RawFormat").expect("raw format read");
        assert!(
            format > depth,
            "raw format read before the bit depth was set:\n{log}"
        );
        assert_eq!(
            fake.get(cam, "cg"),
            0,
            "a camera left in HCG is put back in LCG"
        );
        let info = camera.get_sensor_info();
        assert_eq!((info.bit_depth, info.max_adu), (12, 4095));
        camera.disconnect().await.unwrap();
    });
}

/// Frames arrive top row first and hold the sensor's own 12-bit values.
#[test]
#[ignore = "needs the independent fake SDK on LD_LIBRARY_PATH"]
fn a_frame_is_the_sensor_top_row_first_at_its_own_bit_depth() {
    let fake = fake();
    for upside_down in [0, 1] {
        let cam = fake.camera(COOLED_MONO_12, 64, 48, 12);
        fake.set(cam, "upside_down", upside_down);
        run(async {
            let mut camera = connected().await;
            let image = take(&mut camera, exposure(1, None)).await;
            assert_eq!((image.width, image.height), (64, 48));
            for (row, col) in [(0, 0), (0, 5), (1, 0), (47, 63), (20, 7)] {
                assert_eq!(
                    image.data[(row * 64 + col) as usize],
                    fake.pixel(row, col, 12),
                    "pixel ({row}, {col}) with the camera left upside-down={upside_down}"
                );
            }
            camera.disconnect().await.unwrap();
        });
    }
}

/// An SDK that does not know OPTION_UPSIDE_DOWN keeps its platform default
/// (top row first off Windows, toupcam.h 0x23), and subframes land where asked.
#[test]
#[ignore = "needs the independent fake SDK on LD_LIBRARY_PATH"]
fn an_sdk_without_the_row_order_option_gives_upright_frames_and_subframes() {
    let fake = fake();
    let cam = fake.camera(COOLED_MONO_12, 64, 48, 12);
    fake.set(cam, "upside_down", 1);
    fake.set(cam, "upside_locked", 1);
    run(async {
        let mut camera = connected().await;
        let image = take(&mut camera, exposure(1, None)).await;
        assert_eq!(image.data[0], fake.pixel(0, 0, 12));
        assert_eq!(image.data[47 * 64], fake.pixel(47, 0, 12));
        let sub = SubFrame {
            start_x: 8,
            start_y: 4,
            width: 16,
            height: 16,
        };
        let image = take(&mut camera, exposure(1, Some(sub))).await;
        assert_eq!((image.width, image.height), (16, 16));
        assert_eq!(image.data[0], fake.pixel(4, 8, 12), "subframe top-left");
        assert_eq!(
            image.data[15 * 16 + 15],
            fake.pixel(19, 23, 12),
            "subframe bottom-right"
        );
        camera.disconnect().await.unwrap();
    });
}

/// Binning is the SDK's digital binning (OPTION_BINNING), offered by INDI and
/// NINA on every model; it does not depend on FLAG_BINSKIP_SUPPORTED.
#[test]
#[ignore = "needs the independent fake SDK on LD_LIBRARY_PATH"]
fn a_camera_without_bin_skip_modes_bins() {
    let fake = fake();
    fake.camera(COOLED_MONO_12, 64, 48, 12);
    run(async {
        let mut camera = connected().await;
        let caps = camera.capabilities();
        assert!(caps.can_set_binning, "binning refused: {caps:?}");
        assert_eq!(caps.max_bin_x, 4);
        let image = take(&mut camera, exposure(2, None)).await;
        assert_eq!((image.width, image.height), (32, 24));
        let sum: u32 = (0..2)
            .flat_map(|dy| (0..2).map(move |dx| (dy, dx)))
            .map(|(dy, dx)| u32::from(fake.pixel(2 + dy, 6 + dx, 12)))
            .sum();
        assert_eq!(u32::from(image.data[32 + 3]), sum.min(4095));
        camera.disconnect().await.unwrap();
    });
}

/// A binned subframe is sent in unbinned sensor pixels, even and at least 8
/// (toupcam.h put_Roi), and the delivered frame is the requested binned size.
#[test]
#[ignore = "needs the independent fake SDK on LD_LIBRARY_PATH"]
fn a_binned_subframe_reads_the_region_asked_for() {
    let fake = fake();
    fake.camera(COOLED_MONO_12, 64, 48, 12);
    run(async {
        let mut camera = connected().await;
        fake.clear_log();
        let sub = SubFrame {
            start_x: 5,
            start_y: 3,
            width: 10,
            height: 8,
        };
        let image = take(&mut camera, exposure(2, Some(sub))).await;
        let log = fake.log();
        assert!(log.contains("put_Roi 10 6 20 16"), "{log}");
        assert_eq!((image.width, image.height), (10, 8));
        let sum: u32 = (0..2)
            .flat_map(|dy| (0..2).map(move |dx| (dy, dx)))
            .map(|(dy, dx)| u32::from(fake.pixel(6 + dy, 10 + dx, 12)))
            .sum();
        assert_eq!(u32::from(image.data[0]), sum.min(4095));
        camera.disconnect().await.unwrap();
    });
}

/// The offset is the camera's black level in ADU of its bit depth, at most
/// 31 << (bits - 8), and frames record what the camera used.
#[test]
#[ignore = "needs the independent fake SDK on LD_LIBRARY_PATH"]
fn the_offset_is_the_black_level() {
    let fake = fake();
    let cam = fake.camera(COOLED_MONO_12, 64, 48, 12);
    run(async {
        let mut camera = connected().await;
        assert_eq!(camera.get_offset_range().await.unwrap(), (0, 496));
        let mut params = exposure(1, None);
        params.offset = Some(120);
        let image = take(&mut camera, params).await;
        assert_eq!(fake.get(cam, "blacklevel"), 120);
        assert_eq!(image.metadata.offset, 120);
        let mut params = exposure(1, None);
        params.offset = Some(497);
        assert!(camera.start_exposure(params).await.is_err());
        camera.disconnect().await.unwrap();
    });
}

/// A camera another program left in trigger cancel mode 1 outputs the cancelled
/// frame after its readout (toupcam.h OPTION_TRIGGER_CANCEL_MODE); that frame
/// must not be delivered as the next exposure.
#[test]
#[ignore = "needs the independent fake SDK on LD_LIBRARY_PATH"]
fn a_late_cancelled_frame_is_not_the_next_exposure() {
    let fake = fake();
    let cam = fake.camera(COOLED_MONO_12, 64, 48, 12);
    fake.set(cam, "cancel_mode", 1);
    fake.set(cam, "cancel_ms", 15);
    fake.set(cam, "deliver_ms", 60);
    run(async {
        let mut camera = connected().await;
        camera.start_exposure(exposure(1, None)).await.unwrap();
        camera.abort_exposure().await.unwrap();
        let mut params = exposure(1, None);
        params.duration_secs = 0.031;
        let image = take(&mut camera, params).await;
        assert!(
            (image.metadata.exposure_time - 0.031).abs() < 1e-9,
            "the aborted 0.02 s frame was delivered"
        );
        camera.disconnect().await.unwrap();
    });
}

/// The cooler is reported as the camera has it at connect, set-point included.
#[test]
#[ignore = "needs the independent fake SDK on LD_LIBRARY_PATH"]
fn the_cooler_reads_as_the_camera_has_it() {
    let fake = fake();
    let cam = fake.camera(COOLED_MONO_12, 64, 48, 12);
    fake.set(cam, "tec", 1);
    fake.set(cam, "tectarget", -150);
    run(async {
        let camera = connected().await;
        let status = camera.get_status().await.unwrap();
        assert_eq!(status.cooler_on, Some(true));
        assert_eq!(status.target_temp, Some(-15.0));
        assert_eq!(status.sensor_temp, Some(21.5));
        assert_eq!(status.cooler_power, Some(50.0));
        assert_eq!(
            camera.get_cooler_temp_range().await.unwrap(),
            Some((-50.0, 40.0))
        );
        let mut camera = camera;
        camera.disconnect().await.unwrap();
    });
}

/// An uncooled 8-bit camera without a thermometer stays connected and reads 8-bit samples.
#[test]
#[ignore = "needs the independent fake SDK on LD_LIBRARY_PATH"]
fn an_uncooled_8_bit_camera_works() {
    let fake = fake();
    fake.camera(TRIGGER_SOFTWARE | ROI_HARDWARE, 32, 16, 8);
    run(async {
        let mut camera = connected().await;
        assert!(camera.get_status().await.is_ok());
        let image = take(&mut camera, exposure(1, None)).await;
        assert_eq!(camera.get_sensor_info().bit_depth, 8);
        assert_eq!(image.data[33], fake.pixel(1, 1, 8));
        camera.disconnect().await.unwrap();
    });
}

/// Filter wheels and focusers the SDK enumerates are not cameras.
#[test]
#[ignore = "needs the independent fake SDK on LD_LIBRARY_PATH"]
fn discovery_lists_only_cameras() {
    let fake = fake();
    fake.camera(COOLED_MONO_12, 64, 48, 12);
    fake.add_camera("FILTERWHEEL", "fw-1", FILTERWHEEL, 0, 0, 8);
    run(async {
        let devices = discover_devices_for_brand("Touptek").await.unwrap();
        assert_eq!(
            devices.iter().map(|d| d.name.as_str()).collect::<Vec<_>>(),
            ["ATR585M"]
        );
    });
}

/// EVENT_TRIGGERFAIL ("trigger failed, for example bad frame data or timeout",
/// SDK manual) ends the exposure at once instead of after the frame timeout.
#[test]
#[ignore = "needs the independent fake SDK on LD_LIBRARY_PATH"]
fn a_failed_trigger_fails_the_exposure_at_once() {
    let fake = fake();
    let cam = fake.camera(COOLED_MONO_12, 64, 48, 12);
    fake.set(cam, "auto_frames", 0);
    run(async {
        let mut camera = connected().await;
        camera.start_exposure(exposure(1, None)).await.unwrap();
        fake.fire(0x0007);
        let started = std::time::Instant::now();
        assert!(camera.is_exposure_complete().await.unwrap());
        assert!(camera.download_image().await.is_err());
        assert!(started.elapsed() < std::time::Duration::from_secs(1));
        camera.disconnect().await.unwrap();
    });
}
