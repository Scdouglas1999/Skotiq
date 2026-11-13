use crate::device::{CameraState, CameraStatus};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};
use tokio::sync::RwLock;

pub const SIM_IMAGING_CAMERA_ID: &str = "sim_camera_1";
/// Id of the simulated guide camera: a small sensor behind a short guide scope,
/// so the built-in guider has a camera of its own and never exposes on the
/// imaging camera.
pub const SIM_GUIDE_CAMERA_ID: &str = "sim_camera_2";
/// Display name of the simulated guide camera.
pub const SIM_GUIDE_CAMERA_NAME: &str = "Simulated Guide Camera";

/// Guide camera sensor, in pixels (a typical 1/3" guide camera).
pub const SIM_GUIDE_SENSOR_W: u32 = 1280;
pub const SIM_GUIDE_SENSOR_H: u32 = 960;
/// Guide camera pixel pitch, in micrometers.
pub const SIM_GUIDE_PIXEL_UM: f64 = 3.75;
/// Focal length of the simulated guide scope, in millimeters (a 60 mm f/4).
pub const SIM_GUIDE_FOCAL_LENGTH_MM: f64 = 240.0;

/// `SKOTIQ_SIM_CAMERA_TRAITS` gives the simulated imaging camera limits of real
/// cameras the default simulator does not have, as a comma-separated list:
/// `no-gain` (no gain or offset control, as FLI and Atik CCDs), `no-cooler`,
/// `cooler-unreported` (a cooler that cannot say whether it is on until
/// Skotiq sets it, as FLI and Moravian), and `dslr` (a DSLR: its sensitivity
/// is the ISO speeds below, with no cooler and no offset, so every DSLR screen
/// can be driven without a body on the desk).
pub(crate) const SIM_CAMERA_TRAITS_ENV: &str = "SKOTIQ_SIM_CAMERA_TRAITS";

/// The limits `SKOTIQ_SIM_CAMERA_TRAITS` names.
#[flutter_rust_bridge::frb(ignore)]
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) struct SimCameraTraits {
    pub(crate) no_gain: bool,
    pub(crate) no_cooler: bool,
    pub(crate) cooler_unreported: bool,
    pub(crate) dslr: bool,
}

impl SimCameraTraits {
    fn parse(text: &str) -> Self {
        let mut traits = Self::default();
        for token in text.split(',').map(str::trim).filter(|t| !t.is_empty()) {
            match token.to_ascii_lowercase().as_str() {
                "no-gain" => traits.no_gain = true,
                "no-cooler" => traits.no_cooler = true,
                "cooler-unreported" => traits.cooler_unreported = true,
                "dslr" => traits.dslr = true,
                other => tracing::warn!("{SIM_CAMERA_TRAITS_ENV}: unknown trait '{other}' ignored"),
            }
        }
        traits
    }
}

/// The simulated imaging camera's traits, read once per process.
pub(crate) fn sim_imaging_camera_traits() -> SimCameraTraits {
    static TRAITS: OnceLock<SimCameraTraits> = OnceLock::new();
    *TRAITS.get_or_init(|| {
        SimCameraTraits::parse(&std::env::var(SIM_CAMERA_TRAITS_ENV).unwrap_or_default())
    })
}

/// The simulated DSLR's ISO speeds: a Canon EOS list, extended speeds
/// included.
pub const SIM_DSLR_ISO_SPEEDS: &[i32] = &[
    100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600, 2000, 2500, 3200, 4000,
    5000, 6400, 8000, 10000, 12800, 25600, 51200,
];

/// Display name of the simulated imaging camera in DSLR mode.
pub const SIM_DSLR_NAME: &str = "Simulated DSLR";

/// Whether the simulated imaging camera is a DSLR.
pub(crate) fn sim_imaging_camera_is_dslr() -> bool {
    sim_imaging_camera_traits().dslr
}

/// The ISO speeds the simulated camera at `device_id` offers; empty for a
/// gain camera.
pub(crate) fn sim_camera_iso_speeds(device_id: &str) -> &'static [i32] {
    if sim_imaging_camera_is_dslr() && !is_sim_guide_camera(device_id) {
        SIM_DSLR_ISO_SPEEDS
    } else {
        &[]
    }
}

/// The gain the simulated camera at `device_id` takes for `requested`: an
/// ISO camera goes to its nearest speed, as a body does.
pub(crate) fn sim_camera_accepted_gain(device_id: &str, requested: i32) -> i32 {
    let speeds = sim_camera_iso_speeds(device_id);
    let wanted = f64::from(requested.max(1));
    speeds
        .iter()
        .copied()
        .min_by(|a, b| {
            let da = (f64::from(*a) / wanted).ln().abs();
            let db = (f64::from(*b) / wanted).ln().abs();
            da.total_cmp(&db)
        })
        .unwrap_or(requested)
}

