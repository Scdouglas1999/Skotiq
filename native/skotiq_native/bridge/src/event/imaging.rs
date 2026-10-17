use super::*;

/// Polar alignment error data
#[frb]
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PolarAlignmentEvent {
    pub azimuth_error: f64,
    pub altitude_error: f64,
    pub total_error: f64,
    pub current_ra: f64,
    pub current_dec: f64,
    pub target_ra: f64,
    pub target_dec: f64,
}

/// Polar alignment status update
#[frb]
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PolarAlignmentStatus {
    pub status: String,
    pub phase: String,
    pub point: i32,
}

/// Polar alignment image data for UI display
#[frb]
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PolarAlignmentImageEvent {
    /// JPEG-encoded image bytes for display
    pub image_data: Vec<u8>,
    /// Image width
    pub width: u32,
    /// Image height
    pub height: u32,
    /// Plate solve result (if available)
    pub solved_ra: Option<f64>,
    pub solved_dec: Option<f64>,
    /// Current measurement point (1-3) or 0 for adjustment phase
    pub point: i32,
    /// Phase: "measuring" or "adjusting"
    pub phase: String,
}

/// Imaging-specific events
#[frb]
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum ImagingEvent {
    // Basic exposure events
    ExposureStarted {
        duration_secs: f64,
        frame_type: crate::device::FrameType,
    },
    ExposureStartedWithFrame {
        duration_secs: f64,
        frame_type: crate::device::FrameType,
        frame_number: u32,
        total_frames: Option<u32>,
    },
    ExposureProgress {
        progress: f64,
        remaining_secs: f64,
    },
    ExposureCompleted {
        file_path: Option<String>,
        hfr: f64,
        stars_detected: u32,
    },
    ExposureCompletedWithFrame {
        frame_number: u32,
        total_frames: Option<u32>,
        hfr: f64,
        stars_detected: u32,
    },
    ExposureFailed {
        error: String,
    },
    ExposureCancelled,

    // Download events
    DownloadStarted,
    DownloadCompleted,

    // Image events
    ImageReady {
        width: u32,
        height: u32,
    },
    ImageSaved {
        file_path: String,
    },

    // Post-session integration pipeline progress
    /// Progress update from the offline batch-integration pipeline
    /// ([`crate::api::post_session::api_integrate_session`]). Emitted at every
    /// phase boundary and, during the per-frame register loop, per frame —
    /// never per pixel. The UI filters these by `category == Imaging` +
    /// `eventType == "IntegrationProgress"` and drives a progress bar from
    /// `fraction`.
    IntegrationProgress {
        /// Current pipeline phase: one of `"calibrating"`, `"registering"`,
        /// `"normalizing"`, `"weighting"`, `"integrating"`, `"writing"`, or
        /// `"preview"`.
        phase: String,
        /// Overall completion fraction in `0.0..=1.0`, monotonically advancing
        /// across the phase sequence above.
        fraction: f32,
        /// Frames processed so far in the current phase (`None` when the phase
        /// has no per-frame granularity, e.g. `integrating`/`writing`).
        #[serde(skip_serializing_if = "Option::is_none")]
        frames_done: Option<u32>,
        /// Total frames in the current phase (`None` when N/A).
        #[serde(skip_serializing_if = "Option::is_none")]
        frames_total: Option<u32>,
    },

    // Temperature events
    TemperatureChanged {
        temp_celsius: f64,
        cooler_power: f64,
    },

    // Deprecated (for backwards compatibility)
    #[serde(rename = "ExposureComplete")]
    ExposureComplete {
        success: bool,
    },
    #[serde(rename = "ExposureFailed_Old")]
    ExposureFailedOld {
        reason: String,
    },
}
