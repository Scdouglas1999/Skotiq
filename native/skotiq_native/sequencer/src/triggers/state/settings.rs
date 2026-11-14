//! Operator settings the trigger monitor and the instructions read.

use super::part::state_part;
use super::TriggerState;
use std::sync::Arc;
use tokio::sync::RwLock;

state_part! {
    /// Operator configuration, carried on the trigger state because the
    /// instructions already hold that handle. Never reset by a run.
    pub struct TriggerSettings, checkpointed as SettingsSnapshot {
        persisted {
            pub observer_latitude: Option<f64>,
            pub observer_longitude: Option<f64>,
        }
        transient {
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
            /// The run's dither settle settings, as last pushed.
            pub dither_settle: crate::GuiderSettle,
            /// The operator's guider settle settings (carried on the meridian-flip
            /// config), when known.
            pub guiding_settle: Option<crate::GuiderSettle>,
            /// The run's safety fail mode, copied in by the trigger monitor each tick
            /// so the weather hold resolves a missing safety reading the same way the
            /// monitor does.
            pub safety_fail_mode: crate::SafetyFailMode,
        }
    }
}

state_part! {
    /// Values copied from the armed triggers' configuration on every
    /// evaluation tick (`TriggerManager::sync_state_from_config`), so the
    /// instructions and the trigger evaluator can read them from the state.
    pub struct MirroredTriggerConfig, checkpointed as TriggerConfigSnapshot {
        persisted {
            /// The active meridian trigger method (so MountTrackingLost can defer to OnTrackingLimitHit)
            pub meridian_trigger_method: Option<crate::MeridianTriggerMethod>,
        }
        transient {
            /// Threshold (minutes past meridian) of the active MinutesPastMeridian
            /// flip trigger, propagated by [`TriggerManager::sync_state_from_config`]
            /// on every evaluation tick. The exposure instruction's pre-frame
            /// meridian gate reads this to hold frames that would still be exposing
            /// when the flip fires. None when no MinutesPastMeridian flip trigger
            /// is enabled (other trigger methods are not predictable in advance).
            pub meridian_flip_minutes_past: Option<f64>,
            /// Minutes before the meridian the active MinutesPastMeridian flip trigger
            /// stops tracking and holds the run until the flip, propagated like
            /// [`Self::meridian_flip_minutes_past`]. None when the hold is off.
            pub meridian_pause_before_minutes: Option<f64>,
            /// configurable retention window (seconds) for
            /// `guiding_rms_history`. Set by the trigger evaluator from the
            /// `GuidingFailed` trigger configuration so a user-tuned value is
            /// honoured. Defaults to 300s (5 minutes), matching the previous
            /// hardcoded behaviour.
            pub guiding_rms_retention_secs: u64 = 300,
        }
    }
}

impl TriggerState {
    /// Whether the operator asked for quality problems to stop the run. Off
    /// by default (owner decision 2026-10-06): a judgment the software makes
    /// about the frames, the guiding or the pointing notifies and the run
    /// keeps imaging; only a risk to the hardware stops a run by itself.
    pub fn stops_on_quality_problems(&self) -> bool {
        self.settings.stop_on_quality_problems
    }
}

/// [`TriggerState::stops_on_quality_problems`] through the shared handle. Off
/// with no run state at all (a one-shot instruction).
pub async fn stops_on_quality_problems(state: Option<&Arc<RwLock<TriggerState>>>) -> bool {
    match state {
        Some(state) => state.read().await.stops_on_quality_problems(),
        None => false,
    }
}
