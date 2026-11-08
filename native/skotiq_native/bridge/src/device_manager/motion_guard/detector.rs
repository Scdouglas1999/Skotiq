//! The pure part of the motion guard: given the mount readings in order and
//! what Skotiq commanded, decide whether the mount moved on its own or lost
//! its position.
//!
//! Times are seconds on one monotonic clock, so the rules can be driven
//! sample by sample in tests and from replayed rig logs.

use std::collections::VecDeque;

use super::ledger::CommandLedger;

/// An axis turning faster than this, in degrees per second, is not tracking
/// or guiding. Sidereal is 0.0042 deg/s and the fastest guide rate is about
/// twice that, so this leaves a margin of more than 50x; the NYX-101
/// runaways ran at about 4.7 deg/s.
pub(crate) const RUNAWAY_DEG_PER_SEC: f64 = 0.5;

/// Slower than this the mount counts as stopped (10x sidereal: tracking and
/// guide pulses stay well under it).
pub(crate) const STOPPED_DEG_PER_SEC: f64 = 0.05;

/// A jump between two readings larger than this, with no command, means the
/// reported position changed under the mount.
pub(crate) const JUMP_DEG: f64 = 5.0;

/// A reading within this many degrees of the pole is at the home pose of a
/// German equatorial (counterweights down, tube on the pole).
pub(crate) const HOME_POLE_DEG: f64 = 1.5;

/// Silence longer than this, in seconds, followed by an answer is treated as
/// the mount (or its link) restarting.
pub(crate) const SILENCE_SECS: f64 = 10.0;

/// Consecutive `Slewing` readings with no slew commanded before it counts.
const SLEWING_READINGS: usize = 3;

/// The slewing readings above must span at least this many seconds.
const SLEWING_SPAN_SECS: f64 = 2.0;

/// How long the mount must read stopped before a motion fault counts as over.
const STOPPED_FOR_SECS: f64 = 5.0;

/// A reading below this altitude, reached quickly and with no command, is a
/// dive below the horizon.
const BELOW_HORIZON_DEG: f64 = 0.0;

/// The fall through the horizon must be at least this many degrees across the
/// readings: tracking a setting target moves far less in a few seconds.
const DIVE_DEG: f64 = 2.0;

/// Readings closer together than this are not used for a rate.
const MIN_INTERVAL_SECS: f64 = 0.3;

/// Sidereal hours that pass per SI second.
const SIDEREAL_HOURS_PER_SEC: f64 = 1.002_737_909_35 / 3600.0;

/// One mount status reading.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct Sample {
    pub t: f64,
    pub ra_hours: f64,
    pub dec_deg: f64,
    pub altitude_deg: Option<f64>,
    pub slewing: bool,
    pub tracking: bool,
    pub parked: bool,
    pub at_home: Option<bool>,
}

/// What the guard knows besides the readings.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct Context {
    /// Position rules apply during a run, and after a motion fault until the
    /// operator has dealt with it. Outside those, an idle mount being homed
    /// or moved from Unity or the hand controller is the operator's business.
    pub watch_position: bool,
    /// Declination of the home pose: +90 in the north, -90 in the south.
    pub home_dec_deg: f64,
}

/// The kinds of uncommanded motion.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum MotionKind {
    Runaway,
    Slewing,
    BelowHorizon,
}

impl MotionKind {
    pub(crate) fn as_wire(self) -> &'static str {
        match self {
            Self::Runaway => "runaway",
            Self::Slewing => "slewing",
            Self::BelowHorizon => "below_horizon",
        }
    }
}

/// Why the mount's position is no longer trusted.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum LostReason {
    /// `AtHome` turned true with no home or park commanded.
    AtHomeWithoutCommand,
    /// The reading jumped to the home pose with no command.
    JumpedToHome { degrees: f64 },
    /// The reading jumped with no command.
    Jumped { degrees: f64 },
    /// The mount went silent and answered again at home.
    CameBackAtHome { silent_secs: f64 },
    /// The mount went silent while it was moving on its own.
    CameBackAfterFault { silent_secs: f64 },
    /// The mount went silent and answered again with tracking off.
    CameBackTrackingReset { silent_secs: f64 },
    /// A plate solve put the mount far from where it says it points.
    SolveDisagrees { degrees: f64 },
}

