//! Shared fixtures for the `instructions` unit tests.
//!
//! Release-pass C3: the tests were one 3.7k-line module. The fixtures below
//! stayed here and each cluster of tests moved verbatim into a child module;
//! child modules see these private helpers because they are ancestors' items.

use super::*;

use super::autofocus::AF_GATE_TEST_LOCK;

// P3-7: post-start calibration quality validation

fn _cfg() -> StartGuidingConfig {
    StartGuidingConfig::default()
}

// DOME / ROTATOR MOVE-AND-VERIFY GUARDS (cluster: dome-rotator)
//
// These prove that the dome park/open/close and rotator move
// instructions are MOVE-AND-VERIFY (they poll the device for actual
// arrival before reporting success) and that a park failing to close
// the shutter surfaces a hard error rather than reporting "parked".
// A failed roof MUST return Failure, never Success.

// `DeviceOps`, `DeviceResult`, `GuidingStatus`, `NullDeviceOps`, `ImageData`
// are already in scope via the module-level `use crate::*`
// (lib.rs re-exports `device_ops::*`).
use async_trait::async_trait;

use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU32};
use std::sync::Mutex;

/// Scriptable DeviceOps for the dome/rotator verify tests. Only the
/// dome and rotator methods are interesting; everything else delegates
/// to `NullDeviceOps`. Counters let the tests assert that the
/// instruction actually polled for arrival (move-and-verify) rather
/// than fire-and-forgetting.
struct ScriptedDomeRotatorOps {
    inner: Arc<NullDeviceOps>,
    // Rotator
    /// Sequence of angles `rotator_get_angle` returns, one per poll. The
    /// last entry repeats once the script is exhausted.
    rotator_angles: Mutex<Vec<f64>>,
    rotator_get_angle_calls: AtomicU32,
    rotator_move_to_calls: AtomicU32,
    // Dome
    /// Sequence of shutter statuses `dome_get_shutter_status` returns,
    /// one per poll; the last entry repeats once exhausted.
    dome_shutter_states: Mutex<Vec<String>>,
    dome_shutter_status_calls: AtomicU32,
    dome_close_calls: AtomicU32,
    dome_park_calls: AtomicU32,
    /// When `Some`, `dome_close` fails with this message.
    dome_close_error: Option<String>,
    /// Device ids `dome_open` / `cover_calibrator_open_cover` were called
    /// with, so the role-resolution tests can prove the instruction
    /// commanded the device the ops layer resolved.
    dome_open_ids: Mutex<Vec<String>>,
    cover_open_ids: Mutex<Vec<String>>,
    /// Answers for the `active_*_id` role-resolution hooks — the ops
    /// layer's "here is the connected device" reply.
    active_dome_id: Option<String>,
    active_cover_calibrator_id: Option<String>,
    /// How many times the dome role was resolved. The dome instruction
    /// asks exactly once per execution, so this counts EXECUTIONS of the
    /// node — which is what a retry-collapse test has to pin down before
    /// its "one error entry" assertion means anything.
    active_dome_id_calls: AtomicU32,
    // Centering
    mount_slewing_states: Mutex<Vec<bool>>,
    mount_slew_state_calls: AtomicU32,
    /// How many times the mount was actually commanded to move. A gate that
    /// only changes the returned message while still driving the mount is
    /// indistinguishable from a real gate without this.
    mount_slew_calls: AtomicU32,
    // Camera
    camera_exposure_calls: AtomicU32,
    /// For each `guider_dither`, how many exposures had been started when it
    /// was issued, so a test can tell which frames a dither followed.
    dithers_after_frame: Mutex<Vec<u32>>,
    camera_abort_calls: AtomicU32,
    hang_camera_exposure: bool,
    /// Every `(enabled, target)` the instruction handed the cooler.
    cooler_commands: Mutex<Vec<(bool, f64)>>,
    /// When `Some`, a `camera_set_cooler(_, false, _)` fails with this
    /// message — the shape the reference rig produced when its cooler
    /// could not be switched off.
    cooler_off_error: Option<String>,
    /// Raised by the first exposure only; see
    /// [`ScriptedDomeRotatorOps::pausing_after_first_exposure`].
    pause_flag_after_first_exposure: Option<Arc<AtomicBool>>,
    // Autofocus cleanup
    focuser_moves: Mutex<Vec<i32>>,
    focuser_halt_calls: AtomicU32,
    filter_position: AtomicI32,
    filter_names: Vec<String>,
    filter_moves: Mutex<Vec<i32>>,
    guiding: AtomicBool,
    guider_stop_calls: AtomicU32,
    guider_start_calls: AtomicU32,
    /// When true, `guider_start` returns Ok but the guider never reports
    /// guiding — PHD2's behaviour on the owner's 2026-09-14 run, and the
    /// failure the autofocus cleanup calls CRITICAL.
    guider_resume_never_guides: bool,
    /// Status polls after a `guider_start` that still report not guiding, as
    /// PHD2 does while it loops, selects a star and starts guiding.
    guider_polls_before_lock: AtomicU32,
    /// The guider's reported RMS, in guide-camera pixels.
    guider_rms_total: Mutex<f64>,
    guider_calibration: Option<GuidingCalibration>,
    /// When `Some`, every `guider_dither` fails with this message.
    dither_error: Option<String>,
    /// When true, every plate solve finds no solution (a clouded frame).
    plate_solve_fails: bool,
    /// W1 daylight gate — value returned by `mount_is_parked`. Defaults to
    /// `false` (matching NullDeviceOps); the parked-rig gate test sets it
    /// `true` to prove a parked exposure is never daylight-gated.
    mount_parked: bool,
    /// When `Some`, `mount_is_parked` fails with this message instead of
    /// answering `mount_parked`.
    mount_is_parked_error: Option<String>,
    mount_unpark_calls: AtomicU32,
    // per-frame capture truth
    /// Every `FrameContext` this ops layer was handed by `save_fits`, in
    /// order. This is the FITS writer's own input — recording it is the
    /// only way to assert the frame EVENT was stamped from the same struct
    /// rather than from a second reconstruction of the same exposure.
    saved_frame_contexts: Mutex<Vec<crate::scheduling::FrameContext>>,
    /// The full path each frame was written to, in the same order. The
    /// filename is rendered from a DIFFERENT source than the header, so
    /// recording both is what lets a test prove the two agree.
    saved_frame_paths: Mutex<Vec<String>>,
    /// Distinctive live telemetry so a `FrameContext::default()` cannot
    /// masquerade as a real read. `None` keeps NullDeviceOps' answer.
    scripted_mount_coordinates: Option<(f64, f64)>,
    /// When `Some`, what `mount_readback_frame` answers instead of the
    /// identity default, so a test can stand in for a real mount whose
    /// read-back is of date while the target is J2000.
    scripted_readback_frame: Option<DeviceResult<(f64, f64)>>,
    /// When `Some((hfr, stars, eccentricity))`, what the per-frame star
    /// analysis measures on every frame, so grading sees real numbers.
    scripted_frame_metrics: Option<(f64, usize, f64)>,
    scripted_pier_side: Option<crate::meridian::PierSide>,
    scripted_cooler_power: Option<f64>,
    /// Sensor temperatures `camera_get_temperature` reports, one per read; the
    /// last one repeats. Empty: the inner ops answer.
    scripted_camera_temps: Mutex<std::collections::VecDeque<f64>>,
    scripted_focuser_position: Option<i32>,
    scripted_focuser_temperature: Option<f64>,
    /// What the camera claims it exposed for, independent of what was
    /// commanded — a driver that misreports is the whole point of the
    /// exposure-duration reconciliation.
    scripted_reported_exposure_secs: Option<f64>,
    scripted_gain: Option<i32>,
    scripted_offset: Option<i32>,
    scripted_sensor_temp_c: Option<f64>,
    /// Unbinned pixel pitch the camera reports, in microns. `None` stands
    /// in for a driver that will not answer.
    scripted_pixel_size_um: Option<(f64, f64)>,
    /// `None` stands in for a rig whose site has not been configured.
    scripted_observer_location: Option<(f64, f64)>,
    /// Errors the next exposures fail with, one per exposure, oldest first.
    camera_failures: Mutex<std::collections::VecDeque<String>>,
    /// Errors the next `filterwheel_set_position` calls fail with, one each.
    filter_set_failures: Mutex<std::collections::VecDeque<String>>,
    /// The next this-many `filterwheel_set_position` calls are accepted and
    /// never carried out: a stalled wheel.
    filter_stalled_moves: AtomicU32,
}

