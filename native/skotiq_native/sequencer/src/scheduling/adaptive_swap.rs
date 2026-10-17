//! Sky-conditions-aware adaptive target swap.
//!
//! When transparency / seeing / cloud cover / wind degrade mid-session the
//! `TargetScheduler` consults this module to decide whether the currently-
//! running target is still acceptable for the live conditions and, if not,
//! which lower-tier backup target should be selected instead. The
//! `TransparencyDropped` trigger + `SwitchTargetOrFilter` recovery action
//! provided the trigger-driven half (single-shot, operator-configured backup);
//! this module adds the scheduling-side decision logic so the scheduler can
//! automatically pick a brighter backup any time the composite conditions
//! score falls below the configured threshold, and swap back as conditions
//! recover.
//!
//! ## Brightness tier model
//!
//! Every TargetHeader carries an optional `brightness_tier_hint`:
//!
//! * `Faint` — galaxies, faint nebulae. Needs pristine sky (default ≥ 70).
//! * `Medium` — bright galaxies, medium nebulae. Tolerates degraded sky
//!   (default ≥ 50).
//! * `Bright` — planetary nebulae, open clusters, M-class stars. Tolerates
//!   poor sky (default ≥ 30).
//! * `None` (`Auto`) — the scheduler infers the tier from object brightness
//!   if catalog data is available, otherwise treats the target as `Medium`
//!   so it neither blocks a faint-only session nor steals priority from a
//!   bright backup in poor conditions.
//!
//! The tier->floor mapping is user-tunable via `BrightnessTierPreferences`
//! on `TargetSchedulerConfig` (defaults match the brief).
//!
//! ## Decision flow
//!
//! 1. Read the latest `ConditionsScore` (pushed from Dart via
//!    `ExecutorCommand::UpdateConditionsScore`; the score is the 0..=100
//!    composite of transparency / seeing / clouds / wind).
//! 2. Filter scored candidates to only those whose `brightness_tier` accepts
//!    the live score.
//! 3. If the candidate currently running is still acceptable, prefer it
//!    (no thrashing).
//! 4. Honour `swap_hysteresis_secs`: refuse to swap if the last swap was
//!    too recent.
//! 5. Pick the highest-scoring remaining candidate.
//!
//! ## "No silent fallbacks"
//!
//! When `swap_on_conditions_below` is set but no `ConditionsScore` has been
//! pushed yet, this module returns [`AdaptiveSwapDecision::ConditionsUnknown`]
//! rather than picking blindly — the scheduler treats that as "use the
//! ordinary ranking" and emits a UI-visible breadcrumb so the operator can
//! see that the adaptive layer is idle for telemetry reasons. The same goes
//! for stale scores (older than `max_score_age_secs`).

use serde::{Deserialize, Serialize};
use std::time::{Duration, Instant};

use crate::scheduling::TargetScore;

// Public types

/// Hint on a TargetHeader telling the scheduler which brightness tier this
/// target belongs to. `None` lets the scheduler infer the tier or fall back
/// to [`BrightnessTier::default()`] (Medium).
///
/// Why `Medium` is the default: a target without a tier hint should
/// neither block a faint-only session (which would happen if defaulted to
/// Faint) nor steal priority from a bright backup in poor conditions
/// (which would happen if defaulted to Bright).
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Hash, Default)]
pub enum BrightnessTier {
    /// Galaxies, faint nebulae — needs pristine sky.
    Faint,
    /// Bright galaxies, medium nebulae — tolerates degraded sky.
    #[default]
    Medium,
    /// Planetary nebulae, open clusters — tolerates poor sky.
    Bright,
}

