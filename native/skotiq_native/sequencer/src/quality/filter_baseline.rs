//! Rolling per-target, per-filter baselines for the relative grading checks.
//!
//! A frame is judged against the frames of its own target and filter that
//! were accepted just before it, not against the first frames of the night:
//! a target imaged from low altitude gives far fewer stars than the same
//! field near the meridian, so a baseline fixed from the first frames is
//! either too lenient later (a trailed frame keeps "90%" of a low-altitude
//! count) or too strict early. The baseline is the median of the last
//! [`BASELINE_WINDOW`] accepted frames, which one odd frame cannot move, and
//! the star counts are scaled to the airmass of the frame being judged.
//!
//! Rejected frames never enter a baseline, so a run of bad frames (cloud,
//! trees, a dead guider) is judged against the good sky before it.

use std::collections::{HashMap, VecDeque};

/// Accepted frames a baseline is the median of.
pub const BASELINE_WINDOW: usize = 5;

/// Accepted frames a filter needs before its baseline exists.
pub const BASELINE_MIN_SAMPLES: usize = 3;

/// How fast the detected star count falls with airmass: `count(X)` is taken
/// as proportional to `exp(-k * X)`. Extinction and the brighter sky lower in
/// the sky both cut the count; on the owner's 10" Newtonian the LRGB counts
/// roughly doubled between airmass 1.55 and 1.03 (NGC 891, 2026-10-24), which
/// is k of about 1.3 with focus and seeing changes mixed in. 1.0 keeps the
/// correction on the conservative side of that.
pub const STAR_COUNT_EXTINCTION_PER_AIRMASS: f64 = 1.0;

/// Airmass from apparent altitude (Kasten and Young 1989). `None` below the
/// horizon or for a non-finite altitude.
pub fn airmass(altitude_deg: f64) -> Option<f64> {
    if !altitude_deg.is_finite() || altitude_deg <= 0.0 {
        return None;
    }
    let alt = altitude_deg.min(90.0);
    Some(1.0 / (alt.to_radians().sin() + 0.50572 * (alt + 6.07995).powf(-1.6364)))
}

#[derive(Debug, Clone, Copy, PartialEq)]
struct Sample {
    star_count: Option<u32>,
    hfr: Option<f64>,
    airmass: Option<f64>,
}

/// One light frame's star shape, for the per-side eccentricity baseline.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ShapeSample {
    pub eccentricity: f64,
    /// Long-axis direction (degrees, `[0, 180)`) and how well the frame's
    /// stars agree on it (0 to 1).
    pub elongation: Option<(f64, f64)>,
    /// The guider's RMS while the frame exposed, guide-camera pixels.
    pub guiding_rms: Option<f64>,
}

/// The rolling baseline of one target and filter.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct FilterBaseline {
    samples: VecDeque<Sample>,
    /// Recent star shapes on each side of the pier. Every measured light
    /// frame enters, rejected or not: the eccentricity is what a reject is
    /// judged on, so leaving rejects out would hide the very change these
    /// samples are kept to see.
    east_shapes: VecDeque<ShapeSample>,
    west_shapes: VecDeque<ShapeSample>,
    /// The pier side whose eccentricity change has been reported.
    shape_change_reported_on: Option<crate::PierSide>,
}

impl FilterBaseline {
    /// Add an accepted frame. A zero star count or a non-positive HFR is not
    /// a measurement of the sky and is left out.
    pub fn record(&mut self, star_count: Option<u32>, hfr: Option<f64>, altitude_deg: Option<f64>) {
        let sample = Sample {
            star_count: star_count.filter(|&c| c > 0),
            hfr: hfr.filter(|h| h.is_finite() && *h > 0.0),
            airmass: altitude_deg.and_then(airmass),
        };
        if sample.star_count.is_none() && sample.hfr.is_none() {
            return;
        }
        self.samples.push_back(sample);
        while self.samples.len() > BASELINE_WINDOW {
            self.samples.pop_front();
        }
    }

