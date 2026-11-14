//! The crate's order statistics, in one place.
//!
//! Percentiles disagree by convention: indexing `(n·q)`, indexing
//! `round((n−1)·q)` and interpolating between ranks are three answers to the
//! same question. Each convention is named here so a call site picks one on
//! purpose rather than inheriting whichever its file happened to define:
//!
//! * [`percentile_nearest_rank`] — the crate default. `round((n−1)·q)`, so
//!   `q = 0` is the minimum and `q = 1` the maximum.
//! * [`WeightedSorted::percentile_floor`] — `(n·q)` truncated. Matches
//!   PixInsight's integer-indexed order statistics, which is why the
//!   auto-stretch uses it.
//! * [`percentile_lower_rank`] — `(n−1)·q` truncated, the lower bracketing
//!   rank. DepthLock's bounds use it so they never overstate.
//! * [`percentile_interpolated`] — linear between the two bracketing ranks.
//!   Continuous in `q`, which matters when a percentile is differenced against
//!   another (the accumulating master's normalisation scale).
//!
//! The median has two conventions for an even count. [`median_sorted`] and
//! [`median_in_place`] take the mean of the two centre elements;
//! [`median_upper_in_place`] takes the upper one, as nearest-rank does at
//! `q = 0.5`. A MAD-based sigma inherits the choice, so it comes in both
//! forms ([`mad_sigma`], [`mad_sigma_upper`]); for an odd count they agree.
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

/// Median of `values` without reordering them.
pub(crate) fn median_of(values: &[f64]) -> f64 {
    median_in_place(&mut values.to_vec())
}

/// Median of `values` taking the upper of the two centre elements for an even
/// count, which is what [`percentile_nearest_rank`] answers at `q = 0.5`.
/// Selects rather than sorts, so `values` is left partitioned, not ordered.
pub(crate) fn median_upper_in_place(values: &mut [f64]) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    let mid = values.len() / 2;
    *values.select_nth_unstable_by(mid, f64::total_cmp).1
}

/// [`median_upper_in_place`] for `f32` samples.
pub(crate) fn median_upper_in_place_f32(values: &mut [f32]) -> f32 {
    if values.is_empty() {
        return 0.0;
    }
    let mid = values.len() / 2;
    *values.select_nth_unstable_by(mid, f32::total_cmp).1
}

/// Robust standard deviation of `values` about `center`: the median absolute
/// deviation times [`MAD_TO_SIGMA`]. The median inside is [`median_sorted`]'s
/// (mean of the two centres).
pub(crate) fn mad_sigma(values: &[f64], center: f64) -> f64 {
    let mut deviations: Vec<f64> = values.iter().map(|v| (v - center).abs()).collect();
    median_in_place(&mut deviations) * MAD_TO_SIGMA
}

/// [`mad_sigma`] with the upper-centre median ([`median_upper_in_place`])
/// inside, for the estimators defined that way.
pub(crate) fn mad_sigma_upper(values: &[f64], center: f64) -> f64 {
    let mut deviations: Vec<f64> = values.iter().map(|v| (v - center).abs()).collect();
    median_upper_in_place(&mut deviations) * MAD_TO_SIGMA
}

/// Median and [`mad_sigma`] of `values`, which is left sorted.
pub(crate) fn median_and_sigma(values: &mut [f64]) -> (f64, f64) {
    let median = median_in_place(values);
    (median, mad_sigma(values, median))
}

