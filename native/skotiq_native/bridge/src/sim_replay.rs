//! Replay recorded rig frames through the simulated camera.
//!
//! Armed by `SKOTIQ_SIM_REPLAY=<dir>`, where `<dir>/manifest.json` lists
//! real frames and the device state each was taken in (the format of
//! `test-fixtures/rig-2026-09-14/manifest.json`). While armed, every simulated
//! capture is answered with a recorded frame chosen by what the simulated rig
//! is doing, so autofocus, solving and grading run on real sky:
//!
//! * pointing: farther than [`POINTING_REACH_DEG`] from the recorded field,
//!   the answer is a starless frame. The night recorded nothing there.
//! * exposure: a long light (≥ [`LONG_EXPOSURE_S`]) is answered with the long
//!   frames, in the order they were taken; a short one with the short frames.
//! * guiding: a long frame recorded while guiding is only served while the
//!   simulated guider is guiding. Frames recorded trailed or unguided are
//!   served whatever the guider says: the 2026-09-14 lights trailed while PHD2
//!   reported a lock, so that is what a guided long exposure looked like.
//! * focus: a short frame is chosen by the focuser's OPTICAL position, with
//!   the manifest's backlash applied the way the owner's EAF behaved — the
//!   focuser reports the commanded step, and after a downward move the optics
//!   sit a full dead band higher. Nothing within [`FOCUS_REACH_STEPS`] of a
//!   recorded focus state means a starless frame.
//!
//! The rule throughout is that a state the night did not record gets no
//! picture borrowed from a state it did. A starless frame fails a solve, fails
//! an autofocus and grades as zero stars, which is the honest outcome; a
//! frame from elsewhere would pass them.

use crate::sim_capture::{SimCaptureFrame, SimCaptureRequest};
use serde::Deserialize;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

/// Exposures this long or longer are matched against the recorded lights.
pub(crate) const LONG_EXPOSURE_S: f64 = 30.0;
/// How far the mount may point from the recorded field and still see it.
pub(crate) const POINTING_REACH_DEG: f64 = 0.5;
/// How far, in optical steps, a focus state may be from a recorded one.
pub(crate) const FOCUS_REACH_STEPS: i32 = 40;

#[derive(Debug, Deserialize)]
struct Manifest {
    rig: Rig,
    frames: Vec<FrameEntry>,
    solve: Option<Solve>,
}

#[derive(Debug, Deserialize)]
struct Rig {
    focuser_backlash_steps: i32,
}

#[derive(Debug, Deserialize)]
struct Solve {
    center_ra_deg: f64,
    center_dec_deg: f64,
}

#[derive(Debug, Deserialize)]
struct FrameEntry {
    file: String,
    exposure_s: f64,
    state: FrameState,
}

#[derive(Debug, Deserialize)]
struct FrameState {
    optical_focus_position: Option<i32>,
    /// `true` guided, `false` unguided, `"trailed"` trailed whatever the
    /// guider reported.
    guiding: serde_json::Value,
}

/// How a recorded frame was guided.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Guiding {
    Guided,
    Unguided,
    Trailed,
}

/// One recorded frame, loaded.
#[derive(Debug)]
pub(crate) struct Recorded {
    pub name: String,
    pub exposure_s: f64,
    pub optical_focus_position: Option<i32>,
    pub guiding: Guiding,
    pub width: u32,
    pub height: u32,
    pub data: Vec<u16>,
}

/// The armed replay: recorded frames plus the focuser's gear state.
#[derive(Debug)]
pub(crate) struct Replay {
    pub frames: Vec<Recorded>,
    pub backlash_steps: i32,
    pub field: Option<(f64, f64)>,
    gear: parking_lot::Mutex<Gear>,
    long_served: std::sync::atomic::AtomicUsize,
}

/// How much of the focuser's dead band is taken up: 0 after an upward move,
/// the full backlash after a downward one. Optical = commanded + takeup.
#[derive(Debug, Default)]
struct Gear {
    takeup: i32,
}

/// What the simulated rig is doing when a frame is asked for.
#[derive(Debug, Clone, Copy)]
pub(crate) struct RigState {
    pub exposure_s: f64,
    pub focuser_position: Option<i32>,
    pub pointing_deg: Option<(f64, f64)>,
    pub guiding: bool,
}

