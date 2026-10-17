use super::*;

pub(crate) const BUILTIN_GUIDER_ID: &str = "native:builtin_guider:multi_star";

/// Operator-facing reason for a guiding failure.
///
/// Every layer adds its own label on the way up, so a naive
/// `format!("Guiding stopped: {error}")` reached the UI as
/// "Guiding stopped: Operation failed: Calibration star match failed". Drop the
/// generic wrapper label so the panel shows the cause and nothing else.
pub(crate) fn guiding_failure_reason(error: &SkotiqError) -> String {
    let text = error.to_string();
    let cause = text
        .strip_prefix("Operation failed: ")
        .unwrap_or(text.as_str())
        .trim();
    format!("Guiding stopped: {}", cause)
}
pub(crate) const GUIDE_MAX_MATCH_DISTANCE_PX: f64 = 20.0;
/// Up to this many guide stars are tracked per frame. Raised from 8 to 12 so the
/// sigma-clipped weighted centroid (see [`measure_offset`]) has enough samples
/// to drop one or two outliers and still average over a healthy set.
pub(crate) const GUIDE_MAX_TRACKED_STARS: usize = 12;
pub(crate) const GUIDE_MIN_STAR_SEPARATION_PX: f64 = 10.0;
/// A tracked star whose centroid lands within this many pixels of the frame edge
/// is rejected at selection time: stars partially off-sensor have biased
/// centroids and are the first to vanish under field rotation.
pub(crate) const GUIDE_EDGE_MARGIN_PX: f64 = 12.0;
/// Stars dimmer than this SNR are not used as guide references — too noisy to
/// contribute a reliable per-star displacement.
pub(crate) const GUIDE_MIN_REFERENCE_SNR: f64 = 6.0;
/// Stars rounder-than-this (eccentricity) are preferred; above this they are
/// rejected because an elongated detection (blended pair / hot column) gives a
/// centroid that walks with seeing rather than with the mount.
pub(crate) const GUIDE_MAX_REFERENCE_ECCENTRICITY: f64 = 0.6;
/// Peak ADU at/above which a star is treated as saturated and rejected: a
/// clipped core flattens the centroid and biases the displacement toward zero.
pub(crate) const GUIDE_SATURATION_PEAK_ADU: f64 = 60000.0;
/// Sigma multiplier for the robust (sigma-clipped) offset: per-star
/// displacements more than this many MADs from the median are dropped as
/// outliers (a star that jumped — cloud edge, cosmic ray, misassociation).
pub(crate) const GUIDE_OUTLIER_SIGMA: f64 = 2.5;
/// Below this many surviving stars the robust centroid is not trustworthy; the
/// guider falls back to the plain weighted mean over whatever matched.
pub(crate) const GUIDE_MIN_STARS_FOR_CLIP: usize = 4;
/// 1.4826 * MAD ≈ standard deviation for a normal distribution. Used to scale
/// the median-absolute-deviation into a sigma-equivalent for outlier rejection.
pub(crate) const MAD_TO_SIGMA: f64 = 1.4826;

/// Configurable parameters for the built-in guider.
///
/// All fields have sensible defaults matching the original hardcoded values.
#[derive(Clone, Debug)]
pub struct GuiderConfig {
    /// Guide camera exposure time in seconds
    pub exposure_secs: f64,
    /// Guide camera gain
    pub gain: i32,
    /// Guide camera offset
    pub offset: i32,
    /// Guide camera binning
    pub binning: i32,
    /// Calibration pulse duration in milliseconds
    pub calibration_ms: u32,
    /// Sleep between settle checks in milliseconds
    pub settle_sleep_ms: u64,
    /// Minimum guide pulse length in milliseconds (pulses smaller than this are skipped)
    pub min_pulse_ms: f64,
    /// Maximum guide pulse length in milliseconds (pulses are clamped to this)
    pub max_pulse_ms: f64,
    /// RA correction aggressiveness (0..1+). Each computed RA pulse is scaled by
    /// this before clamping. 1.0 = full correction; lower values damp chasing
    /// seeing. Defaults to a slightly conservative value.
    pub ra_aggressiveness: f64,
    /// Dec correction aggressiveness (0..1+). Dec is usually run softer than RA
    /// because it only fights drift and is the axis with backlash.
    pub dec_aggressiveness: f64,
    /// Minimum guide displacement (pixels) below which no correction is issued.
    /// Avoids chasing centroid noise frame-to-frame.
    pub min_move_px: f64,
}

impl Default for GuiderConfig {
    fn default() -> Self {
        Self {
            exposure_secs: 1.0,
            gain: 100,
            offset: 10,
            binning: 1,
            calibration_ms: 250,
            settle_sleep_ms: 200,
            min_pulse_ms: 75.0,
            max_pulse_ms: 1200.0,
            ra_aggressiveness: 0.7,
            dec_aggressiveness: 0.6,
            min_move_px: 0.15,
        }
    }
}

#[derive(Clone, Copy, Debug, Default)]
pub(crate) struct Vec2 {
    pub(crate) x: f64,
    pub(crate) y: f64,
}

impl Vec2 {
    pub(crate) fn magnitude(self) -> f64 {
        (self.x * self.x + self.y * self.y).sqrt()
    }
}

#[cfg(test)]
mod guiding_failure_reason_tests {
    use super::*;

    #[test]
    fn strips_the_generic_operation_failed_label() {
        let err = SkotiqError::OperationFailed("Calibration star match failed".to_string());
        assert_eq!(
            guiding_failure_reason(&err),
            "Guiding stopped: Calibration star match failed"
        );
    }

    #[test]
    fn keeps_a_message_that_has_no_wrapper_label() {
        let err = SkotiqError::NotConnected("native:builtin_guider:multi_star".to_string());
        let reason = guiding_failure_reason(&err);
        assert!(reason.starts_with("Guiding stopped: "));
        assert!(reason.contains("not connected"));
        assert!(!reason.contains("Operation failed"));
    }
}
