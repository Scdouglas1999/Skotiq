//! The driver against a camera written from Moravian's documents, not from the driver.
//!
//! `DocCamera` answers the calls the way the vendor documents say a camera does:
//! gxccd.h (libgxccd, Linux/macOS), cxusb.h / gxusb.h and
//! MoravianCameraDriver.pdf ("SIPS Camera Driver Interface", Windows), and the
//! two drivers Moravian's users rely on, INDI `indi-mi/mi_ccd.cpp` (maintained
//! by Moravian) and NINA `MoravianCamera.cs`. Where the documents disagree the
//! choice is named at the rule.
//!
//! The sensor holds a known scene: physical pixel (x, y), y counted from the
//! top of the picture, has the value `1 + y * WIDTH + x`. A frame Skotiq hands
//! on is right when its pixel (i, j) is the scene pixel the request named.

use super::*;
use std::collections::HashSet;
use std::sync::Mutex;
use std::time::{Duration, Instant};

const WIDTH: u32 = 12;
const HEIGHT: u32 = 8;
const CAMERA_ID: u32 = 7;
/// GIP_MINIMAL_EXPOSURE is in microseconds (gxccd.h:273, pdf gipMinimalExposure).
const MIN_EXPOSURE_US: i32 = 125;
const READ_MODES: [&str; 3] = ["Normal", "Fast 12-bit", "Low noise"];
/// GIP_DEFAULT_READ_MODE (gxccd.h:277); INDI selects it at connect (mi_ccd.cpp:397-407).
const DEFAULT_READ_MODE: u32 = 2;

fn scene(x: u32, y_from_top: u32) -> u16 {
    (1 + y_from_top * WIDTH + x) as u16
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum Pending {
    /// Camera timing: started, ready once its time has passed.
    Started {
        at: Instant,
        seconds: f64,
        shutter: bool,
        roi: (i32, i32, i32, i32),
    },
    /// Computer timing: begun, not yet ended.
    Begun { at: Instant, shutter: bool },
    /// Computer timing: ended, waiting for GetImage.
    Ended { shutter: bool },
}

#[derive(Debug)]
struct State {
    open: HashSet<u32>,
    initialize_calls: u32,
    released: u32,
    plugged: bool,
    /// Whether an unplugged camera still answers GBP_CONNECTED (with false).
    answers_connected_when_unplugged: bool,
    bin: (u32, u32),
    read_mode: u32,
    gain: Option<u16>,
    target_c: Option<f32>,
    pending: Option<Pending>,
    /// "image ready" asked before the exposure time passed (gxccd.h:397-404 asks callers not to).
    early_ready_polls: u32,
    started_seconds: Vec<f64>,
    shutter_flags: Vec<bool>,
    aborts: Vec<bool>,
    ends: Vec<(bool, bool)>,
}

struct DocCamera {
    library: Library,
    color: bool,
    x_odd: bool,
    y_odd: bool,
    max_gain: i32,
    read_modes: &'static [&'static str],
    state: Mutex<State>,
}

impl DocCamera {
    fn new(library: Library) -> Self {
        Self {
            library,
            color: false,
            x_odd: false,
            y_odd: false,
            max_gain: 4030,
            read_modes: &READ_MODES,
            state: Mutex::new(State {
                open: HashSet::new(),
                initialize_calls: 0,
                released: 0,
                plugged: true,
                answers_connected_when_unplugged: true,
                bin: (1, 1),
                read_mode: 0,
                gain: None,
                target_c: None,
                pending: None,
                early_ready_polls: 0,
                started_seconds: Vec::new(),
                shutter_flags: Vec::new(),
                aborts: Vec::new(),
                ends: Vec::new(),
            }),
        }
    }

    fn st(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap()
    }

    fn handle_for(id: u32) -> PCCamera {
        (0x1000 + id as usize) as PCCamera
    }

    fn live(&self, handle: PCCamera) -> bool {
        let id = (handle as usize).wrapping_sub(0x1000) as u32;
        let st = self.st();
        st.open.contains(&id) && st.plugged
    }

