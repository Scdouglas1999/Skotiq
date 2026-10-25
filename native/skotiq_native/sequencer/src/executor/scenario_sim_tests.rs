//! Device / disconnect SIMULATION HARNESS — unattended-night safety + recovery.
//!
//! These tests convert the unattended-night failure modes from
//! "believed to work, needs hardware" into "proven in software". They drive the
//! real, reachable executor recovery seams — `run_recovery_attempt`,
//! `recover_guide_star`, and `device_ops::park_and_close_safe_state` — through a
//! scriptable [`ScriptedDeviceOps`] whose behaviour can be changed MID-RUN
//! (disconnect a device at a chosen point then reconnect; flip weather
//! safe/unsafe; lose then re-lock the guide star; fail park/close). Each test is
//! a named scenario that asserts BOTH the device-call sequence AND the final
//! state.
//!
//! Scenario coverage (cluster brief):
//!   1) USB/comms DISCONNECT during exposure -> recovery promotes -> reconnect
//!      -> sequence RESUMES & re-runs the failed node (W1 disconnect-resume).
//!   2) WEATHER UNSAFE (device safety OR pushed Dart verdict) -> PAUSE +
//!      mount PARKS + cover/dome CLOSE (W1 ParkAndAbort safe-state).
//!   3) Pushed verdict `Some(true)` that goes STALE -> stays paused fail-closed
//!      + emits the stale warning, never auto-resumes (staleness observability).
//!   4) DAWN / end-of-night -> the trigger fires and the park path runs.
//!   5) GUIDE STAR LOST -> recovery re-acquires (guider re-locks) or fails closed.
//!   6) GuideStarLost / disconnect recovery EXHAUSTION -> safe end-state
//!      (park + close), not an unsafe abort.
//!
//! Scenarios 2 and 3 are exercised here at BOTH the trigger-evaluation seam
//! (`Trigger::check` / `is_weather_verdict_stale_unsafe`) AND the executor
//! recovery-gate (`run_recovery_attempt(WeatherUnsafe, ...)`) plus the
//! ParkAndAbort device-sweep (`park_and_close_safe_state`). The portion of the
//! ParkAndAbort/give-up flow that lives inline in the 7000-line trigger-monitor
//! closure cannot be invoked as a unit; the device-call sequence it performs is
//! `park_and_close_safe_state`, which IS invoked directly here, so the proven
//! call sequence is identical to what the closure runs.

use super::*;
use crate::device_ops::{
    park_and_close_safe_state, DeviceOps, DeviceResult, GuidingCalibration, GuidingStatus,
    ImageData, NullDeviceOps, PlateSolveResult, SharedDeviceOps,
};
use crate::recovery::{AttemptOutcome, RecoveryCause};
use crate::{Trigger, TriggerManager, TriggerState, TriggerType};
use async_trait::async_trait;
use std::collections::HashSet;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};

/// Scriptable device-ops double. Records every safety-relevant device call into
/// a shared log and lets the test flip device state MID-RUN (the whole point of
/// a disconnect-simulation harness). Everything not explicitly scripted
/// delegates to [`NullDeviceOps`] so the surface stays small.
pub(crate) struct ScriptedDeviceOps {
    inner: Arc<NullDeviceOps>,
    /// Ordered record of safety-relevant calls (e.g. `"mount_park:mount-1"`,
    /// `"connect_device:cam-1"`). Scenario assertions match against this.
    calls: Arc<Mutex<Vec<String>>>,
    /// Device ids currently reporting "connected". A disconnect removes the id;
    /// `connect_device` (or a scripted auto-reconnect) re-adds it.
    connected: Arc<Mutex<HashSet<String>>>,
    /// When true, `connect_device` actually reconnects (re-adds to `connected`).
    /// When false it records the attempt but leaves the device disconnected —
    /// models a dead USB hub that no reconnect can revive (-> exhaustion).
    pub(crate) connect_succeeds: Arc<AtomicBool>,
    /// Hardware safety-monitor verdict returned by `safety_is_safe`.
    weather_safe: Arc<AtomicBool>,
    /// Guider lock state reported by `guider_get_status`.
    pub(crate) guiding: Arc<AtomicBool>,
    /// If > 0, the guider auto-re-locks after this many `guider_start` calls
    /// (models PHD2 re-acquiring a star). 0 = never auto-relock.
    relock_after_starts: Arc<AtomicU32>,
    guider_start_count: Arc<AtomicU32>,
    /// When true, `mount_park` fails (models a stuck mount). Used by the
    /// exhaustion / unsafe-park scenarios.
    park_fails: Arc<AtomicBool>,
    /// When true, `cover_calibrator_close_cover` and `dome_close` fail.
    close_fails: Arc<AtomicBool>,
    /// Simulated dome shutter position reported by `dome_get_shutter_status`.
    /// Starts "Open"; a successful `dome_close` flips it to "Closed" (a faithful
    /// dome). The hardened safe-state sweep VERIFIES this reaches "Closed", so a
    /// fire-and-forget mock that never updated it would (correctly) be flagged
    /// unsafe. When `close_fails` is set the shutter stays "Open" — the jam case.
    shutter_state: Arc<Mutex<String>>,
    /// Mount tracking as the driver reports it. `mount_set_tracking` writes it
    /// and a successful `mount_park` clears it, like a real mount.
    mount_tracking: Arc<AtomicBool>,
    /// Mount park latch reported by `mount_is_parked`.
    mount_parked: Arc<AtomicBool>,
    /// When true, `guider_start` fails, as a guider with no star does.
    pub(crate) guider_start_fails: Arc<AtomicBool>,
    /// When true, `guider_select_fresh_star` finds no star (a clouded or
    /// empty guide frame).
    pub(crate) no_guide_star: Arc<AtomicBool>,
    /// What `mount_is_slewing` answers.
    pub(crate) mount_slewing: Arc<AtomicBool>,
    /// Test mount changes pier side when slewed, as a successful flip does.
    pub(crate) flip_on_slew: Arc<AtomicBool>,
    flipped: Arc<AtomicBool>,
    /// Errors the next exposures fail with, one per exposure, oldest first.
    /// Empty: every exposure succeeds.
    camera_failures: Arc<Mutex<std::collections::VecDeque<String>>>,
    /// Exposures started, failed ones included.
    exposure_calls: Arc<AtomicU32>,
    /// Paths `save_fits` was handed, in order: the frames on disk.
    saved_frames: Arc<Mutex<Vec<String>>>,
    /// When true, every plate solve finds no solution (a clouded frame).
    pub(crate) plate_solve_fails: Arc<AtomicBool>,
    /// When true, `safety_is_safe` answers as a rig with no safety monitor or
    /// weather device does: an error, resolved through the fail mode.
    pub(crate) safety_absent: Arc<AtomicBool>,
    /// The mount's position (RA hours, Dec degrees).
    pub(crate) mount_position: Arc<Mutex<(f64, f64)>>,
    /// Degrees of Dec each guider status read moves the mount while guiding:
    /// a guider chasing noise dragging it.
    pub(crate) guide_drag_deg: Arc<Mutex<f64>>,
    /// The star the guider measures, for selection floors and
    /// `guider_star_quality`. `None`: it cannot measure stars.
    pub(crate) guide_star: Arc<Mutex<Option<crate::GuideStarQuality>>>,
}

impl ScriptedDeviceOps {
    pub(crate) fn new() -> Self {
        Self {
            inner: Arc::new(NullDeviceOps),
            calls: Arc::new(Mutex::new(Vec::new())),
            connected: Arc::new(Mutex::new(HashSet::new())),
            connect_succeeds: Arc::new(AtomicBool::new(true)),
            weather_safe: Arc::new(AtomicBool::new(true)),
            guiding: Arc::new(AtomicBool::new(true)),
            relock_after_starts: Arc::new(AtomicU32::new(0)),
            guider_start_count: Arc::new(AtomicU32::new(0)),
            park_fails: Arc::new(AtomicBool::new(false)),
            close_fails: Arc::new(AtomicBool::new(false)),
            shutter_state: Arc::new(Mutex::new("Open".to_string())),
            mount_tracking: Arc::new(AtomicBool::new(true)),
            mount_parked: Arc::new(AtomicBool::new(false)),
            guider_start_fails: Arc::new(AtomicBool::new(false)),
            no_guide_star: Arc::new(AtomicBool::new(false)),
            mount_slewing: Arc::new(AtomicBool::new(false)),
            flip_on_slew: Arc::new(AtomicBool::new(false)),
            flipped: Arc::new(AtomicBool::new(false)),
            camera_failures: Arc::new(Mutex::new(std::collections::VecDeque::new())),
            exposure_calls: Arc::new(AtomicU32::new(0)),
            saved_frames: Arc::new(Mutex::new(Vec::new())),
            plate_solve_fails: Arc::new(AtomicBool::new(false)),
            safety_absent: Arc::new(AtomicBool::new(false)),
            mount_position: Arc::new(Mutex::new((2.3, 42.3))),
            guide_drag_deg: Arc::new(Mutex::new(0.0)),
            guide_star: Arc::new(Mutex::new(None)),
        }
    }

    /// Fail the next exposures with these errors, one each.
    fn fail_next_exposures(&self, errors: &[&str]) {
        self.camera_failures
            .lock()
            .unwrap()
            .extend(errors.iter().map(|e| e.to_string()));
    }

    fn record(&self, call: impl Into<String>) {
        self.calls.lock().unwrap().push(call.into());
    }

    pub(crate) fn calls(&self) -> Vec<String> {
        self.calls.lock().unwrap().clone()
    }

    pub(crate) fn call_count(&self, prefix: &str) -> usize {
        self.calls
            .lock()
            .unwrap()
            .iter()
            .filter(|c| c.starts_with(prefix))
            .count()
    }

    fn index_of(&self, call: &str) -> Option<usize> {
        self.calls.lock().unwrap().iter().position(|c| c == call)
    }

    fn set_connected(&self, id: &str, connected: bool) {
        let mut set = self.connected.lock().unwrap();
        if connected {
            set.insert(id.to_string());
        } else {
            set.remove(id);
        }
    }
}

#[async_trait]
impl DeviceOps for ScriptedDeviceOps {
    // Scripted, recorded methods

    async fn device_is_connected(&self, device_id: &str) -> DeviceResult<bool> {
        self.record(format!("device_is_connected:{device_id}"));
        Ok(self.connected.lock().unwrap().contains(device_id))
    }

    async fn connect_device(&self, device_id: &str) -> DeviceResult<()> {
        self.record(format!("connect_device:{device_id}"));
        if self.connect_succeeds.load(Ordering::SeqCst) {
            self.set_connected(device_id, true);
            Ok(())
        } else {
            Err(format!("simulated reconnect failure for {device_id}"))
        }
    }

    async fn safety_is_safe(&self, _safety_id: Option<&str>) -> DeviceResult<bool> {
        if self.safety_absent.load(Ordering::SeqCst) {
            self.record("safety_is_safe->absent");
            return Err(
                "No safety monitor or weather device configured for sequencer safety checks"
                    .to_string(),
            );
        }
        let safe = self.weather_safe.load(Ordering::SeqCst);
        self.record(format!("safety_is_safe->{safe}"));
        Ok(safe)
    }

    async fn guider_get_status(&self) -> DeviceResult<GuidingStatus> {
        let guiding = self.guiding.load(Ordering::SeqCst);
        self.record(format!("guider_get_status->{guiding}"));
        if self.guider_start_count.load(Ordering::SeqCst) > 0 {
            let drag = *self.guide_drag_deg.lock().unwrap();
            self.mount_position.lock().unwrap().1 += drag;
        }
        Ok(GuidingStatus {
            is_guiding: guiding,
            rms_ra: 0.5,
            rms_dec: 0.4,
            rms_total: 0.64,
        })
    }

    async fn guider_get_calibration(&self) -> DeviceResult<GuidingCalibration> {
        self.inner.guider_get_calibration().await
    }

    async fn guider_start(&self, sp: f64, st: f64, sto: f64) -> DeviceResult<()> {
        self.record("guider_start");
        if self.guider_start_fails.load(Ordering::SeqCst) {
            return Err("simulated guider start failure: no star".to_string());
        }
        let n = self.guider_start_count.fetch_add(1, Ordering::SeqCst) + 1;
        let relock_after = self.relock_after_starts.load(Ordering::SeqCst);
        if relock_after > 0 && n >= relock_after {
            // PHD2 re-acquired a star — flip the lock so the post-start poll
            // sees `is_guiding == true`.
            self.guiding.store(true, Ordering::SeqCst);
        }
        // No real settle wait; keep the inner call for signature parity but it
        // is a no-op against NullDeviceOps under tokio::time::pause.
        let _ = (sp, st, sto);
        Ok(())
    }

    async fn guider_select_fresh_star(&self) -> DeviceResult<()> {
        self.record("guider_select_fresh_star");
        if self.no_guide_star.load(Ordering::SeqCst) {
            return Err("simulated empty guide frame: no star found".to_string());
        }
        Ok(())
    }

    async fn guider_select_fresh_star_above(
        &self,
        floor: crate::GuideStarFloor,
    ) -> DeviceResult<()> {
        self.guider_select_fresh_star().await?;
        match *self.guide_star.lock().unwrap() {
            Some(star) if !floor.accepts(&star) => Err(format!(
                "the star measures SNR {:.1}, mass {:.0}, below the floor",
                star.snr, star.star_mass
            )),
            _ => Ok(()),
        }
    }

    async fn guider_star_quality(&self) -> DeviceResult<Option<crate::GuideStarQuality>> {
        Ok(*self.guide_star.lock().unwrap())
    }

    async fn guider_stop(&self) -> DeviceResult<()> {
        self.record("guider_stop");
        self.guider_start_count.store(0, Ordering::SeqCst);
        Ok(())
    }

    async fn mount_park(&self, mount_id: &str) -> DeviceResult<()> {
        self.record(format!("mount_park:{mount_id}"));
        if self.park_fails.load(Ordering::SeqCst) {
            Err(format!("simulated park failure for {mount_id}"))
        } else {
            self.mount_parked.store(true, Ordering::SeqCst);
            self.mount_tracking.store(false, Ordering::SeqCst);
            Ok(())
        }
    }

    async fn mount_is_tracking(&self, mount_id: &str) -> DeviceResult<bool> {
        self.record(format!("mount_is_tracking:{mount_id}"));
        Ok(self.mount_tracking.load(Ordering::SeqCst))
    }

    async fn mount_set_tracking(&self, mount_id: &str, enabled: bool) -> DeviceResult<()> {
        self.record(format!("mount_set_tracking:{mount_id}:{enabled}"));
        self.mount_tracking.store(enabled, Ordering::SeqCst);
        Ok(())
    }

    async fn cover_calibrator_close_cover(&self, device_id: &str) -> DeviceResult<()> {
        self.record(format!("cover_close:{device_id}"));
        if self.close_fails.load(Ordering::SeqCst) {
            Err(format!("simulated cover-close failure for {device_id}"))
        } else {
            Ok(())
        }
    }

    async fn dome_close(&self, dome_id: &str) -> DeviceResult<()> {
        self.record(format!("dome_close:{dome_id}"));
        if self.close_fails.load(Ordering::SeqCst) {
            // A jammed shutter: the close fails AND the shutter stays Open, so
            // the safe-state sweep's verification will (correctly) flag it.
            Err(format!("simulated dome-close failure for {dome_id}"))
        } else {
            // A healthy dome: the shutter actually reaches Closed.
            *self.shutter_state.lock().unwrap() = "Closed".to_string();
            Ok(())
        }
    }

