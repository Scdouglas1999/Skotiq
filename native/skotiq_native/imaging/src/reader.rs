//! Memory-mapped image reader for large files
//!
//! This module provides efficient reading of large image files without
//! loading the entire file into memory. Useful for:
//! - Preview generation from 60MP+ images
//! - Region-of-interest extraction
//! - Streaming operations
//!
//! # `unwrap_or` policy
//!
//! Two FITS-standard fallbacks appear in this reader:
//!
//! * `BZERO.unwrap_or(0.0)`, `BSCALE.unwrap_or(1.0)` — these are the
//!   FITS 4.0 spec defaults for the linear pixel-value transform when the
//!   keywords are absent: `physical_value = BZERO + BSCALE * stored_value`
//!   degenerates to identity at `(0.0, 1.0)`.
//! * `extension().unwrap_or("")` — no extension on the file path; empty
//!   string flows through to the format-detection arm that fails with a
//!   real error if no magic-bytes match.

use crate::fits_layout::{detect_layout, layout_from_header, PlaneLayout};
use crate::{FitsError, FitsHeader, ImageData, PixelType};
use image::GenericImageView;
use memmap2::Mmap;
use std::fs::File;
use std::path::Path;

/// Memory-mapped image reader for large FITS files
pub struct MappedFitsReader {
    mmap: Mmap,
    width: u32,
    height: u32,
    channels: u32,
    pixel_type: PixelType,
    data_offset: usize,
    header: FitsHeader,
    layout: PlaneLayout,
}

impl MappedFitsReader {
    /// Open a FITS file with memory mapping
    pub fn open(path: &Path) -> Result<Self, FitsError> {
        let file = File::open(path)?;
        // SAFETY: `Mmap::map` is `unsafe` because callers must ensure the mapped file is
        // not concurrently modified by another process (which could violate the
        // immutable-byte-slice invariant the `Mmap` exposes). FITS captures we open here
        // are produced and finalized by the capture path before being read, and this
        // reader takes a `&Path` for read-only access — no writer holds the file. The
        // returned `Mmap` is owned by `Self` and stays alive for the reader's lifetime.
        let mmap = unsafe { Mmap::map(&file)? };

        // Parse header to get dimensions
        let mut cursor = std::io::Cursor::new(&mmap[..]);
        let header = crate::fits::read_header(&mut cursor)?;

        let (width, height, channels, pixel_type) = crate::fits::geometry_from_header(&header)?;

        // `read_header` already consumes the full FITS header and skips the
        // required padding, so the cursor now points at the exact data start.
        let data_offset = usize::try_from(cursor.position()).map_err(|_| {
            FitsError::InvalidFormat("FITS data offset exceeds platform limits".to_string())
        })?;

        let samples = (width as usize) * (height as usize) * (channels as usize);
        let data_end = samples
            .checked_mul(pixel_type.byte_size())
            .and_then(|bytes| bytes.checked_add(data_offset));
        if data_end.is_none_or(|end| end > mmap.len()) {
            return Err(FitsError::InvalidFormat(
                "FITS data is shorter than its header declares".to_string(),
            ));
        }
        let layout = if channels > 1 {
            layout_from_header(&header).unwrap_or_else(|| {
                let bzero = header.get_float("BZERO").unwrap_or(0.0);
                let bscale = header.get_float("BSCALE").unwrap_or(1.0);
                detect_layout(width as usize, height as usize, channels as usize, |k| {
                    be_sample(&mmap[data_offset..], pixel_type, bzero, bscale, k)
                })
            })
        } else {
            PlaneLayout::Interleaved
        };

        tracing::info!(
            "Opened memory-mapped FITS: {}x{}x{}, type {:?}, data offset: {}",
            width,
            height,
            channels,
            pixel_type,
            data_offset
        );

        Ok(Self {
            mmap,
            width,
            height,
            channels,
            pixel_type,
            data_offset,
            header,
            layout,
        })
    }

    /// Append the raw (big-endian) bytes of pixel `(x, y)`, channels in
    /// interleaved order, whichever way the file orders its planes.
    fn push_pixel(&self, x: usize, y: usize, out: &mut Vec<u8>) {
        let bytes = self.pixel_type.byte_size();
        let channels = self.channels as usize;
        let width = self.width as usize;
        let plane = width * self.height as usize;
        match self.layout {
            PlaneLayout::Interleaved => {
                let at = self.data_offset + (y * width + x) * channels * bytes;
                out.extend_from_slice(&self.mmap[at..at + channels * bytes]);
            }
            PlaneLayout::Planar => {
                for c in 0..channels {
                    let at = self.data_offset + (c * plane + y * width + x) * bytes;
                    out.extend_from_slice(&self.mmap[at..at + bytes]);
                }
            }
        }
    }

