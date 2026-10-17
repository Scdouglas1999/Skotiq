//! What calibration was actually applied to a group's lights, and how well it
//! matched them.
//!
//! The matcher that *chooses* a dark/flat/bias runs in Dart; this module states
//! the consequences of that choice from the files themselves. Every comparison
//! reads the master's own FITS header against the group's anchor light, so the
//! report describes the bytes that were subtracted and divided, not the
//! intentions of whoever picked them.
//!
//! Three rules the shape enforces:
//!
//! * A calibration type with no master is an explicit entry
//!   ([`MatchQuality::Missing`]), never an omission.
//! * A dimension that could not be compared — either side missing the keyword —
//!   lands in [`AppliedMaster::unverified`] instead of counting as a match.
//! * Staleness is measured, not assumed: an in-date master, an out-of-date one
//!   and one whose date is unknown each read differently.

use super::*;

/// Maximum separation between a master **dark** and the lights it calibrates.
///
/// A sensor's hot-pixel population and dark-current floor drift as the detector
/// ages, and a dark library rebuilt seasonally tracks that drift; beyond a
/// quarter the residual after subtraction stops being noise-limited and starts
/// showing structure the frame no longer has.
pub(crate) const DARK_MAX_AGE_DAYS: f64 = 90.0;

/// Maximum separation between a master **bias** and the lights it calibrates.
///
/// The read pedestal is set by the readout electronics and is stable over far
/// longer than dark current; it moves on firmware, gain-mode or hardware
/// changes, which the gain/offset/instrument dimensions catch directly. Twice
/// the dark window keeps the age term meaningful without flagging a bias that
/// is still exactly right.
pub(crate) const BIAS_MAX_AGE_DAYS: f64 = 180.0;

/// Maximum separation between a master **flat** and the lights it calibrates.
///
/// A flat records the *current* optical train: dust motes migrate, a filter
/// wheel repositions with hysteresis, and refocusing shifts vignetting. Flats
/// are conventionally shot per session, so a week is already generous — beyond
/// it, dividing by the flat can add dust shadows rather than remove them.
pub(crate) const FLAT_MAX_AGE_DAYS: f64 = 7.0;

/// Maximum sensor-temperature difference (°C) between a master dark and the
/// lights it is subtracted from.
///
/// CMOS dark current roughly doubles every 5–7 °C, so a 2 °C mismatch leaves a
/// ~20–30 % dark-current error — enough residual amp glow to survive
/// integration as a fixed pattern. Below that the residual is under the
/// per-frame read noise.
pub(crate) const DARK_MAX_TEMP_DELTA_C: f64 = 2.0;

/// Maximum sensor-temperature difference (°C) between a master bias and the
/// lights it is subtracted from.
///
/// The bias pedestal is dominated by the readout amplifier, which is
/// temperature-insensitive to first order over the range a cooled camera
/// operates in; the wider window reflects that a bias is not a dark.
pub(crate) const BIAS_MAX_TEMP_DELTA_C: f64 = 10.0;

/// Maximum fractional exposure difference between a master dark and the lights.
///
/// [`skotiq_imaging::calibration::calibrate_frame`] subtracts the dark
/// as-is — it does **not** scale it by exposure ratio — so a dark of a different
/// duration over- or under-subtracts dark current in direct proportion. 1 %
/// absorbs the jitter of a real shutter without absorbing a genuinely different
/// exposure.
pub(crate) const DARK_MAX_EXPOSURE_FRACTION: f64 = 0.01;

/// Which calibration slot an [`AppliedMaster`] describes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) enum MasterKind {
    Dark,
    Flat,
    Bias,
}

impl MasterKind {
    /// The wire token for this slot.
    pub(crate) fn wire(self) -> &'static str {
        match self {
            MasterKind::Dark => "dark",
            MasterKind::Flat => "flat",
            MasterKind::Bias => "bias",
        }
    }

    /// Maximum age, in days, before this slot's master reads as stale.
    fn max_age_days(self) -> f64 {
        match self {
            MasterKind::Dark => DARK_MAX_AGE_DAYS,
            MasterKind::Flat => FLAT_MAX_AGE_DAYS,
            MasterKind::Bias => BIAS_MAX_AGE_DAYS,
        }
    }

    /// Maximum sensor-temperature difference, or `None` for a slot whose
    /// correction does not depend on temperature.
    fn max_temperature_delta_c(self) -> Option<f64> {
        match self {
            MasterKind::Dark => Some(DARK_MAX_TEMP_DELTA_C),
            MasterKind::Bias => Some(BIAS_MAX_TEMP_DELTA_C),
            MasterKind::Flat => None,
        }
    }
}

