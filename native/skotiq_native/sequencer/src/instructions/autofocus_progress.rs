//! What an autofocus run reports while it works.

use crate::autofocus::FocusDataPoint;
use serde::Serialize;
use std::fmt;

/// Receives an autofocus run's progress: the percent done and the step.
pub type AutofocusProgressSink<'a> = Option<&'a (dyn Fn(f64, &AutofocusProgress) + Send + Sync)>;

/// One step of an autofocus run.
#[derive(Debug, Clone, PartialEq)]
pub enum AutofocusProgress {
    Starting,
    MovingToStart {
        position: i32,
    },
    /// On the way to a sweep point. `point` is 1-based.
    MovingToPoint {
        point: usize,
        total_points: usize,
        position: i32,
    },
    PointMeasured(Box<SweepSnapshot>),
    Validating,
    /// The measured points again, each marked with whether the fit uses it.
    PointsScreened(Box<SweepSnapshot>),
    MovingToBestFocus {
        position: i32,
    },
    Complete {
        position: i32,
        hfr: f64,
        /// False when the HFR is the fit's prediction because the frame taken
        /// at best focus could not be measured.
        hfr_measured: bool,
        r_squared: f64,
    },
    /// The lowest HFR was at the sweep's edge; the next sweep is centered here.
    FocusBeyondSweep {
        sweep_center: i32,
    },
    /// A sweep failed and the next configured attempt starts.
    AttemptFailed {
        attempt: u32,
        attempts: u32,
    },
}

impl AutofocusProgress {
    /// The sweep as of the latest measured point, which the focus panel draws.
    pub fn sweep(&self) -> Option<&SweepSnapshot> {
        match self {
            Self::PointMeasured(sweep) | Self::PointsScreened(sweep) => Some(sweep),
            _ => None,
        }
    }

    /// The HFR this step reports: the latest point's, or the final one.
    pub fn hfr(&self) -> Option<f64> {
        match self {
            Self::Complete { hfr, .. } => Some(*hfr),
            _ => self.sweep().map(|sweep| sweep.hfr),
        }
    }
}

impl fmt::Display for AutofocusProgress {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Starting => write!(f, "Starting autofocus..."),
            Self::MovingToStart { position } => write!(f, "Moving to start position: {position}"),
            Self::MovingToPoint {
                point,
                total_points,
                position,
            } => write!(f, "Point {point}/{total_points}: pos {position}"),
            Self::PointMeasured(sweep) | Self::PointsScreened(sweep) => write!(
                f,
                "Point {}/{}: HFR {:.2}",
                sweep.point, sweep.total_points, sweep.hfr
            ),
            Self::Validating => write!(f, "Validating focus data..."),
            Self::MovingToBestFocus { position } => write!(f, "Moving to best focus: {position}"),
            Self::Complete {
                position,
                hfr,
                hfr_measured,
                r_squared,
            } => write!(
                f,
                "Complete: pos {position}, HFR {hfr:.2} ({}), R² {r_squared:.3}",
                hfr_note(*hfr_measured)
            ),
            Self::FocusBeyondSweep { sweep_center } => write!(
                f,
                "Focus lies beyond the sweep; sweeping around {sweep_center}"
            ),
            Self::AttemptFailed { attempt, attempts } => write!(
                f,
                "Autofocus attempt {attempt}/{attempts} failed; retrying full sweep"
            ),
        }
    }
}

/// How the final HFR was obtained, as the operator reads it.
pub(crate) fn hfr_note(measured: bool) -> &'static str {
    if measured {
        "measured"
    } else {
        "predicted; the verification frame could not be measured"
    }
}

/// The sweep as of its latest measured point. Serialized, it is the focuser's
/// `AutofocusProgress` property the focus panel draws the V-curve from.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "type", rename = "autofocus_progress")]
pub struct SweepSnapshot {
    /// The latest point, 1-based.
    pub point: usize,
    pub total_points: usize,
    pub hfr: f64,
    pub star_count: u32,
    pub focus_range: FocusRange,
    pub vcurve_points: Vec<SweepPoint>,
    pub star_crops: Vec<StarCrop>,
}

impl SweepSnapshot {
    pub fn to_json(&self) -> String {
        serde_json::to_string(self).expect("a sweep snapshot has no map keys to fail on")
    }
}

/// The first and last focuser positions of the sweep.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct FocusRange {
    pub min: i32,
    pub max: i32,
}

/// One measured point of the V-curve.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct SweepPoint {
    pub position: i32,
    pub hfr: f64,
    pub star_count: u32,
    /// Why the fit leaves this point out; absent for a point it uses.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rejected: Option<String>,
}

impl SweepPoint {
    /// A point the fit uses.
    pub(crate) fn used(point: &FocusDataPoint) -> Self {
        Self {
            position: point.position,
            hfr: point.hfr,
            star_count: point.star_count,
            rejected: None,
        }
    }
}

/// One of the brightest stars of a point's frame, for the focus panel.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct StarCrop {
    /// 8-bit grayscale pixels, base64.
    pub pixels_base64: String,
    pub width: u32,
    pub height: u32,
    pub hfr: f64,
    pub snr: f64,
}
