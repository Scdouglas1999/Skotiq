//! What each [`RecoveryCause`] means for the recovery loop, as one table.
//!
//! The recovery driver, the attempt runner and the event bridge ask the row;
//! none of them match on the cause to decide policy.

use super::RecoveryCause;

/// How often a weather hold checks the sky.
pub const WEATHER_HOLD_CHECK_SECS: f64 = 15.0;

/// How often a guide-star hold looks for the star again, at most: soon enough
/// that the run resumes shortly after a cloud passes.
pub const GUIDE_STAR_RECHECK_SECS: f64 = 60.0;

/// First wait between attempts to get a stopped mount tracking again. Each
/// failed attempt doubles it, up to [`TRACKING_RECHECK_MAX_SECS`]; the attempts
/// never run out, because nothing else gets the mount tracking.
pub const TRACKING_RECHECK_SECS: f64 = 30.0;
pub const TRACKING_RECHECK_MAX_SECS: f64 = 300.0;

/// The span a hold that never runs out reports as its budget. It only keeps
/// the attempt counters the recovery events carry finite.
pub const WEATHER_HOLD_NOMINAL_SPAN_SECS: f64 = 12.0 * 3600.0;

/// A recovery that waits for something outside the run to change, with the
/// mount left tracking so the run can image again the moment it does.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HoldKind {
    /// Waits for the sky to read safe. Weather alone never ends the run.
    Weather,
    /// Waits for the guide star, which is most often behind cloud.
    GuideStar,
    /// Waits for a stopped mount to track again. Ending the run would leave
    /// it stopped just the same, so the attempts never run out.
    Tracking,
}

/// How long the loop waits between attempts and how long it keeps trying.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum RetryCadence {
    /// The operator's retry interval and time budget.
    Configured,
    /// A fixed interval; the budget is nominal.
    Fixed { interval_secs: f64, span_secs: f64 },
    /// The operator's interval, capped; the operator's budget.
    CappedInterval { max_interval_secs: f64 },
    /// The operator's interval capped at `first_interval_secs`, doubled after
    /// each failed attempt up to `max_interval_secs`; the budget is nominal.
    Backoff {
        first_interval_secs: f64,
        max_interval_secs: f64,
        span_secs: f64,
    },
}

impl RetryCadence {
    /// The `(retry interval, time budget)` a loop starts with, given the
    /// operator's configured pair.
    pub fn resolve(self, configured_interval_secs: f64, configured_budget_secs: f64) -> (f64, f64) {
        match self {
            Self::Configured => (configured_interval_secs, configured_budget_secs),
            Self::Fixed {
                interval_secs,
                span_secs,
            } => (interval_secs, span_secs),
            Self::CappedInterval { max_interval_secs } => (
                configured_interval_secs.min(max_interval_secs),
                configured_budget_secs,
            ),
            Self::Backoff {
                first_interval_secs,
                span_secs,
                ..
            } => (configured_interval_secs.min(first_interval_secs), span_secs),
        }
    }

    /// The interval after a failed attempt.
    pub fn after_failure(self, interval_secs: f64) -> f64 {
        match self {
            Self::Backoff {
                max_interval_secs, ..
            } => (interval_secs * 2.0).min(max_interval_secs),
            _ => interval_secs,
        }
    }
}

/// What one recovery attempt does.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AttemptKind {
    /// Get the guider locked and settled on a star again.
    ReacquireGuideStar,
    /// Switch mount tracking back on, unless the mount is parked.
    RestoreTracking,
    /// Check that the safety device and the app's verdict both read safe.
    CheckSky,
    /// Reconnect the run's devices and verify each one.
    ReconnectDevices,
    /// Nothing to repair here: resume after the wait and let the node tree
    /// (or the next trigger) deal with what is left.
    ResumeAfterWait,
    /// Waiting cannot prove the cause cleared: pause for the operator.
    PauseForOperator,
}

/// What the loop does when its attempts or its time run out.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OnGiveUp {
    /// End the run (and park, if the operator's settings say so).
    EndRun,
    /// Carry on imaging unguided unless the operator turned on "Stop the run
    /// for quality problems": a missing guide star costs trailed frames,
    /// which grading marks, not the hardware.
    ContinueUnguided,
}

/// One row of recovery policy.
#[derive(Debug)]
pub struct CausePolicy {
    /// The variant name. The app's `RecoveryCause.fromJson` and the replay
    /// timeline read it.
    pub kind: &'static str,
    /// Stable key for analytics and persisted session history.
    pub wire_key: &'static str,
    /// Label for the Run Dashboard banner. A custom cause shows its own text.
    pub display_label: &'static str,
    pub hold: Option<HoldKind>,
    pub cadence: RetryCadence,
    /// Whether the operator's "stop tracking during recovery" setting
    /// applies. Never for a hold: a mount that keeps tracking is still on the
    /// target when the hold ends.
    pub may_stop_tracking: bool,
    /// Whether the loop ends when its attempts or time budget run out.
    pub can_give_up: bool,
    pub on_give_up: OnGiveUp,
    pub attempt: AttemptKind,
}