/// How far a compared dimension may differ before the master stops matching.
#[derive(Debug, Clone, Copy)]
enum Tolerance {
    /// Any difference at all makes this a fallback.
    Exact,
    /// `|master - light|` may not exceed this fraction of the light's value.
    Relative(f64),
    /// Reported for the record; a difference never downgrades the match.
    Advisory,
}

/// One dimension along which the applied master differs from the lights.
///
/// `dimension` is the FITS keyword compared. `delta` and `tolerance` are
/// populated only for numeric comparisons; a string dimension (`FILTER`,
/// `INSTRUME`) carries the two values and nothing else. Time and temperature are
/// **not** here — they are the staleness term ([`CalibrationStaleness`]).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct CalibrationMismatch {
    pub(crate) dimension: String,
    /// The value the anchor light carries.
    pub(crate) light: String,
    /// The value the applied master carries.
    pub(crate) master: String,
    /// `master - light` for numeric dimensions.
    pub(crate) delta: Option<f64>,
    /// The threshold `delta` was judged against, in the same units.
    pub(crate) tolerance: Option<f64>,
    /// `false` when this difference alone downgrades the match to a fallback.
    pub(crate) within_tolerance: bool,
}

/// How well an applied master matched the lights it was applied to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) enum MatchQuality {
    /// Applied, and every dimension the report could compare agreed exactly.
    Exact,
    /// Applied, with differences that all stayed inside their tolerances.
    Acceptable,
    /// Applied, but no dimension could be compared at all — a master or light
    /// whose header carries none of the metadata the comparison needs. Distinct
    /// from [`MatchQuality::Exact`] because agreeing on nothing is not a match.
    Unverified,
    /// Applied, with at least one difference past its tolerance. The master
    /// still ran — the caller pinned or matched it — but the result carries a
    /// known calibration error.
    Fallback,
    /// No master of this type was supplied, so this correction did not run.
    Missing,
    /// Deliberately absent: a matched dark already carries the bias pedestal, so
    /// subtracting a separate bias as well would remove it twice.
    NotRequired,
}

/// The staleness term for one applied master: how far it sits from the lights in
/// time and in sensor temperature, and the threshold each was judged against.
///
/// Kept apart from [`CalibrationMismatch`] because these two are continuous and
/// always present — a master is never *exactly* as old as its lights — while a
/// mismatch is a discrete disagreement about what the frame is. Both thresholds
/// are the module constants, surfaced here so a report can explain the verdict
/// without hard-coding the numbers a second time.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct CalibrationStaleness {
    /// `master DATE-OBS - light DATE-OBS`, in days; negative when the master
    /// predates the lights. `null` when either side carries no `DATE-OBS`.
    pub(crate) age_days: Option<f64>,
    /// The maximum separation this slot tolerates, judged on `|age_days|`.
    pub(crate) max_age_days: f64,
    /// `master CCD-TEMP - light CCD-TEMP`, in °C. `null` when either side
    /// carries no `CCD-TEMP`, and always `null` for a flat.
    pub(crate) temperature_delta_c: Option<f64>,
    /// The temperature threshold, or `null` for a slot with no temperature term.
    ///
    /// A flat is normalised to unit mean before it divides, so the temperature it
    /// was shot at does not enter the correction; giving it a threshold would
    /// invent a criterion that means nothing.
    pub(crate) max_temperature_delta_c: Option<f64>,
    /// `true` when age or temperature exceeded its threshold.
    pub(crate) stale: bool,
}

/// One calibration slot's outcome for a group.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct AppliedMaster {
    /// `"dark"` | `"flat"` | `"bias"`.
    pub(crate) kind: String,
    /// The master's path, or `null` when none was applied.
    pub(crate) path: Option<String>,
    /// Whether this master's correction actually ran over the lights.
    pub(crate) applied: bool,
    pub(crate) quality: MatchQuality,
    /// Every dimension that differs, in a fixed comparison order.
    pub(crate) mismatches: Vec<CalibrationMismatch>,
    /// Dimensions left unjudged because one side's header lacked the keyword —
    /// `"age"` and `"temperature"` included. A match is never claimed for a
    /// dimension listed here.
    pub(crate) unverified: Vec<String>,
    pub(crate) staleness: CalibrationStaleness,
    /// Shorthand for `staleness.stale`.
    pub(crate) stale: bool,
}