    // Delegating methods (kept minimal; only those a scenario might hit)

    async fn mount_slew_to_coordinates(&self, id: &str, ra: f64, dec: f64) -> DeviceResult<()> {
        self.record(format!("mount_slew:{id}"));
        if self.flip_on_slew.load(Ordering::SeqCst) {
            self.flipped.store(true, Ordering::SeqCst);
        }
        self.inner.mount_slew_to_coordinates(id, ra, dec).await
    }
    async fn mount_abort_slew(&self, id: &str) -> DeviceResult<()> {
        self.inner.mount_abort_slew(id).await
    }
    async fn mount_get_coordinates(&self, _id: &str) -> DeviceResult<(f64, f64)> {
        Ok(*self.mount_position.lock().unwrap())
    }
    async fn mount_sync(&self, id: &str, ra: f64, dec: f64) -> DeviceResult<()> {
        self.inner.mount_sync(id, ra, dec).await
    }
    async fn mount_unpark(&self, id: &str) -> DeviceResult<()> {
        self.inner.mount_unpark(id).await
    }
    async fn mount_is_slewing(&self, _id: &str) -> DeviceResult<bool> {
        Ok(self.mount_slewing.load(Ordering::SeqCst))
    }
    async fn mount_is_parked(&self, _id: &str) -> DeviceResult<bool> {
        Ok(self.mount_parked.load(Ordering::SeqCst))
    }
    async fn mount_can_flip(&self, id: &str) -> DeviceResult<bool> {
        self.inner.mount_can_flip(id).await
    }
    async fn mount_side_of_pier(&self, id: &str) -> DeviceResult<crate::meridian::PierSide> {
        if self.flip_on_slew.load(Ordering::SeqCst) {
            return Ok(if self.flipped.load(Ordering::SeqCst) {
                crate::meridian::PierSide::East
            } else {
                crate::meridian::PierSide::West
            });
        }
        self.inner.mount_side_of_pier(id).await
    }
    async fn camera_start_exposure(
        &self,
        id: &str,
        d: f64,
        g: Option<i32>,
        o: Option<i32>,
        bx: i32,
        by: i32,
    ) -> DeviceResult<ImageData> {
        self.exposure_calls.fetch_add(1, Ordering::SeqCst);
        if let Some(error) = self.camera_failures.lock().unwrap().pop_front() {
            return Err(error);
        }
        self.inner.camera_start_exposure(id, d, g, o, bx, by).await
    }
    async fn camera_abort_exposure(&self, id: &str) -> DeviceResult<()> {
        self.inner.camera_abort_exposure(id).await
    }
    async fn camera_set_cooler(&self, id: &str, e: bool, t: f64) -> DeviceResult<()> {
        self.inner.camera_set_cooler(id, e, t).await
    }
    async fn camera_get_temperature(&self, id: &str) -> DeviceResult<f64> {
        self.inner.camera_get_temperature(id).await
    }
    async fn camera_get_cooler_power(&self, id: &str) -> DeviceResult<f64> {
        self.inner.camera_get_cooler_power(id).await
    }
    async fn focuser_move_to(&self, id: &str, p: i32) -> DeviceResult<()> {
        self.inner.focuser_move_to(id, p).await
    }
    async fn focuser_get_position(&self, id: &str) -> DeviceResult<i32> {
        self.inner.focuser_get_position(id).await
    }
    async fn focuser_is_moving(&self, id: &str) -> DeviceResult<bool> {
        self.inner.focuser_is_moving(id).await
    }
    async fn focuser_get_temperature(&self, id: &str) -> DeviceResult<Option<f64>> {
        self.inner.focuser_get_temperature(id).await
    }
    async fn focuser_halt(&self, id: &str) -> DeviceResult<()> {
        self.inner.focuser_halt(id).await
    }
    async fn filterwheel_set_position(&self, id: &str, p: i32) -> DeviceResult<()> {
        self.inner.filterwheel_set_position(id, p).await
    }
    async fn filterwheel_get_position(&self, id: &str) -> DeviceResult<i32> {
        self.inner.filterwheel_get_position(id).await
    }
    async fn filterwheel_get_names(&self, id: &str) -> DeviceResult<Vec<String>> {
        self.inner.filterwheel_get_names(id).await
    }
    async fn filterwheel_set_filter_by_name(&self, id: &str, n: &str) -> DeviceResult<i32> {
        self.inner.filterwheel_set_filter_by_name(id, n).await
    }
    async fn rotator_move_to(&self, id: &str, a: f64) -> DeviceResult<()> {
        self.inner.rotator_move_to(id, a).await
    }
    async fn rotator_move_relative(&self, id: &str, d: f64) -> DeviceResult<()> {
        self.inner.rotator_move_relative(id, d).await
    }
    async fn rotator_get_angle(&self, id: &str) -> DeviceResult<f64> {
        self.inner.rotator_get_angle(id).await
    }
    async fn rotator_halt(&self, id: &str) -> DeviceResult<()> {
        self.inner.rotator_halt(id).await
    }
    async fn guider_dither(
        &self,
        p: f64,
        sp: f64,
        st: f64,
        sto: f64,
        ra: bool,
    ) -> DeviceResult<()> {
        self.inner.guider_dither(p, sp, st, sto, ra).await
    }
    async fn plate_solve(
        &self,
        d: &ImageData,
        ra: Option<f64>,
        dec: Option<f64>,
        s: Option<f64>,
    ) -> DeviceResult<PlateSolveResult> {
        self.record("plate_solve");
        if self.plate_solve_fails.load(Ordering::SeqCst) {
            return Err("no solution: too few stars".to_string());
        }
        self.inner.plate_solve(d, ra, dec, s).await
    }
    async fn save_fits(
        &self,
        d: &ImageData,
        f: &str,
        ctx: &crate::scheduling::FrameContext,
    ) -> DeviceResult<()> {
        self.saved_frames.lock().unwrap().push(f.to_string());
        self.inner.save_fits(d, f, ctx).await
    }
    async fn send_notification(
        &self,
        l: &str,
        t: &str,
        m: &str,
        x: Option<&[String]>,
    ) -> DeviceResult<()> {
        self.inner.send_notification(l, t, m, x).await
    }
    fn calculate_altitude(&self, r: f64, d: f64, la: f64, lo: f64) -> f64 {
        self.inner.calculate_altitude(r, d, la, lo)
    }
    fn get_observer_location(&self) -> Option<(f64, f64)> {
        self.inner.get_observer_location()
    }
    async fn polar_align_update(
        &self,
        r: &crate::polar_align::PolarAlignResult,
    ) -> DeviceResult<()> {
        self.inner.polar_align_update(r).await
    }
    async fn dome_open(&self, id: &str) -> DeviceResult<()> {
        self.inner.dome_open(id).await
    }
    async fn dome_park(&self, id: &str) -> DeviceResult<()> {
        self.inner.dome_park(id).await
    }
    async fn dome_get_shutter_status(&self, _id: &str) -> DeviceResult<String> {
        Ok(self.shutter_state.lock().unwrap().clone())
    }
    async fn calculate_image_hfr(&self, d: &ImageData) -> DeviceResult<Option<f64>> {
        self.inner.calculate_image_hfr(d).await
    }
    async fn detect_stars_in_image(&self, d: &ImageData) -> DeviceResult<Vec<(f64, f64, f64)>> {
        self.inner.detect_stars_in_image(d).await
    }
    async fn cover_calibrator_open_cover(&self, id: &str) -> DeviceResult<()> {
        self.inner.cover_calibrator_open_cover(id).await
    }
    async fn cover_calibrator_halt_cover(&self, id: &str) -> DeviceResult<()> {
        self.inner.cover_calibrator_halt_cover(id).await
    }
    async fn cover_calibrator_calibrator_on(&self, id: &str, b: i32) -> DeviceResult<()> {
        self.inner.cover_calibrator_calibrator_on(id, b).await
    }
    async fn cover_calibrator_calibrator_off(&self, id: &str) -> DeviceResult<()> {
        self.inner.cover_calibrator_calibrator_off(id).await
    }
    async fn cover_calibrator_get_cover_state(&self, id: &str) -> DeviceResult<i32> {
        self.inner.cover_calibrator_get_cover_state(id).await
    }
    async fn cover_calibrator_get_calibrator_state(&self, id: &str) -> DeviceResult<i32> {
        self.inner.cover_calibrator_get_calibrator_state(id).await
    }
    async fn cover_calibrator_get_brightness(&self, id: &str) -> DeviceResult<i32> {
        self.inner.cover_calibrator_get_brightness(id).await
    }
    async fn cover_calibrator_get_max_brightness(&self, id: &str) -> DeviceResult<i32> {
        self.inner.cover_calibrator_get_max_brightness(id).await
    }
}

/// Build a `TriggerManager` whose shared `TriggerState` we can mutate to push a
/// Dart weather verdict — used by the WeatherUnsafe recovery-gate scenarios.
async fn manager_with_state() -> (Arc<RwLock<TriggerManager>>, Arc<RwLock<TriggerState>>) {
    let manager = TriggerManager::new();
    let state = manager.state();
    (Arc::new(RwLock::new(manager)), state)
}

// SCENARIO 1 — USB/comms DISCONNECT during an exposure -> recovery promotes ->
// reconnect -> sequence RESUMES (recovery attempt returns Succeeded, which the
// executor driver turns into `Recovering -> Running`, re-running the failed
// node). This is the W1 disconnect-resume fix.

#[tokio::test]
async fn scenario1_usb_disconnect_during_exposure_reconnects_and_resumes() {
    let ops_concrete = Arc::new(ScriptedDeviceOps::new());
    let ops: SharedDeviceOps = ops_concrete.clone();
    let cam = "native:zwo:cam-1";

    // The camera dropped out mid-exposure (USB hiccup). reconnect WILL succeed.
    ops_concrete.set_connected(cam, false);
    ops_concrete.connect_succeeds.store(true, Ordering::SeqCst);

    let (manager, _state) = manager_with_state().await;

    let outcome = super::run_recovery_attempt(
        &RecoveryCause::DeviceDisconnected,
        &ops,
        Some("mount-1"),
        &[cam.to_string()],
        &manager,
    )
    .await;

    // The recovery attempt succeeds -> the executor resumes (re-runs the node).
    assert_eq!(
        outcome,
        AttemptOutcome::Succeeded,
        "a reconnectable device must recover and let the sequence RESUME"
    );

    // It must ACTIVELY reconnect (not merely poll): connect_device fires BEFORE
    // the verifying device_is_connected. Camera/focuser/FW default to
    // auto_reconnect=false, so a passive poll would never recover them.
    let calls = ops_concrete.calls();
    let connect_idx = ops_concrete
        .index_of(&format!("connect_device:{cam}"))
        .expect("recovery must actively call connect_device");
    let verify_idx = ops_concrete
        .index_of(&format!("device_is_connected:{cam}"))
        .expect("recovery must verify the reconnect");
    assert!(
        connect_idx < verify_idx,
        "connect_device must precede the is_connected verification: {calls:?}"
    );
    // The device is connected again afterwards (the rig is whole, ready to resume).
    assert!(ops_concrete.connected.lock().unwrap().contains(cam));
}

#[tokio::test]
async fn scenario1b_disconnect_with_no_device_ids_is_unrecoverable_not_retried() {
    // Edge of the same scenario: a DeviceDisconnected cause with no captured
    // device ids must FAIL rather than "succeed" and resume into a
    // half-connected rig.
    //
    // It must fail TERMINALLY, not retryably: with no ids there is nothing to
    // reconnect and nothing to poll, so every subsequent attempt returns this
    // identical answer and a `Failed` here buys nine more of them spread over
    // the shipped 90-minute budget — a run started with no camera assigned
    // otherwise sits at `recovering / Device disconnected, progress 0.0` with
    // no frames written.
    let ops_concrete = Arc::new(ScriptedDeviceOps::new());
    let ops: SharedDeviceOps = ops_concrete.clone();
    let (manager, _state) = manager_with_state().await;

    let outcome = super::run_recovery_attempt(
        &RecoveryCause::DeviceDisconnected,
        &ops,
        Some("mount-1"),
        &[],
        &manager,
    )
    .await;

    assert!(
        matches!(outcome, AttemptOutcome::Unrecoverable { .. }),
        "no device ids -> nothing to reconnect -> must end the loop now, not \
         schedule another identical attempt; got {outcome:?}"
    );
    // Specifically NOT the retryable variant.
    assert!(
        !matches!(outcome, AttemptOutcome::Failed { .. }),
        "a retryable Failed here re-enters the wait timer and burns the budget"
    );
}

// SCENARIO 2 — WEATHER UNSAFE (device safety OR pushed Dart verdict) -> the run
// PAUSES and the mount PARKS + cover/dome CLOSE (ParkAndAbort safe-state).

#[tokio::test]
async fn scenario2_weather_unsafe_trigger_fires_from_hardware_and_from_verdict() {
    // The WeatherUnsafe trigger is the gate the executor watches; it must fire on
    // EITHER source. This is the OR-of-unsafe the executor promotes to
    // ParkAndAbort.
    let mut trigger = Trigger::new(
        "weather",
        "Weather",
        TriggerType::WeatherUnsafe,
        crate::RecoveryAction::ParkAndAbort,
    );

    // (a) hardware safety monitor unsafe, no Dart verdict.
    let mut state = TriggerState::new();
    state.weather_safe = false;
    assert!(
        trigger.check(&state).await,
        "hardware-unsafe must fire WeatherUnsafe"
    );

    // (b) hardware safe, Dart verdict unsafe (rig with no safety device).
    let mut state = TriggerState::new();
    state.weather_safe = true;
    state.update_weather_verdict(Some(true));
    assert!(
        trigger.check(&state).await,
        "Dart-verdict-unsafe must fire WeatherUnsafe even when hardware reads safe"
    );

    // (c) both clear -> must NOT fire (no false safe-state at the worst time).
    let mut state = TriggerState::new();
    state.weather_safe = true;
    state.update_weather_verdict(Some(false));
    assert!(
        !trigger.check(&state).await,
        "both-clear must not fire WeatherUnsafe"
    );
}

#[tokio::test]
async fn scenario2_park_and_abort_safe_state_sweep_parks_then_closes_in_order() {
    // The device-call sequence the executor's ParkAndAbort path performs IS
    // `park_and_close_safe_state`. Prove it: park the mount, THEN close the
    // cover, THEN close the dome — strict order, all succeed.
    let ops_concrete = Arc::new(ScriptedDeviceOps::new());
    let ops: SharedDeviceOps = ops_concrete.clone();

    let outcome = park_and_close_safe_state(
        &ops,
        Some("mount-1"),
        Some("cover-1"),
        Some("dome-1"),
        1,
        0.0,
    )
    .await;

    assert!(outcome.park.as_ref().unwrap().success);
    assert!(outcome.cover_close_error.is_none());
    assert!(outcome.dome_close_error.is_none());

    let park_idx = ops_concrete.index_of("mount_park:mount-1").unwrap();
    let cover_idx = ops_concrete.index_of("cover_close:cover-1").unwrap();
    let dome_idx = ops_concrete.index_of("dome_close:dome-1").unwrap();
    assert!(
        park_idx < cover_idx && cover_idx < dome_idx,
        "order must be park -> close cover -> close dome: {:?}",
        ops_concrete.calls()
    );
}

