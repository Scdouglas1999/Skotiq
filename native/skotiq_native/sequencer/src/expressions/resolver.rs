//! Resolver — turns parsed [`TemplatePart`]s into a rendered string by
//! consulting an [`ExecutionContext`] and a per-call [`EvaluationFrame`].
//!
//! The resolver is the only piece that knows what `target.alt` actually
//! means; the parser does not interpret names, and the catalog only declares
//! that the name exists. Adding a new variable means:
//! 1. Add the [`VariableEntry`] to `catalog::variable_catalog()`.
//! 2. Add a match arm in [`resolve_variable`].
//! 3. The Dart picker auto-picks it up from the catalog JSON.

use super::catalog::variable_catalog;
use super::errors::InterpolationError;
use super::parser::{parse_template, TemplatePart};
use crate::node::context::ExecutionContext;
use chrono::{DateTime, Utc};

/// Synthetic filter label for rigs with no filter wheel.
///
/// Must match the label used by the non-template filename path in
/// `instructions.rs`. Deliberately NOT "L": a missing filter on a
/// narrowband/RGB capture must not be recorded as luminance.
pub(crate) const NO_FILTER_LABEL: &str = "nofilter";

/// Synthetic target label for a run with no TargetHeader in scope.
///
/// Must match the label used by the non-template filename path in
/// `instructions.rs`, which already substitutes `"untargeted"` (with a
/// `warn!`) rather than refusing to save the frame.
pub(crate) const NO_TARGET_LABEL: &str = "untargeted";

/// Per-call values that vary frame-to-frame inside a single
/// [`ExecutionContext`]. Built fresh for each call site (e.g. once per frame
/// in `expose.rs`).
///
/// `frame` and `frame_total` are `None` for call sites that aren't inside an
/// exposure (e.g. a notification at the end of a target group). The variable
/// resolver returns [`InterpolationError::Unresolvable`] when a template
/// references a frame field outside an exposure burst, surfacing the bug
/// instead of silently substituting `"0"`.
#[derive(Debug, Clone, Default)]
pub struct EvaluationFrame {
    /// 1-based frame index within the current burst.
    pub frame: Option<u32>,
    /// Total frames in the current burst.
    pub frame_total: Option<u32>,
    /// Exposure duration (seconds).
    pub exposure_duration_secs: Option<f64>,
    /// Exposure gain.
    pub exposure_gain: Option<i32>,
    /// Exposure offset.
    pub exposure_offset: Option<i32>,
    /// Binning string ("1x1", "2x2", ...).
    pub exposure_binning: Option<String>,
    /// 1-based filter wheel position.
    pub filter_position: Option<i32>,
    /// Session start (used by `session.start`/`session.date` so the value is
    /// stable across calls within one run).
    pub session_start: Option<DateTime<Utc>>,
    /// Now-clock override (tests inject a deterministic timestamp;
    /// production leaves this `None` so `time.now` reads the wall clock).
    pub now_override: Option<DateTime<Utc>>,
    /// Moon illumination fraction (0.0 – 1.0).
    pub moon_phase: Option<f64>,
    /// Ambient temperature (°C).
    pub weather_temp_c: Option<f64>,
    /// Relative humidity (%).
    pub weather_humidity: Option<f64>,
    /// Sky-quality measurement (mag/arcsec²).
    pub sqm: Option<f64>,
}

impl EvaluationFrame {
    pub fn empty() -> Self {
        Self::default()
    }
}

/// One resolved variable value. Carries enough type information that the
/// format-spec evaluator can apply the right rules.
#[derive(Debug, Clone)]
pub enum VariableValue {
    Str(String),
    Int(i64),
    Float(f64),
}

impl VariableValue {
    /// Human-readable type tag for error reporting. `#[allow(dead_code)]`
    /// because the field is consumed only by `IncompatibleFormatSpec`
    /// arms via the manual string we already pass — keeping the helper
    /// available makes adding new error sites trivial.
    #[allow(dead_code)]
    fn type_name(&self) -> &'static str {
        match self {
            VariableValue::Str(_) => "string",
            VariableValue::Int(_) => "integer",
            VariableValue::Float(_) => "float",
        }
    }
}

/// Interpolate a template that may contain `${...}` placeholders. Returns
/// the rendered string.
pub fn interpolate(
    template: &str,
    ctx: &ExecutionContext,
    frame: &EvaluationFrame,
) -> Result<String, InterpolationError> {
    let parts = parse_template(template)?;
    let mut out = String::with_capacity(template.len());
    for part in parts {
        match part {
            TemplatePart::Literal(s) => out.push_str(&s),
            TemplatePart::Variable {
                name,
                format_spec,
                offset,
            } => {
                let value = resolve_variable(&name, offset, ctx, frame)?;
                let rendered = apply_format_spec(&name, offset, &value, format_spec.as_deref())?;
                out.push_str(&rendered);
            }
        }
    }
    Ok(out)
}