impl AppliedMaster {
    /// The slot's entry when no master was supplied.
    fn absent(kind: MasterKind, quality: MatchQuality) -> Self {
        Self {
            kind: kind.wire().to_string(),
            path: None,
            applied: false,
            quality,
            mismatches: Vec::new(),
            unverified: Vec::new(),
            staleness: CalibrationStaleness {
                age_days: None,
                max_age_days: kind.max_age_days(),
                temperature_delta_c: None,
                max_temperature_delta_c: kind.max_temperature_delta_c(),
                stale: false,
            },
            stale: false,
        }
    }
}

/// What calibration ran over one group of lights.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct CalibrationReport {
    /// Always three entries, in dark / flat / bias order.
    pub(crate) masters: Vec<AppliedMaster>,
    /// Whether per-light self-derived hot/cold transient repair ran.
    pub(crate) cosmetic_correction: bool,
    /// The light whose header anchored every comparison — the group's first sub,
    /// matching the anchor the Dart calibration matcher selects on.
    pub(crate) anchor_light: Option<String>,
    /// `true` when the anchor light's header could not be read, so every
    /// dimension is unverified rather than matched.
    pub(crate) anchor_unreadable: bool,
}

impl CalibrationReport {
    /// `true` when any applied master fell back or is stale — the single flag a
    /// morning report needs to decide whether to say anything at all.
    pub(crate) fn has_warnings(&self) -> bool {
        self.masters.iter().any(|m| {
            m.stale
                || matches!(
                    m.quality,
                    MatchQuality::Fallback | MatchQuality::Missing | MatchQuality::Unverified
                )
                || !m.unverified.is_empty()
        })
    }
}

/// Build the applied-masters report for one group.
///
/// `anchor_light` is the group's first sub. Header reads are best-effort by
/// design: a light or master whose header cannot be read yields `unverified`
/// dimensions, never a silent claim of a match. The masters themselves were
/// already read (and any geometry mismatch already rejected) by the caller, so a
/// failure here is a metadata problem, not a calibration one.
pub(crate) fn build_calibration_report(
    anchor_light: &str,
    calibration: &CalibrationArgs,
) -> CalibrationReport {
    let light_header = read_header_if_fits(anchor_light);
    let dark_path = non_blank(&calibration.dark);
    let flat_path = non_blank(&calibration.flat);
    let bias_path = non_blank(&calibration.bias);

    let dark = match dark_path {
        Some(p) => evaluate_master(MasterKind::Dark, p, light_header.as_ref()),
        None => AppliedMaster::absent(MasterKind::Dark, MatchQuality::Missing),
    };
    let flat = match flat_path {
        Some(p) => evaluate_master(MasterKind::Flat, p, light_header.as_ref()),
        None => AppliedMaster::absent(MasterKind::Flat, MatchQuality::Missing),
    };
    let bias = match bias_path {
        Some(p) => evaluate_master(MasterKind::Bias, p, light_header.as_ref()),
        // A matched dark carries the bias pedestal; the pipeline deliberately
        // leaves the bias slot empty rather than double-subtracting it.
        None if dark_path.is_some() => {
            AppliedMaster::absent(MasterKind::Bias, MatchQuality::NotRequired)
        }
        None => AppliedMaster::absent(MasterKind::Bias, MatchQuality::Missing),
    };

    CalibrationReport {
        masters: vec![dark, flat, bias],
        cosmetic_correction: calibration.cosmetic_correction,
        anchor_light: Some(anchor_light.to_string()),
        anchor_unreadable: light_header.is_none(),
    }
}

/// `Some(path)` when an optional path is present and non-blank.
fn non_blank(path: &Option<String>) -> Option<&str> {
    match path {
        Some(p) if !p.trim().is_empty() => Some(p.as_str()),
        _ => None,
    }
}

/// Read a FITS header by path, or `None` for a non-FITS or unreadable file.
///
/// Only FITS carries typed keywords through this reader; XISF and RAW flatten
/// them lossily, so attempting them would compare mangled values.
fn read_header_if_fits(path: &str) -> Option<FitsHeader> {
    let ext = Path::new(path)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    if ext != "fits" && ext != "fit" && ext != "fts" {
        return None;
    }
    read_fits_header(Path::new(path)).ok()
}

