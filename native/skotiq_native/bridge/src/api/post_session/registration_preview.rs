//! Registration pre-pass: where every selected light lands on the grid, and
//! the common crop that geometry allows, before anything is integrated.
//!
//! Each light is registered onto the grid reference from its stars alone
//! (detect and match, no warp), so the pass costs a fraction of a build. A
//! light's footprint is the part of the grid its resampling kernel fully
//! supports: the source rectangle shrunk by the kernel's reach, mapped
//! forward. The common crop is the largest axis-aligned rectangle inside every
//! footprint. Footprints are convex, so their intersection is computed exactly
//! by clipping, and every edge of it records the frame that put it there; those
//! frames are the ones that limit the crop.
//!
//! Stars are detected on the raw lights. Calibration changes pixel values, not
//! where stars are, so the transforms match the build's.

use super::*;
use rayon::prelude::*;
use skotiq_imaging::registration::solve_registration;
use std::sync::atomic::{AtomicU32, Ordering};

/// Lights registered at once. Each holds one full frame plus its detection
/// buffers, so this bounds the pass's memory.
const MAX_PARALLEL_FRAMES: usize = 4;

/// Frames on the crop's boundary that are re-evaluated by leaving them out.
const MAX_LIMITING_CANDIDATES: usize = 32;

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct PreviewReference {
    pub(crate) path: String,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct PreviewLight {
    pub(crate) path: String,
    /// Side of the pier when it was captured, as recorded (`East`/`West`).
    pub(crate) side: Option<String>,
    /// The outcome of an earlier pass over this light. Supplied, it is reused
    /// instead of registering the light again, so excluding frames re-evaluates
    /// the crop at once.
    pub(crate) known: Option<KnownFootprint>,
}

/// A light's registration from an earlier pass: its footprint, or the reason
/// it could not be registered.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct KnownFootprint {
    pub(crate) corners: Option<[[f64; 2]; 4]>,
    pub(crate) rotation_deg: Option<f64>,
    pub(crate) shift_px: Option<[f64; 2]>,
    pub(crate) stars_matched: Option<usize>,
    pub(crate) rms_px: Option<f64>,
    pub(crate) failure: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct PreviewGroup {
    pub(crate) label: String,
    pub(crate) lights: Vec<PreviewLight>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct PreviewSettings {
    pub(crate) align: AlignArgs,
}

/// Request for `op: "registrationPreview"`.
#[derive(Debug, Clone, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct RegistrationPreviewArgs {
    pub(crate) run_id: String,
    pub(crate) grid_reference: PreviewReference,
    pub(crate) groups: Vec<PreviewGroup>,
    pub(crate) settings: PreviewSettings,
    /// `[width, height]` of the grid. Needed only when every light is known,
    /// so the reference need not be read.
    pub(crate) grid_size: Option<[u32; 2]>,
    /// A light covering less of the grid than this is left out of the build.
    pub(crate) min_overlap: f64,
    /// Smallest crop, as a fraction of the grid, the build accepts.
    pub(crate) min_retained_area: f64,
}

impl Default for RegistrationPreviewArgs {
    fn default() -> Self {
        Self {
            run_id: String::new(),
            grid_reference: PreviewReference::default(),
            groups: Vec::new(),
            settings: PreviewSettings::default(),
            grid_size: None,
            min_overlap: 0.95,
            min_retained_area: 0.8,
        }
    }
}

/// Where one light lands, or why it does not.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct FrameFootprint {
    pub(crate) path: String,
    pub(crate) group: String,
    pub(crate) side: Option<String>,
    /// Corners of the fully supported footprint on the grid, in order.
    pub(crate) corners: Option<[[f64; 2]; 4]>,
    /// Fraction of the grid the footprint covers.
    pub(crate) overlap: Option<f64>,
    pub(crate) rotation_deg: Option<f64>,
    pub(crate) shift_px: Option<[f64; 2]>,
    pub(crate) stars_matched: Option<usize>,
    pub(crate) rms_px: Option<f64>,
    /// Why it could not be registered; absent when it was.
    pub(crate) failure: Option<String>,
    /// `true` when the build would include it: registered and within the
    /// overlap limit.
    pub(crate) included: bool,
    /// Why it is not included.
    pub(crate) reason: Option<String>,
}

