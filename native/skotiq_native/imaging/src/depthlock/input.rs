//! From files to admissible evidence.
//!
//! Everything that stands between a saved FITS frame and an [`ApertureFrame`]
//! the estimator in the parent module may use: the reference frame's frozen
//! geometry, the registration→WCS composition, signed calibration against
//! Skotiq master frames, the source mask, the frame's stable identity,
//! and the acquisition-provenance checks. Each function refuses what it
//! cannot verify rather than inferring it; the reasons are written for the
//! operator, because the host surfaces them verbatim.
//!
//! Units: pixels are 0-based image coordinates; sky positions are ICRS
//! degrees; calibrated intensities are signed ADU per native pixel.

use super::ApertureFrame;
use crate::calibration::is_calibrated;
use crate::fits::FitsHeader;
use crate::registration::{RegistrationStats, TransformKind, TransformModel};
use crate::{
    detect_stars, Acquisition, AgreementPolicy, ExposureTolerance, FrameType, ImageData,
    MasterProvenance, NumberMatch, PixelType, Setting, SipWcs, StarDetectionConfig,
};
use serde::{Deserialize, Serialize};

/// U16 lights at or above this level are treated as saturated. Two-thirds of
/// the way to full well leaves room for cameras whose ADC clips early.
pub const SATURATION_ADU: f64 = 60_000.0;

/// Fewest input frames a master dark or flat must declare. A master built
/// from fewer carries enough of its own noise into every calibrated light
/// that the calibration error floor could not honestly be called small.
pub const MIN_MASTER_FRAMES: i64 = 8;

/// The reference frame's pixel geometry, frozen into the goal at creation so
/// later frames are anchored to the selection the user made, not to whatever
/// header a re-solved reference might carry later.
///
/// `crpix*` follow the FITS 1-based convention; the CD matrix is degrees per
/// pixel. The geometry is the linear part of the reference's TAN solution
/// ([`reference_wcs`] says why).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ReferenceGeometry {
    pub width: u32,
    pub height: u32,
    pub crval1: f64,
    pub crval2: f64,
    pub crpix1: f64,
    pub crpix2: f64,
    pub cd1_1: f64,
    pub cd1_2: f64,
    pub cd2_1: f64,
    pub cd2_2: f64,
}

impl ReferenceGeometry {
    /// Read the geometry from a reference frame's own header.
    pub fn from_header(header: &FitsHeader, width: u32, height: u32) -> Result<Self, String> {
        let wcs = reference_wcs(header)?;
        Self::from_wcs(&wcs, width, height)
    }

    /// Freeze an already-validated WCS (for example one the host resolved
    /// from its plate-solve records rather than the file header).
    pub fn from_wcs(wcs: &SipWcs, width: u32, height: u32) -> Result<Self, String> {
        let geometry = Self {
            width,
            height,
            crval1: wcs.crval1,
            crval2: wcs.crval2,
            crpix1: wcs.crpix1,
            crpix2: wcs.crpix2,
            cd1_1: wcs.cd1_1,
            cd1_2: wcs.cd1_2,
            cd2_1: wcs.cd2_1,
            cd2_2: wcs.cd2_2,
        };
        geometry.validate()?;
        Ok(geometry)
    }

    pub fn validate(&self) -> Result<(), String> {
        if self.width < 16 || self.height < 16 {
            return Err("Reference image is too small to anchor a sky region".into());
        }
        let wcs = self.wcs();
        if ![
            self.crval1,
            self.crval2,
            self.crpix1,
            self.crpix2,
            self.cd1_1,
            self.cd1_2,
            self.cd2_1,
            self.cd2_2,
        ]
        .iter()
        .all(|v| v.is_finite())
            || !wcs.is_invertible()
            || !(0.0..360.0).contains(&self.crval1)
            || self.crval2.abs() > 85.0
        {
            return Err(
                "Reference astrometry is singular or outside the supported sky field".into(),
            );
        }
        Ok(())
    }

    pub fn wcs(&self) -> SipWcs {
        SipWcs::tan_only(
            self.crval1,
            self.crval2,
            self.crpix1,
            self.crpix2,
            self.cd1_1,
            self.cd1_2,
            self.cd2_1,
            self.cd2_2,
        )
    }

    /// Native pixel scale in arcseconds per pixel (geometric mean of the axes).
    pub fn pixel_scale_arcsec(&self) -> f64 {
        (self.cd1_1 * self.cd2_2 - self.cd1_2 * self.cd2_1)
            .abs()
            .sqrt()
            * 3600.0
    }
}

fn numeric(header: &FitsHeader, key: &str) -> Result<f64, String> {
    header
        .get_float(key)
        .filter(|v| v.is_finite())
        .ok_or_else(|| format!("DepthLock requires a finite {key} FITS keyword"))
}

