//! The run's meridian-flip bookkeeping for its current target, and the one
//! precondition every flip decision reads.
//!
//! The trigger, the pre-frame flip gate, the pre-meridian hold and an
//! operator's flip request all ask "could the trigger flip now?". They ask it
//! through [`TriggerState::flip_blocked`] so the answer cannot drift between
//! them.

use super::run_mode::{RunMode, TriggerEvaluation};
use super::TriggerState;
use crate::{MeridianTriggerMethod, PierSide};

/// The flip that has run for the current target.
#[derive(Debug, Clone, Copy, PartialEq)]
struct Flipped {
    /// The pier side the mount left. Observing it again means the mount is
    /// back on the pre-flip side and a fresh flip is due. `None` when the
    /// side was not known, which keeps the flip latched until the target
    /// changes.
    origin: Option<PierSide>,
}

/// Flip bookkeeping for the current target.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct MeridianFlipState {
    flipped: Option<Flipped>,
    /// The operator asked the running sequence to flip now rather than wait
    /// for the window. See `manual_flip.rs`.
    requested: bool,
    /// The trigger fired on the monitor's last tick and its action is waiting
    /// for the imaging train or running. The monitor runs the action inline,
    /// so the tick that clears this comes only after the flip has finished.
    dispatch_pending: bool,
}

impl MeridianFlipState {
    /// Whether a flip has run for the current target. Once set the trigger
    /// does not fire again until the target changes or the mount is seen back
    /// on the side it flipped from.
    pub fn has_flipped(&self) -> bool {
        self.flipped.is_some()
    }

    /// The pier side the recorded flip left, when known.
    pub fn flip_origin(&self) -> Option<PierSide> {
        self.flipped.and_then(|flipped| flipped.origin)
    }

    /// Record a completed flip. `pier_side_now` is the side read after the
    /// flip; the origin is its opposite.
    pub fn mark_performed(&mut self, pier_side_now: Option<PierSide>) {
        let origin = match pier_side_now {
            Some(PierSide::East) => Some(PierSide::West),
            Some(PierSide::West) => Some(PierSide::East),
            _ => None,
        };
        self.flipped = Some(Flipped { origin });
        self.requested = false;
    }

    /// Restore the flipped latch from a checkpoint, which records only whether
    /// a flip ran.
    pub fn restore_flipped(&mut self, flipped: bool) {
        self.flipped = flipped.then(|| Flipped {
            origin: self.flip_origin(),
        });
    }

    /// Forget the flip at a natural target boundary.
    pub fn clear_flipped(&mut self) {
        self.flipped = None;
    }

    /// Clear the flip when the mount is observed back on the side it flipped
    /// from. Returns whether it cleared. `Unknown` and an unrecorded origin
    /// are not evidence of a return.
    pub fn on_pier_side_observed(&mut self, side: PierSide) -> bool {
        let Some(origin) = self.flip_origin() else {
            return false;
        };
        if side == PierSide::Unknown || side != origin {
            return false;
        }
        self.flipped = None;
        true
    }

    pub fn is_requested(&self) -> bool {
        self.requested
    }

    /// The operator asks for a flip now.
    pub fn request(&mut self) {
        self.requested = true;
    }

    /// Consume the operator's request; it asked for this flip, not every later
    /// one.
    pub fn take_request(&mut self) -> bool {
        std::mem::take(&mut self.requested)
    }

    pub fn dispatch_pending(&self) -> bool {
        self.dispatch_pending
    }

    /// The target changed: nothing recorded for the old one applies.
    pub fn target_changed(&mut self) {
        self.flipped = None;
        self.requested = false;
    }

    /// Forget the flip and the request; the dispatch latch belongs to the
    /// monitor tick and is left alone.
    pub fn clear(&mut self) {
        self.flipped = None;
        self.requested = false;
    }

    /// A run is starting.
    pub fn reset_for_new_run(&mut self) {
        *self = Self::default();
    }
}

/// Why the meridian trigger cannot flip right now, before its window is
/// considered.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FlipBlocked {
    /// No target is set, so there is nothing to flip for.
    NoTarget,
    /// The current target has already been flipped.
    AlreadyFlipped,
    /// The mount reports parked. Calibration frames are taken that way, and
    /// where a parked mount points cannot ruin them.
    MountParked,
    /// The mount reports it is not tracking.
    MountNotTracking,
}

