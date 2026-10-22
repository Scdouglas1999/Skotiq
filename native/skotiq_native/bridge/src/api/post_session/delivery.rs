//! A target's per-filter masters as linear files PixInsight opens directly.
//!
//! [`master_deliver`] registers every master onto one reference master, writes
//! each as a 32-bit float FITS on the reference grid, and stacks the red, green
//! and blue masters into one planar RGB FITS. Samples are the masters' ADU
//! divided by 65535, one factor for every file so channel ratios and linearity
//! survive, and clipped to the [0, 1] range PixInsight expects of float data.
//! Pixels a master does not cover after registration are 0.
//!
//! Masters built on a shared grid (the multi-night build registers every
//! filter onto one reference) are measured but not resampled again when the
//! fitted geometry is within [`ON_GRID_PX`] of the identity.

use super::*;

use skotiq_imaging::color_composite::{
    alignment_check, classify_filter, register_onto, warp_window, Affine2, FilterRole, Rect,
};
use skotiq_imaging::recipe::{OpContext, OpImage};

/// One master offered for delivery.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct DeliverMasterArgs {
    pub(crate) path: String,
    /// The filter; the master's `FILTER` card when absent.
    pub(crate) filter: Option<String>,
}

/// Request for `op: "deliver"`.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct MasterDeliverArgs {
    pub(crate) masters: Vec<DeliverMasterArgs>,
    /// The filter whose master is the grid. Absent ⇒ luminance when there is
    /// one, otherwise the master with the most integration time.
    pub(crate) reference_filter: Option<String>,
    pub(crate) output_dir: String,
    /// Prefixes every file name.
    pub(crate) target: String,
}

/// How one master was placed on the grid.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct DeliveredMaster {
    pub(crate) source_path: String,
    pub(crate) output_path: String,
    pub(crate) filter: Option<String>,
    /// `luminance` | `red` | `green` | `blue` | … as the composite names roles.
    pub(crate) role: String,
    pub(crate) reference: bool,
    /// The fitted geometry was the identity, so the master was not resampled.
    pub(crate) on_grid: bool,
    pub(crate) model: Option<String>,
    pub(crate) stars_matched: Option<usize>,
    pub(crate) fit_rms_px: Option<f64>,
    pub(crate) rotation_deg: Option<f64>,
    pub(crate) scale: Option<f64>,
    pub(crate) shift_px: Option<[f64; 2]>,
    /// Fraction of grid pixels the master covers.
    pub(crate) coverage: f64,
    /// Star centroid offsets against the reference after registration, over a
    /// central window.
    pub(crate) check_stars: Option<usize>,
    pub(crate) check_median_offset_px: Option<f64>,
    pub(crate) check_rms_offset_px: Option<f64>,
    /// Covered samples clipped to 0 or 1.
    pub(crate) clipped_samples: usize,
    pub(crate) frames: Option<i64>,
    pub(crate) integration_sec: Option<f64>,
}

/// Response for `op: "deliver"`.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct MasterDeliverResult {
    pub(crate) reference_filter: Option<String>,
    pub(crate) width: u32,
    pub(crate) height: u32,
    pub(crate) masters: Vec<DeliveredMaster>,
    /// The planar R,G,B FITS, when red, green and blue masters were offered.
    pub(crate) rgb_path: Option<String>,
}

/// The divisor that maps ADU onto PixInsight's [0, 1] float range.
const ADU_FULL_SCALE: f32 = 65535.0;
/// Largest displacement, over the frame, of a fitted geometry still taken as
/// the identity.
const ON_GRID_PX: f64 = 0.05;
/// Side of the central window the registration check measures.
const CHECK_WINDOW_PX: u32 = 2048;

struct Loaded {
    path: String,
    filter: Option<String>,
    role: FilterRole,
    image: OpImage,
}

fn load(args: &DeliverMasterArgs) -> Result<Loaded, String> {
    let (data, header) = read_fits(Path::new(args.path.trim()))
        .map_err(|e| format!("cannot read master '{}': {e}", args.path))?;
    let image = OpImage::from_image_data(&data, header)
        .map_err(|e| format!("cannot use master '{}': {e}", args.path))?;
    let filter = args
        .filter
        .clone()
        .filter(|f| !f.trim().is_empty())
        .or_else(|| {
            image
                .header()
                .get_string("FILTER")
                .map(|f| f.trim().to_string())
        })
        .filter(|f| !f.is_empty());
    let role = classify_filter(filter.as_deref(), image.channels());
    Ok(Loaded {
        path: args.path.trim().to_string(),
        filter,
        role,
        image,
    })
}