    /// The star count expected of a frame at `altitude_deg`: the median of the
    /// recent accepted counts, each scaled from its own airmass to this one.
    /// Without an altitude (or a sample without one) the counts are used as
    /// measured.
    pub fn star_count_at(&self, altitude_deg: Option<f64>) -> Option<f64> {
        let target_airmass = altitude_deg.and_then(airmass);
        let scaled: Vec<f64> = self
            .samples
            .iter()
            .filter_map(|s| {
                let count = f64::from(s.star_count?);
                Some(match (target_airmass, s.airmass) {
                    (Some(x), Some(xi)) => {
                        count * (-STAR_COUNT_EXTINCTION_PER_AIRMASS * (x - xi)).exp()
                    }
                    _ => count,
                })
            })
            .collect();
        median_of(scaled)
    }

    /// The median HFR of the recent accepted frames.
    pub fn hfr(&self) -> Option<f64> {
        median_of(self.samples.iter().filter_map(|s| s.hfr).collect())
    }

    fn shapes(&self, side: crate::PierSide) -> Option<&VecDeque<ShapeSample>> {
        match side {
            crate::PierSide::East => Some(&self.east_shapes),
            crate::PierSide::West => Some(&self.west_shapes),
            crate::PierSide::Unknown => None,
        }
    }

    /// Add a measured light frame's shape on `side`. A side the mount cannot
    /// report keeps no baseline.
    pub fn record_shape(&mut self, side: crate::PierSide, sample: ShapeSample) {
        if !sample.eccentricity.is_finite() {
            return;
        }
        let shapes = match side {
            crate::PierSide::East => &mut self.east_shapes,
            crate::PierSide::West => &mut self.west_shapes,
            crate::PierSide::Unknown => return,
        };
        shapes.push_back(sample);
        while shapes.len() > BASELINE_WINDOW {
            shapes.pop_front();
        }
    }

    /// Median eccentricity of the recent frames on `side`.
    pub fn eccentricity_on(&self, side: crate::PierSide) -> Option<f64> {
        median_of(self.shapes(side)?.iter().map(|s| s.eccentricity).collect())
    }

    /// Median guiding RMS of the recent frames on `side`.
    pub fn guiding_rms_on(&self, side: crate::PierSide) -> Option<f64> {
        median_of(
            self.shapes(side)?
                .iter()
                .filter_map(|s| s.guiding_rms)
                .collect(),
        )
    }

    /// Mean long-axis direction of the recent frames on `side` and how well
    /// the frames agree on it (0 to 1), each frame weighted by how well its
    /// own stars agree.
    pub fn elongation_on(&self, side: crate::PierSide) -> Option<(f64, f64)> {
        let frames: Vec<(f64, f64)> = self
            .shapes(side)?
            .iter()
            .filter_map(|s| s.elongation)
            .collect();
        if frames.len() < BASELINE_MIN_SAMPLES {
            return None;
        }
        let (mut c, mut s, mut w) = (0.0, 0.0, 0.0);
        for (angle, consistency) in frames {
            let doubled = (2.0 * angle).to_radians();
            c += consistency * doubled.cos();
            s += consistency * doubled.sin();
            w += consistency;
        }
        if w <= 0.0 {
            return None;
        }
        Some((
            (0.5 * s.atan2(c).to_degrees()).rem_euclid(180.0),
            (c.hypot(s) / w).clamp(0.0, 1.0),
        ))
    }
}

/// A rise in median eccentricity on the new pier side, over the other side,
/// that counts as stars more elongated than before the flip.
pub const ECCENTRICITY_RISE: f64 = 0.08;

/// Guiding counts as worse on the new side when its RMS is this many times
/// the other side's.
const GUIDING_WORSE_RATIO: f64 = 1.15;

/// Frames agree on an elongation direction when their mean resultant is at
/// least this long.
const CONSISTENT_DIRECTION: f64 = 0.7;

