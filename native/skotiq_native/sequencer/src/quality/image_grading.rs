//! Image Grading: per-frame Pass/Reject decision based on HFR,
//! eccentricity, and star count.
//!
//! `frame_quality_assessment_service.dart` is advisory only — it tags frames
//! as Good / Needs Review / Poor but never moves them off-disk, so bad frames
//! stay mixed with good ones until the user culls them by hand.
//! `ImageQualityCheck` is the real-time gate: captures exceeding the
//! configured thresholds are routed to a `Reject/` subfolder, excluded from
//! the per-filter integration-budget accounting, and surfaced in the run
//! dashboard's quality panel.
//!
//! ## Design notes
//!
//! * **Per-node toggle**: `ExposureConfig.quality_check` overrides the
//!   global settings, so an operator can disable grading on a specific
//!   smart-exposure burst while keeping it active globally.
//! * **Baseline computation**: `hfr_baseline_percent` compares the current
//!   frame's HFR against a rolling baseline of the first 5 accepted
//!   frames. This catches sky-quality degradation that absolute thresholds
//!   miss (a dry-air HFR of 2.4 px is great; the same field at 3.6 px the
//!   next night is everyone-pack-up bad — `hfr_baseline_percent: 50` would
//!   flag it).
//! * **Consecutive-reject notice**: 3 in a row tells the operator once for
//!   that streak, because no amount of averaging will fix a systematic
//!   failure (focus walked off, cloud bank moved through, dome failed to
//!   slave). It never pauses, stops or parks the run (owner decision
//!   2026-10-06); the frames are still graded and the rejects kept.
//! * **A metric never taken grades Pass.** When a measurement is `None`
//!   (detection did not run, `calculate_image_hfr` returned None) the frame
//!   passes rather than rejecting: a missing measurement is not a known-bad
//!   frame, and narrowband on a dim nebula legitimately defeats the detector.
//! * **…but a measured zero is evidence.** `star_count: Some(0)` is not
//!   absence: the detector ran on a light frame and found nothing. Every
//!   other metric is then `None` by construction, so every configured gate
//!   would be skipped and a clouded-out or badly trailed frame would pass on
//!   the strength of having been unmeasurable. See `grade_frame`.

use serde::{Deserialize, Serialize};

/// Default number of accepted frames blended into the baseline before the
/// `hfr_baseline_percent` check becomes active.
pub const DEFAULT_HFR_BASELINE_WINDOW: usize = 5;

/// The eccentricity limit the app ships with: the default of the Dart
/// setting `imageGradingEccentricityThreshold`, which is what reaches
/// [`ImageQualityCheck::eccentricity_threshold`] on a profile that never set
/// one. Pinned here so the rig-frame tests grade against the shipped value.
///
/// Chosen from the owner's frames of 2026-09-14 (10" f/4 Newtonian,
/// `test-fixtures/rig-2026-09-14`), measured by the grader itself. In focus:
/// 0.51, 0.54 and 0.68 on the full frames, 0.66 and 0.77 on the 1024 px
/// crops. Trailed by a dead guider: 0.82, 0.83 and 0.97 on the crops, 0.83,
/// 0.85 and 0.97 on the full frames. The old 0.7 rejected an in-focus frame;
/// 0.8 (a 1.67:1 axis ratio) passes every in-focus frame and still rejects
/// every trailed one.
pub const DEFAULT_ECCENTRICITY_THRESHOLD: f64 = 0.8;

