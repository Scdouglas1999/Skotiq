//! The target scorer for the app: the TargetScheduler step's ranking at an
//! instant (its preview in the sequence editor) and the night score the
//! planner ranks by. Times cross as Unix milliseconds.

use chrono::{DateTime, Utc};
use skotiq_sequencer::scheduling::{
    score_targets, score_targets_for_night, AltitudeFloor, HorizonProfile, HorizonSample,
    NightObserver, NightScore, NightTarget, ObserverContext, ScoringWeights, TargetInput,
    TargetScore,
};

/// The weight of each scoring axis.
#[derive(Debug, Clone, Copy)]
pub struct ApiScoringWeights {
    pub altitude: f64,
    pub moon_distance: f64,
    pub transit_proximity: f64,
    pub darkness: f64,
    pub airmass: f64,
    /// A target nearer than this to an up, lit Moon cannot run.
    pub min_moon_separation_deg: Option<f64>,
}

/// The floor toward one azimuth.
#[derive(Debug, Clone, Copy)]
pub struct ApiFloorSample {
    pub azimuth_deg: f64,
    pub altitude_deg: f64,
}

/// One target of a TargetScheduler step.
#[derive(Debug, Clone)]
pub struct ApiSchedulerTarget {
    pub id: String,
    pub name: String,
    pub ra_hours: f64,
    pub dec_degrees: f64,
    pub min_altitude_deg: Option<f64>,
    pub start_after_unix_secs: Option<i64>,
    pub end_before_unix_secs: Option<i64>,
    pub priority: i32,
}

/// A target's score now, as the step ranks it.
#[derive(Debug, Clone)]
pub struct ApiTargetScoreNow {
    pub target_id: String,
    pub total_score: f64,
    pub altitude_score: f64,
    pub moon_distance_score: f64,
    pub transit_proximity_score: f64,
    pub darkness_score: f64,
    pub airmass_score: f64,
    pub altitude_deg: f64,
    pub azimuth_deg: f64,
    pub airmass: f64,
    pub moon_distance_deg: f64,
    pub runnable: bool,
    /// Why the target cannot run now (`None` when it can).
    pub skip_reason: Option<String>,
}

/// The night being planned.
#[derive(Debug, Clone)]
pub struct ApiNightSky {
    pub latitude_deg: f64,
    pub longitude_deg: f64,
    pub now_unix_ms: i64,
    pub night_start_unix_ms: i64,
    pub night_end_unix_ms: i64,
    /// The Moon for the night in the targets' frame; both or neither.
    pub moon_ra_deg: Option<f64>,
    pub moon_dec_deg: Option<f64>,
    pub moon_illumination_percent: f64,
    /// The floor by azimuth; empty counts from the horizon.
    pub floor: Vec<ApiFloorSample>,
}

/// A catalog position to score over the night: J2000, RA in degrees.
#[derive(Debug, Clone)]
pub struct ApiNightTarget {
    pub id: String,
    pub ra_deg: f64,
    pub dec_deg: f64,
}

/// One target's night score and the figures behind it. Rise and set times
/// are not among them: the app shows those by its own visibility rule.
#[derive(Debug, Clone)]
pub struct ApiNightScore {
    pub target_id: String,
    pub total_score: f64,
    pub altitude_score: f64,
    pub moon_distance_score: f64,
    pub transit_proximity_score: f64,
    pub darkness_score: f64,
    pub airmass_score: f64,
    pub current_altitude_deg: f64,
    pub current_azimuth_deg: f64,
    pub peak_altitude_deg: f64,
    pub peak_azimuth_deg: f64,
    pub peak_unix_ms: i64,
    pub hours_above_floor: f64,
    pub first_usable_unix_ms: Option<i64>,
    /// `None` when the target never clears the floor.
    pub best_airmass: Option<f64>,
    pub moon_distance_deg: f64,
}