impl LostReason {
    pub(crate) fn as_wire(&self) -> &'static str {
        match self {
            Self::AtHomeWithoutCommand => "at_home_without_command",
            Self::JumpedToHome { .. } => "jumped_to_home",
            Self::Jumped { .. } => "jumped",
            Self::CameBackAtHome { .. } => "came_back_at_home",
            Self::CameBackAfterFault { .. } => "came_back_after_fault",
            Self::CameBackTrackingReset { .. } => "came_back_tracking_reset",
            Self::SolveDisagrees { .. } => "solve_disagrees",
        }
    }

    pub(crate) fn describe(&self) -> String {
        match self {
            Self::AtHomeWithoutCommand => {
                "The mount reported that it is at home, but nothing told it to go home.".to_string()
            }
            Self::JumpedToHome { degrees } => format!(
                "The mount's reported position jumped {degrees:.0} degrees to its home position \
                 with no command. A mount that restarts assumes it is at home wherever it is."
            ),
            Self::Jumped { degrees } => format!(
                "The mount's reported position jumped {degrees:.0} degrees between two readings \
                 with no command."
            ),
            Self::CameBackAtHome { silent_secs } => format!(
                "The mount stopped answering for {silent_secs:.0} s and came back reporting its \
                 home position. It most likely restarted and now assumes it is at home."
            ),
            Self::CameBackAfterFault { silent_secs } => format!(
                "The mount stopped answering for {silent_secs:.0} s while it was moving on its \
                 own. It most likely restarted, and a restarted mount assumes it is at home."
            ),
            Self::CameBackTrackingReset { silent_secs } => format!(
                "The mount stopped answering for {silent_secs:.0} s and came back with tracking \
                 off. It most likely restarted."
            ),
            Self::SolveDisagrees { degrees } => format!(
                "A plate solve put the telescope {degrees:.1} degrees from where the mount says \
                 it points, far more than normal pointing error."
            ),
        }
    }
}

/// What one reading showed.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Finding {
    /// Motion no command explains started.
    Motion {
        kind: MotionKind,
        rate_deg_per_sec: f64,
    },
    /// A motion fault the detector reported has stopped.
    Stopped,
    /// Uncommanded motion is taking the mount below its altitude limit; the
    /// reason says what the mount reported. Raised by the guard, not here.
    Danger(String),
    PositionLost(LostReason),
}

/// How far ahead, in seconds, a mount dropping toward the altitude limit is
/// projected: one idle reading interval, so a dive is stopped before it gets
/// there rather than a reading after.
pub(crate) const DIVE_LOOKAHEAD_SECS: f64 = 5.0;

/// Falling faster than this, in degrees of altitude per second, is a dive.
/// Tracking a setting target falls at most about 0.004 deg/s.
pub(crate) const DIVE_DEG_PER_SEC: f64 = 0.5;

/// Great-circle separation of two equatorial positions, in degrees.
pub(crate) fn separation_deg(a: (f64, f64), b: (f64, f64)) -> f64 {
    let (ra1, dec1) = ((a.0 * 15.0).to_radians(), a.1.to_radians());
    let (ra2, dec2) = ((b.0 * 15.0).to_radians(), b.1.to_radians());
    let cos = dec1.sin() * dec2.sin() + dec1.cos() * dec2.cos() * (ra1 - ra2).cos();
    cos.clamp(-1.0, 1.0).acos().to_degrees()
}