/// How far `transform` moves any corner of a `width`×`height` frame.
fn largest_displacement(transform: &Affine2, width: u32, height: u32) -> f64 {
    let (w, h) = (width as f64 - 1.0, height as f64 - 1.0);
    [(0.0, 0.0), (w, 0.0), (0.0, h), (w, h)]
        .iter()
        .map(|&(x, y)| {
            let (mx, my) = transform.apply(x, y);
            (mx - x).hypot(my - y)
        })
        .fold(0.0, f64::max)
}

/// Resample `image` onto the reference grid. Grid pixels whose source lies
/// outside the master become NaN, so they read as uncovered.
fn warp_onto_grid(
    image: &OpImage,
    transform: &Affine2,
    width: u32,
    height: u32,
    ctx: &OpContext,
) -> Result<Vec<f32>, String> {
    let full = Rect {
        x: 0,
        y: 0,
        width,
        height,
    };
    let mut data = warp_window(image, transform, full, ctx).map_err(|e| e.to_string())?;
    let inverse = transform
        .inverse()
        .ok_or_else(|| "the fitted geometry is singular".to_string())?;
    let channels = image.channels() as usize;
    let (sw, sh) = (image.width() as f64 - 1.0, image.height() as f64 - 1.0);
    for (i, pixel) in data.chunks_mut(channels).enumerate() {
        let (x, y) = ((i % width as usize) as f64, (i / width as usize) as f64);
        let (sx, sy) = inverse.apply(x, y);
        if !(0.0..=sw).contains(&sx) || !(0.0..=sh).contains(&sy) {
            pixel.fill(f32::NAN);
        }
    }
    Ok(data)
}

/// A central window of an interleaved buffer as an image, for the check.
fn window(data: &[f32], width: u32, height: u32, channels: u32) -> Result<OpImage, String> {
    let w = CHECK_WINDOW_PX.min(width);
    let h = CHECK_WINDOW_PX.min(height);
    let (x0, y0) = ((width - w) / 2, (height - h) / 2);
    let c = channels as usize;
    let mut out = Vec::with_capacity((w * h) as usize * c);
    for y in y0..y0 + h {
        let start = ((y * width + x0) as usize) * c;
        out.extend(data[start..start + w as usize * c].iter().map(|v| {
            if v.is_finite() {
                *v
            } else {
                0.0
            }
        }));
    }
    OpImage::new(w, h, channels, out, FitsHeader::new()).map_err(|e| e.to_string())
}

/// Scale ADU into [0, 1]; NaN (uncovered) becomes 0. Returns the covered
/// fraction and how many covered samples were clipped.
fn to_unit_range(data: &mut [f32]) -> (f64, usize) {
    let mut covered = 0usize;
    let mut clipped = 0usize;
    for v in data.iter_mut() {
        if !v.is_finite() {
            *v = 0.0;
            continue;
        }
        covered += 1;
        let scaled = *v / ADU_FULL_SCALE;
        if !(0.0..=1.0).contains(&scaled) {
            clipped += 1;
        }
        *v = scaled.clamp(0.0, 1.0);
    }
    (covered as f64 / data.len().max(1) as f64, clipped)
}

fn delivery_header(source: &OpImage, history: &[String]) -> FitsHeader {
    let mut header = FitsHeader::new();
    for key in [
        "OBJECT", "FILTER", "NFRAMES", "EXPTIME", "IMAGETYP", "INSTRUME", "TELESCOP", "FOCALLEN",
        "XPIXSZ", "YPIXSZ", "GAIN", "OFFSET", "CALSTAT",
    ] {
        if let Some(value) = source.header().get(key) {
            match value {
                skotiq_imaging::FitsValue::String(s) => header.set_string(key, s),
                skotiq_imaging::FitsValue::Integer(i) => header.set_int(key, *i),
                skotiq_imaging::FitsValue::Float(f) => header.set_float(key, *f),
                skotiq_imaging::FitsValue::Boolean(b) => header.set_bool(key, *b),
                skotiq_imaging::FitsValue::Comment(_) => {}
            }
        }
    }
    for line in &source.header().history {
        header.add_history(line);
    }
    for line in history {
        header.add_history(line);
    }
    header
}

