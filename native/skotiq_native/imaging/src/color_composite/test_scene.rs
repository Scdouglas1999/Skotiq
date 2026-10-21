//! A synthetic star field imaged through several filters, each master on its
//! own geometry, for the composite tests.

use std::sync::Arc;

use super::align::Affine2;
use crate::fits::FitsHeader;
use crate::recipe::{ImagePyramid, OpImage};

/// A seeded generator, so every scene is the same on every run.
pub(crate) struct Lcg(u64);

impl Lcg {
    pub(crate) fn new(seed: u64) -> Self {
        Self(
            seed.wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407),
        )
    }

    pub(crate) fn unit(&mut self) -> f64 {
        self.0 = self
            .0
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        ((self.0 >> 11) as f64) / ((1u64 << 53) as f64)
    }

    /// A standard normal draw (Box–Muller).
    pub(crate) fn normal(&mut self) -> f64 {
        let u1 = self.unit().max(1e-12);
        let u2 = self.unit();
        (-2.0 * u1.ln()).sqrt() * (2.0 * std::f64::consts::PI * u2).cos()
    }
}

/// One star: its reference-frame position and its flux in red, green and blue.
#[derive(Debug, Clone, Copy)]
pub(crate) struct Star {
    pub(crate) x: f64,
    pub(crate) y: f64,
    pub(crate) rgb: [f64; 3],
}

/// The scene's stars, placed away from the edges.
pub(crate) fn stars(width: u32, height: u32, count: usize, seed: u64) -> Vec<Star> {
    let mut rng = Lcg::new(seed);
    (0..count)
        .map(|_| {
            let x = 24.0 + rng.unit() * (width as f64 - 48.0);
            let y = 24.0 + rng.unit() * (height as f64 - 48.0);
            let flux = 3_000.0 * (10f64).powf(rng.unit() * 1.6);
            // A color from red-ish to blue-ish, as field stars span.
            let t = rng.unit();
            let rgb = [flux * (1.3 - 0.6 * t), flux, flux * (0.6 + 0.7 * t)];
            Star { x, y, rgb }
        })
        .collect()
}

/// Render one master: every star's `weights`-weighted flux as a Gaussian PSF at
/// the position `to_reference` maps onto it, over `pedestal`, plus noise.
#[allow(clippy::too_many_arguments)]
pub(crate) fn render_master(
    width: u32,
    height: u32,
    stars: &[Star],
    weights: [f64; 3],
    to_reference: &Affine2,
    pedestal: f64,
    noise: f64,
    seed: u64,
) -> Vec<f32> {
    let from_reference = to_reference.inverse().expect("invertible");
    let sigma = 1.6_f64;
    let mut plane = vec![pedestal as f32; (width * height) as usize];
    let radius = 7i64;
    for star in stars {
        let (sx, sy) = from_reference.apply(star.x, star.y);
        let flux = weights[0] * star.rgb[0] + weights[1] * star.rgb[1] + weights[2] * star.rgb[2];
        let norm = flux / (2.0 * std::f64::consts::PI * sigma * sigma);
        let cx = sx.round() as i64;
        let cy = sy.round() as i64;
        for y in (cy - radius)..=(cy + radius) {
            for x in (cx - radius)..=(cx + radius) {
                if x < 0 || y < 0 || x >= width as i64 || y >= height as i64 {
                    continue;
                }
                let dx = x as f64 - sx;
                let dy = y as f64 - sy;
                let v = norm * (-(dx * dx + dy * dy) / (2.0 * sigma * sigma)).exp();
                plane[(y as u32 * width + x as u32) as usize] += v as f32;
            }
        }
    }
    let mut rng = Lcg::new(seed);
    for v in plane.iter_mut() {
        *v += (noise * rng.normal()) as f32;
    }
    plane
}

/// A mono `OpImage` from a plane.
pub(crate) fn mono(width: u32, height: u32, plane: Vec<f32>, filter: &str) -> OpImage {
    let mut header = FitsHeader::new();
    header.set_int("NAXIS", 2);
    header.set_int("NAXIS1", width as i64);
    header.set_int("NAXIS2", height as i64);
    header.set_string("FILTER", filter);
    OpImage::new(width, height, 1, plane, header).expect("valid image")
}

/// The pyramid of an image.
pub(crate) fn pyramid(image: OpImage) -> Arc<ImagePyramid> {
    Arc::new(ImagePyramid::build(Arc::new(image)).expect("pyramid"))
}

/// A similarity map: rotate by `degrees` about the frame centre, then shift.
pub(crate) fn similarity(degrees: f64, dx: f64, dy: f64, width: u32, height: u32) -> Affine2 {
    let (s, c) = degrees.to_radians().sin_cos();
    let cx = width as f64 / 2.0;
    let cy = height as f64 / 2.0;
    // x' = R (x − centre) + centre + shift
    Affine2 {
        m: [
            c,
            -s,
            cx - c * cx + s * cy + dx,
            s,
            c,
            cy - s * cx - c * cy + dy,
        ],
    }
}