/// How far the mount's axes turned between two readings, in degrees.
///
/// A tracking mount keeps its RA and a stopped one keeps its hour angle, so
/// the motion is the smaller of the move in RA/Dec and the move in hour
/// angle/Dec. Working from the elapsed time keeps it independent of the site
/// and the clock.
pub(crate) fn axis_motion_deg(a: &Sample, b: &Sample) -> f64 {
    let in_ra = separation_deg((a.ra_hours, a.dec_deg), (b.ra_hours, b.dec_deg));
    let sky_hours = (b.t - a.t) * SIDEREAL_HOURS_PER_SEC;
    let in_hour_angle =
        separation_deg((a.ra_hours + sky_hours, a.dec_deg), (b.ra_hours, b.dec_deg));
    in_ra.min(in_hour_angle)
}

fn rate(a: &Sample, b: &Sample) -> Option<f64> {
    let dt = b.t - a.t;
    (dt >= MIN_INTERVAL_SECS).then(|| axis_motion_deg(a, b) / dt)
}

fn near_home(sample: &Sample, home_dec_deg: f64) -> bool {
    sample.at_home == Some(true) || (sample.dec_deg - home_dec_deg).abs() <= HOME_POLE_DEG
}

#[derive(Debug, Clone, Copy)]
struct Entry {
    sample: Sample,
    /// Whether a command explained motion when this reading was taken.
    expected: bool,
}

/// Per-mount detector state.
#[derive(Debug, Default)]
pub(crate) struct Detector {
    history: VecDeque<Entry>,
    /// The mount is moving on its own and has not yet read stopped.
    fault_moving: bool,
    stopped_since: Option<f64>,
    /// When the mount started failing to answer, and the last good reading.
    silent_since: Option<f64>,
    before_silence: Option<Sample>,
}

impl Detector {
    /// Whether a motion fault this detector reported is still moving.
    pub(crate) fn fault_moving(&self) -> bool {
        self.fault_moving
    }

    /// The latest good reading.
    pub(crate) fn last(&self) -> Option<Sample> {
        self.history.back().map(|e| e.sample)
    }

    /// Why the motion is a danger to the rig, or `None`: the mount reports
    /// pointing below `min_altitude_deg`, or its altitude is falling fast
    /// enough to get there within [`DIVE_LOOKAHEAD_SECS`]. Anything else
    /// moving the mount (a user in the mount's own software or at the hand
    /// controller) is not Skotiq's to stop.
    pub(crate) fn danger(&self, min_altitude_deg: f64) -> Option<String> {
        let n = self.history.len();
        let last = self.history.back()?.sample;
        let altitude = last.altitude_deg?;
        if altitude < min_altitude_deg {
            return Some(format!(
                "It reports altitude {altitude:+.1}, below the {min_altitude_deg:.0} degree limit."
            ));
        }
        if n < 2 {
            return None;
        }
        let prev = self.history[n - 2].sample;
        let dt = last.t - prev.t;
        let previous_altitude = prev.altitude_deg?;
        if dt < MIN_INTERVAL_SECS {
            return None;
        }
        let falling = (previous_altitude - altitude) / dt;
        if falling > DIVE_DEG_PER_SEC && altitude - min_altitude_deg < falling * DIVE_LOOKAHEAD_SECS
        {
            return Some(format!(
                "It is dropping {falling:.1} degrees a second at altitude {altitude:+.1} and will \
                 be below the {min_altitude_deg:.0} degree limit in a few seconds."
            ));
        }
        None
    }

    /// The fastest rate across the last two readings, if there are two.
    pub(crate) fn latest_rate(&self) -> Option<f64> {
        let n = self.history.len();
        if n < 2 {
            return None;
        }
        rate(&self.history[n - 2].sample, &self.history[n - 1].sample)
    }

    /// The mount did not answer at `t`.
    pub(crate) fn observe_failure(&mut self, t: f64) {
        if self.silent_since.is_none() {
            self.silent_since = Some(t);
            self.before_silence = self.last();
        }
    }

    /// Forget the motion fault, for when the operator acknowledges it.
    pub(crate) fn clear_fault(&mut self) {
        self.fault_moving = false;
        self.stopped_since = None;
    }