/// Per-burst image-grading thresholds.
///
/// All fields are `Option` so an operator can enable just the checks they
/// want — absolute HFR alone, or only the baseline-relative check, or both.
/// `max_consecutive_rejects` is required (`u32`); zero (or `u32::MAX`)
/// turns the streak notice off while keeping the per-frame check.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ImageQualityCheck {
    /// Reject if HFR exceeds this absolute pixel value.
    pub hfr_threshold: Option<f64>,
    /// Reject if HFR exceeds `baseline * (1 + percent / 100)`. Baseline
    /// is the median of the first `DEFAULT_HFR_BASELINE_WINDOW` accepted
    /// frames of the current target.
    pub hfr_baseline_percent: Option<f64>,
    /// Reject if the eccentricity (axis-ratio derived measure of star
    /// roundness) exceeds this value. 0.6 is a 1.25:1 smear (tight guiding
    /// gone soft); 0.8 is a 1.7:1 smear (a gust or a dropped correction).
    /// The star detector measures up to
    /// `skotiq_imaging::DETECTION_MAX_ECCENTRICITY` (0.95, a ~3:1 smear)
    /// before treating a source as a satellite trail rather than a star, so
    /// any threshold below that is genuinely reachable.
    pub eccentricity_threshold: Option<f64>,
    /// Reject if star count drops below this floor. Trips when clouds
    /// roll in or the dome slit drifts off-target.
    pub star_count_min: Option<u32>,
    /// Notify the operator once when this many frames in a row have been
    /// rejected. The run carries on. Counter resets to 0 on each accepted
    /// frame, so a later streak is notified again.
    pub max_consecutive_rejects: u32,
}

impl Default for ImageQualityCheck {
    fn default() -> Self {
        Self {
            hfr_threshold: None,
            hfr_baseline_percent: None,
            eccentricity_threshold: None,
            star_count_min: None,
            max_consecutive_rejects: 3,
        }
    }
}

impl ImageQualityCheck {
    /// Returns true iff at least one quality threshold is configured.
    /// An all-`None` check is functionally a no-op and `grade_frame`
    /// returns `Pass` immediately without doing any work.
    pub fn is_active(&self) -> bool {
        self.hfr_threshold.is_some()
            || self.hfr_baseline_percent.is_some()
            || self.eccentricity_threshold.is_some()
            || self.star_count_min.is_some()
    }
}

/// Outcome of grading a single frame.
#[derive(Debug, Clone, PartialEq)]
pub enum FrameGrade {
    /// Frame passes all configured checks.
    Pass,
    /// Frame fails at least one check; reason describes which.
    /// The numeric fields are carried through so the dashboard panel can
    /// show "rejected: HFR 5.21 px > 3.50 threshold" instead of just
    /// "rejected".
    Reject {
        reason: String,
        hfr: Option<f64>,
        eccentricity: Option<f64>,
        star_count: Option<u32>,
    },
}

impl FrameGrade {
    pub fn is_pass(&self) -> bool {
        matches!(self, FrameGrade::Pass)
    }

    pub fn is_reject(&self) -> bool {
        matches!(self, FrameGrade::Reject { .. })
    }

    pub fn reject_reason(&self) -> Option<&str> {
        match self {
            FrameGrade::Pass => None,
            FrameGrade::Reject { reason, .. } => Some(reason.as_str()),
        }
    }
}

/// Measured frame quality metrics. Filled by the post-exposure
/// star-detection pipeline before grading is invoked.
#[derive(Debug, Clone, Copy, Default)]
pub struct FrameMetrics {
    /// Median half-flux radius across detected stars, pixels. `None`
    /// when star detection failed entirely (no stars to measure).
    pub hfr: Option<f64>,
    /// Median eccentricity (0.0 = perfectly round). `None` when not
    /// computed.
    pub eccentricity: Option<f64>,
    /// Number of detected stars. `None` when detection didn't run.
    pub star_count: Option<u32>,
}

