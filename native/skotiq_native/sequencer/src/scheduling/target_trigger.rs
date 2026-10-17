//! Per-target start/end trigger primitives.
//!
//! SGP and NINA both support a notion that's missing from Skotiq
//! pre-"start the target *when an altitude crossing happens*, stop
//! when another crossing happens." Today [`crate::TargetHeaderConfig`] only
//! has `start_after` / `end_before` (Unix timestamps) and
//! `min_altitude` / `max_altitude` (instantaneous checks), which can only
//! express "wait until 21:00 OR currently above 35°", not "start the first
//! moment the altitude crosses 35° after 21:00."
//!
//! This module introduces [`TargetTrigger`] — a small expression language
//! the user can attach to a TargetHeader as `start_when` / `end_when`.
//! Each variant is independently testable: given a `TriggerObserverContext`
//! (clock + observer location + target RA/Dec), it returns a boolean
//! ("is this condition true right now?").
//!
//! ### Semantics
//!
//! * `start_when` is a **wait** condition. The TargetHeader runtime polls
//!   `is_satisfied(...)` every `poll_interval` seconds (default 30s) and
//!   only enters its children once the trigger fires. If the trigger is
//!   already true at sequence start, the TargetHeader proceeds without
//!   waiting.
//! * `end_when` is a **stop** condition. Once a polling tick observes the
//!   trigger true, the TargetHeader marks remaining children Skipped and
//!   returns Success.
//!
//! ### Back-compat
//!
//! The legacy `start_after` / `end_before` / `min_altitude` / `max_altitude`
//! fields are kept for serialization back-compat. At load time the runtime
//! translates them into a normalised [`TargetTrigger`] expression via
//! [`TargetTriggerExt::from_legacy_fields`] when an explicit `start_when`
//! / `end_when` is absent. This means existing sequences round-trip without
//! editing.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::meridian::hour_angle;
use crate::scheduling::astronomy::{local_sidereal_time, object_alt_az};

/// One leaf or compound condition that can gate a target's start / end.
///
/// `serde(tag = "kind", content = "value")` keeps the JSON shape
/// `{"kind":"AltitudeAbove","value":35.0}` symmetric to
/// [`crate::FilterBudgetEntry`]'s tag/content encoding so the Dart sealed-
/// class round-trip stays uniform across the project.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "kind", content = "value")]
pub enum TargetTrigger {
    /// Target altitude at the observer is **at or above** the given degrees.
    AltitudeAbove(f64),
    /// Target altitude at the observer is **at or below** the given degrees.
    AltitudeBelow(f64),
    /// Wall-clock time is at or after the given Unix timestamp (seconds).
    TimeAfter(i64),
    /// Wall-clock time is strictly before the given Unix timestamp (seconds).
    TimeBefore(i64),
    /// All of the listed sub-triggers must be satisfied. Empty list is
    /// caught by the [`TargetTriggerEmptyCompoundRule`] validator and is
    /// treated as `false` at runtime so an error config can't silently
    /// short-circuit.
    And(Vec<TargetTrigger>),
    /// At least one of the listed sub-triggers must be satisfied. Empty
    /// list is treated as `false` (same validator + runtime guard).
    Or(Vec<TargetTrigger>),
    /// Hour angle of the target (in hours) lies in `[min_ha, max_ha]`.
    /// HA convention matches [`crate::meridian::hour_angle`] — negative
    /// values east of the meridian, positive west.
    HourAngleBetween {
        /// Minimum hour angle in hours.
        #[serde(rename = "minHa")]
        min_ha: f64,
        /// Maximum hour angle in hours.
        #[serde(rename = "maxHa")]
        max_ha: f64,
    },
}