/// The dimensions compared for a slot, in a fixed order so two runs over the
/// same files produce the same report.
fn dimensions_for(kind: MasterKind) -> &'static [(&'static str, Tolerance)] {
    match kind {
        MasterKind::Dark => &[
            ("INSTRUME", Tolerance::Exact),
            ("EXPTIME", Tolerance::Relative(DARK_MAX_EXPOSURE_FRACTION)),
            ("GAIN", Tolerance::Exact),
            ("OFFSET", Tolerance::Exact),
            ("XBINNING", Tolerance::Exact),
            ("YBINNING", Tolerance::Exact),
        ],
        MasterKind::Bias => &[
            ("INSTRUME", Tolerance::Exact),
            ("GAIN", Tolerance::Exact),
            ("OFFSET", Tolerance::Exact),
            ("XBINNING", Tolerance::Exact),
            ("YBINNING", Tolerance::Exact),
        ],
        // A flat is normalised to unit mean before it divides, so a different
        // gain changes its noise, not its illumination map — reported, not
        // disqualifying. The filter it was shot through is the whole point of a
        // flat, so that one is exact.
        MasterKind::Flat => &[
            ("INSTRUME", Tolerance::Exact),
            ("FILTER", Tolerance::Exact),
            ("XBINNING", Tolerance::Exact),
            ("YBINNING", Tolerance::Exact),
            ("GAIN", Tolerance::Advisory),
        ],
    }
}

/// Compare one master against the anchor light and classify the match.
fn evaluate_master(
    kind: MasterKind,
    master_path: &str,
    light_header: Option<&FitsHeader>,
) -> AppliedMaster {
    let mut mismatches: Vec<CalibrationMismatch> = Vec::new();
    let mut unverified: Vec<String> = Vec::new();

    let master_header = read_header_if_fits(master_path);
    let staleness = match (light_header, master_header.as_ref()) {
        (Some(light), Some(master)) => {
            for &(dimension, tolerance) in dimensions_for(kind) {
                match compare_dimension(dimension, tolerance, light, master) {
                    Comparison::Same => {}
                    Comparison::Differs(m) => mismatches.push(m),
                    Comparison::Unavailable => unverified.push(dimension.to_string()),
                }
            }
            let staleness = measure_staleness(kind, light, master);
            if staleness.age_days.is_none() {
                unverified.push("age".to_string());
            }
            if staleness.max_temperature_delta_c.is_some()
                && staleness.temperature_delta_c.is_none()
            {
                unverified.push("temperature".to_string());
            }
            staleness
        }
        // One side's header is unreadable: nothing can be judged, and claiming
        // an exact match here is precisely the false reassurance this report
        // exists to remove.
        _ => {
            for &(dimension, _) in dimensions_for(kind) {
                unverified.push(dimension.to_string());
            }
            unverified.push("age".to_string());
            let max_temperature_delta_c = kind.max_temperature_delta_c();
            if max_temperature_delta_c.is_some() {
                unverified.push("temperature".to_string());
            }
            CalibrationStaleness {
                age_days: None,
                max_age_days: kind.max_age_days(),
                temperature_delta_c: None,
                max_temperature_delta_c,
                stale: false,
            }
        }
    };

    // Every slot compares its own dimension list, plus age, plus temperature
    // where it has one.
    let comparable =
        dimensions_for(kind).len() + 1 + usize::from(staleness.max_temperature_delta_c.is_some());
    let quality = if staleness.stale || mismatches.iter().any(|m| !m.within_tolerance) {
        MatchQuality::Fallback
    } else if unverified.len() == comparable {
        MatchQuality::Unverified
    } else if !mismatches.is_empty() {
        MatchQuality::Acceptable
    } else {
        MatchQuality::Exact
    };

    AppliedMaster {
        kind: kind.wire().to_string(),
        path: Some(master_path.to_string()),
        applied: true,
        quality,
        mismatches,
        unverified,
        stale: staleness.stale,
        staleness,
    }
}

/// The outcome of comparing one dimension.
enum Comparison {
    Same,
    Differs(CalibrationMismatch),
    Unavailable,
}

