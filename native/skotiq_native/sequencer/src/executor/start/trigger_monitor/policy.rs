//! Stage 3 of a monitor tick: turn firings into dispatches.

use super::*;
use crate::triggers::Firing;

/// The operator settings that turn a firing into what is dispatched.
pub(super) struct DispatchPolicy {
    /// The sequence ends itself at dawn, so the Dawn Approaching trigger
    /// stands down while the run is not held.
    pub explicit_end: bool,
    pub calibration_run: bool,
    pub park_policy: ParkPolicy,
    pub stop_on_quality_problems: bool,
    pub weather_advisory_only: bool,
}

/// A firing the run will act on this tick.
pub(super) struct Dispatch {
    pub trigger_id: String,
    pub trigger_name: String,
    pub fired: FiredTriggerAction,
    pub cooldown_secs: Option<u64>,
}

/// Turn this tick's firings into dispatches: apply the operator's park and
/// quality settings, then drop what `mode` does not allow. Only a firing that
/// is kept is dispatched, which is what starts its cooldown; a dropped one
/// fires again on the first tick its mode allows.
pub(super) fn select_dispatches(
    manager: &mut TriggerManager,
    fired: Vec<Firing>,
    mode: RunMode,
    policy: DispatchPolicy,
) -> Vec<Dispatch> {
    let mut dispatches = Vec::new();
    for firing in fired {
        let trigger_id = firing.trigger_id().to_string();
        // A plan that owns its finish time reaches it only while its node
        // tree runs. Paused or recovering, its end never comes, so dawn ends
        // the night as for any plan.
        if policy.explicit_end && trigger_id == "dawn_approaching" && !mode.executor_held() {
            continue;
        }
        if policy.calibration_run
            && !super::super::calibration_run::acts_in_calibration_run(&trigger_id)
        {
            continue;
        }
        // Park and quality settings first, so the mode judges what the
        // trigger will actually do.
        let trigger_type = manager
            .get_trigger(&trigger_id)
            .map(|trigger| trigger.trigger_type.clone());
        let fired = apply_quality_policy(
            &trigger_id,
            trigger_type.as_ref(),
            apply_park_policy(
                &trigger_id,
                firing.action().clone(),
                policy.park_policy,
                policy.weather_advisory_only,
            ),
            policy.stop_on_quality_problems,
        );
        // A trigger removed since the evaluation cannot be classified, and an
        // unclassified trigger must not act under a hold.
        let may_act = match manager.get_trigger(&trigger_id) {
            Some(trigger) => mode.may_act(&trigger.trigger_type, &fired.action),
            None => mode.is_running(),
        };
        if !may_act {
            tracing::debug!(
                "Trigger '{}' fired while the run is held; it is not a safety-class trigger \
                 with a protective action, so it is not acted on until the run resumes",
                trigger_id
            );
            continue;
        }
        let (trigger_name, cooldown_secs) = match manager.dispatch(firing) {
            Some(trigger) => (trigger.name.clone(), trigger.cooldown_secs),
            None => (trigger_id.clone(), None),
        };
        dispatches.push(Dispatch {
            trigger_id,
            trigger_name,
            fired,
            cooldown_secs,
        });
    }
    // If the sky turns unsafe on the very tick the limit hold's flip comes
    // due, park first. A terminating safety action must never wait for a slew.
    if matches!(
        mode,
        RunMode::HeldByRun(crate::triggers::RunHold::TrackingLimit)
    ) {
        dispatches.sort_by_key(|d| !matches!(d.fired.action, RecoveryAction::ParkAndAbort));
    }
    dispatches
}

/// When each notify-only trigger last fired, so a condition that keeps holding
/// is told once per episode (see `notify_episode_gap`).
#[derive(Default)]
pub(super) struct NotifyEpisodes {
    last_fired: HashMap<String, std::time::Instant>,
}

impl NotifyEpisodes {
    /// Record a notify-only firing and return whether it begins a new
    /// episode the operator should hear about.
    pub(super) fn is_new_episode(&mut self, dispatch: &Dispatch) -> bool {
        let now = std::time::Instant::now();
        let same_episode = self
            .last_fired
            .get(&dispatch.trigger_id)
            .is_some_and(|last| {
                now.duration_since(*last) < notify_episode_gap(dispatch.cooldown_secs)
            });
        self.last_fired.insert(dispatch.trigger_id.clone(), now);
        !same_episode
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fired(action: RecoveryAction) -> FiredTriggerAction {
        FiredTriggerAction {
            action,
            end_without_parking: false,
            notify_only: false,
        }
    }

    fn hfr_degraded() -> TriggerType {
        TriggerType::HfrDegraded {
            threshold_percent: 20.0,
            absolute_threshold: 0.0,
            consecutive_frames: 1,
        }
    }

    fn notifies(trigger_type: TriggerType, action: RecoveryAction, stop: bool) -> bool {
        apply_quality_policy("saved", Some(&trigger_type), fired(action), stop).notify_only
    }

    /// Saved configurations carry Pause or Retry for quality triggers (the rig
    /// had Guide Star Lost on Pause). The rule overrides them: a quality or
    /// guiding trigger only notifies unless the operator turned on Stop the
    /// run for quality problems.
    #[test]
    fn quality_triggers_that_would_stop_the_run_only_notify() {
        let quality = [
            TriggerType::GuideStarLost,
            TriggerType::GuidingFailed {
                rms_threshold: 2.0,
                duration_secs: 60.0,
                rms_retention_secs: 300,
            },
            TriggerType::TransparencyDropped {
                below_threshold: 0.6,
                duration_secs: 60.0,
            },
            hfr_degraded(),
            TriggerType::DriftLimit { max_pixels: 30.0 },
        ];
        for trigger_type in quality {
            for action in [
                RecoveryAction::Pause,
                RecoveryAction::Retry { max_attempts: 3 },
                RecoveryAction::PauseAndWaitForClear,
                RecoveryAction::ParkAndAbort,
            ] {
                assert!(
                    notifies(trigger_type.clone(), action.clone(), false),
                    "{trigger_type:?} with {action:?}"
                );
                assert!(
                    !notifies(trigger_type.clone(), action.clone(), true),
                    "opt-in keeps {trigger_type:?} with {action:?}"
                );
            }
        }
    }

    #[test]
    fn actions_that_keep_imaging_and_rig_safety_triggers_are_left_alone() {
        assert!(!notifies(
            hfr_degraded(),
            RecoveryAction::Autofocus,
            false
        ));
        assert!(!notifies(
            TriggerType::DriftLimit { max_pixels: 30.0 },
            RecoveryAction::Recenter,
            false
        ));
        assert!(!notifies(
            TriggerType::DawnApproaching {
                minutes_before: 30.0
            },
            RecoveryAction::ParkAndAbort,
            false
        ));
        assert!(!notifies(
            TriggerType::MountTrackingLost,
            RecoveryAction::Pause,
            false
        ));
        assert!(!notifies(
            TriggerType::WeatherUnsafe,
            RecoveryAction::ParkAndAbort,
            false
        ));
    }
}
