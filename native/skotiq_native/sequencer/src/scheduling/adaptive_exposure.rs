//! sky-brightness adaptive exposure math.
//!
//! Goal: keep per-frame SNR roughly constant across changing sky conditions
//! by stretching individual exposures when the sky background gets brighter
//! (light-pollution rise, moon up, twilight haze, transparency drop) and
//! shrinking them when conditions improve.
//!
//! The configured nominal `exposure_duration_secs` on every `ExposureConfig`
//! is treated as the operator's "this is the right exposure at reference
//! sky brightness" anchor. At capture time we compare the *live* sky
//! brightness (mag/arcsec² — bigger = darker) against the configured
//! reference and rescale the exposure inversely proportional to the sky
//! background ADU/sec ratio.
//!
//! # SNR math
//!
//! Sky-noise-limited SNR is dominated by Poisson noise from the sky
//! background. For a roughly constant signal:
//!
//! ```text
//!     SNR ≈ signal · sqrt(t) / sqrt(b · t)  =  signal · sqrt(t / b)
//! ```
//!
//! where `b` is the sky background flux (electrons / second) and `t` is the
//! exposure time. Holding SNR constant across two skies with backgrounds
//! `b_ref` and `b_cur` means:
//!
//! ```text
//!     t_cur / b_cur  =  t_ref / b_ref       =>  t_cur = t_ref · (b_cur / b_ref)
//! ```
//!
//! Astronomical magnitudes are defined so a 1 mag/arcsec² change corresponds
//! to a flux ratio of 2.5^Δmag (Pogson's relation):
//!
//! ```text
//!     b_cur / b_ref  =  10^( (mag_ref − mag_cur) / 2.5 )
//! ```
//!
//! Note the sign convention: mag/arcsec² is brighter when smaller. A Bortle 1
//! site is ≈ 21.9 mag/arcsec²; a Bortle 6 backyard might be 19.0. So
//! `mag_ref − mag_cur` is positive when current sky is brighter than
//! reference, which makes the flux ratio > 1 and stretches the exposure.
//!
//! # Worked example
//!
//! Configured nominal 60 s at reference 21.5 mag/arcsec² (rural dark site).
//! Tonight's live sky brightness reads 19.2 mag/arcsec² (Bortle 6 backyard).
//!
//! ```text
//!     Δmag       = 21.5 − 19.2          = 2.3 mag/arcsec² brighter sky
//!     flux ratio = 10^(2.3 / 2.5)       ≈ 8.32
//!     t_adapted  = 60 · 8.32            ≈ 499 s
//! ```
//!
//! That's far too long for backyard tracking. The configured per-filter or
//! global `max_exposure_secs` ceiling kicks in and clamps the value — we
//! don't fight the user's known tracking limits. In a typical config of
//! `max=300 s` the adapter would emit `300 s` with a clamp warning so the
//! user knows the SNR target wasn't met.
//!
//! Edge cases
//! ----------
//! * Missing live sky brightness — `compute_adaptive_exposure` returns the
//!   nominal duration with reason = `Unavailable`. The exposure runs at the
//!   configured nominal; this is the documented fallback rather than
//!   refusing to capture.
//! * Min/max clamping — the adapted value is clamped to
//!   `[min_exposure_secs, max_exposure_secs]`, or the per-filter overrides
//!   when present. We always honour the user's configured ceilings.
//! * Nominal already outside bounds — emitted as `OutOfNominalBounds`. The
//!   exposure still runs at the clamped value; validation surfaces a
//!   warning so the user can fix the config.
//! * Mag/arcsec² <= 0 or NaN — treated as `Unavailable`, fall back to
//!   nominal.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Sky-brightness adaptive-exposure configuration carried on an
/// `ExposureConfig` (or as a global default on `RuntimeConfig`). All fields
/// have `#[serde(default)]` so old JSON without an `adaptive_exposure`
/// section deserializes cleanly (the exposure runs at nominal duration).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AdaptiveExposureConfig {
    /// Target SNR. Currently informational (we scale the *exposure* to keep
    /// SNR constant across nights, but we don't try to *aim* at a numeric
    /// target — that requires per-camera read-noise + gain calibration we
    /// don't track yet). Future work: replace the simple background-ratio
    /// math with a true SNR-target solver once `frame_metrics` carries the
    /// background flux per frame.
    #[serde(default = "default_target_snr")]
    pub target_snr: f64,

    /// Sky brightness in mag/arcsec² that the configured nominal
    /// `ExposureConfig.duration_secs` is calibrated for. Bigger = darker;
    /// a typical dark-site value is 21.5; a Bortle 5 backyard is ~19.5.
    #[serde(default = "default_reference_sky_brightness_mag")]
    pub reference_sky_brightness_mag: f64,

    /// Minimum exposure clamp (seconds). Per-filter values override this.
    #[serde(default = "default_min_exposure_secs")]
    pub min_exposure_secs: f64,

    /// Maximum exposure clamp (seconds). Per-filter values override this.
    /// The default is large (10 minutes) because the rig's tracking limit
    /// is camera/mount-specific and the operator should set it explicitly
    /// when they know.
    #[serde(default = "default_max_exposure_secs")]
    pub max_exposure_secs: f64,

    /// Per-filter enable map. Filter name -> bool. When a filter name is
    /// absent, the global `enabled_by_default` applies. The brief
    /// calls out the typical use case: enable on Lum/clear, leave RGB at
    /// fixed exposures because chromatic noise behaves differently.
    #[serde(default)]
    pub per_filter_enabled: HashMap<String, bool>,

    /// Optional per-filter minimum exposure floor (overrides the global
    /// `min_exposure_secs`).
    #[serde(default)]
    pub per_filter_min_secs: HashMap<String, f64>,

    /// Optional per-filter maximum exposure ceiling (overrides the global
    /// `max_exposure_secs`).
    #[serde(default)]
    pub per_filter_max_secs: HashMap<String, f64>,

    /// Global enable. When false the whole config is a no-op regardless of
    /// per-filter map content. Surfaced separately so the user can keep
    /// their per-filter map populated while temporarily disabling the
    /// feature.
    #[serde(default = "default_enabled")]
    pub enabled: bool,
}

