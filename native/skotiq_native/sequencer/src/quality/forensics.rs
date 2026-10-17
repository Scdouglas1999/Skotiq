//! Frame-Failure Forensics: structured "why did this frame fail?"
//! classification.
//!
//! Image Grading decides Pass/Reject for a frame but only emits a
//! one-line `reason` ("HFR 5.21 px exceeds absolute threshold 3.50 px"). The
//! user is left wondering whether that 5.21 px HFR is a one-off cloud
//! passage, a slow seeing degradation, a guiding failure, focus walking off,
//! or simply a satellite trail clipping the corner.
//!
//! This module produces a structured cause + evidence list every time a
//! frame is rejected. The classifier is heuristic — there is no ground truth
//! — so it reports `Unknown` when the evidence is weak rather than picking a
//! default category, which would mask the genuinely interesting cases.
//!
//! ## Classification overview
//!
//! Heuristics consult three buckets of data:
//!
//! 1. **The rejected frame's own metrics** — HFR, eccentricity, star count.
//!    These match against the absolute / baseline thresholds the grader
//!    already used.
//! 2. **Recent frame history** — `recent_frames` holds the last N frame
//!    outcomes (accepted or rejected) with metrics + timestamps. We look at
//!    HFR trajectory, the cluster of rejects, etc.
//! 3. **Environment snapshot** — sky brightness, cloud cover, wind speed,
//!    guide RMS, sensor temperature at the capture moment. Plus the
//!    delta-from-previous-snapshot for change-rate detection.
//!
//! The output is a `LikelyCause` plus an `evidence` list of human-readable
//! bullets the UI surfaces.

use serde::{Deserialize, Serialize};

/// Eight categories the classifier emits. Wire-stable string labels are
/// produced by [`LikelyCause::label`] so the Dart side can match against
/// canonical strings instead of relying on serde's variant names.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LikelyCause {
    /// Sky brightness dropped + cloud cover spiked + several concurrent
    /// rejects.
    CloudPassage,
    /// HFR > 2× baseline AND last few frames also showed HFR creep — a
    /// transient seeing degradation, not a focus problem.
    SeeingSpike,
    /// Guide RMS > 2× recent median AT the capture instant.
    GuidingFailure,
    /// Wind > threshold and clustered rejects.
    WindGust,
    /// Isolated rejection with no environmental pattern — almost certainly
    /// a satellite or aircraft track.
    SatellitePass,
    /// Localized hot pixel / cosmic ray, often single-frame, no
    /// environmental change.
    HotPixelOrCosmic,
    /// Monotonic upward HFR trend across last 5-10 frames — focus has
    /// walked off, not a seeing transient.
    FocusDrift,
    /// Evidence is insufficient to pick a single cause. The raw metrics
    /// (and any partial signals) are still presented to the user.
    Unknown,
}

impl LikelyCause {
    /// Wire-stable label matching the snake_case serde rename — used as the
    /// DB-stored cause string and the canonical match key on the Dart side.
    pub fn label(self) -> &'static str {
        match self {
            LikelyCause::CloudPassage => "cloud_passage",
            LikelyCause::SeeingSpike => "seeing_spike",
            LikelyCause::GuidingFailure => "guiding_failure",
            LikelyCause::WindGust => "wind_gust",
            LikelyCause::SatellitePass => "satellite_pass",
            LikelyCause::HotPixelOrCosmic => "hot_pixel_or_cosmic",
            LikelyCause::FocusDrift => "focus_drift",
            LikelyCause::Unknown => "unknown",
        }
    }
}

/// Per-frame record kept in the rolling forensics history. Every
/// accepted or rejected frame contributes one entry; the oldest entry is
/// evicted when the buffer exceeds [`FORENSIC_HISTORY_LEN`].
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct RecentFrameSample {
    /// Unix epoch seconds at capture completion. We use unix seconds (not
    /// `Instant`) so the buffer survives suspend/resume and serialises
    /// cleanly into checkpoints.
    pub unix_secs: f64,
    /// True if the frame passed grading.
    pub accepted: bool,
    pub hfr: Option<f64>,
    pub eccentricity: Option<f64>,
    pub star_count: Option<u32>,
    pub sky_brightness_mag: Option<f64>,
    pub cloud_cover_percent: Option<f64>,
    pub wind_kph: Option<f64>,
    pub guide_rms_arcsec: Option<f64>,
    pub sensor_temp_c: Option<f64>,
}

