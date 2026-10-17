use super::*;

/// Simulated camera state
pub(crate) static SIM_CAMERA: OnceLock<Arc<RwLock<SimulatedCamera>>> = OnceLock::new();

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
                cooler_on: false,
                gain: 100,
                offset: 10,
                bin_x: 1,
                bin_y: 1,
                sensor_width: crate::sim_frame::SIM_W as u32,
                sensor_height: crate::sim_frame::SIM_H as u32,
                pixel_size_x: 3.76,
                pixel_size_y: 3.76,
                max_adu: crate::sim_frame::SIM_MAX_ADU as u32,
                can_cool: true,
                can_set_gain: true,
                can_set_offset: true,
            },
        }
    }
}

pub(crate) fn get_sim_camera() -> &'static Arc<RwLock<SimulatedCamera>> {
    SIM_CAMERA.get_or_init(|| Arc::new(RwLock::new(SimulatedCamera::default())))
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
/// `skotiq_native::camera::FrameType`, which the generator resolves by bare
/// name to the unrelated `crate::device::FrameType`, emitting a
/// `frb_generated.rs` that does not compile. The committed generated file
/// predates this struct and so hid the problem until the next regeneration.
#[flutter_rust_bridge::frb(ignore)]
#[derive(Debug, Clone)]
pub(crate) struct SimExposureRequest {
    pub secs: f64,
    pub frame_type: skotiq_native::camera::FrameType,
    pub subframe: Option<(u32, u32, u32, u32)>,
}

impl Default for SimExposureRequest {
    fn default() -> Self {
        Self {
            secs: 1.0,
            frame_type: skotiq_native::camera::FrameType::Light,
            subframe: None,
        }
    }
}

pub(crate) static SIM_LAST_EXPOSURE: OnceLock<Arc<RwLock<SimExposureRequest>>> = OnceLock::new();

pub(crate) fn get_sim_last_exposure() -> &'static Arc<RwLock<SimExposureRequest>> {
    SIM_LAST_EXPOSURE.get_or_init(|| Arc::new(RwLock::new(SimExposureRequest::default())))
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

pub(crate) static SIM_EXPOSURE_PHASE: OnceLock<Arc<RwLock<SimExposurePhase>>> = OnceLock::new();

pub(crate) fn sim_exposure_phase() -> &'static Arc<RwLock<SimExposurePhase>> {
    SIM_EXPOSURE_PHASE.get_or_init(|| Arc::new(RwLock::new(SimExposurePhase::Idle)))
}

/// Record the start of a simulated exposure.
pub(crate) async fn begin_sim_exposure(request: SimExposureRequest) {
    *get_sim_last_exposure().write().await = request;
    *sim_exposure_phase().write().await = SimExposurePhase::Integrating(std::time::Instant::now());
}

/// Return the camera to idle without consuming a frame.
///
/// Production code never needs this — the download claims the frame via
/// [`take_sim_exposure_for_download`] and an abort goes through
/// [`abort_sim_exposure`] — but a test that drives the singleton has to be able
/// to start from a known phase.
#[cfg(test)]
pub(crate) async fn clear_sim_exposure() {
    *sim_exposure_phase().write().await = SimExposurePhase::Idle;
}

/// Abandon the in-flight exposure. The frame is gone — a later download must
/// fail rather than synthesize one.
pub(crate) async fn abort_sim_exposure() {
    *sim_exposure_phase().write().await = SimExposurePhase::Aborted;
}

/// Whether the in-flight simulated exposure has finished integrating.
///
/// Idle and aborted both read as complete: a caller polling without having
/// started anything, or after abandoning what it started, must not be made to
/// wait forever.
pub(crate) async fn sim_exposure_is_complete() -> bool {
    match *sim_exposure_phase().read().await {
        SimExposurePhase::Idle | SimExposurePhase::Aborted => true,
        SimExposurePhase::Integrating(start) => {
            let requested = get_sim_last_exposure().read().await.secs;
            sim_exposure_elapsed_is_complete(start.elapsed().as_secs_f64(), requested)
        }
    }
}

