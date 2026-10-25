//! What a guide-star recovery that keeps failing has seen, kept for the run
//! and for the obstruction check.

/// One failed guide-star recovery attempt.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct GuideRecoveryFailure {
    /// When the attempt failed, Unix seconds.
    pub at_unix: i64,
    /// Altitude and azimuth the mount pointed at, degrees. `None` when the
    /// mount position or the site was not known.
    pub alt_az_deg: Option<(f64, f64)>,
}

/// A guide-star recovery that has failed at least once and not yet ended
/// with guiding settled.
///
/// Failures at one altitude and azimuth while the frames lose their stars
/// point to something in the way (trees, a roof) rather than cloud. The
/// obstruction check reads this with the frames' star counts; it is cleared
/// only when guiding settles again, so it outlives a recovery that gave up
/// and let the run image unguided.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct GuideRecoveryStall {
    /// The mount position (RA hours, Dec degrees) when the recovery began.
    /// How far guiding has moved the mount during the recovery is measured
    /// from here.
    pub origin: Option<(f64, f64)>,
    pub failures: Vec<GuideRecoveryFailure>,
}

impl GuideRecoveryStall {
    pub fn failed_attempts(&self) -> usize {
        self.failures.len()
    }

    /// When the first attempt failed, Unix seconds.
    pub fn since_unix(&self) -> Option<i64> {
        self.failures.first().map(|failure| failure.at_unix)
    }

    /// The largest angle between the pointings of the failed attempts,
    /// degrees. `None` until two failures have a known pointing.
    pub fn pointing_spread_deg(&self) -> Option<f64> {
        let pointings: Vec<(f64, f64)> = self
            .failures
            .iter()
            .filter_map(|failure| failure.alt_az_deg)
            .collect();
        if pointings.len() < 2 {
            return None;
        }
        let mut spread: f64 = 0.0;
        for (i, a) in pointings.iter().enumerate() {
            for b in &pointings[i + 1..] {
                spread = spread.max(horizontal_separation_deg(*a, *b));
            }
        }
        Some(spread)
    }

    /// Whether at least `min_failures` attempts failed while the mount
    /// pointed within `max_spread_deg` of one place.
    pub fn stalled_at_one_pointing(&self, min_failures: usize, max_spread_deg: f64) -> bool {
        self.failed_attempts() >= min_failures
            && self
                .pointing_spread_deg()
                .is_some_and(|spread| spread <= max_spread_deg)
    }
}

/// Great-circle angle between two (altitude, azimuth) pointings, degrees.
fn horizontal_separation_deg(a: (f64, f64), b: (f64, f64)) -> f64 {
    let (alt1, az1) = (a.0.to_radians(), a.1.to_radians());
    let (alt2, az2) = (b.0.to_radians(), b.1.to_radians());
    let cos = alt1.sin() * alt2.sin() + alt1.cos() * alt2.cos() * (az2 - az1).cos();
    cos.clamp(-1.0, 1.0).acos().to_degrees()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn failure(at_unix: i64, alt: f64, az: f64) -> GuideRecoveryFailure {
        GuideRecoveryFailure {
            at_unix,
            alt_az_deg: Some((alt, az)),
        }
    }

    /// The rig behind its tree line on 2026-10-24: recovery failed again and
    /// again near altitude 64, azimuth 286.
    #[test]
    fn failures_at_one_pointing_read_as_a_stall_there() {
        let stall = GuideRecoveryStall {
            origin: None,
            failures: vec![
                failure(0, 64.2, 285.6),
                failure(120, 63.9, 286.0),
                failure(240, 63.6, 286.4),
            ],
        };
        assert_eq!(stall.since_unix(), Some(0));
        assert!(stall.pointing_spread_deg().unwrap() < 1.0);
        assert!(stall.stalled_at_one_pointing(3, 2.0));
        assert!(!stall.stalled_at_one_pointing(4, 2.0));
    }

    #[test]
    fn a_wandering_pointing_is_not_one_place() {
        let stall = GuideRecoveryStall {
            origin: None,
            failures: vec![failure(0, 64.0, 286.0), failure(600, 40.0, 250.0)],
        };
        assert!(!stall.stalled_at_one_pointing(2, 2.0));
    }

    #[test]
    fn unknown_pointings_are_no_evidence() {
        let stall = GuideRecoveryStall {
            origin: None,
            failures: vec![
                GuideRecoveryFailure {
                    at_unix: 0,
                    alt_az_deg: None,
                };
                3
            ],
        };
        assert_eq!(stall.pointing_spread_deg(), None);
        assert!(!stall.stalled_at_one_pointing(3, 2.0));
    }
}