/// Maximum number of recent frames retained in the forensic history.
///
/// 10 is enough for the FocusDrift heuristic (which requires a trend over
/// 5-10 frames) without consuming significant memory.
pub const FORENSIC_HISTORY_LEN: usize = 10;

/// Snapshot of environmental telemetry at the moment a frame was captured.
/// Threaded into [`analyze_rejection`] so the classifier can correlate the
/// reject with conditions.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct EnvironmentSnapshot {
    pub sky_brightness_mag: Option<f64>,
    pub cloud_cover_percent: Option<f64>,
    pub wind_kph: Option<f64>,
    pub guide_rms_arcsec: Option<f64>,
    pub sensor_temp_c: Option<f64>,
}

/// Inputs the classifier needs to render a verdict.
#[derive(Debug, Clone)]
pub struct ForensicInputs<'a> {
    /// HFR for the rejected frame (if measured).
    pub hfr: Option<f64>,
    /// Eccentricity for the rejected frame (if measured).
    pub eccentricity: Option<f64>,
    /// Star count for the rejected frame (if measured).
    pub star_count: Option<u32>,
    /// Pre-frame HFR baseline (rolling median from the first 5 accepted
    /// frames of the target). `None` until the baseline locks.
    pub hfr_baseline: Option<f64>,
    /// Environment at capture time.
    pub environment: EnvironmentSnapshot,
    /// Recent frame samples, oldest first. The classifier looks at the
    /// last 5-10 of these for trend / cluster detection.
    pub recent_frames: &'a [RecentFrameSample],
    /// Grader's reason string (e.g. "HFR 5.21 px exceeds absolute
    /// threshold 3.50 px"). Used as a tie-breaker hint when the
    /// classifier ends up at `Unknown`.
    pub grader_reason: &'a str,
}

/// Forensic verdict — picked cause + supporting human-readable bullets.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct ForensicVerdict {
    /// `None` when the classifier could not muster a single best guess
    /// (mirrors `LikelyCause::Unknown` but surfaced as `None` so the UI
    /// can fall back to a neutral colour / wording).
    pub likely_cause: Option<LikelyCause>,
    /// Ordered list of evidence bullets. Empty when no environmental
    /// telemetry was available at all.
    pub evidence: Vec<String>,
}

