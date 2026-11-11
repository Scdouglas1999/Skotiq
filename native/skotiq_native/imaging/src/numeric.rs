//! Small numeric building blocks shared across the crate: the dense linear
//! solver, the least-squares line, the 3×3 determinant and the separable
//! Gaussian blur.

use rayon::prelude::*;

/// Solve the dense `n × n` system `a · x = b` by Gaussian elimination with
/// partial pivoting. `a` is row-major. `None` when a pivot's magnitude is
/// below `singular_below`: the system has no stable solution at the caller's
/// scale.
pub(crate) fn solve_dense(
    mut a: Vec<f64>,
    mut b: Vec<f64>,
    singular_below: f64,
) -> Option<Vec<f64>> {
    let n = b.len();
    if a.len() != n * n {
        return None;
    }
    for col in 0..n {
        let mut pivot = col;
        let mut largest = a[col * n + col].abs();
        for row in (col + 1)..n {
            let candidate = a[row * n + col].abs();
            if candidate > largest {
                largest = candidate;
                pivot = row;
            }
        }
        if largest < singular_below {
            return None;
        }
        if pivot != col {
            for k in 0..n {
                a.swap(col * n + k, pivot * n + k);
            }
            b.swap(col, pivot);
        }
        let pivot_value = a[col * n + col];
        for row in (col + 1)..n {
            let factor = a[row * n + col] / pivot_value;
            if factor != 0.0 {
                for k in col..n {
                    a[row * n + k] -= factor * a[col * n + k];
                }
                b[row] -= factor * b[col];
            }
        }
    }
    let mut x = vec![0.0; n];
    for row in (0..n).rev() {
        let mut sum = b[row];
        for k in (row + 1)..n {
            sum -= a[row * n + k] * x[k];
        }
        x[row] = sum / a[row * n + row];
    }
    Some(x)
}

/// Running sums of a weighted least-squares line `y = slope·x + intercept`.
#[derive(Debug, Clone, Copy, Default)]
pub(crate) struct LineSums {
    w: f64,
    wx: f64,
    wy: f64,
    wxx: f64,
    wxy: f64,
}

impl LineSums {
    #[inline]
    pub(crate) fn add(&mut self, x: f64, y: f64, weight: f64) {
        self.w += weight;
        self.wx += weight * x;
        self.wy += weight * y;
        self.wxx += weight * x * x;
        self.wxy += weight * x * y;
    }

    /// `(slope, intercept)`, or `None` when the points have no spread in `x`
    /// (the normal determinant is within `f64::EPSILON` of zero) or the line is
    /// not finite.
    pub(crate) fn solve(&self) -> Option<(f64, f64)> {
        let det = self.w * self.wxx - self.wx * self.wx;
        if det.is_nan() || det.abs() <= f64::EPSILON {
            return None;
        }
        let slope = (self.w * self.wxy - self.wx * self.wy) / det;
        let intercept = (self.wy - slope * self.wx) / self.w;
        (slope.is_finite() && intercept.is_finite()).then_some((slope, intercept))
    }
}

/// Determinant of a 3×3 matrix, expanded along the first row.
#[inline]
pub(crate) fn det3(m: &[[f64; 3]; 3]) -> f64 {
    m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
        - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
        + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
}

/// A plane sample type the blur reads and writes; every pass accumulates in
/// `f64` whatever the storage.
pub(crate) trait PlaneSample: Copy + Send + Sync {
    fn to_f64(self) -> f64;
    fn from_f64(value: f64) -> Self;
}

impl PlaneSample for f32 {
    #[inline]
    fn to_f64(self) -> f64 {
        self as f64
    }
    #[inline]
    fn from_f64(value: f64) -> Self {
        value as f32
    }
}

impl PlaneSample for f64 {
    #[inline]
    fn to_f64(self) -> f64 {
        self
    }
    #[inline]
    fn from_f64(value: f64) -> Self {
        value
    }
}

/// Gaussian taps of standard deviation `sigma` (pixels) over `±⌈3σ⌉`,
/// normalized to sum to one so a blur keeps flux.
pub(crate) fn gaussian_taps(sigma: f64) -> Vec<f64> {
    let radius = (3.0 * sigma).ceil() as i64;
    let taps: Vec<f64> = (-radius..=radius)
        .map(|i| (-(i * i) as f64 / (2.0 * sigma * sigma)).exp())
        .collect();
    let sum: f64 = taps.iter().sum();
    taps.iter().map(|t| t / sum).collect()
}

