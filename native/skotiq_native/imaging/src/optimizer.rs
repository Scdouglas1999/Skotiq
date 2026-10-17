//! Marginal-SNR integration optimizer (Pillar 2): *prove the cull before you
//! pay for it*.
//!
//! [`crate::frame_weighting`] tells you how much each sub should *weigh*; this
//! module answers the next, more actionable question: **how many of the
//! weight-ranked subs are actually worth integrating?** Past some point each
//! additional, lower-weight sub adds more of its own noise than signal and the
//! stacked SNR stops climbing — and a genuinely bad sub (cloud, satellite-lit
//! background, lost guiding) makes it *fall*. The honest answer to "keep all of
//! them" is usually "no": a smaller, cleaner subset can beat the full stack.
//!
//! The whole module is **pure and cheap**. It takes the per-frame quality
//! descriptors and weights you already computed and *predicts* the integrated
//! SNR of every weight-ordered prefix analytically. It performs **no
//! re-integration** — no pixels are touched. The output is a recommendation the
//! caller may accept or ignore (exactly the project's never-silently-drop
//! idiom): which subs to keep, the predicted SNR change versus keeping
//! everything, and a human-readable reason.
//!
//! ## The noise model (state the assumption plainly)
//!
//! We model the stack as a **background-limited, independent-noise weighted
//! mean** — the standard regime for deep-sky integration where each sub's noise
//! is dominated by sky-background shot noise plus read noise and is independent
//! frame-to-frame. Under that model, for a weighted mean with per-sub weights
//! `wᵢ`, signal `sᵢ`, and per-sub noise variance `vᵢ`:
//!
//! ```text
//!                Σ wᵢ·sᵢ
//!   SNR(set) = ─────────────────
//!              √( Σ wᵢ²·vᵢ )
//! ```
//!
//! This is the textbook error-propagation result for a linear combination of
//! independent Gaussian estimates (the numerator is the combined signal; the
//! denominator is the combined noise, with each sub's variance scaled by the
//! *square* of its weight because variance propagates through a weight as `w²`).
//! We recover each sub's signal and noise from its [`FrameQuality`]:
//! `signalᵢ = snrᵢ · noiseᵢ` (so `snrᵢ = signalᵢ / noiseᵢ` by construction) and
//! `vᵢ = noiseᵢ²`. With all weights and noises equal this collapses to the
//! familiar `SNR(n) = √n · SNR₁` — the `√n` improvement law — which is exactly
//! what test 1 pins down.
//!
//! ## What "recommend a subset" means
//!
//! 1. Rank subs by weight, best first (stable, so ties keep input order).
//! 2. Walk the prefixes `n = 1..=N` and predict `SNR(n)` with the formula above.
//! 3. Find two landmarks on that curve:
//!    - `n_maxsnr` — the prefix with the highest predicted SNR (keep *exactly*
//!      this many for the mathematically best stack; anything past it is a sub
//!      whose noise outweighs its signal).
//!    - `n_knee` — the first prefix where the *marginal* SNR gain
//!      `(SNR(n) − SNR(n−1)) / SNR(n)` drops below a small epsilon: the point of
//!      diminishing returns, where you are spending integration time for almost
//!      no SNR. This is the classic "elbow"/knee of a diminishing-returns curve.
//! 4. Interpolate between them by `aggressiveness ∈ [0, 1]` (0 = stop at the
//!    knee, conservative; 1 = chase the max-SNR point, maximally aggressive) and
//!    clamp into `[min_keep, N]`.
//! 5. Apply the **never-harm floor**. The knee is a *wall-clock* landmark — it
//!    answers "is it worth more capture time to keep shooting?", where each extra
//!    sub costs real minutes. But this module's question is "which of the frames
//!    *already on disk* should I integrate?", and for a captured sub the marginal
//!    cost is zero: there is never a reason to drop a net-positive frame. So the
//!    knee must never pull `keep_n` below the SNR-monotone region. We floor
//!    `keep_n` at the smallest prefix whose predicted SNR already meets the
//!    full-stack SNR, which guarantees the recommended subset is never one the
//!    model itself predicts is *worse* than keeping everything (a smaller cleaner
//!    subset can still win, but only by *recovering* SNR from net-negative subs).
//!
//! ## Limitations
//!
//! - The **noise model** is the explicit assumption above. It is the right
//!   first-order model for background-limited deep-sky subs and matches the
//!   inverse-variance spirit of [`crate::frame_weighting`]'s default weighting,
//!   but it does *not* model object (source) shot noise, spatially varying
//!   coverage, or rejection — those are integration-time effects this cheap
//!   predictor deliberately does not simulate. It predicts the *trend* (does
//!   adding sub k help or hurt?), which is what the cull decision needs; it is
//!   not a substitute for measuring the real master.
//! - The knee epsilon and the default `aggressiveness` (0.7) are **defensible
//!   defaults, not corpus-tuned**. They are exposed as knobs precisely so they
//!   can be revisited against real sub sets. The curve itself is deterministic
//!   and unit-tested on synthetic descriptors here.