/// A frame whose footprint bounds the common crop.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct LimitingFrame {
    pub(crate) path: String,
    pub(crate) group: String,
    /// Retained fraction of the grid if this frame alone is excluded.
    pub(crate) retained_without: f64,
}

/// Response for `op: "registrationPreview"`.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct RegistrationPreviewResult {
    pub(crate) width: u32,
    pub(crate) height: u32,
    pub(crate) frames: Vec<FrameFootprint>,
    /// `[x0, y0, x1, y1]`, end-exclusive, in grid pixels; absent when no
    /// pixel is covered by every included frame.
    pub(crate) crop: Option<[usize; 4]>,
    pub(crate) retained_area: f64,
    pub(crate) min_retained_area: f64,
    pub(crate) meets_minimum: bool,
    /// Largest gain first.
    pub(crate) limiting: Vec<LimitingFrame>,
}

/// What bounds one edge of a clipped footprint.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum EdgeSource {
    Grid,
    Frame(usize),
}

/// A polygon vertex and the source of the edge from it to the next vertex.
#[derive(Debug, Clone, Copy)]
struct Vertex {
    x: f64,
    y: f64,
    edge: EdgeSource,
}

fn signed_area(points: &[[f64; 2]]) -> f64 {
    let n = points.len();
    (0..n)
        .map(|i| {
            let [x0, y0] = points[i];
            let [x1, y1] = points[(i + 1) % n];
            x0 * y1 - x1 * y0
        })
        .sum::<f64>()
        / 2.0
}

/// `points` in positive orientation.
fn oriented(mut points: Vec<[f64; 2]>) -> Vec<[f64; 2]> {
    if signed_area(&points) < 0.0 {
        points.reverse();
    }
    points
}

/// The grid's pixel centers, `[0, w-1] × [0, h-1]`, as a polygon.
fn grid_polygon(width: u32, height: u32) -> Vec<Vertex> {
    let (w, h) = (
        (width as f64 - 1.0).max(0.0),
        (height as f64 - 1.0).max(0.0),
    );
    oriented(vec![[0.0, 0.0], [w, 0.0], [w, h], [0.0, h]])
        .into_iter()
        .map(|[x, y]| Vertex {
            x,
            y,
            edge: EdgeSource::Grid,
        })
        .collect()
}

/// Clip a positively oriented convex polygon to the left of `a → b`, labeling
/// edges that run along the clip line with `source`.
fn clip(polygon: &[Vertex], a: [f64; 2], b: [f64; 2], source: EdgeSource) -> Vec<Vertex> {
    let side = |v: &Vertex| (b[0] - a[0]) * (v.y - a[1]) - (b[1] - a[1]) * (v.x - a[0]);
    let mut out = Vec::with_capacity(polygon.len() + 1);
    let n = polygon.len();
    for i in 0..n {
        let current = polygon[i];
        let next = polygon[(i + 1) % n];
        let (sc, sn) = (side(&current), side(&next));
        let crossing = || {
            let t = sc / (sc - sn);
            (
                current.x + t * (next.x - current.x),
                current.y + t * (next.y - current.y),
            )
        };
        match (sc >= 0.0, sn >= 0.0) {
            (true, true) => out.push(current),
            (true, false) => {
                out.push(current);
                let (x, y) = crossing();
                out.push(Vertex { x, y, edge: source });
            }
            (false, true) => {
                let (x, y) = crossing();
                out.push(Vertex {
                    x,
                    y,
                    edge: current.edge,
                });
            }
            (false, false) => {}
        }
    }
    out
}

/// Intersection of the grid with every footprint in `quads` (each positively
/// oriented), skipping index `skip`.
fn intersect(
    width: u32,
    height: u32,
    quads: &[(usize, Vec<[f64; 2]>)],
    skip: Option<usize>,
) -> Vec<Vertex> {
    let mut polygon = grid_polygon(width, height);
    for (index, quad) in quads {
        if Some(*index) == skip {
            continue;
        }
        for i in 0..quad.len() {
            polygon = clip(
                &polygon,
                quad[i],
                quad[(i + 1) % quad.len()],
                EdgeSource::Frame(*index),
            );
            if polygon.len() < 3 {
                return Vec::new();
            }
        }
    }
    polygon
}

