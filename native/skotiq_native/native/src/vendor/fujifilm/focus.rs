//! How the focus position of an electronic Fujifilm lens becomes focuser
//! positions, and when a lens move counts as finished. Pure rules, so they are
//! tested on every platform; the SDK calls are in `lens.rs` (Windows only).
//!
//! The rules follow the owner's NINA plugin (3.1.x), measured on a GFX100S II:
//! the usable travel includes the over-search margins beyond both marks, a
//! position is never negative, and a move is over when the lens reaches its
//! target or stops moving, because some lenses come to rest a fixed 29-38
//! pulses from the target they were given.

use std::time::{Duration, Instant};

/// What `CapFocusPos` reports (`SDK_FOCUS_POS_CAP`, XAPIOpt.h; SDK
/// Programming Reference 4.2.1.37), in focus pulses. The axis runs
/// `INF - over-search | INF ... MOD | MOD + over-search`: both marks lie inside
/// the travel, and astronomical focus often sits past the infinity mark.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(crate) struct FocusCapability {
    pub(crate) infinity: i32,
    pub(crate) closest: i32,
    pub(crate) over_search_infinity: i32,
    pub(crate) over_search_closest: i32,
    /// Depth of field in pulses; zero when the lens has no Set/GetFocusPos.
    pub(crate) depth_of_field: i32,
    pub(crate) min_drive_step: i32,
}

/// The lens travel as focuser positions: 0 is the infinity-side hard stop,
/// [`range`](Self::range) the close-focus one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct FocusTravel {
    lowest_pulse: i32,
    range: i32,
    infinity_pulse: i32,
    past_infinity: i32,
    step: i32,
}

impl FocusTravel {
    /// `None` when the lens reports no focus control: a zero depth of field
    /// marks the structure invalid (XAPIOpt.h), and a lens with neither mark
    /// set has no range to drive.
    pub(crate) fn from_capability(cap: FocusCapability) -> Option<Self> {
        if cap.depth_of_field == 0 || (cap.infinity == 0 && cap.closest == 0) {
            return None;
        }
        // The SDK reports the over-search margins as distances, and on every
        // lens measured pulses rise from infinity to close focus; the order is
        // not documented, so the lower mark anchors the travel.
        let over_infinity = cap.over_search_infinity.abs();
        let over_closest = cap.over_search_closest.abs();
        let (lowest, highest) = if cap.infinity <= cap.closest {
            (cap.infinity - over_infinity, cap.closest + over_closest)
        } else {
            (cap.closest - over_closest, cap.infinity + over_infinity)
        };
        Some(Self {
            lowest_pulse: lowest,
            range: highest - lowest,
            infinity_pulse: cap.infinity,
            past_infinity: over_infinity,
            step: cap.min_drive_step.max(1),
        })
    }

    /// The largest focuser position.
    pub(crate) fn range(&self) -> i32 {
        self.range
    }

    /// The focuser position of the lens' infinity mark.
    pub(crate) fn infinity_position(&self) -> i32 {
        self.infinity_pulse - self.lowest_pulse
    }

    /// Travel beyond the infinity mark, in focuser steps.
    pub(crate) fn past_infinity(&self) -> i32 {
        self.past_infinity
    }

    /// The smallest move the lens makes (`lMinDriveStepMFDriveEndThresh`).
    /// Requests are not rounded to it: the lens goes as close as it can, and
    /// rounding made most positions unreachable in the NINA plugin (3.1.1).
    pub(crate) fn step(&self) -> i32 {
        self.step
    }

    /// The focuser position of a pulse reading, kept inside the travel: the
    /// SDK says the pulse count drifts with temperature, so a reading can lie
    /// just outside the range the lens reported.
    pub(crate) fn position(&self, pulse: i32) -> i32 {
        (pulse - self.lowest_pulse).clamp(0, self.range)
    }

    /// The pulse to send for a focuser position.
    pub(crate) fn pulse(&self, position: i32) -> Result<i32, String> {
        if !(0..=self.range).contains(&position) {
            return Err(format!(
                "Lens focus position {position} is outside the lens travel 0 to {} \
                 (infinity is at {})",
                self.range,
                self.infinity_position()
            ));
        }
        Ok(self.lowest_pulse + position)
    }
}

/// How long the reading must stay put before a lens that has not reached
/// its target counts as stopped. The NINA plugin uses four 50 ms samples; the
/// sequencer polls every 100 ms, so the window is in time, not samples.
const SETTLE_WINDOW: Duration = Duration::from_millis(300);

/// A move is not judged stopped before this: the lens may not have started
/// when the first readings come in. A measured full move took about 550 ms.
const SHORTEST_MOVE: Duration = Duration::from_millis(500);

/// How a lens move ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum MoveEnd {
    /// The reading is within one drive step of the target.
    Arrived,
    /// The lens stopped this many pulses from the target.
    Settled { residual: i32 },
    /// The reading never left the starting point.
    DidNotMove,
}

