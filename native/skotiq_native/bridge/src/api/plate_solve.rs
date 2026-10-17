// split from monolithic api.rs
#![allow(unused_imports)]
// Shared imports inherited from the monolithic api.rs.
use crate::device::*;
use crate::device_manager::DeviceManager;
use crate::error::*;
use crate::event::*;
use crate::state::*;
use crate::storage::{AppSettings, ObserverLocation};
use crate::unified_device_ops::create_unified_device_ops;
use skotiq_imaging::{
    calculate_airmass, validate_fits_header, validate_image, write_fits, BayerPattern,
    DebayerAlgorithm, FitsHeader, ImageData,
};
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::sync::OnceLock;
use std::time::{Duration, Instant};
use tokio::sync::Mutex;
use tokio::sync::RwLock;
// Sibling-module items via the parent's pub use re-exports.
use super::*;

/// Process-wide admission gate shared by UI, headless HTTP, sequencer, and
/// recovery callers. External solvers write sibling `.ini`/`.wcs` artifacts;
/// allowing overlapping runs can mix or delete another solve's result.
static PLATE_SOLVE_GATE: OnceLock<Mutex<()>> = OnceLock::new();
const DEFAULT_SOLVER_TIMEOUT_SECS: u32 = 60;
const MAX_SOLVER_TIMEOUT_SECS: u32 = 3600;

fn plate_solve_gate() -> &'static Mutex<()> {
    PLATE_SOLVE_GATE.get_or_init(|| Mutex::new(()))
}

/// Solves currently running, keyed by the frame they are solving.
///
/// The admission gate above serialises solves; it does not stop two callers from
/// solving the *same frame twice in a row*, and a second blind solve throws away
/// the position hint the first caller had. One frame has one answer, so the
/// second caller waits for the first caller's result instead of launching a
/// solver of its own.
type SolveOutcome = Result<PlateSolveResult, String>;
type SolveBroadcast = tokio::sync::broadcast::Sender<Arc<SolveOutcome>>;
static IN_FLIGHT_SOLVES: OnceLock<std::sync::Mutex<HashMap<String, SolveBroadcast>>> =
    OnceLock::new();

fn in_flight_solves() -> &'static std::sync::Mutex<HashMap<String, SolveBroadcast>> {
    IN_FLIGHT_SOLVES.get_or_init(|| std::sync::Mutex::new(HashMap::new()))
}

/// What a caller brings to a solve of the same frame.
///
/// Coalescing alone leaves *which* caller leads a race, and the two are not
/// interchangeable: on a real rig a blind ASTAP run costs tens of seconds
/// against a few for a hinted one, and it is the run that can lock onto the
/// wrong field. The hinted caller therefore always leads, so no solve pays the
/// blind cost while a good position hint sits unused in the other caller.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum SolvePreference {
    /// The caller knows roughly where the telescope is pointing (and/or the
    /// field scale). Always leads.
    Hinted,
    /// The caller knows nothing about the field. Yields the lead briefly so a
    /// hinted caller for the same frame can take it.
    Blind,
}

/// How long a blind caller waits for a hinted caller to claim the same frame.
///
/// The two live requests for one snapshot arrived 4 ms and 11 ms apart. This is
/// an order of magnitude above that and an order of magnitude below the cost it
/// avoids; a blind solve that really is alone pays it once and is otherwise
/// unaffected.
const BLIND_YIELD_WINDOW: Duration = Duration::from_millis(150);
const BLIND_YIELD_POLL: Duration = Duration::from_millis(5);

fn solve_in_flight(key: &str) -> bool {
    in_flight_solves()
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .contains_key(key)
}

/// Removes the in-flight entry even if the solve future is dropped or panics,
/// so one abandoned solve cannot wedge every later solve of that frame.
struct InFlightGuard(String);

impl Drop for InFlightGuard {
    fn drop(&mut self) {
        if let Ok(mut map) = in_flight_solves().lock() {
            map.remove(&self.0);
        }
    }
}

/// Run `solve` for `file_path`, or — if that exact frame is already being
/// solved — wait for the running solve and return its result.
///
/// `label` names the caller in the log so the two callers of a coalesced pair
/// are identifiable afterwards; that log line is the only way the double-solve
/// showed up at all.
pub(crate) async fn coalesced_solve<F, Fut>(
    file_path: &str,
    label: &str,
    preference: SolvePreference,
    solve: F,
) -> Result<PlateSolveResult, SkotiqError>
where
    F: FnOnce() -> Fut,
    Fut: std::future::Future<Output = Result<PlateSolveResult, SkotiqError>>,
{
    // Canonicalise so `./frame.fits` and `/tmp/frame.fits` are one frame. A
    // path that cannot be canonicalised (not yet written, odd mount) keys on
    // its own spelling rather than failing the solve.
    let key = std::fs::canonicalize(file_path)
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_else(|_| file_path.to_string());

    // A blind caller offers the lead to a hinted caller for the same frame
    // before claiming it. Nothing is skipped either way: whoever leads,
    // exactly one solver runs and both callers get its answer.
    if preference == SolvePreference::Blind && !solve_in_flight(&key) {
        let deadline = Instant::now() + BLIND_YIELD_WINDOW;
        let mut yielded = false;
        while Instant::now() < deadline {
            tokio::time::sleep(BLIND_YIELD_POLL).await;
            if solve_in_flight(&key) {
                yielded = true;
                break;
            }
        }
        if yielded {
            tracing::info!(
                "Plate solve ({label}): a hinted solve of {key} took the lead; \
                 waiting for it rather than solving blind"
            );
        }
    }

    let (leader_tx, follower_rx) = {
        let mut map = in_flight_solves()
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        match map.get(&key) {
            Some(tx) => (None, Some(tx.subscribe())),
            None => {
                let (tx, _rx) = tokio::sync::broadcast::channel(1);
                map.insert(key.clone(), tx.clone());
                (Some(tx), None)
            }
        }
    };

    if let Some(mut rx) = follower_rx {
        tracing::info!(
            "Plate solve ({label}): {key} is already being solved; waiting for that \
             result instead of starting a second solver process"
        );
        match rx.recv().await {
            Ok(outcome) => return (*outcome).clone().map_err(SkotiqError::OperationFailed),
            Err(e) => {
                tracing::warn!(
                    "Plate solve ({label}): the solve of {key} we were waiting on ended \
                     without publishing a result ({e}); solving it here instead"
                );
                return solve().await;
            }
        }
    }

    let _guard = InFlightGuard(key);
    let result = solve().await;
    if let Some(tx) = leader_tx {
        // Publish before the guard removes the entry: a follower that is
        // already subscribed gets the answer, and any caller arriving after
        // this starts a fresh solve.
        let _ = tx.send(Arc::new(result.clone().map_err(|e| e.to_string())));
    }
    result
}

/// Take the admission gate, saying so when the caller has to wait.
///
/// A solve that queues behind another solve looks, from the outside, exactly
/// like a slow solve. Naming the wait is what turns "the solver is slow"
/// into "two callers are solving at once".
async fn acquire_solve_gate(label: &str) -> tokio::sync::MutexGuard<'static, ()> {
    let gate = plate_solve_gate();
    match gate.try_lock() {
        Ok(guard) => guard,
        Err(_) => {
            let waited = Instant::now();
            let guard = gate.lock().await;
            tracing::info!(
                "Plate solve ({label}): waited {:.1}s for another solve to finish \
                 (one solver process at a time)",
                waited.elapsed().as_secs_f64()
            );
            guard
        }
    }
}

fn validate_solver_timeout(timeout_secs: Option<u32>) -> Result<u32, SkotiqError> {
    let timeout = timeout_secs.unwrap_or(DEFAULT_SOLVER_TIMEOUT_SECS);
    if timeout == 0 || timeout > MAX_SOLVER_TIMEOUT_SECS {
        return Err(SkotiqError::InvalidParameter(format!(
            "Plate-solve timeout must be between 1 and {MAX_SOLVER_TIMEOUT_SECS} seconds"
        )));
    }
    Ok(timeout)
}

// Solver hints

/// The field-scale facts a solve can be told up front.
///
/// A solver given no scale has to find one. ASTAP sweeps its field-of-view
/// ladder downward from ~9.5°, and on a narrow field that sweep is the
/// difference between a 0.3 s solve and five consecutive failures on the same
/// frames, same catalogs, same sensor. Both numbers here are measured rather
/// than assumed — the focal length is the operator's own profile entry and the
/// pitch is what the camera reports — so a rig that reports neither contributes
/// no card and the solver behaves exactly as it did before.
///
/// Gather once per solve with [`gather_solve_hints`] and hand the result to
/// whichever writer stamps the frame the solver will read: the solver never
/// sees these values as flags, it reads them out of the FITS header.
#[derive(Debug, Clone)]
pub(crate) struct SolveHints {
    /// Telescope focal length in millimetres (FITS `FOCALLEN`).
    pub(crate) focal_length_mm: Option<f64>,
    /// UNBINNED sensor pixel pitch in microns, `(x, y)` (FITS `PIXSIZE1/2`).
    pub(crate) pixel_size_um: Option<(f64, f64)>,
    /// Binning the frame was taken at. `XPIXSZ`/`YPIXSZ` are the pitch scaled
    /// by it, which is what a solver needs to derive the plate scale.
    pub(crate) binning: (i32, i32),
}