fn default_target_snr() -> f64 {
    30.0
}
fn default_reference_sky_brightness_mag() -> f64 {
    21.5
}
fn default_min_exposure_secs() -> f64 {
    5.0
}
fn default_max_exposure_secs() -> f64 {
    600.0
}
fn default_enabled() -> bool {
    true
}

impl Default for AdaptiveExposureConfig {
    fn default() -> Self {
        Self {
            target_snr: default_target_snr(),
            reference_sky_brightness_mag: default_reference_sky_brightness_mag(),
            min_exposure_secs: default_min_exposure_secs(),
            max_exposure_secs: default_max_exposure_secs(),
            per_filter_enabled: HashMap::new(),
            per_filter_min_secs: HashMap::new(),
            per_filter_max_secs: HashMap::new(),
            enabled: default_enabled(),
        }
    }
}

impl AdaptiveExposureConfig {
    /// Whether this config wants to adapt the given filter. Returns true
    /// when the global `enabled` flag is true AND the per-filter map either
    /// explicitly enables the filter OR is empty (the implicit-enable
    /// fallback).
    pub fn is_enabled_for_filter(&self, filter: Option<&str>) -> bool {
        if !self.enabled {
            return false;
        }
        let Some(filter) = filter else {
            // No filter = monochrome / no filter wheel; the global enable
            // alone governs.
            return true;
        };
        if let Some(per) = self.per_filter_enabled.get(filter) {
            return *per;
        }
        // When the user has populated the per-filter map at all, an
        // absent filter is treated as "not opted in". This matches the
        // UI contract: the checkboxes are exhaustive when present.
        // Empty map = "apply globally".
        self.per_filter_enabled.is_empty()
    }