#[tokio::test]
async fn scenario2_park_failure_still_closes_cover_and_dome() {
    // A stuck mount must NOT abort the roof close — the shutter must close even if
    // the mount can't park (otherwise rain hits the optics). park_fails=true,
    // closes still fire; outcome reports the park failure loudly.
    let ops_concrete = Arc::new(ScriptedDeviceOps::new());
    let ops: SharedDeviceOps = ops_concrete.clone();
    ops_concrete.park_fails.store(true, Ordering::SeqCst);

    let outcome = park_and_close_safe_state(
        &ops,
        Some("mount-1"),
        Some("cover-1"),
        Some("dome-1"),
        1,
        0.0,
    )
    .await;

    assert!(
        !outcome.park.as_ref().unwrap().success,
        "a failed park must be reported as a failed park"
    );
    assert!(outcome.park.as_ref().unwrap().last_error.is_some());
    // The roof still closed despite the stuck mount.
    assert!(ops_concrete.index_of("cover_close:cover-1").is_some());
    assert!(ops_concrete.index_of("dome_close:dome-1").is_some());
    assert!(outcome.cover_close_error.is_none());
    assert!(outcome.dome_close_error.is_none());
    // park retry honoured (1 retry -> 2 park calls).
    assert_eq!(ops_concrete.call_count("mount_park:"), 2);
}

#[tokio::test]
async fn scenario2_weather_recovery_gate_holds_while_dart_verdict_unsafe() {
    // The executor's WeatherUnsafe recovery re-check requires BOTH the hardware
    // poll AND the Dart verdict to be clear before resuming. With hardware safe
    // but the verdict still Some(true), the attempt must FAIL (stay paused) — it
    // must not resume into API-unsafe weather just because the hardware boolean
    // reads safe.
    let ops_concrete = Arc::new(ScriptedDeviceOps::new());
    let ops: SharedDeviceOps = ops_concrete.clone();
    ops_concrete.weather_safe.store(true, Ordering::SeqCst); // hardware says safe

    let (manager, state) = manager_with_state().await;
    state.write().await.update_weather_verdict(Some(true)); // Dart says UNSAFE

    let outcome = super::run_recovery_attempt(
        &RecoveryCause::WeatherUnsafe,
        &ops,
        Some("mount-1"),
        &[],
        &manager,
    )
    .await;

    assert!(
        matches!(outcome, AttemptOutcome::Failed { .. }),
        "verdict-unsafe must block resume even when hardware reads safe"
    );

    // Now the Dart verdict clears AND hardware reads safe -> resume permitted.
    state.write().await.update_weather_verdict(Some(false));
    let outcome2 = super::run_recovery_attempt(
        &RecoveryCause::WeatherUnsafe,
        &ops,
        Some("mount-1"),
        &[],
        &manager,
    )
    .await;
    assert_eq!(
        outcome2,
        AttemptOutcome::Succeeded,
        "both sources clear -> weather recovery may resume"
    );
}

// SCENARIO 3 — pushed verdict Some(true) that goes STALE -> stays paused
// fail-closed + emits the stale warning, never auto-resumes.

#[tokio::test]
async fn scenario3_stale_unsafe_verdict_stays_paused_and_warns_never_resumes() {
    let ops_concrete = Arc::new(ScriptedDeviceOps::new());
    let ops: SharedDeviceOps = ops_concrete.clone();
    ops_concrete.weather_safe.store(true, Ordering::SeqCst); // hardware reads safe

    let (manager, state) = manager_with_state().await;
    state.write().await.update_weather_verdict(Some(true));

    // Force the verdict push time into the past so it is STALE (a dead Dart
    // feed). Windows Instants are boot-relative and a fresh CI VM may not be
    // 600s old yet ("overflow when subtracting duration from instant"), so
    // saturate to the oldest representable instant — runner uptime is always
    // well past the 60s staleness window asserted below.
    state.write().await.weather_verdict_last_update = Some({
        let now = std::time::Instant::now();
        now.checked_sub(std::time::Duration::from_secs(600))
            .unwrap_or_else(|| {
                let mut probe = std::time::Duration::from_secs(1);
                let mut oldest = now;
                while let Some(earlier) = now.checked_sub(probe) {
                    oldest = earlier;
                    probe *= 2;
                }
                oldest
            })
    });

    // Observability: the stale-unsafe predicate must read TRUE and must NOT clear
    // the unsafe verdict.
    {
        let guard = state.read().await;
        assert!(
            guard.is_weather_verdict_stale_unsafe(60),
            "a 600s-old unsafe verdict with a 60s window must read stale"
        );
        assert_eq!(
            guard.weather_verdict_unsafe,
            Some(true),
            "staleness must NOT clear the unsafe verdict"
        );
    }

    // The stale-warning emitter fires on the rising edge (loud, fail-closed),
    // carrying the window, then rate-limits.
    let mut warned = false;
    let msg = super::weather_verdict_stale_warning(true, 60, &mut warned)
        .expect("stale-unsafe must emit a loud warning");
    assert!(warned);
    assert!(
        msg.contains("stale") && msg.contains("paused") && msg.contains("60"),
        "warning must frame the stale fail-closed hold + the window: {msg}"
    );
    assert!(
        super::weather_verdict_stale_warning(true, 60, &mut warned).is_none(),
        "a still-stale verdict must rate-limit (no per-poll spam)"
    );

    // CRITICAL: the recovery gate must still REFUSE to resume — staleness holds
    // paused fail-closed, it never auto-resumes.
    let outcome = super::run_recovery_attempt(
        &RecoveryCause::WeatherUnsafe,
        &ops,
        Some("mount-1"),
        &[],
        &manager,
    )
    .await;
    assert!(
        matches!(outcome, AttemptOutcome::Failed { .. }),
        "a stale unsafe verdict must NOT auto-resume the sequence"
    );
}

// SCENARIO 4 — DAWN / end-of-night -> the DawnApproaching trigger fires and the
// park path runs. End-of-night scheduling lives partly on the Dart side, but the
// trigger that fires the in-sequencer park IS in the sequencer and is asserted
// here, together with the park device-call it drives.

#[tokio::test]
async fn scenario4_dawn_approaching_fires_and_parks() {
    // DawnApproaching{minutes_before:30} must fire once dawn is <30 min away, and
    // must NOT fire once dawn has already passed (no daylight-long re-firing).
    let mut trigger = Trigger::new(
        "dawn",
        "Dawn",
        TriggerType::DawnApproaching {
            minutes_before: 30.0,
        },
        crate::RecoveryAction::ParkAndAbort,
    );

    let now = chrono::Utc::now().timestamp();
    let mut state = TriggerState::new();

    // Dawn 15 min out -> fire.
    state.dawn_time = Some(now + 15 * 60);
    assert!(
        trigger.check(&state).await,
        "dawn 15 min away must fire DawnApproaching(30)"
    );

    // Dawn already passed -> must NOT fire.
    let mut trigger2 = Trigger::new(
        "dawn2",
        "Dawn2",
        TriggerType::DawnApproaching {
            minutes_before: 30.0,
        },
        crate::RecoveryAction::ParkAndAbort,
    );
    let mut past = TriggerState::new();
    past.dawn_time = Some(now - 5 * 60);
    assert!(
        !trigger2.check(&past).await,
        "after dawn has passed the trigger must not fire through the day"
    );

    // The park path the dawn trigger drives: park the mount (end-of-night safe).
    let ops_concrete = Arc::new(ScriptedDeviceOps::new());
    let ops: SharedDeviceOps = ops_concrete.clone();
    let outcome = park_and_close_safe_state(
        &ops,
        Some("mount-1"),
        Some("cover-1"),
        Some("dome-1"),
        1,
        0.0,
    )
    .await;
    assert!(
        outcome.park.as_ref().is_some_and(|p| p.success),
        "end-of-night park sweep must park the mount"
    );
    assert!(outcome.cover_close_error.is_none());
    assert!(outcome.dome_close_error.is_none());
    assert!(ops_concrete.index_of("mount_park:mount-1").is_some());
}

// =============================================================================
// SCENARIO 5 — GUIDE STAR LOST -> recovery re-acquires (guider re-locks) or
// fails closed.
// =============================================================================

#[tokio::test(start_paused = true)]
async fn scenario5_guide_star_lost_reacquires_when_guider_relocks() {
    let ops_concrete = Arc::new(ScriptedDeviceOps::new());
    let ops: SharedDeviceOps = ops_concrete.clone();

    // Star is lost now; PHD2 re-locks on the first guider_start.
    ops_concrete.guiding.store(false, Ordering::SeqCst);
    ops_concrete.relock_after_starts.store(1, Ordering::SeqCst);

    let outcome = super::recover_guide_star(&ops, None, None).await;
    assert_eq!(
        outcome,
        AttemptOutcome::Succeeded,
        "a guider that re-locks after re-acquisition must recover"
    );
    // It actually issued a real re-acquisition.
    assert!(
        ops_concrete.index_of("guider_start").is_some(),
        "guide-star recovery must issue guider_start"
    );
}

#[tokio::test(start_paused = true)]
async fn scenario5b_guide_star_already_recovered_skips_reacquire() {
    // Fast-path: if the guider already re-locked on its own during the wait, we
    // must NOT force a fresh guider_start (which can trigger an unnecessary
    // re-calibration on some setups).
    let ops_concrete = Arc::new(ScriptedDeviceOps::new());
    let ops: SharedDeviceOps = ops_concrete.clone();
    ops_concrete.guiding.store(true, Ordering::SeqCst);

    let outcome = super::recover_guide_star(&ops, None, None).await;
    assert_eq!(outcome, AttemptOutcome::Succeeded);
    assert!(
        ops_concrete.index_of("guider_start").is_none(),
        "an already-locked guider must not be force-restarted"
    );
}

#[tokio::test(start_paused = true)]
async fn scenario5c_guide_star_never_relocks_fails_closed() {
    // The star never comes back: recovery must FAIL (so the loop counts the
    // attempt and eventually gives up to a safe state) — never silently succeed.
    let ops_concrete = Arc::new(ScriptedDeviceOps::new());
    let ops: SharedDeviceOps = ops_concrete.clone();
    ops_concrete.guiding.store(false, Ordering::SeqCst);
    ops_concrete.relock_after_starts.store(0, Ordering::SeqCst); // never re-lock

    let outcome = super::recover_guide_star(&ops, None, None).await;
    assert!(
        matches!(outcome, AttemptOutcome::Failed { .. }),
        "a guider that never re-locks must fail closed, not fake success"
    );
}

/// A re-acquisition picks a fresh star before it guides: PHD2's `guide` keeps
/// the lock position it had, which after a move is empty sky.
#[tokio::test(start_paused = true)]
async fn scenario5d_guide_star_reacquire_selects_a_fresh_star_first() {
    let ops_concrete = Arc::new(ScriptedDeviceOps::new());
    let ops: SharedDeviceOps = ops_concrete.clone();
    ops_concrete.guiding.store(false, Ordering::SeqCst);
    ops_concrete.relock_after_starts.store(1, Ordering::SeqCst);

    let outcome = super::recover_guide_star(&ops, None, None).await;

    assert_eq!(outcome, AttemptOutcome::Succeeded);
    let select = ops_concrete.index_of("guider_select_fresh_star");
    let start = ops_concrete.index_of("guider_start");
    assert!(
        select.is_some() && select < start,
        "the re-acquisition must select a fresh star before guider_start; calls={:?}",
        ops_concrete.calls()
    );
}

/// No star in a fresh frame fails the attempt without starting the guider on
/// the old lock position.
#[tokio::test(start_paused = true)]
async fn scenario5e_no_star_in_a_fresh_frame_fails_the_attempt() {
    let ops_concrete = Arc::new(ScriptedDeviceOps::new());
    let ops: SharedDeviceOps = ops_concrete.clone();
    ops_concrete.guiding.store(false, Ordering::SeqCst);
    ops_concrete.relock_after_starts.store(1, Ordering::SeqCst);
    ops_concrete.no_guide_star.store(true, Ordering::SeqCst);

    let outcome = super::recover_guide_star(&ops, None, None).await;

    assert!(
        matches!(&outcome, AttemptOutcome::Failed { message } if message.contains("no star")),
        "{outcome:?}"
    );
    assert!(
        ops_concrete.index_of("guider_start").is_none(),
        "guiding was started on the old star; calls={:?}",
        ops_concrete.calls()
    );
}

/// A guide-star recovery with a trigger state, as the driver runs it.
async fn trigger_manager_with_site() -> Arc<RwLock<TriggerManager>> {
    let manager = Arc::new(RwLock::new(TriggerManager::new()));
    {
        let guard = manager.read().await;
        let lock = guard.state();
        let mut state = lock.write().await;
        state.observer_latitude = Some(43.0);
        state.observer_longitude = Some(-79.0);
    }
    manager
}

async fn trigger_state_of(manager: &Arc<RwLock<TriggerManager>>) -> crate::triggers::TriggerState {
    let guard = manager.read().await;
    let lock = guard.state();
    let state = lock.read().await.clone();
    state
}

/// N3: a guide star cannot be held on a mount that is not tracking. The
/// attempt hands the recovery to tracking and never touches the guider.
#[tokio::test(start_paused = true)]
async fn scenario5f_a_stopped_mount_hands_the_recovery_to_tracking() {
    let ops_concrete = Arc::new(ScriptedDeviceOps::new());
    let ops: SharedDeviceOps = ops_concrete.clone();
    ops_concrete.guiding.store(false, Ordering::SeqCst);
    ops_concrete.mount_tracking.store(false, Ordering::SeqCst);

    let outcome = super::recover_guide_star(&ops, Some("mount-1"), None).await;

    assert!(
        matches!(
            &outcome,
            AttemptOutcome::HandOff { cause: crate::recovery::RecoveryCause::MountTrackingLost, message }
                if message.contains("not tracking")
        ),
        "{outcome:?}"
    );
    assert_eq!(
        ops_concrete.call_count("guider_"),
        0,
        "{:?}",
        ops_concrete.calls()
    );
}

/// A mount that is slewing reads as not tracking on some drivers; that is
/// the run's own move, not a stopped mount.
#[tokio::test(start_paused = true)]
async fn scenario5g_a_slewing_mount_is_not_handed_to_tracking() {
    let ops_concrete = Arc::new(ScriptedDeviceOps::new());
    let ops: SharedDeviceOps = ops_concrete.clone();
    ops_concrete.guiding.store(false, Ordering::SeqCst);
    ops_concrete.relock_after_starts.store(1, Ordering::SeqCst);
    ops_concrete.mount_tracking.store(false, Ordering::SeqCst);
    ops_concrete.mount_slewing.store(true, Ordering::SeqCst);

    let outcome = super::recover_guide_star(&ops, Some("mount-1"), None).await;

    assert!(
        !matches!(outcome, AttemptOutcome::HandOff { .. }),
        "{outcome:?}"
    );
}

/// M7: behind the trees PHD2 offered sources at a few percent of the run's
/// guide star's mass. The recovery refuses them, records the failure with
/// where the mount pointed, and does not start guiding.
#[tokio::test(start_paused = true)]
async fn scenario5h_recovery_refuses_a_star_far_fainter_than_the_runs() {
    let ops_concrete = Arc::new(ScriptedDeviceOps::new());
    let ops: SharedDeviceOps = ops_concrete.clone();
    ops_concrete.guiding.store(false, Ordering::SeqCst);
    ops_concrete.relock_after_starts.store(1, Ordering::SeqCst);
    *ops_concrete.guide_star.lock().unwrap() = Some(crate::GuideStarQuality {
        snr: 77.3,
        star_mass: 29_612.0,
    });
    let manager = trigger_manager_with_site().await;
    {
        let guard = manager.read().await;
        guard.state().write().await.guide_star_reference = Some(crate::GuideStarQuality {
            snr: 230.0,
            star_mass: 750_000.0,
        });
    }

    let first = super::recover_guide_star(&ops, Some("mount-1"), Some(&manager)).await;
    let second = super::recover_guide_star(&ops, Some("mount-1"), Some(&manager)).await;

    assert!(
        matches!(&first, AttemptOutcome::Failed { message } if message.contains("below the floor")),
        "{first:?}"
    );
    assert!(matches!(second, AttemptOutcome::Failed { .. }));
    assert!(
        ops_concrete.index_of("guider_start").is_none(),
        "{:?}",
        ops_concrete.calls()
    );
    let stall = trigger_state_of(&manager)
        .await
        .guide_recovery
        .expect("the failures are recorded");
    assert_eq!(stall.failed_attempts(), 2);
    assert!(
        stall.stalled_at_one_pointing(2, 1.0),
        "two attempts at one pointing: {stall:?}"
    );
}