impl ScriptedDomeRotatorOps {
    fn new() -> Self {
        Self {
            inner: Arc::new(NullDeviceOps),
            rotator_angles: Mutex::new(vec![0.0]),
            rotator_get_angle_calls: AtomicU32::new(0),
            rotator_move_to_calls: AtomicU32::new(0),
            dome_shutter_states: Mutex::new(vec!["Closed".to_string()]),
            dome_shutter_status_calls: AtomicU32::new(0),
            dome_close_calls: AtomicU32::new(0),
            dome_park_calls: AtomicU32::new(0),
            dome_close_error: None,
            dome_open_ids: Mutex::new(Vec::new()),
            cover_open_ids: Mutex::new(Vec::new()),
            active_dome_id: None,
            active_cover_calibrator_id: None,
            active_dome_id_calls: AtomicU32::new(0),
            mount_slewing_states: Mutex::new(vec![false]),
            mount_slew_state_calls: AtomicU32::new(0),
            mount_slew_calls: AtomicU32::new(0),
            camera_exposure_calls: AtomicU32::new(0),
            dithers_after_frame: Mutex::new(Vec::new()),
            camera_abort_calls: AtomicU32::new(0),
            hang_camera_exposure: false,
            cooler_commands: Mutex::new(Vec::new()),
            cooler_off_error: None,
            pause_flag_after_first_exposure: None,
            mount_parked: false,
            mount_is_parked_error: None,
            mount_unpark_calls: AtomicU32::new(0),
            focuser_moves: Mutex::new(Vec::new()),
            focuser_halt_calls: AtomicU32::new(0),
            filter_position: AtomicI32::new(1),
            filter_names: vec!["L".to_string(), "R".to_string()],
            filter_moves: Mutex::new(Vec::new()),
            guiding: AtomicBool::new(false),
            guider_stop_calls: AtomicU32::new(0),
            guider_start_calls: AtomicU32::new(0),
            guider_resume_never_guides: false,
            guider_polls_before_lock: AtomicU32::new(0),
            guider_rms_total: Mutex::new(0.7),
            guider_calibration: None,
            dither_error: None,
            plate_solve_fails: false,
            saved_frame_contexts: Mutex::new(Vec::new()),
            saved_frame_paths: Mutex::new(Vec::new()),
            scripted_mount_coordinates: None,
            scripted_readback_frame: None,
            scripted_frame_metrics: None,
            scripted_pier_side: None,
            scripted_cooler_power: None,
            scripted_camera_temps: Mutex::new(std::collections::VecDeque::new()),
            scripted_focuser_position: None,
            scripted_focuser_temperature: None,
            scripted_reported_exposure_secs: None,
            scripted_gain: None,
            scripted_offset: None,
            scripted_sensor_temp_c: None,
            scripted_pixel_size_um: None,
            scripted_observer_location: None,
            camera_failures: Mutex::new(std::collections::VecDeque::new()),
            filter_set_failures: Mutex::new(std::collections::VecDeque::new()),
            filter_stalled_moves: AtomicU32::new(0),
        }
    }