/// Convenience for `Option<String>` templates that are common in
/// `ExposureConfig.save_to` / `NotificationConfig.title`. `None` and empty
/// templates short-circuit to `Ok(None)`.
pub fn interpolate_optional(
    template: Option<&str>,
    ctx: &ExecutionContext,
    frame: &EvaluationFrame,
) -> Result<Option<String>, InterpolationError> {
    match template {
        None => Ok(None),
        Some("") => Ok(None),
        Some(s) => Ok(Some(interpolate(s, ctx, frame)?)),
    }
}

/// Resolve a single dotted variable name to a [`VariableValue`].
///
/// Errors on unknown names ([`InterpolationError::UnknownVariable`]) and on
/// known names whose runtime data is missing ([`InterpolationError::Unresolvable`]).
pub fn resolve_variable(
    name: &str,
    offset: usize,
    ctx: &ExecutionContext,
    frame: &EvaluationFrame,
) -> Result<VariableValue, InterpolationError> {
    // Verify against the catalog FIRST so a typo like `${target.naem}` is
    // reported as UnknownVariable rather than ever-so-helpfully resolving to
    // empty. We rely on a small linear scan — the catalog is < 50 entries.
    if !variable_catalog().iter().any(|e| e.name == name) {
        return Err(InterpolationError::UnknownVariable {
            name: name.to_string(),
            offset,
        });
    }
    match name {
        // Target
        // `${target.name}` is in the DEFAULT save-path template
        // (`${target.name}_${filter}_${frame:04}.fits`), so making it
        // unresolvable aborted frame 1 of any run with no TargetHeader in
        // scope — the same shape of failure the `${filter}` arm below already
        // fixed for OSC/DSLR rigs.
        //
        // `expose.rs::calibration_target_label` covers the calibration case by
        // stamping `Dark`/`Bias`/`Flat`/`DarkFlat` onto the context before the
        // render, and deliberately does NOT cover on-sky frames — inventing a
        // sky target for science data would be worse than not naming the file.
        // That reasoning is right, but it leaves the LIGHT case landing here,
        // and what happens here is not "the file goes unnamed": the exposure
        // has already been taken and the whole run is failed, so real photons
        // are discarded. Observed verbatim on the live rig running a five-node
        // sequence (change filter -> 2x2s light -> delay -> change filter ->
        // 1x4s dark) against a real ZWO ASI1600MM:
        //   "Save-path template render failed for frame 1/2: Variable
        //    `${target.name}` cannot be resolved: no active target. Aborting
        //    exposure ..."
        // -> zero frames written, run terminal state `failed`.
        //
        // `untargeted` is not an invented target — it is the explicit
        // statement that there wasn't one, and it is exactly what the
        // non-template filename path in `instructions.rs` already writes (with
        // a `warn!`) for this case. Resolving to it keeps the data, keeps the
        // frame auditable in a directory listing, and makes the two filename
        // paths agree. `target.id` / `target.ra` / `target.dec` stay
        // unresolvable below: those are load-bearing join keys and
        // coordinates, not display labels, and none appear in the default
        // template.
        "target.name" => Ok(VariableValue::Str(
            match ctx.target_name.as_deref().filter(|n| !n.is_empty()) {
                Some(name) => name.to_string(),
                None => {
                    tracing::warn!(
                        "[TEMPLATE] `${{target.name}}` has no active target — using the synthetic \
                         label \"{}\". The sequence was started without a TargetHeader/TargetGroup; \
                         review the configuration.",
                        NO_TARGET_LABEL
                    );
                    NO_TARGET_LABEL.to_string()
                }
            },
        )),
        "target.id" => str_or_unresolvable(
            name,
            ctx.target_id.as_deref(),
            "no active target (id is set by TargetHeader)",
        ),
        "target.ra" => float_or_unresolvable(name, ctx.target_ra, "no active target RA"),
        "target.dec" => float_or_unresolvable(name, ctx.target_dec, "no active target Dec"),
        "target.rotation" => {
            float_or_unresolvable(name, ctx.target_rotation, "target has no rotation set")
        }
        "target.alt" => float_or_unresolvable(
            name,
            ctx.calculate_altitude(),
            "altitude requires target RA/Dec and observer location",
        ),
        "target.az" => float_or_unresolvable(
            name,
            calculate_azimuth(ctx),
            "azimuth requires target RA/Dec and observer location",
        ),
        // Filter
        // A rig with no filter wheel (OSC / DSLR) has no filter, and that is
        // NORMAL — not an error. `${filter}` appears in the DEFAULT save-path
        // template (`${target.name}_${filter}_${frame:04}.fits`), so making it
        // unresolvable aborted the very first frame of any sequence on such a
        // rig: "Save-path template render failed … Variable `${filter}` cannot
        // be resolved: no filter set. Aborting exposure". Reproduced by running
        // a plain TakeExposure node with no filter against the simulator camera.
        //
        // The sibling filename path in `instructions.rs` already handles this
        // by substituting the synthetic label `nofilter`, with a comment
        // explaining it must NOT be "L" (that would mis-label narrowband/RGB
        // frames as luminance). Resolve to the same label here so the two
        // filename paths agree instead of one aborting the capture.
        "filter" => Ok(VariableValue::Str(
            ctx.current_filter
                .as_deref()
                .filter(|f| !f.is_empty())
                .unwrap_or(NO_FILTER_LABEL)
                .to_string(),
        )),
        "filter.position" => int_or_unresolvable(
            name,
            frame
                .filter_position
                .map(i64::from)
                .or_else(|| ctx.current_filter_index.map(i64::from)),
            "filter position is unknown (no recent filter change)",
        ),
        // Frame counters
        "frame" => int_or_unresolvable(
            name,
            frame.frame.map(i64::from),
            "frame number is only set inside an exposure burst",
        ),
        "frame.total" => int_or_unresolvable(
            name,
            frame.frame_total.map(i64::from),
            "frame total is only set inside an exposure burst",
        ),
        // Session
        "session.id" => Ok(VariableValue::Str(ctx.session_id.clone())),
        "session.date" => {
            let dt = frame.session_start.unwrap_or_else(now_utc);
            Ok(VariableValue::Str(dt.format("%Y-%m-%d").to_string()))
        }
        "session.start" => {
            let dt = frame.session_start.unwrap_or_else(now_utc);
            Ok(VariableValue::Str(
                dt.format("%Y-%m-%dT%H:%M:%SZ").to_string(),
            ))
        }
        // Time
        "time.now" => Ok(VariableValue::Str(
            frame
                .now_override
                .unwrap_or_else(now_utc)
                .format("%Y-%m-%dT%H:%M:%SZ")
                .to_string(),
        )),
        "time.local" => Ok(VariableValue::Str(
            // chrono::Local applies the system local offset.
            frame
                .now_override
                .map(|u| u.with_timezone(&chrono::Local))
                .unwrap_or_else(chrono::Local::now)
                .format("%Y-%m-%d %H:%M:%S %:z")
                .to_string(),
        )),
        "time.date" => Ok(VariableValue::Str(
            frame
                .now_override
                .unwrap_or_else(now_utc)
                .format("%Y-%m-%d")
                .to_string(),
        )),
        // Moon
        "moon.phase" => float_or_unresolvable(
            name,
            frame
                .moon_phase
                .or_else(|| Some(moon_illumination_fraction(now_utc()))),
            "moon phase requires a system clock",
        ),
        "moon.separation" => float_or_unresolvable(
            name,
            ctx.calculate_moon_separation(),
            "moon separation requires target RA/Dec",
        ),
        // Weather
        "weather.temp_c" => float_or_unresolvable(
            name,
            frame.weather_temp_c,
            "no weather temperature available (configure a weather provider)",
        ),
        "weather.humidity" => float_or_unresolvable(
            name,
            frame.weather_humidity,
            "no humidity reading available (configure a weather provider)",
        ),
        "sqm" => float_or_unresolvable(
            name,
            frame.sqm,
            "no SQM reading available (configure a sky-brightness provider)",
        ),
        // Observer
        "observer.name" => str_or_unresolvable(
            name,
            ctx.observer_name.as_deref(),
            "observer name is not set in app settings",
        ),
        "observer.lat" => float_or_unresolvable(name, ctx.latitude, "observer latitude is unset"),
        "observer.lon" => float_or_unresolvable(name, ctx.longitude, "observer longitude is unset"),
        "observer.elevation" => {
            float_or_unresolvable(name, ctx.site_elevation_m, "observer elevation is unset")
        }
        // Equipment
        "equipment.camera" => {
            let camera = match (ctx.camera_make.as_deref(), ctx.camera_model.as_deref()) {
                (Some(make), Some(model)) => Some(format!("{make} {model}")),
                (None, Some(model)) => Some(model.to_string()),
                (Some(make), None) => Some(make.to_string()),
                (None, None) => None,
            };
            str_or_unresolvable(
                name,
                camera.as_deref(),
                "no camera identification in profile",
            )
        }
        "equipment.telescope" => str_or_unresolvable(
            name,
            ctx.telescope_name.as_deref(),
            "telescope name is unset in equipment profile",
        ),
        "equipment.focal_length" => float_or_unresolvable(
            name,
            ctx.telescope_focal_length_mm,
            "telescope focal length is unset in equipment profile",
        ),
        "equipment.aperture" => float_or_unresolvable(
            name,
            ctx.telescope_aperture_mm,
            "telescope aperture is unset in equipment profile",
        ),
        // Exposure
        "exposure.duration" => float_or_unresolvable(
            name,
            frame.exposure_duration_secs,
            "exposure duration is only set inside an exposure burst",
        ),
        "exposure.gain" => int_or_unresolvable(
            name,
            frame.exposure_gain.map(i64::from),
            "exposure gain is only set inside an exposure burst",
        ),
        "exposure.offset" => int_or_unresolvable(
            name,
            frame.exposure_offset.map(i64::from),
            "exposure offset is only set inside an exposure burst",
        ),
        "exposure.binning" => str_or_unresolvable(
            name,
            frame.exposure_binning.as_deref(),
            "exposure binning is only set inside an exposure burst",
        ),
        "exposure.temp_c" => float_or_unresolvable(
            name,
            ctx.set_temp_c,
            "cooler set-point is unset (no CoolCamera in this run)",
        ),
        "exposure.total" => {
            let (Some(dur), Some(count)) = (frame.exposure_duration_secs, frame.frame_total) else {
                return Err(InterpolationError::Unresolvable {
                    name: name.to_string(),
                    reason: "exposure.total needs duration and frame count from the active burst"
                        .to_string(),
                });
            };
            Ok(VariableValue::Float(dur * f64::from(count) / 60.0))
        }
        // Unreachable: the catalog gate above rejects unknown names. Any
        // entry registered in the catalog but not in this match is a bug.
        other => {
            tracing::error!(
                "Variable `{other}` is in the catalog but has no resolver — this is a bug; \
                 update expressions/resolver.rs."
            );
            Err(InterpolationError::Unresolvable {
                name: other.to_string(),
                reason: "no resolver registered (engine bug)".to_string(),
            })
        }
    }
}