/// Compare one FITS keyword across the light and the master.
fn compare_dimension(
    dimension: &str,
    tolerance: Tolerance,
    light: &FitsHeader,
    master: &FitsHeader,
) -> Comparison {
    let (Some(l), Some(m)) = (light.get(dimension), master.get(dimension)) else {
        return Comparison::Unavailable;
    };
    let light_text = l.to_header_string();
    let master_text = m.to_header_string();

    // A numeric pair is judged on its delta; anything else on exact text.
    match (l.as_f64(), m.as_f64()) {
        (Some(lv), Some(mv)) => {
            let delta = mv - lv;
            let (limit, within) = match tolerance {
                Tolerance::Exact => (0.0, delta == 0.0),
                Tolerance::Relative(t) => {
                    let limit = t * lv.abs();
                    (limit, delta.abs() <= limit)
                }
                Tolerance::Advisory => (f64::INFINITY, true),
            };
            if delta == 0.0 {
                return Comparison::Same;
            }
            Comparison::Differs(CalibrationMismatch {
                dimension: dimension.to_string(),
                light: light_text,
                master: master_text,
                delta: Some(delta),
                tolerance: limit.is_finite().then_some(limit),
                within_tolerance: within,
            })
        }
        _ => {
            if light_text.trim().eq_ignore_ascii_case(master_text.trim()) {
                return Comparison::Same;
            }
            Comparison::Differs(CalibrationMismatch {
                dimension: dimension.to_string(),
                light: light_text,
                master: master_text,
                delta: None,
                tolerance: None,
                within_tolerance: matches!(tolerance, Tolerance::Advisory),
            })
        }
    }
}

/// Measure the staleness term: the master's separation from the lights in time
/// and in sensor temperature, against this slot's thresholds.
///
/// Both deltas are reported signed (`master - light`, so a negative age is a
/// master built before the lights) and judged on their magnitude — a flat shot
/// at the following dawn is exactly as far from the data as one shot the
/// previous dusk, and a dark 3 °C colder is as wrong as one 3 °C warmer.
///
/// A term with no data on one side stays `None` and cannot make the master
/// stale: an unknown separation is unknown, not acceptable.
fn measure_staleness(
    kind: MasterKind,
    light: &FitsHeader,
    master: &FitsHeader,
) -> CalibrationStaleness {
    let max_age_days = kind.max_age_days();
    let max_temperature_delta_c = kind.max_temperature_delta_c();

    let age_days = match (
        light.get_string("DATE-OBS").and_then(parse_fits_datetime),
        master.get_string("DATE-OBS").and_then(parse_fits_datetime),
    ) {
        (Some(light_at), Some(master_at)) => {
            Some((master_at - light_at).num_milliseconds() as f64 / 86_400_000.0)
        }
        _ => None,
    };

    let temperature_delta_c = match (
        max_temperature_delta_c,
        light.get_float("CCD-TEMP"),
        master.get_float("CCD-TEMP"),
    ) {
        (Some(_), Some(light_c), Some(master_c)) => Some(master_c - light_c),
        _ => None,
    };

    let stale = age_days.is_some_and(|d| d.abs() > max_age_days)
        || match (max_temperature_delta_c, temperature_delta_c) {
            (Some(limit), Some(delta)) => delta.abs() > limit,
            _ => false,
        };

    CalibrationStaleness {
        age_days,
        max_age_days,
        temperature_delta_c,
        max_temperature_delta_c,
        stale,
    }
}

/// Parse a FITS `DATE-OBS` value.
///
/// FITS 4.0 §9.1.1 writes `YYYY-MM-DDThh:mm:ss[.sss…]`; the date-only form and a
/// trailing `Z` both appear in the wild. Anything else yields `None`, which
/// leaves the age dimension unverified rather than inventing a date.
fn parse_fits_datetime(value: &str) -> Option<chrono::NaiveDateTime> {
    let text = value.trim().trim_end_matches('Z').trim_end_matches('z');
    for format in [
        "%Y-%m-%dT%H:%M:%S%.f",
        "%Y-%m-%dT%H:%M",
        "%Y-%m-%d %H:%M:%S%.f",
    ] {
        if let Ok(parsed) = chrono::NaiveDateTime::parse_from_str(text, format) {
            return Some(parsed);
        }
    }
    chrono::NaiveDate::parse_from_str(text, "%Y-%m-%d")
        .ok()
        .and_then(|d| d.and_hms_opt(0, 0, 0))
}

/// One fold's calibration in an accumulating master's log.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct FoldCalibration {
    /// The fold label (ISO date / session id) the caller supplied on `add`.
    pub(crate) label: String,
    /// How many lights this fold contributed.
    pub(crate) lights: usize,
    pub(crate) report: CalibrationReport,
}

