//! Free-standing monitoring helpers the executor's trigger monitor and
//! recovery driver call: poll bounding, the stall watchdog, mount-tracking
//! edge detection, recovery escalation, and the weather-verdict staleness
//! rules. Moved verbatim out of `executor/mod.rs`.

use super::*;

pub(super) fn effective_safety_check_interval_secs(value: u64) -> u64 {
    if value == 0 {
        DEFAULT_SAFETY_CHECK_INTERVAL_SECS
    } else {
        value.clamp(5, 3600)
    }
}

/// Resolve the effective weather-verdict staleness window. `0` => the default;
/// otherwise clamped to a sane floor (the safety poll cadence) so a tiny
/// misconfiguration cannot make a still-fresh verdict warn every tick, and an
/// upper bound so a typo cannot disable the observability entirely.
pub(super) fn effective_weather_verdict_staleness_secs(value: u64) -> u64 {
    if value == 0 {
        DEFAULT_WEATHER_VERDICT_STALENESS_SECS
    } else {
        value.clamp(30, 86_400)
    }
}

/// How long any one trigger-monitor device poll may take before it is treated
/// as failed.
///
/// The monitor is the only thing enforcing weather, altitude, drift,
/// tracking-loss, dome and meridian protection while the execution branch
/// exposes. A driver call that never returns — a documented hazard on this
/// project's ASCOM path — parks the monitor's loop forever: it never reaches
/// its next tick, and the `select!` that joins it only handles the monitor
/// *exiting*, not hanging. Every poll is therefore bounded, and a poll that
/// runs out of time is reported as the poll *failure* it is, which the
/// `SafetyFailMode` ladder and each caller's `Err` arm already know how to
/// handle. Ten seconds is far longer than any healthy driver round-trip and
/// far shorter than an exposure.
pub(super) const TRIGGER_POLL_TIMEOUT_SECS: u64 = 10;

/// How long the monitor may go without completing a loop iteration before the
/// watchdog declares it dead.
///
/// A pathological iteration in which every bounded poll times out still
/// finishes well inside this window, so only a stall the per-call timeouts
/// cannot see (a blocking driver call that never yields to the runtime, a
/// deadlocked lock) reaches it.
pub(super) const TRIGGER_MONITOR_STALL_TIMEOUT_SECS: u64 = 180;

/// How often the mount is polled for tracking / slewing / parked / pier side /
/// coordinates.
///
/// Running these five calls on the monitor's 1 Hz tick is five serial
/// round-trips per second, which is expensive on ASCOM (single-threaded
/// apartment, per-call COM marshalling) and on INDI. Nothing downstream needs
/// second-resolution — tracking loss is edge-detected and then waits minutes
/// before acting, and the meridian hour angle moves 15° per hour.
pub(super) const MOUNT_POLL_INTERVAL_SECS: u64 = 5;

/// Bound one trigger-monitor device poll. See [`TRIGGER_POLL_TIMEOUT_SECS`].
pub(super) async fn bounded_poll<T>(
    what: &str,
    poll: impl std::future::Future<Output = crate::device_ops::DeviceResult<T>>,
) -> crate::device_ops::DeviceResult<T> {
    let limit = std::time::Duration::from_secs(TRIGGER_POLL_TIMEOUT_SECS);
    match tokio::time::timeout(limit, poll).await {
        Ok(result) => result,
        Err(_) => Err(format!(
            "{what} did not answer within {TRIGGER_POLL_TIMEOUT_SECS}s (treated as a poll failure)"
        )),
    }
}

/// Resolves once the trigger monitor has gone `stall_after` without completing
/// a loop iteration.
///
/// The `select!` that joins the monitor handles it exiting; it cannot see it
/// hanging, and a hung monitor looks exactly like a healthy one from the
/// outside while every protection it enforces is silently gone. This is the
/// detector for that case.
///
/// A trigger recovery action legitimately holds the loop for minutes (a
/// meridian-flip retry ladder sleeps between attempts), so the watchdog holds
/// off while one is in flight — it watches the poll phase, not the action.
pub(super) async fn trigger_monitor_stall_watchdog(
    mut heartbeat: watch::Receiver<u64>,
    action_in_flight: Arc<AtomicBool>,
    stall_after: std::time::Duration,
) {
    loop {
        match tokio::time::timeout(stall_after, heartbeat.changed()).await {
            // A fresh beat: the monitor completed another iteration.
            Ok(Ok(())) => {}
            // The monitor future was dropped, so it is already resolved and
            // whoever dropped it owns the outcome. Never win the join.
            Ok(Err(_)) => std::future::pending::<()>().await,
            Err(_) if action_in_flight.load(Ordering::Acquire) => {}
            Err(_) => return,
        }
    }
}

/// Where the ACTIVE TARGET is right now: the two sky quantities the trigger
/// monitor refreshes on every tick for the triggers that ask about the target.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(super) struct TargetSkyState {
    /// Degrees above the horizon; feeds `AltitudeLimit`.
    pub altitude_degrees: f64,
    /// Signed hour angle in hours, normalized to `[-12, +12]` — negative is
    /// east of the meridian. Feeds every `MeridianFlip` trigger method that
    /// reasons about transit, and the exposure gate that holds a frame the
    /// flip would interrupt.
    pub hour_angle_hours: f64,
}