impl CausePolicy {
    /// Whether this recovery stands down for the tracking-limit hold: a
    /// guide-star or tracking retry cannot repair a mount stopped at its
    /// limit, and must not take the mount from the flip that will.
    pub fn yields_to_tracking_limit_flip(&self) -> bool {
        matches!(self.hold, Some(HoldKind::GuideStar | HoldKind::Tracking))
    }
}

/// A repair with the operator's cadence and budget that resumes after the wait.
const fn plain(
    kind: &'static str,
    wire_key: &'static str,
    display_label: &'static str,
    attempt: AttemptKind,
) -> CausePolicy {
    CausePolicy {
        kind,
        wire_key,
        display_label,
        hold: None,
        cadence: RetryCadence::Configured,
        may_stop_tracking: true,
        can_give_up: true,
        on_give_up: OnGiveUp::EndRun,
        attempt,
    }
}

static GUIDE_STAR_LOST: CausePolicy = CausePolicy {
    kind: "GuideStarLost",
    wire_key: "guide_star_lost",
    display_label: "Guide star lost",
    hold: Some(HoldKind::GuideStar),
    cadence: RetryCadence::CappedInterval {
        max_interval_secs: GUIDE_STAR_RECHECK_SECS,
    },
    may_stop_tracking: false,
    can_give_up: true,
    on_give_up: OnGiveUp::ContinueUnguided,
    attempt: AttemptKind::ReacquireGuideStar,
};
static SLEW_FAILED: CausePolicy = plain(
    "SlewFailed",
    "slew_failed",
    "Slew failed",
    AttemptKind::ResumeAfterWait,
);
static PLATE_SOLVE_FAILED: CausePolicy = plain(
    "PlateSolveFailed",
    "plate_solve_failed",
    "Plate-solve failed",
    AttemptKind::ResumeAfterWait,
);
static WEATHER_UNSAFE: CausePolicy = CausePolicy {
    kind: "WeatherUnsafe",
    wire_key: "weather_unsafe",
    display_label: "Weather unsafe",
    hold: Some(HoldKind::Weather),
    cadence: RetryCadence::Fixed {
        interval_secs: WEATHER_HOLD_CHECK_SECS,
        span_secs: WEATHER_HOLD_NOMINAL_SPAN_SECS,
    },
    may_stop_tracking: false,
    can_give_up: false,
    on_give_up: OnGiveUp::EndRun,
    attempt: AttemptKind::CheckSky,
};
static MOUNT_TRACKING_LOST: CausePolicy = CausePolicy {
    kind: "MountTrackingLost",
    wire_key: "mount_tracking_lost",
    display_label: "Mount tracking lost",
    hold: Some(HoldKind::Tracking),
    cadence: RetryCadence::Backoff {
        first_interval_secs: TRACKING_RECHECK_SECS,
        max_interval_secs: TRACKING_RECHECK_MAX_SECS,
        span_secs: WEATHER_HOLD_NOMINAL_SPAN_SECS,
    },
    may_stop_tracking: false,
    can_give_up: false,
    on_give_up: OnGiveUp::EndRun,
    attempt: AttemptKind::RestoreTracking,
};
// The next periodic autofocus lowers HFR if a refocus is due; the autofocus
// triggers stay armed and fire again if it is still high.
static FOCUS_DRIFT_CRITICAL: CausePolicy = plain(
    "FocusDriftCritical",
    "focus_drift_critical",
    "Critical focus drift",
    AttemptKind::ResumeAfterWait,
);
// Nothing sends this cause since the owner's 2026-10-06 decision that a
// reject streak only notifies. Kept so recorded history still parses.
static CONSECUTIVE_REJECTS_EXCEEDED: CausePolicy = plain(
    "ConsecutiveRejectsExceeded",
    "consecutive_rejects_exceeded",
    "Consecutive rejects",
    AttemptKind::PauseForOperator,
);
static DEVICE_DISCONNECTED: CausePolicy = plain(
    "DeviceDisconnected",
    "device_disconnected",
    "Device disconnected",
    AttemptKind::ReconnectDevices,
);
static CUSTOM: CausePolicy = plain("Custom", "custom", "", AttemptKind::ResumeAfterWait);

