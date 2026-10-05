//! Recovery Mode — first-class executor state machine.
//!
//! When a trigger or instruction returns a *recoverable* failure (guide-star
//! lost, slew failed, plate-solve failed, weather unsafe, etc.) the executor
//! transitions `Running` -> `Recovering` and drives a retry loop here. The
//! whole reason for promoting recovery to first-class status is user
//! visibility: SGP's killer feature is that an unattended user can see at a
//! glance the rig is *recovering* rather than dead or running fine. Pre-Wave-4
//! Nightshade had only `RecoveryAction` variants and a buried per-action
//! retry — none of it surfaced to the UI.
//!
//! # Lifecycle
//!
//! ```text
//!     Running
//!        │  recoverable failure fires
//!        ▼
//!     Recovering ── Waiting ─► Attempting ──┐
//!        ▲                       │          │
//!        │                       │success   │failure
//!        │                       ▼          ▼
//!        │                    Recovered  Waiting
//!        │                       │          │
//!        │                       │          │ attempts >= max
//!        │                       │          ▼
//!        │                       │       GaveUp
//!        │                       ▼          │
//!        └──── Running (resume sequence)    ▼
//!                                       Failed (or ParkAndAbort per config)
//! ```
//!
//! # User-driven controls
//!
//! - `RecoveryTryNow`  — immediately force the next attempt (skip the wait).
//! - `RecoveryAbort`   — exit the loop and transition to `Failed`.
//!
//! # Settings (Dart-side mirror)
//!
//! - `recoveryDefaultRetryIntervalMins` (default 10) — wait between attempts.
//! - `recoveryDefaultMaxDurationMins`   (default 90) — total time budget.
//! - `recoveryStopTrackingDuringRecovery` (default true) — pause tracking.
//! - `recoveryAbortOnMeridian`          (default true) — bail if flip due.
//! - `recoveryAudibleAlertWhenEntered`  (default true) — bell on entry.

use chrono::{DateTime, Duration as ChronoDuration, Utc};
use serde::{Deserialize, Serialize};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;

/// What kicked off the recovery loop. The display strings are user-facing —
/// they show up on the Run Dashboard banner ("Recovering: Guide star lost").
///
/// `Custom(String)` is the escape hatch for future causes wired through
/// plugin / script nodes — every other variant maps to a known executor
/// failure path.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum RecoveryCause {
    /// PHD2 (or equivalent) lost the guide star and the trigger fired.
    GuideStarLost,
    /// A slew instruction did not converge inside its timeout.
    SlewFailed,
    /// Plate-solve returned no solution (or repeated failures).
    PlateSolveFailed,
    /// Weather / safety device declared the site unsafe.
    WeatherUnsafe,
    /// The mount stopped tracking unexpectedly.
    MountTrackingLost,
    /// Focus drift exceeded the configured budget (HFR > baseline * x).
    FocusDriftCritical,
    /// image grading hit `max_consecutive_rejects`.
    ConsecutiveRejectsExceeded,
    /// A required device is missing or dropped out during an instruction.
    DeviceDisconnected,
    /// Anything plugin / script / user-defined surfaces.
    Custom(String),
}

impl RecoveryCause {
    /// Human-readable label for the Run Dashboard banner. Kept stable so
    /// the Dart side can rely on the strings for analytics / history.
    pub fn display_label(&self) -> String {
        match self {
            RecoveryCause::GuideStarLost => "Guide star lost".to_string(),
            RecoveryCause::SlewFailed => "Slew failed".to_string(),
            RecoveryCause::PlateSolveFailed => "Plate-solve failed".to_string(),
            RecoveryCause::WeatherUnsafe => "Weather unsafe".to_string(),
            RecoveryCause::MountTrackingLost => "Mount tracking lost".to_string(),
            RecoveryCause::FocusDriftCritical => "Critical focus drift".to_string(),
            RecoveryCause::ConsecutiveRejectsExceeded => "Consecutive rejects".to_string(),
            RecoveryCause::DeviceDisconnected => "Device disconnected".to_string(),
            RecoveryCause::Custom(msg) => msg.clone(),
        }
    }

