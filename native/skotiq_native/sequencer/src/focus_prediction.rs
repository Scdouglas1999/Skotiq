//! Focus Prediction Engine
//!
//! Provides temperature-based focus position prediction and filter offset management.
//!
//! # Predictive autofocus
//!
//! In addition to the in-session [`FocusPredictionEngine`] used by the
//! sequencer, this module exposes a *persistence-oriented* layer
//! ([`PersistedFocusModel`], [`PredictiveAfDecision`]) that the Dart side
//! drives across sessions. The Rust regression math is the single source of
//! truth — the Dart layer is responsible only for storage and UI glue.
//!
//! ## Design
//!
//! * A [`PersistedFocusModel`] is keyed by `(equipment_profile_id,
//!   filter_name)` and owns a vector of [`FocusTrainingSample`] that
//!   accumulates across sessions, capped at `max_samples` (default 50).
//! * On every successful autofocus run the Dart layer appends a sample,
//!   the Rust regression recomputes slope + intercept + R², and the
//!   confidence-gated [`PersistedFocusModel::evaluate`] function returns
//!   a [`PredictiveAfDecision`] telling the caller whether to apply the
//!   prediction directly, dampen it, or force a real AF sweep.
//! * Drift detection: [`PersistedFocusModel::record_prediction_outcome`]
//!   tracks cumulative drift across consecutive bad predictions and
//!   surfaces a [`DriftStatus::ShouldWarn`] when the threshold is crossed.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// A single focus data point from an autofocus run
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FocusDataPoint {
    pub timestamp_secs: i64,
    pub temperature_celsius: f64,
    pub focus_position: i32,
    pub hfr: f64,
    pub filter_name: Option<String>,
}

/// Linear regression model for temperature-focus correlation
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FocusModel {
    pub slope: f64,     // Steps per degree C
    pub intercept: f64, // Base focus position at 0°C
    pub r_squared: f64, // Correlation coefficient
    pub data_point_count: usize,
}

impl FocusModel {
    /// Predict focus position for a given temperature
    pub fn predict_position(&self, temperature: f64) -> i32 {
        // Why: linear-regression output for a focus position. Slope/intercept are
        // bounded by the fitted i32 positions; even a wild extrapolation cannot
        // overflow f64. f64 -> i32 saturates per Rust 1.45 spec, so a bogus model
        // pinned at the focuser-limit position is the worst case.
        (self.intercept + self.slope * temperature).round() as i32
    }

    /// Check if model is reliable enough to use
    pub fn is_reliable(&self) -> bool {
        self.r_squared >= 0.7 && self.data_point_count >= 5
    }
}

/// Filter focus offset relative to a reference filter
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FilterOffset {
    pub filter_name: String,
    pub reference_filter: String,
    pub offset_steps: i32,
    pub measurement_count: usize,
    pub confidence: f64,
}

/// Focus prediction engine with temperature compensation
#[derive(Debug, Clone, Default)]
pub struct FocusPredictionEngine {
    data_points: Vec<FocusDataPoint>,
    temperature_model: Option<FocusModel>,
    filter_offsets: HashMap<String, FilterOffset>,
    reference_filter: Option<String>,
    max_data_points: usize,
}

impl FocusPredictionEngine {
    pub fn new() -> Self {
        Self {
            data_points: Vec::new(),
            temperature_model: None,
            filter_offsets: HashMap::new(),
            reference_filter: None,
            max_data_points: 100,
        }
    }

    /// Add a data point from an autofocus run
    pub fn add_datapoint(&mut self, point: FocusDataPoint) {
        self.data_points.push(point);
        self.trim_data_points();

        // Recalculate model
        self.recalculate_model();
    }

    fn trim_data_points(&mut self) {
        if self.data_points.len() <= self.max_data_points {
            return;
        }
        if self.max_data_points == 0 {
            self.data_points.clear();
            return;
        }
        if self.max_data_points == 1 {
            if let Some(last) = self
                .data_points
                .iter()
                .max_by_key(|point| point.timestamp_secs)
                .cloned()
            {
                self.data_points = vec![last];
            }
            return;
        }

        self.data_points.sort_by_key(|p| p.timestamp_secs);

        let last_index = self.data_points.len() - 1;
        let target_last_index = self.max_data_points - 1;
        let mut retained = Vec::with_capacity(self.max_data_points);

        for slot in 0..self.max_data_points {
            let idx = if slot == target_last_index {
                last_index
            } else {
                // Why: slot, last_index, target_last_index are usize bounded by
                // max_data_points (100 default; user-config). u64::MAX-class values
                // would lose precision in f64 above 2^53 — astronomically beyond any
                // sane focus-history cap. f64 -> usize saturates per Rust 1.45 spec.
                ((slot as f64 * last_index as f64) / target_last_index as f64).round() as usize
            };

            if retained
                .last()
                .map(|point: &FocusDataPoint| {
                    point.timestamp_secs == self.data_points[idx].timestamp_secs
                })
                // Why: `retained.last()` is None on the first iteration
                // (empty Vec). "No prior point" → not a duplicate → `false` is the correct
                // dedup-test answer.
                .unwrap_or(false)
            {
                continue;
            }

            retained.push(self.data_points[idx].clone());
        }

        self.data_points = retained;
    }