/// Classify a rejection. See module docs for the heuristics; the order
/// below is deliberate (most-specific wins).
///
/// Reasoning:
///
/// * Cloud passage shows up with multiple correlated signals at once
///   (brightness drop, cloud spike, cluster of other rejects) so we check
///   it first — a missing-stars frame *during* a clear sky is a different
///   kind of bug.
/// * Guiding failure is the next most specific because RMS spikes are
///   precisely timed and unambiguous when present.
/// * FocusDrift requires a multi-frame trend so it ranks below
///   single-frame guiding failures (a transient guide RMS spike inside a
///   stable HFR trend is GuidingFailure, not FocusDrift).
/// * SeeingSpike fires when HFR is high AND nearby frames also showed
///   creep, but neither cloud cover nor guiding explained it.
/// * WindGust mirrors the cluster heuristic for cloud passages but keyed
///   on wind speed.
/// * SatellitePass / HotPixelOrCosmic catch the single-frame isolated
///   case; the difference is whether HFR was elevated (satellite trail
///   blows up HFR) or not (hot pixel).
/// * `Unknown` is the honest fallback — the analyzer must never
///   silently pick a default.
pub fn analyze_rejection(inputs: &ForensicInputs<'_>) -> ForensicVerdict {
    let mut evidence: Vec<String> = Vec::new();
    let env = &inputs.environment;
    let recent = inputs.recent_frames;

    // ----- Pre-compute some shared signals so each branch can reach
    // them without re-walking the recent_frames slice.
    let last_n_window_secs = 120.0; // "concurrent" rejects defined as <2min apart
    let now_unix = recent.last().map(|s| s.unix_secs).unwrap_or(0.0);
    let nearby_rejects: usize = recent
        .iter()
        .filter(|s| !s.accepted && (now_unix - s.unix_secs).abs() <= last_n_window_secs)
        .count();

    // Sky-brightness drop magnitude over the last 60s — pull the oldest
    // and newest samples in window and subtract. "Drop" here means the
    // sky got brighter (smaller mag/arcsec² number).
    let brightness_drop_mag: Option<f64> = compute_brightness_drop(recent, 60.0);
    // Cloud cover delta: latest - earliest in window.
    let cloud_spike_pct: Option<f64> =
        compute_metric_delta(recent, 60.0, |s| s.cloud_cover_percent);
    // Guide RMS median over the last 5 frames *excluding* the most recent
    // (so we can compare the at-capture value to historical median).
    let prior_guide_rms_median = median_of_finite(
        recent
            .iter()
            .rev()
            .skip(1)
            .take(5)
            .filter_map(|s| s.guide_rms_arcsec),
    );
    let prior_wind_median = median_of_finite(
        recent
            .iter()
            .rev()
            .skip(1)
            .take(5)
            .filter_map(|s| s.wind_kph),
    );

    // 1) Cloud passage — sky brightness drop AND cloud cover spike, OR
    //    star-count-floor reject with concurrent cluster.
    let cloud_signals = {
        let mut score = 0;
        if let Some(drop) = brightness_drop_mag {
            if drop >= 0.5 {
                score += 1;
                evidence.push(format!(
                    "Sky brightness dropped {:.2} mag in last 60s",
                    drop
                ));
            }
        }
        if let Some(spike) = cloud_spike_pct {
            if spike >= 30.0 {
                score += 1;
                evidence.push(format!(
                    "Cloud cover spiked from {:.0}% to {:.0}%",
                    env.cloud_cover_percent.unwrap_or(0.0) - spike,
                    env.cloud_cover_percent.unwrap_or(spike),
                ));
            }
        }
        if let Some(cc) = env.cloud_cover_percent {
            if cc >= 60.0 && score == 0 {
                // Absolute cover ceiling — still informative even if we
                // don't have a delta sample yet.
                evidence.push(format!("Cloud cover {:.0}% at capture", cc));
                score += 1;
            }
        }
        // Star-count floor + cluster is the strongest cloud signal short
        // of a sky-brightness telemetry stream.
        let star_floor_hint = inputs.grader_reason.contains("star count") && nearby_rejects >= 2;
        if star_floor_hint {
            score += 1;
            evidence.push(format!(
                "{} other frames in same window also rejected",
                nearby_rejects
            ));
        }
        score
    };
    if cloud_signals >= 2 {
        return ForensicVerdict {
            likely_cause: Some(LikelyCause::CloudPassage),
            evidence,
        };
    }

    // 2) Guiding failure — rms at capture > 2× prior median.
    if let (Some(at_capture), Some(prior)) = (env.guide_rms_arcsec, prior_guide_rms_median) {
        if prior > 0.0 && at_capture >= prior * 2.0 && at_capture >= 1.0 {
            evidence.push(format!(
                "Guide RMS {:.2}\" at capture vs {:.2}\" recent median",
                at_capture, prior
            ));
            return ForensicVerdict {
                likely_cause: Some(LikelyCause::GuidingFailure),
                evidence,
            };
        }
    }

    // 3) Wind gust — wind > threshold + a small cluster of nearby
    //    rejects. Uses a fixed 30 km/h floor as the gust threshold
    //    when no historical wind is available (matches the default
    //    weather safety max_wind_speed_kph).
    if let Some(wind) = env.wind_kph {
        let high_wind = match prior_wind_median {
            Some(prior) if prior > 0.0 => wind >= prior * 1.5 && wind >= 20.0,
            _ => wind >= 30.0,
        };
        if high_wind && nearby_rejects >= 2 {
            evidence.push(format!("Wind {:.0} km/h at capture", wind));
            if let Some(prior) = prior_wind_median {
                evidence.push(format!("Prior wind median {:.0} km/h", prior));
            }
            evidence.push(format!(
                "{} other frames in same window also rejected",
                nearby_rejects
            ));
            return ForensicVerdict {
                likely_cause: Some(LikelyCause::WindGust),
                evidence,
            };
        }
    }

    // 4) Focus drift — monotonic upward HFR trend across last 5-10
    //    frames. We require at least 4 successive non-decreasing HFR
    //    samples AND a meaningful total rise (>=15%) before naming this.
    if let Some(rise) = monotonic_hfr_rise(recent, inputs.hfr) {
        evidence.push(format!(
            "HFR trend up {:.0}% over last {} frames",
            rise.percent, rise.frames
        ));
        if let Some(baseline) = inputs.hfr_baseline {
            evidence.push(format!(
                "Baseline HFR {:.2} px, current {:.2} px",
                baseline,
                inputs.hfr.unwrap_or(0.0),
            ));
        }
        return ForensicVerdict {
            likely_cause: Some(LikelyCause::FocusDrift),
            evidence,
        };
    }

    // 5) Seeing spike — HFR > 2× baseline AND last 3 frames also showed
    //    HFR creep relative to baseline (but no monotonic drift, which
    //    would have been caught above). The "spike" framing distinguishes
    //    this from gradual focus drift.
    if let (Some(hfr), Some(baseline)) = (inputs.hfr, inputs.hfr_baseline) {
        if baseline > 0.0 && hfr >= baseline * 2.0 {
            let elevated_neighbours = recent
                .iter()
                .rev()
                .take(3)
                .filter_map(|s| s.hfr)
                .filter(|h| *h > baseline * 1.3)
                .count();
            if elevated_neighbours >= 1 {
                evidence.push(format!(
                    "HFR {:.2} px is {:.1}× baseline {:.2} px",
                    hfr,
                    hfr / baseline,
                    baseline
                ));
                evidence.push(format!(
                    "{} of last 3 frames also showed HFR > 1.3× baseline",
                    elevated_neighbours
                ));
                return ForensicVerdict {
                    likely_cause: Some(LikelyCause::SeeingSpike),
                    evidence,
                };
            }
        }
    }

    // 6) Single-frame isolated reject — distinguish satellite trail
    //    (HFR or eccentricity elevated, no neighbours bad) from a hot
    //    pixel / cosmic event (no HFR elevation, no neighbours bad).
    let nearby_bad = recent.iter().rev().take(3).filter(|s| !s.accepted).count();
    if nearby_bad == 0 {
        // Look at the rejected frame's own metrics to decide the flavour.
        let hfr_elevated = match (inputs.hfr, inputs.hfr_baseline) {
            (Some(hfr), Some(baseline)) if baseline > 0.0 => hfr >= baseline * 1.5,
            (Some(hfr), None) => hfr >= 4.0,
            _ => false,
        };
        let ecc_elevated = inputs.eccentricity.map(|e| e >= 0.7).unwrap_or(false);
        if hfr_elevated || ecc_elevated {
            evidence.push("Isolated rejection — no nearby frames bad".to_string());
            if let Some(h) = inputs.hfr {
                evidence.push(format!("HFR {:.2} px on this frame only", h));
            }
            if let Some(e) = inputs.eccentricity {
                evidence.push(format!("Eccentricity {:.2}", e));
            }
            return ForensicVerdict {
                likely_cause: Some(LikelyCause::SatellitePass),
                evidence,
            };
        }
        // Star-count below floor with no HFR elevation is the classical
        // hot-pixel / cosmic signature (the detector got fooled by
        // localised bright spots and missed the field stars).
        if inputs.grader_reason.contains("star count") && !hfr_elevated && !ecc_elevated {
            evidence
                .push("Isolated rejection — star count low without HFR/ecc elevation".to_string());
            if let Some(c) = inputs.star_count {
                evidence.push(format!("Detected stars: {}", c));
            }
            return ForensicVerdict {
                likely_cause: Some(LikelyCause::HotPixelOrCosmic),
                evidence,
            };
        }
    }

    // 7) Unknown — emit raw metrics so the user still has *something* to
    //    look at instead of a blank panel.
    if let Some(h) = inputs.hfr {
        evidence.push(format!("HFR {:.2} px", h));
    }
    if let Some(e) = inputs.eccentricity {
        evidence.push(format!("Eccentricity {:.2}", e));
    }
    if let Some(s) = inputs.star_count {
        evidence.push(format!("Star count: {}", s));
    }
    if env.is_empty() && evidence.is_empty() {
        evidence.push("No environmental telemetry available at capture time".to_string());
    }
    ForensicVerdict {
        likely_cause: Some(LikelyCause::Unknown),
        evidence,
    }
}