fn role_wire(role: &FilterRole) -> String {
    match role {
        FilterRole::Other(_) => "other".to_string(),
        known => known.as_wire().to_string(),
    }
}

/// Register a target's masters onto one grid and write the PixInsight set.
pub(crate) fn master_deliver(args_json: &str) -> Result<MasterDeliverResult, String> {
    let args: MasterDeliverArgs =
        serde_json::from_str(args_json).map_err(|e| format!("invalid deliver args: {e}"))?;
    if args.masters.is_empty() {
        return Err("deliver requires at least one master".to_string());
    }
    if args.output_dir.trim().is_empty() {
        return Err("deliver requires outputDir".to_string());
    }
    let target = if args.target.trim().is_empty() {
        "target".to_string()
    } else {
        sanitize_name(args.target.trim())
    };
    let out_dir = Path::new(args.output_dir.trim());
    std::fs::create_dir_all(out_dir)
        .map_err(|e| format!("cannot create '{}': {e}", out_dir.display()))?;

    // Choose the grid from headers alone, so only one master is held at a time
    // besides the reference.
    let mut offered = Vec::with_capacity(args.masters.len());
    for m in &args.masters {
        let header = read_fits_header(Path::new(m.path.trim()))
            .map_err(|e| format!("cannot read master '{}': {e}", m.path))?;
        let filter = m
            .filter
            .clone()
            .filter(|f| !f.trim().is_empty())
            .or_else(|| header.get_string("FILTER").map(|f| f.trim().to_string()));
        let channels = header.get_int("NAXIS3").unwrap_or(1).max(1) as u32;
        let seconds = header.get_float("EXPTIME").unwrap_or(0.0);
        offered.push((
            classify_filter(filter.as_deref(), channels),
            filter,
            seconds,
        ));
    }
    let wanted = args.reference_filter.as_deref().map(str::trim);
    let reference_index = wanted
        .and_then(|w| {
            offered
                .iter()
                .position(|(_, f, _)| f.as_deref().is_some_and(|f| f.eq_ignore_ascii_case(w)))
        })
        .or_else(|| {
            offered
                .iter()
                .position(|(r, _, _)| *r == FilterRole::Luminance)
        })
        .unwrap_or_else(|| {
            offered
                .iter()
                .enumerate()
                .max_by(|a, b| a.1 .2.total_cmp(&b.1 .2))
                .map(|(i, _)| i)
                .unwrap_or(0)
        });

    let ctx = OpContext::new();
    let reference = load(&args.masters[reference_index])?;
    let (width, height) = (reference.image.width(), reference.image.height());
    let reference_window = window(
        reference.image.data(),
        width,
        height,
        reference.image.channels(),
    )?;

    let mut delivered = Vec::new();
    let mut rgb: [Option<Vec<f32>>; 3] = [None, None, None];
    for (index, args_master) in args.masters.iter().enumerate() {
        let is_reference = index == reference_index;
        let loaded = if is_reference {
            None
        } else {
            Some(load(args_master)?)
        };
        let master = loaded.as_ref().unwrap_or(&reference);
        let mut history = vec![format!(
            "Skotiq delivery: master ADU / {ADU_FULL_SCALE:.0}, clipped to [0,1]"
        )];
        let mut entry = DeliveredMaster {
            source_path: master.path.clone(),
            output_path: String::new(),
            filter: master.filter.clone(),
            role: role_wire(&master.role),
            reference: is_reference,
            on_grid: is_reference,
            model: None,
            stars_matched: None,
            fit_rms_px: None,
            rotation_deg: None,
            scale: None,
            shift_px: None,
            coverage: 1.0,
            check_stars: None,
            check_median_offset_px: None,
            check_rms_offset_px: None,
            clipped_samples: 0,
            frames: master.image.header().get_int("NFRAMES"),
            integration_sec: master.image.header().get_float("EXPTIME"),
        };
        let mut data = if is_reference {
            history.push("Skotiq delivery: the reference grid".to_string());
            master.image.data().to_vec()
        } else {
            let alignment = register_onto(&reference.image, &master.image, &ctx).map_err(|e| {
                format!(
                    "the {} master could not be registered onto the {} master: {e}",
                    master.filter.as_deref().unwrap_or("unnamed"),
                    reference.filter.as_deref().unwrap_or("reference")
                )
            })?;
            let t = alignment.transform;
            entry.model = Some(alignment.model.to_string());
            entry.stars_matched = Some(alignment.inliers);
            entry.fit_rms_px = Some(alignment.rms_px);
            entry.rotation_deg = Some(t.rotation_deg());
            entry.scale = Some(t.scale());
            entry.shift_px = Some([t.m[2], t.m[5]]);
            entry.on_grid = master.image.width() == width
                && master.image.height() == height
                && largest_displacement(&t, width, height) <= ON_GRID_PX;
            if entry.on_grid {
                history.push(format!(
                    "Skotiq delivery: already on the {} grid (fit rms {:.3} px over {} stars)",
                    reference.filter.as_deref().unwrap_or("reference"),
                    alignment.rms_px,
                    alignment.inliers
                ));
                master.image.data().to_vec()
            } else {
                history.push(format!(
                    "Skotiq delivery: registered onto the {} master ({}, Lanczos-3)",
                    reference.filter.as_deref().unwrap_or("reference"),
                    alignment.model
                ));
                history.push(format!(
                    "Skotiq delivery: rot {:.4} deg, scale {:.5}, shift {:.2},{:.2} px, rms {:.3} px over {} stars",
                    t.rotation_deg(),
                    t.scale(),
                    t.m[2],
                    t.m[5],
                    alignment.rms_px,
                    alignment.inliers
                ));
                warp_onto_grid(&master.image, &t, width, height, &ctx)?
            }
        };
        if !is_reference {
            let aligned = window(&data, width, height, master.image.channels())?;
            if let Some(check) =
                alignment_check(&reference_window, &aligned, &ctx).map_err(|e| e.to_string())?
            {
                entry.check_stars = Some(check.stars);
                entry.check_median_offset_px = Some(check.median_px);
                entry.check_rms_offset_px = Some(check.rms_px);
            }
        }
        let (coverage, clipped) = to_unit_range(&mut data);
        entry.coverage = coverage;
        entry.clipped_samples = clipped;

        let name = match &master.role {
            FilterRole::Color => "color".to_string(),
            _ => sanitize_name(master.filter.as_deref().unwrap_or("nofilter")),
        };
        let output = out_dir.join(format!("{target}_{name}_linear.fits"));
        let image = ImageData::from_f32(width, height, master.image.channels(), &data);
        write_fits(&output, &image, &delivery_header(&master.image, &history))
            .map_err(|e| format!("failed to write '{}': {e:?}", output.display()))?;
        entry.output_path = output.to_string_lossy().to_string();
        let slot = match master.role {
            FilterRole::Red => Some(0),
            FilterRole::Green => Some(1),
            FilterRole::Blue => Some(2),
            _ => None,
        };
        if let Some(slot) = slot.filter(|_| master.image.channels() == 1) {
            if rgb[slot].is_none() {
                rgb[slot] = Some(data);
            }
        }
        delivered.push(entry);
    }

    let rgb_path = if let [Some(r), Some(g), Some(b)] = &rgb {
        let mut interleaved = Vec::with_capacity(r.len() * 3);
        for i in 0..r.len() {
            interleaved.extend_from_slice(&[r[i], g[i], b[i]]);
        }
        let mut header = FitsHeader::new();
        header.set_string("OBJECT", &args.target);
        header.set_string("COLORSPC", "RGB");
        header.add_history("Skotiq delivery: planes 1, 2, 3 are the R, G and B masters");
        header.add_history(&format!(
            "Skotiq delivery: linear, registered onto the {} master, ADU / {ADU_FULL_SCALE:.0}",
            reference.filter.as_deref().unwrap_or("reference")
        ));
        header.add_history("Skotiq delivery: no color calibration or background extraction");
        let output = out_dir.join(format!("{target}_RGB_linear.fits"));
        write_fits(
            &output,
            &ImageData::from_f32(width, height, 3, &interleaved),
            &header,
        )
        .map_err(|e| format!("failed to write '{}': {e:?}", output.display()))?;
        Some(output.to_string_lossy().to_string())
    } else {
        None
    };

    Ok(MasterDeliverResult {
        reference_filter: reference.filter.clone(),
        width,
        height,
        masters: delivered,
        rgb_path,
    })
}

/// A file-name-safe form of `name`.
fn sanitize_name(name: &str) -> String {
    let cleaned: String = name
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                c
            } else {
                '_'
            }
        })
        .collect();
    if cleaned.is_empty() {
        "unnamed".to_string()
    } else {
        cleaned
    }
}