    /// Stable wire-key for analytics / persisted session history. Lower-case
    /// snake_case so Dart code can use this directly as a Map key without
    /// caring about display formatting.
    pub fn wire_key(&self) -> String {
        match self {
            RecoveryCause::GuideStarLost => "guide_star_lost".to_string(),
            RecoveryCause::SlewFailed => "slew_failed".to_string(),
            RecoveryCause::PlateSolveFailed => "plate_solve_failed".to_string(),
            RecoveryCause::WeatherUnsafe => "weather_unsafe".to_string(),
            RecoveryCause::MountTrackingLost => "mount_tracking_lost".to_string(),
            RecoveryCause::FocusDriftCritical => "focus_drift_critical".to_string(),
            RecoveryCause::ConsecutiveRejectsExceeded => "consecutive_rejects_exceeded".to_string(),
            RecoveryCause::DeviceDisconnected => "device_disconnected".to_string(),
            RecoveryCause::Custom(_) => "custom".to_string(),
        }
    }
}

/// Phase within the recovery state machine. Distinct from `ExecutorState`
/// because the executor only sees "Recovering" — this is the inner sub-state
/// that drives whether the loop is sleeping, attempting, succeeded, or
/// gave up.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum RecoveryPhase {
    /// Waiting `retry_interval_secs` between attempts. The countdown is
    /// visible to the user via the dashboard banner; `RecoveryTryNow`
    /// fast-forwards out of this phase.
    Waiting,
    /// Currently re-executing the failed operation (re-slew, re-solve,
    /// re-acquire guide star, …). No retries fire while in this phase.
    Attempting,
    /// The attempt succeeded; the executor will transition `Recovering` ->
    /// `Running` and resume the sequence on the next tick.
    Recovered,
    /// Out of attempts or out of time. The executor will transition
    /// `Recovering` -> `Failed` (or ParkAndAbort if configured) on the
    /// next tick.
    GaveUp,
}

/// Snapshot of a live recovery loop. Cloned cheaply (small POD-ish struct)
/// for the executor event payload so the UI can render the banner without
/// reaching back into the executor for every redraw.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecoveryContext {
    /// UTC timestamp when the loop entered the `Recovering` state.
    pub started_at: DateTime<Utc>,
    /// What triggered the loop. Drives the dashboard banner title.
    pub cause: RecoveryCause,
    /// UTC timestamp of the most recent attempt (Attempting phase entry).
    /// `None` before the first attempt has fired.
    pub last_attempt_at: Option<DateTime<Utc>>,
    /// 1-based attempt counter. `attempt_count == 0` means "scheduled but
    /// not yet attempted"; `attempt_count == max_attempts` means we are on
    /// the final allowed retry.
    pub attempt_count: u32,
    /// Hard cap on the number of attempts. Derived from
    /// `max_duration_secs / retry_interval_secs` and clamped to a sane
    /// minimum (1) so a sub-interval duration still gets one shot.
    pub max_attempts: u32,
    /// Seconds between attempts while in `Waiting`.
    pub retry_interval_secs: f64,
    /// Total time budget (seconds). After this elapses we transition to
    /// `GaveUp` regardless of `attempt_count`.
    pub max_duration_secs: f64,
    /// Current sub-phase. See `RecoveryPhase` for transitions.
    pub phase: RecoveryPhase,
    /// Most recent failure message from the underlying recovery operation
    /// (slew/solve/guide). Surfaced in the banner so the operator can
    /// triage without diving into logs.
    pub last_error: Option<String>,
}

impl RecoveryContext {
    pub fn new(cause: RecoveryCause, retry_interval_secs: f64, max_duration_secs: f64) -> Self {
        let max_attempts = compute_max_attempts(retry_interval_secs, max_duration_secs);
        Self {
            started_at: Utc::now(),
            cause,
            last_attempt_at: None,
            attempt_count: 0,
            max_attempts,
            retry_interval_secs,
            max_duration_secs,
            phase: RecoveryPhase::Waiting,
            last_error: None,
        }
    }