impl BrightnessTier {
    /// Stable wire string used by Dart JSON serialisation. Lowercase to
    /// match the Dart enum convention; we deliberately do NOT use serde's
    /// default PascalCase because the rest of the conditions wire format is
    /// snake_case / lowercase.
    pub fn as_str(&self) -> &'static str {
        match self {
            BrightnessTier::Faint => "faint",
            BrightnessTier::Medium => "medium",
            BrightnessTier::Bright => "bright",
        }
    }

    /// Parse a wire string. Returns `None` for unrecognised values so the
    /// caller can fall back to the default tier — silent acceptance of
    /// junk input would mask schema drift between Rust and Dart. Named
    /// `parse_wire` rather than `from_str` so clippy doesn't confuse it
    /// with `std::str::FromStr`.
    pub fn parse_wire(s: &str) -> Option<Self> {
        match s.to_ascii_lowercase().as_str() {
            "faint" => Some(BrightnessTier::Faint),
            "medium" => Some(BrightnessTier::Medium),
            "bright" => Some(BrightnessTier::Bright),
            _ => None,
        }
    }
}

/// User-tunable conditions-score floors per brightness tier. Defaults match
/// the brief: faint ≥ 70, medium ≥ 50, bright ≥ 30.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
pub struct BrightnessTierPreferences {
    pub faint_min_score: f64,
    pub medium_min_score: f64,
    pub bright_min_score: f64,
}

impl Default for BrightnessTierPreferences {
    fn default() -> Self {
        Self {
            faint_min_score: 70.0,
            medium_min_score: 50.0,
            bright_min_score: 30.0,
        }
    }
}

impl BrightnessTierPreferences {
    /// True when the conditions score meets the floor for the given tier.
    pub fn accepts(&self, tier: BrightnessTier, score: f64) -> bool {
        score >= self.floor_for(tier)
    }

    pub fn floor_for(&self, tier: BrightnessTier) -> f64 {
        match tier {
            BrightnessTier::Faint => self.faint_min_score,
            BrightnessTier::Medium => self.medium_min_score,
            BrightnessTier::Bright => self.bright_min_score,
        }
    }
}

/// Per-axis weights applied when the Dart side composes the conditions
/// score. Mirrored to Rust so the validator + tests can reason about which
/// inputs dominated a decision. Sums to 1.0 by default; the Dart composer
/// re-normalises if the user has nudged the weights.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
pub struct ConditionsScoreWeights {
    pub transparency_weight: f64,
    pub seeing_weight: f64,
    pub cloud_weight: f64,
    pub wind_weight: f64,
}

impl Default for ConditionsScoreWeights {
    fn default() -> Self {
        Self {
            transparency_weight: 0.40,
            seeing_weight: 0.25,
            cloud_weight: 0.25,
            wind_weight: 0.10,
        }
    }
}

impl ConditionsScoreWeights {
    pub fn sum(&self) -> f64 {
        self.transparency_weight + self.seeing_weight + self.cloud_weight + self.wind_weight
    }
}

/// Latest composite conditions score pushed from Dart. Stored alongside
/// the per-axis inputs so the dashboard can render a breakdown and the
/// validator + decision logic can attribute the score to a cause.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ConditionsScore {
    /// 0..=100 composite. 90+ = pristine, 70-90 = good, 50-70 = degraded,
    /// <50 = bad.
    pub score: f64,
    /// Optional per-axis 0..=100 sub-scores. `None` => Dart did not have
    /// that input available; the missing axis is treated as a worst-case
    /// 50 (neutral) inside the composer, but we keep `None` here so the UI
    /// can render "no data" rather than a fake mid-value.
    pub transparency_score: Option<f64>,
    pub seeing_score: Option<f64>,
    pub cloud_score: Option<f64>,
    pub wind_score: Option<f64>,
    /// Weights used by the composer at the time this score was produced.
    /// Mirrored here so a UI tooltip can show the formula.
    pub weights: ConditionsScoreWeights,
    /// Unix epoch seconds at which the Dart side composed this score.
    /// Distinct from the in-process `Instant` because that is not
    /// serialisable.
    pub generated_unix_secs: i64,
}

impl ConditionsScore {
    /// True when the composite score is at or below `threshold`.
    pub fn is_below(&self, threshold: f64) -> bool {
        self.score <= threshold
    }
}

