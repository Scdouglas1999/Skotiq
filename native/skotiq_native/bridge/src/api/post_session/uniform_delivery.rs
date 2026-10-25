//! Export masters on one grid, cropped to full exposure support in every lane.
use super::*;
use rayon::prelude::*;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Input {
    path: String,
    coverage_path: String,
    filter: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Args {
    masters: Vec<Input>,
    output_dir: String,
    #[serde(default = "minimum_area")]
    min_retained_area: f64,
    /// `adu` (default): every filter's samples are its ADU / 65535, so ratios
    /// and the zero point survive. `perFilter`: each filter spans 0..1 between
    /// its own minimum and maximum.
    #[serde(default)]
    scale: Option<String>,
    /// Write the RGB and LRGB composites when R, G and B (and L) are present.
    #[serde(default = "yes")]
    composites: bool,
}
fn minimum_area() -> f64 {
    0.8
}
fn yes() -> bool {
    true
}

/// The divisor that maps ADU onto PixInsight's 0..1 float range.
const ADU_FULL_SCALE: f64 = 65535.0;

/// Largest all-true rectangle in O(width * height) time and O(width) memory.
fn rectangle(mask: &[bool], width: usize, height: usize) -> Option<[usize; 4]> {
    let mut heights = vec![0; width];
    let mut best = (0, None);
    for y in 0..height {
        let mut stack: Vec<(usize, usize)> = Vec::new();
        for x in 0..=width {
            let h = if x == width {
                0
            } else {
                heights[x] = if mask[y * width + x] {
                    heights[x] + 1
                } else {
                    0
                };
                heights[x]
            };
            let mut start = x;
            while stack.last().is_some_and(|&(_, previous)| previous > h) {
                let (left, previous) = stack.pop().unwrap();
                let area = previous * (x - left);
                if area > best.0 {
                    best = (area, Some([left, y + 1 - previous, x, y + 1]));
                }
                start = left;
            }
            if stack.last().is_none_or(|&(_, previous)| previous < h) {
                stack.push((start, h));
            }
        }
    }
    best.1
}

pub(super) fn deliver(json: &str) -> Result<serde_json::Value, String> {
    let args: Args = serde_json::from_str(json).map_err(|e| e.to_string())?;
    if args.masters.is_empty() || !(0.0..=1.0).contains(&args.min_retained_area) {
        return Err("delivery needs masters and a retained-area fraction between 0 and 1".into());
    }
    let per_filter = match args.scale.as_deref().map(str::trim).unwrap_or("") {
        "" | "adu" => false,
        "perFilter" => true,
        other => {
            return Err(format!(
                "unknown scale '{other}'; expected adu or perFilter"
            ))
        }
    };
    let mut loaded = Vec::new();
    let mut mask = Vec::new();
    let mut geometry = (0, 0, 0);
    let mut grid = String::new();
    let mut filters = std::collections::HashSet::new();
    for input in &args.masters {
        if input.filter.is_empty()
            || !input
                .filter
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
            || !filters.insert(&input.filter)
        {
            return Err("each delivery filter must have a unique filename-safe label".into());
        }
        let header = read_fits_header(Path::new(&input.path)).map_err(|e| e.to_string())?;
        let (coverage, coverage_header) =
            read_fits(Path::new(&input.coverage_path)).map_err(|e| e.to_string())?;
        let size = (
            header.get_int("NAXIS1").unwrap_or(0) as u32,
            header.get_int("NAXIS2").unwrap_or(0) as u32,
            header.get_int("NAXIS3").unwrap_or(1).max(1) as u32,
        );
        let reference = header.get_string("GRIDREF").unwrap_or_default().to_string();
        let count = header.get_int("NFRAMES").unwrap_or(0);
        if count <= 0
            || reference.is_empty()
            || coverage_header.get_int("NFRAMES") != Some(count)
            || coverage_header.get_string("GRIDREF").unwrap_or_default() != reference
            || (coverage.width, coverage.height, coverage.channels) != size
        {
            return Err(format!(
                "{} has missing or mismatched geometric coverage",
                input.filter
            ));
        }
        if loaded.is_empty() {
            geometry = size;
            grid = reference.clone();
            mask = vec![true; (size.0 * size.1) as usize];
        } else if size != geometry || reference != grid {
            return Err(
                "masters must be built on the same reference grid before common cropping".into(),
            );
        }
        let counts = image_to_f64(&coverage);
        for (i, values) in counts.chunks(size.2 as usize).enumerate() {
            mask[i] &= values.iter().all(|&v| v == count as f64);
        }
        loaded.push(header);
    }
    let (width, height, channels) = geometry;
    let crop = rectangle(&mask, width as usize, height as usize)
        .ok_or("No rectangle is covered by every exposure. Exclude shifted frames and rebuild.")?;
    let [x0, y0, x1, y1] = crop;
    let (cw, ch) = (x1 - x0, y1 - y0);
    let fraction = (cw * ch) as f64 / (width as f64 * height as f64);
    if fraction < args.min_retained_area {
        return Err(format!("Only {:.1}% of the field has full shared coverage. Exclude shifted frames or tighten minimum overlap and rebuild.", fraction * 100.0));
    }
    let out = Path::new(&args.output_dir);
    std::fs::create_dir_all(out).map_err(|e| e.to_string())?;
    for input in &args.masters {
        for ext in ["fits", "png"] {
            let path = out.join(format!("{}_master_linear.{ext}", input.filter));
            if path.exists() {
                return Err(format!("output already exists: {}", path.display()));
            }
        }
    }
    let mut results = Vec::new();
    // Cropped mono planes by color role, for the composites.
    let mut planes: std::collections::HashMap<&'static str, (Vec<f32>, FitsHeader)> =
        std::collections::HashMap::new();
    for (input, mut header) in args.masters.iter().zip(loaded) {
        let (image, _) = read_fits(Path::new(&input.path)).map_err(|e| e.to_string())?;
        let pixels = image_to_f64(&image);
        drop(image);
        let c = channels as usize;
        let mut cropped = Vec::with_capacity(cw * ch * c);
        for y in y0..y1 {
            let start = (y * width as usize + x0) * c;
            cropped.extend_from_slice(&pixels[start..start + cw * c]);
        }
        drop(pixels);
        let (offset, divisor) = if per_filter {
            let low = cropped.iter().copied().fold(f64::INFINITY, f64::min);
            let high = cropped.iter().copied().fold(f64::NEG_INFINITY, f64::max);
            if !(low.is_finite() && high > low) {
                return Err(format!("{} has no usable range", input.filter));
            }
            (low, high - low)
        } else {
            (0.0, ADU_FULL_SCALE)
        };
        let samples: Vec<f32> = cropped
            .iter()
            .map(|&v| ((v - offset) / divisor) as f32)
            .collect();
        if samples.iter().any(|v| !v.is_finite()) {
            return Err(format!("{} contains non-finite pixels", input.filter));
        }
        for (key, origin) in [("CRPIX1", x0), ("CRPIX2", y0)] {
            if let Some(value) = header.get_float(key) {
                header.set_float(key, value - origin as f64);
            }
        }
        header.add_history(&format!(
            "Common full-coverage crop x={x0}..{x1}, y={y0}..{y1}"
        ));
        if per_filter {
            header.set_float("SKLOW", offset);
            header.set_float("SKHIGH", offset + divisor);
            header.add_history(&format!(
                "Linear samples = (ADU - {offset}) / {divisor}, this filter's own range"
            ));
        } else {
            header.set_float("SKSCALE", ADU_FULL_SCALE);
            header.add_history(&format!(
                "Linear samples = ADU / {ADU_FULL_SCALE}; no offset, clipping or stretch"
            ));
        }
        let path = out.join(format!("{}_master_linear.fits", input.filter));
        let preview = out.join(format!("{}_master_linear.png", input.filter));
        let image = ImageData::from_f32(cw as u32, ch as u32, channels, &samples);
        write_fits(&path, &image, &header).map_err(|e| e.to_string())?;
        write_preview_png(&image, &preview)?;
        results.push(serde_json::json!({"filter":input.filter,"path":path,"previewPath":preview,"channels":channels}));
        if channels == 1 {
            let named = header
                .get_string("FILTER")
                .map(str::to_string)
                .unwrap_or_else(|| input.filter.clone());
            let role = match skotiq_imaging::color_composite::classify_filter(Some(&named), 1) {
                skotiq_imaging::color_composite::FilterRole::Luminance => Some("L"),
                skotiq_imaging::color_composite::FilterRole::Red => Some("R"),
                skotiq_imaging::color_composite::FilterRole::Green => Some("G"),
                skotiq_imaging::color_composite::FilterRole::Blue => Some("B"),
                _ => None,
            };
            if let Some(role) = role.filter(|_| args.composites) {
                planes.entry(role).or_insert((samples, header));
            }
        }
    }
    let composites = if args.composites {
        write_composites(out, &planes, cw as u32, ch as u32, per_filter)?
    } else {
        serde_json::Value::Null
    };
    Ok(serde_json::json!({
        "masters":results,"crop":crop,"width":cw,"height":ch,"retainedArea":fraction,
        "scale": if per_filter { "perFilter" } else { "adu" },
        "composites": composites,
    }))
}

/// Header for a composite: the optics, site and WCS of one of its masters.
fn composite_header(source: &FitsHeader, history: &[&str]) -> FitsHeader {
    let mut header = FitsHeader::new();
    copy_optics_cards(&mut header, source);
    copy_wcs(&mut header, source);
    for key in ["OBJECT", "GRIDREF"] {
        if let Some(v) = source.get_string(key) {
            header.set_string(key, v);
        }
    }
    header.set_string("COLORSPC", "RGB");
    for line in history {
        header.add_history(line);
    }
    header
}

fn write_rgb(
    path_stem: &Path,
    rgb: &[f32],
    width: u32,
    height: u32,
    header: &FitsHeader,
) -> Result<(String, String, String), String> {
    let image = ImageData::from_f32(width, height, 3, rgb);
    let fits = path_stem.with_extension("fits");
    let xisf = path_stem.with_extension("xisf");
    write_fits(&fits, &image, header)
        .map_err(|e| format!("failed to write '{}': {e:?}", fits.display()))?;
    let metadata = skotiq_imaging::XisfMetadata {
        fits_keywords: header
            .keywords
            .iter()
            .map(|(k, v)| (k.clone(), v.to_header_string()))
            .collect(),
        ..Default::default()
    };
    skotiq_imaging::write_xisf(&xisf, &image, &metadata)
        .map_err(|e| format!("failed to write '{}': {e:?}", xisf.display()))?;
    // The stretched thumbnail the master library shows for the composite,
    // each channel auto-stretched on its own as PixInsight's STF does.
    let png = path_stem.with_extension("png");
    write_preview_png_with_mode(&image, &png, RgbStretchMode::Unlinked)?;
    Ok((
        fits.to_string_lossy().to_string(),
        xisf.to_string_lossy().to_string(),
        png.to_string_lossy().to_string(),
    ))
}

/// The planar RGB composite of the R, G and B masters and, with an L master,
/// a linear LRGB composite, as FITS and XISF. Linear, no color calibration or
/// background extraction.
///
/// The LRGB composite keeps each pixel's color ratios from RGB and takes its
/// brightness from L: `c' = L · c̃ / Ỹ`, where `c̃` is the channel averaged over
/// 3×3 pixels and `Ỹ` the mean of the three. Pixels where `Ỹ` is within the
/// RGB noise of zero take L in every channel, so the ratio never divides noise
/// by noise.
fn write_composites(
    out: &Path,
    planes: &std::collections::HashMap<&'static str, (Vec<f32>, FitsHeader)>,
    width: u32,
    height: u32,
    per_filter: bool,
) -> Result<serde_json::Value, String> {
    let (Some((r, rh)), Some((g, _)), Some((b, _))) =
        (planes.get("R"), planes.get("G"), planes.get("B"))
    else {
        return Ok(serde_json::Value::Null);
    };
    let n = r.len();
    let mut rgb = Vec::with_capacity(n * 3);
    for i in 0..n {
        rgb.extend_from_slice(&[r[i], g[i], b[i]]);
    }
    let scale_note = if per_filter {
        "Channels keep each filter's own 0..1 scaling; color ratios are not physical"
    } else {
        "Channels are ADU / 65535 of each master; no color calibration or background extraction"
    };
    let header = composite_header(
        rh,
        &[
            "Planes 1, 2, 3 are the R, G and B masters on the common crop",
            scale_note,
        ],
    );
    let (rgb_fits, rgb_xisf, rgb_png) =
        write_rgb(&out.join("RGB_linear"), &rgb, width, height, &header)?;
    let mut result = serde_json::json!({
        "rgbPath": rgb_fits,
        "rgbXisfPath": rgb_xisf,
        "rgbPreviewPath": rgb_png,
    });

    if let Some((l, lh)) = planes.get("L") {
        let (w, h) = (width as usize, height as usize);
        let smooth = |plane: &[f32]| -> Vec<f32> {
            (0..w * h)
                .into_par_iter()
                .map(|i| {
                    let (x, y) = (i % w, i / w);
                    let (mut sum, mut count) = (0.0f32, 0.0f32);
                    for yy in y.saturating_sub(1)..(y + 2).min(h) {
                        for xx in x.saturating_sub(1)..(x + 2).min(w) {
                            sum += plane[yy * w + xx];
                            count += 1.0;
                        }
                    }
                    sum / count
                })
                .collect()
        };
        let (rs, gs, bs) = (smooth(r), smooth(g), smooth(b));
        let luma: Vec<f32> = (0..n).map(|i| (rs[i] + gs[i] + bs[i]) / 3.0).collect();
        // The RGB noise floor: robust sigma of the smoothed luminance's
        // neighbor differences.
        let mut diffs: Vec<f32> = luma
            .windows(2)
            .step_by(7)
            .map(|p| (p[1] - p[0]).abs())
            .collect();
        let floor = if diffs.is_empty() {
            0.0
        } else {
            let mid = diffs.len() / 2;
            3.0 * 1.4826 * *diffs.select_nth_unstable_by(mid, f32::total_cmp).1
                / std::f32::consts::SQRT_2
        };
        let mut lrgb = Vec::with_capacity(n * 3);
        for i in 0..n {
            if luma[i] > floor && luma[i] > 0.0 {
                let k = l[i] / luma[i];
                lrgb.extend_from_slice(&[rs[i] * k, gs[i] * k, bs[i] * k]);
            } else {
                lrgb.extend_from_slice(&[l[i], l[i], l[i]]);
            }
        }
        let header = composite_header(
            lh,
            &[
                "Linear LRGB: brightness from the L master, color ratios from RGB averaged over 3x3 pixels",
                scale_note,
            ],
        );
        let (fits, xisf, png) = write_rgb(&out.join("LRGB_linear"), &lrgb, width, height, &header)?;
        result["lrgbPath"] = serde_json::json!(fits);
        result["lrgbXisfPath"] = serde_json::json!(xisf);
        result["lrgbPreviewPath"] = serde_json::json!(png);
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rectangle_never_includes_partial_coverage() {
        let mask = [
            false, true, true, true, false, true, true, true, false, true, true, false,
        ];
        let r = rectangle(&mask, 4, 3).unwrap();
        assert_eq!((r[2] - r[0]) * (r[3] - r[1]), 6);
        for y in r[1]..r[3] {
            for x in r[0]..r[2] {
                assert!(mask[y * 4 + x]);
            }
        }
        assert_eq!(rectangle(&[false; 12], 4, 3), None);
    }

    /// A linear composite with a strong color cast (blue sky glow far above
    /// red and green) previews with every channel's background lifted into
    /// the STF's target range, not two black channels and a blue one.
    #[test]
    fn a_linear_composite_previews_auto_stretched_per_channel() {
        let dir = tempfile::tempdir().expect("temp dir");
        let (w, h) = (96u32, 64u32);
        let mut seed = 7u32;
        let mut noise = || {
            seed = seed.wrapping_mul(1_103_515_245).wrapping_add(12_345);
            ((seed >> 16) & 0x7fff) as f32 / 32_768.0 - 0.5
        };
        let background = [0.004f32, 0.006, 0.03];
        let mut rgb = Vec::with_capacity((w * h * 3) as usize);
        for i in 0..(w * h) {
            let star = i % 397 == 0;
            for level in background {
                let v = level * (1.0 + 0.1 * noise());
                rgb.push(if star { 0.9 } else { v });
            }
        }
        let header = FitsHeader::default();
        let (_, _, png) = write_rgb(&dir.path().join("RGB_linear"), &rgb, w, h, &header)
            .expect("composite written");
        let preview = image::open(&png).expect("preview").to_rgb8();
        for c in 0..3 {
            let mut values: Vec<u8> = preview.pixels().map(|p| p.0[c]).collect();
            values.sort_unstable();
            let median = values[values.len() / 2] as f32 / 255.0;
            assert!(
                (0.12..=0.45).contains(&median),
                "channel {c} preview median {median} is outside the auto-stretch range"
            );
        }
    }
}