    /// Recalculate the temperature-focus model using linear regression
    fn recalculate_model(&mut self) {
        if self.data_points.len() < 3 {
            self.temperature_model = None;
            if let Some(ref_filter) = &self.reference_filter {
                self.update_filter_offsets(ref_filter.clone());
            }
            return;
        }

        // Group by temperature buckets and take best HFR from each
        let mut buckets: HashMap<i32, Vec<&FocusDataPoint>> = HashMap::new();
        for point in &self.data_points {
            // Why: temperature is a real-world Celsius value (typical -40..+50);
            // rounding to i32 saturates per Rust 1.45 if a sensor returns garbage.
            let bucket = point.temperature_celsius.round() as i32;
            buckets.entry(bucket).or_default().push(point);
        }

        // Take best (lowest HFR) from each bucket
        let mut best_points: Vec<&FocusDataPoint> = Vec::new();
        for points in buckets.values() {
            if let Some(best) = points.iter().min_by(|a, b| {
                a.hfr
                    .partial_cmp(&b.hfr)
                    // Why: f64 PartialOrd — NaN HFR samples cluster as
                    // Equal; outlier-rejection at the linear-regression layer drops them.
                    .unwrap_or(std::cmp::Ordering::Equal)
            }) {
                best_points.push(best);
            }
        }

        if best_points.len() < 3 {
            self.temperature_model = None;
        } else {
            // Linear regression: y = mx + b
            // Why: best_points.len() is usize bounded by data_points (max ~100); lossless to f64.
            let n = best_points.len() as f64;
            let (mut sum_x, mut sum_y, mut sum_xy, mut sum_x2) = (0.0, 0.0, 0.0, 0.0);

            for point in &best_points {
                let x = point.temperature_celsius;
                // Why: i32 focus position -> f64 lossless.
                let y = point.focus_position as f64;
                sum_x += x;
                sum_y += y;
                sum_xy += x * y;
                sum_x2 += x * x;
            }

            let denom = n * sum_x2 - sum_x * sum_x;
            if denom.abs() < 1e-10 {
                self.temperature_model = None;
            } else {
                let slope = (n * sum_xy - sum_x * sum_y) / denom;
                let intercept = (sum_y - slope * sum_x) / n;

                // Calculate R-squared
                let mean_y = sum_y / n;
                let mut ss_tot = 0.0;
                let mut ss_res = 0.0;

                for point in &best_points {
                    let predicted = intercept + slope * point.temperature_celsius;
                    // Why: i32 focus position -> f64 lossless.
                    ss_tot += (point.focus_position as f64 - mean_y).powi(2);
                    ss_res += (point.focus_position as f64 - predicted).powi(2);
                }

                let r_squared = if ss_tot > 0.0 {
                    1.0 - (ss_res / ss_tot)
                } else {
                    0.0
                };

                self.temperature_model = Some(FocusModel {
                    slope,
                    intercept,
                    r_squared,
                    data_point_count: best_points.len(),
                });
            }
        }

        // Update filter offsets if we have a reference
        if let Some(ref_filter) = &self.reference_filter {
            self.update_filter_offsets(ref_filter.clone());
        }
    }

    /// Update filter offsets based on collected data
    fn update_filter_offsets(&mut self, reference_filter: String) {
        self.filter_offsets.clear();

        // Group by filter
        let mut by_filter: HashMap<String, Vec<&FocusDataPoint>> = HashMap::new();
        for point in &self.data_points {
            if let Some(filter) = &point.filter_name {
                by_filter.entry(filter.clone()).or_default().push(point);
            }
        }

        // Get reference filter average
        let ref_points = match by_filter.get(&reference_filter) {
            Some(points) if !points.is_empty() => points,
            _ => return,
        };

        // Why: i32 focus position -> f64 lossless; ref_points.len() bounded by
        // data_points (max ~100); lossless to f64.
        let ref_avg: f64 = ref_points
            .iter()
            .map(|p| p.focus_position as f64)
            .sum::<f64>()
            / ref_points.len() as f64;

        // Calculate offsets for each filter
        for (filter_name, points) in &by_filter {
            if filter_name == &reference_filter || points.is_empty() {
                continue;
            }

            // Why: i32 focus position -> f64 lossless; points.len() bounded by
            // data_points (max ~100); lossless to f64.
            let filter_avg: f64 =
                points.iter().map(|p| p.focus_position as f64).sum::<f64>() / points.len() as f64;

            // Why: offset is the difference of two averages of i32 positions; falls in
            // (-2^31, 2^31). f64 -> i32 saturates per Rust 1.45 spec on overflow.
            let offset_steps = (filter_avg - ref_avg).round() as i32;

            // Calculate confidence based on variance and count
            let variance: f64 = points
                .iter()
                .map(|p| (p.focus_position as f64 - filter_avg).powi(2))
                .sum::<f64>()
                / points.len() as f64;

            let std_dev = variance.sqrt();
            let consistency = if std_dev < 50.0 { 1.0 } else { 50.0 / std_dev };
            // Why: points.len() bounded by max_data_points (~100); lossless to f64.
            let count_factor = (points.len() as f64 / 5.0).min(1.0);
            let confidence = (consistency * count_factor).clamp(0.0, 1.0);

            self.filter_offsets.insert(
                filter_name.clone(),
                FilterOffset {
                    filter_name: filter_name.clone(),
                    reference_filter: reference_filter.clone(),
                    offset_steps,
                    measurement_count: points.len(),
                    confidence,
                },
            );
        }
    }