use crate::frame_weighting::FrameQuality;

/// Marginal-SNR gain below which a prefix is considered to be at the "knee" of
/// the diminishing-returns curve. `(SNR(n) − SNR(n−1)) / SNR(n) < KNEE_EPS`
/// means the next sub bought less than ~0.5 % SNR — past the point where the
/// integration time is worth it.
///
/// A default, not a corpus-tuned value (see module docs).
const KNEE_EPS: f64 = 0.005;

/// One point on the predicted integration curve: the stacked metrics you would
/// get from integrating the best `n` weight-ranked subs.
///
/// All fields are *predictions* from the cheap analytic model (see module
/// docs); no pixels were integrated to produce them.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CurvePoint {
    /// Number of subs in this prefix (`1..=N`).
    pub n: usize,
    /// Predicted integrated signal-to-noise of the best `n` subs under the
    /// background-limited weighted-mean model.
    pub snr: f64,
    /// Weighted-mean FWHM (px) over the prefix — the seeing you would inherit
    /// from this subset. Subs with no measurable stars (`fwhm ≤ 0`) are skipped
    /// so they neither help nor poison the average; `0.0` when the whole prefix
    /// lacks any measurable FWHM.
    pub fwhm: f64,
    /// Cumulative integration time (seconds) of the prefix — the cost axis of
    /// the curve. Missing exposures (input shorter than the population) count
    /// as `0`.
    pub cumulative_integration_s: f64,
}

/// Tunables for [`recommend_subset`].
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct OptimizerConfig {
    /// Where to land between the two curve landmarks, in `[0, 1]`:
    /// `0` = stop at the knee (conservative — keep only up to diminishing
    /// returns), `1` = chase the maximum-SNR prefix (aggressive — keep every sub
    /// that still helps the SNR at all). Values are clamped into `[0, 1]`.
    pub aggressiveness: f64,
    /// Never recommend keeping fewer than this many subs (a thin night should
    /// not be culled to nothing). Clamped up to `1` internally — keeping zero
    /// subs is never a recommendation, only the empty-input degenerate case.
    pub min_keep: usize,
}

impl Default for OptimizerConfig {
    fn default() -> Self {
        // 0.7 leans toward the max-SNR point without insisting on the very last
        // marginal sub: a defensible default, not corpus-tuned (see module docs).
        Self {
            aggressiveness: 0.7,
            min_keep: 1,
        }
    }
}

/// The optimizer's verdict: which subs to integrate, and what it buys you.
#[derive(Debug, Clone, PartialEq)]
pub struct SubsetRecommendation {
    /// How many of the weight-ranked subs to keep.
    pub keep_n: usize,
    /// The **original** indices (into the caller's `qualities`/`weights`/
    /// `exposures_s` slices) of the kept subs, i.e. the top `keep_n` by weight.
    /// Stable: ties keep input order.
    pub kept_indices: Vec<usize>,
    /// Predicted SNR change of keeping the subset versus keeping *all* `N` subs,
    /// in percent: `(SNR(keep_n) − SNR(N)) / SNR(N) · 100`. Positive means the
    /// cull is predicted to *improve* SNR (the dropped subs were net-negative);
    /// `0` when keeping everything is already optimal.
    ///
    /// **Never negative.** The recommender clamps `keep_n` up to the smallest
    /// prefix whose predicted SNR already meets the full-stack SNR (the never-harm
    /// floor), so the returned subset is never one the model itself predicts is
    /// *worse* than keeping everything. A captured sub is only ever dropped to
    /// *recover* SNR (it was net-negative), never to chase the diminishing-returns
    /// knee — that knee is a wall-clock "should I shoot more?" landmark, irrelevant
    /// to which already-captured frames to integrate.
    pub predicted_snr_gain_pct: f64,
    /// Human-readable, UI-ready summary of the recommendation.
    pub reason: String,
}

/// Errors from this module. Both variants are *caller* mistakes the optimizer
/// refuses to paper over (mismatched parallel-array lengths) rather than
/// silently best-efforting on inconsistent input — the project idiom.
#[derive(Debug, thiserror::Error, PartialEq)]
pub enum OptimizerError {
    /// `qualities` and `weights` had different lengths; they describe the same
    /// population and must align one-to-one.
    #[error("qualities ({qualities}) and weights ({weights}) must have the same length")]
    LengthMismatch {
        /// Length of the `qualities` slice.
        qualities: usize,
        /// Length of the `weights` slice.
        weights: usize,
    },
}