    /// The mount answered with `sample`.
    pub(crate) fn observe(
        &mut self,
        sample: Sample,
        ledger: &mut CommandLedger,
        ctx: Context,
        fault_recorded: bool,
    ) -> Vec<Finding> {
        let mut findings = Vec::new();

        // A reading that does not move forward in time is a duplicate (two
        // callers read status at once); it adds nothing.
        if self.last().is_some_and(|last| sample.t - last.t < 0.05) {
            return findings;
        }

        if let Some(since) = self.silent_since.take() {
            let silent_secs = sample.t - since;
            let before = self.before_silence.take();
            // Rates across a gap are meaningless.
            self.history.clear();
            // Only a fault the guard recorded counts: motion it noticed and
            // left alone (someone moving an idle mount) is not a fault.
            let after_fault = fault_recorded;
            // While the mount is moving on its own, any silence that ends at
            // home is the controller restarting, however short.
            let restarted_at_home = after_fault
                && silent_secs >= 1.0
                && near_home(&sample, ctx.home_dec_deg)
                && !before.is_some_and(|b| near_home(&b, ctx.home_dec_deg));
            if (silent_secs >= SILENCE_SECS && ctx.watch_position) || restarted_at_home {
                let was_home = before.is_some_and(|b| near_home(&b, ctx.home_dec_deg));
                let reason = if after_fault {
                    Some(LostReason::CameBackAfterFault { silent_secs })
                } else if near_home(&sample, ctx.home_dec_deg)
                    && !was_home
                    && !ledger.home_or_park_recent(sample.t)
                {
                    Some(LostReason::CameBackAtHome { silent_secs })
                } else if before.is_some_and(|b| b.tracking) && !sample.tracking && !sample.parked {
                    Some(LostReason::CameBackTrackingReset { silent_secs })
                } else {
                    None
                };
                if let Some(reason) = reason {
                    findings.push(Finding::PositionLost(reason));
                }
                // The restart ended whatever motion was under way.
                self.fault_moving = false;
                self.stopped_since = None;
            }
        }

        let moving_now = sample.slewing
            || self
                .last()
                .and_then(|last| rate(&last, &sample))
                .is_some_and(|r| r > STOPPED_DEG_PER_SEC);
        ledger.observe(sample.t, moving_now);
        let expected = ledger.expects_motion(sample.t);
        let previous = self.last();
        self.history.push_back(Entry { sample, expected });
        while self.history.len() > 4 {
            self.history.pop_front();
        }

        // AtHome turning on by itself.
        if ctx.watch_position
            && previous.is_some_and(|p| p.at_home == Some(false))
            && sample.at_home == Some(true)
            && !expected
            && !ledger.home_or_park_recent(sample.t)
        {
            findings.push(Finding::PositionLost(LostReason::AtHomeWithoutCommand));
        }

        // The reading jumped and stayed. During a motion fault only a jump to
        // the home pose counts: a mount restarting mid-run assumes it is at
        // home, while a fast move that simply stopped between two readings is
        // the fault ending.
        let n = self.history.len();
        if n >= 3 && (ctx.watch_position || fault_recorded) {
            let (e0, e1, e2) = (
                self.history[n - 3],
                self.history[n - 2],
                self.history[n - 1],
            );
            let before_jump = (n >= 4).then(|| self.history[n - 4].sample);
            if !e0.expected && !e1.expected && !e2.expected && !ledger.sync_recent(e1.sample.t) {
                match jump_rule(before_jump, e0.sample, e1.sample, e2.sample, ctx) {
                    Some(reason @ LostReason::JumpedToHome { .. }) => {
                        findings.push(Finding::PositionLost(reason));
                    }
                    Some(reason) if !self.fault_moving && ctx.watch_position => {
                        findings.push(Finding::PositionLost(reason));
                    }
                    _ => {}
                }
            }
        }

        if self.fault_moving {
            if moving_now {
                self.stopped_since = None;
            } else {
                let since = *self.stopped_since.get_or_insert(sample.t);
                if sample.t - since >= STOPPED_FOR_SECS {
                    self.fault_moving = false;
                    self.stopped_since = None;
                    findings.push(Finding::Stopped);
                }
            }
            return findings;
        }

        if n >= 3 {
            let (e0, e1, e2) = (
                self.history[n - 3],
                self.history[n - 2],
                self.history[n - 1],
            );
            let unexplained = !e0.expected && !e1.expected && !e2.expected;
            if unexplained {
                if let Some(finding) = self.motion_rule(e0.sample, e1.sample, e2.sample) {
                    self.fault_moving = true;
                    self.stopped_since = None;
                    findings.push(finding);
                    return findings;
                }
            }
        }

        if let Some(finding) = self.slewing_rule() {
            self.fault_moving = true;
            self.stopped_since = None;
            findings.push(finding);
        }
        findings
    }

