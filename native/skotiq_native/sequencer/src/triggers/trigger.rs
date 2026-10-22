//! The [`Trigger`] record and its condition evaluation.

use super::state::looks_like_tracking_limit_hit;
use super::{TriggerState, FOCUS_DRIFT_WINDOW_MAX};
use crate::{RecoveryAction, TriggerType};
use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::time::{Duration, Instant};

/// If `trigger_type` is `FocusDrift` and the configured window exceeds
/// `FOCUS_DRIFT_WINDOW_MAX`, clamp it and log a warning. Used by
/// `Trigger::new` so a stored sequence with an oversized window does not
/// allocate without bounds at runtime.
///
/// Returns `(clamped_type, Option<TriggerClampWarning>)` so `Trigger::new`
/// can capture the clamping diagnostic and the executor can surface it as a
/// user-visible `ExecutorEvent::Error` rather than a log line the operator
/// never sees.
fn clamp_focus_drift_window(
    trigger_type: TriggerType,
) -> (TriggerType, Option<TriggerClampWarning>) {
    if let TriggerType::FocusDrift {
        window_size,
        min_increasing_count,
        min_total_increase,
    } = &trigger_type
    {
        if *window_size > FOCUS_DRIFT_WINDOW_MAX {
            tracing::warn!(
                "FocusDrift trigger window_size {} exceeds maximum {}; clamping. \
                 Reduce window_size in the trigger configuration to silence this warning.",
                window_size,
                FOCUS_DRIFT_WINDOW_MAX
            );
            let warning = TriggerClampWarning {
                field: "FocusDrift.window_size",
                original: *window_size,
                clamped_to: FOCUS_DRIFT_WINDOW_MAX,
            };
            return (
                TriggerType::FocusDrift {
                    window_size: FOCUS_DRIFT_WINDOW_MAX,
                    min_increasing_count: *min_increasing_count,
                    min_total_increase: *min_total_increase,
                },
                Some(warning),
            );
        }
    }
    (trigger_type, None)
}

/// A trigger that monitors conditions and fires when met
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Trigger {
    pub id: String,
    pub name: String,
    pub trigger_type: TriggerType,
    pub recovery_action: RecoveryAction,
    pub enabled: bool,
    #[serde(skip)]
    pub cooldown_secs: Option<u64>,
    #[serde(skip)]
    pub last_triggered: Option<Instant>,
    /// Counter for consecutive frames exceeding HFR threshold.
    /// Only used by HfrDegraded triggers; reset when condition clears.
    #[serde(skip)]
    pub hfr_bad_frame_count: u32,
    /// the `TriggerState::hfr_sample_seq` last consumed by this
    /// HfrDegraded trigger. `check()` runs on the ~1Hz monitor tick; gating on
    /// a change here makes `hfr_bad_frame_count` advance once per FRAME instead
    /// of once per tick (which had turned `consecutive_frames` into seconds).
    #[serde(skip, default)]
    pub last_hfr_seq: Option<u64>,
    /// Rolling window of HFR values for FocusDrift detection.
    /// Stores recent HFR measurements to detect monotonic upward trends.
    /// Switched from `Vec<f64>` to `VecDeque<f64>` so the
    /// per-tick trim uses O(1) `pop_front` instead of O(n) `remove(0)`. The
    /// window is bounded by `FOCUS_DRIFT_WINDOW_MAX` (enforced at trigger
    /// creation time) so worst-case allocation is fixed.
    #[serde(skip)]
    pub focus_drift_hfr_window: VecDeque<f64>,
    /// when `Trigger::new` clamped an oversize FocusDrift
    /// `window_size`, the original user-supplied value is captured here so the
    /// executor can emit a user-visible `ExecutorEvent::Error` on start
    /// instead of leaving the clamp silently in the tracing log. `None` means
    /// no clamping occurred.
    #[serde(skip, default)]
    pub clamp_warning: Option<TriggerClampWarning>,
    /// monotonic timestamp at which the `CloudCoverThreshold`
    /// trigger first observed cover above its `max_percent`. Reset to `None`
    /// whenever a sample drops back below the threshold; reused to implement
    /// the user's `duration_secs` debounce. Per-trigger (not on shared
    /// `TriggerState`) so multiple `CloudCoverThreshold` triggers with
    /// different thresholds debounce independently.
    #[serde(skip, default)]
    pub cloud_cover_above_threshold_since: Option<Instant>,
    /// Science: monotonic timestamp at which a
    /// `TransparencyDropped` trigger first observed transparency at or
    /// below its `below_threshold`. Reset to `None` whenever the sample
    /// recovers above the threshold; used to implement the user's
    /// `duration_secs` debounce. Per-trigger so multiple triggers with
    /// different thresholds debounce independently.
    #[serde(skip, default)]
    pub transparency_below_threshold_since: Option<Instant>,
    /// Whether the last evaluation fired, so the manager can log a firing
    /// once instead of on every tick a level-type trigger stays due.
    #[serde(skip, default)]
    pub was_firing: bool,
}

