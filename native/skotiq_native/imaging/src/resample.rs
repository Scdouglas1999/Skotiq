//! Resampling: the interpolation kernels and the samplers built on them.
//!
//! Every warp in the crate that reads a source at fractional positions comes
//! here. The registration warp, the mosaic, the atlas fold and the difference
//! reprojection share [`Interpolator::taps`]; the live stack shares its
//! bilinear weights through [`Bilinear::edge_clamped`]; the PSF crop and the
//! chroma lattice share [`bilinear_clamped`]. The forms differ in edge rule and
//! in the order of their floating-point operations, and each caller keeps the
//! one its outputs were made with.

/// High-quality resampling kernels for the warp step.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Interpolator {
    /// 2×2 bilinear — fastest, softest; matches the rigid `LiveStacker` path.
    Bilinear,
    /// 4×4 Catmull-Rom cubic — sharp, no ringing, mild overshoot. A good
    /// default for noisy sub-frames where Lanczos ringing on bright stars is
    /// undesirable.
    CatmullRom,
    /// 6×6 windowed-sinc (Lanczos, `a = 3`) — sharpest reconstruction, the
    /// PixInsight default for high-SNR data; can ring around saturated stars.
    #[default]
    Lanczos3,
}

impl Interpolator {
    /// Half-width of the kernel: taps span `[-radius + 1, radius]` around the
    /// floor of the sample position.
    fn radius(self) -> i64 {
        match self {
            Interpolator::Bilinear => 1,
            Interpolator::CatmullRom => 2,
            Interpolator::Lanczos3 => 3,
        }
    }

    /// The floor `(x0, y0)` of a sample position as a column and row, when
    /// every tap around it lies inside a `w` × `h` frame. `None` for a NaN
    /// position; an infinite one saturates and fails the bounds.
    #[inline]
    fn support_origin(self, x0: f64, y0: f64, w: usize, h: usize) -> Option<(i64, i64)> {
        if x0.is_nan() || y0.is_nan() {
            return None;
        }
        let (ix, iy) = (x0 as i64, y0 as i64);
        let reach = self.radius();
        let inside = |i: i64, extent: usize| i >= reach - 1 && i <= extent as i64 - 1 - reach;
        (inside(ix, w) && inside(iy, h)).then_some((ix, iy))
    }

    /// The taps and weights of a sample at source position `(sx, sy)` in a
    /// `width` × `height` frame, or `None` when any tap falls outside it.
    ///
    /// There is no edge replication: a sample the frame cannot fully support is
    /// not produced, so a frame border never smears into a stack or a seam.
    #[inline]
    pub(crate) fn taps(self, sx: f64, sy: f64, width: usize, height: usize) -> Option<Taps> {
        let (x0, y0) = (sx.floor(), sy.floor());
        let (ix, iy) = self.support_origin(x0, y0, width, height)?;
        let (fx, fy) = (sx - x0, sy - y0);
        Some(match self {
            Interpolator::Bilinear => {
                let (ix, iy) = (ix as usize, iy as usize);
                Taps::Bilinear(Bilinear::new(ix, iy, ix + 1, iy + 1, fx, fy))
            }
            Interpolator::CatmullRom => separable(fx, fy, ix, iy, 2, catmull_rom),
            Interpolator::Lanczos3 => separable(fx, fy, ix, iy, 3, lanczos3),
        })
    }
}

/// The taps of a separable kernel of half-width `radius` at fractional offset
/// `(fx, fy)` from the floor `(x0, y0)`, whose support is inside the frame.
#[inline]
fn separable(fx: f64, fy: f64, x0: i64, y0: i64, radius: i64, kernel: impl Fn(f64) -> f64) -> Taps {
    let start = -(radius - 1);
    let n = (2 * radius) as usize;
    let mut wx = [0.0f64; 6];
    let mut wy = [0.0f64; 6];
    let mut sum_wx = 0.0;
    let mut sum_wy = 0.0;
    for t in 0..n {
        let offset = (start + t as i64) as f64;
        wx[t] = kernel(fx - offset);
        wy[t] = kernel(fy - offset);
        sum_wx += wx[t];
        sum_wy += wy[t];
    }
    // Both kernels sum to within a few percent of one at every fractional
    // offset; dividing by the sum keeps a flat field flat.
    Taps::Separable(Separable {
        x0: (x0 + start) as usize,
        y0: (y0 + start) as usize,
        n,
        wx,
        wy,
        norm: sum_wx * sum_wy,
    })
}