/// Every fold's calibration for one accumulating master, in fold order.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct FoldCalibrationLog {
    pub(crate) folds: Vec<FoldCalibration>,
}

/// Path of the per-fold calibration log written beside a master sidecar.
///
/// Appended (not extension-replaced) for the same reason as the reference
/// companion: distinct sidecars never collide and the link to the sidecar stays
/// obvious. An accumulating master outlives the process that folded each night
/// into it, so the calibration of a fold from three nights ago has nowhere else
/// to live.
pub(crate) fn calibration_log_path(sidecar: &Path) -> std::path::PathBuf {
    let mut p = sidecar.to_path_buf();
    let name = sidecar
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "master".to_string());
    p.set_file_name(format!("{name}.calib.json"));
    p
}

/// Read a master's fold calibration log. `Ok(None)` when no log exists yet; a
/// log that exists but does not parse is an error, never a silent reset — a
/// truncated record would otherwise erase every earlier fold's provenance.
pub(crate) fn read_fold_calibration_log(
    sidecar: &Path,
) -> Result<Option<FoldCalibrationLog>, String> {
    let path = calibration_log_path(sidecar);
    let bytes = match std::fs::read(&path) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => {
            return Err(format!(
                "failed to read calibration log '{}': {e}",
                path.display()
            ))
        }
    };
    serde_json::from_slice(&bytes)
        .map(Some)
        .map_err(|e| format!("corrupt calibration log '{}': {e}", path.display()))
}

/// Append one fold's calibration to a master's log, creating the log on the
/// first fold.
///
/// The write goes through a temporary sibling and a rename, the same way the
/// Darkroom places an export. A plain `fs::write` truncates first, so a process
/// killed mid-append left a torn log on disk — and because a log that exists and
/// does not parse is an error rather than a silent reset, that single kill made
/// every later fold of that master report failure.
pub(crate) fn append_fold_calibration(
    sidecar: &Path,
    entry: FoldCalibration,
) -> Result<(), String> {
    let mut log = match read_fold_calibration_log(sidecar)? {
        Some(existing) => existing,
        // No log on disk means this is the master's first fold. A log that
        // exists but does not parse already errored out above rather than
        // landing here and erasing the record.
        None => FoldCalibrationLog { folds: Vec::new() },
    };
    log.folds.push(entry);
    let path = calibration_log_path(sidecar);
    let encoded =
        serde_json::to_vec(&log).map_err(|e| format!("failed to encode calibration log: {e}"))?;
    let temp = calibration_log_temp_path(&path);
    std::fs::write(&temp, encoded)
        .map_err(|e| format!("failed to write calibration log '{}': {e}", temp.display()))?;
    match std::fs::rename(&temp, &path) {
        Ok(()) => Ok(()),
        Err(rename_error) => {
            if let Err(cleanup_error) = std::fs::remove_file(&temp) {
                tracing::warn!(
                    "could not remove '{}' after a failed calibration-log rename: {cleanup_error}",
                    temp.display()
                );
            }
            Err(format!(
                "failed to place calibration log '{}': {rename_error}",
                path.display()
            ))
        }
    }
}

/// The temporary sibling a calibration-log write goes through.
fn calibration_log_temp_path(path: &Path) -> std::path::PathBuf {
    let mut p = path.to_path_buf();
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "master.calib.json".to_string());
    p.set_file_name(format!("{name}.nshatmp"));
    p
}