/// The linear part of the celestial TAN solution a reference header carries:
/// `CRVAL`, `CRPIX` and the CD matrix, with any SIP polynomials left out.
///
/// A goal's regions are drawn in the reference's pixels and stored as
/// tangent-plane rectangles through this map, and every later frame reaches
/// those pixels through its registration onto the reference, never through
/// its own solve. Under a linear map a rectangle drawn in pixels is a
/// rectangle on the tangent plane and back, so the apertures land on exactly
/// the pixels the operator drew; under the SIP polynomials it would be a
/// curved quadrilateral that no stored rectangle reproduces. Leaving them
/// out moves where on the sky the region is said to lie by the distortion at
/// its position (about a pixel at the corners of an ASTAP solve), not which
/// pixels are measured.
///
/// Other projections and unstated coordinate systems are refused: the
/// aperture geometry is that of a gnomonic projection in ICRS (or FK5 at
/// J2000, which is the same frame to far better than an aperture).
pub fn reference_wcs(header: &FitsHeader) -> Result<SipWcs, String> {
    let projection = |key: &str, tan: &str| {
        header
            .get_string(key)
            .is_some_and(|ctype| ctype == tan || ctype.strip_suffix("-SIP") == Some(tan))
    };
    if !projection("CTYPE1", "RA---TAN") || !projection("CTYPE2", "DEC--TAN") {
        return Err("DepthLock requires a celestial TAN reference".into());
    }
    let system = header
        .get_string("RADESYS")
        .or_else(|| header.get_string("RADECSYS"));
    if system != Some("ICRS")
        && !(system == Some("FK5") && header.get_float("EQUINOX") == Some(2000.0))
    {
        return Err("Reference must explicitly use ICRS or FK5/J2000 coordinates".into());
    }
    // Every card of the form the header uses must be present and finite;
    // nothing is defaulted.
    let required: &[&str] = if header.get_float("CD1_1").is_some() {
        &["CD1_1", "CD1_2", "CD2_1", "CD2_2"]
    } else {
        &["CDELT1", "CDELT2", "CROTA2"]
    };
    for key in required
        .iter()
        .chain(&["CRVAL1", "CRVAL2", "CRPIX1", "CRPIX2"])
    {
        numeric(header, key)?;
    }
    let wcs = SipWcs::from_header(header)
        .ok_or("Reference astrometry is singular or outside the supported sky field")?;
    if !wcs.is_invertible() || !(0.0..360.0).contains(&wcs.crval1) || wcs.crval2.abs() > 85.0 {
        return Err("Reference astrometry is singular or outside the supported sky field".into());
    }
    Ok(wcs.cd_only())
}

/// The WCS of a frame that was registered onto the reference.
///
/// `transform` maps frame pixels to reference pixels (0-based), as fitted by
/// [`crate::registration::solve_registration`]. Composing it with the
/// reference WCS gives the frame its own TAN solution: `CD_frame = CD_ref · A`
/// and the frame's reference pixel is the reference's `CRPIX` pulled back
/// through the inverse map. Only a similarity fit of near-unit scale with a
/// tight, well-supported residual is accepted; a looser fit would move every
/// aperture by more than the interpolation it feeds.
pub fn registered_wcs(
    reference: &SipWcs,
    transform: &TransformModel,
    quality: &RegistrationStats,
) -> Result<SipWcs, String> {
    if transform.kind != TransformKind::Similarity
        || transform.matrix[2] != [0.0, 0.0, 1.0]
        || !transform.matrix.iter().flatten().all(|v| v.is_finite())
        || (transform.scale() - 1.0).abs() > 0.01
        || quality.inlier_count < 8
        || !quality.inlier_fraction.is_finite()
        || !(0.8..=1.0).contains(&quality.inlier_fraction)
        || !quality.rms_residual_px.is_finite()
        || !(0.0..=0.5).contains(&quality.rms_residual_px)
    {
        return Err(format!(
            "Registration must be a similarity fit with matched scale, at least 8 inliers, \
             80% agreement and <= 0.5 px RMS (got scale {:.4}, {} inliers, {:.0}% agreement, \
             {:.2} px RMS)",
            transform.scale(),
            quality.inlier_count,
            quality.inlier_fraction * 100.0,
            quality.rms_residual_px
        ));
    }
    let inverse = transform
        .inverse()
        .ok_or("Registration transform is singular")?;
    let (x, y) = inverse.apply(reference.crpix1 - 1.0, reference.crpix2 - 1.0);
    let m = &transform.matrix;
    Ok(SipWcs::tan_only(
        reference.crval1,
        reference.crval2,
        x + 1.0,
        y + 1.0,
        reference.cd1_1 * m[0][0] + reference.cd1_2 * m[1][0],
        reference.cd1_1 * m[0][1] + reference.cd1_2 * m[1][1],
        reference.cd2_1 * m[0][0] + reference.cd2_2 * m[1][0],
        reference.cd2_1 * m[0][1] + reference.cd2_2 * m[1][1],
    ))
}

