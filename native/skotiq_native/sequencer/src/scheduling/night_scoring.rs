//! How good a target is over a whole night, for planning.
//!
//! The same five axes as [`super::score_target`], read over the night instead
//! of at one instant: altitude is the highest the target stands above the
//! floor, airmass the best it reaches there, transit how close its culmination
//! falls to the middle of the night, and darkness how much of the night it
//! spends above the floor. The planner's "Best tonight" and the planetarium's
//! best targets rank with this; the TargetScheduler step and its preview rank
//! with the instant form.

use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};

use super::astronomy::{airmass, angular_separation};
use super::scoring::{score_airmass, score_altitude, score_moon_distance, ScoringWeights};
use super::AltitudeFloor;
use crate::meridian::{julian_day, local_sidereal_time, wrap_hours};

/// How far apart the night's altitude samples are.
const SAMPLE_STEP: Duration = Duration::minutes(15);

/// Sidereal hours per solar hour.
const SIDEREAL_RATE: f64 = 1.002_737_909_35;

/// A catalog position to score: J2000, RA in degrees.
#[derive(Debug, Clone, PartialEq)]
pub struct NightTarget {
    pub id: String,
    pub ra_deg: f64,
    pub dec_deg: f64,
}

/// The night being planned and the sky over it.
#[derive(Debug, Clone)]
pub struct NightObserver {
    pub latitude_deg: f64,
    pub longitude_deg: f64,
    /// The moment the "current altitude" figures are read at.
    pub now: DateTime<Utc>,
    /// The dark stretch the target is scored over.
    pub night_start: DateTime<Utc>,
    pub night_end: DateTime<Utc>,
    /// The Moon for the night (RA, Dec degrees, the frame of the targets);
    /// `None` scores every target as far from it.
    pub moon: Option<(f64, f64)>,
    /// Illuminated percentage, 0..=100.
    pub moon_illumination: f64,
    /// How high a target must stand toward each direction to count as usable;
    /// `None` counts it from the horizon.
    pub floor: Option<AltitudeFloor>,
}

/// Rise, culmination and set against the horizon, nearest a given instant.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct HorizonPass {
    pub rise_time: Option<DateTime<Utc>>,
    pub transit_time: Option<DateTime<Utc>>,
    pub set_time: Option<DateTime<Utc>>,
    pub transit_altitude_deg: f64,
    pub is_circumpolar: bool,
    pub never_rises: bool,
}

/// One target's night score and the figures behind it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NightScore {
    pub target_id: String,
    /// 0..=100, the weighted mean of the five axes.
    pub total_score: f64,
    pub altitude_score: f64,
    pub moon_distance_score: f64,
    pub transit_proximity_score: f64,
    /// The share of the night spent above the floor, scored.
    pub darkness_score: f64,
    pub airmass_score: f64,
    pub current_altitude_deg: f64,
    pub current_azimuth_deg: f64,
    /// The highest the target stands above the floor during the night; when
    /// it never clears the floor, the highest it gets at all.
    pub peak_altitude_deg: f64,
    pub peak_azimuth_deg: f64,
    pub peak_time: DateTime<Utc>,
    /// Hours of the night the target spends above the floor.
    pub hours_above_floor: f64,
    /// The first moment of the night the target is above the floor.
    pub first_usable_time: Option<DateTime<Utc>>,
    /// The lowest airmass the target reaches above the floor (infinite when it
    /// never clears it).
    pub best_airmass: f64,
    pub moon_distance_deg: f64,
    pub pass: HorizonPass,
}

/// Score every target over the night, in input order.
pub fn score_targets_for_night(
    targets: &[NightTarget],
    observer: &NightObserver,
    weights: &ScoringWeights,
) -> Vec<NightScore> {
    let night = NightSamples::new(observer);
    targets
        .iter()
        .map(|target| score_with(target, observer, &night, weights))
        .collect()
}

/// Score one target over the night.
pub fn score_target_for_night(
    target: &NightTarget,
    observer: &NightObserver,
    weights: &ScoringWeights,
) -> NightScore {
    score_with(target, observer, &NightSamples::new(observer), weights)
}

