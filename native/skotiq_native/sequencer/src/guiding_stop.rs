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
    RunStopped,
    /// Someone stopped guiding from the guider controls.
    Operator,
    /// The mount moved on its own or lost its position, and the run is held
    /// until the operator recovers it.
    MountFault,
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
            Self::MountFault => "mount_fault",
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
            "mount_fault" => Self::MountFault,
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
            Self::MountFault => "Guiding stopped: the mount moved on its own",
        }
    }
}

/// What the guider did when it was asked to stop for a mount move.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GuiderForMove {
    /// The rig has no connected guider, or the guider is not moving the
    /// mount: there was nothing to stop.
    Idle,
    /// The guider was guiding and has stopped.
    Stopped,
    /// The guider could not be asked, or did not stop within
    /// [`GUIDER_STOP_BOUND`]; in the device layer's words.
    NotAnswering(String),
}

/// How long a mount move waits for the guider to say what it is doing and to
/// stop. A guider that takes longer is treated as not answering.
pub const GUIDER_STOP_BOUND: std::time::Duration = std::time::Duration::from_secs(10);

/// The one rule for every mount move this app starts (a GoTo, a park, a
/// home, a center, a flip, the run's own slews): a guider that may move the
/// mount is stopped first, because a guider left guiding chases the move and
/// loses its star (see [`crate::DeviceOps::guider_is_active`]).
///
/// The caller decides what [`GuiderForMove::NotAnswering`] means for its
/// move; this never refuses one. A guider whose state cannot be read is asked
/// to stop anyway: guiding through a move is the worse mistake, and stopping
/// an idle guider costs nothing. The wait is bounded, and a guider that
/// answers after the bound is still stopped, in the background.
pub async fn stop_guider_for_move(
    device_ops: &crate::SharedDeviceOps,
    what: &str,
    reason: GuidingStopReason,
) -> GuiderForMove {
    stop_guider_for_move_within(device_ops, what, reason, GUIDER_STOP_BOUND).await
}

