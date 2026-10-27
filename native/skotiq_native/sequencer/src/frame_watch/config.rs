//! The operator's frame-watch settings and the site's learned horizon, read
//! from the loaded sequence's metadata.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Sequence-metadata key that carries [`FrameWatchConfig`] as a JSON string.
pub const FRAME_WATCH_METADATA_KEY: &str = "frame_watch";

/// Fraction of the frame's shorter side a solved center may sit from the
/// target before the run recenters.
pub const DEFAULT_DRIFT_LIMIT_FRACTION: f64 = 0.10;

/// Half an arcminute, independent of camera pixel scale or field of view.
pub const DEFAULT_DRIFT_LIMIT_ARCSEC: f64 = 30.0;

/// How far either side of a learned obstruction point's azimuth the point
/// blocks the sky.
pub const LEARNED_AZIMUTH_HALF_WIDTH_DEG: f64 = 6.0;

/// How far above a learned obstruction point's altitude the point still
/// blocks the sky.
pub const LEARNED_ALTITUDE_MARGIN_DEG: f64 = 1.0;

/// Where an obstruction was seen: the target's altitude and azimuth on the
/// first frame that lost its stars to it.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
pub struct HorizonPoint {
    pub azimuth_deg: f64,
    pub altitude_deg: f64,
}

