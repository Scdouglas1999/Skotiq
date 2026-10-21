//! [`TriggerState`] — the observed-condition snapshot trigger evaluation reads.

use super::{CAMERA_BUSY_DOWNLOAD_SLACK_SECS, IMAGING_TRAIN_CLAIM_OVERRUN_GRACE_SECS};
use crate::PierSide;
use chrono::Utc;
use std::time::Instant;

/// An exclusive claim on the IMAGING TRAIN: the main camera and the filter
/// wheel, arbitrated as one resource.
///
/// The two devices are one claim because every operation that contends for
/// them takes both. The capture loop sets a filter and then exposes through it;
/// a trigger-fired autofocus sets its own filter and then exposes through that;
/// a meridian flip re-solves and restores the filter. Arbitrating the camera
/// alone is what produced the 2026-09-14 failure: the autofocus trigger held
/// the camera and commanded the wheel to "L" (position 0), the capture loop —
/// blocked on the camera but having already commanded the wheel for its own
/// frame — left it at "SII" (position 5), and autofocus then polled a healthy,
/// idle, responsive wheel for 120 s waiting for a position nothing was going to
/// move it to. The wheel was never broken; the arbitration was.
///
/// Borrowing is allowed and expected — an autofocus needs the wheel mid-burst —
/// but a holder that moves the wheel MUST put it back before releasing, because
/// the capture loop sets its filter once per burst and expects it to still be
/// there for the next frame. `execute_autofocus_once` does this; so does the
/// meridian-flip executor.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImagingTrainClaim {
    /// Identity of this claim. A release only takes effect if it presents the
    /// token that is currently installed, so a late or duplicated release
    /// cannot free somebody else's claim — which would destroy exactly the
    /// frame the claim exists to protect.
    pub token: u64,
    /// Operator-facing name of the holder ("the capture loop", "autofocus"),
    /// used in the hold messages a waiter logs.
    pub holder: &'static str,
    /// When the holder expects to be done, as Unix millis. This is the number a
    /// waiter reads to size its wait and its own device timeouts; it is NOT
    /// when the claim lapses.
    pub expected_finish_ms: i64,
    /// When the claim lapses regardless, as Unix millis: `expected_finish_ms`
    /// plus [`IMAGING_TRAIN_CLAIM_OVERRUN_GRACE_SECS`]. Only the backstop for a
    /// holder that died without releasing — see that constant for why it is not
    /// the same instant as the expected finish.
    pub expires_at_ms: i64,
}

/// What a waiter learns about a claim it could not take.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ImagingTrainHold {
    /// Operator-facing name of the current holder.
    pub holder: &'static str,
    /// Seconds until the holder expects to be finished. Zero once that instant
    /// has passed but the claim has not yet been released — the holder is
    /// overrunning its estimate, which is precisely when the token must NOT
    /// change hands.
    pub expected_remaining_secs: f64,
    /// Seconds until the claim lapses on its own. This is the bound on how long
    /// a wait for this claim can last, derived from the in-flight operation
    /// rather than fixed.
    pub max_remaining_secs: f64,
}

pub(super) fn looks_like_tracking_limit_hit(state: &TriggerState) -> bool {
    if !state.mount_tracking_expected || !state.mount_tracking_lost {
        return false;
    }

    if state.mount_status_query_failed {
        tracing::debug!("Tracking lost but status query failed - not a limit hit");
        return false;
    }

    if !matches!(state.mount_is_tracking, Some(false) | None) {
        tracing::debug!(
            "Tracking lost heuristic rejected because tracking state is {:?}",
            state.mount_is_tracking
        );
        return false;
    }

    let not_slewing = matches!(state.mount_slewing, Some(false) | None);
    let not_parked = matches!(state.mount_parked, Some(false) | None);
    if !not_slewing || !not_parked {
        tracing::debug!(
            "Tracking lost but mount is slewing={:?} parked={:?} - not a limit hit",
            state.mount_slewing,
            state.mount_parked
        );
        return false;
    }

    let now = Utc::now().timestamp();
    if let Some(limit_time) = state.mount_tracking_limit_time {
        if limit_time <= now + 60 {
            return !matches!(state.pier_side, Some(PierSide::East));
        }
    }

    // Same window as the flip trigger itself, minus the threshold: a mount
    // that stopped tracking BEFORE its target transited did not hit a
    // meridian-side tracking limit, whatever else went wrong.
    let past_meridian = match state.current_hour_angle {
        Some(ha) => super::on_pre_flip_side(ha, state.pier_side),
        None => false,
    };
    if !past_meridian {
        tracing::debug!(
            "Tracking lost but HA={:?} / pier {:?} is not the pre-flip side past the \
             meridian - not a limit hit",
            state.current_hour_angle,
            state.pier_side
        );
    }
    past_meridian
}

/// State information used by triggers
#[derive(Debug, Clone)]
pub struct TriggerState {
    // HFR tracking
    pub baseline_hfr: Option<f64>,
    pub current_hfr: Option<f64>,
    /// monotonically increments each time a NEW frame's HFR is recorded
    /// via `update_hfr`. The HfrDegraded trigger gates its consecutive-bad-frame
    /// counter on a change here so it counts frames, not ~1Hz monitor ticks.
    pub hfr_sample_seq: u64,
    pub autofocus_invalidated: bool,
    pub autofocus_invalidation_reason: Option<String>,

    // Meridian flip - enhanced fields
    /// Hour angle of the ACTIVE TARGET in hours, signed and normalized to
    /// `[-12, +12]`: negative is east of the meridian (not yet transited),
    /// positive is west of it.
    ///
    /// Written by the executor's monitor loop from the target's own RA and the
    /// observer longitude — never from the mount's reported pointing. Those two
    /// are the same number only while the mount is actually tracking the
    /// target, and the gap between them is not a rounding difference: a mount
    /// parked at its home position (RA 0h on every simulator, and on plenty of
    /// drivers) reads whatever the local sidereal time happens to be, so a run
    /// whose first target was 1.5h EAST of the meridian was flipped 1.5 ms
    /// after it started, before the first slew, on the strength of the parked
    /// mount's +2.6h. The trigger is about the target's transit; the target's
    /// own coordinates are the only honest input to it.
    pub current_hour_angle: Option<f64>,
    /// Current pier side of the mount
    pub pier_side: Option<PierSide>,
    /// Unix timestamp when mount will hit its tracking limit (if reported by mount)
    pub mount_tracking_limit_time: Option<i64>,
    /// Whether we've already flipped for the current target (prevents double-flip)
    pub has_flipped_this_target: bool,
    /// The operator asked the running sequence to flip now rather than wait
    /// for the configured window. The meridian trigger fires on the next tick
    /// while [`TriggerState::manual_flip_refusal`] has no objection, and the
    /// flip action clears it when its turn comes. See `manual_flip.rs`.
    pub meridian_flip_requested: bool,
    /// Target name for the current meridian flip tracking
    pub current_target_name: Option<String>,
    /// Legacy field - Unix timestamp for flip (deprecated, use current_hour_angle instead)
    pub next_meridian_flip_time: Option<i64>,
    /// Threshold (minutes past meridian) of the active MinutesPastMeridian
    /// flip trigger, propagated by [`TriggerManager::sync_state_from_config`]
    /// on every evaluation tick. The exposure instruction's pre-frame
    /// meridian gate reads this to hold frames that would still be exposing
    /// when the flip fires. None when no MinutesPastMeridian flip trigger
    /// is enabled (other trigger methods are not predictable in advance).
    pub meridian_flip_minutes_past: Option<f64>,

