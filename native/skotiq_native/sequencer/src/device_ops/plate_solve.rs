//! Plate solving.

use super::{DeviceResult, ImageData};
use async_trait::async_trait;

/// Plate solve result
#[derive(Debug, Clone)]
pub struct PlateSolveResult {
    pub ra_degrees: f64,
    pub dec_degrees: f64,
    pub pixel_scale: f64,
    pub rotation: f64,
    /// Position angle of the image's +Y axis, degrees east of north, read
    /// from the CD matrix. Unlike `rotation` (the solver's CROTA2) its sign
    /// does not depend on whether the image is mirrored, which is what a
    /// camera attitude needs (see `polar_align::CameraAttitude`).
    pub up_position_angle_deg: f64,
    pub success: bool,
    /// The solve's full WCS, SIP distortion included, for writing into the
    /// solved frame.
    pub wcs: Option<skotiq_imaging::SipWcs>,
}

#[async_trait]
pub trait PlateSolveOps: Send + Sync {
    async fn plate_solve(
        &self,
        image_data: &ImageData,
        hint_ra: Option<f64>,
        hint_dec: Option<f64>,
        hint_scale: Option<f64>,
    ) -> DeviceResult<PlateSolveResult>;
}
