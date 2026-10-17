//! High-performance image processing with tiling and parallelism
//!
//! This module provides memory-efficient processing for large images by:
//! - Breaking images into tiles to avoid loading entire image into memory
//! - Processing tiles in parallel using rayon
//! - Providing progress callbacks for long operations
//! - Supporting streaming operations

use crate::{ImageData, PixelType};
use rayon::prelude::*;
use std::sync::{Arc, Mutex};

/// Tile region for processing
#[derive(Debug, Clone, Copy)]
pub struct TileRegion {
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
}

impl TileRegion {
    /// Create a new tile region
    pub fn new(x: u32, y: u32, width: u32, height: u32) -> Self {
        Self {
            x,
            y,
            width,
            height,
        }
    }

    /// Calculate the actual pixel count in this tile.
    ///
    /// Returns `None` if `width * height` overflows `u32`. A 32K x 32K tile would
    /// overflow `u32` (about 1.07 G pixels fits, but bigger tiles do not). Callers
    /// downstream allocate based on this value, so silent wrap would mis-size buffers.
    pub fn pixel_count(&self) -> usize {
        // Why: promote to u64 to avoid u32 multiplication overflow for very large tiles;
        // u64 -> usize is value-preserving on every Tier 1 target (usize is 32- or 64-bit
        // and we already overflow-check). On a 32-bit host with a > 4 G pixel tile, the
        // try_from would fail; saturate to usize::MAX so downstream allocation explodes
        // loudly rather than silently mis-sizing.
        let product = (self.width as u64).saturating_mul(self.height as u64);
        usize::try_from(product).unwrap_or(usize::MAX)
    }
}

/// Processing operation types
#[derive(Debug, Clone)]
pub enum ProcessOperation {
    /// Auto-stretch with given parameters
    AutoStretch {
        shadow: f64,
        midtone: f64,
        highlight: f64,
    },
    /// Normalize to 0-1 range
    Normalize,
    /// Apply gamma correction
    Gamma { gamma: f64 },
    /// Debayer (for RAW processing)
    Debayer { pattern: String },
    /// Custom operation (user-defined)
    Custom,
}

/// Progress callback type
pub type ProgressCallback = Arc<dyn Fn(f32) + Send + Sync>;

/// Calculate tile grid for an image
pub fn calculate_tile_grid(width: u32, height: u32, tile_size: u32) -> Vec<TileRegion> {
    let mut tiles = Vec::new();

    let tiles_x = width.div_ceil(tile_size);
    let tiles_y = height.div_ceil(tile_size);

    for ty in 0..tiles_y {
        for tx in 0..tiles_x {
            let x = tx * tile_size;
            let y = ty * tile_size;
            let w = (tile_size).min(width - x);
            let h = (tile_size).min(height - y);

            tiles.push(TileRegion::new(x, y, w, h));
        }
    }

    tiles
}

/// Process large image in tiles to avoid memory pressure
///
/// This function:
/// - Divides the image into tiles
/// - Processes each tile in parallel using rayon
/// - Merges results back together
/// - Reports progress via callback
///
/// Memory usage: ~(tile_size^2 * num_threads * bytes_per_pixel) instead of full image
///
/// # CPU-bound — not async
///
/// Despite the original name, this function is **synchronous and CPU-bound**:
/// all work runs inside `rayon::par_iter`. Callers on a Tokio runtime MUST wrap
/// the call in `tokio::task::spawn_blocking(...)` to avoid stalling the async
/// executor. Why: keeping it sync makes the blocking explicit
/// at the call site rather than hidden behind a deceptive `async fn`.
pub fn process_tiled(
    image: &ImageData,
    tile_size: u32,
    operation: ProcessOperation,
    progress_callback: Option<ProgressCallback>,
) -> Result<ImageData, String> {
    let tiles = calculate_tile_grid(image.width, image.height, tile_size);
    let total_tiles = tiles.len();

    tracing::info!(
        "Processing {}x{} image with {} tiles of size {}x{}",
        image.width,
        image.height,
        total_tiles,
        tile_size,
        tile_size
    );

    // Thread-safe progress counter
    let completed = Arc::new(Mutex::new(0usize));

    // per-tile min/max normalization breaks global brightness
    // consistency at tile boundaries. We compute the global range once and
    // every tile rescales against the same numbers.
    let global_minmax = if matches!(operation, ProcessOperation::Normalize) {
        Some(compute_global_minmax(image)?)
    } else {
        None
    };

    // Process tiles in parallel
    let results: Result<Vec<_>, String> = tiles
        .par_iter()
        .map(|tile| {
            let result = process_tile(image, tile, &operation, global_minmax.as_ref())?;

            // Update progress
            if let Some(ref callback) = progress_callback {
                // propagate poisoned-mutex panics rather than
                // silently taking the inner value (which would hide the bug
                // that caused the poison).
                let mut count = completed.lock().expect("progress mutex poisoned");
                *count += 1;
                let progress = (*count as f32) / (total_tiles as f32);
                callback(progress);
            }

            Ok((*tile, result))
        })
        .collect();

    let tile_results = results?;

    // Merge results
    merge_tile_results(
        tile_results,
        image.width,
        image.height,
        image.channels,
        image.pixel_type,
    )
}