/// Observer + target + clock snapshot fed into [`TargetTrigger::is_satisfied`].
/// Built once per evaluation; cheap to pass by reference.
#[derive(Debug, Clone)]
pub struct TriggerObserverContext {
    pub latitude_deg: f64,
    pub longitude_deg: f64,
    /// Target right ascension in HOURS (matches `TargetHeaderConfig.ra_hours`).
    pub target_ra_hours: f64,
    /// Target declination in DEGREES (matches `TargetHeaderConfig.dec_degrees`).
    pub target_dec_degrees: f64,
    /// Current wall-clock instant. The TargetHeader runtime reads this from
    /// `ExecutionContext::clock.now_utc()` so tests can pin it.
    pub now: DateTime<Utc>,
}

impl TriggerObserverContext {
    /// Cached altitude in degrees. Used both by `AltitudeAbove` /
    /// `AltitudeBelow` and by the live-preview text in the target row.
    pub fn current_altitude_deg(&self) -> f64 {
        let (alt, _az) = object_alt_az(
            self.target_ra_hours * 15.0,
            self.target_dec_degrees,
            &self.now,
            self.latitude_deg,
            self.longitude_deg,
        );
        alt
    }

    /// Current hour angle in hours.
    pub fn current_hour_angle_hours(&self) -> f64 {
        let lst = local_sidereal_time(&self.now, self.longitude_deg);
        hour_angle(self.target_ra_hours, lst)
    }
}

impl TargetTrigger {
    /// Evaluate this trigger against the given observer snapshot. Returns
    /// `true` when the condition is satisfied right now.
    ///
    /// Errors-are-a-feature: this function never panics and never silently
    /// pretends the condition is met. An empty `And` / `Or` returns
    /// `false` so a misconfigured trigger can never short-circuit the
    /// wait. Validation rules surface the empty-compound case at edit
    /// time.
    pub fn is_satisfied(&self, ctx: &TriggerObserverContext) -> bool {
        match self {
            TargetTrigger::AltitudeAbove(threshold) => ctx.current_altitude_deg() >= *threshold,
            TargetTrigger::AltitudeBelow(threshold) => ctx.current_altitude_deg() <= *threshold,
            TargetTrigger::TimeAfter(ts) => ctx.now.timestamp() >= *ts,
            TargetTrigger::TimeBefore(ts) => ctx.now.timestamp() < *ts,
            TargetTrigger::And(children) => {
                if children.is_empty() {
                    return false;
                }
                children.iter().all(|c| c.is_satisfied(ctx))
            }
            TargetTrigger::Or(children) => {
                if children.is_empty() {
                    return false;
                }
                children.iter().any(|c| c.is_satisfied(ctx))
            }
            TargetTrigger::HourAngleBetween { min_ha, max_ha } => {
                let ha = ctx.current_hour_angle_hours();
                ha >= *min_ha && ha <= *max_ha
            }
        }
    }

    /// True iff this trigger references altitude — used by the validation
    /// layer to surface "this target never reaches that altitude from your
    /// location" errors.
    pub fn references_altitude(&self) -> bool {
        match self {
            TargetTrigger::AltitudeAbove(_) | TargetTrigger::AltitudeBelow(_) => true,
            TargetTrigger::And(v) | TargetTrigger::Or(v) => {
                v.iter().any(|t| t.references_altitude())
            }
            _ => false,
        }
    }

    /// Pull every `AltitudeAbove(N)` threshold out of this expression
    /// (recursively). Used by the [`TargetTriggerImpossibleAltitudeRule`]
    /// validator to find the strictest threshold the target must clear.
    pub fn altitude_above_thresholds(&self, out: &mut Vec<f64>) {
        match self {
            TargetTrigger::AltitudeAbove(n) => out.push(*n),
            TargetTrigger::And(v) | TargetTrigger::Or(v) => {
                for t in v {
                    t.altitude_above_thresholds(out);
                }
            }
            _ => {}
        }
    }

    /// Compound-with-empty-children detector for the validator.
    pub fn has_empty_compound(&self) -> bool {
        match self {
            TargetTrigger::And(v) | TargetTrigger::Or(v) => {
                if v.is_empty() {
                    return true;
                }
                v.iter().any(|t| t.has_empty_compound())
            }
            _ => false,
        }
    }