/// Compute [`TargetSkyState`] for the active target, or `None` when either the
/// target or the observing site is unknown (nothing to compute from, and a
/// fabricated value would be worse than an inert trigger).
///
/// Both values come from the TARGET's own coordinates. The altitude always
/// did; the hour angle used to be recomputed from `mount_get_coordinates`
/// instead, which is a different question with a different answer whenever the
/// mount is not tracking the target — parked at home, mid-slew, still on the
/// previous target, or (the case that shipped) sitting at its power-on RA 0h
/// while the sequence was still changing filters. `MeridianFlip` then fired on
/// the parked mount's hour angle for a target 1.5h east of the meridian, and
/// the flip's own banner printed the target's honest `-1.50h` a millisecond
/// later. One target-derived source ends that disagreement; the exposure gate
/// in `instructions::center` was already computing the target's own hour angle
/// precisely because it could not trust this field.
///
/// `now` is a parameter rather than `Utc::now()` so the transit geometry is
/// testable without waiting for the sky to turn.
pub(super) fn target_sky_state(
    target_ra_degrees: Option<f64>,
    target_dec_degrees: Option<f64>,
    latitude: Option<f64>,
    longitude: Option<f64>,
    now: chrono::DateTime<chrono::Utc>,
) -> Option<TargetSkyState> {
    let (ra_degrees, dec_degrees, latitude, longitude) =
        match (target_ra_degrees, target_dec_degrees, latitude, longitude) {
            (Some(ra), Some(dec), Some(lat), Some(lon)) => (ra, dec, lat, lon),
            _ => return None,
        };

    // `TriggerState` stores target RA in DEGREES and in J2000 (it is compared
    // against plate-solve output); the astronomy helpers take hours, and the
    // hour angle needs the RA of date (see `meridian::target_of_date`).
    let (ra_hours, dec_degrees) =
        crate::meridian::target_of_date(ra_degrees / 15.0, dec_degrees, now);
    let lst = crate::meridian::local_sidereal_time(crate::meridian::julian_day(&now), longitude);
    Some(TargetSkyState {
        altitude_degrees: crate::meridian::calculate_altitude(
            ra_hours,
            dec_degrees,
            latitude,
            longitude,
            now,
        ),
        hour_angle_hours: crate::meridian::hour_angle(ra_hours, lst),
    })
}

/// Decide whether a mount tracking poll represents a genuine *loss* of tracking
/// (an ON → OFF transition) rather than tracking simply not having started yet.
///
/// "Lost" means tracking was observed ON and then went OFF, so the PREVIOUS
/// reading (`previously_tracking`) must have been `Some(true)`. A first poll
/// (`None`) or a mount that has not yet started tracking never trips it — a
/// level-triggered `expected && !tracking` test fires `MountTrackingLost` on
/// the very first poll of a still-parked mount and self-cancels the sequence
/// seconds after start, and `safety_fail_mode = FailOpen` cannot suppress a
/// mount trigger. A genuine mid-sequence drop (`Some(true)` → `false`) still
/// trips it.
pub(super) fn mount_tracking_just_lost(
    tracking_expected: bool,
    currently_tracking: bool,
    previously_tracking: Option<bool>,
    already_flagged_lost: bool,
) -> bool {
    tracking_expected
        && !currently_tracking
        && !already_flagged_lost
        && previously_tracking == Some(true)
}

/// One mount-tracking poll's verdict for the trigger monitor's device-
/// readiness gate. `currently_tracking` is the fresh `mount_is_tracking`
/// reading; the other arguments are the baseline carried in `TriggerState`.
///
/// Returns `(expected, just_lost)`:
///   * `expected` is the new tracking-loss baseline. It is armed
///     LAZILY — set to `true` only once the mount has been OBSERVED actually
///     tracking, never assumed at monitor start. Until the first `Ok(true)`
///     reading a not-yet-tracking / still-parked / headless mount keeps it
///     `false`, so the loss detector stays disarmed and a loaded sequence
///     cannot self-cancel at startup. The baseline only ever latches up, so a
///     value restored from a mid-session checkpoint is preserved.
///   * `just_lost` is whether this poll is a genuine ON → OFF loss, evaluated
///     against the (possibly freshly armed) `expected` baseline.
pub(super) fn mount_tracking_poll_verdict(
    expected_before: bool,
    currently_tracking: bool,
    previously_tracking: Option<bool>,
    already_flagged_lost: bool,
) -> (bool, bool) {
    let expected = expected_before || currently_tracking;
    let just_lost = mount_tracking_just_lost(
        expected,
        currently_tracking,
        previously_tracking,
        already_flagged_lost,
    );
    (expected, just_lost)
}