impl Default for SolveHints {
    fn default() -> Self {
        Self {
            focal_length_mm: None,
            pixel_size_um: None,
            // Unbinned, so a caller that never learned the binning still
            // stamps a truthful pitch rather than zeroing it.
            binning: (1, 1),
        }
    }
}

/// Plate scale in arcsec per UNBINNED pixel, per camera id, as measured by the
/// most recent successful solve on that camera.
///
/// Normalised to unbinned on the way in and scaled back up on the way out, so
/// one remembered number serves every binning the rig images at.
///
/// Process-global for the same reason [`ACTIVE_SOLVER_PREF`] is: the solve call
/// sites sit deep in the call stack with nowhere to thread a parameter. Session
/// lifetime only — the first solve after a restart still has to sweep, and
/// promoting this to the durable profile store is the obvious next step. It is
/// not a substitute for the focal length: an operator who enters the real focal
/// length gets the computed scale, which is authoritative and binning-exact.
///
/// [`ACTIVE_SOLVER_PREF`]: skotiq_imaging
static MEASURED_PLATE_SCALE: std::sync::LazyLock<
    std::sync::RwLock<std::collections::HashMap<String, f64>>,
> = std::sync::LazyLock::new(|| std::sync::RwLock::new(std::collections::HashMap::new()));

impl SolveHints {
    /// Stamp the scale cards onto a FITS header, using the same keywords and
    /// the same binning convention as a saved capture
    /// (`api::imaging::write_fits_with_header`), so a solver cannot tell a
    /// solve frame from a light frame.
    pub(crate) fn apply_to_fits_header(&self, header: &mut skotiq_imaging::FitsHeader) {
        if let Some(focal) = self.focal_length_mm {
            header.set_float("FOCALLEN", focal);
        }
        if let Some((pitch_x, pitch_y)) = self.pixel_size_um {
            header.set_float("PIXSIZE1", pitch_x);
            header.set_float("PIXSIZE2", pitch_y);
            header.set_float("XPIXSZ", pitch_x * f64::from(self.binning.0));
            header.set_float("YPIXSZ", pitch_y * f64::from(self.binning.1));
        }
        header.set_int("XBINNING", i64::from(self.binning.0));
        header.set_int("YBINNING", i64::from(self.binning.1));
    }

    /// The plate scale these hints describe, in arcsec per pixel **of the
    /// frame as taken** — pitch scaled by binning, which is the number a
    /// solver turns into a field size.
    ///
    /// This is the value the solver is handed as `-fov`. It stayed unused for
    /// three waves: the wizard computed it, logged it in
    /// [`SolveScale::log_scale`], and then called a solve that took no scale
    /// argument.
    pub(crate) fn arcsec_per_px(&self) -> Option<f64> {
        let focal = self.focal_length_mm.filter(|f| f.is_finite() && *f > 0.0)?;
        let (pitch_x, _) = self.pixel_size_um?;
        let binned_pitch = pitch_x * f64::from(self.binning.0.max(1));
        let scale = 206.264_806 * binned_pitch / focal;
        scale.is_finite().then_some(scale).filter(|s| *s > 0.0)
    }
}

/// One solve's field-scale facts, the camera they were read from, and what an
/// earlier solve on that camera measured.
///
/// [`SolveHints`] is a bridged type and stays exactly the set of cards that go
/// into the FITS header. This wraps it with the two things a header has no slot
/// for: WHICH camera the pitch came from, and the scale this rig's own optics
/// have already been measured at.
#[derive(Debug, Clone)]
pub(crate) struct SolveScale {
    /// The cards the frame's header is stamped from.
    pub(crate) hints: SolveHints,
    /// The camera [`SolveHints::pixel_size_um`] was read from, when one was
    /// resolved. Also the key a measurement is remembered under.
    pub(crate) camera_id: Option<String>,
    /// Plate scale in arcsec per UNBINNED pixel, as MEASURED by an earlier
    /// successful solve on [`Self::camera_id`] this session.
    ///
    /// The weaker of the two sources and only consulted when the profile
    /// cannot supply a focal length — but it is a real measurement of the rig
    /// in front of the operator rather than a number typed into a form, and it
    /// was the one available on the night this was written: the owner's first
    /// solve measured 0.7877"/px on a sensor reporting 3.8 um, i.e. 995 mm,
    /// while every later solve that night was still told nothing and had to
    /// sweep for the scale. One of those sweeps is what made the
    /// drift-recenter time out.
    measured_arcsec_per_px: Option<f64>,
}

impl SolveScale {
    /// The scale to hand this solve, in arcsec per pixel of the frame as
    /// taken: computed from the optics when the profile can supply them, else
    /// carried over from what this camera's last solve measured.
    pub(crate) fn arcsec_per_px(&self) -> Option<f64> {
        self.hints
            .arcsec_per_px()
            .or_else(|| self.remembered_arcsec_per_px())
    }

    /// The scale an earlier solve on this camera MEASURED, scaled to the
    /// binning this frame was taken at.
    fn remembered_arcsec_per_px(&self) -> Option<f64> {
        let unbinned = self
            .measured_arcsec_per_px
            .filter(|s| s.is_finite() && *s > 0.0)?;
        let scale = unbinned * f64::from(self.hints.binning.0.max(1));
        scale.is_finite().then_some(scale).filter(|s| *s > 0.0)
    }

    /// The focal length this rig's measured scale implies, for operator-facing
    /// copy. `None` unless both a measurement and a pitch are in hand.
    fn implied_focal_length_mm(&self) -> Option<f64> {
        let unbinned = self
            .measured_arcsec_per_px
            .filter(|s| s.is_finite() && *s > 0.0)?;
        let (pitch_x, _) = self.hints.pixel_size_um?;
        let focal = 206.264_806 * pitch_x / unbinned;
        focal.is_finite().then_some(focal).filter(|f| *f > 0.0)
    }

    /// Remember what a successful solve measured, so the next solve on this
    /// camera can be told the scale instead of sweeping for it.
    ///
    /// Recorded per camera and normalised to unbinned. A solve whose scale was
    /// already computed from the optics is recorded too: it costs nothing and
    /// keeps the memory warm for a later run whose profile has been edited.
    pub(crate) fn record_measured_scale(&self, solved_arcsec_per_px: f64) {
        let Some(camera_id) = self.camera_id.as_deref() else {
            return;
        };
        if !solved_arcsec_per_px.is_finite() || solved_arcsec_per_px <= 0.0 {
            return;
        }
        let unbinned = solved_arcsec_per_px / f64::from(self.hints.binning.0.max(1));
        if !unbinned.is_finite() || unbinned <= 0.0 {
            return;
        }
        MEASURED_PLATE_SCALE
            .write()
            .expect("measured-scale RwLock")
            .insert(camera_id.to_string(), unbinned);
    }

    /// Three outcomes, and they are genuinely different situations — a hint
    /// computed from the optics, a hint carried over from what this rig's own
    /// solve measured, and no hint at all.
    ///
    /// The warning branch names ONLY what is actually missing. It used to
    /// print "(focal length unknown, pixel pitch unknown)" whenever either was
    /// absent, so a rig whose camera was reporting 3.8 um was told both were
    /// unknown and the operator had nothing to act on.
    pub(crate) fn log_scale(&self, context: &str) {
        if let (Some(focal), Some((pitch_x, _))) =
            (self.hints.focal_length_mm, self.hints.pixel_size_um)
        {
            tracing::info!(
                "{} scale hint: focal length {:.1} mm, pixel pitch {:.2} um \
                 ({:.2}\"/px unbinned)",
                context,
                focal,
                pitch_x,
                206.264_806 * pitch_x / focal
            );
            return;
        }

        if let Some(scale) = self.remembered_arcsec_per_px() {
            tracing::info!(
                "{} scale hint {:.4}\"/px, MEASURED by an earlier solve on camera {}{}. No \
                 focal length is set on the active equipment profile; set it and the scale is \
                 computed exactly instead of carried over.",
                context,
                scale,
                self.camera_id.as_deref().unwrap_or("(unknown)"),
                self.implied_focal_length_mm()
                    .map_or_else(String::new, |focal| format!(
                        " (implying a focal length of {focal:.0} mm)"
                    )),
            );
            return;
        }

        // Naming ONLY the absent input is the whole point of this branch. The
        // old copy printed "(focal length unknown, pixel pitch unknown)"
        // whenever either was missing, so a rig whose camera was reporting
        // 3.8 um was told both were unknown and the operator had nothing to
        // act on. Each arm therefore says what is missing, where it comes
        // from, and what is already in hand.
        let missing = self.missing_scale_input();
        tracing::warn!(
            "{} has no field-scale hint: {missing}. The solver must search for the scale, \
             which is slower and can fail on a field it would otherwise solve. The first \
             successful solve on this camera is remembered and hints every solve after it.",
            context,
        );
    }

    /// Which of the two scale inputs this solve is missing, as an
    /// operator-facing clause. Only reached when at least one is absent.
    fn missing_scale_input(&self) -> String {
        match (self.hints.focal_length_mm, self.hints.pixel_size_um) {
            (None, None) => "no telescope focal length (no active equipment profile, or none \
                             set on it) and no pixel pitch (no camera resolved, or its driver \
                             reports none)"
                .to_string(),
            (None, Some((pitch_x, _))) => format!(
                "no telescope focal length on the active equipment profile — the camera's \
                 {pitch_x:.2} um pitch on its own cannot give a scale. Set the focal length \
                 there"
            ),
            (Some(focal), None) => format!(
                "no pixel pitch (no camera resolved, or its driver reports none) — the \
                 profile's {focal:.1} mm focal length on its own cannot give a scale. Connect \
                 the imaging camera, or name it on the active profile"
            ),
            // Both present is the computed branch above.
            (Some(_), Some(_)) => unreachable!("handled by the computed branch"),
        }
    }
}

