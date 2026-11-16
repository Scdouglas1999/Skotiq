//! How good a target is to image now: the five-axis score the TargetScheduler
//! step ranks its targets by, and the hard gates that make a target
//! unrunnable (completed, outside its time window, below its floor, behind
//! the horizon, too near a bright Moon).
//!
//! This is the app's one target scorer. The step's preview in the sequence
//! editor asks for the same ranking through the bridge, and the night form in
//! [`super::night_scoring`] reads the same axes over a whole night for the
//! planner.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::scheduling::astronomy::{
    airmass, angular_separation, calculate_object_visibility, object_alt_az, ObjectVisibility,
};

/// One weight per scoring axis.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
pub struct ScoringWeights {
    pub altitude_weight: f64,
    pub moon_distance_weight: f64,
    pub transit_proximity_weight: f64,
    pub darkness_weight: f64,
    pub airmass_weight: f64,
    /// Optional HARD moon-avoidance gate (companion to the soft
    /// `moon_distance_weight` score): when set, a target within this many
    /// degrees of an up, sufficiently-illuminated moon is marked
    /// `runnable=false` regardless of its score. `None` = no hard gate.
    #[serde(default)]
    pub min_moon_separation_deg: Option<f64>,
}

impl Default for ScoringWeights {
    fn default() -> Self {
        Self {
            altitude_weight: 0.25,
            moon_distance_weight: 0.25,
            transit_proximity_weight: 0.20,
            darkness_weight: 0.15,
            airmass_weight: 0.15,
            min_moon_separation_deg: None,
        }
    }
}

impl ScoringWeights {
    /// Sum of all weights.
    pub fn sum(&self) -> f64 {
        self.altitude_weight
            + self.moon_distance_weight
            + self.transit_proximity_weight
            + self.darkness_weight
            + self.airmass_weight
    }

    /// The weighted mean of five 0..=100 axis scores, in field order.
    pub fn weighted_mean(
        &self,
        altitude: f64,
        moon_distance: f64,
        transit_proximity: f64,
        darkness: f64,
        airmass: f64,
    ) -> f64 {
        (altitude * self.altitude_weight
            + moon_distance * self.moon_distance_weight
            + transit_proximity * self.transit_proximity_weight
            + darkness * self.darkness_weight
            + airmass * self.airmass_weight)
            / self.sum().max(f64::EPSILON)
    }
}

/// A target to score. RA in degrees.
#[derive(Debug, Clone)]
pub struct TargetInput {
    pub id: String,
    pub name: String,
    /// Right ascension in DEGREES (0–360).
    pub ra_deg: f64,
    pub dec_deg: f64,
    /// Minimum altitude (degrees) below which the scheduler should treat this
    /// target as un-runnable. `None` means no per-target altitude floor.
    pub min_altitude: Option<f64>,
    /// Optional `start_after` Unix timestamp — target is skipped if `now <
    /// start_after`.
    pub start_after: Option<i64>,
    /// Optional `end_before` Unix timestamp — target is skipped if `now >=
    /// end_before`.
    pub end_before: Option<i64>,
    /// User-assigned priority. Higher = preferred. Ties on raw score are
    /// broken by priority, descending.
    pub priority: i32,
    /// Pre-existing completion flag. The scheduler does not pick a completed
    /// target even if it would otherwise score highest.
    pub completed: bool,
}

/// Observer state for one scheduling decision.
#[derive(Debug, Clone)]
pub struct ObserverContext {
    pub latitude_deg: f64,
    pub longitude_deg: f64,
    pub now: DateTime<Utc>,
    /// Moon position (`(ra_deg, dec_deg)`); `None` scores every target as
    /// 180° from it.
    pub moon: Option<(f64, f64)>,
    /// 0..=100 illumination fraction. Defaults to 0 (new moon).
    pub moon_illumination: f64,
    /// Optional twilight bracket for darkness scoring.
    pub twilight: Option<TwilightBracket>,
    /// The floor by azimuth (horizon profile). A target below it at its
    /// current azimuth is `runnable = false` whatever its score; `None` holds
    /// targets only to their own `min_altitude`.
    pub horizon: Option<HorizonProfile>,
}