fn str_or_unresolvable(
    name: &str,
    value: Option<&str>,
    reason: &str,
) -> Result<VariableValue, InterpolationError> {
    match value {
        Some(v) if !v.is_empty() => Ok(VariableValue::Str(v.to_string())),
        _ => Err(InterpolationError::Unresolvable {
            name: name.to_string(),
            reason: reason.to_string(),
        }),
    }
}

fn float_or_unresolvable(
    name: &str,
    value: Option<f64>,
    reason: &str,
) -> Result<VariableValue, InterpolationError> {
    match value {
        Some(v) if v.is_finite() => Ok(VariableValue::Float(v)),
        Some(_) => Err(InterpolationError::Unresolvable {
            name: name.to_string(),
            reason: "value is not finite".to_string(),
        }),
        None => Err(InterpolationError::Unresolvable {
            name: name.to_string(),
            reason: reason.to_string(),
        }),
    }
}

fn int_or_unresolvable(
    name: &str,
    value: Option<i64>,
    reason: &str,
) -> Result<VariableValue, InterpolationError> {
    match value {
        Some(v) => Ok(VariableValue::Int(v)),
        None => Err(InterpolationError::Unresolvable {
            name: name.to_string(),
            reason: reason.to_string(),
        }),
    }
}

fn now_utc() -> DateTime<Utc> {
    chrono::Utc::now()
}