/// The gain the frame renderer models for the simulated camera: ISO 800 is
/// rendered as the gain camera's 100.
pub(crate) fn sim_render_gain(device_id: &str, gain: i32) -> i32 {
    if sim_camera_iso_speeds(device_id).is_empty() {
        gain
    } else {
        gain / 8
    }
}

/// Whether the two simulated cameras have traded ids, as two USB cameras do
/// when a hub drops and the SDK enumerates them again in the other order (the
/// reference rig, Nov 8 2026: `native:zwo:1` came back as the guide camera).
/// Set by the `unplug(reorder)` fault; see [`unplug_sim_camera`].
static SIM_CAMERA_BUS_SWAPPED: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);

/// Whether `device_id` names the simulated guide camera. After a reorder the
/// guide camera answers the imaging camera's id and the other way round.
pub(crate) fn is_sim_guide_camera(device_id: &str) -> bool {
    let swapped = SIM_CAMERA_BUS_SWAPPED.load(std::sync::atomic::Ordering::SeqCst);
    match device_id {
        SIM_GUIDE_CAMERA_ID => !swapped,
        SIM_IMAGING_CAMERA_ID => swapped,
        _ => false,
    }
}

/// The simulated camera at `device_id` drops off the bus: it reads as
/// disconnected until something connects it again. With `reorder`, the two
/// simulated cameras come back at each other's ids.
pub(crate) async fn unplug_sim_camera(device_id: &str, reorder: bool) {
    get_sim_camera_for(device_id).write().await.status.connected = false;
    if reorder {
        // Both cameras sat behind the hub, so both re-enumerate.
        for id in [SIM_IMAGING_CAMERA_ID, SIM_GUIDE_CAMERA_ID] {
            get_sim_camera_for(id).write().await.status.connected = false;
        }
        SIM_CAMERA_BUS_SWAPPED.fetch_xor(true, std::sync::atomic::Ordering::SeqCst);
        tracing::warn!(
            "Simulated camera bus re-enumerated: {} and {} traded places",
            SIM_IMAGING_CAMERA_ID,
            SIM_GUIDE_CAMERA_ID
        );
        crate::discovery::forget().await;
    }
}

/// Put the simulated cameras back at their own ids (tests).
#[cfg(test)]
pub(crate) fn reset_sim_camera_bus() {
    SIM_CAMERA_BUS_SWAPPED.store(false, std::sync::atomic::Ordering::SeqCst);
}

/// Fault-injection key prefix for a simulated camera: the guide camera has its
/// own keys so a fault armed for the imaging camera's downloads does not also
/// count the guider's frames.
pub(crate) fn sim_camera_fault_prefix(device_id: &str) -> &'static str {
    if is_sim_guide_camera(device_id) {
        "guide_camera"
    } else {
        "camera"
    }
}

/// Everything one simulated camera keeps between calls.
pub(crate) struct SimCameraUnit {
    pub(crate) camera: Arc<RwLock<SimulatedCamera>>,
    pub(crate) last_exposure: Arc<RwLock<SimExposureRequest>>,
    pub(crate) phase: Arc<RwLock<SimExposurePhase>>,
    pub(crate) cooler_tick: Arc<RwLock<Option<std::time::Instant>>>,
}

impl SimCameraUnit {
    fn new(camera: SimulatedCamera) -> Self {
        Self {
            camera: Arc::new(RwLock::new(camera)),
            last_exposure: Arc::new(RwLock::new(SimExposureRequest::default())),
            phase: Arc::new(RwLock::new(SimExposurePhase::Idle)),
            cooler_tick: Arc::new(RwLock::new(None)),
        }
    }
}

static SIM_IMAGING_UNIT: OnceLock<SimCameraUnit> = OnceLock::new();
static SIM_GUIDE_UNIT: OnceLock<SimCameraUnit> = OnceLock::new();

/// The simulated camera `device_id` names. Any simulator camera id other than
/// the guide camera's is the imaging camera, which keeps legacy ids working.
pub(crate) fn sim_camera_unit(device_id: &str) -> &'static SimCameraUnit {
    if is_sim_guide_camera(device_id) {
        SIM_GUIDE_UNIT.get_or_init(|| SimCameraUnit::new(SimulatedCamera::guide_camera()))
    } else {
        SIM_IMAGING_UNIT.get_or_init(|| {
            SimCameraUnit::new(SimulatedCamera::imaging_camera(sim_imaging_camera_traits()))
        })
    }
}

