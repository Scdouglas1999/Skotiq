//! The one rule for calibrating a light frame, used by every path that
//! calibrates one: the Darkroom build and accumulating masters, one-shot
//! integration, drizzle, Stack & Share and live calibration of a captured
//! frame.
//!
//! As PixInsight's ImageCalibration: in 32-bit float, the bias leaves the
//! light, the dark's thermal signal leaves it scaled to the light's exposure,
//! and the light is divided by the flat normalized to unit mean, then
//! cosmetic correction when asked. Nothing is clipped: every sample carries
//! [`CALIBRATION_PEDESTAL`] so sky that noise pulls below the bias keeps its
//! value through a 16-bit copy. Which masters calibrate a light is chosen
//! before this (the Dart calibration selection); this rule applies them.

use crate::post_session::args::CalibrationArgs;
use crate::post_session::calibration_report::DARK_MAX_EXPOSURE_FRACTION;
use crate::post_session::master_cards::fits_header_of;
use crate::post_session::masters::flat_pedestal_state;
use skotiq_imaging::calibration::{calibrate_frame_f32, FlatPedestal, FloatCalibration};
use skotiq_imaging::calibration_masters::{cosmetic_correct_transient, CosmeticConfig};
use skotiq_imaging::{read_image, FitsHeader, ImageData};
use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;

/// Constant added to every calibrated sample, in ADU. A master built from
/// calibrated lights has it removed again; a single calibrated frame states
/// it in its `PEDESTAL` card.
pub const CALIBRATION_PEDESTAL: f32 = 100.0;

/// A master flat and whether its bias pedestal is already removed.
pub(crate) struct FlatMaster {
    pub(crate) image: ImageData,
    pub(crate) pedestal: FlatPedestal,
}

/// The masters and options that calibrate a set of lights, read once.
#[derive(Default, Clone)]
pub struct LightCalibration {
    dark: Option<Arc<ImageData>>,
    /// The dark's exposure in seconds, when its header says.
    dark_exposure: Option<f64>,
    pub(crate) flat: Option<Arc<FlatMaster>>,
    bias: Option<Arc<ImageData>>,
    /// A dark that cannot be scaled to the light's exposure is an error.
    scale_dark: bool,
    cosmetic_correction: bool,
}

/// A light calibrated in floating point, and the 16-bit copy star detection
/// and registration run on.
pub struct CalibratedLight {
    /// `F32`, every sample carrying [`CALIBRATION_PEDESTAL`].
    pub image: ImageData,
    /// The samples rounded into 16 bits, pedestal included.
    pub sixteen_bit: ImageData,
    /// The multiplier applied to the dark's thermal signal.
    pub dark_scale: f64,
}

impl LightCalibration {
    /// Read the masters at these paths; an absent or empty path skips that
    /// correction.
    pub fn load(
        dark: &Option<String>,
        flat: &Option<String>,
        bias: &Option<String>,
    ) -> Result<Self, String> {
        Self::for_lights(&CalibrationArgs {
            dark: dark.clone(),
            flat: flat.clone(),
            bias: bias.clone(),
            ..CalibrationArgs::default()
        })
    }

    /// The calibration a request names.
    pub(crate) fn for_lights(calibration: &CalibrationArgs) -> Result<Self, String> {
        MasterCache::default().calibration(calibration)
    }

    /// No correction at all: no master and no cosmetic correction.
    pub fn is_empty(&self) -> bool {
        self.dark.is_none()
            && self.flat.is_none()
            && self.bias.is_none()
            && !self.cosmetic_correction
    }

    pub(crate) fn has_bias(&self) -> bool {
        self.bias.is_some()
    }

    pub(crate) fn has_dark(&self) -> bool {
        self.dark.is_some()
    }

    pub(crate) fn has_flat(&self) -> bool {
        self.flat.is_some()
    }

    /// Calibrate `light`, `exposure` seconds long when known. A dark of
    /// another exposure is scaled to it, which needs a master bias to tell
    /// the dark's thermal signal from its pedestal.
    pub fn apply(
        &self,
        light: &ImageData,
        exposure: Option<f64>,
    ) -> Result<CalibratedLight, String> {
        let dark_scale = self.dark_scale(exposure)?;
        if self.scale_dark
            && self.dark.is_some()
            && (self.bias.is_none() || self.dark_exposure.is_none() || exposure.is_none())
        {
            return Err(
                "the dark is to be scaled, but scaling needs a master bias and the exposures of the dark and the light".to_string(),
            );
        }
        let cal = FloatCalibration {
            bias: self.bias.as_deref(),
            dark: self.dark.as_deref(),
            dark_scale,
            flat: self.flat.as_deref().map(|f| &f.image),
            flat_pedestal: self
                .flat
                .as_deref()
                .map_or(FlatPedestal::Removed, |f| f.pedestal),
            output_pedestal: CALIBRATION_PEDESTAL,
        };
        let mut image =
            calibrate_frame_f32(light, &cal).map_err(|e| format!("calibration failed: {e}"))?;
        if self.cosmetic_correction {
            cosmetic_correct_transient(&mut image, CosmeticConfig::default())
                .map_err(|e| format!("cosmetic correction failed: {e}"))?;
        }
        let sixteen_bit = sixteen_bit_copy(&image);
        Ok(CalibratedLight {
            image,
            sixteen_bit,
            dark_scale,
        })
    }