/// Apply one mount tracking poll to the trigger state's loss baseline and
/// return whether it is a genuine loss (see [`mount_tracking_poll_verdict`]).
/// The caller records the reading in `mount_is_tracking` afterwards.
///
/// While the run itself has tracking off for the pre-meridian hold (see
/// `instructions::pre_meridian_hold`) nothing is a loss: the baseline stays
/// disarmed and the first `true` after the hold arms it again. Without this the
/// hold's own stop read as "Mount tracking lost during sequence!", the run went
/// into a recovery, and the recovery restarted tracking towards the tripod.
pub(crate) fn apply_mount_tracking_poll(
    state: &mut TriggerState,
    currently_tracking: bool,
) -> bool {
    if state.run.is_held_by_run() {
        state.set_mount_tracking_expected(false);
        return false;
    }
    let (mut expected, just_lost) = mount_tracking_poll_verdict(
        state.tracking.is_expected(),
        currently_tracking,
        state.mount_is_tracking,
        state.tracking.is_lost(),
    );
    // A reading taken while the run moves the mount does not arm the
    // baseline: a park or home turns tracking off at its end, and that stop is
    // the run's own.
    if state.guiding.in_motion() {
        expected = state.tracking.is_expected();
    }
    // A loss stays recorded across repeated stopped readings until tracking
    // actually resumes; re-arming here would forget it.
    if expected != state.tracking.is_expected() {
        state.set_mount_tracking_expected(expected);
    }
    if currently_tracking {
        state.tracking.clear_lost();
    }
    just_lost
}

/// The first-class [`crate::recovery::RecoveryCause`] a standard trigger maps
/// to, or `None` for a trigger with no automatic recovery semantic (an
/// operator-defined watchdog, FilterChange, and the rest).
///
/// A trigger with a cause can be handed to the recovery driver, which FREEZES
/// THE NODE TREE for the length of its attempt ladder. That freeze is the part
/// that matters: it is the only thing that stops the capture loop from taking
/// more frames while a device the run depends on is known to be broken.
///
/// `guiding_failed` is here for exactly that reason. Its standard action is
/// `Retry { max_attempts: 3 }`, and on the trigger side a `Retry` had no
/// operation to re-run — it incremented a counter and logged "requested retry
/// attempt 1/3" while the run went on exposing. Measured on 2026-09-14: the
/// trigger fired at 02:59:10, 03:00:11 and 03:01:11 with guiding RMS far past
/// its 2.0 px threshold, and three 180 s lights were taken across those two
/// minutes. Every one was rejected. Since the owner's 2026-10-06 decision that
/// hand-off happens only when the operator turned on "Stop the run for quality
/// problems"; by default the trigger notifies (see `apply_quality_policy`).
pub fn trigger_recovery_cause(trigger_id: &str) -> Option<crate::recovery::RecoveryCause> {
    match trigger_id {
        "guide_star_lost" | "guiding_failed" => Some(crate::recovery::RecoveryCause::GuideStarLost),
        "mount_tracking_lost" | "on_tracking_limit_hit" => {
            Some(crate::recovery::RecoveryCause::MountTrackingLost)
        }
        "weather_unsafe" | "humidity_threshold" | "temperature_limit" => {
            Some(crate::recovery::RecoveryCause::WeatherUnsafe)
        }
        "focus_drift" => Some(crate::recovery::RecoveryCause::FocusDriftCritical),
        _ => None,
    }
}

/// What a fired trigger does once the operator's park settings are applied.
#[derive(Debug, Clone)]
pub(crate) struct FiredTriggerAction {
    pub action: RecoveryAction,
    /// End the run the way `ParkAndAbort` does, but leave the mount, cover and
    /// dome alone: "Park before dawn" is off.
    pub end_without_parking: bool,
    /// Tell the operator and keep imaging instead of running `action`: the
    /// trigger judged quality, and "Stop the run for quality problems" is
    /// off. See [`apply_quality_policy`].
    pub notify_only: bool,
}

impl FiredTriggerAction {
    /// The action as the trigger-fired event and decision row name it. The
    /// app reads `ParkAndAbort` there as "the trigger ended the run and parked
    /// the mount", so a run ended without parking must not say it.
    pub(crate) fn wire_label(&self) -> String {
        if self.notify_only {
            "Notify".to_string()
        } else if self.end_without_parking {
            "Abort".to_string()
        } else {
            format!("{:?}", self.action)
        }
    }
}

/// Apply the operator's "Park on unsafe weather" and "Park before dawn"
/// settings to a standard trigger's configured action.
///
/// Both standard triggers ship as `ParkAndAbort`, and the executor never heard
/// of the two settings, so switching them off changed nothing: the mount was
/// parked and the cover and dome closed anyway. With a setting off the trigger
/// still protects the data, by the least surprising existing action:
///   * Weather unsafe becomes `Pause`, which for this trigger is the weather
///     recovery ladder: nothing more is exposed, the operator is alerted, and
///     the run resumes when both the hardware and the app's verdict read safe.
///   * Dawn approaching still ends the run, without parking or closing.
///
/// Matched on the standard trigger ids only. A Recovery node the operator put
/// in the sequence with Park and Abort is their explicit choice for that
/// sequence and is left alone.
///
/// `weather_advisory_only` is true when the unsafe weather rests only on a
/// forecast or cloud model (see
/// [`crate::triggers::TriggerState::weather_unsafe_is_advisory_only`]). A
/// forecast never parks the mount or ends the run, whatever the park setting:
/// it holds the run, which resumes on its own when the sky clears.
pub(crate) fn apply_park_policy(
    trigger_id: &str,
    action: RecoveryAction,
    policy: ParkPolicy,
    weather_advisory_only: bool,
) -> FiredTriggerAction {
    let parks = matches!(action, RecoveryAction::ParkAndAbort);
    match trigger_id {
        "weather_unsafe" if parks && (weather_advisory_only || !policy.park_on_unsafe_weather) => {
            FiredTriggerAction {
                action: RecoveryAction::Pause,
                end_without_parking: false,
                notify_only: false,
            }
        }
        "dawn_approaching" if parks && !policy.park_before_dawn => FiredTriggerAction {
            action,
            end_without_parking: true,
            notify_only: false,
        },
        _ => FiredTriggerAction {
            action,
            end_without_parking: false,
            notify_only: false,
        },
    }
}