#[flutter_rust_bridge::frb]
pub struct SimulatedCamera {
    pub status: CameraStatus,
}

impl Default for SimulatedCamera {
    fn default() -> Self {
        Self {
            status: CameraStatus {
                connected: false,
                state: CameraState::Idle,
                sensor_temp: Some(20.0),
                cooler_power: Some(0.0),
                target_temp: Some(-10.0),
                cooler_on: Some(false),
                gain: 100,
                offset: 10,
                bin_x: 1,
                bin_y: 1,
                sensor_width: crate::simulator::frame::SIM_W as u32,
                sensor_height: crate::simulator::frame::SIM_H as u32,
                pixel_size_x: 3.76,
                pixel_size_y: 3.76,
                max_adu: crate::simulator::frame::SIM_MAX_ADU as u32,
                saturation_adu: None,
                can_cool: true,
                can_set_gain: true,
                can_set_offset: true,
            },
        }
    }
}

impl SimulatedCamera {
    /// The simulated imaging camera with `traits` applied (a DSLR shoots at
    /// ISO 800).
    pub(crate) fn imaging_camera(traits: SimCameraTraits) -> Self {
        let mut camera = Self::default();
        if traits.no_gain {
            camera.status.can_set_gain = false;
            camera.status.can_set_offset = false;
            camera.status.gain = 0;
            camera.status.offset = 0;
        }
        if traits.no_cooler {
            camera.status.can_cool = false;
            camera.status.target_temp = None;
            camera.status.cooler_power = None;
        } else if traits.cooler_unreported {
            camera.status.cooler_on = None;
            camera.status.target_temp = None;
        }
        if traits.dslr {
            camera.status.can_cool = false;
            camera.status.target_temp = None;
            camera.status.cooler_power = None;
            camera.status.can_set_offset = false;
            camera.status.offset = 0;
            camera.status.gain = 800;
        }
        camera
    }

    /// The simulated guide camera: uncooled, small, mono.
    pub(crate) fn guide_camera() -> Self {
        let mut camera = Self::default();
        camera.status.sensor_width = SIM_GUIDE_SENSOR_W;
        camera.status.sensor_height = SIM_GUIDE_SENSOR_H;
        camera.status.pixel_size_x = SIM_GUIDE_PIXEL_UM;
        camera.status.pixel_size_y = SIM_GUIDE_PIXEL_UM;
        camera.status.can_cool = false;
        camera.status.target_temp = None;
        camera.status.cooler_power = None;
        camera.status.gain = 50;
        camera
    }
}

#[cfg(test)]
pub(crate) fn get_sim_camera() -> &'static Arc<RwLock<SimulatedCamera>> {
    get_sim_camera_for(SIM_IMAGING_CAMERA_ID)
}

/// The simulated camera `device_id` names.
pub(crate) fn get_sim_camera_for(device_id: &str) -> &'static Arc<RwLock<SimulatedCamera>> {
    &sim_camera_unit(device_id).camera
}

/// What the most recently started simulated exposure was asked for.
///
/// The simulator does not integrate for real, but the download path still has
/// to report an `ImageMetadata::exposure_time`, and that value becomes the saved
/// frame's `EXPTIME` — the one FITS keyword calibration and stacking tools trust
/// most. It was a hardcoded `1.0`, so every simulated frame claimed a 1-second
/// exposure regardless of what the sequence asked for.
///
/// `frame_type` and `subframe` live here for the same reason: the download op
/// takes only a device id, so without them a DARK was generated as a star field
/// and announced itself as a light, and a subframe request came back full-frame.
///
/// Kept out of [`SimulatedCamera`] on purpose: that struct is mirrored to Dart
/// by flutter_rust_bridge, and Dart has no use for this.
///
/// `frb(ignore)` enforces that. Living under `api::` is enough for the codegen
/// to try to bridge it anyway, and it cannot: `frame_type` is
/// `skotiq_device::FrameType`, which the generator resolves by bare
/// name to the unrelated `crate::device::FrameType`, emitting a
/// `frb_generated.rs` that does not compile. The committed generated file
/// predates this struct and so hid the problem until the next regeneration.
#[flutter_rust_bridge::frb(ignore)]
#[derive(Debug, Clone)]
pub(crate) struct SimExposureRequest {
    pub secs: f64,
    pub frame_type: skotiq_device::FrameType,
    pub subframe: Option<(u32, u32, u32, u32)>,
}

impl Default for SimExposureRequest {
    fn default() -> Self {
        Self {
            secs: 1.0,
            frame_type: skotiq_device::FrameType::Light,
            subframe: None,
        }
    }
}