/// Read the active profile's optics and the active camera's pixel pitch so a
/// solve can be told the field scale.
///
/// Shared by every production solve path — the sequencer/imaging solve in
/// `unified_device_ops::plate_solve` and the polar-alignment frames — so none
/// of them can quietly go back to solving blind. A camera that cannot be
/// queried is logged and skipped, never guessed at.
pub(crate) async fn gather_solve_hints() -> SolveScale {
    gather_solve_hints_for_camera(None).await
}

/// As [`gather_solve_hints`], but for a caller that is imaging through a
/// camera of its own rather than the profile's imaging camera.
///
/// The pitch has to come from the camera that took the frame: stamping the
/// profile camera's pitch onto a frame from a different sensor would hand the
/// solver a confidently wrong scale, which is worse than handing it none.
pub(crate) async fn gather_solve_hints_for_camera(camera_id: Option<&str>) -> SolveScale {
    let mut scale = SolveScale {
        hints: SolveHints::default(),
        camera_id: None,
        measured_arcsec_per_px: None,
    };
    let hints = &mut scale.hints;

    // The two facts are read from two independent sources and neither gates the
    // other. An absent profile used to return here, before the camera was even
    // looked at, so a rig with no saved profile reported "pixel pitch unknown"
    // about a sensor that was connected and answering every other caller in the
    // app. The pitch is the camera's to report, not the profile's.
    let profile = crate::get_state().get_profile().await;

    hints.focal_length_mm = profile
        .as_ref()
        .map(|p| p.telescope_focal_length)
        .filter(|focal| focal.is_finite() && *focal > 0.0);

    // The camera that took the frame, in order of how well each source knows
    // it: the caller's own, then the profile's imaging camera, then the one
    // camera that is actually connected.
    //
    // That last rung is not a nicety. `profile.camera_id` is unset on a rig
    // whose devices were connected from the Equipment screen without being
    // saved into the profile, and this function used to give up there — so on
    // 2026-09-15 the owner's every solve was told "pixel pitch unknown" while
    // the camera it was imaging through was reporting 3.8 um to every other
    // caller in the app.
    //
    // Exactly one connected camera, though. Two means guessing which sensor
    // the frame came off, and the pitch of the WRONG sensor is a confidently
    // wrong scale — worse than none, as this module's own note above says.
    let resolved_camera_id = match camera_id {
        Some(id) => Some(id.to_string()),
        None => match profile.as_ref().and_then(|p| p.camera_id.clone()) {
            Some(id) => Some(id),
            None => {
                let connected: Vec<String> = crate::get_state()
                    .get_devices_by_type(DeviceType::Camera)
                    .await
                    .into_iter()
                    .filter(|d| d.connection_state == ConnectionState::Connected)
                    .map(|d| d.device_id)
                    .collect();
                match connected.as_slice() {
                    [only] => {
                        tracing::debug!(
                            "Plate solve: no imaging camera on the active profile; reading the \
                             pixel pitch from the one connected camera '{}'",
                            only
                        );
                        Some(only.clone())
                    }
                    [] => None,
                    many => {
                        tracing::debug!(
                            "Plate solve: no imaging camera on the active profile and {} \
                             cameras are connected; solving without a pixel-scale hint rather \
                             than guessing which sensor took the frame",
                            many.len()
                        );
                        None
                    }
                }
            }
        },
    };

    let Some(camera_id) = resolved_camera_id else {
        return scale;
    };

    match crate::api::devices::camera::get_camera_status(camera_id.clone()).await {
        Ok(status) => {
            // 0.0 is a driver saying "I don't know", not a pitch.
            if status.pixel_size_x > 0.0 && status.pixel_size_y > 0.0 {
                hints.pixel_size_um = Some((status.pixel_size_x, status.pixel_size_y));
            }
            if status.bin_x > 0 && status.bin_y > 0 {
                hints.binning = (status.bin_x, status.bin_y);
            }
        }
        Err(e) => tracing::debug!(
            "Plate solve: camera '{}' status unavailable ({}); solving without a \
             pixel-scale hint",
            camera_id,
            e
        ),
    }

    scale.measured_arcsec_per_px = MEASURED_PLATE_SCALE
        .read()
        .expect("measured-scale RwLock")
        .get(&camera_id)
        .copied();
    scale.camera_id = Some(camera_id);

    scale
}

/// Plate solve result
#[derive(Debug, Clone)]
pub struct PlateSolveResult {
    pub success: bool,
    pub ra: f64,           // degrees
    pub dec: f64,          // degrees
    pub pixel_scale: f64,  // arcsec/pixel
    pub rotation: f64,     // degrees, East of North
    pub field_width: f64,  // degrees
    pub field_height: f64, // degrees
    pub solve_time_secs: f64,
    pub error: Option<String>,
    pub cd1_1: f64, // raw CD matrix, deg/pixel
    pub cd1_2: f64,
    pub cd2_1: f64,
    pub cd2_2: f64,
    pub sip_a_order: u32, // SIP forward distortion, 0 when absent
    pub sip_b_order: u32,
    pub sip_a_coeffs: Vec<f64>, // row-major (i, j): index i * (order + 1) + j
    pub sip_b_coeffs: Vec<f64>,
    pub sip_ap_order: u32, // SIP inverse distortion, 0 when absent
    pub sip_bp_order: u32,
    pub sip_ap_coeffs: Vec<f64>,
    pub sip_bp_coeffs: Vec<f64>,
}

/// Check if a plate solver is available
#[flutter_rust_bridge::frb(sync)]
pub fn api_is_plate_solver_available() -> bool {
    skotiq_imaging::is_solver_available()
}

/// Get the path to the installed plate solver
#[flutter_rust_bridge::frb(sync)]
pub fn api_get_plate_solver_path() -> Option<String> {
    skotiq_imaging::get_solver_path().map(|p| p.to_string_lossy().to_string())
}

/// Apply the persisted plate-solver preference to the imaging crate's
/// process-global before each solve. This ensures that paths saved in
/// Settings → Plate Solving are honoured even if the app was restarted
/// or `set_solver_preference` was never called at startup.
///
/// Why call it here rather than only at `api_platesolve_set_config` time:
/// the imaging crate is a separate compilation unit; its global resets to
/// "no override" on every cold launch. Calling this here makes each solve
/// self-healing without requiring a separate startup hook.
fn apply_saved_preference_to_imaging() {
    // If storage is not initialised (headless / test mode), treat as no-op.
    let pref = match crate::state::get_platesolver_preference() {
        Ok(p) => p,
        Err(e) => {
            tracing::warn!(
                "Could not load plate-solver preference before solve (storage not ready?): {}",
                e
            );
            return;
        }
    };
    skotiq_imaging::set_solver_preference(
        if pref.astap_path.is_empty() {
            None
        } else {
            Some(pref.astap_path.as_str())
        },
        if pref.astrometry_path.is_empty() {
            None
        } else {
            Some(pref.astrometry_path.as_str())
        },
        if pref.catalog_path.is_empty() {
            None
        } else {
            Some(pref.catalog_path.as_str())
        },
        Some(pref.solver_choice.as_str()),
    );
}

/// The field scale to hand a solve of `path`, in arcsec/pixel.
///
/// Order of authority:
/// 1. what the caller measured for this exact frame (`explicit`),
/// 2. what the frame's own header declares — right even for an imported frame
///    shot on somebody else's rig,
/// 3. the active profile's optics and the active camera's pitch.
///
/// A rig that supplies none of the three solves exactly as it did before: no
/// `-fov`, blind scale ladder, and the warning [`SolveHints::log_scale`]
/// already emits.
pub(crate) async fn resolve_solve_scale(
    path: &std::path::Path,
    explicit: Option<f64>,
) -> Option<f64> {
    if let Some(scale) = explicit.filter(|s| s.is_finite() && *s > 0.0) {
        return Some(scale);
    }
    if let Some(scale) = skotiq_imaging::fits_scale_arcsec_per_px(path) {
        tracing::debug!(
            "Plate solve: field scale {:.2}\"/px read from the frame's own header",
            scale
        );
        return Some(scale);
    }
    let scale = gather_solve_hints().await.arcsec_per_px();
    if let Some(scale) = scale {
        tracing::debug!(
            "Plate solve: field scale {:.2}\"/px from the active profile (the frame \
             carries no FOCALLEN/XPIXSZ)",
            scale
        );
    }
    scale
}

/// Plate solve an image file (blind solve)
///
/// FFI entry point; its signature is fixed by the generated bridge. Rust
/// callers that already measured the field scale call
/// [`plate_solve_blind_scaled`] instead of re-deriving it.
pub async fn api_plate_solve_blind(
    file_path: String,
    timeout_secs: Option<u32>,
) -> Result<PlateSolveResult, SkotiqError> {
    plate_solve_blind_scaled(file_path, timeout_secs, None, None).await
}

