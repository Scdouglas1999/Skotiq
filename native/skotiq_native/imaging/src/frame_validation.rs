//! Checks of a captured frame before it is kept: dimensions, signal level,
//! saturation against the sensor's ceiling, and the header cards a frame
//! needs.

use crate::{FitsHeader, ImageData, PixelType};

#[derive(Debug, Clone)]
pub struct ImageValidation {
    pub is_valid: bool,
    pub warnings: Vec<String>,
    pub errors: Vec<String>,
    /// Set when the frame's brightest pixel is under the signal floor: the
    /// frame is kept, and whoever took it tells the user.
    pub below_signal_floor: Option<BelowSignalFloor>,
}

/// A frame with almost no signal: its brightest pixel and the floor it is
/// under, in ADU.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BelowSignalFloor {
    pub max_value: u16,
    pub floor: u16,
}

impl ImageValidation {
    pub fn valid() -> Self {
        Self {
            is_valid: true,
            warnings: Vec::new(),
            errors: Vec::new(),
            below_signal_floor: None,
        }
    }

    pub fn add_warning(&mut self, warning: String) {
        self.warnings.push(warning);
    }

    pub fn add_error(&mut self, error: String) {
        self.errors.push(error);
        self.is_valid = false;
    }
}

/// Validate image data, checking the dimensions against `expected_width` /
/// `expected_height` when they are given.
pub fn validate_image(
    image: &ImageData,
    expected_width: Option<u32>,
    expected_height: Option<u32>,
) -> ImageValidation {
    let mut validation = ImageValidation::valid();

    if let Some(width) = expected_width {
        if image.width != width {
            validation.add_error(format!(
                "Width mismatch: expected {}, got {}",
                width, image.width
            ));
        }
    }

    if let Some(height) = expected_height {
        if image.height != height {
            validation.add_error(format!(
                "Height mismatch: expected {}, got {}",
                height, image.height
            ));
        }
    }

    if image.width == 0 || image.height == 0 {
        validation.add_error("Image has zero dimensions".to_string());
        return validation;
    }

    let pixel_size = match image.pixel_type {
        PixelType::U8 => 1,
        PixelType::U16 => 2,
        PixelType::U32 => 4,
        PixelType::F32 => 4,
        PixelType::F64 => 8,
    };
    let expected_size = (image.width * image.height * image.channels) as usize * pixel_size;
    if image.data.len() != expected_size {
        validation.add_error(format!(
            "Data size mismatch: expected {} bytes, got {}",
            expected_size,
            image.data.len()
        ));
    }

    // For 16-bit images, check for all-zero or all-saturated frames
    if image.pixel_type == PixelType::U16 {
        let pixels: Vec<u16> = image
            .data
            .as_chunks::<2>()
            .0
            .iter()
            .map(|chunk| u16::from_le_bytes([chunk[0], chunk[1]]))
            .collect();

        if !pixels.is_empty() {
            let all_zero = pixels.iter().all(|&p| p == 0);
            // Why: max() of an empty pixel iterator → 0; an empty pixel
            // vec is impossible (we are inside the `pixels.len() > 0`-guarded branch and
            // the prior `all_zero` iterator has already inspected it).
            // Zero is the inert placeholder for the unreachable empty case.
            let max_value = pixels.iter().copied().max().unwrap_or(0);

            // This entry point has no sensor to ask, so the ceiling comes from
            // the frame's own clipping evidence or from the 16-bit default; see
            // DEFAULT_SATURATION_THRESHOLD for why the default is not 65535.
            let count_at_max = pixels.iter().filter(|&&p| p == max_value).count();
            let saturation_threshold =
                infer_full_scale_from_frame(max_value, count_at_max, pixels.len())
                    .and_then(|full_scale| {
                        saturation_threshold_for_full_scale(u32::from(full_scale))
                    })
                    .unwrap_or(DEFAULT_SATURATION_THRESHOLD);
            let all_saturated = pixels.iter().all(|&p| p >= saturation_threshold);

            if all_zero {
                validation.add_error("Image is all-zero (no data captured)".to_string());
            } else if all_saturated {
                // WARNING, not an error, and the distinction decides whether a
                // night survives.
                //
                // A validation error fails the whole exposure
                // (`unified_device_ops.rs`: `if !validation.is_valid { return
                // Err(..) }`). All-zero deserves that — there is no data. An
                // all-saturated frame is real data that is merely clipped, and
                // the condition is recoverable by lowering the exposure.
                //
                // Making it fatal actively breaks the flat wizard, which
                // converges by capturing a deliberately bright flat, measuring
                // it, and reducing the exposure. It captures through this same
                // path, so a hard failure removes the very measurement the
                // correction loop needs.
                validation.add_warning(
                    "Image is all-saturated (overexposed, or a stuck sensor) - \
                     lower the exposure, gain, or light level"
                        .to_string(),
                );
            }

            if max_value < 100 {
                validation.add_warning(format!(
                    "Very low signal detected (max value: {})",
                    max_value
                ));
            }
        }
    }

    validation
}

/// Saturation threshold used when the sensor's full scale is genuinely unknown.
///
/// 65024 = 65535 - (65535 >> 7): a 16-bit container with the usual 1/128 of
/// headroom (see [`SATURATION_HEADROOM_SHIFT`]). It is the right guess for the
/// left-justified 12-/14-bit sensors that dominate astro imaging (they top out
/// at 65520 / 65532) but it is only a guess — prefer
/// [`ImageValidationOptions::sensor_max_adu`] whenever the driver has told us
/// the real ceiling.
pub const DEFAULT_SATURATION_THRESHOLD: u16 = 65024;

/// Headroom below full scale at which a pixel is already called saturated,
/// as a right-shift: threshold = `full_scale - (full_scale >> 7)`, i.e. one
/// part in 128 (~0.8%).
///
/// Real sensors clip slightly BELOW their theoretical ceiling — a live
/// ASI1600MM-Cool clips at 65504, one ADU under the 65520 its left-justified
/// 12-bit samples can reach — so a threshold pinned to the exact ceiling misses
/// the clip, and a missed clip gets misreported as "sensor failure or dead
/// frame". 1/128 reproduces the historical 16-bit constant exactly
/// (65535 - 511 = [`DEFAULT_SATURATION_THRESHOLD`]) while scaling to sensors
/// whose pixel container is not 16-bit wide.
const SATURATION_HEADROOM_SHIFT: u32 = 7;

/// Smallest full scale we will believe from a driver. A camera reporting a
/// sub-8-bit ceiling is broken or uninitialised, and honouring it would drag
/// the saturation threshold down under the sky background — labelling every
/// ordinary frame of the night "completely saturated". Below this we keep the
/// default. 255 itself is trusted: it is the SVBony RAW8 container.
const MIN_TRUSTED_FULL_SCALE: u32 = 255;

/// Container full scales recognisable from the pixel data alone, for drivers
/// that right-justify sub-16-bit samples (INDI CCDs and several ASCOM drivers
/// deliver a 12-bit sensor as values 0..4095 rather than left-shifting them).
///
/// 255 is here because it is a container an actual driver ships: the SVBony
/// `connect()` path falls back to `SVB_IMG_RAW8` when a model offers no RAW16
/// and then publishes `max_adu: 255` (`native/src/vendor/svbony.rs`,
/// `container_max_adu`). Ascending order matters — [`infer_full_scale_from_frame`]
/// takes the first band the peak falls in.
///
/// 16-bit needs no entry: its ceiling is the default.
const RIGHT_JUSTIFIED_FULL_SCALES: [u16; 4] = [255, 1023, 4095, 16383];

