//! [`TriggerState`]: what the trigger monitor and the instructions share about
//! a run.
//!
//! The state is made of parts. Which part a field is in decides when it is
//! reset and, with the `persisted` / `transient` split inside the part,
//! whether it is checkpointed:
//!
//! - [`RigTelemetry`]: live readings of the rig and sky. Not reset by a run.
//! - [`TargetState`]: the current target and what is derived from it. Cleared
//!   when a fresh run starts.
//! - [`RunLatches`]: what a run measured, counted and latched. Reset at the
//!   start of every run.
//! - [`TriggerSettings`], [`MirroredTriggerConfig`]: operator settings and
//!   values mirrored from the armed triggers. Not reset by a run.
//! - the sub-states that own their rules ([`super::MeridianFlipState`],
//!   [`super::RunState`], [`super::GuidingState`],
//!   [`super::TrackingLossState`]) and the [`ImagingTrain`] claim.

mod imaging_train;
mod latches;
mod part;
mod settings;
mod target;
mod telemetry;

pub use imaging_train::*;
pub use latches::*;
pub use settings::*;
pub use target::*;
pub use telemetry::*;

use crate::PierSide;
use chrono::Utc;
use std::time::Instant;

/// How a mount-status reading that never arrived counts when judging whether
/// the mount has stopped at its tracking limit.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum UnknownMountStatus {
    /// Unknown is not evidence: only a reading of `false` counts.
    Rejected,
    /// Unknown counts like `false`.
    Tolerated,
}

/// The mount was expected to track, tracking is lost, and the stop is not a
/// slew, a park or a failed status query. The part of "the stopped mount hit
/// its tracking limit" that both callers share; each adds its own conditions.
pub(crate) fn mount_stopped_while_expected_to_track(
    state: &TriggerState,
    unknown: UnknownMountStatus,
) -> bool {
    let reads_false = |reading: Option<bool>| match reading {
        Some(false) => true,
        Some(true) => false,
        None => unknown == UnknownMountStatus::Tolerated,
    };
    let telemetry = &state.telemetry;
    state.tracking.expected_and_lost()
        && !telemetry.mount_status_query_failed
        && reads_false(telemetry.mount_is_tracking)
        && reads_false(telemetry.mount_slewing)
        && reads_false(telemetry.mount_parked)
}

/// A stopped mount that had been tracking this target on the pre-flip side,
/// read as the mount's own tracking limit. Some mounts stop before transit and
/// do not advertise a limit timestamp, so stops from an hour before transit
/// on are adopted. A stop the run made itself (a hold, or a park, home or
/// slew in progress) is never one, nor is a stop made from the app's own
/// mount controls, and unknown mount state is not evidence of a limit stop. A
/// stop made at the hand controller or by another program looks the same as
/// a limit stop to the driver; the hold's notice says how it was read.
pub(crate) fn tracking_limit_recovery_candidate(state: &TriggerState) -> bool {
    state.target.target_ra.is_some()
        && state.target.target_dec.is_some()
        && !state.meridian.has_flipped()
        && !state.guiding.in_motion()
        && !state.tracking.operator_stopped()
        && mount_stopped_while_expected_to_track(state, UnknownMountStatus::Rejected)
        && state.telemetry.pier_side == Some(PierSide::West)
        && state
            .target
            .current_hour_angle
            .is_some_and(|ha| ha.is_finite() && (-1.0..12.0).contains(&ha))
}