/// Apply a Python-style format spec to a resolved value.
///
/// Supported specs:
/// * Bare (no spec) → default formatting (`Display`).
/// * `0N` (e.g. `04`) → integer zero-pad to width N.
/// * `.Nf` (e.g. `.1f`) → fixed-point with N decimal places.
fn apply_format_spec(
    name: &str,
    offset: usize,
    value: &VariableValue,
    spec: Option<&str>,
) -> Result<String, InterpolationError> {
    let Some(spec) = spec else {
        return Ok(default_render(value));
    };
    if spec.is_empty() {
        return Ok(default_render(value));
    }

    // Integer zero-pad: "04", "06", ...
    if let Some(width_str) = spec.strip_prefix('0') {
        // The remainder must be all ASCII digits, e.g. `0` (width 0),
        // `04`, `06`. Reject malformed specs like `0x4`.
        if width_str.chars().all(|c| c.is_ascii_digit()) {
            let width: usize =
                format!("0{width_str}")
                    .parse()
                    .map_err(|e: std::num::ParseIntError| {
                        InterpolationError::InvalidFormatSpec {
                            name: name.to_string(),
                            spec: spec.to_string(),
                            offset,
                            reason: e.to_string(),
                        }
                    })?;
            return zero_pad(name, offset, value, spec, width);
        }
    }

    // fixed-point: ".1f", ".0f", ".2f", ...
    if let Some(rest) = spec.strip_prefix('.') {
        if let Some(digits) = rest.strip_suffix('f') {
            if digits.chars().all(|c| c.is_ascii_digit()) && !digits.is_empty() {
                let precision: usize = digits.parse().map_err(|e: std::num::ParseIntError| {
                    InterpolationError::InvalidFormatSpec {
                        name: name.to_string(),
                        spec: spec.to_string(),
                        offset,
                        reason: e.to_string(),
                    }
                })?;
                return fixed_point(name, offset, value, spec, precision);
            }
        }
    }

    Err(InterpolationError::InvalidFormatSpec {
        name: name.to_string(),
        spec: spec.to_string(),
        offset,
        reason: "unsupported spec; use `0N` for integer zero-pad or `.Nf` for fixed-point"
            .to_string(),
    })
}