    /// The live exclusive claim on the imaging train, or `None` when it is
    /// free. See [`ImagingTrainClaim`].
    pub imaging_train_claim: Option<ImagingTrainClaim>,

    /// Monotonic counter behind [`ImagingTrainClaim::token`]. Never reused
    /// within a process, so a stale guard can never release a claim that has
    /// since been taken by someone else.
    pub(super) imaging_train_next_token: u64,

    /// Consecutive failed dithers. A single failure is noise; a run of them
    /// means guiding has stopped, which the operator should hear about even
    /// though it does not justify ending the night.
    pub consecutive_dither_failures: u32,

    // Guiding
    pub guiding_rms_history: Option<Vec<(Instant, f64)>>,
    pub guiding_enabled: bool,
    /// Whether the guide star has been lost (guider reports no star / lost lock)
    pub guide_star_lost: bool,
    /// The guide-star recovery ran out without getting a star back and the
    /// run carries on unguided (owner decision 2026-10-06: a lost guide star
    /// is not a reason to end the night unless the operator turned on "Stop
    /// the run for quality problems"). While set, dithers are skipped, a guider
    /// that cannot start does not fail the step that asked for it, and the
    /// guiding RMS is not judged. Cleared when the guider is seen guiding
    /// again.
    pub imaging_unguided: bool,
    /// How many mount moves the run itself is making (slew, center, sync,
    /// flip). While non-zero the guide star leaving the guide frame is what a
    /// move does, so the guiding triggers neither see a lost star nor take RMS
    /// samples, and the recovery leaves tracking alone. A count, because a
    /// Center slews inside its own move.
    pub mount_motion_depth: u32,
    /// A move stopped the guiding this run had started. The next light frame
    /// starts it again on a fresh star first; a StartGuiding or StopGuiding
    /// before then settles it instead.
    pub guiding_resume_pending: bool,
    /// Filter focus offset (steps) currently embodied in the focuser position,
    /// relative to the reference filter. Filter offsets are reference-relative
    /// deltas; a filter change moves the focuser by
    /// `(offset_new - last_applied_filter_offset)` so offsets do not stack and
    /// walk focus off across an LRGB/SHO night. `0` means the focuser is at the
    /// reference-filter focus (the initial state and after selecting the
    /// reference filter).
    pub last_applied_filter_offset: i32,
    /// configurable retention window (seconds) for
    /// `guiding_rms_history`. Set by the trigger evaluator from the
    /// `GuidingFailed` trigger configuration so a user-tuned value is
    /// honoured. Defaults to 300s (5 minutes), matching the previous
    /// hardcoded behaviour.
    pub guiding_rms_retention_secs: u64,
    /// pier side recorded at the moment a flip was marked
    /// performed, so a subsequent observable return to that side can clear
    /// `has_flipped_this_target`. `None` means no flip has been recorded yet
    /// for the current target.
    pub flip_origin_pier_side: Option<PierSide>,

    // Humidity
    /// Current humidity percentage (0-100)
    pub current_humidity: Option<f64>,

    // Altitude
    pub current_altitude: Option<f64>,

    // Weather
    /// Hardware safety-monitor verdict: `true` when the connected safety/weather
    /// device reports safe (or, under `WarnOnly`, the last good reading). Fed by
    /// the executor's safety poll (`executor/mod.rs` `safety_is_safe`).
    pub weather_safe: bool,
    /// Defense-in-depth: the Dart-side `weatherSafetyProvider` overall verdict,
    /// composed from the user's configured thresholds + API/cloud sources (which
    /// the hardware `weather_safe` poll knows nothing about). `Some(true)` means
    /// the Dart side computed UNSAFE; `Some(false)` means it computed SAFE;
    /// `None` means the Dart side has not reported (e.g. provider disabled / no
    /// data) and this layer abstains. Folded into the `WeatherUnsafe` trigger as
    /// an ADDITIONAL unsafe source — it can only make the rig safer, never less
    /// safe than the hardware verdict ("fail closed"). Pushed via
    /// `ExecutorCommand::UpdateWeatherVerdict`.
    pub weather_verdict_unsafe: Option<bool>,
    /// The monotonic timestamp of the most recent `update_weather_verdict`
    /// push. `None` until the Dart side has pushed at least once.
    ///
    /// A pushed `Some(true)` (UNSAFE) verdict is FAIL-CLOSED: a silent Dart feed
    /// does NOT auto-clear it, because holding the sequence paused is the safe
    /// behaviour. An INDEFINITE hold must not be SILENT, though, so the safety
    /// poll loop uses this timestamp to detect a stale-AND-unsafe verdict and
    /// emit a loud warning: the operator learns the hold is sustained by a dead
    /// feed rather than fresh data. It is NEVER used to resume.
    pub weather_verdict_last_update: Option<Instant>,

    // Temperature
    pub baseline_temperature: Option<f64>,
    pub current_temperature: Option<f64>,
    pub baseline_focuser_position: Option<i32>,

    // Filter
    pub filter_changed: bool,
    pub current_filter: Option<String>,

    // Dawn (astronomical twilight timestamp)
    pub dawn_time: Option<i64>,
    pub observer_latitude: Option<f64>,
    pub observer_longitude: Option<f64>,