/// One lens move in progress.
#[derive(Debug, Clone, Copy)]
struct FocusMove {
    position: i32,
    target_pulse: i32,
    start_pulse: i32,
    started: Instant,
    /// The last distinct reading and when it first appeared.
    reading: Option<(i32, Instant)>,
}

/// What the lens focuser knows between SDK calls: its travel, the move in
/// progress, and the position it last arrived at.
#[derive(Debug, Clone)]
pub(crate) struct LensFocus {
    travel: FocusTravel,
    moving: Option<FocusMove>,
    /// The position a finished move was given and the pulse the lens settled
    /// at. Reported instead of the reading while the lens stays there, because
    /// a lens that rests a few pulses off its target would otherwise never
    /// report the position it was sent to.
    held: Option<(i32, i32)>,
}

impl LensFocus {
    pub(crate) fn new(travel: FocusTravel) -> Self {
        Self {
            travel,
            moving: None,
            held: None,
        }
    }

    pub(crate) fn travel(&self) -> &FocusTravel {
        &self.travel
    }

    pub(crate) fn is_moving(&self) -> bool {
        self.moving.is_some()
    }

    /// Start a move to `position` from the pulse the lens reads now. Returns
    /// the pulse to send.
    pub(crate) fn start_move(
        &mut self,
        position: i32,
        current_pulse: i32,
        now: Instant,
    ) -> Result<i32, String> {
        let target_pulse = self.travel.pulse(position)?;
        self.held = None;
        self.moving = Some(FocusMove {
            position,
            target_pulse,
            start_pulse: current_pulse,
            started: now,
            reading: None,
        });
        Ok(target_pulse)
    }

    /// Forget a move the lens refused.
    pub(crate) fn abandon_move(&mut self) {
        self.moving = None;
    }

    /// Take a reading while a move is in progress. `Some` once the move is
    /// over; the lens then reports the position it was sent to, unless it
    /// never moved.
    pub(crate) fn observe(&mut self, pulse: i32, now: Instant) -> Option<MoveEnd> {
        let tolerance = self.travel.step;
        let motion = self.moving.as_mut()?;
        let end = if (pulse - motion.target_pulse).abs() <= tolerance {
            Some(MoveEnd::Arrived)
        } else {
            let since = match motion.reading {
                Some((last, since)) if (pulse - last).abs() <= tolerance => since,
                _ => {
                    motion.reading = Some((pulse, now));
                    now
                }
            };
            let stopped = now.duration_since(since) >= SETTLE_WINDOW
                && now.duration_since(motion.started) >= SHORTEST_MOVE;
            if !stopped {
                None
            } else if (pulse - motion.start_pulse).abs() <= tolerance {
                Some(MoveEnd::DidNotMove)
            } else {
                Some(MoveEnd::Settled {
                    residual: pulse - motion.target_pulse,
                })
            }
        };
        if let Some(end) = end {
            let position = motion.position;
            self.moving = None;
            self.held = (end != MoveEnd::DidNotMove).then_some((position, pulse));
        }
        end
    }