/// Inclusive pixel columns of a convex polygon on each pixel row, starting at
/// the returned first row.
fn row_spans(polygon: &[Vertex]) -> (i64, Vec<Option<(i64, i64)>>) {
    if polygon.len() < 3 {
        return (0, Vec::new());
    }
    const EPS: f64 = 1e-9;
    let y_min = polygon.iter().map(|v| v.y).fold(f64::INFINITY, f64::min);
    let y_max = polygon
        .iter()
        .map(|v| v.y)
        .fold(f64::NEG_INFINITY, f64::max);
    let (first, last) = ((y_min - EPS).ceil() as i64, (y_max + EPS).floor() as i64);
    let n = polygon.len();
    let spans = (first..=last)
        .map(|row| {
            let y = row as f64;
            let mut low = f64::INFINITY;
            let mut high = f64::NEG_INFINITY;
            for i in 0..n {
                let (p, q) = (polygon[i], polygon[(i + 1) % n]);
                let (lo, hi) = if p.y <= q.y { (p, q) } else { (q, p) };
                if y < lo.y - EPS || y > hi.y + EPS {
                    continue;
                }
                let x = if (hi.y - lo.y).abs() < EPS {
                    low = low.min(lo.x.min(hi.x));
                    high = high.max(lo.x.max(hi.x));
                    continue;
                } else {
                    lo.x + (y - lo.y) / (hi.y - lo.y) * (hi.x - lo.x)
                };
                low = low.min(x);
                high = high.max(x);
            }
            let (a, b) = ((low - EPS).ceil() as i64, (high + EPS).floor() as i64);
            (low.is_finite() && a <= b).then_some((a, b))
        })
        .collect();
    (first, spans)
}

fn covered_pixels(polygon: &[Vertex]) -> u64 {
    row_spans(polygon)
        .1
        .iter()
        .flatten()
        .map(|(a, b)| (b - a + 1) as u64)
        .sum()
}

/// Largest axis-aligned rectangle of whole pixels inside a convex polygon:
/// `[x0, y0, x1, y1]`, end-exclusive.
fn largest_rectangle(polygon: &[Vertex]) -> Option<[usize; 4]> {
    let (first, spans) = row_spans(polygon);
    let mut best: Option<(i64, [i64; 4])> = None;
    for top in 0..spans.len() {
        let Some((mut low, mut high)) = spans[top] else {
            continue;
        };
        for (bottom, span) in spans.iter().enumerate().skip(top) {
            let Some((a, b)) = span else { break };
            low = low.max(*a);
            high = high.min(*b);
            if low > high {
                break;
            }
            let rows = (bottom - top + 1) as i64;
            let area = rows * (high - low + 1);
            if best.is_none_or(|(value, _)| area > value) {
                best = Some((
                    area,
                    [low, first + top as i64, high + 1, first + bottom as i64 + 1],
                ));
            }
            if (spans.len() - top) as i64 * (high - low + 1) <= best.map_or(0, |b| b.0) {
                break;
            }
        }
    }
    best.and_then(|(_, r)| r.iter().all(|v| *v >= 0).then(|| r.map(|v| v as usize)))
}

fn retained(rect: Option<[usize; 4]>, width: u32, height: u32) -> f64 {
    rect.map_or(0.0, |[x0, y0, x1, y1]| {
        ((x1 - x0) * (y1 - y0)) as f64 / (width as f64 * height as f64)
    })
}

/// The part of the source a kernel of `reach` taps on each side fully
/// supports, as corners in source pixels.
fn supported_source(width: u32, height: u32, interpolator: Interpolator) -> [[f64; 2]; 4] {
    let reach = match interpolator {
        Interpolator::Bilinear => 1.0,
        Interpolator::CatmullRom => 2.0,
        Interpolator::Lanczos3 => 3.0,
    };
    let (x0, y0) = (reach - 1.0, reach - 1.0);
    let (x1, y1) = (width as f64 - 1.0 - reach, height as f64 - 1.0 - reach);
    [[x0, y0], [x1, y0], [x1, y1], [x0, y1]]
}

struct Registered {
    corners: [[f64; 2]; 4],
    rotation_deg: Option<f64>,
    shift_px: Option<[f64; 2]>,
    stars_matched: Option<usize>,
    rms_px: Option<f64>,
}

impl KnownFootprint {
    fn outcome(&self) -> Option<Result<Registered, String>> {
        if let Some(reason) = &self.failure {
            return Some(Err(reason.clone()));
        }
        let corners = self.corners?;
        corners.iter().flatten().all(|v| v.is_finite()).then(|| {
            Ok(Registered {
                corners,
                rotation_deg: self.rotation_deg,
                shift_px: self.shift_px,
                stars_matched: self.stars_matched,
                rms_px: self.rms_px,
            })
        })
    }
}

