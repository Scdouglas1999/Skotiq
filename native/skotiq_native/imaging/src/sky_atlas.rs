//! The keystone: a HEALPix-tiled, out-of-core, **additive** all-sky accumulator.
//!
//! # Why this module exists
//!
//! [`crate::master_accumulation::IntegratedMaster`] already proves the core
//! property Skotiq 5.0 needs: a per-pixel weighted mean decomposes into the
//! six running sums (`sum_w`, `sum_w2`, `sum_wx`, `sum_wx2`, `coverage`,
//! `rejected`) that are **exactly additive across disjoint batches**, and the
//! state serialises to a resumable sidecar. Folding night-2 into night-1 is
//! bit-for-bit identical to integrating both at once. That is precisely the
//! algebra a federated co-add wants — if my sums and your sums live on the same
//! grid, `merged = mine + yours` is the correct deeper stack, computed without
//! re-reading a single sub.
//!
//! The master stops at one place: **a single fixed pixel grid**. This module
//! removes that limit. The sky is partitioned into **HEALPix NESTED tiles** at a
//! fixed [`ATLAS_HEALPIX_ORDER`]; each tile is its own small
//! `IntegratedMaster`-style additive accumulator
//! ([`SkyTileAccumulator`]) on a deterministic local tangent-plane WCS
//! ([`tile_wcs`]); and frames are reprojected into the tiles they touch using the
//! full CD + SIP astrometry ([`crate::wcs_sip::SipWcs`]) the plate solver
//! produces. A frame touching four tiles folds into four accumulators; nothing
//! is wasted at tile seams because the sums are additive and `finalize`
//! re-divides.
//!
//! # The additivity property (Pillar C's requirement)
//!
//! [`merge_tiles`] adds two [`SkyTileAccumulator`]s for the same tile id +
//! geometry by summing the six running vectors and unioning provenance. With
//! [`crate::master_accumulation::AccumulationMode::RunningWeightedMean`] and
//! `clip == None` this is **provably exact** versus folding both contributors'
//! frames into one accumulator — the master's online-vs-batch parity, lifted to
//! tiles. The master's caveat carries over: cross-batch *online* rejection is
//! not identical to a from-scratch full-population clip, so only with
//! `clip: None` is the merge exact. [`merge_tiles_subtract`] is the
//! retraction: a linear subtraction of a contributor's recorded delta.
//!
//! # Where tiles live
//!
//! Each tile accumulator serialises to a sidecar under
//! `<atlas_root>/tiles/<order>/<tileId>.nst` (magic [`TILE_MAGIC`], the same
//! layout discipline as the master's `.nsmaster`). The atlas is **out-of-core**:
//! a fold loads only the touched tiles, mutates them, and rewrites them; a query
//! loads only the tiles a cone covers. The whole sky is never held in RAM, and a
//! caller-supplied memory budget bounds how many tile buffers are resident at
//! once during a fold.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use serde::{Deserialize, Serialize};

/// Per-write nonce so each [`SkyAtlas::store_tile`] temp sidecar is unique even
/// when two folds for the SAME tile race (or two processes share the atlas):
/// the shared `nst.tmp` name let one fold's temp clobber another mid-write. The
/// final write-then-rename onto the real path stays atomic on the same fs.
static STORE_TILE_NONCE: AtomicU64 = AtomicU64::new(0);

use crate::master_accumulation::{AccumulationMode, NormalizationReference, PerPixelAccumulator};
use crate::registration::{sample_interleaved, Interpolator};
use crate::robust_stats::{percentile_nearest_rank as percentile_sorted, MAD_TO_SIGMA};
use crate::wcs_sip::SipWcs;
use crate::ImageData;

/// On-disk format version for a serialized [`SkyTileAccumulator`].
pub const TILE_STATE_VERSION: u32 = 1;
/// Magic bytes prefixing a serialized tile sidecar (`"NST" + version tag`).
pub const TILE_MAGIC: &[u8; 4] = b"NST1";

/// HEALPix NESTED tile id at a fixed base order. Builders pick the order const;
/// it is recorded in every tile + DB row so a mixed-order mix-up is detectable.
pub type TileId = u64;

/// Default HEALPix order for atlas tiles (`nside = 2^order`). Single source of
/// truth — echoed by the bridge, the hub `/v1/info`, and `migration_v52`.
pub const ATLAS_HEALPIX_ORDER: u32 = 9;
/// Per-tile raster edge in pixels (square tile grid).
pub const TILE_PIXELS: u32 = 1024;

/// Fractional margin added around a tile's angular extent when sizing its local
/// TAN grid, so a frame whose footprint clips a tile edge still resamples
/// cleanly into the neighbouring tile's interior (overlap is harmless — the sums
/// are additive and `finalize` re-divides).
const TILE_SCALE_MARGIN: f64 = 1.08;

// HEALPix NESTED addressing
//
// A from-scratch Rust implementation of the standard HEALPix NESTED scheme
// (Górski et al. 2005), the Rust twin of the Dart HiPS addressing reference. We
// implement exactly the pieces the atlas needs: `ang2pix_nest` (sky -> tile),
// `pix2ang_nest` (tile -> centre), and `neighbours_nest` (gap-free cone cover).

/// `nside` for a HEALPix order (`2^order`).
#[inline]
fn nside_for(order: u32) -> u64 {
    1u64 << order
}

/// Number of base-resolution pixels covering the sphere is 12; total pixels at
/// `nside` is `12 * nside²`.
#[inline]
fn npix_for(order: u32) -> u64 {
    let n = nside_for(order);
    12 * n * n
}

/// Spread the low 16 bits of `v` into the even bit positions (bit `k` -> bit
/// `2k`). The bit-interleaving primitive behind the NESTED <-> (x, y) mapping.
#[inline]
fn spread_bits(v: u32) -> u64 {
    let mut x = (v as u64) & 0xffff;
    x = (x | (x << 16)) & 0x0000_ffff_0000_ffff;
    x = (x | (x << 8)) & 0x00ff_00ff_00ff_00ff;
    x = (x | (x << 4)) & 0x0f0f_0f0f_0f0f_0f0f;
    x = (x | (x << 2)) & 0x3333_3333_3333_3333;
    x = (x | (x << 1)) & 0x5555_5555_5555_5555;
    x
}

/// Inverse of [`spread_bits`]: gather the even bits of `v` back into the low 16.
#[inline]
fn compress_bits(v: u64) -> u32 {
    let mut x = v & 0x5555_5555_5555_5555;
    x = (x | (x >> 1)) & 0x3333_3333_3333_3333;
    x = (x | (x >> 2)) & 0x0f0f_0f0f_0f0f_0f0f;
    x = (x | (x >> 4)) & 0x00ff_00ff_00ff_00ff;
    x = (x | (x >> 8)) & 0x0000_ffff_0000_ffff;
    x = (x | (x >> 16)) & 0x0000_0000_ffff_ffff;
    x as u32
}

/// Encode `(face, ix, iy)` into a NESTED pixel id.
#[inline]
fn xyf_to_nest(ix: u32, iy: u32, face: u32, order: u32) -> TileId {
    ((face as u64) << (2 * order)) | spread_bits(ix) | (spread_bits(iy) << 1)
}

/// Decode a NESTED pixel id into `(ix, iy, face)`.
#[inline]
fn nest_to_xyf(ipix: TileId, order: u32) -> (u32, u32, u32) {
    let face = (ipix >> (2 * order)) as u32;
    let in_face = ipix & ((1u64 << (2 * order)) - 1);
    let ix = compress_bits(in_face);
    let iy = compress_bits(in_face >> 1);
    (ix, iy, face)
}

/// `(z = cos θ, phi)` of a direction -> NESTED pixel id. `phi` in radians,
/// `z` in `[-1, 1]`. Standard HEALPix `ang2pix_nest` via the (x, y, face)
/// decomposition.
fn zphi_to_nest(z: f64, phi: f64, order: u32) -> TileId {
    let nside = nside_for(order) as f64;
    let za = z.abs();
    let tt = {
        // phi in [0, 4) measuring quarter-turns.
        let mut t = (phi / std::f64::consts::FRAC_PI_2).rem_euclid(4.0);
        if t < 0.0 {
            t += 4.0;
        }
        t
    };

    let (ix, iy, face);
    if za <= 2.0 / 3.0 {
        // Equatorial region.
        let temp1 = nside * (0.5 + tt);
        let temp2 = nside * (z * 0.75);
        let jp = (temp1 - temp2).floor() as i64; // ascending edge line index
        let jm = (temp1 + temp2).floor() as i64; // descending edge line index
        let ifp = jp >> order; // in {0,4}
        let ifm = jm >> order;
        let face_num = if ifp == ifm {
            (ifp & 3) + 4
        } else if ifp < ifm {
            ifp & 3
        } else {
            (ifm & 3) + 8
        };
        ix = (jm & (nside as i64 - 1)) as u32;
        iy = (nside as i64 - 1 - (jp & (nside as i64 - 1))) as u32;
        face = face_num as u32;
    } else {
        // Polar region.
        let ntt = (tt.floor() as i64).min(3);
        let tp = tt - ntt as f64;
        let tmp = nside * (3.0 * (1.0 - za)).sqrt();
        let jp = (tp * tmp).floor() as i64;
        let jm = ((1.0 - tp) * tmp).floor() as i64;
        let jp = jp.min(nside as i64 - 1);
        let jm = jm.min(nside as i64 - 1);
        if z >= 0.0 {
            ix = (nside as i64 - 1 - jm) as u32;
            iy = (nside as i64 - 1 - jp) as u32;
            face = ntt as u32;
        } else {
            ix = jp as u32;
            iy = jm as u32;
            face = (ntt + 8) as u32;
        }
    }
    xyf_to_nest(ix, iy, face, order)
}

/// NESTED pixel id -> `(z = cos θ, phi)` of the pixel **centre**. `phi` in
/// radians `[0, 2π)`. Standard HEALPix `pix2ang_nest` centre reconstruction.
fn nest_to_zphi(ipix: TileId, order: u32) -> (f64, f64) {
    let nside = nside_for(order) as i64;
    let (ix, iy, face) = nest_to_xyf(ipix, order);
    let (ix, iy) = (ix as i64, iy as i64);
    // jr = ring index from north pole (1..4*nside-1).
    let jrll = [2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4]; // per base face
    let jpll = [1, 3, 5, 7, 0, 2, 4, 6, 1, 3, 5, 7];
    let face = face as usize;
    let jr = (jrll[face] as i64) * nside - ix - iy - 1;

    // `nr` is the number of pixels in a quadrant of this ring; `kshift` offsets
    // the longitude index by half a pixel on alternating equatorial rings.
    let (z, nr, kshift) = if jr < nside {
        // North polar cap. z = 1 - nr²/(3·nside²) so z -> 2/3 at the belt edge.
        let nr = jr;
        let f = nr as f64 / nside as f64;
        (1.0 - f * f / 3.0, nr, 0i64)
    } else if jr > 3 * nside {
        // South polar cap.
        let nr = 4 * nside - jr;
        let f = nr as f64 / nside as f64;
        (-1.0 + f * f / 3.0, nr, 0i64)
    } else {
        // Equatorial belt.
        let z = (2.0 * nside as f64 - jr as f64) * (2.0 / 3.0) / nside as f64;
        (z, nside, (jr - nside) & 1)
    };

    let jp = (jpll[face] as i64 * nr + ix - iy + 1 + kshift) / 2;
    let jp = wrap_jp(jp, 4 * nr);
    let phi = (jp as f64 - (kshift as f64 + 1.0) * 0.5) * (std::f64::consts::FRAC_PI_2 / nr as f64);
    (z, phi.rem_euclid(2.0 * std::f64::consts::PI))
}

/// Wrap a HEALPix longitude index `jp` into `[1, modulus]` (1-based ring index).
#[inline]
fn wrap_jp(jp: i64, modulus: i64) -> i64 {
    let mut v = jp;
    while v > modulus {
        v -= modulus;
    }
    while v < 1 {
        v += modulus;
    }
    v
}