    /// The maximum Sun altitude (degrees above the horizon) at which an on-sky
    /// LIGHT capture is allowed, carried here so the native daylight gate in
    /// `instructions::execute_slew` / `execute_exposure` can read it through the
    /// shared trigger state. The executor seeds it from
    /// `RuntimeConfig::max_sun_altitude_degrees`, which the Dart side pushes from
    /// `SchedulerConfig.maxSunAltitudeDegrees` via
    /// [`crate::executor::ExecutorCommand::UpdateMaxSunAltitude`]. `None` until
    /// seeded; the gate then falls back to
    /// [`crate::instructions::DEFAULT_MAX_SUN_ALTITUDE_DEGREES`] (-12°). This
    /// value is not itself a trigger — it carries config to the instruction-layer
    /// gate.
    pub max_sun_altitude_degrees: Option<f64>,

    /// The operator's "Stop the run for quality problems" setting, carried
    /// here so the trigger monitor and the instructions read one value.
    ///
    /// Off by default (owner decision 2026-10-06: only a risk to the hardware
    /// stops a run by itself). Off, a judgment the software makes about the
    /// frames, the guiding or the pointing — guiding RMS over the limit, a
    /// Center that did not converge, a dither that did not settle, a post-flip
    /// recenter or guiding check that failed — notifies the operator and the
    /// run keeps imaging. On, each of those stops the run the way it used to.
    /// Configuration, not run state: `reset_for_new_run` leaves it alone.
    pub stop_on_quality_problems: bool,

    // Frame counting for periodic triggers
    pub completed_exposures: u32,
    pub last_autofocus_frame: u32,
    pub last_dither_frame: u32,

    // Plate solve tracking for drift detection
    pub last_plate_solve_ra: Option<f64>,  // RA in degrees
    pub last_plate_solve_dec: Option<f64>, // Dec in degrees
    pub last_plate_solve_pixel_scale: Option<f64>, // arcsec per pixel
    pub target_ra: Option<f64>,            // Target RA in degrees
    pub target_dec: Option<f64>,           // Target Dec in degrees

    // Mount tracking
    pub mount_is_tracking: Option<bool>,
    pub mount_tracking_expected: bool,
    pub mount_tracking_lost: bool,
    /// Whether the mount is currently slewing (from status polling)
    pub mount_slewing: Option<bool>,
    /// Whether the mount is currently parked (from status polling)
    pub mount_parked: Option<bool>,
    /// Set to true when the most recent mount status query failed (connection lost / error).
    /// Defaults to false (no failure). The tracking-limit heuristic requires this to be false.
    pub mount_status_query_failed: bool,
    /// Unix timestamp when tracking limit was first detected (for wait-before-flip)
    pub tracking_limit_detected_at: Option<i64>,
    /// The active meridian trigger method (so MountTrackingLost can defer to OnTrackingLimitHit)
    pub meridian_trigger_method: Option<crate::MeridianTriggerMethod>,

    // Dome status
    pub dome_shutter_status: Option<String>,
    pub dome_shutter_open_expected: bool,

    // Grid dither tracking
    /// Current position index in the NxN grid dither pattern (0-based).
    /// Incremented after each dither, wraps around to 0 after grid_size*grid_size.
    pub grid_dither_index: u32,

    // Cloud-motion telemetry.
    //
    // Fed by `ExecutorCommand::UpdateCloudMotion` which the Dart side
    // pushes from the live `cloudMotionAnalyzerProvider` (currently every
    // 60 seconds). All fields are `Option` because the analyzer may not
    // yet have enough radar history; an absent field disables the
    // corresponding trigger evaluation rather than firing spuriously.
    /// Current cloud coverage percentage (0-100). Source: Dart
    /// `cloudCoverPercentageProvider` (Open-Meteo) merged with analyzer.
    pub current_cloud_coverage_percent: Option<f64>,
    /// Predicted minutes until significant clouds reach the user location.
    /// `Some(n)` when the analyzer reports an approaching cloud bank;
    /// `None` when clouds are absent, stationary, or moving away.
    pub predicted_cloud_arrival_minutes: Option<f64>,
    /// Predicted minutes until a clear opening (gap in the cloud field)
    /// reaches the user. `Some(n)` while currently overcast and a hole
    /// is approaching; `None` when no opening is predicted.
    pub predicted_cloud_opening_minutes: Option<f64>,
    /// Predicted opening duration in seconds. Pairs with
    /// `predicted_cloud_opening_minutes`; the `CloudOpeningIn` trigger
    /// rejects openings shorter than the user's `minimum_duration_secs`.
    pub predicted_cloud_opening_duration_secs: Option<f64>,
    /// (alt, az) of a clear-sky direction reported by the analyzer. Used
    /// by `RecoveryAction::SlewToGapAndContinue` to choose where to
    /// re-point. `None` => no usable gap; the recovery action falls
    /// back to `PauseAndWaitForClear`.
    pub predicted_clear_sky_direction: Option<(f64, f64)>,
    /// Most recent timestamp at which we received a cloud-motion update.
    /// Surfaced to the run dashboard so the operator can tell whether the
    /// telemetry is fresh; also used by validation to flag stale data.
    pub cloud_motion_last_update: Option<Instant>,

    // Science — Sky transparency telemetry.
    //
    // Fed by `ExecutorCommand::UpdateTransparency` which the Dart science
    // pipeline pushes whenever the transparency sampler produces a new
    // reading. `None` until the science pipeline has a first sample;
    // `Some(fraction)` carries the live 0.0..=1.0 transparency reading.
    /// Live transparency reading (0.0..=1.0; 1.0 = clear). Consumed by
    /// `TransparencyDropped`.
    pub current_transparency: Option<f64>,
    /// Most recent timestamp at which we received a transparency update.
    /// Surfaced to the run dashboard for staleness checks.
    pub transparency_last_update: Option<Instant>,

    /// Set by [`crate::checkpoint::TriggerStateSnapshot::restore_into`] and
    /// consumed by [`Self::reset_for_new_run`]. A resumed run re-enters its
    /// tree with the already-completed `TargetHeader` short-circuited, so its
    /// restored target must survive the run-start reset; a fresh run's must
    /// not.
    pub restored_from_checkpoint: bool,
}