/// Convolve a row-major `width` × `height` plane with the odd-length `taps`
/// along x, then along y, repeating the edge pixels. Each pass sums in `f64`
/// and stores in `T`.
pub(crate) fn convolve_separable<T: PlaneSample>(
    plane: &[T],
    width: usize,
    height: usize,
    taps: &[f64],
) -> Vec<T> {
    if width == 0 || height == 0 {
        return plane.to_vec();
    }
    let radius = (taps.len() / 2) as i64;
    let (w, h) = (width as i64, height as i64);
    let mut horizontal = vec![T::from_f64(0.0); plane.len()];
    horizontal
        .par_chunks_exact_mut(width)
        .zip(plane.par_chunks_exact(width))
        .for_each(|(row, src)| {
            for (x, slot) in row.iter_mut().enumerate() {
                let mut acc = 0.0;
                for (k, t) in taps.iter().enumerate() {
                    let sx = (x as i64 + k as i64 - radius).clamp(0, w - 1) as usize;
                    acc += t * src[sx].to_f64();
                }
                *slot = T::from_f64(acc);
            }
        });
    let mut out = vec![T::from_f64(0.0); plane.len()];
    out.par_chunks_exact_mut(width)
        .enumerate()
        .for_each(|(y, row)| {
            let mut acc = vec![0.0f64; width];
            for (k, t) in taps.iter().enumerate() {
                let sy = (y as i64 + k as i64 - radius).clamp(0, h - 1) as usize;
                let src = &horizontal[sy * width..(sy + 1) * width];
                for (a, v) in acc.iter_mut().zip(src) {
                    *a += t * v.to_f64();
                }
            }
            for (slot, a) in row.iter_mut().zip(acc) {
                *slot = T::from_f64(a);
            }
        });
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_dense_system_is_solved_and_a_singular_one_refused() {
        // 2x + y = 5, x + 3y = 10  ->  x = 1, y = 3.
        let x = solve_dense(vec![2.0, 1.0, 1.0, 3.0], vec![5.0, 10.0], 1e-12).unwrap();
        assert!((x[0] - 1.0).abs() < 1e-14 && (x[1] - 3.0).abs() < 1e-14);
        // A zero on the diagonal needs the pivot.
        let x = solve_dense(vec![0.0, 1.0, 1.0, 0.0], vec![2.0, 7.0], 1e-12).unwrap();
        assert_eq!(x, [7.0, 2.0]);
        assert!(solve_dense(vec![1.0, 2.0, 2.0, 4.0], vec![1.0, 2.0], 1e-12).is_none());
        assert!(solve_dense(vec![1.0; 3], vec![1.0, 2.0], 1e-12).is_none());
        assert_eq!(solve_dense(Vec::new(), Vec::new(), 1e-12), Some(Vec::new()));
    }

    #[test]
    fn gaussian_taps_are_symmetric_normalized_and_three_sigma_wide() {
        let taps = gaussian_taps(1.4);
        assert_eq!(taps.len(), 2 * 5 + 1);
        assert!((taps.iter().sum::<f64>() - 1.0).abs() < 1e-12);
        for k in 0..5 {
            assert_eq!(taps[k], taps[10 - k]);
            assert!(taps[k] < taps[k + 1]);
        }
    }

    #[test]
    fn a_blur_keeps_a_flat_plane_and_the_flux_of_a_point() {
        let taps = gaussian_taps(1.5);
        let flat = vec![3.0f32; 12 * 9];
        for v in convolve_separable(&flat, 12, 9, &taps) {
            assert!((v - 3.0).abs() < 1e-6);
        }
        let mut point = vec![0.0f64; 21 * 21];
        point[10 * 21 + 10] = 1.0;
        let out = convolve_separable(&point, 21, 21, &taps);
        assert!((out.iter().sum::<f64>() - 1.0).abs() < 1e-12);
        assert_eq!(out[10 * 21 + 9], out[10 * 21 + 11]);
        assert_eq!(out[9 * 21 + 10], out[10 * 21 + 9]);
        assert!(convolve_separable::<f64>(&[], 0, 0, &taps).is_empty());
    }

    #[test]
    fn a_weighted_line_is_fitted_and_a_vertical_one_refused() {
        let mut sums = LineSums::default();
        for x in 0..5 {
            sums.add(x as f64, 2.0 * x as f64 + 1.0, 1.0);
        }
        sums.add(2.0, 100.0, 0.0);
        let (slope, intercept) = sums.solve().unwrap();
        assert!((slope - 2.0).abs() < 1e-12 && (intercept - 1.0).abs() < 1e-12);
        let mut vertical = LineSums::default();
        vertical.add(3.0, 1.0, 1.0);
        vertical.add(3.0, 5.0, 2.0);
        assert!(vertical.solve().is_none());
        assert!(LineSums::default().solve().is_none());
    }

    #[test]
    fn det3_expands_along_the_first_row() {
        assert_eq!(
            det3(&[[2.0, 0.0, 1.0], [1.0, 3.0, 2.0], [1.0, 1.0, 2.0]]),
            6.0
        );
        assert_eq!(
            det3(&[[1.0, 2.0, 3.0], [2.0, 4.0, 6.0], [0.0, 1.0, 5.0]]),
            0.0
        );
    }
}