fn default_render(value: &VariableValue) -> String {
    match value {
        VariableValue::Str(s) => s.clone(),
        VariableValue::Int(i) => i.to_string(),
        // Float default render: trim trailing zeroes so 3.0 renders as "3"
        // and 3.14 as "3.14". Matches the behaviour the existing
        // `format!("{}", f)` calls produce, with the exception that
        // integers render without a trailing ".0".
        VariableValue::Float(f) => {
            if f.fract() == 0.0 && f.abs() < 1.0e16 {
                format!("{}", *f as i64)
            } else {
                format!("{f}")
            }
        }
    }
}

fn zero_pad(
    name: &str,
    _offset: usize,
    value: &VariableValue,
    spec: &str,
    width: usize,
) -> Result<String, InterpolationError> {
    match value {
        VariableValue::Int(i) => {
            if *i < 0 {
                Ok(format!("{i:0>width$}", width = width))
            } else {
                Ok(format!("{i:0width$}", width = width))
            }
        }
        VariableValue::Float(f) => {
            // Allow zero-padding a float only if it's integer-valued. A
            // template `${target.alt:04}` against a value of `42.7` is
            // ambiguous and almost certainly a user bug.
            if f.fract() == 0.0 && f.abs() < 1.0e16 {
                let i = *f as i64;
                Ok(format!("{i:0width$}", width = width))
            } else {
                Err(InterpolationError::IncompatibleFormatSpec {
                    name: name.to_string(),
                    spec: spec.to_string(),
                    value_type: "float",
                    reason: format!(
                        "zero-pad spec applied to non-integer float ({f}); use `.Nf` instead"
                    ),
                })
            }
        }
        VariableValue::Str(_) => Err(InterpolationError::IncompatibleFormatSpec {
            name: name.to_string(),
            spec: spec.to_string(),
            value_type: "string",
            reason: "zero-pad spec applied to a string value".to_string(),
        }),
    }
}

fn fixed_point(
    name: &str,
    _offset: usize,
    value: &VariableValue,
    spec: &str,
    precision: usize,
) -> Result<String, InterpolationError> {
    match value {
        VariableValue::Float(f) => Ok(format!("{f:.precision$}", precision = precision)),
        VariableValue::Int(i) => {
            // Promote integers to float for fixed-point — a template like
            // `${exposure.gain:.1f}` is unusual but well-defined.
            let f = *i as f64;
            Ok(format!("{f:.precision$}", precision = precision))
        }
        VariableValue::Str(_) => Err(InterpolationError::IncompatibleFormatSpec {
            name: name.to_string(),
            spec: spec.to_string(),
            value_type: "string",
            reason: "fixed-point spec applied to string value".to_string(),
        }),
    }
}

/// Compute the moon illumination fraction (0.0 = new, 1.0 = full) using a
/// low-precision phase angle formula. Accuracy is ~ 1% — adequate for
/// template substitution, where the user wants a rough sense of phase, not
/// an ephemeris.
fn moon_illumination_fraction(now: DateTime<Utc>) -> f64 {
    let jd = crate::meridian::julian_day(&now);
    // Mean phase angle period: 29.530588853 days (synodic month). The
    // reference new-moon epoch is JD 2451550.1 (2000-01-06 UTC). Wrapping
    // the cosine of half the phase angle yields the illuminated fraction.
    let days = jd - 2_451_550.1;
    let phase = (days / 29.530_588_853).rem_euclid(1.0); // 0..1 fraction of synodic month
    let angle = phase * std::f64::consts::TAU; // 0..2π radians
                                               // illumination = (1 - cos(angle)) / 2 produces 0 at new, 1 at full,
                                               // 0 again at the next new moon.
    ((1.0 - angle.cos()) / 2.0).clamp(0.0, 1.0)
}