impl Default for TriggerState {
    fn default() -> Self {
        Self {
            baseline_hfr: None,
            current_hfr: None,
            hfr_sample_seq: 0,
            autofocus_invalidated: false,
            autofocus_invalidation_reason: None,
            current_hour_angle: None,
            pier_side: None,
            mount_tracking_limit_time: None,
            has_flipped_this_target: false,
            meridian_flip_requested: false,
            current_target_name: None,
            next_meridian_flip_time: None,
            meridian_flip_minutes_past: None,
            imaging_train_claim: None,
            imaging_train_next_token: 0,
            consecutive_dither_failures: 0,
            guiding_rms_history: None,
            guiding_enabled: false,
            guide_star_lost: false,
            imaging_unguided: false,
            mount_motion_depth: 0,
            guiding_resume_pending: false,
            last_applied_filter_offset: 0,
            // 300s preserves the previous hardcoded retention so
            // un-configured triggers behave exactly as before.
            guiding_rms_retention_secs: 300,
            flip_origin_pier_side: None,
            current_humidity: None,
            current_altitude: None,
            weather_safe: false,
            weather_verdict_unsafe: None,
            weather_verdict_last_update: None,
            baseline_temperature: None,
            current_temperature: None,
            baseline_focuser_position: None,
            filter_changed: false,
            current_filter: None,
            dawn_time: None,
            observer_latitude: None,
            observer_longitude: None,
            // W1 native daylight gate — None until the executor seeds it from
            // RuntimeConfig; the instruction-layer gate falls back to the
            // default constant when unset.
            max_sun_altitude_degrees: None,
            stop_on_quality_problems: false,
            completed_exposures: 0,
            last_autofocus_frame: 0,
            last_dither_frame: 0,
            last_plate_solve_ra: None,
            last_plate_solve_dec: None,
            last_plate_solve_pixel_scale: None,
            target_ra: None,
            target_dec: None,
            mount_is_tracking: None,
            mount_tracking_expected: false,
            mount_tracking_lost: false,
            mount_slewing: None,
            mount_parked: None,
            mount_status_query_failed: false,
            tracking_limit_detected_at: None,
            meridian_trigger_method: None,
            dome_shutter_status: None,
            dome_shutter_open_expected: false,
            grid_dither_index: 0,
            // cloud-motion telemetry. All None until Dart
            // pushes the first `UpdateCloudMotion`.
            current_cloud_coverage_percent: None,
            predicted_cloud_arrival_minutes: None,
            predicted_cloud_opening_minutes: None,
            predicted_cloud_opening_duration_secs: None,
            predicted_clear_sky_direction: None,
            cloud_motion_last_update: None,
            // Science — transparency telemetry. Both None until the
            // Dart science pipeline pushes the first `UpdateTransparency`.
            current_transparency: None,
            transparency_last_update: None,
            restored_from_checkpoint: false,
        }
    }
}

impl TriggerState {
    pub fn new() -> Self {
        Self {
            weather_safe: false,
            guiding_enabled: false,
            ..Default::default()
        }
    }

    pub fn update_hfr(&mut self, hfr: f64) {
        if self.baseline_hfr.is_none() {
            self.baseline_hfr = Some(hfr);
        }
        self.current_hfr = Some(hfr);
        // mark this as a new HFR sample so the HfrDegraded trigger counts
        // it once (per frame) rather than once per ~1Hz evaluation tick.
        self.hfr_sample_seq = self.hfr_sample_seq.wrapping_add(1);
    }

    pub fn reset_baseline_hfr(&mut self) {
        self.baseline_hfr = self.current_hfr;
    }

    pub fn invalidate_autofocus(&mut self, reason: impl Into<String>) {
        let reason = reason.into();
        self.baseline_hfr = None;
        self.autofocus_invalidated = true;
        self.autofocus_invalidation_reason = Some(reason.clone());
        tracing::info!("Autofocus invalidated: {}", reason);
    }

    /// Append a guiding-RMS sample and trim the rolling history to
    /// `self.guiding_rms_retention_secs`, the window set by
    /// `set_guiding_rms_retention_secs` from the GuidingFailed trigger
    /// configuration (default 300 s).
    pub fn update_guiding_rms(&mut self, rms: f64) {
        if self.guiding_rms_history.is_none() {
            self.guiding_rms_history = Some(Vec::new());
        }

        let retention = self.guiding_rms_retention_secs.max(1);
        if let Some(history) = &mut self.guiding_rms_history {
            history.push((Instant::now(), rms));
            history.retain(|(time, _)| time.elapsed().as_secs() < retention);
        }
    }

    /// set the retention window (seconds) for
    /// `guiding_rms_history`. Driven by the GuidingFailed trigger configuration
    /// so a user-tuned `rms_retention_secs` is honoured at runtime instead of
    /// silently falling back to the previous 300-second hardcode.
    pub fn set_guiding_rms_retention_secs(&mut self, secs: u64) {
        self.guiding_rms_retention_secs = secs.max(1);
    }

    pub fn update_temperature(&mut self, temp: f64) {
        if self.baseline_temperature.is_none() {
            self.baseline_temperature = Some(temp);
        }
        self.current_temperature = Some(temp);
    }

    pub fn reset_baseline_temperature(&mut self) {
        self.baseline_temperature = self.current_temperature;
    }

    pub fn reset_baseline_focuser_position(&mut self, current_position: i32) {
        self.baseline_focuser_position = Some(current_position);
    }

    pub fn set_filter(&mut self, filter: String) {
        let changed = self.current_filter.as_ref() != Some(&filter);
        self.filter_changed = changed;
        if changed {
            // A new filter needs its own HFR baseline -- Ha and L do not share
            // one -- but a filter change is not by itself a reason to refocus.
            // That is the operator's "Auto focus on filter change" setting (off
            // by default, and honoured by the serializer injecting an Autofocus
            // node), and filter focus offsets carry the known per-filter shift.
            // Invalidating autofocus here made the HFR trigger refocus on "L"
            // every time its cooldown expired while a Smart Exposure node cycled
            // narrowband filters.
            self.baseline_hfr = None;
            tracing::debug!("HFR baseline restarted: filter changed to {}", filter);
        }
        self.current_filter = Some(filter);
    }

    pub fn clear_filter_changed(&mut self) {
        self.filter_changed = false;
    }

    /// Increment completed exposures counter (for periodic triggers)
    pub fn increment_exposure_count(&mut self) {
        self.completed_exposures += 1;
    }

    /// Mark that autofocus was just performed
    ///
    /// The temperature shift is measured from here too. Nothing else moved
    /// the baseline, so once the tube had cooled past the threshold the
    /// Temperature Shift trigger stayed true and refocused at every cooldown
    /// for the rest of the night (rig, 2026-10-20: every 10 min after
    /// 2 °C).
    pub fn mark_autofocus_performed(&mut self) {
        self.last_autofocus_frame = self.completed_exposures;
        self.autofocus_invalidated = false;
        self.autofocus_invalidation_reason = None;
        self.reset_baseline_temperature();
    }