/// Candidate target snapshot consumed by [`pick_target_for_conditions`].
/// One per active TargetHeader child of a TargetScheduler. The struct is
/// deliberately small (no node ownership, no children) so the caller can
/// build it from the scheduler's existing per-decision data without
/// re-walking the tree.
#[derive(Debug, Clone)]
pub struct AdaptiveCandidate<'a> {
    pub target_id: &'a str,
    pub target_name: &'a str,
    pub tier: BrightnessTier,
    /// Score from the normal scheduler ranking (0..=100). Drives the
    /// final pick once the tier filter has been applied.
    pub score: &'a TargetScore,
}

/// Result of an adaptive-swap evaluation.
#[derive(Debug, Clone, PartialEq)]
pub enum AdaptiveSwapDecision {
    /// Adaptive swap is disabled or conditions are above the user's
    /// threshold — defer to the ordinary scheduler ranking.
    Defer,
    /// No conditions score available (or it's stale). The scheduler should
    /// fall back to the ordinary ranking but the dashboard surfaces this as
    /// "telemetry missing" so the operator can intervene.
    ConditionsUnknown { reason: String },
    /// The currently-running target is still acceptable for the live
    /// conditions; no swap needed.
    KeepRunning { target_id: String, reason: String },
    /// Hysteresis blocks a swap — the last swap was too recent. The
    /// scheduler treats this as "keep running"; the dashboard surfaces the
    /// countdown so the operator knows why no swap fired.
    HysteresisCooldown {
        until_swap_allowed_secs: f64,
        candidate_target_id: Option<String>,
    },
    /// Adaptive swap picked a different target. The scheduler should
    /// execute this target on the next decision point.
    Swap {
        target_id: String,
        target_name: String,
        from_target_id: Option<String>,
        reason: String,
        conditions_score: f64,
        tier_floor: f64,
    },
    /// No candidate accepts the live conditions. The scheduler should
    /// emit a structured warning ("no bright targets configured, sequence
    /// will pause"); falling back silently would hide a misconfiguration.
    NoCandidateAcceptable {
        conditions_score: f64,
        considered: Vec<String>,
    },
}

impl AdaptiveSwapDecision {
    pub fn picked_target_id(&self) -> Option<&str> {
        match self {
            AdaptiveSwapDecision::KeepRunning { target_id, .. } => Some(target_id),
            AdaptiveSwapDecision::Swap { target_id, .. } => Some(target_id),
            _ => None,
        }
    }
}

// Decision entry point

