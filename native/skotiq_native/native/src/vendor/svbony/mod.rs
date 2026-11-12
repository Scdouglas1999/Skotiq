//! SVBony Camera SDK Bindings
//!
//! Native driver for SVBony cameras using their official SDK.
//!
//! ## Thread Safety
//!
//! The SVBony SDK is NOT thread-safe. Its function table is only reachable
//! through an `SdkGuard`, which holds the SDK lock for as long as it lives.

use crate::camera_core::{
    bayer_from_asi_index, roi_dimension, unpack_samples, CameraCore, Frame, SampleLayout,
};
use crate::utils::calculate_buffer_size_i32;
use async_trait::async_trait;
use skotiq_device::camera::{
    CameraCapabilities, CameraState, CameraStatus, ExposureParams, ImageData, ReadoutMode,
    SensorInfo, SubFrame, VendorFeatures,
};
use skotiq_device::Vendor;
use skotiq_device::{CameraDriver, DeviceDriver, DriverError};
use std::ffi::{c_char, c_int, c_long, CStr};

mod camera;
mod camera_ops;
mod controls;
mod discovery;
mod ffi;
mod roi;
mod sdk;

pub use camera::*;
use controls::*;
pub use discovery::*;
use ffi::*;
use roi::*;
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

    #[test]
    fn y16_and_y8_ceilings_follow_their_containers() {
        assert_eq!(container_max_adu(SvbImgType::Y16, 12), 65520);
        assert_eq!(container_max_adu(SvbImgType::Y8, 12), 255);
    }

    /// SVB_CONTROL_CAPS ends in `char Unused[32]` (SVBCameraSDK.h); a struct
    /// without it is 32 bytes short of what SVBGetControlCaps may write.
    #[test]
    fn control_caps_have_the_header_layout() {
        let long = std::mem::size_of::<c_long>();
        let tail = 64 + 128 + 3 * long + 3 * 4;
        assert_eq!(std::mem::offset_of!(SvbControlCaps, unused), tail);
        assert_eq!(
            std::mem::size_of::<SvbControlCaps>(),
            (tail + 32).next_multiple_of(long)
        );
    }

    #[test]
    fn the_deepest_listed_format_is_read_raw_before_luma() {
        // Color models list the raw mosaic; RGB24 (10) is never chosen.
        assert_eq!(
            SvbImgType::preferred(&[0, 10, 4, -1]),
            Some(SvbImgType::Raw16)
        );
        // Monochrome models list luma only (svbony_base.cpp:472).
        assert_eq!(SvbImgType::preferred(&[5, 9, -1]), Some(SvbImgType::Y16));
        assert_eq!(SvbImgType::preferred(&[0, -1]), Some(SvbImgType::Raw8));
        // Entries after SVB_IMG_END are not formats.
        assert_eq!(SvbImgType::preferred(&[5, -1, 4, 9]), Some(SvbImgType::Y8));
        assert_eq!(SvbImgType::preferred(&[10, 11, -1]), None);
        assert!(SvbImgType::Raw16.is_mosaic());
        assert!(!SvbImgType::Y16.is_mosaic());
    }

    fn subframe(start_x: u32, start_y: u32, width: u32, height: u32) -> SubFrame {
        SubFrame {
            start_x,
            start_y,
            width,
            height,
        }
    }

    #[test]
    fn a_binned_frame_is_rounded_to_the_sizes_the_sdk_takes() {
        // IMX294 (SV405CC): 2822 / 2 = 1411 rows would be refused as INVALID_SIZE.
        let roi = Roi::for_frame(4144, 2822, 2, None, true).unwrap();
        assert_eq!(
            (roi.start_x, roi.start_y, roi.width, roi.height, roi.bin),
            (0, 0, 2072, 1410, 2)
        );
        let roi = Roi::for_frame(1920, 1080, 3, None, true).unwrap();
        assert_eq!((roi.width, roi.height), (640, 360));
        let roi = Roi::for_frame(3856, 2180, 4, None, false).unwrap();
        assert_eq!((roi.width, roi.height), (960, 544));
    }

    #[test]
    fn a_color_subframe_keeps_the_sensors_bayer_phase() {
        let roi = Roi::for_frame(1920, 1080, 1, Some(&subframe(101, 51, 203, 99)), true).unwrap();
        assert_eq!(
            (roi.start_x, roi.start_y, roi.width, roi.height),
            (100, 50, 200, 98)
        );
        let roi = Roi::for_frame(1920, 1080, 1, Some(&subframe(101, 51, 203, 99)), false).unwrap();
        assert_eq!((roi.start_x, roi.start_y), (101, 51));
        let sf = roi.subframe();
        assert_eq!(
            (sf.start_x, sf.start_y, sf.width, sf.height),
            (101, 51, 200, 98)
        );
    }

    #[test]
    fn a_subframe_outside_the_binned_sensor_or_too_small_is_refused() {
        assert!(Roi::for_frame(1920, 1080, 2, Some(&subframe(900, 0, 100, 100)), true).is_err());
        assert!(Roi::for_frame(1920, 1080, 1, Some(&subframe(0, 0, 7, 100)), true).is_err());
        assert!(Roi::for_frame(1920, 1080, 1, Some(&subframe(u32::MAX, 0, 8, 2)), true).is_err());
        assert!(Roi::for_frame(1920, 1080, 0, None, true).is_err());
    }

    fn exposure_control(min: i64, max: i64) -> Control {
        Control {
            control_type: SvbControlType::Exposure as c_int,
            min,
            max,
            default: 1_000_000,
            writable: true,
        }
    }

    #[test]
    fn an_exposure_beyond_the_camera_is_refused_and_a_short_one_takes_its_minimum() {
        let range = exposure_control(32, 1_000_000_000);
        assert_eq!(exposure_micros(2.5, Some(&range)).unwrap(), 2_500_000);
        assert_eq!(exposure_micros(0.0, Some(&range)).unwrap(), 32);
        assert_eq!(
            exposure_micros(1000.0, Some(&range)).unwrap(),
            1_000_000_000
        );
        assert!(matches!(
            exposure_micros(1200.0, Some(&range)),
            Err(DriverError::InvalidParameter(_))
        ));
        assert!(exposure_micros(f64::NAN, Some(&range)).is_err());
        assert!(exposure_micros(-1.0, None).is_err());
    }

    #[test]
    fn an_exposure_the_sdks_long_cannot_hold_is_refused() {
        let micros = exposure_micros(3000.0, None);
        if std::mem::size_of::<c_long>() == 4 {
            assert!(micros.is_err(), "3000 s does not fit a 32-bit long");
        } else {
            assert_eq!(micros.unwrap(), 3_000_000_000);
        }
    }

    #[test]
    fn connect_resets_only_the_image_shaping_controls() {
        let control = |control_type: c_int, writable: bool| Control {
            control_type,
            min: 0,
            max: 100,
            default: 0,
            writable,
        };
        let controls = Controls::new(vec![
            control(0, true),
            control(1, true),
            control(2, true),
            control(7, true),
            control(13, true),
            control(14, true),
            control(15, true),
            control(16, false),
            control(17, false),
            control(18, true),
            control(11, false),
        ]);
        let reset: Vec<c_int> = controls.image_shaping().map(|c| c.control_type).collect();
        assert_eq!(reset, vec![2, 7, 18]);
    }

    #[tokio::test]
    async fn svbony_set_gain_error_does_not_mutate_cache() {
        let mut camera = SvbonyCamera::new(0);
        camera.core.gain = 12;

        let err = camera.set_gain(48).await.unwrap_err();

        assert!(matches!(err, DriverError::NotConnected));
        assert_eq!(camera.core.gain, 12);
    }

    #[tokio::test]
    async fn svbony_set_offset_error_does_not_mutate_cache() {
        let mut camera = SvbonyCamera::new(0);
        camera.core.offset = 8;

        let err = camera.set_offset(22).await.unwrap_err();

        assert!(matches!(err, DriverError::NotConnected));
        assert_eq!(camera.core.offset, 8);
    }
}