/// What the replay chose, and why when it chose nothing.
#[derive(Debug, PartialEq)]
pub(crate) enum Choice<'a> {
    Frame(&'a str),
    Starless(&'static str),
}

impl Replay {
    pub(crate) fn load(dir: &Path) -> Result<Self, String> {
        let manifest_path = dir.join("manifest.json");
        let text = std::fs::read_to_string(&manifest_path)
            .map_err(|e| format!("{}: {e}", manifest_path.display()))?;
        let manifest: Manifest =
            serde_json::from_str(&text).map_err(|e| format!("{}: {e}", manifest_path.display()))?;
        let mut frames = Vec::with_capacity(manifest.frames.len());
        for entry in manifest.frames {
            let path = dir.join(&entry.file);
            let (image, _) = skotiq_imaging::read_fits(&path)
                .map_err(|e| format!("{}: {e}", path.display()))?;
            let data = image
                .as_u16()
                .ok_or_else(|| format!("{}: not a 16-bit frame", path.display()))?;
            let guiding = match &entry.state.guiding {
                serde_json::Value::Bool(true) => Guiding::Guided,
                serde_json::Value::Bool(false) => Guiding::Unguided,
                serde_json::Value::String(s) if s == "trailed" => Guiding::Trailed,
                other => return Err(format!("{}: unknown guiding state {other}", entry.file)),
            };
            frames.push(Recorded {
                name: entry.file,
                exposure_s: entry.exposure_s,
                optical_focus_position: entry.state.optical_focus_position,
                guiding,
                width: image.width,
                height: image.height,
                data,
            });
        }
        Ok(Self {
            frames,
            backlash_steps: manifest.rig.focuser_backlash_steps.max(0),
            field: manifest.solve.map(|s| (s.center_ra_deg, s.center_dec_deg)),
            gear: parking_lot::Mutex::new(Gear::default()),
            long_served: std::sync::atomic::AtomicUsize::new(0),
        })
    }

    /// A focuser move from `from` to `to`, as commanded.
    pub(crate) fn note_focuser_move(&self, from: i32, to: i32) {
        let mut gear = self.gear.lock();
        gear.takeup = (gear.takeup - (to - from)).clamp(0, self.backlash_steps);
    }

    fn optical(&self, commanded: i32) -> i32 {
        commanded + self.gear.lock().takeup
    }

    /// Which recorded frame answers `state`.
    pub(crate) fn choose(&self, state: &RigState) -> Choice<'_> {
        if let (Some((ra, dec)), Some(field)) = (state.pointing_deg, self.field) {
            if separation_deg((ra, dec), field) > POINTING_REACH_DEG {
                return Choice::Starless("the mount points away from the recorded field");
            }
        }
        if state.exposure_s >= LONG_EXPOSURE_S {
            let long: Vec<&Recorded> = self
                .frames
                .iter()
                .filter(|f| f.exposure_s >= LONG_EXPOSURE_S)
                .filter(|f| f.guiding != Guiding::Guided || state.guiding)
                .collect();
            if long.is_empty() {
                return Choice::Starless("no long exposure was recorded in this guider state");
            }
            let n = self
                .long_served
                .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            return Choice::Frame(&long[n % long.len()].name);
        }
        let Some(commanded) = state.focuser_position else {
            return Choice::Starless("no focuser, and the short frames were recorded by focus");
        };
        let optical = self.optical(commanded);
        self.frames
            .iter()
            .filter(|f| f.exposure_s < LONG_EXPOSURE_S)
            .filter_map(|f| f.optical_focus_position.map(|p| (f, (p - optical).abs())))
            .filter(|(_, distance)| *distance <= FOCUS_REACH_STEPS)
            .min_by_key(|(_, distance)| *distance)
            .map_or(
                Choice::Starless("no frame was recorded near this focus"),
                |(f, _)| Choice::Frame(&f.name),
            )
    }

    fn frame(&self, name: &str) -> Option<&Recorded> {
        self.frames.iter().find(|f| f.name == name)
    }
}

fn separation_deg(a: (f64, f64), b: (f64, f64)) -> f64 {
    let (ra1, dec1) = (a.0.to_radians(), a.1.to_radians());
    let (ra2, dec2) = (b.0.to_radians(), b.1.to_radians());
    (dec1.sin() * dec2.sin() + dec1.cos() * dec2.cos() * (ra1 - ra2).cos())
        .clamp(-1.0, 1.0)
        .acos()
        .to_degrees()
}