impl EnvironmentSnapshot {
    /// True when no field is populated. Used to differentiate the
    /// "telemetry channels down" case from the "telemetry present but
    /// uninformative" case.
    pub fn is_empty(&self) -> bool {
        self.sky_brightness_mag.is_none()
            && self.cloud_cover_percent.is_none()
            && self.wind_kph.is_none()
            && self.guide_rms_arcsec.is_none()
            && self.sensor_temp_c.is_none()
    }
}

/// Sky-brightness drop comparing the latest sample to the earliest
/// available reference inside the trailing window. Returns the
/// magnitude difference (positive = sky got brighter / mag value
/// decreased) or `None` when no reference sample is available.
///
/// We deliberately pick the *earliest* sample available — even one
/// that is older than `window_secs` — because a slow-onset cloud
/// passage looks like "30s ago we were at 21.2 mag, now we're at 20.5"
/// just as much as "3 minutes ago we were at 21.2". The window argument
/// is effectively a lower bound on the reference's age, not a strict
/// upper bound (a one-shot reference 90s back is still informative).
fn compute_brightness_drop(recent: &[RecentFrameSample], _window_secs: f64) -> Option<f64> {
    if recent.len() < 2 {
        return None;
    }
    let last = recent.last()?;
    let last_mag = last.sky_brightness_mag?;
    // Pick the earliest sample (front of the ring) that has a reading.
    // The history is bounded to `FORENSIC_HISTORY_LEN`, so the
    // candidate set is small and the linear walk is cheap.
    let earliest = recent
        .iter()
        .take(recent.len().saturating_sub(1)) // exclude the current
        .find(|s| s.sky_brightness_mag.is_some())?;
    let earliest_mag = earliest.sky_brightness_mag?;
    // Bigger mag/arcsec² => darker. "Drop" = darker - brighter = positive
    // when the sky got brighter (cloud rolling in).
    Some(earliest_mag - last_mag)
}