/// Saturation threshold for a sensor whose pixel container tops out at
/// `full_scale` ADU.
///
/// `full_scale` is `CameraStatus::max_adu` / `SensorInfo::max_adu` — the
/// container full scale, NOT `2^bit_depth - 1`. The two differ for every
/// left-justified sub-16-bit sensor (a 12-bit ASI1600 has `bit_depth: 12` but
/// `max_adu: 65520`), and conflating them has already shipped as a defect once;
/// `skotiq_device::SensorInfo` spells out the contract.
///
/// `None` means "not usable as a ceiling, keep
/// [`DEFAULT_SATURATION_THRESHOLD`]".
pub fn saturation_threshold_for_full_scale(full_scale: u32) -> Option<u16> {
    if full_scale < MIN_TRUSTED_FULL_SCALE {
        return None;
    }
    // Samples arrive in a u16 container; a driver advertising a wider full
    // scale (ASCOM MaxADU is an i32) still cannot deliver a sample above
    // u16::MAX through this path.
    let ceiling = full_scale.min(u32::from(u16::MAX)) as u16;
    Some(ceiling - (ceiling >> SATURATION_HEADROOM_SHIFT))
}

/// The severe-underexposure floor ([`ImageValidationOptions::min_max_value`])
/// restated in the scale of a container that tops out at `full_scale`.
///
/// The floor is a FRACTION of full scale wearing absolute-ADU clothes: 100 of a
/// 16-bit container is 0.15%, i.e. "essentially nothing came off the sensor".
/// On a narrower container the same number means something else entirely — on
/// the SVBony RAW8 fallback (`max_adu: 255`, samples handed over as 0..255;
/// `native/src/vendor/svbony.rs`) 100 ADU is 39% of everything the sensor can
/// produce, so an ordinary dim sub would read as "severely underexposed".
///
/// The floor therefore scales with the container, exactly as the saturation
/// ceiling does at the other end of the range.
fn signal_floor_for_full_scale(floor_at_full_16bit: u16, full_scale: u32) -> u16 {
    let ceiling = u64::from(full_scale.min(u32::from(u16::MAX)));
    // At least 1 ADU: on an 8-bit container 0.15% is a fraction of a code, and
    // the only emptier frame that container can express is all-zero, which is
    // already its own error.
    ((u64::from(floor_at_full_16bit) * ceiling) / u64::from(u16::MAX)).max(1) as u16
}

/// Recover the container full scale from the frame itself, for the callers that
/// cannot tell us (`sensor_max_adu: None`).
///
/// A right-justified 12-bit frame clips at 4095, nowhere near the 65024 default,
/// so without this a fully clipped frame reads back as "possible sensor failure
/// or dead frame" — an alarming misdiagnosis of a plain over-exposure.
///
/// The peak is matched against a band, not against the exact full scale.
/// Demanding equality contradicts the fact that motivates
/// [`SATURATION_HEADROOM_SHIFT`] in the first place: real sensors clip a few ADU
/// BELOW their container ceiling, so a right-justified ASI1600 that pins at 4090
/// is every bit as clipped as one that pins at 4095 and must be recognised as a
/// 4095-container clip rather than ignored. The band is that same 1/128 of
/// headroom, and the four bands (254..=255, 1016..=1023, 4064..=4095,
/// 16256..=16383) do not overlap, so at most one candidate ever matches.
///
/// A matching peak alone is not enough: enough pixels must pile up on it to be a
/// clip rather than a coincidence, or a well-exposed 16-bit frame whose
/// brightest star happens to read 4090 would have its highlights redefined as
/// saturated.
fn infer_full_scale_from_frame(
    max_value: u16,
    count_at_max: usize,
    total_pixels: usize,
) -> Option<u16> {
    let full_scale = *RIGHT_JUSTIFIED_FULL_SCALES.iter().find(|&&candidate| {
        max_value <= candidate
            && saturation_threshold_for_full_scale(u32::from(candidate))
                .is_some_and(|clip_floor| max_value >= clip_floor)
    })?;
    // 1 pixel in 2048 (~0.05%), floored at 16 so small guide/thumbnail frames
    // still need a real pile-up. Normal star fields clip a few hundredths of a
    // percent of the sensor at most; a ruined frame clips orders of magnitude
    // more.
    let min_pile_up = (total_pixels / 2048).max(16);
    (count_at_max >= min_pile_up).then_some(full_scale)
}

#[derive(Debug, Clone)]
pub struct ImageValidationOptions {
    /// Expected image width (None to skip check)
    pub expected_width: Option<u32>,
    /// Expected image height (None to skip check)
    pub expected_height: Option<u32>,
    /// Whether this is a bias frame (allows uniform pixel values)
    pub is_bias_frame: bool,
    /// Max pixel value under which a frame is called severely underexposed,
    /// stated against a full 16-bit container (default: 100, i.e. 0.15% of
    /// full scale) and rescaled to the container the frame arrived in (see
    /// [`signal_floor_for_full_scale`]). A warning: the frame is kept.
    pub min_max_value: u16,
    /// Saturation threshold: pixels at/above this are considered saturated.
    /// Default 65024 = 4064 << 4, i.e. 99.2% of the 12-bit ADC ceiling scaled
    /// into 16-bit. Most astro CMOS sensors are 12- or 14-bit and their drivers
    /// left-shift the samples into the 16-bit pixel range, so their theoretical
    /// saturation is 65520 (12-bit) or 65528/65532 (14-bit), NOT 65535 — a
    /// 65535/65530 threshold never fires for the majority of cameras.
    /// Real sensors also clip slightly BELOW the theoretical ceiling: a live
    /// ASI1600MM-Cool (12-bit) saturates at 65504 (4094 << 4), one ADU short of
    /// 65520, which a threshold pinned to the exact ceiling would miss — and a
    /// missed saturation gets misreported as "sensor failure or dead frame".
    /// 65024 leaves that headroom while still meaning "clipped and unusable".
    ///
    /// Only used when the ceiling is unknown — `sensor_max_adu` wins.
    pub saturation_threshold: u16,
    /// The sensor's pixel-container full scale (`CameraStatus::max_adu`) when
    /// the caller knows it, which is the only trustworthy source: a driver that
    /// right-justifies a 12-bit sensor clips at 4095, and no fixed 16-bit
    /// constant can see that. `None` = unknown, fall back to
    /// `saturation_threshold` (with the frame's own evidence as a last resort).
    pub sensor_max_adu: Option<u32>,
    /// Maximum acceptable saturation percentage (default: 0.90 = 90%)
    pub max_saturation_percent: f64,
    /// Saturation percentage above which the frame is called heavily clipped
    /// (default: 0.05 = 5%).
    ///
    /// A normal deep-sky sub clips only star cores — hundredths of a percent.
    /// Once 5% of the sensor sits at the ceiling the exposure or gain is wrong
    /// (or the moon/twilight is washing the field) and the highlights of that
    /// sub are gone — a tier `max_saturation_percent` alone never reports.
    pub warn_saturation_percent: f64,
}