/// Pure decision function. Caller supplies:
///
/// * `candidates` — every TargetHeader child of the active TargetScheduler,
///   already scored by the ordinary ranking.
/// * `current_conditions` — the latest pushed [`ConditionsScore`] (None
///   when telemetry hasn't arrived yet).
/// * `currently_running` — id of the target the executor is mid-imaging.
///   `None` on the very first decision or when the previous target
///   completed normally.
/// * `last_swap_at` — wall-clock `Instant` at which the previous adaptive
///   swap fired. Used for hysteresis.
/// * `hysteresis_secs` — refuse to swap more often than every N seconds.
/// * `threshold` — `swap_on_conditions_below`. The decision engine only
///   engages when the score is at or below this value; otherwise it
///   returns `Defer`.
/// * `prefs` — per-tier floors.
/// * `score_now` — used as the reference `Instant` for the hysteresis
///   calculation. Production callers pass `Instant::now()`; tests pin a
///   fixed instant for determinism.
/// * `max_score_age_secs` — score readings older than this are treated
///   as stale (returns `ConditionsUnknown`).
#[allow(clippy::too_many_arguments)]
pub fn pick_target_for_conditions(
    candidates: &[AdaptiveCandidate<'_>],
    current_conditions: Option<&ConditionsScore>,
    currently_running: Option<&str>,
    last_swap_at: Option<Instant>,
    hysteresis_secs: f64,
    threshold: f64,
    prefs: &BrightnessTierPreferences,
    score_now: Instant,
    max_score_age_secs: i64,
) -> AdaptiveSwapDecision {
    let Some(score) = current_conditions else {
        return AdaptiveSwapDecision::ConditionsUnknown {
            reason: "no conditions score has been pushed yet".to_string(),
        };
    };

    // Staleness: the Dart composer should push at least once a minute, so a
    // score older than `max_score_age_secs` (typical 5 min) is treated as
    // missing data. Without this guard a frozen Dart tracker would leave the
    // scheduler swapping based on hours-old transparency.
    let now_unix = chrono::Utc::now().timestamp();
    let score_age = now_unix - score.generated_unix_secs;
    if score_age > max_score_age_secs {
        return AdaptiveSwapDecision::ConditionsUnknown {
            reason: format!(
                "conditions score is {}s old (max {}s); telemetry stale",
                score_age, max_score_age_secs
            ),
        };
    }

    // Above-threshold => defer. The scheduler picks via the ordinary
    // ranking; the dashboard still shows the score for operator awareness.
    if !score.is_below(threshold) {
        return AdaptiveSwapDecision::Defer;
    }

    // Filter candidates whose tier accepts the live score. Keep ordering by
    // `score.total_score` descending so the first acceptable candidate is
    // the highest scorer.
    let mut acceptable: Vec<&AdaptiveCandidate<'_>> = candidates
        .iter()
        .filter(|c| {
            // Skip non-runnable candidates (already-completed targets, below
            // horizon, outside time window). The standard scoring path
            // already marks these `runnable=false` so we trust that signal.
            c.score.runnable && prefs.accepts(c.tier, score.score)
        })
        .collect();
    acceptable.sort_by(|a, b| {
        b.score
            .total_score
            .partial_cmp(&a.score.total_score)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| b.score.priority.cmp(&a.score.priority))
    });

    if acceptable.is_empty() {
        let considered = candidates
            .iter()
            .map(|c| format!("{}({:?})", c.target_name, c.tier))
            .collect();
        return AdaptiveSwapDecision::NoCandidateAcceptable {
            conditions_score: score.score,
            considered,
        };
    }

    // The currently-running target sticks if it's still acceptable. The
    // sort above already promotes the highest-scoring acceptable candidate
    // to the front, so we only check by id — the score gap between "best"
    // and "currently running" is not a justification for thrashing.
    if let Some(running) = currently_running {
        if acceptable.iter().any(|c| c.target_id == running) {
            return AdaptiveSwapDecision::KeepRunning {
                target_id: running.to_string(),
                reason: format!(
                    "current target's tier accepts conditions score {:.1}",
                    score.score,
                ),
            };
        }
    }

    // Honour hysteresis. We compare against the last swap's `Instant` not
    // the live conditions score because the operator's intent is "don't
    // bounce between targets" — even if conditions briefly bobbed back up
    // and now down again, swapping again inside the cooldown produces
    // thrashing.
    if let Some(last) = last_swap_at {
        let elapsed = score_now.saturating_duration_since(last).as_secs_f64();
        if elapsed < hysteresis_secs {
            return AdaptiveSwapDecision::HysteresisCooldown {
                until_swap_allowed_secs: hysteresis_secs - elapsed,
                candidate_target_id: acceptable.first().map(|c| c.target_id.to_string()),
            };
        }
    }

    let winner = acceptable[0];
    let tier_floor = prefs.floor_for(winner.tier);
    AdaptiveSwapDecision::Swap {
        target_id: winner.target_id.to_string(),
        target_name: winner.target_name.to_string(),
        from_target_id: currently_running.map(|s| s.to_string()),
        reason: format!(
            "conditions {:.1} ≤ threshold {:.1}; swapping to {} ({:?}, floor {:.1})",
            score.score, threshold, winner.target_name, winner.tier, tier_floor,
        ),
        conditions_score: score.score,
        tier_floor,
    }
}

