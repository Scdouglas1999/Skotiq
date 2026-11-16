//! PHD2's event stream read as a whole rather than one event at a time:
//! whether PHD2 holds a guide star, so a lost star counts only then.

use skotiq_phd2::Phd2State;

#[derive(Debug, Default)]
pub(super) struct Phd2Watch {
    /// PHD2's state as its events last said, `None` before the first one.
    state: Option<Phd2State>,
}

impl Phd2Watch {
    pub(super) fn observe_state(&mut self, state: &Phd2State) {
        self.state = Some(state.clone());
    }

    /// Whether PHD2 is calibrating on or guiding a star, so a `StarLost` is a
    /// lost guide star. While PHD2 only loops, a spot that leaves its
    /// candidate box is reported as a lost star too, and that is no loss.
    pub(super) fn holds_guide_star(&self) -> bool {
        matches!(
            self.state,
            Some(
                Phd2State::Calibrating
                    | Phd2State::Guiding
                    | Phd2State::Settling
                    | Phd2State::LostLock
            )
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_star_lost_counts_only_while_phd2_calibrates_or_guides() {
        let mut watch = Phd2Watch::default();
        assert!(!watch.holds_guide_star(), "no state yet");
        for (state, holds) in [
            (Phd2State::Looping, false),
            (Phd2State::Connected, false),
            (Phd2State::Paused, false),
            (Phd2State::Calibrating, true),
            (Phd2State::Guiding, true),
            (Phd2State::Settling, true),
            (Phd2State::LostLock, true),
            (Phd2State::Disconnected, false),
        ] {
            watch.observe_state(&state);
            assert_eq!(watch.holds_guide_star(), holds, "{state:?}");
        }
    }
}