fn register_light(
    reference: &ImageData,
    path: &str,
    config: &RegistrationConfig,
) -> Result<Registered, String> {
    let image = read_image(Path::new(path))
        .map_err(|e| format!("cannot be read: {e}"))?
        .image;
    if image.width != reference.width
        || image.height != reference.height
        || image.channels != reference.channels
    {
        return Err(format!(
            "is {}×{}×{}, the grid is {}×{}×{}",
            image.width,
            image.height,
            image.channels,
            reference.width,
            reference.height,
            reference.channels
        ));
    }
    let (transform, stats) =
        solve_registration(reference, &image, config).map_err(|e| e.to_string())?;
    let corners = supported_source(image.width, image.height, config.interpolator).map(|[x, y]| {
        let (gx, gy) = transform.apply(x, y);
        [gx, gy]
    });
    if corners.iter().flatten().any(|v| !v.is_finite()) {
        return Err("its fitted transform is degenerate".into());
    }
    let m = transform.matrix;
    Ok(Registered {
        corners,
        rotation_deg: Some(m[1][0].atan2(m[0][0]).to_degrees()),
        shift_px: Some([m[0][2], m[1][2]]),
        stars_matched: Some(stats.inlier_count),
        rms_px: Some(stats.rms_residual_px),
    })
}