/// Helper trait — `Instant::saturating_duration_since` exists in 1.39+ but
/// the rest of the crate uses `checked_duration_since` patterns; this
/// wrapper makes the math explicit and easy to mock.
trait InstantExt {
    fn saturating_duration_since(self, other: Instant) -> Duration;
}

impl InstantExt for Instant {
    fn saturating_duration_since(self, other: Instant) -> Duration {
        self.checked_duration_since(other).unwrap_or_default()
    }
}

// Tests

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scheduling::TargetScore;

    fn ts(id: &str, total: f64, runnable: bool) -> TargetScore {
        TargetScore {
            target_id: id.to_string(),
            target_name: id.to_string(),
            total_score: total,
            altitude_score: total,
            moon_distance_score: 100.0,
            transit_proximity_score: total,
            darkness_score: 100.0,
            airmass_score: total,
            current_altitude_deg: 50.0,
            current_azimuth_deg: 0.0,
            current_airmass: 1.5,
            moon_distance_deg: 90.0,
            runnable,
            skip_reason: None,
            priority: 0,
        }
    }

    fn cs(score: f64) -> ConditionsScore {
        ConditionsScore {
            score,
            transparency_score: Some(score),
            seeing_score: Some(score),
            cloud_score: Some(score),
            wind_score: Some(score),
            weights: ConditionsScoreWeights::default(),
            generated_unix_secs: chrono::Utc::now().timestamp(),
        }
    }

    #[test]
    fn tier_prefs_default_thresholds_match_brief() {
        let p = BrightnessTierPreferences::default();
        assert_eq!(p.floor_for(BrightnessTier::Faint), 70.0);
        assert_eq!(p.floor_for(BrightnessTier::Medium), 50.0);
        assert_eq!(p.floor_for(BrightnessTier::Bright), 30.0);
        assert!(p.accepts(BrightnessTier::Bright, 35.0));
        assert!(!p.accepts(BrightnessTier::Faint, 65.0));
    }

    #[test]
    fn no_conditions_score_returns_unknown() {
        let scores = [ts("m51", 90.0, true)];
        let candidates = [AdaptiveCandidate {
            target_id: "m51",
            target_name: "M51",
            tier: BrightnessTier::Faint,
            score: &scores[0],
        }];
        let dec = pick_target_for_conditions(
            &candidates,
            None,
            None,
            None,
            180.0,
            60.0,
            &BrightnessTierPreferences::default(),
            Instant::now(),
            300,
        );
        assert!(matches!(
            dec,
            AdaptiveSwapDecision::ConditionsUnknown { .. }
        ));
    }

    #[test]
    fn stale_conditions_returns_unknown() {
        let scores = [ts("m51", 90.0, true)];
        let candidates = [AdaptiveCandidate {
            target_id: "m51",
            target_name: "M51",
            tier: BrightnessTier::Faint,
            score: &scores[0],
        }];
        let mut score = cs(80.0);
        // Pretend the reading came in 10 minutes ago.
        score.generated_unix_secs -= 600;
        let dec = pick_target_for_conditions(
            &candidates,
            Some(&score),
            None,
            None,
            180.0,
            60.0,
            &BrightnessTierPreferences::default(),
            Instant::now(),
            // Max age = 5 minutes.
            300,
        );
        assert!(matches!(
            dec,
            AdaptiveSwapDecision::ConditionsUnknown { .. }
        ));
    }

    #[test]
    fn above_threshold_defers_to_ordinary_ranking() {
        let scores = [ts("m51", 90.0, true)];
        let candidates = [AdaptiveCandidate {
            target_id: "m51",
            target_name: "M51",
            tier: BrightnessTier::Faint,
            score: &scores[0],
        }];
        // Conditions 80, threshold 60 => defer.
        let dec = pick_target_for_conditions(
            &candidates,
            Some(&cs(80.0)),
            Some("m51"),
            None,
            180.0,
            60.0,
            &BrightnessTierPreferences::default(),
            Instant::now(),
            300,
        );
        assert_eq!(dec, AdaptiveSwapDecision::Defer);
    }

    #[test]
    fn swaps_faint_galaxy_to_bright_nebula_when_transparency_drops() {
        // The scenario from the brief: M51 (faint) currently running,
        // conditions 45, swap threshold 60. The scheduler should swap to
        // M27 (bright).
        let scores = [
            ts("m51", 88.0, true),
            ts("m27", 70.0, true),
            ts("ngc7000", 60.0, true),
        ];
        let candidates = [
            AdaptiveCandidate {
                target_id: "m51",
                target_name: "M51",
                tier: BrightnessTier::Faint,
                score: &scores[0],
            },
            AdaptiveCandidate {
                target_id: "m27",
                target_name: "M27",
                tier: BrightnessTier::Bright,
                score: &scores[1],
            },
            AdaptiveCandidate {
                target_id: "ngc7000",
                target_name: "NGC 7000",
                tier: BrightnessTier::Medium,
                score: &scores[2],
            },
        ];
        let dec = pick_target_for_conditions(
            &candidates,
            Some(&cs(45.0)),
            Some("m51"),
            None,
            180.0,
            60.0,
            &BrightnessTierPreferences::default(),
            Instant::now(),
            300,
        );
        match dec {
            AdaptiveSwapDecision::Swap {
                target_id,
                target_name,
                from_target_id,
                ..
            } => {
                assert_eq!(target_id, "m27");
                assert_eq!(target_name, "M27");
                assert_eq!(from_target_id.as_deref(), Some("m51"));
            }
            other => panic!("expected Swap, got {:?}", other),
        }
    }

    #[test]
    fn keeps_running_target_when_still_acceptable() {
        // Conditions 65 with medium target running — still inside Medium
        // tier (>=50). Should `KeepRunning` even though no swap is
        // strictly mandated.
        let scores = [ts("ngc7000", 80.0, true), ts("m27", 70.0, true)];
        let candidates = [
            AdaptiveCandidate {
                target_id: "ngc7000",
                target_name: "NGC 7000",
                tier: BrightnessTier::Medium,
                score: &scores[0],
            },
            AdaptiveCandidate {
                target_id: "m27",
                target_name: "M27",
                tier: BrightnessTier::Bright,
                score: &scores[1],
            },
        ];
        let dec = pick_target_for_conditions(
            &candidates,
            Some(&cs(55.0)),
            Some("ngc7000"),
            None,
            180.0,
            60.0,
            &BrightnessTierPreferences::default(),
            Instant::now(),
            300,
        );
        assert!(matches!(dec, AdaptiveSwapDecision::KeepRunning { .. }));
    }

    #[test]
    fn hysteresis_blocks_quick_re_swap() {
        let scores = [ts("m51", 90.0, true), ts("m27", 70.0, true)];
        let candidates = [
            AdaptiveCandidate {
                target_id: "m51",
                target_name: "M51",
                tier: BrightnessTier::Faint,
                score: &scores[0],
            },
            AdaptiveCandidate {
                target_id: "m27",
                target_name: "M27",
                tier: BrightnessTier::Bright,
                score: &scores[1],
            },
        ];
        let now = Instant::now();
        let last_swap = now - Duration::from_secs(30); // 30s ago
        let dec = pick_target_for_conditions(
            &candidates,
            Some(&cs(45.0)),
            Some("m51"),
            Some(last_swap),
            // Hysteresis 180s
            180.0,
            60.0,
            &BrightnessTierPreferences::default(),
            now,
            300,
        );
        match dec {
            AdaptiveSwapDecision::HysteresisCooldown {
                until_swap_allowed_secs,
                candidate_target_id,
            } => {
                assert!(until_swap_allowed_secs > 100.0);
                assert!(until_swap_allowed_secs < 180.0);
                assert_eq!(candidate_target_id.as_deref(), Some("m27"));
            }
            other => panic!("expected HysteresisCooldown, got {:?}", other),
        }
    }

    #[test]
    fn hysteresis_allows_swap_once_cooldown_elapsed() {
        let scores = [ts("m51", 90.0, true), ts("m27", 70.0, true)];
        let candidates = [
            AdaptiveCandidate {
                target_id: "m51",
                target_name: "M51",
                tier: BrightnessTier::Faint,
                score: &scores[0],
            },
            AdaptiveCandidate {
                target_id: "m27",
                target_name: "M27",
                tier: BrightnessTier::Bright,
                score: &scores[1],
            },
        ];
        let now = Instant::now();
        let last_swap = now - Duration::from_secs(300); // 5 min ago
        let dec = pick_target_for_conditions(
            &candidates,
            Some(&cs(45.0)),
            Some("m51"),
            Some(last_swap),
            180.0,
            60.0,
            &BrightnessTierPreferences::default(),
            now,
            300,
        );
        assert!(matches!(dec, AdaptiveSwapDecision::Swap { .. }));
    }

    #[test]
    fn no_candidate_acceptable_returns_no_candidate() {
        let scores = [ts("m51", 90.0, true), ts("ngc7000", 70.0, true)];
        // Two faint/medium candidates, conditions 25 (below even bright
        // floor 30).
        let candidates = [
            AdaptiveCandidate {
                target_id: "m51",
                target_name: "M51",
                tier: BrightnessTier::Faint,
                score: &scores[0],
            },
            AdaptiveCandidate {
                target_id: "ngc7000",
                target_name: "NGC 7000",
                tier: BrightnessTier::Medium,
                score: &scores[1],
            },
        ];
        let dec = pick_target_for_conditions(
            &candidates,
            Some(&cs(25.0)),
            Some("m51"),
            None,
            180.0,
            60.0,
            &BrightnessTierPreferences::default(),
            Instant::now(),
            300,
        );
        match dec {
            AdaptiveSwapDecision::NoCandidateAcceptable {
                conditions_score, ..
            } => {
                assert!((conditions_score - 25.0).abs() < 1e-9);
            }
            other => panic!("expected NoCandidateAcceptable, got {:?}", other),
        }
    }

    #[test]
    fn non_runnable_candidates_are_skipped() {
        // Even if conditions are bad, a non-runnable bright target must not
        // be picked (e.g. below horizon).
        let scores = [
            ts("m51", 88.0, true),
            ts("m27", 70.0, false), // below horizon
        ];
        let candidates = [
            AdaptiveCandidate {
                target_id: "m51",
                target_name: "M51",
                tier: BrightnessTier::Faint,
                score: &scores[0],
            },
            AdaptiveCandidate {
                target_id: "m27",
                target_name: "M27",
                tier: BrightnessTier::Bright,
                score: &scores[1],
            },
        ];
        let dec = pick_target_for_conditions(
            &candidates,
            Some(&cs(40.0)),
            Some("m51"),
            None,
            180.0,
            60.0,
            &BrightnessTierPreferences::default(),
            Instant::now(),
            300,
        );
        assert!(matches!(
            dec,
            AdaptiveSwapDecision::NoCandidateAcceptable { .. }
        ));
    }

    #[test]
    fn conditions_score_weights_default_sums_to_one() {
        let w = ConditionsScoreWeights::default();
        assert!((w.sum() - 1.0).abs() < 1e-9);
    }

    #[test]
    fn brightness_tier_wire_strings_round_trip() {
        for tier in [
            BrightnessTier::Faint,
            BrightnessTier::Medium,
            BrightnessTier::Bright,
        ] {
            let s = tier.as_str();
            assert_eq!(BrightnessTier::parse_wire(s), Some(tier));
            // Case insensitive parse.
            assert_eq!(BrightnessTier::parse_wire(&s.to_uppercase()), Some(tier));
        }
        assert_eq!(BrightnessTier::parse_wire("nonsense"), None);
    }
}
