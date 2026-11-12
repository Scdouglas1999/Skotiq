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

/// Save a frame as the operator chose: the app's FITS file at `fits_path`
/// (header from `frame_ctx`, through [`FrameStoreOps::save_fits`]), the
/// camera's own file beside it under the same name with the camera's
/// extension, or both. The camera's file is written byte for byte and never
/// over an existing file: when either name is taken, both move to the next
/// free `_001`-style name. A frame without a camera file (every astronomy
/// camera) always gets the FITS file.
///
/// Only a frame kept as a frame (`keeper`: a sequence's light, dark, flat or
/// bias, a secondary camera's sequence frame, a capture the operator saves)
/// follows `saving`; a scratch frame (live view, loop, framing, plate solve,
/// autofocus) is saved as FITS only. The caller knows which it is.
///
/// Every saved frame comes through here. Returns the file the app records the
/// frame by: the FITS file when one is written, else the camera's file.
pub async fn save_frame<T: FrameStoreOps + ?Sized>(
    ops: &T,
    image_data: &ImageData,
    fits_path: &str,
    frame_ctx: &crate::scheduling::FrameContext,
    saving: crate::CameraFileSaving,
    keeper: bool,
) -> DeviceResult<String> {
    let saving = if keeper {
        saving
    } else {
        crate::CameraFileSaving::Converted
    };
    let camera_file = image_data
        .camera_file
        .as_ref()
        .filter(|_| saving.writes_camera_file());
    let Some(file) = camera_file else {
        ops.save_fits(image_data, fits_path, frame_ctx).await?;
        return Ok(fits_path.to_string());
    };
    let (fits_path, camera_path) = free_names(fits_path, file);
    write_camera_file(&camera_path, file).await?;
    if !saving.writes_converted() {
        return Ok(camera_path);
    }
    ops.save_fits(image_data, &fits_path, frame_ctx).await?;
    Ok(fits_path)
}

/// The first FITS and camera-file pair, starting from `fits_path`, of which
/// neither exists yet.
fn free_names(fits_path: &str, file: &skotiq_device::CameraFile) -> (String, String) {
    let path = std::path::Path::new(fits_path);
    let stem = path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    let extension = path.extension().map(|e| e.to_string_lossy().into_owned());
    let mut candidate = fits_path.to_string();
    for suffix in 1u32.. {
        let camera = camera_file_path(&candidate, file);
        if !std::path::Path::new(&candidate).exists() && !std::path::Path::new(&camera).exists() {
            return (candidate, camera);
        }
        let name = match &extension {
            Some(ext) => format!("{stem}_{suffix:03}.{ext}"),
            None => format!("{stem}_{suffix:03}"),
        };
        candidate = path.with_file_name(name).to_string_lossy().into_owned();
    }
    unreachable!("u32 suffixes run out only after four billion files")
}

/// The camera's file beside `fits_path`: same folder and name, the camera's
/// extension.
pub fn camera_file_path(fits_path: &str, file: &skotiq_device::CameraFile) -> String {
    let path = std::path::Path::new(fits_path);
    match file.extension() {
        Some(extension) => path.with_extension(extension),
        None => path.to_path_buf(),
    }
    .to_string_lossy()
    .into_owned()
}

async fn write_camera_file(path: &str, file: &skotiq_device::CameraFile) -> DeviceResult<()> {
    let path = path.to_string();
    let bytes = file.bytes.clone();
    let target = path.clone();
    let written = tokio::task::spawn_blocking(move || -> std::io::Result<()> {
        use std::io::Write;
        if let Some(parent) = std::path::Path::new(&target).parent() {
            std::fs::create_dir_all(parent)?;
        }
        let mut out = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&target)?;
        out.write_all(&bytes)?;
        out.sync_all()
    })
    .await
    .map_err(|e| format!("Saving the camera's file {path} stopped: {e}"))?;
    written.map_err(|e| format!("Could not save the camera's file {path}: {e}"))?;
    Ok(())
}

#[async_trait]
pub trait FrameStoreOps: Send + Sync {
    /// Write `image_data` as FITS with the header its
    /// [`FrameContext`](crate::scheduling::FrameContext) describes; the
    /// bridge's `frame_header` holds the keyword list. Callers save through
    /// [`save_frame`], which decides whether a FITS file is written.
    async fn save_fits(
        &self,
        image_data: &ImageData,
        file_path: &str,
        frame_ctx: &crate::scheduling::FrameContext,
    ) -> DeviceResult<()>;

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

#[cfg(test)]
mod save_frame_tests {
    use super::*;
    use crate::CameraFileSaving;

