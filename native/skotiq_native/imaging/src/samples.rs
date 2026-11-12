//! Typed access to an [`ImageData`] buffer.
//!
//! `ImageData` stores little-endian samples of one of five types, channel
//! interleaved. Everything that needs numbers rather than bytes reads them
//! through here, so a pixel type is decoded in one place and a caller that
//! only supports some types says so with [`PixelType`] rather than by which
//! decoder it happened to copy.
//!
//! The numbers the `ImageData` methods return are on the app's working scale,
//! 16-bit ADU, whatever the image's [`SampleRange`](crate::SampleRange): a
//! PixInsight float frame in `[0, 1]` and the 16-bit frame it was made from
//! read the same. [`sample_from_le`] and [`sample_to_le`] are the stored
//! values, for the codecs.

use crate::{ImageData, PixelType};
use rayon::prelude::*;

/// One sample from its little-endian bytes. `bytes` holds at least
/// [`PixelType::byte_size`] bytes.
#[inline]
pub fn sample_from_le(bytes: &[u8], pixel_type: PixelType) -> f64 {
    match pixel_type {
        PixelType::U8 => f64::from(bytes[0]),
        PixelType::U16 => f64::from(u16::from_le_bytes([bytes[0], bytes[1]])),
        PixelType::U32 => f64::from(u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]])),
        PixelType::F32 => f64::from(f32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]])),
        PixelType::F64 => f64::from_le_bytes([
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        ]),
    }
}

/// Write one sample as little-endian bytes. Integer types saturate at their
/// range and truncate toward zero (NaN becomes 0); a caller that wants
/// rounding rounds first.
#[inline]
pub fn sample_to_le(bytes: &mut [u8], pixel_type: PixelType, value: f64) {
    match pixel_type {
        PixelType::U8 => bytes[0] = value.clamp(0.0, f64::from(u8::MAX)) as u8,
        PixelType::U16 => {
            let v = value.clamp(0.0, f64::from(u16::MAX)) as u16;
            bytes[..2].copy_from_slice(&v.to_le_bytes());
        }
        PixelType::U32 => {
            let v = value.clamp(0.0, f64::from(u32::MAX)) as u32;
            bytes[..4].copy_from_slice(&v.to_le_bytes());
        }
        PixelType::F32 => bytes[..4].copy_from_slice(&(value as f32).to_le_bytes()),
        PixelType::F64 => bytes[..8].copy_from_slice(&value.to_le_bytes()),
    }
}

impl ImageData {
    /// Whether the buffer holds every sample the dimensions call for.
    pub fn holds_all_samples(&self) -> bool {
        self.data.len() >= self.pixel_count() * self.bytes_per_pixel()
    }

    /// `(low, gain)` taking a stored sample to 16-bit ADU as
    /// `(sample - low) * gain`; `None` when stored samples are ADU already.
    #[inline]
    pub(crate) fn adu_mapping(&self) -> Option<(f64, f64)> {
        (!self.range.is_adu()).then(|| (self.range.low, self.range.adu_per_unit()))
    }

    /// Every sample as `f64` in 16-bit ADU, in buffer (channel-interleaved)
    /// order. A buffer shorter than the dimensions call for yields the samples
    /// it does hold.
    pub fn samples_f64(&self) -> Vec<f64> {
        let mut samples = self.stored_f64();
        if let Some((low, gain)) = self.adu_mapping() {
            samples.par_iter_mut().for_each(|v| *v = (*v - low) * gain);
        }
        samples
    }

    /// Every sample as the image stores it, not taken to ADU: for data that
    /// is not brightness (a coverage or weight map holds counts) and for a
    /// stage whose parameters are in the image's own units.
    pub fn stored_f64(&self) -> Vec<f64> {
        match self.pixel_type {
            PixelType::U8 => self.data.par_iter().map(|&v| f64::from(v)).collect(),
            PixelType::U16 => self
                .data
                .par_chunks_exact(2)
                .map(|c| f64::from(u16::from_le_bytes([c[0], c[1]])))
                .collect(),
            PixelType::U32 => self
                .data
                .par_chunks_exact(4)
                .map(|c| f64::from(u32::from_le_bytes([c[0], c[1], c[2], c[3]])))
                .collect(),
            PixelType::F32 => self
                .data
                .par_chunks_exact(4)
                .map(|c| f64::from(f32::from_le_bytes([c[0], c[1], c[2], c[3]])))
                .collect(),
            PixelType::F64 => self
                .data
                .par_chunks_exact(8)
                .map(|c| sample_from_le(c, PixelType::F64))
                .collect(),
        }
    }

    /// Every sample as `f32` in 16-bit ADU, in buffer order. `U32` and `F64`
    /// lose precision.
    pub fn samples_f32(&self) -> Vec<f32> {
        let Some((low, gain)) = self.adu_mapping() else {
            return self.stored_f32();
        };
        if matches!(self.pixel_type, PixelType::U32 | PixelType::F64) {
            let size = self.bytes_per_pixel();
            let pixel_type = self.pixel_type;
            return self
                .data
                .par_chunks_exact(size)
                .map(|c| ((sample_from_le(c, pixel_type) - low) * gain) as f32)
                .collect();
        }
        let mut samples = self.stored_f32();
        let (low, gain) = (low as f32, gain as f32);
        samples.par_iter_mut().for_each(|v| *v = (*v - low) * gain);
        samples
    }