/// Predict the integration curve over the **weight-ranked** prefixes of the
/// population.
///
/// The population is `qualities[i]` with integration weight `weights[i]` and
/// exposure `exposures_s[i]` (all parallel arrays over the same subs). Subs are
/// ranked by weight descending (stable), then for every prefix `n = 1..=N` we
/// predict the stacked SNR, the weighted-mean FWHM, and the cumulative exposure
/// under the background-limited independent-noise weighted-mean model described
/// in the module docs.
///
/// `exposures_s` may be **shorter** than the population (or empty): any missing
/// exposure is treated as `0` seconds, so the cost axis is still monotone and
/// never panics. `qualities` and `weights` *must* match in length.
///
/// Degenerate subs are handled rather than rejected: a sub with `noise ≤ 0`
/// carries no honest variance and is skipped from the SNR sums (it contributes
/// neither signal nor noise — it cannot make the prediction better *or* worse),
/// and a sub with `fwhm ≤ 0` is skipped from the FWHM average. A prefix whose
/// every sub is degenerate yields `snr = 0` / `fwhm = 0` for that point.
///
/// Returns an empty vector for an empty population.
pub fn integration_curve(
    qualities: &[FrameQuality],
    weights: &[f64],
    exposures_s: &[f64],
) -> Result<Vec<CurvePoint>, OptimizerError> {
    if qualities.len() != weights.len() {
        return Err(OptimizerError::LengthMismatch {
            qualities: qualities.len(),
            weights: weights.len(),
        });
    }
    let n = qualities.len();
    if n == 0 {
        return Ok(Vec::new());
    }

    let order = rank_by_weight_desc(weights);

    // Running accumulators over the ranked prefix. The SNR is a ratio of two
    // running sums (signal numerator, variance-of-signal denominator) so the
    // whole curve is a single linear pass — O(N), no per-prefix recomputation.
    let mut sum_signal = 0.0_f64; // Σ wᵢ·sᵢ
    let mut sum_var = 0.0_f64; // Σ wᵢ²·vᵢ
    let mut sum_w_fwhm = 0.0_f64; // Σ wᵢ·fwhmᵢ over subs with a valid fwhm
    let mut sum_w_for_fwhm = 0.0_f64; // Σ wᵢ over subs with a valid fwhm
    let mut cum_exposure = 0.0_f64;

    let mut curve = Vec::with_capacity(n);
    for (rank, &idx) in order.iter().enumerate() {
        let q = &qualities[idx];
        let w = sanitize_weight(weights[idx]);

        // Per-sub signal and variance from the descriptor. signalᵢ = snrᵢ·noiseᵢ
        // by construction (snr is defined as signal/noise upstream), and
        // varianceᵢ = noiseᵢ². A non-positive or non-finite noise has no honest
        // variance — skip it from the SNR sums entirely so it neither helps nor
        // poisons the prediction.
        if q.noise.is_finite() && q.noise > 0.0 && w > 0.0 {
            let signal = q.snr.max(0.0) * q.noise;
            let variance = q.noise * q.noise;
            sum_signal += w * signal;
            sum_var += w * w * variance;
        }

        // Weighted-mean FWHM over subs that actually measured one.
        if q.fwhm.is_finite() && q.fwhm > 0.0 && w > 0.0 {
            sum_w_fwhm += w * q.fwhm;
            sum_w_for_fwhm += w;
        }

        // Cumulative exposure; missing exposures count as 0 s.
        cum_exposure += exposures_s.get(idx).copied().unwrap_or(0.0).max(0.0);

        let snr = if sum_var > 0.0 {
            sum_signal / sum_var.sqrt()
        } else {
            0.0
        };
        let fwhm = if sum_w_for_fwhm > 0.0 {
            sum_w_fwhm / sum_w_for_fwhm
        } else {
            0.0
        };

        curve.push(CurvePoint {
            n: rank + 1,
            snr,
            fwhm,
            cumulative_integration_s: cum_exposure,
        });
    }

    Ok(curve)
}

