//! Finger Lakes Instrumentation (FLI) SDK Bindings
//!
//! Native driver for FLI cameras, focusers, and filter wheels using libfli.
//! This is an open-source library with cross-platform support.

use crate::camera::{
    CameraCapabilities, CameraState, CameraStatus, ExposureParams, ImageData, ImageMetadata,
    ReadoutMode, SensorInfo, SubFrame, VendorFeatures,
};
use crate::sync::fli_mutex;
use crate::traits::{NativeCamera, NativeDevice, NativeError, NativeFilterWheel, NativeFocuser};
use crate::NativeVendor;
use async_trait::async_trait;
use std::ffi::{c_char, c_double, c_long, CStr, CString};

mod camera;
mod camera_ops;
mod discovery;
mod ffi;
mod filter_wheel;
mod focuser;
mod sdk;

pub use camera::*;
pub use discovery::*;
use ffi::*;
pub use filter_wheel::*;
pub use focuser::*;
use sdk::*;

#[cfg(test)]
mod capability_answer_tests {
    use super::*;

    /// A body with no selectable bit depth is 16-bit, which is the mode the
    /// connect asks for. Turning libfli's not-supported answer into a hard
    /// refusal made those bodies impossible to connect; they imaged in 6.2.0.
    #[test]
    fn libfli_not_supported_codes_are_not_failures() {
        for code in [-22, -25, -38, -95] {
            assert_eq!(
                fli_capability_answer(code),
                FliCapabilityAnswer::NotSupported(code),
                "libfli code {code} means the device has no such control"
            );
        }
    }

    /// Everything else reached the device and failed, and a camera left in
    /// 8-bit while the app advertises a 65535 full scale mis-scales every frame
    /// of the night — so those still refuse.
    #[test]
    fn other_codes_remain_connect_failures() {
        for code in [-5, -19, -110, 7] {
            assert_eq!(
                fli_capability_answer(code),
                FliCapabilityAnswer::Failed(code),
                "libfli code {code} is a real failure"
            );
        }
    }

    #[test]
    fn zero_is_done() {
        assert_eq!(fli_capability_answer(0), FliCapabilityAnswer::Done);
    }
}

#[cfg(test)]
mod camera_tests {
    use super::*;

    #[tokio::test]
    async fn fli_gain_and_offset_writes_report_not_supported() {
        let mut camera = FliCamera::new("test".to_string());

        assert!(matches!(
            camera.set_gain(10).await,
            Err(NativeError::NotSupported)
        ));
        assert!(matches!(
            camera.set_offset(20).await,
            Err(NativeError::NotSupported)
        ));
    }
}
