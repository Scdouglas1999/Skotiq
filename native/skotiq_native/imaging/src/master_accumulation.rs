//! Multi-night accumulating master frame.
//!
//! This is the headline feature of the post-session pipeline: a **serializable
//! running master** you can keep adding subs to across many nights, without
//! ever re-reading the subs already folded in. Each clear night you point it at
//! that night's new (aligned, normalized, weighted) subs, call
//! [`IntegratedMaster::add_frames`], and the master grows; the artifact
//! [`IntegratedMaster::finalize`] produces always reflects the *entire* history.
//!
//! ## Why a weighted mean is exactly accumulable
//!
//! The estimator the master uses is a per-pixel **weighted mean**. The crucial
//! property is that a weighted mean decomposes into two running sums that are
//! both additive across disjoint batches:
//!
//! ```text
//!     master(p) = Σ wᵢ·xᵢ(p) / Σ wᵢ          (sum over every sub i ever folded)
//! ```
//!
//! Storing `sum_wx = Σ wᵢ·xᵢ` and `sum_w = Σ wᵢ` per pixel lets us add a new
//! batch by simply adding its contributions to the running sums and dividing at
//! the very end. Splitting the subs into any number of batches and folding them
//! one batch at a time yields a result **bit-for-bit identical** (to f64
//! rounding) to integrating all of them at once. We additionally carry
//! `sum_wx2 = Σ wᵢ·xᵢ²` so a running variance / per-pixel SNR is available for
//! diagnostics and for the online rejection clip below. This online-vs-batch
//! parity is the property the unit tests pin.
//!
//! ## What this module assumes about its input (same contract as `integration`)
//!
//! [`add_frames`](IntegratedMaster::add_frames) consumes frames that are already
//!
//! 1. **Aligned** onto the frozen geometric reference grid
//!    ([`crate::registration::register_frame`]) — every frame must match the
//!    master's `width × height × channels`.
//! 2. **Normalized** onto the *frozen* photometric reference stored in the
//!    master at creation (see [`NormalizationReference`]). Freezing the
//!    normalization reference at creation is what makes cross-night
//!    accumulation valid: every later night is brought onto the same
//!    background-and-scale footing as the first night, so a pixel's value means
//!    the same thing regardless of which night it came from.
//! 3. **Weighted** with a scalar quality weight
//!    ([`crate::frame_weighting::weight_frames`]).
//!
//! This module performs none of those steps; it folds their output into the
//! running state. It mirrors the [`crate::integration::IntegrationFrame`]
//! contract exactly so the same prepared buffers feed either the one-shot batch
//! integrator or the accumulating master.
//!
//! ## The accumulation/rejection tradeoff
//!
//! Full batch rejection (Winsorized-σ, linear-fit-clip, …) needs the *entire*
//! per-pixel sample column at once. An accumulating master, by construction,
//! does **not** keep old subs around, so it cannot re-run a full batch clip when
//! a new night arrives. Instead it offers an **online robust clip**: each new
//! sub's pixel is tested against the *current running mean ± k·running σ* before
//! it is folded in (the same spirit as the live stacker's online clip, but
//! persisted in the master state). This is not identical to re-integrating every
//! night's full population from scratch — it is the standard, honest
//! accumulation tradeoff. The master records its
//! [`AccumulationMode`] so a UI can offer a "full re-integrate from archived
//! subs" path (via [`crate::integration::integrate_frames`]) whenever the
//! original subs are still on disk.
//!
//! With [`AccumulationMode::RunningWeightedMean`] and `clip == None` (no online
//! rejection), accumulation is provably exact vs. a single batch weighted mean —
//! that is the parity the tests assert.

use crate::integration::IntegrationFrame;
use crate::robust_stats::percentile_interpolated as percentile_of_sorted;
use crate::{ImageData, PixelType};
use serde::{Deserialize, Serialize};

/// Current on-disk format version for the serialized accumulator state. Bumped
/// whenever the binary layout changes so [`IntegratedMaster::deserialize`] can
/// refuse (rather than misread) an incompatible sidecar.
///
/// Version 2 is a DATA retirement, not a layout change: every v1 sidecar was
/// accumulated under the defective background-pair normalization fit that
/// collapsed frame scale to ~0.002 and erased star flux from the fold (see
/// `normalization.rs` module docs). Folding corrected frames onto such an
/// accumulator would blend poisoned pixels into good data with no way to
/// separate them afterwards, so v1 is refused outright — the constituent subs
/// are untouched on disk and a fresh master rebuilds from them.
pub const MASTER_STATE_VERSION: u32 = 2;

/// Magic bytes prefixing a serialized accumulator (`"NSM"` + version tag). Lets
/// [`IntegratedMaster::deserialize`] fail loudly on a non-master / corrupt blob
/// rather than parsing garbage, exactly like [`crate::defect_map`]'s container.
pub const MASTER_MAGIC: &[u8; 4] = b"NSM1";

// Public configuration + metadata types

/// How the accumulating master folds samples and whether it rejects outliers
/// online as it goes.
///
/// `clip` carries the online rejection thresholds. `None` disables rejection —
/// the master is then a pure running weighted mean and is *exactly* equal to a
/// single-batch weighted-mean integration of the same frames. `Some(k)` rejects
/// a new sample at a pixel when it lies more than `k.low`·σ below or `k.high`·σ
/// above the current running mean (σ from the running variance), and records the
/// rejection in the per-pixel rejection counter.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub enum AccumulationMode {
    /// Running weighted mean with an optional online robust clip.
    RunningWeightedMean {
        /// Online rejection thresholds, or `None` for no rejection (exact mean).
        clip: Option<OnlineClip>,
    },
}

impl Default for AccumulationMode {
    fn default() -> Self {
        // A mild online clip by default: it catches gross transients (satellites,
        // planes, cosmic rays) on the new night while leaving the running mean
        // essentially intact for clean pixels. Callers who need bit-exact
        // online-vs-batch parity (or who plan to re-integrate from archived subs)
        // pass `clip: None`.
        AccumulationMode::RunningWeightedMean {
            clip: Some(OnlineClip {
                low: 4.0,
                high: 4.0,
            }),
        }
    }
}

/// Online rejection thresholds (in units of the running σ) for
/// [`AccumulationMode::RunningWeightedMean`].
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct OnlineClip {
    /// Reject a new sample below `mean − low·σ`.
    pub low: f64,
    /// Reject a new sample above `mean + high·σ`.
    pub high: f64,
}

/// The **frozen** photometric reference the master normalizes every later night
/// onto.
///
/// This is the photometric "anchor" captured at creation from the reference
/// frame. It does not itself re-normalize incoming frames (callers normalize
/// against it before calling [`add_frames`](IntegratedMaster::add_frames)); it
/// is stored so a caller can recover the exact background + scale baseline the
/// master was built on (e.g. to normalize a new night's subs consistently, or
/// to document provenance). Freezing it is what keeps cross-night accumulation
/// photometrically consistent.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NormalizationReference {
    /// Per-channel reference background level (ADU) at creation.
    pub background: Vec<f64>,
    /// Per-channel reference signal scale (ADU) at creation.
    pub scale: Vec<f64>,
}

/// The **frozen** geometric reference (the common grid every sub must align to).
///
/// Stored so later subs are validated against the exact grid the master was
/// created on; a sub whose dimensions or channel count differ is rejected with
/// a clear error rather than silently misaccumulated.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct GeometryReference {
    /// Reference grid width in pixels.
    pub width: u32,
    /// Reference grid height in pixels.
    pub height: u32,
    /// Channel count (1 = mono, 3 = OSC/RGB).
    pub channels: u32,
}