impl HorizonPoint {
    /// Whether this point blocks the sky at `altitude_deg`, `azimuth_deg`.
    pub fn blocks(&self, altitude_deg: f64, azimuth_deg: f64) -> bool {
        let mut delta = (azimuth_deg - self.azimuth_deg).rem_euclid(360.0);
        if delta > 180.0 {
            delta = 360.0 - delta;
        }
        delta <= LEARNED_AZIMUTH_HALF_WIDTH_DEG
            && altitude_deg <= self.altitude_deg + LEARNED_ALTITUDE_MARGIN_DEG
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct FrameWatchConfig {
    /// Angular threshold for new runs. Zero disables recentering. Missing
    /// values in older serialized plans retain the field-fraction setting.
    #[serde(default)]
    pub drift_limit_arcsec: Option<f64>,
    /// Keep the first solved light as the run's reference for each target.
    /// Older serialized plans retain their planned-coordinate reference.
    #[serde(default)]
    pub use_first_frame_reference: bool,
    /// Legacy threshold for plans without an angular limit. Zero disables it.
    pub drift_limit_fraction: f64,
    /// Whether a run looks for obstructions at all.
    pub obstruction_detection: bool,
    /// The obstruction points the app learned at this site.
    pub learned_horizon: Vec<HorizonPoint>,
}

impl Default for FrameWatchConfig {
    fn default() -> Self {
        Self {
            drift_limit_arcsec: Some(DEFAULT_DRIFT_LIMIT_ARCSEC),
            use_first_frame_reference: true,
            drift_limit_fraction: DEFAULT_DRIFT_LIMIT_FRACTION,
            obstruction_detection: true,
            learned_horizon: Vec::new(),
        }
    }
}

impl FrameWatchConfig {
    /// The settings in `metadata`, or the defaults when the key is absent or
    /// does not parse (the reason is logged).
    pub fn from_metadata(metadata: &HashMap<String, String>) -> Self {
        let Some(raw) = metadata.get(FRAME_WATCH_METADATA_KEY) else {
            return Self::default();
        };
        match serde_json::from_str::<Self>(raw) {
            Ok(config) => config,
            Err(e) => {
                tracing::warn!(
                    "[FRAME_WATCH] The sequence's frame-watch settings could not be read ({e}); \
                     using the defaults (recenter past {:.0} arcsec, obstruction \
                     detection on, no learned horizon)",
                    DEFAULT_DRIFT_LIMIT_ARCSEC
                );
                Self::default()
            }
        }
    }

    /// The angular limit, or the old field-relative limit for a saved legacy plan.
    pub fn drift_limit_arcmin(&self, field_short_side_arcmin: Option<f64>) -> Option<f64> {
        let limit = match self.drift_limit_arcsec {
            Some(arcsec) => arcsec / 60.0,
            None => self.drift_limit_fraction * field_short_side_arcmin?,
        };
        (limit.is_finite() && limit > 0.0).then_some(limit)
    }

    /// The learned point that blocks `altitude_deg`, `azimuth_deg`, if any.
    pub fn learned_obstruction_at(
        &self,
        altitude_deg: f64,
        azimuth_deg: f64,
    ) -> Option<&HorizonPoint> {
        self.learned_horizon
            .iter()
            .find(|p| p.blocks(altitude_deg, azimuth_deg))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn absent_or_broken_metadata_gives_the_defaults() {
        let mut metadata = HashMap::new();
        assert_eq!(
            FrameWatchConfig::from_metadata(&metadata),
            FrameWatchConfig::default()
        );
        metadata.insert(
            FRAME_WATCH_METADATA_KEY.to_string(),
            "{not json".to_string(),
        );
        assert_eq!(
            FrameWatchConfig::from_metadata(&metadata),
            FrameWatchConfig::default()
        );
    }

    #[test]
    fn legacy_metadata_retains_its_field_relative_limit() {
        let mut metadata = HashMap::new();
        metadata.insert(
            FRAME_WATCH_METADATA_KEY.to_string(),
            r#"{"drift_limit_fraction":0.15,"obstruction_detection":true,
                "learned_horizon":[{"azimuth_deg":286.2,"altitude_deg":65.2}]}"#
                .to_string(),
        );
        let config = FrameWatchConfig::from_metadata(&metadata);
        assert_eq!(config.drift_limit_fraction, 0.15);
        assert_eq!(config.drift_limit_arcsec, None);
        assert_eq!(config.drift_limit_arcmin(Some(40.0)), Some(6.0));
        assert_eq!(config.drift_limit_arcmin(None), None);
        assert_eq!(config.learned_horizon.len(), 1);
    }

    #[test]
    fn angular_metadata_does_not_depend_on_field_size() {
        let metadata = HashMap::from([(
            FRAME_WATCH_METADATA_KEY.to_string(),
            r#"{"drift_limit_arcsec":90,"obstruction_detection":false}"#.to_string(),
        )]);
        let config = FrameWatchConfig::from_metadata(&metadata);
        assert_eq!(config.drift_limit_arcmin(None), Some(1.5));
        assert_eq!(config.drift_limit_arcmin(Some(20.0)), Some(1.5));
        assert_eq!(config.drift_limit_arcmin(Some(120.0)), Some(1.5));
        assert!(!config.obstruction_detection);
        assert_eq!(
            FrameWatchConfig::default().drift_limit_arcmin(None),
            Some(0.5)
        );
    }

    #[test]
    fn disabled_or_invalid_angular_limit_never_falls_back_to_fraction() {
        for limit in [0.0, -1.0, f64::NAN, f64::INFINITY] {
            let config = FrameWatchConfig {
                drift_limit_arcsec: Some(limit),
                ..Default::default()
            };
            assert_eq!(config.drift_limit_arcmin(Some(40.0)), None);
        }
    }

    #[test]
    fn a_learned_point_blocks_a_small_patch_below_and_just_above_it() {
        let point = HorizonPoint {
            azimuth_deg: 286.2,
            altitude_deg: 65.2,
        };
        assert!(point.blocks(64.0, 286.0));
        assert!(point.blocks(66.0, 291.0));
        assert!(!point.blocks(67.0, 286.0));
        assert!(!point.blocks(60.0, 300.0));
        let north = HorizonPoint {
            azimuth_deg: 358.0,
            altitude_deg: 30.0,
        };
        assert!(north.blocks(20.0, 2.0), "the patch wraps through north");
    }
}