/// The sample instants of the night with their sidereal times, shared by
/// every target of one ranking.
struct NightSamples {
    times: Vec<(DateTime<Utc>, f64)>,
    middle: DateTime<Utc>,
    now_lst: f64,
}

impl NightSamples {
    fn new(observer: &NightObserver) -> Self {
        let lst = |at: &DateTime<Utc>| local_sidereal_time(julian_day(at), observer.longitude_deg);
        let mut times = Vec::new();
        let mut at = observer.night_start;
        while at <= observer.night_end {
            times.push((at, lst(&at)));
            at += SAMPLE_STEP;
        }
        let half = (observer.night_end - observer.night_start).num_seconds() / 2;
        Self {
            times,
            middle: observer.night_start + Duration::seconds(half),
            now_lst: lst(&observer.now),
        }
    }
}

fn score_with(
    target: &NightTarget,
    observer: &NightObserver,
    night: &NightSamples,
    weights: &ScoringWeights,
) -> NightScore {
    // One precession for the night: the target moves less than an arcsecond
    // relative to the equinox of date across it.
    let (ra_hours, dec) =
        crate::meridian::target_of_date(target.ra_deg / 15.0, target.dec_deg, night.middle);
    let lat = observer.latitude_deg;
    let alt_az_at_lst = |lst: f64| alt_az_from_hour_angle(wrap_hours(lst - ra_hours), dec, lat);

    let (current_alt, current_az) = alt_az_at_lst(night.now_lst);

    let mut usable_peak: Option<(f64, f64, DateTime<Utc>)> = None;
    let mut overall_peak = (-90.0_f64, 0.0_f64, observer.night_start);
    let mut best_airmass = f64::INFINITY;
    let mut usable_samples = 0_u32;
    let mut first_usable_time = None;
    for &(at, lst) in &night.times {
        let (alt, az) = alt_az_at_lst(lst);
        if alt > overall_peak.0 {
            overall_peak = (alt, az, at);
        }
        let floor = observer.floor.as_ref().map_or(0.0, |f| f.at_azimuth(az));
        if alt >= floor {
            usable_samples += 1;
            first_usable_time.get_or_insert(at);
            if usable_peak.is_none_or(|(peak, _, _)| alt > peak) {
                usable_peak = Some((alt, az, at));
            }
            best_airmass = best_airmass.min(airmass(alt));
        }
    }
    let (peak_alt, peak_az, peak_time) = usable_peak.unwrap_or(overall_peak);
    let hours_above_floor = f64::from(usable_samples) * SAMPLE_STEP.num_minutes() as f64 / 60.0;

    let pass = horizon_pass(ra_hours, dec, lat, observer.longitude_deg, night.middle);

    let moon_distance = observer.moon.map_or(180.0, |(moon_ra, moon_dec)| {
        angular_separation(target.ra_deg, target.dec_deg, moon_ra, moon_dec)
    });

    let altitude_score = score_altitude(peak_alt);
    let moon_distance_score = score_moon_distance(moon_distance, observer.moon_illumination);
    let transit_proximity_score =
        score_transit_in_night(&pass, observer.night_start, observer.night_end);
    let darkness_score =
        score_usable_share(hours_above_floor, observer.night_start, observer.night_end);
    let airmass_score = score_airmass(best_airmass);

    let total_score = weights.weighted_mean(
        altitude_score,
        moon_distance_score,
        transit_proximity_score,
        darkness_score,
        airmass_score,
    );

    NightScore {
        target_id: target.id.clone(),
        total_score,
        altitude_score,
        moon_distance_score,
        transit_proximity_score,
        darkness_score,
        airmass_score,
        current_altitude_deg: current_alt,
        current_azimuth_deg: current_az,
        peak_altitude_deg: peak_alt,
        peak_azimuth_deg: peak_az,
        peak_time,
        hours_above_floor,
        first_usable_time,
        best_airmass,
        moon_distance_deg: moon_distance,
        pass,
    }
}