/// Process a single tile
fn process_tile(
    image: &ImageData,
    tile: &TileRegion,
    operation: &ProcessOperation,
    global_minmax: Option<&GlobalMinMax>,
) -> Result<Vec<u8>, String> {
    // Extract tile data from full image
    let tile_data = extract_tile_data(image, tile)?;

    // Apply operation to tile
    match operation {
        ProcessOperation::AutoStretch {
            shadow,
            midtone,
            highlight,
        } => apply_stretch_to_tile(&tile_data, image.pixel_type, *shadow, *midtone, *highlight),
        ProcessOperation::Normalize => {
            // tile normalization MUST use the image-wide
            // min/max so tile boundaries don't produce visible discontinuities
            // in the merged output. `process_tiled` computes and passes them.
            let mm = global_minmax.ok_or_else(|| {
                "Normalize requires global min/max (process_tiled provides this)".to_string()
            })?;
            normalize_tile(&tile_data, image.pixel_type, mm)
        }
        ProcessOperation::Gamma { gamma } => {
            apply_gamma_to_tile(&tile_data, image.pixel_type, *gamma)
        }
        ProcessOperation::Debayer { pattern: _ } => {
            // Debayering needs neighboring-pixel context across tile boundaries.
            Err("Debayer operation not supported in tiled mode".to_string())
        }
        ProcessOperation::Custom => {
            // User would provide custom processing function
            Ok(tile_data)
        }
    }
}

/// Global pixel range for tiled normalization. See [`compute_global_minmax`].
#[derive(Debug, Clone, Copy)]
struct GlobalMinMax {
    min: f64,
    max: f64,
}