fn geometry_ok(image: &ImageData, bytes_per_pixel: usize) -> bool {
    image.channels == 1
        && image.width >= 16
        && image.height >= 16
        && (image.width as usize)
            .checked_mul(image.height as usize)
            .and_then(|n| n.checked_mul(bytes_per_pixel))
            == Some(image.data.len())
}

/// A camera-native monochrome light as f64 ADU.
pub fn light_pixels(image: &ImageData) -> Result<Vec<f64>, String> {
    if image.pixel_type != PixelType::U16 || !geometry_ok(image, 2) {
        return Err("DepthLock lights must be unprocessed monochrome 16-bit frames".into());
    }
    Ok(image
        .data
        .as_chunks::<2>()
        .0
        .iter()
        .map(|v| f64::from(u16::from_le_bytes(*v)))
        .collect())
}

/// A master frame as f64 ADU, in whichever of Skotiq's two master encodings
/// it was written.
pub fn master_pixels(image: &ImageData) -> Result<Vec<f64>, String> {
    match image.pixel_type {
        PixelType::U16 if geometry_ok(image, 2) => Ok(image.samples_f64()),
        PixelType::F32 if geometry_ok(image, 4) => Ok(image.samples_f64()),
        _ => Err("Master frames must be monochrome U16 or F32 with matching geometry".into()),
    }
}

/// `(light - dark) * median(flat) / flat` in signed f64 ADU per pixel.
///
/// The dark is an unscaled, matched-exposure master that still contains its
/// bias pedestal; the flat is a master flat normalized by its own median here
/// (Skotiq writes unit-mean flats, F32 at 1.0 or U16 at 32768, and either
/// works). Pixels the flat cannot correct — response outside 0.5–1.5× the
/// median — and saturated light pixels become NaN rather than a plausible
/// number, and NaN propagates to any aperture that touches them.
///
/// Negative results are kept: clipping at zero, which the display-oriented
/// calibrator does, would bias every blank region positive.
pub fn calibrate_signed(
    light: &ImageData,
    dark: &ImageData,
    flat: &ImageData,
) -> Result<Vec<f64>, String> {
    if [dark, flat]
        .iter()
        .any(|f| f.width != light.width || f.height != light.height)
    {
        return Err("Calibration masters must match the light's native geometry".into());
    }
    let light = light_pixels(light)?;
    let dark = master_pixels(dark)?;
    let flat = master_pixels(flat)?;
    if dark.iter().chain(&flat).any(|v| !v.is_finite()) {
        return Err("Calibration masters contain non-finite pixels".into());
    }
    let norm = crate::robust_stats::median_of(&flat);
    if !norm.is_finite() || norm <= 0.0 {
        return Err("Flat master has no positive response".into());
    }
    Ok(light
        .iter()
        .zip(&dark)
        .zip(&flat)
        .map(|((l, d), f)| {
            if *l >= SATURATION_ADU || *f < norm * 0.5 || *f > norm * 1.5 {
                f64::NAN
            } else {
                (l - d) * norm / f
            }
        })
        .collect())
}

/// Pixels the estimator must not sample.
///
/// Three layers, each grown into a disk: saturated pixels; every pixel more
/// than five robust sigma above the frame's median (star cores, hot pixels,
/// cosmic rays, trails, bright nebular cores); and the detector's stars at a
/// clamped radius so their wings do not leak into a "blank" aperture. The
/// radius is clamped because a detector FWHM is a measurement, not a truth
/// — an inflated one would blanket the frame. The mask is approximate by
/// construction and is one reason the calibration floor is carried without
/// a 1/sqrt(N) reduction; what it misses the estimator tolerates per cell
/// and per frame.
pub fn source_mask(light: &ImageData) -> Result<Vec<bool>, String> {
    let pixels = light_pixels(light)?;
    let width = light.width as usize;
    let height = light.height as usize;
    let (median, sigma) = robust_level_and_noise(&pixels);
    let bright = median + 5.0 * sigma;
    let mut mask = vec![false; pixels.len()];
    let mut mark_disk = |cx: f64, cy: f64, radius: f64| {
        let x0 = (cx - radius).floor().max(0.0) as usize;
        let y0 = (cy - radius).floor().max(0.0) as usize;
        let x1 = ((cx + radius).ceil().max(0.0) as usize).min(width - 1);
        let y1 = ((cy + radius).ceil().max(0.0) as usize).min(height - 1);
        for y in y0..=y1 {
            for x in x0..=x1 {
                if (x as f64 - cx).powi(2) + (y as f64 - cy).powi(2) <= radius * radius {
                    mask[y * width + x] = true;
                }
            }
        }
    };
    for (i, value) in pixels.iter().enumerate() {
        if *value >= SATURATION_ADU {
            mark_disk((i % width) as f64, (i / width) as f64, 12.0);
        } else if *value > bright {
            mark_disk((i % width) as f64, (i / width) as f64, 2.5);
        }
    }
    // The detector's tuned defaults (5σ, 9-pixel minimum area) find stars;
    // a looser threshold masks noise peaks as "stars" and, over a night,
    // eats the very apertures being measured. Sharp sources are masked.
    // Elongated ones are masked only when they are bright enough to be a
    // real trail; a marginal detection is left unmasked below.
    let config = StarDetectionConfig {
        max_sharpness: 1.0,
        max_eccentricity: 1.0,
        ..StarDetectionConfig::default()
    };
    for star in detect_stars(light, &config) {
        if ![star.x, star.y, star.fwhm].iter().all(|v| v.is_finite()) || star.fwhm < 0.0 {
            return Err("Star masking returned invalid source geometry".into());
        }
        // Elongated sources above the round-star selection ceiling are masked
        // when they are genuine trails (high SNR), not marginal 5σ noise
        // percolation clusters sitting on faint target nebulosity.
        if star.kind() == crate::SourceKind::NoiseCluster {
            continue;
        }
        mark_disk(star.x, star.y, (3.0 * star.fwhm).clamp(6.0, 25.0));
    }
    Ok(mask)
}