/// M7: guiding that drags the mount after noise is stopped once it has
/// moved the mount past the cap, and later attempts do not restart it.
#[tokio::test(start_paused = true)]
async fn scenario5i_guiding_that_drags_the_mount_is_stopped_and_not_restarted() {
    let ops_concrete = Arc::new(ScriptedDeviceOps::new());
    let ops: SharedDeviceOps = ops_concrete.clone();
    ops_concrete.guiding.store(false, Ordering::SeqCst);
    // Locked but never settling, dragging Dec 1' per status read.
    *ops_concrete.guide_drag_deg.lock().unwrap() = 1.0 / 60.0;
    let manager = trigger_manager_with_site().await;

    let first = super::recover_guide_star(&ops, Some("mount-1"), Some(&manager)).await;
    let starts_after_first = ops_concrete.call_count("guider_start");
    let second = super::recover_guide_star(&ops, Some("mount-1"), Some(&manager)).await;

    assert!(
        matches!(&first, AttemptOutcome::Failed { message } if message.contains("moved the mount")),
        "{first:?}"
    );
    assert!(ops_concrete.index_of("guider_stop").is_some());
    assert!(
        matches!(&second, AttemptOutcome::Failed { message } if message.contains("moved the mount")),
        "{second:?}"
    );
    assert_eq!(
        ops_concrete.call_count("guider_start"),
        starts_after_first,
        "a displaced recovery must not restart guiding: {:?}",
        ops_concrete.calls()
    );
}

/// A recovery that ends with guiding settled clears its record.
#[tokio::test(start_paused = true)]
async fn scenario5j_a_settled_recovery_clears_its_record() {
    let ops_concrete = Arc::new(ScriptedDeviceOps::new());
    let ops: SharedDeviceOps = ops_concrete.clone();
    ops_concrete.guiding.store(false, Ordering::SeqCst);
    ops_concrete.no_guide_star.store(true, Ordering::SeqCst);
    let manager = trigger_manager_with_site().await;

    let failed = super::recover_guide_star(&ops, Some("mount-1"), Some(&manager)).await;
    assert!(matches!(failed, AttemptOutcome::Failed { .. }));
    assert!(trigger_state_of(&manager).await.guide_recovery.is_some());

    ops_concrete.no_guide_star.store(false, Ordering::SeqCst);
    ops_concrete.relock_after_starts.store(1, Ordering::SeqCst);
    let recovered = super::recover_guide_star(&ops, Some("mount-1"), Some(&manager)).await;
    assert_eq!(recovered, AttemptOutcome::Succeeded);
    assert!(trigger_state_of(&manager).await.guide_recovery.is_none());
}

// =============================================================================
// SCENARIO 6 — recovery EXHAUSTION (GuideStarLost / disconnect that never
// recovers) -> safe end-state (park + close), not an unsafe abort.
//
// The recovery loop drives `run_recovery_attempt` repeatedly; once exhausted the
// executor runs the give-up safe-state sweep, whose device sequence IS
// `park_and_close_safe_state`. Here we (a) prove the attempt keeps FAILING when
// the device can't reconnect, and (b) prove the give-up sweep that follows leaves
// the rig SAFE.
// =============================================================================

#[tokio::test]
async fn scenario6_disconnect_that_never_recovers_keeps_failing_then_parks_safe() {
    let ops_concrete = Arc::new(ScriptedDeviceOps::new());
    let ops: SharedDeviceOps = ops_concrete.clone();
    let cam = "native:zwo:cam-1";

    // Dead USB hub: device stays disconnected and reconnect always fails.
    ops_concrete.set_connected(cam, false);
    ops_concrete.connect_succeeds.store(false, Ordering::SeqCst);

    let (manager, _state) = manager_with_state().await;

    // Every attempt fails (this is what burns the recovery budget toward
    // exhaustion). Run a few to model the loop.
    for _ in 0..3 {
        let outcome = super::run_recovery_attempt(
            &RecoveryCause::DeviceDisconnected,
            &ops,
            Some("mount-1"),
            &[cam.to_string()],
            &manager,
        )
        .await;
        assert!(
            matches!(outcome, AttemptOutcome::Failed { .. }),
            "an unrecoverable device must keep failing recovery (never fake success)"
        );
    }

    // Exhaustion give-up: the executor parks + closes. Give-up uses 2 park
    // retries (matching the inline path) — model that here.
    let safe = park_and_close_safe_state(
        &ops,
        Some("mount-1"),
        Some("cover-1"),
        Some("dome-1"),
        2,
        0.0,
    )
    .await;
    assert!(
        safe.park.as_ref().is_some_and(|p| p.success),
        "recovery exhaustion must leave the mount parked, not aborted unsafe"
    );
    assert!(safe.cover_close_error.is_none());
    assert!(safe.dome_close_error.is_none());
    let park_idx = ops_concrete.index_of("mount_park:mount-1").unwrap();
    let cover_idx = ops_concrete.index_of("cover_close:cover-1").unwrap();
    let dome_idx = ops_concrete.index_of("dome_close:dome-1").unwrap();
    assert!(
        park_idx < cover_idx && cover_idx < dome_idx,
        "give-up safe-state order must be park -> cover -> dome: {:?}",
        ops_concrete.calls()
    );
}

#[tokio::test(start_paused = true)]
async fn scenario6b_guide_star_exhaustion_then_safe_state_parks_and_closes() {
    // GuideStarLost variant of exhaustion: the star never re-locks, so every
    // attempt fails; the subsequent give-up sweep must park + close. The
    // driver only ends the run (and only sweeps, under the park-and-close
    // opt-in) when "Stop the run for quality problems" is on; by default it
    // images on unguided (see recovery_driver's tests).
    let ops_concrete = Arc::new(ScriptedDeviceOps::new());
    let ops: SharedDeviceOps = ops_concrete.clone();
    ops_concrete.guiding.store(false, Ordering::SeqCst);
    ops_concrete.relock_after_starts.store(0, Ordering::SeqCst);

    // Attempts keep failing.
    for _ in 0..2 {
        let outcome = super::recover_guide_star(&ops, None, None).await;
        assert!(matches!(outcome, AttemptOutcome::Failed { .. }));
    }

    // Give-up safe-state: park + close everything; report SAFE.
    let safe = park_and_close_safe_state(
        &ops,
        Some("mount-1"),
        Some("cover-1"),
        Some("dome-1"),
        2,
        0.0,
    )
    .await;
    assert!(
        safe.park.as_ref().is_some_and(|p| p.success),
        "guide-star exhaustion must end with the mount parked"
    );
    assert!(safe.cover_close_error.is_none());
    assert!(safe.dome_close_error.is_none());
}

#[tokio::test]
async fn scenario6c_exhaustion_with_stuck_mount_still_closes_roof_and_reports_unsafe() {
    // Worst case: recovery exhausted AND the mount is stuck. The give-up sweep
    // must STILL close the roof (protect optics) and must report not-fully-safe so
    // the operator is alerted to the stuck mount. This is the fail-loud contract.
    let ops_concrete = Arc::new(ScriptedDeviceOps::new());
    let ops: SharedDeviceOps = ops_concrete.clone();
    ops_concrete.park_fails.store(true, Ordering::SeqCst);

    let safe = park_and_close_safe_state(
        &ops,
        Some("mount-1"),
        Some("cover-1"),
        Some("dome-1"),
        2,
        0.0,
    )
    .await;

    assert!(
        !safe.park.as_ref().unwrap().success,
        "a stuck mount during give-up must be reported (not silently 'safe')"
    );
    // Roof still closed despite the stuck mount.
    assert!(ops_concrete.index_of("cover_close:cover-1").is_some());
    assert!(ops_concrete.index_of("dome_close:dome-1").is_some());
    // The mount park was retried to exhaustion (2 retries -> 3 calls).
    assert_eq!(ops_concrete.call_count("mount_park:"), 3);
}

// =============================================================================
// SCENARIO 7 — recovery-escalation INTEGRATION: drive the FULL escalation
// branch (`apply_recovery_escalation`, the seam factored out of the inline
// recovery-driver closure) to a `PauseForOperator` escalation and assert the
// SAFETY behaviour:
//
//   #2 (the DEFAULT `HoldForOperator` policy): tracking MUST be re-enabled
//      (`mount_set_tracking:mount-1:true`) BEFORE the run flips to Paused —
//      otherwise a Resume exposes on a non-tracking mount while the UI says
//      "Running". This drives the real branch (not the helper in isolation), so
//      deleting the restore call from the branch makes the test FAIL.
//
//   #1 (`ParkAndClose`, which the operator must opt into): only then is the
//      escalation a safe abandonment — park mount + close cover + close dome,
//      end state Failed. Under the default this sweep must not run at all, and
//      scenario 7c pins that: the owner's mount was parked from this path while
//      he was standing at it.
//
// These use the same `ScriptedDeviceOps` (records `mount_set_tracking:id:enabled`,
// `mount_park:id`, `cover_close:id`, `dome_close:id`) as the rest of this harness.
// =============================================================================

/// The live shared executor state the recovery driver passes to
/// `apply_recovery_escalation`, plus an event receiver — the exact `Arc<…>`
/// clones the inline driver captures, so the extracted function mutates the
/// real state and emits on the real event bus.
struct EscalationFixture {
    runtime: Arc<super::StdRwLock<super::RuntimeConfig>>,
    state: Arc<RwLock<super::ExecutorState>>,
    progress: Arc<super::StdRwLock<super::SequenceProgress>>,
    current: Arc<super::StdRwLock<Option<crate::recovery::RecoveryContext>>>,
    is_cancelled: Arc<AtomicBool>,
    gave_up: Arc<AtomicBool>,
    tx: super::broadcast::Sender<super::ExecutorEvent>,
    rx: super::broadcast::Receiver<super::ExecutorEvent>,
}

/// Build the fixture. `policy` chooses the disposition (`HoldForOperator` =
/// PassivePause, `ParkAndClose` = SafeAbandon).
fn escalation_fixture(policy: super::UnattendedEndPolicy) -> EscalationFixture {
    let rc = super::RuntimeConfig {
        // Recovery entry stops tracking by default — that is the precondition
        // the restore exists to undo. Keep it on so `stop_tracking == true`.
        recovery: crate::recovery::RecoveryRuntimeConfig {
            stop_tracking_during_recovery: true,
            park_and_close_when_recovery_gives_up: policy.may_safe_abandon(),
            ..Default::default()
        },
        ..Default::default()
    };
    let (tx, rx) = super::broadcast::channel(64);
    EscalationFixture {
        runtime: Arc::new(super::StdRwLock::new(rc)),
        state: Arc::new(RwLock::new(super::ExecutorState::Recovering)),
        progress: Arc::new(super::StdRwLock::new(super::SequenceProgress::default())),
        current: Arc::new(super::StdRwLock::new(None)),
        is_cancelled: Arc::new(AtomicBool::new(false)),
        gave_up: Arc::new(AtomicBool::new(false)),
        tx,
        rx,
    }
}

#[tokio::test]
async fn scenario7_attended_escalation_restores_tracking_before_pausing() {
    // Drive the ATTENDED escalation branch end to end. The branch
    // MUST command `mount_set_tracking(true)` BEFORE it flips the run to Paused
    // and emits `StateChanged(Paused)`. We record the Paused state-change event
    // into the SAME ordered log the device ops write to (via a listener task), so
    // the relative order of "tracking restored" vs "paused" is directly
    // observable. Deleting the restore call from the branch removes the
    // `mount_set_tracking:mount-1:true` record entirely and fails this test.
    let ops_concrete = Arc::new(ScriptedDeviceOps::new());
    let ops: SharedDeviceOps = ops_concrete.clone();
    let timeline = ops_concrete.calls.clone();

    let EscalationFixture {
        runtime,
        state,
        progress,
        current,
        is_cancelled,
        gave_up,
        tx,
        mut rx,
    } = escalation_fixture(super::UnattendedEndPolicy::HoldForOperator);

    // Listener: append a marker to the SHARED device-call log the instant the
    // Paused StateChanged lands. Because the branch awaits the tracking restore
    // (which records `mount_set_tracking:...`) BEFORE it sends StateChanged, the
    // tracking record is guaranteed to precede this marker in the log.
    let timeline_for_listener = timeline.clone();
    let listener = tokio::spawn(async move {
        while let Ok(ev) = rx.recv().await {
            if let super::ExecutorEvent::StateChanged(super::ExecutorState::Paused) = ev {
                timeline_for_listener
                    .lock()
                    .unwrap()
                    .push("EVENT:StateChanged(Paused)".to_string());
                break;
            }
        }
    });

    let mut ctx = crate::recovery::RecoveryContext::new(
        RecoveryCause::ConsecutiveRejectsExceeded,
        30.0,
        600.0,
    );
    ctx.attempt_count = 4;

    let escalation_state = super::RecoveryEscalationState {
        device_ops: &ops,
        event_tx: &tx,
        runtime_config: &runtime,
        state: &state,
        progress: &progress,
        current_recovery: &current,
        is_cancelled: &is_cancelled,
        gave_up: &gave_up,
        mount_id: Some("mount-1"),
        cover_id: Some("cover-1"),
        dome_id: Some("dome-1"),
    };

    super::apply_recovery_escalation(
        &escalation_state,
        &ctx,
        "Consecutive-reject storm: paused for operator".to_string(),
        true, // stop_tracking — recovery had stopped it
    )
    .await;

    // Let the listener observe the already-sent Paused event and record its marker.
    let _ = listener.await;

    let calls = ops_concrete.calls();

    // (1) The restore actually happened — tracking was re-enabled on the mount.
    let tracking_idx = ops_concrete
        .index_of("mount_set_tracking:mount-1:true")
        .unwrap_or_else(|| {
            panic!("attended escalation MUST re-enable tracking before pausing; calls={calls:?}")
        });

    // (2) It happened BEFORE the run was flipped to Paused (no untracked-exposed
    // resumable Pause).
    let paused_idx = calls
        .iter()
        .position(|c| c == "EVENT:StateChanged(Paused)")
        .expect("the run must reach Paused (StateChanged event was emitted)");
    assert!(
        tracking_idx < paused_idx,
        "tracking must be restored BEFORE the run flips to Paused: {calls:?}"
    );

    // (3) An attended escalation is a PASSIVE pause — it must NOT park or close.
    assert_eq!(
        ops_concrete.call_count("mount_park:"),
        0,
        "attended escalation must NOT park the mount (operator may resume): {calls:?}"
    );
    assert_eq!(ops_concrete.call_count("cover_close:"), 0);
    assert_eq!(ops_concrete.call_count("dome_close:"), 0);

    // (4) Final state is a resumable Paused (tracking already restored), NOT
    // Failed, and the run was not cancelled/given-up.
    assert_eq!(*state.read().await, super::ExecutorState::Paused);
    assert!(!is_cancelled.load(Ordering::Relaxed));
    assert!(!gave_up.load(Ordering::Relaxed));
}