    /// Resolve the min-exposure clamp for the given filter — per-filter
    /// override wins, falling back to the global value.
    pub fn min_for_filter(&self, filter: Option<&str>) -> f64 {
        if let Some(f) = filter {
            if let Some(v) = self.per_filter_min_secs.get(f) {
                return *v;
            }
        }
        self.min_exposure_secs
    }

    /// Resolve the max-exposure clamp for the given filter — per-filter
    /// override wins, falling back to the global value.
    pub fn max_for_filter(&self, filter: Option<&str>) -> f64 {
        if let Some(f) = filter {
            if let Some(v) = self.per_filter_max_secs.get(f) {
                return *v;
            }
        }
        self.max_exposure_secs
    }
}

/// Result of an adaptive-exposure decision. Returned from
/// [`compute_adaptive_exposure`] so the caller can both pass `adapted_secs`
/// to the camera AND emit a structured progress event with the same data.
#[derive(Debug, Clone, PartialEq)]
pub struct AdaptiveExposureDecision {
    /// The exposure time we'll actually use, in seconds. Always finite,
    /// always >= min and <= max for the applicable filter.
    pub adapted_secs: f64,
    /// The nominal duration the user configured (echoed for the UI).
    pub nominal_secs: f64,
    /// Sky brightness used in the decision (mag/arcsec²). `None` when the
    /// decision was a fallback (`Unavailable` / `Disabled`).
    pub sky_brightness_mag: Option<f64>,
    /// Why the value above was chosen — drives the UI's explanatory text.
    pub reason: AdaptiveExposureReason,
}

/// Tag describing which decision branch produced the adapted exposure.
/// Carried in the structured progress event so the dashboard can render a
/// human-readable explanation without the user reverse-engineering the
/// math.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum AdaptiveExposureReason {
    /// The adapter ran end-to-end with no clamping needed.
    Adapted,
    /// The computed value was below the configured minimum and was raised.
    ClampedMin,
    /// The computed value was above the configured maximum and was lowered.
    /// SNR-target may not be met; the UI surfaces this to the user.
    ClampedMax,
    /// Sky brightness was unavailable / invalid; fell back to nominal.
    Unavailable,
    /// Feature was disabled (globally or per-filter); using nominal.
    Disabled,
    /// The configured nominal duration is outside the adapter's
    /// [min, max] bounds. We still clamp into bounds but emit this reason
    /// so the user is told their configured nominal is silly for the
    /// configured min/max. Surfaced as a warning in validation too.
    OutOfNominalBounds,
}

impl AdaptiveExposureReason {
    /// Single-line label for the dashboard / progress feed.
    pub fn label(&self) -> &'static str {
        match self {
            AdaptiveExposureReason::Adapted => "adapted",
            AdaptiveExposureReason::ClampedMin => "clamped to min",
            AdaptiveExposureReason::ClampedMax => "clamped to max",
            AdaptiveExposureReason::Unavailable => "sky brightness unavailable",
            AdaptiveExposureReason::Disabled => "disabled",
            AdaptiveExposureReason::OutOfNominalBounds => "nominal out of bounds",
        }
    }
}