/// The standard trigger that judges guiding by its RMS.
pub(crate) const GUIDING_FAILED_TRIGGER_ID: &str = "guiding_failed";

/// Apply the operator's "Stop the run for quality problems" setting to a fired
/// standard trigger.
///
/// The standard Guiding Failure trigger fires on guiding RMS over a threshold
/// while the guider is still guiding. That is a judgment of the frames, and it
/// handed the run to the recovery driver, which froze it for up to 90 minutes
/// of re-acquisition and then ended it. Owner decision 2026-10-06: only a risk
/// to the hardware stops a run by itself. So unless the operator turned the
/// setting on, it notifies once per episode and the run keeps imaging. A lost
/// guide star (the guider stopped guiding) is the Guide Star Lost trigger and
/// keeps its recovery.
pub(crate) fn apply_quality_policy(
    trigger_id: &str,
    fired: FiredTriggerAction,
    stop_on_quality_problems: bool,
) -> FiredTriggerAction {
    // An operator-authored Notify always notifies.
    if matches!(fired.action, RecoveryAction::Notify)
        || (trigger_id == GUIDING_FAILED_TRIGGER_ID && !stop_on_quality_problems)
    {
        FiredTriggerAction {
            notify_only: true,
            ..fired
        }
    } else {
        fired
    }
}

/// The Warning a notify-only trigger puts in the run's feed: what it measured
/// and that the run goes on.
pub(crate) fn quality_trigger_notice(
    trigger_name: &str,
    trigger_id: &str,
    manager: &crate::triggers::TriggerManager,
    state: &TriggerState,
) -> String {
    let detail = match manager.get_trigger(trigger_id).map(|t| &t.trigger_type) {
        Some(TriggerType::GuidingFailed {
            rms_threshold,
            duration_secs,
            ..
        }) => {
            let latest = state
                .guiding_rms_history
                .as_ref()
                .and_then(|history| history.last())
                .map(|(_, rms)| format!(" (latest {rms:.2} px)"))
                .unwrap_or_default();
            format!(
                "guiding RMS has been over {rms_threshold:.2} px for {duration_secs:.0} s{latest} \
                 while the guider is still guiding"
            )
        }
        Some(TriggerType::HfrDegraded { .. } | TriggerType::FocusDrift { .. }) => {
            match (state.current_hfr, state.baseline_hfr) {
                (Some(hfr), Some(baseline)) => {
                    format!("HFR is {hfr:.2} px against a baseline of {baseline:.2} px")
                }
                (Some(hfr), None) => format!("HFR is {hfr:.2} px"),
                _ => "its condition holds".to_string(),
            }
        }
        Some(TriggerType::DriftLimit { max_pixels }) => match state.calculate_drift_pixels() {
            Some((ra, dec)) => format!(
                "the last plate solve is {:.0} px from the target (limit {max_pixels:.0} px)",
                ra.hypot(dec)
            ),
            None => "its condition holds".to_string(),
        },
        Some(TriggerType::TransparencyDropped {
            below_threshold, ..
        }) => match state.current_transparency {
            Some(t) => format!("transparency is {t:.2} (limit {below_threshold:.2})"),
            None => "its condition holds".to_string(),
        },
        _ => "its condition holds".to_string(),
    };
    format!(
        "{trigger_name}: {detail}. Imaging continues; you will hear about this again only after \
         it clears and comes back. To have it stop the run instead, turn on Stop the run for \
         quality problems in Settings > Sequencer."
    )
}

/// How long a notify-only trigger has to stay quiet before its next firing is
/// a new episode the operator is told about. A trigger whose condition holds
/// fires again as soon as its cooldown expires; a minute's margin covers a
/// monitor tick held up by slow device polls.
pub(crate) fn notify_episode_gap(cooldown_secs: Option<u64>) -> std::time::Duration {
    std::time::Duration::from_secs(cooldown_secs.unwrap_or(0) + 60)
}

/// How a non-auto-recoverable recovery escalation (an `AttemptOutcome::
/// PauseForOperator`, e.g. from a consecutive-reject storm) must be handled.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EscalationDisposition {
    /// Drive the safe-state sweep (park mount + close cover + close dome) and
    /// fail the run. Taken only when the operator has explicitly asked for it
    /// via [`UnattendedEndPolicy::ParkAndClose`].
    SafeAbandon,
    /// Passively pause and hand the run to the operator for inspection /
    /// resume (after restoring tracking). Nothing is moved or closed.
    PassivePause,
}