    /// Fail the next exposures with these errors, one each.
    fn failing_exposures(self, errors: &[&str]) -> Self {
        self.camera_failures
            .lock()
            .unwrap()
            .extend(errors.iter().map(|e| e.to_string()));
        self
    }

    /// Fail the next filter-wheel moves with these errors, one each.
    fn failing_filter_moves(self, errors: &[&str]) -> Self {
        self.filter_set_failures
            .lock()
            .unwrap()
            .extend(errors.iter().map(|e| e.to_string()));
        self
    }

    /// Accept the next `moves` filter-wheel moves and never arrive.
    fn stalling_filter_moves(self, moves: u32) -> Self {
        self.filter_stalled_moves.store(moves, Ordering::SeqCst);
        self
    }

    fn with_observer_location(mut self, latitude: f64, longitude: f64) -> Self {
        self.scripted_observer_location = Some((latitude, longitude));
        self
    }

    /// Stand in for a fully-instrumented rig: every per-frame telemetry
    /// read answers with a distinctive value, so a frame event stamped
    /// from anything other than this rig's own readings is visible.
    fn with_capture_telemetry(mut self) -> Self {
        self.scripted_mount_coordinates = Some((5.5, -5.25));
        self.scripted_pier_side = Some(crate::meridian::PierSide::West);
        self.scripted_cooler_power = Some(63.5);
        self.scripted_focuser_position = Some(31_705);
        self.scripted_focuser_temperature = Some(4.25);
        self.scripted_gain = Some(139);
        self.scripted_offset = Some(21);
        self.scripted_sensor_temp_c = Some(-9.5);
        self.scripted_pixel_size_um = Some((3.76, 3.76));
        self
    }

    /// Park the mount at these coordinates so a completed slew passes
    /// `validate_slew_position` instead of tripping over NullDeviceOps'
    /// fixed answer.
    fn with_scripted_mount_coordinates(mut self, ra_hours: f64, dec_degrees: f64) -> Self {
        self.scripted_mount_coordinates = Some((ra_hours, dec_degrees));
        self
    }

    /// Make every frame measure as `hfr` px with `stars` stars of
    /// `eccentricity`.
    fn with_scripted_frame_metrics(mut self, hfr: f64, stars: usize, eccentricity: f64) -> Self {
        self.scripted_frame_metrics = Some((hfr, stars, eccentricity));
        self
    }

    /// Make `mount_readback_frame` answer `frame` for every target.
    fn with_scripted_readback_frame(mut self, frame: DeviceResult<(f64, f64)>) -> Self {
        self.scripted_readback_frame = Some(frame);
        self
    }

    /// Make the camera report an exposure length of its own choosing.
    fn with_reported_exposure_secs(mut self, secs: f64) -> Self {
        self.scripted_reported_exposure_secs = Some(secs);
        self
    }

    /// The `FrameContext`s handed to `save_fits`, in call order.
    fn saved_frame_contexts(&self) -> Vec<crate::scheduling::FrameContext> {
        self.saved_frame_contexts.lock().unwrap().clone()
    }

    /// The paths `save_fits` was asked to write, in call order.
    fn saved_frame_paths(&self) -> Vec<String> {
        self.saved_frame_paths.lock().unwrap().clone()
    }

    fn with_mount_parked(mut self, parked: bool) -> Self {
        self.mount_parked = parked;
        self
    }

    fn with_mount_is_parked_error(mut self, msg: &str) -> Self {
        self.mount_is_parked_error = Some(msg.to_string());
        self
    }

    fn with_rotator_angles(mut self, angles: Vec<f64>) -> Self {
        self.rotator_angles = Mutex::new(angles);
        self
    }

    fn with_dome_shutter_states(mut self, states: &[&str]) -> Self {
        self.dome_shutter_states = Mutex::new(states.iter().map(|s| (*s).to_string()).collect());
        self
    }

    fn with_dome_close_error(mut self, msg: &str) -> Self {
        self.dome_close_error = Some(msg.to_string());
        self
    }

    /// Stand in for a rig with this dome connected but no dome role in the
    /// sequence context.
    fn with_active_dome_id(mut self, id: &str) -> Self {
        self.active_dome_id = Some(id.to_string());
        self
    }

    fn with_active_cover_calibrator_id(mut self, id: &str) -> Self {
        self.active_cover_calibrator_id = Some(id.to_string());
        self
    }

    /// A guider that accepts `guider_start` and then never reports guiding.
    /// Measured on the owner's rig: PHD2 kept emitting GuideStep frames (so
    /// `is_guiding` answered true for the run's other pollers) while the
    /// offsets sat at RA -56.8 px / Dec -54.4 px and SNR fell 126.7 -> 11.8.
    fn with_guider_resume_that_never_guides(mut self) -> Self {
        self.guider_resume_never_guides = true;
        self
    }

    /// A guider whose `guider_start` returns before it is guiding: the next
    /// `polls` status reads say not guiding, then it locks. PHD2's `guide`
    /// RPC answers at once and the app state only reaches Guiding once a star
    /// is selected and the first guide frames are in.
    fn with_guider_that_locks_after_polls(self, polls: u32) -> Self {
        self.guider_polls_before_lock.store(polls, Ordering::SeqCst);
        self
    }

    /// A solver that finds no solution in any frame.
    fn with_plate_solve_failing(mut self) -> Self {
        self.plate_solve_fails = true;
        self
    }

    /// A guider whose every dither fails with `message`.
    fn with_dither_failing(mut self, message: &str) -> Self {
        self.dither_error = Some(message.to_string());
        self
    }

    /// A guider reporting `rms_total` px of guide error.
    fn with_guider_rms(self, rms_total: f64) -> Self {
        *self.guider_rms_total.lock().unwrap() = rms_total;
        self
    }

    fn with_guiding(self, guiding: bool) -> Self {
        self.guiding.store(guiding, Ordering::SeqCst);
        self
    }