    /// The dark multiplier for a light of `light_exposure` seconds: the
    /// exposure ratio when the dark is of another exposure, otherwise 1.
    fn dark_scale(&self, light_exposure: Option<f64>) -> Result<f64, String> {
        let (Some(_), Some(dark_s), Some(light_s)) =
            (&self.dark, self.dark_exposure, light_exposure)
        else {
            return Ok(1.0);
        };
        if dark_s <= 0.0
            || light_s <= 0.0
            || (light_s / dark_s - 1.0).abs() <= DARK_MAX_EXPOSURE_FRACTION
        {
            return Ok(1.0);
        }
        if self.bias.is_none() {
            return Err(format!(
                "the dark is {dark_s} s and the light {light_s} s; a dark of another exposure can only be scaled with a master bias"
            ));
        }
        Ok(light_s / dark_s)
    }
}

/// A light's exposure: the one the caller states when positive, else the
/// light's `EXPTIME`.
pub(crate) fn light_exposure(stated: Option<f64>, header: &FitsHeader) -> Option<f64> {
    stated
        .filter(|s| *s > 0.0)
        .or_else(|| header.get_float("EXPTIME"))
}

/// The calibrated samples rounded into 16 bits.
fn sixteen_bit_copy(image: &ImageData) -> ImageData {
    let data: Vec<u16> = image
        .samples_f64()
        .iter()
        .map(|v| {
            if v.is_finite() {
                v.round().clamp(0.0, 65535.0) as u16
            } else {
                0
            }
        })
        .collect();
    ImageData::from_u16(image.width, image.height, image.channels, &data)
}

/// Calibration masters read once and shared by every group that names them.
#[derive(Default)]
pub(crate) struct MasterCache {
    images: HashMap<String, Arc<ImageData>>,
    flats: HashMap<String, Arc<FlatMaster>>,
}

fn present(path: &Option<String>) -> Option<&str> {
    path.as_deref().map(str::trim).filter(|p| !p.is_empty())
}

impl MasterCache {
    fn image(
        &mut self,
        path: &Option<String>,
        label: &str,
    ) -> Result<Option<Arc<ImageData>>, String> {
        let Some(path) = present(path) else {
            return Ok(None);
        };
        if let Some(image) = self.images.get(path) {
            return Ok(Some(Arc::clone(image)));
        }
        let image = Arc::new(
            read_image(Path::new(path))
                .map_err(|e| format!("failed to read {label} master '{path}': {e}"))?
                .image,
        );
        self.images.insert(path.to_string(), Arc::clone(&image));
        Ok(Some(image))
    }

    /// The master flat at `path` with what its header says about its
    /// pedestal, so a bias-corrected master is not bias-subtracted again.
    pub(crate) fn flat(
        &mut self,
        path: &Option<String>,
    ) -> Result<Option<Arc<FlatMaster>>, String> {
        let Some(key) = present(path) else {
            return Ok(None);
        };
        if let Some(flat) = self.flats.get(key) {
            return Ok(Some(Arc::clone(flat)));
        }
        let read = read_image(Path::new(key))
            .map_err(|e| format!("failed to read flat master '{key}': {e}"))?;
        let flat = Arc::new(FlatMaster {
            pedestal: flat_pedestal_state(&read.image, Some(&read.header)),
            image: read.image,
        });
        self.flats.insert(key.to_string(), Arc::clone(&flat));
        Ok(Some(flat))
    }

    pub(crate) fn calibration(
        &mut self,
        calibration: &CalibrationArgs,
    ) -> Result<LightCalibration, String> {
        Ok(LightCalibration {
            dark: self.image(&calibration.dark, "dark")?,
            dark_exposure: present(&calibration.dark)
                .and_then(fits_header_of)
                .and_then(|h| h.get_float("EXPTIME")),
            flat: self.flat(&calibration.flat)?,
            bias: self.image(&calibration.bias, "bias")?,
            scale_dark: calibration.scale_dark,
            cosmetic_correction: calibration.cosmetic_correction,
        })
    }
}