/// Blind (position-unknown) solve that is still told the field scale.
///
/// `downsample` is the ASTAP `-z` factor; `None` leaves the configured
/// default in place. A caller whose frame is already binned in hardware
/// passes `Some(1)` so the two reductions do not compound.
pub(crate) async fn plate_solve_blind_scaled(
    file_path: String,
    timeout_secs: Option<u32>,
    hint_scale: Option<f64>,
    downsample: Option<u32>,
) -> Result<PlateSolveResult, SkotiqError> {
    coalesced_solve(&file_path, "blind", SolvePreference::Blind, || {
        // Through the same ladder as a hinted solve, with no rungs above the
        // blind one: one watchdog, one failure message, one code path.
        solve_ladder(&file_path, None, timeout_secs, hint_scale, downsample)
    })
    .await
}

async fn plate_solve_blind_inner(
    file_path: &str,
    timeout_secs: Option<u32>,
    hint_scale: Option<f64>,
    downsample: Option<u32>,
) -> Result<PlateSolveResult, SkotiqError> {
    use std::path::Path;

    tracing::info!("Blind plate solving: {}", file_path);
    let _solve_guard = acquire_solve_gate("blind").await;

    // Ensure the imaging crate sees the user's configured paths before
    // PlateSolverConfig::default() is called inside blind_solve.
    apply_saved_preference_to_imaging();

    let timeout_secs = validate_solver_timeout(timeout_secs)?;
    let path = Path::new(file_path);
    if !path.exists() {
        return Err(SkotiqError::IoError(format!(
            "File not found: {}",
            file_path
        )));
    }

    // Blind is about POSITION. The scale is still known and still sent.
    let hint_scale = resolve_solve_scale(path, hint_scale).await;

    // External solvers are blocking subprocesses. Keep them off the async
    // runtime worker and pass the UI/headless timeout through to the process
    // runner, which kills and reaps the child on expiry.
    let owned_path = path.to_path_buf();
    let result = tokio::task::spawn_blocking(move || {
        skotiq_imaging::blind_solve_with_timeout(
            &owned_path,
            timeout_secs,
            hint_scale,
            downsample,
        )
    })
    .await
    .map_err(|error| {
        SkotiqError::OperationFailed(format!("Plate-solve task failed: {error}"))
    })?;

    Ok(PlateSolveResult {
        success: result.success,
        ra: result.ra,
        dec: result.dec,
        pixel_scale: result.pixel_scale,
        rotation: result.rotation,
        field_width: result.field_width,
        field_height: result.field_height,
        solve_time_secs: result.solve_time_secs,
        error: result.error,
        cd1_1: result.cd1_1,
        cd1_2: result.cd1_2,
        cd2_1: result.cd2_1,
        cd2_2: result.cd2_2,
        sip_a_order: result.a_order,
        sip_b_order: result.b_order,
        sip_a_coeffs: result.a_coeffs,
        sip_b_coeffs: result.b_coeffs,
        sip_ap_order: result.ap_order,
        sip_bp_order: result.bp_order,
        sip_ap_coeffs: result.ap_coeffs,
        sip_bp_coeffs: result.bp_coeffs,
    })
}

/// Plate solve an image with hint coordinates
///
/// FFI entry point; its signature is fixed by the generated bridge. Rust
/// callers with a measured field scale call [`plate_solve_near_scaled`].
pub async fn api_plate_solve_near(
    file_path: String,
    hint_ra: f64,
    hint_dec: f64,
    search_radius: f64,
    timeout_secs: Option<u32>,
) -> Result<PlateSolveResult, SkotiqError> {
    plate_solve_near_scaled(
        file_path,
        hint_ra,
        hint_dec,
        search_radius,
        timeout_secs,
        None,
        None,
    )
    .await
}

/// Near solve that is told the field scale as well as the position, and that
/// escalates rather than believing the hint to the end.
///
/// A position hint is a guess about where the telescope is, and a guess can be
/// stale: the manual "Solve latest camera frame" button hinted from a target
/// resolved hours and several slews earlier, ASTAP answered "No solution
/// found!" in a second, and the operator was told solving was broken. The
/// ladder is [`solve_ladder`] — the caller's radius, then
/// [`WIDE_SEARCH_RADIUS_DEG`], then blind — and it runs INSIDE the
/// single-flight entry, so a second caller waiting on this frame receives the
/// escalated answer rather than the first rung's failure.
///
/// `downsample` is the ASTAP `-z` factor; `None` leaves the configured
/// default in place.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn plate_solve_near_scaled(
    file_path: String,
    hint_ra: f64,
    hint_dec: f64,
    search_radius: f64,
    timeout_secs: Option<u32>,
    hint_scale: Option<f64>,
    downsample: Option<u32>,
) -> Result<PlateSolveResult, SkotiqError> {
    let hint = SolvePosition {
        ra_degrees: hint_ra,
        dec_degrees: hint_dec,
        search_radius_deg: search_radius,
    };
    coalesced_solve(&file_path, "near", SolvePreference::Hinted, || {
        solve_ladder(&file_path, Some(hint), timeout_secs, hint_scale, downsample)
    })
    .await
}

/// The radius a hinted solve widens to before it gives up on the hint.
///
/// 30° is the whole pole region for a polar-alignment frame and far more than
/// any live pointing error, so a hint that is merely stale still lands inside
/// it. A hint that is wrong by more than this is not a hint.
pub(crate) const WIDE_SEARCH_RADIUS_DEG: f64 = 30.0;

/// Shortest rung worth starting. Below this the solver cannot finish and the
/// time is better spent reporting the failure.
const MIN_LADDER_RUNG_SECS: f64 = 3.0;

/// Share of the budget the hinted rungs may spend between them before the
/// blind rung gets the rest.
///
/// A hinted solve succeeds in seconds or not at all — the rig's failed hinted
/// attempts came back in about a second — so half is already far more than
/// they need, and reserving the other half means a stale hint never costs the
/// frame its blind solve.
const HINTED_BUDGET_FRACTION: f64 = 0.5;

/// Floor under the hinted rungs' share, so a short configured timeout still
/// gives the fast path a fair chance.
const MIN_HINTED_BUDGET_SECS: f64 = 15.0;

/// Below this there is no point starting the blind rung.
const MIN_BLIND_BUDGET_SECS: f64 = 10.0;

/// Smallest total budget a caller may configure.
const MIN_SOLVE_BUDGET_SECS: f64 = 5.0;

/// How far the async watchdog sits beyond the solver's own process timeouts.
///
/// Each rung hands the solver its own deadline, so the solver kills its child,
/// says "ASTAP timed out after N seconds" and releases the gate. This watchdog
/// is only for a solve that wedges somewhere other than the child process, so
/// it must fire strictly later — on the rig both fired at 30 s and one frame
/// was reported as two separate failures of itself.
const SOLVE_WATCHDOG_MARGIN_SECS: f64 = 5.0;

/// Where the telescope is thought to be, and how far around that to look.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct SolvePosition {
    /// Degrees, not hours.
    pub(crate) ra_degrees: f64,
    pub(crate) dec_degrees: f64,
    pub(crate) search_radius_deg: f64,
}

/// How one frame's budget is split between the hinted rungs and the blind one.
/// Seconds; `0.0` means "do not attempt".
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct SolveBudget {
    pub(crate) hinted_secs: f64,
    pub(crate) blind_secs: f64,
}

/// Split a frame's solve budget so the whole ladder fits inside it.
///
/// The operator configured a timeout for solving this frame and that is what
/// the frame is allowed to take. Running each rung for the full timeout would
/// silently triple it.
pub(crate) fn split_solve_budget(total_secs: f64, has_hint: bool) -> SolveBudget {
    let total = if total_secs.is_finite() {
        total_secs.clamp(MIN_SOLVE_BUDGET_SECS, f64::from(MAX_SOLVER_TIMEOUT_SECS))
    } else {
        f64::from(DEFAULT_SOLVER_TIMEOUT_SECS)
    };

    if !has_hint {
        return SolveBudget {
            hinted_secs: 0.0,
            blind_secs: total,
        };
    }

    let hinted = (total * HINTED_BUDGET_FRACTION)
        .max(MIN_HINTED_BUDGET_SECS)
        .min(total);
    let remaining = total - hinted;
    SolveBudget {
        hinted_secs: hinted,
        // A blind rung that cannot finish is worse than none: it spends the
        // operator's night to arrive at the same failure.
        blind_secs: if remaining >= MIN_BLIND_BUDGET_SECS {
            remaining
        } else {
            0.0
        },
    }
}

/// The radii a hinted solve tries, in order.
///
/// A caller who already asked for the wide radius (or wider) does not get the
/// same solve run twice.
pub(crate) fn ladder_radii(requested_deg: f64) -> Vec<f64> {
    if !requested_deg.is_finite() || requested_deg <= 0.0 {
        return vec![WIDE_SEARCH_RADIUS_DEG];
    }
    if requested_deg >= WIDE_SEARCH_RADIUS_DEG {
        return vec![requested_deg];
    }
    vec![requested_deg, WIDE_SEARCH_RADIUS_DEG]
}