/// After a pier-side change, compare each filter of `target` on `side` with
/// the other side and, the first time the stars of at least one filter are
/// clearly more elongated, say what the evidence points to. `None` until
/// every filter with frames on both sides has a baseline on both, or when
/// nothing rose, or when it was already reported for this side.
pub fn diagnose_shape_change(
    baselines: &mut HashMap<String, FilterBaseline>,
    target: Option<&str>,
    side: crate::PierSide,
) -> Option<String> {
    let other = match side {
        crate::PierSide::East => crate::PierSide::West,
        crate::PierSide::West => crate::PierSide::East,
        crate::PierSide::Unknown => return None,
    };
    let prefix = filter_baseline_key(target, None);
    struct FilterChange {
        filter: String,
        before: f64,
        after: f64,
    }
    let mut compared: Vec<FilterChange> = Vec::new();
    let mut rms_before = Vec::new();
    let mut rms_after = Vec::new();
    let mut directions: Vec<(f64, f64)> = Vec::new();
    for (key, baseline) in baselines.iter() {
        let Some(filter) = key.strip_prefix(&prefix) else {
            continue;
        };
        if baseline.shape_change_reported_on == Some(side) {
            return None;
        }
        let has_before = baseline.shapes(other).is_some_and(|s| !s.is_empty());
        let has_after = baseline.shapes(side).is_some_and(|s| !s.is_empty());
        if !(has_before && has_after) {
            continue;
        }
        // A filter part-way into its new-side frames: wait for it, so a
        // filter is never called unchanged before it has been measured.
        let (Some(before), Some(after)) = (
            baseline.eccentricity_on(other),
            baseline.eccentricity_on(side),
        ) else {
            return None;
        };
        rms_before.extend(baseline.guiding_rms_on(other));
        rms_after.extend(baseline.guiding_rms_on(side));
        if after - before >= ECCENTRICITY_RISE {
            directions.extend(baseline.elongation_on(side));
        }
        compared.push(FilterChange {
            filter: if filter.is_empty() {
                "no filter".to_string()
            } else {
                filter.to_string()
            },
            before,
            after,
        });
    }
    compared.sort_by(|a, b| a.filter.cmp(&b.filter));
    let (risen, steady): (Vec<&FilterChange>, Vec<&FilterChange>) = compared
        .iter()
        .partition(|change| change.after - change.before >= ECCENTRICITY_RISE);
    if risen.is_empty() {
        return None;
    }
    for (key, baseline) in baselines.iter_mut() {
        if key.starts_with(&prefix) {
            baseline.shape_change_reported_on = Some(side);
        }
    }

    let side_name = |side: crate::PierSide| match side {
        crate::PierSide::East => "east",
        crate::PierSide::West => "west",
        crate::PierSide::Unknown => "unknown",
    };
    let list = |changes: &[&FilterChange]| {
        changes
            .iter()
            .map(|c| format!("{} {:.2} to {:.2}", c.filter, c.before, c.after))
            .collect::<Vec<_>>()
            .join(", ")
    };
    let mean = |values: &[f64]| {
        (!values.is_empty()).then(|| values.iter().sum::<f64>() / values.len() as f64)
    };
    let guiding = match (mean(&rms_before), mean(&rms_after)) {
        (Some(before), Some(after)) => Some((before, after)),
        _ => None,
    };
    let guiding_worse = guiding.is_some_and(|(before, after)| after > before * GUIDING_WORSE_RATIO);
    let direction = {
        let (mut c, mut s, mut w) = (0.0, 0.0, 0.0);
        for &(angle, consistency) in &directions {
            let doubled = (2.0 * angle).to_radians();
            c += consistency * doubled.cos();
            s += consistency * doubled.sin();
            w += consistency;
        }
        (w > 0.0
            && c.hypot(s) / w >= CONSISTENT_DIRECTION
            && directions
                .iter()
                .all(|&(_, consistency)| consistency >= CONSISTENT_DIRECTION))
        .then(|| (0.5 * s.atan2(c).to_degrees()).rem_euclid(180.0))
    };

    let mut message = format!(
        "Stars are more elongated on the {} side of the pier than on the {} side: eccentricity {}",
        side_name(side),
        side_name(other),
        list(&risen)
    );
    if !steady.is_empty() {
        message.push_str(&format!(", but not {}", list(&steady)));
    }
    message.push('.');
    if let Some((before, after)) = guiding {
        message.push_str(&format!(
            " Guiding RMS went from {before:.2} px to {after:.2} px{}.",
            if guiding_worse {
                ", worse than before"
            } else {
                ""
            }
        ));
    }
    if let Some(angle) = direction {
        message.push_str(&format!(
            " The stars are stretched the same way in every frame (about {angle:.0} degrees in the image)."
        ));
    }
    let cause = if guiding_worse {
        " Guiding is worse on this side, so balance or guiding on this side is the likely cause: \
         check the balance and the guiding."
    } else if !steady.is_empty() {
        " Guiding is no worse, and only some filters changed, so the cause is likely in the \
         imaging train (focus, tilt or flexure) rather than guiding: set per-filter focus \
         offsets, or refocus after the flip."
    } else {
        " Guiding is no worse, so the cause is likely in the imaging train (focus, tilt or \
         flexure) rather than guiding: refocus after the flip, and check the camera and focuser \
         for flexure."
    };
    message.push_str(cause);
    message.push_str(" Frames past the limit are only marked; the run carries on.");
    Some(message)
}