#[tokio::test]
async fn scenario7b_park_and_close_policy_safe_abandons_no_resumable_paused() {
    // Drive the escalation with the operator's explicit `ParkAndClose` policy.
    // Only then may it run the safe-state sweep (park -> close cover -> close
    // dome) and END the run as Failed with the node tree cancelled. Scenario 7c
    // pins the default, where none of this is allowed to happen.
    let ops_concrete = Arc::new(ScriptedDeviceOps::new());
    let ops: SharedDeviceOps = ops_concrete.clone();

    let EscalationFixture {
        runtime,
        state,
        progress,
        current,
        is_cancelled,
        gave_up,
        tx,
        mut rx,
    } = escalation_fixture(super::UnattendedEndPolicy::ParkAndClose);

    // Drain events so the bounded channel never lags the sender.
    let drainer = tokio::spawn(async move { while rx.recv().await.is_ok() {} });

    let mut ctx = crate::recovery::RecoveryContext::new(
        RecoveryCause::ConsecutiveRejectsExceeded,
        30.0,
        600.0,
    );
    ctx.attempt_count = 4;

    let escalation_state = super::RecoveryEscalationState {
        device_ops: &ops,
        event_tx: &tx,
        runtime_config: &runtime,
        state: &state,
        progress: &progress,
        current_recovery: &current,
        is_cancelled: &is_cancelled,
        gave_up: &gave_up,
        mount_id: Some("mount-1"),
        cover_id: Some("cover-1"),
        dome_id: Some("dome-1"),
    };

    super::apply_recovery_escalation(
        &escalation_state,
        &ctx,
        "Consecutive-reject storm: park-and-close policy".to_string(),
        true,
    )
    .await;

    drop(tx);
    let _ = drainer.await;

    let calls = ops_concrete.calls();

    // The safe-state sweep ran in order: park -> close cover -> close dome.
    let park_idx = ops_concrete
        .index_of("mount_park:mount-1")
        .unwrap_or_else(|| {
            panic!("the park-and-close policy MUST park the mount; calls={calls:?}")
        });
    let cover_idx = ops_concrete
        .index_of("cover_close:cover-1")
        .unwrap_or_else(|| {
            panic!("the park-and-close policy MUST close the cover; calls={calls:?}")
        });
    let dome_idx = ops_concrete
        .index_of("dome_close:dome-1")
        .unwrap_or_else(|| {
            panic!("the park-and-close policy MUST close the dome; calls={calls:?}")
        });
    assert!(
        park_idx < cover_idx && cover_idx < dome_idx,
        "safe-state order must be park -> cover -> dome: {calls:?}"
    );

    // It must NOT have re-enabled tracking and parked into a resumable Paused —
    // the run is being ABANDONED, not handed back.
    assert_eq!(
        *state.read().await,
        super::ExecutorState::Failed,
        "the park-and-close policy must FAIL the run, never leave a resumable Paused"
    );
    assert!(
        is_cancelled.load(Ordering::Relaxed),
        "the park-and-close policy must cancel the node tree"
    );
    assert!(
        gave_up.load(Ordering::Relaxed),
        "the park-and-close policy must record give-up"
    );
}

/// SCENARIO 7c — the owner's 2026-09-14 failure, as a regression test.
///
/// Verbatim from that night's log, 03:01:55:
///
/// ```text
/// ERROR monitoring: [RECOVERY] Escalated ConsecutiveRejectsExceeded to operator
///   Pause after 1 attempt on an UNATTENDED rig: ... - abandoning safely
///   (park + close cover + close dome)
/// monitoring: [RECOVERY] Parked mount 'native:onstep:COM4:115200' on unattended
///   reject-storm abandonment (1 attempt)
/// ```
///
/// He was sitting at the telescope. An HTTP client had been polling the API
/// every 25 s all night and the desktop UI was open on his screen, so the
/// "UNATTENDED" verdict was not a measurement — `operator_present` had no
/// writer anywhere in the product and read `false` on every run.
///
/// Under the default policy this escalation must touch NO hardware: no park, no
/// cover, no dome. It must restore tracking and leave a resumable Paused, which
/// is what the escalation's own message ("sequence paused for inspection.
/// Resume once conditions clear") had always promised.
#[tokio::test]
async fn scenario7c_default_policy_never_parks_on_a_reject_storm() {
    let ops_concrete = Arc::new(ScriptedDeviceOps::new());
    let ops: SharedDeviceOps = ops_concrete.clone();

    let EscalationFixture {
        runtime,
        state,
        progress,
        current,
        is_cancelled,
        gave_up,
        tx,
        mut rx,
    } = escalation_fixture(super::UnattendedEndPolicy::default());

    let drainer = tokio::spawn(async move { while rx.recv().await.is_ok() {} });

    // The real numbers from that run: one attempt, then the escalation.
    let mut ctx = crate::recovery::RecoveryContext::new(
        RecoveryCause::ConsecutiveRejectsExceeded,
        600.0,
        5400.0,
    );
    ctx.attempt_count = 1;

    let escalation_state = super::RecoveryEscalationState {
        device_ops: &ops,
        event_tx: &tx,
        runtime_config: &runtime,
        state: &state,
        progress: &progress,
        current_recovery: &current,
        is_cancelled: &is_cancelled,
        gave_up: &gave_up,
        mount_id: Some("mount-1"),
        cover_id: Some("cover-1"),
        dome_id: Some("dome-1"),
    };

    super::apply_recovery_escalation(
        &escalation_state,
        &ctx,
        "Consecutive image-grading rejects exceeded the limit — sequence paused for \
         inspection. Resume once conditions clear."
            .to_string(),
        true,
    )
    .await;

    drop(tx);
    let _ = drainer.await;

    let calls = ops_concrete.calls();
    assert!(
        ops_concrete.index_of("mount_park:mount-1").is_none(),
        "the default policy must NEVER park the mount on a reject storm; calls={calls:?}"
    );
    assert!(
        ops_concrete.index_of("cover_close:cover-1").is_none(),
        "the default policy must NEVER close the cover on a reject storm; calls={calls:?}"
    );
    assert!(
        ops_concrete.index_of("dome_close:dome-1").is_none(),
        "the default policy must NEVER close the dome on a reject storm; calls={calls:?}"
    );

    // Tracking restored, so the operator's Resume does not expose on a drifting
    // mount — recovery entry stopped it and the generic Resume does not.
    assert!(
        ops_concrete
            .index_of("mount_set_tracking:mount-1:true")
            .is_some(),
        "the hold must restore tracking before handing the run back; calls={calls:?}"
    );

    // Resumable, not terminal.
    assert_eq!(
        *state.read().await,
        super::ExecutorState::Paused,
        "the default policy leaves a run the operator can resume"
    );
    assert!(
        !is_cancelled.load(Ordering::Relaxed),
        "holding must not cancel the node tree"
    );
    assert!(!gave_up.load(Ordering::Relaxed), "holding is not a give-up");
}

/// End-to-end (state replay): a loaded sequence whose mount reports
/// `mount_is_tracking == Ok(false)` for the first several trigger polls — the
/// headless / still-parked / not-yet-slewed case — must NOT raise
/// `MountTrackingLost`, and must therefore never self-cancel ~1.5 s after start.
///
/// The live trigger-monitor loop is an inline closure in the 7000-line executor
/// and is not unit-invocable (see this module's header); the portion under test
/// is the exact per-poll decision it runs, `mount_tracking_poll_verdict`, driven
/// here against a real [`TriggerState`] in the same order the monitor applies it
/// (compute verdict -> arm `mount_tracking_expected` -> flag loss -> record the
/// reading). This proves both halves of the contract: the not-yet-tracking
/// startup phase is silent, and a genuine ON -> OFF drop afterward still fires.
#[test]
fn b19_not_yet_tracking_mount_never_self_cancels() {
    let mut state = TriggerState::new();

    // Apply one Ok(is_tracking) poll exactly as the monitor's poll block does,
    // returning whether THIS poll flagged a fresh loss.
    let poll = |state: &mut TriggerState, is_tracking: bool| -> bool {
        let (expected, just_lost) = super::mount_tracking_poll_verdict(
            state.tracking.is_expected(),
            is_tracking,
            state.mount_is_tracking,
            state.tracking.is_lost(),
        );
        state.set_mount_tracking_expected(expected);
        if just_lost {
            state.tracking.mark_lost();
        }
        state.mount_is_tracking = Some(is_tracking);
        just_lost
    };

    // Startup: mount configured but not yet tracking for the first few polls.
    for tick in 0..3 {
        assert!(
            !poll(&mut state, false),
            "not-yet-tracking poll {tick} must not flag a loss"
        );
        assert!(
            !state.tracking.is_expected(),
            "baseline must stay disarmed until tracking is observed (poll {tick})"
        );
        assert!(!state.tracking.is_lost());
    }

    // Mount begins tracking — baseline arms now, from an observed fact.
    assert!(!poll(&mut state, true), "first Ok(true) is not a loss");
    assert!(
        state.tracking.is_expected(),
        "baseline must arm once the mount is observed tracking"
    );
    assert!(!state.tracking.is_lost());

    // Healthy tracking continues.
    assert!(!poll(&mut state, true));
    assert!(!state.tracking.is_lost());

    // Genuine mid-sequence drop: ON -> OFF must fire exactly once.
    assert!(
        poll(&mut state, false),
        "a true -> false transition is a real tracking loss and must fire"
    );
    assert!(state.tracking.is_lost());

    // Still off on the next poll — already flagged, must not re-fire.
    assert!(
        !poll(&mut state, false),
        "loss must not be re-flagged once already recorded"
    );
}