/// A single night's (or batch's) fold into the master, for provenance and the
/// UI's "growth curve".
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FoldRecord {
    /// Number of frames that actually contributed in this fold (weight > 0).
    pub frames_added: usize,
    /// Sum of the contributing frames' weights in this fold.
    pub weight_added: f64,
    /// Integration seconds added in this fold (Σ per-frame exposure), if the
    /// caller supplied per-frame exposure times; `0.0` otherwise.
    pub integration_seconds_added: f64,
    /// Samples rejected by the online clip during this fold.
    pub rejected: u64,
    /// Free-form label (e.g. an ISO date or session id) for the UI fold log.
    pub label: String,
}

/// Provenance + summary metadata carried alongside the running state.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
pub struct MasterMetadata {
    /// Optional filter name (e.g. `"Ha"`, `"L"`, `"OSC"`).
    pub filter: Option<String>,
    /// Optional target name for the UI / FITS provenance.
    pub target: Option<String>,
    /// Total number of frames folded across every fold so far.
    pub total_frames: usize,
    /// Total integration time accumulated (seconds), summed across folds.
    pub total_integration_seconds: f64,
    /// Per-fold log, oldest first.
    pub folds: Vec<FoldRecord>,
}

/// Per-pixel running accumulator state (channel-interleaved, matching
/// [`ImageData`] layout). Every vector has `width × height × channels` entries.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PerPixelAccumulator {
    /// Σ wᵢ (sum of weights) per pixel/channel.
    pub sum_w: Vec<f64>,
    /// Σ wᵢ² (sum of squared weights) per pixel/channel. Needed for the
    /// *unbiased* reliability-weighted running variance used by the online clip
    /// (the same `Σwᵢ − Σwᵢ²/Σwᵢ` effective-sample-size correction the batch
    /// integrator uses). Additive across batches like every other running sum.
    pub sum_w2: Vec<f64>,
    /// Σ wᵢ·xᵢ per pixel/channel — finalize = `sum_wx / sum_w`.
    pub sum_wx: Vec<f64>,
    /// Σ wᵢ·xᵢ² per pixel/channel — running variance for SNR + online clip.
    pub sum_wx2: Vec<f64>,
    /// Number of samples that contributed per pixel/channel (coverage depth).
    pub coverage: Vec<u32>,
    /// Number of samples rejected by the online clip per pixel/channel.
    pub rejected: Vec<u32>,
}

impl PerPixelAccumulator {
    /// A zeroed accumulator sized for `len` pixel/channel slots.
    fn zeroed(len: usize) -> Self {
        Self {
            sum_w: vec![0.0; len],
            sum_w2: vec![0.0; len],
            sum_wx: vec![0.0; len],
            sum_wx2: vec![0.0; len],
            coverage: vec![0; len],
            rejected: vec![0; len],
        }
    }

    /// Length of the per-slot vectors (= `width × height × channels`).
    fn len(&self) -> usize {
        self.sum_w.len()
    }

    /// Internal consistency check used on deserialize: every vector must be the
    /// same length and match the declared geometry.
    fn is_consistent(&self, expected_len: usize) -> bool {
        self.sum_w.len() == expected_len
            && self.sum_w2.len() == expected_len
            && self.sum_wx.len() == expected_len
            && self.sum_wx2.len() == expected_len
            && self.coverage.len() == expected_len
            && self.rejected.len() == expected_len
    }
}

// Configuration for creating a master

/// How to create a new [`IntegratedMaster`].
#[derive(Debug, Clone, Default)]
pub struct MasterCreateConfig {
    /// Folding + online-rejection mode.
    pub mode: AccumulationMode,
    /// Provenance metadata seeded onto the master (totals are managed by the
    /// master itself; the caller supplies filter/target).
    pub filter: Option<String>,
    /// Optional target name.
    pub target: Option<String>,
}

/// What a single [`add_frames`](IntegratedMaster::add_frames) call reports back.
#[derive(Debug, Clone, PartialEq)]
pub struct AddReport {
    /// Frames that actually contributed (weight > 0) in this call.
    pub frames_added: usize,
    /// Σ weights added in this call.
    pub weight_added: f64,
    /// Samples rejected by the online clip in this call.
    pub rejected: u64,
    /// Master's running total frame count after this call.
    pub total_frames: usize,
}

// Errors

/// Errors from the accumulating-master API. Every variant is a caller mistake
/// (a degenerate reference, a mismatched sub, a corrupt sidecar) surfaced loudly
/// rather than silently producing a wrong master.
#[derive(Debug, thiserror::Error, PartialEq)]
pub enum MasterError {
    /// The reference frame passed to [`IntegratedMaster::create`] has a zero
    /// dimension or channel count.
    #[error("reference frame has a zero dimension: {width}×{height}×{channels}")]
    ZeroDimension {
        width: u32,
        height: u32,
        channels: u32,
    },
    /// The reference frame's pixel type is not supported (must be U16 or F32).
    #[error("reference pixel type {0:?} is not supported; use U16 or F32")]
    UnsupportedReferenceType(PixelType),
    /// A frame's geometry does not match the master's frozen reference grid.
    #[error(
        "frame {index} geometry {got_w}×{got_h}×{got_c} does not match the master reference {ref_w}×{ref_h}×{ref_c}"
    )]
    GeometryMismatch {
        index: usize,
        got_w: u32,
        got_h: u32,
        got_c: u32,
        ref_w: u32,
        ref_h: u32,
        ref_c: u32,
    },
    /// A frame's buffer length does not match `width × height × channels`.
    #[error("frame {index} has {got} samples but the master grid expects {expected}")]
    FrameSizeMismatch {
        index: usize,
        got: usize,
        expected: usize,
    },
    /// A frame's coverage mask does not describe the master's pixel grid.
    #[error("frame {index} coverage mask is {mask} px but the master grid is {expected} px")]
    CoverageSizeMismatch {
        index: usize,
        mask: usize,
        expected: usize,
    },
    /// `qualities`/`exposures` length disagrees with `frames` length.
    #[error("per-frame metadata length {meta} does not match frame count {frames}")]
    MetadataLengthMismatch { meta: usize, frames: usize },
    /// The serialized sidecar is shorter than its fixed header.
    #[error("serialized master is truncated: {got} bytes, need at least {need}")]
    Truncated { got: usize, need: usize },
    /// The serialized sidecar did not start with [`MASTER_MAGIC`].
    #[error("serialized master has bad magic bytes (not a Skotiq master sidecar)")]
    BadMagic,
    /// The serialized sidecar's version is not [`MASTER_STATE_VERSION`].
    #[error(
        "serialized master version {got} is unsupported (this build reads version {supported})"
    )]
    UnsupportedVersion { got: u32, supported: u32 },
    /// The serialized sidecar's metadata header could not be parsed.
    #[error("serialized master metadata is corrupt: {0}")]
    CorruptMetadata(String),
    /// The deserialized state vectors are internally inconsistent (wrong length
    /// for the declared geometry) — a corrupt or truncated payload.
    #[error("serialized master payload is inconsistent with its declared geometry")]
    InconsistentPayload,
}

// The accumulating master

/// A resumable, multi-night accumulating master frame.
///
/// Create one from the reference frame, fold in each night's prepared subs with
/// [`add_frames`](Self::add_frames), persist the running state between sessions
/// with [`serialize`](Self::serialize) / [`deserialize`](Self::deserialize), and
/// produce the shareable linear master at any time with
/// [`finalize`](Self::finalize).
#[derive(Debug, Clone, PartialEq)]
pub struct IntegratedMaster {
    /// On-disk state version (== [`MASTER_STATE_VERSION`] for in-memory masters).
    pub version: u32,
    /// Folding + online-rejection mode.
    pub mode: AccumulationMode,
    /// Frozen geometric reference (the common grid).
    pub geometry: GeometryReference,
    /// Frozen photometric reference baseline.
    pub norm_reference: NormalizationReference,
    /// Per-pixel running accumulator state.
    pub state: PerPixelAccumulator,
    /// Provenance + summary metadata.
    pub metadata: MasterMetadata,
}