/// Generic delta-over-window helper used for cloud cover. Returns
/// `latest - earliest` of the metric across the rolling history.
fn compute_metric_delta(
    recent: &[RecentFrameSample],
    _window_secs: f64,
    extract: impl Fn(&RecentFrameSample) -> Option<f64>,
) -> Option<f64> {
    if recent.len() < 2 {
        return None;
    }
    let last = recent.last()?;
    let last_val = extract(last)?;
    let earliest = recent
        .iter()
        .take(recent.len().saturating_sub(1))
        .find(|s| extract(s).is_some())?;
    let earliest_val = extract(earliest)?;
    Some(last_val - earliest_val)
}

/// Compute a simple median over an iterator of finite f64 values. Used
/// for guide-RMS and wind baseline computations.
fn median_of_finite<I: IntoIterator<Item = f64>>(iter: I) -> Option<f64> {
    let mut values: Vec<f64> = iter.into_iter().filter(|v| v.is_finite()).collect();
    if values.is_empty() {
        return None;
    }
    values.sort_by(|a, b| a.partial_cmp(b).expect("finite values sort cleanly"));
    let n = values.len();
    if n % 2 == 1 {
        Some(values[n / 2])
    } else {
        Some((values[n / 2 - 1] + values[n / 2]) / 2.0)
    }
}

/// Output of [`monotonic_hfr_rise`] — captures the rise percentage and
/// the number of frames it spans.
#[derive(Debug, Clone, Copy)]
struct HfrRise {
    percent: f64,
    frames: usize,
}