/// Altitude and azimuth (degrees) of a position at hour angle `ha_hours`.
fn alt_az_from_hour_angle(ha_hours: f64, dec_deg: f64, lat_deg: f64) -> (f64, f64) {
    let ha = (ha_hours * 15.0).to_radians();
    let dec = dec_deg.to_radians();
    let lat = lat_deg.to_radians();
    let sin_alt = lat.sin() * dec.sin() + lat.cos() * dec.cos() * ha.cos();
    let azimuth =
        (-ha.sin() * dec.cos()).atan2(dec.sin() * lat.cos() - dec.cos() * lat.sin() * ha.cos());
    (
        sin_alt.clamp(-1.0, 1.0).asin().to_degrees(),
        azimuth.to_degrees().rem_euclid(360.0),
    )
}

/// Rise, culmination and set against the horizon nearest `center`, for a
/// position of date (RA hours, Dec degrees).
pub fn horizon_pass(
    ra_hours: f64,
    dec_deg: f64,
    lat_deg: f64,
    lon_deg: f64,
    center: DateTime<Utc>,
) -> HorizonPass {
    let transit_altitude_deg = (90.0 - (lat_deg - dec_deg).abs()).clamp(-90.0, 90.0);
    let lowest_altitude_deg = ((lat_deg + dec_deg).abs() - 90.0).clamp(-90.0, 90.0);
    let never_rises = transit_altitude_deg < 0.0;
    let is_circumpolar = !never_rises && lowest_altitude_deg >= 0.0;
    let hours_to_transit =
        -wrap_hours(local_sidereal_time(julian_day(&center), lon_deg) - ra_hours) / SIDEREAL_RATE;
    let transit = center + seconds(hours_to_transit);
    let (rise_time, set_time) = if never_rises || is_circumpolar {
        (None, None)
    } else {
        let cos_h0 = -(lat_deg.to_radians().tan() * dec_deg.to_radians().tan());
        let half_arc = cos_h0.clamp(-1.0, 1.0).acos().to_degrees() / 15.0 / SIDEREAL_RATE;
        (
            Some(transit - seconds(half_arc)),
            Some(transit + seconds(half_arc)),
        )
    };
    HorizonPass {
        rise_time,
        transit_time: (!never_rises).then_some(transit),
        set_time,
        transit_altitude_deg,
        is_circumpolar,
        never_rises,
    }
}

fn seconds(hours: f64) -> Duration {
    // Why: |hours| < 13 here, far inside i64 seconds.
    Duration::seconds((hours * 3600.0).round() as i64)
}

/// Culmination inside the night scores 70..=100, most at the middle; just
/// outside it, less the farther it falls.
fn score_transit_in_night(pass: &HorizonPass, start: DateTime<Utc>, end: DateTime<Utc>) -> f64 {
    if pass.never_rises {
        return 0.0;
    }
    let Some(transit) = pass.transit_time else {
        return 50.0;
    };
    let half_night_minutes = (end - start).num_minutes() as f64 / 2.0;
    if transit > start && transit < end {
        if half_night_minutes <= 0.0 {
            return 100.0;
        }
        let middle = start + Duration::seconds((end - start).num_seconds() / 2);
        let off_middle = (transit - middle).num_minutes().abs() as f64;
        let centeredness = 1.0 - (off_middle / half_night_minutes).clamp(0.0, 1.0);
        return 70.0 + centeredness * 30.0;
    }
    let closest = (transit - start)
        .num_minutes()
        .abs()
        .min((transit - end).num_minutes().abs());
    match closest {
        m if m < 60 => 60.0,
        m if m < 120 => 40.0,
        m if m < 240 => 20.0,
        _ => 10.0,
    }
}

