//! Exposure rules for DSLR and mirrorless bodies, shared by the drivers that
//! run them (the Fujifilm X SDK and gPhoto2): how a requested exposure is
//! made with a body's timed shutter speeds or bulb, and which listed ISO a
//! gain selects (gain is ISO on these bodies). Each driver hands in its
//! body's speeds in its own codes and the rules it follows where the two
//! drivers differ ([`PlanRules`]).

/// A timed speed this close to the request, as a fraction of it, is the
/// request.
pub(crate) const SAME_DURATION: f64 = 0.01;

/// Bulb is timed by the host, which cannot hold a sub-second release
/// reliably, so a shorter request is made with a timed speed.
pub(crate) const SHORTEST_BULB_SECONDS: f64 = 1.0;

/// One timed shutter speed a body lists, in the driver's own terms.
pub(crate) trait TimedSpeed {
    /// How long the shutter is open.
    fn seconds(&self) -> f64;
}

/// How one of several listed speeds is picked for a request.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Pick {
    /// The smallest difference in seconds; a tie goes to the shorter.
    Difference,
    /// The smallest ratio (shutter steps are multiplicative); a tie goes to
    /// the shorter.
    Ratio,
    /// The shortest speed that qualifies.
    Shortest,
}

/// The rules a driver follows where the drivers' plans differ.
#[derive(Debug, Clone, Copy)]
pub(crate) struct PlanRules<'a, C> {
    /// The body can hold its shutter open for a bulb exposure.
    pub(crate) can_bulb: bool,
    /// With bulb available, a timed speed is used only up to this long;
    /// `None` at any length.
    pub(crate) timed_up_to: Option<f64>,
    /// How a listed speed the same as the request is picked.
    pub(crate) same: Pick,
    /// Speeds a body shows as another number than their own time (the X
    /// SDK's 16 s code is the dial's 15 s), as `(is that speed, shown)`.
    pub(crate) shown: &'a [(C, f64)],
    /// A body that lists no timed speed takes a sub-second request as bulb.
    pub(crate) bulb_without_speeds: bool,
    /// How a request that is no listed speed and too short for bulb picks
    /// the speed it is made with.
    pub(crate) fallback: Pick,
}

/// How an exposure is made.
#[derive(Debug, PartialEq)]
pub(crate) enum Plan<'a, S> {
    /// One of the body's timed speeds; the frame lasts that speed.
    Timed(&'a S),
    /// The shutter held open for the request.
    Bulb,
}

/// Why an exposure cannot be made.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) enum Unplannable {
    /// The body lists no timed speed and the request cannot be bulb.
    NoSpeeds,
    /// The body has no bulb and the request is longer than its longest
    /// timed speed, `longest` seconds.
    LongerThanLongest { longest: f64 },
}

/// The speed `pick` takes for `seconds` out of `speeds` (shortest first).
pub(crate) fn pick<'a, S: TimedSpeed>(
    speeds: impl IntoIterator<Item = &'a S>,
    seconds: f64,
    pick: Pick,
) -> Option<&'a S> {
    let mut speeds = speeds.into_iter();
    match pick {
        Pick::Difference => speeds.min_by(|a, b| {
            (a.seconds() - seconds)
                .abs()
                .total_cmp(&(b.seconds() - seconds).abs())
                .then(a.seconds().total_cmp(&b.seconds()))
        }),
        Pick::Ratio => speeds.min_by(|a, b| {
            (a.seconds() / seconds)
                .ln()
                .abs()
                .total_cmp(&(b.seconds() / seconds).ln().abs())
                .then(a.seconds().total_cmp(&b.seconds()))
        }),
        Pick::Shortest => speeds.next(),
    }
}

/// Whether `speed` lasts as long as `seconds`.
fn same_duration(speed: f64, seconds: f64) -> bool {
    (speed - seconds).abs() <= seconds * SAME_DURATION
}