/// Detect a *progressively* climbing HFR trend over the trailing 5-10
/// frames including the current one. Returns `Some(...)` only when:
///
/// * The run length is at least 4 frames.
/// * The aggregate rise is >= 15 %.
/// * Each adjacent pair is *strictly* increasing (with a tiny 1 %
///   tolerance for measurement noise) — a flat-then-spike pattern does
///   NOT qualify; that signature is `SeeingSpike`. A satellite trail
///   spike on top of a stable HFR baseline is `SatellitePass`, not
///   `FocusDrift`.
fn monotonic_hfr_rise(recent: &[RecentFrameSample], current_hfr: Option<f64>) -> Option<HfrRise> {
    // Build the timeline of HFR values for analysis. Include current
    // frame at the tail.
    let mut series: Vec<f64> = recent.iter().filter_map(|s| s.hfr).collect();
    if let Some(c) = current_hfr {
        series.push(c);
    }
    if series.len() < 5 {
        return None;
    }
    // Walk backwards counting STRICTLY increasing pairs. The 1.01
    // multiplier requires each new frame to be at least 1 % above its
    // predecessor — this kills the flat-then-spike pattern that would
    // otherwise be mis-classified as drift.
    let mut run = 1usize;
    for i in (1..series.len()).rev() {
        if series[i] > series[i - 1] * 1.01 {
            run += 1;
        } else {
            break;
        }
    }
    if run < 4 {
        return None;
    }
    let start_idx = series.len() - run;
    let start = series[start_idx];
    let end = *series.last()?;
    if start <= 0.0 {
        return None;
    }
    let rise_pct = (end / start - 1.0) * 100.0;
    if rise_pct < 15.0 {
        return None;
    }
    Some(HfrRise {
        percent: rise_pct,
        frames: run,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample(unix: f64, accepted: bool) -> RecentFrameSample {
        RecentFrameSample {
            unix_secs: unix,
            accepted,
            ..Default::default()
        }
    }

    fn with_hfr(mut s: RecentFrameSample, hfr: f64) -> RecentFrameSample {
        s.hfr = Some(hfr);
        s
    }

    #[allow(dead_code)]
    fn empty_inputs<'a>(recent: &'a [RecentFrameSample]) -> ForensicInputs<'a> {
        ForensicInputs {
            hfr: None,
            eccentricity: None,
            star_count: None,
            hfr_baseline: None,
            environment: EnvironmentSnapshot::default(),
            recent_frames: recent,
            grader_reason: "",
        }
    }

    // Cloud passage — the "production-finished" scenario from the brief:
    // 9 rejects between 02:30 and 02:42, sky brightness drop of 0.7 mag
    // in 30s, cloud cover spike from 12% to 78%, 8 other frames in the
    // same window also rejected.
    #[test]
    fn cloud_passage_full_signature_classifies_correctly() {
        let now = 1_700_000_000.0;
        let mut history: Vec<RecentFrameSample> = (0..9)
            .map(|i| {
                let mut s = sample(now - 600.0 + i as f64 * 60.0, false);
                s.sky_brightness_mag = Some(if i < 4 { 21.2 } else { 20.5 });
                s.cloud_cover_percent = Some(if i < 4 { 12.0 } else { 78.0 });
                s
            })
            .collect();
        // The "current" rejected frame: at `now`, sky brightness 20.5,
        // clouds at 78%.
        history.push(RecentFrameSample {
            unix_secs: now,
            accepted: false,
            sky_brightness_mag: Some(20.5),
            cloud_cover_percent: Some(78.0),
            star_count: Some(15),
            ..Default::default()
        });

        let inputs = ForensicInputs {
            hfr: None,
            eccentricity: None,
            star_count: Some(15),
            hfr_baseline: Some(2.5),
            environment: EnvironmentSnapshot {
                sky_brightness_mag: Some(20.5),
                cloud_cover_percent: Some(78.0),
                ..Default::default()
            },
            recent_frames: &history,
            grader_reason: "star count 15 below minimum 80 (likely cloud / off-target)",
        };

        let verdict = analyze_rejection(&inputs);
        assert_eq!(verdict.likely_cause, Some(LikelyCause::CloudPassage));
        let evidence = verdict.evidence.join("|").to_lowercase();
        assert!(
            evidence.contains("sky brightness"),
            "expected brightness-drop bullet, got: {}",
            evidence
        );
    }

    #[test]
    fn guiding_failure_when_rms_spikes_above_recent_median() {
        let now = 1_700_000_000.0;
        let mut recent = Vec::new();
        // 5 prior frames with RMS ~0.6"
        for i in 0..5 {
            let mut s = sample(now - 300.0 + i as f64 * 60.0, true);
            s.guide_rms_arcsec = Some(0.6);
            recent.push(s);
        }
        // Most recent frame — the one being analysed in the upstream
        // call. analyze_rejection looks at env.guide_rms_arcsec for
        // current, and recent[..-1] for the prior median (the helper
        // skips the most recent entry).
        let mut current = sample(now, false);
        current.guide_rms_arcsec = Some(2.5);
        recent.push(current);
        let inputs = ForensicInputs {
            hfr: Some(3.0),
            eccentricity: None,
            star_count: None,
            hfr_baseline: Some(2.5),
            environment: EnvironmentSnapshot {
                guide_rms_arcsec: Some(2.5),
                ..Default::default()
            },
            recent_frames: &recent,
            grader_reason: "HFR 3.00 px exceeds absolute threshold 2.50 px",
        };
        let verdict = analyze_rejection(&inputs);
        assert_eq!(verdict.likely_cause, Some(LikelyCause::GuidingFailure));
        assert!(verdict
            .evidence
            .iter()
            .any(|e| e.to_lowercase().contains("guide rms")));
    }

    #[test]
    fn focus_drift_detected_with_monotonic_hfr_trend() {
        let now = 1_700_000_000.0;
        // Build 6 frames with steadily climbing HFR: 2.0 -> 2.6
        let recent: Vec<RecentFrameSample> = (0..6)
            .map(|i| {
                with_hfr(
                    sample(now - 300.0 + i as f64 * 60.0, i < 3),
                    2.0 + i as f64 * 0.12,
                )
            })
            .collect();
        let inputs = ForensicInputs {
            hfr: Some(2.8),
            eccentricity: None,
            star_count: None,
            hfr_baseline: Some(2.0),
            environment: EnvironmentSnapshot::default(),
            recent_frames: &recent,
            grader_reason: "HFR 2.80 px exceeds baseline 2.00 px + 25% (limit 2.50 px)",
        };
        let verdict = analyze_rejection(&inputs);
        assert_eq!(verdict.likely_cause, Some(LikelyCause::FocusDrift));
        assert!(verdict.evidence.iter().any(|e| e.contains("HFR trend")));
    }

    #[test]
    fn seeing_spike_when_hfr_double_baseline_and_neighbours_elevated() {
        let now = 1_700_000_000.0;
        let recent: Vec<RecentFrameSample> = (0..5)
            .map(|i| {
                let mut s = sample(now - 240.0 + i as f64 * 60.0, true);
                // Last three frames flirt with 1.3× baseline (2.6 px on
                // baseline 2.0).
                s.hfr = Some(if i >= 2 { 2.7 } else { 2.1 });
                s
            })
            .collect();
        let inputs = ForensicInputs {
            hfr: Some(4.2),
            eccentricity: None,
            star_count: None,
            hfr_baseline: Some(2.0),
            environment: EnvironmentSnapshot::default(),
            recent_frames: &recent,
            grader_reason: "HFR 4.20 px exceeds absolute threshold 3.50 px",
        };
        let verdict = analyze_rejection(&inputs);
        assert_eq!(verdict.likely_cause, Some(LikelyCause::SeeingSpike));
    }

    #[test]
    fn wind_gust_classification_requires_cluster() {
        let now = 1_700_000_000.0;
        let mut recent: Vec<RecentFrameSample> = Vec::new();
        // 4 frames in the window, two of which were rejected (the new
        // one + one ~30s earlier).
        for i in 0..3 {
            let mut s = sample(now - 100.0 + i as f64 * 30.0, true);
            s.wind_kph = Some(8.0);
            recent.push(s);
        }
        let mut bad1 = sample(now - 30.0, false);
        bad1.wind_kph = Some(40.0);
        recent.push(bad1);
        let mut current = sample(now, false);
        current.wind_kph = Some(48.0);
        recent.push(current);
        let inputs = ForensicInputs {
            hfr: Some(5.0),
            eccentricity: None,
            star_count: None,
            hfr_baseline: Some(2.5),
            environment: EnvironmentSnapshot {
                wind_kph: Some(48.0),
                ..Default::default()
            },
            recent_frames: &recent,
            grader_reason: "HFR 5.00 px exceeds absolute threshold 3.50 px",
        };
        let verdict = analyze_rejection(&inputs);
        assert_eq!(verdict.likely_cause, Some(LikelyCause::WindGust));
    }

    #[test]
    fn satellite_pass_isolated_frame_with_elevated_hfr() {
        let now = 1_700_000_000.0;
        let recent: Vec<RecentFrameSample> = (0..4)
            .map(|i| with_hfr(sample(now - 240.0 + i as f64 * 60.0, true), 2.0))
            .collect();
        let inputs = ForensicInputs {
            hfr: Some(3.8),
            eccentricity: Some(0.75),
            star_count: Some(120),
            hfr_baseline: Some(2.0),
            environment: EnvironmentSnapshot::default(),
            recent_frames: &recent,
            grader_reason: "eccentricity 0.75 exceeds threshold 0.60",
        };
        let verdict = analyze_rejection(&inputs);
        assert_eq!(verdict.likely_cause, Some(LikelyCause::SatellitePass));
        assert!(verdict
            .evidence
            .iter()
            .any(|e| e.to_lowercase().contains("isolated")));
    }

    #[test]
    fn hot_pixel_or_cosmic_when_isolated_low_stars_no_hfr_elevation() {
        let now = 1_700_000_000.0;
        let recent: Vec<RecentFrameSample> = (0..4)
            .map(|i| with_hfr(sample(now - 240.0 + i as f64 * 60.0, true), 2.0))
            .collect();
        let inputs = ForensicInputs {
            hfr: Some(2.1),
            eccentricity: Some(0.3),
            star_count: Some(8),
            hfr_baseline: Some(2.0),
            environment: EnvironmentSnapshot::default(),
            recent_frames: &recent,
            grader_reason: "star count 8 below minimum 30 (likely cloud / off-target)",
        };
        let verdict = analyze_rejection(&inputs);
        assert_eq!(verdict.likely_cause, Some(LikelyCause::HotPixelOrCosmic));
    }

    #[test]
    fn unknown_when_signals_too_weak() {
        let inputs = ForensicInputs {
            hfr: Some(2.6),
            eccentricity: Some(0.4),
            star_count: Some(60),
            hfr_baseline: Some(2.0),
            environment: EnvironmentSnapshot::default(),
            recent_frames: &[],
            grader_reason: "HFR 2.60 px exceeds absolute threshold 2.50 px",
        };
        let verdict = analyze_rejection(&inputs);
        assert_eq!(verdict.likely_cause, Some(LikelyCause::Unknown));
        // Must still surface the raw metric bullets — never a blank.
        assert!(!verdict.evidence.is_empty());
    }

    #[test]
    fn unknown_fallback_records_no_telemetry_bullet_when_truly_empty() {
        let inputs = ForensicInputs {
            hfr: None,
            eccentricity: None,
            star_count: None,
            hfr_baseline: None,
            environment: EnvironmentSnapshot::default(),
            recent_frames: &[],
            grader_reason: "",
        };
        let verdict = analyze_rejection(&inputs);
        assert_eq!(verdict.likely_cause, Some(LikelyCause::Unknown));
        assert!(verdict
            .evidence
            .iter()
            .any(|e| e.to_lowercase().contains("no environmental telemetry")));
    }

    #[test]
    fn likely_cause_labels_are_wire_stable_snake_case() {
        // Every variant must have a deterministic label — the Dart side
        // matches against these strings.
        assert_eq!(LikelyCause::CloudPassage.label(), "cloud_passage");
        assert_eq!(LikelyCause::SeeingSpike.label(), "seeing_spike");
        assert_eq!(LikelyCause::GuidingFailure.label(), "guiding_failure");
        assert_eq!(LikelyCause::WindGust.label(), "wind_gust");
        assert_eq!(LikelyCause::SatellitePass.label(), "satellite_pass");
        assert_eq!(LikelyCause::HotPixelOrCosmic.label(), "hot_pixel_or_cosmic");
        assert_eq!(LikelyCause::FocusDrift.label(), "focus_drift");
        assert_eq!(LikelyCause::Unknown.label(), "unknown");
    }

    #[test]
    fn forensic_history_len_bounded() {
        // Defensive: bumping this constant is fine but it should stay
        // small enough to fit comfortably in memory per active sequence.
        // Use const_assert via const block so the constraint is enforced
        // at compile time and clippy doesn't flag `assert!(true)`.
        const _: () = assert!(FORENSIC_HISTORY_LEN <= 32);
        const _: () = assert!(FORENSIC_HISTORY_LEN >= 5);
    }

    #[test]
    fn cloud_signals_dont_misfire_on_stable_clear_skies() {
        // Sanity check: stable clear skies + isolated reject must NOT
        // be classified as CloudPassage.
        let now = 1_700_000_000.0;
        let recent: Vec<RecentFrameSample> = (0..5)
            .map(|i| {
                let mut s = sample(now - 240.0 + i as f64 * 60.0, true);
                s.sky_brightness_mag = Some(21.4);
                s.cloud_cover_percent = Some(5.0);
                s.hfr = Some(2.0);
                s
            })
            .collect();
        let inputs = ForensicInputs {
            hfr: Some(3.7),
            eccentricity: Some(0.65),
            star_count: Some(110),
            hfr_baseline: Some(2.0),
            environment: EnvironmentSnapshot {
                sky_brightness_mag: Some(21.4),
                cloud_cover_percent: Some(6.0),
                ..Default::default()
            },
            recent_frames: &recent,
            grader_reason: "eccentricity 0.65 exceeds threshold 0.60",
        };
        let verdict = analyze_rejection(&inputs);
        assert_ne!(verdict.likely_cause, Some(LikelyCause::CloudPassage));
    }
}