/// Run the pre-pass.
pub(crate) fn registration_preview(args_json: &str) -> Result<RegistrationPreviewResult, String> {
    let args: RegistrationPreviewArgs = serde_json::from_str(args_json)
        .map_err(|e| format!("invalid registration preview args: {e}"))?;
    if args.grid_reference.path.trim().is_empty() {
        return Err("the pre-pass needs gridReference.path".into());
    }
    if !(0.0..=1.0).contains(&args.min_overlap) || !(0.0..=1.0).contains(&args.min_retained_area) {
        return Err("overlap and retained-area limits must be between 0 and 1".into());
    }
    let lights: Vec<(&PreviewGroup, &PreviewLight)> = args
        .groups
        .iter()
        .flat_map(|g| g.lights.iter().map(move |l| (g, l)))
        .collect();
    if lights.is_empty() {
        return Err("the pre-pass needs at least one light".into());
    }
    let total = lights.len() as u32;
    let cancel = RunCancelToken::register(&args.run_id)?;
    let config = build_registration_config(&args.settings.align)?;
    let known: Vec<Option<Result<Registered, String>>> = lights
        .iter()
        .map(|(_, l)| l.known.as_ref().and_then(KnownFootprint::outcome))
        .collect();
    let reference = match (known.iter().all(Option::is_some), args.grid_size) {
        (true, Some(_)) => None,
        _ => Some(
            read_image(Path::new(args.grid_reference.path.trim()))
                .map_err(|e| format!("the grid reference cannot be read: {e}"))?
                .image,
        ),
    };
    let (width, height) = match (&reference, args.grid_size) {
        (Some(r), _) => (r.width, r.height),
        (None, Some([w, h])) => (w, h),
        (None, None) => unreachable!("the reference is read unless the grid size is given"),
    };
    if width == 0 || height == 0 {
        return Err("the grid has no pixels".into());
    }
    let grid_pixels = width as f64 * height as f64;

    let done = AtomicU32::new(0);
    emit_integration_progress("framing", 0.0, Some(0), Some(total));
    let pool = rayon::ThreadPoolBuilder::new()
        .num_threads(MAX_PARALLEL_FRAMES.min(rayon::current_num_threads()).max(1))
        .build()
        .map_err(|e| format!("cannot start the pre-pass workers: {e}"))?;
    let outcomes: Vec<Option<Result<Registered, String>>> = pool.install(|| {
        lights
            .par_iter()
            .zip(known.into_par_iter())
            .map(|((_, light), known)| {
                if cancel.is_cancelled() {
                    return None;
                }
                let outcome = match (known, &reference) {
                    (Some(outcome), _) => outcome,
                    (None, Some(reference)) => register_light(reference, &light.path, &config),
                    (None, None) => unreachable!("the reference is read when a light is unknown"),
                };
                let n = done.fetch_add(1, Ordering::Relaxed) + 1;
                emit_integration_progress("framing", n as f32 / total as f32, Some(n), Some(total));
                Some(outcome)
            })
            .collect()
    });
    cancel.check("framing", Some(done.load(Ordering::Relaxed)), Some(total))?;
    drop(reference);

    let mut frames = Vec::with_capacity(lights.len());
    let mut quads: Vec<(usize, Vec<[f64; 2]>)> = Vec::new();
    for (index, ((group, light), outcome)) in lights.iter().zip(outcomes).enumerate() {
        let mut frame = FrameFootprint {
            path: light.path.clone(),
            group: group.label.clone(),
            side: light.side.clone(),
            corners: None,
            overlap: None,
            rotation_deg: None,
            shift_px: None,
            stars_matched: None,
            rms_px: None,
            failure: None,
            included: false,
            reason: None,
        };
        match outcome.expect("every light ran unless cancelled") {
            Err(reason) => {
                frame.failure = Some(reason.clone());
                frame.reason = Some(reason);
            }
            Ok(registered) => {
                let quad = oriented(registered.corners.to_vec());
                let footprint = intersect(width, height, &[(index, quad.clone())], None);
                let overlap = covered_pixels(&footprint) as f64 / grid_pixels;
                frame.corners = Some(registered.corners);
                frame.overlap = Some(overlap);
                frame.rotation_deg = registered.rotation_deg;
                frame.shift_px = registered.shift_px;
                frame.stars_matched = registered.stars_matched;
                frame.rms_px = registered.rms_px;
                if overlap < args.min_overlap {
                    frame.reason = Some(format!(
                        "{:.1}% field overlap; need at least {:.1}%",
                        overlap * 100.0,
                        args.min_overlap * 100.0
                    ));
                } else {
                    frame.included = true;
                    quads.push((index, quad));
                }
            }
        }
        frames.push(frame);
    }

    let common = intersect(width, height, &quads, None);
    let crop = largest_rectangle(&common);
    let retained_area = retained(crop, width, height);
    let mut boundary: Vec<usize> = common
        .iter()
        .filter_map(|v| match v.edge {
            EdgeSource::Frame(i) => Some(i),
            EdgeSource::Grid => None,
        })
        .collect();
    boundary.sort_unstable();
    boundary.dedup();
    // The reference defines the grid and cannot be left out, so it is never
    // offered as a frame to exclude.
    let reference_path = args.grid_reference.path.trim();
    boundary.retain(|&i| frames[i].path.trim() != reference_path);
    if quads.len() <= 1 {
        boundary.clear();
    }
    let mut limiting: Vec<LimitingFrame> = boundary
        .into_iter()
        .take(MAX_LIMITING_CANDIDATES)
        .map(|i| {
            let without = largest_rectangle(&intersect(width, height, &quads, Some(i)));
            LimitingFrame {
                path: frames[i].path.clone(),
                group: frames[i].group.clone(),
                retained_without: retained(without, width, height),
            }
        })
        .filter(|f| f.retained_without > retained_area)
        .collect();
    limiting.sort_by(|a, b| b.retained_without.total_cmp(&a.retained_without));
    emit_integration_progress("framing", 1.0, Some(total), Some(total));

    Ok(RegistrationPreviewResult {
        width,
        height,
        frames,
        crop,
        retained_area,
        min_retained_area: args.min_retained_area,
        meets_minimum: crop.is_some() && retained_area >= args.min_retained_area,
        limiting,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn quad(points: [[f64; 2]; 4]) -> Vec<[f64; 2]> {
        oriented(points.to_vec())
    }

    fn shifted(w: f64, h: f64, dx: f64, dy: f64) -> Vec<[f64; 2]> {
        quad([
            [dx, dy],
            [w - 1.0 + dx, dy],
            [w - 1.0 + dx, h - 1.0 + dy],
            [dx, h - 1.0 + dy],
        ])
    }

    #[test]
    fn the_crop_of_shifted_frames_is_their_exact_overlap() {
        let quads = vec![
            (0, shifted(100.0, 80.0, 0.0, 0.0)),
            (1, shifted(100.0, 80.0, 10.0, -5.0)),
        ];
        let common = intersect(100, 80, &quads, None);
        assert_eq!(largest_rectangle(&common), Some([10, 0, 100, 75]));
        assert!((retained(Some([10, 0, 100, 75]), 100, 80) - 90.0 * 75.0 / 8000.0).abs() < 1e-12);
    }

    #[test]
    fn a_rotated_frame_limits_the_crop_and_is_named() {
        // Frame 2 is turned 3 degrees about the center; frames 0 and 1 are aligned.
        let (w, h) = (400.0_f64, 300.0_f64);
        let (cx, cy, a) = (w / 2.0, h / 2.0, 3f64.to_radians());
        let turn = |[x, y]: [f64; 2]| {
            let (dx, dy) = (x - cx, y - cy);
            [
                cx + dx * a.cos() - dy * a.sin(),
                cy + dx * a.sin() + dy * a.cos(),
            ]
        };
        let corners = [
            [0.0, 0.0],
            [w - 1.0, 0.0],
            [w - 1.0, h - 1.0],
            [0.0, h - 1.0],
        ];
        let quads = vec![
            (0, shifted(w, h, 0.0, 0.0)),
            (1, shifted(w, h, 2.0, 1.0)),
            (2, quad(corners.map(turn))),
        ];
        let common = intersect(400, 300, &quads, None);
        let with_all = retained(largest_rectangle(&common), 400, 300);
        let labels: Vec<_> = common.iter().map(|v| v.edge).collect();
        assert!(labels.contains(&EdgeSource::Frame(2)));
        let without = retained(
            largest_rectangle(&intersect(400, 300, &quads, Some(2))),
            400,
            300,
        );
        assert!(without > with_all + 0.05, "{without} vs {with_all}");
        // Every pixel of the crop lies inside every footprint.
        let [x0, y0, x1, y1] = largest_rectangle(&common).unwrap();
        for (_, q) in &quads {
            for (x, y) in [(x0, y0), (x1 - 1, y0), (x1 - 1, y1 - 1), (x0, y1 - 1)] {
                let p = Vertex {
                    x: x as f64,
                    y: y as f64,
                    edge: EdgeSource::Grid,
                };
                for i in 0..4 {
                    let (a, b) = (q[i], q[(i + 1) % 4]);
                    let side = (b[0] - a[0]) * (p.y - a[1]) - (b[1] - a[1]) * (p.x - a[0]);
                    assert!(side >= -1e-9);
                }
            }
        }
    }

    #[test]
    fn disjoint_frames_leave_no_crop() {
        let quads = vec![
            (0, shifted(100.0, 80.0, 0.0, 0.0)),
            (1, shifted(100.0, 80.0, 200.0, 0.0)),
        ];
        assert_eq!(largest_rectangle(&intersect(100, 80, &quads, None)), None);
    }

    #[test]
    fn lanczos_support_excludes_the_attenuated_border() {
        let [a, _, c, _] = supported_source(100, 80, Interpolator::Lanczos3);
        assert_eq!(a, [2.0, 2.0]);
        assert_eq!(c, [96.0, 76.0]);
        // An unshifted frame keeps a 2-pixel border on the low side and 3 on
        // the high side, as the kernel's taps reach.
        let quads = vec![(0, quad(supported_source(100, 80, Interpolator::Lanczos3)))];
        assert_eq!(
            largest_rectangle(&intersect(100, 80, &quads, None)),
            Some([2, 2, 97, 77])
        );
    }

    // End to end over synthetic star fields on disk.

    const W: u32 = 320;
    const H: u32 = 240;

    fn field(shift: (f64, f64), seed: u64) -> ImageData {
        let mut state = seed;
        let mut unit = || {
            state = state
                .wrapping_mul(6_364_136_223_846_793_005)
                .wrapping_add(1_442_695_040_888_963_407);
            ((state >> 11) as f64) / ((1u64 << 53) as f64)
        };
        let mut star_state = 0x5EEDu64;
        let mut star_unit = || {
            star_state = star_state
                .wrapping_mul(6_364_136_223_846_793_005)
                .wrapping_add(1_442_695_040_888_963_407);
            ((star_state >> 11) as f64) / ((1u64 << 53) as f64)
        };
        let stars: Vec<(f64, f64, f64)> = (0..90)
            .map(|_| {
                (
                    20.0 + star_unit() * (W as f64 - 40.0),
                    20.0 + star_unit() * (H as f64 - 40.0),
                    4_000.0 * 10f64.powf(star_unit() * 1.2),
                )
            })
            .collect();
        let mut px: Vec<f64> = (0..W * H).map(|_| 600.0 + 8.0 * (unit() - 0.5)).collect();
        let sigma = 1.6_f64;
        for (x, y, flux) in stars {
            let (sx, sy) = (x + shift.0, y + shift.1);
            let norm = flux / (2.0 * std::f64::consts::PI * sigma * sigma);
            for yy in (sy as i64 - 7)..=(sy as i64 + 7) {
                for xx in (sx as i64 - 7)..=(sx as i64 + 7) {
                    if xx < 0 || yy < 0 || xx >= W as i64 || yy >= H as i64 {
                        continue;
                    }
                    let r2 = (xx as f64 - sx).powi(2) + (yy as f64 - sy).powi(2);
                    px[yy as usize * W as usize + xx as usize] +=
                        norm * (-r2 / (2.0 * sigma * sigma)).exp();
                }
            }
        }
        let data: Vec<u16> = px
            .iter()
            .map(|v| v.round().clamp(0.0, 65535.0) as u16)
            .collect();
        ImageData::from_u16(W, H, 1, &data)
    }

    fn scratch() -> std::path::PathBuf {
        let n = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = std::env::temp_dir().join(format!("sk_rp_{}_{n}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn the_pre_pass_names_the_shifted_frame_and_the_unregistrable_one() {
        let dir = scratch();
        let mut paths = Vec::new();
        for (i, shift) in [(0.0, 0.0), (1.5, -1.0), (-2.0, 0.5), (48.0, 30.0)]
            .into_iter()
            .enumerate()
        {
            let path = dir.join(format!("light_{i}.fits"));
            write_fits(&path, &field(shift, 7 + i as u64), &FitsHeader::new()).unwrap();
            paths.push(path.to_string_lossy().to_string());
        }
        let blank = dir.join("blank.fits");
        write_fits(
            &blank,
            &ImageData::from_u16(W, H, 1, &vec![500u16; (W * H) as usize]),
            &FitsHeader::new(),
        )
        .unwrap();
        let request = serde_json::json!({
            "gridReference": {"path": paths[0]},
            "groups": [
                {"label": "Night 1", "lights": [{"path": paths[0], "side": "West"}, {"path": paths[1]}]},
                {"label": "Night 2", "lights": [{"path": paths[2]}, {"path": paths[3]}, {"path": blank.to_string_lossy()}]},
            ],
            "settings": {"align": {"model": "similarity"}},
            "minOverlap": 0.5,
            "minRetainedArea": 0.8,
        });
        let result = registration_preview(&request.to_string()).unwrap();
        std::fs::remove_dir_all(&dir).ok();

        // Excluding the limiting frame re-evaluates from the known footprints,
        // with the source files gone.
        let known = |i: usize| serde_json::to_value(&result.frames[i]).unwrap();
        let again = serde_json::json!({
            "gridReference": {"path": paths[0]},
            "gridSize": [W, H],
            "groups": [{"label": "All", "lights": [
                {"path": paths[0], "known": known(0)},
                {"path": paths[1], "known": known(1)},
                {"path": paths[2], "known": known(2)},
                {"path": blank.to_string_lossy(), "known": known(4)},
            ]}],
            "settings": {"align": {"model": "similarity"}},
            "minOverlap": 0.5,
            "minRetainedArea": 0.8,
        });
        let rerun = registration_preview(&again.to_string()).unwrap();
        assert!(rerun.meets_minimum, "{}", rerun.retained_area);
        assert!((rerun.retained_area - result.limiting[0].retained_without).abs() < 1e-12);
        assert_eq!(rerun.frames[3].failure, result.frames[4].failure);

        assert_eq!(result.frames.len(), 5);
        assert!(
            result.frames[..4].iter().all(|f| f.included),
            "{:?}",
            result.frames
        );
        assert!(!result.frames[4].included);
        assert!(result.frames[4].reason.is_some());
        let shift = result.frames[3].shift_px.unwrap();
        assert!(
            (shift[0] + 48.0).abs() < 0.5 && (shift[1] + 30.0).abs() < 0.5,
            "{shift:?}"
        );
        assert!(!result.meets_minimum, "{}", result.retained_area);
        assert_eq!(result.limiting[0].path, paths[3]);
        assert!(result.limiting.iter().all(|f| f.path != paths[0]));
        assert!(result.limiting[0].retained_without > 0.9);
        assert_eq!(result.frames[0].side.as_deref(), Some("West"));
    }
}