/// The eight (or fewer) NESTED neighbours of a pixel that share an edge or
/// corner. Used to make cone coverage gap-free: after sampling the cone we add
/// every found pixel's neighbours, which guarantees no boundary tile a frame
/// clips is missed. Neighbours that fall off a face boundary are recomputed via
/// the centre direction, so the result is always valid (if conservative).
fn neighbours_nest(ipix: TileId, order: u32) -> Vec<TileId> {
    let nside = nside_for(order) as i64;
    let (ix, iy, _face) = nest_to_xyf(ipix, order);
    let mut out = Vec::with_capacity(8);
    for dy in -1i64..=1 {
        for dx in -1i64..=1 {
            if dx == 0 && dy == 0 {
                continue;
            }
            let nx = ix as i64 + dx;
            let ny = iy as i64 + dy;
            if nx >= 0 && nx < nside && ny >= 0 && ny < nside {
                // Same face: direct encode.
                let (_, _, face) = nest_to_xyf(ipix, order);
                out.push(xyf_to_nest(nx as u32, ny as u32, face, order));
            } else {
                // Crosses a face edge: resolve through the sky direction of the
                // offset point. Sub-pixel step toward the neighbour centre.
                let (z, phi) = nest_to_zphi(ipix, order);
                let dtheta = std::f64::consts::PI / (2.0 * nside as f64); // ~ pixel size
                let theta = z.clamp(-1.0, 1.0).acos();
                let nt = (theta + dy as f64 * dtheta).clamp(1e-9, std::f64::consts::PI - 1e-9);
                let np = phi + dx as f64 * dtheta / nt.sin().max(1e-6);
                let neigh = zphi_to_nest(nt.cos(), np, order);
                if neigh != ipix {
                    out.push(neigh);
                }
            }
        }
    }
    out.sort_unstable();
    out.dedup();
    out
}

/// Convert `(ra_deg, dec_deg)` to the NESTED tile id at `order`. Public so the
/// bridge / Dart layer can answer "which tile does this sky position fall in"
/// without re-deriving the HEALPix addressing.
pub fn radec_to_tile(ra_deg: f64, dec_deg: f64, order: u32) -> TileId {
    let z = dec_deg.to_radians().sin();
    let phi = ra_deg.to_radians();
    zphi_to_nest(z, phi, order)
}

// Public tile addressing

/// `(ra_deg in [0,360), dec_deg)` of a tile's centre.
pub fn tile_center(id: TileId, order: u32) -> (f64, f64) {
    let (z, phi) = nest_to_zphi(id, order);
    let dec = z.clamp(-1.0, 1.0).asin().to_degrees();
    let mut ra = phi.to_degrees() % 360.0;
    if ra < 0.0 {
        ra += 360.0;
    }
    (ra, dec)
}

/// Angular radius (deg) of the disc that circumscribes one tile, i.e. the
/// centre-to-corner distance. A HEALPix pixel at `nside` subtends a solid angle
/// `4π / (12 nside²)`; its circumscribed radius is conservatively
/// `~ 1.5 × sqrt(area/π)`, which guarantees the cone sampler never leaves a gap.
fn tile_circum_radius_deg(order: u32) -> f64 {
    let npix = npix_for(order) as f64;
    let area_sr = 4.0 * std::f64::consts::PI / npix;
    let equiv_radius = (area_sr / std::f64::consts::PI).sqrt(); // radians
    (equiv_radius * 1.5).to_degrees()
}

/// All tiles a cone `(center_ra, center_dec, radius_deg)` covers, at `order`.
///
/// The cone is sampled on a polar lattice dense enough that consecutive samples
/// are closer than a tile, the sampled pixels are collected, and every sampled
/// pixel's neighbours are added so a tile the cone only grazes at its boundary
/// is never dropped. The result is a deduplicated, ascending id list.
pub fn tile_ids_for_cone(
    center_ra: f64,
    center_dec: f64,
    radius_deg: f64,
    order: u32,
) -> Vec<TileId> {
    let mut ids: Vec<TileId> = Vec::new();
    let tile_r = tile_circum_radius_deg(order).max(1e-6);
    // Always include the centre tile.
    ids.push(radec_to_tile(center_ra, center_dec, order));

    if radius_deg > 0.0 {
        // Radial rings spaced at half a tile radius; angular samples per ring
        // spaced so the chord between samples is under a tile radius too.
        let r_step = (tile_r * 0.5).max(1e-4);
        let n_rings = (radius_deg / r_step).ceil() as i64 + 1;
        let dec0 = center_dec.to_radians();
        let ra0 = center_ra.to_radians();
        let (sin_d0, cos_d0) = (dec0.sin(), dec0.cos());
        for ri in 0..=n_rings {
            let rho = (ri as f64 * r_step).min(radius_deg).to_radians();
            if rho == 0.0 {
                continue;
            }
            let circumference = 2.0 * std::f64::consts::PI * rho.to_degrees();
            let n_az = ((circumference / (tile_r * 0.5)).ceil() as i64).max(4);
            let (sin_rho, cos_rho) = (rho.sin(), rho.cos());
            for ai in 0..n_az {
                let az = (ai as f64) * 2.0 * std::f64::consts::PI / (n_az as f64);
                // Offset (rho, az) from the centre on the sphere.
                let sin_dec = sin_d0 * cos_rho + cos_d0 * sin_rho * az.cos();
                let dec = sin_dec.clamp(-1.0, 1.0).asin();
                let dra =
                    (sin_rho * az.sin()).atan2(cos_d0 * cos_rho - sin_d0 * sin_rho * az.cos());
                let ra = (ra0 + dra).to_degrees();
                ids.push(radec_to_tile(ra, dec.to_degrees(), order));
            }
        }
    }

    // Close boundary gaps by unioning every found tile's neighbours.
    let seed: Vec<TileId> = {
        ids.sort_unstable();
        ids.dedup();
        ids.clone()
    };
    for id in seed {
        for n in neighbours_nest(id, order) {
            ids.push(n);
        }
    }
    ids.sort_unstable();
    ids.dedup();
    ids
}

/// All tiles a frame footprint covers. The frame's four corners + centre +
/// edge midpoints are projected to the sky via its WCS, a bounding cone is fit,
/// and [`tile_ids_for_cone`] enumerates the tiles. Returns an empty vec if the
/// WCS is degenerate.
pub fn tile_ids_for_frame(wcs: &SipWcs, width: u32, height: u32, order: u32) -> Vec<TileId> {
    if !wcs.is_invertible() || width == 0 || height == 0 {
        return Vec::new();
    }
    let w = width as f64;
    let h = height as f64;
    let samples = [
        (0.0, 0.0),
        (w - 1.0, 0.0),
        (0.0, h - 1.0),
        (w - 1.0, h - 1.0),
        ((w - 1.0) * 0.5, (h - 1.0) * 0.5),
        ((w - 1.0) * 0.5, 0.0),
        ((w - 1.0) * 0.5, h - 1.0),
        (0.0, (h - 1.0) * 0.5),
        (w - 1.0, (h - 1.0) * 0.5),
    ];
    let center = wcs.pixel_to_world((w - 1.0) * 0.5, (h - 1.0) * 0.5);
    let (c_ra, c_dec) = center;
    let cr = c_ra.to_radians();
    let cd = c_dec.to_radians();
    let (sin_cd, cos_cd) = (cd.sin(), cd.cos());
    let mut max_sep = 0.0f64;
    for &(x, y) in &samples {
        let (ra, dec) = wcs.pixel_to_world(x, y);
        let dr = dec.to_radians();
        let sep = (sin_cd * dr.sin() + cos_cd * dr.cos() * (ra.to_radians() - cr).cos())
            .clamp(-1.0, 1.0)
            .acos();
        if sep > max_sep {
            max_sep = sep;
        }
    }
    let radius_deg = max_sep.to_degrees();
    tile_ids_for_cone(c_ra, c_dec, radius_deg, order)
}

/// The canonical local TAN grid (no SIP) for a tile: centre = the tile centre,
/// a fixed isotropic scale so the [`TILE_PIXELS`]-wide grid spans the tile plus a
/// small margin, axis-aligned (no rotation). Every contributor reprojects *onto*
/// this exact grid, which is what makes per-tile sums additive across observers.
pub fn tile_wcs(id: TileId, order: u32) -> SipWcs {
    let (ra, dec) = tile_center(id, order);
    // Span the tile's circumscribed diameter (+ margin) across TILE_PIXELS.
    let span_deg = 2.0 * tile_circum_radius_deg(order) * TILE_SCALE_MARGIN;
    let scale_deg = span_deg / (TILE_PIXELS as f64);
    // Axis-aligned CD with the standard RA-flip; CRPIX at the grid centre
    // (1-based FITS convention).
    let crpix = (TILE_PIXELS as f64) / 2.0 + 0.5;
    SipWcs::tan_only(
        ra, dec, crpix, crpix, -scale_deg, // cd1_1 (RA increases to the left)
        0.0, 0.0, scale_deg, // cd2_2
    )
}

// Provenance

/// One contributor's fold into a tile (mirrors the master's `FoldRecord`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TileFoldRecord {
    /// Frames that contributed (weight > 0, footprint touched the tile).
    pub frames_added: usize,
    /// Σ weights added in this fold.
    pub weight_added: f64,
    /// Integration seconds added in this fold.
    pub integration_seconds_added: f64,
    /// Samples the online clip rejected during this fold.
    pub rejected: u64,
    /// Free-form label (ISO date / session id).
    pub label: String,
    /// Contributor id; `""` for local.
    pub contributor: String,
}

/// Provenance + summary carried alongside a tile's running state.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
pub struct TileProvenance {
    /// Total frames folded across every fold so far.
    pub total_frames: usize,
    /// Total integration time accumulated (seconds).
    pub total_integration_seconds: f64,
    /// Device / account ids that have folded in (deduped, insertion order).
    pub contributors: Vec<String>,
    /// Per-fold log, oldest first.
    pub folds: Vec<TileFoldRecord>,
}

impl TileProvenance {
    fn note_contributor(&mut self, who: &str) {
        if !self.contributors.iter().any(|c| c == who) {
            self.contributors.push(who.to_string());
        }
    }
}

// Errors

/// Errors from the sky-atlas API. Every variant is a caller mistake surfaced
/// loudly rather than silently producing a wrong tile.
#[derive(Debug, thiserror::Error, PartialEq)]
pub enum AtlasError {
    /// The frame's WCS CD matrix is singular -> world↔pixel is not invertible.
    #[error("frame has a degenerate (non-invertible) WCS")]
    DegenerateWcs,
    /// The frame's footprint covers no tiles (empty / off-sky).
    #[error("frame footprint covers no tiles")]
    NoCoverage,
    /// Two tiles disagree on id (e.g. a merge across different sky positions).
    #[error("tile geometry mismatch: {got} vs {expected}")]
    GeometryMismatch {
        /// The id that was supplied.
        got: TileId,
        /// The id that was expected.
        expected: TileId,
    },
    /// Two tiles disagree on HEALPix order.
    #[error("tile order mismatch: {got} vs {expected}")]
    OrderMismatch {
        /// The order that was supplied.
        got: u32,
        /// The order that was expected.
        expected: u32,
    },
    /// Two tiles (or a frame and a tile) disagree on channel count.
    #[error("channel mismatch: {got} vs {expected}")]
    ChannelMismatch {
        /// The channel count that was supplied.
        got: u32,
        /// The channel count that was expected.
        expected: u32,
    },
    /// A serialized tile is truncated or its payload is inconsistent.
    #[error("serialized tile is truncated/corrupt: {0}")]
    Corrupt(String),
    /// A serialized tile did not begin with [`TILE_MAGIC`].
    #[error("bad magic (not a Skotiq tile sidecar)")]
    BadMagic,
    /// A serialized tile's version is not [`TILE_STATE_VERSION`].
    #[error("unsupported tile version {got} (this build reads {supported})")]
    UnsupportedVersion {
        /// The version found in the blob.
        got: u32,
        /// The version this build can read.
        supported: u32,
    },
    /// An I/O error reading or writing a tile sidecar.
    #[error("tile I/O error: {0}")]
    Io(String),
}

// SkyTileAccumulator