/// The camera state a status read should report right now.
///
/// The device layer never drove this, so `camera_get_status` answered `Idle`
/// for the whole of an exposure while `camera_is_exposure_complete` answered
/// "not yet" — two contradictory answers on the same polling cycle.
pub(crate) async fn sim_camera_state() -> CameraState {
    match *sim_exposure_phase().read().await {
        SimExposurePhase::Idle | SimExposurePhase::Aborted => CameraState::Idle,
        SimExposurePhase::Integrating(start) => {
            let requested = get_sim_last_exposure().read().await.secs;
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
pub(crate) async fn take_sim_exposure_for_download() -> Result<(), String> {
    let mut phase = sim_exposure_phase().write().await;
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
            let requested = get_sim_last_exposure().read().await.secs;
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

pub(crate) static SIM_COOLER_LAST_TICK: OnceLock<Arc<RwLock<Option<std::time::Instant>>>> =
    OnceLock::new();

pub(crate) fn sim_cooler_last_tick() -> &'static Arc<RwLock<Option<std::time::Instant>>> {
    SIM_COOLER_LAST_TICK.get_or_init(|| Arc::new(RwLock::new(None)))
}

/// Advance the simulated sensor temperature toward its setpoint.
///
/// Called on every simulated status read, which is what makes the ramp
/// observable: without it the sensor sits at ambient at 0% power forever and a
/// `CoolCamera` node can never reach its setpoint against the simulator.
pub(crate) async fn advance_sim_cooler() {
    let now = std::time::Instant::now();
    let elapsed = {
        let mut last = sim_cooler_last_tick().write().await;
        let elapsed = last.map(|t| now.duration_since(t).as_secs_f64());
        *last = Some(now);
        // First read after launch establishes the baseline instead of jumping.
        match elapsed {
            Some(secs) if secs.is_finite() && secs > 0.0 => secs,
            _ => return,
        }
    };

    let mut guard = get_sim_camera().write().await;
    let current = guard.status.sensor_temp.unwrap_or(SIM_AMBIENT_TEMP_C);
    let (target, rate) = if guard.status.cooler_on {
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
    guard.status.cooler_power = Some(if !guard.status.cooler_on {
        0.0
    } else if (target - next).abs() > 0.5 {
        // Pulling down to the setpoint.
        85.0
    } else {
        // Holding at the setpoint.
        35.0
    });
}

/// Get camera status
pub async fn api_get_camera_status(device_id: String) -> Result<CameraStatus, SkotiqError> {
    let mgr = get_device_manager();
    mgr.camera_get_status(&device_id)
        .await
        .map_err(SkotiqError::from)
}

/// Set camera cooling target
pub async fn api_set_camera_cooler(
    device_id: String,
    enabled: u8,
    target_temp: Option<f64>,
) -> Result<(), SkotiqError> {
    tracing::info!(
        "Setting camera cooler for {}: enabled={}, target={:?}",
        device_id,
        enabled,
        target_temp
    );
    let mgr = get_device_manager();
    mgr.camera_set_cooler(&device_id, enabled != 0, target_temp)
        .await
        .map_err(SkotiqError::from)
}

/// Set camera gain
pub async fn api_set_camera_gain(device_id: String, gain: i32) -> Result<(), SkotiqError> {
    tracing::info!("Setting camera gain for {}: {}", device_id, gain);
    let mgr = get_device_manager();
    mgr.camera_set_gain(&device_id, gain)
        .await
        .map_err(SkotiqError::from)
}

/// Set camera offset
pub async fn api_set_camera_offset(device_id: String, offset: i32) -> Result<(), SkotiqError> {
    tracing::info!("Setting camera offset for {}: {}", device_id, offset);
    let mgr = get_device_manager();
    mgr.camera_set_offset(&device_id, offset)
        .await
        .map_err(SkotiqError::from)
}