/// Recommend how many weight-ranked subs to integrate, and report what the cull
/// is predicted to buy.
///
/// Computes the [`integration_curve`], finds the maximum-SNR prefix and the
/// diminishing-returns knee, then interpolates between them by
/// `cfg.aggressiveness` and clamps into `[max(cfg.min_keep, 1), N]`. The kept
/// indices are the **original** indices of the top `keep_n` subs by weight.
///
/// `predicted_snr_gain_pct` compares the recommended subset against keeping all
/// `N` subs: a *positive* value means the optimizer predicts the cull will raise
/// the integrated SNR (the dropped subs were dragging the stack down); zero
/// means keeping everything was already best.
///
/// Returns an error only on a `qualities`/`weights` length mismatch. An **empty
/// population** is not an error: it yields `keep_n = 0`, no kept indices, and a
/// neutral reason (never a panic).
pub fn recommend_subset(
    qualities: &[FrameQuality],
    weights: &[f64],
    exposures_s: &[f64],
    cfg: &OptimizerConfig,
) -> Result<SubsetRecommendation, OptimizerError> {
    let curve = integration_curve(qualities, weights, exposures_s)?;
    let total = curve.len();

    if total == 0 {
        return Ok(SubsetRecommendation {
            keep_n: 0,
            kept_indices: Vec::new(),
            predicted_snr_gain_pct: 0.0,
            reason: "No subs to optimize".to_string(),
        });
    }

    // Landmark 1: the prefix with the highest predicted SNR. Ties resolve to the
    // *smallest* n (prefer keeping fewer subs for the same SNR). `n` is 1-based.
    let n_maxsnr = curve
        .iter()
        .enumerate()
        .fold((0usize, f64::NEG_INFINITY), |(best_i, best_snr), (i, p)| {
            if p.snr > best_snr {
                (i, p.snr)
            } else {
                (best_i, best_snr)
            }
        })
        .0
        + 1;

    // Landmark 2: the diminishing-returns knee — the smallest prefix where the
    // marginal *fractional* SNR gain drops below KNEE_EPS. If the curve never
    // flattens (still climbing meaningfully at the end), the knee is the full
    // set. n=1 always "gains" (from 0), so we start scanning at n=2.
    let n_knee = {
        let mut knee = total; // default: never flattened ⇒ knee at the end
        for n in 2..=total {
            let prev = curve[n - 2].snr;
            let cur = curve[n - 1].snr;
            // Fractional gain relative to the current SNR. A non-positive cur SNR
            // cannot define a meaningful fraction; treat it as no gain (knee).
            let gain = if cur > 0.0 { (cur - prev) / cur } else { 0.0 };
            if gain < KNEE_EPS {
                knee = n;
                break;
            }
        }
        knee
    };

    // Interpolate between the two landmarks by aggressiveness, then clamp. Both
    // landmarks are valid prefix sizes in [1, total]; lerp stays inside their
    // span, and the clamp enforces the caller's min_keep (and the universal
    // "keep at least one" floor for a non-empty population).
    let aggressiveness = cfg.aggressiveness.clamp(0.0, 1.0);
    let lo = n_knee.min(n_maxsnr) as f64;
    let hi = n_knee.max(n_maxsnr) as f64;
    // aggressiveness maps knee→maxsnr; when maxsnr < knee (the SNR peaks before
    // returns flatten — e.g. a declining tail), lerp toward maxsnr still pulls
    // *down* toward the peak, which is the correct, more-aggressive cull.
    let target = if n_maxsnr >= n_knee {
        lerp(lo, hi, aggressiveness)
    } else {
        // maxsnr is the aggressive end here, so invert the fraction.
        lerp(hi, lo, aggressiveness)
    };

    // Never-harm floor: the diminishing-returns knee answers "is further capture
    // worth the integration time?", a wall-clock question. For frames already on
    // disk there is *zero* marginal capture cost, so the only honest reason to
    // drop a captured sub is that it makes the stack strictly worse (it is
    // net-negative). The smallest prefix whose predicted SNR already meets the
    // full-stack SNR is therefore the floor below which we must not cull — culling
    // past it would recommend throwing away good data for a self-predicted SNR
    // *loss*, violating the module's never-harm contract. `n_maxsnr_floor` is that
    // prefix; clamping `keep_n` up to it guarantees predicted_snr_gain_pct >= 0.
    let snr_full = curve[total - 1].snr;
    let n_maxsnr_floor = curve
        .iter()
        .find(|p| p.snr >= snr_full)
        .map(|p| p.n)
        .unwrap_or(total);

    let min_keep = cfg.min_keep.max(1).max(n_maxsnr_floor).min(total);
    let keep_n = (target.round() as usize).clamp(min_keep, total);

    // Kept indices = original indices of the top keep_n by weight (stable rank).
    let order = rank_by_weight_desc(weights);
    let kept_indices: Vec<usize> = order.iter().take(keep_n).copied().collect();

    // Predicted SNR gain of the subset versus the full stack. The never-harm
    // floor above guarantees this is >= 0 (modulo float rounding): we never
    // recommend a subset the model itself predicts is worse than the full stack.
    let snr_keep = curve[keep_n - 1].snr;
    let predicted_snr_gain_pct = if snr_full > 0.0 {
        (snr_keep - snr_full) / snr_full * 100.0
    } else {
        0.0
    };

    let dropped = total - keep_n;
    let reason = if dropped == 0 {
        format!(
            "Keep all {total} subs: already optimal ({:+.1}% SNR vs full stack)",
            predicted_snr_gain_pct
        )
    } else {
        // Only call the dropped subs "low-weight" when they genuinely weigh less
        // than the kept tail; otherwise they were dropped for SNR recovery, not
        // weight, and "low-weight" would be a factual lie — the over-cull case
        // where every sub carries the same weight. Compare the heaviest dropped
        // sub to the lightest kept sub: only if the drop boundary is a real
        // weight step do we say "low-weight".
        let kept_min_w = order[..keep_n]
            .iter()
            .map(|&i| sanitize_weight(weights[i]))
            .fold(f64::INFINITY, f64::min);
        let dropped_max_w = order[keep_n..]
            .iter()
            .map(|&i| sanitize_weight(weights[i]))
            .fold(f64::NEG_INFINITY, f64::max);
        let descriptor = if dropped_max_w < kept_min_w {
            "low-weight"
        } else {
            // Equal-or-mixed weight: the cull is justified by SNR recovery, not by
            // the subs being lighter. Call them what they are.
            "net-negative"
        };
        format!(
            "Keep best {keep_n} of {total}: {:+.1}% SNR; dropped {dropped} {descriptor} sub{}",
            predicted_snr_gain_pct,
            if dropped == 1 { "" } else { "s" }
        )
    };

    Ok(SubsetRecommendation {
        keep_n,
        kept_indices,
        predicted_snr_gain_pct,
        reason,
    })
}