    /// Get image dimensions
    pub fn dimensions(&self) -> (u32, u32, u32) {
        (self.width, self.height, self.channels)
    }

    /// Get pixel type
    pub fn pixel_type(&self) -> PixelType {
        self.pixel_type
    }

    /// Get header
    pub fn header(&self) -> &FitsHeader {
        &self.header
    }

    /// Read a specific region without loading the full image
    ///
    /// This is much more memory-efficient than loading the entire image
    /// when you only need a small region (e.g., for preview or ROI analysis)
    pub fn read_region(
        &self,
        x: u32,
        y: u32,
        width: u32,
        height: u32,
    ) -> Result<ImageData, FitsError> {
        // Validate bounds
        if x + width > self.width || y + height > self.height {
            return Err(FitsError::InvalidFormat(format!(
                "Region {}x{} at ({},{}) exceeds image bounds {}x{}",
                width, height, x, y, self.width, self.height
            )));
        }

        let bytes_per_pixel = self.pixel_type.byte_size();
        let channels = self.channels as usize;
        let stride = (self.width as usize) * bytes_per_pixel * channels;

        let region_size = (width as usize) * (height as usize) * bytes_per_pixel * channels;
        let mut region_data = Vec::with_capacity(region_size);

        // Read row by row from memory-mapped file. `open` checked that the
        // whole data block is mapped.
        for row in y..(y + height) {
            if self.layout == PlaneLayout::Planar {
                for col in x..(x + width) {
                    self.push_pixel(col as usize, row as usize, &mut region_data);
                }
                continue;
            }
            let row_offset = self.data_offset + (row as usize) * stride;
            let col_offset = (x as usize) * bytes_per_pixel * channels;
            let offset = row_offset + col_offset;
            let length = (width as usize) * bytes_per_pixel * channels;
            region_data.extend_from_slice(&self.mmap[offset..offset + length]);
        }

        // Convert from FITS big-endian to system little-endian
        let converted_data = self.convert_endianness(&region_data)?;

        Ok(ImageData {
            width,
            height,
            channels: self.channels,
            pixel_type: self.pixel_type,
            data: converted_data,
        })
    }

    /// Convert from FITS big-endian to little-endian
    fn convert_endianness(&self, data: &[u8]) -> Result<Vec<u8>, FitsError> {
        let bzero = self.header.get_float("BZERO").unwrap_or(0.0);
        let bscale = self.header.get_float("BSCALE").unwrap_or(1.0);

        match self.pixel_type {
            PixelType::U8 => {
                // U8 doesn't need endian conversion
                Ok(data.to_vec())
            }
            PixelType::U16 => {
                // Convert i16 big-endian to u16 little-endian
                let converted: Vec<u8> = data
                    .as_chunks::<2>()
                    .0
                    .iter()
                    .flat_map(|chunk| {
                        let val = i16::from_be_bytes([chunk[0], chunk[1]]);
                        let adjusted = if bzero == 32768.0 {
                            (val as i32 + 32768).clamp(0, 65535) as u16
                        } else {
                            ((val as f64 * bscale + bzero).clamp(0.0, 65535.0)) as u16
                        };
                        adjusted.to_le_bytes()
                    })
                    .collect();
                Ok(converted)
            }
            PixelType::F32 => {
                // Convert f32 big-endian to little-endian
                let converted: Vec<u8> = data
                    .as_chunks::<4>()
                    .0
                    .iter()
                    .flat_map(|chunk| {
                        let val = f32::from_be_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]);
                        let adjusted = val * bscale as f32 + bzero as f32;
                        adjusted.to_le_bytes()
                    })
                    .collect();
                Ok(converted)
            }
            _ => Ok(data.to_vec()),
        }
    }

    /// Read downsampled version of the full image
    ///
    /// Reads every Nth pixel to create a smaller version, useful for thumbnails.
    /// This is much faster than reading the full image and then downsampling.
    pub fn read_downsampled(&self, downsample_factor: u32) -> Result<ImageData, FitsError> {
        if downsample_factor == 0 {
            return Err(FitsError::InvalidFormat(
                "Downsample factor must be > 0".to_string(),
            ));
        }

        let out_width = self.width.div_ceil(downsample_factor);
        let out_height = self.height.div_ceil(downsample_factor);

        let bytes_per_pixel = self.pixel_type.byte_size();
        let channels = self.channels as usize;

        let output_size = (out_width as usize) * (out_height as usize) * bytes_per_pixel * channels;
        let mut output_data = Vec::with_capacity(output_size);

        // Sample every Nth row and column. `open` checked that the whole data
        // block is mapped.
        for out_y in 0..out_height {
            let src_y = (out_y * downsample_factor) as usize;
            for out_x in 0..out_width {
                let src_x = (out_x * downsample_factor) as usize;
                self.push_pixel(src_x, src_y, &mut output_data);
            }
        }

        if output_data.len() != output_size {
            return Err(FitsError::InvalidFormat(format!(
                "Downsampled FITS read produced {} bytes, expected {}",
                output_data.len(),
                output_size
            )));
        }

        // Convert endianness
        let converted_data = self.convert_endianness(&output_data)?;

        tracing::info!(
            "Downsampled {}x{} to {}x{} (factor {})",
            self.width,
            self.height,
            out_width,
            out_height,
            downsample_factor
        );

        Ok(ImageData {
            width: out_width,
            height: out_height,
            channels: self.channels,
            pixel_type: self.pixel_type,
            data: converted_data,
        })
    }

    /// Get total file size
    pub fn file_size(&self) -> usize {
        self.mmap.len()
    }
}