/// What has become of a flip that is due, as the pre-frame gate sees it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FlipProgress {
    /// The flip has completed for this target.
    Flipped,
    /// The trigger fired or the operator asked; the flip is on its way.
    Starting,
    /// The trigger had a running evaluation and did not fire, or no monitor is
    /// running at all.
    NotComing,
    /// The run is starting or held and the trigger has not had a running
    /// evaluation since.
    AwaitingEvaluation,
}

impl TriggerState {
    /// Record one monitor evaluation: the mode it ran in, and whether it
    /// dispatched a flip.
    pub fn record_evaluation(&mut self, mode: RunMode, flip_dispatching: bool) {
        self.run.record_evaluation(mode);
        self.meridian.dispatch_pending = flip_dispatching;
    }

    /// The meridian trigger's preconditions for `method`, or `None` when the
    /// trigger may fire if its window is open.
    ///
    /// Only a definite parked or not-tracking reading blocks; a mount that
    /// never reports either keeps its flips. `OnTrackingLimitHit` is exempt
    /// from both, since tracking having stopped is its premise.
    pub fn flip_blocked(&self, method: MeridianTriggerMethod) -> Option<FlipBlocked> {
        if self.target_ra.is_none() || self.target_dec.is_none() {
            return Some(FlipBlocked::NoTarget);
        }
        if self.meridian.has_flipped() {
            return Some(FlipBlocked::AlreadyFlipped);
        }
        if method == MeridianTriggerMethod::OnTrackingLimitHit {
            return None;
        }
        if self.mount_parked == Some(true) {
            return Some(FlipBlocked::MountParked);
        }
        if self.mount_is_tracking == Some(false) {
            return Some(FlipBlocked::MountNotTracking);
        }
        None
    }

    /// An operator's flip request the trigger acts on at its next tick.
    pub fn flip_request_pending(&self) -> bool {
        self.meridian.is_requested() && self.manual_flip_refusal().is_none()
    }