/// Per-tile additive accumulator — the master's [`PerPixelAccumulator`] on a
/// fixed tile grid, plus the tile's frozen [`SipWcs`] and provenance.
#[derive(Debug, Clone, PartialEq)]
pub struct SkyTileAccumulator {
    /// On-disk state version (== [`TILE_STATE_VERSION`] in memory).
    pub version: u32,
    /// HEALPix NESTED tile id.
    pub tile_id: TileId,
    /// HEALPix order this tile was created at.
    pub order: u32,
    /// Grid width (== [`TILE_PIXELS`]).
    pub width: u32,
    /// Grid height (== [`TILE_PIXELS`]).
    pub height: u32,
    /// Channel count (1 = mono, 3 = OSC/RGB).
    pub channels: u32,
    /// The tile's canonical local TAN grid (== [`tile_wcs`]).
    pub wcs: SipWcs,
    /// Frozen photometric reference baseline: the per-channel robust sky
    /// background + signal scale that the FIRST contribution establishes, and that
    /// every later fold (local or remote merge) is brought onto before its sums are
    /// added. This is what makes a cross-telescope / cross-user co-add
    /// photometrically valid — without it the running mean would average raw
    /// instrument ADU across rigs at wildly different gains / focal ratios.
    pub norm_reference: NormalizationReference,
    /// Whether [`norm_reference`] has been frozen from a contribution yet. Until
    /// the first fold establishes it, the reference holds its identity default.
    pub norm_frozen: bool,
    /// Folding + online-rejection mode.
    pub mode: AccumulationMode,
    /// The six running vectors.
    pub state: PerPixelAccumulator,
    /// Provenance + summary metadata.
    pub provenance: TileProvenance,
}

impl SkyTileAccumulator {
    /// Create a fresh, zeroed accumulator for `tile_id` at `order`.
    pub fn create(tile_id: TileId, order: u32, channels: u32, mode: AccumulationMode) -> Self {
        let len = (TILE_PIXELS as usize) * (TILE_PIXELS as usize) * (channels as usize);
        let ch = channels as usize;
        Self {
            version: TILE_STATE_VERSION,
            tile_id,
            order,
            width: TILE_PIXELS,
            height: TILE_PIXELS,
            channels,
            wcs: tile_wcs(tile_id, order),
            norm_reference: NormalizationReference {
                background: vec![0.0; ch],
                scale: vec![1.0; ch],
            },
            norm_frozen: false,
            mode,
            state: PerPixelAccumulator {
                sum_w: vec![0.0; len],
                sum_w2: vec![0.0; len],
                sum_wx: vec![0.0; len],
                sum_wx2: vec![0.0; len],
                coverage: vec![0; len],
                rejected: vec![0; len],
            },
            provenance: TileProvenance::default(),
        }
    }

    /// Adopt an already-frozen photometric reference (e.g. the one the hub or the
    /// first contributor established for this tile) so that subsequent folds map
    /// onto the SAME scale every other contributor uses. This is the federation
    /// prerequisite: `merge == combined fold` is exact only when both contributors
    /// normalized their frames against the same reference. A no-op if [`other`] is
    /// not frozen. Must be called before any fold (it would otherwise be ignored,
    /// as the first fold freezes the reference itself).
    pub fn adopt_reference(&mut self, reference: &NormalizationReference) {
        if reference.background.len() == self.channels as usize
            && reference.scale.len() == self.channels as usize
        {
            self.norm_reference = reference.clone();
            self.norm_frozen = true;
        }
    }

    /// Whether this tile's photometric reference has been frozen yet.
    pub fn is_norm_frozen(&self) -> bool {
        self.norm_frozen
    }

    /// The frozen photometric reference (identity until the first fold or an
    /// [`adopt_reference`](Self::adopt_reference) call).
    pub fn norm_reference(&self) -> &NormalizationReference {
        &self.norm_reference
    }

    /// Length of the per-slot running vectors.
    #[inline]
    fn slot_count(&self) -> usize {
        (self.width as usize) * (self.height as usize) * (self.channels as usize)
    }

    /// Reproject `frame` (with its solved `wcs`) onto this tile's grid and fold
    /// it in with scalar `weight` / `exposure_sec`. For every tile pixel: world
    /// ← tile WCS; source pixel ← frame WCS (CD + SIP); resample with `interp`;
    /// fold the sample into the running sums with the same online-clip logic as
    /// the master. `contributor` tags provenance (`""` for local). Returns the
    /// [`TileFoldRecord`] for this fold.
    ///
    /// Pixels whose source maps outside the frame (or to a degenerate sky
    /// point) contribute nothing — the seam handling is automatic because the
    /// sums are additive and `finalize` re-divides by coverage.
    #[allow(clippy::too_many_arguments)]
    pub fn fold_frame(
        &mut self,
        frame: &ImageData,
        wcs: &SipWcs,
        weight: f64,
        exposure_sec: f64,
        interp: Interpolator,
        label: &str,
        contributor: &str,
    ) -> Result<TileFoldRecord, AtlasError> {
        if !wcs.is_invertible() {
            return Err(AtlasError::DegenerateWcs);
        }
        if frame.channels != self.channels {
            return Err(AtlasError::ChannelMismatch {
                got: frame.channels,
                expected: self.channels,
            });
        }
        // Skip frames the weighting stage deemed worthless (mirrors the master).
        if !weight.is_finite() || weight <= 0.0 {
            let rec = TileFoldRecord {
                frames_added: 0,
                weight_added: 0.0,
                integration_seconds_added: 0.0,
                rejected: 0,
                label: label.to_string(),
                contributor: contributor.to_string(),
            };
            return Ok(rec);
        }

        let src = decode_to_f64(frame);
        let sw = frame.width as usize;
        let sh = frame.height as usize;
        let ch = self.channels as usize;
        let tw = self.width as usize;
        let th = self.height as usize;
        // `decode_to_f64` yields an empty buffer for a pixel type the pipeline
        // never emits (only U16/F32 are linear light); without this guard the
        // resampler would index an empty buffer through nonzero width/height.
        // A frame we cannot decode contributes nothing rather than panicking.
        if src.len() != sw * sh * ch {
            return Ok(TileFoldRecord {
                frames_added: 0,
                weight_added: 0.0,
                integration_seconds_added: 0.0,
                rejected: 0,
                label: label.to_string(),
                contributor: contributor.to_string(),
            });
        }

        let clip = match self.mode {
            AccumulationMode::RunningWeightedMean { clip } => clip,
        };

        // Photometric normalization. Estimate this frame's per-channel robust sky
        // background + signal scale (median + 1.4826·MAD). On the FIRST fold this
        // freezes the tile's reference; every later fold maps its samples onto that
        // reference (`v' = (v - bg)·(ref_scale/scale) + ref_bg`) so contributors at
        // different gains / focal ratios / sky pedestals deposit comparable surface
        // brightness, not raw ADU. Without this the running mean is dominated by
        // whichever rig has the larger ADU pedestal — additive but not
        // photometrically valid (the Pillar C federation requirement).
        let frame_norm = estimate_frame_norm(&src, ch);
        if !self.norm_frozen {
            self.norm_reference = frame_norm.clone();
            self.norm_frozen = true;
        }

        let mut rejected: u64 = 0;
        let mut any_contribution = false;

        for ty in 0..th {
            for tx in 0..tw {
                // Tile pixel -> sky (tile WCS is exact, no SIP).
                let (ra, dec) = self.wcs.pixel_to_world(tx as f64, ty as f64);
                // Sky -> source pixel (frame WCS, CD + SIP).
                let Some((sx, sy)) = wcs.world_to_pixel(ra, dec) else {
                    continue;
                };
                // Reject samples whose support clearly leaves the frame so a
                // border smear does not pollute the tile.
                if sx < 0.0 || sy < 0.0 || sx > (sw as f64 - 1.0) || sy > (sh as f64 - 1.0) {
                    continue;
                }
                for c in 0..ch {
                    let raw = sample_interleaved(&src, sw, sh, ch, c, sx, sy, interp);
                    if !raw.is_finite() {
                        continue;
                    }
                    let v = normalize_sample(
                        raw,
                        frame_norm.background[c],
                        frame_norm.scale[c],
                        self.norm_reference.background[c],
                        self.norm_reference.scale[c],
                    );
                    if !v.is_finite() {
                        continue;
                    }
                    let slot = (ty * tw + tx) * ch + c;
                    if self.fold_sample(slot, v, weight, clip) {
                        any_contribution = true;
                    } else {
                        rejected += 1;
                    }
                }
            }
        }

        let (frames_added, weight_added, seconds_added) = if any_contribution {
            (
                1usize,
                weight,
                if exposure_sec.is_finite() && exposure_sec > 0.0 {
                    exposure_sec
                } else {
                    0.0
                },
            )
        } else {
            (0usize, 0.0, 0.0)
        };

        self.provenance.total_frames += frames_added;
        self.provenance.total_integration_seconds += seconds_added;
        if frames_added > 0 {
            self.provenance.note_contributor(contributor);
        }
        let rec = TileFoldRecord {
            frames_added,
            weight_added,
            integration_seconds_added: seconds_added,
            rejected,
            label: label.to_string(),
            contributor: contributor.to_string(),
        };
        self.provenance.folds.push(rec.clone());
        Ok(rec)
    }

    /// Fold a single sample at `slot` with `weight`, applying the online clip if
    /// configured. Returns `true` if the sample was accumulated, `false` if the
    /// online clip rejected it. Identical estimator to the master's `fold_one`.
    fn fold_sample(
        &mut self,
        slot: usize,
        v: f64,
        weight: f64,
        clip: Option<crate::master_accumulation::OnlineClip>,
    ) -> bool {
        let st = &mut self.state;
        if let Some(clip) = clip {
            if st.coverage[slot] >= MIN_HISTORY_FOR_CLIP {
                let sw = st.sum_w[slot];
                let denom = sw - st.sum_w2[slot] / sw;
                if sw > 0.0 && denom > 0.0 {
                    let mean = st.sum_wx[slot] / sw;
                    let weighted_sq_dev = (st.sum_wx2[slot] - mean * mean * sw).max(0.0);
                    let var = weighted_sq_dev / denom;
                    let sigma = var.sqrt();
                    if sigma > 0.0 {
                        let lo = mean - clip.low * sigma;
                        let hi = mean + clip.high * sigma;
                        if v < lo || v > hi {
                            st.rejected[slot] = st.rejected[slot].saturating_add(1);
                            return false;
                        }
                    }
                }
            }
        }
        st.sum_w[slot] += weight;
        st.sum_w2[slot] += weight * weight;
        st.sum_wx[slot] += weight * v;
        st.sum_wx2[slot] += weight * v * v;
        st.coverage[slot] = st.coverage[slot].saturating_add(1);
        true
    }

    /// The finalized tile: `master(p) = sum_wx / sum_w` per pixel, `F32`. Pixels
    /// with no coverage are zero-filled. Can be called any number of times.
    pub fn finalize(&self) -> ImageData {
        let len = self.slot_count();
        let mut data = vec![0.0f32; len];
        for (i, out) in data.iter_mut().enumerate() {
            let sw = self.state.sum_w[i];
            *out = if sw > 0.0 {
                (self.state.sum_wx[i] / sw) as f32
            } else {
                0.0
            };
        }
        ImageData::from_f32(self.width, self.height, self.channels, &data)
    }

    /// Per-pixel coverage depth (`F32`).
    pub fn coverage_map(&self) -> ImageData {
        let data: Vec<f32> = self.state.coverage.iter().map(|&c| c as f32).collect();
        ImageData::from_f32(self.width, self.height, self.channels, &data)
    }

    /// Per-pixel online-clip rejection count (`F32`).
    pub fn rejection_map(&self) -> ImageData {
        let data: Vec<f32> = self.state.rejected.iter().map(|&c| c as f32).collect();
        ImageData::from_f32(self.width, self.height, self.channels, &data)
    }

    /// Mean coverage depth across all tile pixels (the heat-overlay number).
    pub fn coverage_mean(&self) -> f64 {
        if self.state.coverage.is_empty() {
            return 0.0;
        }
        let sum: u64 = self.state.coverage.iter().map(|&c| c as u64).sum();
        sum as f64 / self.state.coverage.len() as f64
    }