/// [`median_and_sigma`] by the upper-centre convention throughout. `values`
/// is left partitioned, not ordered.
pub(crate) fn median_and_sigma_upper(values: &mut [f64]) -> (f64, f64) {
    let median = median_upper_in_place(values);
    (median, mad_sigma_upper(values, median))
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

/// The slice form of [`WeightedSorted::percentile_floor`], which the tests
/// check the counted form against.
#[cfg(test)]
pub(crate) fn percentile_floor(sorted: &[f64], q: f64) -> f64 {
    let n = sorted.len();
    if n == 0 {
        return 0.0;
    }
    let idx = ((n as f64) * q) as usize;
    sorted[idx.min(n - 1)]
}

/// Value at fractional position `q` of an already-sorted slice, at rank
/// `(n − 1)·q` truncated: the lower of the two bracketing ranks. Never above
/// the interpolated value, which is what a conservative bound wants.
pub(crate) fn percentile_lower_rank(sorted: &[f64], q: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    sorted[((sorted.len() - 1) as f64 * q.clamp(0.0, 1.0)).floor() as usize]
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

/// How many samples sit at each 16-bit level.
///
/// Order statistics of a 16-bit frame need no sort: the counts are the
/// sorted frame. Every statistic read from them is the value a sort of the
/// same samples would give, bit for bit.
pub(crate) struct LevelCounts {
    counts: Vec<u64>,
    total: u64,
}

impl LevelCounts {
    const LEVELS: usize = 1 << 16;

    /// Count the levels of little-endian `u16` samples. A trailing odd byte is
    /// ignored.
    pub(crate) fn of_le_bytes(bytes: &[u8]) -> Self {
        Self::of_par_iter(
            bytes
                .par_chunks_exact(2)
                .map(|c| u16::from_le_bytes([c[0], c[1]])),
        )
    }

    /// Count the levels of one channel of channel-interleaved samples.
    pub(crate) fn of_channel(interleaved: &[u16], channel: usize, channels: usize) -> Self {
        Self::of_par_iter(
            interleaved
                .par_chunks_exact(channels.max(1))
                .map(move |pixel| pixel[channel]),
        )
    }

    fn of_par_iter(levels: impl IndexedParallelIterator<Item = u16>) -> Self {
        // Chunks large enough that the per-chunk table is a small fraction of
        // the samples it counts.
        let counts = levels
            .with_min_len(1 << 18)
            .fold(
                || vec![0u64; Self::LEVELS],
                |mut counts, level| {
                    counts[level as usize] += 1;
                    counts
                },
            )
            .reduce(
                || vec![0u64; Self::LEVELS],
                |mut a, b| {
                    for (x, y) in a.iter_mut().zip(&b) {
                        *x += y;
                    }
                    a
                },
            );
        let total = counts.iter().sum();
        Self { counts, total }
    }

    /// Number of samples counted.
    pub(crate) fn total(&self) -> u64 {
        self.total
    }

    /// Lowest and highest level present.
    pub(crate) fn range(&self) -> Option<(u16, u16)> {
        let low = self.counts.iter().position(|&c| c > 0)?;
        let high = self.counts.iter().rposition(|&c| c > 0)?;
        Some((low as u16, high as u16))
    }

    /// Sum of all samples. Exact: it fits `u64` for any frame under 2^48
    /// samples.
    pub(crate) fn sum(&self) -> u64 {
        self.counts
            .iter()
            .enumerate()
            .map(|(level, &count)| level as u64 * count)
            .sum()
    }

    /// The level at 0-based `rank` of the sorted samples. `rank` is clamped to
    /// the last sample; an empty count answers 0.
    pub(crate) fn level_at(&self, rank: u64) -> u16 {
        let rank = rank.min(self.total.saturating_sub(1));
        let mut seen = 0u64;
        for (level, &count) in self.counts.iter().enumerate() {
            seen += count;
            if seen > rank {
                return level as u16;
            }
        }
        0
    }

    /// Present levels and their counts, lowest first.
    pub(crate) fn present(&self) -> impl Iterator<Item = (u16, u64)> + '_ {
        self.counts
            .iter()
            .enumerate()
            .filter(|(_, &count)| count > 0)
            .map(|(level, &count)| (level as u16, count))
    }

    /// The samples mapped through `value`, as a sorted weighted list: what
    /// sorting `value(sample)` over every sample would give, run-length
    /// encoded.
    pub(crate) fn mapped(&self, value: impl Fn(u16) -> f64) -> WeightedSorted {
        let mut runs: Vec<(f64, u64)> = self
            .present()
            .map(|(level, count)| (value(level), count))
            .collect();
        runs.sort_unstable_by(|a, b| a.0.total_cmp(&b.0));
        WeightedSorted {
            runs,
            total: self.total,
        }
    }
}

/// A sorted sample list held as `(value, count)` runs.
pub(crate) struct WeightedSorted {
    runs: Vec<(f64, u64)>,
    total: u64,
}

impl WeightedSorted {
    /// Runs of `(value, count)`; sorted here, so the caller need not.
    pub(crate) fn from_runs(mut runs: Vec<(f64, u64)>) -> Self {
        runs.retain(|run| run.1 > 0);
        runs.sort_unstable_by(|a, b| a.0.total_cmp(&b.0));
        let total = runs.iter().map(|run| run.1).sum();
        Self { runs, total }
    }

    pub(crate) fn total(&self) -> u64 {
        self.total
    }

    /// The value at 0-based `rank`, clamped to the last sample; 0 when empty.
    pub(crate) fn at(&self, rank: u64) -> f64 {
        let rank = rank.min(self.total.saturating_sub(1));
        let mut seen = 0u64;
        for &(value, count) in &self.runs {
            seen += count;
            if seen > rank {
                return value;
            }
        }
        0.0
    }

    /// [`median_sorted`] of the list.
    pub(crate) fn median(&self) -> f64 {
        if self.total == 0 {
            return 0.0;
        }
        if self.total % 2 == 1 {
            self.at(self.total / 2)
        } else {
            (self.at(self.total / 2 - 1) + self.at(self.total / 2)) * 0.5
        }
    }

    /// Value at fractional position `q`, indexing `(n·q)` truncated toward
    /// zero and clamped to the last sample.
    ///
    /// This is PixInsight's convention for integer-indexed order statistics,
    /// and it is *not* [`percentile_nearest_rank`]: for `q = 0.9` over 10
    /// samples it selects rank 9 where nearest-rank selects rank 8.
    pub(crate) fn percentile_floor(&self, q: f64) -> f64 {
        if self.total == 0 {
            return 0.0;
        }
        self.at(((self.total as f64) * q) as u64)
    }
}

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

    #[test]
    fn level_counts_answer_what_a_sort_would() {
        let levels: Vec<u16> = (0..5000u32)
            .map(|i| ((i.wrapping_mul(2_654_435_761)) >> 16) as u16 % 900 + 100)
            .collect();
        let bytes: Vec<u8> = levels.iter().flat_map(|v| v.to_le_bytes()).collect();
        let counts = LevelCounts::of_le_bytes(&bytes);

        let mut sorted: Vec<f64> = levels.iter().map(|&v| f64::from(v)).collect();
        sorted.sort_unstable_by(f64::total_cmp);
        assert_eq!(counts.total(), 5000);
        assert_eq!(
            counts.range(),
            Some((sorted[0] as u16, sorted[4999] as u16))
        );
        assert_eq!(counts.sum() as f64, sorted.iter().sum::<f64>());
        for rank in [0u64, 1, 2499, 2500, 4999, 9000] {
            assert_eq!(
                f64::from(counts.level_at(rank)),
                sorted[(rank as usize).min(4999)]
            );
        }

        let median = median_sorted(&sorted);
        let mut deviations: Vec<f64> = sorted.iter().map(|v| (v - median).abs()).collect();
        deviations.sort_unstable_by(f64::total_cmp);
        let mapped = counts.mapped(|level| (f64::from(level) - median).abs());
        assert_eq!(mapped.median(), median_sorted(&deviations));
        assert_eq!(
            mapped.percentile_floor(0.9),
            percentile_floor(&deviations, 0.9)
        );
        assert_eq!(counts.mapped(f64::from).median(), median);
    }

    #[test]
    fn one_channel_is_counted_out_of_interleaved_samples() {
        let rgb = [1u16, 10, 100, 2, 20, 200, 3, 30, 300];
        let green = LevelCounts::of_channel(&rgb, 1, 3);
        assert_eq!(green.total(), 3);
        assert_eq!(green.range(), Some((10, 30)));
        assert_eq!(green.level_at(1), 20);
        assert_eq!(
            WeightedSorted::from_runs(vec![(2.0, 1), (1.0, 3), (5.0, 0)]).at(3),
            2.0
        );
        assert_eq!(WeightedSorted::from_runs(Vec::new()).median(), 0.0);
    }

    #[test]
    fn the_two_median_conventions_differ_only_for_an_even_count() {
        let mut even = [4.0, 1.0, 3.0, 2.0];
        assert_eq!(median_upper_in_place(&mut even), 3.0);
        assert_eq!(median_in_place(&mut even), 2.5);
        let mut odd = [5.0, 1.0, 3.0];
        assert_eq!(median_upper_in_place(&mut odd), 3.0);
        assert_eq!(median_upper_in_place(&mut []), 0.0);
        assert_eq!(median_upper_in_place_f32(&mut [4.0, 1.0, 3.0, 2.0]), 3.0);
        assert_eq!(median_upper_in_place_f32(&mut []), 0.0);

        let sorted = [1.0, 2.0, 3.0, 4.0];
        assert_eq!(
            median_upper_in_place(&mut sorted.clone()),
            percentile_nearest_rank(&sorted, 0.5)
        );
    }

    #[test]
    fn mad_sigma_follows_the_median_convention_it_is_named_for() {
        let values = [1.0, 2.0, 4.0, 8.0];
        // Deviations about 3: 2, 1, 1, 5 -> sorted 1, 1, 2, 5.
        assert_eq!(mad_sigma(&values, 3.0), 1.5 * MAD_TO_SIGMA);
        assert_eq!(mad_sigma_upper(&values, 3.0), 2.0 * MAD_TO_SIGMA);
        assert_eq!(
            median_and_sigma(&mut values.clone()),
            (3.0, 1.5 * MAD_TO_SIGMA)
        );
        assert_eq!(
            median_and_sigma_upper(&mut values.clone()),
            (4.0, 3.0 * MAD_TO_SIGMA)
        );
        assert_eq!(mad_sigma(&[], 0.0), 0.0);
    }

    #[test]
    fn the_lower_rank_percentile_never_exceeds_the_interpolated_one() {
        let sorted = [10.0, 20.0, 30.0, 40.0];
        assert_eq!(percentile_lower_rank(&sorted, 0.5), 20.0);
        assert_eq!(percentile_lower_rank(&sorted, 0.99), 30.0);
        assert_eq!(percentile_lower_rank(&sorted, 1.0), 40.0);
        assert_eq!(percentile_lower_rank(&[], 0.5), 0.0);
        for q in [0.1, 0.34, 0.5, 0.75, 0.9] {
            assert!(percentile_lower_rank(&sorted, q) <= percentile_interpolated(&sorted, q));
        }
    }
}