    /// The focuser position for a reading taken now.
    pub(crate) fn position(&mut self, pulse: i32) -> i32 {
        match self.held {
            Some((position, settled)) if (pulse - settled).abs() <= self.travel.step => position,
            _ => {
                self.held = None;
                self.travel.position(pulse)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The shape of a GFX100S II lens in the NINA plugin's notes: pulses rise
    /// from infinity to close focus, with travel past both marks.
    fn cap() -> FocusCapability {
        FocusCapability {
            infinity: 100,
            closest: 900,
            over_search_infinity: 40,
            over_search_closest: 20,
            depth_of_field: 5,
            min_drive_step: 3,
        }
    }

    fn travel() -> FocusTravel {
        FocusTravel::from_capability(cap()).unwrap()
    }

    #[test]
    fn the_travel_reaches_past_both_marks_and_starts_at_zero() {
        let t = travel();
        assert_eq!(t.range(), 860);
        assert_eq!(t.infinity_position(), 40);
        assert_eq!(t.past_infinity(), 40);
        assert_eq!(t.pulse(0), Ok(60));
        assert_eq!(t.pulse(860), Ok(920));
        assert_eq!(t.position(60), 0);
    }

    #[test]
    fn a_lens_without_focus_control_has_no_travel() {
        let no_depth = FocusCapability {
            depth_of_field: 0,
            ..cap()
        };
        assert_eq!(FocusTravel::from_capability(no_depth), None);
        let no_marks = FocusCapability {
            infinity: 0,
            closest: 0,
            ..cap()
        };
        assert_eq!(FocusTravel::from_capability(no_marks), None);
    }

    #[test]
    fn a_lens_whose_pulses_fall_toward_close_focus_still_starts_at_zero() {
        let t = FocusTravel::from_capability(FocusCapability {
            infinity: 900,
            closest: 100,
            ..cap()
        })
        .unwrap();
        assert_eq!(t.range(), 860);
        assert_eq!(t.pulse(0), Ok(80));
        assert_eq!(t.infinity_position(), 820);
    }

    #[test]
    fn negative_over_search_counts_as_a_distance() {
        let t = FocusTravel::from_capability(FocusCapability {
            over_search_infinity: -40,
            over_search_closest: -20,
            ..cap()
        })
        .unwrap();
        assert_eq!(t, travel());
    }

    #[test]
    fn a_reading_outside_the_travel_is_never_a_negative_position() {
        let t = travel();
        assert_eq!(t.position(10), 0);
        assert_eq!(t.position(5000), 860);
    }

    #[test]
    fn a_position_outside_the_travel_is_refused_and_any_inside_is_sent_unrounded() {
        let t = travel();
        assert!(t.pulse(-1).unwrap_err().contains("0 to 860"));
        assert!(t.pulse(861).is_err());
        assert_eq!(t.pulse(401), Ok(461));
    }

    #[test]
    fn a_zero_drive_step_counts_as_one() {
        let t = FocusTravel::from_capability(FocusCapability {
            min_drive_step: 0,
            ..cap()
        })
        .unwrap();
        assert_eq!(t.step(), 1);
    }

    fn ms(start: Instant, millis: u64) -> Instant {
        start + Duration::from_millis(millis)
    }

    #[test]
    fn a_move_that_reaches_its_target_ends_at_once() {
        let t0 = Instant::now();
        let mut focus = LensFocus::new(travel());
        assert_eq!(focus.start_move(400, 160, t0), Ok(460));
        assert!(focus.is_moving());
        assert_eq!(focus.observe(300, ms(t0, 100)), None);
        assert_eq!(focus.observe(459, ms(t0, 200)), Some(MoveEnd::Arrived));
        assert!(!focus.is_moving());
        assert_eq!(focus.position(459), 400);
    }

    #[test]
    fn a_lens_that_rests_off_target_reports_the_position_it_was_sent_to() {
        let t0 = Instant::now();
        let mut focus = LensFocus::new(travel());
        focus.start_move(400, 160, t0).unwrap();
        // A GFX100S II lens comes to rest about 30 pulses short.
        for (at, reading) in [(100, 300), (200, 350), (300, 430), (400, 428), (500, 430)] {
            assert_eq!(focus.observe(reading, ms(t0, at)), None, "at {at} ms");
        }
        assert_eq!(
            focus.observe(430, ms(t0, 600)),
            Some(MoveEnd::Settled { residual: -30 })
        );
        assert_eq!(focus.position(431), 400);
    }

    #[test]
    fn a_settled_position_is_given_up_once_the_lens_is_moved_by_hand() {
        let t0 = Instant::now();
        let mut focus = LensFocus::new(travel());
        focus.start_move(400, 160, t0).unwrap();
        focus.observe(459, ms(t0, 100));
        assert_eq!(focus.position(520), 460);
        assert_eq!(focus.position(459), 399);
    }

    #[test]
    fn a_lens_that_never_leaves_its_start_reports_where_it_is() {
        let t0 = Instant::now();
        let mut focus = LensFocus::new(travel());
        focus.start_move(400, 160, t0).unwrap();
        for at in [100, 200, 300, 400] {
            assert_eq!(focus.observe(160, ms(t0, at)), None, "at {at} ms");
        }
        assert_eq!(focus.observe(161, ms(t0, 500)), Some(MoveEnd::DidNotMove));
        assert_eq!(focus.position(160), 100);
    }

    #[test]
    fn readings_that_have_not_stayed_put_long_enough_keep_the_move_running() {
        let t0 = Instant::now();
        let mut focus = LensFocus::new(travel());
        focus.start_move(400, 160, t0).unwrap();
        assert_eq!(focus.observe(300, ms(t0, 600)), None);
        assert_eq!(focus.observe(301, ms(t0, 800)), None);
        assert_eq!(
            focus.observe(300, ms(t0, 900)),
            Some(MoveEnd::Settled { residual: -160 })
        );
    }

    #[test]
    fn no_reading_ends_a_move_that_was_never_started() {
        let mut focus = LensFocus::new(travel());
        assert_eq!(focus.observe(300, Instant::now()), None);
        assert_eq!(focus.position(300), 240);
    }

    #[test]
    fn a_refused_position_starts_no_move() {
        let mut focus = LensFocus::new(travel());
        assert!(focus.start_move(900, 160, Instant::now()).is_err());
        assert!(!focus.is_moving());
    }

    #[test]
    fn an_abandoned_move_reports_where_the_lens_is() {
        let t0 = Instant::now();
        let mut focus = LensFocus::new(travel());
        focus.start_move(400, 160, t0).unwrap();
        focus.abandon_move();
        assert!(!focus.is_moving());
        assert_eq!(focus.observe(160, ms(t0, 900)), None);
        assert_eq!(focus.position(160), 100);
    }
}