/// The On Tracking Limit Hit flip trigger's reading of a stopped mount: the
/// mount's own limit time has come, or the target is past the meridian on the
/// pre-flip side.
pub(in crate::triggers) fn looks_like_tracking_limit_hit(state: &TriggerState) -> bool {
    if !mount_stopped_while_expected_to_track(state, UnknownMountStatus::Tolerated) {
        if state.tracking.expected_and_lost() {
            tracing::debug!(
                "Tracking lost but not a limit hit: query_failed={} tracking={:?} slewing={:?} \
                 parked={:?}",
                state.telemetry.mount_status_query_failed,
                state.telemetry.mount_is_tracking,
                state.telemetry.mount_slewing,
                state.telemetry.mount_parked
            );
        }
        return false;
    }

    let now = Utc::now().timestamp();
    if let Some(limit_time) = state.telemetry.mount_tracking_limit_time {
        if limit_time <= now + 60 {
            return !matches!(state.telemetry.pier_side, Some(PierSide::East));
        }
    }

    // Same window as the flip trigger itself, minus the threshold: a mount
    // that stopped tracking BEFORE its target transited did not hit a
    // meridian-side tracking limit, whatever else went wrong.
    let past_meridian = match state.target.current_hour_angle {
        Some(ha) => super::on_pre_flip_side(ha, state.telemetry.pier_side),
        None => false,
    };
    if !past_meridian {
        tracing::debug!(
            "Tracking lost but HA={:?} / pier {:?} is not the pre-flip side past the \
             meridian - not a limit hit",
            state.target.current_hour_angle,
            state.telemetry.pier_side
        );
    }
    past_meridian
}

/// What trigger evaluation and the instructions read and write about a run,
/// in parts. Which part a field is in decides when it is reset and whether it
/// is checkpointed.
#[derive(Debug, Clone, Default)]
pub struct TriggerState {
    pub telemetry: RigTelemetry,
    pub target: TargetState,
    pub latches: RunLatches,
    pub settings: TriggerSettings,
    pub trigger_config: MirroredTriggerConfig,
    /// Flip bookkeeping for the current target. See [`super::MeridianFlipState`].
    pub meridian: super::MeridianFlipState,
    /// The run's own hold and the monitor's last evaluation. See
    /// [`super::RunState`].
    pub run: super::RunState,
    /// This run's guiding and the moves that interrupt it. See
    /// [`super::GuidingState`].
    pub guiding: super::GuidingState,
    /// The tracking-loss latch. See [`super::TrackingLossState`].
    pub tracking: super::TrackingLossState,
    pub imaging_train: ImagingTrain,
    /// Set by [`Self::restore`] and consumed by [`Self::reset_for_new_run`].
    /// A resumed run re-enters its tree with the already-completed
    /// `TargetHeader` short-circuited, so its restored target must survive
    /// the run-start reset; a fresh run's must not.
    pub restored_from_checkpoint: bool,
}

/// The checkpointed form of a [`TriggerState`]: the persisted fields of every
/// part, flattened to one JSON object.
#[derive(Debug, Clone, PartialEq, Default, serde::Serialize, serde::Deserialize)]
pub struct PersistedTriggerState {
    #[serde(flatten)]
    pub telemetry: TelemetrySnapshot,
    #[serde(flatten)]
    pub target: TargetSnapshot,
    #[serde(flatten)]
    pub latches: LatchesSnapshot,
    #[serde(flatten)]
    pub settings: SettingsSnapshot,
    #[serde(flatten)]
    pub trigger_config: TriggerConfigSnapshot,
    #[serde(flatten)]
    pub meridian: super::MeridianFlipSnapshot,
    #[serde(flatten)]
    pub guiding: super::GuidingSnapshot,
    #[serde(flatten)]
    pub tracking: super::TrackingLossSnapshot,
}

impl TriggerState {
    pub fn new() -> Self {
        Self::default()
    }

    /// The fields a checkpoint keeps.
    pub fn persisted(&self) -> PersistedTriggerState {
        PersistedTriggerState {
            telemetry: self.telemetry.snapshot(),
            target: self.target.snapshot(),
            latches: self.latches.snapshot(),
            settings: self.settings.snapshot(),
            trigger_config: self.trigger_config.snapshot(),
            meridian: self.meridian.snapshot(),
            guiding: self.guiding.snapshot(),
            tracking: self.tracking.snapshot(),
        }
    }

    /// Take the checkpointed fields from `persisted`. Everything a checkpoint
    /// does not keep stays as it is.
    pub fn restore(&mut self, persisted: &PersistedTriggerState) {
        self.restored_from_checkpoint = true;
        self.telemetry.restore(&persisted.telemetry);
        self.target.restore(&persisted.target);
        self.latches.restore(&persisted.latches);
        self.settings.restore(&persisted.settings);
        self.trigger_config.restore(&persisted.trigger_config);
        self.meridian.restore(&persisted.meridian);
        self.guiding.restore_snapshot(&persisted.guiding);
        self.tracking.restore_snapshot(&persisted.tracking);
    }