/// Median and MAD-derived sigma of a frame, from a stride sample of at most
/// ~250k pixels so a full-frame sort is never paid.
fn robust_level_and_noise(pixels: &[f64]) -> (f64, f64) {
    let stride = (pixels.len() / 250_000).max(1);
    let mut sample: Vec<f64> = pixels.iter().copied().step_by(stride).collect();
    crate::robust_stats::median_and_sigma_upper(&mut sample)
}

/// What identifies one exposure independently of where its file lives or how
/// often it is reprocessed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LightIdentity {
    /// `sk:<session>:<index>` for Skotiq-saved frames; otherwise a digest
    /// of the pixel bytes and the observation start.
    pub frame_id: String,
    /// `DATE-OBS` (exposure start) as Unix milliseconds, UTC.
    pub acquired_at_ms: i64,
}

/// FNV-1a over arbitrary bytes; stable across platforms and versions, which
/// is all an identity hash needs.
pub fn fnv1a64(bytes: impl IntoIterator<Item = u8>) -> u64 {
    bytes.into_iter().fold(0xcbf29ce484222325u64, |h, b| {
        (h ^ u64::from(b)).wrapping_mul(0x100000001b3)
    })
}

/// Parse a FITS `DATE-OBS` (`YYYY-MM-DDThh:mm:ss[.fff]`, UTC) to Unix ms.
pub fn date_obs_ms(value: &str) -> Result<i64, String> {
    let trimmed = value.trim().trim_end_matches('Z');
    let parsed = chrono::NaiveDateTime::parse_from_str(trimmed, "%Y-%m-%dT%H:%M:%S%.f")
        .or_else(|_| chrono::NaiveDateTime::parse_from_str(trimmed, "%Y-%m-%dT%H:%M:%S"))
        .map_err(|_| format!("DATE-OBS {value:?} is not an ISO 8601 UTC timestamp"))?;
    Ok(parsed.and_utc().timestamp_millis())
}

pub fn light_identity(header: &FitsHeader, light: &ImageData) -> Result<LightIdentity, String> {
    let date_obs = header
        .get_string("DATE-OBS")
        .ok_or("DepthLock requires DATE-OBS on every light")?;
    let acquired_at_ms = date_obs_ms(date_obs)?;
    // Frames saved before the rebrand carry NS-SESID/NS-FIDX; treat them the
    // same so a mixed-era light pool still collapses to one identity.
    let session = header
        .get_string("SK-SESID")
        .or_else(|| header.get_string("NS-SESID"));
    let index = header
        .get_int("SK-FIDX")
        .or_else(|| header.get_int("NS-FIDX"));
    let frame_id = match (session, index) {
        (Some(session), Some(index)) if !session.trim().is_empty() && index > 0 => {
            format!("sk:{}:{}", session.trim(), index)
        }
        _ => {
            let digest = fnv1a64(light.data.iter().copied().chain(date_obs.bytes()));
            format!("px:{digest:016x}")
        }
    };
    Ok(LightIdentity {
        frame_id,
        acquired_at_ms,
    })
}

/// The acquisition settings a light declares, read from its header.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AcquisitionSettings {
    /// `INSTRUME`.
    pub instrument: String,
    /// `FILTER`.
    pub filter: String,
    pub exposure_secs: f64,
    pub gain: Option<i32>,
    pub offset: Option<i32>,
    pub bin_x: i32,
    pub bin_y: i32,
    pub ccd_temp_c: Option<f64>,
}