/// What a run is allowed to do to the hardware when recovery cannot fix the
/// problem and there is nobody known to be watching.
///
/// Derived from the operator's
/// [`RecoveryRuntimeConfig::park_and_close_when_recovery_gives_up`] setting,
/// which is off by default and documents why. It replaces an inferred
/// `operator_present` flag that had no writer anywhere in the product, and so
/// read "nobody is here" on every run.
///
/// The enum exists rather than passing the bool around because three separate
/// sites decide on it — the `PauseForOperator` escalation, the retry ladder's
/// give-up branch, and the operator-facing log lines — and a named value with a
/// `label()` is what keeps their wording and their behaviour together.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum UnattendedEndPolicy {
    /// DEFAULT. Hold the run for a human: freeze the node tree, restore
    /// tracking, keep safety-class triggers armed (see the trigger monitor's
    /// paused-state gate) and wait. No mount motion, no cover, no dome.
    ///
    /// The old code rejected a passive pause on the grounds that it left the
    /// rig "dome+cover OPEN with safety monitoring OFF until dawn". That was
    /// true, and it was a separate defect: the monitor returned early on any
    /// non-`Running` state, so a Paused run had no weather, altitude or dawn
    /// evaluation at all. Safety-class triggers now keep evaluating while
    /// paused, so a hold is protected by the same rules an imaging run is, and
    /// no longer needs a park to be safe.
    #[default]
    HoldForOperator,
    /// Opt-in. Run the park → close cover → close dome sweep and fail the run.
    /// For a genuinely remote rig whose owner would rather lose the night than
    /// leave the optics open behind a hold.
    ParkAndClose,
}

impl UnattendedEndPolicy {
    /// Read the policy from the operator's recovery settings. The single
    /// conversion point between the persisted setting and the decision type.
    pub fn from_recovery_config(config: &crate::recovery::RecoveryRuntimeConfig) -> Self {
        if config.park_and_close_when_recovery_gives_up {
            UnattendedEndPolicy::ParkAndClose
        } else {
            UnattendedEndPolicy::HoldForOperator
        }
    }

    /// Whether this policy permits the run to move or close hardware by itself.
    pub fn may_safe_abandon(self) -> bool {
        matches!(self, UnattendedEndPolicy::ParkAndClose)
    }

    /// Operator-facing name, used in the log line that records which policy
    /// decided the outcome so a report never has to guess.
    pub fn label(self) -> &'static str {
        match self {
            UnattendedEndPolicy::HoldForOperator => "hold for operator",
            UnattendedEndPolicy::ParkAndClose => "park and close",
        }
    }
}

/// Decide how a `PauseForOperator` recovery escalation is handled.
///
/// Factored out of the executor task so the safety decision is unit-testable on
/// its own. Every irreversible sweep in the recovery path — this escalation and
/// the retry-ladder give-up branch — asks this one question, so there is no
/// second path that parks under another name.
pub(super) fn recovery_escalation_disposition(
    policy: UnattendedEndPolicy,
) -> EscalationDisposition {
    if policy.may_safe_abandon() {
        EscalationDisposition::SafeAbandon
    } else {
        EscalationDisposition::PassivePause
    }
}

/// Re-enable mount tracking after a recovery loop that stopped it
/// (`stop_tracking_during_recovery`), emitting a LOUD error if it cannot be
/// restored.
///
/// Recovery entry stops tracking by default, and the generic Resume command
/// does not restore it, so any path that resumes or hands the run back to the
/// operator must call this first — otherwise the sequence exposes on a
/// non-tracking mount and every frame trails while the UI reports "Running".
/// Both the recovered-resume branch and the attended operator-Pause branch go
/// through here. A failure is never silent: it logs at error level and
/// forwards an `ExecutorEvent::Error`.
///
/// `context_label` distinguishes the wording ("after recovery" vs "before
/// operator Pause") so the operator sees which path could not restore tracking.
/// Returns `Some(message)` iff tracking restoration failed (also already
/// emitted), so callers/tests can assert on it.
pub(super) async fn restore_tracking_after_recovery(
    device_ops: &SharedDeviceOps,
    mount_id: Option<&str>,
    stop_tracking: bool,
    context_label: &str,
    event_tx: &broadcast::Sender<ExecutorEvent>,
) -> Option<String> {
    if !stop_tracking {
        return None;
    }
    let mount_id = mount_id?;

    // Never command tracking on a PARKED mount.
    //
    // Observed on the live rig: a MoveRotator failure on a rig with no rotator
    // drove the recovery ladder, and this resume path then issued
    // `set tracking = true` on a parked Pegasus NYX-101 — unprompted motion
    // intent on stowed hardware, from a failure that had nothing to do with the
    // mount. It was refused (0x80020009) only because the driver happened to
    // reject it while parked; a mount that accepted would have started sidereal
    // motion against its park latch.
    //
    // A park is also a deliberate safe state — the operator, the weather rule,
    // or the dawn shutdown put it there — and automatic recovery must not take
    // a rig out of a safe state on its own initiative.
    //
    // Reporting matters as much as the command: the generic failure branch
    // below shouts "resumed frames may trail until tracking is restored",
    // which is untrue of a parked mount that is not imaging at all. Say what is
    // actually the case instead.
    match device_ops.mount_is_parked(mount_id).await {
        Ok(true) => {
            tracing::warn!(
                "[RECOVERY] Not re-enabling tracking on '{}' {}: the mount is \
                 parked. Recovery does not un-park a mount on its own.",
                mount_id,
                context_label
            );
            let message = format!(
                "Recovery {} but tracking was not re-enabled on {}: the mount \
                 is parked. Un-park it before resuming imaging.",
                context_label, mount_id
            );
            let _ = event_tx.send(ExecutorEvent::Error {
                message: message.clone(),
            });
            return Some(message);
        }
        Ok(false) => {}
        // Unknown park state: proceed. Refusing to restore tracking because the
        // park flag could not be read would strand a genuinely tracking-capable
        // mount untracked, which is the failure this whole function exists to
        // prevent. The set below reports its own outcome truthfully either way.
        Err(e) => {
            tracing::warn!(
                "[RECOVERY] Could not read park state of '{}' {} ({}); \
                 attempting to restore tracking anyway.",
                mount_id,
                context_label,
                e
            );
        }
    }

    match device_ops.mount_set_tracking(mount_id, true).await {
        Ok(()) => {
            tracing::info!(
                "[RECOVERY] Re-enabled tracking on '{}' {}",
                mount_id,
                context_label
            );
            None
        }
        Err(e) => {
            tracing::error!(
                "[RECOVERY] Failed to re-enable tracking on '{}' {}: {}",
                mount_id,
                context_label,
                e
            );
            let message = format!(
                "Recovery {} but tracking could not be re-enabled on {}: {} — resumed frames may trail until tracking is restored.",
                context_label, mount_id, e
            );
            let _ = event_tx.send(ExecutorEvent::Error {
                message: message.clone(),
            });
            Some(message)
        }
    }
}

