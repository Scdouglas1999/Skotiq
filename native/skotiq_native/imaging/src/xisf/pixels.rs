//! Decoding an image's pixel block into the app's interleaved, little-endian
//! `ImageData`, without holding a second full copy where it can be avoided:
//! an uncompressed attached block streams from the file into place, and a
//! compressed one is unshuffled and de-planarized in the same pass that fills
//! the output.

use super::block::{decompress_block, try_alloc, BlockLocation};
use super::{ByteOrder, ColorSpace, PixelStorage, SampleFormat, XisfError, XisfImageHeader, XisfUnit};
use crate::{ImageData, PixelType};
use rayon::prelude::*;
use std::io::Read;

/// The most memory one decoded image may take. Far beyond any astronomical
/// frame; it keeps a small compressed block that claims an enormous image
/// from exhausting the machine.
const MAX_IMAGE_BYTES: u64 = 16 << 30;

/// How a stored sample becomes an output sample.
#[derive(Clone, Copy)]
enum Convert {
    Copy,
    /// UInt64 has no app pixel type; it becomes Float64 normalized over the
    /// representable range.
    U64ToF64 { low: f64, scale: f64 },
}

#[derive(Clone, Copy)]
struct Layout {
    in_size: usize,
    out_size: usize,
    pixels: usize,
    channels: usize,
    planar: bool,
    big_endian: bool,
    convert: Convert,
}

impl Layout {
    /// The stored index of output sample `o`.
    #[inline]
    fn stored_index(&self, o: usize) -> usize {
        if self.planar {
            (o % self.channels) * self.pixels + o / self.channels
        } else {
            o
        }
    }

    /// Whether stored bytes are already the output bytes, in order.
    fn is_direct(&self) -> bool {
        (!self.planar || self.channels == 1)
            && matches!(self.convert, Convert::Copy)
            && (!self.big_endian || self.in_size == 1)
    }

    #[inline]
    fn write(&self, sample: &mut [u8], dst: &mut [u8]) {
        if self.big_endian {
            sample.reverse();
        }
        match self.convert {
            Convert::Copy => dst.copy_from_slice(sample),
            Convert::U64ToF64 { low, scale } => {
                let v = u64::from_le_bytes(sample.try_into().expect("8 bytes")) as f64;
                dst.copy_from_slice(&((v - low) * scale).to_le_bytes());
            }
        }
    }
}

