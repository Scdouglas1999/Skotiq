//! Raster files: TIFF, PNG and JPEG, written for other programs to show or
//! edit. A raster carries no FITS header and is never read back as a frame.
//!
//! TIFF and PNG keep 8-bit images at 8 bits and write any other sample type
//! as linear 16-bit levels through the image's sample range, so a calibrated
//! float frame stays linear data. JPEG holds 8 bits only: an 8-bit image is
//! written as it is and any other one auto-stretched for display. One plane
//! is gray, three are RGB and four RGBA; JPEG has no alpha, so it composites
//! RGBA over black.

use crate::{ImageData, PixelType, SampleRange};
use image::{ColorType, ImageEncoder};
use std::io::BufWriter;
use std::path::Path;

/// The raster formats Skotiq writes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RasterFormat {
    Tiff,
    Png,
    /// `quality` from 1 to 100.
    Jpeg {
        quality: u8,
    },
}

/// JPEG quality when the caller states none.
pub const DEFAULT_JPEG_QUALITY: u8 = 92;

impl RasterFormat {
    /// The format a file extension names (`tif`, `tiff`, `png`, `jpg`,
    /// `jpeg`, any case), JPEG at [`DEFAULT_JPEG_QUALITY`].
    pub fn from_extension(extension: &str) -> Option<Self> {
        match extension.to_ascii_lowercase().as_str() {
            "tif" | "tiff" => Some(Self::Tiff),
            "png" => Some(Self::Png),
            "jpg" | "jpeg" => Some(Self::Jpeg {
                quality: DEFAULT_JPEG_QUALITY,
            }),
            _ => None,
        }
    }

    /// The format a path's extension names.
    pub fn from_path(path: &Path) -> Option<Self> {
        Self::from_extension(path.extension()?.to_str()?)
    }
}