    /// Seconds elapsed since `started_at`. Used by the time-budget check
    /// and the dashboard countdown.
    pub fn elapsed_secs(&self, now: DateTime<Utc>) -> f64 {
        let delta = now.signed_duration_since(self.started_at);
        // Why: chrono's `num_milliseconds` is i64; we want seconds as f64
        // for the budget comparison. Negative deltas (clock skew) clamp
        // to 0 so the "exhausted" branch can never fire from a wall-clock
        // jump backwards.
        let ms = delta.num_milliseconds().max(0);
        (ms as f64) / 1000.0
    }

    /// Seconds remaining in the time budget. Negative once exhausted.
    pub fn remaining_secs(&self, now: DateTime<Utc>) -> f64 {
        self.max_duration_secs - self.elapsed_secs(now)
    }

    /// Seconds until the next auto-retry. Returns 0 once the wait elapsed
    /// (the executor's tick loop interprets <=0 as "fire now").
    pub fn next_attempt_in_secs(&self, now: DateTime<Utc>) -> f64 {
        match (self.phase, self.last_attempt_at) {
            (RecoveryPhase::Waiting, Some(last)) => {
                let delta_ms = now.signed_duration_since(last).num_milliseconds().max(0);
                let elapsed = (delta_ms as f64) / 1000.0;
                (self.retry_interval_secs - elapsed).max(0.0)
            }
            (RecoveryPhase::Waiting, None) => {
                // First attempt fires immediately — there is no benefit to
                // sleeping when the user is actively staring at the dashboard
                // waiting for *something* to happen.
                0.0
            }
            // Not in waiting phase; the countdown is meaningless. The UI
            // hides the timer for these phases.
            _ => 0.0,
        }
    }

    /// True if the loop has exhausted attempts OR exceeded the time budget.
    pub fn is_exhausted(&self, now: DateTime<Utc>) -> bool {
        self.attempt_count >= self.max_attempts || self.remaining_secs(now) <= 0.0
    }
}

/// User-tunable recovery defaults. Mirrored on the Dart `AppSettingsState`
/// so the user can edit these in Settings > Recovery Mode. The executor
/// reads from this config on every recovery entry (so changes take effect
/// on the next entry — no restart needed).
///
/// Values follow SGP's documented defaults: 10 min between attempts, 90 min
/// total cap. Tightly-coupled with `compute_max_attempts` — changing the
/// duration / interval re-derives `max_attempts`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecoveryRuntimeConfig {
    /// Seconds between auto-retry attempts.
    pub retry_interval_secs: f64,
    /// Total seconds before giving up on the loop.
    pub max_duration_secs: f64,
    /// When true, the executor commands the mount to stop tracking on
    /// recovery entry. Most failure modes (lost guide star, weather, drift)
    /// are improved by parking tracking so the rig doesn't keep moving
    /// while the operator is asleep.
    pub stop_tracking_during_recovery: bool,
    /// When true, an imminent meridian crossing (within
    /// `recoveryAbortOnMeridianMinutes`) immediately aborts the recovery
    /// loop instead of retrying through the flip. SGP behaviour: a recovery
    /// loop that straddles a flip leaves the rig in an unpredictable state.
    pub abort_on_meridian: bool,
    /// When true, ring the platform alert sound on recovery entry. Reuses
    /// the existing `criticalAlertPlayer` path so the user setting is
    /// unified with the rest of the critical-event audio policy.
    pub audible_alert_when_entered: bool,
    /// When true, a recovery that cannot fix the problem parks the mount,
    /// closes the cover and closes the dome before failing the run.
    ///
    /// `false` (the `Default`) is the only safe default, and the reason is not
    /// a preference. The code this replaces decided the same question by
    /// inferring whether a human was present, from a `RuntimeConfig` flag that
    /// had no writer anywhere in the product — no bridge call, no API route, no
    /// setting — so it read "nobody is here" on every run. On 2026-09-14 that
    /// inference parked the owner's mount, closed up and declared the night
    /// abandoned over a reject storm, while he was sitting at the telescope
    /// with an HTTP client polling the API every 25 s and the desktop UI open on
    /// his screen.
    ///
    /// Nothing available here can tell "unattended" from "attended and
    /// watching", and an app that cannot tell must not take an irreversible
    /// action on the guess. Parking a mount and closing an enclosure is that
    /// kind of action; holding the run is not. So this is the operator's
    /// standing decision, made in advance, and it is off until they make it.
    ///
    /// Turning it on is a real choice for a remote rig: it costs the rest of the
    /// night in exchange for never leaving the optics open behind a hold. Note
    /// that it is NOT the rig's only protection either way — the safety-class
    /// triggers (weather unsafe, dawn approaching, dome shutter) keep their own
    /// configured `ParkAndAbort` behaviour, and now keep evaluating while a run
    /// is paused.
    pub park_and_close_when_recovery_gives_up: bool,
}