pub(crate) fn read_image(
    unit: &XisfUnit,
    image: &XisfImageHeader,
    what: &str,
) -> Result<ImageData, XisfError> {
    let pixel_type = match image.sample_format {
        SampleFormat::UInt8 => PixelType::U8,
        SampleFormat::UInt16 => PixelType::U16,
        SampleFormat::UInt32 => PixelType::U32,
        SampleFormat::Float32 => PixelType::F32,
        SampleFormat::UInt64 | SampleFormat::Float64 => PixelType::F64,
        SampleFormat::Complex32 | SampleFormat::Complex64 => {
            return Err(XisfError::Unsupported(format!(
                "its pixels are complex numbers ({}), which have no brightness to show or stack",
                image.sample_format.name()
            )))
        }
    };
    if image.dimensions.len() > 2 {
        return Err(XisfError::Unsupported(format!(
            "it is a {}-dimensional image; Skotiq works with flat images",
            image.dimensions.len()
        )));
    }
    let (width, height, channels) = (
        u32::try_from(image.width()),
        u32::try_from(image.height()),
        u32::try_from(image.channels),
    );
    let (Ok(width), Ok(height), Ok(channels)) = (width, height, channels) else {
        return Err(XisfError::Unsupported("its dimensions are too large".to_string()));
    };
    if image.color_space == ColorSpace::CieLab && channels < 3 {
        return Err(XisfError::Malformed(
            "a CIE L*a*b* image with fewer than three channels".to_string(),
        ));
    }
    let block = image
        .block
        .as_ref()
        .ok_or_else(|| XisfError::Malformed(format!("the {what} has no pixel data")))?;
    let stored_len = image.data_len().expect("checked when parsed");
    let pixels = (width as usize) * (height as usize);

    let convert = match image.sample_format {
        SampleFormat::UInt64 => {
            let (low, high) = image.representable_range().expect("integer range");
            Convert::U64ToF64 {
                low,
                scale: 1.0 / (high - low),
            }
        }
        _ => Convert::Copy,
    };
    let layout = Layout {
        in_size: image.sample_format.size(),
        out_size: pixel_type.byte_size(),
        pixels,
        channels: channels as usize,
        planar: image.pixel_storage == PixelStorage::Planar,
        big_endian: block.byte_order == ByteOrder::Big,
        convert,
    };
    let out_len = (pixels as u64) * (channels as u64) * (layout.out_size as u64);
    if out_len.max(stored_len) > MAX_IMAGE_BYTES {
        return Err(XisfError::Unsupported(format!(
            "its {what} would take {} GB of memory",
            out_len.max(stored_len) >> 30
        )));
    }
    let mut out = try_alloc(out_len, what)?;

    match (&block.location, block.compression) {
        (BlockLocation::Attachment { .. } | BlockLocation::External { .. }, None) => {
            let mut range = block.open(&unit.source)?.expect("file-backed block");
            if range.len != stored_len {
                return Err(XisfError::Corrupt(format!(
                    "the {what} block holds {} bytes, not the {stored_len} its geometry needs",
                    range.len
                )));
            }
            let mut hasher = block.checksum.as_ref().map(|c| c.algorithm.hasher());
            if layout.is_direct() {
                out.resize(out_len as usize, 0);
                range.reader.read_exact(&mut out)?;
                if let Some(h) = hasher.as_mut() {
                    h.update(&out);
                }
            } else {
                out.resize(out_len as usize, 0);
                stream_into(&layout, &mut range.reader, stored_len, &mut out, &mut hasher)?;
            }
            if let (Some(h), Some(checksum)) = (hasher, &block.checksum) {
                if h.finish() != checksum.digest {
                    return Err(XisfError::ChecksumMismatch {
                        what: what.to_string(),
                        algorithm: checksum.algorithm,
                    });
                }
            }
        }
        _ => {
            let stored = block.read_stored(&unit.source, what, stored_len.saturating_mul(2) + (1 << 20))?;
            let (data, shuffle) = match block.compression {
                Some(compression) => {
                    if compression.uncompressed_size != stored_len {
                        return Err(XisfError::Corrupt(format!(
                            "the {what} block uncompresses to {} bytes, not the {stored_len} its geometry needs",
                            compression.uncompressed_size
                        )));
                    }
                    let data =
                        decompress_block(&compression, block.subblocks.as_deref(), &stored, what)?;
                    (data, compression.shuffle_item)
                }
                None => {
                    if stored.len() as u64 != stored_len {
                        return Err(XisfError::Corrupt(format!(
                            "the {what} block holds {} bytes, not the {stored_len} its geometry needs",
                            stored.len()
                        )));
                    }
                    (stored, None)
                }
            };
            out.resize(out_len as usize, 0);
            gather(&layout, &data, shuffle, &mut out);
        }
    }

    let mut result = ImageData {
        width,
        height,
        channels,
        pixel_type,
        data: out,
    };
    if image.color_space == ColorSpace::CieLab {
        lab_to_rgb(image, &mut result);
    }
    Ok(result)
}

/// Fill `out` from the in-memory stored block, in parallel. `shuffle` is the
/// item size of a byte-shuffled block.
fn gather(layout: &Layout, stored: &[u8], shuffle: Option<usize>, out: &mut [u8]) {
    if let Some(item) = shuffle.filter(|&item| item != layout.in_size) {
        // A shuffle item that is not the sample size: undo it separately.
        let plain = super::codec::unshuffle(stored, item);
        return gather(layout, &plain, None, out);
    }
    if layout.is_direct() {
        match shuffle {
            None => out.copy_from_slice(stored),
            Some(item) => unshuffle_into(stored, item, out),
        }
        return;
    }
    let items = stored.len() / layout.in_size;
    const CHUNK_SAMPLES: usize = 1 << 16;
    out.par_chunks_mut(layout.out_size * CHUNK_SAMPLES)
        .enumerate()
        .for_each(|(chunk, dst)| {
            let mut sample = [0u8; 16];
            let first = chunk * CHUNK_SAMPLES;
            for (k, dst) in dst.chunks_exact_mut(layout.out_size).enumerate() {
                let s = layout.stored_index(first + k);
                let sample = &mut sample[..layout.in_size];
                match shuffle {
                    Some(_) => {
                        for (j, b) in sample.iter_mut().enumerate() {
                            *b = stored[j * items + s];
                        }
                    }
                    None => sample
                        .copy_from_slice(&stored[s * layout.in_size..(s + 1) * layout.in_size]),
                }
                layout.write(sample, dst);
            }
        });
}