impl IntegratedMaster {
    /// Create a fresh master anchored to `reference`.
    ///
    /// The reference frame defines the frozen geometric grid (its dimensions +
    /// channel count) and the frozen photometric baseline (per-channel
    /// background = robust median, scale = robust signal spread). It does **not**
    /// itself contribute a sample to the running sums — it is the anchor, not the
    /// first sub. Fold the first night's subs (including the one chosen as the
    /// reference, if desired) via [`add_frames`](Self::add_frames).
    pub fn create(reference: &ImageData, cfg: &MasterCreateConfig) -> Result<Self, MasterError> {
        if reference.width == 0 || reference.height == 0 || reference.channels == 0 {
            return Err(MasterError::ZeroDimension {
                width: reference.width,
                height: reference.height,
                channels: reference.channels,
            });
        }

        let ref_pixels = reference_to_f64(reference)?;
        let channels = reference.channels as usize;
        let locations = (reference.width as usize) * (reference.height as usize);

        let (background, scale) = reference_baseline(&ref_pixels, locations, channels);

        let len = locations * channels;
        Ok(Self {
            version: MASTER_STATE_VERSION,
            mode: cfg.mode,
            geometry: GeometryReference {
                width: reference.width,
                height: reference.height,
                channels: reference.channels,
            },
            norm_reference: NormalizationReference { background, scale },
            state: PerPixelAccumulator::zeroed(len),
            metadata: MasterMetadata {
                filter: cfg.filter.clone(),
                target: cfg.target.clone(),
                total_frames: 0,
                total_integration_seconds: 0.0,
                folds: Vec::new(),
            },
        })
    }

