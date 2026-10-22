//! What the run is doing, as far as the triggers are concerned, and what a
//! fired trigger may therefore do.
//!
//! The trigger monitor keeps evaluating while the run is held, because a held
//! run still has a telescope under the open sky. Whether a firing may act is
//! one function of the [`RunMode`]: running, everything acts; held for any
//! reason, only a safety-class trigger whose action parks the rig.

use crate::ExecutorState;
use crate::{RecoveryAction, TriggerType};

/// Why the run itself is standing still while its executor reports Running.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RunHold {
    /// Tracking is off before the meridian until the target reaches the flip
    /// threshold (see `instructions::pre_meridian_hold`).
    PreMeridian,
}

/// The run as the trigger monitor sees it on one tick.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RunMode {
    Running,
    /// The executor is running but the run is holding still on purpose.
    HeldByRun(RunHold),
    /// The operator (or an action that pauses for the operator) paused the run.
    HeldByOperator {
        run_hold: Option<RunHold>,
    },
    /// The recovery driver owns the run for its attempt ladder.
    Recovering {
        run_hold: Option<RunHold>,
    },
}

impl RunMode {
    /// The mode for an executor state and the run's own hold, or `None` when
    /// the executor is not in a run the monitor watches (idle, stopping or
    /// finished).
    pub fn new(executor: ExecutorState, run_hold: Option<RunHold>) -> Option<Self> {
        match executor {
            ExecutorState::Running => Some(match run_hold {
                Some(hold) => Self::HeldByRun(hold),
                None => Self::Running,
            }),
            ExecutorState::Paused => Some(Self::HeldByOperator { run_hold }),
            ExecutorState::Recovering => Some(Self::Recovering { run_hold }),
            ExecutorState::Idle
            | ExecutorState::Stopping
            | ExecutorState::Cancelled
            | ExecutorState::Completed
            | ExecutorState::Failed => None,
        }
    }

    pub fn is_running(self) -> bool {
        matches!(self, Self::Running)
    }

    /// Whether the executor itself holds the run (paused or recovering), as
    /// opposed to the run holding still on its own account.
    pub fn executor_held(self) -> bool {
        matches!(self, Self::HeldByOperator { .. } | Self::Recovering { .. })
    }

    pub fn run_hold(self) -> Option<RunHold> {
        match self {
            Self::Running => None,
            Self::HeldByRun(hold) => Some(hold),
            Self::HeldByOperator { run_hold } | Self::Recovering { run_hold } => run_hold,
        }
    }

    /// Whether a firing of `trigger_type` with `action` may act in this mode.
    ///
    /// Held, only a trigger that protects the rig may act, and only by parking:
    /// every other action either drives hardware under the hold or lifts it.
    pub fn may_act(self, trigger_type: &TriggerType, action: &RecoveryAction) -> bool {
        self.is_running() || (is_safety_class_trigger(trigger_type) && may_act_during_hold(action))
    }

    /// Whether the mount tracking poll may consume a tracking-loss edge.
    ///
    /// Under an executor hold the edge is kept for the first poll after the
    /// hold: nothing may act on it there, and consuming it would let a run
    /// resume on a mount left untracked. A mount the run stopped itself has no
    /// edge to keep, so it is read under a pause as well.
    pub fn reads_tracking_edge(self) -> bool {
        !self.executor_held() || self.run_hold().is_some()
    }
}

/// Whether a trigger protects the RIG rather than the run's image quality, and
/// so may act while the run is held.
///
/// The split is by consequence: the sky, the Sun or the enclosure turning
/// against the rig matters whether or not a frame is being taken; focus, HFR,
/// dither cadence, flips and recentring only mean something while frames are.
/// Named exhaustively so a new trigger type has to be classified on purpose.
pub fn is_safety_class_trigger(trigger_type: &TriggerType) -> bool {
    match trigger_type {
        TriggerType::WeatherUnsafe
        | TriggerType::HumidityThreshold { .. }
        | TriggerType::DomeShutterNotOpen
        | TriggerType::DawnApproaching { .. }
        | TriggerType::AltitudeLimit { .. }
        | TriggerType::MountTrackingLost
        | TriggerType::CloudArrivingIn { .. }
        | TriggerType::CloudCoverThreshold { .. } => true,
        TriggerType::HfrDegraded { .. }
        | TriggerType::MeridianFlip { .. }
        | TriggerType::GuidingFailed { .. }
        | TriggerType::TemperatureShift { .. }
        | TriggerType::FilterChange
        | TriggerType::AutofocusInterval { .. }
        | TriggerType::DitherInterval { .. }
        | TriggerType::GuideStarLost
        | TriggerType::FocusDrift { .. }
        | TriggerType::DriftLimit { .. }
        // A cloud opening invites a resume; it must not override a hold placed
        // for a human to look at the rig.
        | TriggerType::CloudOpeningIn { .. }
        | TriggerType::TransparencyDropped { .. } => false,
    }
}

/// Whether a safety-class trigger's action may run while the run is held.
///
/// Only parking protects the rig without lifting the hold: `Pause` and `Retry`
/// hand the run to the recovery driver, which resumes it; the rest move
/// hardware.
pub fn may_act_during_hold(action: &RecoveryAction) -> bool {
    matches!(action, RecoveryAction::ParkAndAbort)
}

/// What the trigger monitor's last evaluation was, as the pre-frame meridian
/// gate needs it: a flip trigger that has not had a running tick since a hold
/// may still fire, one that had it and did not fire will not.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum TriggerEvaluation {
    /// No trigger monitor has evaluated for a run.
    #[default]
    NoMonitor,
    /// A run is starting, or the last tick was held; no running evaluation
    /// has happened since.
    AwaitingRunningTick,
    /// The last tick evaluated with the run running.
    Running,
}