/// Run the escalation ladder for one frame: the caller's radius, then
/// [`WIDE_SEARCH_RADIUS_DEG`], then blind.
///
/// Uncoalesced on purpose — it is called from INSIDE [`coalesced_solve`], and
/// the inner entry points it uses must not try to claim the same single-flight
/// key its own leader is already holding.
async fn solve_ladder(
    file_path: &str,
    hint: Option<SolvePosition>,
    timeout_secs: Option<u32>,
    hint_scale: Option<f64>,
    downsample: Option<u32>,
) -> Result<PlateSolveResult, SkotiqError> {
    let total = f64::from(validate_solver_timeout(timeout_secs)?);
    let budget = split_solve_budget(total, hint.is_some());
    let watchdog = Duration::from_secs_f64(total + SOLVE_WATCHDOG_MARGIN_SECS);

    let ladder = async {
        let mut tried: Vec<String> = Vec::new();
        let mut last: Option<PlateSolveResult> = None;

        if let Some(hint) = hint {
            let deadline = Instant::now() + Duration::from_secs_f64(budget.hinted_secs);
            for radius in ladder_radii(hint.search_radius_deg) {
                let remaining = deadline
                    .saturating_duration_since(Instant::now())
                    .as_secs_f64();
                if remaining < MIN_LADDER_RUNG_SECS {
                    break;
                }
                let result = plate_solve_near_inner(
                    file_path,
                    hint.ra_degrees,
                    hint.dec_degrees,
                    radius,
                    Some(rung_timeout(remaining)),
                    hint_scale,
                    downsample,
                )
                .await?;
                if result.success {
                    tracing::info!(
                        "Plate solve: solved within {:.0}° of RA {:.2}°, Dec {:.2}° in {:.1}s",
                        radius,
                        hint.ra_degrees,
                        hint.dec_degrees,
                        result.solve_time_secs
                    );
                    return Ok(result);
                }
                tracing::warn!(
                    "Plate solve: no solution within {:.0}° of RA {:.2}°, Dec {:.2}° ({}); escalating",
                    radius,
                    hint.ra_degrees,
                    hint.dec_degrees,
                    result.error.as_deref().unwrap_or("no solution found")
                );
                tried.push(format!("{radius:.0}° around the hint"));
                last = Some(result);
            }
        }

        if budget.blind_secs >= MIN_LADDER_RUNG_SECS {
            let result = plate_solve_blind_inner(
                file_path,
                Some(rung_timeout(budget.blind_secs)),
                hint_scale,
                downsample,
            )
            .await?;
            if result.success {
                tracing::info!(
                    "Plate solve: solved BLIND in {:.1}s after {} hinted attempt(s)",
                    result.solve_time_secs,
                    tried.len()
                );
                return Ok(result);
            }
            tried.push("a blind solve".to_string());
            last = Some(result);
        }

        // Everything failed. The operator gets the list, because a bare "plate
        // solve failed" against a stale hint reads as "solving is broken".
        let mut result = last.unwrap_or_else(|| empty_solve_result("No solve was attempted"));
        result.success = false;
        result.error = Some(match hint {
            Some(hint) => format!(
                "No solution found for this frame. Tried {} near RA {:.2}°, Dec {:.2}°.",
                tried.join(", then "),
                hint.ra_degrees,
                hint.dec_degrees
            ),
            None => format!(
                "No solution found for this frame. Tried {}.",
                tried.join(", then ")
            ),
        });
        Ok(result)
    };

    match tokio::time::timeout(watchdog, ladder).await {
        Ok(result) => result,
        Err(_) => Err(SkotiqError::OperationFailed(format!(
            "Plate solve did not return within {:.0} seconds",
            watchdog.as_secs_f64()
        ))),
    }
}

/// Seconds a rung hands the solver as its own process timeout: the rung's whole
/// remaining budget, so the solver — not a watchdog racing it — decides the
/// attempt is over, kills the child and says so.
fn rung_timeout(secs: f64) -> u32 {
    secs.ceil().clamp(1.0, f64::from(MAX_SOLVER_TIMEOUT_SECS)) as u32
}

/// A failed result with nothing measured in it, for the case where no solver
/// ever ran.
fn empty_solve_result(error: &str) -> PlateSolveResult {
    PlateSolveResult {
        success: false,
        ra: 0.0,
        dec: 0.0,
        pixel_scale: 0.0,
        rotation: 0.0,
        field_width: 0.0,
        field_height: 0.0,
        solve_time_secs: 0.0,
        error: Some(error.to_string()),
        cd1_1: 0.0,
        cd1_2: 0.0,
        cd2_1: 0.0,
        cd2_2: 0.0,
        sip_a_order: 0,
        sip_b_order: 0,
        sip_a_coeffs: Vec::new(),
        sip_b_coeffs: Vec::new(),
        sip_ap_order: 0,
        sip_bp_order: 0,
        sip_ap_coeffs: Vec::new(),
        sip_bp_coeffs: Vec::new(),
    }
}

#[allow(clippy::too_many_arguments)]
async fn plate_solve_near_inner(
    file_path: &str,
    hint_ra: f64,
    hint_dec: f64,
    search_radius: f64,
    timeout_secs: Option<u32>,
    hint_scale: Option<f64>,
    downsample: Option<u32>,
) -> Result<PlateSolveResult, SkotiqError> {
    use std::path::Path;

    tracing::info!(
        "Plate solving near RA:{:.2}°, Dec:{:.2}°: {}",
        hint_ra,
        hint_dec,
        file_path
    );
    let _solve_guard = acquire_solve_gate("near").await;

    // Ensure the imaging crate sees the user's configured paths before
    // PlateSolverConfig::default() is called inside solve_near.
    apply_saved_preference_to_imaging();

    let timeout_secs = validate_solver_timeout(timeout_secs)?;
    let path = Path::new(file_path);
    if !path.exists() {
        return Err(SkotiqError::IoError(format!(
            "File not found: {}",
            file_path
        )));
    }

    // A position hint says WHERE, not HOW WIDE: without this a near solve
    // still climbs down ASTAP's blind field-of-view ladder.
    let hint_scale = resolve_solve_scale(path, hint_scale).await;

    let owned_path = path.to_path_buf();
    let result = tokio::task::spawn_blocking(move || {
        skotiq_imaging::solve_near_with_timeout(
            &owned_path,
            hint_ra,
            hint_dec,
            search_radius,
            timeout_secs,
            hint_scale,
            downsample,
        )
    })
    .await
    .map_err(|error| {
        SkotiqError::OperationFailed(format!("Plate-solve task failed: {error}"))
    })?;

    Ok(PlateSolveResult {
        success: result.success,
        ra: result.ra,
        dec: result.dec,
        pixel_scale: result.pixel_scale,
        rotation: result.rotation,
        field_width: result.field_width,
        field_height: result.field_height,
        solve_time_secs: result.solve_time_secs,
        error: result.error,
        cd1_1: result.cd1_1,
        cd1_2: result.cd1_2,
        cd2_1: result.cd2_1,
        cd2_2: result.cd2_2,
        sip_a_order: result.a_order,
        sip_b_order: result.b_order,
        sip_a_coeffs: result.a_coeffs,
        sip_b_coeffs: result.b_coeffs,
        sip_ap_order: result.ap_order,
        sip_bp_order: result.bp_order,
        sip_ap_coeffs: result.ap_coeffs,
        sip_bp_coeffs: result.bp_coeffs,
    })
}

// Plate solver UX (detection / verification / config)

/// Detection snapshot returned to the settings UI. Contains everything
/// needed to render the "ASTAP detected at /path/to/astap.exe (catalog: V17
/// to mag 17)" status banner without further FFI round-trips.
#[derive(Debug, Clone)]
pub struct PlateSolverDetection {
    /// Detected ASTAP executable path. `None` when ASTAP is not installed.
    pub astap_path: Option<String>,
    /// Detected `solve-field` path. `None` when astrometry.net is not
    /// installed.
    pub astrometry_path: Option<String>,
    /// Detected ASTAP star catalog. `None` when ASTAP was detected but no
    /// catalog could be located (the user must point us at one).
    pub catalog_name: Option<String>,
    /// Approximate magnitude limit the detected catalog covers (e.g. 17.0
    /// for V17). `None` when the catalog flavour isn't recognised.
    pub catalog_magnitude_limit: Option<f32>,
    /// Directory containing the detected catalog.
    pub catalog_path: Option<String>,
}

/// Detailed information about a verified solver binary. See
/// `api_platesolve_verify`.
#[derive(Debug, Clone)]
pub struct PlateSolverInfo {
    /// Absolute path of the verified binary.
    pub path: String,
    /// `"ASTAP"`, `"Astrometry.net"`, or `"Unknown"`.
    pub flavour: String,
    /// First non-empty line of the binary's `--help` output, useful for
    /// surfacing the build version in the settings UI.
    pub version_line: String,
}

/// Persisted plate-solver UX configuration. Mirrors `storage::PlateSolverPreference`
/// 1:1; lives in this module so flutter_rust_bridge can generate Dart
/// bindings without exporting the storage internals.
#[derive(Debug, Clone)]
pub struct PlateSolverConfigPayload {
    pub astap_path: String,
    pub astrometry_path: String,
    pub catalog_path: String,
    pub solver_choice: String,
}

impl PlateSolverConfigPayload {
    fn into_pref(self) -> crate::storage::PlateSolverPreference {
        crate::storage::PlateSolverPreference {
            astap_path: self.astap_path,
            astrometry_path: self.astrometry_path,
            catalog_path: self.catalog_path,
            solver_choice: self.solver_choice,
        }
    }
}

impl From<crate::storage::PlateSolverPreference> for PlateSolverConfigPayload {
    fn from(pref: crate::storage::PlateSolverPreference) -> Self {
        Self {
            astap_path: pref.astap_path,
            astrometry_path: pref.astrometry_path,
            catalog_path: pref.catalog_path,
            solver_choice: pref.solver_choice,
        }
    }
}