    /// GIP_MAX_PIXEL_VALUE depends on the read mode and binning (gxccd.h:282).
    fn max_pixel(&self) -> i32 {
        let st = self.st();
        match (st.read_mode, st.bin) {
            (1, (1, 1)) => 4095,
            (1, _) => 16383,
            _ => 65535,
        }
    }

    /// The frame the library delivers for a region in binned pixels.
    /// libgxccd: y counted from the bottom (mi_ccd.cpp:514 "libgxccd has 0 on
    /// the bottom") and the first buffer row is the bottom row (gxccd.h:416-434).
    /// Windows: y from the top, first row on top (NINA reads both as they are).
    fn frame(&self, roi: (i32, i32, i32, i32)) -> Vec<u16> {
        let (bx, by) = self.st().bin;
        let full_h = HEIGHT / by;
        let (x, y, w, h) = (roi.0 as u32, roi.1 as u32, roi.2 as u32, roi.3 as u32);
        let mut out = Vec::with_capacity((w * h) as usize);
        for k in 0..h {
            let row_from_top = if self.library == Library::Gxccd {
                full_h - 1 - (y + k)
            } else {
                y + k
            };
            for i in 0..w {
                out.push(scene((x + i) * bx, row_from_top * by));
            }
        }
        out
    }

    fn region_fits(&self, x: i32, y: i32, w: i32, h: i32) -> bool {
        let (bx, by) = self.st().bin;
        let (fw, fh) = ((WIDTH / bx) as i32, (HEIGHT / by) as i32);
        x >= 0 && y >= 0 && w > 0 && h > 0 && x + w <= fw && y + h <= fh
    }
}

impl Api for DocCamera {
    fn library(&self) -> Library {
        self.library
    }

    fn timing(&self) -> Timing {
        match self.library {
            Library::GxUsb => Timing::Computer,
            _ => Timing::Camera,
        }
    }

    fn bottom_up(&self) -> bool {
        self.library == Library::Gxccd
    }

    fn enumerate(&self) -> Vec<u32> {
        if self.st().plugged {
            vec![CAMERA_ID]
        } else {
            Vec::new()
        }
    }

    /// A camera already initialized cannot be initialized again ("already used",
    /// MoravianCameraDriver.pdf Initialize).
    fn initialize(&self, id: u32) -> Option<PCCamera> {
        let mut st = self.st();
        st.initialize_calls += 1;
        if id != CAMERA_ID || !st.plugged || st.open.contains(&id) {
            return None;
        }
        st.open.insert(id);
        Some(Self::handle_for(id))
    }

    unsafe fn raw_release(&self, handle: PCCamera) {
        let id = (handle as usize).wrapping_sub(0x1000) as u32;
        let mut st = self.st();
        assert!(st.open.remove(&id), "released a handle that was not open");
        st.released += 1;
    }

    unsafe fn raw_boolean(&self, handle: PCCamera, index: c_int) -> Option<bool> {
        if index == GBP_CONNECTED {
            let st = self.st();
            return if st.plugged {
                Some(true)
            } else if st.answers_connected_when_unplugged {
                Some(false)
            } else {
                None
            };
        }
        if !self.live(handle) {
            return None;
        }
        Some(match index {
            GBP_SUB_FRAME | GBP_SHUTTER | GBP_COOLER | GBP_GUIDE => true,
            GBP_ASYMMETRIC_BINNING => true,
            GBP_RGB => self.color,
            GBP_CMY | GBP_CMYG => false,
            GBP_DEBAYER_X_ODD => self.x_odd,
            GBP_DEBAYER_Y_ODD => self.y_odd,
            _ => return None,
        })
    }

