//! Measuring a focuser's mechanical backlash instead of asking for it.
//!
//! # What backlash does to a focus sweep
//!
//! A focuser's drive train has a dead band: after reversing direction the
//! motor turns for some number of steps before the drawtube follows. Write the
//! optical position as `a = c + d`, where `c` is the commanded position and
//! `d ∈ [0, b]` is however much of the dead band `b` is currently taken up.
//! A long upward move drives `d` to 0; a long downward move drives it to `b`.
//!
//! So the position that focuses the optics depends on how the focuser arrived:
//! arriving upward, focus is commanded at `A` (the true optical focus);
//! arriving downward, it is commanded at `A - b`. That difference IS the
//! backlash, and it is what this module measures:
//!
//! ```text
//! backlash = optimum_measured_approaching_from_below
//!          - optimum_measured_approaching_from_above
//! ```
//!
//! Measured on the owner's ZWO EAF on 2026-09-14 near position 6600: 6620
//! from below, 6515 from above, so 105 steps. An earlier measurement lower in
//! the travel (2026-09-08, near 2500) gave ~83, so backlash is a function of
//! where in the travel it is measured — every record here therefore carries
//! the position and temperature it was taken at, and nothing presents the
//! figure as exact everywhere.
//!
//! # What the scan's run-up actually buys, and when it is not enough
//!
//! Each point is approached deliberately, running `k` steps past the target
//! and back. It is tempting to reason about that one approach in isolation and
//! conclude that `k` must exceed `b`. It does not, because the scan is
//! monotone. Take the from-below pass, whose points ascend by `step`: the move
//! to `p - k` is only `k - step` BELOW the previous sample, so it adds
//! `k - step` to `d`, and the move up to `p` then takes `k` off it. Per point,
//! net, `d` falls by `step` — except on the first point, where `d` can be as
//! high as `b` and the cap means the up-move leaves `max(b - k, 0)`. The
//! from-above pass is the mirror image, filling `d` instead of draining it.
//!
//! So the reversal the scan has accumulated by its nth point is
//!
//! ```text
//! reversal budget(n) = k + (n - 1) * step
//! ```
//!
//! and what matters is whether that reaches `b` before the scan reaches the
//! points that set the vertex. Given a budget comfortably above `b`, the
//! from-below pass sits at `d = 0` and the from-above pass saturates at
//! `d = b`, so the fits recover exactly `b` — for any `k`, which is why `k`
//! alone is not the test. Given a budget short of `b`, the from-above pass is
//! still filling the dead band while it samples, and the measurement
//! UNDER-reports.
//!
//! Under-reporting cannot be detected from a single run: it produces a
//! SMALLER number and nothing in the data says how much smaller. So there are
//! two bounds rather than one correction. Above `reversal_budget(points)` a
//! figure is refused, because nothing in the scan could have taken up a dead
//! band that wide. Above `reversal_budget(points / 2)` — the reversal in hand
//! by the middle of the scan, where the vertex is set — it is reported at low
//! confidence as possibly a floor rather than the value.
//!
//! All of this was established by simulating a gear train of known width
//! against the real routine (`instructions::tests::focuser_backlash`). An
//! earlier version of this module reasoned from the isolated single approach,
//! concluded the rule was `k >= b`, and would have refused a perfectly good
//! measurement of the owner's 105 steps taken with a 40-step run-up — which
//! the simulation recovers as 102 at R² 0.995.
//!
//! One thing the model rules out entirely: a NEGATIVE difference. `d` is
//! confined to `[0, b]`, so the from-below optimum can never sit below the
//! from-above one. A meaningfully negative result is therefore not a backlash
//! at all — it says the two scans were not measuring the same focus, which is
//! what focus drifting during the run, or a focuser not following its
//! commands, looks like.

use std::fmt;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::autofocus::{AutofocusMethod, FocusDataPoint};

/// A vertex fitted from samples `n` steps apart is not located to better than
/// half that spacing, whatever the fit's R² says — the curve simply was not
/// sampled any finer. A vertex difference smaller than this is not a
/// measurement of anything.
const VERTEX_RESOLUTION_FRACTION: f64 = 0.5;

/// Floor for the resolution limit. A stepper focuser cannot express backlash
/// finer than one step, so claiming better resolution than that would be
/// arithmetic dressed up as measurement.
const MIN_RESOLUTION_LIMIT_STEPS: f64 = 1.0;

/// Fewest points, per direction, that must survive to the fit. Three points
/// define a parabola exactly and would report R² = 1.0 for any three samples;
/// five is the same floor [`crate::autofocus`] uses for a narrowed refit.
const MIN_FIT_POINTS: usize = 5;

/// Both fits must be at least this good, and the result at least this many
/// multiples of the resolution limit, to call the figure high confidence.
const HIGH_CONFIDENCE_R_SQUARED: f64 = 0.95;
const HIGH_CONFIDENCE_RESOLUTION_MULTIPLE: f64 = 3.0;

/// The same, one band down.
const MODERATE_CONFIDENCE_R_SQUARED: f64 = 0.90;
const MODERATE_CONFIDENCE_RESOLUTION_MULTIPLE: f64 = 2.0;

/// Which face of the dead band a scan's points were approached from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ApproachDirection {
    /// Every point reached by running below it and coming up.
    FromBelow,
    /// Every point reached by running above it and coming down.
    FromAbove,
}

impl ApproachDirection {
    /// Wording for an operator-facing message.
    pub fn label(self) -> &'static str {
        match self {
            Self::FromBelow => "from below",
            Self::FromAbove => "from above",
        }
    }
}

impl fmt::Display for ApproachDirection {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.label())
    }
}