impl Default for ImageValidationOptions {
    fn default() -> Self {
        Self {
            expected_width: None,
            expected_height: None,
            is_bias_frame: false,
            min_max_value: 100,
            saturation_threshold: DEFAULT_SATURATION_THRESHOLD,
            sensor_max_adu: None,
            max_saturation_percent: 0.90,
            warn_saturation_percent: 0.05,
        }
    }
}

impl ImageValidationOptions {
    /// Options for a frame off a sensor whose container full scale is known.
    pub fn for_sensor(max_adu: u32) -> Self {
        Self {
            sensor_max_adu: Some(max_adu),
            ..Self::default()
        }
    }
}

/// Validate image data, checking the dimensions against `expected_width` /
/// `expected_height` when they are given. `is_bias_frame` allows uniform pixel
/// values, which a bias frame naturally has.
#[cfg(test)]
fn validate_image_with_options(
    image: &ImageData,
    expected_width: Option<u32>,
    expected_height: Option<u32>,
    is_bias_frame: bool,
) -> ImageValidation {
    validate_image_comprehensive(
        image,
        ImageValidationOptions {
            expected_width,
            expected_height,
            is_bias_frame,
            ..Default::default()
        },
    )
}

/// Comprehensive image validation with full options
///
/// Performs the following validation checks:
/// 1. Validates image data size matches dimensions (width * height)
/// 2. Rejects images where ALL pixels are identical (unless it's a bias frame)
/// 3. Warns on underexposed images (max pixel value < min_max_value, and
///    under five times it)
/// 4. Warns on saturation, judged against the sensor's own ADU ceiling
///    (`sensor_max_adu`) rather than a fixed 16-bit constant
/// 5. Logs validation results for debugging
///
/// # Arguments
/// * `image` - The image data to validate
/// * `options` - Validation options
///
/// # Returns
/// Validation result with errors and warnings
pub fn validate_image_comprehensive(
    image: &ImageData,
    options: ImageValidationOptions,
) -> ImageValidation {
    let mut validation = ImageValidation::valid();

    if let Some(width) = options.expected_width {
        if image.width != width {
            validation.add_error(format!(
                "Width mismatch: expected {}, got {}",
                width, image.width
            ));
        }
    }

    if let Some(height) = options.expected_height {
        if image.height != height {
            validation.add_error(format!(
                "Height mismatch: expected {}, got {}",
                height, image.height
            ));
        }
    }

    if image.width == 0 || image.height == 0 {
        validation.add_error("Image has zero dimensions".to_string());
        tracing::error!("[IMAGE_VALIDATION] REJECTED: Image has zero dimensions");
        return validation;
    }

    let pixel_size = match image.pixel_type {
        PixelType::U8 => 1,
        PixelType::U16 => 2,
        PixelType::U32 => 4,
        PixelType::F32 => 4,
        PixelType::F64 => 8,
    };
    let expected_size = (image.width * image.height * image.channels) as usize * pixel_size;
    if image.data.len() != expected_size {
        validation.add_error(format!(
            "Data size mismatch: expected {} bytes for {}x{}x{} image, got {} bytes (truncated or corrupted)",
            expected_size,
            image.width, image.height, image.channels,
            image.data.len()
        ));
        tracing::error!(
            "[IMAGE_VALIDATION] REJECTED: Data size mismatch - expected {} bytes, got {}",
            expected_size,
            image.data.len()
        );
    }

    if image.pixel_type == PixelType::U16 && !image.data.is_empty() {
        let pixels: Vec<u16> = image
            .data
            .as_chunks::<2>()
            .0
            .iter()
            .map(|chunk| u16::from_le_bytes([chunk[0], chunk[1]]))
            .collect();

        if !pixels.is_empty() {
            let total_pixels = pixels.len();

            // Calculate statistics in a single pass for efficiency. The
            // saturation count cannot ride along: on a sensor that delivers
            // right-justified sub-16-bit samples the ceiling IS this pass's
            // peak, so what counts as saturated is not known until it finishes.
            let (min_value, max_value, sum, count_at_max) = pixels.iter().fold(
                (u16::MAX, u16::MIN, 0u64, 0usize),
                |(min, max, sum, count_at_max), &pixel| {
                    let (max, count_at_max) = match pixel.cmp(&max) {
                        std::cmp::Ordering::Greater => (pixel, 1),
                        std::cmp::Ordering::Equal => (max, count_at_max + 1),
                        std::cmp::Ordering::Less => (max, count_at_max),
                    };
                    (min.min(pixel), max, sum + pixel as u64, count_at_max)
                },
            );
            let mean_value = if total_pixels > 0 {
                sum / total_pixels as u64
            } else {
                0
            };

            // Two independent estimates of the pixel container's full scale:
            // what the driver declared, and where the frame itself clips.
            //
            // A declared ceiling the frame itself EXCEEDS is a driver reporting
            // ADC bits where container full scale belongs (the documented
            // bit_depth/max_adu confusion) — believing it would call an ordinary
            // frame completely saturated, so distrust it entirely.
            let declared_full_scale = options
                .sensor_max_adu
                .filter(|declared| u32::from(max_value) <= *declared);
            let observed_full_scale =
                infer_full_scale_from_frame(max_value, count_at_max, total_pixels).map(u32::from);

            // Take the LOWER of the two, because the two ways of being wrong are
            // not symmetric. A driver that cannot name its reachable ceiling
            // answers with the container width instead — INDI falls back to
            // `(1 << CCD_BITSPERPIXEL) - 1`, i.e. 65535, for a sensor whose
            // right-justified samples clip at 4095 — and believing that puts the
            // threshold above anything the frame can ever reach, so every
            // clipped flat passes in silence. A pile-up parked on a recognised
            // container ceiling is positive evidence of where the ADC actually
            // clips, so it wins whenever it is the lower of the two.
            //
            // One believed ceiling, used by every verdict below. Both ends of
            // the range are proportions of it: what counts as clipped, and what
            // counts as nothing at all.
            let believed_full_scale = declared_full_scale
                .into_iter()
                .chain(observed_full_scale)
                .min()
                .filter(|&full_scale| full_scale >= MIN_TRUSTED_FULL_SCALE);
            let saturation_threshold = believed_full_scale
                .and_then(saturation_threshold_for_full_scale)
                .unwrap_or(options.saturation_threshold);
            let saturated_count = pixels
                .iter()
                .filter(|&&pixel| pixel >= saturation_threshold)
                .count();
            let saturation_percent = saturated_count as f64 / total_pixels as f64;

            // Log statistics for debugging. The threshold is included because a
            // saturation verdict is meaningless without the ceiling it was
            // judged against.
            tracing::debug!(
                "[IMAGE_VALIDATION] Stats: size={}, min={}, max={}, mean={}, saturated={:.1}% (>= {})",
                total_pixels,
                min_value,
                max_value,
                mean_value,
                saturation_percent * 100.0,
                saturation_threshold
            );

            // Check 1: All pixels identical (uniform data). A uniform frame is
            // one of four distinct conditions — do NOT lump them all under
            // "sensor failure or dead frame":
            //   * bias frame          -> legitimate (allowed)
            //   * all-zero            -> no data captured (Check 2 message)
            //   * uniform at ceiling  -> fully saturated / over-exposed; Check 5
            //                            reports it with "reduce exposure/gain".
            //                            Common in daylight testing and flats and
            //                            is NOT a hardware fault.
            //   * uniform mid-value   -> genuinely stuck/dead sensor.
            // Reporting an over-exposed frame as "sensor failure" is an
            // alarming misdiagnosis, and a Check 5 threshold that assumes
            // 16-bit never fires at all on 12-/14-bit cameras.
            let all_same = min_value == max_value;
            if all_same {
                if options.is_bias_frame {
                    // Bias frames may legitimately have very uniform data
                    tracing::info!(
                        "[IMAGE_VALIDATION] INFO: Bias frame has uniform pixel value {}",
                        min_value
                    );
                } else if min_value == 0 {
                    // Uniform black = no data captured (Check 2 handles the
                    // non-uniform case; report it here for the uniform case).
                    validation.add_error("Image is all-zero (no data captured)".to_string());
                    tracing::error!("[IMAGE_VALIDATION] REJECTED: All-zero image");
                } else if min_value >= saturation_threshold {
                    // Fully saturated / over-exposed: Check 5 adds the accurate
                    // "completely saturated - reduce exposure time or gain"
                    // report. Not a dead sensor.
                    tracing::warn!(
                        "[IMAGE_VALIDATION] Uniform frame fully saturated at {} (over-exposed, see saturation check)",
                        min_value
                    );
                } else {
                    validation.add_error(format!(
                        "All {} pixels have identical value {} - possible sensor failure or dead frame",
                        total_pixels, min_value
                    ));
                    tracing::error!(
                        "[IMAGE_VALIDATION] REJECTED: All pixels identical (value={})",
                        min_value
                    );
                }
            }

            // Check 2: All-zero frame (no data captured) — non-uniform safety
            // net; the uniform all-zero case is already handled in Check 1.
            let all_zero = max_value == 0;
            if all_zero && !all_same {
                validation.add_error("Image is all-zero (no data captured)".to_string());
                tracing::error!("[IMAGE_VALIDATION] REJECTED: All-zero image");
            }

            // Check 3: Underexposure, in two tiers (max < signal_floor, and
            // max < signal_floor * 5). Both are warnings: a dim frame is real
            // data (a short narrowband subframe off a right-justified 12-bit
            // camera whose driver declares a 16-bit ceiling peaks under the
            // floor), and a capture error throws the frame away.
            //
            // Both tiers are proportions of the container the frame actually
            // arrived in, not bare ADU counts. The unscaled 100/500 pair is
            // 0.15%/0.76% of a 16-bit container but 39%/196% of an 8-bit one,
            // so on the SVBony RAW8 fallback it called every frame low-signal —
            // including a completely saturated one, in the same breath as
            // calling it clipped — and aborted the dim ones outright. See
            // signal_floor_for_full_scale.
            let signal_floor = believed_full_scale.map_or(options.min_max_value, |full_scale| {
                signal_floor_for_full_scale(options.min_max_value, full_scale)
            });
            let moderate_threshold = signal_floor.saturating_mul(5);
            if max_value < signal_floor && !all_zero && !options.is_bias_frame {
                validation.add_warning(format!(
                    "Image severely underexposed: max pixel value {} is below {} - \
                    increase the exposure time, or check the shutter, cap and dome",
                    max_value, signal_floor
                ));
                validation.below_signal_floor = Some(BelowSignalFloor {
                    max_value,
                    floor: signal_floor,
                });
                tracing::warn!(
                    "[IMAGE_VALIDATION] WARNING: Severely underexposed (max={} < {})",
                    max_value,
                    signal_floor
                );
            } else if max_value < moderate_threshold && !all_zero && !options.is_bias_frame {
                // Moderate underexposure - useful signal but concerning
                validation.add_warning(format!(
                    "Low signal detected (max value: {}) - consider increasing exposure time",
                    max_value
                ));
                tracing::warn!(
                    "[IMAGE_VALIDATION] WARNING: Low signal (max={} < {})",
                    max_value,
                    moderate_threshold
                );
            }

            // Check 4: Saturation with tiered thresholds
            // Excessive (>max_saturation_percent, default 90%) - severe
            // overexposure. Heavy (>warn_saturation_percent, default 5%) - the
            // sub's highlights are already gone, which a single 90% tier never
            // reports.
            if saturation_percent > options.max_saturation_percent {
                validation.add_warning(format!(
                    "Excessive saturation: {:.1}% of pixels are saturated (>{}%) - \
                    reduce exposure time or gain",
                    saturation_percent * 100.0,
                    options.max_saturation_percent * 100.0
                ));
                tracing::warn!(
                    "[IMAGE_VALIDATION] WARNING: Excessive saturation ({:.1}% > {:.1}%)",
                    saturation_percent * 100.0,
                    options.max_saturation_percent * 100.0
                );
            } else if saturation_percent > options.warn_saturation_percent {
                validation.add_warning(format!(
                    "Heavy saturation: {:.1}% of pixels are clipped at/above {} - \
                    those highlights are unrecoverable; reduce exposure time or gain",
                    saturation_percent * 100.0,
                    saturation_threshold
                ));
                tracing::warn!(
                    "[IMAGE_VALIDATION] WARNING: Heavy saturation ({:.1}% clipped at/above {})",
                    saturation_percent * 100.0,
                    saturation_threshold
                );
            }

            // Check 5: All pixels saturated (complete overexposure).
            //
            // WARNING, not an error, and this is the surface where that
            // distinction bites: THIS is the validator the capture path runs
            // (`unified_device_ops.rs` `camera_start_exposure_configured` calls
            // `validate_image_comprehensive` with the camera's own `max_adu`,
            // then `if !validation.is_valid { return Err(..) }`). An error here
            // does not annotate the frame, it
            // destroys it — the exposure returns Err and the caller never sees a
            // pixel.
            //
            // An over-exposed frame is real, recoverable data; the cure is a
            // shorter exposure, which the caller can only choose if it gets the
            // measurement. Failing it outright breaks the flat wizard outright:
            // it converges by deliberately over-exposing, measuring the mean
            // ADU, and stepping the exposure down (`FlatWizardService.
            // exposeAndAwait` -> `api_camera_start_exposure_configured` -> here), so a hard
            // failure removes the very measurement the correction loop runs on.
            // All-zero keeps its error because there genuinely is no data.
            let all_saturated = min_value >= saturation_threshold;
            if all_saturated {
                validation.add_warning(format!(
                    "Image is completely saturated (min value {} >= {}) - \
                    significantly reduce exposure time or gain",
                    min_value, saturation_threshold
                ));
                tracing::warn!(
                    "[IMAGE_VALIDATION] WARNING: All pixels saturated (min={})",
                    min_value
                );
            }
        }
    }

    if validation.is_valid {
        if validation.warnings.is_empty() {
            tracing::debug!("[IMAGE_VALIDATION] PASSED: Image validated successfully");
        } else {
            tracing::info!(
                "[IMAGE_VALIDATION] PASSED with {} warning{}: {:?}",
                validation.warnings.len(),
                if validation.warnings.len() == 1 {
                    ""
                } else {
                    "s"
                },
                validation.warnings
            );
        }
    } else {
        tracing::error!(
            "[IMAGE_VALIDATION] FAILED with {} error{}: {:?}",
            validation.errors.len(),
            if validation.errors.len() == 1 {
                ""
            } else {
                "s"
            },
            validation.errors
        );
    }

    validation
}