/// First-pass scan of the whole image to compute min/max for tiled normalization.
///
/// per-tile min/max produces visible discontinuities at tile
/// boundaries because each tile rescales against its own range. We compute the
/// global range once here, then each tile rescales against the same numbers.
fn compute_global_minmax(image: &ImageData) -> Result<GlobalMinMax, String> {
    match image.pixel_type {
        PixelType::U16 => {
            if image.data.len() < 2 {
                return Err("Image data too small for U16 normalization".to_string());
            }
            let (min, max) = image
                .data
                .par_chunks_exact(2)
                .map(|chunk| {
                    let v = u16::from_le_bytes([chunk[0], chunk[1]]);
                    (v, v)
                })
                .reduce(
                    || (u16::MAX, u16::MIN),
                    |(a_lo, a_hi), (b_lo, b_hi)| (a_lo.min(b_lo), a_hi.max(b_hi)),
                );
            Ok(GlobalMinMax {
                min: min as f64,
                max: max as f64,
            })
        }
        PixelType::F32 => {
            if image.data.len() < 4 {
                return Err("Image data too small for F32 normalization".to_string());
            }
            let (min, max) = image
                .data
                .par_chunks_exact(4)
                .map(|chunk| {
                    let v = f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]) as f64;
                    (v, v)
                })
                .reduce(
                    || (f64::INFINITY, f64::NEG_INFINITY),
                    |(a_lo, a_hi), (b_lo, b_hi)| (a_lo.min(b_lo), a_hi.max(b_hi)),
                );
            if !min.is_finite() || !max.is_finite() {
                return Err("Image contains no finite pixel values".to_string());
            }
            Ok(GlobalMinMax { min, max })
        }
        PixelType::U8 => {
            // the other branches all reject empty data with
            // a typed error; U8 used `unwrap_or(&0)`/`unwrap_or(&255)` which
            // would silently produce a (0, 255) range for an empty image and
            // then divide-by-zero downstream in the tile normalization. Match
            // the sibling branches and fail closed.
            if image.data.is_empty() {
                return Err("Image data empty (U8 normalization)".to_string());
            }
            let min = *image
                .data
                .iter()
                .min()
                .expect("U8 min: data is non-empty (just checked)") as f64;
            let max = *image
                .data
                .iter()
                .max()
                .expect("U8 max: data is non-empty (just checked)") as f64;
            Ok(GlobalMinMax { min, max })
        }
        PixelType::U32 => {
            if image.data.len() < 4 {
                return Err("Image data too small for U32 normalization".to_string());
            }
            let (min, max) = image
                .data
                .par_chunks_exact(4)
                .map(|chunk| {
                    let v = u32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]);
                    (v, v)
                })
                .reduce(
                    || (u32::MAX, u32::MIN),
                    |(a_lo, a_hi), (b_lo, b_hi)| (a_lo.min(b_lo), a_hi.max(b_hi)),
                );
            Ok(GlobalMinMax {
                min: min as f64,
                max: max as f64,
            })
        }
        PixelType::F64 => {
            if image.data.len() < 8 {
                return Err("Image data too small for F64 normalization".to_string());
            }
            let (min, max) = image
                .data
                .par_chunks_exact(8)
                .map(|chunk| {
                    let v = f64::from_le_bytes([
                        chunk[0], chunk[1], chunk[2], chunk[3], chunk[4], chunk[5], chunk[6],
                        chunk[7],
                    ]);
                    (v, v)
                })
                .reduce(
                    || (f64::INFINITY, f64::NEG_INFINITY),
                    |(a_lo, a_hi), (b_lo, b_hi)| (a_lo.min(b_lo), a_hi.max(b_hi)),
                );
            if !min.is_finite() || !max.is_finite() {
                return Err("Image contains no finite pixel values".to_string());
            }
            Ok(GlobalMinMax { min, max })
        }
    }
}

/// Extract tile data from full image
fn extract_tile_data(image: &ImageData, tile: &TileRegion) -> Result<Vec<u8>, String> {
    let bytes_per_pixel = image.bytes_per_pixel();
    // Why: image.channels is u8; widening to usize via `as` is always safe.
    let channels = image.channels as usize;
    // Why: image.width is u32; on 64-bit hosts u32 -> usize is widening. On 32-bit
    // hosts the stride product could overflow usize (a 65k-wide RGBA32 image is 1 MB
    // per row, well under usize::MAX, but pathological inputs warrant a checked path).
    let width_usize = image.width as usize;
    let stride = width_usize
        .checked_mul(bytes_per_pixel)
        .and_then(|s| s.checked_mul(channels))
        .ok_or_else(|| {
            format!(
                "Stride overflow: width={} bpp={} channels={}",
                image.width, bytes_per_pixel, channels
            )
        })?;

    let mut tile_data = Vec::with_capacity(tile.pixel_count() * bytes_per_pixel * channels);

    // Why: tile.width is u32; widening to usize is safe on every Tier 1 target.
    // The multiplication can overflow on 32-bit hosts for pathologically large tiles,
    // so use checked arithmetic.
    let row_len = (tile.width as usize)
        .checked_mul(bytes_per_pixel)
        .and_then(|r| r.checked_mul(channels))
        .ok_or_else(|| "Tile row_len overflow".to_string())?;

    for y in 0..tile.height {
        // Why: tile.y + y where both are u32; widening to usize via `as` is safe on
        // every Tier 1 target. The addition is u32 and cannot overflow for valid
        // tiles bounded by image dimensions (TileRegion is constructed from validated u32s).
        let src_y = (tile.y + y) as usize;
        let src_x = tile.x as usize;

        let row_start = src_y
            .checked_mul(stride)
            .and_then(|s| {
                let col_off = src_x.checked_mul(bytes_per_pixel)?.checked_mul(channels)?;
                s.checked_add(col_off)
            })
            .ok_or_else(|| "Tile row_start overflow".to_string())?;
        let row_end = row_start
            .checked_add(row_len)
            .ok_or_else(|| "Tile row_end overflow".to_string())?;
        if row_end <= image.data.len() {
            tile_data.extend_from_slice(&image.data[row_start..row_end]);
        } else {
            return Err("Tile region out of bounds".to_string());
        }
    }

    Ok(tile_data)
}