// Internal helpers

/// Indices of `weights`, sorted by weight **descending**, stable on ties (a tie
/// keeps the lower original index first). This is the weight-rank order every
/// public function shares so curve prefixes and `kept_indices` agree exactly.
fn rank_by_weight_desc(weights: &[f64]) -> Vec<usize> {
    let mut order: Vec<usize> = (0..weights.len()).collect();
    // sort_by is stable, so equal weights retain ascending original-index order.
    order.sort_by(|&a, &b| sanitize_weight(weights[b]).total_cmp(&sanitize_weight(weights[a])));
    order
}

/// Map a possibly-degenerate weight to a finite, non-negative value. A NaN or
/// negative weight is treated as `0` (worst), so it ranks last and contributes
/// nothing — never poisoning a sum or producing a NaN comparison key.
#[inline]
fn sanitize_weight(w: f64) -> f64 {
    if w.is_finite() && w > 0.0 {
        w
    } else {
        0.0
    }
}

/// Linear interpolation `a + (b − a)·t`.
#[inline]
fn lerp(a: f64, b: f64, t: f64) -> f64 {
    a + (b - a) * t
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a [`FrameQuality`] from just the fields the optimizer reads,
    /// leaving the rest neutral. Keeps the synthetic descriptors terse.
    fn quality(snr: f64, noise: f64, fwhm: f64) -> FrameQuality {
        FrameQuality {
            noise,
            background: 1000.0,
            snr,
            fwhm,
            eccentricity: Some(0.1),
            star_count: 50,
        }
    }

    // Test 1: N equal-quality subs ⇒ SNR ~ √n (the integration improvement law),
    // and the recommendation keeps them all.

    #[test]
    fn equal_quality_subs_follow_sqrt_n_and_keep_all() {
        let n = 12usize;
        // Identical subs: same SNR, same noise, same weight, same FWHM.
        let qualities: Vec<FrameQuality> = (0..n).map(|_| quality(10.0, 5.0, 3.0)).collect();
        let weights = vec![1.0; n];
        let exposures = vec![60.0; n];

        let curve = integration_curve(&qualities, &weights, &exposures).expect("curve");
        assert_eq!(curve.len(), n);

        // With equal weights and noises the weighted mean collapses to
        // SNR(k) = √k · SNR₁. Check the analytic law point by point.
        let snr1 = curve[0].snr;
        assert!(
            (snr1 - 10.0).abs() < 1e-9,
            "single-sub SNR should equal the per-sub SNR, got {snr1}"
        );
        for (i, p) in curve.iter().enumerate() {
            let k = (i + 1) as f64;
            let expected = (k).sqrt() * 10.0;
            assert!(
                (p.snr - expected).abs() < 1e-9,
                "prefix {} SNR {} != √n law {}",
                p.n,
                p.snr,
                expected
            );
        }

        // SNR is strictly increasing (monotone up) — every sub helps.
        for w in curve.windows(2) {
            assert!(
                w[1].snr > w[0].snr,
                "equal-quality SNR must climb: {:?}",
                curve
            );
        }

        // FWHM of an all-equal prefix is just the common FWHM.
        assert!((curve[n - 1].fwhm - 3.0).abs() < 1e-9);
        // Cumulative exposure is a clean prefix sum.
        assert!((curve[n - 1].cumulative_integration_s - 60.0 * n as f64).abs() < 1e-9);

        // The recommendation must keep every sub (nothing is net-negative).
        let rec = recommend_subset(
            &qualities,
            &weights,
            &exposures,
            &OptimizerConfig::default(),
        )
        .expect("recommendation");
        assert_eq!(
            rec.keep_n, n,
            "all equal subs should be kept: {}",
            rec.reason
        );
        assert_eq!(rec.kept_indices.len(), n);
        assert!(
            rec.predicted_snr_gain_pct.abs() < 1e-9,
            "no gain from culling equal subs"
        );
    }

    // Test 2: N good subs + one appended high-noise/low-SNR sub ⇒ the curve's
    // tail declines (SNR(N) < SNR(N-1)) and the optimizer drops the bad
    // one, identifying it by its ORIGINAL index.

    #[test]
    fn appending_a_bad_sub_declines_the_tail_and_is_culled() {
        let good_n = 10usize;
        let mut qualities: Vec<FrameQuality> =
            (0..good_n).map(|_| quality(15.0, 4.0, 2.5)).collect();
        let mut weights = vec![1.0; good_n];
        let mut exposures = vec![120.0; good_n];

        // The villain: very low SNR but high noise. Its huge variance (weighted
        // by w²) swamps the denominator faster than its meagre signal lifts the
        // numerator, so the stacked SNR *falls* when it is included. It is
        // appended at the END so its original index (good_n) differs from its
        // weight rank (last).
        qualities.push(quality(1.0, 60.0, 8.0));
        weights.push(0.05); // low weight ⇒ ranks last
        exposures.push(120.0);
        let bad_index = good_n; // original index of the appended bad sub

        let curve = integration_curve(&qualities, &weights, &exposures).expect("curve");
        let total = curve.len();
        // The declining tail: adding the worst sub lowers the predicted SNR.
        assert!(
            curve[total - 1].snr < curve[total - 2].snr,
            "tail must decline when the bad sub is added: SNR(N)={} >= SNR(N-1)={}",
            curve[total - 1].snr,
            curve[total - 2].snr
        );

        let rec = recommend_subset(
            &qualities,
            &weights,
            &exposures,
            &OptimizerConfig::default(),
        )
        .expect("recommendation");
        // It must drop exactly the bad sub.
        assert_eq!(
            rec.keep_n, good_n,
            "should keep the good subs only: {}",
            rec.reason
        );
        assert!(
            !rec.kept_indices.contains(&bad_index),
            "the bad sub (original index {bad_index}) must be dropped; kept = {:?}",
            rec.kept_indices
        );
        // Dropping a net-negative sub is predicted to *improve* SNR.
        assert!(
            rec.predicted_snr_gain_pct > 0.0,
            "culling the bad sub should predict a positive SNR gain, got {}",
            rec.predicted_snr_gain_pct
        );
    }

    // Test 3: min_keep clamp is honored even when the math wants to cull harder.

    #[test]
    fn min_keep_clamp_is_honored() {
        // A population where the SNR peaks early (the later subs are weak), so an
        // unconstrained optimizer would keep only a couple. A high min_keep must
        // override that and force more subs to be kept.
        let mut qualities = vec![quality(20.0, 3.0, 2.0), quality(20.0, 3.0, 2.0)];
        let mut weights = vec![1.0, 1.0];
        // Append weak, high-noise subs that the optimizer would otherwise drop.
        for _ in 0..6 {
            qualities.push(quality(0.5, 50.0, 9.0));
            weights.push(0.02);
        }
        let total = qualities.len();
        let exposures = vec![30.0; total];

        // Aggressive config that, unconstrained, would cull down to the peak.
        let cfg = OptimizerConfig {
            aggressiveness: 1.0,
            min_keep: 5,
        };
        let rec = recommend_subset(&qualities, &weights, &exposures, &cfg).expect("rec");
        assert!(
            rec.keep_n >= 5,
            "min_keep=5 must be honored, got keep_n={} ({})",
            rec.keep_n,
            rec.reason
        );
        assert_eq!(rec.kept_indices.len(), rec.keep_n);

        // And min_keep can never exceed the population size.
        let cfg_over = OptimizerConfig {
            aggressiveness: 0.0,
            min_keep: 999,
        };
        let rec_over = recommend_subset(&qualities, &weights, &exposures, &cfg_over).expect("rec");
        assert_eq!(rec_over.keep_n, total, "min_keep clamps to N, not beyond");
    }

    // Test 4: empty input ⇒ empty curve / keep_n = 0, no panic.

    #[test]
    fn empty_input_is_handled_without_panic() {
        let curve = integration_curve(&[], &[], &[]).expect("curve");
        assert!(curve.is_empty(), "empty population yields empty curve");

        let rec = recommend_subset(&[], &[], &[], &OptimizerConfig::default()).expect("rec");
        assert_eq!(rec.keep_n, 0);
        assert!(rec.kept_indices.is_empty());
        assert_eq!(rec.predicted_snr_gain_pct, 0.0);
        assert!(!rec.reason.is_empty(), "even the empty case gets a reason");
    }

    // Error path: mismatched parallel-array lengths are refused.

    #[test]
    fn length_mismatch_is_an_error() {
        let qualities = vec![quality(10.0, 5.0, 3.0), quality(10.0, 5.0, 3.0)];
        let weights = vec![1.0]; // one short
        let err = integration_curve(&qualities, &weights, &[]).unwrap_err();
        assert_eq!(
            err,
            OptimizerError::LengthMismatch {
                qualities: 2,
                weights: 1,
            }
        );
        // recommend_subset surfaces the same error.
        let err2 =
            recommend_subset(&qualities, &weights, &[], &OptimizerConfig::default()).unwrap_err();
        assert_eq!(err2, err);
    }

    // Supplementary correctness / robustness coverage.

    #[test]
    fn aggressiveness_interpolates_between_knee_and_maxsnr() {
        // A long plateau of strong subs (knee fires early) followed by a couple
        // of marginally-helpful subs (max-SNR is later). Conservative
        // aggressiveness should land at/near the knee; aggressive should chase
        // the later max-SNR prefix. keep_n must be monotone non-decreasing in
        // aggressiveness for this shape.
        let mut qualities: Vec<FrameQuality> = (0..8).map(|_| quality(30.0, 2.0, 2.0)).collect();
        // Two marginal subs: positive contribution but tiny — they still raise
        // SNR (so max-SNR is the full set) yet add almost nothing (so the knee
        // fired earlier in the plateau). Their individual SNR (15) is high enough
        // that signal/√variance still nudges the stack up, but only by ~0.2 %.
        qualities.push(quality(15.0, 2.0, 3.0));
        qualities.push(quality(15.0, 2.0, 3.0));
        let total = qualities.len();
        let weights = vec![1.0; total];
        let exposures = vec![60.0; total];

        let conservative = recommend_subset(
            &qualities,
            &weights,
            &exposures,
            &OptimizerConfig {
                aggressiveness: 0.0,
                min_keep: 1,
            },
        )
        .expect("rec")
        .keep_n;
        let aggressive = recommend_subset(
            &qualities,
            &weights,
            &exposures,
            &OptimizerConfig {
                aggressiveness: 1.0,
                min_keep: 1,
            },
        )
        .expect("rec")
        .keep_n;

        assert!(
            aggressive >= conservative,
            "aggressive keep_n ({aggressive}) must be >= conservative ({conservative})"
        );
        // Every sub here is net-positive (all SNRs/noises finite, weights equal),
        // so the maximum-SNR prefix is the whole set: aggressive should keep all.
        assert_eq!(aggressive, total, "max-SNR prefix is the full set here");
    }

    #[test]
    fn kept_indices_are_original_indices_in_weight_rank_order() {
        // Weights deliberately out of order so rank != input order. The best two
        // by weight are original indices 2 (w=9) then 0 (w=5); the third by
        // weight (original index 1, w=1) is a high-noise sub that *lowers* the
        // stacked SNR, so the max-SNR prefix is exactly 2 — an aggressive config
        // culls to it, exercising the original-index mapping of `kept_indices`.
        let qualities = vec![
            quality(10.0, 5.0, 3.0),
            quality(1.0, 40.0, 8.0),
            quality(10.0, 5.0, 3.0),
        ];
        let weights = vec![5.0, 1.0, 9.0];
        let exposures = vec![60.0, 60.0, 60.0];
        let cfg = OptimizerConfig {
            aggressiveness: 1.0,
            min_keep: 1,
        };
        let rec = recommend_subset(&qualities, &weights, &exposures, &cfg).expect("rec");
        assert_eq!(rec.keep_n, 2);
        assert_eq!(
            rec.kept_indices,
            vec![2, 0],
            "top-2 by weight, original indices, ranked"
        );
    }

    #[test]
    fn missing_and_degenerate_inputs_do_not_panic() {
        // exposures shorter than the population ⇒ missing count as 0 s.
        let qualities = vec![
            quality(10.0, 5.0, 3.0),
            quality(8.0, 6.0, 0.0), // no measurable FWHM (skipped from avg)
            quality(0.0, 0.0, 0.0), // fully degenerate noise (skipped from SNR)
        ];
        let weights = vec![1.0, 1.0, 1.0];
        let exposures = vec![60.0]; // only the first has an exposure

        let curve = integration_curve(&qualities, &weights, &exposures).expect("curve");
        assert_eq!(curve.len(), 3);
        // All SNR/FWHM/exposure values are finite (no NaN/∞ from degenerates).
        for p in &curve {
            assert!(p.snr.is_finite(), "snr finite, got {}", p.snr);
            assert!(p.fwhm.is_finite(), "fwhm finite, got {}", p.fwhm);
            assert!(p.cumulative_integration_s.is_finite());
        }
        // Cumulative exposure: only the first sub (rank 0, the highest-weight tie
        // and lowest index) contributes 60 s; the rest add 0.
        assert!((curve[2].cumulative_integration_s - 60.0).abs() < 1e-9);
        // The fully-degenerate (noise=0) sub contributes nothing to SNR, so the
        // last prefix SNR equals the prefix of the two real subs.
        assert!(curve[2].snr.is_finite() && curve[2].snr >= 0.0);

        // recommend_subset must not panic on this input.
        let rec = recommend_subset(
            &qualities,
            &weights,
            &exposures,
            &OptimizerConfig::default(),
        )
        .expect("rec");
        assert!(rec.keep_n >= 1 && rec.keep_n <= 3);
    }

    #[test]
    fn single_sub_population_keeps_the_one() {
        let qualities = vec![quality(12.0, 4.0, 2.0)];
        let weights = vec![1.0];
        let exposures = vec![300.0];
        let rec = recommend_subset(
            &qualities,
            &weights,
            &exposures,
            &OptimizerConfig::default(),
        )
        .expect("rec");
        assert_eq!(rec.keep_n, 1);
        assert_eq!(rec.kept_indices, vec![0]);
        assert_eq!(
            rec.predicted_snr_gain_pct, 0.0,
            "keeping the only sub is a no-op"
        );
    }

    // A large pile of identical good subs must NOT be culled. The
    // diminishing-returns knee for equal-quality subs fires at the first prefix
    // where (1 − √((n−1)/n)) < KNEE_EPS, i.e. around n ≈ 101, regardless of N.
    // keep_n is floored at the SNR-monotone region, so for equal subs (SNR
    // strictly climbing) the floor is the full set: keep_n == N and gain >= 0 at
    // every aggressiveness. Without that floor a stack of >100 equal subs is
    // pulled down toward ~101–170, dropping already-captured frames for a
    // self-predicted SNR loss.
    #[test]
    fn large_pile_of_equal_good_subs_is_never_culled() {
        let n = 200usize; // well past the knee's ~101 landing point
        let qualities: Vec<FrameQuality> = (0..n).map(|_| quality(50.0, 2.0, 2.0)).collect();
        let weights = vec![1.0; n];
        let exposures = vec![60.0; n];

        for aggr in [0.0, 0.5, 0.7, 1.0] {
            let cfg = OptimizerConfig {
                aggressiveness: aggr,
                min_keep: 1,
            };
            let rec = recommend_subset(&qualities, &weights, &exposures, &cfg).expect("rec");
            assert_eq!(
                rec.keep_n, n,
                "aggressiveness={aggr}: {n} identical good subs must all be kept \
                 (SNR climbs monotonically, so the full set is the max-SNR prefix); \
                 got keep_n={} ({})",
                rec.keep_n, rec.reason
            );
            assert!(
                rec.predicted_snr_gain_pct >= -1e-9,
                "aggressiveness={aggr}: recommendation must never predict an SNR loss, \
                 got {}% ({})",
                rec.predicted_snr_gain_pct,
                rec.reason
            );
            // The reason must never libel equal-weight subs as "low-weight".
            assert!(
                !rec.reason.contains("low-weight"),
                "equal-weight subs must not be labelled low-weight: {}",
                rec.reason
            );
        }
    }

    // General never-harm invariant: across a spread of random populations and
    // every aggressiveness, the recommended subset's predicted SNR is never
    // worse than the full stack. This is the property that backs the module's
    // never-harm contract, and a large equal-quality pile is its hardest case.
    #[test]
    fn recommended_subset_never_predicts_an_snr_loss() {
        // Tiny deterministic LCG so the random populations are reproducible.
        let mut state: u64 = 0xDEAD_BEEF_CAFE_F00D;
        let mut next = || {
            state = state
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            (state >> 11) as f64 / (1u64 << 53) as f64
        };

        for trial in 0..40 {
            // Population size spans both the small and the large (>knee) regimes.
            let n = 1 + (next() * 220.0) as usize;
            let qualities: Vec<FrameQuality> = (0..n)
                .map(|_| {
                    // SNR in [2, 60], noise in [1, 8], fwhm in [1.5, 5].
                    let snr = 2.0 + next() * 58.0;
                    let noise = 1.0 + next() * 7.0;
                    let fwhm = 1.5 + next() * 3.5;
                    quality(snr, noise, fwhm)
                })
                .collect();
            let weights: Vec<f64> = (0..n).map(|_| 0.1 + next() * 1.9).collect();
            let exposures = vec![60.0; n];

            for aggr in [0.0, 0.5, 0.7, 1.0] {
                let cfg = OptimizerConfig {
                    aggressiveness: aggr,
                    min_keep: 1,
                };
                let rec = recommend_subset(&qualities, &weights, &exposures, &cfg).expect("rec");
                assert!(
                    rec.predicted_snr_gain_pct >= -1e-9,
                    "trial {trial} (n={n}, aggr={aggr}): predicted SNR loss {}% — the \
                     recommender must never drop captured subs for a self-predicted loss \
                     ({})",
                    rec.predicted_snr_gain_pct,
                    rec.reason
                );
                assert!(
                    rec.keep_n >= 1 && rec.keep_n <= n,
                    "trial {trial}: keep_n {} out of range 1..={n}",
                    rec.keep_n
                );
            }
        }
    }
}