    // Serialization (resumable sidecar), same layout discipline as the master

    /// Serialize to a self-contained, versioned blob:
    /// `MAGIC (4) | version (u32 LE) | header_len (u32 LE) | JSON header | raw
    /// payload`. The JSON header carries the small structured fields (ids, WCS,
    /// mode, normalization reference, provenance, slot count); the payload packs
    /// the six per-pixel vectors little-endian (`sum_*` f64, `coverage`/
    /// `rejected` u32) — keeping the big arrays out of JSON so a 1024² tile is
    /// compact and fast to read/write.
    pub fn serialize(&self) -> Vec<u8> {
        let header = TileHeader {
            tile_id: self.tile_id,
            order: self.order,
            width: self.width,
            height: self.height,
            channels: self.channels,
            wcs: self.wcs.clone(),
            norm_reference: self.norm_reference.clone(),
            norm_frozen: self.norm_frozen,
            mode: self.mode,
            provenance: self.provenance.clone(),
            slot_count: self.slot_count(),
        };
        let header_json = serde_json::to_vec(&header).expect("tile header serializes");
        let len = self.slot_count();
        let mut out = Vec::with_capacity(12 + header_json.len() + len * (8 * 4 + 4 * 2));
        out.extend_from_slice(TILE_MAGIC);
        out.extend_from_slice(&TILE_STATE_VERSION.to_le_bytes());
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

    /// Reconstruct a tile from a blob produced by [`serialize`](Self::serialize).
    /// Fails loudly on bad magic, an unsupported version, a truncated payload, or
    /// state vectors whose lengths disagree with the declared geometry.
    pub fn deserialize(bytes: &[u8]) -> Result<Self, AtlasError> {
        const FIXED: usize = 12;
        if bytes.len() < FIXED {
            return Err(AtlasError::Corrupt(format!(
                "truncated: {} bytes, need at least {FIXED}",
                bytes.len()
            )));
        }
        if &bytes[0..4] != TILE_MAGIC {
            return Err(AtlasError::BadMagic);
        }
        let version = u32::from_le_bytes(bytes[4..8].try_into().expect("4 bytes"));
        if version != TILE_STATE_VERSION {
            return Err(AtlasError::UnsupportedVersion {
                got: version,
                supported: TILE_STATE_VERSION,
            });
        }
        let header_len = u32::from_le_bytes(bytes[8..12].try_into().expect("4 bytes")) as usize;
        let header_end = FIXED
            .checked_add(header_len)
            .ok_or_else(|| AtlasError::Corrupt("header length overflow".into()))?;
        if bytes.len() < header_end {
            return Err(AtlasError::Corrupt("truncated header".into()));
        }
        let header: TileHeader = serde_json::from_slice(&bytes[FIXED..header_end])
            .map_err(|e| AtlasError::Corrupt(e.to_string()))?;

        let len = header.slot_count;
        let geom_len =
            (header.width as usize) * (header.height as usize) * (header.channels as usize);
        if len != geom_len {
            return Err(AtlasError::Corrupt(
                "slot count disagrees with declared geometry".into(),
            ));
        }
        let f64_bytes = len
            .checked_mul(8)
            .ok_or_else(|| AtlasError::Corrupt("payload length overflow".into()))?;
        let u32_bytes = len
            .checked_mul(4)
            .ok_or_else(|| AtlasError::Corrupt("payload length overflow".into()))?;
        let payload_len = f64_bytes
            .checked_mul(4)
            .and_then(|x| x.checked_add(u32_bytes.checked_mul(2)?))
            .ok_or_else(|| AtlasError::Corrupt("payload length overflow".into()))?;
        let total = header_end
            .checked_add(payload_len)
            .ok_or_else(|| AtlasError::Corrupt("payload length overflow".into()))?;
        if bytes.len() < total {
            return Err(AtlasError::Corrupt(format!(
                "truncated payload: {} bytes, need {total}",
                bytes.len()
            )));
        }

        let mut cursor = header_end;
        let sum_w = read_f64(bytes, &mut cursor, len);
        let sum_w2 = read_f64(bytes, &mut cursor, len);
        let sum_wx = read_f64(bytes, &mut cursor, len);
        let sum_wx2 = read_f64(bytes, &mut cursor, len);
        let coverage = read_u32(bytes, &mut cursor, len);
        let rejected = read_u32(bytes, &mut cursor, len);

        Ok(Self {
            version,
            tile_id: header.tile_id,
            order: header.order,
            width: header.width,
            height: header.height,
            channels: header.channels,
            wcs: header.wcs,
            norm_reference: header.norm_reference,
            norm_frozen: header.norm_frozen,
            mode: header.mode,
            state: PerPixelAccumulator {
                sum_w,
                sum_w2,
                sum_wx,
                sum_wx2,
                coverage,
                rejected,
            },
            provenance: header.provenance,
        })
    }
}

/// Minimum accumulated samples at a pixel before the online clip may reject
/// (mirrors the master — σ is too poorly determined below this to clip honestly).
const MIN_HISTORY_FOR_CLIP: u32 = 5;

/// JSON-serialized portion of the tile sidecar.
#[derive(Debug, Serialize, Deserialize)]
struct TileHeader {
    tile_id: TileId,
    order: u32,
    width: u32,
    height: u32,
    channels: u32,
    wcs: SipWcs,
    norm_reference: NormalizationReference,
    /// Defaulted for backward-compat with sidecars written before per-tile
    /// photometric normalization (they carry the identity reference, unfrozen).
    #[serde(default)]
    norm_frozen: bool,
    mode: AccumulationMode,
    provenance: TileProvenance,
    slot_count: usize,
}

// Federation: merge / subtract

/// Add `other` into `dst` (same tile id + order + grid). Sums the six running
/// vectors (scaling `other`'s weighted sums by `trust`) and unions provenance.
/// With `clip == None` this is **exact** versus folding both contributors'
/// frames into one accumulator — the master's additivity, per tile.
///
/// `trust` in `[0, 1]` scales `other`'s contribution (1.0 = full trust). It
/// multiplies the weighted sums (`sum_w`, `sum_w2`, `sum_wx`, `sum_wx2`) so a
/// low-trust contributor moves the finalized mean less; coverage/rejection
/// counts are integer tallies and are added unscaled.
pub fn merge_tiles(
    dst: &mut SkyTileAccumulator,
    other: &SkyTileAccumulator,
    trust: f64,
) -> Result<(), AtlasError> {
    merge_signed(dst, other, trust, 1.0)
}

/// Retraction: subtract `other`'s (trust-scaled) contribution from `dst`. Exact
/// because the running sums are linear. Coverage/rejection counts are clamped at
/// zero (they are tallies, never negative).
pub fn merge_tiles_subtract(
    dst: &mut SkyTileAccumulator,
    other: &SkyTileAccumulator,
    trust: f64,
) -> Result<(), AtlasError> {
    merge_signed(dst, other, trust, -1.0)
}

/// Shared body for [`merge_tiles`] / [`merge_tiles_subtract`]. `sign` is `+1` for
/// addition, `-1` for subtraction.
fn merge_signed(
    dst: &mut SkyTileAccumulator,
    other: &SkyTileAccumulator,
    trust: f64,
    sign: f64,
) -> Result<(), AtlasError> {
    if dst.order != other.order {
        return Err(AtlasError::OrderMismatch {
            got: other.order,
            expected: dst.order,
        });
    }
    if dst.tile_id != other.tile_id {
        return Err(AtlasError::GeometryMismatch {
            got: other.tile_id,
            expected: dst.tile_id,
        });
    }
    if dst.channels != other.channels {
        return Err(AtlasError::ChannelMismatch {
            got: other.channels,
            expected: dst.channels,
        });
    }
    if dst.slot_count() != other.slot_count() {
        return Err(AtlasError::Corrupt(
            "merge operands have mismatched slot counts".into(),
        ));
    }

    // A fresh (unfrozen) destination adopts the operand's photometric reference,
    // so a hub merging the first contribution into an empty tile carries that
    // reference forward for every later contributor to normalize against.
    if sign >= 0.0 && !dst.norm_frozen && other.norm_frozen {
        dst.norm_reference = other.norm_reference.clone();
        dst.norm_frozen = true;
    }

    let k = sign * trust;
    // sum_w2 = Σw² is QUADRATIC in the weight, so scaling a contributor's
    // effective weight by `trust` scales its Σw² by trust² — not trust. The
    // sign (add vs. subtract) stays linear. Using `k` here would leave a
    // trust!=1.0 merged tile with an inconsistent Σw² (Σw scaled by trust but
    // Σw² by trust), which breaks the online clip's effective-sample-size
    // denominator `sw - sum_w2/sw` (it can even go non-positive), silently
    // disabling rejection on every later fold into the merged tile. Scaling by
    // trust² keeps (Σw, Σw²) the exact sums of the trust-scaled weights, so the
    // clip stays well-defined.
    let k2 = sign * trust * trust;
    let len = dst.slot_count();
    for i in 0..len {
        dst.state.sum_w[i] += k * other.state.sum_w[i];
        dst.state.sum_w2[i] += k2 * other.state.sum_w2[i];
        dst.state.sum_wx[i] += k * other.state.sum_wx[i];
        dst.state.sum_wx2[i] += k * other.state.sum_wx2[i];
        if sign >= 0.0 {
            dst.state.coverage[i] = dst.state.coverage[i].saturating_add(other.state.coverage[i]);
            dst.state.rejected[i] = dst.state.rejected[i].saturating_add(other.state.rejected[i]);
        } else {
            dst.state.coverage[i] = dst.state.coverage[i].saturating_sub(other.state.coverage[i]);
            dst.state.rejected[i] = dst.state.rejected[i].saturating_sub(other.state.rejected[i]);
        }
    }

    // Provenance union / retraction.
    if sign >= 0.0 {
        dst.provenance.total_frames += other.provenance.total_frames;
        dst.provenance.total_integration_seconds += other.provenance.total_integration_seconds;
        for f in &other.provenance.folds {
            dst.provenance.note_contributor(&f.contributor);
            dst.provenance.folds.push(f.clone());
        }
    } else {
        dst.provenance.total_frames = dst
            .provenance
            .total_frames
            .saturating_sub(other.provenance.total_frames);
        dst.provenance.total_integration_seconds = (dst.provenance.total_integration_seconds
            - other.provenance.total_integration_seconds)
            .max(0.0);
        // Record the retraction in the fold log for an auditable history.
        for f in &other.provenance.folds {
            dst.provenance.folds.push(TileFoldRecord {
                frames_added: f.frames_added,
                weight_added: -f.weight_added,
                integration_seconds_added: -f.integration_seconds_added,
                rejected: f.rejected,
                label: format!("retract:{}", f.label),
                contributor: f.contributor.clone(),
            });
        }
    }
    Ok(())
}

// Out-of-core atlas: per-tile sidecars on disk

/// A handle to an on-disk atlas: a directory of serialized tile sidecars under
/// `<root>/tiles/<order>/<tileId>.nst`. The atlas is the bulk pixel store; the
/// DB index (`sky_tiles`) lives separately. No tile pixels are held in RAM
/// beyond the tiles a single fold/query touches.
#[derive(Debug, Clone)]
pub struct SkyAtlas {
    root: PathBuf,
    order: u32,
    /// Soft cap on resident tile buffers during a multi-tile fold. A 1024² mono
    /// f64 accumulator is ~50 MB; the budget bounds how many are decoded at once
    /// so a wide frame touching dozens of tiles never blows the heap.
    memory_budget_bytes: u64,
}

impl SkyAtlas {
    /// Open (creating the directory tree if absent) an atlas rooted at `root`
    /// for `order`, with a resident-tile memory budget in bytes.
    pub fn open(root: impl AsRef<Path>, order: u32, memory_budget_bytes: u64) -> Self {
        Self {
            root: root.as_ref().to_path_buf(),
            order,
            memory_budget_bytes: memory_budget_bytes.max(tile_buffer_bytes(1)),
        }
    }

    /// The HEALPix order this atlas stores tiles at.
    pub fn order(&self) -> u32 {
        self.order
    }