    unsafe fn raw_integer(&self, handle: PCCamera, index: c_int) -> Option<i32> {
        if !self.live(handle) {
            return None;
        }
        Some(match index {
            GIP_CHIP_W => WIDTH as i32,
            GIP_CHIP_D => HEIGHT as i32,
            GIP_PIXEL_W | GIP_PIXEL_D => 3760,
            GIP_MAX_BINNING_X | GIP_MAX_BINNING_Y => 4,
            GIP_MINIMAL_EXPOSURE => MIN_EXPOSURE_US,
            GIP_DEFAULT_READ_MODE => DEFAULT_READ_MODE as i32,
            GIP_MAX_GAIN => self.max_gain,
            GIP_MAX_PIXEL_VALUE => self.max_pixel(),
            _ => return None,
        })
    }

    unsafe fn raw_string(&self, handle: PCCamera, index: c_int) -> Option<String> {
        if !self.live(handle) {
            return None;
        }
        match index {
            GSP_CAMERA_DESCRIPTION => Some("C3-61000 Pro".to_string()),
            GSP_CAMERA_SERIAL => Some("12345".to_string()),
            _ => None,
        }
    }

    unsafe fn raw_value(&self, handle: PCCamera, index: c_int) -> Option<f32> {
        if !self.live(handle) {
            return None;
        }
        match index {
            GV_CHIP_TEMPERATURE => Some(-9.5),
            // A fraction 0..1 (gxccd.h:323-324).
            GV_POWER_UTILIZATION => Some(0.42),
            _ => None,
        }
    }

    unsafe fn raw_last_error(&self, _: PCCamera) -> String {
        "documented camera refused".to_string()
    }

    unsafe fn raw_set_temperature(&self, handle: PCCamera, celsius: f32) -> bool {
        self.live(handle) && {
            self.st().target_c = Some(celsius);
            true
        }
    }

    unsafe fn raw_set_binning(&self, handle: PCCamera, x: u32, y: u32) -> bool {
        self.live(handle) && (1..=4).contains(&x) && (1..=4).contains(&y) && {
            self.st().bin = (x, y);
            true
        }
    }

    unsafe fn raw_read_mode_name(&self, handle: PCCamera, index: u32) -> Option<String> {
        if !self.live(handle) {
            return None;
        }
        self.read_modes.get(index as usize).map(|s| s.to_string())
    }

    unsafe fn raw_set_read_mode(&self, handle: PCCamera, index: u32) -> bool {
        self.live(handle) && (index as usize) < self.read_modes.len() && {
            self.st().read_mode = index;
            true
        }
    }

    /// Register value 0..GIP_MAX_GAIN (gxccd.h:471-478).
    unsafe fn raw_set_gain(&self, handle: PCCamera, gain: u16) -> Option<bool> {
        Some(
            self.live(handle) && i32::from(gain) <= self.max_gain && {
                self.st().gain = Some(gain);
                true
            },
        )
    }

    unsafe fn raw_start_exposure(
        &self,
        handle: PCCamera,
        seconds: f64,
        open_shutter: bool,
        roi: SdkRoi,
    ) -> bool {
        assert_eq!(self.timing(), Timing::Camera, "gXusb has no StartExposure");
        if !self.live(handle) || !self.region_fits(roi.x, roi.y, roi.w, roi.h) {
            return false;
        }
        let mut st = self.st();
        st.started_seconds.push(seconds);
        st.shutter_flags.push(open_shutter);
        st.pending = Some(Pending::Started {
            at: Instant::now(),
            seconds,
            shutter: open_shutter,
            roi: (roi.x, roi.y, roi.w, roi.h),
        });
        true
    }

    unsafe fn raw_abort_exposure(&self, handle: PCCamera, keep_image: bool) -> bool {
        let mut st = self.st();
        st.aborts.push(keep_image);
        st.pending = None;
        drop(st);
        self.live(handle)
    }

    unsafe fn raw_image_ready(&self, handle: PCCamera) -> Option<bool> {
        if !self.live(handle) {
            return None;
        }
        let mut st = self.st();
        match st.pending {
            Some(Pending::Started { at, seconds, .. }) => {
                let ready = at.elapsed().as_secs_f64() >= seconds;
                if !ready {
                    st.early_ready_polls += 1;
                }
                Some(ready)
            }
            _ => None,
        }
    }