    fn frame(camera_file: Option<skotiq_device::CameraFile>) -> ImageData {
        ImageData {
            width: 2,
            height: 2,
            data: vec![1, 2, 3, 4],
            bits_per_pixel: 14,
            exposure_secs: 1.0,
            gain: None,
            offset: None,
            temperature: None,
            filter: None,
            timestamp: 0,
            sensor_type: Some("Color".to_string()),
            color_filter: Some(skotiq_device::BayerPattern::Rggb),
            camera_file,
        }
    }

    fn camera_file() -> skotiq_device::CameraFile {
        skotiq_device::CameraFile {
            file_name: "IMG_0042.CR3".to_string(),
            bytes: std::sync::Arc::new(b"the camera's bytes".to_vec()),
        }
    }

    fn scratch(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("sk-save-frame-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    async fn save(dir: &std::path::Path, image: &ImageData, saving: CameraFileSaving) -> DeviceResult<String> {
        save_as(dir, image, saving, true).await
    }

    async fn save_as(
        dir: &std::path::Path,
        image: &ImageData,
        saving: CameraFileSaving,
        keeper: bool,
    ) -> DeviceResult<String> {
        let fits = dir.join("M31_Light_0001.fits");
        save_frame(
            &super::super::NullDeviceOps,
            image,
            fits.to_str().unwrap(),
            &crate::scheduling::FrameContext::default(),
            saving,
            keeper,
        )
        .await
    }

    #[tokio::test]
    async fn a_scratch_frame_never_writes_the_camera_file() {
        let dir = scratch("scratch");
        for saving in [CameraFileSaving::CameraFile, CameraFileSaving::Both] {
            let recorded = save_as(&dir, &frame(Some(camera_file())), saving, false).await.unwrap();
            assert!(recorded.ends_with("M31_Light_0001.fits"), "{recorded}");
        }
        assert!(!dir.join("M31_Light_0001.CR3").exists());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[tokio::test]
    async fn the_camera_file_is_written_as_delivered_under_the_frame_name() {
        let dir = scratch("both");
        let recorded = save(&dir, &frame(Some(camera_file())), CameraFileSaving::Both).await.unwrap();
        assert!(recorded.ends_with("M31_Light_0001.fits"), "{recorded}");
        let raw = dir.join("M31_Light_0001.CR3");
        assert_eq!(std::fs::read(&raw).unwrap(), b"the camera's bytes");

        let dir = scratch("camera");
        let recorded = save(&dir, &frame(Some(camera_file())), CameraFileSaving::CameraFile).await.unwrap();
        assert!(recorded.ends_with("M31_Light_0001.CR3"), "{recorded}");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[tokio::test]
    async fn converted_only_and_cameras_without_a_file_record_the_fits_file() {
        let dir = scratch("converted");
        let recorded = save(&dir, &frame(Some(camera_file())), CameraFileSaving::Converted).await.unwrap();
        assert!(recorded.ends_with(".fits"));
        assert!(!dir.join("M31_Light_0001.CR3").exists());

        // An astronomy camera delivers no file: it gets the FITS file whatever the setting.
        let recorded = save(&dir, &frame(None), CameraFileSaving::CameraFile).await.unwrap();
        assert!(recorded.ends_with(".fits"));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[tokio::test]
    async fn an_existing_file_is_never_overwritten() {
        let dir = scratch("existing");
        std::fs::write(dir.join("M31_Light_0001.CR3"), b"an earlier frame").unwrap();
        let recorded = save(&dir, &frame(Some(camera_file())), CameraFileSaving::Both).await.unwrap();
        assert!(recorded.ends_with("M31_Light_0001_001.fits"), "{recorded}");
        assert_eq!(std::fs::read(dir.join("M31_Light_0001.CR3")).unwrap(), b"an earlier frame");
        assert_eq!(
            std::fs::read(dir.join("M31_Light_0001_001.CR3")).unwrap(),
            b"the camera's bytes"
        );
        let _ = std::fs::remove_dir_all(dir);
    }
}