/// Undo byte shuffling straight into `out`, in parallel: each worker fills a
/// run of whole items, one byte plane at a time.
fn unshuffle_into(stored: &[u8], item: usize, out: &mut [u8]) {
    const CHUNK_ITEMS: usize = 1 << 16;
    let items = stored.len() / item;
    out.par_chunks_mut(item * CHUNK_ITEMS)
        .enumerate()
        .for_each(|(chunk, dst)| {
            let first = chunk * CHUNK_ITEMS;
            let count = dst.len() / item;
            for byte in 0..item {
                let plane = &stored[byte * items + first..byte * items + first + count];
                for (k, &b) in plane.iter().enumerate() {
                    dst[k * item + byte] = b;
                }
            }
        });
}

/// Read an uncompressed block sequentially, placing each stored sample.
fn stream_into(
    layout: &Layout,
    reader: &mut impl Read,
    stored_len: u64,
    out: &mut [u8],
    hasher: &mut Option<super::codec::BlockHasher>,
) -> Result<(), XisfError> {
    const CHUNK: usize = 8 << 20;
    let chunk_len = CHUNK - CHUNK % layout.in_size;
    let mut buffer = vec![0u8; chunk_len.min(stored_len as usize)];
    let mut remaining = stored_len as usize;
    let mut s = 0usize;
    let mut sample = [0u8; 16];
    while remaining > 0 {
        let n = remaining.min(buffer.len());
        let chunk = &mut buffer[..n];
        reader.read_exact(chunk)?;
        if let Some(h) = hasher.as_mut() {
            h.update(chunk);
        }
        for stored in chunk.chunks_exact(layout.in_size) {
            let o = if layout.planar {
                (s % layout.pixels) * layout.channels + s / layout.pixels
            } else {
                s
            };
            let sample = &mut sample[..layout.in_size];
            sample.copy_from_slice(stored);
            layout.write(sample, &mut out[o * layout.out_size..(o + 1) * layout.out_size]);
            s += 1;
        }
        remaining -= n;
    }
    Ok(())
}

/// Replace the first three channels' L*a*b* values with RGB in the image's
/// working space, keeping the sample format and representable range.
fn lab_to_rgb(image: &XisfImageHeader, data: &mut ImageData) {
    let space = image
        .rgb_working_space
        .clone()
        .unwrap_or_else(super::RgbWorkingSpace::srgb);
    let (low, high) = match image.sample_format {
        SampleFormat::UInt64 => (0.0, 1.0),
        _ => image.representable_range().unwrap_or((0.0, 1.0)),
    };
    let span = high - low;
    let pixel_type = data.pixel_type;
    let integer = matches!(pixel_type, PixelType::U8 | PixelType::U16 | PixelType::U32);
    let size = pixel_type.byte_size();
    let stride = size * data.channels as usize;
    data.data.par_chunks_exact_mut(stride).for_each(|pixel| {
        let mut lab = [0.0; 3];
        for (c, v) in lab.iter_mut().enumerate() {
            *v = (crate::samples::sample_from_le(&pixel[c * size..(c + 1) * size], pixel_type) - low) / span;
        }
        let rgb = space.lab_to_rgb(lab);
        for (c, v) in rgb.iter().enumerate() {
            let value = low + v * span;
            let value = if integer { value.round() } else { value };
            crate::samples::sample_to_le(&mut pixel[c * size..(c + 1) * size], pixel_type, value);
        }
    });
}