    /// The bar autofocus and a flip restart guiding at; see
    /// [`crate::GuiderSettle::restart_bar`].
    pub fn restart_settle(&self) -> crate::GuiderSettle {
        crate::GuiderSettle::restart_bar(self.settings.dither_settle, self.settings.guiding_settle)
    }

    pub fn update_hfr(&mut self, hfr: f64) {
        if self.latches.baseline_hfr.is_none() {
            self.latches.baseline_hfr = Some(hfr);
        }
        self.latches.current_hfr = Some(hfr);
        // mark this as a new HFR sample so the HfrDegraded trigger counts
        // it once (per frame) rather than once per ~1Hz evaluation tick.
        self.latches.hfr_sample_seq = self.latches.hfr_sample_seq.wrapping_add(1);
    }

    /// Take the current HFR as the baseline. Called after a successful
    /// autofocus, so it is also remembered as the current filter's focused HFR.
    pub fn reset_baseline_hfr(&mut self) {
        self.latches.baseline_hfr = self.latches.current_hfr;
        if let (Some(filter), Some(hfr)) = (
            self.latches.current_filter.as_ref(),
            self.latches.current_hfr,
        ) {
            self.latches
                .focused_hfr_by_filter
                .insert(filter.clone(), hfr);
        }
    }

    pub fn invalidate_autofocus(&mut self, reason: impl Into<String>) {
        let reason = reason.into();
        self.latches.baseline_hfr = None;
        self.latches.autofocus_invalidated = true;
        self.latches.autofocus_invalidation_reason = Some(reason.clone());
        tracing::info!("Autofocus invalidated: {}", reason);
    }

    /// Append a guiding-RMS sample and trim the rolling history to
    /// `self.trigger_config.guiding_rms_retention_secs`, the window set by
    /// `set_guiding_rms_retention_secs` from the GuidingFailed trigger
    /// configuration (default 300 s).
    pub fn update_guiding_rms(&mut self, rms: f64) {
        if self.latches.guiding_rms_history.is_none() {
            self.latches.guiding_rms_history = Some(Vec::new());
        }

        let retention = self.trigger_config.guiding_rms_retention_secs.max(1);
        if let Some(history) = &mut self.latches.guiding_rms_history {
            history.push((Instant::now(), rms));
            history.retain(|(time, _)| time.elapsed().as_secs() < retention);
        }
    }

    /// set the retention window (seconds) for
    /// `guiding_rms_history`. Driven by the GuidingFailed trigger configuration
    /// so a user-tuned `rms_retention_secs` is honoured at runtime instead of
    /// silently falling back to the previous 300-second hardcode.
    pub fn set_guiding_rms_retention_secs(&mut self, secs: u64) {
        self.trigger_config.guiding_rms_retention_secs = secs.max(1);
    }

    pub fn update_temperature(&mut self, temp: f64) {
        if self.latches.baseline_temperature.is_none() {
            self.latches.baseline_temperature = Some(temp);
        }
        self.latches.current_temperature = Some(temp);
    }

    pub fn reset_baseline_temperature(&mut self) {
        self.latches.baseline_temperature = self.latches.current_temperature;
    }

    pub fn reset_baseline_focuser_position(&mut self, current_position: i32) {
        self.latches.baseline_focuser_position = Some(current_position);
    }

    pub fn set_filter(&mut self, filter: String) {
        let changed = self.latches.current_filter.as_ref() != Some(&filter);
        self.latches.filter_changed = changed;
        if changed {
            // A new filter needs its own HFR baseline -- Ha and L do not share
            // one -- but a filter change is not by itself a reason to refocus.
            // That is the operator's "Auto focus on filter change" setting (off
            // by default, and honoured by the serializer injecting an Autofocus
            // node), and filter focus offsets carry the known per-filter shift.
            // Invalidating autofocus here made the HFR trigger refocus on "L"
            // every time its cooldown expired while a Smart Exposure node cycled
            // narrowband filters.
            // The filter's own focused HFR when it has one: the first frame
            // after the change may already be out of focus, and adopting it
            // would make the blur the reference no trigger can see past.
            self.latches.baseline_hfr = self.latches.focused_hfr_by_filter.get(&filter).copied();
            tracing::debug!(
                "HFR baseline for {} is {:?} after the filter change",
                filter,
                self.latches.baseline_hfr
            );
        }
        self.latches.current_filter = Some(filter);
    }