/// Detect installed plate solvers and catalogs. Honours the user-configured
/// override paths from the persisted plate-solver preference, if any. Does
/// not run the binaries — that's `api_platesolve_verify`.
#[flutter_rust_bridge::frb(sync)]
pub fn api_platesolve_detect() -> Result<PlateSolverDetection, SkotiqError> {
    use std::path::Path;

    // Why: first-run / no-saved-prefs is the dominant case — return defaults
    // so detection still scans standard install paths. A storage IO error
    // here is non-fatal because the only state read is overlay-on-defaults;
    // the user can still set explicit paths in the Plate Solving settings.
    let pref = crate::state::get_platesolver_preference()
        .unwrap_or_else(|_| crate::storage::PlateSolverPreference::default());

    let configured_astap = if pref.astap_path.is_empty() {
        None
    } else {
        Some(pref.astap_path.clone())
    };
    let configured_astrometry = if pref.astrometry_path.is_empty() {
        None
    } else {
        Some(pref.astrometry_path.clone())
    };
    let configured_catalog = if pref.catalog_path.is_empty() {
        None
    } else {
        Some(pref.catalog_path.clone())
    };

    // Probing involves filesystem reads which are fast but blocking. The
    // function is sync — callers can wrap it if they need it off the UI
    // isolate.
    skotiq_imaging::invalidate_solver_availability_cache();

    let astap_path =
        skotiq_imaging::find_astap_with_override(configured_astap.as_deref().map(Path::new));
    let astrometry_path = skotiq_imaging::find_astrometry_with_override(
        configured_astrometry.as_deref().map(Path::new),
    );

    let catalog = skotiq_imaging::detect_astap_catalog(
        astap_path.as_deref(),
        configured_catalog.as_deref().map(Path::new),
    );

    Ok(PlateSolverDetection {
        astap_path: astap_path.map(|p| p.to_string_lossy().to_string()),
        astrometry_path: astrometry_path.map(|p| p.to_string_lossy().to_string()),
        catalog_name: catalog.as_ref().and_then(|c| {
            if c.name.is_empty() {
                None
            } else {
                Some(c.name.clone())
            }
        }),
        catalog_magnitude_limit: catalog.as_ref().and_then(|c| c.magnitude_limit),
        catalog_path: catalog
            .as_ref()
            .map(|c| c.path.to_string_lossy().to_string()),
    })
}

/// Run the supplied solver binary with `--help` to confirm it's healthy.
/// Returns a `PlateSolverInfo` with the detected flavour and version banner,
/// or a `SkotiqError` if the binary is missing / fails to spawn / exits
/// with non-zero status and empty output.
pub fn api_platesolve_verify(executable_path: String) -> Result<PlateSolverInfo, SkotiqError> {
    use std::path::Path;
    let path = Path::new(&executable_path);
    match skotiq_imaging::verify_solver(path) {
        Ok(info) => Ok(PlateSolverInfo {
            path: info.path.to_string_lossy().to_string(),
            flavour: info.flavour,
            version_line: info.version_line,
        }),
        Err(e) => Err(SkotiqError::OperationFailed(e.to_string())),
    }
}

/// Read the persisted plate-solver configuration. Falls back to defaults if
/// the storage was never written.
#[flutter_rust_bridge::frb(sync)]
pub fn api_platesolve_get_config() -> Result<PlateSolverConfigPayload, SkotiqError> {
    let pref =
        crate::state::get_platesolver_preference().map_err(SkotiqError::OperationFailed)?;
    Ok(pref.into())
}

/// Persist a new plate-solver configuration. Immediately propagates the new
/// paths into the imaging crate's process-global so subsequent solves (blind
/// or near, from any call site including the sequencer) use the updated paths
/// without requiring a restart. Also invalidates the solver availability
/// cache so the next `api_is_plate_solver_available()` call re-probes the
/// filesystem with the new paths.
#[flutter_rust_bridge::frb(sync)]
pub fn api_platesolve_set_config(config: PlateSolverConfigPayload) -> Result<(), SkotiqError> {
    // Push the new paths into the imaging crate before saving, so the
    // preference is live immediately even if the subsequent storage write
    // fails (the user just configured the paths; honour them in this session).
    skotiq_imaging::set_solver_preference(
        if config.astap_path.is_empty() {
            None
        } else {
            Some(config.astap_path.as_str())
        },
        if config.astrometry_path.is_empty() {
            None
        } else {
            Some(config.astrometry_path.as_str())
        },
        if config.catalog_path.is_empty() {
            None
        } else {
            Some(config.catalog_path.as_str())
        },
        Some(config.solver_choice.as_str()),
    );

    let pref = config.into_pref();
    crate::state::save_platesolver_preference(&pref).map_err(SkotiqError::OperationFailed)?;
    skotiq_imaging::invalidate_solver_availability_cache();
    Ok(())
}

/// One frame, one solve.
#[cfg(test)]
mod solve_coalescing_tests {
    use super::{coalesced_solve, PlateSolveResult, SolvePreference};
    use crate::error::SkotiqError;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    fn result_at(ra: f64) -> PlateSolveResult {
        PlateSolveResult {
            success: true,
            ra,
            dec: 0.0,
            pixel_scale: 1.29,
            rotation: 0.0,
            field_width: 0.0,
            field_height: 0.0,
            solve_time_secs: 0.0,
            error: None,
            cd1_1: 0.0,
            cd1_2: 0.0,
            cd2_1: 0.0,
            cd2_2: 0.0,
            sip_a_order: 0,
            sip_b_order: 0,
            sip_a_coeffs: Vec::new(),
            sip_b_coeffs: Vec::new(),
            sip_ap_order: 0,
            sip_bp_order: 0,
            sip_ap_coeffs: Vec::new(),
            sip_bp_coeffs: Vec::new(),
        }
    }

    /// The live shape: two callers hit the same snapshot 4 ms apart and two
    /// `astap_cli` processes ran at once, the second one blind. The second
    /// caller now waits for the first caller's answer.
    #[tokio::test]
    async fn two_callers_on_one_frame_run_one_solver() {
        let runs = Arc::new(AtomicUsize::new(0));
        let path = "/tmp/skotiq-coalesce-one-frame.fits";

        let solve = |runs: Arc<AtomicUsize>| async move {
            runs.fetch_add(1, Ordering::SeqCst);
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
            Ok::<_, SkotiqError>(result_at(42.0))
        };

        let (first, second) = tokio::join!(
            coalesced_solve(path, "near", SolvePreference::Hinted, || solve(
                runs.clone()
            )),
            async {
                // The follower arrives while the leader is still solving.
                tokio::time::sleep(std::time::Duration::from_millis(5)).await;
                coalesced_solve(path, "blind", SolvePreference::Blind, || {
                    solve(runs.clone())
                })
                .await
            }
        );

        assert_eq!(runs.load(Ordering::SeqCst), 1, "a second solver ran");
        assert_eq!(first.unwrap().ra, 42.0);
        assert_eq!(
            second.unwrap().ra,
            42.0,
            "the follower must get the leader's answer, not a blind re-solve"
        );
    }

    /// Coalescing alone leaves the lead to a race, and the caller that leads is
    /// the one whose hints the solver gets. A blind lead throws away a good
    /// position hint and runs the slow, mis-lockable blind path instead.
    #[tokio::test]
    async fn a_hinted_caller_leads_even_when_the_blind_one_arrives_first() {
        let runs = Arc::new(AtomicUsize::new(0));
        let path = "/tmp/skotiq-coalesce-hint-wins.fits";

        // Each closure reports WHICH caller ran the solver, via the RA.
        let solve = |runs: Arc<AtomicUsize>, ra: f64| async move {
            runs.fetch_add(1, Ordering::SeqCst);
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
            Ok::<_, SkotiqError>(result_at(ra))
        };

        let (blind, hinted) = tokio::join!(
            coalesced_solve(path, "blind", SolvePreference::Blind, || solve(
                runs.clone(),
                1.0
            )),
            async {
                // The live pair arrived 4-11 ms apart.
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
                coalesced_solve(path, "near", SolvePreference::Hinted, || {
                    solve(runs.clone(), 2.0)
                })
                .await
            }
        );

        assert_eq!(runs.load(Ordering::SeqCst), 1, "two solvers ran");
        assert_eq!(
            hinted.unwrap().ra,
            2.0,
            "the hinted caller must be the one that runs the solver"
        );
        assert_eq!(
            blind.unwrap().ra,
            2.0,
            "the blind caller takes the hinted answer"
        );
    }

    /// The blind caller must not wait forever for a hinted caller that never
    /// comes — the common case is a blind solve that is genuinely alone.
    #[tokio::test]
    async fn a_lone_blind_caller_still_solves() {
        let runs = Arc::new(AtomicUsize::new(0));
        let path = "/tmp/skotiq-coalesce-lone-blind.fits";
        let solve = |runs: Arc<AtomicUsize>| async move {
            runs.fetch_add(1, Ordering::SeqCst);
            Ok::<_, SkotiqError>(result_at(9.0))
        };

        let started = std::time::Instant::now();
        let result = coalesced_solve(path, "blind", SolvePreference::Blind, || {
            solve(runs.clone())
        })
        .await;

        assert_eq!(runs.load(Ordering::SeqCst), 1);
        assert_eq!(result.unwrap().ra, 9.0);
        assert!(
            started.elapsed() < std::time::Duration::from_millis(1000),
            "the yield window must be a short offer, not a stall"
        );
    }