    /// Human-friendly label used for tracing/logging when the runtime emits
    /// a "still waiting for…" lifecycle event.
    pub fn label(&self) -> String {
        match self {
            TargetTrigger::AltitudeAbove(n) => format!("altitude ≥ {:.1}°", n),
            TargetTrigger::AltitudeBelow(n) => format!("altitude ≤ {:.1}°", n),
            TargetTrigger::TimeAfter(ts) => format!("time ≥ {}", ts),
            TargetTrigger::TimeBefore(ts) => format!("time < {}", ts),
            TargetTrigger::And(v) => format!(
                "({})",
                v.iter().map(Self::label).collect::<Vec<_>>().join(" AND ")
            ),
            TargetTrigger::Or(v) => format!(
                "({})",
                v.iter().map(Self::label).collect::<Vec<_>>().join(" OR ")
            ),
            TargetTrigger::HourAngleBetween { min_ha, max_ha } => {
                format!("{min_ha:.2}h ≤ HA ≤ {max_ha:.2}h")
            }
        }
    }
}

/// Translate the legacy `start_after` / `end_before` / `min_altitude` /
/// `max_altitude` fields into the new trigger model. Returns
/// `(start_when, end_when)`. Used as a fallback in
/// [`crate::TargetHeaderConfig::effective_triggers`] when the explicit
/// fields are absent. Pure function; no side effects.
pub fn legacy_to_triggers(
    start_after: Option<i64>,
    end_before: Option<i64>,
    min_altitude: Option<f64>,
    max_altitude: Option<f64>,
) -> (Option<TargetTrigger>, Option<TargetTrigger>) {
    let mut start_terms: Vec<TargetTrigger> = Vec::new();
    if let Some(ts) = start_after {
        start_terms.push(TargetTrigger::TimeAfter(ts));
    }
    if let Some(alt) = min_altitude {
        start_terms.push(TargetTrigger::AltitudeAbove(alt));
    }
    let start = match start_terms.len() {
        0 => None,
        1 => Some(start_terms.into_iter().next().unwrap()),
        _ => Some(TargetTrigger::And(start_terms)),
    };

    let mut end_terms: Vec<TargetTrigger> = Vec::new();
    if let Some(ts) = end_before {
        end_terms.push(TargetTrigger::TimeAfter(ts));
    }
    if let Some(alt) = max_altitude {
        end_terms.push(TargetTrigger::AltitudeAbove(alt));
    }
    let end = match end_terms.len() {
        0 => None,
        1 => Some(end_terms.into_iter().next().unwrap()),
        _ => Some(TargetTrigger::Or(end_terms)),
    };

    (start, end)
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn ctx_for(now: DateTime<Utc>) -> TriggerObserverContext {
        TriggerObserverContext {
            latitude_deg: 40.0,
            longitude_deg: -74.0,
            // M42, RA=5.59h, Dec=-5.39°
            target_ra_hours: 5.59,
            target_dec_degrees: -5.39,
            now,
        }
    }

    #[test]
    fn time_after_matches_inclusive_lower_bound() {
        let trig = TargetTrigger::TimeAfter(100);
        let mut c = ctx_for(Utc.timestamp_opt(99, 0).unwrap());
        assert!(!trig.is_satisfied(&c));
        c.now = Utc.timestamp_opt(100, 0).unwrap();
        assert!(trig.is_satisfied(&c));
        c.now = Utc.timestamp_opt(200, 0).unwrap();
        assert!(trig.is_satisfied(&c));
    }

    #[test]
    fn time_before_excludes_equal() {
        let trig = TargetTrigger::TimeBefore(100);
        let mut c = ctx_for(Utc.timestamp_opt(99, 0).unwrap());
        assert!(trig.is_satisfied(&c));
        c.now = Utc.timestamp_opt(100, 0).unwrap();
        assert!(!trig.is_satisfied(&c));
    }

    #[test]
    fn altitude_above_below_are_complementary_at_threshold() {
        // Pick a time when M42 is below 35° (mid-summer noon UTC at 40N).
        // We don't depend on the exact altitude — we just assert that
        // AltitudeAbove(35) and AltitudeBelow(35) cannot both be true
        // simultaneously unless the altitude exactly equals 35.
        let summer_noon = Utc.with_ymd_and_hms(2026, 7, 1, 18, 0, 0).unwrap();
        let c = ctx_for(summer_noon);
        let alt = c.current_altitude_deg();
        let above_35 = TargetTrigger::AltitudeAbove(35.0).is_satisfied(&c);
        let below_35 = TargetTrigger::AltitudeBelow(35.0).is_satisfied(&c);
        assert_eq!(above_35, alt >= 35.0);
        assert_eq!(below_35, alt <= 35.0);
    }

    #[test]
    fn and_or_empty_returns_false_not_true() {
        let c = ctx_for(Utc.timestamp_opt(100, 0).unwrap());
        assert!(!TargetTrigger::And(vec![]).is_satisfied(&c));
        assert!(!TargetTrigger::Or(vec![]).is_satisfied(&c));
    }

    #[test]
    fn and_short_circuits_on_false() {
        let c = ctx_for(Utc.timestamp_opt(100, 0).unwrap());
        let trig = TargetTrigger::And(vec![
            TargetTrigger::TimeAfter(50),  // true
            TargetTrigger::TimeBefore(50), // false
            TargetTrigger::TimeAfter(50),  // true
        ]);
        assert!(!trig.is_satisfied(&c));
    }

    #[test]
    fn or_short_circuits_on_true() {
        let c = ctx_for(Utc.timestamp_opt(100, 0).unwrap());
        let trig = TargetTrigger::Or(vec![
            TargetTrigger::TimeBefore(50), // false
            TargetTrigger::TimeAfter(50),  // true
            TargetTrigger::TimeBefore(50), // false
        ]);
        assert!(trig.is_satisfied(&c));
    }

    #[test]
    fn legacy_to_triggers_passes_through_alt_floor() {
        let (start, end) = legacy_to_triggers(None, None, Some(30.0), None);
        assert_eq!(start, Some(TargetTrigger::AltitudeAbove(30.0)));
        assert!(end.is_none());
    }

    #[test]
    fn legacy_to_triggers_combines_time_and_alt_for_start() {
        let (start, end) = legacy_to_triggers(Some(1000), None, Some(35.0), None);
        assert_eq!(
            start,
            Some(TargetTrigger::And(vec![
                TargetTrigger::TimeAfter(1000),
                TargetTrigger::AltitudeAbove(35.0),
            ]))
        );
        assert!(end.is_none());
    }

    #[test]
    fn altitude_above_thresholds_extracts_nested() {
        let trig = TargetTrigger::Or(vec![
            TargetTrigger::AltitudeAbove(20.0),
            TargetTrigger::And(vec![
                TargetTrigger::AltitudeAbove(35.0),
                TargetTrigger::TimeAfter(0),
            ]),
        ]);
        let mut out = Vec::new();
        trig.altitude_above_thresholds(&mut out);
        assert_eq!(out, vec![20.0, 35.0]);
    }

    #[test]
    fn has_empty_compound_detects_nested() {
        let trig = TargetTrigger::Or(vec![
            TargetTrigger::AltitudeAbove(20.0),
            TargetTrigger::And(vec![]),
        ]);
        assert!(trig.has_empty_compound());
        let trig2 = TargetTrigger::Or(vec![TargetTrigger::AltitudeAbove(20.0)]);
        assert!(!trig2.has_empty_compound());
    }

    #[test]
    fn json_round_trip_preserves_compound_shape() {
        let trig = TargetTrigger::And(vec![
            TargetTrigger::TimeAfter(1000),
            TargetTrigger::AltitudeAbove(35.0),
        ]);
        let json = serde_json::to_string(&trig).unwrap();
        let back: TargetTrigger = serde_json::from_str(&json).unwrap();
        assert_eq!(trig, back);
    }
}