/// trigger-creation-time clamping diagnostic. Built by
/// `Trigger::new` when the user-supplied configuration was reduced to fit a
/// hard upper bound (currently `FOCUS_DRIFT_WINDOW_MAX`). Consumed by the
/// executor's start path so the user sees the clamp in the UI run dashboard.
#[derive(Debug, Clone)]
pub struct TriggerClampWarning {
    pub field: &'static str,
    pub original: usize,
    pub clamped_to: usize,
}

impl Trigger {
    /// Create a new trigger.
    ///
    /// When `trigger_type` is `FocusDrift`, the configured `window_size` is
    /// clamped to `FOCUS_DRIFT_WINDOW_MAX` and a `tracing::warn!` records it, so
    /// a misconfigured sequence is visible in the logs. Callers that want to
    /// reject invalid windows up front use [`Trigger::new_focus_drift_checked`]
    /// instead, which returns an `Err(String)` for sizes exceeding the cap.
    pub fn new(
        id: impl Into<String>,
        name: impl Into<String>,
        trigger_type: TriggerType,
        recovery_action: RecoveryAction,
    ) -> Self {
        let (trigger_type, clamp_warning) = clamp_focus_drift_window(trigger_type);
        Self {
            id: id.into(),
            name: name.into(),
            trigger_type,
            recovery_action,
            enabled: true,
            cooldown_secs: None,
            last_triggered: None,
            hfr_bad_frame_count: 0,
            last_hfr_seq: None,
            focus_drift_hfr_window: VecDeque::new(),
            clamp_warning,
            cloud_cover_above_threshold_since: None,
            transparency_below_threshold_since: None,
            was_firing: false,
        }
    }

    /// Construct a `FocusDrift` trigger, rejecting `window_size` values
    /// above `FOCUS_DRIFT_WINDOW_MAX` instead of clamping silently. This is
    /// the preferred entry point when loading a user-provided sequence: a
    /// clear error message lets the UI surface the misconfiguration rather
    /// than silently truncating the user's value.
    pub fn new_focus_drift_checked(
        id: impl Into<String>,
        name: impl Into<String>,
        window_size: usize,
        min_increasing_count: usize,
        min_total_increase: f64,
        recovery_action: RecoveryAction,
    ) -> Result<Self, String> {
        if window_size > FOCUS_DRIFT_WINDOW_MAX {
            return Err(format!(
                "FocusDrift window_size {} exceeds maximum {}. \
                 Reduce window_size in the trigger configuration.",
                window_size, FOCUS_DRIFT_WINDOW_MAX
            ));
        }
        Ok(Self::new(
            id,
            name,
            TriggerType::FocusDrift {
                window_size,
                min_increasing_count,
                min_total_increase,
            },
            recovery_action,
        ))
    }

    /// Set cooldown duration
    pub fn with_cooldown(mut self, secs: u64) -> Self {
        self.cooldown_secs = Some(secs);
        self
    }

    /// Forget a firing the run did not act on.
    ///
    /// [`Trigger::check`] starts the cooldown whenever it fires, whether or
    /// not anything acts on the firing. A firing the trigger monitor drops
    /// because the run is held (paused, or in a recovery) must not spend it,
    /// or the trigger stays silent for up to its cooldown after the hold ends.
    pub fn rearm_after_hold(&mut self) {
        self.last_triggered = None;
    }