/// One direction's scan: the points that reached the fit, and what the fit
/// made of them.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DirectionalScan {
    pub approach: ApproachDirection,
    /// The points the fit actually used — post outlier rejection, so this is
    /// the evidence for the vertex rather than everything that was exposed.
    pub points: Vec<FocusDataPoint>,
    /// Fitted vertex, in commanded focuser steps.
    pub optimum_position: i32,
    pub r_squared: f64,
    pub method: AutofocusMethod,
}

impl DirectionalScan {
    /// Lowest and highest position the fit saw.
    pub fn span(&self) -> Option<(i32, i32)> {
        let lo = self.points.iter().map(|point| point.position).min()?;
        let hi = self.points.iter().map(|point| point.position).max()?;
        Some((lo, hi))
    }

    /// Positions covered, end to end.
    pub fn span_steps(&self) -> i32 {
        self.span()
            .map_or(0, |(lo, hi)| hi.saturating_sub(lo))
            .abs()
    }

    /// Median gap between adjacent sampled positions. Median rather than the
    /// nominal step size because a scan may have had points rejected, and
    /// because the spacing sets the resolution limit — the typical gap is the
    /// honest summary of how finely the curve was actually sampled.
    pub fn median_spacing(&self) -> i32 {
        let mut positions: Vec<i32> = self.points.iter().map(|point| point.position).collect();
        positions.sort_unstable();
        positions.dedup();
        let mut gaps: Vec<i32> = positions
            .windows(2)
            .map(|pair| pair[1].saturating_sub(pair[0]))
            .collect();
        if gaps.is_empty() {
            return 0;
        }
        gaps.sort_unstable();
        gaps[gaps.len() / 2]
    }

    /// The point with the lowest HFR — the one nearest focus, and the one the
    /// vertex position depends on most.
    pub fn best_point(&self) -> Option<&FocusDataPoint> {
        self.points.iter().min_by(|a, b| a.hfr.total_cmp(&b.hfr))
    }

    /// How many points found at least `star_floor` stars.
    pub fn points_meeting_star_floor(&self, star_floor: u32) -> usize {
        self.points
            .iter()
            .filter(|point| point.star_count >= star_floor)
            .count()
    }
}

/// Metadata that makes a stored figure interpretable later: which focuser,
/// when, how warm, and which build measured it.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MeasurementContext {
    /// The focuser this belongs to. A figure measured on one drive train says
    /// nothing about another, so nothing is ever read back without this.
    pub focuser_device_id: String,
    pub taken_at: DateTime<Utc>,
    /// Focuser temperature at the time, when the driver reports one.
    pub temperature_celsius: Option<f64>,
    pub app_version: String,
}

/// Acceptance thresholds for the analysis, and the run-up the scans used.
#[derive(Debug, Clone, Copy)]
pub struct BacklashAnalysisThresholds {
    /// Minimum stars a frame must find for its HFR to be worth fitting.
    pub min_star_count: u32,
    /// Minimum R² either fit may have.
    pub r_squared_threshold: f64,
    /// The run-up `k` each point was approached with. Recorded for
    /// provenance; it is not itself the acceptance test.
    pub clearance_steps: i32,
    /// How far the scan reversed the drive train in total: the widest dead
    /// band it could possibly have taken up, and so a hard ceiling on any
    /// figure it can produce.
    pub reversal_budget_steps: i32,
    /// The same, taken only as far as the middle of the scan, where the points
    /// that set the vertex are. A result above this could be a floor rather
    /// than the value.
    pub reversal_budget_at_vertex_steps: i32,
}

/// How much the measurement is worth, given the evidence behind it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CalibrationConfidence {
    High,
    Moderate,
    Low,
}

impl CalibrationConfidence {
    pub fn label(self) -> &'static str {
        match self {
            Self::High => "high",
            Self::Moderate => "moderate",
            Self::Low => "low",
        }
    }
}

impl fmt::Display for CalibrationConfidence {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.label())
    }
}

/// A completed backlash measurement, with everything it was derived from.
///
/// `steps` is 0 when the two vertices landed closer together than the scans
/// could resolve. That is a real outcome — plenty of focusers have no backlash
/// worth compensating — and it is reported as such rather than nudged up to a
/// number that would move somebody's drawtube for no reason.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FocuserBacklashCalibration {
    /// Backlash to apply, in focuser steps. Never negative.
    pub steps: i32,
    /// The raw signed difference between the two vertices, before the
    /// resolution test. Kept because it is the measurement; `steps` is the
    /// conclusion drawn from it.
    pub vertex_difference: i32,
    /// False when the difference was inside [`Self::resolution_limit_steps`],
    /// i.e. "no backlash larger than that was detectable".
    pub measurable: bool,
    /// The smallest difference these two scans could have told apart.
    pub resolution_limit_steps: f64,
    pub below: DirectionalScan,
    pub above: DirectionalScan,
    /// Where in the travel this was measured — the from-below optimum, which
    /// is true optical focus. Backlash varies along the travel, so the figure
    /// is only claimed for this neighbourhood.
    pub measured_at_position: i32,
    /// The run-up each scan point was approached with.
    pub clearance_steps: i32,
    /// How far the scan reversed the drive train in total: a hard ceiling on
    /// any figure it can produce.
    pub reversal_budget_steps: i32,
    /// The reversal accumulated by the middle of the scan, where the vertex is
    /// set. A result above this could be a floor rather than the value.
    pub reversal_budget_at_vertex_steps: i32,
    pub confidence: CalibrationConfidence,
    /// Plain-language grounds for the confidence, for the operator to read.
    pub confidence_reason: String,
    pub context: MeasurementContext,
}

impl FocuserBacklashCalibration {
    /// Worse of the two fits — the one that limits the measurement.
    pub fn worst_r_squared(&self) -> f64 {
        self.below.r_squared.min(self.above.r_squared)
    }