/// Grade a frame against the configured thresholds.
///
/// Returns `Pass` when no check is active, when metrics were never measured
/// (honest-ignorance rule), or when every active check passes. Returns
/// `Reject` with a descriptive reason on the first failing check, and for a
/// light frame whose star count was *measured* as zero.
///
/// `hfr_baseline` is the rolling median of accepted-frame HFRs maintained
/// by `ExecutionContext::hfr_baseline`. Pass `None` when the baseline
/// hasn't been established yet (first 5 frames of a target) — the
/// baseline check is then skipped.
pub fn grade_frame(
    check: &ImageQualityCheck,
    metrics: &FrameMetrics,
    hfr_baseline: Option<f64>,
) -> FrameGrade {
    if !check.is_active() {
        return FrameGrade::Pass;
    }

    // Zero measured stars. This runs first because when the detector found
    // nothing, every other metric is `None` and every gate below would be
    // skipped — the frame would then pass *because* it was unmeasurable,
    // which is the failure mode this gate exists to prevent. A clouded-out
    // frame, a frame trailed past the detector's streak ceiling, a closed
    // dust cap and a slew that landed off-target all land here.
    //
    // `Some(0)` and `None` are emphatically different: `None` means the
    // detector never ran (the caller skips it for darks/flats/bias) and
    // stays honest ignorance, while `Some(0)` is a measurement.
    // `run_exposure_loop` only grades light frames, so a calibration burst
    // can never reach this branch.
    if metrics.star_count == Some(0) {
        return FrameGrade::Reject {
            reason: "no stars detected — frame quality is unmeasurable (clouds, \
                     trailing, off-target slew, or an obstructed aperture)"
                .to_string(),
            hfr: metrics.hfr,
            eccentricity: metrics.eccentricity,
            star_count: Some(0),
        };
    }

    // Absolute HFR. Only fires when HFR is actually measured — a None
    // hfr means star detection didn't return any stars, which is a
    // legitimate "we don't know" rather than a known-bad signal.
    if let (Some(threshold), Some(hfr)) = (check.hfr_threshold, metrics.hfr) {
        if hfr > threshold {
            return FrameGrade::Reject {
                reason: format!(
                    "HFR {:.2} px exceeds absolute threshold {:.2} px",
                    hfr, threshold
                ),
                hfr: Some(hfr),
                eccentricity: metrics.eccentricity,
                star_count: metrics.star_count,
            };
        }
    }

    // Baseline-relative HFR. Only fires when both the current HFR and
    // the baseline are known. baseline_percent is in % (50 = 1.5x).
    if let (Some(pct), Some(hfr), Some(baseline)) =
        (check.hfr_baseline_percent, metrics.hfr, hfr_baseline)
    {
        if baseline > 0.0 {
            let limit = baseline * (1.0 + pct / 100.0);
            if hfr > limit {
                return FrameGrade::Reject {
                    reason: format!(
                        "HFR {:.2} px exceeds baseline {:.2} px + {:.0}% (limit {:.2} px)",
                        hfr, baseline, pct, limit
                    ),
                    hfr: Some(hfr),
                    eccentricity: metrics.eccentricity,
                    star_count: metrics.star_count,
                };
            }
        }
    }

    // Eccentricity.
    if let (Some(threshold), Some(ecc)) = (check.eccentricity_threshold, metrics.eccentricity) {
        if ecc > threshold {
            return FrameGrade::Reject {
                reason: format!("eccentricity {:.2} exceeds threshold {:.2}", ecc, threshold),
                hfr: metrics.hfr,
                eccentricity: Some(ecc),
                star_count: metrics.star_count,
            };
        }
    }

    // Star count floor.
    if let (Some(min), Some(count)) = (check.star_count_min, metrics.star_count) {
        if count < min {
            return FrameGrade::Reject {
                reason: format!(
                    "star count {} below minimum {} (likely cloud / off-target)",
                    count, min
                ),
                hfr: metrics.hfr,
                eccentricity: metrics.eccentricity,
                star_count: Some(count),
            };
        }
    }

    FrameGrade::Pass
}

