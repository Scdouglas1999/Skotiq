//! Export masters on one grid, cropped to full exposure support in every lane.
use super::*;

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
}
fn minimum_area() -> f64 {
    0.8
}

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
    let mut loaded = Vec::new();
    let mut mask = Vec::new();
    let mut geometry = (0, 0, 0);
    let mut grid = String::new();
    let mut low = 0.0_f64;
    let mut high = 1.0_f64;
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
        let (image, header) = read_fits(Path::new(&input.path)).map_err(|e| e.to_string())?;
        let (coverage, coverage_header) =
            read_fits(Path::new(&input.coverage_path)).map_err(|e| e.to_string())?;
        let size = (image.width, image.height, image.channels);
        let reference = header.get_string("GRIDREF").unwrap_or_default();
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
            grid = reference.to_string();
            mask = vec![true; (image.width * image.height) as usize];
        } else if size != geometry || reference != grid {
            return Err(
                "masters must be built on the same reference grid before common cropping".into(),
            );
        }
        let pixels = image_to_f64(&image);
        if pixels.iter().any(|v| !v.is_finite()) {
            return Err(format!("{} contains non-finite pixels", input.filter));
        }
        for &value in &pixels {
            low = low.min(value);
            high = high.max(value);
        }
        let counts = image_to_f64(&coverage);
        for (i, values) in counts.chunks(image.channels as usize).enumerate() {
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
    for (input, mut header) in args.masters.iter().zip(loaded) {
        let (image, _) = read_fits(Path::new(&input.path)).map_err(|e| e.to_string())?;
        let pixels = image_to_f64(&image);
        drop(image);
        let path = out.join(format!("{}_master_linear.fits", input.filter));
        let preview = out.join(format!("{}_master_linear.png", input.filter));
        let mut cropped = Vec::with_capacity(cw * ch * channels as usize);
        for y in y0..y1 {
            let start = (y * width as usize + x0) * channels as usize;
            cropped.extend(
                pixels[start..start + cw * channels as usize]
                    .iter()
                    .map(|&v| ((v - low) / (high - low)) as f32),
            );
        }
        for (key, offset) in [("CRPIX1", x0), ("CRPIX2", y0)] {
            if let Some(value) = header.get_float(key) {
                header.set_float(key, value - offset as f64);
            }
        }
        header.set_float("SKLOW", low);
        header.set_float("SKHIGH", high);
        header.add_history(&format!(
            "Common full-coverage crop x={x0}..{x1}, y={y0}..{y1}"
        ));
        header.add_history(&format!(
            "Linear samples = (ADU - {low}) / ({}); no clipping or stretch",
            high - low
        ));
        let image = ImageData::from_f32(cw as u32, ch as u32, channels, &cropped);
        write_fits(&path, &image, &header).map_err(|e| e.to_string())?;
        write_preview_png(&image, &preview)?;
        results.push(serde_json::json!({"filter":input.filter,"path":path,"previewPath":preview,"channels":channels}));
    }
    Ok(
        serde_json::json!({"masters":results,"crop":crop,"width":cw,"height":ch,"retainedArea":fraction,"linearRange":[low,high]}),
    )
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
}