    /// Buffer must hold w*h 16-bit pixels; size in bytes (gxccd.h:408-414).
    unsafe fn raw_read_image(&self, handle: PCCamera, pixels: &mut [u16]) -> bool {
        if !self.live(handle) {
            return false;
        }
        let pending = self.st().pending;
        let Some(Pending::Started {
            at, seconds, roi, ..
        }) = pending
        else {
            return false;
        };
        if at.elapsed().as_secs_f64() < seconds || pixels.len() < (roi.2 * roi.3) as usize {
            return false;
        }
        let frame = self.frame(roi);
        pixels[..frame.len()].copy_from_slice(&frame);
        self.st().pending = None;
        true
    }

    unsafe fn raw_begin_exposure(&self, handle: PCCamera, open_shutter: bool) -> bool {
        assert_eq!(self.timing(), Timing::Computer);
        if !self.live(handle) {
            return false;
        }
        let mut st = self.st();
        st.shutter_flags.push(open_shutter);
        st.pending = Some(Pending::Begun {
            at: Instant::now(),
            shutter: open_shutter,
        });
        true
    }

    /// UseShutter must match the begin call (pdf EndExposure); AbortData true discards.
    unsafe fn raw_end_exposure(&self, handle: PCCamera, open_shutter: bool, discard: bool) -> bool {
        if !self.live(handle) {
            return false;
        }
        let mut st = self.st();
        st.ends.push((open_shutter, discard));
        match st.pending {
            Some(Pending::Begun { at, shutter }) if shutter == open_shutter => {
                st.started_seconds.push(at.elapsed().as_secs_f64());
                st.pending = (!discard).then_some(Pending::Ended { shutter });
                true
            }
            _ => false,
        }
    }

    unsafe fn raw_get_image(&self, handle: PCCamera, roi: SdkRoi, pixels: &mut [u16]) -> bool {
        if !self.live(handle) || !matches!(self.st().pending, Some(Pending::Ended { .. })) {
            return false;
        }
        if !self.region_fits(roi.x, roi.y, roi.w, roi.h) || pixels.len() < (roi.w * roi.h) as usize
        {
            return false;
        }
        let frame = self.frame((roi.x, roi.y, roi.w, roi.h));
        pixels[..frame.len()].copy_from_slice(&frame);
        self.st().pending = None;
        true
    }
}

fn params(seconds: f64, bin: i32, subframe: Option<(u32, u32, u32, u32)>) -> ExposureParams {
    ExposureParams {
        duration_secs: seconds,
        gain: None,
        offset: None,
        bin_x: bin,
        bin_y: bin,
        subframe: subframe.map(|(start_x, start_y, width, height)| SubFrame {
            start_x,
            start_y,
            width,
            height,
        }),
        readout_mode: None,
        frame_type: skotiq_device::camera::FrameType::Light,
    }
}

