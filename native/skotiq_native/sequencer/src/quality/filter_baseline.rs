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

/// The rolling baseline of one target and filter.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct FilterBaseline {
    samples: VecDeque<Sample>,
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
}