impl Default for RecoveryRuntimeConfig {
    fn default() -> Self {
        Self {
            retry_interval_secs: 10.0 * 60.0,
            max_duration_secs: 90.0 * 60.0,
            stop_tracking_during_recovery: true,
            abort_on_meridian: true,
            audible_alert_when_entered: true,
            park_and_close_when_recovery_gives_up: false,
        }
    }
}

/// Derive the maximum number of attempts from interval + total duration.
/// Always returns at least 1 so a sub-interval duration still gets a shot.
pub fn compute_max_attempts(retry_interval_secs: f64, max_duration_secs: f64) -> u32 {
    if retry_interval_secs <= 0.0 {
        return 1;
    }
    let raw = (max_duration_secs / retry_interval_secs).floor() as i64;
    // i64 -> u32: clamp negatives to 0 first, then cap at u32::MAX. The
    // final `.max(1)` enforces the documented "at least one attempt"
    // invariant.
    let clamped = raw.clamp(0, u32::MAX as i64) as u32;
    clamped.max(1)
}

/// Shared inter-task signal that the user requested `RecoveryTryNow` or
/// `RecoveryAbort`. The recovery-loop driver polls these on its own cadence
/// so the user can punch through the wait timer without blocking on a
/// mutex.
///
/// Why three atomics instead of an mpsc channel: the recovery driver lives
/// inside the trigger-monitor closure (already complex async chain) and
/// adding another mpsc would mean choosing between a single multiplexed
/// receiver (lifetime headaches) or a third `tokio::select!` branch (more
/// state). Atomics are lock-free, can be set from any task, and the driver
/// already polls on a fixed cadence, so the read cost is zero.
#[derive(Debug)]
pub struct RecoverySignals {
    /// User pressed "Try Now": clear the wait and attempt immediately.
    pub try_now: Arc<AtomicBool>,
    /// User pressed "Abort": exit the loop with a Failed transition.
    pub abort: Arc<AtomicBool>,
    /// Monotonic counter of *entries* into Recovering, so the Dart side
    /// can distinguish a fresh recovery from "we're still in the same
    /// one". Incremented every time the executor starts a new recovery
    /// loop. Wraps at u64::MAX which won't realistically happen.
    pub entry_counter: Arc<AtomicU64>,
}

impl Default for RecoverySignals {
    fn default() -> Self {
        Self::new()
    }
}

impl RecoverySignals {
    pub fn new() -> Self {
        Self {
            try_now: Arc::new(AtomicBool::new(false)),
            abort: Arc::new(AtomicBool::new(false)),
            entry_counter: Arc::new(AtomicU64::new(0)),
        }
    }