    /// One line stating the figure and where it came from, in the house style
    /// for a measured value: never a bare number.
    pub fn provenance(&self) -> String {
        let when = self.context.taken_at.format("%Y-%m-%d %H:%M UTC");
        let temperature = match self.context.temperature_celsius {
            Some(celsius) => format!(", {:.1} °C", celsius),
            None => String::new(),
        };
        if self.measurable {
            format!(
                "{} steps — measured {} at position {}{}, {} confidence",
                self.steps, when, self.measured_at_position, temperature, self.confidence
            )
        } else {
            format!(
                "no backlash larger than {:.0} steps — measured {} at position {}{}, {} confidence",
                self.resolution_limit_steps,
                when,
                self.measured_at_position,
                temperature,
                self.confidence
            )
        }
    }
}

/// Why a calibration produced no figure. Every variant names something the
/// operator can act on; none of them is "it didn't work".
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "code", rename_all = "snake_case")]
pub enum CalibrationRefusal {
    /// A scan was abandoned part-way because frame after frame found no stars.
    ScanAbandonedForStars {
        direction: ApproachDirection,
        low_points: usize,
        total_points: usize,
        star_floor: u32,
    },
    /// Too few points survived to the fit to describe a curve.
    NotEnoughPoints {
        direction: ApproachDirection,
        points: usize,
        required: usize,
    },
    /// The frames nearest focus — the ones the vertex depends on — did not
    /// find enough stars.
    TooFewStarsAtFocus {
        direction: ApproachDirection,
        position: i32,
        stars: u32,
        required: u32,
    },
    /// Enough points, but too few of them measurable, so the curve is
    /// reconstructed from a handful of frames.
    TooFewMeasurablePoints {
        direction: ApproachDirection,
        measurable: usize,
        required: usize,
        star_floor: u32,
    },
    /// A fit too poor to locate a vertex.
    PoorFit {
        direction: ApproachDirection,
        r_squared: f64,
        required: f64,
    },
    /// The fitted vertex lies outside the range that was scanned, so focus
    /// was never bracketed and the vertex is an extrapolation.
    VertexOutsideScan {
        direction: ApproachDirection,
        vertex: i32,
        span: (i32, i32),
    },
    /// The two vertices are further apart than the scan is wide. They cannot
    /// both be describing the same focus curve.
    ExceedsScanRange {
        vertex_difference: i32,
        scan_span: i32,
    },
    /// A backlash wider than the scan ever reversed the drive train. Nothing
    /// in the scan could have taken up a dead band that big, so the number
    /// did not come from one.
    ExceedsReversalBudget {
        vertex_difference: i32,
        reversal_budget_steps: i32,
        clearance_steps: i32,
    },
    /// A meaningfully negative difference, which backlash cannot produce: the
    /// dead-band takeup is confined to `[0, b]`, so the from-below optimum
    /// cannot sit below the from-above one. Something changed between the two
    /// scans.
    NegativeBeyondResolution {
        vertex_difference: i32,
        resolution_limit_steps: f64,
    },
}

impl CalibrationRefusal {
    /// A short machine-stable identifier, for logs and UI mapping.
    pub fn code(&self) -> &'static str {
        match self {
            Self::ScanAbandonedForStars { .. } => "scan_abandoned_for_stars",
            Self::NotEnoughPoints { .. } => "not_enough_points",
            Self::TooFewStarsAtFocus { .. } => "too_few_stars_at_focus",
            Self::TooFewMeasurablePoints { .. } => "too_few_measurable_points",
            Self::PoorFit { .. } => "poor_fit",
            Self::VertexOutsideScan { .. } => "vertex_outside_scan",
            Self::ExceedsScanRange { .. } => "exceeds_scan_range",
            Self::ExceedsReversalBudget { .. } => "exceeds_reversal_budget",
            Self::NegativeBeyondResolution { .. } => "negative_beyond_resolution",
        }
    }

    /// What the operator should do about it.
    pub fn remedy(&self) -> String {
        match self {
            Self::ScanAbandonedForStars { .. } | Self::TooFewStarsAtFocus { .. } => {
                "Point at a richer star field, get roughly in focus first, or raise the \
                 exposure time, then run the calibration again."
                    .to_string()
            }
            Self::NotEnoughPoints { .. } | Self::TooFewMeasurablePoints { .. } => {
                "Widen the scan or lengthen the exposure so more points return a usable \
                 star measurement."
                    .to_string()
            }
            Self::PoorFit { .. } => {
                "Start from rough focus and wait for steadier seeing — the samples did not \
                 trace a focus curve."
                    .to_string()
            }
            Self::VertexOutsideScan { .. } => {
                "Get closer to focus before starting, or widen the scan, so best focus falls \
                 inside the range being scanned."
                    .to_string()
            }
            Self::ExceedsScanRange { .. } => {
                "Widen the scan. The two directions found optima further apart than the scan \
                 covers, so at least one of them is not on the focus curve."
                    .to_string()
            }
            Self::ExceedsReversalBudget {
                clearance_steps, ..
            } => format!(
                "Raise the run-up well above {} steps, or widen the scan, and run the \
                 calibration again.",
                clearance_steps
            ),
            Self::NegativeBeyondResolution { .. } => {
                "Check that the focuser reaches the positions it is sent to, then run the \
                 calibration again — ideally over a shorter span so focus cannot drift \
                 between the two scans."
                    .to_string()
            }
        }
    }
}

