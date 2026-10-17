//! SVBony Camera SDK Bindings
//!
//! Native driver for SVBony cameras using their official SDK.
//!
//! ## Thread Safety
//!
//! The SVBony SDK is NOT thread-safe. All SDK operations are protected
//! by `svbony_mutex()` from `crate::sync` to prevent concurrent access.

use crate::camera::{
    BayerPattern, CameraCapabilities, CameraState, CameraStatus, ExposureParams, ImageData,
    ImageMetadata, ReadoutMode, SensorInfo, SubFrame, VendorFeatures,
};
use crate::sync::svbony_mutex;
use crate::traits::{NativeCamera, NativeDevice, NativeError};
use crate::utils::calculate_buffer_size_i32;
use crate::NativeVendor;
use async_trait::async_trait;
use std::ffi::{c_char, c_int, c_long, CStr};

mod camera;
mod camera_ops;
mod discovery;
mod ffi;
mod sdk;

pub use camera::*;
pub use discovery::*;
use ffi::*;
use sdk::*;

#[cfg(test)]
mod tests {
    use super::*;

    /// RAW16 ceilings must be the left-justified container full scale, not the
    /// ADC range.
    ///
    /// `(1 << MaxBitDepth) - 1` is the ADC range, not the container full scale.
    /// Measured on an SV305 (12-bit): once the SVBony SDK started delivering
    /// RAW16, every pixel value became a multiple of 16 and the saturation level
    /// moved from 4096 to 65536 ADU. See [`container_max_adu`] for the citation.
    #[test]
    fn raw16_container_max_adu_accounts_for_left_justification() {
        // 12-bit sensor (SV305/SV305 Pro class): 4095 << 4
        assert_eq!(container_max_adu(SvbImgType::Raw16, 12), 65520);
        // 14-bit sensor: 16383 << 2
        assert_eq!(container_max_adu(SvbImgType::Raw16, 14), 65532);
        // 10-bit sensor: 1023 << 6
        assert_eq!(container_max_adu(SvbImgType::Raw16, 10), 65472);
        // A genuinely 16-bit sensor (SV605MC/SV605CC class) needs no shift.
        assert_eq!(container_max_adu(SvbImgType::Raw16, 16), 65535);
    }

    /// Whatever ceiling we publish must be a value a `u16` sample can hold, and
    /// must land on the sample grid the ADC produces — a 12-bit sensor
    /// left-justified into 16 bits can only emit multiples of 16.
    #[test]
    fn raw16_container_max_adu_is_a_reachable_u16_sample() {
        for bit_depth in 1..=16u32 {
            let max = container_max_adu(SvbImgType::Raw16, bit_depth);
            assert!(
                max <= u32::from(u16::MAX),
                "bit_depth {bit_depth} produced {max}, outside the u16 container"
            );
            let step = 1u32 << (16 - bit_depth.min(16));
            assert_eq!(
                max % step,
                0,
                "bit_depth {bit_depth}: {max} is not a multiple of the {step}-ADU sample step"
            );
        }
    }

    /// The RAW8 fallback in `connect()` caps every sample at 255 no matter how
    /// deep the sensor is. Publishing the sensor-derived ceiling there overstates
    /// an 8-bit frame by up to 16x and breaks flats the same way, just in the
    /// opposite direction.
    #[test]
    fn raw8_fallback_ceiling_is_the_byte_container_not_the_sensor() {
        for bit_depth in [0u32, 8, 10, 12, 14, 16] {
            assert_eq!(
                container_max_adu(SvbImgType::Raw8, bit_depth),
                255,
                "RAW8 must cap at 255 regardless of the {bit_depth}-bit sensor"
            );
        }
    }

    /// An unpopulated / out-of-range `MaxBitDepth` must fall back to the
    /// container ceiling, never to 0 — a 0 ceiling would tell every
    /// percent-of-full-scale consumer the camera cannot produce any signal, and
    /// a `(1 << bit_depth.min(31)) - 1` returns 2147483647 for 31.
    #[test]
    fn raw16_unknown_bit_depth_falls_back_to_container() {
        assert_eq!(container_max_adu(SvbImgType::Raw16, 0), 65535);
        assert_eq!(container_max_adu(SvbImgType::Raw16, 31), 65535);
        assert_eq!(container_max_adu(SvbImgType::Raw16, u32::MAX), 65535);
    }

    /// The ceiling must agree with the pipeline's own saturation threshold
    /// (`skotiq_imaging::fits` uses 65024, documented as "4064 << 4").
    /// A ceiling below that threshold can never reach saturation, which makes
    /// flat calibration impossible.
    #[test]
    fn raw16_container_max_adu_agrees_with_pipeline_saturation_threshold() {
        const PIPELINE_SATURATION_THRESHOLD: u32 = 65024;
        let twelve_bit_ceiling = container_max_adu(SvbImgType::Raw16, 12);
        assert!(
            PIPELINE_SATURATION_THRESHOLD < twelve_bit_ceiling,
            "12-bit ceiling {twelve_bit_ceiling} is below the pipeline saturation threshold"
        );
        // Publishing the ADC range instead would put the ceiling below the
        // threshold: saturation undetectable on an SV305-class sensor, and a 50%
        // flat target below the camera's own bias floor.
        let adc_range_formula = |bits: u32| (1u32 << bits) - 1;
        assert!(adc_range_formula(12) < PIPELINE_SATURATION_THRESHOLD);
    }

    #[tokio::test]
    async fn svbony_set_gain_error_does_not_mutate_cache() {
        let mut camera = SvbonyCamera::new(0);
        camera.current_gain = 12;

        let err = camera.set_gain(48).await.unwrap_err();

        assert!(matches!(err, NativeError::NotConnected));
        assert_eq!(camera.current_gain, 12);
    }

    #[tokio::test]
    async fn svbony_set_offset_error_does_not_mutate_cache() {
        let mut camera = SvbonyCamera::new(0);
        camera.current_offset = 8;

        let err = camera.set_offset(22).await.unwrap_err();

        assert!(matches!(err, NativeError::NotConnected));
        assert_eq!(camera.current_offset, 8);
    }
}