/// Whether every tap of `interp` around source position `(sx, sy)` lies inside
/// a `w` × `h` frame.
pub fn kernel_inside(sx: f64, sy: f64, w: usize, h: usize, interp: Interpolator) -> bool {
    interp
        .support_origin(sx.floor(), sy.floor(), w, h)
        .is_some()
}

/// The taps of one resampling position, computed once and applied to every
/// channel there.
#[derive(Debug, Clone, Copy)]
pub(crate) enum Taps {
    Bilinear(Bilinear),
    Separable(Separable),
}

impl Taps {
    /// The interpolated value, reading the source pixel at `(x, y)` through
    /// `at`. Every tap is inside the frame the taps were made for.
    #[inline]
    pub(crate) fn apply(&self, at: impl Fn(usize, usize) -> f64) -> f64 {
        match self {
            Taps::Bilinear(cell) => cell.apply(at),
            Taps::Separable(taps) => taps.apply(at),
        }
    }
}

/// A separable kernel over `n × n` taps starting at `(x0, y0)`.
#[derive(Debug, Clone, Copy)]
pub(crate) struct Separable {
    x0: usize,
    y0: usize,
    n: usize,
    wx: [f64; 6],
    wy: [f64; 6],
    norm: f64,
}

impl Separable {
    #[inline]
    fn apply(&self, at: impl Fn(usize, usize) -> f64) -> f64 {
        let mut acc = 0.0;
        for (ty, w_y) in self.wy.iter().enumerate().take(self.n) {
            let mut row_acc = 0.0;
            for (tx, w_x) in self.wx.iter().enumerate().take(self.n) {
                row_acc += w_x * at(self.x0 + tx, self.y0 + ty);
            }
            acc += w_y * row_acc;
        }
        acc / self.norm
    }
}

/// The four pixels and weights of a bilinear sample.
#[derive(Debug, Clone, Copy)]
pub(crate) struct Bilinear {
    x0: usize,
    y0: usize,
    x1: usize,
    y1: usize,
    weights: [f64; 4],
}

impl Bilinear {
    fn new(x0: usize, y0: usize, x1: usize, y1: usize, dx: f64, dy: f64) -> Self {
        Self {
            x0,
            y0,
            x1,
            y1,
            weights: [
                (1.0 - dx) * (1.0 - dy),
                dx * (1.0 - dy),
                (1.0 - dx) * dy,
                dx * dy,
            ],
        }
    }

    /// A sample whose base pixel `(⌊sx⌋, ⌊sy⌋)` lies inside the frame; the
    /// neighbor past the last column or row repeats the edge. An on-grid sample
    /// on the last row or column gives that neighbor no weight, so the identity
    /// warp keeps the whole frame.
    #[inline]
    pub(crate) fn edge_clamped(sx: f64, sy: f64, width: usize, height: usize) -> Option<Self> {
        let x0 = sx.floor();
        let y0 = sy.floor();
        let (ix, iy) = (x0 as i64, y0 as i64);
        if ix < 0 || iy < 0 || ix >= width as i64 || iy >= height as i64 {
            return None;
        }
        let (ix, iy) = (ix as usize, iy as usize);
        Some(Self::new(
            ix,
            iy,
            (ix + 1).min(width - 1),
            (iy + 1).min(height - 1),
            sx - x0,
            sy - y0,
        ))
    }

    #[inline]
    pub(crate) fn apply(&self, at: impl Fn(usize, usize) -> f64) -> f64 {
        let [w00, w10, w01, w11] = self.weights;
        w00 * at(self.x0, self.y0)
            + w10 * at(self.x1, self.y0)
            + w01 * at(self.x0, self.y1)
            + w11 * at(self.x1, self.y1)
    }
}

/// Bilinear sample of a row-major `width` × `height` lattice at fractional
/// `(x, y)`, held constant beyond the outermost row and column.
#[inline]
pub(crate) fn bilinear_clamped(values: &[f64], width: usize, height: usize, x: f64, y: f64) -> f64 {
    let x = x.clamp(0.0, (width - 1) as f64);
    let y = y.clamp(0.0, (height - 1) as f64);
    let (x0, y0) = (x.floor() as usize, y.floor() as usize);
    let (x1, y1) = ((x0 + 1).min(width - 1), (y0 + 1).min(height - 1));
    let (fx, fy) = (x - x0 as f64, y - y0 as f64);
    let top = values[y0 * width + x0] * (1.0 - fx) + values[y0 * width + x1] * fx;
    let bottom = values[y1 * width + x0] * (1.0 - fx) + values[y1 * width + x1] * fx;
    top * (1.0 - fy) + bottom * fy
}