/// The report as FITS `HISTORY` card text, one line per statement.
///
/// Written into every master this pipeline produces so the calibration that
/// shaped the pixels travels with the file, not just with the database row.
/// Deterministic: the slot order is fixed and every mismatch is rendered from
/// its own fields.
pub(crate) fn calibration_history_lines(report: &CalibrationReport) -> Vec<String> {
    let mut lines = Vec::new();
    for master in &report.masters {
        let quality = quality_wire(master.quality);
        match master.path.as_deref() {
            Some(path) => lines.push(format!("Calibration {}: {} [{quality}]", master.kind, path)),
            None => lines.push(format!(
                "Calibration {}: none applied [{quality}]",
                master.kind
            )),
        }
        for mismatch in &master.mismatches {
            let verdict = if mismatch.within_tolerance {
                "within tolerance"
            } else {
                "OUT OF TOLERANCE"
            };
            let numbers = match (mismatch.delta, mismatch.tolerance) {
                (Some(d), Some(t)) => format!(" (delta {d:+.4}, tol {t:.4})"),
                (Some(d), None) => format!(" (delta {d:+.4})"),
                _ => String::new(),
            };
            lines.push(format!(
                "  {} light={} master={}{numbers} {verdict}",
                mismatch.dimension, mismatch.light, mismatch.master
            ));
        }
        if master.applied {
            lines.push(staleness_line(&master.staleness));
        }
        if !master.unverified.is_empty() {
            lines.push(format!("  unverified: {}", master.unverified.join(", ")));
        }
    }
    lines.push(format!(
        "Calibration cosmetic correction: {}",
        if report.cosmetic_correction {
            "applied"
        } else {
            "off"
        }
    ));
    if let Some(anchor) = report.anchor_light.as_deref() {
        lines.push(format!("Calibration compared against light {anchor}"));
    }
    if report.anchor_unreadable {
        lines.push(
            "Calibration anchor light has no readable FITS header; every dimension is unverified"
                .to_string(),
        );
    }
    lines
}

/// What a finalize found where the master's provenance log should be.
///
/// The three cases read differently in the FITS `HISTORY` because they mean
/// different things to whoever opens the file later: a log that was never
/// written, one that cannot be parsed, and one that is there.
pub(crate) enum FoldCalibrationRecord<'a> {
    /// The log as read from disk.
    Present(&'a FoldCalibrationLog),
    /// No log beside the sidecar.
    Missing,
    /// A log exists and could not be read, with the reason.
    Unreadable(&'a str),
}

/// Write an accumulating master's per-fold calibration into `header` as
/// `HISTORY` cards, and return whether the record warrants a warning.
///
/// A warning is raised when any fold fell back, is stale, left a dimension
/// unverified, or — the case a per-fold report cannot state on its own — when
/// the log does not cover every fold the sidecar counted. A master silently
/// missing three nights of calibration provenance is exactly as misleading as
/// one that claims calibration it never applied.
pub(crate) fn write_fold_calibration_history(
    header: &mut FitsHeader,
    record: FoldCalibrationRecord<'_>,
    sidecar_fold_count: usize,
) -> bool {
    let log = match record {
        FoldCalibrationRecord::Present(log) => log,
        FoldCalibrationRecord::Missing => {
            header.add_history(
                "Calibration record unavailable: no fold calibration log beside the sidecar",
            );
            return true;
        }
        FoldCalibrationRecord::Unreadable(reason) => {
            header.add_history(&format!("Calibration record unreadable: {reason}"));
            return true;
        }
    };
    let mut warns = log.folds.len() != sidecar_fold_count;
    if warns {
        header.add_history(&format!(
            "Calibration record covers {} of {sidecar_fold_count} folds",
            log.folds.len()
        ));
    }
    for fold in &log.folds {
        header.add_history(&format!("Fold '{}' ({} lights)", fold.label, fold.lights));
        for line in calibration_history_lines(&fold.report) {
            header.add_history(&line);
        }
        warns |= fold.report.has_warnings();
    }
    warns
}

/// The staleness term as one `HISTORY` line: both separations, both thresholds,
/// and the verdict. An unmeasurable term reads `unknown`, never `0`.
fn staleness_line(staleness: &CalibrationStaleness) -> String {
    let age = match staleness.age_days {
        Some(days) => format!("{days:+.2} d (max {:.1} d)", staleness.max_age_days),
        None => format!("unknown (max {:.1} d)", staleness.max_age_days),
    };
    let temperature = match (
        staleness.temperature_delta_c,
        staleness.max_temperature_delta_c,
    ) {
        (Some(delta), Some(limit)) => format!("{delta:+.2} C (max {limit:.1} C)"),
        (None, Some(limit)) => format!("unknown (max {limit:.1} C)"),
        _ => "not applicable".to_string(),
    };
    let verdict = if staleness.stale { "STALE" } else { "fresh" };
    format!("  staleness age={age} temperature={temperature} {verdict}")
}

/// The wire token for a [`MatchQuality`].
fn quality_wire(quality: MatchQuality) -> &'static str {
    match quality {
        MatchQuality::Exact => "exact",
        MatchQuality::Acceptable => "acceptable",
        MatchQuality::Unverified => "unverified",
        MatchQuality::Fallback => "fallback",
        MatchQuality::Missing => "missing",
        MatchQuality::NotRequired => "notRequired",
    }
}