    /// Clear both control signals — call this on entry to a new recovery
    /// loop so a stale TryNow from a previous loop doesn't pre-fire the
    /// first attempt. Increment the entry counter so the Dart side sees a
    /// fresh recovery distinct from any earlier one.
    pub fn arm(&self) {
        self.try_now.store(false, Ordering::Relaxed);
        self.abort.store(false, Ordering::Relaxed);
        self.entry_counter.fetch_add(1, Ordering::Relaxed);
    }

    /// Returns true and clears the flag if the user requested TryNow.
    pub fn take_try_now(&self) -> bool {
        self.try_now.swap(false, Ordering::Relaxed)
    }

    /// Returns true and clears the flag if the user requested Abort.
    pub fn take_abort(&self) -> bool {
        self.abort.swap(false, Ordering::Relaxed)
    }

    pub fn request_try_now(&self) {
        self.try_now.store(true, Ordering::Relaxed);
    }

    pub fn request_abort(&self) {
        self.abort.store(true, Ordering::Relaxed);
    }

    /// Read the current entry counter without modifying it. Used by tests
    /// and by checkpoint serialisation.
    pub fn current_entry(&self) -> u64 {
        self.entry_counter.load(Ordering::Relaxed)
    }
}

/// Outcome of running a single recovery attempt. The driver inspects this
/// and updates the `RecoveryContext` accordingly.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AttemptOutcome {
    /// The recovery action succeeded — exit the loop, resume the sequence.
    Succeeded,
    /// The action failed; the loop will sleep and try again (unless
    /// exhausted).
    Failed { message: String },
    /// The user (or another shutdown path) cancelled mid-attempt — exit
    /// the loop with a Cancelled status.
    Cancelled,
    /// The cause is not auto-recoverable by waiting — escalate to a real
    /// operator Pause and stop the loop. Unlike `Succeeded` (auto-resume)
    /// this freezes the run in `ExecutorState::Paused` until the operator
    /// resumes, and unlike `Failed`/exhaustion it does NOT park-and-abort
    /// the rig. Used for a consecutive-reject storm: a wait does not prove
    /// the sky cleared, so hand the night to the operator instead of
    /// oscillating fail → wait → "recovered" → fail on a fresh budget.
    PauseForOperator { message: String },
    /// Retrying cannot possibly clear this cause, so the loop must end NOW
    /// rather than spend its whole budget re-learning a fact it already knows.
    ///
    /// Unlike `Failed` (sleep `retry_interval_secs`, try again until the
    /// attempt/time budget runs out) this breaks out on the first attempt and
    /// takes the ordinary give-up path — park the mount, close cover and dome,
    /// fail the run loudly. A `DeviceDisconnected` recovery entered with NO
    /// device ids configured is the shape: `connect_device` has nothing to call
    /// and `device_is_connected` nothing to poll, so with the shipped defaults
    /// (10 min interval, 90 min cap) the operator gets nine identical failures
    /// spread over ninety minutes, presented as `recovering` at `progress 0.0`.
    Unrecoverable { message: String },
}

/// Record of a single completed recovery loop for the post-session report.
/// Persisted via the session run record ('s structured
/// warnings section) so the user can review every recovery after the run.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RecoveryHistoryEntry {
    pub started_at: DateTime<Utc>,
    pub ended_at: DateTime<Utc>,
    pub cause: RecoveryCause,
    /// Total number of attempts that ran during the loop.
    pub attempts: u32,
    /// True if the loop recovered (sequence resumed); false otherwise.
    pub recovered: bool,
    /// True if the user pressed Abort. Distinct from `recovered=false`
    /// (which can also mean "exhausted").
    pub aborted_by_user: bool,
    /// Last error message recorded inside the context, if any.
    pub last_error: Option<String>,
}

impl RecoveryHistoryEntry {
    pub fn duration(&self) -> ChronoDuration {
        self.ended_at.signed_duration_since(self.started_at)
    }