    /// Forget everything this trigger learned during a previous run: its
    /// cooldown, its edge latch, and the frames it was counting. The trigger
    /// list outlives every run, so a cooldown started last night silenced the
    /// trigger at the start of tonight's run, and a half-full HFR window
    /// judged tonight's first frame against last night's.
    pub fn reset_for_new_run(&mut self) {
        self.last_triggered = None;
        self.was_firing = false;
        self.hfr_bad_frame_count = 0;
        self.last_hfr_seq = None;
        self.focus_drift_hfr_window.clear();
        self.cloud_cover_above_threshold_since = None;
        self.transparency_below_threshold_since = None;
    }

    /// Check if the trigger is in cooldown
    pub fn is_in_cooldown(&self) -> bool {
        if let (Some(cooldown), Some(last)) = (self.cooldown_secs, self.last_triggered) {
            last.elapsed() < Duration::from_secs(cooldown)
        } else {
            false
        }
    }

    /// Check if the trigger condition is met
    pub async fn check(&mut self, state: &TriggerState) -> bool {
        if !self.enabled || self.is_in_cooldown() {
            return false;
        }

        let triggered = match &self.trigger_type {
            TriggerType::HfrDegraded {
                threshold_percent,
                absolute_threshold,
                consecutive_frames,
            } => {
                if state.autofocus_invalidated {
                    tracing::info!(
                        "HFR trigger forcing autofocus because autofocus state was invalidated: {:?}",
                        state.autofocus_invalidation_reason
                    );
                    self.hfr_bad_frame_count = (*consecutive_frames).max(1);
                    true
                } else {
                    let current = match state.current_hfr {
                        Some(v) => v,
                        None => return false,
                    };

                    let required = (*consecutive_frames).max(1);
                    // only advance the consecutive-bad-frame counter when
                    // a NEW frame has been graded. check() runs on the ~1Hz
                    // monitor tick, so counting per tick made `consecutive_frames`
                    // mean "seconds" — the trigger fired partway through a SINGLE
                    // bad sub. Gate on the per-frame HFR sample sequence; on a
                    // stale tick return the latched decision unchanged.
                    if self.last_hfr_seq == Some(state.hfr_sample_seq) {
                        return self.hfr_bad_frame_count >= required;
                    }
                    self.last_hfr_seq = Some(state.hfr_sample_seq);

                    // A threshold of 0.0 means "this branch is disabled" — both
                    // modes share the trigger and either alone can fire. Users
                    // typically pick one; the OR below makes the choice
                    // declarative rather than requiring a separate "mode" enum.
                    let exceeds_absolute =
                        *absolute_threshold > 0.0 && current > *absolute_threshold;

                    let exceeds_relative = if *threshold_percent > 0.0 {
                        if let Some(baseline) = state.baseline_hfr {
                            if baseline > 0.0 {
                                let increase = (current - baseline) / baseline * 100.0;
                                increase > *threshold_percent
                            } else {
                                false
                            }
                        } else {
                            false
                        }
                    } else {
                        false
                    };

                    let is_bad = exceeds_absolute || exceeds_relative;

                    // A single bad frame is usually a seeing spike, not a real
                    // focus problem. consecutive_frames is the user's tolerance
                    // for how many bad frames in a row count as a real
                    // degradation worth interrupting the sequence over.
                    if is_bad {
                        self.hfr_bad_frame_count += 1;
                    } else {
                        self.hfr_bad_frame_count = 0;
                    }

                    self.hfr_bad_frame_count >= required
                }
            }
            TriggerType::MeridianFlip { config } => {
                // once flipped for a target, the same trigger
                // must not fire again until the target changes. Without this
                // guard, the post-flip pier-side reading could ping-pong and
                // request a second flip in the opposite direction.
                if state.has_flipped_this_target {
                    return false;
                }

                // An operator's request skips the window threshold, never the
                // preconditions below; the refusal check applies them all.
                if state.meridian_flip_requested && state.manual_flip_refusal().is_none() {
                    return true;
                }

                // A flip only means anything for a target we are tracking.
                // Hour angle comes from the MOUNT, so without this the trigger
                // fires on a run that never set a target — and the flip arm
                // then either slews to whatever coordinates were left over or
                // reports a flip failure the operator cannot act on.
                if state.target_ra.is_none() || state.target_dec.is_none() {
                    return false;
                }

                // ...and the mount has to actually be following it.
                //
                // `current_hour_angle` is now the TARGET's, which fixed the
                // flip that fired off a parked mount's home RA. It did not fix
                // the case underneath: a parked mount whose named target really
                // is past the meridian still armed the flip. That is precisely a
                // calibration block — a TargetHeader with darks under it, mount
                // parked, dome shut — and the flip then slews a parked mount,
                // retries against whatever the centering step needs, and the
                // exhausted flip coerces a run that captured every frame it was
                // asked for into FAILED (see `meridian_flip_failed` in
                // `executor/start.rs`). A dark, bias or flat is taken with the
                // shutter closed or on a flat panel, so where the mount points
                // cannot ruin it.
                //
                // These are the same two questions the Dart countdown banner
                // already asks before it will arm ("Mount is parked" / "Mount
                // not tracking" in `meridian_countdown_provider`). Only that
                // banner asked them, which is how the Imaging screen could say
                // "Meridian flip imminent — handled automatically" while the
                // Sequencer reported "attempt 2/4 failed" for the same instant.
                //
                // Both fields are `Option`: `Some(_)` is a real reading, `None`
                // means the mount never reported. Only a definite reading
                // blocks the flip, so a mount that publishes neither behaves
                // exactly as before rather than losing flips entirely.
                //
                // `OnTrackingLimitHit` is exempt: tracking having STOPPED is its
                // whole premise, and `looks_like_tracking_limit_hit` already
                // refuses a parked or slewing mount itself.
                if !matches!(
                    config.trigger_method,
                    crate::MeridianTriggerMethod::OnTrackingLimitHit
                ) && (state.mount_parked == Some(true) || state.mount_is_tracking == Some(false))
                {
                    return false;
                }

                match config.trigger_method {
                    crate::MeridianTriggerMethod::MinutesPastMeridian => {
                        // `current_hour_angle` is the TARGET's hour angle
                        // (see `TriggerState::current_hour_angle`), so the
                        // window test below is asking about the object the
                        // sequence is imaging, not about wherever the mount
                        // happens to be parked or slewing through.
                        match state.current_hour_angle {
                            Some(ha) => super::flip_window_open(
                                ha,
                                state.pier_side,
                                config.minutes_past_meridian / 60.0,
                            ),
                            None => false,
                        }
                    }
                    crate::MeridianTriggerMethod::MinutesBeforeLimit => {
                        // Requires the mount to advertise a real tracking-limit
                        // time. We deliberately do NOT fall back to estimating
                        // from HA: that estimate would be the user's previous
                        // mode (HourAngleThreshold), and silently switching
                        // modes hides misconfiguration.
                        if let Some(limit_time) = state.mount_tracking_limit_time {
                            let now = chrono::Utc::now().timestamp();
                            // Why: i64 timestamp difference -> f64; durations under
                            // ~285k years fit in f64 mantissa.
                            let minutes_to_limit = (limit_time - now) as f64 / 60.0;
                            minutes_to_limit > 0.0
                                && minutes_to_limit <= config.minutes_before_limit
                        } else {
                            false
                        }
                    }
                    crate::MeridianTriggerMethod::HourAngleThreshold => {
                        // Same window, threshold already expressed in hours.
                        match state.current_hour_angle {
                            Some(ha) => super::flip_window_open(
                                ha,
                                state.pier_side,
                                config.hour_angle_threshold,
                            ),
                            None => false,
                        }
                    }
                    crate::MeridianTriggerMethod::OnTrackingLimitHit => {
                        if !looks_like_tracking_limit_hit(state) {
                            return false;
                        }

                        // The wait period lets users absorb a brief tracking
                        // glitch (e.g. EQ8 self-recovering from a brief stall)
                        // without forcing a flip; zero means "flip immediately".
                        if config.tracking_limit_wait_minutes > 0.0 {
                            if let Some(detected_at) = state.tracking_limit_detected_at {
                                let elapsed_secs = chrono::Utc::now().timestamp() - detected_at;
                                // Why: tracking_limit_wait_minutes is f64 user-config
                                // (UI-bounded, typically 0..30). f64 -> i64 saturates
                                // per Rust 1.45 spec; negatives clamp to 0 which is
                                // the "no wait, flip immediately" semantics.
                                let wait_secs = (config.tracking_limit_wait_minutes * 60.0) as i64;
                                if elapsed_secs < wait_secs {
                                    // Why: emit "n/a" when HA is unmeasured so the log
                                    // never advertises the 0.0 sentinel as if it were real data.
                                    tracing::trace!(
                                        "Tracking limit hit: waiting {}/{}s before flip (HA={}h)",
                                        elapsed_secs,
                                        wait_secs,
                                        state
                                            .current_hour_angle
                                            .map(|v| format!("{:.2}", v))
                                            // Why: hour-angle is
                                            // Option<f64>; None means the mount has not yet
                                            // reported coordinates. "n/a" is the documented
                                            // diagnostic substitute (never 0.0, which would
                                            // mask missing data).
                                            .unwrap_or_else(|| "n/a".into())
                                    );
                                    return false;
                                }
                                // Why: see the HA formatting note above — preserve "n/a"
                                // distinction at info level too.
                                tracing::info!(
                                    "Tracking limit wait elapsed ({:.1} min), triggering meridian flip (HA={}h)",
                                    config.tracking_limit_wait_minutes,
                                    state
                                        .current_hour_angle
                                        .map(|v| format!("{:.2}", v))
                                        // Why: see equivalent above.
                                        .unwrap_or_else(|| "n/a".into())
                                );
                            } else {
                                // No timestamp yet - wait for executor to record it on next poll
                                return false;
                            }
                        } else {
                            // Why: HA may be `None` if the mount has not yet reported
                            // coordinates this poll cycle — log "n/a" rather than masking
                            // missing data as 0.0.
                            tracing::info!(
                                "Tracking limit hit detected, triggering immediate meridian flip (HA={}h, pier={:?})",
                                state
                                    .current_hour_angle
                                    .map(|v| format!("{:.2}", v))
                                    // Why: see equivalent above.
                                    .unwrap_or_else(|| "n/a".into()),
                                state.pier_side
                            );
                        }

                        true
                    }
                }
            }
            TriggerType::GuidingFailed {
                rms_threshold,
                duration_secs,
                rms_retention_secs: _,
            } => {
                // the configured retention is propagated to
                // the trigger state by `TriggerManager::sync_state_from_config`
                // (called after every config edit and on standard-trigger
                // construction). Reading state here is sufficient — the
                // history has already been trimmed by `update_guiding_rms`
                // using the propagated retention.
                if let Some(rms_history) = &state.guiding_rms_history {
                    // Work backward over the uninterrupted tail of bad samples.
                    // The oldest sample in that run must cover the full debounce
                    // interval; merely having every sample currently inside the
                    // interval be bad lets a single fresh spike fire immediately.
                    let mut bad_run = rms_history
                        .iter()
                        .rev()
                        .take_while(|(_, rms)| *rms > *rms_threshold);
                    let newest_bad = bad_run.next();
                    let oldest_bad = bad_run.last();

                    match (newest_bad, oldest_bad) {
                        (Some((newest_time, _)), Some((oldest_time, _))) => {
                            newest_time.elapsed().as_secs_f64() < *duration_secs
                                && oldest_time.elapsed().as_secs_f64() >= *duration_secs
                        }
                        _ => false,
                    }
                } else {
                    false
                }
            }
            TriggerType::AltitudeLimit { min_altitude } => {
                // A mount that is parked, or that has definitely stopped
                // tracking, is not following the target — so whatever the
                // target's altitude is, this trigger's action (skip to the
                // next target) is not the answer. The case that shipped: a
                // three-frame DARKS block under a parked simulated mount fired
                // `NextTarget` 8 ms into the run because its named target, M4,
                // sat at 16.6° against the default 30° floor. Nothing about a
                // dark, bias or flat depends on where the tube points, and the
                // Session Report then reported `Trigger fires 1` for a run in
                // which no trigger should have had anything to say.
                //
                // Deliberately the same two questions, read the same way, as
                // the meridian-flip guard above: `Some(_)` is a real reading
                // and blocks; `None` means the mount never reported and
                // behaves exactly as before, so a driver that publishes
                // neither does not lose altitude protection.
                if state.mount_parked == Some(true) || state.mount_is_tracking == Some(false) {
                    return false;
                }
                // `current_altitude` is the TARGET's altitude, computed by the
                // trigger monitor from the target's coordinates, the observing
                // site and the clock (`executor::monitoring::target_sky_state`)
                // — never the mount's own pointing, which is a different
                // question with a different answer whenever the mount is not
                // on the target.
                if let Some(alt) = state.current_altitude {
                    alt < *min_altitude
                } else {
                    false
                }
            }
            TriggerType::WeatherUnsafe => {
                // Defense-in-depth (full-night audit 2026-06-04): the in-sequencer
                // WeatherUnsafe trigger must abort when EITHER the hardware safety
                // monitor reports unsafe OR the Dart-side weather-safety verdict
                // (configured thresholds + API/cloud sources) computed unsafe. A
                // rig with no hardware safety device leaves `weather_safe` at its
                // `false`-by-default/last-poll value; the verdict is the path that
                // makes the trigger react to non-hardware weather conditions. This
                // is OR-of-unsafe (never less safe than the hardware verdict) — an
                // abstaining verdict (`None`) or a `Some(false)` SAFE verdict never
                // suppresses a hardware-unsafe reading.
                let hardware_unsafe = !state.weather_safe;
                let verdict_unsafe = state.weather_verdict_counts_unsafe();
                if hardware_unsafe || verdict_unsafe {
                    // Name the deciding input: this trigger's action is ParkAndAbort, so
                    // firing ends the night and "Sequence cancelled" alone leaves the cause
                    // readable only in the source. Logged at warn on the aborting edge, so
                    // it cannot flood a healthy run.
                    tracing::warn!(
                        "WeatherUnsafe: hardware safety monitor {}, Dart weather verdict {} \
                         (weather_safe={}, weather_verdict_unsafe={:?})",
                        if hardware_unsafe {
                            "reports UNSAFE (or has not reported yet)"
                        } else {
                            "reports safe"
                        },
                        match state.weather_verdict_unsafe {
                            Some(true) => "reports UNSAFE",
                            Some(false) => "reports safe",
                            None => "has not been pushed (abstaining)",
                        },
                        state.weather_safe,
                        state.weather_verdict_unsafe,
                    );
                    true
                } else {
                    false
                }
            }
            TriggerType::TemperatureShift { degrees } => {
                if let (Some(baseline), Some(current)) =
                    (state.baseline_temperature, state.current_temperature)
                {
                    (current - baseline).abs() > *degrees
                } else {
                    false
                }
            }
            TriggerType::FilterChange => state.filter_changed,
            TriggerType::DawnApproaching { minutes_before } => {
                // `dawn_time` is seeded by the executor when observer location
                // becomes available; absent it we cannot evaluate without
                // forcing a recompute on every poll.
                if let Some(dawn_time) = state.dawn_time {
                    let now = chrono::Utc::now().timestamp();
                    // Why: i64 timestamp difference -> f64 lossless for any
                    // single-night duration.
                    let time_to_dawn = (dawn_time - now) as f64 / 60.0;
                    // Positive `time_to_dawn` excludes the case where dawn has
                    // already passed (negative value); without it the trigger
                    // would fire continuously through the daylight hours.
                    time_to_dawn > 0.0 && time_to_dawn <= *minutes_before
                } else {
                    false
                }
            }
            TriggerType::AutofocusInterval { every_n_frames } => {
                if state.completed_exposures == 0 || *every_n_frames == 0 {
                    false
                } else {
                    let frames_since_af = state
                        .completed_exposures
                        .saturating_sub(state.last_autofocus_frame);
                    frames_since_af >= *every_n_frames
                }
            }
            TriggerType::DitherInterval { every_n_frames } => {
                if state.completed_exposures == 0
                    || *every_n_frames == 0
                    || state.node_owns_dither_cadence()
                {
                    false
                } else {
                    let frames_since_dither = state
                        .completed_exposures
                        .saturating_sub(state.last_dither_frame);
                    frames_since_dither >= *every_n_frames
                }
            }
            TriggerType::MountTrackingLost => {
                if !state.mount_tracking_expected || !state.mount_tracking_lost {
                    return false;
                }

                // Tracking-limit hits also raise mount_tracking_lost, but the
                // user wants those to drive a meridian flip, not a Pause. We
                // suppress MountTrackingLost when the limit-hit heuristic
                // matches so MeridianFlip(OnTrackingLimitHit) wins the dispatch.
                if matches!(
                    state.meridian_trigger_method,
                    Some(crate::MeridianTriggerMethod::OnTrackingLimitHit)
                ) {
                    let looks_like_limit_hit = looks_like_tracking_limit_hit(state);

                    if looks_like_limit_hit {
                        tracing::debug!(
                            "Tracking lost but matches limit-hit heuristic - deferring to MeridianFlip trigger"
                        );
                        return false;
                    }
                }

                true
            }
            TriggerType::DomeShutterNotOpen => {
                state.dome_shutter_open_expected
                    && match state.dome_shutter_status.as_deref() {
                        Some("Open") => false,
                        Some(_) => true,
                        None => true, // Unknown shutter state is treated unsafe (fail-closed).
                    }
            }
            TriggerType::GuideStarLost => {
                // `guiding_enabled` gate prevents the trigger from firing while
                // the guider is idle between sequences (e.g. during slews or
                // before a StartGuiding node has run).
                state.guiding_enabled && state.guide_star_lost
            }
            TriggerType::FocusDrift {
                window_size,
                min_increasing_count,
                min_total_increase,
            } => {
                let current = match state.current_hfr {
                    Some(v) => v,
                    None => return false,
                };

                // O(1) push to the back of the VecDeque, which the head-drop in the
                // trim loop below also relies on.
                self.focus_drift_hfr_window.push_back(current);

                // `.max(2)` guards against a misconfigured window of 0 or 1 —
                // a single sample cannot show a trend, so the math below would
                // panic on the run-start subtraction. The window is further
                // clamped to FOCUS_DRIFT_WINDOW_MAX at trigger construction
                // time, so the allocation here is bounded.
                let max_size = (*window_size).clamp(2, FOCUS_DRIFT_WINDOW_MAX);
                while self.focus_drift_hfr_window.len() > max_size {
                    // O(1) head-drop replaces the
                    // O(n) `Vec::remove(0)` shift.
                    self.focus_drift_hfr_window.pop_front();
                }

                let min_count = (*min_increasing_count).max(2);
                if self.focus_drift_hfr_window.len() < min_count {
                    return false;
                }

                // Walking from the tail forward captures the *current* trend
                // (focus drift is by definition ongoing, not historical) and
                // ignores earlier wobbles that might otherwise dilute the run.
                let window = &self.focus_drift_hfr_window;
                let mut increasing_run = 1usize;
                for i in (1..window.len()).rev() {
                    if window[i] > window[i - 1] {
                        increasing_run += 1;
                    } else {
                        break;
                    }
                }

                if increasing_run < min_count {
                    return false;
                }

                // The total-rise threshold defends against creeping near-zero
                // increases that satisfy "monotonic" but are within noise:
                // 0.01 px/frame over 5 frames is not a drift, it is jitter.
                let run_start = window.len() - increasing_run;
                // Why: `back()` returns None only if the
                // deque is empty, but the `len() < min_count` early return
                // above guarantees at least `min_count >= 2` samples are
                // present here. The unwrap documents that invariant.
                let total_increase =
                    window.back().expect("non-empty window invariant") - window[run_start];
                total_increase >= *min_total_increase
            }
            TriggerType::HumidityThreshold { max_percent } => {
                match state.current_humidity {
                    Some(humidity) => humidity > *max_percent,
                    None => false, // No humidity data - can't trigger
                }
            }
            TriggerType::DriftLimit { max_pixels } => {
                // fire when accumulated plate-solve drift exceeds
                // the configured pixel budget. The state holds the most recent
                // plate-solve coordinates and pixel scale; absent any of them
                // we cannot evaluate drift and the trigger stays inactive.
                let Some((ra_px, dec_px)) = state.calculate_drift_pixels() else {
                    return false;
                };
                // Combine in quadrature so a small drift on one axis cannot
                // mask a large drift on the other. `calculate_drift_pixels`
                // already returns absolute values.
                let drift = (ra_px * ra_px + dec_px * dec_px).sqrt();
                drift > *max_pixels
            }
            TriggerType::CloudArrivingIn {
                minutes_before,
                coverage_threshold,
            } => {
                // fire when (a) the analyzer says clouds
                // arrive within `minutes_before` minutes AND (b) the
                // predicted coverage exceeds `coverage_threshold`. The two
                // gates together prevent firing for a passing wisp.
                //
                // Coverage threshold reads `current_cloud_coverage_percent`
                // — this is the analyzer's best-known coverage at the
                // (predicted) arrival time. Using a separate "predicted
                // coverage" field would be more accurate but the analyzer
                // does not yet model that; treating the current value as
                // the prediction is the documented behaviour until the
                // analyzer exposes a forecast curve.
                let Some(arrival) = state.predicted_cloud_arrival_minutes else {
                    return false;
                };
                let Some(coverage) = state.current_cloud_coverage_percent else {
                    return false;
                };
                arrival <= *minutes_before && coverage > *coverage_threshold
            }
            TriggerType::CloudOpeningIn {
                minutes_before,
                minimum_duration_secs,
            } => {
                // fire when the analyzer predicts a clear
                // opening within `minutes_before` minutes AND the opening's
                // duration is at least `minimum_duration_secs`. Used by
                // `RecoveryAction::PauseAndWaitForClear` to auto-resume.
                let Some(opening) = state.predicted_cloud_opening_minutes else {
                    return false;
                };
                if opening > *minutes_before {
                    return false;
                }
                // A missing duration is treated as "unknown" rather than
                // "any": firing on an unknown-length opening would lead
                // the recovery layer to slew into a hole that closes
                // before settle.
                let Some(duration) = state.predicted_cloud_opening_duration_secs else {
                    return false;
                };
                duration >= *minimum_duration_secs
            }
            TriggerType::CloudCoverThreshold {
                max_percent,
                duration_secs,
            } => {
                // fire when the current cloud cover has been
                // above `max_percent` for at least `duration_secs` consecutive
                // seconds. The debounce is implemented via the per-trigger
                // `cloud_cover_above_threshold_since` timestamp so multiple
                // CloudCoverThreshold triggers with different thresholds
                // (e.g. 50% warn / 80% park) debounce independently.
                let Some(coverage) = state.current_cloud_coverage_percent else {
                    // No data => reset our debounce timer so a stale arming
                    // from a previous reading does not fire.
                    self.cloud_cover_above_threshold_since = None;
                    return false;
                };
                if coverage <= *max_percent {
                    self.cloud_cover_above_threshold_since = None;
                    return false;
                }
                // We are above threshold. Arm the debounce timer on the
                // first crossing and check elapsed on subsequent samples.
                let since = *self
                    .cloud_cover_above_threshold_since
                    .get_or_insert_with(Instant::now);
                since.elapsed().as_secs_f64() >= *duration_secs
            }
            TriggerType::TransparencyDropped {
                below_threshold,
                duration_secs,
            } => {
                // Science: fire when the live transparency reading
                // has been at or below `below_threshold` for at least
                // `duration_secs` consecutive seconds. Same debounce
                // pattern as `CloudCoverThreshold` so multiple triggers
                // (e.g. 0.7 warn / 0.4 swap) debounce independently.
                let Some(transparency) = state.current_transparency else {
                    // No data => reset our debounce timer so a stale
                    // arming from a previous reading does not fire.
                    self.transparency_below_threshold_since = None;
                    return false;
                };
                if transparency > *below_threshold {
                    self.transparency_below_threshold_since = None;
                    return false;
                }
                let since = *self
                    .transparency_below_threshold_since
                    .get_or_insert_with(Instant::now);
                since.elapsed().as_secs_f64() >= *duration_secs
            }
        };

        if triggered {
            self.last_triggered = Some(Instant::now());
        }

        triggered
    }
}