    /// [`ImageData::stored_f64`] as `f32`.
    pub fn stored_f32(&self) -> Vec<f32> {
        match self.pixel_type {
            PixelType::U8 => self.data.par_iter().map(|&v| f32::from(v)).collect(),
            PixelType::U16 => self
                .data
                .par_chunks_exact(2)
                .map(|c| f32::from(u16::from_le_bytes([c[0], c[1]])))
                .collect(),
            PixelType::F32 => self
                .data
                .par_chunks_exact(4)
                .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
                .collect(),
            PixelType::U32 | PixelType::F64 => {
                let size = self.bytes_per_pixel();
                let pixel_type = self.pixel_type;
                self.data
                    .par_chunks_exact(size)
                    .map(|c| sample_from_le(c, pixel_type) as f32)
                    .collect()
            }
        }
    }

    /// Decode `count` samples starting at sample `start` into `out` as 16-bit
    /// ADU, replacing its contents. `out` is scratch a caller reuses from band
    /// to band.
    ///
    /// Panics when the range reaches past the buffer.
    pub fn samples_f64_into(&self, start: usize, count: usize, out: &mut Vec<f64>) {
        let size = self.bytes_per_pixel();
        let bytes = &self.data[start * size..(start + count) * size];
        out.clear();
        out.reserve(count);
        match self.pixel_type {
            PixelType::U16 => out.extend(
                bytes
                    .as_chunks::<2>()
                    .0
                    .iter()
                    .map(|c| f64::from(u16::from_le_bytes(*c))),
            ),
            PixelType::F32 => out.extend(
                bytes
                    .as_chunks::<4>()
                    .0
                    .iter()
                    .map(|c| f64::from(f32::from_le_bytes(*c))),
            ),
            pixel_type => out.extend(
                bytes
                    .chunks_exact(size)
                    .map(|c| sample_from_le(c, pixel_type)),
            ),
        }
        if let Some((low, gain)) = self.adu_mapping() {
            out.iter_mut().for_each(|v| *v = (*v - low) * gain);
        }
    }

    /// Every sample as a whole 16-bit ADU level: rounded and held within the
    /// 16-bit range, with a sample that is not finite at level 0. What a
    /// measurement that counts levels (statistics of a 16-bit frame, the
    /// frame-quality percentiles) reads from an image of any type.
    pub fn adu_levels(&self) -> Vec<u16> {
        if self.pixel_type == PixelType::U16 {
            return self
                .data
                .par_chunks_exact(2)
                .map(|c| u16::from_le_bytes([c[0], c[1]]))
                .collect();
        }
        let size = self.bytes_per_pixel();
        let pixel_type = self.pixel_type;
        let (low, gain) = self.adu_mapping().unwrap_or((0.0, 1.0));
        self.data
            .par_chunks_exact(size)
            // `as` saturates and maps NaN to 0.
            .map(|c| ((sample_from_le(c, pixel_type) - low) * gain).round() as u16)
            .collect()
    }