/// Read and vet a light's header: an unprocessed monochrome `Light` with the
/// cards the compatibility checks need.
pub fn light_settings(header: &FitsHeader) -> Result<AcquisitionSettings, String> {
    let provenance = MasterProvenance::from_header(header);
    if !provenance
        .kind()
        .is_some_and(|kind| kind.base == FrameType::Light)
    {
        let image_type = header.get_string("IMAGETYP").unwrap_or("");
        return Err(format!(
            "Only light exposures may be measured; this file is IMAGETYP {image_type:?}"
        ));
    }
    if is_calibrated(header) || provenance.says_master() {
        return Err(
            "Only unprocessed lights may be measured; this file is already calibrated or stacked"
                .into(),
        );
    }
    if header.get_string("BAYERPAT").is_some() {
        return Err(
            "DepthLock measures monochrome data; this light carries a Bayer pattern".into(),
        );
    }
    let instrument = header
        .get_string("INSTRUME")
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .ok_or("Light has no camera identity (INSTRUME)")?
        .to_string();
    let filter = header
        .get_string("FILTER")
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .ok_or("Light has no filter identity (FILTER)")?
        .to_string();
    let exposure_secs = numeric(header, "EXPTIME")?;
    if exposure_secs <= 0.0 {
        return Err("Light has a non-positive EXPTIME".into());
    }
    let int_card = |key: &str| -> Result<Option<i32>, String> {
        match header.get_int(key) {
            None => Ok(None),
            Some(v) => i32::try_from(v)
                .map(Some)
                .map_err(|_| format!("{key} is out of range")),
        }
    };
    Ok(AcquisitionSettings {
        instrument,
        filter,
        exposure_secs,
        gain: int_card("GAIN")?,
        offset: int_card("OFFSET")?,
        bin_x: int_card("XBINNING")?.unwrap_or(1),
        bin_y: int_card("YBINNING")?.unwrap_or(1),
        ccd_temp_c: header.get_float("CCD-TEMP").filter(|v| v.is_finite()),
    })
}

/// How much a light may differ from the acquisition the goal was defined
/// for and still be pooled with the goal's other evidence.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CompatibilityPolicy {
    /// Accepted sensor temperature difference; `CCD-TEMP` is only compared
    /// when both sides carry it.
    pub temperature_tolerance_c: f64,
}

impl Default for CompatibilityPolicy {
    fn default() -> Self {
        Self {
            temperature_tolerance_c: 1.0,
        }
    }
}

impl AcquisitionSettings {
    fn acquisition(&self) -> Acquisition {
        Acquisition {
            instrument: Some(self.instrument.clone()),
            filter: Some(self.filter.clone()),
            exposure_s: Some(self.exposure_secs),
            gain: self.gain.map(f64::from),
            offset: self.offset.map(f64::from),
            bin_x: Some(f64::from(self.bin_x)),
            bin_y: Some(f64::from(self.bin_y)),
            sensor_temp_c: self.ccd_temp_c,
            ..Acquisition::default()
        }
    }
}

/// A number a [`Disagreement`](crate::Disagreement) states, to one decimal.
fn one_decimal(value: &str) -> String {
    value
        .parse::<f64>()
        .map_or_else(|_| value.to_string(), |v| format!("{v:.1}"))
}

/// A number a [`Disagreement`](crate::Disagreement) states, to three decimals.
fn three_decimals(value: &str) -> String {
    value
        .parse::<f64>()
        .map_or_else(|_| value.to_string(), |v| format!("{v:.3}"))
}

/// DepthLock's agreement rule: names in any case, exposure within 0.1 % of
/// the goal's (darks are not scaled), whole gain, offset and binning, and no
/// set-point or read-mode check.
const DEPTHLOCK_AGREEMENT: AgreementPolicy = AgreementPolicy {
    instrument: true,
    filter: true,
    exposure: Some(ExposureTolerance {
        absolute_s: 0.0,
        relative: 0.001,
    }),
    set_point_c: None,
    read_mode: false,
    numbers: NumberMatch::Whole,
    text_ignores_case: true,
    first_states_numbers: false,
    sensor_temp_c: None,
};