    /// Coalescing is per frame, not a global one-solve-per-process rule.
    #[tokio::test]
    async fn two_frames_still_get_two_solves() {
        let runs = Arc::new(AtomicUsize::new(0));
        let solve = |runs: Arc<AtomicUsize>| async move {
            runs.fetch_add(1, Ordering::SeqCst);
            Ok::<_, SkotiqError>(result_at(1.0))
        };

        let _ = coalesced_solve(
            "/tmp/skotiq-coalesce-a.fits",
            "near",
            SolvePreference::Hinted,
            || solve(runs.clone()),
        )
        .await;
        let _ = coalesced_solve(
            "/tmp/skotiq-coalesce-b.fits",
            "near",
            SolvePreference::Hinted,
            || solve(runs.clone()),
        )
        .await;

        assert_eq!(runs.load(Ordering::SeqCst), 2);
    }

    /// A finished solve must release its frame, or the first solve of a file
    /// would be the only solve of that file for the life of the process —
    /// re-solving after a re-point would silently return the old answer.
    #[tokio::test]
    async fn a_finished_solve_releases_its_frame() {
        let runs = Arc::new(AtomicUsize::new(0));
        let path = "/tmp/skotiq-coalesce-sequential.fits";
        let solve = |runs: Arc<AtomicUsize>| async move {
            runs.fetch_add(1, Ordering::SeqCst);
            Ok::<_, SkotiqError>(result_at(7.0))
        };

        let _ = coalesced_solve(path, "near", SolvePreference::Hinted, || {
            solve(runs.clone())
        })
        .await;
        let _ = coalesced_solve(path, "near", SolvePreference::Hinted, || {
            solve(runs.clone())
        })
        .await;

        assert_eq!(runs.load(Ordering::SeqCst), 2);
    }
}

#[cfg(test)]
mod solve_hint_tests {
    use super::{SolveHints, SolveScale};
    use skotiq_imaging::FitsHeader;

    /// `XPIXSZ` is the *binned* pitch — that is the number a solver turns into
    /// a plate scale. Stamping the unbinned pitch on a 2x2 frame would tell it
    /// the field is twice as wide as it is.
    #[test]
    fn xpixsz_is_the_pitch_the_frame_was_actually_taken_at() {
        let hints = SolveHints {
            focal_length_mm: Some(416.0),
            pixel_size_um: Some((3.76, 3.76)),
            binning: (2, 2),
        };
        let mut header = FitsHeader::new();
        hints.apply_to_fits_header(&mut header);

        assert_eq!(header.get_float("FOCALLEN"), Some(416.0));
        assert_eq!(header.get_float("PIXSIZE1"), Some(3.76));
        assert_eq!(header.get_float("XPIXSZ"), Some(7.52));
        assert_eq!(header.get_float("YPIXSZ"), Some(7.52));
        assert_eq!(header.get_int("XBINNING"), Some(2));
    }

    /// The scale handed to the solver is the scale of the frame as taken.
    /// 600 mm at 3.76 um is 1.29"/px unbinned and 2.59"/px at 2x2 — one of
    /// those two numbers describes the pixels ASTAP is about to measure.
    #[test]
    fn the_solver_scale_is_the_binned_sampling() {
        let unbinned = SolveHints {
            focal_length_mm: Some(600.0),
            pixel_size_um: Some((3.76, 3.76)),
            binning: (1, 1),
        };
        assert!((unbinned.arcsec_per_px().unwrap() - 1.292_59).abs() < 1e-4);

        let binned = SolveHints {
            binning: (2, 2),
            ..unbinned.clone()
        };
        assert!((binned.arcsec_per_px().unwrap() - 2.585_18).abs() < 1e-4);
    }

    /// A rig that reports no optics gets no hint — the solver searches, as it
    /// always did. A fabricated scale would be worse than none.
    #[test]
    fn missing_optics_produce_no_scale_rather_than_a_guess() {
        assert_eq!(SolveHints::default().arcsec_per_px(), None);
        assert_eq!(
            SolveHints {
                focal_length_mm: Some(600.0),
                pixel_size_um: None,
                binning: (1, 1),
            }
            .arcsec_per_px(),
            None
        );
        assert_eq!(
            SolveHints {
                focal_length_mm: Some(0.0),
                pixel_size_um: Some((3.76, 3.76)),
                binning: (1, 1),
            }
            .arcsec_per_px(),
            None
        );
    }

    /// The scale the app can DERIVE when the profile carries no focal length:
    /// what this rig's own last solve measured.
    ///
    /// The owner's numbers from 2026-09-15 — a solve that measured 0.7877"/px
    /// on an ASI1600MM reporting 3.8 um, i.e. 995 mm — because every solve
    /// after that one was still told nothing and had to sweep for the scale,
    /// and one of those sweeps is what made the drift-recenter time out.
    #[test]
    fn a_measured_scale_hints_the_next_solve_when_the_profile_has_no_focal_length() {
        let scale = SolveScale {
            hints: SolveHints {
                focal_length_mm: None,
                pixel_size_um: Some((3.8, 3.8)),
                binning: (1, 1),
            },
            camera_id: Some("native:zwo:1".to_string()),
            measured_arcsec_per_px: None,
        };
        assert_eq!(
            scale.arcsec_per_px(),
            None,
            "nothing has been measured yet, so there is nothing to carry over"
        );

        scale.record_measured_scale(0.7877);
        let next = SolveScale {
            measured_arcsec_per_px: super::MEASURED_PLATE_SCALE
                .read()
                .expect("measured-scale RwLock")
                .get("native:zwo:1")
                .copied(),
            ..scale.clone()
        };
        let hinted = next
            .arcsec_per_px()
            .expect("the next solve on this camera is hinted");
        assert!(
            (hinted - 0.7877).abs() < 1e-9,
            "the measurement carries over verbatim at the binning it was taken at, got {hinted}"
        );
        let implied = next
            .implied_focal_length_mm()
            .expect("a measured scale plus a known pitch implies a focal length");
        assert!(
            (implied - 995.0).abs() < 1.0,
            "0.7877\"/px at 3.8 um is a 995 mm scope, got {implied}"
        );
    }

    /// The warning must name what is MISSING, and only that.
    ///
    /// The first version of this branch printed "(focal length unknown, pixel
    /// pitch unknown)" whenever either input was absent, so a rig whose camera
    /// was reporting 3.8 um was told both were unknown. The replacement was
    /// then caught on a live run saying "this run knows the telescope focal
    /// length" about the one input it did not have — the same lie, inverted.
    #[test]
    fn the_warning_names_only_the_absent_input() {
        // No way to assert on `tracing` output here without a subscriber, so
        // the arms are asserted through the same match the warning uses.
        let pitch_only = SolveScale {
            hints: SolveHints {
                focal_length_mm: None,
                pixel_size_um: Some((3.8, 3.8)),
                binning: (1, 1),
            },
            camera_id: Some("pitch-only-camera".to_string()),
            measured_arcsec_per_px: None,
        };
        assert_eq!(
            pitch_only.missing_scale_input(),
            "no telescope focal length on the active equipment profile — the camera's 3.80 um \
             pitch on its own cannot give a scale. Set the focal length there"
        );

        let focal_only = SolveScale {
            hints: SolveHints {
                focal_length_mm: Some(995.0),
                pixel_size_um: None,
                binning: (1, 1),
            },
            camera_id: None,
            measured_arcsec_per_px: None,
        };
        assert!(
            focal_only
                .missing_scale_input()
                .starts_with("no pixel pitch"),
            "got: {}",
            focal_only.missing_scale_input()
        );
        assert!(
            focal_only.missing_scale_input().contains("995.0 mm"),
            "the input it DOES have is stated as held, not as missing"
        );

        let neither = SolveScale {
            hints: SolveHints::default(),
            camera_id: None,
            measured_arcsec_per_px: None,
        };
        let text = neither.missing_scale_input();
        assert!(text.starts_with("no telescope focal length"), "got: {text}");
        assert!(text.contains("and no pixel pitch"), "got: {text}");
    }

    /// Binning is not baked into the memory: a 2x2 frame is hinted at twice
    /// the sampling the 1x1 solve measured.
    #[test]
    fn a_measured_scale_rescales_to_the_binning_of_the_frame() {
        let one_by_one = SolveScale {
            hints: SolveHints {
                focal_length_mm: None,
                pixel_size_um: Some((3.8, 3.8)),
                binning: (1, 1),
            },
            camera_id: Some("bin-test-camera".to_string()),
            measured_arcsec_per_px: None,
        };
        one_by_one.record_measured_scale(0.7877);
        let remembered = super::MEASURED_PLATE_SCALE
            .read()
            .expect("measured-scale RwLock")
            .get("bin-test-camera")
            .copied();

        let two_by_two = SolveScale {
            hints: SolveHints {
                binning: (2, 2),
                ..one_by_one.hints.clone()
            },
            measured_arcsec_per_px: remembered,
            ..one_by_one.clone()
        };
        let hinted = two_by_two.arcsec_per_px().expect("hinted at 2x2");
        assert!(
            (hinted - 1.5754).abs() < 1e-6,
            "a 2x2 frame samples at twice the 1x1 scale, got {hinted}"
        );
    }