    /// Mark that autofocus was ATTEMPTED at this frame and did not converge.
    ///
    /// The cadence anchor moves even though focus did not improve, because the
    /// unattended trigger policy (owner decision 2026-08-14) is to continue on
    /// the last-good focus. Leaving `last_autofocus_frame` where it was would
    /// keep `frames_since_af >= every_n_frames` true forever, so the interval
    /// trigger — which deliberately carries no time cooldown — would re-fire a
    /// failing autofocus after EVERY subsequent frame and spend the rest of the
    /// night sweeping instead of imaging. Retry one full cadence later.
    ///
    /// The stale-focus latch is dropped for the same reason it is dropped when
    /// the action is impossible: the HFR trigger force-fires on it every
    /// evaluation tick otherwise. The temperature baseline moves for the same
    /// reason as the cadence anchor: left behind, the Temperature Shift
    /// trigger re-fires the failing sweep at every cooldown.
    pub fn mark_autofocus_attempted(&mut self) {
        self.last_autofocus_frame = self.completed_exposures;
        self.clear_autofocus_invalidation();
        self.reset_baseline_temperature();
    }

    /// Drop a pending "autofocus is stale" latch WITHOUT claiming an autofocus
    /// actually ran.
    ///
    /// [`Self::mark_autofocus_performed`] also advances `last_autofocus_frame`,
    /// which is the interval trigger's "frames since the last AF" cursor — using
    /// it to clear an unactionable latch would record a focus run that never
    /// happened and push the next interval refocus out by a whole cadence.
    ///
    /// The caller is the trigger evaluator's Autofocus recovery action on a rig
    /// with no focuser: the latch (set by any filter/target change) would
    /// otherwise re-force the HFR trigger on every evaluation tick forever.
    pub fn clear_autofocus_invalidation(&mut self) {
        self.autofocus_invalidated = false;
        self.autofocus_invalidation_reason = None;
    }

    /// Clear the per-RUN latches so a second run in the same app launch does not
    /// inherit the previous run's transient trigger state. [`TriggerManager`] and
    /// its state are built once in [`SequenceExecutor::new`] and outlive every
    /// run, so nothing else resets these — an inherited `autofocus_invalidated`
    /// force-fires the HFR trigger seconds into the next run, and an inherited
    /// target makes the altitude-limit trigger skip a whole tree (while reporting
    /// `completed`) on coordinates this run never had, or slew to the previous
    /// target in daylight.
    ///
    /// Deliberately NOT cleared here: operator/runtime configuration
    /// (thresholds, retention windows, meridian config) and live device
    /// telemetry (weather verdict, pier side), which are properties of the rig
    /// rather than of a run.
    pub fn reset_for_new_run(&mut self) {
        self.baseline_hfr = None;
        self.current_hfr = None;
        self.autofocus_invalidated = false;
        self.autofocus_invalidation_reason = None;
        self.filter_changed = false;
        self.current_filter = None;
        self.has_flipped_this_target = false;
        self.meridian_flip_requested = false;
        self.flip_origin_pier_side = None;
        self.last_applied_filter_offset = 0;
        self.completed_exposures = 0;
        self.last_autofocus_frame = 0;
        self.last_dither_frame = 0;
        self.consecutive_dither_failures = 0;
        self.imaging_unguided = false;
        // The guide-star latch and RMS history describe guiding the previous
        // run started. Carried over, run 2 on the rig (2026-10-07) fired Guide
        // Star Lost 1.6 s after Start on a PHD2 that was only looping, and the
        // recovery stopped mount tracking mid-slew.
        self.guide_star_lost = false;
        self.guiding_rms_history = None;
        self.mount_motion_depth = 0;
        self.guiding_resume_pending = false;
        if std::mem::take(&mut self.restored_from_checkpoint) {
            // A resumed run carries on the guiding its checkpoint recorded.
            return;
        }
        self.guiding_enabled = false;
        self.clear_target_state();
    }

    /// Drop everything derived from a target: the coordinates themselves, the
    /// values computed from them (altitude, hour angle, flip time), and the
    /// plate-solve reference they are compared against.
    ///
    /// `current_altitude` matters as much as the coordinates: the executor's
    /// monitor loop only recomputes it while a target is set, so a stale
    /// altitude left behind here keeps the altitude-limit trigger firing for a
    /// run that has no target at all.
    pub fn clear_target_state(&mut self) {
        self.current_target_name = None;
        self.target_ra = None;
        self.target_dec = None;
        self.current_altitude = None;
        self.current_hour_angle = None;
        self.next_meridian_flip_time = None;
        self.tracking_limit_detected_at = None;
        self.last_plate_solve_ra = None;
        self.last_plate_solve_dec = None;
        self.last_plate_solve_pixel_scale = None;
    }

    /// Mark that dither was just performed
    pub fn mark_dither_performed(&mut self) {
        self.last_dither_frame = self.completed_exposures;
    }

    /// Reset exposure counters (for new sequence)
    pub fn reset_exposure_counters(&mut self) {
        self.completed_exposures = 0;
        self.last_autofocus_frame = 0;
        self.last_dither_frame = 0;
    }

    /// Update plate solve result for drift detection
    pub fn update_plate_solve(&mut self, ra_degrees: f64, dec_degrees: f64, pixel_scale: f64) {
        self.last_plate_solve_ra = Some(ra_degrees);
        self.last_plate_solve_dec = Some(dec_degrees);
        self.last_plate_solve_pixel_scale = Some(pixel_scale);
    }

    /// Set target coordinates for drift detection
    pub fn set_target(&mut self, ra_degrees: f64, dec_degrees: f64) {
        // A plate solve of the previous target says nothing about drift on
        // this one: measured against the new coordinates it read as degrees of
        // "drift" and fired a DriftLimit recenter the moment a target started,
        // before its own slew or Center node had run.
        if self.target_ra != Some(ra_degrees) || self.target_dec != Some(dec_degrees) {
            self.last_plate_solve_ra = None;
            self.last_plate_solve_dec = None;
            self.last_plate_solve_pixel_scale = None;
        }
        self.target_ra = Some(ra_degrees);
        self.target_dec = Some(dec_degrees);
    }

    /// Calculate drift from target in pixels (RA, Dec)
    /// Returns None if insufficient data available
    pub fn calculate_drift_pixels(&self) -> Option<(f64, f64)> {
        let solve_ra = self.last_plate_solve_ra?;
        let solve_dec = self.last_plate_solve_dec?;
        let target_ra = self.target_ra?;
        let target_dec = self.target_dec?;
        let pixel_scale = self.last_plate_solve_pixel_scale?;

        let ra_diff_deg = solve_ra - target_ra;
        let dec_diff_deg = solve_dec - target_dec;

        // RA must be scaled by cos(dec) — RA "circles" shrink as you approach
        // the poles, so a 1° RA difference at Dec=89° is a tiny on-sky distance
        // compared to a 1° RA difference at the equator. Omitting cos(dec) is
        // the classic high-declination drift bug.
        let dec_rad = target_dec.to_radians();
        let ra_arcsec = ra_diff_deg * 3600.0 * dec_rad.cos();
        let dec_arcsec = dec_diff_deg * 3600.0;

        let ra_pixels = ra_arcsec / pixel_scale;
        let dec_pixels = dec_arcsec / pixel_scale;

        Some((ra_pixels.abs(), dec_pixels.abs()))
    }

