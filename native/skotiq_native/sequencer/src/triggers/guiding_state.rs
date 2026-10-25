//! The run's guiding as the triggers see it: whether this run's guiding is
//! armed, whether its star is lost, whether the run has gone on unguided, and
//! the mount moves that interrupt guiding.

/// Guiding bookkeeping for the run.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct GuidingState {
    /// Guiding this run started (or resumed) is active, which arms the
    /// Guide Star Lost trigger. A guider that was already guiding for someone
    /// else when the run started does not arm it.
    enabled: bool,
    /// The guider reports no star or lost lock while guiding is armed.
    star_lost: bool,
    /// The guide-star recovery gave up and the run carries on unguided:
    /// dithers are skipped and guiding RMS is not judged until the guider is
    /// seen guiding again.
    unguided: bool,
    /// Mount moves the run is making (slew, center, sync, flip). A count,
    /// because a Center slews inside its own move. While non-zero the star
    /// leaving the guide frame is what a move does.
    motion_depth: u32,
    /// A move stopped this run's guiding; the next light frame starts it again
    /// on a fresh star.
    resume_pending: bool,
    /// When the run last tried to start guiding while imaging unguided, or
    /// went unguided.
    last_unguided_attempt: Option<tokio::time::Instant>,
    /// The operator has been told guiding waits for the mount to track.
    tracking_wait_noted: bool,
}

/// What the monitor's guider poll changed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GuiderObservation {
    Unchanged,
    /// The run had gone on unguided and the guider is guiding again, so this
    /// run's guiding is armed again.
    GuidingAgain,
    /// The run is unguided and the guider reports guiding, but the mount is
    /// not tracking. Reported once until guiding runs again.
    GuidingWithoutTracking,
}

impl GuidingState {
    pub fn is_enabled(&self) -> bool {
        self.enabled
    }

    /// Arm or disarm the Guide Star Lost trigger. Armed only when this run
    /// starts or resumes guiding; cleared on an explicit stop so an
    /// intentional stop does not read as a lost star.
    pub fn set_enabled(&mut self, enabled: bool) {
        if self.enabled != enabled {
            tracing::debug!("Guiding-enabled (star-lost trigger arm) -> {}", enabled);
        }
        self.enabled = enabled;
    }

    pub fn star_lost(&self) -> bool {
        self.star_lost
    }

    pub fn set_star_lost(&mut self, lost: bool) {
        if lost && !self.star_lost {
            tracing::warn!("Guide star lost detected");
        }
        self.star_lost = lost;
    }

    /// Whether the Guide Star Lost trigger's condition holds.
    pub fn armed_and_lost(&self) -> bool {
        self.enabled && self.star_lost
    }

    pub fn is_unguided(&self) -> bool {
        self.unguided
    }

    pub fn set_unguided(&mut self, unguided: bool) {
        if unguided && !self.unguided {
            self.last_unguided_attempt = Some(tokio::time::Instant::now());
        }
        self.unguided = unguided;
        if !unguided {
            self.tracking_wait_noted = false;
        }
    }

    /// The guide-star recovery gave up: carry on unguided with nothing armed.
    pub fn give_up_guiding(&mut self) {
        self.set_unguided(true);
        self.set_enabled(false);
        self.set_star_lost(false);
    }

    /// Whether a run imaging unguided is due to try starting guiding again:
    /// it has been `interval` since it went unguided or last tried.
    pub fn unguided_retry_due(&self, interval: std::time::Duration) -> bool {
        self.unguided
            && !self.in_motion()
            && self
                .last_unguided_attempt
                .is_none_or(|last| last.elapsed() >= interval)
    }

    /// Whether a run imaging unguided should try to start guiding again: it
    /// has been `interval` since it went unguided or last tried. Taking a
    /// due attempt starts the next interval.
    pub fn take_unguided_retry(&mut self, interval: std::time::Duration) -> bool {
        let due = self.unguided_retry_due(interval);
        if due {
            self.last_unguided_attempt = Some(tokio::time::Instant::now());
        }
        due
    }