/// Refuse a light whose acquisition differs from the goal's. Gain and offset
/// are compared when the goal knows them; a goal defined without them is
/// pooling on the calibration library's word alone, and says so.
pub fn check_compatible(
    goal: &AcquisitionSettings,
    light: &AcquisitionSettings,
    policy: &CompatibilityPolicy,
) -> Result<(), String> {
    let agreement = AgreementPolicy {
        first_states_numbers: true,
        sensor_temp_c: Some(policy.temperature_tolerance_c),
        ..DEPTHLOCK_AGREEMENT
    };
    // Binning is named before gain and offset, the sensor temperature last.
    let rank = |setting: Setting| match setting {
        Setting::BinX | Setting::BinY => 0,
        Setting::Gain | Setting::Offset => 1,
        Setting::SensorTemp => 2,
        _ => -1,
    };
    let Some(first) = goal
        .acquisition()
        .disagreements(&light.acquisition(), &agreement)
        .into_iter()
        .min_by_key(|d| rank(d.setting))
    else {
        return Ok(());
    };
    let stated = |value: Option<i32>| value.map_or("unstated".to_string(), |v| v.to_string());
    Err(match first.setting {
        Setting::Instrument => format!(
            "Camera differs: goal was defined for {:?}, light is from {:?}",
            goal.instrument, light.instrument
        ),
        Setting::Filter => format!(
            "Filter differs: goal is for {:?}, light was taken through {:?}",
            goal.filter, light.filter
        ),
        Setting::Exposure => format!(
            "Exposure differs: goal and its master dark are for {:.3} s, light is {:.3} s \
             (DepthLock does not scale darks)",
            goal.exposure_secs, light.exposure_secs
        ),
        Setting::BinX | Setting::BinY => format!(
            "Binning differs: goal is {}x{}, light is {}x{}",
            goal.bin_x, goal.bin_y, light.bin_x, light.bin_y
        ),
        Setting::Gain => format!(
            "Gain differs: goal is {}, light is {}",
            stated(goal.gain),
            stated(light.gain)
        ),
        Setting::Offset => format!(
            "Offset differs: goal is {}, light is {}",
            stated(goal.offset),
            stated(light.offset)
        ),
        Setting::SensorTemp => format!(
            "Sensor temperature differs by more than {:.1} °C: goal {} °C, light {} °C",
            policy.temperature_tolerance_c,
            one_decimal(&first.first),
            one_decimal(&first.other)
        ),
        Setting::SetPoint | Setting::ReadMode => format!(
            "{} differs: goal is {}, light is {}",
            first.setting.card(),
            first.first,
            first.other
        ),
    })
}

/// Which master a file must declare itself to be.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MasterKind {
    Dark,
    Flat,
}

/// Vet a master frame's header and geometry against the light it will
/// calibrate. A master says so by `FRAMETYP = MASTER` or in `IMAGETYP` (the
/// dark library writes `IMAGETYP = 'Master Dark'`), names its kind in
/// `IMAGETYP`, and counts its frames in `NFRAMES`, else `NCOMBINE`. Acquisition cards a master carries must agree with the
/// frozen goal settings.
pub fn validate_master(
    kind: MasterKind,
    header: &FitsHeader,
    image: &ImageData,
    goal: &AcquisitionSettings,
    reference: &ReferenceGeometry,
) -> Result<(), String> {
    let label = match kind {
        MasterKind::Dark => "Master dark",
        MasterKind::Flat => "Master flat",
    };
    let (wanted, base) = match kind {
        MasterKind::Dark => ("dark", FrameType::Dark),
        MasterKind::Flat => ("flat", FrameType::Flat),
    };
    let provenance = MasterProvenance::from_header(header);
    if !provenance.says_master() {
        return Err(format!(
            "{label} is not a master frame (neither FRAMETYP nor IMAGETYP says MASTER)"
        ));
    }
    let image_type = header.get_string("IMAGETYP").unwrap_or("").trim();
    if !provenance.kind().is_some_and(|kind| kind.base == base) {
        return Err(format!(
            "{label} declares IMAGETYP {image_type:?}, not a {wanted}"
        ));
    }
    if header.get_string("BAYERPAT").is_some() {
        return Err(format!(
            "{label} carries a Bayer pattern; DepthLock is monochrome only"
        ));
    }
    let frames = provenance.frames.or(provenance.combined).unwrap_or(0);
    if frames < MIN_MASTER_FRAMES {
        return Err(format!(
            "{label} was built from {frames} frames; DepthLock needs at least {MIN_MASTER_FRAMES}"
        ));
    }
    if image.width != reference.width || image.height != reference.height {
        return Err(format!(
            "{label} is {}x{} but the goal's reference is {}x{}",
            image.width, image.height, reference.width, reference.height
        ));
    }
    master_pixels(image)?;
    let card_text = |key: &str| header.get_string(key).map(|v| v.trim().to_string());
    let card_number = |key: &str| header.get_int(key).map(|v| v as f64);
    let master = Acquisition {
        instrument: card_text("INSTRUME"),
        filter: card_text("FILTER"),
        exposure_s: header.get_float("EXPTIME"),
        gain: card_number("GAIN"),
        offset: card_number("OFFSET"),
        bin_x: card_number("XBINNING"),
        bin_y: card_number("YBINNING"),
        ..Acquisition::default()
    };
    // A master dark is held to the goal's exposure, a master flat to its filter.
    let agreement = AgreementPolicy {
        filter: kind == MasterKind::Flat,
        exposure: DEPTHLOCK_AGREEMENT
            .exposure
            .filter(|_| kind == MasterKind::Dark),
        ..DEPTHLOCK_AGREEMENT
    };
    let Some(first) = goal.acquisition().disagreement(&master, &agreement) else {
        return Ok(());
    };
    let raw = |key: &str| header.get_string(key).unwrap_or(first.other.as_str());
    Err(match first.setting {
        Setting::Instrument => format!(
            "{label} is from camera {:?}, goal is for {:?}",
            raw("INSTRUME"),
            goal.instrument
        ),
        Setting::Filter => format!(
            "{label} is for filter {:?}, goal is for {:?}",
            raw("FILTER"),
            goal.filter
        ),
        Setting::Exposure => format!(
            "{label} exposure {} s does not match the goal's {:.3} s",
            three_decimals(&first.other),
            goal.exposure_secs
        ),
        setting => format!(
            "{label} {} is {}, goal is {}",
            setting.card(),
            first.other,
            first.first
        ),
    })
}