impl ObserverContext {
    /// The sky over a site at `now` as the TargetScheduler step sees it: the
    /// Moon and twilight from the scheduler's ephemeris, and `horizon` as the
    /// floor. The step and its preview both build their observer here.
    pub fn at_site(
        latitude_deg: f64,
        longitude_deg: f64,
        now: DateTime<Utc>,
        horizon: Option<HorizonProfile>,
    ) -> Self {
        Self {
            latitude_deg,
            longitude_deg,
            now,
            moon: Some(super::ephemeris::moon_equatorial(&now)),
            moon_illumination: super::ephemeris::moon_illumination_percent(&now),
            twilight: Some(super::ephemeris::twilight_bracket(
                &now,
                latitude_deg,
                longitude_deg,
            )),
            horizon,
        }
    }
}

/// One azimuth/altitude pair defining a tree, building, or roof outline.
/// Serialized as `{"az": .., "alt": ..}`, the shape the app writes.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
pub struct HorizonSample {
    #[serde(rename = "az")]
    pub azimuth_deg: f64,
    #[serde(rename = "alt")]
    pub altitude_deg: f64,
}

impl HorizonSample {
    pub fn new(azimuth_deg: f64, altitude_deg: f64) -> Self {
        Self {
            azimuth_deg,
            altitude_deg,
        }
    }
}

/// A site-horizon profile: the operator's local obstructions encoded as a
/// series of (azimuth, altitude) samples, interpolated linearly around the
/// compass (with wrap-around at 360°). `samples` is never empty by
/// construction (see [`HorizonProfile::new`]).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct HorizonProfile {
    pub samples: Vec<HorizonSample>,
}

impl HorizonProfile {
    /// Build a profile from samples. Returns `None` when `samples` is empty
    /// (a horizon with no points cannot answer `min_altitude_at` — fail
    /// closed rather than invent a flat 0° floor).
    pub fn new(samples: Vec<HorizonSample>) -> Option<Self> {
        if samples.is_empty() {
            return None;
        }
        Some(Self { samples })
    }

    /// Canonical flat horizon at a fixed altitude.
    pub fn flat(altitude_deg: f64) -> Self {
        Self {
            samples: vec![HorizonSample::new(0.0, altitude_deg)],
        }
    }

    fn wrap360(az: f64) -> f64 {
        let mut v = az % 360.0;
        if v < 0.0 {
            v += 360.0;
        }
        v
    }