/// Shared state the recovery driver hands to [`apply_recovery_escalation`] so
/// the escalation branch can be driven (and asserted on) without spinning up
/// the whole 7000-line trigger-monitor closure.
///
/// All fields are borrows of the executor's live shared state — the same
/// `Arc<…>` clones the inline driver captured — so the extracted function
/// mutates exactly the production state and emits on the production event bus.
pub(crate) struct RecoveryEscalationState<'a> {
    pub device_ops: &'a SharedDeviceOps,
    pub event_tx: &'a broadcast::Sender<ExecutorEvent>,
    pub runtime_config: &'a Arc<StdRwLock<RuntimeConfig>>,
    pub state: &'a Arc<RwLock<ExecutorState>>,
    pub progress: &'a Arc<StdRwLock<SequenceProgress>>,
    pub current_recovery: &'a Arc<StdRwLock<Option<crate::recovery::RecoveryContext>>>,
    pub is_cancelled: &'a Arc<AtomicBool>,
    pub gave_up: &'a Arc<AtomicBool>,
    pub mount_id: Option<&'a str>,
    pub cover_id: Option<&'a str>,
    pub dome_id: Option<&'a str>,
}

/// Apply a `PauseForOperator` recovery escalation, exactly as the recovery
/// driver loop does once an `AttemptOutcome::PauseForOperator` ends the retry
/// loop. A free function rather than inline driver code so an integration test
/// can drive the real device-ops and assert the call ORDER (tracking restored
/// BEFORE the Paused `StateChanged`) and the SafeAbandon path (park+close →
/// Failed, never a resumable Paused-untracked state).
///
/// The disposition is derived live from the operator's
/// [`UnattendedEndPolicy`]:
///   * `HoldForOperator` (default) → PassivePause: restore tracking, flip to
///     Paused, move nothing.
///   * `ParkAndClose` (opt-in) → SafeAbandon: park mount, close cover+dome,
///     FAIL.
pub(super) async fn apply_recovery_escalation(
    s: &RecoveryEscalationState<'_>,
    ctx: &crate::recovery::RecoveryContext,
    pause_message: String,
    stop_tracking: bool,
) {
    // Read the policy live so an operator changing it mid-session takes effect
    // on THIS escalation.
    let policy = UnattendedEndPolicy::from_recovery_config(&s.runtime_config.read().recovery);
    let disposition = recovery_escalation_disposition(policy);

    if disposition == EscalationDisposition::SafeAbandon {
        // The operator has set `UnattendedEndPolicy::ParkAndClose`, so this
        // escalation is a SAFE ABANDONMENT, identical to the give-up branch:
        // park the mount (the OTA can't track into the Sun at dawn), close the
        // cover, close the dome (verified — see `park_and_close_safe_state`),
        // then FAIL the run, which cancels the node tree.
        //
        // Only an explicit setting reaches here. Nothing about a reject storm
        // is evidence that the rig is unattended, and this sweep is the one
        // action in the recovery path that cannot be undone from the couch.
        tracing::error!(
            "[RECOVERY] Escalated {:?} to operator Pause after {} attempt{}: {} — operator policy is '{}', so abandoning safely (park + close cover + close dome)",
            ctx.cause,
            ctx.attempt_count,
            if ctx.attempt_count == 1 { "" } else { "s" },
            pause_message,
            policy.label()
        );
        s.gave_up.store(true, Ordering::Relaxed);
        *s.current_recovery.write() = None;

        // Surface WHY first, so the operator / push channel sees the escalation
        // reason even if a safe-state step then fails.
        let _ = s.event_tx.send(ExecutorEvent::Error {
            message: pause_message.clone(),
        });

        // Single source of truth for the park → close cover → close dome sweep.
        // Mirror the give-up branch's retry tuning (2 park retries, 2s delay) so
        // behaviour is identical.
        let outcome = crate::device_ops::park_and_close_safe_state(
            s.device_ops,
            s.mount_id,
            s.cover_id,
            s.dome_id,
            2,
            2.0,
        )
        .await;

        if let (Some(mount_id), Some(park)) = (s.mount_id, &outcome.park) {
            if park.success {
                tracing::info!(
                    "[RECOVERY] Parked mount '{}' because the operator's park-and-close policy \
                     is on ({} attempt{})",
                    mount_id,
                    park.attempts_made,
                    if park.attempts_made == 1 { "" } else { "s" }
                );
            } else {
                let msg = format!(
                    "Reject-storm abandonment: the mount could not be parked ({}): {} — mount may be UNSAFE.",
                    mount_id,
                    park.last_error
                        .clone()
                        .unwrap_or_else(|| "unknown".to_string())
                );
                tracing::error!("[RECOVERY] {}", msg);
                let _ = s.event_tx.send(ExecutorEvent::Error { message: msg });
            }
        }
        if let (Some(cover_id), Some(e)) = (s.cover_id, &outcome.cover_close_error) {
            let msg = format!(
                "Reject-storm abandonment: failed to close cover '{}': {}",
                cover_id, e
            );
            tracing::error!("[RECOVERY] {}", msg);
            let _ = s.event_tx.send(ExecutorEvent::Error { message: msg });
        }
        if let (Some(dome_id), Some(e)) = (s.dome_id, &outcome.dome_close_error) {
            let msg = format!(
                "Reject-storm abandonment: failed to close dome '{}': {} — scope may be exposed.",
                dome_id, e
            );
            tracing::error!("[RECOVERY] {}", msg);
            let _ = s.event_tx.send(ExecutorEvent::Error { message: msg });
        }

        // Cancel the node tree and fail the run, exactly like the give-up
        // branch. The safety triggers keep protecting the rig right up to this
        // point (state was Recovering, never a passive Paused), and the rig now
        // sits in the safe parked+closed end-state rather than dome-open and
        // unmonitored.
        s.is_cancelled.store(true, Ordering::Relaxed);
        *s.state.write().await = ExecutorState::Failed;
        {
            let mut prog = s.progress.write();
            prog.state = ExecutorState::Failed;
            prog.message = Some(format!(
                "{}: abandoned safely after {} attempt{} (park-and-close policy)",
                ctx.cause.display_label(),
                ctx.attempt_count,
                if ctx.attempt_count == 1 { "" } else { "s" }
            ));
        }
        let _ = s
            .event_tx
            .send(ExecutorEvent::StateChanged(ExecutorState::Failed));
        let _ = s.event_tx.send(ExecutorEvent::RecoveryGaveUp {
            context: Box::new(ctx.clone()),
            aborted_by_user: false,
        });
    } else {
        // DEFAULT. Escalate to a real operator Pause: leave the node tree
        // frozen (is_paused == true from step 2) and flip to the same Paused
        // state the operator's Pause command produces. This does NOT
        // park-and-abort the rig and does NOT auto-resume. The operator's
        // Resume clears is_paused and flips back to Running.
        //
        // This is what the escalation message has always promised ("sequence
        // paused for inspection. Resume once conditions clear"), and it is the
        // action the run can be talked out of.
        tracing::warn!(
            "[RECOVERY] Escalated {:?} to operator Pause after {} attempt{}: {} — holding the run for a human; nothing moved or closed",
            ctx.cause,
            ctx.attempt_count,
            if ctx.attempt_count == 1 { "" } else { "s" },
            pause_message
        );

        // Restore tracking BEFORE handing off to the operator
        // Pause. Recovery entry stops tracking (the default); the generic Resume
        // path does NOT re-enable it, so resuming from this Pause would expose
        // on a non-tracking mount and every frame would trail with the UI saying
        // "Running". Mirror the recovered branch (same shared helper): restore
        // tracking for all causes, loud error on failure (never silently leave a
        // resumable Pause that exposes untracked).
        let tracking_warning = restore_tracking_after_recovery(
            s.device_ops,
            s.mount_id,
            stop_tracking,
            "paused for operator",
            s.event_tx,
        )
        .await;

        *s.state.write().await = ExecutorState::Paused;
        {
            let mut prog = s.progress.write();
            prog.state = ExecutorState::Paused;
            // The status API (`sequencer_get_status`) reads this snapshot, not
            // the event stream. Dropping the restore verdict here left the
            // pause reason alone on screen while the mount sat untracked, so
            // the operator's Resume exposed on a drifting mount. Carry the
            // helper's verdict into the message the poller actually reads.
            prog.message = Some(match &tracking_warning {
                Some(warning) => format!("{pause_message} — {warning}"),
                None => pause_message.clone(),
            });
        }
        *s.current_recovery.write() = None;
        // Surface the reason as a critical-event banner so the operator (and any
        // push channel) sees why the run stopped.
        let _ = s.event_tx.send(ExecutorEvent::Error {
            message: pause_message,
        });
        let _ = s
            .event_tx
            .send(ExecutorEvent::StateChanged(ExecutorState::Paused));
        // Close out the recovery banner — the loop ended, it did not give up (no
        // park/fail), it handed off to a Pause.
        let _ = s.event_tx.send(ExecutorEvent::RecoveryCompleted {
            context: Box::new(ctx.clone()),
        });
    }
}