pub(crate) fn get_sim_last_exposure_for(
    device_id: &str,
) -> &'static Arc<RwLock<SimExposureRequest>> {
    &sim_camera_unit(device_id).last_exposure
}

/// Monotonic frame counter feeding the noise seed of each simulated read.
///
/// Successive frames must not be bit-identical or a stack cannot exercise
/// sigma-clipping, while a fixed starting point keeps a run reproducible.
pub(crate) static SIM_FRAME_SEED: AtomicU64 = AtomicU64::new(0);

pub(crate) fn next_sim_frame_seed() -> u64 {
    SIM_FRAME_SEED.fetch_add(1, Ordering::Relaxed)
}

/// Reset the frame-noise sequence so a test can reproduce a run exactly.
#[cfg(test)]
pub(crate) fn reset_sim_frame_seed(seed: u64) {
    SIM_FRAME_SEED.store(seed, Ordering::Relaxed);
}

/// Where the simulated camera is in its exposure cycle.
///
/// Real cameras pace their callers by simply not being finished yet, so the
/// simulator holds an exposure for its requested duration too. Completing
/// instantly leaves nothing to pace the built-in guider's capture loop and
/// makes exposure progress, remaining-time estimates and "still integrating"
/// UI state impossible to exercise without hardware.
///
/// `Aborted` is distinct from `Idle` on purpose. Both release a caller polling
/// for completion, but only `Idle` follows a frame that was actually read out —
/// collapsing them let a download after an abort hand back a full frame, so an
/// aborted exposure was indistinguishable from a successful one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SimExposurePhase {
    Idle,
    Integrating(std::time::Instant),
    Aborted,
}

fn sim_exposure_phase(device_id: &str) -> &'static Arc<RwLock<SimExposurePhase>> {
    &sim_camera_unit(device_id).phase
}

/// Record the start of a simulated exposure on the imaging camera.
#[cfg(test)]
pub(crate) async fn begin_sim_exposure(request: SimExposureRequest) {
    begin_sim_exposure_for(SIM_IMAGING_CAMERA_ID, request).await;
}

/// Record the start of a simulated exposure on `device_id`.
pub(crate) async fn begin_sim_exposure_for(device_id: &str, request: SimExposureRequest) {
    *get_sim_last_exposure_for(device_id).write().await = request;
    *sim_exposure_phase(device_id).write().await =
        SimExposurePhase::Integrating(std::time::Instant::now());
}

/// Return the camera to idle without consuming a frame.
///
/// Production code never needs this — the download claims the frame via
/// [`take_sim_exposure_for_download`] and an abort goes through
/// [`abort_sim_exposure`] — but a test that drives the singleton has to be able
/// to start from a known phase.
#[cfg(test)]
pub(crate) async fn clear_sim_exposure() {
    *sim_exposure_phase(SIM_IMAGING_CAMERA_ID).write().await = SimExposurePhase::Idle;
    *sim_exposure_phase(SIM_GUIDE_CAMERA_ID).write().await = SimExposurePhase::Idle;
}

/// Abandon the in-flight exposure. The frame is gone — a later download must
/// fail rather than synthesize one.
pub(crate) async fn abort_sim_exposure(device_id: &str) {
    *sim_exposure_phase(device_id).write().await = SimExposurePhase::Aborted;
}

/// Whether the in-flight simulated exposure has finished integrating.
///
/// Idle and aborted both read as complete: a caller polling without having
/// started anything, or after abandoning what it started, must not be made to
/// wait forever.
pub(crate) async fn sim_exposure_is_complete(device_id: &str) -> bool {
    match *sim_exposure_phase(device_id).read().await {
        SimExposurePhase::Idle | SimExposurePhase::Aborted => true,
        SimExposurePhase::Integrating(start) => {
            let requested = get_sim_last_exposure_for(device_id).read().await.secs;
            sim_exposure_elapsed_is_complete(start.elapsed().as_secs_f64(), requested)
        }
    }
}

/// The camera state a status read should report right now.
///
/// The device layer never drove this, so `camera_get_status` answered `Idle`
/// for the whole of an exposure while `camera_is_exposure_complete` answered
/// "not yet" — two contradictory answers on the same polling cycle.
pub(crate) async fn sim_camera_state(device_id: &str) -> CameraState {
    match *sim_exposure_phase(device_id).read().await {
        SimExposurePhase::Idle | SimExposurePhase::Aborted => CameraState::Idle,
        SimExposurePhase::Integrating(start) => {
            let requested = get_sim_last_exposure_for(device_id).read().await.secs;
            if sim_exposure_elapsed_is_complete(start.elapsed().as_secs_f64(), requested) {
                CameraState::Reading
            } else {
                CameraState::Exposing
            }
        }
    }
}