/// Holds the registry turn for the test, so the open-camera registry is this test's alone.
struct Turn(#[allow(dead_code)] std::sync::MutexGuard<'static, ()>);

fn turn() -> Turn {
    let turn = discovery::REGISTRY_TEST_TURN
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    discovery::forget_every_open_camera();
    Turn(turn)
}

fn connected(api: &DocCamera) -> MoravianCamera {
    let mut camera = MoravianCamera::new(api.library, CAMERA_ID);
    camera.open(api).expect("the documented camera connects");
    camera
}

fn expose(camera: &mut MoravianCamera, api: &DocCamera, p: &ExposureParams) -> ImageData {
    camera.begin(api, p).expect("the exposure starts");
    let deadline = Instant::now() + Duration::from_secs(5);
    while !camera.poll_complete(api).expect("the poll answers") {
        assert!(Instant::now() < deadline, "the exposure never completed");
        std::thread::sleep(Duration::from_millis(2));
    }
    camera.read_frame(api).expect("the frame reads")
}

/// The scene pixels a request for this binned region (origin top-left) names.
fn expected(bin: u32, region: (u32, u32, u32, u32)) -> Vec<u16> {
    let (x, y, w, h) = region;
    (0..h)
        .flat_map(|j| (0..w).map(move |i| scene((x + i) * bin, (y + j) * bin)))
        .collect()
}

const ALL: [Library; 3] = [Library::Gxccd, Library::CxUsb, Library::GxUsb];

#[test]
fn a_full_frame_arrives_top_row_first_on_every_library() {
    let _turn = turn();
    for library in ALL {
        let api = DocCamera::new(library);
        let mut camera = connected(&api);
        let image = expose(&mut camera, &api, &params(0.001, 1, None));
        assert_eq!((image.width, image.height), (WIDTH, HEIGHT), "{library:?}");
        assert_eq!(
            image.data,
            expected(1, (0, 0, WIDTH, HEIGHT)),
            "{library:?}: the frame is not the scene top row first"
        );
    }
}

#[test]
fn a_binned_subframe_reads_the_region_named_in_binned_pixels_from_the_top() {
    let _turn = turn();
    for library in ALL {
        for (bin, region) in [(1, (3, 1, 5, 4)), (2, (1, 1, 3, 2)), (2, (0, 0, 6, 1))] {
            let api = DocCamera::new(library);
            let mut camera = connected(&api);
            let image = expose(&mut camera, &api, &params(0.001, bin, Some(region)));
            assert_eq!((image.width, image.height), (region.2, region.3));
            assert_eq!(
                image.data,
                expected(bin as u32, region),
                "{library:?} bin {bin} region {region:?}"
            );
            assert_eq!((image.metadata.bin_x, image.metadata.bin_y), (bin, bin));
        }
    }
}

#[test]
fn starting_an_exposure_returns_at_once_and_the_camera_is_not_asked_early() {
    let _turn = turn();
    for library in [Library::Gxccd, Library::CxUsb] {
        let api = DocCamera::new(library);
        let mut camera = connected(&api);
        let started = Instant::now();
        camera.begin(&api, &params(0.3, 1, None)).unwrap();
        assert!(started.elapsed() < Duration::from_millis(100));
        for _ in 0..5 {
            assert!(!camera.poll_complete(&api).unwrap());
        }
        assert_eq!(api.st().early_ready_polls, 0, "{library:?}");
        std::thread::sleep(Duration::from_millis(320));
        assert!(camera.poll_complete(&api).unwrap());
        camera.read_frame(&api).unwrap();
    }
}

#[test]
fn computer_timing_ends_after_the_requested_time_and_records_what_was_exposed() {
    let _turn = turn();
    let api = DocCamera::new(Library::GxUsb);
    let mut camera = connected(&api);
    let image = expose(&mut camera, &api, &params(0.05, 1, None));
    let exposed = api.st().started_seconds[0];
    assert!(
        exposed >= 0.05,
        "the camera was exposed {exposed} s for a 0.05 s request"
    );
    assert!((image.metadata.exposure_time - exposed).abs() < 0.01);
    assert_eq!(api.st().ends, vec![(true, false)]);
}

#[test]
fn only_light_and_flat_frames_open_the_shutter() {
    let _turn = turn();
    use skotiq_device::camera::FrameType::*;
    for library in ALL {
        let api = DocCamera::new(library);
        let mut camera = connected(&api);
        for frame_type in [Light, Dark, Flat, Bias, DarkFlat] {
            let mut p = params(0.001, 1, None);
            p.frame_type = frame_type;
            expose(&mut camera, &api, &p);
        }
        assert_eq!(
            api.st().shutter_flags,
            vec![true, false, true, false, false],
            "{library:?} (mi_ccd.cpp:502, MoravianCamera.cs ShouldUseShutter)"
        );
    }
}

#[test]
fn a_request_below_the_shortest_exposure_is_taken_at_it() {
    let _turn = turn();
    let api = DocCamera::new(Library::Gxccd);
    let mut camera = connected(&api);
    let image = expose(&mut camera, &api, &params(0.0, 1, None));
    let min = f64::from(MIN_EXPOSURE_US) / 1e6;
    assert_eq!(api.st().started_seconds, vec![min]);
    assert_eq!(image.metadata.exposure_time, min);
}

#[test]
fn connect_selects_the_default_read_mode_and_bit_depth_follows_mode_and_binning() {
    let _turn = turn();
    for library in ALL {
        let api = DocCamera::new(library);
        let mut camera = connected(&api);
        assert_eq!(api.st().read_mode, DEFAULT_READ_MODE);
        assert_eq!(camera.core.readout_mode.as_deref(), Some(READ_MODES[2]));
        let mut fast = params(0.001, 1, None);
        fast.readout_mode = Some(READ_MODES[1].to_string());
        let image = expose(&mut camera, &api, &fast);
        assert_eq!(
            image.bits_per_pixel, 12,
            "{library:?} 4095 at 1x1 in the 12-bit mode"
        );
        assert_eq!(camera.get_sensor_info().max_adu, 4095);
        let mut binned = params(0.001, 2, None);
        binned.readout_mode = Some(READ_MODES[1].to_string());
        let image = expose(&mut camera, &api, &binned);
        assert_eq!(image.bits_per_pixel, 14, "{library:?} 16383 binned");
        assert_eq!(image.metadata.readout_mode.as_deref(), Some(READ_MODES[1]));
    }
}

#[test]
fn gain_is_a_register_from_zero_to_the_reported_maximum() {
    let _turn = turn();
    let api = DocCamera::new(Library::CxUsb);
    let mut camera = connected(&api);
    assert!(camera.core.capabilities.can_set_gain);
    let mut p = params(0.001, 1, None);
    p.gain = Some(2750);
    let image = expose(&mut camera, &api, &p);
    assert_eq!(api.st().gain, Some(2750));
    assert_eq!(image.metadata.gain, 2750);
    p.gain = Some(4031);
    assert!(matches!(
        camera.begin(&api, &p),
        Err(DriverError::InvalidParameter(_))
    ));

    let mut ccd = DocCamera::new(Library::GxUsb);
    ccd.max_gain = 0;
    let camera = connected(&ccd);
    assert!(
        !camera.core.capabilities.can_set_gain,
        "INDI offers gain only with GIP_MAX_GAIN > 0 (mi_ccd.cpp:198)"
    );
}

#[test]
fn cooler_power_is_reported_in_percent_and_off_is_a_warm_target() {
    let _turn = turn();
    let api = DocCamera::new(Library::Gxccd);
    let mut camera = connected(&api);
    let status = camera.status(&api).unwrap();
    assert_eq!(status.cooler_power, Some(42.0));
    camera.cooler(&api, true, Some(-15.0)).unwrap();
    assert_eq!(api.st().target_c, Some(-15.0));
    camera.cooler(&api, false, None).unwrap();
    assert_eq!(
        api.st().target_c,
        Some(100.0),
        "mi_ccd.cpp:35 TEMP_COOLER_OFF"
    );
}

#[test]
fn an_unplugged_camera_reads_as_disconnected() {
    let _turn = turn();
    for answers in [true, false] {
        let api = DocCamera::new(Library::CxUsb);
        let mut camera = connected(&api);
        api.st().answers_connected_when_unplugged = answers;
        api.st().plugged = false;
        let status = camera.status(&api);
        let start = camera.begin(&api, &params(0.001, 1, None));
        // NINA: Connected = handle && GetBooleanParameter(gbpConnected) succeeded
        // and returned true (MoravianCamera.cs:70, GetBoolSafe).
        assert!(
            matches!(status, Err(DriverError::Disconnected)),
            "unplugged camera that {} GBP_CONNECTED: status {:?}",
            if answers { "answers false to" } else { "fails" },
            status
        );
        assert!(
            matches!(start, Err(DriverError::Disconnected)),
            "start on unplugged camera: {start:?}"
        );
    }
}

#[test]
fn a_search_while_exposing_lists_the_open_camera_without_initializing_it() {
    let _turn = turn();
    for library in ALL {
        let api = DocCamera::new(library);
        let mut camera = connected(&api);
        camera.begin(&api, &params(0.2, 1, None)).unwrap();
        let calls = api.st().initialize_calls;
        let found = discovery::list_cameras(&api);
        assert_eq!(api.st().initialize_calls, calls, "{library:?}");
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].name, "C3-61000 Pro");
        assert_eq!(found[0].serial_number.as_deref(), Some("12345"));
        assert_eq!(
            MoravianCamera::from_address(&found[0].address())
                .unwrap()
                .library,
            library
        );
        camera.abort(&api);
        camera.close(&api);
        assert_eq!(api.st().released, 1);
    }
}