/// Compute the adapted exposure for a single capture.
///
/// Pure function — no side effects, deterministic for a given input set.
/// Designed to be cheap enough to call before every burst (it's a handful
/// of FLOPs).
///
/// Returns a fallback `AdaptiveExposureDecision { adapted_secs == nominal_secs }`
/// when the feature is off / unavailable so the caller can use a single
/// uniform code path (`decision.adapted_secs`) regardless of whether
/// adaptation actually ran.
pub fn compute_adaptive_exposure(
    config: Option<&AdaptiveExposureConfig>,
    nominal_secs: f64,
    filter: Option<&str>,
    current_sky_brightness_mag: Option<f64>,
) -> AdaptiveExposureDecision {
    // No config at all -> disabled fallback.
    let Some(config) = config else {
        return AdaptiveExposureDecision {
            adapted_secs: nominal_secs,
            nominal_secs,
            sky_brightness_mag: current_sky_brightness_mag,
            reason: AdaptiveExposureReason::Disabled,
        };
    };

    if !config.is_enabled_for_filter(filter) {
        return AdaptiveExposureDecision {
            adapted_secs: nominal_secs,
            nominal_secs,
            sky_brightness_mag: current_sky_brightness_mag,
            reason: AdaptiveExposureReason::Disabled,
        };
    }

    // Sky brightness must be present and finite + positive. Mag/arcsec² is
    // physically in roughly [16, 23]; <= 0 / NaN means the tracker hasn't
    // converged yet.
    let Some(mag) = current_sky_brightness_mag else {
        return AdaptiveExposureDecision {
            adapted_secs: nominal_secs,
            nominal_secs,
            sky_brightness_mag: None,
            reason: AdaptiveExposureReason::Unavailable,
        };
    };
    if !mag.is_finite() || mag <= 0.0 {
        return AdaptiveExposureDecision {
            adapted_secs: nominal_secs,
            nominal_secs,
            sky_brightness_mag: None,
            reason: AdaptiveExposureReason::Unavailable,
        };
    }

    let min = config.min_for_filter(filter);
    let max = config.max_for_filter(filter);
    // A defensive guard: if a user has min > max, both clamps fight each
    // other. Validation rule `AdaptiveExposureBoundsRule` flags this as an
    // error before the sequence runs; at runtime we just degenerate to
    // "clamp to max" so the camera still captures.
    let (eff_min, eff_max) = if min > max { (max, max) } else { (min, max) };

    // Flux ratio: 10^((mag_ref − mag_cur) / 2.5).
    // mag_ref − mag_cur > 0  =>  current sky brighter  =>  ratio > 1  =>  stretch exposure.
    let delta_mag = config.reference_sky_brightness_mag - mag;
    let ratio = 10f64.powf(delta_mag / 2.5);
    let raw = nominal_secs * ratio;

    // Clamp into the effective bounds and choose the reason flag.
    let mut reason = AdaptiveExposureReason::Adapted;
    let clamped = if raw < eff_min {
        reason = AdaptiveExposureReason::ClampedMin;
        eff_min
    } else if raw > eff_max {
        reason = AdaptiveExposureReason::ClampedMax;
        eff_max
    } else {
        raw
    };

    // OutOfNominalBounds takes precedence over a generic ClampedMin/Max
    // (which would imply the live conditions caused the clamp), because
    // the user wants to be told their *config* is misshapen.
    if nominal_secs < eff_min || nominal_secs > eff_max {
        reason = AdaptiveExposureReason::OutOfNominalBounds;
    }

    AdaptiveExposureDecision {
        adapted_secs: clamped,
        nominal_secs,
        sky_brightness_mag: Some(mag),
        reason,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn close(a: f64, b: f64, tol: f64) -> bool {
        (a - b).abs() < tol
    }

    #[test]
    fn disabled_when_global_flag_off() {
        let cfg = AdaptiveExposureConfig {
            enabled: false,
            ..AdaptiveExposureConfig::default()
        };
        let d = compute_adaptive_exposure(Some(&cfg), 60.0, Some("L"), Some(19.2));
        assert_eq!(d.adapted_secs, 60.0);
        assert_eq!(d.reason, AdaptiveExposureReason::Disabled);
    }

    #[test]
    fn disabled_when_per_filter_excluded() {
        let mut cfg = AdaptiveExposureConfig::default();
        cfg.per_filter_enabled.insert("L".into(), true);
        // R / G / B are absent from the map; with a non-empty per-filter
        // map, absent filters are not opted in.
        let d = compute_adaptive_exposure(Some(&cfg), 120.0, Some("R"), Some(19.2));
        assert_eq!(d.adapted_secs, 120.0);
        assert_eq!(d.reason, AdaptiveExposureReason::Disabled);
    }

    #[test]
    fn enabled_per_filter_runs_the_math() {
        let mut cfg = AdaptiveExposureConfig::default();
        cfg.per_filter_enabled.insert("L".into(), true);
        let d = compute_adaptive_exposure(Some(&cfg), 60.0, Some("L"), Some(19.2));
        // Δmag = 21.5 - 19.2 = 2.3; ratio = 10^(2.3/2.5) ≈ 8.32; raw ≈ 499.4
        // Default max_exposure_secs = 600 -> not clamped.
        assert!(close(d.adapted_secs, 60.0 * 10f64.powf(2.3 / 2.5), 1e-6));
        assert_eq!(d.reason, AdaptiveExposureReason::Adapted);
        assert_eq!(d.sky_brightness_mag, Some(19.2));
    }

    #[test]
    fn unavailable_when_mag_missing() {
        let cfg = AdaptiveExposureConfig::default();
        let d = compute_adaptive_exposure(Some(&cfg), 60.0, Some("L"), None);
        assert_eq!(d.adapted_secs, 60.0);
        assert_eq!(d.reason, AdaptiveExposureReason::Unavailable);
        assert_eq!(d.sky_brightness_mag, None);
    }

    #[test]
    fn unavailable_when_mag_nan_or_nonpositive() {
        let cfg = AdaptiveExposureConfig::default();
        for bad in [f64::NAN, 0.0, -3.0] {
            let d = compute_adaptive_exposure(Some(&cfg), 60.0, Some("L"), Some(bad));
            assert_eq!(d.adapted_secs, 60.0);
            assert_eq!(d.reason, AdaptiveExposureReason::Unavailable);
        }
    }

    #[test]
    fn clamps_to_min_when_sky_is_darker_than_reference() {
        let cfg = AdaptiveExposureConfig {
            min_exposure_secs: 30.0,
            max_exposure_secs: 600.0,
            ..AdaptiveExposureConfig::default()
        };
        // mag = 23 (very dark, darker than reference 21.5) ->
        //   delta = 21.5 - 23 = -1.5  -> ratio = 10^(-0.6) ≈ 0.251
        //   raw  = 60 * 0.251 ≈ 15s  -> below min_exposure_secs = 30
        let d = compute_adaptive_exposure(Some(&cfg), 60.0, Some("L"), Some(23.0));
        assert_eq!(d.adapted_secs, 30.0);
        assert_eq!(d.reason, AdaptiveExposureReason::ClampedMin);
    }

    #[test]
    fn clamps_to_max_when_sky_is_very_bright() {
        let cfg = AdaptiveExposureConfig {
            min_exposure_secs: 10.0,
            max_exposure_secs: 300.0,
            ..AdaptiveExposureConfig::default()
        };
        // mag = 18 (Bortle 8, very bright) ->
        //   delta = 21.5 - 18 = 3.5 -> ratio = 10^(1.4) ≈ 25.1
        //   raw  = 60 * 25.1 ≈ 1507s -> way above max = 300
        let d = compute_adaptive_exposure(Some(&cfg), 60.0, Some("L"), Some(18.0));
        assert_eq!(d.adapted_secs, 300.0);
        assert_eq!(d.reason, AdaptiveExposureReason::ClampedMax);
    }

    #[test]
    fn per_filter_min_and_max_override_globals() {
        let mut cfg = AdaptiveExposureConfig {
            min_exposure_secs: 5.0,
            max_exposure_secs: 1200.0,
            ..AdaptiveExposureConfig::default()
        };
        cfg.per_filter_min_secs.insert("L".into(), 30.0);
        cfg.per_filter_max_secs.insert("L".into(), 200.0);
        // Same input as the clamps_to_max test but per-filter cap is 200 s.
        let d = compute_adaptive_exposure(Some(&cfg), 60.0, Some("L"), Some(18.0));
        assert_eq!(d.adapted_secs, 200.0);
        assert_eq!(d.reason, AdaptiveExposureReason::ClampedMax);
        // And the dark side too — per-filter min wins.
        let d2 = compute_adaptive_exposure(Some(&cfg), 60.0, Some("L"), Some(23.0));
        assert_eq!(d2.adapted_secs, 30.0);
        assert_eq!(d2.reason, AdaptiveExposureReason::ClampedMin);
    }

    #[test]
    fn no_filter_falls_back_to_global_enable() {
        let cfg = AdaptiveExposureConfig::default();
        // No filter at all (mono setup); global enable governs.
        let d = compute_adaptive_exposure(Some(&cfg), 60.0, None, Some(19.2));
        assert_eq!(d.reason, AdaptiveExposureReason::Adapted);
        assert!(close(d.adapted_secs, 60.0 * 10f64.powf(2.3 / 2.5), 1e-6));
    }

    #[test]
    fn no_config_is_disabled() {
        let d = compute_adaptive_exposure(None, 60.0, Some("L"), Some(19.2));
        assert_eq!(d.adapted_secs, 60.0);
        assert_eq!(d.reason, AdaptiveExposureReason::Disabled);
    }

    #[test]
    fn out_of_nominal_bounds_is_surfaced() {
        let cfg = AdaptiveExposureConfig {
            min_exposure_secs: 10.0,
            max_exposure_secs: 60.0,
            ..AdaptiveExposureConfig::default()
        };
        // Nominal 600 is far outside [10, 60]; the user obviously
        // misconfigured. We clamp into bounds and surface
        // `OutOfNominalBounds` rather than `ClampedMax` so the UI tells
        // them to look at the config.
        let d = compute_adaptive_exposure(Some(&cfg), 600.0, Some("L"), Some(21.5));
        assert!(d.adapted_secs >= 10.0 && d.adapted_secs <= 60.0);
        assert_eq!(d.reason, AdaptiveExposureReason::OutOfNominalBounds);
    }

    #[test]
    fn min_greater_than_max_degenerates_safely() {
        let cfg = AdaptiveExposureConfig {
            min_exposure_secs: 300.0,
            max_exposure_secs: 60.0,
            ..AdaptiveExposureConfig::default()
        };
        // We pin to max; the validation rule will fire an error in the UI
        // but at runtime we still capture rather than crashing.
        let d = compute_adaptive_exposure(Some(&cfg), 60.0, Some("L"), Some(19.2));
        assert_eq!(d.adapted_secs, 60.0);
    }

    #[test]
    fn round_trip_serialize_deserialize() {
        let mut cfg = AdaptiveExposureConfig {
            target_snr: 25.0,
            reference_sky_brightness_mag: 21.0,
            min_exposure_secs: 10.0,
            max_exposure_secs: 400.0,
            enabled: true,
            ..AdaptiveExposureConfig::default()
        };
        cfg.per_filter_enabled.insert("L".into(), true);
        cfg.per_filter_enabled.insert("R".into(), false);
        cfg.per_filter_min_secs.insert("L".into(), 30.0);
        cfg.per_filter_max_secs.insert("L".into(), 240.0);
        let s = serde_json::to_string(&cfg).expect("serialize");
        let back: AdaptiveExposureConfig = serde_json::from_str(&s).expect("deserialize");
        assert_eq!(back, cfg);
    }

    #[test]
    fn empty_per_filter_map_means_apply_everywhere() {
        let cfg = AdaptiveExposureConfig::default();
        assert!(cfg.is_enabled_for_filter(Some("L")));
        assert!(cfg.is_enabled_for_filter(Some("Ha")));
        assert!(cfg.is_enabled_for_filter(None));
    }

    #[test]
    fn populated_per_filter_map_is_opt_in_only() {
        let mut cfg = AdaptiveExposureConfig::default();
        cfg.per_filter_enabled.insert("L".into(), true);
        assert!(cfg.is_enabled_for_filter(Some("L")));
        assert!(!cfg.is_enabled_for_filter(Some("R")));
        // Mono camera (filter=None) keeps the implicit-global behaviour
        // even when the map is populated — the user has no filter wheel
        // to opt in/out per filter.
        assert!(cfg.is_enabled_for_filter(None));
    }

    /// Worked example from the brief: L:60s nominal, ref=21.5 mag/arcsec²,
    /// site 19.2 (Bortle 6). The brief promises "each L sub is actually
    /// ~142s". Note that exact value depends on the brief author's mental
    /// math; our straight Pogson formula yields ≈ 499s (a 2.3 mag flux
    /// ratio is huge). We document the actual physics here and let the
    /// per-filter max ceiling do the practical clamping.
    #[test]
    fn worked_example_from_brief() {
        let cfg = AdaptiveExposureConfig::default();
        let d = compute_adaptive_exposure(Some(&cfg), 60.0, Some("L"), Some(19.2));
        let expected = 60.0 * 10f64.powf(2.3 / 2.5);
        assert!(close(d.adapted_secs, expected, 1e-6));
        // Pin the actual value (≈ 499.211) so a change in the math is
        // caught. The Pogson result is the source of truth here, not a
        // mental-math estimate of "~142s" from a different scaling law.
        assert!(
            close(d.adapted_secs, 499.21, 0.5),
            "actual = {}",
            d.adapted_secs
        );
    }

    #[test]
    fn rgb_fixed_lum_adaptive_matches_brief() {
        // Brief says: "R/G/B fixed at user-configured times (per-filter
        // override disabled). User configures L:60s nominal, adaptive
        // enabled at SNR=30, reference=21.5 mag/arcsec². Runs at Bortle 6
        // (~19.2). Each L sub is actually adapted; RGB stays at the
        // nominal duration."
        let mut cfg = AdaptiveExposureConfig::default();
        cfg.per_filter_enabled.insert("L".into(), true);
        cfg.per_filter_enabled.insert("R".into(), false);
        cfg.per_filter_enabled.insert("G".into(), false);
        cfg.per_filter_enabled.insert("B".into(), false);
        let l = compute_adaptive_exposure(Some(&cfg), 60.0, Some("L"), Some(19.2));
        let r = compute_adaptive_exposure(Some(&cfg), 120.0, Some("R"), Some(19.2));
        let g = compute_adaptive_exposure(Some(&cfg), 120.0, Some("G"), Some(19.2));
        let b = compute_adaptive_exposure(Some(&cfg), 120.0, Some("B"), Some(19.2));
        assert_eq!(l.reason, AdaptiveExposureReason::Adapted);
        // RGB stays at nominal:
        assert_eq!(r.adapted_secs, 120.0);
        assert_eq!(g.adapted_secs, 120.0);
        assert_eq!(b.adapted_secs, 120.0);
        assert_eq!(r.reason, AdaptiveExposureReason::Disabled);
    }

    #[test]
    fn label_text_for_every_reason() {
        // Future-proofing: if a new variant is added without a label, the
        // dashboard would render the Debug form. Force the maintainer to
        // visit `label()`.
        for r in [
            AdaptiveExposureReason::Adapted,
            AdaptiveExposureReason::ClampedMin,
            AdaptiveExposureReason::ClampedMax,
            AdaptiveExposureReason::Unavailable,
            AdaptiveExposureReason::Disabled,
            AdaptiveExposureReason::OutOfNominalBounds,
        ] {
            assert!(!r.label().is_empty());
        }
    }
}