/// Validate FITS header completeness for astrophotography
///
/// # Arguments
/// * `header` - The FITS header to validate
///
/// # Returns
/// Validation result with warnings for missing recommended keywords
pub fn validate_fits_header(header: &FitsHeader) -> ImageValidation {
    let mut validation = ImageValidation::valid();

    let required = vec!["SIMPLE", "BITPIX", "NAXIS", "NAXIS1", "NAXIS2"];
    for keyword in required {
        if header.get(keyword).is_none() {
            validation.add_error(format!("Missing required keyword: {}", keyword));
        }
    }

    let recommended = vec![
        "DATE-OBS", "EXPTIME", "IMAGETYP", "OBJECT", "TELESCOP", "INSTRUME", "OBSERVER",
    ];
    for keyword in recommended {
        if header.get(keyword).is_none() {
            validation.add_warning(format!("Missing recommended keyword: {}", keyword));
        }
    }

    validation
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_validate_image_correct_dimensions() {
        let image = ImageData::from_u16(100, 100, 1, &vec![1000u16; 100 * 100]);
        let validation = validate_image(&image, Some(100), Some(100));
        assert!(
            validation.is_valid,
            "Image with correct dimensions should be valid"
        );
        assert!(validation.errors.is_empty(), "Should have no errors");
    }

    #[test]
    fn test_validate_image_wrong_dimensions() {
        let image = ImageData::from_u16(100, 100, 1, &vec![1000u16; 100 * 100]);
        let validation = validate_image(&image, Some(200), Some(200));
        assert!(
            !validation.is_valid,
            "Image with wrong dimensions should be invalid"
        );
        assert_eq!(
            validation.errors.len(),
            2,
            "Should have 2 dimension mismatch errors"
        );
    }

    #[test]
    fn test_validate_image_all_zero() {
        let image = ImageData::from_u16(100, 100, 1, &vec![0u16; 100 * 100]);
        let validation = validate_image(&image, None, None);
        assert!(!validation.is_valid, "All-zero image should be invalid");
        assert!(
            validation.errors.iter().any(|e| e.contains("all-zero")),
            "Should have all-zero error"
        );
    }

    #[test]
    fn test_validate_image_all_saturated() {
        let image = ImageData::from_u16(100, 100, 1, &vec![65535u16; 100 * 100]);
        let validation = validate_image(&image, None, None);
        // Reported, but NOT fatal: a validation error aborts the exposure, and
        // an over-exposed frame is recoverable data the caller needs to see in
        // order to lower the exposure. The flat wizard converges on exactly
        // this frame.
        assert!(
            validation.is_valid,
            "an over-exposed frame must not fail the capture"
        );
        assert!(
            validation.warnings.iter().any(|w| w.contains("saturated")),
            "Should warn about saturation, got {:?}",
            validation.warnings
        );
    }

    #[test]
    fn test_validate_image_low_signal() {
        let image = ImageData::from_u16(100, 100, 1, &vec![50u16; 100 * 100]);
        let validation = validate_image(&image, None, None);
        assert!(
            validation.is_valid,
            "Low signal image should still be valid"
        );
        assert!(
            !validation.warnings.is_empty(),
            "Should have low signal warning"
        );
    }

    /// Errors + warnings, lowercased, for the "did it say anything about
    /// clipping?" assertions below.
    fn saturation_messages(v: &ImageValidation) -> Vec<String> {
        v.errors
            .iter()
            .chain(v.warnings.iter())
            .map(|m| m.to_lowercase())
            .filter(|m| m.contains("saturat") || m.contains("clipped"))
            .collect()
    }

    #[test]
    fn test_saturation_threshold_tracks_the_sensor_ceiling() {
        // The threshold is a proportion of the sensor's own full scale, not a
        // constant: ~0.8% of headroom under the ceiling, whatever the ceiling.
        for full_scale in [255u32, 1023, 4095, 16383, 65520, 65535] {
            let t = saturation_threshold_for_full_scale(full_scale)
                .unwrap_or_else(|| panic!("{full_scale} is a usable ceiling"));
            let headroom_adu = full_scale - u32::from(t);
            let headroom = f64::from(headroom_adu) / f64::from(full_scale);
            assert!(
                headroom_adu >= 1 && headroom <= 0.009,
                "threshold {t} for full scale {full_scale} leaves {headroom_adu} ADU \
                 ({headroom:.4}) of headroom; it must sit at least one ADU below the \
                 ceiling (sensors clip a little low) and no more than ~1% below it \
                 (or unclipped highlights start counting as saturated)"
            );
            if full_scale >= 1023 {
                assert!(
                    headroom >= 0.006,
                    "full scale {full_scale} got only {headroom:.4} headroom; the ~0.8% \
                     margin is what caught the ASI1600 clipping at 65504 instead of 65520"
                );
            }
        }

        // 16-bit must reproduce the historical constant exactly so nothing that
        // relied on 65024 shifts underfoot.
        assert_eq!(
            saturation_threshold_for_full_scale(65535),
            Some(DEFAULT_SATURATION_THRESHOLD)
        );

        // A driver reporting a nonsense ceiling must not drag the threshold
        // under the sky background and fail every frame of the night.
        assert_eq!(saturation_threshold_for_full_scale(0), None);
        assert_eq!(saturation_threshold_for_full_scale(64), None);
    }

    #[test]
    fn test_declared_ceiling_decides_saturation_not_the_pixel_values() {
        // Same bytes, two sensors. A quarter of the frame sits in the top 1% of
        // a 12-bit container: badly over-exposed on a 12-bit camera, an ordinary
        // dim frame on a 16-bit one. Nothing in the pixels says which — only the
        // declared ceiling does.
        //
        // The bright region is deliberately NOT clipped: its values spread over
        // 4064..=4090 and only ten pixels reach the peak, far under the pile-up
        // a real clip leaves. That is what keeps this a test of the declaration
        // rather than of the frame's own evidence.
        let mut pixels = vec![800u16; 128 * 128];
        for (i, p) in pixels.iter_mut().enumerate().take(4000) {
            *p = 4064 + (i % 26) as u16;
        }
        for p in pixels.iter_mut().skip(4000).take(10) {
            *p = 4090;
        }
        let image = ImageData::from_u16(128, 128, 1, &pixels);

        let twelve_bit =
            validate_image_comprehensive(&image, ImageValidationOptions::for_sensor(4095));
        assert!(
            !saturation_messages(&twelve_bit).is_empty(),
            "half a 12-bit frame at its 4095 ceiling is clipped, got {:?} / {:?}",
            twelve_bit.errors,
            twelve_bit.warnings
        );

        let sixteen_bit =
            validate_image_comprehensive(&image, ImageValidationOptions::for_sensor(65535));
        assert!(
            saturation_messages(&sixteen_bit).is_empty(),
            "4090 is 6% of full scale on a 16-bit sensor and must not read as \
             saturation, got {:?} / {:?}",
            sixteen_bit.errors,
            sixteen_bit.warnings
        );
    }

    #[test]
    fn test_container_width_declaration_does_not_hide_a_right_justified_clip() {
        // The counterpart to the test above, and the reason the declared ceiling
        // cannot simply win. A driver with nothing better to say answers with the
        // container width — INDI falls back to `(1 << CCD_BITSPERPIXEL) - 1` =
        // 65535 — while delivering right-justified 12-bit samples that pile up on
        // 4095. Against a 65535 ceiling nothing in this frame is saturated, so
        // taking the declaration at face value hides a completely clipped flat.
        let image = ImageData::from_u16(256, 256, 1, &vec![4095u16; 256 * 256]);
        let v = validate_image_comprehensive(&image, ImageValidationOptions::for_sensor(65535));
        assert!(
            !saturation_messages(&v).is_empty(),
            "a frame pinned to 4095 is clipped no matter what ceiling the driver \
             declared, got {:?} / {:?}",
            v.errors,
            v.warnings
        );
    }

    #[test]
    fn test_declared_ceiling_below_the_data_is_distrusted() {
        // The shipped bit_depth/max_adu confusion: a driver advertises 4095 (its
        // ADC bits) while its left-justified samples reach 65504. Honouring that
        // ceiling would call a perfectly exposed frame completely saturated and
        // fail the exposure, so a ceiling the frame itself exceeds is discarded.
        //
        // The sky background sits at a genuine left-justified level (2000 << 4)
        // rather than a token few hundred ADU, and that is what gives this test
        // teeth: against a believed 4095 ceiling EVERY pixel here is over the
        // 4064 clip threshold, so deleting the `filter` that discards the
        // declaration turns an ordinary sub into "Excessive saturation: 100.0%".
        // Over a dim background only the two bright pixels would cross it —
        // 0.01% of the frame, under every reporting tier — and the assertions
        // below would pass with or without the guard, pinning nothing.
        let mut pixels = vec![32000u16; 128 * 128];
        pixels[0] = 65504;
        pixels[1] = 40000;
        let image = ImageData::from_u16(128, 128, 1, &pixels);

        let v = validate_image_comprehensive(&image, ImageValidationOptions::for_sensor(4095));
        assert!(
            saturation_messages(&v).is_empty(),
            "a frame that exceeds the declared ceiling proves the declaration \
             wrong; it must not be reported as saturated: {:?} / {:?}",
            v.errors,
            v.warnings
        );
        assert!(
            v.is_valid,
            "well-exposed frame must stay valid: {:?}",
            v.errors
        );
    }

    #[test]
    fn test_right_justified_12bit_clip_is_saturation_not_a_dead_sensor() {
        // INDI CCDs and several ASCOM drivers deliver a 12-bit sensor as 0..4095
        // instead of left-shifting into 16 bits. A fully clipped frame from one
        // of those never reached the 16-bit threshold, so the app announced
        // "possible sensor failure or dead frame" at an over-exposed user.
        // Driven through the exact call the capture path makes.
        let image = ImageData::from_u16(256, 256, 1, &vec![4095u16; 256 * 256]);
        let v = validate_image_with_options(&image, Some(256), Some(256), false);
        assert!(v.is_valid, "a clipped 12-bit frame must still be returned");
        assert!(
            v.warnings
                .iter()
                .any(|w| w.to_lowercase().contains("saturated")),
            "expected a saturation error at the 12-bit ceiling, got {:?}",
            v.errors
        );
        assert!(
            !v.errors
                .iter()
                .any(|e| e.contains("dead frame") || e.contains("sensor failure")),
            "over-exposure must not be misreported as broken hardware: {:?}",
            v.errors
        );
    }

    #[test]
    fn test_right_justified_14bit_clip_is_saturation_not_a_dead_sensor() {
        // Same story one ADC generation up: 0..16383.
        let image = ImageData::from_u16(256, 256, 1, &vec![16383u16; 256 * 256]);
        let v = validate_image_with_options(&image, Some(256), Some(256), false);
        assert!(v.is_valid, "a clipped 14-bit frame must still be returned");
        assert!(
            v.warnings
                .iter()
                .any(|w| w.to_lowercase().contains("saturated")),
            "expected a saturation warning at the 14-bit ceiling, got {:?}",
            v.warnings
        );
        assert!(
            !v.errors
                .iter()
                .any(|e| e.contains("dead frame") || e.contains("sensor failure")),
            "over-exposure must not be misreported as broken hardware: {:?}",
            v.errors
        );
    }

    #[test]
    fn test_right_justified_clip_flagged_by_the_basic_validator_too() {
        // api_* image loads go through the three-argument validator, which had
        // the 16-bit constant baked in and stayed silent on the same frame.
        let image = ImageData::from_u16(256, 256, 1, &vec![4095u16; 256 * 256]);
        let v = validate_image(&image, Some(256), Some(256));
        assert!(
            v.warnings
                .iter()
                .any(|w| w.to_lowercase().contains("saturated")),
            "expected an all-saturated warning at the 12-bit ceiling, got {:?}",
            v.warnings
        );
        // Detected without failing the capture: the frame is clipped against
        // its own 12-bit ceiling, and an over-exposed frame is still a frame.
        assert!(
            v.is_valid,
            "a clipped 12-bit flat must still return a frame"
        );
    }

    #[test]
    fn test_half_clipped_frame_is_reported() {
        // Half the pixels at the ceiling is a ruined sub, and a 90%-only tier
        // never says so.
        let mut pixels = vec![12000u16; 128 * 128];
        for p in pixels.iter_mut().take(128 * 128 / 2) {
            *p = 65535;
        }
        let image = ImageData::from_u16(128, 128, 1, &pixels);
        let v = validate_image_with_options(&image, Some(128), Some(128), false);
        let reported = saturation_messages(&v);
        assert!(
            !reported.is_empty(),
            "a 50%-clipped frame must say so, got {:?} / {:?}",
            v.errors,
            v.warnings
        );
        assert!(
            reported.iter().any(|m| m.contains("50.0%")),
            "the report should carry the actual clipped fraction: {reported:?}"
        );
    }

    #[test]
    fn test_normal_star_field_with_a_few_clipped_cores_is_clean() {
        // The counterweight to the two tests above: a good 12-bit sub clips only
        // the brightest star cores. Neither the ceiling inference nor the new
        // lower saturation tier may turn that into a complaint, or every frame
        // of a normal night carries a warning and the warning stops meaning
        // anything.
        let mut pixels: Vec<u16> = (0..256 * 256).map(|i| 495 + (i % 11) as u16).collect();
        for i in 0..8 {
            pixels[i * 997] = 4095;
        }
        let image = ImageData::from_u16(256, 256, 1, &pixels);
        let v = validate_image_with_options(&image, Some(256), Some(256), false);
        assert!(
            saturation_messages(&v).is_empty(),
            "0.01% clipped cores is a normal sub: {:?} / {:?}",
            v.errors,
            v.warnings
        );
        assert!(v.is_valid, "normal sub must be valid: {:?}", v.errors);
    }

    #[test]
    fn test_sensor_clipping_a_few_adu_low_is_still_a_clip() {
        // An over-exposed flat off a 12-bit sensor delivered right-justified,
        // whose ADC pins at 4090 rather than the container's exact 4095 — the
        // same "real sensors clip a little low" fact that SATURATION_HEADROOM_SHIFT
        // exists for (the live ASI1600 clips at 4094 << 4, not 4095 << 4).
        //
        // The driver has nothing better to declare than the container width:
        // INDI answers `(1 << CCD_BITSPERPIXEL) - 1` = 65535 for exactly these
        // cameras. So the frame's own pile-up is the only evidence of where it
        // clips, and if the inference demands the peak equal 4095 exactly, a
        // 70%-clipped flat is reported as a perfectly good frame.
        let mut pixels = vec![4090u16; 256 * 256];
        // Vignetted corners fall away from the clipped plateau, so the frame is
        // not uniform — the dead-sensor path is not what is under test.
        for (i, p) in pixels.iter_mut().enumerate().take(20_000) {
            *p = 3000 + (i % 500) as u16;
        }
        let image = ImageData::from_u16(256, 256, 1, &pixels);

        let v = validate_image_comprehensive(&image, ImageValidationOptions::for_sensor(65535));
        let reported = saturation_messages(&v);
        assert!(
            !reported.is_empty(),
            "a frame with 69% of its pixels pinned at 4090 is a clipped 12-bit \
             frame, five ADU low or not: {:?} / {:?}",
            v.errors,
            v.warnings
        );
        assert!(
            reported.iter().any(|m| m.contains("4064")),
            "the report must be judged against the 12-bit container the pile-up \
             identifies, not the declared 65535: {reported:?}"
        );
        assert!(v.is_valid, "an over-exposed flat must still be returned");
    }

    #[test]
    fn test_clip_below_the_ceiling_flagged_by_the_basic_validator_too() {
        // Same shortfall through the three-argument validator the api_* image
        // loads use, which has no sensor to ask at all.
        let image = ImageData::from_u16(256, 256, 1, &vec![4090u16; 256 * 256]);
        let v = validate_image(&image, Some(256), Some(256));
        assert!(
            v.warnings
                .iter()
                .any(|w| w.to_lowercase().contains("saturated")),
            "a frame pinned at 4090 is clipped, got {:?} / {:?}",
            v.errors,
            v.warnings
        );
        assert!(v.is_valid, "a clipped flat must still return a frame");
    }

    #[test]
    fn test_every_recognised_container_is_recognised_without_a_declared_ceiling() {
        // RIGHT_JUSTIFIED_FULL_SCALES is a claim about hardware we support, and
        // only two of its four entries were held by anything: deleting 255 or
        // 1023 from the table left the entire suite green. All four are real —
        // `vendor/touptek.rs` `max_adu_from_bit_depth` returns `(1 << bits) - 1`
        // verbatim, so an 8-/10-/12-/14-bit Touptek-family camera declares
        // 255 / 1023 / 4095 / 16383, and both the QHY 8-bit transfer container
        // and the SVBony RAW8 connect fallback land on 255.
        //
        // Driven with NO declared ceiling, which is a live production branch and
        // not a contrivance: `unified_device_ops.rs` asks the camera for its
        // status best-effort and passes `sensor_max_adu: None` whenever the
        // driver cannot answer, and the three `validate_image` call sites in
        // `api/imaging.rs` have no camera to ask at all. The frame's own pile-up
        // is then the only evidence of where the sensor clips.
        //
        // Each frame clips a few ADU UNDER its container ceiling, the way real
        // sensors do, so the tolerance band is pinned for every container rather
        // than only for the 12-bit one.
        for (full_scale, clips_at) in [(255u16, 254u16), (1023, 1018), (4095, 4090), (16383, 16303)]
        {
            let image = ImageData::from_u16(128, 128, 1, &vec![clips_at; 128 * 128]);

            let v = validate_image_comprehensive(&image, ImageValidationOptions::default());
            assert!(
                v.is_valid,
                "a blown flat off a {full_scale}-ADU container is over-exposed, \
                 not a failure — an error here aborts the exposure: {:?}",
                v.errors
            );
            assert!(
                !v.errors
                    .iter()
                    .any(|e| e.contains("dead frame") || e.contains("sensor failure")),
                "a frame pinned at {clips_at} on a {full_scale}-ADU container is \
                 clipped, not a broken camera: {:?}",
                v.errors
            );
            assert!(
                !saturation_messages(&v).is_empty(),
                "a {full_scale}-ADU container clipping at {clips_at} must be \
                 reported as saturated: {:?} / {:?}",
                v.errors,
                v.warnings
            );
            assert!(
                exposure_level_messages(&v).is_empty(),
                "a clipped frame is the opposite of underexposed: {:?} / {:?}",
                v.errors,
                v.warnings
            );

            let basic = validate_image(&image, Some(128), Some(128));
            assert!(
                basic
                    .warnings
                    .iter()
                    .any(|w| w.to_lowercase().contains("saturated")),
                "the FITS-save validator must recognise the same {full_scale}-ADU \
                 clip: {:?} / {:?}",
                basic.errors,
                basic.warnings
            );
        }
    }

    /// Errors + warnings, lowercased, for the "did it call the frame empty?"
    /// assertions below.
    fn exposure_level_messages(v: &ImageValidation) -> Vec<String> {
        v.errors
            .iter()
            .chain(v.warnings.iter())
            .map(|m| m.to_lowercase())
            .filter(|m| m.contains("underexposed") || m.contains("low signal"))
            .collect()
    }

    #[test]
    fn test_eight_bit_container_frame_is_not_called_underexposed() {
        // The SVBony `connect()` fallback: a model with no RAW16 mode runs as
        // SVB_IMG_RAW8, publishes `max_adu: 255` and hands its samples over as
        // 0..255 widened into the 16-bit buffer (`vendor/svbony.rs`). A sub
        // peaking at 90 of 255 is a third of full scale — a perfectly ordinary
        // dim sub, not an empty frame.
        //
        // Judged against the unscaled 100-ADU floor it is "severely
        // underexposed": every sub off that camera.
        let mut pixels = vec![24u16; 128 * 128];
        for (i, p) in pixels.iter_mut().enumerate().step_by(97) {
            *p = 60 + (i % 31) as u16;
        }
        pixels[0] = 90;
        let image = ImageData::from_u16(128, 128, 1, &pixels);

        let v = validate_image_comprehensive(&image, ImageValidationOptions::for_sensor(255));
        assert!(
            v.is_valid,
            "a third of an 8-bit container's full scale is a real frame: {:?}",
            v.errors
        );
        assert!(
            exposure_level_messages(&v).is_empty(),
            "nothing here is underexposed at a 255-ADU ceiling: {:?} / {:?}",
            v.errors,
            v.warnings
        );
    }

    #[test]
    fn test_signal_floor_still_catches_a_frame_with_nothing_in_it() {
        // The counterweight: scaling the floor to the container must not retire
        // the check. Four ADU out of a 4095 container is 0.1%: a blocked
        // shutter or a capped scope, which the frame is kept to show.
        let mut pixels = vec![1u16; 128 * 128];
        pixels[0] = 4;
        let image = ImageData::from_u16(128, 128, 1, &pixels);

        let v = validate_image_comprehensive(&image, ImageValidationOptions::for_sensor(4095));
        assert!(v.is_valid, "{:?}", v.errors);
        assert!(
            v.warnings
                .iter()
                .any(|w| w.to_lowercase().contains("severely underexposed")),
            "expected a severe-underexposure warning: {:?}",
            v.warnings
        );
    }

    #[test]
    fn a_dim_frame_off_a_camera_that_declares_a_wider_ceiling_is_kept() {
        // A right-justified 12-bit camera whose driver declares the 16-bit
        // container (INDI's `(1 << CCD_BITSPERPIXEL) - 1`): a short
        // narrowband subframe with no star sits at the black level plus read
        // noise, far under 100 of 65535. That is a quality problem, not a
        // broken capture; the frame is kept and the problem said.
        let pixels: Vec<u16> = (0..64 * 64).map(|i| 20 + (i * 7 % 23) as u16).collect();
        let image = ImageData::from_u16(64, 64, 1, &pixels);

        let v = validate_image_comprehensive(&image, ImageValidationOptions::for_sensor(65535));
        assert!(v.is_valid, "a dim frame was refused: {:?}", v.errors);
        assert!(
            v.warnings
                .iter()
                .any(|w| w.to_lowercase().contains("severely underexposed")),
            "{:?}",
            v.warnings
        );
    }

    #[test]
    fn test_comprehensive_uniform_saturated_not_dead_frame() {
        // A frame uniformly at the 14-bit sensor ceiling (16382 << 2 = 65528)
        // is over-exposed, NOT a dead sensor. It must be rejected as saturated
        // with "reduce exposure" guidance, never as "sensor failure or dead
        // frame" — the misdiagnosis a 14-bit ASI178MM frame invites.
        let image = ImageData::from_u16(64, 64, 1, &vec![65528u16; 64 * 64]);
        let v = validate_image_comprehensive(&image, ImageValidationOptions::default());
        assert!(
            v.is_valid,
            "a saturated frame must still be returned to the caller"
        );
        assert!(
            v.warnings
                .iter()
                .any(|w| w.to_lowercase().contains("saturated")),
            "expected a saturation error, got {:?}",
            v.errors
        );
        assert!(
            !v.errors
                .iter()
                .any(|e| e.contains("dead frame") || e.contains("sensor failure")),
            "saturation must not be misreported as a dead/failed sensor: {:?}",
            v.errors
        );
    }

    #[test]
    fn test_comprehensive_real_asi1600_saturation_not_dead_frame() {
        // Captured live from an ASI1600MM-Cool (12-bit): a fully clipped frame
        // reads 65504 (4094 << 4) — ONE ADU below the theoretical 12-bit ceiling
        // of 65520. A threshold pinned to the exact ceiling missed it and the
        // frame came back as "possible sensor failure or dead frame".
        let image = ImageData::from_u16(64, 64, 1, &vec![65504u16; 64 * 64]);
        let v = validate_image_comprehensive(&image, ImageValidationOptions::default());
        assert!(
            v.is_valid,
            "a clipped frame must still be returned to the caller"
        );
        assert!(
            v.warnings
                .iter()
                .any(|w| w.to_lowercase().contains("saturated")),
            "expected saturation error for real ASI1600 clip value, got {:?}",
            v.errors
        );
        assert!(
            !v.errors
                .iter()
                .any(|e| e.contains("dead frame") || e.contains("sensor failure")),
            "real-world saturation must not read as a dead sensor: {:?}",
            v.errors
        );
    }

    #[test]
    fn test_comprehensive_12bit_saturation_detected() {
        // 12-bit ceiling scaled to 16-bit = 4095 << 4 = 65520 (e.g. ASI1600MM).
        let image = ImageData::from_u16(64, 64, 1, &vec![65520u16; 64 * 64]);
        let v = validate_image_comprehensive(&image, ImageValidationOptions::default());
        assert!(
            v.is_valid,
            "an over-exposed frame must be reported without failing the capture"
        );
        assert!(
            v.warnings
                .iter()
                .any(|w| w.to_lowercase().contains("saturated")),
            "expected saturation error for 12-bit ceiling, got {:?}",
            v.errors
        );
    }

    #[test]
    fn test_comprehensive_uniform_midvalue_is_dead_frame() {
        // A uniform frame at an arbitrary mid value (not 0, not saturated) is a
        // genuinely stuck/dead sensor and must still be rejected as such.
        let image = ImageData::from_u16(64, 64, 1, &vec![30000u16; 64 * 64]);
        let v = validate_image_comprehensive(&image, ImageValidationOptions::default());
        assert!(!v.is_valid, "stuck-sensor frame is invalid");
        assert!(
            v.errors
                .iter()
                .any(|e| e.contains("sensor failure") || e.contains("dead frame")),
            "mid-value uniform frame should read as dead/failed sensor: {:?}",
            v.errors
        );
    }

    #[test]
    fn test_comprehensive_uniform_zero_is_no_data() {
        // A uniform all-zero frame is "no data captured", not a dead sensor.
        let image = ImageData::from_u16(64, 64, 1, &vec![0u16; 64 * 64]);
        let v = validate_image_comprehensive(&image, ImageValidationOptions::default());
        assert!(!v.is_valid, "all-zero frame is invalid");
        assert!(
            v.errors.iter().any(|e| e.contains("all-zero")),
            "expected all-zero error: {:?}",
            v.errors
        );
    }

    #[test]
    fn test_validate_fits_header_minimal() {
        let mut header = FitsHeader::new();
        header.set_string("SIMPLE", "T");
        header.set_int("BITPIX", 16);
        header.set_int("NAXIS", 2);
        header.set_int("NAXIS1", 100);
        header.set_int("NAXIS2", 100);

        let validation = validate_fits_header(&header);
        assert!(validation.is_valid, "Minimal FITS header should be valid");
        assert!(
            !validation.warnings.is_empty(),
            "Should have warnings for missing recommended keywords"
        );
    }

    #[test]
    fn test_validate_fits_header_complete() {
        let mut header = FitsHeader::new();
        // Required
        header.set_string("SIMPLE", "T");
        header.set_int("BITPIX", 16);
        header.set_int("NAXIS", 2);
        header.set_int("NAXIS1", 100);
        header.set_int("NAXIS2", 100);
        // Recommended
        header.set_string("DATE-OBS", "2025-01-01T00:00:00");
        header.set_float("EXPTIME", 60.0);
        header.set_string("IMAGETYP", "Light");
        header.set_string("OBJECT", "M31");
        header.set_string("TELESCOP", "Test Scope");
        header.set_string("INSTRUME", "Test Camera");
        header.set_string("OBSERVER", "Test Observer");

        let validation = validate_fits_header(&header);
        assert!(validation.is_valid, "Complete FITS header should be valid");
        assert!(
            validation.warnings.is_empty(),
            "Complete header should have no warnings"
        );
    }

    #[test]
    fn test_validate_fits_header_missing_required() {
        let mut header = FitsHeader::new();
        header.set_string("SIMPLE", "T");
        // Missing BITPIX, NAXIS, etc.

        let validation = validate_fits_header(&header);
        assert!(
            !validation.is_valid,
            "Header missing required keywords should be invalid"
        );
        assert!(
            !validation.errors.is_empty(),
            "Should have errors for missing required keywords"
        );
    }
}