impl fmt::Display for CalibrationRefusal {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::ScanAbandonedForStars {
                direction,
                low_points,
                total_points,
                star_floor,
            } => write!(
                f,
                "The {} scan was stopped after {} of {} frames found fewer than {} stars",
                direction, low_points, total_points, star_floor
            ),
            Self::NotEnoughPoints {
                direction,
                points,
                required,
            } => write!(
                f,
                "The {} scan reached the fit with only {} usable points; {} are needed to \
                 describe a curve",
                direction, points, required
            ),
            Self::TooFewStarsAtFocus {
                direction,
                position,
                stars,
                required,
            } => write!(
                f,
                "The {} scan's frame nearest focus (position {}) found {} stars, under the {} \
                 needed — the optimum it reports would be the average of a handful of stars",
                direction, position, stars, required
            ),
            Self::TooFewMeasurablePoints {
                direction,
                measurable,
                required,
                star_floor,
            } => write!(
                f,
                "Only {} points of the {} scan found {} or more stars; {} are needed",
                measurable, direction, star_floor, required
            ),
            Self::PoorFit {
                direction,
                r_squared,
                required,
            } => write!(
                f,
                "The {} scan fitted R² {:.3}, below the {:.3} required to locate an optimum",
                direction, r_squared, required
            ),
            Self::VertexOutsideScan {
                direction,
                vertex,
                span,
            } => write!(
                f,
                "The {} scan's optimum came out at {}, outside the {}–{} it scanned, so focus \
                 was never bracketed",
                direction, vertex, span.0, span.1
            ),
            Self::ExceedsScanRange {
                vertex_difference,
                scan_span,
            } => write!(
                f,
                "The two directions disagree by {} steps across a scan only {} steps wide",
                vertex_difference, scan_span
            ),
            Self::ExceedsReversalBudget {
                vertex_difference,
                reversal_budget_steps,
                ..
            } => write!(
                f,
                "The measurement came out at {} steps, but the scan only ever reversed the \
                 drive train by {} — so nothing in it could have taken up a dead band that wide",
                vertex_difference, reversal_budget_steps
            ),
            Self::NegativeBeyondResolution {
                vertex_difference,
                resolution_limit_steps,
            } => write!(
                f,
                "The two scans put focus {} steps apart in the order backlash cannot produce, \
                 by more than the {:.0}-step resolution of this scan. Focus moved between the \
                 two passes, or the focuser is not reaching the positions it is sent to",
                vertex_difference, resolution_limit_steps
            ),
        }
    }
}

/// Smallest vertex difference two scans of these spacings could tell apart.
pub fn resolution_limit_steps(below: &DirectionalScan, above: &DirectionalScan) -> f64 {
    let coarsest = below
        .median_spacing()
        .abs()
        .max(above.median_spacing().abs())
        .max(1);
    (f64::from(coarsest) * VERTEX_RESOLUTION_FRACTION).max(MIN_RESOLUTION_LIMIT_STEPS)
}

/// Turn two directional scans into a backlash figure, or into a refusal that
/// says what to do instead.
///
/// The arithmetic is one subtraction. Everything else here is the set of
/// conditions under which that subtraction is not a measurement.
pub fn derive_backlash_calibration(
    below: DirectionalScan,
    above: DirectionalScan,
    thresholds: BacklashAnalysisThresholds,
    context: MeasurementContext,
) -> Result<FocuserBacklashCalibration, CalibrationRefusal> {
    for scan in [&below, &above] {
        validate_scan(scan, thresholds)?;
    }

    let vertex_difference = below
        .optimum_position
        .saturating_sub(above.optimum_position);
    let resolution = resolution_limit_steps(&below, &above);

    // Both scans cover the same ground, but rejection can trim either, so the
    // narrower one bounds what the pair can say.
    let scan_span = below.span_steps().min(above.span_steps());
    if vertex_difference.abs() > scan_span {
        return Err(CalibrationRefusal::ExceedsScanRange {
            vertex_difference,
            scan_span,
        });
    }

    if f64::from(vertex_difference) < -resolution {
        return Err(CalibrationRefusal::NegativeBeyondResolution {
            vertex_difference,
            resolution_limit_steps: resolution,
        });
    }

    if vertex_difference > thresholds.reversal_budget_steps {
        return Err(CalibrationRefusal::ExceedsReversalBudget {
            vertex_difference,
            reversal_budget_steps: thresholds.reversal_budget_steps,
            clearance_steps: thresholds.clearance_steps,
        });
    }

    let measurable = f64::from(vertex_difference) > resolution;
    // Inside the resolution limit the honest figure is zero, in both
    // directions: a small negative is noise about zero, not a negative gear.
    let steps = if measurable { vertex_difference } else { 0 };

    let (confidence, confidence_reason) = grade_confidence(
        &below,
        &above,
        vertex_difference,
        resolution,
        measurable,
        thresholds.reversal_budget_at_vertex_steps,
    );

    let measured_at_position = below.optimum_position;

    Ok(FocuserBacklashCalibration {
        steps,
        vertex_difference,
        measurable,
        resolution_limit_steps: resolution,
        below,
        above,
        measured_at_position,
        clearance_steps: thresholds.clearance_steps,
        reversal_budget_steps: thresholds.reversal_budget_steps,
        reversal_budget_at_vertex_steps: thresholds.reversal_budget_at_vertex_steps,
        confidence,
        confidence_reason,
        context,
    })
}