/// Calculate current azimuth (degrees, 0 = North, increasing eastward) of
/// the active target. Mirrors `ExecutionContext::calculate_altitude` so the
/// catalog can offer both fields without depending on the planetarium code.
fn calculate_azimuth(ctx: &ExecutionContext) -> Option<f64> {
    let ra_hours = ctx.target_ra?;
    let dec_degrees = ctx.target_dec?;
    let lat = ctx.latitude?;
    let lon = ctx.longitude?;

    let now = chrono::Utc::now();
    let jd = crate::meridian::julian_day(&now);
    let lst = crate::meridian::local_sidereal_time(jd, lon);

    let ha = lst - ra_hours;
    let ha_rad = (ha * 15.0).to_radians();
    let dec_rad = dec_degrees.to_radians();
    let lat_rad = lat.to_radians();

    // Standard horizontal-coords formula: tan(Az) = -cos(dec) sin(HA) /
    // (sin(dec) cos(lat) - cos(dec) sin(lat) cos(HA))
    let sin_az = -dec_rad.cos() * ha_rad.sin();
    let cos_az = dec_rad.sin() * lat_rad.cos() - dec_rad.cos() * lat_rad.sin() * ha_rad.cos();
    let az = sin_az.atan2(cos_az).to_degrees();
    Some(az.rem_euclid(360.0))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::node::context::ExecutionContext;

    fn ctx_with_target() -> ExecutionContext {
        let mut ctx = ExecutionContext::new_for_test("root".to_string());
        ctx.target_name = Some("M42".to_string());
        ctx.target_id = Some("tgt-42".to_string());
        ctx.target_ra = Some(5.59);
        ctx.target_dec = Some(-5.39);
        ctx.target_rotation = Some(45.0);
        ctx.current_filter = Some("Ha".to_string());
        ctx.current_filter_index = Some(3);
        ctx.latitude = Some(40.7);
        ctx.longitude = Some(-74.0);
        ctx.observer_name = Some("Alice".to_string());
        ctx.site_elevation_m = Some(150.0);
        ctx.camera_make = Some("ZWO".to_string());
        ctx.camera_model = Some("ASI2600MM".to_string());
        ctx.telescope_name = Some("TS APO".to_string());
        ctx.telescope_focal_length_mm = Some(910.0);
        ctx.telescope_aperture_mm = Some(130.0);
        ctx.set_temp_c = Some(-10.0);
        ctx
    }

    fn frame_with_burst() -> EvaluationFrame {
        EvaluationFrame {
            frame: Some(8),
            frame_total: Some(30),
            exposure_duration_secs: Some(180.0),
            exposure_gain: Some(100),
            exposure_offset: Some(10),
            exposure_binning: Some("1x1".to_string()),
            filter_position: Some(3),
            session_start: Some(
                chrono::Utc
                    .with_ymd_and_hms(2026, 1, 15, 22, 14, 33)
                    .single()
                    .unwrap(),
            ),
            now_override: Some(
                chrono::Utc
                    .with_ymd_and_hms(2026, 1, 15, 22, 47, 12)
                    .single()
                    .unwrap(),
            ),
            moon_phase: Some(0.42),
            weather_temp_c: Some(12.4),
            weather_humidity: Some(67.0),
            sqm: Some(21.2),
        }
    }
    use chrono::TimeZone;

    #[test]
    fn resolves_target_name() {
        let ctx = ctx_with_target();
        let frame = frame_with_burst();
        let out = interpolate("${target.name}", &ctx, &frame).expect("must resolve");
        assert_eq!(out, "M42");
    }

    #[test]
    fn frame_format_spec_zero_pads() {
        let ctx = ctx_with_target();
        let frame = frame_with_burst();
        let out = interpolate("${frame:04}", &ctx, &frame).expect("must resolve");
        assert_eq!(out, "0008");
    }

    #[test]
    fn fixed_point_for_float() {
        let ctx = ctx_with_target();
        let frame = frame_with_burst();
        // target.alt is computed from ctx — exact value depends on system
        // clock, so we check it parses and has 1 decimal place.
        let out = interpolate("${target.alt:.1f}", &ctx, &frame).expect("must resolve");
        let dot = out.find('.').expect("expected a decimal point");
        // exactly one digit after the dot
        assert_eq!(out.len() - dot - 1, 1, "got {out}");
    }

    #[test]
    fn session_date_renders_from_start() {
        let ctx = ctx_with_target();
        let frame = frame_with_burst();
        let out = interpolate("${session.date}", &ctx, &frame).expect("must resolve");
        assert_eq!(out, "2026-01-15");
    }

    #[test]
    fn time_now_uses_override() {
        let ctx = ctx_with_target();
        let frame = frame_with_burst();
        let out = interpolate("${time.now}", &ctx, &frame).expect("must resolve");
        assert_eq!(out, "2026-01-15T22:47:12Z");
    }

    #[test]
    fn exposure_total_is_minutes() {
        let ctx = ctx_with_target();
        let frame = frame_with_burst();
        // 30 frames × 180 s = 5400 s = 90 min.
        let out = interpolate("${exposure.total:.1f}", &ctx, &frame).expect("must resolve");
        assert_eq!(out, "90.0");
    }

    #[test]
    fn hierarchical_save_path_renders() {
        let ctx = ctx_with_target();
        let frame = frame_with_burst();
        let out = interpolate(
            "${session.date}/${target.name}/${filter}/sub_${frame:04}.fits",
            &ctx,
            &frame,
        )
        .expect("must resolve");
        assert_eq!(out, "2026-01-15/M42/Ha/sub_0008.fits");
    }

    #[test]
    fn unknown_variable_errors() {
        let ctx = ctx_with_target();
        let frame = frame_with_burst();
        let err = interpolate("${target.naem}", &ctx, &frame).expect_err("typo must error");
        match err {
            InterpolationError::UnknownVariable { name, .. } => assert_eq!(name, "target.naem"),
            other => panic!("expected UnknownVariable, got {other:?}"),
        }
    }

    /// `${target.name}` renders the synthetic `untargeted` label rather than
    /// erroring: an untargeted run (every calibration sequence) must still be
    /// able to save its frames. `${target.id}` below keeps the strict
    /// behaviour — it is a join key, not a display label.
    #[test]
    fn missing_target_name_renders_untargeted_label() {
        let mut ctx = ctx_with_target();
        ctx.target_name = None;
        let frame = frame_with_burst();
        let rendered = interpolate("${target.name}", &ctx, &frame).expect("must render");
        assert_eq!(rendered, "untargeted");
    }

    #[test]
    fn missing_target_id_errors() {
        let mut ctx = ctx_with_target();
        ctx.target_id = None;
        let frame = frame_with_burst();
        let err = interpolate("${target.id}", &ctx, &frame).expect_err("must error");
        match err {
            InterpolationError::Unresolvable { name, .. } => assert_eq!(name, "target.id"),
            other => panic!("expected Unresolvable, got {other:?}"),
        }
    }

    #[test]
    fn frame_outside_burst_errors() {
        let ctx = ctx_with_target();
        let frame = EvaluationFrame::empty();
        let err = interpolate("${frame}", &ctx, &frame).expect_err("must error");
        assert!(matches!(err, InterpolationError::Unresolvable { .. }));
    }

    #[test]
    fn doubled_dollar_yields_literal() {
        let ctx = ctx_with_target();
        let frame = frame_with_burst();
        let out = interpolate("price is $${100}", &ctx, &frame).expect("must resolve");
        assert_eq!(out, "price is ${100}");
    }

    #[test]
    fn invalid_format_spec_errors() {
        let ctx = ctx_with_target();
        let frame = frame_with_burst();
        let err = interpolate("${frame:xyz}", &ctx, &frame).expect_err("bad spec must error");
        match err {
            InterpolationError::InvalidFormatSpec { name, spec, .. } => {
                assert_eq!(name, "frame");
                assert_eq!(spec, "xyz");
            }
            other => panic!("expected InvalidFormatSpec, got {other:?}"),
        }
    }

    #[test]
    fn zero_pad_on_string_errors() {
        let ctx = ctx_with_target();
        let frame = frame_with_burst();
        let err = interpolate("${target.name:04}", &ctx, &frame).expect_err("must error");
        assert!(matches!(
            err,
            InterpolationError::IncompatibleFormatSpec { .. }
        ));
    }

    #[test]
    fn float_default_renders_integer_when_no_fraction() {
        // gain=100 (int) renders as "100", not "100.0".
        let ctx = ctx_with_target();
        let frame = frame_with_burst();
        let out = interpolate("${exposure.gain}", &ctx, &frame).expect("must resolve");
        assert_eq!(out, "100");
    }

    #[test]
    fn observer_lat_renders_default_with_decimals() {
        let ctx = ctx_with_target();
        let frame = frame_with_burst();
        let out = interpolate("${observer.lat}", &ctx, &frame).expect("must resolve");
        assert_eq!(out, "40.7");
    }

    #[test]
    fn catalog_and_resolver_agree_for_every_entry() {
        // Every catalog entry must either resolve or report Unresolvable
        // (never UnknownVariable) when we throw an empty context+frame at
        // it. This catches the "added entry to catalog but forgot the
        // resolver arm" bug.
        let ctx = ExecutionContext::new_for_test("root".to_string());
        let frame = EvaluationFrame::empty();
        for entry in variable_catalog() {
            let err = resolve_variable(entry.name, 0, &ctx, &frame).err();
            if let Some(InterpolationError::UnknownVariable { .. }) = err {
                panic!(
                    "Catalog declares `{}` but resolver does not handle it",
                    entry.name
                );
            }
        }
    }

    #[test]
    fn round_trip_template_remains_unchanged() {
        // Saving a template should NOT pre-render. The parser is the only
        // thing that touches the string before resolve-time. This test
        // pins the contract: parse → render-from-parts → re-parse yields
        // the same parts.
        let original = "${session.date}/${target.name}/${filter}/sub_${frame:04}.fits";
        let parts = parse_template(original).expect("parse");
        // Re-build the source from the parts and ensure it round-trips.
        let mut rebuilt = String::new();
        for part in &parts {
            match part {
                TemplatePart::Literal(s) => rebuilt.push_str(s),
                TemplatePart::Variable {
                    name, format_spec, ..
                } => {
                    rebuilt.push_str("${");
                    rebuilt.push_str(name);
                    if let Some(spec) = format_spec {
                        rebuilt.push(':');
                        rebuilt.push_str(spec);
                    }
                    rebuilt.push('}');
                }
            }
        }
        assert_eq!(rebuilt, original);
    }
}
/// A rig with no filter wheel must still render the default save-path
/// template: an Unresolvable `${filter}` aborts frame 1 of every sequence on
/// an OSC/DSLR rig ("Save-path template render failed … no filter set"). The
/// label matches the non-template filename path in `instructions.rs` and is
/// deliberately NOT "L".
#[test]
fn filter_falls_back_to_nofilter_label_when_unset() {
    let mut ctx = ExecutionContext::new_for_test("root".to_string());
    ctx.target_name = Some("M31".to_string());
    ctx.current_filter = None;
    let frame = EvaluationFrame {
        frame: Some(1),
        frame_total: Some(3),
        ..EvaluationFrame::default()
    };

    let rendered = interpolate("${target.name}_${filter}_${frame:04}.fits", &ctx, &frame)
        .expect("default template must render without a filter wheel");
    assert_eq!(rendered, "M31_nofilter_0001.fits");
    assert!(!rendered.contains("_L_"), "must not mis-label as luminance");
}