#[derive(Debug, thiserror::Error)]
pub enum RasterError {
    #[error("a {0}-channel image has no raster encoding; rasters hold 1 (gray), 3 (RGB) or 4 (RGBA) channels")]
    Channels(u32),
    #[error("the image holds {held} bytes, not the {needed} its size needs")]
    Size { held: usize, needed: usize },
    #[error("{0}")]
    Io(#[from] std::io::Error),
    #[error("{0}")]
    Encode(#[from] image::ImageError),
}

/// Write `image` to `path` as `format`.
pub fn write_raster(
    path: &Path,
    image: &ImageData,
    format: RasterFormat,
) -> Result<(), RasterError> {
    let channels = image.channels;
    if !matches!(channels, 1 | 3 | 4) {
        return Err(RasterError::Channels(channels));
    }
    let needed = image.pixel_count() * image.bytes_per_pixel();
    if image.data.len() != needed {
        return Err(RasterError::Size {
            held: image.data.len(),
            needed,
        });
    }
    let (w, h) = (image.width, image.height);
    let file = BufWriter::new(std::fs::File::create(path)?);
    match format {
        RasterFormat::Tiff | RasterFormat::Png => {
            let (bytes, color) = if image.pixel_type == PixelType::U8 {
                let color = [ColorType::L8, ColorType::Rgb8, ColorType::Rgba8];
                (std::borrow::Cow::Borrowed(&image.data), color)
            } else {
                // The image crate takes 16-bit samples in native order.
                let levels: Vec<u8> = image
                    .converted_to(PixelType::U16, SampleRange::ADU)
                    .data
                    .as_chunks::<2>()
                    .0
                    .iter()
                    .flat_map(|le| u16::from_le_bytes(*le).to_ne_bytes())
                    .collect();
                let color = [ColorType::L16, ColorType::Rgb16, ColorType::Rgba16];
                (std::borrow::Cow::Owned(levels), color)
            };
            let color = color[match channels {
                1 => 0,
                3 => 1,
                _ => 2,
            }];
            if format == RasterFormat::Tiff {
                image::codecs::tiff::TiffEncoder::new(file).write_image(&bytes, w, h, color)?;
            } else {
                image::codecs::png::PngEncoder::new(file).write_image(&bytes, w, h, color)?;
            }
        }
        RasterFormat::Jpeg { quality } => {
            let display = if image.pixel_type == PixelType::U8 {
                std::borrow::Cow::Borrowed(&image.data)
            } else {
                std::borrow::Cow::Owned(image.to_display_u8())
            };
            let (bytes, color) = match channels {
                1 => (display, ColorType::L8),
                3 => (display, ColorType::Rgb8),
                _ => (
                    std::borrow::Cow::Owned(
                        display
                            .as_chunks::<4>()
                            .0
                            .iter()
                            .flat_map(|[r, g, b, a]| {
                                let over_black =
                                    |c: &u8| (u32::from(*c) * u32::from(*a) / 255) as u8;
                                [over_black(r), over_black(g), over_black(b)]
                            })
                            .collect(),
                    ),
                    ColorType::Rgb8,
                ),
            };
            image::codecs::jpeg::JpegEncoder::new_with_quality(file, quality.clamp(1, 100))
                .write_image(&bytes, w, h, color)?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn written(image: &ImageData, format: RasterFormat, name: &str) -> image::DynamicImage {
        let dir = std::env::temp_dir().join(format!("raster-{}-{name}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join(name);
        write_raster(&path, image, format).unwrap();
        let read = image::open(&path).unwrap();
        std::fs::remove_dir_all(&dir).unwrap();
        read
    }

    #[test]
    fn a_16_bit_frame_is_written_as_its_own_levels() {
        let frame = ImageData::from_u16(2, 1, 1, &[1000, 65535]);
        for (format, name) in [(RasterFormat::Tiff, "a.tif"), (RasterFormat::Png, "a.png")] {
            let read = written(&frame, format, name);
            assert_eq!(read.to_luma16().as_raw(), &[1000, 65535], "{name}");
        }
    }

    /// A calibrated light is float on the 16-bit ADU scale; its raster is the
    /// same linear levels, not a display stretch.
    #[test]
    fn a_float_frame_stays_linear_through_its_range() {
        let adu = ImageData::from_f32(3, 1, 1, &[0.0, 1000.4, 70000.0]);
        let read = written(&adu, RasterFormat::Tiff, "f.tif");
        assert_eq!(read.to_luma16().as_raw(), &[0, 1000, 65535]);

        let unit = ImageData::from_f32(2, 1, 1, &[0.25, 1.0]).with_range(SampleRange::UNIT);
        let read = written(&unit, RasterFormat::Png, "u.png");
        assert_eq!(read.to_luma16().as_raw(), &[16384, 65535]);
    }

    #[test]
    fn rgba_keeps_its_alpha_and_a_jpeg_composites_it_over_black() {
        let mut rgba = ImageData::new(1, 1, 4, PixelType::U8);
        rgba.data = vec![255, 255, 255, 128];
        let png = written(&rgba, RasterFormat::Png, "c.png");
        assert_eq!(png.to_rgba8().as_raw(), &[255, 255, 255, 128]);
        let jpeg = written(&rgba, RasterFormat::Jpeg { quality: 95 }, "c.jpg");
        for channel in jpeg.to_rgb8().as_raw() {
            assert!((i32::from(*channel) - 128).abs() <= 8, "{channel}");
        }
    }

    #[test]
    fn a_buffer_that_does_not_fit_its_size_is_refused() {
        let mut short = ImageData::new(2, 2, 4, PixelType::U8);
        short.data.truncate(12);
        let path = std::env::temp_dir().join(format!("raster-short-{}.png", std::process::id()));
        assert!(matches!(
            write_raster(&path, &short, RasterFormat::Png),
            Err(RasterError::Size {
                held: 12,
                needed: 16
            })
        ));
        assert!(!path.exists());
        let two = ImageData::new(1, 1, 2, PixelType::U8);
        assert!(matches!(
            write_raster(&path, &two, RasterFormat::Png),
            Err(RasterError::Channels(2))
        ));
    }

    #[test]
    fn extensions_name_their_format() {
        assert_eq!(
            RasterFormat::from_path(Path::new("a.TIF")),
            Some(RasterFormat::Tiff)
        );
        assert_eq!(
            RasterFormat::from_path(Path::new("a.jpeg")),
            Some(RasterFormat::Jpeg {
                quality: DEFAULT_JPEG_QUALITY
            })
        );
        assert_eq!(RasterFormat::from_path(Path::new("a.fits")), None);
    }
}