/// Apply stretch to tile data
fn apply_stretch_to_tile(
    data: &[u8],
    pixel_type: PixelType,
    shadow: f64,
    midtone: f64,
    highlight: f64,
) -> Result<Vec<u8>, String> {
    match pixel_type {
        PixelType::U16 => {
            let u16_data: Vec<u16> = data
                .as_chunks::<2>()
                .0
                .iter()
                .map(|chunk| u16::from_le_bytes([chunk[0], chunk[1]]))
                .collect();

            // Why: u16 -> f64 is lossless (53-bit mantissa easily holds 16-bit values).
            // After clamp(0.0, 1.0) * 255.0 the value is in [0.0, 255.0], so f64 -> u8
            // saturating truncation is safe and well-defined.
            let stretched: Vec<u8> = u16_data
                .par_iter()
                .map(|&val| {
                    let normalized = val as f64 / 65535.0;
                    let stretched = apply_mtf(normalized, shadow, midtone, highlight);
                    (stretched.clamp(0.0, 1.0) * 255.0) as u8
                })
                .collect();

            Ok(stretched)
        }
        PixelType::F32 => {
            let f32_data: Vec<f32> = data
                .as_chunks::<4>()
                .0
                .iter()
                .map(|chunk| f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]))
                .collect();

            // Why: f32 -> f64 is lossless widening; after clamp(0.0, 1.0) * 255.0 the
            // value is in [0.0, 255.0], so f64 -> u8 saturating truncation is safe.
            let stretched: Vec<u8> = f32_data
                .par_iter()
                .map(|&val| {
                    let stretched = apply_mtf(val as f64, shadow, midtone, highlight);
                    (stretched.clamp(0.0, 1.0) * 255.0) as u8
                })
                .collect();

            Ok(stretched)
        }
        _ => Ok(data.to_vec()),
    }
}

/// Apply midtone transfer function (MTF)
fn apply_mtf(value: f64, shadow: f64, midtone: f64, highlight: f64) -> f64 {
    // Guard against zero-width range (shadow == highlight)
    let range = highlight - shadow;
    if range.abs() < f64::EPSILON {
        return 0.0;
    }

    // Normalize to shadow-highlight range
    let normalized = ((value - shadow) / range).clamp(0.0, 1.0);

    // Apply midtone transfer
    if midtone < 0.5 {
        // Compress shadows
        let m = 2.0 * midtone;
        if m.abs() < f64::EPSILON {
            return 0.0;
        }
        normalized.powf(1.0 / m)
    } else {
        // Compress highlights
        let m = 2.0 * (1.0 - midtone);
        if m.abs() < f64::EPSILON {
            return 0.0;
        }
        1.0 - (1.0 - normalized).powf(1.0 / m)
    }
}