    /// Update guide star lost state
    pub fn set_guide_star_lost(&mut self, lost: bool) {
        if lost && !self.guide_star_lost {
            tracing::warn!("Guide star lost detected");
        }
        self.guide_star_lost = lost;
    }

    /// Arm or disarm the `GuideStarLost` trigger.
    ///
    /// `guiding_enabled` gates `GuideStarLost` (see `check`) so the trigger
    /// cannot fire while the guider is idle between sequences. It MUST be set
    /// `true` once guiding is active, otherwise the star-lost safety net is
    /// dead and the sequence silently keeps exposing unguided after a star
    /// loss. It is set `true` only when this run starts or resumes guiding
    /// (StartGuiding, the guide-star recovery, the post-autofocus and
    /// post-flip resumes, a restored checkpoint); a guider that was already
    /// guiding for someone else when the run started does not arm it. It is
    /// cleared on an explicit stop so an intentional stop does not masquerade
    /// as a lost star, and at the start of every run.
    pub fn set_guiding_enabled(&mut self, enabled: bool) {
        if self.guiding_enabled != enabled {
            tracing::debug!("Guiding-enabled (star-lost trigger arm) -> {}", enabled);
        }
        self.guiding_enabled = enabled;
    }

    /// Record the filter focus offset (steps, reference-relative) now embodied
    /// in the focuser position. Set after a filter-offset move so the next
    /// filter change applies only the delta. See `last_applied_filter_offset`.
    pub fn set_last_applied_filter_offset(&mut self, offset: i32) {
        self.last_applied_filter_offset = offset;
    }

    /// Update current humidity reading
    /// push the latest cloud-motion analyzer reading into
    /// the trigger state. Called from the executor when a Dart-side
    /// `UpdateCloudMotion` command arrives. Every argument is optional so the
    /// caller can express "analyzer says no arrival predicted" by passing
    /// `predicted_arrival_minutes: None`.
    ///
    /// `current_cover_percent` outside `[0, 100]` is clamped, but the original
    /// out-of-range value is logged at WARN so a buggy data source is loud. NaN /
    /// inf are dropped by `.filter` — the comparison operators would otherwise
    /// read them as "fire".
    pub fn update_cloud_motion(
        &mut self,
        current_cover_percent: Option<f64>,
        predicted_arrival_minutes: Option<f64>,
        predicted_opening_minutes: Option<f64>,
        predicted_opening_duration_secs: Option<f64>,
        predicted_clear_sky_alt_az: Option<(f64, f64)>,
    ) {
        let sanitize_finite = |v: Option<f64>| v.filter(|x| x.is_finite());

        let cover = sanitize_finite(current_cover_percent).map(|v| {
            if !(0.0..=100.0).contains(&v) {
                tracing::warn!(
                    "update_cloud_motion: cover {:.2}% out of [0,100]; clamping",
                    v
                );
                v.clamp(0.0, 100.0)
            } else {
                v
            }
        });

        // Negative predicted minutes are clamped to 0 ("any second now") because
        // the user's intent for "fire within N minutes" still applies: if the
        // analyzer says "-2 minutes" the cloud is already arriving.
        let arrival = sanitize_finite(predicted_arrival_minutes).map(|v| v.max(0.0));
        let opening = sanitize_finite(predicted_opening_minutes).map(|v| v.max(0.0));
        let duration = sanitize_finite(predicted_opening_duration_secs).map(|v| v.max(0.0));

        self.current_cloud_coverage_percent = cover;
        self.predicted_cloud_arrival_minutes = arrival;
        self.predicted_cloud_opening_minutes = opening;
        self.predicted_cloud_opening_duration_secs = duration;
        self.predicted_clear_sky_direction = predicted_clear_sky_alt_az;
        self.cloud_motion_last_update = Some(Instant::now());
    }

    pub fn update_humidity(&mut self, humidity: f64) {
        self.current_humidity = Some(humidity);
    }

    /// Seed the configured maximum Sun altitude (degrees) for on-sky LIGHT
    /// captures so the instruction-layer gate (`instructions::execute_slew` /
    /// `execute_exposure`) can read it through the shared trigger state. A
    /// non-finite value is rejected (stored as `None`) so the gate falls back to
    /// its default rather than silently disabling itself on a NaN/inf config
    /// push.
    /// Move the observer to a new site.
    ///
    /// Clearing `dawn_time` is the point of having a setter at all: the
    /// trigger monitor only recomputes dawn when the cached value is missing
    /// or already past, so a site change that left the cache in place would
    /// keep `DawnApproaching` stopping the run at the OLD site's dawn.
    pub fn set_observer_location(&mut self, latitude: Option<f64>, longitude: Option<f64>) {
        self.observer_latitude = latitude;
        self.observer_longitude = longitude;
        self.dawn_time = None;
    }

    pub fn set_max_sun_altitude_degrees(&mut self, degrees: f64) {
        self.max_sun_altitude_degrees = if degrees.is_finite() {
            Some(degrees)
        } else {
            None
        };
    }

    /// Defense-in-depth (full-night audit 2026-06-04): store the Dart-side
    /// weather-safety verdict. `Some(true)` = Dart computed UNSAFE, `Some(false)`
    /// = Dart computed SAFE, `None` = Dart abstains (provider disabled / no data).
    /// Folded into the `WeatherUnsafe` trigger as an additional unsafe source so a
    /// rig without a hardware safety device still aborts when the configured
    /// thresholds / API / cloud sources say unsafe. Never makes the trigger LESS
    /// safe than the hardware `weather_safe` reading (see the evaluator).
    pub fn update_weather_verdict(&mut self, unsafe_override: Option<bool>) {
        self.weather_verdict_unsafe = unsafe_override;
        // Stamp the push time so the safety poll can detect a stale-AND-unsafe
        // verdict (a dead Dart feed holding the sequence paused) and warn loudly
        // without ever auto-clearing the unsafe state. Stamp on EVERY push,
        // including `None` (abstain) and `Some(false)` (safe): freshness is a
        // property of the channel, not of the verdict value, and a fresh
        // abstain/safe is exactly what clears the stale-unsafe condition.
        self.weather_verdict_last_update = Some(Instant::now());
    }