/// Lanczos kernel with `a = 3` (windowed sinc): 1 at 0, 0 at and beyond ±3.
pub(crate) fn lanczos3(x: f64) -> f64 {
    const A: f64 = 3.0;
    if x.abs() < f64::EPSILON {
        1.0
    } else if x.abs() < A {
        let px = std::f64::consts::PI * x;
        (A * px.sin() * (px / A).sin()) / (px * px)
    } else {
        0.0
    }
}

/// Catmull-Rom cubic kernel (a = -0.5). Interpolating, C¹, mild sharpening.
fn catmull_rom(x: f64) -> f64 {
    let a = -0.5;
    let x = x.abs();
    if x < 1.0 {
        (a + 2.0) * x.powi(3) - (a + 3.0) * x.powi(2) + 1.0
    } else if x < 2.0 {
        a * x.powi(3) - 5.0 * a * x.powi(2) + 8.0 * a * x - 4.0 * a
    } else {
        0.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lanczos3_is_one_at_the_centre_zero_at_whole_offsets_and_even() {
        assert_eq!(lanczos3(0.0), 1.0);
        for k in 1..=3 {
            assert!(lanczos3(k as f64).abs() < 1e-15);
        }
        assert_eq!(lanczos3(3.5), 0.0);
        assert_eq!(lanczos3(-1.3), lanczos3(1.3));
        assert!(lanczos3(0.5) > 0.6 && lanczos3(1.5) < 0.0);
    }

    #[test]
    fn separable_weights_sum_near_one_at_every_offset() {
        for interp in [Interpolator::CatmullRom, Interpolator::Lanczos3] {
            for i in 0..=1000 {
                let f = i as f64 / 1000.0;
                let Some(Taps::Separable(Separable { norm, .. })) =
                    interp.taps(10.0 + f, 10.0 + f, 32, 32)
                else {
                    panic!("{interp:?} at {f} has no taps");
                };
                assert!((norm - 1.0).abs() < 0.05, "{interp:?} at {f}: {norm}");
            }
        }
    }

    #[test]
    fn a_sample_needs_its_whole_support_inside_the_frame() {
        let flat = |_: usize, _: usize| 7.0;
        for interp in [
            Interpolator::Bilinear,
            Interpolator::CatmullRom,
            Interpolator::Lanczos3,
        ] {
            let reach = interp.radius() as f64;
            let inside = interp
                .taps(reach - 1.0, reach - 1.0, 16, 16)
                .expect("inside");
            assert!((inside.apply(flat) - 7.0).abs() < 1e-12);
            assert!(interp.taps(reach - 1.5, 8.0, 16, 16).is_none());
            assert!(interp.taps(16.0 - reach + 0.5, 8.0, 16, 16).is_none());
            assert!(interp.taps(f64::NAN, 8.0, 16, 16).is_none());
            assert!(interp.taps(8.0, f64::INFINITY, 16, 16).is_none());
            assert!(interp.taps(f64::NEG_INFINITY, 8.0, 16, 16).is_none());
            assert!(!kernel_inside(f64::NAN, 8.0, 16, 16, interp));
        }
    }

    #[test]
    fn the_live_stack_bilinear_keeps_the_last_row_and_column() {
        let plane: Vec<f64> = (0..16).map(|i| i as f64).collect();
        let at = |x: usize, y: usize| plane[y * 4 + x];
        let corner = Bilinear::edge_clamped(3.0, 3.0, 4, 4).expect("on grid");
        assert_eq!(corner.apply(at), 15.0);
        assert!(Bilinear::edge_clamped(4.0, 0.0, 4, 4).is_none());
        assert!(Interpolator::Bilinear.taps(3.0, 3.0, 4, 4).is_none());
        let mid = Bilinear::edge_clamped(1.5, 2.25, 4, 4).expect("inside");
        assert_eq!(mid.apply(at), 2.25 * 4.0 + 1.5);
    }

    #[test]
    fn the_clamped_lattice_sampler_holds_its_edges() {
        let lattice = [0.0, 1.0, 2.0, 3.0];
        assert_eq!(bilinear_clamped(&lattice, 2, 2, 0.5, 0.5), 1.5);
        assert_eq!(bilinear_clamped(&lattice, 2, 2, -3.0, 9.0), 2.0);
    }
}