fn validate_scan(
    scan: &DirectionalScan,
    thresholds: BacklashAnalysisThresholds,
) -> Result<(), CalibrationRefusal> {
    if scan.points.len() < MIN_FIT_POINTS {
        return Err(CalibrationRefusal::NotEnoughPoints {
            direction: scan.approach,
            points: scan.points.len(),
            required: MIN_FIT_POINTS,
        });
    }

    let star_floor = thresholds.min_star_count.max(1);

    // The frame nearest focus is checked on its own because it carries the
    // vertex. A scan can have healthy wings and still be worthless if the
    // bottom of the V was measured from four stars.
    if let Some(best) = scan.best_point() {
        if best.star_count < star_floor {
            return Err(CalibrationRefusal::TooFewStarsAtFocus {
                direction: scan.approach,
                position: best.position,
                stars: best.star_count,
                required: star_floor,
            });
        }
    }

    let measurable = scan.points_meeting_star_floor(star_floor);
    if measurable < MIN_FIT_POINTS {
        return Err(CalibrationRefusal::TooFewMeasurablePoints {
            direction: scan.approach,
            measurable,
            required: MIN_FIT_POINTS,
            star_floor,
        });
    }

    if scan.r_squared < thresholds.r_squared_threshold {
        return Err(CalibrationRefusal::PoorFit {
            direction: scan.approach,
            r_squared: scan.r_squared,
            required: thresholds.r_squared_threshold,
        });
    }

    if let Some((lo, hi)) = scan.span() {
        if !(lo..=hi).contains(&scan.optimum_position) {
            return Err(CalibrationRefusal::VertexOutsideScan {
                direction: scan.approach,
                vertex: scan.optimum_position,
                span: (lo, hi),
            });
        }
    }

    Ok(())
}

