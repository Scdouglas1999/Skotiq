//! Stage 3 of a monitor tick: turn firings into dispatches.

use super::*;
use crate::triggers::Firing;

/// The operator settings that turn a firing into what is dispatched.
pub(super) struct DispatchPolicy {
    /// The sequence ends itself at dawn, so the Dawn Approaching trigger
    /// stands down.
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
        if policy.explicit_end && trigger_id == "dawn_approaching" {
            continue;
        }
        if policy.calibration_run && !super::super::calibration_run::acts_in_calibration_run(&trigger_id) {
            continue;
        }
        // Park and quality settings first, so the mode judges what the
        // trigger will actually do.
        let fired = apply_quality_policy(
            &trigger_id,
            apply_park_policy(&trigger_id, firing.action().clone(), policy.park_policy, policy.weather_advisory_only),
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