    /// The operator's own focal length is authoritative: a measurement never
    /// overrides the computed scale.
    #[test]
    fn the_computed_scale_outranks_a_measured_one() {
        let scale = SolveScale {
            hints: SolveHints {
                focal_length_mm: Some(600.0),
                pixel_size_um: Some((3.76, 3.76)),
                binning: (1, 1),
            },
            camera_id: Some("computed-wins-camera".to_string()),
            measured_arcsec_per_px: Some(9.99),
        };
        let hinted = scale.arcsec_per_px().expect("computed from the optics");
        assert!(
            (hinted - 1.292_59).abs() < 1e-4,
            "600 mm at 3.76 um is 1.29\"/px; the stale 9.99 must not win, got {hinted}"
        );
    }

    /// A failed solve measures nothing, and a solve with no camera resolved has
    /// nowhere to record a measurement.
    #[test]
    fn nothing_usable_is_remembered_from_nothing_usable() {
        let no_camera = SolveScale {
            hints: SolveHints::default(),
            camera_id: None,
            measured_arcsec_per_px: None,
        };
        no_camera.record_measured_scale(1.0);
        assert!(
            !super::MEASURED_PLATE_SCALE
                .read()
                .expect("measured-scale RwLock")
                .values()
                .any(|v| (*v - 1.0).abs() < f64::EPSILON),
            "a solve with no camera resolved must not write under some other key"
        );

        let camera = SolveScale {
            camera_id: Some("rejects-garbage-camera".to_string()),
            ..no_camera
        };
        for garbage in [0.0, -1.0, f64::NAN, f64::INFINITY] {
            camera.record_measured_scale(garbage);
        }
        assert_eq!(
            super::MEASURED_PLATE_SCALE
                .read()
                .expect("measured-scale RwLock")
                .get("rejects-garbage-camera"),
            None,
            "a non-finite or non-positive scale is not a measurement"
        );
    }

    /// The default must be *unbinned*, not zeroed: a derived `Default` would
    /// give binning (0, 0) and multiply every pitch to 0.0 um, which is a
    /// confidently wrong scale rather than an absent one.
    #[test]
    fn default_hints_are_unbinned_and_stamp_no_scale_cards() {
        let hints = SolveHints::default();
        assert_eq!(hints.binning, (1, 1));

        let mut header = FitsHeader::new();
        hints.apply_to_fits_header(&mut header);
        assert_eq!(header.get_float("FOCALLEN"), None);
        assert_eq!(header.get_float("XPIXSZ"), None);
    }
}

#[cfg(test)]
mod solve_ladder_tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering as AtomicOrdering};

    /// A stale hint is the common case, not the exceptional one: the manual
    /// solve button hinted from coordinates hours old and ASTAP said "No
    /// solution found!" inside a second. Widening has to happen before the
    /// operator is told solving is broken.
    #[test]
    fn a_narrow_hint_widens_before_it_gives_up() {
        assert_eq!(ladder_radii(5.0), vec![5.0, WIDE_SEARCH_RADIUS_DEG]);
    }

    /// A caller who already asked for the wide radius does not pay for the
    /// same search twice — polar alignment asks for exactly this.
    #[test]
    fn a_hint_that_is_already_wide_is_not_searched_twice() {
        assert_eq!(ladder_radii(WIDE_SEARCH_RADIUS_DEG), vec![30.0]);
        assert_eq!(ladder_radii(45.0), vec![45.0]);
    }

    /// A radius of zero or nonsense is not a search instruction.
    #[test]
    fn a_meaningless_radius_falls_back_to_the_wide_one() {
        assert_eq!(ladder_radii(0.0), vec![WIDE_SEARCH_RADIUS_DEG]);
        assert_eq!(ladder_radii(-3.0), vec![WIDE_SEARCH_RADIUS_DEG]);
        assert_eq!(ladder_radii(f64::NAN), vec![WIDE_SEARCH_RADIUS_DEG]);
    }

    /// Every rung together must fit in the timeout the operator set. Running
    /// each for the full timeout would silently triple the frame's cost.
    #[test]
    fn the_whole_ladder_fits_inside_the_configured_timeout() {
        let budget = split_solve_budget(90.0, true);
        assert!(budget.hinted_secs > 0.0 && budget.blind_secs > 0.0);
        assert!(
            budget.hinted_secs + budget.blind_secs <= 90.0 + 1e-9,
            "{budget:?} outruns the operator's timeout"
        );
        assert!(
            budget.blind_secs >= 30.0,
            "the blind rung must still beat the 26.5s a blind solve took on the rig: {budget:?}"
        );
    }

    /// With no hint there is only the blind rung, so it gets everything.
    #[test]
    fn a_frame_with_no_hint_spends_the_whole_budget_solving_blind() {
        let budget = split_solve_budget(90.0, false);
        assert_eq!(budget.hinted_secs, 0.0);
        assert_eq!(budget.blind_secs, 90.0);
    }

    /// A short configured timeout still gives the fast path its floor, and
    /// refuses to start a blind rung that cannot finish in what is left.
    #[test]
    fn a_short_budget_keeps_the_hinted_floor_and_drops_a_hopeless_blind_rung() {
        let budget = split_solve_budget(20.0, true);
        assert_eq!(budget.hinted_secs, MIN_HINTED_BUDGET_SECS);
        assert_eq!(budget.blind_secs, 0.0);
    }

    /// A nonsense timeout from the wire cannot produce a zero-length rung.
    #[test]
    fn an_impossible_timeout_is_clamped_rather_than_obeyed() {
        let budget = split_solve_budget(0.0, true);
        assert!(budget.hinted_secs >= MIN_SOLVE_BUDGET_SECS);
        let budget = split_solve_budget(f64::NAN, false);
        assert_eq!(budget.blind_secs, f64::from(DEFAULT_SOLVER_TIMEOUT_SECS));
    }

    /// ASTAP owns each rung's deadline, so it kills its own child and says so
    /// instead of being abandoned by a watchdog that fired at the same second.
    #[test]
    fn astap_gets_the_rungs_whole_budget_and_the_watchdog_sits_behind_it() {
        let budget = split_solve_budget(90.0, false);
        assert_eq!(rung_timeout(budget.blind_secs), 90);
        assert!(
            f64::from(rung_timeout(budget.blind_secs)) >= budget.blind_secs,
            "ASTAP must not be killed before the rung gives up"
        );
        assert!(
            90.0 + SOLVE_WATCHDOG_MARGIN_SECS > f64::from(rung_timeout(budget.blind_secs)),
            "the watchdog must fire after ASTAP's own timeout, not with it"
        );
    }

    /// The escalation must live inside the single-flight entry, so a second
    /// caller waiting on the same frame gets the answer the ladder ENDED on
    /// rather than the rung it started with. Two callers, one ladder, one
    /// escalated result.
    #[tokio::test]
    async fn a_follower_receives_the_escalated_result_not_the_first_rung() {
        static RUNS: AtomicUsize = AtomicUsize::new(0);
        let path =
            std::env::temp_dir().join(format!("ns-ladder-coalesce-{}.fits", std::process::id()));
        std::fs::write(&path, b"not a real frame").expect("scratch file");
        let key = path.to_string_lossy().to_string();

        // Stands in for the ladder: slow enough that the second caller is a
        // follower, and it "escalates" from the first rung's failure to a
        // success only at the end.
        let ladder = |key: String| async move {
            coalesced_solve(&key, "test", SolvePreference::Hinted, || async {
                RUNS.fetch_add(1, AtomicOrdering::SeqCst);
                tokio::time::sleep(Duration::from_millis(50)).await;
                let mut escalated = empty_solve_result("first rung failed");
                escalated.success = true;
                escalated.error = None;
                escalated.ra = 42.0;
                Ok(escalated)
            })
            .await
        };

        let leader = tokio::spawn(ladder(key.clone()));
        tokio::time::sleep(Duration::from_millis(10)).await;
        let follower = tokio::spawn(ladder(key.clone()));

        let leader = leader.await.expect("leader").expect("leader result");
        let follower = follower.await.expect("follower").expect("follower result");

        assert_eq!(
            RUNS.load(AtomicOrdering::SeqCst),
            1,
            "the ladder must run once for one frame"
        );
        assert!(leader.success && follower.success);
        assert_eq!(
            follower.ra, 42.0,
            "the follower got a rung's answer instead of the ladder's"
        );

        let _ = std::fs::remove_file(&path);
    }

    /// A frame that no rung solved has to say what was tried. "Plate solve
    /// failed" against a stale hint is what made the operator report that
    /// solving was broken.
    #[tokio::test]
    async fn a_frame_no_rung_solves_names_every_rung_it_tried() {
        // No solver is installed in the test environment, so every rung fails
        // immediately — which is exactly the path this message is for.
        let path =
            std::env::temp_dir().join(format!("ns-ladder-message-{}.fits", std::process::id()));
        std::fs::write(&path, b"not a real frame").expect("scratch file");

        let result = solve_ladder(
            &path.to_string_lossy(),
            Some(SolvePosition {
                ra_degrees: 341.84,
                dec_degrees: 58.13,
                search_radius_deg: 5.0,
            }),
            Some(30),
            None,
            None,
        )
        .await
        .expect("a failed solve is a result, not an error");

        assert!(!result.success);
        let error = result.error.expect("a failure must explain itself");
        assert!(error.contains("5° around the hint"), "{error}");
        assert!(error.contains("30° around the hint"), "{error}");
        assert!(error.contains("a blind solve"), "{error}");
        assert!(error.contains("341.84"), "{error}");

        let _ = std::fs::remove_file(&path);
    }
}