/// Subsystem 2 step 3 (stale-verdict observability): build the loud
/// "verdict feed stale; holding paused fail-closed" warning that the safety
/// poll emits when a `Some(true)`=UNSAFE Dart verdict has not been refreshed
/// within the staleness window.
///
/// Returns `Some(message)` ONLY on the rising edge (stale-and-unsafe AND not
/// already warned), advancing `*already_warned` to `true` so a dead feed does
/// not flood the event stream every poll. When the condition clears it re-arms
/// the latch (so a recovered-then-re-degraded feed warns again) and returns
/// `None`. This is pure observability — it NEVER touches or clears the verdict.
///
/// Factored out so the emission decision (gate + rate-limit + message) is
/// unit-testable without spinning up the full executor task; the loop calls it
/// and just forwards any returned message as an `ExecutorEvent::Error`.
pub(super) fn weather_verdict_stale_warning(
    stale_unsafe: bool,
    staleness_secs: u64,
    already_warned: &mut bool,
) -> Option<String> {
    if stale_unsafe {
        if *already_warned {
            return None;
        }
        *already_warned = true;
        Some(format!(
            "Weather verdict feed stale ({}s without a refresh); holding the \
             sequence paused fail-closed. The last Dart weather verdict was \
             UNSAFE and has not been refreshed — the hold will continue until a \
             fresh verdict arrives. Operator attention required.",
            staleness_secs
        ))
    } else {
        // Fresh (or no-longer-unsafe) verdict — re-arm so a future stale-unsafe
        // episode warns again.
        *already_warned = false;
        None
    }
}