    pub fn clear_filter_changed(&mut self) {
        self.latches.filter_changed = false;
    }

    /// Increment completed exposures counter (for periodic triggers)
    pub fn increment_exposure_count(&mut self) {
        self.latches.completed_exposures += 1;
    }

    /// Mark that autofocus was just performed
    ///
    /// The temperature shift is measured from here too. Nothing else moved
    /// the baseline, so once the tube had cooled past the threshold the
    /// Temperature Shift trigger stayed true and refocused at every cooldown
    /// for the rest of the night (rig, 2026-10-20: every 10 min after
    /// 2 °C).
    pub fn mark_autofocus_performed(&mut self) {
        self.latches.autofocus_hfr_seq = Some(self.latches.hfr_sample_seq);
        self.latches.last_autofocus_frame = self.latches.completed_exposures;
        self.latches.autofocus_invalidated = false;
        self.latches.autofocus_invalidation_reason = None;
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
        self.latches.autofocus_hfr_seq = Some(self.latches.hfr_sample_seq);
        self.latches.last_autofocus_frame = self.latches.completed_exposures;
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
        self.latches.autofocus_invalidated = false;
        self.latches.autofocus_invalidation_reason = None;
    }

    /// Start a run with nothing left over from the previous one. The trigger
    /// manager and this state are built once and outlive every run, so
    /// nothing else resets them: an inherited `autofocus_invalidated` fires
    /// the HFR trigger seconds into the next run, and an inherited target
    /// makes the altitude-limit trigger skip a whole tree on coordinates this
    /// run never had.
    ///
    /// Reset by part: the run latches, the flip bookkeeping, the run hold and
    /// the guiding state on every run; the target and the tracking baseline
    /// only on a fresh one, because a resumed run carries on the guiding and
    /// target its checkpoint recorded. Settings and telemetry belong to the
    /// rig and are left alone.
    pub fn reset_for_new_run(&mut self) {
        self.latches = RunLatches {
            // Not reset: the HFR sample counter only ever grows, and the grid
            // dither walk carries on where the last run left it.
            hfr_sample_seq: self.latches.hfr_sample_seq,
            grid_dither_index: self.latches.grid_dither_index,
            ..RunLatches::default()
        };
        self.meridian.reset_for_new_run();
        self.run.reset_for_new_run();
        let resumed = std::mem::take(&mut self.restored_from_checkpoint);
        self.guiding.reset_for_new_run(resumed);
        if resumed {
            return;
        }
        // The tracking-loss baseline is armed by this run's own readings.
        // Carried over, a mount parked at the end of the last run and unparked
        // for this one read as a lost track on the run's first poll.
        self.tracking.set_expected(false);
        self.tracking.clear_lost();
        self.telemetry.mount_is_tracking = None;
        self.clear_target_state();
    }

    /// Drop everything derived from a target: the coordinates themselves, the
    /// values computed from them (altitude, hour angle), the guide star and
    /// plate-solve references they are compared against, and the
    /// tracking-limit wait.
    ///
    /// `current_altitude` matters as much as the coordinates: the monitor
    /// only recomputes it while a target is set, so a stale altitude keeps
    /// the altitude-limit trigger firing for a run that has no target.
    pub fn clear_target_state(&mut self) {
        self.target = TargetState::default();
        self.tracking.forget_limit_detection();
    }

    /// Mark that dither was just performed
    pub fn mark_dither_performed(&mut self) {
        self.latches.last_dither_frame = self.latches.completed_exposures;
    }

    /// Mark a dither performed inside an exposure burst, after
    /// `frames_into_burst` of its frames. The burst adds its frames to
    /// `completed_exposures` only when it ends, so the dither's place in the
    /// run's count is ahead of the counter by that many frames.
    pub fn mark_dither_performed_in_burst(&mut self, frames_into_burst: u32) {
        self.latches.last_dither_frame = self
            .latches
            .completed_exposures
            .saturating_add(frames_into_burst);
    }

