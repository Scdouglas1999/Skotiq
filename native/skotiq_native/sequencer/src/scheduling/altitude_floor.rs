//! The site's altitude floor: how high a target must stand to be imaged.
//!
//! The floor toward an azimuth is the property horizon's altitude there when
//! the operator set a horizon, otherwise the minimum altitude setting;
//! obstructions the runs learned raise it where they are. The app resolves
//! that rule (`AltitudeFloor` in `skotiq_core`) and sends the result as
//! samples by azimuth in the run configuration, so the run never holds a
//! number of its own. Both sides answer the cases in
//! `test_fixtures/altitude_floor/cases.json`.

use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};

use super::HorizonProfile;

/// The floor by azimuth, and the questions a run asks of it.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(transparent)]
pub struct AltitudeFloor {
    profile: HorizonProfile,
}

/// A target as the floor needs it: J2000 coordinates and the observing site.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FloorTarget {
    pub ra_hours: f64,
    pub dec_degrees: f64,
    pub latitude_deg: f64,
    pub longitude_deg: f64,
}

impl FloorTarget {
    /// Altitude and azimuth in degrees at `at`.
    pub fn alt_az(&self, at: DateTime<Utc>) -> (f64, f64) {
        let (ra_hours, dec_degrees) =
            crate::meridian::target_of_date(self.ra_hours, self.dec_degrees, at);
        crate::meridian::calculate_alt_az(
            ra_hours,
            dec_degrees,
            self.latitude_deg,
            self.longitude_deg,
            at,
        )
    }
}

/// How finely a crossing of the floor is searched for.
const CROSSING_STEP_SECS: i64 = 60;

impl AltitudeFloor {
    pub fn new(profile: HorizonProfile) -> Self {
        Self { profile }
    }

    /// The same floor in every direction.
    pub fn flat(altitude_deg: f64) -> Self {
        Self::new(HorizonProfile::flat(altitude_deg))
    }

    pub fn profile(&self) -> &HorizonProfile {
        &self.profile
    }

    /// The floor in degrees toward `azimuth_deg`.
    pub fn at_azimuth(&self, azimuth_deg: f64) -> f64 {
        self.profile.min_altitude_at(azimuth_deg)
    }

    /// Whether a point at `altitude_deg` toward `azimuth_deg` clears the floor.
    pub fn clears(&self, altitude_deg: f64, azimuth_deg: f64) -> bool {
        altitude_deg >= self.at_azimuth(azimuth_deg)
    }

    /// Whether `target` is above the floor in the direction it stands at `at`.
    pub fn is_above(&self, target: &FloorTarget, at: DateTime<Utc>) -> bool {
        let (alt, az) = target.alt_az(at);
        self.clears(alt, az)
    }

    /// The first time in `[from, until]` that `target` is above the floor:
    /// `from` itself when it already is, `None` when it stays below.
    pub fn rises_above(
        &self,
        target: &FloorTarget,
        from: DateTime<Utc>,
        until: DateTime<Utc>,
    ) -> Option<DateTime<Utc>> {
        self.first_time(target, from, until, true)
    }

    /// The first time in `[from, until]` that `target` is below the floor:
    /// `from` itself when it already is, `None` when it stays above.
    pub fn sets_below(
        &self,
        target: &FloorTarget,
        from: DateTime<Utc>,
        until: DateTime<Utc>,
    ) -> Option<DateTime<Utc>> {
        self.first_time(target, from, until, false)
    }

