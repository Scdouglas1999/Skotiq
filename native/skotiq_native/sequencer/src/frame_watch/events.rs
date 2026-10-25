//! What the frame watch tells the app. The bridge forwards each event as a
//! structured-progress event whose `detail_kind` is the variant name and
//! whose `detail_json` is the payload; the app keys its frame record and its
//! learned horizon on them.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub enum FrameWatchEvent {
    FrameAssessed(FrameAssessed),
    HorizonObstruction(HorizonObstructionReport),
}

impl FrameWatchEvent {
    /// The `detail_kind` the app decodes this event by.
    pub fn kind(&self) -> &'static str {
        match self {
            FrameWatchEvent::FrameAssessed(_) => "FrameAssessed",
            FrameWatchEvent::HorizonObstruction(_) => "HorizonObstruction",
        }
    }

    /// The payload as JSON.
    pub fn payload_json(&self) -> String {
        let value = match self {
            FrameWatchEvent::FrameAssessed(f) => serde_json::to_string(f),
            FrameWatchEvent::HorizonObstruction(h) => serde_json::to_string(h),
        };
        value.unwrap_or_else(|_| "{}".to_string())
    }
}

/// One saved light frame as the frame watch measured and judged it. The app
/// updates the frame's `captured_images` row, found by `save_path`.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct FrameAssessed {
    /// The path the frame was saved at (the reject path for a graded reject).
    pub save_path: String,
    pub filter: Option<String>,
    pub exposure_secs: f64,
    /// The grader's verdict.
    pub was_accepted: bool,
    pub solve_attempted: bool,
    pub plate_solved: bool,
    pub solved_ra_deg: Option<f64>,
    pub solved_dec_deg: Option<f64>,
    pub solved_rotation_deg: Option<f64>,
    /// Arcseconds per pixel.
    pub solved_pixel_scale: Option<f64>,
    /// Distance of the solved center from the target, arcminutes.
    pub offset_arcmin: Option<f64>,
    /// Root mean square of the guider's total-RMS samples during the exposure,
    /// in the guider's units.
    pub guide_rms_total: Option<f64>,
    pub guide_rms_samples: u32,
    /// Median sky level, ADU.
    pub background_adu: Option<f64>,
    pub star_count: Option<u32>,
    pub altitude_deg: Option<f64>,
    pub azimuth_deg: Option<f64>,
    pub pier_side: Option<String>,
    pub off_target: bool,
    pub obstructed: bool,
    /// Why the frame no longer counts as integration; starts with
    /// [`super::OFF_TARGET_PREFIX`] or [`super::OBSTRUCTED_PREFIX`].
    pub exclusion_reason: Option<String>,
}

/// A confirmed obstruction: where it began and what the run did about it.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct HorizonObstructionReport {
    pub altitude_deg: f64,
    pub azimuth_deg: f64,
    pub target_name: Option<String>,
    pub latitude: Option<f64>,
    pub longitude: Option<f64>,
    /// Always `"obstruction"`; cloud never produces this event.
    pub verdict: String,
    /// `"next_target"` or `"end_of_night"`.
    pub action: String,
    pub message: String,
}
