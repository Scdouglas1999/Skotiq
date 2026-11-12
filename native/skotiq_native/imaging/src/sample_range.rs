//! What a sample value means.
//!
//! A 16-bit camera frame, a PixInsight float image in `[0, 1]` and a float
//! master in ADU can hold the same scene in different numbers. Every
//! [`ImageData`](crate::ImageData) says which numbers it holds with a
//! [`SampleRange`]: the sample values of black and of full scale. The reader
//! of a file decides it once, from what the file declares; algorithms work on
//! the 16-bit ADU scale and reach it through [`SampleRange::to_adu`]
//! (`ImageData::samples_f32` and its siblings do that for them); writers
//! record it.

use crate::PixelType;

/// Full scale of the app's working scale, 16-bit ADU.
pub const ADU_FULL_SCALE: f64 = 65535.0;

/// The sample values that mean black (`low`) and full scale (`high`).
///
/// Samples may lie outside the range: a background-subtracted master goes
/// below `low`, a sum above `high`. The range says what the numbers mean, not
/// where they stop.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SampleRange {
    pub low: f64,
    pub high: f64,
}

impl SampleRange {
    /// 16-bit ADU: a 16-bit frame, and float data computed from such frames.
    pub const ADU: Self = Self {
        low: 0.0,
        high: ADU_FULL_SCALE,
    };

    /// `[0, 1]`: PixInsight's float images, and stretched or delivered ones.
    pub const UNIT: Self = Self {
        low: 0.0,
        high: 1.0,
    };

    /// `None` unless both ends are finite and `high` is above `low`.
    pub fn new(low: f64, high: f64) -> Option<Self> {
        (low.is_finite() && high.is_finite() && high > low).then_some(Self { low, high })
    }

    /// The range of samples of `pixel_type` when nothing declares another:
    /// an integer type's whole range, as PixInsight reads integer images, and
    /// 16-bit ADU for a float.
    pub fn of(pixel_type: PixelType) -> Self {
        match pixel_type {
            PixelType::U8 => Self {
                low: 0.0,
                high: f64::from(u8::MAX),
            },
            PixelType::U32 => Self {
                low: 0.0,
                high: f64::from(u32::MAX),
            },
            PixelType::U16 | PixelType::F32 | PixelType::F64 => Self::ADU,
        }
    }

    pub fn is_adu(&self) -> bool {
        *self == Self::ADU
    }

    /// ADU per sample unit.
    #[inline]
    pub fn adu_per_unit(&self) -> f64 {
        ADU_FULL_SCALE / (self.high - self.low)
    }

    /// A sample on the 16-bit ADU scale.
    #[inline]
    pub fn to_adu(&self, sample: f64) -> f64 {
        (sample - self.low) * self.adu_per_unit()
    }

    /// The sample that a 16-bit ADU level is in this range.
    #[inline]
    pub fn from_adu(&self, adu: f64) -> f64 {
        adu / self.adu_per_unit() + self.low
    }

    /// The range that also holds `low..=high`, for a writer whose format
    /// truncates samples outside the declared range.
    pub fn widened_to(&self, low: f64, high: f64) -> Self {
        Self {
            low: if low.is_finite() { self.low.min(low) } else { self.low },
            high: if high.is_finite() { self.high.max(high) } else { self.high },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn integer_types_span_their_range_and_floats_are_adu() {
        assert_eq!(SampleRange::of(PixelType::U8).high, 255.0);
        assert_eq!(SampleRange::of(PixelType::U16), SampleRange::ADU);
        assert_eq!(SampleRange::of(PixelType::U32).high, 4_294_967_295.0);
        assert_eq!(SampleRange::of(PixelType::F32), SampleRange::ADU);
        assert_eq!(SampleRange::of(PixelType::F64), SampleRange::ADU);
    }

    #[test]
    fn a_sample_maps_to_adu_and_back() {
        assert_eq!(SampleRange::UNIT.to_adu(0.5), 32767.5);
        assert_eq!(SampleRange::UNIT.from_adu(65535.0), 1.0);
        assert_eq!(SampleRange::ADU.to_adu(1234.0), 1234.0);
        let offset = SampleRange::new(-10.0, 10.0).unwrap();
        assert_eq!(offset.to_adu(0.0), 32767.5);
        assert_eq!(offset.from_adu(32767.5), 0.0);
        assert_eq!(SampleRange::of(PixelType::U8).to_adu(255.0), 65535.0);
    }

    #[test]
    fn an_empty_or_unbounded_range_is_refused() {
        assert!(SampleRange::new(1.0, 1.0).is_none());
        assert!(SampleRange::new(0.0, f64::INFINITY).is_none());
        assert!(SampleRange::new(f64::NAN, 1.0).is_none());
    }

    #[test]
    fn widening_keeps_the_range_when_the_data_fit() {
        assert_eq!(SampleRange::ADU.widened_to(10.0, 4000.0), SampleRange::ADU);
        let wide = SampleRange::ADU.widened_to(-12.5, 70000.0);
        assert_eq!((wide.low, wide.high), (-12.5, 70000.0));
        assert_eq!(SampleRange::ADU.widened_to(f64::INFINITY, f64::NEG_INFINITY), SampleRange::ADU);
    }
}
