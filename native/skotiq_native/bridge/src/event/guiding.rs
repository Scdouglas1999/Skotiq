use super::*;

/// Guiding-specific events
#[frb]
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum GuidingEvent {
    Connected,
    Disconnected,
    GuidingStarted,
    GuidingStopped,
    Paused,
    Resumed,
    Settled {
        rms: f64,
    },
    LostStar,
    /// PHD2 gave up waiting for the guider to settle. The star may still be
    /// locked; this is not a lost star.
    SettleTimedOut {
        /// PHD2's own words for the failure.
        error: String,
    },
    /// Why the guider is stopped changed: a snake_case reason, or `None`
    /// once guiding runs again.
    StopReason {
        reason: Option<String>,
    },
    DitherStarted {
        pixels: f64,
    },
    DitherCompleted,
    Correction {
        ra: f64,
        dec: f64,
        ra_raw: f64,
        dec_raw: f64,
    },
    /// Looping exposures without guiding
    Looping,
    /// Settling after dither or guide start
    Settling,
    /// Calibration in progress
    Calibrating,
    /// Calibration completed successfully
    CalibrationComplete,
    /// Guide star selected at position
    StarSelected {
        x: f64,
        y: f64,
    },
    /// PHD2 app state change (for states not covered by other events)
    AppState {
        state: String,
    },
    /// SNR and star mass update from guide step
    GuideStats {
        snr: f64,
        star_mass: f64,
    },
}
