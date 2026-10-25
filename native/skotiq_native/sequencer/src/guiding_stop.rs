//! Why the guider is stopped, so a planned stop never reads as lost guiding.
//!
//! The run states a reason through [`crate::DeviceOps::guider_note_stop_reason`]
//! before it stops the guider for one of its own steps, and the device layer
//! publishes it beside the guider's state. A reason stays until guiding starts
//! again.

use serde::{Deserialize, Serialize};

/// What stopped (or is holding) the guider.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GuidingStopReason {
    /// Autofocus stops guiding while it moves the focuser.
    Autofocus,
    /// A meridian flip stops guiding before the mount turns over.
    MeridianFlip,
    /// The mount reached its tracking limit and the run holds until the flip.
    TrackingLimitHold,
    /// A slew, center or sync the run is making.
    MountMove,
    /// The run stopped tracking ahead of the meridian and waits for the flip.
    PreMeridianHold,
    /// The sequence's own Stop Guiding step.
    SequenceStep,
    /// The guider is settling after a dither.
    DitherSettle,
    /// The run was stopped.
    RunStopped,
    /// Someone stopped guiding from the guider controls.
    Operator,
}

impl GuidingStopReason {
    /// Stable snake_case name for the wire and the REST API.
    pub fn as_wire(self) -> &'static str {
        match self {
            Self::Autofocus => "autofocus",
            Self::MeridianFlip => "meridian_flip",
            Self::TrackingLimitHold => "tracking_limit_hold",
            Self::MountMove => "mount_move",
            Self::PreMeridianHold => "pre_meridian_hold",
            Self::SequenceStep => "sequence_step",
            Self::DitherSettle => "dither_settle",
            Self::RunStopped => "run_stopped",
            Self::Operator => "operator",
        }
    }

    pub fn from_wire(wire: &str) -> Option<Self> {
        Some(match wire {
            "autofocus" => Self::Autofocus,
            "meridian_flip" => Self::MeridianFlip,
            "tracking_limit_hold" => Self::TrackingLimitHold,
            "mount_move" => Self::MountMove,
            "pre_meridian_hold" => Self::PreMeridianHold,
            "sequence_step" => Self::SequenceStep,
            "dither_settle" => Self::DitherSettle,
            "run_stopped" => Self::RunStopped,
            "operator" => Self::Operator,
            _ => return None,
        })
    }

    /// Plain words for a status line: "Guiding paused for autofocus".
    pub fn describe(self) -> &'static str {
        match self {
            Self::Autofocus => "Guiding paused for autofocus",
            Self::MeridianFlip => "Guiding paused for the meridian flip",
            Self::TrackingLimitHold => {
                "Guiding paused: the mount is at its tracking limit and waits for the flip"
            }
            Self::MountMove => "Guiding paused while the mount moves",
            Self::PreMeridianHold => "Guiding paused: the run waits at the meridian for the flip",
            Self::SequenceStep => "Guiding stopped by the sequence's Stop Guiding step",
            Self::DitherSettle => "Guiding is settling after a dither",
            Self::RunStopped => "Guiding stopped because the run was stopped",
            Self::Operator => "Guiding stopped from the guider controls",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_reason_round_trips_through_its_wire_name() {
        for reason in [
            GuidingStopReason::Autofocus,
            GuidingStopReason::MeridianFlip,
            GuidingStopReason::TrackingLimitHold,
            GuidingStopReason::MountMove,
            GuidingStopReason::PreMeridianHold,
            GuidingStopReason::SequenceStep,
            GuidingStopReason::DitherSettle,
            GuidingStopReason::RunStopped,
            GuidingStopReason::Operator,
        ] {
            assert_eq!(GuidingStopReason::from_wire(reason.as_wire()), Some(reason));
            assert_eq!(
                serde_json::to_value(reason).unwrap(),
                serde_json::Value::String(reason.as_wire().to_string())
            );
            assert!(!reason.describe().to_lowercase().contains("lost"));
        }
    }
}