/// The armed replay, or `None` when `SKOTIQ_SIM_REPLAY` is unset. A set
/// but unloadable directory is logged as an error and disarms the replay
/// rather than silently falling back to the synthetic sky.
pub(crate) fn armed() -> Option<&'static Replay> {
    static REPLAY: OnceLock<Option<Replay>> = OnceLock::new();
    REPLAY
        .get_or_init(|| {
            let dir = PathBuf::from(std::env::var_os("SKOTIQ_SIM_REPLAY")?);
            match Replay::load(&dir) {
                Ok(replay) => {
                    tracing::warn!(
                        "Simulator camera is REPLAYING {} recorded frames from {}",
                        replay.frames.len(),
                        dir.display()
                    );
                    Some(replay)
                }
                Err(e) => {
                    tracing::error!(
                        "SKOTIQ_SIM_REPLAY={} could not be loaded ({e}). Every simulated \
                         frame will be starless until it is fixed: the synthetic sky is not \
                         a stand-in for the recording.",
                        dir.display()
                    );
                    Some(Replay {
                        frames: Vec::new(),
                        backlash_steps: 0,
                        field: None,
                        gear: parking_lot::Mutex::new(Gear::default()),
                        long_served: std::sync::atomic::AtomicUsize::new(0),
                    })
                }
            }
        })
        .as_ref()
}

/// Answer a simulated capture from the recording. Binning is applied by
/// summing; a subframe is cut from the binned frame.
pub(crate) fn capture(
    replay: &Replay,
    request: &SimCaptureRequest,
    state: &RigState,
) -> SimCaptureFrame {
    let choice = replay.choose(state);
    let recorded = match &choice {
        Choice::Frame(name) => replay.frame(name),
        Choice::Starless(_) => None,
    };
    let Some(recorded) = recorded else {
        if let Choice::Starless(why) = choice {
            tracing::warn!("Replay: starless frame ({why}): {state:?}");
        }
        return starless(request);
    };
    tracing::info!("Replay: {} for {state:?}", recorded.name);
    let (mut w, mut h, mut data) = (recorded.width, recorded.height, recorded.data.clone());
    let (bin_x, bin_y) = (request.bin_x.max(1), request.bin_y.max(1));
    if bin_x > 1 || bin_y > 1 {
        let (bw, bh) = (w / bin_x, h / bin_y);
        let mut binned = vec![0u16; (bw * bh) as usize];
        for y in 0..bh {
            for x in 0..bw {
                let mut sum = 0u32;
                for dy in 0..bin_y {
                    for dx in 0..bin_x {
                        sum += u32::from(data[((y * bin_y + dy) * w + x * bin_x + dx) as usize]);
                    }
                }
                binned[(y * bw + x) as usize] = sum.min(u32::from(u16::MAX)) as u16;
            }
        }
        (w, h, data) = (bw, bh, binned);
    }
    if let Some((x0, y0, sw, sh)) = request.subframe {
        if x0 + sw <= w && y0 + sh <= h {
            let mut cut = Vec::with_capacity((sw * sh) as usize);
            for y in y0..y0 + sh {
                let row = (y * w + x0) as usize;
                cut.extend_from_slice(&data[row..row + sw as usize]);
            }
            (w, h, data) = (sw, sh, cut);
        } else {
            tracing::warn!(
                "Replay: subframe {:?} lies outside the recorded frame",
                request.subframe
            );
            return starless(request);
        }
    }
    SimCaptureFrame {
        data,
        width: w,
        height: h,
    }
}