/// The share of the night above the floor, scored: most of it is 100, none
/// is 0.
fn score_usable_share(hours: f64, start: DateTime<Utc>, end: DateTime<Utc>) -> f64 {
    let night_hours = (end - start).num_minutes() as f64 / 60.0;
    if night_hours <= 0.0 {
        return 10.0;
    }
    if hours <= 0.0 {
        return 0.0;
    }
    match (hours / night_hours).clamp(0.0, 1.0) {
        f if f >= 0.8 => 100.0,
        f if f >= 0.6 => 90.0,
        f if f >= 0.4 => 75.0,
        f if f >= 0.2 => 55.0,
        _ => 30.0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::meridian::calculate_alt_az;
    use crate::scheduling::{HorizonProfile, HorizonSample};
    use chrono::TimeZone;

    /// A January night at 40N 74W: dark from 23:00 to 11:00 UTC.
    fn january_night(floor: Option<AltitudeFloor>) -> NightObserver {
        NightObserver {
            latitude_deg: 40.0,
            longitude_deg: -74.0,
            now: Utc.with_ymd_and_hms(2026, 1, 15, 23, 0, 0).unwrap(),
            night_start: Utc.with_ymd_and_hms(2026, 1, 15, 23, 0, 0).unwrap(),
            night_end: Utc.with_ymd_and_hms(2026, 1, 16, 11, 0, 0).unwrap(),
            moon: None,
            moon_illumination: 0.0,
            floor,
        }
    }

    fn target(id: &str, ra_deg: f64, dec_deg: f64) -> NightTarget {
        NightTarget {
            id: id.into(),
            ra_deg,
            dec_deg,
        }
    }

    fn m42() -> NightTarget {
        target("m42", 83.82, -5.39)
    }

    #[test]
    fn a_winter_target_scores_high_and_culminates_inside_the_night() {
        let score =
            score_target_for_night(&m42(), &january_night(None), &ScoringWeights::default());
        assert!(score.hours_above_floor > 6.0, "{score:?}");
        assert!(score.peak_altitude_deg > 40.0, "{score:?}");
        let transit = score.pass.transit_time.expect("M42 rises at 40N");
        let night = january_night(None);
        assert!(transit > night.night_start && transit < night.night_end);
        assert!(score.transit_proximity_score >= 70.0);
        assert!(score.total_score > 70.0, "{score:?}");
    }

    #[test]
    fn a_target_that_never_rises_scores_zero_hours_and_no_transit() {
        let score = score_target_for_night(
            &target("south", 100.0, -70.0),
            &january_night(None),
            &ScoringWeights::default(),
        );
        assert!(score.pass.never_rises);
        assert_eq!(score.hours_above_floor, 0.0);
        assert_eq!(score.transit_proximity_score, 0.0);
        assert_eq!(score.airmass_score, 0.0);
        assert!(score.first_usable_time.is_none());
    }

    #[test]
    fn a_wall_everywhere_leaves_no_usable_hours_but_reports_the_true_peak() {
        let wall = AltitudeFloor::flat(90.0);
        let score = score_target_for_night(
            &m42(),
            &january_night(Some(wall)),
            &ScoringWeights::default(),
        );
        assert_eq!(score.hours_above_floor, 0.0);
        assert_eq!(score.darkness_score, 0.0);
        assert_eq!(score.airmass_score, 0.0);
        assert!(score.peak_altitude_deg > 0.0, "{score:?}");
    }

    #[test]
    fn a_hill_removes_hours_only_in_the_direction_the_target_stands() {
        let open = score_target_for_night(&m42(), &january_night(None), &ScoringWeights::default());
        // M42 stands south all night from 40N; a hill to the north does not
        // touch it, one to the south hides it.
        let hill = |center_az: f64| {
            AltitudeFloor::new(
                HorizonProfile::new(vec![
                    HorizonSample::new((center_az - 60.0).rem_euclid(360.0), 0.0),
                    HorizonSample::new((center_az - 59.0).rem_euclid(360.0), 89.0),
                    HorizonSample::new((center_az + 59.0).rem_euclid(360.0), 89.0),
                    HorizonSample::new((center_az + 60.0).rem_euclid(360.0), 0.0),
                ])
                .unwrap(),
            )
        };
        let behind = score_target_for_night(
            &m42(),
            &january_night(Some(hill(180.0))),
            &ScoringWeights::default(),
        );
        let north = score_target_for_night(
            &m42(),
            &january_night(Some(hill(0.0))),
            &ScoringWeights::default(),
        );
        assert!(behind.hours_above_floor < open.hours_above_floor);
        assert!((north.hours_above_floor - open.hours_above_floor).abs() < 1e-9);
    }

    #[test]
    fn a_target_that_rises_late_is_first_usable_after_dusk() {
        // RA 13h rises around local midnight in mid-January at 40N.
        let night = january_night(Some(AltitudeFloor::flat(30.0)));
        let score = score_target_for_night(
            &target("late", 195.0, 10.0),
            &night,
            &ScoringWeights::default(),
        );
        let first = score
            .first_usable_time
            .expect("clears 30 degrees before dawn");
        assert!(first > night.night_start + Duration::hours(3), "{first}");
        assert!(score.hours_above_floor > 0.0 && score.hours_above_floor < 8.0);
    }

    /// A target that culminates through the zenith at noon stands higher than
    /// one that culminates at midnight, yet it is the poorer target tonight.
    #[test]
    fn a_target_culminating_in_daylight_scores_below_one_culminating_at_night() {
        let night = january_night(Some(AltitudeFloor::flat(30.0)));
        let ra_transiting_at =
            |at: DateTime<Utc>| local_sidereal_time(julian_day(&at), night.longitude_deg) * 15.0;
        let middle = night.night_start + (night.night_end - night.night_start) / 2;
        let noon = Utc.with_ymd_and_hms(2026, 1, 16, 17, 0, 0).unwrap();
        let weights = ScoringWeights::default();
        let daylight = score_target_for_night(
            &target("noon", ra_transiting_at(noon), 40.0),
            &night,
            &weights,
        );
        let dark = score_target_for_night(
            &target("night", ra_transiting_at(middle), 20.0),
            &night,
            &weights,
        );
        assert!(daylight.pass.transit_altitude_deg > dark.pass.transit_altitude_deg);
        assert!(
            dark.total_score > daylight.total_score,
            "{dark:?} vs {daylight:?}"
        );
        assert!(dark.hours_above_floor > daylight.hours_above_floor);
    }

    #[test]
    fn a_brighter_moon_never_scores_better_at_the_same_separation() {
        let mut previous = f64::INFINITY;
        for illumination in [5.0, 25.0, 50.0, 75.0, 100.0] {
            let mut night = january_night(None);
            night.moon = Some((263.82, -5.39));
            night.moon_illumination = illumination;
            let score = score_target_for_night(&m42(), &night, &ScoringWeights::default());
            assert!(
                score.moon_distance_score < previous,
                "{illumination}: {score:?}"
            );
            previous = score.moon_distance_score;
        }
    }

    #[test]
    fn a_ranking_keeps_each_score_with_its_target() {
        let targets = [
            target("south", 100.0, -70.0),
            m42(),
            target("late", 195.0, 10.0),
        ];
        let night = january_night(None);
        let batch = score_targets_for_night(&targets, &night, &ScoringWeights::default());
        for (t, s) in targets.iter().zip(&batch) {
            assert_eq!(s.target_id, t.id);
            assert_eq!(
                s,
                &score_target_for_night(t, &night, &ScoringWeights::default())
            );
        }
    }

    #[test]
    fn the_horizon_pass_matches_the_analytic_rise_and_set() {
        let center = Utc.with_ymd_and_hms(2026, 1, 16, 5, 0, 0).unwrap();
        let (ra, dec) = crate::meridian::target_of_date(83.82 / 15.0, -5.39, center);
        let pass = horizon_pass(ra, dec, 40.0, -74.0, center);
        for (label, at) in [("rise", pass.rise_time), ("set", pass.set_time)] {
            let at = at.unwrap();
            let (alt, _) = calculate_alt_az(ra, dec, 40.0, -74.0, at);
            assert!(alt.abs() < 0.1, "{label} at {at}: altitude {alt}");
        }
        let transit = pass.transit_time.unwrap();
        assert!((transit - center).num_hours().abs() <= 12);
        let (alt, _) = calculate_alt_az(ra, dec, 40.0, -74.0, transit);
        assert!((alt - pass.transit_altitude_deg).abs() < 0.1);
    }
}
