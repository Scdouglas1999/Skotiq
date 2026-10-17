//! The crate's order statistics, in one place.
//!
//! Percentiles disagree by convention: indexing `(n·q)`, indexing
//! `round((n−1)·q)` and interpolating between ranks are three answers to the
//! same question. Each convention is named here so a call site picks one on
//! purpose rather than inheriting whichever its file happened to define:
//!
//! * [`percentile_nearest_rank`] — the crate default. `round((n−1)·q)`, so
//!   `q = 0` is the minimum and `q = 1` the maximum.
//! * [`percentile_floor`] — `(n·q)` truncated. Matches PixInsight's
//!   integer-indexed order statistics, which is why the auto-stretch uses it.
//! * [`percentile_interpolated`] — linear between the two bracketing ranks.
//!   Continuous in `q`, which matters when a percentile is differenced against
//!   another (the accumulating master's normalisation scale).
//!
//! At `q = 0.5` all three agree, so the choice only shows up in the tails.
//!
//! Ordering is [`f64::total_cmp`] throughout: `partial_cmp` reports `Equal` for
//! NaN, which is not a total order, so a single NaN leaves the slice unsorted
//! and the "median" arbitrary. `total_cmp` sinks NaN to the end
//! deterministically. For NaN-free input the two agree.
//!
//! Every function answers `0.0` for an empty input rather than panicking;
//! callers that care guard first.

use rayon::prelude::*;

/// MAD → Gaussian-σ consistency constant, `1 / Φ⁻¹(0.75)`. Multiplying a
/// median absolute deviation by this puts it on a standard-deviation footing
/// for normally distributed data.
pub(crate) const MAD_TO_SIGMA: f64 = 1.4826;

/// Median of an already-sorted slice: the centre element, or the mean of the
/// two centre elements for an even count.
pub(crate) fn median_sorted(sorted: &[f64]) -> f64 {
    let n = sorted.len();
    if n == 0 {
        return 0.0;
    }
    if n % 2 == 1 {
        sorted[n / 2]
    } else {
        (sorted[n / 2 - 1] + sorted[n / 2]) * 0.5
    }
}

/// Median of `values`, sorting it in place.
pub(crate) fn median_in_place(values: &mut [f64]) -> f64 {
    values.sort_unstable_by(f64::total_cmp);
    median_sorted(values)
}

/// [`median_in_place`] with a parallel sort. Worth it only for the
/// megapixel-scale slices in the frame-quality path; the parallel sort's setup
/// dominates for short inputs.
pub(crate) fn median_in_place_par(values: &mut [f64]) -> f64 {
    values.par_sort_unstable_by(f64::total_cmp);
    median_sorted(values)
}

/// The rank [`percentile_nearest_rank`] selects, for callers holding a sorted
/// buffer of something other than `f64` (a `u16` pixel histogram, say).
///
/// `len` must be non-zero.
pub(crate) fn nearest_rank_index(len: usize, q: f64) -> usize {
    let idx = ((len as f64 - 1.0) * q.clamp(0.0, 1.0)).round() as usize;
    idx.min(len - 1)
}

/// Value at fractional position `q` of an already-sorted slice, by nearest
/// rank over `(n − 1)·q`. `q = 0` is the minimum, `q = 1` the maximum.
pub(crate) fn percentile_nearest_rank(sorted: &[f64], q: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    sorted[nearest_rank_index(sorted.len(), q)]
}

/// Value at fractional position `q` of an already-sorted slice, indexing
/// `(n·q)` truncated toward zero and clamped to the last element.
///
/// This is PixInsight's convention for integer-indexed order statistics, and
/// it is *not* [`percentile_nearest_rank`]: for `q = 0.9` over 10 samples it
/// selects rank 9 where nearest-rank selects rank 8.
pub(crate) fn percentile_floor(sorted: &[f64], q: f64) -> f64 {
    let n = sorted.len();
    if n == 0 {
        return 0.0;
    }
    let idx = ((n as f64) * q) as usize;
    sorted[idx.min(n - 1)]
}

/// Value at fractional position `q` of an already-sorted slice, linearly
/// interpolated between the two ranks bracketing `(n − 1)·q`.
pub(crate) fn percentile_interpolated(sorted: &[f64], q: f64) -> f64 {
    let n = sorted.len();
    if n == 0 {
        return 0.0;
    }
    if n == 1 {
        return sorted[0];
    }
    let rank = q.clamp(0.0, 1.0) * (n - 1) as f64;
    let lo = rank.floor() as usize;
    let hi = rank.ceil() as usize;
    if lo == hi {
        sorted[lo]
    } else {
        let frac = rank - lo as f64;
        sorted[lo] * (1.0 - frac) + sorted[hi] * frac
    }
}