impl RecoveryCause {
    pub fn policy(&self) -> &'static CausePolicy {
        match self {
            RecoveryCause::GuideStarLost => &GUIDE_STAR_LOST,
            RecoveryCause::SlewFailed => &SLEW_FAILED,
            RecoveryCause::PlateSolveFailed => &PLATE_SOLVE_FAILED,
            RecoveryCause::WeatherUnsafe => &WEATHER_UNSAFE,
            RecoveryCause::MountTrackingLost => &MOUNT_TRACKING_LOST,
            RecoveryCause::FocusDriftCritical => &FOCUS_DRIFT_CRITICAL,
            RecoveryCause::ConsecutiveRejectsExceeded => &CONSECUTIVE_REJECTS_EXCEEDED,
            RecoveryCause::DeviceDisconnected => &DEVICE_DISCONNECTED,
            RecoveryCause::Custom(_) => &CUSTOM,
        }
    }

    /// Label for the Run Dashboard banner. Stable: the app keeps these
    /// strings in analytics and history.
    pub fn display_label(&self) -> String {
        match self {
            RecoveryCause::Custom(message) => message.clone(),
            cause => cause.policy().display_label.to_string(),
        }
    }

    /// Stable snake_case key for analytics and persisted session history.
    pub fn wire_key(&self) -> String {
        self.policy().wire_key.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn all_causes() -> Vec<RecoveryCause> {
        vec![
            RecoveryCause::GuideStarLost,
            RecoveryCause::SlewFailed,
            RecoveryCause::PlateSolveFailed,
            RecoveryCause::WeatherUnsafe,
            RecoveryCause::MountTrackingLost,
            RecoveryCause::FocusDriftCritical,
            RecoveryCause::ConsecutiveRejectsExceeded,
            RecoveryCause::DeviceDisconnected,
            RecoveryCause::Custom("Roof sensor tripped".into()),
        ]
    }

    /// The app parses `kind` (`RecoveryCause.fromJson`), keys analytics on
    /// `wire_key` and shows `display_label`; recovery history persists the
    /// serde form. A table edit must not change any of them.
    #[test]
    fn recovery_cause_wire_strings_are_pinned() {
        let rows: Vec<(String, String, String, String)> = all_causes()
            .iter()
            .map(|cause| {
                (
                    cause.policy().kind.to_string(),
                    cause.wire_key(),
                    cause.display_label(),
                    serde_json::to_string(cause).unwrap(),
                )
            })
            .collect();
        let expected = [
            ("GuideStarLost", "guide_star_lost", "Guide star lost", r#""GuideStarLost""#),
            ("SlewFailed", "slew_failed", "Slew failed", r#""SlewFailed""#),
            ("PlateSolveFailed", "plate_solve_failed", "Plate-solve failed", r#""PlateSolveFailed""#),
            ("WeatherUnsafe", "weather_unsafe", "Weather unsafe", r#""WeatherUnsafe""#),
            ("MountTrackingLost", "mount_tracking_lost", "Mount tracking lost", r#""MountTrackingLost""#),
            ("FocusDriftCritical", "focus_drift_critical", "Critical focus drift", r#""FocusDriftCritical""#),
            (
                "ConsecutiveRejectsExceeded",
                "consecutive_rejects_exceeded",
                "Consecutive rejects",
                r#""ConsecutiveRejectsExceeded""#,
            ),
            ("DeviceDisconnected", "device_disconnected", "Device disconnected", r#""DeviceDisconnected""#),
            ("Custom", "custom", "Roof sensor tripped", r#"{"Custom":"Roof sensor tripped"}"#),
        ];
        assert_eq!(rows.len(), expected.len());
        for (row, (kind, wire_key, label, json)) in rows.iter().zip(expected) {
            assert_eq!(
                (row.0.as_str(), row.1.as_str(), row.2.as_str(), row.3.as_str()),
                (kind, wire_key, label, json)
            );
        }
    }

    #[test]
    fn holds_keep_tracking_and_only_the_guide_star_hold_runs_out() {
        for cause in all_causes() {
            let policy = cause.policy();
            assert_eq!(policy.may_stop_tracking, policy.hold.is_none(), "{cause:?}");
            let expected_give_up = !matches!(
                policy.hold,
                Some(HoldKind::Weather | HoldKind::Tracking)
            );
            assert_eq!(policy.can_give_up, expected_give_up, "{cause:?}");
            assert_eq!(
                policy.on_give_up == OnGiveUp::ContinueUnguided,
                cause == RecoveryCause::GuideStarLost,
                "{cause:?}"
            );
        }
    }

    #[test]
    fn cadence_resolves_against_the_operators_interval_and_budget() {
        let weather = RecoveryCause::WeatherUnsafe.policy().cadence;
        assert_eq!(weather.resolve(600.0, 5400.0), (15.0, 43_200.0));
        let guide = RecoveryCause::GuideStarLost.policy().cadence;
        assert_eq!(guide.resolve(600.0, 5400.0), (60.0, 5400.0));
        assert_eq!(guide.resolve(20.0, 5400.0), (20.0, 5400.0));
        let tracking = RecoveryCause::MountTrackingLost.policy().cadence;
        assert_eq!(tracking.resolve(600.0, 5400.0), (30.0, 43_200.0));
        assert_eq!(tracking.after_failure(30.0), 60.0);
        assert_eq!(tracking.after_failure(240.0), 300.0);
        let plain = RecoveryCause::DeviceDisconnected.policy().cadence;
        assert_eq!(plain.resolve(600.0, 5400.0), (600.0, 5400.0));
        assert_eq!(plain.after_failure(600.0), 600.0);
    }
}