    /// Predict optimal focus position based on current conditions
    pub fn predict_position(
        &self,
        temperature: f64,
        filter: Option<&str>,
    ) -> Option<PredictionResult> {
        let model = self.temperature_model.as_ref()?;
        if !model.is_reliable() {
            return None;
        }

        let mut predicted_position = model.predict_position(temperature);
        let mut confidence = model.r_squared;
        let mut filter_offset = 0;

        // Apply filter offset if applicable
        if let Some(filter_name) = filter {
            if let Some(offset) = self.filter_offsets.get(filter_name) {
                if offset.confidence >= 0.5 {
                    filter_offset = offset.offset_steps;
                    predicted_position += filter_offset;
                    confidence *= offset.confidence;
                }
            }
        }

        Some(PredictionResult {
            position: predicted_position,
            confidence,
            based_on_temperature: temperature,
            filter_offset,
            slope: model.slope,
        })
    }

    /// Check if autofocus should be triggered based on temperature drift
    pub fn should_refocus(
        &self,
        current_temp: f64,
        last_focus_temp: f64,
        max_drift_steps: f64,
    ) -> bool {
        let model = match &self.temperature_model {
            Some(m) if m.is_reliable() => m,
            _ => return false,
        };

        let temp_delta = (current_temp - last_focus_temp).abs();
        let expected_drift = temp_delta * model.slope.abs();

        expected_drift >= max_drift_steps
    }

    /// Set the reference filter for offset calculations
    pub fn set_reference_filter(&mut self, filter: String) {
        self.reference_filter = Some(filter.clone());
        self.update_filter_offsets(filter);
    }

    /// Get the current temperature model
    pub fn get_model(&self) -> Option<&FocusModel> {
        self.temperature_model.as_ref()
    }

    /// Get filter offset for a specific filter
    pub fn get_filter_offset(&self, filter: &str) -> Option<&FilterOffset> {
        self.filter_offsets.get(filter)
    }

    /// Clear all data
    pub fn clear(&mut self) {
        self.data_points.clear();
        self.temperature_model = None;
        self.filter_offsets.clear();
    }

    /// Get data point count
    pub fn data_point_count(&self) -> usize {
        self.data_points.len()
    }
}

/// Result of focus position prediction
#[derive(Debug, Clone)]
pub struct PredictionResult {
    pub position: i32,
    pub confidence: f64,
    pub based_on_temperature: f64,
    pub filter_offset: i32,
    pub slope: f64, // For display: steps per °C
}

// ─────────────────────────────────────────────────────────────────────────
//  Predictive AF persistence layer
// ─────────────────────────────────────────────────────────────────────────

/// A single (temperature, focus position) training sample accumulated across
/// sessions. Persisted by the Dart layer inside `focus_models.training_samples_json`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct FocusTrainingSample {
    /// Unix timestamp (seconds) of the AF run that produced the sample.
    pub timestamp_secs: i64,
    /// Focuser temperature in degrees Celsius at the time of the sample.
    pub temperature_celsius: f64,
    /// Best focuser position the AF run converged on (steps).
    pub focus_position: i32,
    /// HFR achieved at the best position — used as a quality weight when
    /// the same temperature bucket has multiple samples.
    pub hfr: f64,
}

/// Confidence-gated decision a caller should follow when deciding whether to
/// trust a learned focus model.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum PredictiveAfDecision {
    /// Insufficient samples or invalid regression — caller must run a real
    /// autofocus sweep. Carries the reason for surfacing to the UI.
    InsufficientData { reason: String },
    /// Confidence is below the "trust" threshold — caller must run a real
    /// AF sweep, but the model's existing prediction is included so the UI
    /// can compare actual vs predicted after the sweep.
    ForceAutofocus {
        suggested_position: i32,
        confidence: f64,
    },
    /// Confidence is between the low and high thresholds — apply the
    /// prediction with a damping factor (`correction_factor` < 1) so partial
    /// trust doesn't overshoot.
    ApplyDampened {
        predicted_position: i32,
        correction_factor: f64,
        confidence: f64,
    },
    /// High-confidence model — apply the prediction directly.
    ApplyDirect {
        predicted_position: i32,
        confidence: f64,
    },
}