    fn with_mount_slewing_states(mut self, states: Vec<bool>) -> Self {
        self.mount_slewing_states = Mutex::new(states);
        self
    }

    fn with_hanging_camera(mut self) -> Self {
        self.hang_camera_exposure = true;
        self
    }

    /// A sensor that reads `temps` in turn, then stays at the last one.
    fn with_camera_temperatures(self, temps: &[f64]) -> Self {
        self.scripted_camera_temps
            .lock()
            .unwrap()
            .extend(temps.iter().copied());
        self
    }

    /// Stand in for the reference rig on 2026-08-09: the cooler-off
    /// command comes back as an error.
    fn with_failing_cooler_off(mut self, message: &str) -> Self {
        self.cooler_off_error = Some(message.to_string());
        self
    }

    /// Stand in for the operator pressing Pause while frame 1 of a burst
    /// is integrating: the FIRST exposure raises `flag`, later ones don't.
    fn pausing_after_first_exposure(mut self, flag: Arc<AtomicBool>) -> Self {
        self.pause_flag_after_first_exposure = Some(flag);
        self
    }

    fn with_guider_calibration(mut self, calibration: GuidingCalibration) -> Self {
        self.guider_calibration = Some(calibration);
        self
    }

    /// Pop the next scripted value, repeating the final entry forever
    /// once the script runs out (so a "never arrives" script can drive
    /// the timeout path).
    fn next_scripted<T: Clone>(script: &Mutex<Vec<T>>) -> T {
        let mut v = script.lock().unwrap();
        if v.len() > 1 {
            v.remove(0)
        } else {
            v[0].clone()
        }
    }
}

#[async_trait]
impl DeviceOps for ScriptedDomeRotatorOps {
    // Rotator (verified-move surface)
    async fn rotator_move_to(&self, _id: &str, _angle: f64) -> DeviceResult<()> {
        self.rotator_move_to_calls.fetch_add(1, Ordering::SeqCst);
        Ok(())
    }
    async fn rotator_get_angle(&self, _id: &str) -> DeviceResult<f64> {
        self.rotator_get_angle_calls.fetch_add(1, Ordering::SeqCst);
        Ok(Self::next_scripted(&self.rotator_angles))
    }

    // Dome (verified-close surface)
    async fn dome_close(&self, id: &str) -> DeviceResult<()> {
        self.dome_close_calls.fetch_add(1, Ordering::SeqCst);
        if let Some(err) = &self.dome_close_error {
            return Err(err.clone());
        }
        self.inner.dome_close(id).await
    }
    async fn dome_park(&self, _id: &str) -> DeviceResult<()> {
        self.dome_park_calls.fetch_add(1, Ordering::SeqCst);
        Ok(())
    }
    async fn dome_get_shutter_status(&self, _id: &str) -> DeviceResult<String> {
        self.dome_shutter_status_calls
            .fetch_add(1, Ordering::SeqCst);
        Ok(Self::next_scripted(&self.dome_shutter_states))
    }