    /// Fold a batch of aligned, normalized, weighted frames into the running
    /// state.
    ///
    /// `exposures` (optional) carries each frame's exposure time in seconds for
    /// the integration-time bookkeeping; pass `&[]` to skip it. `label` tags the
    /// resulting [`FoldRecord`] (e.g. the night's ISO date). Frames with weight
    /// ≤ 0 are skipped (the weighting stage already deemed them worthless).
    ///
    /// Returns an error — rather than a partially-folded state — if any frame's
    /// geometry, buffer length, coverage mask, or metadata length is wrong. The
    /// validation runs **before** any mutation so a bad batch never corrupts an
    /// existing master.
    pub fn add_frames(
        &mut self,
        frames: &[IntegrationFrame<'_>],
        exposures: &[f64],
        label: &str,
    ) -> Result<AddReport, MasterError> {
        let w = self.geometry.width as usize;
        let h = self.geometry.height as usize;
        let c = self.geometry.channels as usize;
        let locations = w * h;
        let expected_len = locations * c;

        if !exposures.is_empty() && exposures.len() != frames.len() {
            return Err(MasterError::MetadataLengthMismatch {
                meta: exposures.len(),
                frames: frames.len(),
            });
        }

        // Validate the whole batch up front (fail-before-mutate).
        for (i, f) in frames.iter().enumerate() {
            if f.pixels.len() != expected_len {
                return Err(MasterError::FrameSizeMismatch {
                    index: i,
                    got: f.pixels.len(),
                    expected: expected_len,
                });
            }
            if let Some(mask) = f.coverage {
                let mask_len = mask.width() * mask.height();
                if mask_len != locations {
                    return Err(MasterError::CoverageSizeMismatch {
                        index: i,
                        mask: mask_len,
                        expected: locations,
                    });
                }
            }
        }

        let clip = match self.mode {
            AccumulationMode::RunningWeightedMean { clip } => clip,
        };

        let mut frames_added = 0usize;
        let mut weight_added = 0.0f64;
        let mut rejected_this_fold: u64 = 0;
        let mut seconds_added = 0.0f64;

        for (i, f) in frames.iter().enumerate() {
            if f.weight <= 0.0 || !f.weight.is_finite() {
                continue;
            }
            frames_added += 1;
            weight_added += f.weight;
            if let Some(exp) = exposures.get(i) {
                if exp.is_finite() && *exp > 0.0 {
                    seconds_added += *exp;
                }
            }

            rejected_this_fold += self.fold_one(f, clip, locations, c);
        }

        self.metadata.total_frames += frames_added;
        self.metadata.total_integration_seconds += seconds_added;
        self.metadata.folds.push(FoldRecord {
            frames_added,
            weight_added,
            integration_seconds_added: seconds_added,
            rejected: rejected_this_fold,
            label: label.to_string(),
        });

        Ok(AddReport {
            frames_added,
            weight_added,
            rejected: rejected_this_fold,
            total_frames: self.metadata.total_frames,
        })
    }

    /// Fold a single frame's covered, finite pixels into the running state,
    /// applying the online clip if configured. Returns the number of samples
    /// this frame rejected.
    fn fold_one(
        &mut self,
        f: &IntegrationFrame<'_>,
        clip: Option<OnlineClip>,
        locations: usize,
        channels: usize,
    ) -> u64 {
        let w = f.weight;
        let mut rejected: u64 = 0;
        let st = &mut self.state;

        for loc in 0..locations {
            let covered = f.coverage.map(|m| m.is_valid_at(loc)).unwrap_or(true);
            if !covered {
                continue;
            }
            for ch in 0..channels {
                let slot = loc * channels + ch;
                let v = f.pixels[slot];
                if !v.is_finite() {
                    continue;
                }

                // Online robust clip against the *current* running distribution.
                // Only applied once a pixel has enough history to estimate σ;
                // before that, every sample is accepted (we cannot reject against
                // an undefined distribution without throwing away the first subs).
                if let Some(clip) = clip {
                    if st.coverage[slot] >= MIN_HISTORY_FOR_CLIP {
                        let sw = st.sum_w[slot];
                        // Unbiased reliability-weighted variance: divide the
                        // weighted squared deviation by the effective sample
                        // size `Σw − Σw²/Σw` (Bessel-style correction), the same
                        // estimator the batch integrator uses. The *biased*
                        // population variance (`Σwx²/Σw − μ²`) systematically
                        // underestimates σ when only a handful of samples have
                        // accumulated, which would over-clip clean tail samples
                        // on the first few nights — exactly the regime the online
                        // clip is most exposed to.
                        let denom = sw - st.sum_w2[slot] / sw;
                        if sw > 0.0 && denom > 0.0 {
                            let mean = st.sum_wx[slot] / sw;
                            // Σw·(x−μ)² = Σwx² − 2μ·Σwx + μ²·Σw = Σwx² − μ²·Σw.
                            let weighted_sq_dev = (st.sum_wx2[slot] - mean * mean * sw).max(0.0);
                            let var = weighted_sq_dev / denom;
                            let sigma = var.sqrt();
                            if sigma > 0.0 {
                                let lo = mean - clip.low * sigma;
                                let hi = mean + clip.high * sigma;
                                if v < lo || v > hi {
                                    st.rejected[slot] = st.rejected[slot].saturating_add(1);
                                    rejected += 1;
                                    continue;
                                }
                            }
                        }
                    }
                }

                st.sum_w[slot] += w;
                st.sum_w2[slot] += w * w;
                st.sum_wx[slot] += w * v;
                st.sum_wx2[slot] += w * v * v;
                st.coverage[slot] = st.coverage[slot].saturating_add(1);
            }
        }

        rejected
    }

    /// Produce the finalized linear master (`F32`) from the current running
    /// state: `master(p) = sum_wx(p) / sum_w(p)`. Pixels with no coverage
    /// (`sum_w == 0`) are zero-filled. This can be called at any time and any
    /// number of times; it does not consume or alter the accumulator, so you can
    /// finalize, fold another night, and finalize again.
    pub fn finalize(&self) -> ImageData {
        let len = self.state.len();
        let mut data = vec![0.0f32; len];
        for (i, out) in data.iter_mut().enumerate() {
            let sw = self.state.sum_w[i];
            *out = if sw > 0.0 {
                (self.state.sum_wx[i] / sw) as f32
            } else {
                0.0
            };
        }
        ImageData::from_f32(
            self.geometry.width,
            self.geometry.height,
            self.geometry.channels,
            &data,
        )
    }

    /// A per-pixel **coverage map** (`F32`, one channel per master channel):
    /// how many samples contributed at each pixel/channel. A diagnostic twin of
    /// [`finalize`](Self::finalize) (drizzle/edge coverage, depth-of-stack).
    pub fn coverage_map(&self) -> ImageData {
        let data: Vec<f32> = self.state.coverage.iter().map(|&c| c as f32).collect();
        ImageData::from_f32(
            self.geometry.width,
            self.geometry.height,
            self.geometry.channels,
            &data,
        )
    }

    /// A per-pixel **rejection map** (`F32`): how many samples the online clip
    /// rejected at each pixel/channel across the master's whole history.
    pub fn rejection_map(&self) -> ImageData {
        let data: Vec<f32> = self.state.rejected.iter().map(|&c| c as f32).collect();
        ImageData::from_f32(
            self.geometry.width,
            self.geometry.height,
            self.geometry.channels,
            &data,
        )
    }

    // Serialization (resumable sidecar)

    /// Serialize the running accumulator state into a self-contained, versioned
    /// blob (the `.skmaster` sidecar).
    ///
    /// Layout: `MAGIC (4) | version (u32 LE) | header_len (u32 LE) | JSON header
    /// | raw payload`. The JSON header carries the small, structured metadata
    /// (mode, geometry, normalization reference, provenance) and the *lengths*
    /// of the raw arrays; the raw payload carries the large per-pixel vectors as
    /// packed little-endian (`sum_w`, `sum_w2`, `sum_wx`, `sum_wx2` as f64;
    /// `coverage`, `rejected` as u32). Keeping the big arrays out of JSON makes the sidecar
    /// compact and fast to read/write even for 60 MP masters, while keeping the
    /// metadata human-inspectable.
    pub fn serialize(&self) -> Vec<u8> {
        let header = SerializedHeader {
            mode: self.mode,
            geometry: self.geometry.clone(),
            norm_reference: self.norm_reference.clone(),
            metadata: self.metadata.clone(),
            slot_count: self.state.len(),
        };
        // serde_json on a struct with only finite f64/u32/strings cannot fail;
        // unwrap is safe and keeping the signature infallible matches
        // `DefectMap::serialize`.
        let header_json = serde_json::to_vec(&header).expect("master header serializes");

        let len = self.state.len();
        let mut out = Vec::with_capacity(4 + 4 + 4 + header_json.len() + len * (8 * 4 + 4 * 2));
        out.extend_from_slice(MASTER_MAGIC);
        out.extend_from_slice(&MASTER_STATE_VERSION.to_le_bytes());
        out.extend_from_slice(&(header_json.len() as u32).to_le_bytes());
        out.extend_from_slice(&header_json);

        for &v in &self.state.sum_w {
            out.extend_from_slice(&v.to_le_bytes());
        }
        for &v in &self.state.sum_w2 {
            out.extend_from_slice(&v.to_le_bytes());
        }
        for &v in &self.state.sum_wx {
            out.extend_from_slice(&v.to_le_bytes());
        }
        for &v in &self.state.sum_wx2 {
            out.extend_from_slice(&v.to_le_bytes());
        }
        for &v in &self.state.coverage {
            out.extend_from_slice(&v.to_le_bytes());
        }
        for &v in &self.state.rejected {
            out.extend_from_slice(&v.to_le_bytes());
        }

        out
    }

    /// Reconstruct a master from a blob produced by [`serialize`](Self::serialize).
    ///
    /// Fails loudly (never silently misreads) on a bad magic, an unsupported
    /// version, a truncated payload, corrupt metadata, or state vectors whose
    /// lengths disagree with the declared geometry.
    pub fn deserialize(bytes: &[u8]) -> Result<Self, MasterError> {
        const FIXED_HEADER: usize = 4 + 4 + 4; // magic + version + header_len
        if bytes.len() < FIXED_HEADER {
            return Err(MasterError::Truncated {
                got: bytes.len(),
                need: FIXED_HEADER,
            });
        }
        if &bytes[0..4] != MASTER_MAGIC {
            return Err(MasterError::BadMagic);
        }
        let version = u32::from_le_bytes(bytes[4..8].try_into().expect("4 bytes"));
        if version != MASTER_STATE_VERSION {
            return Err(MasterError::UnsupportedVersion {
                got: version,
                supported: MASTER_STATE_VERSION,
            });
        }
        let header_len = u32::from_le_bytes(bytes[8..12].try_into().expect("4 bytes")) as usize;

        let header_start = FIXED_HEADER;
        let header_end = header_start
            .checked_add(header_len)
            .ok_or(MasterError::InconsistentPayload)?;
        if bytes.len() < header_end {
            return Err(MasterError::Truncated {
                got: bytes.len(),
                need: header_end,
            });
        }

        let header: SerializedHeader = serde_json::from_slice(&bytes[header_start..header_end])
            .map_err(|e| MasterError::CorruptMetadata(e.to_string()))?;

        let len = header.slot_count;
        let geom_len = (header.geometry.width as usize)
            .checked_mul(header.geometry.height as usize)
            .and_then(|wh| wh.checked_mul(header.geometry.channels as usize))
            .ok_or(MasterError::InconsistentPayload)?;
        if len != geom_len {
            return Err(MasterError::InconsistentPayload);
        }

        let f64_bytes = len.checked_mul(8).ok_or(MasterError::InconsistentPayload)?;
        let u32_bytes = len.checked_mul(4).ok_or(MasterError::InconsistentPayload)?;
        let payload_len = f64_bytes
            .checked_mul(4)
            .and_then(|x| x.checked_add(u32_bytes.checked_mul(2)?))
            .ok_or(MasterError::InconsistentPayload)?;
        let total_needed = header_end
            .checked_add(payload_len)
            .ok_or(MasterError::InconsistentPayload)?;
        if bytes.len() < total_needed {
            return Err(MasterError::Truncated {
                got: bytes.len(),
                need: total_needed,
            });
        }

        let mut cursor = header_end;
        let sum_w = read_f64_array(bytes, &mut cursor, len);
        let sum_w2 = read_f64_array(bytes, &mut cursor, len);
        let sum_wx = read_f64_array(bytes, &mut cursor, len);
        let sum_wx2 = read_f64_array(bytes, &mut cursor, len);
        let coverage = read_u32_array(bytes, &mut cursor, len);
        let rejected = read_u32_array(bytes, &mut cursor, len);

        let state = PerPixelAccumulator {
            sum_w,
            sum_w2,
            sum_wx,
            sum_wx2,
            coverage,
            rejected,
        };
        if !state.is_consistent(len) {
            return Err(MasterError::InconsistentPayload);
        }

        Ok(Self {
            version,
            mode: header.mode,
            geometry: header.geometry,
            norm_reference: header.norm_reference,
            state,
            metadata: header.metadata,
        })
    }
}

/// Minimum number of accumulated samples at a pixel before the online clip is
/// allowed to reject. Below this the running σ is too poorly determined to make
/// an honest rejection decision, so early subs are always accepted (the same
/// principle the batch rejectors use when they refuse to clip < 3 samples).
const MIN_HISTORY_FOR_CLIP: u32 = 5;

/// The JSON-serialized portion of the sidecar (small structured fields + the
/// array length, so the raw payload that follows can be sliced exactly).
#[derive(Debug, Serialize, Deserialize)]
struct SerializedHeader {
    mode: AccumulationMode,
    geometry: GeometryReference,
    norm_reference: NormalizationReference,
    metadata: MasterMetadata,
    slot_count: usize,
}

// Helpers

/// Read the reference frame into a flat f64 buffer (channel-interleaved). Only
/// U16 and F32 references are supported; everything else is a caller error.
fn reference_to_f64(reference: &ImageData) -> Result<Vec<f64>, MasterError> {
    match reference.pixel_type {
        PixelType::U16 => Ok(reference
            .as_u16()
            .expect("U16 image yields u16 data")
            .into_iter()
            .map(|v| v as f64)
            .collect()),
        PixelType::F32 => Ok(reference
            .as_f32()
            .expect("F32 image yields f32 data")
            .into_iter()
            .map(|v| v as f64)
            .collect()),
        other => Err(MasterError::UnsupportedReferenceType(other)),
    }
}

/// Estimate the frozen per-channel photometric baseline from the reference:
/// `background` = robust median, `scale` = robust signal spread (the gap between
/// a high percentile and the median, a stable proxy for the frame's signal
/// range). These are stored as the photometric anchor; they are diagnostics +
/// provenance, not applied to incoming frames here.
fn reference_baseline(
    ref_pixels: &[f64],
    locations: usize,
    channels: usize,
) -> (Vec<f64>, Vec<f64>) {
    let mut background = vec![0.0f64; channels];
    let mut scale = vec![1.0f64; channels];

    for ch in 0..channels {
        let mut vals: Vec<f64> = Vec::with_capacity(locations);
        for loc in 0..locations {
            let v = ref_pixels[loc * channels + ch];
            if v.is_finite() {
                vals.push(v);
            }
        }
        if vals.is_empty() {
            continue;
        }
        vals.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        let median = percentile_of_sorted(&vals, 0.5);
        let high = percentile_of_sorted(&vals, 0.95);
        background[ch] = median;
        // Signal spread; floored to 1.0 so a flat reference does not yield a
        // degenerate zero scale.
        scale[ch] = (high - median).max(1.0);
    }

    (background, scale)
}

/// Read `len` little-endian f64 values from `bytes` starting at `*cursor`,
/// advancing the cursor. The caller has already bounds-checked the total length.
fn read_f64_array(bytes: &[u8], cursor: &mut usize, len: usize) -> Vec<f64> {
    let mut out = Vec::with_capacity(len);
    for _ in 0..len {
        let c = *cursor;
        let v = f64::from_le_bytes(bytes[c..c + 8].try_into().expect("8 bytes"));
        out.push(v);
        *cursor += 8;
    }
    out
}

/// Read `len` little-endian u32 values from `bytes` starting at `*cursor`,
/// advancing the cursor. The caller has already bounds-checked the total length.
fn read_u32_array(bytes: &[u8], cursor: &mut usize, len: usize) -> Vec<u32> {
    let mut out = Vec::with_capacity(len);
    for _ in 0..len {
        let c = *cursor;
        let v = u32::from_le_bytes(bytes[c..c + 4].try_into().expect("4 bytes"));
        out.push(v);
        *cursor += 4;
    }
    out
}

/// Validate that an [`IntegrationFrame`] matches a master's geometry, returning a
/// precise [`MasterError::GeometryMismatch`] if not. Exposed as a free function
/// so callers building an [`IntegrationFrame`] from an [`ImageData`] can check
/// the source image's dimensions before flattening it.
pub fn check_frame_geometry(
    index: usize,
    frame_width: u32,
    frame_height: u32,
    frame_channels: u32,
    reference: &GeometryReference,
) -> Result<(), MasterError> {
    if frame_width != reference.width
        || frame_height != reference.height
        || frame_channels != reference.channels
    {
        return Err(MasterError::GeometryMismatch {
            index,
            got_w: frame_width,
            got_h: frame_height,
            got_c: frame_channels,
            ref_w: reference.width,
            ref_h: reference.height,
            ref_c: reference.channels,
        });
    }
    Ok(())
}

/// Convenience: build an [`IntegrationFrame`]-compatible f64 buffer from an
/// [`ImageData`], validating it against the master geometry first.
///
/// This is the bridge from the on-disk image domain (U16/F32 [`ImageData`]) to
/// the f64 sample domain [`add_frames`](IntegratedMaster::add_frames) consumes.
/// It centralises the geometry check + pixel-type handling so callers do not
/// re-implement it (and cannot forget the geometry guard).
pub fn frame_buffer_for_master(
    index: usize,
    image: &ImageData,
    reference: &GeometryReference,
) -> Result<Vec<f64>, MasterError> {
    check_frame_geometry(index, image.width, image.height, image.channels, reference)?;
    reference_to_f64(image)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::integration::{integrate_frames, Combine, IntegrationConfig, Reject};
    use crate::normalization::CoverageMask;

    /// A tiny deterministic LCG for reproducible synthetic noise (mirrors the
    /// crate's existing test-noise idiom in `integration.rs` / `stacking.rs`).
    struct Lcg(u64);
    impl Lcg {
        fn next_f64(&mut self) -> f64 {
            self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1);
            (self.0 >> 11) as f64 / (1u64 << 53) as f64
        }
        fn next_gauss(&mut self) -> f64 {
            let s: f64 = (0..12).map(|_| self.next_f64()).sum();
            s - 6.0
        }
    }