/// Whether an UNSAFE app verdict that has gone stale keeps holding the run.
///
/// A stale verdict is missing data, so the fail mode decides: fail closed keeps
/// the hold; fail open and warn only set the verdict aside and let the run go
/// on, with a warning. A verdict that holds forever because nothing refreshes
/// it is the defect this exists to prevent.
pub(super) fn stale_unsafe_verdict_holds(mode: SafetyFailMode) -> bool {
    safety_fail_mode_no_data_resolution(mode) == NoDataResolution::Unsafe
}

/// The warning for an UNSAFE verdict set aside because it went stale under a
/// permissive fail mode.
pub(super) fn stale_verdict_dropped_message(staleness_secs: u64, mode: SafetyFailMode) -> String {
    let mode = match mode {
        SafetyFailMode::WarnOnly => "warn only",
        _ => "fail open",
    };
    format!(
        "The app's weather verdict has not been refreshed for {staleness_secs} s. The safety \
         fail mode is {mode}, so its last UNSAFE reading is set aside and the run carries on. \
         It holds again as soon as a fresh verdict says unsafe."
    )
}

/// How a [`SafetyFailMode`] resolves the "no usable safety/weather data"
/// situation (poll error on the Rust side, no connected source on the Dart
/// side). This is the SINGLE cross-language truth table for the fail-mode
/// semantics — both the Rust safety poll below and the Dart weather-safety
/// verdict (`weather_safety_provider.dart` `noDataFailModeResolution`) must
/// agree on it.
///
/// The Dart side mirrors this enum as `NoDataResolution` and is pinned against
/// the identical table by `weather_fail_mode_parity_test.dart`; the Rust side
/// is pinned by `safety_fail_mode_no_data_resolution_truth_table` in this
/// module. A row changed here must be changed in BOTH tests.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NoDataResolution {
    /// Treat the absence of data as UNSAFE (fail closed). The Rust poll sets
    /// `weather_safe = false`; the Dart verdict pushes `Some(true)` (unsafe).
    Unsafe,
    /// Treat the absence of data as SAFE (fail open). The Rust poll sets
    /// `weather_safe = true`; the Dart verdict ABSTAINS (`None`) rather than
    /// asserting SAFE, so a permissive Dart policy can never gag a
    /// hardware-unsafe device — but the resolution row is still "safe".
    Safe,
    /// Preserve the prior reading and emit an operator warning (warn-only).
    /// The Rust poll leaves `weather_safe` unchanged; the Dart verdict
    /// ABSTAINS (`None`).
    Preserve,
}

/// The single cross-language definition of how each [`SafetyFailMode`] resolves
/// a no-data / poll-error situation. See [`NoDataResolution`] for the contract
/// and the two tests that pin this table on each side.
pub fn safety_fail_mode_no_data_resolution(mode: SafetyFailMode) -> NoDataResolution {
    match mode {
        SafetyFailMode::FailClosed => NoDataResolution::Unsafe,
        SafetyFailMode::FailOpen => NoDataResolution::Safe,
        SafetyFailMode::WarnOnly => NoDataResolution::Preserve,
    }
}