    /// True when a `Some(true)` (UNSAFE) verdict has not been refreshed within
    /// `staleness_secs`. Used by the safety poll to emit a loud "verdict feed
    /// stale; holding paused fail-closed" warning.
    ///
    /// Returns false (NOT stale) when:
    ///   * the verdict is not `Some(true)` (a safe / abstaining verdict that
    ///     goes stale is harmless — nothing is being held), or
    ///   * no verdict has ever been pushed (`weather_verdict_last_update` is
    ///     `None`); there is no feed to be stale yet, and the hardware poll is
    ///     the active gate.
    ///
    /// This NEVER mutates state and NEVER clears the unsafe verdict — it is a
    /// pure observability predicate.
    pub fn is_weather_verdict_stale_unsafe(&self, staleness_secs: u64) -> bool {
        if self.weather_verdict_unsafe != Some(true) {
            return false;
        }
        match self.weather_verdict_last_update {
            Some(last) => last.elapsed().as_secs() >= staleness_secs,
            None => false,
        }
    }

    /// Science: store the latest transparency reading. `None`
    /// clears the slot (used when the science pipeline loses lock).
    /// NaN / infinite values are dropped via `is_finite` rather than stored.
    pub fn update_transparency(&mut self, transparency: Option<f64>) {
        let sanitised = transparency.filter(|v| v.is_finite()).map(|v| {
            if !(0.0..=1.5).contains(&v) {
                tracing::warn!("update_transparency: {:.3} out of [0,1.5]; clamping", v);
                v.clamp(0.0, 1.5)
            } else {
                v
            }
        });
        self.current_transparency = sanitised;
        self.transparency_last_update = Some(Instant::now());
    }

    /// Set mount tracking expected state
    pub fn set_mount_tracking_expected(&mut self, expected: bool) {
        self.mount_tracking_expected = expected;
        self.mount_tracking_lost = false;
    }

    /// Update dome shutter status
    pub fn update_dome_status(&mut self, status: String) {
        self.dome_shutter_status = Some(status);
    }

    /// Set dome shutter open expected state
    pub fn set_dome_shutter_expected(&mut self, expected: bool) {
        self.dome_shutter_open_expected = expected;
    }

    /// Reset mount tracking lost state
    pub fn reset_mount_tracking_state(&mut self) {
        self.mount_tracking_lost = false;
    }

    /// Get the next grid dither offset (in pixels) for an NxN grid pattern.
    /// Returns (ra_offset, dec_offset) centered on (0,0), then advances the index.
    /// The grid walks through positions in row-major order, wrapping after N*N.
    pub fn next_grid_dither_offset(&mut self, grid_size: u32, pixels: f64) -> (f64, f64) {
        let n = grid_size.max(1);
        let total_positions = n * n;
        let idx = self.grid_dither_index % total_positions;

        let row = idx / n;
        let col = idx % n;

        // Grid is centred on the target by translating each index to a
        // signed offset from the grid centre. step = pixels*2/(n-1) so the
        // outermost positions land exactly at ±pixels (matching the user's
        // intended dither radius); n=1 degenerates to a single (0,0) position.
        let (ra_offset, dec_offset) = if n > 1 {
            // Why: n is u32 grid_size (UI-bounded, typically <=10); col and row
            // are derived from idx % n / n. All u32 -> f64 widenings are lossless
            // for any plausible grid size.
            let step = pixels * 2.0 / f64::from(n - 1);
            let center = f64::from(n - 1) / 2.0;
            let ra = (f64::from(col) - center) * step;
            let dec = (f64::from(row) - center) * step;
            (ra, dec)
        } else {
            (0.0, 0.0)
        };

        self.grid_dither_index = (idx + 1) % total_positions;

        (ra_offset, dec_offset)
    }

    /// Reset grid dither position (call when sequence starts or target changes)
    pub fn reset_grid_dither(&mut self) {
        self.grid_dither_index = 0;
    }

    // Meridian Flip State Management

    /// Update the active target's hour angle. Called every monitor tick with a
    /// value recomputed from the TARGET's coordinates — see
    /// [`TriggerState::current_hour_angle`] for why the mount's own pointing is
    /// not that value.
    pub fn update_hour_angle(&mut self, hour_angle: f64) {
        self.current_hour_angle = Some(hour_angle);
    }

    /// Take the imaging train (camera + filter wheel) for an operation the
    /// holder expects to take `expected_secs`, if nobody else holds it.
    ///
    /// Returns the claim token on success and `None` when it is already held.
    /// Test-and-set happens under the single write lock the caller already
    /// holds, which is what makes it safe: two independent "is the other one
    /// busy?" flags cannot be tested and set without a race, and losing that
    /// race is what destroys a frame.
    ///
    /// `expected_secs` is an estimate and is allowed to be wrong. Being wrong
    /// delays a waiter's log line; it never transfers ownership. See
    /// [`IMAGING_TRAIN_CLAIM_OVERRUN_GRACE_SECS`].
    pub fn try_claim_imaging_train(
        &mut self,
        holder: &'static str,
        expected_secs: f64,
    ) -> Option<u64> {
        if self.imaging_train_hold().is_some() {
            return None;
        }
        // Readout and download are part of the operation: the frame is not safe
        // the instant the shutter closes, and the download is exactly when the
        // destroyed-frame failure appeared, because that is when the capture
        // loop asks the camera for an image something else has already taken.
        let expected = if expected_secs.is_finite() && expected_secs > 0.0 {
            expected_secs + CAMERA_BUSY_DOWNLOAD_SLACK_SECS
        } else {
            CAMERA_BUSY_DOWNLOAD_SLACK_SECS
        };
        let now_ms = Utc::now().timestamp_millis();
        let expected_finish_ms = now_ms + (expected * 1000.0) as i64;
        let token = self.imaging_train_next_token.wrapping_add(1);
        self.imaging_train_next_token = token;
        self.imaging_train_claim = Some(ImagingTrainClaim {
            token,
            holder,
            expected_finish_ms,
            expires_at_ms: expected_finish_ms
                + (IMAGING_TRAIN_CLAIM_OVERRUN_GRACE_SECS * 1000.0) as i64,
        });
        Some(token)
    }

    /// Hand the imaging train back. The operation is done (or gave up), so
    /// release immediately rather than letting the claim lapse, and a waiter
    /// starts now instead of sitting out the grace window.
    ///
    /// Identity-checked and therefore idempotent: a release presenting a token
    /// that is no longer installed does nothing.
    pub fn release_imaging_train(&mut self, token: u64) {
        if self
            .imaging_train_claim
            .as_ref()
            .is_some_and(|claim| claim.token == token)
        {
            self.imaging_train_claim = None;
        }
    }