/// The physical value of the `k`-th big-endian sample of FITS data.
fn be_sample(data: &[u8], pixel_type: PixelType, bzero: f64, bscale: f64, k: usize) -> f64 {
    let size = pixel_type.byte_size();
    let Some(b) = data.get(k * size..(k + 1) * size) else {
        return f64::NAN;
    };
    let stored = match pixel_type {
        PixelType::U8 => b[0] as f64,
        PixelType::U16 => i16::from_be_bytes([b[0], b[1]]) as f64,
        PixelType::U32 => i32::from_be_bytes([b[0], b[1], b[2], b[3]]) as f64,
        PixelType::F32 => f32::from_be_bytes([b[0], b[1], b[2], b[3]]) as f64,
        PixelType::F64 => f64::from_be_bytes([b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]]),
    };
    stored * bscale + bzero
}

/// Generate a preview thumbnail without loading the full image
///
/// This function intelligently selects the best method:
/// - For RAW files: extract embedded JPEG preview
/// - For FITS: use memory-mapped downsampling
/// - For TIFF/PNG: use image library with subsampling
pub fn generate_thumbnail(path: &Path, max_dimension: u32) -> Result<ImageData, String> {
    let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("");

    match ext.to_lowercase().as_str() {
        // RAW formats - use LibRaw embedded preview
        "cr2" | "cr3" | "nef" | "arw" | "raf" | "pef" | "orf" | "rw2" => {
            tracing::info!("Extracting RAW thumbnail from {}", path.display());
            crate::raw::extract_thumbnail(path).map_err(|e| e.to_string())
        }

        // FITS - use memory-mapped downsampling
        "fits" | "fit" | "fts" => {
            tracing::info!("Generating FITS thumbnail from {}", path.display());
            let reader = MappedFitsReader::open(path).map_err(|e| e.to_string())?;

            let (width, height, _) = reader.dimensions();
            let max_dim = width.max(height);
            let downsample = max_dim.div_ceil(max_dimension);

            if downsample <= 1 {
                // Image is already small, read full
                reader
                    .read_region(0, 0, width, height)
                    .map_err(|e| e.to_string())
            } else {
                reader
                    .read_downsampled(downsample)
                    .map_err(|e| e.to_string())
            }
        }

        // Other formats - use image crate
        _ => {
            tracing::info!("Loading thumbnail with image crate from {}", path.display());
            let img = image::open(path).map_err(|e| format!("Failed to open image: {}", e))?;

            let (width, height) = img.dimensions();
            let scale = (width.max(height) as f32) / (max_dimension as f32);

            if scale <= 1.0 {
                // Already small enough
                let rgba = img.to_rgba8();
                Ok(ImageData {
                    width,
                    height,
                    channels: 4,
                    pixel_type: PixelType::U8,
                    data: rgba.into_raw(),
                })
            } else {
                let new_width = (width as f32 / scale) as u32;
                let new_height = (height as f32 / scale) as u32;

                let thumbnail = img.thumbnail(new_width, new_height);
                let rgba = thumbnail.to_rgba8();

                Ok(ImageData {
                    width: new_width,
                    height: new_height,
                    channels: 4,
                    pixel_type: PixelType::U8,
                    data: rgba.into_raw(),
                })
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::MappedFitsReader;
    use crate::{write_fits, FitsError, FitsHeader, ImageData, PixelType};
    use std::fs;
    use std::path::PathBuf;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_path(name: &str) -> PathBuf {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock before epoch")
            .as_nanos();
        std::env::temp_dir().join(format!("skotiq_reader_{name}_{unique}.fits"))
    }

    #[test]
    fn test_thumbnail_max_dimension() {
        // Test would require actual image files
        // This path exists for integration tests
    }

    #[test]
    fn mapped_reader_open_rejects_header_without_end() {
        let path = temp_path("missing_end");
        let invalid_header = vec![b' '; 2880];
        fs::write(&path, invalid_header).expect("failed to write malformed FITS");

        let result = MappedFitsReader::open(&path);
        let _ = fs::remove_file(&path);

        assert!(result.is_err(), "missing END keyword should be rejected");
    }

    #[test]
    fn mapped_reader_reads_valid_fits_written_by_writer() {
        let path = temp_path("valid");
        let image = ImageData {
            width: 2,
            height: 2,
            channels: 1,
            pixel_type: PixelType::U8,
            data: vec![1, 2, 3, 4],
        };
        let header = FitsHeader::new();
        write_fits(&path, &image, &header).expect("failed to write FITS");

        let reader = MappedFitsReader::open(&path).expect("reader should open valid FITS");
        let region = reader
            .read_region(0, 0, 2, 2)
            .expect("reader should return the stored pixels");
        let _ = fs::remove_file(&path);

        assert_eq!(region.data, image.data);
    }

    /// Write a single-record FITS header from raw card text, with no data.
    fn write_header_only_fits(path: &PathBuf, cards: &[&str]) {
        let mut bytes = vec![b' '; 2880];
        for (idx, card) in cards.iter().enumerate() {
            let offset = idx * 80;
            let mut card_bytes = [b' '; 80];
            let raw = card.as_bytes();
            card_bytes[..raw.len()].copy_from_slice(raw);
            bytes[offset..offset + 80].copy_from_slice(&card_bytes);
        }
        fs::write(path, bytes).expect("failed to write FITS header");
    }

    #[test]
    fn mapped_reader_requires_naxis2_for_2d_images() {
        let path = temp_path("missing_naxis2");
        write_header_only_fits(
            &path,
            &[
                "SIMPLE  =                    T",
                "BITPIX  =                    8",
                "NAXIS   =                    2",
                "NAXIS1  =                    2",
                "END",
            ],
        );

        let result = MappedFitsReader::open(&path);
        let _ = fs::remove_file(&path);

        assert!(matches!(result, Err(FitsError::MissingKeyword(keyword)) if keyword == "NAXIS2"));
    }

    /// The mapped reader and `read_fits` both derive geometry from
    /// `geometry_from_header`, so a 4-D cube is rejected on either path rather
    /// than read as a 3-D image with every plane past NAXIS3 discarded.
    #[test]
    fn mapped_reader_rejects_a_4d_cube_like_read_fits_does() {
        let path = temp_path("naxis4");
        write_header_only_fits(
            &path,
            &[
                "SIMPLE  =                    T",
                "BITPIX  =                   16",
                "NAXIS   =                    4",
                "NAXIS1  =                    1",
                "NAXIS2  =                    1",
                "NAXIS3  =                    1",
                "NAXIS4  =                    1",
                "END",
            ],
        );

        let result = MappedFitsReader::open(&path);
        let _ = fs::remove_file(&path);

        assert!(
            matches!(result, Err(FitsError::Unsupported4DCube { naxis: 4 })),
            "expected Unsupported4DCube, got {:?}",
            result.map(|_| "Ok")
        );
    }

    /// A NAXIS=3 header with no NAXIS3 card is malformed; `read_fits` says so
    /// and the mapped reader must not quietly assume one channel.
    #[test]
    fn mapped_reader_requires_naxis3_for_3d_images() {
        let path = temp_path("missing_naxis3");
        write_header_only_fits(
            &path,
            &[
                "SIMPLE  =                    T",
                "BITPIX  =                    8",
                "NAXIS   =                    3",
                "NAXIS1  =                    2",
                "NAXIS2  =                    2",
                "END",
            ],
        );

        let result = MappedFitsReader::open(&path);
        let _ = fs::remove_file(&path);

        assert!(matches!(result, Err(FitsError::MissingKeyword(keyword)) if keyword == "NAXIS3"));
    }
}