    /// Minimum altitude (degrees) at the given azimuth, by linear
    /// interpolation between bracketing samples with wrap-around at 360°.
    /// With a single sample the profile is a flat horizon at that altitude.
    /// The app's `AltitudeFloor` answers the same cases
    /// (`test_fixtures/altitude_floor/cases.json`).
    pub fn min_altitude_at(&self, azimuth_deg: f64) -> f64 {
        // By construction `samples` is non-empty; `flat` / `new` enforce it.
        // Defence in depth: if a hand-edited payload somehow produced an
        // empty list, treat it as "no obstruction" (0°) rather than panic
        // inside the scheduling hot path.
        if self.samples.is_empty() {
            return 0.0;
        }
        let az = Self::wrap360(azimuth_deg);
        if self.samples.len() == 1 {
            return self.samples[0].altitude_deg;
        }

        // The app sends samples in compass order; only an unordered profile
        // (hand-edited JSON) pays for a sorted copy. A night ranking asks
        // this hundreds of thousands of times.
        let sorted: std::borrow::Cow<'_, [HorizonSample]> = if self
            .samples
            .is_sorted_by(|a, b| a.azimuth_deg <= b.azimuth_deg)
        {
            std::borrow::Cow::Borrowed(&self.samples)
        } else {
            let mut owned = self.samples.clone();
            owned.sort_by(|a, b| {
                a.azimuth_deg
                    .partial_cmp(&b.azimuth_deg)
                    .unwrap_or(std::cmp::Ordering::Equal)
            });
            std::borrow::Cow::Owned(owned)
        };

        let last = *sorted.last().unwrap();
        let first = sorted[0];
        let mut lower = last;
        let mut upper = first;
        let mut lower_az = Self::wrap360(last.azimuth_deg) - 360.0;
        let mut upper_az = Self::wrap360(first.azimuth_deg);

        for (i, next) in sorted.iter().enumerate() {
            let next_az = Self::wrap360(next.azimuth_deg);
            if next_az >= az {
                upper = *next;
                upper_az = next_az;
                if i == 0 {
                    lower = last;
                    lower_az = Self::wrap360(last.azimuth_deg) - 360.0;
                } else {
                    lower = sorted[i - 1];
                    lower_az = Self::wrap360(lower.azimuth_deg);
                }
                break;
            }
            lower = *next;
            lower_az = next_az;
            if i == sorted.len() - 1 {
                upper = first;
                upper_az = Self::wrap360(first.azimuth_deg) + 360.0;
            }
        }

        let span = upper_az - lower_az;
        if span <= 0.0 {
            return lower.altitude_deg;
        }
        let t = (az - lower_az) / span;
        lower.altitude_deg + t * (upper.altitude_deg - lower.altitude_deg)
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct TwilightBracket {
    pub civil_dusk: Option<i64>,
    pub civil_dawn: Option<i64>,
    pub nautical_dusk: Option<i64>,
    pub nautical_dawn: Option<i64>,
    pub astronomical_dusk: Option<i64>,
    pub astronomical_dawn: Option<i64>,
}

/// Per-axis + total score for one target.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TargetScore {
    pub target_id: String,
    pub target_name: String,
    pub total_score: f64,
    pub altitude_score: f64,
    pub moon_distance_score: f64,
    pub transit_proximity_score: f64,
    pub darkness_score: f64,
    pub airmass_score: f64,
    pub current_altitude_deg: f64,
    pub current_azimuth_deg: f64,
    pub current_airmass: f64,
    pub moon_distance_deg: f64,
    /// True when the target fails a hard constraint (below horizon at min
    /// altitude, outside start_after/end_before, already completed). The
    /// scheduler skips runnable=false candidates regardless of score.
    pub runnable: bool,
    /// Reason the target was filtered out (`None` when `runnable == true`).
    pub skip_reason: Option<String>,
    /// Carried through so the dashboard can order ties by priority.
    pub priority: i32,
}

/// Score one target at `observer.now`.
pub fn score_target(
    target: &TargetInput,
    observer: &ObserverContext,
    weights: &ScoringWeights,
) -> TargetScore {
    // Current position
    let (alt, az) = object_alt_az(
        target.ra_deg,
        target.dec_deg,
        &observer.now,
        observer.latitude_deg,
        observer.longitude_deg,
    );

    // Rise / transit / set
    let visibility = calculate_object_visibility(
        target.ra_deg,
        target.dec_deg,
        &observer.now,
        observer.latitude_deg,
        observer.longitude_deg,
        0.0,
    );

    let am = airmass(alt);

    let moon_dist = match observer.moon {
        Some((moon_ra, moon_dec)) => {
            angular_separation(target.ra_deg, target.dec_deg, moon_ra, moon_dec)
        }
        None => 180.0,
    };

    let alt_score = score_altitude(alt);
    let moon_score = score_moon_distance(moon_dist, observer.moon_illumination);
    let transit_score = score_transit_proximity(&visibility, &observer.now);
    let darkness_score = score_darkness(observer.twilight.as_ref(), observer.now.timestamp());
    let airmass_score = score_airmass(am);

    let total = weights.weighted_mean(
        alt_score,
        moon_score,
        transit_score,
        darkness_score,
        airmass_score,
    );

    // Hard runnable filters.
    let now_ts = observer.now.timestamp();
    let mut runnable = true;
    let mut skip_reason = None;
    if target.completed {
        runnable = false;
        skip_reason = Some("already completed".to_string());
    } else if let Some(after) = target.start_after {
        if now_ts < after {
            runnable = false;
            skip_reason = Some(format!(
                "start_after not reached ({}s remaining)",
                after - now_ts
            ));
        }
    }
    if runnable {
        if let Some(before) = target.end_before {
            if now_ts >= before {
                runnable = false;
                skip_reason = Some("end_before passed".to_string());
            }
        }
    }
    if runnable {
        if let Some(min_alt) = target.min_altitude {
            if alt < min_alt {
                runnable = false;
                skip_reason = Some(format!(
                    "altitude {alt:.1}° below per-target floor {min_alt:.1}°"
                ));
            }
        }
    }
    // A target that clears its own floor can still be behind a tree or roof
    // at its current azimuth.
    if runnable {
        if let Some(horizon) = observer.horizon.as_ref() {
            let horizon_min = horizon.min_altitude_at(az);
            if alt < horizon_min {
                runnable = false;
                skip_reason = Some(format!(
                    "altitude {alt:.1}° below the altitude floor ({horizon_min:.1}° at azimuth {az:.0}°)"
                ));
            }
        }
    }
    // Hard moon-avoidance gate. Only avoid a moon that is actually above the
    // horizon AND bright enough to matter — a set or near-new moon needs no
    // avoidance, so the gate stays out of the way on dark nights.
    if runnable {
        if let (Some(min_sep), Some((moon_ra, moon_dec))) =
            (weights.min_moon_separation_deg, observer.moon)
        {
            const MOON_AVOID_MIN_ILLUM: f64 = 10.0;
            let (moon_alt, _) = object_alt_az(
                moon_ra,
                moon_dec,
                &observer.now,
                observer.latitude_deg,
                observer.longitude_deg,
            );
            if moon_alt > 0.0
                && observer.moon_illumination >= MOON_AVOID_MIN_ILLUM
                && moon_dist < min_sep
            {
                runnable = false;
                skip_reason = Some(format!(
                    "within {moon_dist:.0}° of the moon (gate {min_sep:.0}°; moon {moon_alt:.0}° alt, {:.0}% illum)",
                    observer.moon_illumination
                ));
            }
        }
    }

    TargetScore {
        target_id: target.id.clone(),
        target_name: target.name.clone(),
        total_score: total,
        altitude_score: alt_score,
        moon_distance_score: moon_score,
        transit_proximity_score: transit_score,
        darkness_score,
        airmass_score,
        current_altitude_deg: alt,
        current_azimuth_deg: az,
        current_airmass: am,
        moon_distance_deg: moon_dist,
        runnable,
        skip_reason,
        priority: target.priority,
    }
}

/// Score many targets and return them sorted: runnable first, then by total
/// score descending, with priority as the tie-breaker.
pub fn score_targets(
    targets: &[TargetInput],
    observer: &ObserverContext,
    weights: &ScoringWeights,
) -> Vec<TargetScore> {
    let mut scored: Vec<TargetScore> = targets
        .iter()
        .map(|t| score_target(t, observer, weights))
        .collect();
    scored.sort_by(|a, b| {
        b.runnable
            .cmp(&a.runnable)
            .then_with(|| {
                b.total_score
                    .partial_cmp(&a.total_score)
                    .unwrap_or(std::cmp::Ordering::Equal)
            })
            .then_with(|| b.priority.cmp(&a.priority))
    });
    scored
}

/// Pick the highest-scoring runnable target above `min_score`. Returns `None`
/// when no target clears the threshold.
pub fn pick_best(
    targets: &[TargetInput],
    observer: &ObserverContext,
    weights: &ScoringWeights,
    min_score: f64,
) -> Option<TargetScore> {
    let scored = score_targets(targets, observer, weights);
    scored
        .into_iter()
        .find(|s| s.runnable && s.total_score >= min_score)
}

// Per-axis scores, 0..=100. The night form reads the same ones.

pub(super) fn score_altitude(altitude: f64) -> f64 {
    if altitude < 0.0 {
        return 0.0;
    }
    if altitude < 15.0 {
        return altitude * 2.0;
    }
    if altitude < 30.0 {
        return 30.0 + (altitude - 15.0) * 2.0;
    }
    if altitude < 60.0 {
        return 60.0 + (altitude - 30.0) * 1.33;
    }
    100.0
}

pub(super) fn score_moon_distance(distance: f64, illumination: f64) -> f64 {
    let moon_factor = (illumination / 100.0).clamp(0.0, 1.0);
    if illumination < 10.0 {
        // New moon - distance doesn't matter much.
        return 90.0 + (distance / 180.0) * 10.0;
    }
    let min_good_dist = 30.0 + 70.0 * moon_factor;

    // Moonlight raises the sky background over the whole hemisphere, so no
    // separation earns a perfect moon score under a bright moon.
    let best_achievable = 100.0 - 22.0 * moon_factor;

    if distance >= min_good_dist {
        return best_achievable;
    }
    if distance < 10.0 {
        return 10.0 * (1.0 - moon_factor * 0.8);
    }
    (distance / min_good_dist) * best_achievable
}

fn score_transit_proximity(visibility: &ObjectVisibility, time: &DateTime<Utc>) -> f64 {
    if visibility.never_rises {
        return 0.0;
    }
    let Some(transit) = visibility.transit_time else {
        return 50.0;
    };
    let minutes = (transit.signed_duration_since(*time).num_minutes()).abs();
    if minutes < 30 {
        return 100.0;
    }
    if minutes < 60 {
        return 90.0;
    }
    if minutes < 120 {
        return 80.0;
    }
    if minutes < 240 {
        return 60.0;
    }
    if minutes < 360 {
        return 40.0;
    }
    20.0
}

fn score_darkness(twilight: Option<&TwilightBracket>, now_ts: i64) -> f64 {
    let Some(tw) = twilight else {
        return 70.0;
    };

    if let (Some(dusk), Some(dawn)) = (tw.astronomical_dusk, tw.astronomical_dawn) {
        if now_ts > dusk && now_ts < dawn {
            return 100.0;
        }
    }
    if let (Some(dusk), Some(dawn)) = (tw.nautical_dusk, tw.nautical_dawn) {
        if now_ts > dusk && now_ts < dawn {
            return 70.0;
        }
    }
    if let (Some(dusk), Some(dawn)) = (tw.civil_dusk, tw.civil_dawn) {
        if now_ts > dusk && now_ts < dawn {
            return 40.0;
        }
    }
    10.0
}

pub(super) fn score_airmass(airmass: f64) -> f64 {
    if airmass.is_infinite() {
        return 0.0;
    }
    if airmass <= 1.0 {
        return 100.0;
    }
    if airmass <= 1.5 {
        return 90.0;
    }
    if airmass <= 2.0 {
        return 70.0;
    }
    if airmass <= 2.5 {
        return 50.0;
    }
    if airmass <= 3.0 {
        return 30.0;
    }
    10.0
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    #[test]
    fn altitude_score_breakpoints() {
        // 0° → 0
        assert!((score_altitude(0.0) - 0.0).abs() < 1e-9);
        // 7.5° → 15 (linear 0..30 over [0,15))
        assert!((score_altitude(7.5) - 15.0).abs() < 1e-9);
        // 15° → 30 (start of next segment)
        assert!((score_altitude(15.0) - 30.0).abs() < 1e-9);
        // 30° → 60 (start of third segment)
        assert!((score_altitude(30.0) - 60.0).abs() < 1e-9);
        // 60° → 100 (saturation)
        assert!((score_altitude(60.0) - 100.0).abs() < 1e-9);
        assert!((score_altitude(89.0) - 100.0).abs() < 1e-9);
    }

    #[test]
    fn airmass_score_breakpoints() {
        assert_eq!(score_airmass(f64::INFINITY), 0.0);
        assert_eq!(score_airmass(1.0), 100.0);
        assert_eq!(score_airmass(1.5), 90.0);
        assert_eq!(score_airmass(2.0), 70.0);
        assert_eq!(score_airmass(2.5), 50.0);
        assert_eq!(score_airmass(3.0), 30.0);
        assert_eq!(score_airmass(4.0), 10.0);
    }

    #[test]
    fn moon_distance_new_moon_branch() {
        // illumination < 10 → 90 + (d/180)*10
        let s = score_moon_distance(90.0, 5.0);
        assert!((s - 95.0).abs() < 1e-9, "got {s}");
    }

    /// A bright moon can never score as well as a dark sky at the same
    /// separation: a full moon at 120 deg scoring a perfect 100.0 against a new
    /// moon's 96.7 at the same separation is the scorer preferring the worse
    /// night.
    #[test]
    fn moon_distance_bright_moon_never_scores_perfect() {
        // illumination 100 -> moon_factor 1.0 -> best_achievable = 78.0, and
        // min_good_dist = 100 so 120 deg clears the "far enough" branch.
        let full_moon_far = score_moon_distance(120.0, 100.0);
        assert!(
            (full_moon_far - 78.0).abs() < 1e-9,
            "expected 78.0, got {full_moon_far}"
        );

        // The ordering is the property that actually matters: the same target,
        // same separation, under a darker moon must score HIGHER.
        let new_moon_far = score_moon_distance(120.0, 5.0);
        assert!(
            new_moon_far > full_moon_far,
            "a new moon at 120 deg scored {new_moon_far} but a FULL moon at the \
             same separation scored {full_moon_far} — the moon factor is rewarding \
             the worse night"
        );

        // And it has to be monotonic in illumination, not just right at the ends.
        let mut previous = f64::INFINITY;
        for illumination in [10.0, 25.0, 50.0, 75.0, 100.0] {
            let score = score_moon_distance(150.0, illumination);
            assert!(
                score < previous,
                "score at illumination {illumination} was {score}, not below the \
                 previous {previous}"
            );
            previous = score;
        }
    }

    #[test]
    fn hard_moon_gate_marks_targets_near_an_up_bright_moon_unrunnable() {
        let now = Utc.with_ymd_and_hms(2026, 1, 15, 6, 0, 0).unwrap();
        // Place the moon at M42's position (known to be UP from 40N at this
        // time) so the gate's "moon above horizon"
        // check is satisfied.
        let moon_up = (83.82, -5.39);
        let target = |ra: f64, dec: f64| TargetInput {
            id: "t".into(),
            name: "T".into(),
            ra_deg: ra,
            dec_deg: dec,
            min_altitude: None,
            start_after: None,
            end_before: None,
            priority: 0,
            completed: false,
        };
        let observer = |moon: Option<(f64, f64)>, illum: f64| ObserverContext {
            latitude_deg: 40.0,
            longitude_deg: -74.0,
            now,
            moon,
            moon_illumination: illum,
            twilight: None,
            horizon: None,
        };
        let gated = ScoringWeights {
            min_moon_separation_deg: Some(30.0),
            ..Default::default()
        };

        // Target ON the moon, bright moon up → gated out.
        let near = score_target(&target(83.9, -5.3), &observer(Some(moon_up), 80.0), &gated);
        assert!(!near.runnable, "target on a bright up moon must be gated");
        assert!(near.skip_reason.as_deref().unwrap_or("").contains("moon"));

        // Far from the moon → not gated.
        let far = score_target(&target(250.0, 40.0), &observer(Some(moon_up), 80.0), &gated);
        assert!(far.runnable, "target far from the moon must stay runnable");

        // Same near target but NO gate configured → runnable (soft score only).
        let ungated = score_target(
            &target(83.9, -5.3),
            &observer(Some(moon_up), 80.0),
            &ScoringWeights::default(),
        );
        assert!(
            ungated.runnable,
            "without a gate the soft score never marks unrunnable"
        );

        // Near a DOWN moon (opposite hemisphere of sky) → gate must not fire.
        let moon_down = (264.0, -5.0);
        let near_down = score_target(
            &target(264.1, -5.0),
            &observer(Some(moon_down), 80.0),
            &gated,
        );
        assert!(
            near_down.runnable,
            "a moon below the horizon needs no avoidance"
        );

        // Near an up but near-NEW moon (<10% illum) → gate must not fire.
        let near_new = score_target(&target(83.9, -5.3), &observer(Some(moon_up), 3.0), &gated);
        assert!(near_new.runnable, "a near-new moon needs no avoidance");
    }

    #[test]
    fn pick_best_picks_highest_runnable_above_threshold() {
        let now = Utc.with_ymd_and_hms(2026, 1, 15, 6, 0, 0).unwrap();
        let observer = ObserverContext {
            latitude_deg: 40.0,
            longitude_deg: -74.0,
            now,
            moon: Some((0.0, 0.0)),
            moon_illumination: 5.0,
            twilight: None,
            horizon: None,
        };
        let weights = ScoringWeights::default();
        // M42-ish (Orion, high in winter from 40N at 06:00 UTC ≈ midnight EST)
        let m42 = TargetInput {
            id: "m42".into(),
            name: "M42".into(),
            ra_deg: 83.82,
            dec_deg: -5.39,
            min_altitude: None,
            start_after: None,
            end_before: None,
            priority: 0,
            completed: false,
        };
        // A target near the sun → currently below horizon → unrunnable
        let sun_neighbour = TargetInput {
            id: "behind_sun".into(),
            name: "Behind Sun".into(),
            ra_deg: 300.0,
            dec_deg: -23.0,
            min_altitude: Some(20.0),
            start_after: None,
            end_before: None,
            priority: 5,
            completed: false,
        };
        let best = pick_best(&[sun_neighbour, m42.clone()], &observer, &weights, 30.0)
            .expect("expected a runnable target");
        assert_eq!(best.target_id, "m42");
        assert!(best.runnable);
        assert!(best.total_score >= 30.0);
    }

    #[test]
    fn pick_best_respects_min_score_threshold() {
        // Place observer + time so M42 is below its min_altitude floor → the
        // hard runnable filter trips → pick_best returns None regardless of
        // the score threshold. (Mid-summer noon at 40N: M42 culminates well
        // below the horizon.)
        let now = Utc.with_ymd_and_hms(2026, 7, 1, 18, 0, 0).unwrap();
        let observer = ObserverContext {
            latitude_deg: 40.0,
            longitude_deg: -74.0,
            now,
            moon: None,
            moon_illumination: 0.0,
            twilight: None,
            horizon: None,
        };
        let weights = ScoringWeights::default();
        let m42 = TargetInput {
            id: "m42".into(),
            name: "M42".into(),
            ra_deg: 83.82,
            dec_deg: -5.39,
            // Floor of 50° — M42 cannot reach that at lat=40 (transit max ~45°).
            // The runnable check fires before the score threshold even
            // matters.
            min_altitude: Some(50.0),
            start_after: None,
            end_before: None,
            priority: 0,
            completed: false,
        };
        assert!(pick_best(&[m42], &observer, &weights, 50.0).is_none());
    }

    #[test]
    fn completed_targets_are_skipped() {
        let now = Utc.with_ymd_and_hms(2026, 1, 15, 6, 0, 0).unwrap();
        let observer = ObserverContext {
            latitude_deg: 40.0,
            longitude_deg: -74.0,
            now,
            moon: None,
            moon_illumination: 0.0,
            twilight: None,
            horizon: None,
        };
        let weights = ScoringWeights::default();
        let m42 = TargetInput {
            id: "m42".into(),
            name: "M42".into(),
            ra_deg: 83.82,
            dec_deg: -5.39,
            min_altitude: None,
            start_after: None,
            end_before: None,
            priority: 0,
            completed: true,
        };
        let scored = score_target(&m42, &observer, &weights);
        assert!(!scored.runnable);
        assert_eq!(scored.skip_reason.as_deref(), Some("already completed"));
    }

    // Per-azimuth horizon mask

    #[test]
    fn horizon_single_sample_is_flat() {
        let h = HorizonProfile::flat(20.0);
        assert!((h.min_altitude_at(0.0) - 20.0).abs() < 1e-9);
        assert!((h.min_altitude_at(123.0) - 20.0).abs() < 1e-9);
        assert!((h.min_altitude_at(359.0) - 20.0).abs() < 1e-9);
    }

    #[test]
    fn horizon_interpolates_linearly_between_samples() {
        // A wall: 0°→10°, 90°→30°. Halfway (45°) → 20°.
        let h = HorizonProfile::new(vec![
            HorizonSample::new(0.0, 10.0),
            HorizonSample::new(90.0, 30.0),
        ])
        .unwrap();
        assert!((h.min_altitude_at(0.0) - 10.0).abs() < 1e-9);
        assert!((h.min_altitude_at(90.0) - 30.0).abs() < 1e-9);
        assert!(
            (h.min_altitude_at(45.0) - 20.0).abs() < 1e-9,
            "got {}",
            h.min_altitude_at(45.0)
        );
    }

    #[test]
    fn horizon_wraps_around_north() {
        // Samples at 10° and 350° azimuth bracket due-north (0°/360°).
        // 10°→20°, 350°→40°. At az=0 (= 360), it sits 10° past the 350°
        // sample on a 20° span (350→370) → t = 10/20 = 0.5 → 30°.
        let h = HorizonProfile::new(vec![
            HorizonSample::new(10.0, 20.0),
            HorizonSample::new(350.0, 40.0),
        ])
        .unwrap();
        assert!(
            (h.min_altitude_at(0.0) - 30.0).abs() < 1e-9,
            "north wrap got {}",
            h.min_altitude_at(0.0)
        );
    }

    #[test]
    fn horizon_samples_out_of_compass_order_answer_as_sorted_ones() {
        let sorted = HorizonProfile::new(vec![
            HorizonSample::new(30.0, 15.0),
            HorizonSample::new(120.0, 45.0),
            HorizonSample::new(300.0, 25.0),
        ])
        .unwrap();
        let shuffled = HorizonProfile::new(vec![
            HorizonSample::new(300.0, 25.0),
            HorizonSample::new(30.0, 15.0),
            HorizonSample::new(120.0, 45.0),
        ])
        .unwrap();
        for az in [0.0, 29.0, 75.0, 200.0, 359.0] {
            assert_eq!(
                sorted.min_altitude_at(az),
                shuffled.min_altitude_at(az),
                "az {az}"
            );
        }
    }

    #[test]
    fn horizon_empty_samples_rejected() {
        assert!(HorizonProfile::new(vec![]).is_none());
    }

    #[test]
    fn horizon_gate_rejects_target_behind_obstruction() {
        // M42 from 40N at this instant is up (~40°).
        // Build a horizon that is high (60°) at M42's current azimuth so
        // the target is blocked, and verify the skip reason names the
        // azimuth. Then drop the horizon to a low flat 5° and confirm the
        // same target becomes runnable — isolating the gate as the cause.
        let now = Utc.with_ymd_and_hms(2026, 1, 15, 6, 0, 0).unwrap();
        let m42 = TargetInput {
            id: "m42".into(),
            name: "M42".into(),
            ra_deg: 83.82,
            dec_deg: -5.39,
            min_altitude: None,
            start_after: None,
            end_before: None,
            priority: 0,
            completed: false,
        };
        let base = |horizon: Option<HorizonProfile>| ObserverContext {
            latitude_deg: 40.0,
            longitude_deg: -74.0,
            now,
            moon: None,
            moon_illumination: 0.0,
            twilight: None,
            horizon,
        };
        let weights = ScoringWeights::default();

        // First read M42's current altitude/azimuth via an ungated score.
        let probe = score_target(&m42, &base(None), &weights);
        assert!(probe.runnable, "M42 should be up for this fixture");
        let az = probe.current_azimuth_deg;
        let alt = probe.current_altitude_deg;

        // A flat horizon set just ABOVE M42's current altitude blocks it.
        let blocking = HorizonProfile::flat(alt + 5.0);
        let gated = score_target(&m42, &base(Some(blocking)), &weights);
        assert!(
            !gated.runnable,
            "M42 below a {:.1}° horizon must be gated",
            alt + 5.0
        );
        let reason = gated.skip_reason.as_deref().unwrap_or("");
        assert!(reason.contains("altitude floor"), "reason: {reason}");
        assert!(
            reason.contains(&format!("{az:.0}")),
            "skip reason must name the azimuth ({az:.0}); reason: {reason}"
        );

        // A flat horizon BELOW M42's altitude leaves it runnable.
        let clear = HorizonProfile::flat((alt - 5.0).max(0.0));
        let open = score_target(&m42, &base(Some(clear)), &weights);
        assert!(open.runnable, "M42 above the horizon must stay runnable");
    }
}