/// One measured exposure, assembled from its vetted parts.
pub fn aperture_frame(
    identity: LightIdentity,
    source_path: &str,
    provenance_digest: &str,
    signal: super::ApertureSamples,
    background: super::ApertureSamples,
) -> ApertureFrame {
    ApertureFrame {
        frame_id: identity.frame_id,
        acquired_at_ms: identity.acquired_at_ms,
        source_path: source_path.to_string(),
        provenance_digest: provenance_digest.to_string(),
        signal,
        background,
    }
}

/// A calibration error floor derived from the master frames themselves.
///
/// The residual a master leaves in every calibrated light is its own pixel
/// noise: the master dark's noise is subtracted into each light unchanged,
/// and the master flat's relative noise multiplies the sky level. Neither
/// averages down with more lights, but both average over the aperture's
/// pixels when they are uncorrelated pixel to pixel — which is what the
/// noise estimate below measures (neighbour differences are blind to the
/// smooth pattern a master is supposed to carry, and robust to hot pixels).
/// Spatially correlated residuals — a dust shadow that moved, a gradient the
/// flat does not match — are not captured and are the reason the floor is a
/// minimum, not a ceiling.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct FloorSuggestion {
    /// Suggested `systematic_floor_adu`.
    pub floor_adu: f64,
    /// Master dark pixel noise, ADU.
    pub dark_noise_adu: f64,
    /// Master flat pixel noise relative to its level.
    pub flat_relative_noise: f64,
    /// Sky level of the reference light above the dark, ADU per pixel.
    pub sky_adu: f64,
    /// Aperture side in native pixels the floor was averaged over.
    pub aperture_pixels: f64,
    /// Operator-facing derivation, suitable for `systematic_floor_source`.
    pub source: String,
}

/// Robust per-pixel noise from horizontal neighbour differences:
/// `MAD(x[i+1] − x[i]) · 1.4826 / √2` over a stride sample.
fn neighbour_noise(pixels: &[f64], width: usize) -> f64 {
    let stride = (pixels.len() / 250_000).max(1);
    let mut diffs: Vec<f64> = pixels
        .chunks(width)
        .flat_map(|row| row.windows(2).map(|w| w[1] - w[0]))
        .step_by(stride)
        .filter(|d| d.is_finite())
        .collect();
    if diffs.is_empty() {
        return f64::NAN;
    }
    let (_, sigma) = crate::robust_stats::median_and_sigma_upper(&mut diffs);
    sigma / std::f64::consts::SQRT_2
}

pub fn suggest_floor(
    dark: &ImageData,
    flat: &ImageData,
    light: &ImageData,
    aperture_pixels: f64,
) -> Result<FloorSuggestion, String> {
    if !(1.0..=64.0).contains(&aperture_pixels) {
        return Err("Aperture must be 1 to 64 native pixels across".into());
    }
    if dark.width != light.width
        || dark.height != light.height
        || flat.width != light.width
        || flat.height != light.height
    {
        return Err("Calibration masters must match the light's native geometry".into());
    }
    let width = light.width as usize;
    let dark_pixels = master_pixels(dark)?;
    let flat_pixels = master_pixels(flat)?;
    let light_pixels = light_pixels(light)?;
    let dark_noise = neighbour_noise(&dark_pixels, width);
    let flat_level = crate::robust_stats::median_of(&flat_pixels);
    if !flat_level.is_finite() || flat_level <= 0.0 {
        return Err("Flat master has no positive response".into());
    }
    let flat_relative_noise = neighbour_noise(&flat_pixels, width) / flat_level;
    let (light_level, _) = robust_level_and_noise(&light_pixels);
    let dark_level = crate::robust_stats::median_of(&dark_pixels);
    let sky = (light_level - dark_level).max(0.0);
    if ![dark_noise, flat_relative_noise, sky]
        .iter()
        .all(|v| v.is_finite())
    {
        return Err("Could not estimate master-frame noise".into());
    }
    let per_pixel = dark_noise.hypot(flat_relative_noise * sky);
    let floor = (per_pixel / aperture_pixels).max(0.01);
    let source = format!(
        "Derived from the masters: dark pixel noise {dark_noise:.2} ADU and flat relative noise \
         {:.3}% at a sky level of {sky:.0} ADU, averaged over a {aperture_pixels:.1}-pixel \
         aperture ({per_pixel:.2} ADU per pixel). Spatially correlated residuals are not included.",
        flat_relative_noise * 100.0
    );
    Ok(FloorSuggestion {
        floor_adu: floor,
        dark_noise_adu: dark_noise,
        flat_relative_noise,
        sky_adu: sky,
        aperture_pixels,
        source,
    })
}