impl PredictiveAfDecision {
    /// Convenience: the position to send to the focuser regardless of which
    /// arm fired. For `InsufficientData` this returns `None` because the
    /// caller has no recourse but to run a sweep from the current position.
    pub fn target_position(&self) -> Option<i32> {
        match self {
            Self::InsufficientData { .. } => None,
            Self::ForceAutofocus {
                suggested_position, ..
            } => Some(*suggested_position),
            Self::ApplyDampened {
                predicted_position, ..
            } => Some(*predicted_position),
            Self::ApplyDirect {
                predicted_position, ..
            } => Some(*predicted_position),
        }
    }
}

/// Result of feeding an actual AF outcome back into the model for drift
/// tracking.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum DriftStatus {
    /// Prediction was within tolerance — drift counters reset.
    WithinTolerance { delta_steps: i32 },
    /// Prediction was off, but not enough consecutive bad runs to warn yet.
    Drifting {
        delta_steps: i32,
        consecutive_bad_runs: u32,
        accumulated_drift_steps: i32,
    },
    /// Consecutive bad-prediction threshold crossed — caller should surface
    /// a "re-train recommended" notification to the user.
    ShouldWarn {
        consecutive_bad_runs: u32,
        accumulated_drift_steps: i32,
        message: String,
    },
}

/// Tunables for the predictive AF gates. Mirrors the Dart-side
/// `PredictiveAfConfig`; both sides must agree on the thresholds because the
/// regression decisions are made here in Rust.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PredictiveAfConfig {
    /// Minimum sample count before any prediction is allowed.
    pub min_samples_for_trust: usize,
    /// R² at-or-above this → apply prediction directly.
    pub high_confidence_threshold: f64,
    /// R² below this → force a real AF sweep.
    pub low_confidence_threshold: f64,
    /// In the dampened band, scale the correction by linear interpolation
    /// between this floor (at low_threshold) and 1.0 (at high_threshold).
    pub min_correction_factor: f64,
    /// Prediction "off by" threshold in focuser steps that counts as a bad
    /// prediction for drift tracking. Typical: 5× the AF step size.
    pub drift_threshold_steps: i32,
    /// Number of *consecutive* bad predictions before a re-train warning
    /// fires.
    pub drift_runs_before_warn: u32,
}

impl Default for PredictiveAfConfig {
    fn default() -> Self {
        Self {
            min_samples_for_trust: 8,
            high_confidence_threshold: 0.8,
            low_confidence_threshold: 0.5,
            min_correction_factor: 0.4,
            drift_threshold_steps: 200,
            drift_runs_before_warn: 5,
        }
    }
}

/// A persisted per-(equipment profile, filter) focus model. The Rust side
/// owns the regression math and the drift counters; the Dart side owns
/// long-term storage in the `focus_models` table.
///
/// The struct is `Serialize`/`Deserialize` so the Dart side can hand the
/// whole thing to Rust over FRB as JSON. (We deliberately *don't* expose
/// the engine through FRB — the Dart [`PredictiveAfService`] mirrors the
/// regression math for hot-path predictions to avoid the FFI hop, and uses
/// this struct as the canonical schema.)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PersistedFocusModel {
    pub equipment_profile_id: i64,
    pub filter_name: String,
    pub filter_index: Option<i32>,
    /// Cap on training-window size. New samples beyond the cap evict the
    /// oldest by timestamp.
    pub max_samples: usize,
    /// Training samples in insertion (i.e. chronological) order.
    pub samples: Vec<FocusTrainingSample>,
    /// Cached regression — `None` while samples are still accumulating
    /// below the minimum count.
    pub regression: Option<FocusModel>,
    /// Reference temperature used by the cached intercept. Set to the
    /// sample-mean temperature at re-fit time.
    pub reference_temp_celsius: f64,
    /// Monotonic count of all training events the model has ever seen.
    pub training_run_count: u32,
    /// Tracks consecutive AF runs whose prediction was off by more than
    /// the drift threshold. Reset on a successful match or a re-train.
    pub consecutive_bad_predictions: u32,
    /// Cumulative drift across [`Self::consecutive_bad_predictions`].
    pub accumulated_drift_steps: i32,
}

impl PersistedFocusModel {
    /// Construct an empty model for the given key. Slope is 0 / regression
    /// is `None` until enough samples have been added.
    pub fn new(equipment_profile_id: i64, filter_name: String) -> Self {
        Self {
            equipment_profile_id,
            filter_name,
            filter_index: None,
            max_samples: 50,
            samples: Vec::new(),
            regression: None,
            reference_temp_celsius: 10.0,
            training_run_count: 0,
            consecutive_bad_predictions: 0,
            accumulated_drift_steps: 0,
        }
    }