#[test]
fn filter_uses_the_real_name_when_set() {
    let mut ctx = ExecutionContext::new_for_test("root".to_string());
    ctx.target_name = Some("M31".to_string());
    ctx.current_filter = Some("Ha".to_string());
    let frame = EvaluationFrame {
        frame: Some(2),
        frame_total: Some(3),
        ..EvaluationFrame::default()
    };
    let rendered = interpolate("${target.name}_${filter}_${frame:04}.fits", &ctx, &frame).unwrap();
    assert_eq!(rendered, "M31_Ha_0002.fits");
}

/// A calibration / untargeted run must still render the default save-path
/// template: an Unresolvable `${target.name}` aborts frame 1 of every sequence
/// with no TargetHeader ("Save-path template render failed … no active
/// target"). The label matches the non-template filename path in
/// `instructions.rs`.
#[test]
fn target_name_falls_back_to_untargeted_label_when_unset() {
    let mut ctx = ExecutionContext::new_for_test("root".to_string());
    ctx.target_name = None;
    ctx.current_filter = Some("Ha".to_string());
    let frame = EvaluationFrame {
        frame: Some(1),
        frame_total: Some(2),
        ..EvaluationFrame::default()
    };

    let rendered = interpolate("${target.name}_${filter}_${frame:04}.fits", &ctx, &frame)
        .expect("default template must render for an untargeted (calibration) run");
    assert_eq!(rendered, "untargeted_Ha_0001.fits");
}

/// The real target name must still win when a TargetHeader is in scope.
#[test]
fn target_name_uses_the_real_name_when_set() {
    let mut ctx = ExecutionContext::new_for_test("root".to_string());
    ctx.target_name = Some("M31".to_string());
    ctx.current_filter = None;
    let frame = EvaluationFrame {
        frame: Some(7),
        frame_total: Some(9),
        ..EvaluationFrame::default()
    };
    let rendered = interpolate("${target.name}_${filter}_${frame:04}.fits", &ctx, &frame).unwrap();
    assert_eq!(rendered, "M31_nofilter_0007.fits");
}