/// Rank a TargetScheduler step's targets at `now_unix_ms` exactly as the step
/// does when it decides: runnable first, then by score, then by priority.
/// `floor` is the step's own horizon when it has one, else the site's floor.
#[flutter_rust_bridge::frb(sync)]
pub fn api_rank_scheduler_targets(
    latitude_deg: f64,
    longitude_deg: f64,
    now_unix_ms: i64,
    targets: Vec<ApiSchedulerTarget>,
    weights: ApiScoringWeights,
    floor: Vec<ApiFloorSample>,
) -> Vec<ApiTargetScoreNow> {
    let observer = ObserverContext::at_site(
        latitude_deg,
        longitude_deg,
        instant(now_unix_ms),
        profile(floor),
    );
    let inputs: Vec<TargetInput> = targets
        .into_iter()
        .map(|t| TargetInput {
            id: t.id,
            name: t.name,
            ra_deg: t.ra_hours * 15.0,
            dec_deg: t.dec_degrees,
            min_altitude: t.min_altitude_deg,
            start_after: t.start_after_unix_secs,
            end_before: t.end_before_unix_secs,
            priority: t.priority,
            completed: false,
        })
        .collect();
    score_targets(&inputs, &observer, &weights.into())
        .into_iter()
        .map(ApiTargetScoreNow::from)
        .collect()
}

/// Score catalog positions over one night, in input order, keeping only the
/// targets that stand above the floor at some point of it: a target that is
/// never usable tonight is never a recommendation, and a catalog ranking
/// would otherwise send back thousands of them.
pub async fn api_score_targets_for_night(
    sky: ApiNightSky,
    targets: Vec<ApiNightTarget>,
    weights: ApiScoringWeights,
) -> Vec<ApiNightScore> {
    let observer = NightObserver {
        latitude_deg: sky.latitude_deg,
        longitude_deg: sky.longitude_deg,
        now: instant(sky.now_unix_ms),
        night_start: instant(sky.night_start_unix_ms),
        night_end: instant(sky.night_end_unix_ms),
        moon: sky.moon_ra_deg.zip(sky.moon_dec_deg),
        moon_illumination: sky.moon_illumination_percent,
        floor: profile(sky.floor).map(AltitudeFloor::new),
    };
    let targets: Vec<NightTarget> = targets
        .into_iter()
        .map(|t| NightTarget {
            id: t.id,
            ra_deg: t.ra_deg,
            dec_deg: t.dec_deg,
        })
        .collect();
    score_targets_for_night(&targets, &observer, &weights.into())
        .into_iter()
        .filter(|score| score.hours_above_floor > 0.0)
        .map(ApiNightScore::from)
        .collect()
}

fn instant(unix_ms: i64) -> DateTime<Utc> {
    DateTime::from_timestamp_millis(unix_ms).unwrap_or_default()
}

fn profile(floor: Vec<ApiFloorSample>) -> Option<HorizonProfile> {
    HorizonProfile::new(
        floor
            .into_iter()
            .map(|s| HorizonSample::new(s.azimuth_deg, s.altitude_deg))
            .collect(),
    )
}

impl From<ApiScoringWeights> for ScoringWeights {
    fn from(w: ApiScoringWeights) -> Self {
        Self {
            altitude_weight: w.altitude,
            moon_distance_weight: w.moon_distance,
            transit_proximity_weight: w.transit_proximity,
            darkness_weight: w.darkness,
            airmass_weight: w.airmass,
            min_moon_separation_deg: w.min_moon_separation_deg,
        }
    }
}

impl From<TargetScore> for ApiTargetScoreNow {
    fn from(s: TargetScore) -> Self {
        Self {
            target_id: s.target_id,
            total_score: s.total_score,
            altitude_score: s.altitude_score,
            moon_distance_score: s.moon_distance_score,
            transit_proximity_score: s.transit_proximity_score,
            darkness_score: s.darkness_score,
            airmass_score: s.airmass_score,
            altitude_deg: s.current_altitude_deg,
            azimuth_deg: s.current_azimuth_deg,
            airmass: s.current_airmass,
            moon_distance_deg: s.moon_distance_deg,
            runnable: s.runnable,
            skip_reason: s.skip_reason,
        }
    }
}