/// Claim the finished frame for download, moving the camera back to idle.
///
/// Returns the reason the frame is not available when it is not: downloading
/// mid-exposure, after an abort, or without having started anything at all are
/// all caller errors that a real driver reports rather than satisfying.
pub(crate) async fn take_sim_exposure_for_download(device_id: &str) -> Result<(), String> {
    let mut phase = sim_exposure_phase(device_id).write().await;
    match *phase {
        SimExposurePhase::Idle => Err(
            "No exposure is available to download from the simulated camera. \
             Start an exposure first."
                .to_string(),
        ),
        SimExposurePhase::Aborted => Err(
            "The simulated camera's exposure was aborted, so there is no frame to download."
                .to_string(),
        ),
        SimExposurePhase::Integrating(start) => {
            let requested = get_sim_last_exposure_for(device_id).read().await.secs;
            let elapsed = start.elapsed().as_secs_f64();
            if !sim_exposure_elapsed_is_complete(elapsed, requested) {
                return Err(format!(
                    "The simulated camera is still integrating ({:.1}s of {:.1}s elapsed); \
                     wait for the exposure to complete before downloading.",
                    elapsed, requested
                ));
            }
            *phase = SimExposurePhase::Idle;
            Ok(())
        }
    }
}

/// Completion predicate, split out so the boundary is testable without a clock.
///
/// A non-finite or non-positive request completes immediately rather than
/// hanging: a 0-second bias frame is a legitimate request, and a NaN duration is
/// a caller bug that must not wedge the capture loop.
pub(crate) fn sim_exposure_elapsed_is_complete(elapsed_secs: f64, requested_secs: f64) -> bool {
    if !requested_secs.is_finite() || requested_secs <= 0.0 {
        return true;
    }
    elapsed_secs >= requested_secs
}

/// Ambient temperature the simulated sensor drifts back to with the cooler off.
pub(crate) const SIM_AMBIENT_TEMP_C: f64 = 20.0;
/// Cooling slew rate, °C per second.
///
/// Deliberately far brisker than real hardware (a good TEC manages roughly a
/// degree a second): the point is that cooling COMPLETES within a sequence
/// node's normal budget so `CoolCamera` / `WarmCamera`, the cooling UI and the
/// "wait for setpoint" paths are all exercisable without a camera attached.
/// It still ramps rather than snapping, so intermediate states are observable.
pub(crate) const SIM_COOL_RATE_C_PER_SEC: f64 = 8.0;
/// Passive warm-up is slower than active cooling, as on real hardware.
pub(crate) const SIM_WARM_RATE_C_PER_SEC: f64 = 3.0;

/// Advance the simulated sensor temperature toward its setpoint.
///
/// Called on every simulated status read, which is what makes the ramp
/// observable: without it the sensor sits at ambient at 0% power forever and a
/// `CoolCamera` node can never reach its setpoint against the simulator.
pub(crate) async fn advance_sim_cooler(device_id: &str) {
    let now = std::time::Instant::now();
    let elapsed = {
        let mut last = sim_camera_unit(device_id).cooler_tick.write().await;
        let elapsed = last.map(|t| now.duration_since(t).as_secs_f64());
        *last = Some(now);
        // First read after launch establishes the baseline instead of jumping.
        match elapsed {
            Some(secs) if secs.is_finite() && secs > 0.0 => secs,
            _ => return,
        }
    };

    let mut guard = get_sim_camera_for(device_id).write().await;
    let current = guard.status.sensor_temp.unwrap_or(SIM_AMBIENT_TEMP_C);
    let (target, rate) = if guard.status.cooler_on == Some(true) {
        (
            guard.status.target_temp.unwrap_or(SIM_AMBIENT_TEMP_C),
            SIM_COOL_RATE_C_PER_SEC,
        )
    } else {
        (SIM_AMBIENT_TEMP_C, SIM_WARM_RATE_C_PER_SEC)
    };

    let delta = target - current;
    let step = rate * elapsed;
    let next = if delta.abs() <= step {
        target
    } else {
        current + step * delta.signum()
    };
    guard.status.sensor_temp = Some(next);
    if !guard.status.can_cool {
        return;
    }
    guard.status.cooler_power = Some(if guard.status.cooler_on != Some(true) {
        0.0
    } else if (target - next).abs() > 0.5 {
        // Pulling down to the setpoint.
        85.0
    } else {
        // Holding at the setpoint.
        35.0
    });
}