async fn stop_guider_for_move_within(
    device_ops: &crate::SharedDeviceOps,
    what: &str,
    reason: GuidingStopReason,
    bound: std::time::Duration,
) -> GuiderForMove {
    use crate::device_ops::{DeviceError, DeviceKind};

    let ops = device_ops.clone();
    let move_name = what.to_string();
    // A task of its own: a guider client that blocks its thread cannot hold
    // the move past the bound.
    let asked = tokio::spawn(async move {
        match ops.guider_is_active().await {
            Ok(false) => return GuiderForMove::Idle,
            Ok(true) => {}
            Err(DeviceError::NO_GUIDER)
            | Err(DeviceError::NotConnected {
                device: DeviceKind::Guider,
                ..
            }) => return GuiderForMove::Idle,
            Err(error) => {
                tracing::warn!(
                    "[GUIDING] Could not read the guider's state before the {move_name} \
                     ({error}); stopping it so it cannot guide while the mount moves"
                );
            }
        }
        tracing::info!(
            "[GUIDING] Stopping the guider for the {move_name}: it cannot guide while the \
             mount moves"
        );
        ops.guider_note_stop_reason(Some(reason)).await;
        match ops.guider_stop().await {
            Ok(()) => GuiderForMove::Stopped,
            Err(error) => GuiderForMove::NotAnswering(error.to_string()),
        }
    });
    let outcome = match tokio::time::timeout(bound, asked).await {
        Ok(Ok(outcome)) => outcome,
        Ok(Err(join_error)) => GuiderForMove::NotAnswering(join_error.to_string()),
        Err(_) => GuiderForMove::NotAnswering(format!(
            "the guider did not answer within {} s",
            bound.as_secs()
        )),
    };
    if let GuiderForMove::NotAnswering(why) = &outcome {
        tracing::warn!("[GUIDING] The guider did not stop for the {what}: {why}");
    }
    outcome
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
            GuidingStopReason::MountFault,
        ] {
            assert_eq!(GuidingStopReason::from_wire(reason.as_wire()), Some(reason));
            assert_eq!(
                serde_json::to_value(reason).unwrap(),
                serde_json::Value::String(reason.as_wire().to_string())
            );
            assert!(!reason.describe().to_lowercase().contains("lost"));
        }
    }

    /// A guider scripted to be in one condition when a move asks it to stop.
    struct ScriptedGuider {
        inner: crate::device_ops::NullDeviceOps,
        active: fn() -> crate::device_ops::DeviceResult<bool>,
        stop: fn() -> crate::device_ops::DeviceResult<()>,
        /// How long the guider takes to answer anything.
        answers_after: std::time::Duration,
        stops: std::sync::atomic::AtomicUsize,
        reasons: std::sync::Mutex<Vec<Option<GuidingStopReason>>>,
    }

    impl ScriptedGuider {
        fn shared(
            active: fn() -> crate::device_ops::DeviceResult<bool>,
            stop: fn() -> crate::device_ops::DeviceResult<()>,
            answers_after: std::time::Duration,
        ) -> (std::sync::Arc<Self>, crate::SharedDeviceOps) {
            let guider = std::sync::Arc::new(Self {
                inner: crate::device_ops::NullDeviceOps,
                active,
                stop,
                answers_after,
                stops: std::sync::atomic::AtomicUsize::new(0),
                reasons: std::sync::Mutex::new(Vec::new()),
            });
            (guider.clone(), guider)
        }

        fn stops(&self) -> usize {
            self.stops.load(std::sync::atomic::Ordering::SeqCst)
        }
    }

    crate::forward_device_ops!(ScriptedGuider => inner: MountOps, CameraOps, FocuserOps, FilterWheelOps, RotatorOps, DomeOps, CoverCalibratorOps, SafetyOps, PlateSolveOps, FrameStoreOps, OperatorNotifyOps, ConnectionOps, SiteOps);

    #[async_trait::async_trait]
    impl crate::device_ops::GuiderOps for ScriptedGuider {
        async fn guider_dither(
            &self,
            _pixels: f64,
            _settle_pixels: f64,
            _settle_time: f64,
            _settle_timeout: f64,
            _ra_only: bool,
        ) -> crate::device_ops::DeviceResult<()> {
            Ok(())
        }

        async fn guider_get_status(
            &self,
        ) -> crate::device_ops::DeviceResult<crate::device_ops::GuidingStatus> {
            Err("not scripted".into())
        }

        async fn guider_is_active(&self) -> crate::device_ops::DeviceResult<bool> {
            tokio::time::sleep(self.answers_after).await;
            (self.active)()
        }

        async fn guider_start(
            &self,
            _settle_pixels: f64,
            _settle_time: f64,
            _settle_timeout: f64,
        ) -> crate::device_ops::DeviceResult<()> {
            Ok(())
        }

        async fn guider_stop(&self) -> crate::device_ops::DeviceResult<()> {
            tokio::time::sleep(self.answers_after).await;
            self.stops.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            (self.stop)()
        }

        async fn guider_note_stop_reason(&self, reason: Option<GuidingStopReason>) {
            self.reasons.lock().unwrap().push(reason);
        }
    }

    const AT_ONCE: std::time::Duration = std::time::Duration::ZERO;

    #[tokio::test]
    async fn a_guiding_guider_is_stopped_with_the_moves_reason() {
        let (guider, ops) = ScriptedGuider::shared(|| Ok(true), || Ok(()), AT_ONCE);
        let outcome = stop_guider_for_move(&ops, "slew", GuidingStopReason::MountMove).await;
        assert_eq!(outcome, GuiderForMove::Stopped);
        assert_eq!(guider.stops(), 1);
        assert_eq!(
            *guider.reasons.lock().unwrap(),
            vec![Some(GuidingStopReason::MountMove)]
        );
    }

    #[tokio::test]
    async fn an_idle_missing_or_unconnected_guider_is_left_alone() {
        use crate::device_ops::{DeviceError, DeviceKind};
        let conditions: [fn() -> crate::device_ops::DeviceResult<bool>; 3] = [
            || Ok(false),
            || Err(DeviceError::NO_GUIDER),
            || {
                Err(DeviceError::NotConnected {
                    device: DeviceKind::Guider,
                    message: "Device not connected: PHD2".to_string(),
                })
            },
        ];
        for active in conditions {
            let (guider, ops) = ScriptedGuider::shared(active, || Ok(()), AT_ONCE);
            let outcome = stop_guider_for_move(&ops, "park", GuidingStopReason::MountMove).await;
            assert_eq!(outcome, GuiderForMove::Idle);
            assert_eq!(guider.stops(), 0, "nothing to stop");
            assert!(guider.reasons.lock().unwrap().is_empty());
        }
    }

    #[tokio::test]
    async fn a_guider_whose_state_cannot_be_read_is_asked_to_stop() {
        let (guider, ops) = ScriptedGuider::shared(
            || Err("Failed to get PHD2 state: timed out".into()),
            || Ok(()),
            AT_ONCE,
        );
        let outcome = stop_guider_for_move(&ops, "slew", GuidingStopReason::MountMove).await;
        assert_eq!(outcome, GuiderForMove::Stopped);
        assert_eq!(guider.stops(), 1);
    }

    #[tokio::test]
    async fn a_guider_that_will_not_stop_is_not_answering() {
        let (_guider, ops) = ScriptedGuider::shared(
            || Ok(true),
            || Err("Failed to stop PHD2 capture: timed out".into()),
            AT_ONCE,
        );
        let outcome = stop_guider_for_move(&ops, "slew", GuidingStopReason::MountMove).await;
        assert!(
            matches!(&outcome, GuiderForMove::NotAnswering(why) if why.contains("timed out")),
            "{outcome:?}"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn a_guider_slower_than_the_bound_does_not_hold_the_move() {
        let (guider, ops) = ScriptedGuider::shared(
            || Ok(true),
            || Ok(()),
            std::time::Duration::from_secs(60),
        );
        let asked = tokio::time::Instant::now();
        let outcome = stop_guider_for_move(&ops, "park", GuidingStopReason::MountMove).await;
        assert!(matches!(outcome, GuiderForMove::NotAnswering(_)), "{outcome:?}");
        assert_eq!(asked.elapsed(), GUIDER_STOP_BOUND);
        assert_eq!(guider.stops(), 0);

        // The stop is not abandoned: a guider that answers late still stops.
        tokio::time::sleep(std::time::Duration::from_secs(180)).await;
        assert_eq!(guider.stops(), 1);
    }
}