/// Poll `executor` until `pred` holds for its state, or `timeout` passes.
async fn wait_for_state(
    executor: &super::SequenceExecutor,
    timeout: std::time::Duration,
    pred: impl Fn(super::ExecutorState) -> bool,
) -> super::ExecutorState {
    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        let state = executor.get_state().await;
        if pred(state) || tokio::time::Instant::now() >= deadline {
            return state;
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
}

/// A long single-node run against a scripted mount, started and returned so a
/// scenario can pause it, change the rig under it and watch what the executor
/// does. Nothing in it needs a camera.
async fn start_long_run_on_scripted_mount(ops: Arc<ScriptedDeviceOps>) -> super::SequenceExecutor {
    let mut executor = super::SequenceExecutor::new();
    executor.set_devices(None, Some("mount-1".to_string()), None, None, None);
    start_long_run(executor, ops).await
}

/// [`start_long_run_on_scripted_mount`] for an executor the scenario has
/// already configured.
async fn start_long_run(
    mut executor: super::SequenceExecutor,
    ops: Arc<ScriptedDeviceOps>,
) -> super::SequenceExecutor {
    use crate::{NodeDefinition, NodeType, SequenceDefinition};
    executor.set_device_ops(ops as SharedDeviceOps);
    let mut sequence = SequenceDefinition::new("Hold integrity".to_string());
    sequence.nodes.push(NodeDefinition {
        id: "hold-delay".to_string(),
        name: "Long wait".to_string(),
        node_type: NodeType::Delay(crate::DelayConfig { seconds: 600.0 }),
        enabled: true,
        children: vec![],
    });
    sequence.root_node_id = Some("hold-delay".to_string());
    executor.load_sequence(sequence).expect("sequence loads");
    executor.start().await.expect("executor starts");
    arm_run_guiding(&executor).await;
    executor
}

/// What a StartGuiding node that succeeded leaves behind: this run's guiding
/// is armed, so a guider that stops guiding is a lost star. A guider merely
/// seen guiding does not arm it.
pub(crate) async fn arm_run_guiding(executor: &super::SequenceExecutor) {
    let manager = executor.trigger_manager.read().await;
    manager.state().write().await.set_guiding_enabled(true);
}

/// A paused run must stay paused when a safety-class trigger fires under it.
///
/// Since the trigger monitor started evaluating safety-class triggers while a
/// run is paused, `mount_tracking_lost` (safety class, action Pause) can fire
/// during a hold. Its Pause action hands the run to the recovery driver, and a
/// recovery that succeeds sets the run back to Running. A hold placed by the
/// operator, or by the dead-guider or reject-storm escalations, must not be
/// lifted by the rig itself: the mount has to stay as the operator left it and
/// the run must not start exposing again.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_tracking_loss_during_a_hold_does_not_resume_the_run() {
    let ops = Arc::new(ScriptedDeviceOps::new());
    let mut executor = start_long_run_on_scripted_mount(ops.clone()).await;

    // Let the monitor observe the mount tracking so the loss baseline arms.
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(10);
    while ops.call_count("mount_is_tracking:mount-1") == 0 {
        assert!(
            tokio::time::Instant::now() < deadline,
            "monitor never polled the mount"
        );
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }

    executor.pause().await.expect("pause");
    let state = wait_for_state(&executor, std::time::Duration::from_secs(5), |s| {
        s == super::ExecutorState::Paused
    })
    .await;
    assert_eq!(state, super::ExecutorState::Paused);

    // The operator stops tracking to look at the rig.
    ops.mount_tracking.store(false, Ordering::SeqCst);
    let polls_before = ops.call_count("mount_is_tracking:mount-1");
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(12);
    while ops.call_count("mount_is_tracking:mount-1") < polls_before + 1 {
        assert!(
            tokio::time::Instant::now() < deadline,
            "monitor stopped polling the mount"
        );
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    // Give the fired trigger and anything it starts time to act.
    tokio::time::sleep(std::time::Duration::from_secs(4)).await;

    let calls = ops.calls();
    let state = executor.get_state().await;
    assert!(
        !calls.iter().any(|c| c == "mount_set_tracking:mount-1:true"),
        "the rig re-enabled tracking under an operator hold; calls={calls:?}"
    );
    assert_eq!(
        state,
        super::ExecutorState::Paused,
        "a trigger lifted an operator hold; calls={calls:?}"
    );

    // The loss is still acted on once the operator resumes with the mount
    // untracked: the run must not expose without tracking.
    executor.resume().await.expect("resume");
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(15);
    while !ops.mount_tracking.load(Ordering::SeqCst) {
        if tokio::time::Instant::now() >= deadline {
            let calls = ops.calls();
            let _ = executor.stop().await;
            panic!("a run resumed on an untracked mount never restored tracking; calls={calls:?}");
        }
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
    let _ = executor.stop().await;
}

/// A parked mount is not a mount that lost tracking. Parking stops tracking,
/// so an operator who parks during a run trips Mount Tracking Lost, and the
/// recovery attempt must not answer by switching tracking back on under the
/// park latch and declaring the run recovered.
#[tokio::test]
async fn tracking_recovery_never_commands_tracking_on_a_parked_mount() {
    let ops_concrete = Arc::new(ScriptedDeviceOps::new());
    let ops: SharedDeviceOps = ops_concrete.clone();
    ops_concrete.mount_parked.store(true, Ordering::SeqCst);
    ops_concrete.mount_tracking.store(false, Ordering::SeqCst);
    let (manager, _state) = manager_with_state().await;

    let outcome = super::run_recovery_attempt(
        &RecoveryCause::MountTrackingLost,
        &ops,
        Some("mount-1"),
        &[],
        &manager,
    )
    .await;

    let calls = ops_concrete.calls();
    assert!(
        !calls.iter().any(|c| c == "mount_set_tracking:mount-1:true"),
        "recovery switched tracking on under the park latch; outcome={outcome:?} calls={calls:?}"
    );
    assert_ne!(
        outcome,
        AttemptOutcome::Succeeded,
        "a parked mount is not a recovered one; calls={calls:?}"
    );
}

/// An operator Stop while recovery is waiting between attempts is a stop, not
/// recovery running out. It must not be reported as "Recovery could not fix",
/// and it must not run the park-and-close sweep that the operator opted into
/// for a recovery that genuinely gives up.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn stopping_during_recovery_is_a_stop_not_a_give_up() {
    let ops = Arc::new(ScriptedDeviceOps::new());
    ops.guider_start_fails.store(true, Ordering::SeqCst);
    let mut executor = super::SequenceExecutor::new();
    executor.set_devices(None, Some("mount-1".to_string()), None, None, None);
    executor.set_dome(Some("dome-1".to_string()));
    executor
        .update_recovery_config(crate::recovery::RecoveryRuntimeConfig {
            retry_interval_secs: 60.0,
            max_duration_secs: 3600.0,
            park_and_close_when_recovery_gives_up: true,
            ..crate::recovery::RecoveryRuntimeConfig::default()
        })
        .await;
    let mut events = executor.subscribe();
    let mut executor = start_long_run(executor, ops.clone()).await;

    // Let the monitor see the guider guiding, then lose the star.
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(10);
    while ops.call_count("guider_get_status") < 2 {
        assert!(
            tokio::time::Instant::now() < deadline,
            "monitor never polled the guider"
        );
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    ops.guiding.store(false, Ordering::SeqCst);
    let state = wait_for_state(&executor, std::time::Duration::from_secs(15), |s| {
        s == super::ExecutorState::Recovering
    })
    .await;
    assert_eq!(
        state,
        super::ExecutorState::Recovering,
        "calls={:?}",
        ops.calls()
    );
    // Attempt 1 fails at once; the driver is now waiting out the interval.
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(10);
    while ops.call_count("guider_start") < 1 {
        assert!(
            tokio::time::Instant::now() < deadline,
            "recovery never attempted"
        );
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;

    let _ = executor.stop().await;
    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    let mut messages = Vec::new();
    let mut gave_up = false;
    while let Ok(event) = events.try_recv() {
        match event {
            super::ExecutorEvent::Error { message } => messages.push(message),
            super::ExecutorEvent::RecoveryGaveUp { .. } => gave_up = true,
            _ => {}
        }
    }
    let calls = ops.calls();
    assert!(
        !calls
            .iter()
            .any(|c| c.starts_with("mount_park") || c.starts_with("dome_close")),
        "an operator Stop ran the give-up park-and-close sweep; messages={messages:?} \
         calls={calls:?}"
    );
    assert!(
        !messages
            .iter()
            .any(|m| m.contains("Recovery could not fix")),
        "an operator Stop was reported as recovery running out; messages={messages:?}"
    );
    assert!(
        !gave_up,
        "an operator Stop was published as RecoveryGaveUp; messages={messages:?}"
    );
}

/// A recovery ladder can run for 90 minutes, and a lost guide star is most
/// often cloud. The rig is still under the sky while the driver waits between
/// attempts, so the weather rule must still act: rain arriving during a
/// guide-star recovery has to reach Weather Unsafe's configured park, and the
/// run must not then report a recovery give-up it never had.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn weather_turning_unsafe_during_recovery_is_still_acted_on() {
    let ops = Arc::new(ScriptedDeviceOps::new());
    ops.guider_start_fails.store(true, Ordering::SeqCst);
    let mut executor = super::SequenceExecutor::new();
    executor.set_devices(None, Some("mount-1".to_string()), None, None, None);
    executor.set_safety_check_interval_secs(5);
    executor
        .update_recovery_config(crate::recovery::RecoveryRuntimeConfig {
            retry_interval_secs: 600.0,
            max_duration_secs: 5400.0,
            ..crate::recovery::RecoveryRuntimeConfig::default()
        })
        .await;
    let mut events = executor.subscribe();
    let mut executor = start_long_run(executor, ops.clone()).await;

    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(10);
    while ops.call_count("guider_get_status") < 2 {
        assert!(
            tokio::time::Instant::now() < deadline,
            "monitor never polled the guider"
        );
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    ops.guiding.store(false, Ordering::SeqCst);
    let state = wait_for_state(&executor, std::time::Duration::from_secs(15), |s| {
        s == super::ExecutorState::Recovering
    })
    .await;
    assert_eq!(
        state,
        super::ExecutorState::Recovering,
        "calls={:?}",
        ops.calls()
    );

    // Rain.
    ops.weather_safe.store(false, Ordering::SeqCst);
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(20);
    while ops.call_count("mount_park") == 0 && tokio::time::Instant::now() < deadline {
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    let calls = ops.calls();
    let _ = executor.stop().await;
    let mut messages = Vec::new();
    while let Ok(event) = events.try_recv() {
        if let super::ExecutorEvent::Error { message } = event {
            messages.push(message);
        }
    }
    assert!(
        calls.iter().any(|c| c == "mount_park:mount-1"),
        "weather turned unsafe during a recovery ladder and nothing acted on it; \
         messages={messages:?} calls={calls:?}"
    );
    assert!(
        !messages
            .iter()
            .any(|m| m.contains("Recovery could not fix")),
        "a weather abort was reported as recovery running out; messages={messages:?}"
    );
}

/// Start a run on a scripted rig whose guide star is lost and whose guider
/// cannot restart, and return it once it is in a recovery ladder that retries
/// every `retry_interval_secs`.
async fn start_run_in_guide_star_recovery(
    ops: Arc<ScriptedDeviceOps>,
    retry_interval_secs: f64,
) -> super::SequenceExecutor {
    ops.guider_start_fails.store(true, Ordering::SeqCst);
    let mut executor = super::SequenceExecutor::new();
    executor.set_devices(None, Some("mount-1".to_string()), None, None, None);
    executor
        .update_recovery_config(crate::recovery::RecoveryRuntimeConfig {
            retry_interval_secs,
            max_duration_secs: 5400.0,
            ..crate::recovery::RecoveryRuntimeConfig::default()
        })
        .await;
    let executor = start_long_run(executor, ops.clone()).await;
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(10);
    while ops.call_count("guider_get_status") < 2 {
        assert!(
            tokio::time::Instant::now() < deadline,
            "monitor never polled the guider"
        );
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    ops.guiding.store(false, Ordering::SeqCst);
    let state = wait_for_state(&executor, std::time::Duration::from_secs(15), |s| {
        s == super::ExecutorState::Recovering
    })
    .await;
    assert_eq!(
        state,
        super::ExecutorState::Recovering,
        "calls={:?}",
        ops.calls()
    );
    executor
}

/// Resume is the answer to a pause, not to a recovery. Pressed while the
/// ladder is still re-acquiring the guide star, it must not unfreeze the node
/// tree: every frame taken then is unguided. Try-now and abort are the
/// operator's controls over a ladder.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn resume_during_recovery_does_not_unfreeze_the_run() {
    let ops = Arc::new(ScriptedDeviceOps::new());
    let mut executor = start_run_in_guide_star_recovery(ops.clone(), 600.0).await;

    executor.resume().await.expect("resume");
    tokio::time::sleep(std::time::Duration::from_secs(1)).await;
    let state = executor.get_state().await;
    let recovering = executor.current_recovery().is_some();
    let _ = executor.stop().await;
    assert!(recovering, "the ladder should still be running");
    assert_ne!(
        state,
        super::ExecutorState::Running,
        "Resume set the run Running while recovery was still re-acquiring the guide star"
    );
}

/// An operator who pauses while a recovery ladder runs has placed a hold. A
/// ladder that then succeeds must leave the run paused, not resume it under
/// him.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_pause_placed_during_recovery_survives_the_recovery() {
    let ops = Arc::new(ScriptedDeviceOps::new());
    let mut executor = start_run_in_guide_star_recovery(ops.clone(), 2.0).await;

    executor.pause().await.expect("pause");
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
    // The guider can restart now; the next attempt re-acquires.
    ops.relock_after_starts.store(1, Ordering::SeqCst);
    ops.guider_start_fails.store(false, Ordering::SeqCst);
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(20);
    while executor.current_recovery().is_some() {
        assert!(
            tokio::time::Instant::now() < deadline,
            "recovery never finished; calls={:?}",
            ops.calls()
        );
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    let state = executor.get_state().await;
    let _ = executor.stop().await;
    assert_eq!(
        state,
        super::ExecutorState::Paused,
        "the operator's pause was lifted when recovery succeeded"
    );
}

/// When recovery runs out under the default hold-for-operator policy, what it
/// tells the operator must match what it did to the rig. A lost guide star
/// never switches tracking off (it is mostly cloud, and the mount must stay on
/// the target), so the give-up message must not say tracking was left off.
///
/// A lost guide star ends the run when recovery runs out only for the operator
/// who turned on "Stop the run for quality problems"; by default the run
/// images on unguided (owner decision 2026-10-06), so this test turns it on.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_guide_star_give_up_leaves_tracking_on_and_says_nothing_about_it() {
    let ops = Arc::new(ScriptedDeviceOps::new());
    ops.guider_start_fails.store(true, Ordering::SeqCst);
    let mut executor = super::SequenceExecutor::new();
    executor.set_devices(None, Some("mount-1".to_string()), None, None, None);
    executor.set_stop_on_quality_problems(true).await;
    executor
        .update_recovery_config(crate::recovery::RecoveryRuntimeConfig {
            retry_interval_secs: 1.0,
            max_duration_secs: 2.0,
            ..crate::recovery::RecoveryRuntimeConfig::default()
        })
        .await;
    let mut events = executor.subscribe();
    let mut executor = start_long_run(executor, ops.clone()).await;
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(10);
    while ops.call_count("guider_get_status") < 2 {
        assert!(
            tokio::time::Instant::now() < deadline,
            "monitor never polled the guider"
        );
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    ops.guiding.store(false, Ordering::SeqCst);
    let state = wait_for_state(&executor, std::time::Duration::from_secs(30), |s| {
        s == super::ExecutorState::Failed
    })
    .await;
    let calls = ops.calls();
    let _ = executor.stop().await;
    let mut messages = Vec::new();
    while let Ok(event) = events.try_recv() {
        if let super::ExecutorEvent::Error { message } = event {
            messages.push(message);
        }
    }
    assert_eq!(state, super::ExecutorState::Failed, "calls={calls:?}");
    assert!(
        !calls
            .iter()
            .any(|c| c == "mount_set_tracking:mount-1:false"),
        "a lost guide star must not stop tracking; calls={calls:?}"
    );
    assert!(ops.mount_tracking.load(Ordering::SeqCst));
    let give_up = messages
        .iter()
        .find(|m| m.contains("Recovery could not fix"))
        .unwrap_or_else(|| panic!("no give-up message; messages={messages:?}"));
    assert!(
        !give_up.to_lowercase().contains("tracking"),
        "the give-up message claims something about tracking it did not do: {give_up}"
    );
}

/// The default ending of the same night: the guide star never comes back, the
/// run images on unguided (owner decision 2026-10-06), and tracking was never
/// switched off, so no frame after it trails for a second reason.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_guide_star_never_reacquired_images_on_with_tracking_back_on() {
    let ops = Arc::new(ScriptedDeviceOps::new());
    ops.guider_start_fails.store(true, Ordering::SeqCst);
    let mut executor = super::SequenceExecutor::new();
    executor.set_devices(None, Some("mount-1".to_string()), None, None, None);
    executor
        .update_recovery_config(crate::recovery::RecoveryRuntimeConfig {
            retry_interval_secs: 1.0,
            max_duration_secs: 2.0,
            ..crate::recovery::RecoveryRuntimeConfig::default()
        })
        .await;
    let mut events = executor.subscribe();
    let mut executor = start_long_run(executor, ops.clone()).await;
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(10);
    while ops.call_count("guider_get_status") < 2 {
        assert!(
            tokio::time::Instant::now() < deadline,
            "monitor never polled the guider"
        );
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    ops.guiding.store(false, Ordering::SeqCst);
    let recovered = tokio::time::timeout(std::time::Duration::from_secs(30), async {
        loop {
            match events.recv().await {
                Ok(super::ExecutorEvent::RecoveryCompleted { .. }) => return true,
                Ok(super::ExecutorEvent::RecoveryGaveUp { .. }) => return false,
                Ok(_) | Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {}
                Err(tokio::sync::broadcast::error::RecvError::Closed) => return false,
            }
        }
    })
    .await
    .expect("the recovery never ended");
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    let state = executor.get_state().await;
    let calls = ops.calls();
    let _ = executor.stop().await;

    assert!(recovered, "the run must not give up; calls={calls:?}");
    assert_eq!(state, super::ExecutorState::Running, "calls={calls:?}");
    assert!(
        !calls
            .iter()
            .any(|c| c == "mount_set_tracking:mount-1:false"),
        "a lost guide star must not stop tracking; calls={calls:?}"
    );
    assert!(
        ops.mount_tracking.load(Ordering::SeqCst),
        "tracking must be back on for the unguided frames; calls={calls:?}"
    );
    assert!(
        !calls.iter().any(|c| c.starts_with("mount_park")),
        "{calls:?}"
    );
}

// =============================================================================
// The operator's park settings: "Park on unsafe weather", "Park before dawn".
// =============================================================================

/// A run on a scripted mount, dome and cover, with the operator's park
/// settings applied as the app pushes them before launch.
async fn start_park_policy_run(
    ops: Arc<ScriptedDeviceOps>,
    policy: Option<super::ParkPolicy>,
) -> super::SequenceExecutor {
    let mut executor = super::SequenceExecutor::new();
    executor.set_devices(None, Some("mount-1".to_string()), None, None, None);
    executor.set_dome(Some("dome-1".to_string()));
    executor.set_cover_calibrator(Some("cover-1".to_string()));
    if let Some(policy) = policy {
        executor.set_park_policy(policy);
    }
    start_long_run(executor, ops).await
}

fn parked_or_closed(calls: &[String]) -> bool {
    calls.iter().any(|c| {
        c.starts_with("mount_park") || c.starts_with("cover_close") || c.starts_with("dome_close")
    })
}

/// Collect the trigger-fired actions and error messages sent so far.
fn drain_fired_and_errors(
    events: &mut tokio::sync::broadcast::Receiver<super::ExecutorEvent>,
) -> (Vec<(String, String)>, Vec<String>) {
    let mut fired = Vec::new();
    let mut errors = Vec::new();
    while let Ok(event) = events.try_recv() {
        match event {
            super::ExecutorEvent::TriggerFired {
                trigger_id, action, ..
            } => fired.push((trigger_id, action)),
            super::ExecutorEvent::Error { message } => errors.push(message),
            _ => {}
        }
    }
    (fired, errors)
}

async fn wait_for_monitor(ops: &ScriptedDeviceOps) {
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(10);
    while ops.call_count("guider_get_status") < 2 {
        assert!(
            tokio::time::Instant::now() < deadline,
            "monitor never polled"
        );
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
}

const WEATHER_OFF: super::ParkPolicy = super::ParkPolicy {
    park_on_unsafe_weather: false,
    park_before_dawn: true,
};

const DAWN_OFF: super::ParkPolicy = super::ParkPolicy {
    park_on_unsafe_weather: true,
    park_before_dawn: false,
};

/// The shipped settings keep parking: an unsafe verdict parks and closes.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn unsafe_weather_parks_when_park_on_unsafe_weather_is_on() {
    let ops = Arc::new(ScriptedDeviceOps::new());
    let mut executor = start_park_policy_run(ops.clone(), None).await;
    wait_for_monitor(&ops).await;
    executor.update_weather_verdict(Some(true)).await;
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(10);
    while ops.call_count("mount_park") == 0 && tokio::time::Instant::now() < deadline {
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
    let calls = ops.calls();
    let _ = executor.stop().await;
    assert!(
        calls.iter().any(|c| c == "mount_park:mount-1"),
        "calls={calls:?}"
    );
}

/// With "Park on unsafe weather" off, unsafe weather still stops the run
/// exposing and says so, but nothing is parked or closed.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn unsafe_weather_holds_without_parking_when_the_operator_turned_parking_off() {
    let ops = Arc::new(ScriptedDeviceOps::new());
    let mut executor = super::SequenceExecutor::new();
    let mut events = executor.subscribe();
    executor.set_park_policy(WEATHER_OFF);
    executor.set_devices(None, Some("mount-1".to_string()), None, None, None);
    executor.set_dome(Some("dome-1".to_string()));
    executor.set_cover_calibrator(Some("cover-1".to_string()));
    let mut executor = start_long_run(executor, ops.clone()).await;
    wait_for_monitor(&ops).await;

    executor.update_weather_verdict(Some(true)).await;
    let state = wait_for_state(&executor, std::time::Duration::from_secs(10), |s| {
        s != super::ExecutorState::Running
    })
    .await;
    tokio::time::sleep(std::time::Duration::from_secs(3)).await;
    let calls = ops.calls();
    let _ = executor.stop().await;
    let (fired, _) = drain_fired_and_errors(&mut events);

    assert!(
        !parked_or_closed(&calls),
        "Park on unsafe weather is off and the rig was parked or closed; calls={calls:?}"
    );
    assert_eq!(
        state,
        super::ExecutorState::Recovering,
        "unsafe weather must stop the run exposing; fired={fired:?}"
    );
    assert!(
        fired
            .iter()
            .any(|(id, action)| id == "weather_unsafe" && action == "Pause"),
        "the fired trigger must say what it did, not ParkAndAbort; fired={fired:?}"
    );
}

/// The same setting holds during an operator pause: the weather rule may act
/// under a hold only by parking, and parking is off, so it leaves the hold be.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn unsafe_weather_during_a_pause_does_not_park_when_parking_is_off() {
    let ops = Arc::new(ScriptedDeviceOps::new());
    let mut executor = start_park_policy_run(ops.clone(), Some(WEATHER_OFF)).await;
    wait_for_monitor(&ops).await;
    executor.pause().await.expect("pause");
    let state = wait_for_state(&executor, std::time::Duration::from_secs(5), |s| {
        s == super::ExecutorState::Paused
    })
    .await;
    assert_eq!(state, super::ExecutorState::Paused);

    executor.update_weather_verdict(Some(true)).await;
    tokio::time::sleep(std::time::Duration::from_secs(4)).await;
    let calls = ops.calls();
    let state = executor.get_state().await;
    let _ = executor.stop().await;
    assert!(!parked_or_closed(&calls), "calls={calls:?}");
    assert_eq!(state, super::ExecutorState::Paused);
}

/// And during a recovery ladder, which since 09fbea229 watches the weather too.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn unsafe_weather_during_recovery_does_not_park_when_parking_is_off() {
    let ops = Arc::new(ScriptedDeviceOps::new());
    ops.guider_start_fails.store(true, Ordering::SeqCst);
    let mut executor = super::SequenceExecutor::new();
    executor.set_park_policy(WEATHER_OFF);
    executor.set_devices(None, Some("mount-1".to_string()), None, None, None);
    executor.set_dome(Some("dome-1".to_string()));
    executor
        .update_recovery_config(crate::recovery::RecoveryRuntimeConfig {
            retry_interval_secs: 600.0,
            max_duration_secs: 5400.0,
            ..crate::recovery::RecoveryRuntimeConfig::default()
        })
        .await;
    let mut executor = start_long_run(executor, ops.clone()).await;
    wait_for_monitor(&ops).await;
    ops.guiding.store(false, Ordering::SeqCst);
    let state = wait_for_state(&executor, std::time::Duration::from_secs(15), |s| {
        s == super::ExecutorState::Recovering
    })
    .await;
    assert_eq!(state, super::ExecutorState::Recovering);

    executor.update_weather_verdict(Some(true)).await;
    tokio::time::sleep(std::time::Duration::from_secs(4)).await;
    let calls = ops.calls();
    let _ = executor.stop().await;
    assert!(!parked_or_closed(&calls), "calls={calls:?}");
}

/// A setting changed while the run is going reaches the trigger at once.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn turning_weather_parking_off_mid_run_takes_effect() {
    let ops = Arc::new(ScriptedDeviceOps::new());
    let mut executor = start_park_policy_run(ops.clone(), None).await;
    wait_for_monitor(&ops).await;
    executor.set_park_policy(WEATHER_OFF);

    executor.update_weather_verdict(Some(true)).await;
    let _ = wait_for_state(&executor, std::time::Duration::from_secs(10), |s| {
        s != super::ExecutorState::Running
    })
    .await;
    tokio::time::sleep(std::time::Duration::from_secs(3)).await;
    let calls = ops.calls();
    let _ = executor.stop().await;
    assert!(!parked_or_closed(&calls), "calls={calls:?}");
}

/// Force the Dawn Approaching trigger: a site and a dawn ten minutes away.
async fn bring_dawn_near(executor: &super::SequenceExecutor) {
    executor
        .update_trigger_state(|ts| {
            ts.set_observer_location(Some(45.0), Some(-75.0));
            ts.dawn_time = Some(chrono::Utc::now().timestamp() + 600);
        })
        .await;
}

/// The shipped setting parks at dawn.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn dawn_parks_when_park_before_dawn_is_on() {
    let ops = Arc::new(ScriptedDeviceOps::new());
    let mut executor = start_park_policy_run(ops.clone(), None).await;
    wait_for_monitor(&ops).await;
    bring_dawn_near(&executor).await;
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(10);
    while ops.call_count("mount_park") == 0 && tokio::time::Instant::now() < deadline {
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
    let calls = ops.calls();
    let _ = executor.stop().await;
    assert!(
        calls.iter().any(|c| c == "mount_park:mount-1"),
        "calls={calls:?}"
    );
}

/// With "Park before dawn" off, dawn still ends the run, and nothing is parked
/// or closed. The operator is told the mount was left as it was.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn dawn_ends_the_run_without_parking_when_the_operator_turned_parking_off() {
    let ops = Arc::new(ScriptedDeviceOps::new());
    let mut executor = super::SequenceExecutor::new();
    let mut events = executor.subscribe();
    executor.set_park_policy(DAWN_OFF);
    executor.set_devices(None, Some("mount-1".to_string()), None, None, None);
    executor.set_dome(Some("dome-1".to_string()));
    executor.set_cover_calibrator(Some("cover-1".to_string()));
    let mut executor = start_long_run(executor, ops.clone()).await;
    wait_for_monitor(&ops).await;

    bring_dawn_near(&executor).await;
    let state = wait_for_state(&executor, std::time::Duration::from_secs(15), |s| {
        matches!(
            s,
            super::ExecutorState::Cancelled
                | super::ExecutorState::Completed
                | super::ExecutorState::Failed
        )
    })
    .await;
    let calls = ops.calls();
    let _ = executor.stop().await;
    let (fired, errors) = drain_fired_and_errors(&mut events);

    assert!(
        !parked_or_closed(&calls),
        "Park before dawn is off and the rig was parked or closed; calls={calls:?}"
    );
    assert_eq!(
        state,
        super::ExecutorState::Cancelled,
        "dawn must still end the run; fired={fired:?}"
    );
    assert!(
        fired
            .iter()
            .any(|(id, action)| id == "dawn_approaching" && action == "Abort"),
        "fired={fired:?}"
    );
    assert!(
        errors.iter().any(|m| m.contains("not parked")),
        "the operator must be told the mount was left as it was; errors={errors:?}"
    );
}