fn median_of(mut values: Vec<f64>) -> Option<f64> {
    if values.len() < BASELINE_MIN_SAMPLES {
        return None;
    }
    values.sort_by(f64::total_cmp);
    let mid = values.len() / 2;
    Some(if values.len() % 2 == 1 {
        values[mid]
    } else {
        (values[mid - 1] + values[mid]) / 2.0
    })
}

/// The baselines of a run, one per target and filter.
pub type FilterBaselines = std::sync::Arc<tokio::sync::RwLock<HashMap<String, FilterBaseline>>>;

/// Key of a frame's baseline.
pub fn filter_baseline_key(target: Option<&str>, filter: Option<&str>) -> String {
    format!("{}\u{1f}{}", target.unwrap_or(""), filter.unwrap_or(""))
}

/// The two baselines a frame of `key` at `altitude_deg` is graded against:
/// (HFR, star count).
pub async fn baselines_for(
    baselines: &FilterBaselines,
    key: &str,
    altitude_deg: Option<f64>,
) -> (Option<f64>, Option<f64>) {
    let guard = baselines.read().await;
    match guard.get(key) {
        Some(baseline) => (baseline.hfr(), baseline.star_count_at(altitude_deg)),
        None => (None, None),
    }
}

/// Add an accepted frame to its baseline.
pub async fn record_accepted(
    baselines: &FilterBaselines,
    key: String,
    star_count: Option<u32>,
    hfr: Option<f64>,
    altitude_deg: Option<f64>,
) {
    baselines
        .write()
        .await
        .entry(key)
        .or_default()
        .record(star_count, hfr, altitude_deg);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn airmass_is_one_at_the_zenith_and_grows_toward_the_horizon() {
        assert!((airmass(90.0).unwrap() - 1.0).abs() < 1e-3);
        assert!((airmass(30.0).unwrap() - 1.995).abs() < 0.01);
        assert_eq!(airmass(0.0), None);
        assert_eq!(airmass(-5.0), None);
    }

    #[test]
    fn no_baseline_until_three_accepted_frames() {
        let mut b = FilterBaseline::default();
        b.record(Some(2000), Some(2.0), None);
        b.record(Some(2100), Some(2.1), None);
        assert_eq!(b.star_count_at(None), None);
        assert_eq!(b.hfr(), None);
        b.record(Some(1900), Some(1.9), None);
        assert_eq!(b.star_count_at(None), Some(2000.0));
        assert_eq!(b.hfr(), Some(2.0));
    }

    #[test]
    fn the_baseline_follows_the_last_five_accepted_frames() {
        let mut b = FilterBaseline::default();
        // One early low-altitude frame and two more before the field rises.
        for count in [965, 1000, 1060] {
            b.record(Some(count), None, None);
        }
        assert_eq!(b.star_count_at(None), Some(1000.0));
        for count in [2000, 2050, 2100, 2080, 2030] {
            b.record(Some(count), None, None);
        }
        assert_eq!(b.star_count_at(None), Some(2050.0));
    }

    #[test]
    fn counts_are_scaled_to_the_airmass_of_the_frame_being_judged() {
        let mut b = FilterBaseline::default();
        for _ in 0..3 {
            b.record(Some(2000), None, Some(80.0));
        }
        let near_zenith = b.star_count_at(Some(80.0)).unwrap();
        let low = b.star_count_at(Some(30.0)).unwrap();
        assert!((near_zenith - 2000.0).abs() < 1e-9);
        assert!(low < 0.4 * near_zenith, "{low}");
    }

    #[test]
    fn zero_counts_and_missing_measurements_are_not_samples() {
        let mut b = FilterBaseline::default();
        b.record(Some(0), None, None);
        b.record(None, Some(f64::NAN), None);
        b.record(None, Some(-1.0), None);
        assert_eq!(b.samples.len(), 0);
    }

    fn shape(eccentricity: f64, angle: f64, rms: f64) -> ShapeSample {
        ShapeSample {
            eccentricity,
            elongation: Some((angle, 0.9)),
            guiding_rms: Some(rms),
        }
    }

    /// The night of 2026-10-24/25 on NGC 891: after the flip to the east side
    /// R, G and L stars stretched (rejects R 6, G 4, L 4, B 0) along one
    /// direction while guiding was no worse (west 0.86-1.06, east
    /// 0.79-0.86). The evidence points at the imaging train, not guiding.
    #[test]
    fn a_per_filter_rise_after_the_flip_with_steady_guiding_points_at_the_imaging_train() {
        use crate::PierSide::{East, West};
        let mut baselines: HashMap<String, FilterBaseline> = HashMap::new();
        let west = [("L", 0.60), ("R", 0.61), ("G", 0.60), ("B", 0.62)];
        let east = [("L", 0.72), ("R", 0.80), ("G", 0.79), ("B", 0.63)];
        for (filter, w) in west.iter() {
            let b = baselines
                .entry(filter_baseline_key(Some("NGC0891"), Some(filter)))
                .or_default();
            for (i, rms) in [0.86, 1.06, 0.95].into_iter().enumerate() {
                b.record_shape(West, shape(*w + 0.01 * (i as f64 - 1.0), 170.0, rms));
            }
        }
        // Part-way through the east frames nothing is said yet.
        for (filter, e) in east {
            let b = baselines
                .get_mut(&filter_baseline_key(Some("NGC0891"), Some(filter)))
                .unwrap();
            b.record_shape(East, shape(e, 32.0, 0.82));
        }
        assert_eq!(
            diagnose_shape_change(&mut baselines, Some("NGC0891"), East),
            None
        );
        for _ in 0..2 {
            for (filter, e) in east {
                let b = baselines
                    .get_mut(&filter_baseline_key(Some("NGC0891"), Some(filter)))
                    .unwrap();
                b.record_shape(East, shape(e, 35.0, 0.80));
            }
        }

        let message = diagnose_shape_change(&mut baselines, Some("NGC0891"), East)
            .expect("the rise is reported");
        assert!(message.contains("R 0.61 to 0.80"), "{message}");
        assert!(message.contains("G 0.60 to 0.79"), "{message}");
        assert!(message.contains("but not B"), "{message}");
        assert!(message.contains("imaging train"), "{message}");
        assert!(message.contains("per-filter focus offsets"), "{message}");
        assert!(message.contains("refocus after the flip"), "{message}");
        assert!(message.contains("same way in every frame"), "{message}");
        assert!(!message.contains("worse than before"), "{message}");
        assert!(message.contains("only marked"), "{message}");
        assert_eq!(
            diagnose_shape_change(&mut baselines, Some("NGC0891"), East),
            None,
            "told once per side"
        );
    }

    #[test]
    fn a_rise_on_every_filter_with_worse_guiding_points_at_guiding() {
        use crate::PierSide::{East, West};
        let mut baselines: HashMap<String, FilterBaseline> = HashMap::new();
        for filter in ["R", "G"] {
            let b = baselines
                .entry(filter_baseline_key(Some("M31"), Some(filter)))
                .or_default();
            for _ in 0..3 {
                b.record_shape(West, shape(0.55, 10.0, 0.6));
                b.record_shape(East, shape(0.75, 80.0, 1.2));
            }
        }
        let message = diagnose_shape_change(&mut baselines, Some("M31"), East).expect("reported");
        assert!(message.contains("worse than before"), "{message}");
        assert!(message.contains("balance or guiding"), "{message}");
    }

    #[test]
    fn no_change_across_the_flip_is_not_reported() {
        use crate::PierSide::{East, West};
        let mut baselines: HashMap<String, FilterBaseline> = HashMap::new();
        let b = baselines
            .entry(filter_baseline_key(Some("M31"), Some("L")))
            .or_default();
        for _ in 0..3 {
            b.record_shape(West, shape(0.6, 10.0, 0.6));
            b.record_shape(East, shape(0.63, 10.0, 0.6));
        }
        assert_eq!(
            diagnose_shape_change(&mut baselines, Some("M31"), East),
            None
        );
    }
}