    /// A node that dithers on its own cadence has started.
    pub fn claim_dither_cadence(&mut self) {
        self.latches.dither_cadence_owners = self.latches.dither_cadence_owners.saturating_add(1);
    }

    /// The node that claimed the dither cadence has finished.
    pub fn release_dither_cadence(&mut self) {
        self.latches.dither_cadence_owners = self.latches.dither_cadence_owners.saturating_sub(1);
    }

    /// Whether a running node owns the dither cadence, so the Dither
    /// Interval trigger must not dither on its own count.
    pub fn node_owns_dither_cadence(&self) -> bool {
        self.latches.dither_cadence_owners > 0
    }

    /// Update plate solve result for drift detection
    pub fn update_plate_solve(&mut self, ra_degrees: f64, dec_degrees: f64, pixel_scale: f64) {
        self.target.last_plate_solve_ra = Some(ra_degrees);
        self.target.last_plate_solve_dec = Some(dec_degrees);
        self.target.last_plate_solve_pixel_scale = Some(pixel_scale);
    }

    /// Set target coordinates for drift detection
    pub fn set_target(&mut self, ra_degrees: f64, dec_degrees: f64) {
        // A plate solve of the previous target says nothing about drift on
        // this one: measured against the new coordinates it read as degrees of
        // "drift" and fired a DriftLimit recenter the moment a target started,
        // before its own slew or Center node had run.
        if self.target.target_ra != Some(ra_degrees) || self.target.target_dec != Some(dec_degrees)
        {
            // Nor is the previous field's guide star a measure for this one.
            self.target.guide_star_reference = None;
            self.target.last_plate_solve_ra = None;
            self.target.last_plate_solve_dec = None;
            self.target.last_plate_solve_pixel_scale = None;
        }
        self.target.target_ra = Some(ra_degrees);
        self.target.target_dec = Some(dec_degrees);
    }

    /// Calculate drift from target in pixels (RA, Dec)
    /// Returns None if insufficient data available
    pub fn calculate_drift_pixels(&self) -> Option<(f64, f64)> {
        let solve_ra = self.target.last_plate_solve_ra?;
        let solve_dec = self.target.last_plate_solve_dec?;
        let target_ra = self.target.target_ra?;
        let target_dec = self.target.target_dec?;
        let pixel_scale = self.target.last_plate_solve_pixel_scale?;

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
        self.guiding.set_star_lost(lost);
    }

    /// Arm or disarm the `GuideStarLost` trigger; see
    /// [`super::GuidingState::set_enabled`].
    pub fn set_guiding_enabled(&mut self, enabled: bool) {
        self.guiding.set_enabled(enabled);
    }

    /// Record the filter focus offset (steps, reference-relative) now embodied
    /// in the focuser position. Set after a filter-offset move so the next
    /// filter change applies only the delta. See `last_applied_filter_offset`.
    pub fn set_last_applied_filter_offset(&mut self, offset: i32) {
        self.latches.last_applied_filter_offset = offset;
    }

    /// Store the latest cloud-motion analyzer reading. Every argument is
    /// optional so the caller can say "no arrival predicted" by passing
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