/// The way to make an exposure of `seconds` (finite and positive) with the
/// timed `speeds` a body lists, shortest first:
///
/// 1. a listed speed of the same duration, unless bulb is available and the
///    request is longer than [`PlanRules::timed_up_to`];
/// 2. a speed the body shows as the request ([`PlanRules::shown`]);
/// 3. bulb for exactly the request, when the body can and the request is a
///    second or more (or the body lists no speed and
///    [`PlanRules::bulb_without_speeds`]);
/// 4. else the [`PlanRules::fallback`] speed; the frame records that speed.
pub(crate) fn plan<'a, S, C>(
    speeds: &'a [S],
    seconds: f64,
    rules: &PlanRules<'_, C>,
    is: impl Fn(&S, &C) -> bool,
) -> Result<Plan<'a, S>, Unplannable>
where
    S: TimedSpeed,
{
    let bulb_instead = rules.can_bulb
        && rules
            .timed_up_to
            .is_some_and(|longest| seconds > longest * (1.0 + SAME_DURATION));
    let same = pick(
        speeds
            .iter()
            .filter(|speed| same_duration(speed.seconds(), seconds)),
        seconds,
        rules.same,
    );
    if let Some(same) = same.filter(|_| !bulb_instead) {
        return Ok(Plan::Timed(same));
    }
    let shown = rules
        .shown
        .iter()
        .find(|(_, shown)| same_duration(*shown, seconds))
        .and_then(|(code, _)| speeds.iter().find(|speed| is(speed, code)));
    if let Some(shown) = shown {
        return Ok(Plan::Timed(shown));
    }
    if rules.can_bulb
        && (seconds >= SHORTEST_BULB_SECONDS || (rules.bulb_without_speeds && speeds.is_empty()))
    {
        return Ok(Plan::Bulb);
    }
    let fallback = pick(speeds, seconds, rules.fallback).ok_or(Unplannable::NoSpeeds)?;
    if let Some(longest) = speeds
        .last()
        .map(TimedSpeed::seconds)
        .filter(|longest| seconds > longest * (1.0 + SAME_DURATION))
    {
        if !rules.can_bulb {
            return Err(Unplannable::LongerThanLongest { longest });
        }
    }
    Ok(Plan::Timed(fallback))
}

/// The listed ISO speed nearest to `requested` by ratio, as ISO steps go
/// (`speeds` lowest first; a tie goes to the lower speed; a request below 1
/// counts as 1), or `None` when none is listed.
pub(crate) fn nearest_iso<T>(
    speeds: &[T],
    speed_of: impl Fn(&T) -> i32,
    requested: i32,
) -> Option<&T> {
    let requested = f64::from(requested.max(1));
    let distance = |speed: &T| (f64::from(speed_of(speed)) / requested).ln().abs();
    speeds
        .iter()
        .min_by(|a, b| distance(a).total_cmp(&distance(b)))
}

#[cfg(test)]
mod tests {
    use super::*;

    impl TimedSpeed for f64 {
        fn seconds(&self) -> f64 {
            *self
        }
    }

    const FULL_STOPS: [i32; 6] = [100, 200, 400, 800, 1600, 3200];

    /// Between two full stops 1200 is nearer 1600 by ratio.
    #[test]
    fn a_gain_between_two_iso_steps_takes_the_nearer_by_ratio() {
        assert_eq!(*nearest_iso(&FULL_STOPS, |s| *s, 1200).unwrap(), 1600);
        assert_eq!(*nearest_iso(&FULL_STOPS, |s| *s, 1131).unwrap(), 800);
        assert_eq!(nearest_iso(&[] as &[i32], |s| *s, 800), None);
    }

    #[test]
    fn a_tie_goes_to_the_shorter_speed() {
        let speeds = [2.0, 4.0];
        assert_eq!(pick(&speeds, 3.0, Pick::Difference), Some(&2.0));
        assert_eq!(pick(&speeds, 3.0, Pick::Shortest), Some(&2.0));
    }
}