    /// The live hold on the imaging train, or `None` when it is free.
    ///
    /// A claim past its hard expiry reads as free: the failure mode of this
    /// mechanism is then a late autofocus, not a run wedged for the night by a
    /// holder that panicked without releasing.
    pub fn imaging_train_hold(&self) -> Option<ImagingTrainHold> {
        let claim = self.imaging_train_claim.as_ref()?;
        let now_ms = Utc::now().timestamp_millis();
        let max_remaining_ms = claim.expires_at_ms - now_ms;
        if max_remaining_ms <= 0 {
            return None;
        }
        // i64 milliseconds -> f64 seconds; holds are seconds to minutes,
        // nowhere near the f64 mantissa limit.
        Some(ImagingTrainHold {
            holder: claim.holder,
            expected_remaining_secs: ((claim.expected_finish_ms - now_ms).max(0)) as f64 / 1000.0,
            max_remaining_secs: max_remaining_ms as f64 / 1000.0,
        })
    }

    /// Update the current pier side and clear `has_flipped_this_target` if
    /// the mount has returned to the side it was on before the recorded flip.
    /// Observing the original pier side is authoritative evidence that the mount
    /// is back on the pre-flip side and a fresh flip is again required — a long
    /// single-target session that crosses two meridians (high latitude,
    /// pause-resume, mosaic with a shared name) never changes target name, so
    /// that alone cannot clear the flag.
    pub fn update_pier_side(&mut self, pier_side: PierSide) {
        self.pier_side = Some(pier_side);
        self.on_pier_side_observed(pier_side);
    }

    /// invariant check. Called from `update_pier_side` (and any
    /// other code path that observes mount pier-side telemetry); clears
    /// `has_flipped_this_target` when the observed side matches the
    /// pre-flip side recorded by `mark_flip_performed`. Public so external
    /// observers (e.g., bridge layer reading mount state on a different
    /// cadence) can apply the same invariant without going through
    /// `update_pier_side`.
    pub fn on_pier_side_observed(&mut self, side: PierSide) {
        if !self.has_flipped_this_target {
            return;
        }
        let Some(origin) = self.flip_origin_pier_side else {
            // Why: without an origin we cannot reason about a return-to-pre-flip
            // event. Clearing on every observation reopens the double-flip
            // bug, so we leave the flag set until the user changes target.
            return;
        };
        // Unknown is non-actionable — wait for a real reading.
        if matches!(side, PierSide::Unknown) {
            return;
        }
        if side == origin {
            tracing::info!(
                "[MERIDIAN] Pier side returned to pre-flip side ({:?}); clearing has_flipped_this_target so a second flip can be triggered for the same target",
                origin
            );
            self.has_flipped_this_target = false;
            self.flip_origin_pier_side = None;
        }
    }

    /// explicit reset of the flip-performed bookkeeping. Called
    /// at natural target-boundaries (sequence reset, target group entry)
    /// where a double-flip on the new target is impossible by construction.
    pub fn clear_flipped_state(&mut self) {
        self.has_flipped_this_target = false;
        self.flip_origin_pier_side = None;
    }

    /// Update mount tracking limit time (if mount reports it)
    pub fn update_tracking_limit_time(&mut self, limit_time: i64) {
        self.mount_tracking_limit_time = Some(limit_time);
    }

    /// Set the current target for meridian flip tracking
    /// This also resets the has_flipped flag for the new target
    pub fn set_meridian_target(&mut self, target_name: String) {
        if self.current_target_name.as_ref() != Some(&target_name) {
            let previous = self.current_target_name.clone();
            self.current_target_name = Some(target_name);
            // a target change is a natural boundary; reset both
            // the flag and the recorded origin so flip bookkeeping starts
            // fresh.
            self.has_flipped_this_target = false;
            // A flip asked for on the previous target is not one for this one.
            self.meridian_flip_requested = false;
            self.flip_origin_pier_side = None;
            if let Some(previous) = previous {
                self.invalidate_autofocus(format!("target changed from {}", previous));
            }
        }
    }

    /// Mark that a meridian flip has been performed for the current target.
    /// also records the pier side that was active *before* the
    /// flip (in `flip_origin_pier_side`) so `on_pier_side_observed` can
    /// detect the mount returning to that side and clear the flag, allowing
    /// a second flip on the same long-running target.
    pub fn mark_flip_performed(&mut self) {
        self.has_flipped_this_target = true;
        self.meridian_flip_requested = false;
        // The pier side was updated immediately after the flip, so it now
        // reflects the *post-flip* side. The origin (pre-flip) side is the
        // opposite of the current side. East <-> West; Unknown stays Unknown
        // and prevents future return-detection until telemetry recovers.
        self.flip_origin_pier_side = match self.pier_side {
            Some(PierSide::East) => Some(PierSide::West),
            Some(PierSide::West) => Some(PierSide::East),
            // Why: if telemetry is unavailable we cannot compute the origin
            // safely; leaving it None keeps the flag latched until target
            // change, which is the safe default.
            _ => None,
        };
        tracing::info!(
            "[MERIDIAN] Flip marked as completed for target: {:?} (origin pier side: {:?})",
            self.current_target_name,
            self.flip_origin_pier_side
        );
    }

    /// Clear meridian flip state (call when target changes or sequence resets)
    pub fn clear_meridian_state(&mut self) {
        self.current_hour_angle = None;
        self.pier_side = None;
        self.mount_tracking_limit_time = None;
        self.has_flipped_this_target = false;
        self.meridian_flip_requested = false;
        self.flip_origin_pier_side = None; //
        self.current_target_name = None;
        self.next_meridian_flip_time = None;
        self.tracking_limit_detected_at = None;
    }

    /// Reset tracking limit detection state (call when tracking resumes or flip completes)
    pub fn reset_tracking_limit_detection(&mut self) {
        self.tracking_limit_detected_at = None;
        self.mount_tracking_lost = false;
    }

    /// Check if a meridian flip might be needed based on current state
    /// Returns (needs_flip, minutes_past_meridian) for diagnostic purposes
    pub fn meridian_flip_status(&self) -> (bool, Option<f64>) {
        if self.has_flipped_this_target {
            return (false, None);
        }

        if let Some(ha) = self.current_hour_angle {
            (super::on_pre_flip_side(ha, self.pier_side), Some(ha * 60.0))
        } else {
            (false, None)
        }
    }
}