    /// Note that guiding waits for the mount to track. True the first time
    /// since guiding was last running, so the operator is told once.
    pub fn note_tracking_wait(&mut self) -> bool {
        !std::mem::replace(&mut self.tracking_wait_noted, true)
    }

    /// Whether the run is moving the mount itself.
    pub fn in_motion(&self) -> bool {
        self.motion_depth > 0
    }

    pub fn motion_depth(&self) -> u32 {
        self.motion_depth
    }

    /// A move starts. Returns whether it is the outermost one, and, when it
    /// is and this run was guiding, disarms the guiding and marks it for
    /// resumption after the move.
    pub fn begin_motion(&mut self) -> MotionStart {
        self.motion_depth += 1;
        let outermost = self.motion_depth == 1;
        let run_was_guiding = self.enabled;
        MotionStart {
            outermost,
            run_was_guiding,
        }
    }

    /// The outermost move stopped this run's guiding.
    pub fn guiding_stopped_by_motion(&mut self) {
        self.set_enabled(false);
        self.set_star_lost(false);
        self.resume_pending = true;
    }

    pub fn end_motion(&mut self) {
        self.motion_depth = self.motion_depth.saturating_sub(1);
    }

    pub fn resume_pending(&self) -> bool {
        self.resume_pending
    }

    pub fn set_resume_pending(&mut self, pending: bool) {
        self.resume_pending = pending;
    }

    /// Consume the pending resume.
    pub fn take_resume_pending(&mut self) -> bool {
        std::mem::take(&mut self.resume_pending)
    }

    /// Whether a guiding RMS sample may be judged: only guiding this run
    /// started, while it is guiding and the mount is not being moved.
    pub fn judges_rms(&self) -> bool {
        self.enabled && !self.unguided && self.motion_depth == 0
    }

    /// Apply the monitor's guider poll: `Ok(is_guiding)`, or `Err` when the
    /// guider could not be read.
    pub fn observe_guider(&mut self, poll: Result<bool, ()>) -> GuiderObservation {
        self.observe_guider_on_mount(poll, None)
    }

    /// [`Self::observe_guider`] knowing whether the mount tracks. A guider
    /// that reports guiding on a mount known not to track is chasing a star
    /// the sky carries away, so it does not end the run's unguided imaging.
    pub fn observe_guider_on_mount(
        &mut self,
        poll: Result<bool, ()>,
        mount_tracking: Option<bool>,
    ) -> GuiderObservation {
        if self.unguided && poll == Ok(true) && mount_tracking == Some(false) {
            return if self.note_tracking_wait() {
                GuiderObservation::GuidingWithoutTracking
            } else {
                GuiderObservation::Unchanged
            };
        }
        if self.in_motion() {
            self.set_star_lost(false);
            return GuiderObservation::Unchanged;
        }
        match poll {
            Ok(true) => {
                // A guider seen guiding does not arm the trigger by itself;
                // only guiding this run started does.
                self.set_star_lost(false);
                if self.unguided {
                    self.set_unguided(false);
                    self.set_enabled(true);
                    return GuiderObservation::GuidingAgain;
                }
            }
            Ok(false) => {
                let lost = self.enabled;
                self.set_star_lost(lost);
            }
            Err(()) => {
                if self.enabled {
                    self.set_star_lost(true);
                }
            }
        }
        GuiderObservation::Unchanged
    }

    /// Restore the checkpointed latches without logging edges that already
    /// happened in the run that wrote it.
    pub fn restore(&mut self, enabled: bool, star_lost: bool) {
        self.enabled = enabled;
        self.star_lost = star_lost;
    }

    /// A run is starting. Guiding stays armed only for a run resumed from a
    /// checkpoint, which carries on the guiding it recorded.
    pub fn reset_for_new_run(&mut self, resumed: bool) {
        let enabled = resumed && self.enabled;
        *self = Self {
            enabled,
            ..Self::default()
        };
    }
}