fn grade_confidence(
    below: &DirectionalScan,
    above: &DirectionalScan,
    vertex_difference: i32,
    resolution: f64,
    measurable: bool,
    reversal_budget_at_vertex_steps: i32,
) -> (CalibrationConfidence, String) {
    let worst_r_squared = below.r_squared.min(above.r_squared);

    if !measurable {
        // The claim is a bound, not a value, so the only thing that limits it
        // is how well the two curves were fitted.
        let confidence = if worst_r_squared >= HIGH_CONFIDENCE_R_SQUARED {
            CalibrationConfidence::High
        } else if worst_r_squared >= MODERATE_CONFIDENCE_R_SQUARED {
            CalibrationConfidence::Moderate
        } else {
            CalibrationConfidence::Low
        };
        return (
            confidence,
            format!(
                "Both optima landed within {:.0} steps of each other, which is all these scans \
                 could resolve; the poorer of the two fits was R² {:.3}. This focuser has no \
                 backlash worth compensating in this part of its travel.",
                resolution, worst_r_squared
            ),
        );
    }

    let multiple = f64::from(vertex_difference).abs() / resolution;

    // The points that set the vertex sit around the middle of the scan, so a
    // result above the reversal accumulated by then may be a floor rather than
    // the value: the gear was still being taken up while the vertex was being
    // measured. Under-reporting cannot be detected from one run — it produces
    // a smaller number, and nothing in the data says how much smaller — so the
    // honest move is to say the figure is bounded and ask for a bigger run-up.
    if vertex_difference > reversal_budget_at_vertex_steps {
        return (
            CalibrationConfidence::Low,
            format!(
                "{} steps is as far as this scan had reversed the drive train ({} steps) by the \
                 points that set the optimum, so the real figure could be larger. Re-run with a \
                 larger run-up to confirm.",
                vertex_difference, reversal_budget_at_vertex_steps
            ),
        );
    }

    if worst_r_squared >= HIGH_CONFIDENCE_R_SQUARED
        && multiple >= HIGH_CONFIDENCE_RESOLUTION_MULTIPLE
    {
        return (
            CalibrationConfidence::High,
            format!(
                "Both directions fitted well (poorer of the two R² {:.3}) and the {} steps \
                 between their optima is {:.1}x what these scans can resolve.",
                worst_r_squared, vertex_difference, multiple
            ),
        );
    }

    if worst_r_squared >= MODERATE_CONFIDENCE_R_SQUARED
        && multiple >= MODERATE_CONFIDENCE_RESOLUTION_MULTIPLE
    {
        return (
            CalibrationConfidence::Moderate,
            format!(
                "The poorer of the two fits was R² {:.3} and the {} steps between the optima is \
                 {:.1}x the resolution of these scans — enough to act on, worth re-measuring on \
                 a steadier night.",
                worst_r_squared, vertex_difference, multiple
            ),
        );
    }

    (
        CalibrationConfidence::Low,
        format!(
            "The {} steps between the optima is only {:.1}x what these scans can resolve \
             (poorer fit R² {:.3}). Treat it as an estimate and re-measure with a finer scan.",
            vertex_difference, multiple, worst_r_squared
        ),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The owner's ZWO EAF, measured by hand over the API on 2026-09-14 near
    /// position 6600. 0.5 s exposures, median HFR of the 25 brightest star
    /// crops, 2 frames per point.
    const RIG_FROM_BELOW: &[(i32, f64)] = &[
        (6320, 14.52),
        (6420, 11.36),
        (6520, 5.66),
        (6620, 2.99),
        (6720, 6.00),
        (6820, 12.86),
    ];
    const RIG_FROM_ABOVE: &[(i32, f64)] = &[
        (6470, 3.32),
        (6520, 2.87),
        (6545, 3.17),
        (6570, 3.76),
        (6595, 4.63),
    ];

    fn points(samples: &[(i32, f64)], star_count: u32) -> Vec<FocusDataPoint> {
        samples
            .iter()
            .map(|&(position, hfr)| FocusDataPoint {
                position,
                hfr,
                fwhm: None,
                star_count,
            })
            .collect()
    }

    fn scan(
        approach: ApproachDirection,
        samples: &[(i32, f64)],
        optimum_position: i32,
        r_squared: f64,
    ) -> DirectionalScan {
        DirectionalScan {
            approach,
            points: points(samples, 40),
            optimum_position,
            r_squared,
            method: AutofocusMethod::Quadratic,
        }
    }

    /// The same from-above shape, shifted so its samples bracket 6620 rather
    /// than 6515. Needed by the cases where the two optima coincide: a vertex
    /// has to lie inside the points that produced it or it is an
    /// extrapolation, which the analysis refuses on its own.
    const COINCIDENT_FROM_ABOVE: &[(i32, f64)] = &[
        (6575, 3.32),
        (6625, 2.87),
        (6650, 3.17),
        (6675, 3.76),
        (6700, 4.63),
    ];

    /// 13 points at the 30-step spacing the calibration routine actually uses,
    /// on a parabola through the owner's measured depth (HFR 2.99 at focus,
    /// ~12 at ±180).
    fn thirteen_point_scan(vertex: i32) -> Vec<(i32, f64)> {
        (0..13)
            .map(|index| {
                let position = vertex - 180 + index * 30;
                let offset = f64::from(position - vertex);
                (position, 2.99 + offset * offset * 0.000_28)
            })
            .collect()
    }

    fn thresholds() -> BacklashAnalysisThresholds {
        BacklashAnalysisThresholds {
            min_star_count: 10,
            r_squared_threshold: 0.9,
            clearance_steps: 300,
            // 300 + 12 * 30, and 300 + 5 * 30 by the middle of the scan.
            reversal_budget_steps: 660,
            reversal_budget_at_vertex_steps: 450,
        }
    }

    fn context() -> MeasurementContext {
        MeasurementContext {
            focuser_device_id: "zwo-eaf-1".to_string(),
            taken_at: DateTime::from_timestamp(1_757_900_000, 0).expect("valid fixture timestamp"),
            temperature_celsius: Some(14.5),
            app_version: "7.0.0+28".to_string(),
        }
    }

    fn rig_scans() -> (DirectionalScan, DirectionalScan) {
        (
            scan(ApproachDirection::FromBelow, RIG_FROM_BELOW, 6620, 0.98),
            scan(ApproachDirection::FromAbove, RIG_FROM_ABOVE, 6515, 0.97),
        )
    }

    #[test]
    fn the_owners_rig_measures_105_steps() {
        let (below, above) = rig_scans();
        let calibration = derive_backlash_calibration(below, above, thresholds(), context())
            .expect("the rig's own numbers must produce a figure");

        assert_eq!(calibration.steps, 105);
        assert_eq!(calibration.vertex_difference, 105);
        assert!(calibration.measurable);
        assert_eq!(calibration.measured_at_position, 6620);
        // His from-below pass stepped 100 at a time, which locates a vertex to
        // no better than 50 steps, so 105 is only 2.1x the resolution of the
        // scan that produced it. Moderate is the honest grade for these
        // samples — see the next test for what the app's own spacing earns.
        assert_eq!(calibration.confidence, CalibrationConfidence::Moderate);
    }

    /// The calibration routine samples every 30 steps, which resolves a vertex
    /// to 15 — so the same 105-step backlash comes out at 7x the resolution
    /// limit and is reported with high confidence.
    #[test]
    fn the_routines_own_scan_spacing_grades_the_same_backlash_high() {
        let below = scan(
            ApproachDirection::FromBelow,
            &thirteen_point_scan(6620),
            6620,
            0.99,
        );
        let above = scan(
            ApproachDirection::FromAbove,
            &thirteen_point_scan(6515),
            6515,
            0.98,
        );
        let calibration = derive_backlash_calibration(below, above, thresholds(), context())
            .expect("a clean pair of scans must produce a figure");

        assert_eq!(calibration.steps, 105);
        assert_eq!(calibration.resolution_limit_steps, 15.0);
        assert_eq!(calibration.confidence, CalibrationConfidence::High);
    }

    /// The 2026-09-08 measurement lower in the travel gave ~83 steps, which is
    /// why the record carries its position: the same focuser, a different
    /// answer.
    #[test]
    fn the_same_focuser_lower_in_its_travel_measures_differently() {
        let below = scan(
            ApproachDirection::FromBelow,
            &[
                (2200, 13.9),
                (2300, 10.2),
                (2400, 5.4),
                (2506, 2.8),
                (2600, 5.9),
                (2700, 11.4),
            ],
            2506,
            0.98,
        );
        let above = scan(
            ApproachDirection::FromAbove,
            &[
                (2323, 3.3),
                (2373, 2.9),
                (2423, 2.8),
                (2473, 3.7),
                (2523, 4.8),
            ],
            2423,
            0.96,
        );
        let calibration = derive_backlash_calibration(below, above, thresholds(), context())
            .expect("a clean pair of scans must produce a figure");

        assert_eq!(calibration.steps, 83);
        assert_eq!(calibration.measured_at_position, 2506);
    }

    #[test]
    fn provenance_states_the_position_time_and_confidence() {
        let (below, above) = rig_scans();
        let calibration =
            derive_backlash_calibration(below, above, thresholds(), context()).expect("figure");
        let provenance = calibration.provenance();

        assert!(provenance.contains("105 steps"), "{provenance}");
        assert!(provenance.contains("position 6620"), "{provenance}");
        assert!(provenance.contains("14.5 °C"), "{provenance}");
        assert!(provenance.contains("moderate confidence"), "{provenance}");
    }

    #[test]
    fn two_coincident_optima_report_no_measurable_backlash_rather_than_a_figure() {
        let below = scan(ApproachDirection::FromBelow, RIG_FROM_BELOW, 6620, 0.99);
        let above = scan(
            ApproachDirection::FromAbove,
            COINCIDENT_FROM_ABOVE,
            6618,
            0.98,
        );
        let calibration = derive_backlash_calibration(below, above, thresholds(), context())
            .expect("coincident optima are a result, not a failure");

        assert_eq!(calibration.steps, 0);
        assert_eq!(calibration.vertex_difference, 2);
        assert!(!calibration.measurable);
        assert!(calibration.provenance().contains("no backlash larger than"));
    }

    /// The case the brief singles out: a small negative must not be clamped
    /// into a fake positive, and must not be refused either — inside the
    /// resolution limit it is noise about zero.
    #[test]
    fn a_small_negative_difference_is_zero_not_a_fabricated_positive() {
        let below = scan(ApproachDirection::FromBelow, RIG_FROM_BELOW, 6620, 0.99);
        let above = scan(
            ApproachDirection::FromAbove,
            COINCIDENT_FROM_ABOVE,
            6640,
            0.98,
        );
        let calibration = derive_backlash_calibration(below, above, thresholds(), context())
            .expect("a difference inside the resolution limit is a zero result");

        assert_eq!(calibration.steps, 0);
        assert_eq!(calibration.vertex_difference, -20);
        assert!(!calibration.measurable);
    }

    #[test]
    fn a_negative_difference_beyond_the_resolution_limit_is_refused_as_impossible() {
        let below = scan(ApproachDirection::FromBelow, RIG_FROM_BELOW, 6520, 0.99);
        let above = scan(ApproachDirection::FromAbove, RIG_FROM_ABOVE, 6595, 0.98);
        let refusal = derive_backlash_calibration(below, above, thresholds(), context())
            .expect_err("-75 steps is not a backlash");

        // Backlash confines the dead-band takeup to [0, b], so the from-below
        // optimum cannot sit below the from-above one. This says focus moved
        // between the passes, or the focuser is not going where it is sent.
        assert_eq!(
            refusal,
            CalibrationRefusal::NegativeBeyondResolution {
                vertex_difference: -75,
                resolution_limit_steps: 50.0,
            }
        );
        assert!(
            refusal.remedy().contains("reaches the positions"),
            "{}",
            refusal.remedy()
        );
    }

    /// A figure wider than the scan ever reversed the drive train did not come
    /// out of that scan's gear.
    #[test]
    fn a_result_wider_than_the_scan_reversed_the_drive_train_is_refused() {
        let below = scan(ApproachDirection::FromBelow, RIG_FROM_BELOW, 6620, 0.99);
        let above = scan(ApproachDirection::FromAbove, RIG_FROM_ABOVE, 6515, 0.98);
        let thresholds = BacklashAnalysisThresholds {
            clearance_steps: 40,
            reversal_budget_steps: 80,
            reversal_budget_at_vertex_steps: 55,
            ..thresholds()
        };
        let refusal = derive_backlash_calibration(below, above, thresholds, context())
            .expect_err("105 steps cannot come out of a scan that reversed only 80");

        assert_eq!(refusal.code(), "exceeds_reversal_budget");
    }

    /// The reversal budget is how far the scan drove the gear back, so a
    /// figure equal to it is one the scan could have produced; one step more is
    /// not. Only the far-over case above was pinned.
    #[test]
    fn a_result_equal_to_the_reversal_budget_is_accepted_and_one_over_refused() {
        let at_budget = BacklashAnalysisThresholds {
            reversal_budget_steps: 105,
            ..thresholds()
        };
        let (below, above) = rig_scans();
        let calibration = derive_backlash_calibration(below, above, at_budget, context())
            .expect("105 steps from a scan that reversed 105 is within what it covered");
        assert_eq!(calibration.steps, 105);

        let one_short = BacklashAnalysisThresholds {
            reversal_budget_steps: 104,
            ..thresholds()
        };
        let (below, above) = rig_scans();
        let refusal = derive_backlash_calibration(below, above, one_short, context())
            .expect_err("105 steps cannot come out of a 104-step reversal");
        assert_eq!(refusal.code(), "exceeds_reversal_budget");
    }

    /// The correction the gear-train simulation forced: a run-up smaller than
    /// the backlash is NOT in itself a reason to refuse. What matters is the
    /// reversal the scan accumulates, and a 40-step run-up over 13 points at a
    /// 30-step spacing accumulates 130 — enough to expose 105.
    #[test]
    fn a_run_up_smaller_than_the_backlash_still_measures_it_given_enough_points() {
        let below = scan(ApproachDirection::FromBelow, RIG_FROM_BELOW, 6620, 0.99);
        let above = scan(ApproachDirection::FromAbove, RIG_FROM_ABOVE, 6515, 0.98);
        let thresholds = BacklashAnalysisThresholds {
            clearance_steps: 40,
            reversal_budget_steps: 400,
            reversal_budget_at_vertex_steps: 190,
            ..thresholds()
        };
        let calibration = derive_backlash_calibration(below, above, thresholds, context())
            .expect("130 steps of reversal is enough to expose 105");

        assert_eq!(calibration.steps, 105);
        // Reported, and not held back by the modest run-up: 190 steps of
        // reversal by the vertex clears 105 comfortably. Moderate rather than
        // high only because these are the owner's hand-measured samples, whose
        // 100-step from-below spacing resolves a vertex to no better than 50.
        assert_eq!(calibration.confidence, CalibrationConfidence::Moderate);
    }

    #[test]
    fn a_result_wider_than_the_scan_is_refused() {
        let below = scan(ApproachDirection::FromBelow, RIG_FROM_BELOW, 6820, 0.99);
        let above = scan(ApproachDirection::FromAbove, RIG_FROM_ABOVE, 6470, 0.98);
        let refusal = derive_backlash_calibration(below, above, thresholds(), context())
            .expect_err("350 steps across a 125-step scan is not a measurement");

        assert_eq!(refusal.code(), "exceeds_scan_range");
    }

    #[test]
    fn a_poor_fit_is_refused_and_names_the_direction() {
        let below = scan(ApproachDirection::FromBelow, RIG_FROM_BELOW, 6620, 0.99);
        let above = scan(ApproachDirection::FromAbove, RIG_FROM_ABOVE, 6515, 0.41);
        let refusal = derive_backlash_calibration(below, above, thresholds(), context())
            .expect_err("R² 0.41 cannot locate an optimum");

        assert_eq!(
            refusal,
            CalibrationRefusal::PoorFit {
                direction: ApproachDirection::FromAbove,
                r_squared: 0.41,
                required: 0.9,
            }
        );
        assert!(refusal.to_string().contains("from above"));
    }

    #[test]
    fn a_star_starved_frame_at_focus_is_refused() {
        let mut below = scan(ApproachDirection::FromBelow, RIG_FROM_BELOW, 6620, 0.99);
        // 6620 is the minimum-HFR point: the one the vertex rests on.
        below.points[3].star_count = 4;
        let above = scan(ApproachDirection::FromAbove, RIG_FROM_ABOVE, 6515, 0.98);
        let refusal = derive_backlash_calibration(below, above, thresholds(), context())
            .expect_err("four stars at focus cannot locate an optimum");

        assert_eq!(
            refusal,
            CalibrationRefusal::TooFewStarsAtFocus {
                direction: ApproachDirection::FromBelow,
                position: 6620,
                stars: 4,
                required: 10,
            }
        );
    }

    #[test]
    fn a_scan_with_mostly_star_starved_wings_is_refused() {
        let mut below = scan(ApproachDirection::FromBelow, RIG_FROM_BELOW, 6620, 0.99);
        for point in below.points.iter_mut() {
            if point.position != 6620 && point.position != 6520 {
                point.star_count = 3;
            }
        }
        let above = scan(ApproachDirection::FromAbove, RIG_FROM_ABOVE, 6515, 0.98);
        let refusal = derive_backlash_calibration(below, above, thresholds(), context())
            .expect_err("two usable points do not make a curve");

        assert_eq!(
            refusal,
            CalibrationRefusal::TooFewMeasurablePoints {
                direction: ApproachDirection::FromBelow,
                measurable: 2,
                required: MIN_FIT_POINTS,
                star_floor: 10,
            }
        );
    }

    #[test]
    fn a_four_point_scan_is_refused_rather_than_fitted() {
        let below = scan(
            ApproachDirection::FromBelow,
            &RIG_FROM_BELOW[..4],
            6620,
            0.99,
        );
        let above = scan(ApproachDirection::FromAbove, RIG_FROM_ABOVE, 6515, 0.98);
        let refusal = derive_backlash_calibration(below, above, thresholds(), context())
            .expect_err("four points fit a parabola too well to mean anything");

        assert_eq!(
            refusal,
            CalibrationRefusal::NotEnoughPoints {
                direction: ApproachDirection::FromBelow,
                points: 4,
                required: MIN_FIT_POINTS,
            }
        );
    }

    #[test]
    fn an_extrapolated_vertex_is_refused() {
        let below = scan(ApproachDirection::FromBelow, RIG_FROM_BELOW, 7100, 0.99);
        let above = scan(ApproachDirection::FromAbove, RIG_FROM_ABOVE, 6515, 0.98);
        let refusal = derive_backlash_calibration(below, above, thresholds(), context())
            .expect_err("a vertex past the end of the scan is an extrapolation");

        assert_eq!(
            refusal,
            CalibrationRefusal::VertexOutsideScan {
                direction: ApproachDirection::FromBelow,
                vertex: 7100,
                span: (6320, 6820),
            }
        );
    }

    #[test]
    fn a_result_crowding_the_scans_reversal_is_reported_at_low_confidence_not_refused() {
        let below = scan(ApproachDirection::FromBelow, RIG_FROM_BELOW, 6620, 0.99);
        let above = scan(ApproachDirection::FromAbove, RIG_FROM_ABOVE, 6515, 0.98);
        let thresholds = BacklashAnalysisThresholds {
            reversal_budget_at_vertex_steps: 90,
            ..thresholds()
        };
        let calibration = derive_backlash_calibration(below, above, thresholds, context())
            .expect("still a measurement, just an uncertain one");

        assert_eq!(calibration.steps, 105);
        assert_eq!(calibration.confidence, CalibrationConfidence::Low);
        assert!(calibration.confidence_reason.contains("could be larger"));
    }

    #[test]
    fn the_resolution_limit_follows_the_coarser_scan() {
        let (below, above) = rig_scans();
        // 100-step spacing below, 25-step median above.
        assert_eq!(below.median_spacing(), 100);
        assert_eq!(above.median_spacing(), 25);
        assert_eq!(resolution_limit_steps(&below, &above), 50.0);
    }

    #[test]
    fn a_one_step_scan_never_claims_sub_step_resolution() {
        let below = scan(
            ApproachDirection::FromBelow,
            &[(100, 9.0), (101, 6.0), (102, 3.0), (103, 6.0), (104, 9.0)],
            102,
            0.99,
        );
        let above = scan(
            ApproachDirection::FromAbove,
            &[(100, 9.0), (101, 6.0), (102, 3.0), (103, 6.0), (104, 9.0)],
            102,
            0.99,
        );
        assert_eq!(resolution_limit_steps(&below, &above), 1.0);
    }

    #[test]
    fn a_refusal_serialises_with_a_stable_code_for_the_ui() {
        let refusal = CalibrationRefusal::PoorFit {
            direction: ApproachDirection::FromAbove,
            r_squared: 0.4,
            required: 0.9,
        };
        let json = serde_json::to_value(&refusal).expect("refusals must serialise");
        assert_eq!(json["code"], "poor_fit");
        assert_eq!(json["direction"], "from_above");
    }

    #[test]
    fn a_calibration_round_trips_through_json_with_its_evidence() {
        let (below, above) = rig_scans();
        let calibration =
            derive_backlash_calibration(below, above, thresholds(), context()).expect("figure");
        let json = serde_json::to_string(&calibration).expect("must serialise");
        let restored: FocuserBacklashCalibration =
            serde_json::from_str(&json).expect("must deserialise");

        assert_eq!(restored.steps, 105);
        assert_eq!(restored.below.points.len(), 6);
        assert_eq!(restored.above.points.len(), 5);
        assert_eq!(restored.context.focuser_device_id, "zwo-eaf-1");
        assert_eq!(restored.context.app_version, "7.0.0+28");
    }
}