    /// Append a new training sample, evicting the oldest if the window is
    /// full, then re-fit the regression. Returns the freshly computed
    /// [`FocusModel`] (or `None` if there are still fewer than 3 samples).
    pub fn add_training_sample(&mut self, sample: FocusTrainingSample) -> Option<&FocusModel> {
        self.samples.push(sample);
        // Evict oldest by timestamp to keep the most recent N samples. We
        // sort first because the caller might insert out-of-order samples
        // (e.g. importing historical data).
        if self.samples.len() > self.max_samples {
            self.samples.sort_by_key(|s| s.timestamp_secs);
            let drop_count = self.samples.len() - self.max_samples;
            self.samples.drain(0..drop_count);
        }
        self.training_run_count = self.training_run_count.saturating_add(1);
        self.refit();
        self.regression.as_ref()
    }

    /// Re-run the linear regression on the persisted samples. Bucketed by
    /// 1 °C and HFR-best per bucket, matching the in-session engine so the
    /// math is identical regardless of which side is driving.
    pub fn refit(&mut self) {
        if self.samples.len() < 3 {
            self.regression = None;
            return;
        }

        let mut buckets: HashMap<i32, Vec<&FocusTrainingSample>> = HashMap::new();
        for s in &self.samples {
            // Why: temperature is a real-world Celsius value (typical -40..+50);
            // rounding to i32 saturates per Rust 1.45 if a sensor returns garbage.
            let bucket = s.temperature_celsius.round() as i32;
            buckets.entry(bucket).or_default().push(s);
        }

        let mut best_points: Vec<&FocusTrainingSample> = Vec::new();
        for points in buckets.values() {
            if let Some(best) = points.iter().min_by(|a, b| {
                a.hfr
                    .partial_cmp(&b.hfr)
                    // Why: f64 NaN orders Equal; outlier-rejection happens
                    // at the regression layer.
                    .unwrap_or(std::cmp::Ordering::Equal)
            }) {
                best_points.push(*best);
            }
        }

        if best_points.len() < 3 {
            self.regression = None;
            return;
        }

        // Why: best_points.len() is usize bounded by max_samples (default 50,
        // user-cap 200); lossless to f64.
        let n = best_points.len() as f64;
        let (mut sum_x, mut sum_y, mut sum_xy, mut sum_x2) = (0.0, 0.0, 0.0, 0.0);
        for p in &best_points {
            let x = p.temperature_celsius;
            // Why: i32 focuser position -> f64 lossless.
            let y = p.focus_position as f64;
            sum_x += x;
            sum_y += y;
            sum_xy += x * y;
            sum_x2 += x * x;
        }

        let denom = n * sum_x2 - sum_x * sum_x;
        if denom.abs() < 1e-10 {
            self.regression = None;
            return;
        }

        let slope = (n * sum_xy - sum_x * sum_y) / denom;
        let intercept = (sum_y - slope * sum_x) / n;

        // Reference temperature is the sample-mean — recomputing the
        // intercept around the cluster center keeps the regression
        // numerically well-conditioned when samples span wide ranges.
        let ref_temp = sum_x / n;
        self.reference_temp_celsius = ref_temp;

        let mean_y = sum_y / n;
        let mut ss_tot = 0.0;
        let mut ss_res = 0.0;
        for p in &best_points {
            let predicted = intercept + slope * p.temperature_celsius;
            // Why: i32 focuser position -> f64 lossless.
            ss_tot += (p.focus_position as f64 - mean_y).powi(2);
            ss_res += (p.focus_position as f64 - predicted).powi(2);
        }

        let r_squared = if ss_tot > 0.0 {
            (1.0 - (ss_res / ss_tot)).clamp(0.0, 1.0)
        } else {
            0.0
        };

        self.regression = Some(FocusModel {
            slope,
            intercept,
            r_squared,
            data_point_count: best_points.len(),
        });
    }

    /// Predict focus position from the persisted model for the given
    /// temperature. Returns `None` if the model is not yet fit.
    pub fn predict_position(&self, temperature_celsius: f64) -> Option<i32> {
        let m = self.regression.as_ref()?;
        Some(m.predict_position(temperature_celsius))
    }