/// Update the rolling HFR baseline with a newly-accepted frame.
///
/// Until `DEFAULT_HFR_BASELINE_WINDOW` samples have been collected, the
/// baseline remains `None` and incoming samples are pushed into `samples`.
/// Once the window fills, the median is computed once and stored in
/// `baseline`; further samples are ignored (the baseline is intentionally
/// stable for the rest of the target — drifting it with every new frame
/// would defeat the "is this frame degrading vs the start of the
/// session?" semantics).
///
/// Returns the current baseline value after the update.
pub fn update_hfr_baseline(
    baseline: &mut Option<f64>,
    samples: &mut Vec<f64>,
    new_hfr: Option<f64>,
) -> Option<f64> {
    if baseline.is_some() {
        // Baseline already fixed — don't drift it.
        return *baseline;
    }
    let Some(hfr) = new_hfr else {
        return *baseline;
    };
    if !hfr.is_finite() || hfr <= 0.0 {
        return *baseline;
    }
    samples.push(hfr);
    if samples.len() >= DEFAULT_HFR_BASELINE_WINDOW {
        let mut sorted = samples.clone();
        sorted.sort_by(|a, b| {
            a.partial_cmp(b)
                .expect("filtered for NaN/<=0 above; partial_cmp must succeed")
        });
        let mid = sorted.len() / 2;
        let median = if sorted.len() % 2 == 1 {
            sorted[mid]
        } else {
            (sorted[mid - 1] + sorted[mid]) / 2.0
        };
        *baseline = Some(median);
    }
    *baseline
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn inactive_check_always_passes() {
        let check = ImageQualityCheck::default();
        assert!(!check.is_active());
        let metrics = FrameMetrics {
            hfr: Some(5.0),
            eccentricity: Some(0.9),
            star_count: Some(2),
        };
        let grade = grade_frame(&check, &metrics, None);
        assert_eq!(grade, FrameGrade::Pass);
    }

    #[test]
    fn absolute_hfr_rejects_above_threshold() {
        let check = ImageQualityCheck {
            hfr_threshold: Some(4.0),
            ..Default::default()
        };
        let metrics = FrameMetrics {
            hfr: Some(5.2),
            ..Default::default()
        };
        match grade_frame(&check, &metrics, None) {
            FrameGrade::Reject { reason, hfr, .. } => {
                assert!(reason.contains("HFR 5.20"));
                assert!(reason.contains("4.00"));
                assert_eq!(hfr, Some(5.2));
            }
            other => panic!("expected Reject, got {:?}", other),
        }
    }

    #[test]
    fn absolute_hfr_passes_at_or_below_threshold() {
        let check = ImageQualityCheck {
            hfr_threshold: Some(4.0),
            ..Default::default()
        };
        let metrics = FrameMetrics {
            hfr: Some(3.99),
            ..Default::default()
        };
        assert_eq!(grade_frame(&check, &metrics, None), FrameGrade::Pass);
        let metrics_exact = FrameMetrics {
            hfr: Some(4.0),
            ..Default::default()
        };
        assert_eq!(
            grade_frame(&check, &metrics_exact, None),
            FrameGrade::Pass,
            "exact threshold should pass (strict > comparison)"
        );
    }

    #[test]
    fn baseline_check_fires_with_percent_above_limit() {
        let check = ImageQualityCheck {
            hfr_baseline_percent: Some(50.0),
            ..Default::default()
        };
        // Baseline 2.0 + 50% => limit 3.0
        let metrics_pass = FrameMetrics {
            hfr: Some(2.8),
            ..Default::default()
        };
        let metrics_fail = FrameMetrics {
            hfr: Some(3.1),
            ..Default::default()
        };
        assert_eq!(
            grade_frame(&check, &metrics_pass, Some(2.0)),
            FrameGrade::Pass
        );
        assert!(grade_frame(&check, &metrics_fail, Some(2.0)).is_reject());
    }

    #[test]
    fn baseline_check_skipped_when_baseline_not_yet_established() {
        let check = ImageQualityCheck {
            hfr_baseline_percent: Some(50.0),
            ..Default::default()
        };
        let metrics = FrameMetrics {
            hfr: Some(99.0),
            ..Default::default()
        };
        // No baseline => skip baseline-relative check.
        assert_eq!(grade_frame(&check, &metrics, None), FrameGrade::Pass);
    }

    #[test]
    fn elongated_frame_above_threshold_is_rejected() {
        // The capture pipeline measures per-frame eccentricity from star shape
        // moments, so a trailed frame above the configured threshold is culled.
        let check = ImageQualityCheck {
            eccentricity_threshold: Some(0.7),
            ..Default::default()
        };
        let metrics = FrameMetrics {
            hfr: Some(2.4),
            eccentricity: Some(0.85),
            star_count: Some(150),
        };
        match grade_frame(&check, &metrics, None) {
            FrameGrade::Reject {
                reason,
                eccentricity,
                ..
            } => {
                assert!(reason.contains("eccentricity"), "reason: {reason}");
                assert_eq!(eccentricity, Some(0.85));
            }
            other => panic!("expected Reject for trailed frame, got {:?}", other),
        }
    }

    #[test]
    fn round_frame_passes_eccentricity_gate() {
        let check = ImageQualityCheck {
            eccentricity_threshold: Some(0.7),
            ..Default::default()
        };
        // A well-guided round frame (low ecc) must pass.
        let metrics = FrameMetrics {
            hfr: Some(2.1),
            eccentricity: Some(0.18),
            star_count: Some(220),
        };
        assert_eq!(grade_frame(&check, &metrics, None), FrameGrade::Pass);
        // Exact threshold passes (strict > comparison).
        let metrics_exact = FrameMetrics {
            eccentricity: Some(0.7),
            ..Default::default()
        };
        assert_eq!(
            grade_frame(&check, &metrics_exact, None),
            FrameGrade::Pass,
            "exact threshold should pass (strict > comparison)"
        );
    }

    #[test]
    fn unmeasured_eccentricity_does_not_reject() {
        // Honest-absence path: when too few reliable stars were available to
        // form a stable median, the detector reports None. The gate must NOT
        // reject on no evidence — None is "unknown", not "bad". (The
        // measured-zero-stars gate covers the genuinely-empty-frame case.)
        let check = ImageQualityCheck {
            eccentricity_threshold: Some(0.5),
            ..Default::default()
        };
        let metrics = FrameMetrics {
            hfr: Some(2.5),
            eccentricity: None,
            star_count: Some(120),
        };
        assert_eq!(
            grade_frame(&check, &metrics, None),
            FrameGrade::Pass,
            "an unmeasured eccentricity must not produce a no-evidence reject"
        );
    }

    #[test]
    fn measured_zero_stars_is_rejected_even_with_only_an_eccentricity_gate() {
        // The shape this closes: the operator configured the eccentricity
        // gate and nothing else, the frame came back with no stars, so HFR
        // and eccentricity were both None and every gate was skipped. The
        // frame that most needed culling was the one that passed.
        let check = ImageQualityCheck {
            eccentricity_threshold: Some(0.8),
            ..Default::default()
        };
        let metrics = FrameMetrics {
            hfr: None,
            eccentricity: None,
            star_count: Some(0),
        };
        match grade_frame(&check, &metrics, None) {
            FrameGrade::Reject {
                reason, star_count, ..
            } => {
                assert!(reason.contains("no stars detected"), "reason: {reason}");
                assert_eq!(star_count, Some(0));
            }
            other => panic!(
                "expected Reject for a starless light frame, got {:?}",
                other
            ),
        }
    }

    #[test]
    fn unmeasured_star_count_is_still_honest_absence() {
        // The counterpart invariant: `None` must keep passing. This is the
        // path calibration frames and detector failures take, and turning it
        // into a reject would dump whole dark/flat bursts into Reject/.
        let check = ImageQualityCheck {
            eccentricity_threshold: Some(0.8),
            star_count_min: Some(20),
            ..Default::default()
        };
        let metrics = FrameMetrics {
            hfr: None,
            eccentricity: None,
            star_count: None,
        };
        assert_eq!(grade_frame(&check, &metrics, None), FrameGrade::Pass);
    }

    #[test]
    fn star_count_minimum() {
        let check = ImageQualityCheck {
            star_count_min: Some(50),
            ..Default::default()
        };
        let metrics = FrameMetrics {
            star_count: Some(20),
            ..Default::default()
        };
        match grade_frame(&check, &metrics, None) {
            FrameGrade::Reject { reason, .. } => {
                assert!(reason.contains("star count 20"));
            }
            other => panic!("expected Reject, got {:?}", other),
        }
    }

    #[test]
    fn missing_metrics_are_treated_as_unknown_not_bad() {
        // No HFR measured, but threshold configured: the check is skipped
        // (we don't know, so we don't reject).
        let check = ImageQualityCheck {
            hfr_threshold: Some(2.0),
            star_count_min: Some(100),
            ..Default::default()
        };
        let metrics = FrameMetrics::default();
        assert_eq!(grade_frame(&check, &metrics, None), FrameGrade::Pass);
    }

    #[test]
    fn first_check_failing_short_circuits() {
        // HFR fails before star_count_min would; reason should be HFR.
        let check = ImageQualityCheck {
            hfr_threshold: Some(2.0),
            star_count_min: Some(100),
            ..Default::default()
        };
        let metrics = FrameMetrics {
            hfr: Some(5.0),
            star_count: Some(10),
            ..Default::default()
        };
        let grade = grade_frame(&check, &metrics, None);
        match grade {
            FrameGrade::Reject { reason, .. } => {
                assert!(reason.contains("HFR"));
                assert!(!reason.contains("star count"));
            }
            other => panic!("expected Reject, got {:?}", other),
        }
    }

    #[test]
    fn baseline_finalizes_at_window_size() {
        let mut baseline = None;
        let mut samples = Vec::new();

        update_hfr_baseline(&mut baseline, &mut samples, Some(2.0));
        update_hfr_baseline(&mut baseline, &mut samples, Some(2.1));
        update_hfr_baseline(&mut baseline, &mut samples, Some(1.9));
        update_hfr_baseline(&mut baseline, &mut samples, Some(2.2));
        // Still 4 < window (5); baseline remains None.
        assert!(
            baseline.is_none(),
            "baseline shouldn't lock until {} samples",
            DEFAULT_HFR_BASELINE_WINDOW
        );

        update_hfr_baseline(&mut baseline, &mut samples, Some(2.0));
        // 5 samples — baseline computed.
        let b = baseline.expect("baseline should be set after window fills");
        assert!(
            (b - 2.0).abs() < f64::EPSILON,
            "median of [1.9,2.0,2.0,2.1,2.2] = 2.0; got {}",
            b
        );
    }

    #[test]
    fn baseline_does_not_drift_after_locked() {
        let mut baseline = Some(2.0);
        let mut samples = Vec::new();
        for _ in 0..10 {
            update_hfr_baseline(&mut baseline, &mut samples, Some(5.0));
        }
        assert_eq!(baseline, Some(2.0), "baseline must stay fixed once locked");
        assert!(
            samples.is_empty(),
            "post-lock samples should not be accumulated"
        );
    }

    // Pixels-to-verdict wiring.
    //
    // Everything above hand-builds `FrameMetrics`, which cannot catch the
    // real defect: the metrics the capture loop actually assembles came
    // from a detector that discarded every trailed star before it could be
    // measured, so `grade_frame` was handed `None` and passed the frame.
    // These tests drive the same chain `run_exposure_loop` drives —
    // `detect_stars(StarDetectionConfig::default())` (verbatim what
    // `UnifiedDeviceOps::measure_frame_eccentricity` and
    // `detect_stars_in_image` use) → `frame_eccentricity` → `FrameMetrics`
    // → `grade_frame` — starting from pixels.

    /// A field of identically-smeared elliptical Gaussians on a flat
    /// background: what wind shake or a dropped guide correction does to
    /// every star in the frame at once.
    fn render_star_field(sigma_major: f64, sigma_minor: f64) -> skotiq_imaging::ImageData {
        const WIDTH: u32 = 280;
        const HEIGHT: u32 = 160;
        const BACKGROUND: f64 = 1000.0;
        const PEAK: f64 = 30000.0;
        let centers: Vec<(f64, f64)> = (0..8)
            .map(|i| (40.0 + (i % 4) as f64 * 60.0, 40.0 + (i / 4) as f64 * 60.0))
            .collect();
        let two_sx_sq = 2.0 * sigma_major * sigma_major;
        let two_sy_sq = 2.0 * sigma_minor * sigma_minor;
        let mut data = vec![BACKGROUND as u16; (WIDTH * HEIGHT) as usize];
        for y in 0..HEIGHT {
            for x in 0..WIDTH {
                let mut v = BACKGROUND;
                for &(cx, cy) in &centers {
                    let dx = x as f64 - cx;
                    let dy = y as f64 - cy;
                    v += PEAK * (-(dx * dx) / two_sx_sq - (dy * dy) / two_sy_sq).exp();
                }
                data[(y * WIDTH + x) as usize] = v.clamp(0.0, 65535.0) as u16;
            }
        }
        skotiq_imaging::ImageData::from_u16(WIDTH, HEIGHT, 1, &data)
    }

    /// Reproduce the capture loop's metric assembly for a light frame.
    fn measure_light_frame(image: &skotiq_imaging::ImageData) -> FrameMetrics {
        let stars = skotiq_imaging::detect_stars(
            image,
            &skotiq_imaging::StarDetectionConfig::default(),
        );
        FrameMetrics {
            hfr: skotiq_imaging::calculate_median_hfr(image),
            eccentricity: skotiq_imaging::frame_eccentricity(&stars),
            star_count: Some(stars.len() as u32),
        }
    }

    #[test]
    fn trailed_frame_measured_from_pixels_is_rejected() {
        // 2.5:1 smear (analytic e = 0.917) — the "catastrophic tracking
        // failure" the settings screen promises the 0.8 threshold catches.
        let image = render_star_field(6.0, 2.4);
        let metrics = measure_light_frame(&image);
        let check = ImageQualityCheck {
            eccentricity_threshold: Some(0.8),
            ..Default::default()
        };
        match grade_frame(&check, &metrics, None) {
            FrameGrade::Reject { reason, .. } => {
                assert!(reason.contains("eccentricity"), "reason: {reason}");
            }
            other => panic!(
                "a trailed frame must be rejected; got {:?} from metrics {:?}",
                other, metrics
            ),
        }
    }

    #[test]
    fn round_frame_measured_from_pixels_is_accepted() {
        // The control: the same chain on a well-guided frame must not
        // reject, or the gate above would just be a frame shredder.
        let image = render_star_field(2.6, 2.5);
        let metrics = measure_light_frame(&image);
        let check = ImageQualityCheck {
            eccentricity_threshold: Some(0.8),
            ..Default::default()
        };
        assert_eq!(
            grade_frame(&check, &metrics, None),
            FrameGrade::Pass,
            "round frame metrics {:?} must pass",
            metrics
        );
    }

    #[test]
    fn baseline_filters_nan_and_non_positive() {
        let mut baseline = None;
        let mut samples = Vec::new();
        update_hfr_baseline(&mut baseline, &mut samples, Some(f64::NAN));
        update_hfr_baseline(&mut baseline, &mut samples, Some(-1.0));
        update_hfr_baseline(&mut baseline, &mut samples, Some(0.0));
        update_hfr_baseline(&mut baseline, &mut samples, None);
        assert!(baseline.is_none());
        assert!(samples.is_empty(), "bad samples should not be retained");
    }

    /// The baseline is the MEDIAN of the first frames, whatever order they
    /// arrive in. The test above uses samples whose second- and third-smallest
    /// values are equal, so taking the wrong element of the sorted window (or
    /// averaging two of them) still gave 2.0 and passed.
    #[test]
    fn baseline_is_the_median_of_distinct_samples_in_arrival_order() {
        let mut baseline = None;
        let mut samples = Vec::new();
        for hfr in [3.0, 1.0, 5.0, 2.0, 4.0] {
            update_hfr_baseline(&mut baseline, &mut samples, Some(hfr));
        }
        assert_eq!(baseline, Some(3.0));
    }

    /// A frame exactly at a limit is accepted: the limits are maxima and
    /// minima the operator set, not values to stay strictly inside.
    #[test]
    fn a_frame_exactly_at_each_limit_passes_and_one_step_past_it_is_rejected() {
        let check = ImageQualityCheck {
            hfr_threshold: Some(4.0),
            hfr_baseline_percent: Some(50.0),
            eccentricity_threshold: Some(0.5),
            star_count_min: Some(20),
            ..Default::default()
        };
        let at_limits = FrameMetrics {
            hfr: Some(3.0),
            eccentricity: Some(0.5),
            star_count: Some(20),
        };
        // Baseline 2.0 + 50% = a 3.0 px limit.
        assert!(grade_frame(&check, &at_limits, Some(2.0)).is_pass());

        let past = |metrics: FrameMetrics| grade_frame(&check, &metrics, Some(2.0));
        assert!(past(FrameMetrics {
            hfr: Some(3.01),
            ..at_limits
        })
        .is_reject());
        assert!(past(FrameMetrics {
            eccentricity: Some(0.51),
            ..at_limits
        })
        .is_reject());
        assert!(past(FrameMetrics {
            star_count: Some(19),
            ..at_limits
        })
        .is_reject());
    }
}