// =============================================================================
// Camera retries: one failed download no longer ends the run.
// =============================================================================

/// A run of `frames` zero-second darks on `cam-1`, saved under a scratch
/// directory, with the given retry policy pushed as the app pushes it before
/// launch (`None` leaves the executor's default).
async fn start_capture_run(
    ops: Arc<ScriptedDeviceOps>,
    frames: u32,
    policy: Option<crate::instructions::DeviceRetryPolicy>,
) -> (
    super::SequenceExecutor,
    std::path::PathBuf,
    tokio::sync::broadcast::Receiver<super::ExecutorEvent>,
) {
    use crate::{ExposureConfig, NodeDefinition, NodeType, SequenceDefinition};
    let dir = std::env::temp_dir().join(format!("sk-retry-run-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&dir).expect("temp dir");
    let mut executor = super::SequenceExecutor::new();
    executor.set_devices(Some("cam-1".to_string()), None, None, None, None);
    executor.set_save_path(Some(dir.clone()));
    if let Some(policy) = policy {
        executor.set_device_retry_policy(policy);
    }
    executor.set_device_ops(ops as SharedDeviceOps);
    let mut sequence = SequenceDefinition::new("Retry run".to_string());
    sequence.nodes.push(NodeDefinition {
        id: "darks".to_string(),
        name: "Darks".to_string(),
        node_type: NodeType::TakeExposure(ExposureConfig {
            count: frames,
            duration_secs: 0.0,
            frame_type: "dark".to_string(),
            ..ExposureConfig::default()
        }),
        enabled: true,
        children: vec![],
    });
    sequence.root_node_id = Some("darks".to_string());
    executor.load_sequence(sequence).expect("sequence loads");
    let events = executor.subscribe();
    executor.start().await.expect("executor starts");
    (executor, dir, events)
}

fn retry_warnings(
    events: &mut tokio::sync::broadcast::Receiver<super::ExecutorEvent>,
) -> Vec<String> {
    let mut warnings = Vec::new();
    while let Ok(event) = events.try_recv() {
        if let super::ExecutorEvent::Warning { message } = event {
            if message.contains("Retrying in") {
                warnings.push(message);
            }
        }
    }
    warnings
}

/// The soak's `camera_download_hang` / `intermittent_errors` shape: one
/// download fails mid-run. With the executor's default policy (the setting's
/// default, 3) the frame is retried and the run completes with every frame
/// saved once.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn one_failed_download_is_retried_and_the_run_completes() {
    let ops = Arc::new(ScriptedDeviceOps::new());
    ops.fail_next_exposures(&[
        "Failed to download image: Injected simulator fault: the driver reported a failure",
    ]);
    let executor = super::SequenceExecutor::new();
    assert_eq!(
        executor.device_retry_policy(),
        crate::instructions::DeviceRetryPolicy::default(),
        "an executor the app has not configured yet retries 3 times, the setting's default"
    );
    drop(executor);

    let (executor, dir, mut events) = start_capture_run(ops.clone(), 2, None).await;
    let state = wait_for_state(&executor, std::time::Duration::from_secs(20), |s| {
        matches!(
            s,
            super::ExecutorState::Completed
                | super::ExecutorState::Failed
                | super::ExecutorState::Cancelled
        )
    })
    .await;
    let _ = std::fs::remove_dir_all(&dir);

    assert_eq!(
        state,
        super::ExecutorState::Completed,
        "one download error must not end the run"
    );
    assert_eq!(
        ops.exposure_calls.load(Ordering::SeqCst),
        3,
        "frame 1 twice, frame 2 once"
    );
    let saved = ops.saved_frames.lock().unwrap().clone();
    assert_eq!(
        saved.len(),
        2,
        "one file per frame, none for the failed attempt: {saved:?}"
    );
    assert_ne!(saved[0], saved[1]);
    let warnings = retry_warnings(&mut events);
    assert_eq!(
        warnings.len(),
        1,
        "the retry is reported once: {warnings:?}"
    );
    assert!(warnings[0].contains("retry 1 of 3"), "{}", warnings[0]);
}

/// Retries set to 0 is the old behavior: the first failed download ends the
/// run, with the device's own error.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn zero_camera_retries_fails_the_run_on_the_first_failed_download() {
    let ops = Arc::new(ScriptedDeviceOps::new());
    ops.fail_next_exposures(&["Failed to download image: USB transfer error"]);
    let (executor, dir, _events) = start_capture_run(
        ops.clone(),
        2,
        Some(crate::instructions::DeviceRetryPolicy::SINGLE_ATTEMPT),
    )
    .await;
    let state = wait_for_state(&executor, std::time::Duration::from_secs(20), |s| {
        matches!(
            s,
            super::ExecutorState::Completed
                | super::ExecutorState::Failed
                | super::ExecutorState::Cancelled
        )
    })
    .await;
    let _ = std::fs::remove_dir_all(&dir);

    assert_eq!(state, super::ExecutorState::Failed);
    assert_eq!(ops.exposure_calls.load(Ordering::SeqCst), 1);
    assert!(ops.saved_frames.lock().unwrap().is_empty());
}

async fn set_mount_motion_depth(executor: &super::SequenceExecutor, depth: u32) {
    let manager = executor.trigger_manager.read().await;
    let state = manager.state();
    let mut state = state.write().await;
    while state.guiding.motion_depth() < depth {
        let _ = state.guiding.begin_motion();
    }
    while state.guiding.motion_depth() > depth {
        state.guiding.end_motion();
    }
}

/// Wait up to `within` for the guide-star-lost trigger.
async fn guide_star_lost_fires(
    events: &mut tokio::sync::broadcast::Receiver<super::ExecutorEvent>,
    within: std::time::Duration,
) -> bool {
    tokio::time::timeout(within, async {
        loop {
            match events.recv().await {
                Ok(super::ExecutorEvent::TriggerFired { trigger_id, .. })
                    if trigger_id == "guide_star_lost" =>
                {
                    return true;
                }
                Ok(_) | Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {}
                Err(tokio::sync::broadcast::error::RecvError::Closed) => return false,
            }
        }
    })
    .await
    .unwrap_or(false)
}

/// While the run moves the mount itself (slew, center, sync, flip) the guide
/// star leaving the guide frame is what the move does. On the rig it fired
/// Guide Star Lost 1.6 s into a slew and paused the run.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_star_lost_during_the_runs_own_move_is_not_a_lost_star() {
    let ops = Arc::new(ScriptedDeviceOps::new());
    let mut executor = super::SequenceExecutor::new();
    executor.set_devices(None, Some("mount-1".to_string()), None, None, None);
    let mut events = executor.subscribe();
    let mut executor = start_long_run(executor, ops.clone()).await;

    set_mount_motion_depth(&executor, 1).await;
    ops.guiding.store(false, Ordering::SeqCst);
    let fired_during_move =
        guide_star_lost_fires(&mut events, std::time::Duration::from_secs(3)).await;
    // The move is over and the star is still gone: now it is lost.
    set_mount_motion_depth(&executor, 0).await;
    let fired_after_move =
        guide_star_lost_fires(&mut events, std::time::Duration::from_secs(5)).await;
    let _ = executor.stop().await;

    assert!(
        !fired_during_move,
        "Guide Star Lost fired during the run's own move"
    );
    assert!(
        fired_after_move,
        "a star still lost after the move must fire"
    );
}