    /// Filesystem path of a tile's sidecar.
    pub fn tile_path(&self, tile_id: TileId) -> PathBuf {
        self.root
            .join("tiles")
            .join(self.order.to_string())
            .join(format!("{tile_id}.nst"))
    }

    /// Load a tile sidecar from disk, or `None` if it does not exist yet.
    pub fn load_tile(&self, tile_id: TileId) -> Result<Option<SkyTileAccumulator>, AtlasError> {
        let path = self.tile_path(tile_id);
        match std::fs::read(&path) {
            Ok(bytes) => Ok(Some(SkyTileAccumulator::deserialize(&bytes)?)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(AtlasError::Io(e.to_string())),
        }
    }

    /// Load a tile, or create a fresh zeroed one if it does not exist.
    pub fn load_or_create(
        &self,
        tile_id: TileId,
        channels: u32,
        mode: AccumulationMode,
    ) -> Result<SkyTileAccumulator, AtlasError> {
        match self.load_tile(tile_id)? {
            Some(t) => {
                if t.channels != channels {
                    return Err(AtlasError::ChannelMismatch {
                        got: channels,
                        expected: t.channels,
                    });
                }
                Ok(t)
            }
            None => Ok(SkyTileAccumulator::create(
                tile_id, self.order, channels, mode,
            )),
        }
    }

    /// Persist a tile sidecar to disk (atomically: write a temp file then
    /// rename, so a crash mid-write never corrupts the existing tile).
    pub fn store_tile(&self, tile: &SkyTileAccumulator) -> Result<(), AtlasError> {
        let path = self.tile_path(tile.tile_id);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| AtlasError::Io(e.to_string()))?;
        }
        // Per-write-unique temp (pid + monotonic nonce) so a concurrent fold for
        // the same tile can't collide on a shared `nst.tmp`; the rename onto the
        // real path is still atomic on the same filesystem.
        let tmp = path.with_extension(format!(
            "nst.tmp.{}.{}",
            std::process::id(),
            STORE_TILE_NONCE.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::write(&tmp, tile.serialize()).map_err(|e| AtlasError::Io(e.to_string()))?;
        std::fs::rename(&tmp, &path).map_err(|e| AtlasError::Io(e.to_string()))?;
        Ok(())
    }

    /// Fold one plate-solved frame into every tile its footprint covers. Tiles
    /// are processed one at a time (load -> fold -> store), so the resident
    /// memory never exceeds a handful of tile buffers regardless of how many the
    /// frame touches. Returns the per-tile fold records.
    #[allow(clippy::too_many_arguments)]
    pub fn fold_frame(
        &self,
        frame: &ImageData,
        wcs: &SipWcs,
        weight: f64,
        exposure_sec: f64,
        interp: Interpolator,
        mode: AccumulationMode,
        label: &str,
        contributor: &str,
    ) -> Result<Vec<(TileId, TileFoldRecord)>, AtlasError> {
        if !wcs.is_invertible() {
            return Err(AtlasError::DegenerateWcs);
        }
        let tiles = tile_ids_for_frame(wcs, frame.width, frame.height, self.order);
        if tiles.is_empty() {
            return Err(AtlasError::NoCoverage);
        }
        // The budget bounds how many *buffers* we may hold resident; we process
        // tiles sequentially (one buffer) so the bound is structurally honoured,
        // and we assert it to document the contract for future batched variants.
        debug_assert!(self.memory_budget_bytes >= tile_buffer_bytes(frame.channels));

        let mut out = Vec::new();
        for tid in tiles {
            let mut tile = self.load_or_create(tid, frame.channels, mode)?;
            let rec =
                tile.fold_frame(frame, wcs, weight, exposure_sec, interp, label, contributor)?;
            if rec.frames_added > 0 || !tile_is_empty(&tile) {
                self.store_tile(&tile)?;
            }
            out.push((tid, rec));
        }
        Ok(out)
    }

    /// Query: the finalized co-added cutout over a cone, plus its coverage map.
    ///
    /// The cone's tiles are loaded one at a time and each tile pixel whose centre
    /// falls inside the cone is reprojected onto a fresh output TAN grid centred
    /// on the cone (scale = the tile scale), accumulating a weighted mean so
    /// overlapping tiles blend seamlessly. Returns `(cutout_f32, coverage_f32)`
    /// at the requested `out_pixels` square edge.
    pub fn query_cone(
        &self,
        center_ra: f64,
        center_dec: f64,
        radius_deg: f64,
        channels: u32,
        out_pixels: u32,
        interp: Interpolator,
    ) -> Result<(ImageData, ImageData), AtlasError> {
        let out_w = out_pixels.max(1) as usize;
        let out_h = out_w;
        let ch = channels as usize;
        // Output grid: TAN centred on the cone, spanning 2·radius (+ margin).
        let span_deg = (2.0 * radius_deg * TILE_SCALE_MARGIN).max(1e-6);
        let scale_deg = span_deg / (out_w as f64);
        let crpix = (out_w as f64) / 2.0 + 0.5;
        let out_wcs = SipWcs::tan_only(
            center_ra, center_dec, crpix, crpix, -scale_deg, 0.0, 0.0, scale_deg,
        );

        let len = out_w * out_h * ch;
        let mut acc = vec![0.0f64; len];
        let mut wsum = vec![0.0f64; len];
        let mut cover = vec![0.0f64; len];

        let tiles = tile_ids_for_cone(center_ra, center_dec, radius_deg, self.order);
        for tid in tiles {
            let Some(tile) = self.load_tile(tid)? else {
                continue;
            };
            if tile.channels != channels {
                return Err(AtlasError::ChannelMismatch {
                    got: tile.channels,
                    expected: channels,
                });
            }
            // Finalized tile raster + its coverage (resident one tile at a time).
            let finalized = tile.finalize();
            let tile_f32 = finalized.as_f32().expect("finalize yields F32");
            let tile_cov = tile.coverage_map();
            let cov_f32 = tile_cov.as_f32().expect("coverage map is F32");
            let tw = tile.width as usize;
            let th = tile.height as usize;
            // Interleave to f64 for the resampler.
            let tile_buf: Vec<f64> = tile_f32.iter().map(|&v| v as f64).collect();
            let cov_buf: Vec<f64> = cov_f32.iter().map(|&v| v as f64).collect();

            for oy in 0..out_h {
                for ox in 0..out_w {
                    let (ra, dec) = out_wcs.pixel_to_world(ox as f64, oy as f64);
                    let Some((sx, sy)) = tile.wcs.world_to_pixel(ra, dec) else {
                        continue;
                    };
                    if sx < 0.0 || sy < 0.0 || sx > (tw as f64 - 1.0) || sy > (th as f64 - 1.0) {
                        continue;
                    }
                    // Coverage at this tile pixel (nearest, since it is a count).
                    let cov_here =
                        sample_interleaved(&cov_buf, tw, th, ch, 0, sx, sy, Interpolator::Bilinear);
                    if cov_here <= 0.0 {
                        continue;
                    }
                    for c in 0..ch {
                        let v = sample_interleaved(&tile_buf, tw, th, ch, c, sx, sy, interp);
                        if !v.is_finite() {
                            continue;
                        }
                        let slot = (oy * out_w + ox) * ch + c;
                        acc[slot] += cov_here * v;
                        wsum[slot] += cov_here;
                        // Coverage is a DEPTH, not a flux: in the overlap band where
                        // several tiles cover the same output pixel, the true depth is
                        // the deepest contributor, not the sum (summing double-counts
                        // the same sky and reports a fictitious depth at every seam).
                        // The pixel VALUE stays the coverage-weighted mean (acc/wsum).
                        cover[slot] = cover[slot].max(cov_here);
                    }
                }
            }
        }

        let mut out = vec![0.0f32; len];
        for i in 0..len {
            out[i] = if wsum[i] > 0.0 {
                (acc[i] / wsum[i]) as f32
            } else {
                0.0
            };
        }
        let cov_out: Vec<f32> = cover.iter().map(|&c| c as f32).collect();
        Ok((
            ImageData::from_f32(out_pixels.max(1), out_pixels.max(1), channels, &out),
            ImageData::from_f32(out_pixels.max(1), out_pixels.max(1), channels, &cov_out),
        ))
    }
}

/// Bytes one resident tile accumulator buffer occupies (the six running vectors
/// for a [`TILE_PIXELS`]² grid with `channels` channels): four f64 + two u32.
fn tile_buffer_bytes(channels: u32) -> u64 {
    let slots = (TILE_PIXELS as u64) * (TILE_PIXELS as u64) * (channels as u64);
    slots * (8 * 4 + 4 * 2)
}

/// True if a tile has accumulated no samples (so storing it would only litter
/// the atlas with empty sidecars).
fn tile_is_empty(tile: &SkyTileAccumulator) -> bool {
    tile.state.coverage.iter().all(|&c| c == 0)
}

/// Decode an [`ImageData`] to channel-interleaved f64 (the resampler's layout).
/// U16 and F32 are supported (the linear types the pipeline emits); other types
/// decode to an empty buffer, which the caller treats as no contribution.
fn decode_to_f64(image: &ImageData) -> Vec<f64> {
    if let Some(f) = image.as_f32() {
        f.into_iter().map(|v| v as f64).collect()
    } else if let Some(u) = image.as_u16() {
        u.into_iter().map(|v| v as f64).collect()
    } else {
        Vec::new()
    }
}

/// Estimate a frame's per-channel robust photometric baseline: the sky
/// `background` (median) and signal `scale` (`1.4826·MAD`, the Gaussian-consistent
/// robust spread). Channels with no finite samples fall back to the identity
/// `(0, 1)`. A degenerate (zero) spread is floored to 1.0 so a flat frame maps
/// through as a pure pedestal shift rather than dividing by zero.
fn estimate_frame_norm(src: &[f64], channels: usize) -> NormalizationReference {
    let ch = channels.max(1);
    let mut background = vec![0.0; ch];
    let mut scale = vec![1.0; ch];
    let npix = src.len().checked_div(ch).unwrap_or(0);
    for c in 0..ch {
        let mut vals: Vec<f64> = (0..npix)
            .map(|p| src[p * ch + c])
            .filter(|v| v.is_finite())
            .collect();
        if vals.is_empty() {
            continue;
        }
        vals.sort_unstable_by(f64::total_cmp);
        let median = percentile_sorted(&vals, 0.5);
        let mut dev: Vec<f64> = vals.iter().map(|&v| (v - median).abs()).collect();
        dev.sort_unstable_by(f64::total_cmp);
        let mad = percentile_sorted(&dev, 0.5);
        let s = MAD_TO_SIGMA * mad;
        background[c] = median;
        scale[c] = if s.is_finite() && s > 0.0 { s } else { 1.0 };
    }
    NormalizationReference { background, scale }
}

/// Map a raw sample onto the frozen reference's photometric scale:
/// `v' = (v - frame_bg)·(ref_scale / frame_scale) + ref_bg`. Reduces to the
/// identity when the frame *is* the reference (the first contribution), so the
/// single-rig path is unchanged bit-for-bit.
#[inline]
fn normalize_sample(v: f64, frame_bg: f64, frame_scale: f64, ref_bg: f64, ref_scale: f64) -> f64 {
    if !(frame_scale.is_finite() && frame_scale > 0.0) {
        return v;
    }
    (v - frame_bg) * (ref_scale / frame_scale) + ref_bg
}

fn read_f64(bytes: &[u8], cursor: &mut usize, len: usize) -> Vec<f64> {
    let mut out = Vec::with_capacity(len);
    for _ in 0..len {
        let c = *cursor;
        out.push(f64::from_le_bytes(
            bytes[c..c + 8].try_into().expect("8 bytes"),
        ));
        *cursor += 8;
    }
    out
}

fn read_u32(bytes: &[u8], cursor: &mut usize, len: usize) -> Vec<u32> {
    let mut out = Vec::with_capacity(len);
    for _ in 0..len {
        let c = *cursor;
        out.push(u32::from_le_bytes(
            bytes[c..c + 4].try_into().expect("4 bytes"),
        ));
        *cursor += 4;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::master_accumulation::OnlineClip;

    fn no_clip() -> AccumulationMode {
        AccumulationMode::RunningWeightedMean { clip: None }
    }

    // HEALPix addressing

    #[test]
    fn tile_round_trip_center_maps_back_to_same_tile() {
        // pix -> centre -> pix must be the identity for a spread of tiles across
        // all twelve base faces and both caps.
        let order = ATLAS_HEALPIX_ORDER;
        let npix = npix_for(order);
        for &id in &[
            0u64,
            1,
            npix / 12, // start of face 1
            npix / 2,  // equatorial belt
            npix - 1,  // last (south cap)
            npix / 3,
            npix / 4 + 7,
            123_456,
        ] {
            let id = id % npix;
            let (ra, dec) = tile_center(id, order);
            let back = radec_to_tile(ra, dec, order);
            assert_eq!(back, id, "tile {id} centre ({ra},{dec}) -> {back}");
        }
    }

    #[test]
    fn cone_covers_the_center_tile_and_a_plausible_count() {
        let order = ATLAS_HEALPIX_ORDER;
        let (ra, dec) = (83.6, -5.4);
        let center = radec_to_tile(ra, dec, order);
        let ids = tile_ids_for_cone(ra, dec, 0.0, order);
        assert!(
            ids.contains(&center),
            "zero-radius cone must include centre"
        );

        // A 0.3° cone at order 9 (~6.9' tiles) should cover a handful of tiles,
        // and every returned id must be a valid pixel.
        let ids = tile_ids_for_cone(ra, dec, 0.3, order);
        assert!(ids.contains(&center));
        assert!(ids.len() > 1 && ids.len() < 2000, "got {} tiles", ids.len());
        let npix = npix_for(order);
        for &id in &ids {
            assert!(id < npix);
        }
    }

    #[test]
    fn cone_is_gap_free_for_sampled_directions() {
        // Every direction inside the cone must land in a tile the cone enumerates
        // (the gap-free guarantee the fold relies on).
        let order = 7; // coarser -> fewer tiles, faster, same property
        let (ra, dec) = (200.0, 40.0);
        let radius = 1.0;
        let ids: std::collections::HashSet<TileId> = tile_ids_for_cone(ra, dec, radius, order)
            .into_iter()
            .collect();
        let dec0 = dec.to_radians();
        let ra0 = ra.to_radians();
        let (sin_d0, cos_d0) = (dec0.sin(), dec0.cos());
        let mut checked = 0;
        for i in 0..40 {
            for j in 0..40 {
                let rho = (radius * 0.95) * (i as f64 / 39.0);
                let az = 2.0 * std::f64::consts::PI * (j as f64 / 40.0);
                let rr = rho.to_radians();
                let sin_dec = sin_d0 * rr.cos() + cos_d0 * rr.sin() * az.cos();
                let d = sin_dec.clamp(-1.0, 1.0).asin();
                let dra =
                    (rr.sin() * az.sin()).atan2(cos_d0 * rr.cos() - sin_d0 * rr.sin() * az.cos());
                let r = (ra0 + dra).to_degrees();
                let t = radec_to_tile(r, d.to_degrees(), order);
                assert!(ids.contains(&t), "cone missed a tile for an interior point");
                checked += 1;
            }
        }
        assert!(checked > 0);
    }

    // Fold + finalize

    /// A flat F32 frame whose WCS is the tile's own grid, so the frame covers the
    /// tile pixel-for-pixel. Returns (frame, wcs).
    fn frame_on_tile(
        tile_id: TileId,
        order: u32,
        value: f32,
        channels: u32,
    ) -> (ImageData, SipWcs) {
        let wcs = tile_wcs(tile_id, order);
        let w = TILE_PIXELS;
        let len = (w as usize) * (w as usize) * (channels as usize);
        let data = vec![value; len];
        (ImageData::from_f32(w, w, channels, &data), wcs)
    }

    #[test]
    fn fold_then_finalize_recovers_the_value() {
        let order = ATLAS_HEALPIX_ORDER;
        let tid = radec_to_tile(120.0, 25.0, order);
        let mut tile = SkyTileAccumulator::create(tid, order, 1, no_clip());
        let (frame, wcs) = frame_on_tile(tid, order, 1000.0, 1);
        let rec = tile
            .fold_frame(&frame, &wcs, 1.0, 300.0, Interpolator::Bilinear, "n1", "")
            .unwrap();
        assert_eq!(rec.frames_added, 1);
        assert!((rec.integration_seconds_added - 300.0).abs() < 1e-9);

        let out = tile.finalize().as_f32().unwrap();
        // The bulk of the tile (away from the very edge where the resampler has
        // no support) must recover ~1000.
        let mid = (TILE_PIXELS as usize / 2) * (TILE_PIXELS as usize) + TILE_PIXELS as usize / 2;
        assert!((out[mid] as f64 - 1000.0).abs() < 1.0, "got {}", out[mid]);
        assert!(tile.coverage_mean() > 0.5);
    }

    #[test]
    fn fold_honours_frame_sip_distortion() {
        // The atlas reproject must route through the frame's full SipWcs, not a
        // CD-only shortcut. Fold the same pixel data once with a CD-only frame WCS
        // and once with the same WCS plus a non-trivial forward SIP; the sampled
        // tile must differ, which is what proves SIP is applied. A gradient
        // frame makes the distortion observable.
        let order = ATLAS_HEALPIX_ORDER;
        let tid = radec_to_tile(140.0, -20.0, order);
        let w = TILE_PIXELS as usize;
        // Horizontal ramp so a pixel shift changes the sampled value.
        let mut data = vec![0.0f32; w * w];
        for y in 0..w {
            for x in 0..w {
                data[y * w + x] = x as f32;
            }
        }
        let frame = ImageData::from_f32(TILE_PIXELS, TILE_PIXELS, 1, &data);

        let cd_only = tile_wcs(tid, order);
        let mut with_sip = cd_only.clone();
        let stride = 3usize; // order 2
        with_sip.a_order = 2;
        with_sip.b_order = 2;
        let mut a = vec![0.0; stride * stride];
        let mut b = vec![0.0; stride * stride];
        a[2 * stride] = 5.0e-6; // A_2_0 — several px of distortion at the edge
        b[2] = 5.0e-6; // B_0_2
        with_sip.a_coeffs = a;
        with_sip.b_coeffs = b;
        assert_ne!(with_sip, cd_only);

        let mut plain = SkyTileAccumulator::create(tid, order, 1, no_clip());
        plain
            .fold_frame(&frame, &cd_only, 1.0, 0.0, Interpolator::Bilinear, "p", "")
            .unwrap();
        let mut distorted = SkyTileAccumulator::create(tid, order, 1, no_clip());
        distorted
            .fold_frame(&frame, &with_sip, 1.0, 0.0, Interpolator::Bilinear, "d", "")
            .unwrap();

        let p = plain.finalize().as_f32().unwrap();
        let d = distorted.finalize().as_f32().unwrap();
        // Somewhere off-axis (where SIP bites) the two reprojections must diverge.
        let mut max_diff = 0.0f64;
        for (pv, dv) in p.iter().zip(&d) {
            max_diff = max_diff.max((*pv as f64 - *dv as f64).abs());
        }
        assert!(
            max_diff > 1.0,
            "frame SIP was not applied during reprojection (max diff {max_diff})"
        );
    }

    // The additivity property

    /// A structured (ramped) frame on a tile's own grid so the per-channel robust
    /// scale (MAD) is non-degenerate and the photometric normalization is
    /// exercised — a flat constant frame has zero spread and would collapse under
    /// normalization. `base` sets the pedestal; the ramp adds 0..(w-1) across x.
    fn ramped_frame_on_tile(
        tile_id: TileId,
        order: u32,
        base: f32,
        channels: u32,
    ) -> (ImageData, SipWcs) {
        let wcs = tile_wcs(tile_id, order);
        let w = TILE_PIXELS as usize;
        let ch = channels as usize;
        let mut data = vec![0.0f32; w * w * ch];
        for y in 0..w {
            for x in 0..w {
                for c in 0..ch {
                    data[(y * w + x) * ch + c] = base + (x as f32) * 0.5;
                }
            }
        }
        (
            ImageData::from_f32(TILE_PIXELS, TILE_PIXELS, channels, &data),
            wcs,
        )
    }

    #[test]
    fn merge_equals_combined_fold_exactly_no_clip() {
        // Two contributors fold disjoint frames into separate tiles, then merge.
        // The merged finalized tile must equal one tile that folded BOTH frames,
        // bit-for-bit (within f64 round-off) — the federation correctness proof.
        // Both contributors normalize against the SAME frozen reference (the one
        // the first fold establishes / the merge target adopts), which is the
        // prerequisite for the co-add being photometrically valid AND additive.
        let order = ATLAS_HEALPIX_ORDER;
        let tid = radec_to_tile(45.0, 10.0, order);

        let (f1, w1) = ramped_frame_on_tile(tid, order, 800.0, 1);
        let (f2, w2) = ramped_frame_on_tile(tid, order, 1200.0, 1);

        // Combined: one tile folds both frames (freezes its reference from f1).
        let mut combined = SkyTileAccumulator::create(tid, order, 1, no_clip());
        combined
            .fold_frame(&f1, &w1, 1.0, 100.0, Interpolator::Bilinear, "a", "alice")
            .unwrap();
        combined
            .fold_frame(&f2, &w2, 2.0, 100.0, Interpolator::Bilinear, "b", "bob")
            .unwrap();

        // Federated: alice folds f1 (freezing the reference), bob adopts that same
        // reference before folding f2, hub merges bob into alice.
        let mut alice = SkyTileAccumulator::create(tid, order, 1, no_clip());
        alice
            .fold_frame(&f1, &w1, 1.0, 100.0, Interpolator::Bilinear, "a", "alice")
            .unwrap();
        let mut bob = SkyTileAccumulator::create(tid, order, 1, no_clip());
        bob.adopt_reference(alice.norm_reference());
        bob.fold_frame(&f2, &w2, 2.0, 100.0, Interpolator::Bilinear, "b", "bob")
            .unwrap();
        merge_tiles(&mut alice, &bob, 1.0).unwrap();

        let c = combined.finalize().as_f32().unwrap();
        let m = alice.finalize().as_f32().unwrap();
        assert_eq!(c.len(), m.len());
        for (i, (a, b)) in c.iter().zip(&m).enumerate() {
            assert!(
                (*a as f64 - *b as f64).abs() < 1e-3,
                "pixel {i}: combined {a} != merged {b}"
            );
        }
        // Provenance unioned.
        assert_eq!(alice.provenance.total_frames, 2);
        assert!(alice.provenance.contributors.contains(&"alice".to_string()));
        assert!(alice.provenance.contributors.contains(&"bob".to_string()));
    }

    #[test]
    fn merge_running_sums_are_bit_exact_vs_combined_fold() {
        // The finalized-f32 equality test is convincing but lossy. Prove the
        // claim at the source: the six f64 running vectors after a full-trust
        // merge equal, element-for-element, the vectors of one accumulator that
        // folded both frames. This is the exact additivity Pillar C federates on.
        let order = ATLAS_HEALPIX_ORDER;
        let tid = radec_to_tile(220.0, 8.0, order);
        // Two *different-valued* frames so the sums are non-trivial, with unequal
        // weights so weighted terms differ per contributor.
        let (f1, w1) = ramped_frame_on_tile(tid, order, 640.0, 1);
        let (f2, w2) = ramped_frame_on_tile(tid, order, 1830.0, 1);

        let mut combined = SkyTileAccumulator::create(tid, order, 1, no_clip());
        combined
            .fold_frame(&f1, &w1, 1.3, 100.0, Interpolator::Lanczos3, "a", "alice")
            .unwrap();
        combined
            .fold_frame(&f2, &w2, 0.7, 100.0, Interpolator::Lanczos3, "b", "bob")
            .unwrap();

        let mut alice = SkyTileAccumulator::create(tid, order, 1, no_clip());
        alice
            .fold_frame(&f1, &w1, 1.3, 100.0, Interpolator::Lanczos3, "a", "alice")
            .unwrap();
        let mut bob = SkyTileAccumulator::create(tid, order, 1, no_clip());
        bob.adopt_reference(alice.norm_reference());
        bob.fold_frame(&f2, &w2, 0.7, 100.0, Interpolator::Lanczos3, "b", "bob")
            .unwrap();
        merge_tiles(&mut alice, &bob, 1.0).unwrap();

        // Element-for-element identity of all six running vectors.
        assert_eq!(alice.state.sum_w, combined.state.sum_w);
        assert_eq!(alice.state.sum_w2, combined.state.sum_w2);
        assert_eq!(alice.state.sum_wx, combined.state.sum_wx);
        assert_eq!(alice.state.sum_wx2, combined.state.sum_wx2);
        assert_eq!(alice.state.coverage, combined.state.coverage);
        assert_eq!(alice.state.rejected, combined.state.rejected);
    }

    #[test]
    fn cross_rig_gains_are_normalized_onto_one_scale() {
        // Two rigs image the same structured field at very different gains/pedestals
        // (rig B is ~10x the ADU of rig A). After folding both against the SAME
        // frozen reference, the co-add must be a sensible blend on rig A's scale —
        // NOT dominated by rig B's larger pedestal (the photometric-validity fix).
        let order = ATLAS_HEALPIX_ORDER;
        let tid = radec_to_tile(45.0, 10.0, order);
        let (fa, wa) = ramped_frame_on_tile(tid, order, 100.0, 1);
        // Rig B: same structure, 10x gain + a big pedestal (raw ADU 1000 + 10x ramp).
        let w = TILE_PIXELS as usize;
        let mut b = vec![0.0f32; w * w];
        for y in 0..w {
            for x in 0..w {
                b[y * w + x] = 1000.0 + (x as f32) * 5.0; // 10x A's ramp slope
            }
        }
        let fb = ImageData::from_f32(TILE_PIXELS, TILE_PIXELS, 1, &b);
        let wb = tile_wcs(tid, order);

        let mut acc = SkyTileAccumulator::create(tid, order, 1, no_clip());
        acc.fold_frame(&fa, &wa, 1.0, 100.0, Interpolator::Bilinear, "a", "rigA")
            .unwrap();
        // Rig B folds against rig A's frozen reference (the federation flow).
        acc.fold_frame(&fb, &wb, 1.0, 100.0, Interpolator::Bilinear, "b", "rigB")
            .unwrap();

        // Sample a mid-tile pixel: on rig A's scale the value at x≈512 is ~100+256
        // = ~356. If rig B's raw 10x ADU had leaked in unnormalized, the mean would
        // be pulled into the thousands. Normalization keeps it on rig A's scale.
        let out = acc.finalize().as_f32().unwrap();
        let mid = (w / 2) * w + (w / 2);
        let v = out[mid] as f64;
        assert!(
            v > 250.0 && v < 500.0,
            "co-add stayed on rig A's photometric scale: got {v} (raw rig-B ADU would be ~3500)"
        );
    }

    #[test]
    fn merge_subtract_retracts_exactly() {
        // Merging then subtracting a contributor must return to the pre-merge
        // state (linear retraction).
        let order = ATLAS_HEALPIX_ORDER;
        let tid = radec_to_tile(300.0, -30.0, order);
        let (f1, w1) = frame_on_tile(tid, order, 500.0, 1);
        let (f2, w2) = frame_on_tile(tid, order, 1500.0, 1);

        let mut base = SkyTileAccumulator::create(tid, order, 1, no_clip());
        base.fold_frame(&f1, &w1, 1.0, 60.0, Interpolator::Bilinear, "a", "")
            .unwrap();
        let before = base.finalize().as_f32().unwrap();

        let mut delta = SkyTileAccumulator::create(tid, order, 1, no_clip());
        delta
            .fold_frame(&f2, &w2, 1.0, 60.0, Interpolator::Bilinear, "b", "carol")
            .unwrap();

        merge_tiles(&mut base, &delta, 1.0).unwrap();
        merge_tiles_subtract(&mut base, &delta, 1.0).unwrap();
        let after = base.finalize().as_f32().unwrap();

        for (x, y) in before.iter().zip(&after) {
            assert!((*x as f64 - *y as f64).abs() < 1e-6, "{x} != {y}");
        }
        assert_eq!(base.provenance.total_frames, 1);
    }

    #[test]
    fn trust_weighted_merge_keeps_a_consistent_sum_w2() {
        // A trust-scaled merge must scale Σw² by trust² (quadratic), not trust, so
        // the merged tile's (Σw, Σw²) are exactly the sums of the trust-scaled
        // weights and the online clip's effective-sample-size denominator
        // `Σw − Σw²/Σw` stays strictly positive (the clip is well-defined). With the
        // old linear scaling that denominator is wrong and can go non-positive,
        // silently disabling rejection on later folds into the merged tile.
        let order = ATLAS_HEALPIX_ORDER;
        let tid = radec_to_tile(133.0, 22.0, order);
        let trust = 0.4;

        // A destination with its own history (unequal weights so Σw² != Σw), into
        // which a contributor is merged at less-than-full trust.
        let mut dst = SkyTileAccumulator::create(tid, order, 1, no_clip());
        let (d1, dw1) = frame_on_tile(tid, order, 800.0, 1);
        let (d2, dw2) = frame_on_tile(tid, order, 1200.0, 1);
        dst.fold_frame(&d1, &dw1, 1.3, 0.0, Interpolator::Bilinear, "d1", "")
            .unwrap();
        dst.fold_frame(&d2, &dw2, 0.6, 0.0, Interpolator::Bilinear, "d2", "")
            .unwrap();

        let mut other = SkyTileAccumulator::create(tid, order, 1, no_clip());
        other.adopt_reference(dst.norm_reference());
        let (o1, ow1) = frame_on_tile(tid, order, 1000.0, 1);
        let (o2, ow2) = frame_on_tile(tid, order, 1400.0, 1);
        other
            .fold_frame(&o1, &ow1, 0.9, 0.0, Interpolator::Bilinear, "o1", "")
            .unwrap();
        other
            .fold_frame(&o2, &ow2, 1.1, 0.0, Interpolator::Bilinear, "o2", "")
            .unwrap();

        merge_tiles(&mut dst, &other, trust).unwrap();

        // Reference: fold the SAME contributor frames into a from-scratch tile with
        // their weights scaled by `trust`. The merged Σw and Σw² must equal the
        // destination's own contribution PLUS this trust-scaled fold, element-wise.
        let mut scaled = SkyTileAccumulator::create(tid, order, 1, no_clip());
        scaled
            .fold_frame(&d1, &dw1, 1.3, 0.0, Interpolator::Bilinear, "d1", "")
            .unwrap();
        scaled
            .fold_frame(&d2, &dw2, 0.6, 0.0, Interpolator::Bilinear, "d2", "")
            .unwrap();
        scaled
            .fold_frame(
                &o1,
                &ow1,
                0.9 * trust,
                0.0,
                Interpolator::Bilinear,
                "o1",
                "",
            )
            .unwrap();
        scaled
            .fold_frame(
                &o2,
                &ow2,
                1.1 * trust,
                0.0,
                Interpolator::Bilinear,
                "o2",
                "",
            )
            .unwrap();

        let len = dst.slot_count();
        for i in 0..len {
            assert!(
                (dst.state.sum_w[i] - scaled.state.sum_w[i]).abs() < 1e-9,
                "slot {i}: sum_w {} != trust-scaled fold {}",
                dst.state.sum_w[i],
                scaled.state.sum_w[i]
            );
            assert!(
                (dst.state.sum_w2[i] - scaled.state.sum_w2[i]).abs() < 1e-9,
                "slot {i}: sum_w2 {} != trust-scaled fold {} (must scale by trust², not trust)",
                dst.state.sum_w2[i],
                scaled.state.sum_w2[i]
            );
        }

        // The online-clip denominator `Σw − Σw²/Σw` must be strictly positive at a
        // covered pixel — the property the quadratic scaling preserves. Probe the
        // tile centre, which the on-tile frame footprint always covers (corners can
        // fall just outside the reprojected footprint).
        let probe = (TILE_PIXELS as usize / 2) * (TILE_PIXELS as usize) + TILE_PIXELS as usize / 2;
        let sw = dst.state.sum_w[probe];
        let sw2 = dst.state.sum_w2[probe];
        assert!(sw > 0.0, "probe pixel must have coverage");
        assert!(
            sw - sw2 / sw > 0.0,
            "online-clip denominator Σw − Σw²/Σw must stay positive (sw={sw}, sw2={sw2})"
        );
    }

    #[test]
    fn trust_scales_the_merge() {
        // A trust of 0 contributes nothing; a trust of 1 contributes fully.
        let order = ATLAS_HEALPIX_ORDER;
        let tid = radec_to_tile(10.0, 60.0, order);
        let (f1, w1) = frame_on_tile(tid, order, 100.0, 1);
        let (f2, w2) = frame_on_tile(tid, order, 900.0, 1);

        let mut zero_trust = SkyTileAccumulator::create(tid, order, 1, no_clip());
        zero_trust
            .fold_frame(&f1, &w1, 1.0, 0.0, Interpolator::Bilinear, "a", "")
            .unwrap();
        let mut other = SkyTileAccumulator::create(tid, order, 1, no_clip());
        other
            .fold_frame(&f2, &w2, 1.0, 0.0, Interpolator::Bilinear, "b", "x")
            .unwrap();

        let mut t0 = zero_trust.clone();
        merge_tiles(&mut t0, &other, 0.0).unwrap();
        let mut t1 = zero_trust.clone();
        merge_tiles(&mut t1, &other, 1.0).unwrap();

        let center = (TILE_PIXELS as usize / 2) * (TILE_PIXELS as usize) + TILE_PIXELS as usize / 2;
        let v0 = t0.finalize().as_f32().unwrap()[center] as f64;
        let v1 = t1.finalize().as_f32().unwrap()[center] as f64;
        assert!((v0 - 100.0).abs() < 1.0, "zero-trust stayed at base: {v0}");
        // Equal weights, full trust -> mean of 100 and 900 = 500.
        assert!((v1 - 500.0).abs() < 2.0, "full-trust merged mean: {v1}");
    }

    // Serialize / deserialize

    #[test]
    fn serialize_deserialize_round_trips() {
        let order = ATLAS_HEALPIX_ORDER;
        let tid = radec_to_tile(150.0, 5.0, order);
        let mut tile = SkyTileAccumulator::create(tid, order, 3, AccumulationMode::default());
        let (frame, wcs) = frame_on_tile(tid, order, 700.0, 3);
        tile.fold_frame(&frame, &wcs, 1.5, 120.0, Interpolator::Bilinear, "n", "me")
            .unwrap();

        let bytes = tile.serialize();
        assert!(bytes.starts_with(TILE_MAGIC));
        let restored = SkyTileAccumulator::deserialize(&bytes).expect("round trip");
        assert_eq!(restored, tile);
    }

    #[test]
    fn deserialize_rejects_bad_magic_and_version() {
        assert_eq!(
            SkyTileAccumulator::deserialize(b"BADM\x01\x00\x00\x00\x00\x00\x00\x00").unwrap_err(),
            AtlasError::BadMagic
        );
        let mut blob = Vec::new();
        blob.extend_from_slice(TILE_MAGIC);
        blob.extend_from_slice(&99u32.to_le_bytes());
        blob.extend_from_slice(&0u32.to_le_bytes());
        assert_eq!(
            SkyTileAccumulator::deserialize(&blob).unwrap_err(),
            AtlasError::UnsupportedVersion {
                got: 99,
                supported: TILE_STATE_VERSION,
            }
        );
    }

    #[test]
    fn merge_rejects_mismatched_geometry() {
        let order = ATLAS_HEALPIX_ORDER;
        let a_id = radec_to_tile(10.0, 10.0, order);
        let b_id = radec_to_tile(200.0, -40.0, order);
        let mut a = SkyTileAccumulator::create(a_id, order, 1, no_clip());
        let b = SkyTileAccumulator::create(b_id, order, 1, no_clip());
        assert_eq!(
            merge_tiles(&mut a, &b, 1.0).unwrap_err(),
            AtlasError::GeometryMismatch {
                got: b_id,
                expected: a_id,
            }
        );
    }

    // Out-of-core atlas (disk round-trip + query)

    #[test]
    fn atlas_fold_persists_and_query_recovers() {
        let dir = std::env::temp_dir().join(format!("sk_atlas_test_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let atlas = SkyAtlas::open(&dir, ATLAS_HEALPIX_ORDER, 256 * 1024 * 1024);

        // Fold a flat frame placed on one tile's grid.
        let tid = radec_to_tile(60.0, 15.0, ATLAS_HEALPIX_ORDER);
        let (frame, wcs) = frame_on_tile(tid, ATLAS_HEALPIX_ORDER, 1234.0, 1);
        let recs = atlas
            .fold_frame(
                &frame,
                &wcs,
                1.0,
                300.0,
                Interpolator::Bilinear,
                no_clip(),
                "session-1",
                "",
            )
            .unwrap();
        assert!(recs.iter().any(|(_, r)| r.frames_added > 0));

        // The sidecar exists on disk.
        assert!(atlas.tile_path(tid).exists());

        // Reload and confirm the centre value.
        let reloaded = atlas.load_tile(tid).unwrap().expect("tile on disk");
        let out = reloaded.finalize().as_f32().unwrap();
        let mid = (TILE_PIXELS as usize / 2) * (TILE_PIXELS as usize) + TILE_PIXELS as usize / 2;
        assert!((out[mid] as f64 - 1234.0).abs() < 1.0);

        // Query a small cone over the tile centre; the cutout centre must recover
        // the folded value and report coverage.
        let (tile_ra, tile_dec) = tile_center(tid, ATLAS_HEALPIX_ORDER);
        let (cut, cov) = atlas
            .query_cone(tile_ra, tile_dec, 0.02, 1, 64, Interpolator::Bilinear)
            .unwrap();
        let cut_f = cut.as_f32().unwrap();
        let cov_f = cov.as_f32().unwrap();
        let cmid = 32 * 64 + 32;
        assert!(
            (cut_f[cmid] as f64 - 1234.0).abs() < 5.0,
            "query cutout centre {} should recover the folded value",
            cut_f[cmid]
        );
        assert!(
            cov_f[cmid] > 0.0,
            "query must report coverage at the centre"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn store_tile_unique_temp_no_collision_under_concurrency() {
        // Many concurrent store_tile calls for the SAME tile must not collide on
        // a shared `.nst.tmp` path; each write uses a pid+nonce-unique temp and a
        // final atomic rename, so the on-disk sidecar is always a complete,
        // deserializable accumulator after the storm settles.
        use std::sync::Arc;
        let dir = std::env::temp_dir().join(format!(
            "sk_atlas_store_tmp_{}_{}",
            std::process::id(),
            STORE_TILE_NONCE.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = std::fs::remove_dir_all(&dir);
        let atlas = Arc::new(SkyAtlas::open(&dir, ATLAS_HEALPIX_ORDER, 256 * 1024 * 1024));

        let tid = radec_to_tile(120.0, 30.0, ATLAS_HEALPIX_ORDER);
        let (frame, wcs) = frame_on_tile(tid, ATLAS_HEALPIX_ORDER, 777.0, 1);
        // A populated accumulator to serialize on every write.
        let mut seed = SkyTileAccumulator::create(tid, ATLAS_HEALPIX_ORDER, 1, no_clip());
        seed.fold_frame(&frame, &wcs, 1.0, 100.0, Interpolator::Bilinear, "seed", "")
            .unwrap();
        let seed = Arc::new(seed);

        let handles: Vec<_> = (0..16)
            .map(|_| {
                let atlas = Arc::clone(&atlas);
                let seed = Arc::clone(&seed);
                std::thread::spawn(move || atlas.store_tile(&seed))
            })
            .collect();
        for h in handles {
            h.join()
                .expect("store_tile thread panicked")
                .expect("store_tile must not error");
        }

        // The final sidecar deserializes cleanly (no half-written / clobbered temp
        // got renamed into place).
        let reloaded = atlas.load_tile(tid).unwrap().expect("tile on disk");
        assert_eq!(reloaded.tile_id, tid);
        // No stray `.nst.tmp.*` temp files survived the storm.
        let tiles_dir = atlas.tile_path(tid).parent().unwrap().to_path_buf();
        let leftover_tmp = std::fs::read_dir(&tiles_dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_name().to_string_lossy().contains(".nst.tmp."))
            .count();
        assert_eq!(leftover_tmp, 0, "no temp files should remain after renames");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn online_clip_rejects_a_transient_in_a_tile() {
        let order = ATLAS_HEALPIX_ORDER;
        let tid = radec_to_tile(75.0, -10.0, order);
        let mode = AccumulationMode::RunningWeightedMean {
            clip: Some(OnlineClip {
                low: 3.0,
                high: 3.0,
            }),
        };
        let mut tile = SkyTileAccumulator::create(tid, order, 1, mode);
        // Build clean history with a little scatter so the running σ is well
        // defined (a perfectly flat history has σ = 0 and the clip — correctly —
        // never fires, exactly like the master's online-clip test).
        for k in 0..10 {
            let v = 1000.0 + ((k as f32 % 3.0) - 1.0) * 5.0;
            let (f, w) = frame_on_tile(tid, order, v, 1);
            tile.fold_frame(&f, &w, 1.0, 0.0, Interpolator::Bilinear, "clean", "")
                .unwrap();
        }
        // A bright transient frame.
        let (spike, sw) = frame_on_tile(tid, order, 50000.0, 1);
        let rec = tile
            .fold_frame(&spike, &sw, 1.0, 0.0, Interpolator::Bilinear, "spike", "")
            .unwrap();
        assert!(rec.rejected > 0, "the transient must be clipped");
        let mid = (TILE_PIXELS as usize / 2) * (TILE_PIXELS as usize) + TILE_PIXELS as usize / 2;
        let v = tile.finalize().as_f32().unwrap()[mid] as f64;
        assert!((v - 1000.0).abs() < 50.0, "finalized stayed near 1000: {v}");
    }

    // Cross-language parity fixtures
    //
    // The hub (`server/skotiq_hub`) re-implements this module's `NST1`
    // additive tile codec in Dart and claims byte-for-byte parity. To make a
    // silent layout drift on either side a *test failure* rather than a silent
    // corruption of every community stack, this test emits Rust-produced
    // ground-truth artifacts into the hub's fixtures directory:
    //
    //   * `tile_a.nst`, `tile_b.nst` — two compact (4x4x1) serialized
    //     accumulators with deterministic, distinct per-slot running sums.
    //   * `merge_expected.json` — the exact `merge_signed(a, b, trust=0.5,
    //     +1)` result (the six running vectors + finalized mean) computed by
    //     THIS crate, so the Dart `mergeSigned` is asserted against Rust math,
    //     not against a Dart re-derivation.
    //
    // The Dart `tile_codec_test.dart` reads these fixtures and asserts it
    // decodes the identical vectors and produces the identical merge. Run with
    // `SKOTIQ_EMIT_FIXTURES=1` to (re)write them; otherwise the test only
    // self-checks the round-trip so CI never depends on a writable path.
    fn parity_tile(tile_id: TileId, base: f64) -> SkyTileAccumulator {
        // A deterministic 4x4 mono tile. Each slot i carries a distinct value so
        // a transposed or mis-ordered vector is detectable; weights vary per
        // slot so sum_w != coverage and a sum_w/sum_w2 swap is caught.
        let order = ATLAS_HEALPIX_ORDER;
        let len = 16usize;
        let mut t = SkyTileAccumulator {
            version: TILE_STATE_VERSION,
            tile_id,
            order,
            width: 4,
            height: 4,
            channels: 1,
            wcs: tile_wcs(tile_id, order),
            norm_reference: NormalizationReference {
                background: vec![0.0],
                scale: vec![1.0],
            },
            norm_frozen: true,
            mode: no_clip(),
            state: PerPixelAccumulator {
                sum_w: vec![0.0; len],
                sum_w2: vec![0.0; len],
                sum_wx: vec![0.0; len],
                sum_wx2: vec![0.0; len],
                coverage: vec![0; len],
                rejected: vec![0; len],
            },
            provenance: TileProvenance::default(),
        };
        for i in 0..len {
            let w = 1.0 + (i as f64) * 0.25; // per-slot weight
            let v = base + (i as f64); // per-slot value
            t.state.sum_w[i] = w;
            t.state.sum_w2[i] = w * w;
            t.state.sum_wx[i] = w * v;
            t.state.sum_wx2[i] = w * v * v;
            t.state.coverage[i] = (i as u32) % 5 + 1;
            t.state.rejected[i] = (i as u32) % 2;
        }
        t.provenance.total_frames = 4;
        t.provenance.total_integration_seconds = 1200.0;
        t.provenance.note_contributor("rust-fixture");
        t.provenance.folds.push(TileFoldRecord {
            frames_added: 4,
            weight_added: 4.0,
            integration_seconds_added: 1200.0,
            rejected: 0,
            label: format!("fixture-{tile_id}"),
            contributor: "rust-fixture".into(),
        });
        t
    }

    #[test]
    fn emit_hub_parity_fixtures() {
        let tile_id = radec_to_tile(83.6, -5.4, ATLAS_HEALPIX_ORDER);
        let a = parity_tile(tile_id, 100.0);
        let b = parity_tile(tile_id, 200.0);

        // Self-check: serialize -> deserialize is the identity (the Rust side of
        // the parity claim).
        let a_bytes = a.serialize();
        let b_bytes = b.serialize();
        assert_eq!(SkyTileAccumulator::deserialize(&a_bytes).unwrap(), a);
        assert_eq!(SkyTileAccumulator::deserialize(&b_bytes).unwrap(), b);

        // Ground-truth merge with a non-trivial trust so a missing trust-scale
        // in the Dart merge is caught: dst = a + 0.5 * b.
        let trust = 0.5;
        let mut merged = a.clone();
        merge_tiles(&mut merged, &b, trust).unwrap();
        let mean = merged.finalize();
        let mean = mean.as_f32().unwrap();

        // Compose the expected-merge metadata as JSON the Dart test asserts
        // against. Numbers are written with full f64 precision.
        let to_json_f64 = |v: &[f64]| -> String {
            let items: Vec<String> = v.iter().map(|x| format!("{x:?}")).collect();
            format!("[{}]", items.join(","))
        };
        let to_json_u32 = |v: &[u32]| -> String {
            let items: Vec<String> = v.iter().map(|x| x.to_string()).collect();
            format!("[{}]", items.join(","))
        };
        let mean_f64: Vec<f64> = mean.iter().map(|&x| x as f64).collect();
        let expected_json = format!(
            "{{\n  \"tileId\": {},\n  \"order\": {},\n  \"trust\": {trust:?},\n  \
             \"sum_w\": {},\n  \"sum_w2\": {},\n  \"sum_wx\": {},\n  \"sum_wx2\": {},\n  \
             \"coverage\": {},\n  \"rejected\": {},\n  \"mean\": {},\n  \
             \"total_frames\": {},\n  \"contributors\": {}\n}}\n",
            tile_id,
            merged.order,
            to_json_f64(&merged.state.sum_w),
            to_json_f64(&merged.state.sum_w2),
            to_json_f64(&merged.state.sum_wx),
            to_json_f64(&merged.state.sum_wx2),
            to_json_u32(&merged.state.coverage),
            to_json_u32(&merged.state.rejected),
            to_json_f64(&mean_f64),
            merged.provenance.total_frames,
            merged.provenance.contributors.len(),
        );

        // Only write the fixtures when explicitly asked (a writable repo
        // checkout); the round-trip self-check above runs unconditionally.
        if std::env::var("SKOTIQ_EMIT_FIXTURES").as_deref() == Ok("1") {
            let dir = Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../../server/skotiq_hub/test/fixtures");
            std::fs::create_dir_all(&dir).expect("create fixtures dir");
            std::fs::write(dir.join("tile_a.nst"), &a_bytes).expect("write tile_a");
            std::fs::write(dir.join("tile_b.nst"), &b_bytes).expect("write tile_b");
            std::fs::write(dir.join("merge_expected.json"), expected_json.as_bytes())
                .expect("write merge_expected");
        }
    }
}