    /// The axis-rate and horizon rules over three readings.
    fn motion_rule(&self, s0: Sample, s1: Sample, s2: Sample) -> Option<Finding> {
        let (r01, r12) = (rate(&s0, &s1)?, rate(&s1, &s2)?);
        // A single bad reading shows as a fast move out and a fast move back;
        // the motion from first to last reading tells them apart.
        let net = axis_motion_deg(&s0, &s2) / (s2.t - s0.t);
        if r01 > RUNAWAY_DEG_PER_SEC && r12 > RUNAWAY_DEG_PER_SEC && net > RUNAWAY_DEG_PER_SEC / 2.0
        {
            return Some(Finding::Motion {
                kind: MotionKind::Runaway,
                rate_deg_per_sec: r01.max(r12),
            });
        }
        if let (Some(a0), Some(a1), Some(a2)) = (s0.altitude_deg, s1.altitude_deg, s2.altitude_deg)
        {
            if a0 >= BELOW_HORIZON_DEG
                && a1 < BELOW_HORIZON_DEG
                && a2 < BELOW_HORIZON_DEG
                && a0 - a2 > DIVE_DEG
            {
                return Some(Finding::Motion {
                    kind: MotionKind::BelowHorizon,
                    rate_deg_per_sec: net,
                });
            }
        }
        None
    }

    /// `Slewing` on several readings in a row with no slew commanded.
    fn slewing_rule(&self) -> Option<Finding> {
        let n = self.history.len();
        if n < SLEWING_READINGS {
            return None;
        }
        let recent: Vec<&Entry> = self.history.iter().skip(n - SLEWING_READINGS).collect();
        let all = recent.iter().all(|e| e.sample.slewing && !e.expected);
        let span = recent[SLEWING_READINGS - 1].sample.t - recent[0].sample.t;
        (all && span >= SLEWING_SPAN_SECS).then(|| Finding::Motion {
            kind: MotionKind::Slewing,
            rate_deg_per_sec: self.latest_rate().unwrap_or(0.0),
        })
    }
}

/// A jump from `s0` to `s1` that `s2` confirms (the mount stays at the new
/// reading), so it is not a single bad read. A reading that lands back where
/// the mount was before `s0` is the end of a bad read at `s0`, not a jump.
fn jump_rule(
    before: Option<Sample>,
    s0: Sample,
    s1: Sample,
    s2: Sample,
    ctx: Context,
) -> Option<LostReason> {
    if before.is_some_and(|b| axis_motion_deg(&b, &s2) < 1.0) {
        return None;
    }
    let jump = axis_motion_deg(&s0, &s1);
    if jump < JUMP_DEG || rate(&s0, &s1)? < RUNAWAY_DEG_PER_SEC {
        return None;
    }
    if rate(&s1, &s2)? > STOPPED_DEG_PER_SEC {
        return None;
    }
    let degrees = jump.round();
    Some(
        if near_home(&s1, ctx.home_dec_deg) && !near_home(&s0, ctx.home_dec_deg) {
            LostReason::JumpedToHome { degrees }
        } else {
            LostReason::Jumped { degrees }
        },
    )
}