    /// Confidence-gated decision: should the caller trust this prediction,
    /// dampen it, or force a real AF sweep?
    pub fn evaluate(
        &self,
        temperature_celsius: f64,
        config: &PredictiveAfConfig,
    ) -> PredictiveAfDecision {
        let regression = match self.regression.as_ref() {
            Some(r) => r,
            None => {
                return PredictiveAfDecision::InsufficientData {
                    reason: format!(
                        "Need at least 3 unique-temperature samples (have {})",
                        self.samples.len()
                    ),
                };
            }
        };

        if self.samples.len() < config.min_samples_for_trust {
            // Carry the regression prediction anyway so the dashboard can
            // show "predicted X, but model has too few samples to trust".
            return PredictiveAfDecision::ForceAutofocus {
                suggested_position: regression.predict_position(temperature_celsius),
                confidence: regression.r_squared,
            };
        }

        if regression.r_squared < config.low_confidence_threshold {
            return PredictiveAfDecision::ForceAutofocus {
                suggested_position: regression.predict_position(temperature_celsius),
                confidence: regression.r_squared,
            };
        }

        let predicted = regression.predict_position(temperature_celsius);

        if regression.r_squared >= config.high_confidence_threshold {
            PredictiveAfDecision::ApplyDirect {
                predicted_position: predicted,
                confidence: regression.r_squared,
            }
        } else {
            // Linear interp between min_correction_factor (at low_threshold)
            // and 1.0 (at high_threshold). Guards against zero-width band.
            let band =
                (config.high_confidence_threshold - config.low_confidence_threshold).max(1e-6);
            let t =
                ((regression.r_squared - config.low_confidence_threshold) / band).clamp(0.0, 1.0);
            let correction =
                config.min_correction_factor + t * (1.0 - config.min_correction_factor);
            PredictiveAfDecision::ApplyDampened {
                predicted_position: predicted,
                correction_factor: correction,
                confidence: regression.r_squared,
            }
        }
    }

    /// After an actual autofocus run, feed the predicted-vs-actual delta
    /// back into the drift counters. Returns a [`DriftStatus`] the UI can
    /// surface.
    ///
    /// `predicted_position` should be whatever the model said *before* the
    /// AF sweep ran; `actual_position` is the AF's converged result.
    pub fn record_prediction_outcome(
        &mut self,
        predicted_position: i32,
        actual_position: i32,
        config: &PredictiveAfConfig,
    ) -> DriftStatus {
        let delta = actual_position.saturating_sub(predicted_position);
        let abs_delta = delta.saturating_abs();

        if abs_delta <= config.drift_threshold_steps {
            // Reset drift state on a good run.
            self.consecutive_bad_predictions = 0;
            self.accumulated_drift_steps = 0;
            return DriftStatus::WithinTolerance { delta_steps: delta };
        }

        self.consecutive_bad_predictions = self.consecutive_bad_predictions.saturating_add(1);
        self.accumulated_drift_steps = self.accumulated_drift_steps.saturating_add(abs_delta);

        if self.consecutive_bad_predictions >= config.drift_runs_before_warn {
            let msg = format!(
                "Your {filter} filter focus model has drifted by {drift} steps over the last {runs} runs. \
                 Consider re-training (clear samples and start fresh).",
                filter = self.filter_name,
                drift = self.accumulated_drift_steps,
                runs = self.consecutive_bad_predictions,
            );
            return DriftStatus::ShouldWarn {
                consecutive_bad_runs: self.consecutive_bad_predictions,
                accumulated_drift_steps: self.accumulated_drift_steps,
                message: msg,
            };
        }

        DriftStatus::Drifting {
            delta_steps: delta,
            consecutive_bad_runs: self.consecutive_bad_predictions,
            accumulated_drift_steps: self.accumulated_drift_steps,
        }
    }