impl From<NightScore> for ApiNightScore {
    fn from(s: NightScore) -> Self {
        let ms = |t: DateTime<Utc>| t.timestamp_millis();
        Self {
            target_id: s.target_id,
            total_score: s.total_score,
            altitude_score: s.altitude_score,
            moon_distance_score: s.moon_distance_score,
            transit_proximity_score: s.transit_proximity_score,
            darkness_score: s.darkness_score,
            airmass_score: s.airmass_score,
            current_altitude_deg: s.current_altitude_deg,
            current_azimuth_deg: s.current_azimuth_deg,
            peak_altitude_deg: s.peak_altitude_deg,
            peak_azimuth_deg: s.peak_azimuth_deg,
            peak_unix_ms: ms(s.peak_time),
            hours_above_floor: s.hours_above_floor,
            first_usable_unix_ms: s.first_usable_time.map(ms),
            best_airmass: s.best_airmass.is_finite().then_some(s.best_airmass),
            moon_distance_deg: s.moon_distance_deg,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn weights() -> ApiScoringWeights {
        ApiScoringWeights {
            altitude: 0.25,
            moon_distance: 0.25,
            transit_proximity: 0.20,
            darkness: 0.15,
            airmass: 0.15,
            min_moon_separation_deg: None,
        }
    }

    fn m42() -> ApiSchedulerTarget {
        ApiSchedulerTarget {
            id: "m42".into(),
            name: "M42".into(),
            ra_hours: 83.82 / 15.0,
            dec_degrees: -5.39,
            min_altitude_deg: None,
            start_after_unix_secs: None,
            end_before_unix_secs: None,
            priority: 0,
        }
    }

    // 2026-01-15 06:00 UTC: M42 stands about 40 degrees up from 40N 74W.
    const JAN_15_0600_MS: i64 = 1_768_456_800_000;

    #[test]
    fn the_preview_holds_targets_to_the_floor_it_is_given() {
        let open = api_rank_scheduler_targets(40.0, -74.0, JAN_15_0600_MS, vec![m42()], weights(), vec![]);
        assert!(open[0].runnable, "{:?}", open[0]);
        let wall = vec![ApiFloorSample {
            azimuth_deg: 0.0,
            altitude_deg: 80.0,
        }];
        let blocked = api_rank_scheduler_targets(40.0, -74.0, JAN_15_0600_MS, vec![m42()], weights(), wall);
        assert!(!blocked[0].runnable);
        assert!(blocked[0]
            .skip_reason
            .as_deref()
            .is_some_and(|r| r.contains("horizon")));
    }

    #[tokio::test]
    async fn a_night_ranking_leaves_out_targets_never_usable_tonight() {
        let sky = ApiNightSky {
            latitude_deg: 40.0,
            longitude_deg: -74.0,
            now_unix_ms: JAN_15_0600_MS,
            night_start_unix_ms: JAN_15_0600_MS - 7 * 3_600_000,
            night_end_unix_ms: JAN_15_0600_MS + 5 * 3_600_000,
            moon_ra_deg: None,
            moon_dec_deg: None,
            moon_illumination_percent: 0.0,
            floor: vec![],
        };
        let targets = vec![
            ApiNightTarget {
                id: "m42".into(),
                ra_deg: 83.82,
                dec_deg: -5.39,
            },
            ApiNightTarget {
                id: "south-pole".into(),
                ra_deg: 0.0,
                dec_deg: -89.0,
            },
        ];
        let scores = api_score_targets_for_night(sky, targets, weights()).await;
        let ids: Vec<&str> = scores.iter().map(|s| s.target_id.as_str()).collect();
        assert_eq!(ids, ["m42"]);
    }

    #[test]
    fn the_preview_ranks_as_the_step_does() {
        let now = instant(JAN_15_0600_MS);
        let observer = ObserverContext::at_site(40.0, -74.0, now, None);
        let mut low = m42();
        low.id = "low".into();
        low.dec_degrees = -40.0;
        let api = api_rank_scheduler_targets(
            40.0,
            -74.0,
            JAN_15_0600_MS,
            vec![low.clone(), m42()],
            weights(),
            vec![],
        );
        let step = score_targets(
            &[low, m42()]
                .into_iter()
                .map(|t| TargetInput {
                    id: t.id,
                    name: t.name,
                    ra_deg: t.ra_hours * 15.0,
                    dec_deg: t.dec_degrees,
                    min_altitude: None,
                    start_after: None,
                    end_before: None,
                    priority: 0,
                    completed: false,
                })
                .collect::<Vec<_>>(),
            &observer,
            &weights().into(),
        );
        let api_order: Vec<&str> = api.iter().map(|s| s.target_id.as_str()).collect();
        let step_order: Vec<&str> = step.iter().map(|s| s.target_id.as_str()).collect();
        assert_eq!(api_order, step_order);
        assert_eq!(api[0].total_score, step[0].total_score);
    }
}