    fn iframe<'a>(pixels: &'a [f64], weight: f64) -> IntegrationFrame<'a> {
        IntegrationFrame {
            pixels,
            weight,
            coverage: None,
        }
    }

    /// A U16 reference frame of the given geometry filled with a flat value.
    fn flat_u16(width: u32, height: u32, channels: u32, value: u16) -> ImageData {
        let len = (width as usize) * (height as usize) * (channels as usize);
        ImageData::from_u16(width, height, channels, &vec![value; len])
    }

    fn no_clip_mode() -> AccumulationMode {
        AccumulationMode::RunningWeightedMean { clip: None }
    }

    // Online-vs-batch parity (the headline correctness property)

    #[test]
    fn incremental_two_batches_equals_single_batch_weighted_mean() {
        // Build a population of synthetic mono subs, split into two batches.
        // Accumulating batch-1 then batch-2 must equal a single batch
        // integration (weighted mean, no rejection) of all of them, within ε.
        let w = 8u32;
        let h = 6u32;
        let px = (w * h) as usize;
        let mut lcg = Lcg(0xABCD_1234);

        let n1 = 5usize;
        let n2 = 7usize;
        let weights: Vec<f64> = (0..(n1 + n2)).map(|i| 0.5 + (i as f64) * 0.1).collect();

        let mut bufs: Vec<Vec<f64>> = Vec::new();
        for _ in 0..(n1 + n2) {
            let mut b = vec![0.0; px];
            for v in &mut b {
                *v = 1000.0 + lcg.next_gauss() * 30.0;
            }
            bufs.push(b);
        }

        // Single-batch reference (weighted mean, no rejection).
        let all_frames: Vec<_> = bufs
            .iter()
            .zip(&weights)
            .map(|(b, &wt)| iframe(b, wt))
            .collect();
        let batch = integrate_frames(
            &all_frames,
            w,
            h,
            1,
            &IntegrationConfig {
                combine: Combine::Mean,
                reject: Reject::None,
                ..Default::default()
            },
        )
        .unwrap();
        let batch_master = batch.master.as_f32().unwrap();

        // Accumulating path: create (anchor on a flat ref), fold batch 1, fold 2.
        let reference = flat_u16(w, h, 1, 1000);
        let mut master = IntegratedMaster::create(
            &reference,
            &MasterCreateConfig {
                mode: no_clip_mode(),
                ..Default::default()
            },
        )
        .unwrap();

        let b1: Vec<_> = bufs[..n1]
            .iter()
            .zip(&weights[..n1])
            .map(|(b, &wt)| iframe(b, wt))
            .collect();
        master.add_frames(&b1, &[], "night1").unwrap();

        let b2: Vec<_> = bufs[n1..]
            .iter()
            .zip(&weights[n1..])
            .map(|(b, &wt)| iframe(b, wt))
            .collect();
        master.add_frames(&b2, &[], "night2").unwrap();

        let acc_master = master.finalize().as_f32().unwrap();

        assert_eq!(acc_master.len(), batch_master.len());
        for (i, (a, b)) in acc_master.iter().zip(&batch_master).enumerate() {
            assert!(
                (*a as f64 - *b as f64).abs() < 1e-3,
                "pixel {i}: accumulated {a} != batch {b}"
            );
        }
        assert_eq!(master.metadata.total_frames, n1 + n2);
    }

    #[test]
    fn three_batches_equals_single_batch() {
        // Same parity property but split three ways and including a 3-channel
        // (OSC) frame so per-channel accumulation is exercised too.
        let w = 5u32;
        let h = 4u32;
        let c = 3u32;
        let px = (w * h * c) as usize;
        let mut lcg = Lcg(0x5151_7777);

        let n = 9usize;
        let mut bufs: Vec<Vec<f64>> = Vec::new();
        for _ in 0..n {
            let mut b = vec![0.0; px];
            for v in &mut b {
                *v = 500.0 + lcg.next_gauss() * 15.0;
            }
            bufs.push(b);
        }
        let weights: Vec<f64> = (0..n).map(|i| 1.0 + (i % 3) as f64).collect();

        let all: Vec<_> = bufs
            .iter()
            .zip(&weights)
            .map(|(b, &wt)| iframe(b, wt))
            .collect();
        let batch = integrate_frames(
            &all,
            w,
            h,
            c,
            &IntegrationConfig {
                combine: Combine::Mean,
                reject: Reject::None,
                ..Default::default()
            },
        )
        .unwrap();
        let batch_master = batch.master.as_f32().unwrap();

        let reference = flat_u16(w, h, c, 500);
        let mut master = IntegratedMaster::create(
            &reference,
            &MasterCreateConfig {
                mode: no_clip_mode(),
                ..Default::default()
            },
        )
        .unwrap();

        for chunk in [0..3usize, 3..6, 6..9] {
            let fr: Vec<_> = bufs[chunk.clone()]
                .iter()
                .zip(&weights[chunk])
                .map(|(b, &wt)| iframe(b, wt))
                .collect();
            master.add_frames(&fr, &[], "batch").unwrap();
        }

        let acc = master.finalize().as_f32().unwrap();
        for (a, b) in acc.iter().zip(&batch_master) {
            assert!((*a as f64 - *b as f64).abs() < 1e-3, "{a} != {b}");
        }
        assert_eq!(master.metadata.folds.len(), 3);
    }

    #[test]
    fn single_batch_via_accumulator_equals_direct_integration() {
        // Folding all frames in one add_frames call must also match the batch
        // integrator (sanity for the n_batches == 1 case).
        let w = 4u32;
        let h = 4u32;
        let px = (w * h) as usize;
        let mut lcg = Lcg(7);
        let n = 6;
        let bufs: Vec<Vec<f64>> = (0..n)
            .map(|_| (0..px).map(|_| 800.0 + lcg.next_gauss() * 20.0).collect())
            .collect();
        let frames: Vec<_> = bufs.iter().map(|b| iframe(b, 1.0)).collect();

        let batch = integrate_frames(
            &frames,
            w,
            h,
            1,
            &IntegrationConfig {
                reject: Reject::None,
                ..Default::default()
            },
        )
        .unwrap()
        .master
        .as_f32()
        .unwrap();

        let reference = flat_u16(w, h, 1, 800);
        let mut master = IntegratedMaster::create(
            &reference,
            &MasterCreateConfig {
                mode: no_clip_mode(),
                ..Default::default()
            },
        )
        .unwrap();
        master.add_frames(&frames, &[], "all").unwrap();
        let acc = master.finalize().as_f32().unwrap();

        for (a, b) in acc.iter().zip(&batch) {
            assert!((*a as f64 - *b as f64).abs() < 1e-3);
        }
    }

    // Serialize / deserialize round-trip

    #[test]
    fn serialize_deserialize_round_trips_exactly() {
        let w = 6u32;
        let h = 5u32;
        let c = 3u32;
        let px = (w * h * c) as usize;
        let mut lcg = Lcg(0xDEAD_BEEF);

        let reference = flat_u16(w, h, c, 1200);
        let mut master = IntegratedMaster::create(
            &reference,
            &MasterCreateConfig {
                mode: AccumulationMode::default(),
                filter: Some("Ha".to_string()),
                target: Some("NGC 7000".to_string()),
            },
        )
        .unwrap();

        // Fold a couple of batches with exposures so metadata is non-trivial.
        for night in 0..2 {
            let bufs: Vec<Vec<f64>> = (0..4)
                .map(|_| (0..px).map(|_| 1200.0 + lcg.next_gauss() * 25.0).collect())
                .collect();
            let frames: Vec<_> = bufs.iter().map(|b| iframe(b, 1.0 + night as f64)).collect();
            let exposures = vec![300.0; frames.len()];
            master
                .add_frames(&frames, &exposures, &format!("night{night}"))
                .unwrap();
        }

        let bytes = master.serialize();
        assert!(bytes.starts_with(MASTER_MAGIC));

        let restored = IntegratedMaster::deserialize(&bytes).expect("round trip");
        assert_eq!(restored, master);

        // And the finalized masters match bit-for-bit.
        let a = master.finalize().as_f32().unwrap();
        let b = restored.finalize().as_f32().unwrap();
        assert_eq!(a, b);
    }

    #[test]
    fn resume_from_sidecar_then_add_matches_uninterrupted() {
        // Folding night1, serializing, deserializing, then folding night2 must
        // equal folding night1+night2 in one uninterrupted master.
        let w = 4u32;
        let h = 4u32;
        let px = (w * h) as usize;
        let mut lcg = Lcg(0x1111_2222);

        let n1: Vec<Vec<f64>> = (0..3)
            .map(|_| (0..px).map(|_| 700.0 + lcg.next_gauss() * 10.0).collect())
            .collect();
        let n2: Vec<Vec<f64>> = (0..4)
            .map(|_| (0..px).map(|_| 700.0 + lcg.next_gauss() * 10.0).collect())
            .collect();

        let reference = flat_u16(w, h, 1, 700);
        let cfg = MasterCreateConfig {
            mode: no_clip_mode(),
            ..Default::default()
        };

        // Uninterrupted.
        let mut whole = IntegratedMaster::create(&reference, &cfg).unwrap();
        let f1: Vec<_> = n1.iter().map(|b| iframe(b, 1.0)).collect();
        let f2: Vec<_> = n2.iter().map(|b| iframe(b, 1.0)).collect();
        whole.add_frames(&f1, &[], "n1").unwrap();
        whole.add_frames(&f2, &[], "n2").unwrap();

        // Resumed.
        let mut part = IntegratedMaster::create(&reference, &cfg).unwrap();
        part.add_frames(&f1, &[], "n1").unwrap();
        let bytes = part.serialize();
        let mut resumed = IntegratedMaster::deserialize(&bytes).unwrap();
        resumed.add_frames(&f2, &[], "n2").unwrap();

        let a = whole.finalize().as_f32().unwrap();
        let b = resumed.finalize().as_f32().unwrap();
        for (x, y) in a.iter().zip(&b) {
            assert!((*x as f64 - *y as f64).abs() < 1e-6, "{x} != {y}");
        }
        assert_eq!(whole.metadata.total_frames, resumed.metadata.total_frames);
    }

    // Mismatched-geometry rejection

    #[test]
    fn create_rejects_zero_dimension_reference() {
        let bad = ImageData::new(0, 4, 1, PixelType::U16);
        let err = IntegratedMaster::create(&bad, &MasterCreateConfig::default()).unwrap_err();
        assert!(matches!(err, MasterError::ZeroDimension { .. }));
    }

    #[test]
    fn create_rejects_unsupported_reference_type() {
        let bad = ImageData::new(4, 4, 1, PixelType::U8);
        let err = IntegratedMaster::create(&bad, &MasterCreateConfig::default()).unwrap_err();
        assert_eq!(err, MasterError::UnsupportedReferenceType(PixelType::U8));
    }

    #[test]
    fn add_frames_rejects_wrong_buffer_length() {
        let reference = flat_u16(4, 4, 1, 100);
        let mut master =
            IntegratedMaster::create(&reference, &MasterCreateConfig::default()).unwrap();
        // 4x4 mono expects 16 samples; pass 15.
        let bad = vec![100.0; 15];
        let frames = [iframe(&bad, 1.0)];
        let err = master.add_frames(&frames, &[], "bad").unwrap_err();
        assert_eq!(
            err,
            MasterError::FrameSizeMismatch {
                index: 0,
                got: 15,
                expected: 16,
            }
        );
        // The master must be untouched after a failed batch.
        assert_eq!(master.metadata.total_frames, 0);
        assert!(master.metadata.folds.is_empty());
    }

    #[test]
    fn add_frames_rejects_wrong_coverage_size() {
        let reference = flat_u16(2, 2, 1, 100);
        let mut master =
            IntegratedMaster::create(&reference, &MasterCreateConfig::default()).unwrap();
        let pixels = vec![100.0; 4];
        let bad_mask = CoverageMask::new(1, 1, vec![true]).unwrap(); // 1 px, grid is 4
        let frames = [IntegrationFrame {
            pixels: &pixels,
            weight: 1.0,
            coverage: Some(&bad_mask),
        }];
        let err = master.add_frames(&frames, &[], "bad").unwrap_err();
        assert_eq!(
            err,
            MasterError::CoverageSizeMismatch {
                index: 0,
                mask: 1,
                expected: 4,
            }
        );
    }

    #[test]
    fn add_frames_rejects_metadata_length_mismatch() {
        let reference = flat_u16(2, 2, 1, 100);
        let mut master =
            IntegratedMaster::create(&reference, &MasterCreateConfig::default()).unwrap();
        let p0 = vec![100.0; 4];
        let p1 = vec![100.0; 4];
        let frames = [iframe(&p0, 1.0), iframe(&p1, 1.0)];
        // 2 frames, 1 exposure.
        let err = master.add_frames(&frames, &[300.0], "bad").unwrap_err();
        assert_eq!(
            err,
            MasterError::MetadataLengthMismatch { meta: 1, frames: 2 }
        );
    }

    #[test]
    fn check_frame_geometry_flags_mismatch() {
        let reference = GeometryReference {
            width: 100,
            height: 80,
            channels: 1,
        };
        // Right geometry passes.
        assert!(check_frame_geometry(0, 100, 80, 1, &reference).is_ok());
        // Wrong width fails with a precise error.
        let err = check_frame_geometry(2, 100, 81, 1, &reference).unwrap_err();
        assert_eq!(
            err,
            MasterError::GeometryMismatch {
                index: 2,
                got_w: 100,
                got_h: 81,
                got_c: 1,
                ref_w: 100,
                ref_h: 80,
                ref_c: 1,
            }
        );
    }

    #[test]
    fn frame_buffer_for_master_validates_then_flattens() {
        let reference = GeometryReference {
            width: 2,
            height: 2,
            channels: 1,
        };
        let img = ImageData::from_u16(2, 2, 1, &[1, 2, 3, 4]);
        let buf = frame_buffer_for_master(0, &img, &reference).unwrap();
        assert_eq!(buf, vec![1.0, 2.0, 3.0, 4.0]);

        let wrong = ImageData::from_u16(3, 2, 1, &[0; 6]);
        let err = frame_buffer_for_master(1, &wrong, &reference).unwrap_err();
        assert!(matches!(err, MasterError::GeometryMismatch { .. }));
    }

    // Online clip behaviour

    #[test]
    fn online_clip_rejects_a_late_transient() {
        // Build up a clean running distribution, then fold one sub with a gross
        // spike at a single pixel: the spike must be rejected and the finalized
        // pixel must stay near the clean mean.
        let w = 1u32;
        let h = 1u32;
        let reference = flat_u16(w, h, 1, 100);
        let mut master = IntegratedMaster::create(
            &reference,
            &MasterCreateConfig {
                mode: AccumulationMode::RunningWeightedMean {
                    clip: Some(OnlineClip {
                        low: 3.0,
                        high: 3.0,
                    }),
                },
                ..Default::default()
            },
        )
        .unwrap();

        // Ten clean subs around 100 with small scatter (establishes σ).
        let mut lcg = Lcg(0x00C0_FFEE);
        for _ in 0..10 {
            let v = vec![100.0 + lcg.next_gauss() * 2.0];
            master.add_frames(&[iframe(&v, 1.0)], &[], "clean").unwrap();
        }
        // One transient.
        let spike = vec![9000.0];
        let report = master
            .add_frames(&[iframe(&spike, 1.0)], &[], "spike")
            .unwrap();
        assert_eq!(report.rejected, 1, "the spike must be clipped");

        let m = master.finalize().as_f32().unwrap()[0] as f64;
        assert!(
            (m - 100.0).abs() < 5.0,
            "finalized pixel {m} should stay near 100"
        );
        // The rejection map must record exactly one rejection at the pixel.
        let rej = master.rejection_map().as_f32().unwrap();
        assert_eq!(rej[0] as u32, 1);
    }

    /// Pin the online clip's Bessel-corrected weighted variance/σ at the
    /// accept/reject boundary, so the late-transient path is characterized beyond
    /// the gross ~3000σ spike `online_clip_rejects_a_late_transient` exercises.
    /// The running σ is computed independently and the clip's decision is probed
    /// just inside, just outside, and — decisively — in the gap between the
    /// *biased* (`Σwx²/Σw − μ²`) and the *unbiased* (effective-sample-size
    /// corrected) σ, proving the estimator applies the Bessel correction.
    #[test]
    fn online_clip_variance_is_unbiased_and_pins_the_boundary() {
        // Ten clean unit-weight samples at one pixel. With every weight == 1 the
        // online estimator reduces to the textbook sample variance with an N−1
        // (Bessel) denominator: var = Σ(x−μ)² / (N−1). The values are chosen so
        // none are clipped during buildup (asserted below), so the master's
        // internal running sums match this exact population.
        let clean = [
            98.0, 99.0, 100.0, 101.0, 102.0, 100.0, 99.0, 101.0, 98.0, 102.0,
        ];
        let n = clean.len() as f64;
        let mean = clean.iter().sum::<f64>() / n; // 100.0
        let ss: f64 = clean.iter().map(|x| (x - mean).powi(2)).sum(); // 20.0
        let sigma_unbiased = (ss / (n - 1.0)).sqrt(); // sqrt(20/9)
        let sigma_biased = (ss / n).sqrt(); // sqrt(20/10)
        assert!(
            sigma_unbiased > sigma_biased,
            "the unbiased σ must exceed the biased one"
        );

        let k = 3.0;
        // Build a master that has folded exactly the ten clean samples, asserting
        // zero buildup rejections so its sums correspond to `clean` precisely.
        let build = || {
            let reference = flat_u16(1, 1, 1, 100);
            let mut m = IntegratedMaster::create(
                &reference,
                &MasterCreateConfig {
                    mode: AccumulationMode::RunningWeightedMean {
                        clip: Some(OnlineClip { low: k, high: k }),
                    },
                    ..Default::default()
                },
            )
            .unwrap();
            for v in clean {
                let f = [v];
                let r = m.add_frames(&[iframe(&f, 1.0)], &[], "clean").unwrap();
                assert_eq!(
                    r.rejected, 0,
                    "no clean sample may be clipped during buildup"
                );
            }
            m
        };

        // Boundary pin: a sample 1e-6 inside the unbiased upper bound `mean+k·σ`
        // is accepted; 1e-6 outside is rejected. The 1e-6 margin is far larger
        // than f64 rounding, so this can only hold if the master's running σ
        // equals the independently computed unbiased σ.
        let hi = mean + k * sigma_unbiased;
        {
            let mut m = build();
            let v = [hi - 1e-6];
            assert_eq!(
                m.add_frames(&[iframe(&v, 1.0)], &[], "inside")
                    .unwrap()
                    .rejected,
                0,
                "a sample just inside mean+k·σ must be accepted"
            );
        }
        {
            let mut m = build();
            let v = [hi + 1e-6];
            assert_eq!(
                m.add_frames(&[iframe(&v, 1.0)], &[], "outside")
                    .unwrap()
                    .rejected,
                1,
                "a sample just outside mean+k·σ must be rejected"
            );
        }

        // Decisive Bessel-correction pin: a sample in the gap between the biased
        // and unbiased upper bounds must be ACCEPTED. A biased (N denom) σ would
        // place the bound below it and wrongly reject it; only the unbiased (N−1)
        // σ keeps it inside.
        let between = mean + k * (sigma_biased + sigma_unbiased) / 2.0;
        assert!(
            between > mean + k * sigma_biased && between < mean + k * sigma_unbiased,
            "the probe must lie strictly between the biased and unbiased bounds"
        );
        {
            let mut m = build();
            let v = [between];
            assert_eq!(
                m.add_frames(&[iframe(&v, 1.0)], &[], "between")
                    .unwrap()
                    .rejected,
                0,
                "a sample inside the unbiased bound but outside the biased bound \
                 must be accepted — the clip must use the Bessel-corrected σ"
            );
        }
    }

    #[test]
    fn no_clip_mode_folds_every_sample() {
        // With clip == None even a wild value is folded (the exact-mean mode).
        let reference = flat_u16(1, 1, 1, 100);
        let mut master = IntegratedMaster::create(
            &reference,
            &MasterCreateConfig {
                mode: no_clip_mode(),
                ..Default::default()
            },
        )
        .unwrap();
        let a = vec![100.0];
        let b = vec![300.0];
        master.add_frames(&[iframe(&a, 1.0)], &[], "a").unwrap();
        let report = master.add_frames(&[iframe(&b, 1.0)], &[], "b").unwrap();
        assert_eq!(report.rejected, 0);
        let m = master.finalize().as_f32().unwrap()[0] as f64;
        assert!((m - 200.0).abs() < 1e-4, "got {m}");
    }

    // Coverage handling + maps

    #[test]
    fn coverage_mask_limits_contribution_and_map() {
        // 2x1 mono, 3 frames; frame 0 does not cover pixel 1. Pixel 1 coverage
        // must be 2, pixel 0 must be 3, and finalize must ignore the masked junk.
        let reference = flat_u16(2, 1, 1, 10);
        let mut master = IntegratedMaster::create(
            &reference,
            &MasterCreateConfig {
                mode: no_clip_mode(),
                ..Default::default()
            },
        )
        .unwrap();
        let f0 = [10.0, 999.0];
        let f1 = [10.0, 20.0];
        let f2 = [10.0, 20.0];
        let mask0 = CoverageMask::new(2, 1, vec![true, false]).unwrap();
        let frames = [
            IntegrationFrame {
                pixels: &f0,
                weight: 1.0,
                coverage: Some(&mask0),
            },
            iframe(&f1, 1.0),
            iframe(&f2, 1.0),
        ];
        master.add_frames(&frames, &[], "cov").unwrap();

        let m = master.finalize().as_f32().unwrap();
        assert!((m[0] as f64 - 10.0).abs() < 1e-4);
        assert!(
            (m[1] as f64 - 20.0).abs() < 1e-4,
            "masked junk leaked: {}",
            m[1]
        );

        let cov = master.coverage_map().as_f32().unwrap();
        assert_eq!(cov[0] as u32, 3);
        assert_eq!(cov[1] as u32, 2);
    }

    #[test]
    fn zero_and_negative_weight_frames_are_skipped() {
        let reference = flat_u16(1, 1, 1, 50);
        let mut master = IntegratedMaster::create(
            &reference,
            &MasterCreateConfig {
                mode: no_clip_mode(),
                ..Default::default()
            },
        )
        .unwrap();
        let good = vec![50.0];
        let zero = vec![9999.0];
        let neg = vec![1234.0];
        let frames = [iframe(&good, 1.0), iframe(&zero, 0.0), iframe(&neg, -1.0)];
        let report = master.add_frames(&frames, &[], "mixed").unwrap();
        assert_eq!(report.frames_added, 1);
        let m = master.finalize().as_f32().unwrap()[0] as f64;
        assert!((m - 50.0).abs() < 1e-4, "got {m}");
    }

    // Deserialize failure modes

    #[test]
    fn deserialize_rejects_bad_magic() {
        let err =
            IntegratedMaster::deserialize(b"BADM\x01\x00\x00\x00\x00\x00\x00\x00").unwrap_err();
        assert_eq!(err, MasterError::BadMagic);
    }

    #[test]
    fn deserialize_rejects_truncated_blob() {
        let err = IntegratedMaster::deserialize(b"NSM").unwrap_err();
        assert!(matches!(err, MasterError::Truncated { .. }));
    }

    #[test]
    fn deserialize_rejects_unsupported_version() {
        // Valid magic, version 99, zero header len.
        let mut blob = Vec::new();
        blob.extend_from_slice(MASTER_MAGIC);
        blob.extend_from_slice(&99u32.to_le_bytes());
        blob.extend_from_slice(&0u32.to_le_bytes());
        let err = IntegratedMaster::deserialize(&blob).unwrap_err();
        assert_eq!(
            err,
            MasterError::UnsupportedVersion {
                got: 99,
                supported: MASTER_STATE_VERSION,
            }
        );
    }

    #[test]
    fn deserialize_rejects_geometry_dimension_overflow() {
        // A header whose width×height×channels overflows usize must be rejected
        // as InconsistentPayload, not panic or wrap into a value that happens to
        // match a small slot_count. slot_count is tiny here while the declared
        // geometry product blows past usize::MAX.
        let header = SerializedHeader {
            mode: AccumulationMode::default(),
            geometry: GeometryReference {
                width: u32::MAX,
                height: u32::MAX,
                channels: 2,
            },
            norm_reference: NormalizationReference {
                background: vec![0.0],
                scale: vec![1.0],
            },
            metadata: MasterMetadata::default(),
            slot_count: 0,
        };
        let header_json = serde_json::to_vec(&header).unwrap();
        let mut blob = Vec::new();
        blob.extend_from_slice(MASTER_MAGIC);
        blob.extend_from_slice(&MASTER_STATE_VERSION.to_le_bytes());
        blob.extend_from_slice(&(header_json.len() as u32).to_le_bytes());
        blob.extend_from_slice(&header_json);
        // (No payload bytes: slot_count == 0, and the geometry check fires first.)
        let err = IntegratedMaster::deserialize(&blob).unwrap_err();
        assert_eq!(err, MasterError::InconsistentPayload);
    }

    #[test]
    fn deserialize_rejects_truncated_payload() {
        // Serialize a real master then chop off the last few payload bytes.
        let reference = flat_u16(3, 3, 1, 100);
        let mut master =
            IntegratedMaster::create(&reference, &MasterCreateConfig::default()).unwrap();
        let v = vec![100.0; 9];
        master.add_frames(&[iframe(&v, 1.0)], &[], "n").unwrap();
        let mut bytes = master.serialize();
        bytes.truncate(bytes.len() - 4);
        let err = IntegratedMaster::deserialize(&bytes).unwrap_err();
        assert!(matches!(err, MasterError::Truncated { .. }));
    }
}