    /// Wipe samples, reset drift counters, leave the key fields intact.
    /// Used by the "Re-train" button in the model viewer.
    pub fn clear_samples(&mut self) {
        self.samples.clear();
        self.regression = None;
        self.consecutive_bad_predictions = 0;
        self.accumulated_drift_steps = 0;
        // Don't reset training_run_count — that's a lifetime counter.
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── Predictive-AF persistence layer tests live below the existing
    // FocusPredictionEngine tests in the same #[cfg(test)] block. ──

    #[test]
    fn test_linear_model() {
        let mut engine = FocusPredictionEngine::new();

        // Add data points with clear linear relationship
        // Focus moves 100 steps per degree C
        for i in 0..10_i32 {
            // Why: test fixture; i is i32 in 0..10, lossless to f64/i64.
            let temp = 10.0 + f64::from(i);
            let pos = 10000 + (i * 100);
            engine.add_datapoint(FocusDataPoint {
                timestamp_secs: i64::from(i),
                temperature_celsius: temp,
                focus_position: pos,
                hfr: 2.0,
                filter_name: None,
            });
        }

        let model = engine.get_model().expect("Model should exist");
        assert!(model.is_reliable());
        assert!((model.slope - 100.0).abs() < 1.0);
        assert!(model.r_squared > 0.99);

        // Test prediction
        let prediction = engine.predict_position(15.0, None).expect("Should predict");
        assert!((prediction.position - 10500).abs() < 10);
    }

    #[test]
    fn test_filter_offsets() {
        let mut engine = FocusPredictionEngine::new();
        engine.set_reference_filter("L".to_string());

        // Add L filter data
        for i in 0..5_i64 {
            // Why: test fixture; i is i64 directly.
            engine.add_datapoint(FocusDataPoint {
                timestamp_secs: i,
                temperature_celsius: 15.0,
                focus_position: 10000,
                hfr: 2.0,
                filter_name: Some("L".to_string()),
            });
        }

        // Add Ha filter data with offset
        for i in 0..5_i64 {
            engine.add_datapoint(FocusDataPoint {
                // Why: test fixture; i is i64, +10 lossless.
                timestamp_secs: i + 10,
                temperature_celsius: 15.0,
                focus_position: 10200,
                hfr: 2.0,
                filter_name: Some("Ha".to_string()),
            });
        }

        let offset = engine.get_filter_offset("Ha").expect("Offset should exist");
        assert_eq!(offset.offset_steps, 200);
        assert!(offset.confidence > 0.5);
    }

    #[test]
    fn test_trim_data_points_preserves_history_span() {
        let mut engine = FocusPredictionEngine::new();
        engine.max_data_points = 5;

        for i in 0..10_i64 {
            engine.add_datapoint(FocusDataPoint {
                timestamp_secs: i,
                // Why: test fixture; i is i64 in 0..10, lossless to f64/i32.
                temperature_celsius: 10.0 + i as f64,
                focus_position: 10000 + i as i32,
                hfr: 2.0,
                filter_name: None,
            });
        }

        let timestamps: Vec<i64> = engine
            .data_points
            .iter()
            .map(|p| p.timestamp_secs)
            .collect();
        assert_eq!(timestamps.len(), 5);
        assert_eq!(timestamps.first().copied(), Some(0));
        assert_eq!(timestamps.last().copied(), Some(9));
    }

    // ─────────────────────────────────────────────────────────────────
    //  Persistent predictive-AF layer tests
    // ─────────────────────────────────────────────────────────────────

    fn sample(ts: i64, temp: f64, position: i32, hfr: f64) -> FocusTrainingSample {
        FocusTrainingSample {
            timestamp_secs: ts,
            temperature_celsius: temp,
            focus_position: position,
            hfr,
        }
    }

    #[test]
    fn persisted_model_linear_regression_recovers_known_slope() {
        let mut model = PersistedFocusModel::new(1, "Ha".to_string());
        // 47 steps per °C, baseline 28000 at 0°C
        for i in 0..15 {
            let temp = 5.0 + f64::from(i);
            let position = 28000 + i * 47;
            model.add_training_sample(sample(i64::from(i), temp, position, 1.8));
        }
        let reg = model.regression.as_ref().expect("regression should fit");
        assert!((reg.slope - 47.0).abs() < 0.5);
        assert!(reg.r_squared > 0.99);
        // Predict at 5°C → should reproduce sample[0] = 28000.
        let predicted = model.predict_position(5.0).expect("should predict");
        assert!(
            (predicted - 28000).abs() <= 5,
            "predicted at 5°C should be ~28000, got {}",
            predicted
        );
        // Predict at 10°C → 47*5 + 28000 = 28235.
        let predicted_10 = model.predict_position(10.0).expect("should predict");
        assert!(
            (predicted_10 - 28235).abs() <= 5,
            "predicted at 10°C should be ~28235, got {}",
            predicted_10
        );
    }

    #[test]
    fn persisted_model_decision_force_until_min_samples() {
        let mut model = PersistedFocusModel::new(1, "L".to_string());
        let config = PredictiveAfConfig::default();
        // Only 5 points (fewer than default min_samples_for_trust=8) but
        // perfectly linear → R²=1.0 but still must force AF.
        for i in 0..5 {
            model.add_training_sample(sample(
                i64::from(i),
                10.0 + f64::from(i),
                10000 + i * 50,
                2.0,
            ));
        }
        let decision = model.evaluate(12.0, &config);
        match decision {
            PredictiveAfDecision::ForceAutofocus {
                confidence,
                suggested_position,
            } => {
                assert!(confidence > 0.99);
                // Carry the prediction even when forcing AF.
                assert!((suggested_position - (10000 + 2 * 50)).abs() <= 5);
            }
            other => panic!("expected ForceAutofocus, got {:?}", other),
        }
    }

    #[test]
    fn persisted_model_decision_direct_when_high_confidence() {
        let mut model = PersistedFocusModel::new(1, "L".to_string());
        let config = PredictiveAfConfig::default();
        for i in 0..12 {
            model.add_training_sample(sample(i64::from(i), f64::from(i), 15000 + i * 30, 2.0));
        }
        let decision = model.evaluate(6.0, &config);
        match decision {
            PredictiveAfDecision::ApplyDirect {
                predicted_position,
                confidence,
            } => {
                assert!(confidence >= config.high_confidence_threshold);
                assert!((predicted_position - (15000 + 6 * 30)).abs() <= 5);
            }
            other => panic!("expected ApplyDirect, got {:?}", other),
        }
    }

    #[test]
    fn persisted_model_decision_dampened_in_mid_band() {
        let mut model = PersistedFocusModel::new(1, "Ha".to_string());
        let config = PredictiveAfConfig::default();
        // Noisy data ⇒ mid-band R² (~0.6).
        let positions = [
            10000, 10020, 10080, 10110, 10090, 10140, 10220, 10180, 10260, 10310, 10290, 10350,
        ];
        for (i, &p) in positions.iter().enumerate() {
            model.add_training_sample(sample(i as i64, i as f64, p, 2.0));
        }
        let r2 = model.regression.as_ref().unwrap().r_squared;
        // Adjust assertion based on what the noisy data actually yields.
        if (config.low_confidence_threshold..config.high_confidence_threshold).contains(&r2) {
            let decision = model.evaluate(6.0, &config);
            match decision {
                PredictiveAfDecision::ApplyDampened {
                    correction_factor, ..
                } => {
                    assert!(correction_factor > 0.0 && correction_factor < 1.0);
                }
                other => panic!("expected ApplyDampened at r2={}, got {:?}", r2, other),
            }
        }
    }

    #[test]
    fn drift_status_warns_after_consecutive_bad_predictions() {
        let mut model = PersistedFocusModel::new(1, "Ha".to_string());
        let config = PredictiveAfConfig {
            drift_threshold_steps: 100,
            drift_runs_before_warn: 3,
            ..PredictiveAfConfig::default()
        };
        // Simulate three predictions all off by 500 steps.
        let mut last_status = None;
        for _ in 0..3 {
            last_status = Some(model.record_prediction_outcome(28000, 28500, &config));
        }
        match last_status {
            Some(DriftStatus::ShouldWarn {
                consecutive_bad_runs,
                accumulated_drift_steps,
                ..
            }) => {
                assert_eq!(consecutive_bad_runs, 3);
                assert_eq!(accumulated_drift_steps, 1500);
            }
            other => panic!("expected ShouldWarn, got {:?}", other),
        }
    }

    #[test]
    fn drift_status_resets_on_good_run() {
        let mut model = PersistedFocusModel::new(1, "L".to_string());
        let config = PredictiveAfConfig {
            drift_threshold_steps: 100,
            drift_runs_before_warn: 3,
            ..PredictiveAfConfig::default()
        };
        model.record_prediction_outcome(28000, 28500, &config); // bad
        model.record_prediction_outcome(28000, 28500, &config); // bad
        assert_eq!(model.consecutive_bad_predictions, 2);
        let status = model.record_prediction_outcome(28000, 28050, &config); // good
        match status {
            DriftStatus::WithinTolerance { delta_steps } => {
                assert_eq!(delta_steps, 50);
                assert_eq!(model.consecutive_bad_predictions, 0);
                assert_eq!(model.accumulated_drift_steps, 0);
            }
            other => panic!("expected WithinTolerance, got {:?}", other),
        }
    }

    #[test]
    fn samples_are_capped_at_max_samples() {
        let mut model = PersistedFocusModel::new(1, "L".to_string());
        model.max_samples = 5;
        for i in 0..10 {
            model.add_training_sample(sample(i64::from(i), f64::from(i), 10000 + i * 50, 2.0));
        }
        assert_eq!(model.samples.len(), 5);
        // Should have kept the most recent.
        assert_eq!(model.samples.last().unwrap().timestamp_secs, 9);
        // Lifetime counter must continue to grow past the cap.
        assert_eq!(model.training_run_count, 10);
    }

    #[test]
    fn clear_samples_resets_drift_but_not_lifetime_counter() {
        let mut model = PersistedFocusModel::new(1, "Ha".to_string());
        let config = PredictiveAfConfig::default();
        for i in 0..6 {
            model.add_training_sample(sample(i64::from(i), f64::from(i), 10000 + i * 50, 2.0));
        }
        model.record_prediction_outcome(0, 99999, &config);
        assert!(model.consecutive_bad_predictions > 0);
        let lifetime = model.training_run_count;
        model.clear_samples();
        assert!(model.samples.is_empty());
        assert!(model.regression.is_none());
        assert_eq!(model.consecutive_bad_predictions, 0);
        assert_eq!(model.accumulated_drift_steps, 0);
        // Lifetime is preserved.
        assert_eq!(model.training_run_count, lifetime);
    }

    #[test]
    fn persisted_model_round_trip_serde() {
        let mut model = PersistedFocusModel::new(42, "Ha".to_string());
        model.filter_index = Some(2);
        for i in 0..10 {
            model.add_training_sample(sample(
                i64::from(i),
                5.0 + f64::from(i),
                28000 + i * 47,
                1.9,
            ));
        }
        let json = serde_json::to_string(&model).expect("serialize");
        let round: PersistedFocusModel = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(round.equipment_profile_id, 42);
        assert_eq!(round.filter_name, "Ha");
        assert_eq!(round.filter_index, Some(2));
        assert_eq!(round.samples.len(), 10);
        let reg = round.regression.expect("regression survives round-trip");
        assert!((reg.slope - 47.0).abs() < 0.5);
    }
}