/// The run-level facts the triggers read: whether the run is holding still on
/// its own account, and what the monitor's last evaluation was.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct RunState {
    hold: Option<RunHold>,
    last_evaluation: TriggerEvaluation,
}

impl RunState {
    pub fn hold(&self) -> Option<RunHold> {
        self.hold
    }

    pub fn is_held_by_run(&self) -> bool {
        self.hold.is_some()
    }

    pub fn begin_hold(&mut self, hold: RunHold) {
        self.hold = Some(hold);
    }

    pub fn end_hold(&mut self) {
        self.hold = None;
    }

    pub fn last_evaluation(&self) -> TriggerEvaluation {
        self.last_evaluation
    }

    /// Record that the monitor evaluated the triggers in `mode`.
    pub fn record_evaluation(&mut self, mode: RunMode) {
        self.last_evaluation = if mode.is_running() {
            TriggerEvaluation::Running
        } else {
            TriggerEvaluation::AwaitingRunningTick
        };
    }

    /// A run is starting: no hold, and no running evaluation yet.
    pub fn reset_for_new_run(&mut self) {
        self.hold = None;
        self.last_evaluation = TriggerEvaluation::AwaitingRunningTick;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ALL_EXECUTOR_STATES: [ExecutorState; 8] = [
        ExecutorState::Idle,
        ExecutorState::Running,
        ExecutorState::Paused,
        ExecutorState::Stopping,
        ExecutorState::Cancelled,
        ExecutorState::Completed,
        ExecutorState::Failed,
        ExecutorState::Recovering,
    ];

    #[test]
    fn only_a_live_run_has_a_mode() {
        for executor in ALL_EXECUTOR_STATES {
            for hold in [None, Some(RunHold::PreMeridian)] {
                let live = matches!(
                    executor,
                    ExecutorState::Running | ExecutorState::Paused | ExecutorState::Recovering
                );
                assert_eq!(RunMode::new(executor, hold).is_some(), live, "{executor:?}");
            }
        }
    }

    #[test]
    fn a_run_hold_turns_a_running_executor_into_a_held_run() {
        assert_eq!(
            RunMode::new(ExecutorState::Running, None),
            Some(RunMode::Running)
        );
        assert_eq!(
            RunMode::new(ExecutorState::Running, Some(RunHold::PreMeridian)),
            Some(RunMode::HeldByRun(RunHold::PreMeridian))
        );
        let paused = RunMode::new(ExecutorState::Paused, Some(RunHold::PreMeridian)).unwrap();
        assert_eq!(paused.run_hold(), Some(RunHold::PreMeridian));
        assert!(paused.executor_held());
    }

    #[test]
    fn held_in_any_way_only_a_safety_trigger_that_parks_may_act() {
        let weather = TriggerType::WeatherUnsafe;
        let flip = TriggerType::MeridianFlip {
            config: crate::MeridianFlipConfig::default(),
        };
        let held_modes = [
            RunMode::HeldByRun(RunHold::PreMeridian),
            RunMode::HeldByOperator { run_hold: None },
            RunMode::HeldByOperator {
                run_hold: Some(RunHold::PreMeridian),
            },
            RunMode::Recovering { run_hold: None },
            RunMode::Recovering {
                run_hold: Some(RunHold::PreMeridian),
            },
        ];
        for mode in held_modes {
            assert!(
                mode.may_act(&weather, &RecoveryAction::ParkAndAbort),
                "{mode:?}"
            );
            assert!(!mode.may_act(&weather, &RecoveryAction::Pause), "{mode:?}");
            assert!(
                !mode.may_act(&flip, &RecoveryAction::ParkAndAbort),
                "{mode:?}"
            );
            assert!(
                !mode.may_act(&flip, &RecoveryAction::MeridianFlip(Default::default())),
                "{mode:?}"
            );
        }
        let running = RunMode::Running;
        assert!(running.may_act(&flip, &RecoveryAction::MeridianFlip(Default::default())));
        assert!(running.may_act(&weather, &RecoveryAction::Pause));
    }

    #[test]
    fn an_executor_hold_keeps_the_tracking_edge_unless_the_run_stopped_tracking() {
        assert!(RunMode::Running.reads_tracking_edge());
        assert!(RunMode::HeldByRun(RunHold::PreMeridian).reads_tracking_edge());
        assert!(!RunMode::HeldByOperator { run_hold: None }.reads_tracking_edge());
        assert!(!RunMode::Recovering { run_hold: None }.reads_tracking_edge());
        assert!(RunMode::HeldByOperator {
            run_hold: Some(RunHold::PreMeridian)
        }
        .reads_tracking_edge());
    }

    #[test]
    fn only_a_running_tick_counts_as_the_triggers_evaluating_the_run() {
        let mut run = RunState::default();
        assert_eq!(run.last_evaluation(), TriggerEvaluation::NoMonitor);
        run.reset_for_new_run();
        assert_eq!(
            run.last_evaluation(),
            TriggerEvaluation::AwaitingRunningTick
        );
        run.record_evaluation(RunMode::HeldByOperator { run_hold: None });
        assert_eq!(
            run.last_evaluation(),
            TriggerEvaluation::AwaitingRunningTick
        );
        run.record_evaluation(RunMode::Running);
        assert_eq!(run.last_evaluation(), TriggerEvaluation::Running);
        run.record_evaluation(RunMode::HeldByRun(RunHold::PreMeridian));
        assert_eq!(
            run.last_evaluation(),
            TriggerEvaluation::AwaitingRunningTick
        );
    }
}