/// Normalize tile to 0-255 range using image-wide min/max.
///
/// each tile rescales against the same global range so tile
/// boundaries do not produce brightness discontinuities in the merged output.
fn normalize_tile(
    data: &[u8],
    pixel_type: PixelType,
    global: &GlobalMinMax,
) -> Result<Vec<u8>, String> {
    let range = global.max - global.min;
    match pixel_type {
        PixelType::U16 => {
            let u16_data: Vec<u16> = data
                .as_chunks::<2>()
                .0
                .iter()
                .map(|chunk| u16::from_le_bytes([chunk[0], chunk[1]]))
                .collect();

            if range <= 0.0 {
                return Ok(vec![128u8; u16_data.len()]);
            }

            // Why: u16 -> f64 is lossless; after clamp(0.0, 255.0) the value is in
            // [0.0, 255.0], so f64 -> u8 saturating truncation is safe.
            let normalized: Vec<u8> = u16_data
                .par_iter()
                .map(|&val| (((val as f64 - global.min) / range * 255.0).clamp(0.0, 255.0)) as u8)
                .collect();

            Ok(normalized)
        }
        _ => Ok(data.to_vec()),
    }
}

/// Apply gamma correction to tile
fn apply_gamma_to_tile(data: &[u8], pixel_type: PixelType, gamma: f64) -> Result<Vec<u8>, String> {
    match pixel_type {
        PixelType::U16 => {
            let u16_data: Vec<u16> = data
                .as_chunks::<2>()
                .0
                .iter()
                .map(|chunk| u16::from_le_bytes([chunk[0], chunk[1]]))
                .collect();

            // Why: u16 -> f64 is lossless; after clamp(0.0, 255.0) the value is in
            // [0.0, 255.0], so f64 -> u8 saturating truncation is safe.
            let corrected: Vec<u8> = u16_data
                .par_iter()
                .map(|&val| {
                    let normalized = (val as f64) / 65535.0;
                    let corrected = normalized.powf(1.0 / gamma);
                    (corrected * 255.0).clamp(0.0, 255.0) as u8
                })
                .collect();

            Ok(corrected)
        }
        _ => Ok(data.to_vec()),
    }
}

/// Merge tile results back into a single image
fn merge_tile_results(
    tile_results: Vec<(TileRegion, Vec<u8>)>,
    width: u32,
    height: u32,
    channels: u32,
    _pixel_type: PixelType,
) -> Result<ImageData, String> {
    let output_channels = channels.max(1);
    // Why: `width * height * output_channels` is u32 multiplication that can overflow
    // for very large images (e.g. 32K x 32K x 3 channels = 3 GB; fits in u32::MAX = 4
    // GB but a 4K-mosaic at 16K x 16K x 4 channels = 1 GB — still fits, but bigger
    // pano stitches exceed u32). Promote to u64 and surface overflow as Err so the
    // allocator does not receive a wrapped tiny value.
    let total_bytes_u64 = (width as u64)
        .checked_mul(height as u64)
        .and_then(|p| p.checked_mul(output_channels as u64))
        .ok_or_else(|| {
            format!(
                "Output buffer dimensions overflow u64: {}x{} channels={}",
                width, height, output_channels
            )
        })?;
    let total_bytes = usize::try_from(total_bytes_u64).map_err(|_| {
        format!(
            "Output buffer size {} does not fit in usize",
            total_bytes_u64
        )
    })?;
    let mut output = vec![0u8; total_bytes];

    for (tile, tile_data) in tile_results {
        // Why: tile.width and output_channels are u32; widening to usize via `as` is
        // value-preserving on every Tier 1 target. The multiplication can overflow on
        // 32-bit hosts for pathological tile dimensions, so check.
        let src_row_stride = (tile.width as usize)
            .checked_mul(output_channels as usize)
            .ok_or_else(|| "Tile src_row_stride overflow".to_string())?;
        let dst_row_stride = (width as usize)
            .checked_mul(output_channels as usize)
            .ok_or_else(|| "Output dst_row_stride overflow".to_string())?;

        for y in 0..tile.height {
            // Why: y < tile.height (u32), widening to usize is safe; multiplication
            // checked.
            let src_offset = (y as usize)
                .checked_mul(src_row_stride)
                .ok_or_else(|| "src_offset overflow".to_string())?;
            // Why: tile.y + y where both are u32; can wrap, but in normal use tile
            // coordinates are bounded by image height so this is safe in practice.
            // Use checked_add to surface bugs in callers passing oversized tiles.
            let dst_y_u32 = tile.y.checked_add(y).ok_or("Tile dst_y overflow u32")?;
            let dst_y = dst_y_u32 as usize;
            let dst_x = tile.x as usize;
            let dst_offset = dst_y
                .checked_mul(dst_row_stride)
                .and_then(|p| {
                    let col = dst_x.checked_mul(output_channels as usize)?;
                    p.checked_add(col)
                })
                .ok_or_else(|| "dst_offset overflow".to_string())?;

            let src_start = src_offset;
            let src_end = src_start
                .checked_add(src_row_stride)
                .ok_or_else(|| "src_end overflow".to_string())?;
            let dst_start = dst_offset;
            let dst_end = dst_start
                .checked_add(src_row_stride)
                .ok_or_else(|| "dst_end overflow".to_string())?;

            if src_end <= tile_data.len() && dst_end <= output.len() {
                output[dst_start..dst_end].copy_from_slice(&tile_data[src_start..src_end]);
            } else {
                return Err("Tile merge bounds exceeded".to_string());
            }
        }
    }

    Ok(ImageData {
        width,
        height,
        channels: output_channels,
        pixel_type: PixelType::U8,
        data: output,
    })
}