/// Bias level only, at the requested geometry.
fn starless(request: &SimCaptureRequest) -> SimCaptureFrame {
    let (bin_x, bin_y) = (request.bin_x.max(1), request.bin_y.max(1));
    let (w, h) = match request.subframe {
        Some((_, _, sw, sh)) => (sw, sh),
        None => (request.sensor_width / bin_x, request.sensor_height / bin_y),
    };
    SimCaptureFrame {
        data: vec![(request.offset.max(0) as u16).saturating_mul(16).max(256); (w * h) as usize],
        width: w,
        height: h,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn night() -> Replay {
        Replay::load(&Path::new(env!("CARGO_MANIFEST_DIR")).join("../test-fixtures/rig-2026-09-14"))
            .expect("fixture manifest loads")
    }

    const NGC7380: (f64, f64) = (341.8375, 58.1317);

    fn short_at(focuser: i32) -> RigState {
        RigState {
            exposure_s: 2.0,
            focuser_position: Some(focuser),
            pointing_deg: Some(NGC7380),
            guiding: false,
        }
    }

    #[test]
    fn a_run_up_to_6620_sees_the_in_focus_frame_and_a_landing_from_above_does_not() {
        let replay = night();
        // Up through the sweep and onto 6620 from below.
        replay.note_focuser_move(6550, 6250);
        replay.note_focuser_move(6250, 6620);
        assert_eq!(
            replay.choose(&short_at(6620)),
            Choice::Frame("focused_L_0005.fits")
        );
        // The rig's own landing: down from the top of the sweep.
        replay.note_focuser_move(6620, 6850);
        replay.note_focuser_move(6850, 6620);
        assert_eq!(
            replay.choose(&short_at(6620)),
            Choice::Frame("landed_from_above_L_0003.fits")
        );
    }

    #[test]
    fn a_focus_the_night_never_recorded_is_starless() {
        let replay = night();
        replay.note_focuser_move(6250, 6400);
        assert!(matches!(
            replay.choose(&short_at(6400)),
            Choice::Starless(_)
        ));
    }

    #[test]
    fn long_lights_are_the_recorded_lights_in_order_and_only_on_the_recorded_field() {
        let replay = night();
        let light = RigState {
            exposure_s: 180.0,
            focuser_position: Some(6620),
            pointing_deg: Some(NGC7380),
            guiding: true,
        };
        let served: Vec<_> = (0..4).map(|_| replay.choose(&light)).collect();
        assert_eq!(
            served,
            vec![
                Choice::Frame("trailed_Ha_0001_001.fits"),
                Choice::Frame("trailed_SII_0001_001.fits"),
                Choice::Frame("trailed_OIII_0001.fits"),
                Choice::Frame("trailed_Ha_0001_001.fits"),
            ]
        );
        let elsewhere = RigState {
            pointing_deg: Some((83.82, -5.39)),
            ..light
        };
        assert!(matches!(replay.choose(&elsewhere), Choice::Starless(_)));
    }

    fn request(bin: u32, subframe: Option<(u32, u32, u32, u32)>) -> SimCaptureRequest {
        SimCaptureRequest {
            exposure_secs: 2.0,
            sensor_width: 4656,
            sensor_height: 3520,
            pixel_size_um: 3.8,
            gain: 139,
            offset: 21,
            bin_x: bin,
            bin_y: bin,
            subframe,
            frame_type: skotiq_native::camera::FrameType::Light,
            max_adu: 65520,
        }
    }

    #[test]
    fn the_recorded_pixels_come_back_binned_and_cut_as_asked() {
        let replay = night();
        replay.note_focuser_move(6250, 6620);
        let state = short_at(6620);
        let full = capture(&replay, &request(1, None), &state);
        assert_eq!((full.width, full.height), (1024, 1024));
        let recorded = replay.frame("focused_L_0005.fits").expect("loaded");
        assert_eq!(
            full.data, recorded.data,
            "the recording must come back untouched"
        );

        let binned = capture(&replay, &request(2, None), &state);
        assert_eq!((binned.width, binned.height), (512, 512));
        let expected: u32 = [0usize, 1, 1024, 1025]
            .iter()
            .map(|&i| u32::from(recorded.data[i]))
            .sum();
        assert_eq!(u32::from(binned.data[0]), expected.min(65535));

        let cut = capture(&replay, &request(1, Some((100, 200, 64, 32))), &state);
        assert_eq!((cut.width, cut.height), (64, 32));
        assert_eq!(cut.data[0], recorded.data[200 * 1024 + 100]);
    }

    #[test]
    fn a_frame_recorded_guided_is_never_served_to_a_dead_guider() {
        let mut replay = night();
        for frame in &mut replay.frames {
            if frame.exposure_s >= LONG_EXPOSURE_S {
                frame.guiding = Guiding::Guided;
            }
        }
        let unguided = RigState {
            exposure_s: 180.0,
            focuser_position: Some(6620),
            pointing_deg: Some(NGC7380),
            guiding: false,
        };
        assert!(matches!(replay.choose(&unguided), Choice::Starless(_)));
    }
}