    // Delegating methods
    async fn mount_slew_to_coordinates(&self, id: &str, ra: f64, dec: f64) -> DeviceResult<()> {
        self.mount_slew_calls.fetch_add(1, Ordering::SeqCst);
        self.inner.mount_slew_to_coordinates(id, ra, dec).await
    }
    async fn mount_abort_slew(&self, id: &str) -> DeviceResult<()> {
        self.inner.mount_abort_slew(id).await
    }
    async fn mount_get_coordinates(&self, id: &str) -> DeviceResult<(f64, f64)> {
        match self.scripted_mount_coordinates {
            Some(coords) => Ok(coords),
            None => self.inner.mount_get_coordinates(id).await,
        }
    }
    async fn mount_readback_frame(
        &self,
        id: &str,
        ra_hours: f64,
        dec_degrees: f64,
    ) -> DeviceResult<(f64, f64)> {
        match &self.scripted_readback_frame {
            Some(frame) => frame.clone(),
            None => {
                self.inner
                    .mount_readback_frame(id, ra_hours, dec_degrees)
                    .await
            }
        }
    }
    async fn mount_sync(&self, id: &str, ra: f64, dec: f64) -> DeviceResult<()> {
        self.inner.mount_sync(id, ra, dec).await
    }
    async fn mount_park(&self, id: &str) -> DeviceResult<()> {
        self.inner.mount_park(id).await
    }
    async fn mount_unpark(&self, id: &str) -> DeviceResult<()> {
        self.mount_unpark_calls.fetch_add(1, Ordering::SeqCst);
        self.inner.mount_unpark(id).await
    }
    async fn mount_is_slewing(&self, id: &str) -> DeviceResult<bool> {
        let _ = id;
        self.mount_slew_state_calls.fetch_add(1, Ordering::SeqCst);
        Ok(Self::next_scripted(&self.mount_slewing_states))
    }
    async fn mount_is_parked(&self, _id: &str) -> DeviceResult<bool> {
        if let Some(err) = &self.mount_is_parked_error {
            return Err(err.clone());
        }
        Ok(self.mount_parked)
    }
    async fn mount_can_flip(&self, id: &str) -> DeviceResult<bool> {
        self.inner.mount_can_flip(id).await
    }
    async fn mount_side_of_pier(&self, id: &str) -> DeviceResult<crate::meridian::PierSide> {
        if let Some(side) = self.scripted_pier_side {
            return Ok(side);
        }
        self.inner.mount_side_of_pier(id).await
    }
    async fn mount_is_tracking(&self, id: &str) -> DeviceResult<bool> {
        self.inner.mount_is_tracking(id).await
    }
    async fn mount_set_tracking(&self, id: &str, enabled: bool) -> DeviceResult<()> {
        self.inner.mount_set_tracking(id, enabled).await
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
        let call = self.camera_exposure_calls.fetch_add(1, Ordering::SeqCst) + 1;
        if call == 1 {
            if let Some(flag) = &self.pause_flag_after_first_exposure {
                flag.store(true, Ordering::SeqCst);
            }
        }
        if self.hang_camera_exposure {
            return std::future::pending::<DeviceResult<ImageData>>().await;
        }
        if let Some(error) = self.camera_failures.lock().unwrap().pop_front() {
            return Err(error);
        }
        // A scripted report decouples what the driver CLAIMS from what was
        // commanded — that split is the whole point — so the double also
        // drops NullDeviceOps' simulated integration sleep. Waiting the
        // commanded minutes in real time would only slow the suite; nothing
        // under test reads the wall clock.
        let simulated_integration = match self.scripted_reported_exposure_secs {
            Some(_) => 0.0,
            None => d,
        };
        let mut image = self
            .inner
            .camera_start_exposure(id, simulated_integration, g, o, bx, by)
            .await?;
        // The camera's own report of the frame, which is a DIFFERENT source
        // from what was commanded. Overriding it here is what lets a test
        // tell the two apart.
        if let Some(secs) = self.scripted_reported_exposure_secs {
            image.exposure_secs = secs;
        }
        if self.scripted_gain.is_some() {
            image.gain = self.scripted_gain;
        }
        if self.scripted_offset.is_some() {
            image.offset = self.scripted_offset;
        }
        if self.scripted_sensor_temp_c.is_some() {
            image.temperature = self.scripted_sensor_temp_c;
        }
        Ok(image)
    }
    async fn camera_abort_exposure(&self, id: &str) -> DeviceResult<()> {
        self.camera_abort_calls.fetch_add(1, Ordering::SeqCst);
        self.inner.camera_abort_exposure(id).await
    }
    async fn camera_set_cooler(&self, id: &str, e: bool, t: f64) -> DeviceResult<()> {
        self.cooler_commands.lock().unwrap().push((e, t));
        if !e {
            if let Some(err) = &self.cooler_off_error {
                return Err(err.clone());
            }
        }
        self.inner.camera_set_cooler(id, e, t).await
    }
    async fn camera_get_temperature(&self, id: &str) -> DeviceResult<f64> {
        {
            let mut temps = self.scripted_camera_temps.lock().unwrap();
            match temps.len() {
                0 => {}
                1 => return Ok(temps[0]),
                _ => return Ok(temps.pop_front().unwrap()),
            }
        }
        self.inner.camera_get_temperature(id).await
    }
    async fn camera_get_cooler_power(&self, id: &str) -> DeviceResult<f64> {
        match self.scripted_cooler_power {
            Some(power) => Ok(power),
            None => self.inner.camera_get_cooler_power(id).await,
        }
    }
    async fn camera_get_pixel_size_um(&self, id: &str) -> DeviceResult<Option<(f64, f64)>> {
        match self.scripted_pixel_size_um {
            Some(pitch) => Ok(Some(pitch)),
            None => self.inner.camera_get_pixel_size_um(id).await,
        }
    }
    /// What the bridge impls return: the driver's name for the connected
    /// camera, with the serial that tells two of the same model apart.
    async fn camera_get_model(&self, _id: &str) -> DeviceResult<Option<String>> {
        Ok(Some("ZWO ASI1600MM-Cool (1600-A1B2)".to_string()))
    }
    async fn focuser_move_to(&self, _id: &str, p: i32) -> DeviceResult<()> {
        self.focuser_moves.lock().unwrap().push(p);
        Ok(())
    }
    async fn focuser_get_position(&self, id: &str) -> DeviceResult<i32> {
        match self.scripted_focuser_position {
            Some(pos) => Ok(pos),
            None => self.inner.focuser_get_position(id).await,
        }
    }
    async fn focuser_is_moving(&self, _id: &str) -> DeviceResult<bool> {
        Ok(false)
    }
    async fn focuser_get_temperature(&self, id: &str) -> DeviceResult<Option<f64>> {
        if self.scripted_focuser_temperature.is_some() {
            return Ok(self.scripted_focuser_temperature);
        }
        self.inner.focuser_get_temperature(id).await
    }
    async fn focuser_halt(&self, _id: &str) -> DeviceResult<()> {
        self.focuser_halt_calls.fetch_add(1, Ordering::SeqCst);
        Ok(())
    }
    async fn filterwheel_set_position(&self, _id: &str, p: i32) -> DeviceResult<()> {
        self.filter_moves.lock().unwrap().push(p);
        if let Some(error) = self.filter_set_failures.lock().unwrap().pop_front() {
            return Err(error);
        }
        let stalled = self
            .filter_stalled_moves
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| n.checked_sub(1))
            .is_ok();
        if !stalled {
            self.filter_position.store(p, Ordering::SeqCst);
        }
        Ok(())
    }
    async fn filterwheel_get_position(&self, _id: &str) -> DeviceResult<i32> {
        Ok(self.filter_position.load(Ordering::SeqCst))
    }
    async fn filterwheel_get_names(&self, _id: &str) -> DeviceResult<Vec<String>> {
        Ok(self.filter_names.clone())
    }
    async fn filterwheel_set_filter_by_name(&self, id: &str, n: &str) -> DeviceResult<i32> {
        self.inner.filterwheel_set_filter_by_name(id, n).await
    }
    async fn rotator_move_relative(&self, id: &str, d: f64) -> DeviceResult<()> {
        self.inner.rotator_move_relative(id, d).await
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
        self.dithers_after_frame
            .lock()
            .unwrap()
            .push(self.camera_exposure_calls.load(Ordering::SeqCst));
        if let Some(message) = &self.dither_error {
            return Err(message.clone());
        }
        self.inner.guider_dither(p, sp, st, sto, ra).await
    }
    async fn guider_get_status(&self) -> DeviceResult<GuidingStatus> {
        let pending = self.guider_polls_before_lock.load(Ordering::SeqCst);
        if pending > 0 {
            self.guider_polls_before_lock
                .store(pending - 1, Ordering::SeqCst);
            if pending == 1 && !self.guider_resume_never_guides {
                self.guiding.store(true, Ordering::SeqCst);
            }
        }
        let rms_total = *self.guider_rms_total.lock().unwrap();
        Ok(GuidingStatus {
            is_guiding: pending == 0 && self.guiding.load(Ordering::SeqCst),
            rms_ra: rms_total / std::f64::consts::SQRT_2,
            rms_dec: rms_total / std::f64::consts::SQRT_2,
            rms_total,
        })
    }
    async fn guider_get_calibration(&self) -> DeviceResult<GuidingCalibration> {
        match &self.guider_calibration {
            Some(calibration) => Ok(calibration.clone()),
            None => self.inner.guider_get_calibration().await,
        }
    }
    async fn guider_start(&self, _sp: f64, _st: f64, _sto: f64) -> DeviceResult<()> {
        self.guider_start_calls.fetch_add(1, Ordering::SeqCst);
        if !self.guider_resume_never_guides
            && self.guider_polls_before_lock.load(Ordering::SeqCst) == 0
        {
            self.guiding.store(true, Ordering::SeqCst);
        }
        Ok(())
    }
    async fn guider_stop(&self) -> DeviceResult<()> {
        self.guider_stop_calls.fetch_add(1, Ordering::SeqCst);
        self.guiding.store(false, Ordering::SeqCst);
        Ok(())
    }
    async fn plate_solve(
        &self,
        d: &ImageData,
        ra: Option<f64>,
        dec: Option<f64>,
        s: Option<f64>,
    ) -> DeviceResult<crate::device_ops::PlateSolveResult> {
        if self.plate_solve_fails {
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
        self.saved_frame_contexts.lock().unwrap().push(ctx.clone());
        self.saved_frame_paths.lock().unwrap().push(f.to_string());
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
        self.scripted_observer_location
    }
    async fn polar_align_update(
        &self,
        r: &crate::polar_align::PolarAlignResult,
    ) -> DeviceResult<()> {
        self.inner.polar_align_update(r).await
    }
    async fn dome_open(&self, id: &str) -> DeviceResult<()> {
        self.dome_open_ids.lock().unwrap().push(id.to_string());
        self.inner.dome_open(id).await
    }
    async fn active_dome_id(&self) -> Option<String> {
        self.active_dome_id_calls.fetch_add(1, Ordering::SeqCst);
        self.active_dome_id.clone()
    }
    async fn active_cover_calibrator_id(&self) -> Option<String> {
        self.active_cover_calibrator_id.clone()
    }
    async fn safety_is_safe(&self, id: Option<&str>) -> DeviceResult<bool> {
        self.inner.safety_is_safe(id).await
    }
    async fn calculate_image_hfr(&self, d: &ImageData) -> DeviceResult<Option<f64>> {
        match self.scripted_frame_metrics {
            Some((hfr, _, _)) => Ok(Some(hfr)),
            None => self.inner.calculate_image_hfr(d).await,
        }
    }
    async fn detect_stars_in_image(&self, d: &ImageData) -> DeviceResult<Vec<(f64, f64, f64)>> {
        match self.scripted_frame_metrics {
            Some((hfr, stars, _)) => Ok((0..stars).map(|i| (i as f64, i as f64, hfr)).collect()),
            None => self.inner.detect_stars_in_image(d).await,
        }
    }
    async fn measure_frame_eccentricity(&self, d: &ImageData) -> DeviceResult<Option<f64>> {
        match self.scripted_frame_metrics {
            Some((_, _, eccentricity)) => Ok(Some(eccentricity)),
            None => self.inner.measure_frame_eccentricity(d).await,
        }
    }
    async fn cover_calibrator_open_cover(&self, id: &str) -> DeviceResult<()> {
        self.cover_open_ids.lock().unwrap().push(id.to_string());
        self.inner.cover_calibrator_open_cover(id).await
    }
    async fn cover_calibrator_close_cover(&self, id: &str) -> DeviceResult<()> {
        self.inner.cover_calibrator_close_cover(id).await
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

/// Build an InstructionContext wired to the given scripted ops with a
/// dome + rotator attached.
async fn ctx_with_ops(ops: Arc<ScriptedDomeRotatorOps>) -> InstructionContext {
    let mut ec = crate::node::context::ExecutionContext::new_for_test("test-node".to_string());
    ec.device_ops = ops;
    ec.camera_id = Some("camera-1".to_string());
    ec.focuser_id = Some("focuser-1".to_string());
    ec.filterwheel_id = Some("filterwheel-1".to_string());
    ec.dome_id = Some("dome-1".to_string());
    ec.rotator_id = Some("rotator-1".to_string());
    ec.to_instruction_context("test-node").await
}

// Native daylight gate
//
// The "no daylight imaging" invariant is enforced structurally in
// execute_slew / execute_exposure, not only in scheduler_engine.dart: a raw
// sequence started via api_sequencer_start (a mosaic included) would
// otherwise slew and expose LIGHT frames in full daylight. These tests pin
// the native gate.
//
// Determinism: the Sun's real altitude depends on wall-clock + location,
// which cannot be pinned here without a MockClock on the instruction layer.
// Instead these compute the live Sun altitude for a fixed observer and then
// drive the CONFIGURED threshold relative to it — `sun_alt - delta` is
// guaranteed "Sun up" (above max) and `sun_alt + delta` is guaranteed
// "Sun down" (below max), regardless of the date/time the test runs.

/// Fixed observer for the gate tests — a mid-northern-latitude site so the
/// Sun-altitude math is well-conditioned (away from the polar edge cases).
const TEST_LAT: f64 = 40.0;

const TEST_LON: f64 = -74.0;

fn live_sun_alt() -> f64 {
    crate::node::context::current_sun_altitude_degrees(TEST_LAT, TEST_LON)
}

fn is_daylight_block(result: &InstructionResult) -> bool {
    result.status == NodeStatus::Failure
        && result
            .message
            .as_deref()
            .is_some_and(|m| m.contains("Daylight gate"))
}

// execute_slew gate

async fn slew_ctx(max_sun_alt: f64) -> InstructionContext {
    let mut ec = crate::node::context::ExecutionContext::new_for_test("test-node".to_string());
    ec.device_ops = Arc::new(NullDeviceOps);
    ec.mount_id = Some("mount-1".to_string());
    ec.latitude = Some(TEST_LAT);
    ec.longitude = Some(TEST_LON);
    ec.target_ra = Some(5.5);
    ec.target_dec = Some(22.0);
    ec.max_sun_altitude_degrees = max_sun_alt;
    // The gate reads the configured max through the InstructionContext's
    // trigger-state handle (exactly as the live executor seeds it). Install
    // a trigger state so the test exercises that same resolution path.
    let mut ts = crate::triggers::TriggerState::new();
    ts.set_max_sun_altitude_degrees(max_sun_alt);
    ec.trigger_state = Some(std::sync::Arc::new(tokio::sync::RwLock::new(ts)));
    ec.to_instruction_context("test-node").await
}

// unset-target pointing gate
//
// A TargetHeader dragged in from the palette carries RA 0h / Dec +0° until
// the operator picks a target. Dart's TargetCoordinatesUnsetRule blocks
// that on the GUI start path only; the headless REST start, a raw
// sequencer_load_json and every checkpoint resume reach the executor
// without it. These tests pin the gate at the two nodes that command the
// mount, which is what makes it hold for all of those entry points.

/// The recovery code `failure_with_recovery` stashed in `data`, if any.
fn recovery_code_of(result: &InstructionResult) -> Option<String> {
    result
        .data
        .as_ref()?
        .get("recovery_code")?
        .as_str()
        .map(str::to_string)
}

/// Context whose pointing comes from a TargetHeader with `target`
/// coordinates, wired to `ops` so the tests can prove whether the mount was
/// commanded. The Sun threshold is set above the live Sun so the daylight
/// gate cannot be what produced a rejection.
async fn pointing_ctx(
    ops: Arc<ScriptedDomeRotatorOps>,
    target_name: &str,
    target: (f64, f64),
) -> InstructionContext {
    let max_sun_alt = live_sun_alt() + 5.0;
    let mut ec = crate::node::context::ExecutionContext::new_for_test("test-node".to_string());
    ec.device_ops = ops;
    ec.mount_id = Some("mount-1".to_string());
    ec.camera_id = Some("cam-1".to_string());
    ec.latitude = Some(TEST_LAT);
    ec.longitude = Some(TEST_LON);
    ec.target_name = Some(target_name.to_string());
    ec.target_ra = Some(target.0);
    ec.target_dec = Some(target.1);
    ec.max_sun_altitude_degrees = max_sun_alt;
    let mut ts = crate::triggers::TriggerState::new();
    ts.set_max_sun_altitude_degrees(max_sun_alt);
    ec.trigger_state = Some(std::sync::Arc::new(tokio::sync::RwLock::new(ts)));
    ec.to_instruction_context("test-node").await
}

// execute_exposure gate

async fn expose_ctx(
    ops: Arc<dyn DeviceOps>,
    target: Option<(f64, f64)>,
    max_sun_alt: f64,
) -> InstructionContext {
    let mut ec = crate::node::context::ExecutionContext::new_for_test("test-node".to_string());
    ec.device_ops = ops;
    ec.camera_id = Some("cam-1".to_string());
    ec.mount_id = Some("mount-1".to_string());
    ec.latitude = Some(TEST_LAT);
    ec.longitude = Some(TEST_LON);
    if let Some((ra, dec)) = target {
        ec.target_ra = Some(ra);
        ec.target_dec = Some(dec);
    }
    ec.max_sun_altitude_degrees = max_sun_alt;
    let mut ts = crate::triggers::TriggerState::new();
    ts.set_max_sun_altitude_degrees(max_sun_alt);
    ec.trigger_state = Some(std::sync::Arc::new(tokio::sync::RwLock::new(ts)));
    ec.to_instruction_context("test-node").await
}

fn one_light() -> ExposureConfig {
    ExposureConfig {
        duration_secs: 0.01,
        count: 1,
        ..ExposureConfig::default()
    }
}

/// A scratch capture folder that removes itself even when a test panics.
struct ScratchDir(std::path::PathBuf);

impl Drop for ScratchDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn scratch_dir(tag: &str) -> ScratchDir {
    let dir = std::env::temp_dir().join(format!("ns-{}-{}", tag, uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&dir).expect("scratch dir");
    ScratchDir(dir)
}

/// An `InstructionContext` wired the way a real burst is: a resolvable save
/// folder plus every device id, so `build_frame_context_for_save` actually
/// performs its telemetry reads instead of skipping them.
async fn saving_expose_ctx(
    ops: Arc<dyn DeviceOps>,
    save_path: std::path::PathBuf,
    event_tx: tokio::sync::broadcast::Sender<crate::executor::ExecutorEvent>,
) -> InstructionContext {
    let mut ec = crate::node::context::ExecutionContext::new_for_test("expose-node".to_string());
    ec.device_ops = ops;
    ec.camera_id = Some("cam-1".to_string());
    ec.mount_id = Some("mount-1".to_string());
    ec.focuser_id = Some("foc-1".to_string());
    ec.rotator_id = Some("rot-1".to_string());
    ec.save_path = Some(save_path);
    ec.latitude = Some(TEST_LAT);
    ec.longitude = Some(TEST_LON);
    ec.event_tx = Some(event_tx);
    ec.to_instruction_context("expose-node").await
}

/// The same rig as [`saving_expose_ctx`] but returned as the
/// `ExecutionContext` the node runtime actually hands an instruction, plus
/// a connected filter wheel. Tests that need to prove the NODE (not just
/// `execute_exposure`) does something must start here — the save-path
/// renderer is built inside `ExposeInstruction::execute` and never exists
/// on the `execute_exposure` path a hand-built `InstructionContext` takes.
async fn expose_node_execution_ctx(
    ops: Arc<dyn DeviceOps>,
    save_path: std::path::PathBuf,
) -> crate::node::context::ExecutionContext {
    let mut ec = crate::node::context::ExecutionContext::new_for_test("expose-node".to_string());
    ec.device_ops = ops;
    ec.camera_id = Some("cam-1".to_string());
    ec.focuser_id = Some("foc-1".to_string());
    ec.rotator_id = Some("rot-1".to_string());
    ec.filterwheel_id = Some("fw-1".to_string());
    ec.save_path = Some(save_path);
    ec.latitude = Some(TEST_LAT);
    ec.longitude = Some(TEST_LON);
    ec
}

/// Run a Take Exposures node exactly the way `RuntimeNode` does.
async fn run_expose_node(
    config: ExposureConfig,
    ec: &mut crate::node::context::ExecutionContext,
) -> NodeStatus {
    let node_type = NodeType::TakeExposure(config);
    crate::node::instructions::expose::ExposeInstruction
        .execute("expose-node", &node_type, ec)
        .await
}

/// A Take Exposures node with no filter of its own — the shape that
/// produced `untargeted_nofilter_0001.fits` with no FILTER card on a rig
/// whose wheel was sitting on a known, named slot.
fn one_dark_no_filter() -> ExposureConfig {
    ExposureConfig {
        duration_secs: 0.01,
        count: 1,
        frame_type: "Dark".to_string(),
        filter: None,
        filter_index: None,
        ..ExposureConfig::default()
    }
}

/// The rig of [`expose_node_execution_ctx`] collapsed to the
/// `InstructionContext` that the callers who never build a node hand
/// `execute_exposure` — the Flat Wizard and the bridge one-shots.
async fn direct_capture_ctx(
    ops: Arc<dyn DeviceOps>,
    save_path: std::path::PathBuf,
) -> InstructionContext {
    let mut ec = crate::node::context::ExecutionContext::new_for_test("direct".to_string());
    ec.device_ops = ops;
    ec.camera_id = Some("cam-1".to_string());
    ec.focuser_id = Some("foc-1".to_string());
    ec.rotator_id = Some("rot-1".to_string());
    ec.filterwheel_id = Some("fw-1".to_string());
    ec.save_path = Some(save_path);
    ec.latitude = Some(TEST_LAT);
    ec.longitude = Some(TEST_LON);
    ec.to_instruction_context("direct").await
}

/// A calibration burst: the daylight gate never applies, so the test runs
/// at any wall-clock hour, and no grader touches the frame.
fn one_dark(count: u32) -> ExposureConfig {
    ExposureConfig {
        duration_secs: 0.01,
        count,
        frame_type: "Dark".to_string(),
        gain: Some(1),
        offset: Some(2),
        binning: Binning::Two,
        ..ExposureConfig::default()
    }
}

/// Drain the frame events a burst emitted, newest last.
fn drain_frame_captures(
    rx: &mut tokio::sync::broadcast::Receiver<crate::executor::ExecutorEvent>,
) -> Vec<crate::scheduling::FrameCaptureMetadata> {
    let mut out = Vec::new();
    while let Ok(event) = rx.try_recv() {
        if let crate::executor::ExecutorEvent::NodeProgress {
            structured_detail: Some(detail),
            ..
        } = event
        {
            match *detail {
                crate::node::ProgressDetail::FrameAccepted { capture, .. }
                | crate::node::ProgressDetail::FrameRejected { capture, .. } => out.push(capture),
                _ => {}
            }
        }
    }
    out
}

// A script that outruns its timeout must (a) return the
// exact "Script timed out ..." failure and (b) leave no live child
// process behind (kill_on_drop reaps it).

#[cfg(target_os = "linux")]
async fn script_ctx() -> InstructionContext {
    crate::node::context::ExecutionContext::new_for_test("test-node".to_string())
        .to_instruction_context("test-node")
        .await
}

#[cfg(target_os = "linux")]
fn empty_frame() -> crate::expressions::EvaluationFrame {
    crate::expressions::EvaluationFrame::empty()
}

/// True while `pid` is a live, schedulable process. A child that has
/// been killed and reaped is gone (no `/proc/<pid>`); one that was
/// killed but not yet reaped shows up as a zombie (`State: Z`), which
/// for our purposes is "not running". Linux-only because it reads
/// `/proc`; that matches where this crate's process tests run.
#[cfg(target_os = "linux")]
fn pid_is_running(pid: u32) -> bool {
    match std::fs::read_to_string(format!("/proc/{pid}/stat")) {
        // /proc/<pid>/stat is "pid (comm) state ...". The state char
        // after the closing paren is 'Z' for a reaped-pending zombie.
        Ok(stat) => match stat.rsplit_once(") ") {
            Some((_, rest)) => !rest.starts_with('Z'),
            None => true,
        },
        Err(_) => false,
    }
}

mod autofocus;
mod center;
mod cooling;
mod daylight_gate;
mod device_retry;
mod disconnect;
mod dome;
mod expose;
mod filter_identity;
mod focuser_backlash;
mod frame_metadata;
mod grading;
mod guiding;
mod meridian_gate;
mod park;
mod pointing_gate;
mod rotator;
mod save_path;
// Every test in `script` spawns a real /bin/sh, so the whole file is
// Linux-only; without this the module's `use super::*` is an unused import on
// Windows and `-D warnings` fails the build there.
#[cfg(target_os = "linux")]
mod script;
mod slew;
mod wait_time;