    /// The image re-encoded as `pixel_type` samples spanning `range`, or
    /// borrowed unchanged when it already is. Integer targets round and
    /// clamp to their type; NaN becomes 0.
    pub fn converted_to(
        &self,
        pixel_type: PixelType,
        range: crate::SampleRange,
    ) -> std::borrow::Cow<'_, ImageData> {
        if (self.pixel_type == pixel_type && self.range == range) || self.is_empty() {
            return std::borrow::Cow::Borrowed(self);
        }
        let integer = !matches!(pixel_type, PixelType::F32 | PixelType::F64);
        let size = pixel_type.byte_size();
        let mut out = ImageData::new(self.width, self.height, self.channels, pixel_type);
        out.range = range;
        let values = self.samples_f64();
        out.data
            .par_chunks_exact_mut(size)
            .zip(values.par_iter())
            .for_each(|(bytes, &adu)| {
                let v = if adu.is_nan() { 0.0 } else { range.from_adu(adu) };
                sample_to_le(bytes, pixel_type, if integer { v.round() } else { v });
            });
        std::borrow::Cow::Owned(out)
    }

    /// Channel `channel` as an `f64` plane of `width × height` in 16-bit ADU,
    /// row-major. `None` when the channel does not exist or the buffer is
    /// short.
    pub fn plane_f64(&self, channel: usize) -> Option<Vec<f64>> {
        let channels = self.channels.max(1) as usize;
        if channel >= channels || !self.holds_all_samples() {
            return None;
        }
        let size = self.bytes_per_pixel();
        let stride = channels * size;
        let pixel_type = self.pixel_type;
        let locations = (self.width as usize) * (self.height as usize);
        let (low, gain) = self.adu_mapping().unwrap_or((0.0, 1.0));
        Some(
            self.data[..locations * stride]
                .par_chunks_exact(stride)
                .map(|pixel| (sample_from_le(&pixel[channel * size..], pixel_type) - low) * gain)
                .collect(),
        )
    }

    /// One `f64` plane per channel. Empty when the buffer is short.
    pub fn planes_f64(&self) -> Vec<Vec<f64>> {
        (0..self.channels.max(1) as usize)
            .map_while(|channel| self.plane_f64(channel))
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn image(pixel_type: PixelType, channels: u32, values: &[f64]) -> ImageData {
        let mut image = ImageData::new(values.len() as u32 / channels, 1, channels, pixel_type)
            .with_range(crate::SampleRange::ADU);
        let size = pixel_type.byte_size();
        for (i, &v) in values.iter().enumerate() {
            sample_to_le(&mut image.data[i * size..], pixel_type, v);
        }
        image
    }

    #[test]
    fn every_pixel_type_round_trips_through_f64() {
        let values = [0.0, 1.0, 37.0, 200.0, 255.0, 12.0];
        for pixel_type in [
            PixelType::U8,
            PixelType::U16,
            PixelType::U32,
            PixelType::F32,
            PixelType::F64,
        ] {
            let image = image(pixel_type, 1, &values);
            assert_eq!(image.samples_f64(), values, "{pixel_type:?}");
            let as_f32: Vec<f64> = image.samples_f32().iter().map(|&v| f64::from(v)).collect();
            assert_eq!(as_f32, values, "{pixel_type:?} as f32");
            let mut band = vec![9.0];
            image.samples_f64_into(2, 3, &mut band);
            assert_eq!(band, &values[2..5], "{pixel_type:?} band");
        }
    }

    #[test]
    fn samples_come_out_in_adu_whatever_the_range() {
        use crate::SampleRange;
        let adu = [0.0, 6553.5, 32767.5, 65535.0];
        let unit = image(PixelType::F32, 1, &[0.0, 0.1, 0.5, 1.0]).with_range(SampleRange::UNIT);
        for (got, want) in unit.samples_f64().iter().zip(adu) {
            assert!((got - want).abs() < 0.01, "{got} vs {want}");
        }
        for (got, want) in unit.samples_f32().iter().zip(adu) {
            assert!((f64::from(*got) - want).abs() < 0.01, "{got} vs {want}");
        }
        let mut band = Vec::new();
        unit.samples_f64_into(2, 2, &mut band);
        assert!((band[0] - 32767.5).abs() < 0.01 && (band[1] - 65535.0).abs() < 0.01);
        assert!((unit.plane_f64(0).unwrap()[1] - 6553.5).abs() < 0.01);

        // An 8-bit image spans its type: 255 is full scale.
        let bytes = ImageData::new(2, 1, 1, PixelType::U8);
        assert_eq!(bytes.range.high, 255.0);
        let mut bytes = bytes;
        bytes.data = vec![0, 255];
        assert_eq!(bytes.samples_f64(), [0.0, 65535.0]);
        assert_eq!(bytes.samples_f32(), [0.0, 65535.0]);
    }

    #[test]
    fn planes_split_the_interleaved_channels() {
        let image = image(PixelType::U16, 3, &[1.0, 2.0, 3.0, 4.0, 5.0, 6.0]);
        assert_eq!(image.plane_f64(0).unwrap(), [1.0, 4.0]);
        assert_eq!(image.plane_f64(2).unwrap(), [3.0, 6.0]);
        assert!(image.plane_f64(3).is_none());
        assert_eq!(image.planes_f64().len(), 3);
    }

    #[test]
    fn a_short_buffer_has_no_planes_and_integers_saturate() {
        let mut short = image(PixelType::F32, 1, &[1.0, 2.0]);
        short.data.truncate(5);
        assert!(!short.holds_all_samples());
        assert!(short.plane_f64(0).is_none());
        assert!(short.planes_f64().is_empty());
        assert_eq!(short.samples_f64(), [1.0]);

        let mut bytes = [0u8; 2];
        sample_to_le(&mut bytes, PixelType::U16, 70_000.7);
        assert_eq!(u16::from_le_bytes(bytes), u16::MAX);
        sample_to_le(&mut bytes, PixelType::U16, f64::NAN);
        assert_eq!(u16::from_le_bytes(bytes), 0);
        sample_to_le(&mut bytes, PixelType::U16, 12.9);
        assert_eq!(u16::from_le_bytes(bytes), 12);
        sample_to_le(&mut bytes, PixelType::U8, 300.0);
        assert_eq!(bytes[0], 255);
        sample_to_le(&mut bytes, PixelType::U8, -5.0);
        assert_eq!(bytes[0], 0);
        let mut wide = [0u8; 8];
        sample_to_le(&mut wide, PixelType::F64, -12345.678);
        assert_eq!(sample_from_le(&wide, PixelType::F64), -12345.678);
    }
}