    fn first_time(
        &self,
        target: &FloorTarget,
        from: DateTime<Utc>,
        until: DateTime<Utc>,
        above: bool,
    ) -> Option<DateTime<Utc>> {
        let mut at = from;
        while at <= until {
            if self.is_above(target, at) == above {
                return Some(at);
            }
            at += Duration::seconds(CROSSING_STEP_SECS);
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::Deserialize;

    #[derive(Deserialize)]
    struct Fixture {
        site: Site,
        floors: std::collections::HashMap<String, FloorCase>,
        at_azimuth: Vec<AtAzimuth>,
        above: Vec<Above>,
        crossings: Vec<Crossing>,
        crossing_tolerance_secs: i64,
    }

    #[derive(Deserialize)]
    struct Site {
        latitude: f64,
        longitude: f64,
    }

    #[derive(Deserialize)]
    struct FloorCase {
        wire: AltitudeFloor,
    }

    #[derive(Deserialize)]
    struct AtAzimuth {
        floor: String,
        azimuth: f64,
        expect: f64,
    }

    #[derive(Deserialize)]
    struct Above {
        floor: String,
        name: String,
        ra_hours: f64,
        dec_degrees: f64,
        at: DateTime<Utc>,
        expect: bool,
    }

    #[derive(Deserialize)]
    struct Crossing {
        floor: String,
        name: String,
        ra_hours: f64,
        dec_degrees: f64,
        from: DateTime<Utc>,
        until: DateTime<Utc>,
        rises_above: Option<DateTime<Utc>>,
        sets_below: Option<DateTime<Utc>>,
    }

    fn fixture() -> Fixture {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../test_fixtures/altitude_floor/cases.json"
        );
        serde_json::from_str(&std::fs::read_to_string(path).expect("the shared fixture"))
            .expect("the fixture's shape")
    }

    fn close(
        actual: Option<DateTime<Utc>>,
        expected: Option<DateTime<Utc>>,
        tolerance_secs: i64,
    ) -> bool {
        match (actual, expected) {
            (None, None) => true,
            (Some(a), Some(e)) => (a - e).num_seconds().abs() <= tolerance_secs,
            _ => false,
        }
    }

    #[test]
    fn the_floor_answers_the_shared_cases_as_the_app_does() {
        let fixture = fixture();
        let target = |ra_hours, dec_degrees| FloorTarget {
            ra_hours,
            dec_degrees,
            latitude_deg: fixture.site.latitude,
            longitude_deg: fixture.site.longitude,
        };
        for case in &fixture.at_azimuth {
            let floor = &fixture.floors[&case.floor].wire;
            let got = floor.at_azimuth(case.azimuth);
            assert!(
                (got - case.expect).abs() < 1e-6,
                "{} at azimuth {}: {got}, expected {}",
                case.floor,
                case.azimuth,
                case.expect
            );
        }
        for case in &fixture.above {
            let floor = &fixture.floors[&case.floor].wire;
            assert_eq!(
                floor.is_above(&target(case.ra_hours, case.dec_degrees), case.at),
                case.expect,
                "{} over {} at {}",
                case.name,
                case.floor,
                case.at
            );
        }
        for case in &fixture.crossings {
            let floor = &fixture.floors[&case.floor].wire;
            let target = target(case.ra_hours, case.dec_degrees);
            let rises = floor.rises_above(&target, case.from, case.until);
            let sets = floor.sets_below(&target, case.from, case.until);
            assert!(
                close(rises, case.rises_above, fixture.crossing_tolerance_secs),
                "{} over {} rises above at {rises:?}, expected {:?}",
                case.name,
                case.floor,
                case.rises_above
            );
            assert!(
                close(sets, case.sets_below, fixture.crossing_tolerance_secs),
                "{} over {} sets below at {sets:?}, expected {:?}",
                case.name,
                case.floor,
                case.sets_below
            );
        }
    }

    #[test]
    fn a_target_already_above_rises_at_once_and_one_that_stays_below_never_does() {
        let floor = AltitudeFloor::flat(30.0);
        let from = "2026-01-15T03:00:00Z".parse::<DateTime<Utc>>().unwrap();
        let until = from + Duration::hours(6);
        // Polaris stands near the site's latitude all night.
        let polaris = FloorTarget {
            ra_hours: 2.53,
            dec_degrees: 89.26,
            latitude_deg: 40.0,
            longitude_deg: -75.0,
        };
        assert_eq!(floor.rises_above(&polaris, from, until), Some(from));
        assert_eq!(floor.sets_below(&polaris, from, until), None);
        // Declination -60 never clears 30 degrees from latitude 40.
        let southern = FloorTarget {
            dec_degrees: -60.0,
            ..polaris
        };
        assert_eq!(floor.rises_above(&southern, from, until), None);
        assert_eq!(floor.sets_below(&southern, from, until), Some(from));
    }
}