        self.telemetry.current_cloud_coverage_percent = cover;
        self.telemetry.predicted_cloud_arrival_minutes = arrival;
        self.telemetry.predicted_cloud_opening_minutes = opening;
        self.telemetry.predicted_cloud_opening_duration_secs = duration;
        self.telemetry.predicted_clear_sky_direction = predicted_clear_sky_alt_az;
        self.telemetry.cloud_motion_last_update = Some(Instant::now());
    }

    pub fn update_humidity(&mut self, humidity: f64) {
        self.telemetry.current_humidity = Some(humidity);
    }

    /// Move the observer to a new site.
    ///
    /// Clearing `dawn_time` is the point of having a setter at all: the
    /// trigger monitor only recomputes dawn when the cached value is missing
    /// or already past, so a site change that left the cache in place would
    /// keep `DawnApproaching` stopping the run at the OLD site's dawn.
    pub fn set_observer_location(&mut self, latitude: Option<f64>, longitude: Option<f64>) {
        self.settings.observer_latitude = latitude;
        self.settings.observer_longitude = longitude;
        self.telemetry.dawn_time = None;
    }

    /// Set the maximum Sun altitude (degrees) for on-sky light frames. A
    /// non-finite value is stored as `None`, so the daylight gate falls back
    /// to its default instead of switching itself off.
    pub fn set_max_sun_altitude_degrees(&mut self, degrees: f64) {
        self.settings.max_sun_altitude_degrees = if degrees.is_finite() {
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
        self.update_weather_verdict_from(unsafe_override, false);
    }

    /// [`Self::update_weather_verdict`] with the verdict's source class:
    /// `advisory` is true when the UNSAFE verdict rests only on a forecast or
    /// cloud model. Ignored for a verdict that is not UNSAFE.
    pub fn update_weather_verdict_from(&mut self, unsafe_override: Option<bool>, advisory: bool) {
        self.telemetry.weather_verdict_unsafe = unsafe_override;
        self.telemetry.weather_verdict_advisory = unsafe_override == Some(true) && advisory;
        // Stamp the push time so the safety poll can detect a stale-AND-unsafe
        // verdict (a dead Dart feed holding the sequence paused) and warn loudly
        // without ever auto-clearing the unsafe state. Stamp on EVERY push,
        // including `None` (abstain) and `Some(false)` (safe): freshness is a
        // property of the channel, not of the verdict value, and a fresh
        // abstain/safe is exactly what clears the stale-unsafe condition.
        self.telemetry.weather_verdict_last_update = Some(Instant::now());
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
        if self.telemetry.weather_verdict_unsafe != Some(true) {
            return false;
        }
        match self.telemetry.weather_verdict_last_update {
            Some(last) => last.elapsed().as_secs() >= staleness_secs,
            None => false,
        }
    }

    /// Whether the operator's "the sky is clear" override is in force.
    pub fn weather_operator_clear_active(&self) -> bool {
        self.telemetry
            .weather_operator_clear_until
            .is_some_and(|until| Instant::now() < until)
    }

    /// Whether the app's pushed verdict currently says UNSAFE and is acted on:
    /// it is not under the operator's clear-sky override.
    pub fn weather_verdict_counts_unsafe(&self) -> bool {
        self.telemetry.weather_verdict_unsafe == Some(true) && !self.weather_operator_clear_active()
    }

    /// Whether unsafe weather right now rests only on advisory sources: the
    /// hardware safety reading is safe and the app's UNSAFE verdict comes from
    /// a forecast. Such weather holds the run and never parks or ends it.
    pub fn weather_unsafe_is_advisory_only(&self) -> bool {
        self.telemetry.weather_safe
            && self.weather_verdict_counts_unsafe()
            && self.telemetry.weather_verdict_advisory
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
        self.telemetry.current_transparency = sanitised;
    }

    /// Set mount tracking expected state
    pub fn set_mount_tracking_expected(&mut self, expected: bool) {
        self.tracking.set_expected(expected);
    }

    /// Update dome shutter status
    pub fn update_dome_status(&mut self, status: String) {
        self.telemetry.dome_shutter_status = Some(status);
    }

    /// Set dome shutter open expected state
    pub fn set_dome_shutter_expected(&mut self, expected: bool) {
        self.telemetry.dome_shutter_open_expected = expected;
    }

    /// Get the next grid dither offset (in pixels) for an NxN grid pattern.
    /// Returns (ra_offset, dec_offset) centered on (0,0), then advances the index.
    /// The grid walks through positions in row-major order, wrapping after N*N.
    pub fn next_grid_dither_offset(&mut self, grid_size: u32, pixels: f64) -> (f64, f64) {
        let n = grid_size.max(1);
        let total_positions = n * n;
        let idx = self.latches.grid_dither_index % total_positions;

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

        self.latches.grid_dither_index = (idx + 1) % total_positions;

        (ra_offset, dec_offset)
    }

    // Meridian Flip State Management

    /// Update the active target's hour angle. Called every monitor tick with a
    /// value recomputed from the TARGET's coordinates — see
    /// [`TriggerState::current_hour_angle`] for why the mount's own pointing is
    /// not that value.
    pub fn update_hour_angle(&mut self, hour_angle: f64) {
        self.target.current_hour_angle = Some(hour_angle);
    }

    /// Record the mount's pier side. Seeing the side a recorded flip left is
    /// what allows a second flip on a target that crosses the meridian again
    /// without changing name.
    pub fn update_pier_side(&mut self, pier_side: PierSide) {
        self.telemetry.pier_side = Some(pier_side);
        self.on_pier_side_observed(pier_side);
    }

    /// Clear the recorded flip when `side` is the side it left. See
    /// [`super::MeridianFlipState::on_pier_side_observed`].
    pub fn on_pier_side_observed(&mut self, side: PierSide) {
        let origin = self.meridian.flip_origin();
        if self.meridian.on_pier_side_observed(side) {
            tracing::info!(
                "[MERIDIAN] Pier side returned to pre-flip side ({:?}); clearing has_flipped_this_target so a second flip can be triggered for the same target",
                origin
            );
        }
    }

    /// Update mount tracking limit time (if mount reports it)
    pub fn update_tracking_limit_time(&mut self, limit_time: i64) {
        self.telemetry.mount_tracking_limit_time = Some(limit_time);
    }

    /// Set the current target for meridian flip tracking. A new target starts
    /// with no flip and no request recorded.
    pub fn set_meridian_target(&mut self, target_name: String) {
        if self.target.current_target_name.as_ref() != Some(&target_name) {
            let previous = self.target.current_target_name.clone();
            self.target.current_target_name = Some(target_name);
            self.meridian.target_changed();
            if let Some(previous) = previous {
                self.invalidate_autofocus(format!("target changed from {}", previous));
            }
        }
    }

    /// Mark that a meridian flip has been performed for the current target.
    pub fn mark_flip_performed(&mut self) {
        // The pier side was updated right after the flip, so it is the
        // post-flip side; the origin is its opposite.
        self.meridian.mark_performed(self.telemetry.pier_side);
        tracing::info!(
            "[MERIDIAN] Flip marked as completed for target: {:?} (origin pier side: {:?})",
            self.target.current_target_name,
            self.meridian.flip_origin()
        );
    }

    /// Reset tracking limit detection state (call when tracking resumes or flip completes)
    pub fn reset_tracking_limit_detection(&mut self) {
        self.tracking.clear_limit_detection();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn used_state() -> TriggerState {
        let mut state = TriggerState::new();
        state.update_hfr(2.5);
        state.set_filter("Ha".into());
        state.latches.completed_exposures = 12;
        state.latches.grid_dither_index = 7;
        state.latches.mount_fault_at = Some(1_700_000_000);
        state.latches.autofocus_hold = Some("trailed frames".into());
        state.set_meridian_target("NGC 891".into());
        state.set_target(35.5, 42.25);
        state.target.current_altitude = Some(58.0);
        state.target.current_hour_angle = Some(0.5);
        state.update_plate_solve(35.6, 42.3, 1.25);
        state.tracking.set_expected(true);
        state.tracking.record_loss(1_700_000_100);
        state.telemetry.mount_is_tracking = Some(false);
        state.telemetry.pier_side = Some(PierSide::West);
        state.telemetry.weather_safe = true;
        state.update_weather_verdict(Some(true));
        state.settings.stop_on_quality_problems = true;
        state.settings.observer_latitude = Some(45.5);
        state.trigger_config.meridian_flip_minutes_past = Some(5.0);
        state.guiding.set_enabled(true);
        state
    }

    fn assert_rig_parts_untouched(state: &TriggerState) {
        assert_eq!(state.telemetry.pier_side, Some(PierSide::West));
        assert!(state.telemetry.weather_safe);
        assert_eq!(state.telemetry.weather_verdict_unsafe, Some(true));
        assert!(state.stops_on_quality_problems());
        assert_eq!(state.settings.observer_latitude, Some(45.5));
        assert_eq!(state.trigger_config.meridian_flip_minutes_past, Some(5.0));
    }

    fn assert_latches_reset(state: &TriggerState) {
        assert_eq!(state.latches.current_hfr, None);
        assert_eq!(state.latches.baseline_hfr, None);
        assert_eq!(state.latches.current_filter, None);
        assert_eq!(state.latches.completed_exposures, 0);
        assert_eq!(state.latches.mount_fault_at, None);
        assert_eq!(state.latches.autofocus_hold, None);
        // The two counters a run start does not reset.
        assert_eq!(state.latches.hfr_sample_seq, 1);
        assert_eq!(state.latches.grid_dither_index, 7);
    }

    #[test]
    fn a_fresh_run_resets_the_latches_and_the_target_and_leaves_the_rig_parts() {
        let mut state = used_state();
        state.reset_for_new_run();

        assert_latches_reset(&state);
        assert_eq!(state.target.current_target_name, None);
        assert_eq!(state.target.target_ra, None);
        assert_eq!(state.target.current_altitude, None);
        assert_eq!(state.target.current_hour_angle, None);
        assert_eq!(state.target.last_plate_solve_ra, None);
        assert_eq!(state.telemetry.mount_is_tracking, None);
        assert!(!state.tracking.is_expected());
        assert_eq!(state.tracking.limit_detected_at(), None);
        assert!(!state.guiding.is_enabled());
        assert_rig_parts_untouched(&state);
    }

    #[test]
    fn a_resumed_run_resets_the_latches_and_keeps_its_target_and_tracking() {
        let mut state = used_state();
        state.restored_from_checkpoint = true;
        state.reset_for_new_run();

        assert_latches_reset(&state);
        assert_eq!(state.target.current_target_name.as_deref(), Some("NGC 891"));
        assert_eq!(state.target.target_ra, Some(35.5));
        assert_eq!(state.target.current_altitude, Some(58.0));
        assert_eq!(state.target.last_plate_solve_ra, Some(35.6));
        assert_eq!(state.telemetry.mount_is_tracking, Some(false));
        assert!(state.tracking.expected_and_lost());
        assert_eq!(state.tracking.limit_detected_at(), Some(1_700_000_100));
        assert!(state.guiding.is_enabled());
        assert!(!state.restored_from_checkpoint, "the flag is consumed");
        assert_rig_parts_untouched(&state);
    }

    #[test]
    fn restoring_a_checkpoint_keeps_what_the_checkpoint_does_not_carry() {
        let mut state = used_state();
        let persisted = TriggerState::new().persisted();
        state.restore(&persisted);

        // Checkpointed fields take the checkpoint's values.
        assert_eq!(state.latches.completed_exposures, 0);
        assert_eq!(state.target.current_target_name, None);
        assert_eq!(state.telemetry.pier_side, None);
        // The rest keep their live values: the weather verdict the app
        // pushed and the operator's settings are not in a checkpoint.
        assert_eq!(state.telemetry.weather_verdict_unsafe, Some(true));
        assert!(state.stops_on_quality_problems());
        assert_eq!(
            state.latches.autofocus_hold.as_deref(),
            Some("trailed frames")
        );
        assert!(state.restored_from_checkpoint);
    }

    #[test]
    fn unknown_mount_status_counts_only_where_the_caller_tolerates_it() {
        let mut state = TriggerState::new();
        state.tracking.set_expected(true);
        state.tracking.mark_lost();
        assert!(!mount_stopped_while_expected_to_track(
            &state,
            UnknownMountStatus::Rejected
        ));
        assert!(mount_stopped_while_expected_to_track(
            &state,
            UnknownMountStatus::Tolerated
        ));

        state.telemetry.mount_is_tracking = Some(false);
        state.telemetry.mount_slewing = Some(false);
        state.telemetry.mount_parked = Some(false);
        assert!(mount_stopped_while_expected_to_track(
            &state,
            UnknownMountStatus::Rejected
        ));

        for spoil in [0, 1, 2, 3] {
            let mut state = state.clone();
            match spoil {
                0 => state.telemetry.mount_status_query_failed = true,
                1 => state.telemetry.mount_is_tracking = Some(true),
                2 => state.telemetry.mount_slewing = Some(true),
                _ => state.telemetry.mount_parked = Some(true),
            }
            for unknown in [UnknownMountStatus::Rejected, UnknownMountStatus::Tolerated] {
                assert!(
                    !mount_stopped_while_expected_to_track(&state, unknown),
                    "case {spoil} with {unknown:?}"
                );
            }
        }
    }
}