/// The recovery stopped tracking 40 ms into the run's slew on the rig. It must
/// leave tracking alone while the mount is moving.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn recovery_leaves_tracking_on_while_the_mount_slews() {
    let ops = Arc::new(ScriptedDeviceOps::new());
    let mut executor = super::SequenceExecutor::new();
    executor.set_devices(None, Some("mount-1".to_string()), None, None, None);
    let mut events = executor.subscribe();
    let mut executor = start_long_run(executor, ops.clone()).await;

    ops.mount_slewing.store(true, Ordering::SeqCst);
    ops.guiding.store(false, Ordering::SeqCst);
    let recovering = tokio::time::timeout(std::time::Duration::from_secs(15), async {
        loop {
            match events.recv().await {
                Ok(super::ExecutorEvent::RecoveryStarted { .. }) => return true,
                Ok(_) | Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {}
                Err(tokio::sync::broadcast::error::RecvError::Closed) => return false,
            }
        }
    })
    .await
    .unwrap_or(false);
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    let calls = ops.calls();
    let _ = executor.stop().await;

    assert!(recovering, "the lost star must still start a recovery");
    assert!(
        !calls
            .iter()
            .any(|c| c == "mount_set_tracking:mount-1:false"),
        "tracking was stopped under a slewing mount: {calls:?}"
    );
}

/// A long run on a rig with no safety monitor, fail open, as the owner's rig
/// is set up. The sky must read safe for `resume_after_secs` before a hold
/// ends.
async fn start_weather_run(
    ops: Arc<ScriptedDeviceOps>,
    policy: Option<super::ParkPolicy>,
    resume_after_secs: u64,
) -> super::SequenceExecutor {
    ops.safety_absent.store(true, Ordering::SeqCst);
    let mut executor = super::SequenceExecutor::new();
    executor.set_safety_fail_mode(crate::SafetyFailMode::FailOpen);
    if let Some(policy) = policy {
        executor.set_park_policy(policy);
    }
    executor.set_weather_resume_after_safe_secs(resume_after_secs);
    executor.set_devices(None, Some("mount-1".to_string()), None, None, None);
    executor.set_dome(Some("dome-1".to_string()));
    executor.set_cover_calibrator(Some("cover-1".to_string()));
    let executor = start_long_run(executor, ops.clone()).await;
    wait_for_monitor(&ops).await;
    executor
}

/// A rig with no safety monitor, fail open, "Park on unsafe weather" off: an
/// unsafe app verdict holds the run, and once the verdict clears the run goes
/// back to imaging on its own. The hold leaves tracking on.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn weather_hold_without_a_safety_monitor_resumes_when_the_verdict_clears() {
    let ops = Arc::new(ScriptedDeviceOps::new());
    let mut executor = start_weather_run(ops.clone(), Some(WEATHER_OFF), 0).await;

    executor.update_weather_verdict(Some(true)).await;
    let held = wait_for_state(&executor, std::time::Duration::from_secs(10), |s| {
        s == super::ExecutorState::Recovering
    })
    .await;
    executor.update_weather_verdict(None).await;
    let after = wait_for_state(&executor, std::time::Duration::from_secs(30), |s| {
        s == super::ExecutorState::Running
    })
    .await;
    let calls = ops.calls();
    let _ = executor.stop().await;
    assert_eq!(held, super::ExecutorState::Recovering);
    assert_eq!(after, super::ExecutorState::Running, "calls={calls:?}");
    assert!(
        !calls
            .iter()
            .any(|c| c == "mount_set_tracking:mount-1:false"),
        "a weather hold keeps the mount tracking; calls={calls:?}"
    );
}

/// A forecast says cloudy with the shipped settings (park on unsafe weather
/// on): the run is held, nothing is parked or closed, the run is not ended,
/// and it resumes by itself once the forecast clears.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_forecast_cloud_holds_and_resumes_and_never_parks() {
    let ops = Arc::new(ScriptedDeviceOps::new());
    let mut executor = start_weather_run(ops.clone(), None, 0).await;
    let mut events = executor.subscribe();

    executor.update_weather_verdict_from(Some(true), true).await;
    let held = wait_for_state(&executor, std::time::Duration::from_secs(10), |s| {
        s != super::ExecutorState::Running
    })
    .await;
    // Long enough for the hold to have been re-judged many times.
    tokio::time::sleep(std::time::Duration::from_secs(4)).await;
    let still_held = executor.get_state().await;
    executor.update_weather_verdict_from(None, false).await;
    let after = wait_for_state(&executor, std::time::Duration::from_secs(30), |s| {
        s == super::ExecutorState::Running
    })
    .await;
    let calls = ops.calls();
    let _ = executor.stop().await;
    let (fired, _) = drain_fired_and_errors(&mut events);

    assert_eq!(held, super::ExecutorState::Recovering, "fired={fired:?}");
    assert_eq!(still_held, super::ExecutorState::Recovering);
    assert!(
        !parked_or_closed(&calls),
        "a forecast must never park or close; calls={calls:?}"
    );
    assert!(
        fired
            .iter()
            .all(|(id, action)| id != "weather_unsafe" || action == "Pause"),
        "fired={fired:?}"
    );
    assert_eq!(after, super::ExecutorState::Running, "calls={calls:?}");
}

/// The same verdict from a sensor at the site keeps the configured park.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_sensor_verdict_still_parks_when_parking_is_on() {
    let ops = Arc::new(ScriptedDeviceOps::new());
    let mut executor = start_weather_run(ops.clone(), None, 0).await;
    executor
        .update_weather_verdict_from(Some(true), false)
        .await;
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(10);
    while ops.call_count("mount_park") == 0 && tokio::time::Instant::now() < deadline {
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
    let calls = ops.calls();
    let _ = executor.stop().await;
    assert!(
        calls.iter().any(|c| c == "mount_park:mount-1"),
        "calls={calls:?}"
    );
}

/// A weather hold has no budget: a recovery config that would give any other
/// cause up in seconds leaves a weather hold holding, never `Failed`.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_weather_hold_never_runs_out_and_fails_the_run() {
    let ops = Arc::new(ScriptedDeviceOps::new());
    ops.safety_absent.store(true, Ordering::SeqCst);
    let mut executor = super::SequenceExecutor::new();
    executor.set_safety_fail_mode(crate::SafetyFailMode::FailOpen);
    executor.set_devices(None, Some("mount-1".to_string()), None, None, None);
    executor
        .update_recovery_config(crate::recovery::RecoveryRuntimeConfig {
            retry_interval_secs: 1.0,
            max_duration_secs: 2.0,
            ..crate::recovery::RecoveryRuntimeConfig::default()
        })
        .await;
    let mut executor = start_long_run(executor, ops.clone()).await;
    wait_for_monitor(&ops).await;

    executor.update_weather_verdict_from(Some(true), true).await;
    let held = wait_for_state(&executor, std::time::Duration::from_secs(10), |s| {
        s == super::ExecutorState::Recovering
    })
    .await;
    tokio::time::sleep(std::time::Duration::from_secs(6)).await;
    let later = executor.get_state().await;
    let _ = executor.stop().await;
    assert_eq!(held, super::ExecutorState::Recovering);
    assert_eq!(later, super::ExecutorState::Recovering);
}

/// The operator's "the sky is clear" resumes a held run at once, while the
/// forecast still says cloudy and the safe period has not passed.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_operator_clear_sky_override_resumes_a_held_run_now() {
    let ops = Arc::new(ScriptedDeviceOps::new());
    let mut executor = start_weather_run(ops.clone(), None, 300).await;

    executor.update_weather_verdict_from(Some(true), true).await;
    let held = wait_for_state(&executor, std::time::Duration::from_secs(10), |s| {
        s == super::ExecutorState::Recovering
    })
    .await;
    executor
        .set_weather_operator_clear(1800, "stars in the guide camera")
        .await;
    let after = wait_for_state(&executor, std::time::Duration::from_secs(10), |s| {
        s == super::ExecutorState::Running
    })
    .await;
    // The verdict is still UNSAFE; the override keeps it from re-holding.
    tokio::time::sleep(std::time::Duration::from_secs(3)).await;
    let later = executor.get_state().await;
    let calls = ops.calls();
    let _ = executor.stop().await;
    assert_eq!(held, super::ExecutorState::Recovering);
    assert_eq!(after, super::ExecutorState::Running, "calls={calls:?}");
    assert_eq!(later, super::ExecutorState::Running);
    assert!(!parked_or_closed(&calls), "calls={calls:?}");
}

/// A verdict nobody refreshes is missing data. Under fail open it is set aside
/// and the held run carries on, with a warning; under fail closed it holds.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_stale_unsafe_verdict_is_set_aside_under_fail_open() {
    let ops = Arc::new(ScriptedDeviceOps::new());
    let mut executor = start_weather_run(ops.clone(), Some(WEATHER_OFF), 0).await;
    executor
        .runtime_config
        .write()
        .weather_verdict_staleness_secs = 30;
    let mut events = executor.subscribe();

    executor.update_weather_verdict_from(Some(true), true).await;
    let held = wait_for_state(&executor, std::time::Duration::from_secs(10), |s| {
        s == super::ExecutorState::Recovering
    })
    .await;
    // No further pushes: the verdict goes stale after 30 s.
    let after = wait_for_state(&executor, std::time::Duration::from_secs(60), |s| {
        s == super::ExecutorState::Running
    })
    .await;
    let _ = executor.stop().await;
    let mut warnings = Vec::new();
    while let Ok(event) = events.try_recv() {
        if let super::ExecutorEvent::Warning { message } = event {
            warnings.push(message);
        }
    }
    assert_eq!(held, super::ExecutorState::Recovering);
    assert_eq!(after, super::ExecutorState::Running);
    assert!(
        warnings.iter().any(|w| w.contains("set aside")),
        "warnings={warnings:?}"
    );
}

#[test]
fn only_fail_closed_keeps_holding_on_a_stale_verdict() {
    use crate::SafetyFailMode;
    assert!(super::stale_unsafe_verdict_holds(
        SafetyFailMode::FailClosed
    ));
    assert!(!super::stale_unsafe_verdict_holds(SafetyFailMode::FailOpen));
    assert!(!super::stale_unsafe_verdict_holds(SafetyFailMode::WarnOnly));
}

/// A passing cloud: the guide star is lost, the run holds with the mount still
/// tracking and nothing reads the hold as lost tracking, and once the stars are
/// back the guider holds a star again and the run resumes by itself.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_cloud_that_loses_the_guide_star_holds_tracking_and_resumes_when_stars_return() {
    let ops = Arc::new(ScriptedDeviceOps::new());
    let mut executor = super::SequenceExecutor::new();
    let mut events = executor.subscribe();
    executor.set_devices(None, Some("mount-1".to_string()), None, None, None);
    // The shipped interval is 10 min; the hold looks for the star at least
    // every GUIDE_STAR_RECHECK_SECS. A short interval keeps the test short.
    executor
        .update_recovery_config(crate::recovery::RecoveryRuntimeConfig {
            retry_interval_secs: 3.0,
            max_duration_secs: 600.0,
            // Even an operator who asked for tracking to stop during
            // recovery keeps it for a lost guide star.
            stop_tracking_during_recovery: true,
            ..crate::recovery::RecoveryRuntimeConfig::default()
        })
        .await;
    let mut executor = start_long_run(executor, ops.clone()).await;
    wait_for_monitor(&ops).await;

    // Cloud: no guide star, no star to pick.
    ops.no_guide_star.store(true, Ordering::SeqCst);
    ops.guiding.store(false, Ordering::SeqCst);
    let held = wait_for_state(&executor, std::time::Duration::from_secs(15), |s| {
        s == super::ExecutorState::Recovering
    })
    .await;
    tokio::time::sleep(std::time::Duration::from_secs(6)).await;
    let during = executor.get_state().await;

    // The cloud passes: PHD2 holds a star again.
    ops.no_guide_star.store(false, Ordering::SeqCst);
    ops.guiding.store(true, Ordering::SeqCst);
    let after = wait_for_state(&executor, std::time::Duration::from_secs(20), |s| {
        s == super::ExecutorState::Running
    })
    .await;
    let calls = ops.calls();
    let _ = executor.stop().await;
    let (fired, _) = drain_fired_and_errors(&mut events);

    assert_eq!(held, super::ExecutorState::Recovering, "fired={fired:?}");
    assert_eq!(during, super::ExecutorState::Recovering);
    assert_eq!(after, super::ExecutorState::Running, "calls={calls:?}");
    assert!(
        !calls
            .iter()
            .any(|c| c == "mount_set_tracking:mount-1:false"),
        "a lost guide star must not stop tracking; calls={calls:?}"
    );
    assert!(
        !fired.iter().any(|(id, _)| id == "mount_tracking_lost"),
        "fired={fired:?}"
    );
}

// =============================================================================
// Calibration-only runs: the standard triggers stand down.
// =============================================================================

/// A darks run with a mount assigned, dawn ten minutes away, an unsafe weather
/// verdict and this run's guiding armed: none of the standard triggers may act
/// on it. Before the exemption, Dawn Approaching ended such a run at 0 frames
/// and the dither and autofocus triggers drove the mount and focuser.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_calibration_run_is_not_parked_dithered_or_ended_by_the_standard_triggers() {
    use crate::{
        ExposureConfig, LoopCondition, LoopConfig, NodeDefinition, NodeType, SequenceDefinition,
    };
    let ops = Arc::new(ScriptedDeviceOps::new());
    let dir = std::env::temp_dir().join(format!("sk-cal-run-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&dir).expect("temp dir");
    let mut executor = super::SequenceExecutor::new();
    let mut events = executor.subscribe();
    executor.set_devices(
        Some("cam-1".to_string()),
        Some("mount-1".to_string()),
        Some("focuser-1".to_string()),
        None,
        None,
    );
    executor.set_save_path(Some(dir.clone()));
    executor.set_device_ops(ops.clone() as SharedDeviceOps);
    let mut sequence = SequenceDefinition::new("End of night calibration".to_string());
    sequence.nodes = vec![
        NodeDefinition {
            id: "root".to_string(),
            name: "Calibration".to_string(),
            node_type: NodeType::Loop(LoopConfig {
                iterations: Some(1),
                condition: LoopCondition::Count,
                ..Default::default()
            }),
            enabled: true,
            children: vec!["darks".to_string(), "wait".to_string()],
        },
        NodeDefinition {
            id: "darks".to_string(),
            name: "Darks".to_string(),
            node_type: NodeType::TakeExposure(ExposureConfig {
                count: 6,
                duration_secs: 0.0,
                frame_type: "dark".to_string(),
                dither_every: Some(1),
                ..ExposureConfig::default()
            }),
            enabled: true,
            children: vec![],
        },
        NodeDefinition {
            id: "wait".to_string(),
            name: "Long wait".to_string(),
            node_type: NodeType::Delay(crate::DelayConfig { seconds: 600.0 }),
            enabled: true,
            children: vec![],
        },
    ];
    sequence.root_node_id = Some("root".to_string());
    executor.load_sequence(sequence).expect("sequence loads");
    executor.start().await.expect("executor starts");
    arm_run_guiding(&executor).await;
    wait_for_monitor(&ops).await;
    bring_dawn_near(&executor).await;
    executor.update_weather_verdict(Some(true)).await;
    executor
        .update_trigger_state(|ts| {
            ts.completed_exposures = 50;
            ts.set_guide_star_lost(true);
        })
        .await;
    tokio::time::sleep(std::time::Duration::from_secs(4)).await;

    let state = executor.get_state().await;
    let calls = ops.calls();
    let _ = executor.stop().await;
    let _ = std::fs::remove_dir_all(&dir);
    let (fired, _) = drain_fired_and_errors(&mut events);

    assert_eq!(state, super::ExecutorState::Running, "fired={fired:?}");
    assert!(fired.is_empty(), "fired={fired:?}");
    assert!(!parked_or_closed(&calls), "calls={calls:?}");
    assert!(
        !calls
            .iter()
            .any(|c| c.starts_with("focuser_move") || c.starts_with("mount_slew")),
        "calls={calls:?}"
    );
}