    /// What has become of a due flip, for the pre-frame gate.
    pub fn flip_progress(&self) -> FlipProgress {
        if self.meridian.has_flipped() {
            FlipProgress::Flipped
        } else if self.meridian.dispatch_pending() || self.flip_request_pending() {
            FlipProgress::Starting
        } else if self.run.last_evaluation() == TriggerEvaluation::AwaitingRunningTick {
            FlipProgress::AwaitingEvaluation
        } else {
            FlipProgress::NotComing
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::triggers::{RunHold, Trigger};
    use crate::{MeridianFlipConfig, RecoveryAction, TriggerType};

    /// A target 15 minutes past the meridian, tracked on the pre-flip side.
    fn due_state() -> TriggerState {
        let mut state = TriggerState::new();
        state.target_ra = Some(10.0);
        state.target_dec = Some(40.0);
        state.current_hour_angle = Some(0.25);
        state.pier_side = Some(PierSide::West);
        state.mount_is_tracking = Some(true);
        state.mount_parked = Some(false);
        state
    }

    fn flip_trigger(method: MeridianTriggerMethod) -> Trigger {
        let config = MeridianFlipConfig {
            trigger_method: method,
            minutes_past_meridian: 5.0,
            ..Default::default()
        };
        Trigger::new(
            "meridian_flip",
            "Meridian Flip",
            TriggerType::MeridianFlip {
                config: config.clone(),
            },
            RecoveryAction::MeridianFlip(config),
        )
    }

    #[test]
    fn a_flip_records_the_side_it_left_and_clears_only_on_a_real_return() {
        let mut flip = MeridianFlipState::default();
        flip.request();
        flip.mark_performed(Some(PierSide::East));
        assert!(flip.has_flipped());
        assert!(
            !flip.is_requested(),
            "a completed flip consumes the request"
        );
        assert_eq!(flip.flip_origin(), Some(PierSide::West));

        assert!(!flip.on_pier_side_observed(PierSide::Unknown));
        assert!(!flip.on_pier_side_observed(PierSide::East));
        assert!(flip.has_flipped());
        assert!(flip.on_pier_side_observed(PierSide::West));
        assert!(!flip.has_flipped());
        assert_eq!(flip.flip_origin(), None);
    }

    #[test]
    fn a_flip_from_an_unknown_side_stays_latched_until_the_target_changes() {
        let mut flip = MeridianFlipState::default();
        flip.mark_performed(Some(PierSide::Unknown));
        assert_eq!(flip.flip_origin(), None);
        assert!(!flip.on_pier_side_observed(PierSide::West));
        assert!(!flip.on_pier_side_observed(PierSide::East));
        assert!(flip.has_flipped());
        flip.target_changed();
        assert!(!flip.has_flipped());
    }

    /// No origin can exist without a flip: there is no field to hold one.
    #[test]
    fn restoring_an_unflipped_target_leaves_no_origin() {
        let mut flip = MeridianFlipState::default();
        flip.mark_performed(Some(PierSide::West));
        flip.restore_flipped(false);
        assert!(!flip.has_flipped());
        assert_eq!(flip.flip_origin(), None);
        flip.restore_flipped(true);
        assert!(flip.has_flipped());
    }

    #[test]
    fn the_request_is_consumed_once() {
        let mut flip = MeridianFlipState::default();
        flip.request();
        assert!(flip.take_request());
        assert!(!flip.take_request());
    }

    #[test]
    fn a_target_change_keeps_a_dispatch_already_on_its_way() {
        let mut state = due_state();
        state.record_evaluation(RunMode::Running, true);
        state.meridian.mark_performed(Some(PierSide::East));
        state.meridian.target_changed();
        assert!(state.meridian.dispatch_pending());
        assert_eq!(state.flip_progress(), FlipProgress::Starting);
    }

    #[test]
    fn preconditions_are_reported_in_a_fixed_order() {
        let mut state = due_state();
        assert_eq!(
            state.flip_blocked(MeridianTriggerMethod::MinutesPastMeridian),
            None
        );
        state.mount_is_tracking = Some(false);
        assert_eq!(
            state.flip_blocked(MeridianTriggerMethod::MinutesPastMeridian),
            Some(FlipBlocked::MountNotTracking)
        );
        state.mount_parked = Some(true);
        assert_eq!(
            state.flip_blocked(MeridianTriggerMethod::MinutesPastMeridian),
            Some(FlipBlocked::MountParked)
        );
        state.meridian.mark_performed(None);
        assert_eq!(
            state.flip_blocked(MeridianTriggerMethod::MinutesPastMeridian),
            Some(FlipBlocked::AlreadyFlipped)
        );
        state.target_ra = None;
        assert_eq!(
            state.flip_blocked(MeridianTriggerMethod::MinutesPastMeridian),
            Some(FlipBlocked::NoTarget)
        );
    }

    #[test]
    fn a_tracking_limit_flip_is_not_blocked_by_the_mount_having_stopped() {
        let mut state = due_state();
        state.mount_is_tracking = Some(false);
        state.mount_parked = Some(true);
        assert_eq!(
            state.flip_blocked(MeridianTriggerMethod::OnTrackingLimitHit),
            None
        );
    }

    /// Every precondition that blocks the predicate stops the trigger and is
    /// refused to an operator; with none, the trigger fires in its window.
    #[tokio::test]
    async fn the_trigger_and_the_operator_request_agree_with_the_predicate() {
        type Mutation = fn(&mut TriggerState);
        let blockers: [Mutation; 4] = [
            |s| s.target_dec = None,
            |s| s.meridian.mark_performed(None),
            |s| s.mount_parked = Some(true),
            |s| s.mount_is_tracking = Some(false),
        ];
        for block in blockers {
            let mut state = due_state();
            block(&mut state);
            assert!(state
                .flip_blocked(MeridianTriggerMethod::MinutesPastMeridian)
                .is_some());
            assert!(
                !flip_trigger(MeridianTriggerMethod::MinutesPastMeridian)
                    .check(&state)
                    .await
            );
            assert!(state.manual_flip_refusal().is_some());
            state.meridian.request();
            assert!(!state.flip_request_pending());
        }
        let state = due_state();
        assert!(
            flip_trigger(MeridianTriggerMethod::MinutesPastMeridian)
                .check(&state)
                .await
        );
        assert!(state.manual_flip_refusal().is_none());
    }

    #[test]
    fn flip_progress_follows_the_monitor() {
        let mut state = due_state();
        assert_eq!(state.flip_progress(), FlipProgress::NotComing, "no monitor");
        state.reset_for_new_run();
        state.target_ra = Some(10.0);
        state.target_dec = Some(40.0);
        assert_eq!(state.flip_progress(), FlipProgress::AwaitingEvaluation);
        state.record_evaluation(RunMode::HeldByRun(RunHold::PreMeridian), false);
        assert_eq!(state.flip_progress(), FlipProgress::AwaitingEvaluation);
        state.record_evaluation(RunMode::Running, false);
        assert_eq!(state.flip_progress(), FlipProgress::NotComing);
        state.record_evaluation(RunMode::Running, true);
        assert_eq!(state.flip_progress(), FlipProgress::Starting);
        state.mark_flip_performed();
        assert_eq!(state.flip_progress(), FlipProgress::Flipped);
    }
}
