//! PHD2's event stream read as a whole rather than one event at a time:
//! whether PHD2 holds a guide star, so a lost star counts only then, and
//! whether its guide pulses reach the mount.

use skotiq_phd2::{GuideFrame, Phd2State};

/// A guide step whose RA error is at least this many pixels and that sends no
/// pulse on either axis is a correction PHD2 did not make. Far above any
/// minimum move, so guiding that holds the star inside its minimum move
/// (no pulse, small error) never counts.
const UNANSWERED_ERROR_PX: f64 = 2.0;

/// How long, and over how many such steps, before the operator is told: long
/// enough that a resist-switch hold or a single odd frame never reaches it.
const UNANSWERED_FOR_SECS: f64 = 60.0;
const UNANSWERED_STEPS: u32 = 10;

#[derive(Debug, Default)]
pub(super) struct Phd2Watch {
    /// PHD2's state as its events last said, `None` before the first one.
    state: Option<Phd2State>,
    /// The current run of guide steps that sent no pulse at a large error.
    unanswered: Option<Unanswered>,
    /// The operator has heard about the current run.
    told: bool,
}

#[derive(Debug)]
struct Unanswered {
    /// PHD2 time of the first step of the run, in seconds.
    since: f64,
    steps: u32,
}

impl Phd2Watch {
    pub(super) fn observe_state(&mut self, state: &Phd2State) {
        self.state = Some(state.clone());
        if !matches!(
            state,
            Phd2State::Guiding | Phd2State::Settling | Phd2State::LostLock
        ) {
            self.unanswered = None;
            self.told = false;
        }
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

    /// Take one guide step at PHD2 time `at_secs`. Returns the notice for the
    /// operator when this step completes a sustained run of large errors that
    /// PHD2 answered with no pulse: once per run, which ends at the first step
    /// that sends a pulse or when guiding stops.
    pub(super) fn observe_step(&mut self, step: &GuideFrame, at_secs: f64) -> Option<String> {
        if step.ra_duration > 0 || step.dec_duration > 0 {
            self.unanswered = None;
            self.told = false;
            return None;
        }
        if step.ra_distance.abs() < UNANSWERED_ERROR_PX {
            return None;
        }
        let run = self.unanswered.get_or_insert(Unanswered {
            since: at_secs,
            steps: 0,
        });
        run.steps += 1;
        let lasted = at_secs - run.since;
        if self.told || run.steps < UNANSWERED_STEPS || lasted < UNANSWERED_FOR_SECS {
            return None;
        }
        self.told = true;
        Some(format!(
            "PHD2 has sent no guide pulse for {} min although the guide star is {:.0} px off \
             its lock position ({} guide steps in a row): its corrections are not reaching the \
             mount. Disconnecting and reconnecting the mount in PHD2's Connect Equipment dialog \
             usually restores guiding.",
            ((lasted / 60.0).round() as u32).max(1),
            step.ra_distance.abs(),
            run.steps,
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn step(ra_px: f64, ra_ms: i32, dec_ms: i32) -> GuideFrame {
        GuideFrame {
            frame: 0,
            timestamp: 0.0,
            ra_distance: ra_px,
            dec_distance: 0.4,
            ra_duration: ra_ms,
            dec_duration: dec_ms,
            ra_direction: String::new(),
            dec_direction: String::new(),
            snr: 150.0,
            star_mass: 240_000.0,
            star_x: 0.0,
            star_y: 0.0,
            avg_dist: 0.0,
        }
    }

    fn guiding() -> Phd2Watch {
        let mut watch = Phd2Watch::default();
        watch.observe_state(&Phd2State::Guiding);
        watch
    }

    /// Steps `count` steps of `ra_px` with no pulse, `every` seconds apart
    /// from `from`; the notices they raised.
    fn unanswered(watch: &mut Phd2Watch, from: f64, every: f64, count: u32) -> Vec<String> {
        (0..count)
            .filter_map(|i| watch.observe_step(&step(12.0, 0, 0), from + every * f64::from(i)))
            .collect()
    }

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

    #[test]
    fn a_short_run_of_unanswered_steps_is_not_reported() {
        let mut watch = guiding();
        assert!(
            unanswered(&mut watch, 0.0, 4.5, 13).is_empty(),
            "13 steps over 54 s"
        );
        let mut watch = guiding();
        assert!(
            unanswered(&mut watch, 0.0, 10.0, 9).is_empty(),
            "9 steps over 80 s"
        );
    }

    #[test]
    fn a_sustained_run_is_reported_once_until_a_pulse_goes_out() {
        let mut watch = guiding();
        let notices = unanswered(&mut watch, 0.0, 4.5, 40);
        assert_eq!(notices.len(), 1, "{notices:?}");
        assert!(notices[0].contains("for 1 min"), "{}", notices[0]);

        assert!(watch.observe_step(&step(12.0, 300, 0), 200.0).is_none());
        assert_eq!(
            unanswered(&mut watch, 300.0, 4.5, 40).len(),
            1,
            "a new run is a new episode"
        );
    }

    #[test]
    fn steps_inside_the_minimum_move_neither_count_nor_end_a_run() {
        let mut watch = guiding();
        let mut notices = Vec::new();
        for i in 0..30 {
            let at = 4.5 * f64::from(i);
            let ra = if i % 2 == 0 { 12.0 } else { 0.1 };
            notices.extend(watch.observe_step(&step(ra, 0, 0), at));
        }
        assert_eq!(notices.len(), 1, "15 unanswered steps over 126 s");
    }

    #[test]
    fn guiding_that_stops_ends_the_run() {
        let mut watch = guiding();
        assert!(unanswered(&mut watch, 0.0, 4.5, 12).is_empty());
        watch.observe_state(&Phd2State::Looping);
        watch.observe_state(&Phd2State::Guiding);
        assert!(
            unanswered(&mut watch, 60.0, 4.5, 12).is_empty(),
            "the run started again"
        );
    }
}