    /// Total seconds the loop spent in Recovering. Exposed as f64 for
    /// JSON serialisation parity with elsewhere in the API.
    pub fn duration_secs(&self) -> f64 {
        let ms = self.duration().num_milliseconds().max(0);
        (ms as f64) / 1000.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compute_max_attempts_floors_correctly() {
        assert_eq!(compute_max_attempts(60.0, 600.0), 10);
        assert_eq!(compute_max_attempts(600.0, 5400.0), 9);
        // sub-interval duration still gets one shot
        assert_eq!(compute_max_attempts(600.0, 60.0), 1);
        assert_eq!(compute_max_attempts(600.0, 0.0), 1);
        // pathological inputs
        assert_eq!(compute_max_attempts(0.0, 600.0), 1);
        assert_eq!(compute_max_attempts(-1.0, 600.0), 1);
    }

    #[test]
    fn recovery_cause_display_and_wire_keys_distinct() {
        let causes = [
            RecoveryCause::GuideStarLost,
            RecoveryCause::SlewFailed,
            RecoveryCause::PlateSolveFailed,
            RecoveryCause::WeatherUnsafe,
            RecoveryCause::MountTrackingLost,
            RecoveryCause::FocusDriftCritical,
            RecoveryCause::ConsecutiveRejectsExceeded,
            RecoveryCause::DeviceDisconnected,
        ];
        let mut wire_keys = std::collections::HashSet::new();
        let mut labels = std::collections::HashSet::new();
        for cause in &causes {
            assert!(!cause.display_label().is_empty());
            // One label per cause: the banner and the give-up message are the
            // operator's only way to tell a guider loss from a weather abort.
            assert!(labels.insert(cause.display_label()));
            assert!(wire_keys.insert(cause.wire_key()));
        }
        assert_eq!(
            RecoveryCause::GuideStarLost.display_label(),
            "Guide star lost"
        );
        assert_eq!(
            RecoveryCause::Custom("Roof sensor tripped".into()).display_label(),
            "Roof sensor tripped"
        );
    }

    #[test]
    fn recovery_context_starts_in_waiting() {
        let ctx = RecoveryContext::new(RecoveryCause::GuideStarLost, 60.0, 600.0);
        assert_eq!(ctx.phase, RecoveryPhase::Waiting);
        assert_eq!(ctx.attempt_count, 0);
        assert_eq!(ctx.max_attempts, 10);
        assert!(!ctx.is_exhausted(Utc::now()));
        // First attempt fires immediately when no previous attempt exists.
        assert_eq!(ctx.next_attempt_in_secs(Utc::now()), 0.0);
    }

    #[test]
    fn recovery_context_exhausted_when_attempts_reach_max() {
        let mut ctx = RecoveryContext::new(RecoveryCause::SlewFailed, 60.0, 180.0);
        assert_eq!(ctx.max_attempts, 3);
        ctx.attempt_count = 3;
        assert!(ctx.is_exhausted(Utc::now()));
    }

    #[test]
    fn recovery_context_remaining_secs_after_simulated_elapsed() {
        let mut ctx = RecoveryContext::new(RecoveryCause::SlewFailed, 60.0, 300.0);
        // Pretend the loop started a minute ago.
        ctx.started_at = Utc::now() - ChronoDuration::seconds(60);
        let remaining = ctx.remaining_secs(Utc::now());
        // Allow 5s of test scheduler jitter.
        assert!(
            (remaining - 240.0).abs() < 5.0,
            "expected ~240s remaining, got {}",
            remaining
        );
    }

    #[test]
    fn signals_arm_clears_and_increments() {
        let signals = RecoverySignals::new();
        let start = signals.current_entry();
        signals.request_try_now();
        signals.request_abort();
        signals.arm();
        assert!(!signals.take_try_now());
        assert!(!signals.take_abort());
        assert_eq!(signals.current_entry(), start + 1);
    }

    #[test]
    fn signals_take_returns_value_and_clears() {
        let signals = RecoverySignals::new();
        signals.request_try_now();
        assert!(signals.take_try_now());
        assert!(!signals.take_try_now());
        signals.request_abort();
        assert!(signals.take_abort());
        assert!(!signals.take_abort());
    }

    #[test]
    fn history_entry_duration_matches_timestamps() {
        let started = Utc::now();
        let ended = started + ChronoDuration::seconds(150);
        let entry = RecoveryHistoryEntry {
            started_at: started,
            ended_at: ended,
            cause: RecoveryCause::WeatherUnsafe,
            attempts: 3,
            recovered: false,
            aborted_by_user: false,
            last_error: Some("clouds rolled in".to_string()),
        };
        assert!((entry.duration_secs() - 150.0).abs() < 0.1);
    }

    /// The wait-timer computation must reflect a previous attempt that
    /// happened `n` seconds ago — pressing TryNow is the only way to
    /// fast-forward the wait.
    #[test]
    fn next_attempt_in_secs_decreases_with_elapsed_time() {
        let mut ctx = RecoveryContext::new(RecoveryCause::SlewFailed, 120.0, 600.0);
        ctx.last_attempt_at = Some(Utc::now() - ChronoDuration::seconds(30));
        ctx.phase = RecoveryPhase::Waiting;
        let remaining = ctx.next_attempt_in_secs(Utc::now());
        assert!(
            (remaining - 90.0).abs() < 5.0,
            "expected ~90s until next attempt, got {}",
            remaining
        );
    }

    /// Once the wait elapses next_attempt_in_secs clamps to zero so the
    /// driver fires the attempt instead of doing a negative-sleep.
    #[test]
    fn next_attempt_in_secs_clamps_to_zero_after_wait_elapsed() {
        let mut ctx = RecoveryContext::new(RecoveryCause::SlewFailed, 30.0, 600.0);
        ctx.last_attempt_at = Some(Utc::now() - ChronoDuration::seconds(60));
        ctx.phase = RecoveryPhase::Waiting;
        assert_eq!(ctx.next_attempt_in_secs(Utc::now()), 0.0);
    }

    /// Phases other than Waiting are not in the wait/countdown UI — the
    /// driver returns 0 so the UI hides the timer.
    #[test]
    fn next_attempt_in_secs_zero_outside_waiting_phase() {
        let mut ctx = RecoveryContext::new(RecoveryCause::WeatherUnsafe, 60.0, 600.0);
        ctx.last_attempt_at = Some(Utc::now());
        ctx.phase = RecoveryPhase::Attempting;
        assert_eq!(ctx.next_attempt_in_secs(Utc::now()), 0.0);
        ctx.phase = RecoveryPhase::Recovered;
        assert_eq!(ctx.next_attempt_in_secs(Utc::now()), 0.0);
        ctx.phase = RecoveryPhase::GaveUp;
        assert_eq!(ctx.next_attempt_in_secs(Utc::now()), 0.0);
    }

    /// Exhaustion fires on EITHER attempt count OR time budget. This test
    /// pegs the time-budget side: the loop is still on attempt 1 but the
    /// session ran out of time.
    #[test]
    fn recovery_context_exhausts_on_time_budget_alone() {
        let mut ctx = RecoveryContext::new(RecoveryCause::PlateSolveFailed, 600.0, 600.0);
        ctx.started_at = Utc::now() - ChronoDuration::seconds(700);
        assert!(ctx.is_exhausted(Utc::now()));
    }

    /// Defaults match SGP's documented behaviour: 10 min between attempts,
    /// 90 min total, stop tracking during recovery, abort on imminent
    /// meridian, audible alert on entry.
    #[test]
    fn recovery_runtime_config_defaults_match_sgp() {
        let cfg = RecoveryRuntimeConfig::default();
        assert!((cfg.retry_interval_secs - 600.0).abs() < f64::EPSILON);
        assert!((cfg.max_duration_secs - 5400.0).abs() < f64::EPSILON);
        assert!(cfg.stop_tracking_during_recovery);
        assert!(cfg.abort_on_meridian);
        assert!(cfg.audible_alert_when_entered);
    }
}