/// Process with progress reporting.
///
/// Synchronous CPU-bound — see [`process_tiled`] doc-comment. Callers on a
/// Tokio runtime must wrap this in `spawn_blocking`.
pub fn process_with_progress<F>(
    image: &ImageData,
    operation: ProcessOperation,
    tile_size: u32,
    progress_callback: F,
) -> Result<ImageData, String>
where
    F: Fn(f32) + Send + Sync + 'static,
{
    let callback = Arc::new(progress_callback);
    process_tiled(image, tile_size, operation, Some(callback))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_calculate_tile_grid() {
        let tiles = calculate_tile_grid(1000, 1000, 256);
        assert_eq!(tiles.len(), 16); // 4x4 grid

        let tiles = calculate_tile_grid(1920, 1080, 512);
        assert_eq!(tiles.len(), 12); // 4x3 grid
    }

    #[test]
    fn test_tile_region() {
        let tile = TileRegion::new(0, 0, 256, 256);
        assert_eq!(tile.pixel_count(), 65536);
    }

    #[test]
    fn test_process_tiled_normalize() {
        let image = ImageData::new(512, 512, 1, PixelType::U16);
        let result = process_tiled(&image, 256, ProcessOperation::Normalize, None);

        assert!(result.is_ok());
        let processed = result.unwrap();
        assert_eq!(processed.width, 512);
        assert_eq!(processed.height, 512);
    }

    /// with a horizontal gradient, tiled normalization must
    /// produce a monotonic output. The earlier per-tile min/max version would
    /// rescale every tile to span 0..255 horizontally, creating a step pattern
    /// at tile boundaries.
    #[test]
    fn test_process_tiled_normalize_uses_global_range() {
        let w: u32 = 64;
        let h: u32 = 64;
        // Why: test fixture with statically known small dimensions (64*64*2 = 8192).
        // No overflow possible; all `as` casts are widening within bounds.
        let mut data = Vec::with_capacity((w * h * 2) as usize);
        for _y in 0..h {
            for x in 0..w {
                let v = ((x * 65535) / (w - 1)) as u16;
                data.extend_from_slice(&v.to_le_bytes());
            }
        }
        let image = ImageData {
            width: w,
            height: h,
            channels: 1,
            pixel_type: PixelType::U16,
            data,
        };

        // 16x16 tiles -> 4x4 grid; with global rescale the row stays monotonic.
        let out = process_tiled(&image, 16, ProcessOperation::Normalize, None).unwrap();
        // Why: w = 64, out.channels = 1; stride = 64 well under usize::MAX on any host.
        let stride = (w * out.channels) as usize;
        let row = &out.data[0..stride];
        for i in 1..row.len() {
            assert!(
                row[i] >= row[i - 1],
                "tile boundary discontinuity at x={i}: {} -> {}",
                row[i - 1],
                row[i]
            );
        }
        assert_eq!(row[0], 0);
        assert_eq!(*row.last().unwrap(), 255);
    }
}