#[test]
fn abort_discards_the_frame_the_way_each_library_says() {
    let _turn = turn();
    let api = DocCamera::new(Library::Gxccd);
    let mut camera = connected(&api);
    camera.begin(&api, &params(1.0, 1, None)).unwrap();
    camera.abort(&api);
    assert_eq!(
        api.st().aborts,
        vec![false],
        "mi_ccd.cpp:534 download=false"
    );

    let api = DocCamera::new(Library::GxUsb);
    let mut camera = connected(&api);
    let mut dark = params(1.0, 1, None);
    dark.frame_type = skotiq_device::camera::FrameType::Dark;
    camera.begin(&api, &dark).unwrap();
    camera.abort(&api);
    assert_eq!(
        api.st().ends,
        vec![(false, true)],
        "EndExposure(UseShutter as begun, AbortData=TRUE) (pdf EndExposure)"
    );
}

/// The Bayer cell at the first pixel of the frame Skotiq hands on (top row
/// first). The flags describe the library's own pixel (0, 0) (gxccd.h:249-252;
/// pdf gbpDebayerXOdd/YOdd), which for libgxccd is the bottom-left pixel. No
/// reference driver uses these flags (INDI sets no pattern, NINA uses offset 0),
/// so this reading is the documents', unconfirmed on hardware.
#[test]
fn the_bayer_cell_follows_the_flags_the_row_direction_and_the_region_origin() {
    let _turn = turn();
    use BayerPattern::*;
    // libgxccd, HEIGHT = 8 (even): the top row is library row 7 (odd).
    let cases = [
        (Library::Gxccd, false, false, None, Gbrg),
        (Library::Gxccd, false, true, None, Rggb),
        (Library::Gxccd, true, false, Some((1, 0, 4, 4)), Gbrg),
        (Library::Gxccd, false, false, Some((0, 1, 4, 4)), Rggb),
        (Library::CxUsb, false, false, None, Rggb),
        (Library::CxUsb, true, true, None, Bggr),
        (Library::CxUsb, false, false, Some((1, 1, 4, 4)), Bggr),
    ];
    for (library, x_odd, y_odd, region, cell) in cases {
        let mut api = DocCamera::new(library);
        api.color = true;
        api.x_odd = x_odd;
        api.y_odd = y_odd;
        let mut camera = connected(&api);
        let image = expose(&mut camera, &api, &params(0.001, 1, region));
        assert_eq!(
            image.bayer_pattern,
            Some(cell),
            "{library:?} x_odd {x_odd} y_odd {y_odd} region {region:?}"
        );
    }
}

/// The capture pipeline selects a read mode by index before every frame only
/// when the camera offers any (imaging_service/exposure_state.dart
/// `_resolveReadoutModeIndex`). A camera whose library lists no read modes
/// offers none and names none on its frames, and its frames start without one.
#[tokio::test]
async fn a_camera_that_lists_no_read_modes_offers_none() {
    let _turn = turn();
    for library in ALL {
        let mut api = DocCamera::new(library);
        api.read_modes = &[];
        let mut camera = connected(&api);
        assert!(
            camera.get_readout_modes().await.unwrap().is_empty(),
            "{library:?}"
        );
        assert_eq!(camera.core.readout_mode, None, "{library:?}");
        camera
            .begin(&api, &params(0.001, 1, None))
            .expect("a frame without a read mode starts");
        camera.abort(&api);
    }
}