// A combined `mad_sigma(sorted, center)` helper is deliberately absent. The
// six MAD call sites do not agree on the median inside the MAD:
// `sky_atlas::estimate_frame_norm` and `difference_image::residual_background`
// take it by nearest rank (the upper centre for an even count) while the rest
// take the mean of the two centres. One shared helper would have to pick, and
// picking would move the noise floor of whichever sites it did not match.
// `MAD_TO_SIGMA` is the part they genuinely share, so that is what is shared.

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn median_takes_the_mean_of_the_two_centres_for_an_even_count() {
        assert_eq!(median_sorted(&[1.0, 2.0, 3.0, 8.0]), 2.5);
        assert_eq!(median_sorted(&[1.0, 2.0, 3.0]), 2.0);
        assert_eq!(median_sorted(&[]), 0.0);
    }

    #[test]
    fn median_in_place_sorts_first() {
        let mut v = [9.0, 1.0, 5.0];
        assert_eq!(median_in_place(&mut v), 5.0);
        assert_eq!(v, [1.0, 5.0, 9.0]);
    }

    #[test]
    fn median_in_place_par_agrees_with_the_sequential_sort() {
        let mut a: Vec<f64> = (0..5000).map(|i| ((i * 7919) % 5000) as f64).collect();
        let mut b = a.clone();
        assert_eq!(median_in_place(&mut a), median_in_place_par(&mut b));
    }

    /// A NaN must not be able to leave the slice unsorted and the median
    /// arbitrary: `total_cmp` sinks it past every real value.
    #[test]
    fn a_nan_sample_sinks_to_the_end_instead_of_corrupting_the_order() {
        let mut v = [3.0, f64::NAN, 1.0, 2.0, 4.0];
        assert_eq!(median_in_place(&mut v), 3.0);
        assert!(v[4].is_nan());
        assert_eq!(&v[..4], &[1.0, 2.0, 3.0, 4.0]);
    }

    /// The three conventions agree at the median and disagree in the tails.
    /// This is the whole reason they are named rather than inlined.
    #[test]
    fn the_three_percentile_conventions_agree_only_at_the_median() {
        let sorted: Vec<f64> = (0..10).map(|i| i as f64).collect();

        assert_eq!(percentile_nearest_rank(&sorted, 0.5), 5.0);
        assert_eq!(percentile_floor(&sorted, 0.5), 5.0);
        assert_eq!(percentile_interpolated(&sorted, 0.5), 4.5);

        // q = 0.9 over ten samples: rank 8 vs rank 9 vs the point between.
        assert_eq!(percentile_nearest_rank(&sorted, 0.9), 8.0);
        assert_eq!(percentile_floor(&sorted, 0.9), 9.0);
        assert_eq!(percentile_interpolated(&sorted, 0.9), 8.1);

        // The extremes: nearest-rank and interpolated span the full range,
        // floor cannot reach the minimum's neighbour the same way.
        assert_eq!(percentile_nearest_rank(&sorted, 0.0), 0.0);
        assert_eq!(percentile_nearest_rank(&sorted, 1.0), 9.0);
        assert_eq!(percentile_interpolated(&sorted, 1.0), 9.0);
        assert_eq!(percentile_floor(&sorted, 1.0), 9.0);
    }

    #[test]
    fn percentiles_clamp_out_of_range_q_and_answer_zero_for_empty() {
        let sorted = [1.0, 2.0, 3.0];
        assert_eq!(percentile_nearest_rank(&sorted, -1.0), 1.0);
        assert_eq!(percentile_nearest_rank(&sorted, 4.0), 3.0);
        assert_eq!(percentile_interpolated(&sorted, 4.0), 3.0);
        assert_eq!(percentile_floor(&sorted, 4.0), 3.0);
        assert_eq!(percentile_nearest_rank(&[], 0.5), 0.0);
        assert_eq!(percentile_floor(&[], 0.5), 0.0);
        assert_eq!(percentile_interpolated(&[], 0.5), 0.0);
    }

    #[test]
    fn nearest_rank_index_is_the_rank_percentile_nearest_rank_reads() {
        let sorted: Vec<f64> = (0..7).map(|i| i as f64).collect();
        for step in 0..=10 {
            let q = step as f64 / 10.0;
            assert_eq!(
                sorted[nearest_rank_index(sorted.len(), q)],
                percentile_nearest_rank(&sorted, q)
            );
        }
    }
}