#[cfg(test)]
mod source_mask_tests {
    use super::*;

    #[test]
    fn source_mask_masks_stars_without_eating_faint_nebula_box() {
        let (w, h) = (512usize, 384usize);
        let mut s: u64 = 7;
        let mut nf = || {
            s = s
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            ((s >> 11) as f64) / ((1u64 << 53) as f64)
        };
        let mut stars = Vec::new();
        while stars.len() < 90 {
            let x = 20.0 + nf() * (w as f64 - 40.0);
            let y = 20.0 + nf() * (h as f64 - 40.0);
            if (150.0..=250.0).contains(&x) && (100.0..=200.0).contains(&y) {
                continue;
            }
            if (250.0..=350.0).contains(&x) && (100.0..=200.0).contains(&y) {
                continue;
            }
            stars.push((x, y, 3_000.0 + nf() * 22_000.0));
        }
        let mut masked_frames = 0usize;
        for index in [1usize, 15, 29, 36, 56, 68] {
            let mut ns = 1_000u64 + index as u64;
            let mut nu = || {
                ns = ns
                    .wrapping_mul(6364136223846793005)
                    .wrapping_add(1442695040888963407);
                ((ns >> 11) as f64) / ((1u64 << 53) as f64)
            };
            let dx = nu() * 12.0 - 6.0;
            let dy = nu() * 12.0 - 6.0;
            let mut px = vec![0.0f64; w * h];
            for y in 0..h {
                for x in 0..w {
                    let rx = x as f64 - dx;
                    let ry = y as f64 - dy;
                    let inside = (185.0..=215.0).contains(&rx) && (135.0..=165.0).contains(&ry);
                    px[y * w + x] = 300.0 + if inside { 12.0 } else { 0.0 };
                }
            }
            for &(sx, sy, peak) in &stars {
                let cx = sx + dx;
                let cy = sy + dy;
                for y in
                    ((cy - 5.0).floor().max(0.0) as usize)..=((cy + 5.0).ceil() as usize).min(h - 1)
                {
                    for x in ((cx - 5.0).floor().max(0.0) as usize)
                        ..=((cx + 5.0).ceil() as usize).min(w - 1)
                    {
                        let r2 = (x as f64 - cx).powi(2) + (y as f64 - cy).powi(2);
                        px[y * w + x] += peak * (-r2 / (2.0 * 1.3 * 1.3)).exp();
                    }
                }
            }
            let data: Vec<u16> = px
                .iter()
                .enumerate()
                .map(|(i, &sky)| {
                    let (x, y) = (i % w, i / w);
                    let vx = x as f64 - w as f64 / 2.0;
                    let vy = y as f64 - h as f64 / 2.0;
                    let vig = 1.0 - 0.03 * (vx * vx + vy * vy) / ((w * w + h * h) as f64 / 4.0);
                    let u = nu().max(1e-12);
                    let g = (-2.0 * u.ln()).sqrt() * (2.0 * std::f64::consts::PI * nu()).cos();
                    (sky * vig + 500.0 + 20.0 * g).round().clamp(0.0, 65535.0) as u16
                })
                .collect();
            let img = ImageData::from_u16(w as u32, h as u32, 1, &data);
            let mask = source_mask(&img).unwrap();
            // Real stars must still be masked.
            let (sx0, sy0, _) = stars[0];
            assert!(
                mask[(sy0 + dy).round() as usize * w + (sx0 + dx).round() as usize],
                "frame {index}: bright star must remain masked"
            );
            let mut masked_in_box = 0usize;
            for y in ((140.0 + dy).floor() as usize)..=((160.0 + dy).ceil() as usize) {
                for x in ((190.0 + dx).floor() as usize)..=((210.0 + dx).ceil() as usize) {
                    if mask[y * w + x] {
                        masked_in_box += 1;
                    }
                }
            }
            if masked_in_box > 0 {
                masked_frames += 1;
            }
        }
        assert_eq!(
            masked_frames, 0,
            "marginal elongated noise ripples must not mask the faint structure box"
        );
    }
}
