//! Saving a frame and measuring its stars.

use super::{DeviceResult, ImageData};
use async_trait::async_trait;

/// A light frame's star shape: the median eccentricity, and the mean
/// direction of the stars' long axes with how well they agree on it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FrameStarShape {
    pub eccentricity: f64,
    /// `(degrees from the image +x axis toward +y in [0, 180), agreement 0
    /// to 1)`, when the measurement gives one.
    pub elongation: Option<(f64, f64)>,
}

#[async_trait]
pub trait FrameStoreOps: Send + Sync {
    /// Save image as FITS file.
    ///
    /// Image Grading: the per-frame metadata bundle is the
    /// [`FrameContext`](crate::scheduling::FrameContext) carried from
    /// `expose.rs`. It supersedes the previous 4-field call signature
    /// (target_name, filter, RA, Dec) — the FITS writer extracts every
    /// relevant keyword (target identification, plate-solve coords,
    /// telemetry, mosaic panel, observer/site info, equipment ID) from
    /// the context. See `bridge/src/api/imaging.rs::api_save_fits_file`
    /// for the keyword list.
    async fn save_fits(
        &self,
        image_data: &ImageData,
        file_path: &str,
        frame_ctx: &crate::scheduling::FrameContext,
    ) -> DeviceResult<()>;

    /// The extension, without the dot, of the file format frames are saved
    /// in: the host's capture file format setting.
    fn frame_file_extension(&self) -> &'static str {
        "fits"
    }

    /// Calculate median HFR from an image
    async fn calculate_image_hfr(&self, image_data: &ImageData) -> DeviceResult<Option<f64>>;

    /// Detect stars and return their HFRs (returns x, y, hfr tuples)
    async fn detect_stars_in_image(
        &self,
        image_data: &ImageData,
    ) -> DeviceResult<Vec<(f64, f64, f64)>>;

    /// Measure the per-frame median star eccentricity (0.0 = round,
    /// →1.0 = trailed/elongated).
    ///
    /// Returns `Ok(None)` when the metric cannot be honestly measured for
    /// this frame (no stars, or too few reliable stars to form a stable
    /// median). This feeds `FrameMetrics.eccentricity`, which the grading
    /// gate treats as "unknown — do not reject". The default implementation
    /// returns `Ok(None)`; the real backend (`UnifiedDeviceOps`) overrides
    /// it to run the shape-moment detector. Callers MUST distinguish a real
    /// `Some(ecc)` from `None` so a configured eccentricity gate is never
    /// silently bypassed.
    async fn measure_frame_eccentricity(
        &self,
        image_data: &ImageData,
    ) -> DeviceResult<Option<f64>> {
        let _ = image_data;
        Ok(None)
    }

    /// How trailed the frame's stars are, measured from the image rather than
    /// from detected stars (a trailed star is too long for the detector to
    /// keep). `None` when not measured; the default measures nothing.
    async fn measure_frame_trail(
        &self,
        image_data: &ImageData,
    ) -> DeviceResult<Option<skotiq_imaging::FrameTrail>> {
        let _ = image_data;
        Ok(None)
    }

    /// The frame's star shape with the direction of elongation. A device
    /// layer that measures only the eccentricity keeps this default.
    async fn measure_frame_star_shape(
        &self,
        image_data: &ImageData,
    ) -> DeviceResult<Option<FrameStarShape>> {
        Ok(self
            .measure_frame_eccentricity(image_data)
            .await?
            .map(|eccentricity| FrameStarShape {
                eccentricity,
                elongation: None,
            }))
    }
}