/// What [`GuidingState::begin_motion`] found.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MotionStart {
    pub outermost: bool,
    pub run_was_guiding: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn armed() -> GuidingState {
        let mut guiding = GuidingState::default();
        guiding.set_enabled(true);
        guiding
    }

    #[test]
    fn a_guider_that_stops_guiding_loses_the_star_only_when_armed() {
        let mut idle = GuidingState::default();
        idle.observe_guider(Ok(false));
        assert!(!idle.star_lost());
        idle.observe_guider(Err(()));
        assert!(!idle.star_lost());

        let mut guiding = armed();
        guiding.observe_guider(Ok(false));
        assert!(guiding.armed_and_lost());
        guiding.observe_guider(Ok(true));
        assert!(!guiding.star_lost());
        guiding.observe_guider(Err(()));
        assert!(guiding.armed_and_lost());
    }

    #[test]
    fn a_move_is_never_a_lost_star_and_suspends_rms_judging() {
        let mut guiding = armed();
        let start = guiding.begin_motion();
        assert_eq!(
            start,
            MotionStart {
                outermost: true,
                run_was_guiding: true
            }
        );
        guiding.guiding_stopped_by_motion();
        assert!(!guiding.is_enabled());
        assert!(guiding.resume_pending());
        assert!(!guiding.judges_rms());

        // A Center slews inside its own move.
        assert!(!guiding.begin_motion().outermost);
        guiding.observe_guider(Err(()));
        assert!(!guiding.star_lost());
        guiding.end_motion();
        guiding.end_motion();
        guiding.end_motion();
        assert_eq!(guiding.motion_depth(), 0, "ending never underflows");
        assert!(guiding.take_resume_pending());
        assert!(!guiding.take_resume_pending());
    }

    #[test]
    fn a_run_that_went_unguided_is_armed_again_when_the_guider_guides() {
        let mut guiding = armed();
        guiding.give_up_guiding();
        assert!(guiding.is_unguided());
        assert!(!guiding.judges_rms());
        assert_eq!(
            guiding.observe_guider(Ok(false)),
            GuiderObservation::Unchanged
        );
        assert!(!guiding.star_lost());
        assert_eq!(
            guiding.observe_guider(Ok(true)),
            GuiderObservation::GuidingAgain
        );
        assert!(guiding.is_enabled());
        assert!(!guiding.is_unguided());
        assert!(guiding.judges_rms());
    }

    #[test]
    fn only_a_resumed_run_keeps_its_guiding_armed() {
        let mut guiding = armed();
        guiding.set_star_lost(true);
        guiding.set_unguided(true);
        guiding.begin_motion();
        guiding.reset_for_new_run(true);
        assert_eq!(
            guiding,
            GuidingState {
                enabled: true,
                ..Default::default()
            }
        );
        guiding.reset_for_new_run(false);
        assert_eq!(guiding, GuidingState::default());
    }

    /// On 2026-10-24 the monitor logged "The guider is guiding again" at
    /// 04:46:06 while the mount had stopped tracking at its limit and PHD2
    /// was sending 2.5 s pulses after a star the sky carried away.
    #[test]
    fn a_guider_guiding_a_stopped_mount_does_not_end_unguided_imaging() {
        let mut guiding = GuidingState::default();
        guiding.give_up_guiding();
        assert_eq!(
            guiding.observe_guider_on_mount(Ok(true), Some(false)),
            GuiderObservation::GuidingWithoutTracking
        );
        assert_eq!(
            guiding.observe_guider_on_mount(Ok(true), Some(false)),
            GuiderObservation::Unchanged,
            "reported once"
        );
        assert!(guiding.is_unguided());
        assert!(!guiding.is_enabled());
        assert_eq!(
            guiding.observe_guider_on_mount(Ok(true), Some(true)),
            GuiderObservation::GuidingAgain
        );
        assert!(guiding.is_enabled());
    }

    #[test]
    fn an_unguided_run_retries_guiding_once_per_interval() {
        let mut guiding = GuidingState::default();
        let interval = std::time::Duration::from_secs(600);
        assert!(
            !guiding.take_unguided_retry(interval),
            "guided runs never retry"
        );
        guiding.give_up_guiding();
        assert!(
            !guiding.take_unguided_retry(interval),
            "not straight after giving up"
        );
        assert!(guiding.take_unguided_retry(std::time::Duration::ZERO));
        guiding.set_unguided(false);
        assert!(!guiding.take_unguided_retry(std::time::Duration::ZERO));
    }
}
