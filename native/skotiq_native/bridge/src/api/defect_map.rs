//! Defect maps (bad-pixel cosmetic correction): the map files, and which map
//! the sequencer applies to lights as they are captured.
//!
//! The map loaded into the sequencer is written only here, together with the
//! record of it, so building, enabling, disabling and clearing a map change
//! the file, what the status reports and what the next light gets in one step.

use crate::error::SkotiqError;
use skotiq_imaging::defect_map::{
    bucket_temperature, build_defect_map, CorrectionMethod, DefectMap, KernelSize,
    MIN_CONSISTENCY_FRAMES,
};
use skotiq_imaging::ImageData;
use skotiq_sequencer::DefectMapApplyState;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::Mutex;

/// Status of a stored defect map for a given camera / sensor / temperature.
pub struct ApiDefectMapStatus {
    pub camera_id: String,
    pub width: u32,
    pub height: u32,
    pub temperature_bucket_decicelsius: i16,
    pub defective_pixel_count: u32,
    pub last_rebuilt_unix_seconds: i64,
    /// Whether the sequencer corrects this camera's lights with a map.
    pub apply_during_capture: bool,
    pub stored_on_disk: bool,
}

/// The map the sequencer applies, as last handed to it; `None` when
/// correction is off.
static APPLIED: Mutex<Option<DefectMapApplyState>> = Mutex::const_new(None);

fn defect_maps_root() -> PathBuf {
    // Why: SKOTIQ_DATA_DIR is the per-platform application data path the app
    // sets at launch. Without it (unit tests, a bare headless start) the maps
    // live in the temp dir for the session.
    let base = std::env::var_os("SKOTIQ_DATA_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::temp_dir().join("skotiq"));
    base.join("defect_maps")
}

fn defect_map_path(camera_id: &str, width: u32, height: u32, bucket_decicelsius: i16) -> PathBuf {
    let camera: String = camera_id
        .chars()
        .map(|c| match c {
            'a'..='z' | 'A'..='Z' | '0'..='9' | '-' | '_' => c,
            _ => '_',
        })
        .collect();
    defect_maps_root().join(format!(
        "{}_{}x{}_{:+05}.ndm",
        camera, width, height, bucket_decicelsius
    ))
}

fn require_camera(camera_id: &str) -> Result<(), SkotiqError> {
    if camera_id.trim().is_empty() {
        return Err(SkotiqError::InvalidParameter(
            "camera_id is empty".to_string(),
        ));
    }
    Ok(())
}

/// Whether `applied` is the map stored for this camera, size and bucket.
fn is_map(
    applied: &DefectMapApplyState,
    camera_id: &str,
    width: u32,
    height: u32,
    bucket: i16,
) -> bool {
    applied.camera_id == camera_id
        && applied.map.width == width
        && applied.map.height == height
        && applied.map.temperature_bucket_decicelsius == bucket
}

fn applies_to(applied: &Option<DefectMapApplyState>, camera_id: &str) -> bool {
    applied.as_ref().is_some_and(|a| a.camera_id == camera_id)
}

/// Hand `state` to the sequencer and record it; applies from the next
/// exposure.
async fn apply(applied: &mut Option<DefectMapApplyState>, state: Option<DefectMapApplyState>) {
    crate::api::sequencer::get_sequence_executor()
        .read()
        .await
        .update_defect_map(state.clone())
        .await;
    *applied = state;
}

fn unix_seconds(time: std::time::SystemTime) -> i64 {
    time.duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64)
}

/// Build a defect map for a camera from at least
/// [`MIN_CONSISTENCY_FRAMES`] dark frames (FITS/XISF) of one size and pixel
/// type, and store it under `$SKOTIQ_DATA_DIR/defect_maps/` by camera, sensor
/// size and temperature bucket. When the sequencer is applying the map this
/// replaces, it applies the new one from the next exposure.
pub async fn api_defect_map_build(
    camera_id: String,
    dark_frame_paths: Vec<String>,
    sensor_temperature_celsius: f64,
) -> Result<ApiDefectMapStatus, SkotiqError> {
    require_camera(&camera_id)?;
    if dark_frame_paths.len() < MIN_CONSISTENCY_FRAMES {
        return Err(SkotiqError::InvalidParameter(format!(
            "defect map build requires at least {} dark frames; got {}",
            MIN_CONSISTENCY_FRAMES,
            dark_frame_paths.len()
        )));
    }

    let darks: Vec<ImageData> = tokio::task::spawn_blocking(move || {
        dark_frame_paths
            .iter()
            .map(|path| {
                skotiq_imaging::read_image(std::path::Path::new(path))
                    .map(|read| read.image)
                    .map_err(|e| format!("failed to read {}: {}", path, e))
            })
            .collect::<Result<Vec<_>, String>>()
    })
    .await
    .map_err(|e| SkotiqError::ImageError(format!("join error reading darks: {}", e)))?
    .map_err(SkotiqError::ImageError)?;

    let bucket = bucket_temperature(sensor_temperature_celsius);
    let dark_refs: Vec<&ImageData> = darks.iter().collect();
    let map =
        build_defect_map(&dark_refs, bucket).map_err(|e| SkotiqError::ImageError(e.to_string()))?;

    let path = defect_map_path(&camera_id, map.width, map.height, bucket);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| {
            SkotiqError::ImageError(format!(
                "failed to create defect map directory {}: {}",
                parent.display(),
                e
            ))
        })?;
    }

    let mut applied = APPLIED.lock().await;
    map.write_to_file(&path)
        .map_err(|e| SkotiqError::ImageError(e.to_string()))?;
    let status = ApiDefectMapStatus {
        camera_id,
        width: map.width,
        height: map.height,
        temperature_bucket_decicelsius: bucket,
        defective_pixel_count: map.defective_count(),
        last_rebuilt_unix_seconds: unix_seconds(std::time::SystemTime::now()),
        apply_during_capture: false,
        stored_on_disk: true,
    };
    if let Some(current) = applied
        .as_ref()
        .filter(|a| is_map(a, &status.camera_id, map.width, map.height, bucket))
    {
        let rebuilt = DefectMapApplyState {
            map: Arc::new(map),
            ..current.clone()
        };
        apply(&mut applied, Some(rebuilt)).await;
    }
    Ok(ApiDefectMapStatus {
        apply_during_capture: applies_to(&applied, &status.camera_id),
        ..status
    })
}

/// Turn correction of a camera's lights during capture on, with the map
/// stored for this sensor size and temperature, or off. `method` and
/// `kernel_diameter` (3, 5 or 7) say how a defective pixel is filled;
/// `save_original` also keeps the uncorrected frame in a `Raw/` folder
/// beside it. Applies from the next exposure.
pub async fn api_defect_map_set_correction(
    camera_id: String,
    width: u32,
    height: u32,
    sensor_temperature_celsius: f64,
    enabled: bool,
    method: String,
    kernel_diameter: u8,
    save_original: bool,
) -> Result<(), SkotiqError> {
    require_camera(&camera_id)?;
    if !enabled {
        apply(&mut *APPLIED.lock().await, None).await;
        tracing::info!("Defect map correction off (camera {})", camera_id);
        return Ok(());
    }

    let kernel = KernelSize::from_diameter(kernel_diameter).ok_or_else(|| {
        SkotiqError::InvalidParameter(format!(
            "kernel_diameter must be 3, 5, or 7; got {}",
            kernel_diameter
        ))
    })?;
    let bucket = bucket_temperature(sensor_temperature_celsius);
    let path = defect_map_path(&camera_id, width, height, bucket);

    let mut applied = APPLIED.lock().await;
    if !path.exists() {
        return Err(SkotiqError::InvalidParameter(format!(
            "No defect map is stored for {} at {}x{} and {:.1} °C; build one from darks first.",
            camera_id,
            width,
            height,
            f64::from(bucket) / 10.0,
        )));
    }
    let map =
        DefectMap::read_from_file(&path).map_err(|e| SkotiqError::ImageError(e.to_string()))?;
    let state = DefectMapApplyState {
        camera_id,
        map: Arc::new(map),
        method: CorrectionMethod::from_wire(&method),
        kernel,
        save_original,
    };
    tracing::info!(
        "Defect map correction on: camera {} ({}x{}, bucket {} dC), method {}, kernel {}, save original {}",
        state.camera_id,
        width,
        height,
        bucket,
        method,
        kernel_diameter,
        save_original,
    );
    apply(&mut applied, Some(state)).await;
    Ok(())
}

/// Delete the defect map stored for this camera, sensor size and temperature
/// bucket. When the sequencer is applying that map, correction stops from the
/// next exposure.
pub async fn api_defect_map_clear(
    camera_id: String,
    width: u32,
    height: u32,
    sensor_temperature_celsius: f64,
) -> Result<(), SkotiqError> {
    require_camera(&camera_id)?;
    let bucket = bucket_temperature(sensor_temperature_celsius);
    let path = defect_map_path(&camera_id, width, height, bucket);

    let mut applied = APPLIED.lock().await;
    if path.exists() {
        std::fs::remove_file(&path).map_err(|e| {
            SkotiqError::ImageError(format!(
                "failed to delete defect map {}: {}",
                path.display(),
                e
            ))
        })?;
    }
    if applied
        .as_ref()
        .is_some_and(|a| is_map(a, &camera_id, width, height, bucket))
    {
        apply(&mut applied, None).await;
        tracing::info!(
            "Defect map for camera {} cleared; correction off",
            camera_id
        );
    }
    Ok(())
}

/// The stored defect map for a camera at this sensor size and temperature,
/// or `None` when there is none.
pub async fn api_defect_map_get_status(
    camera_id: String,
    width: u32,
    height: u32,
    sensor_temperature_celsius: f64,
) -> Result<Option<ApiDefectMapStatus>, SkotiqError> {
    require_camera(&camera_id)?;
    let bucket = bucket_temperature(sensor_temperature_celsius);
    let path = defect_map_path(&camera_id, width, height, bucket);

    let applied = APPLIED.lock().await;
    if !path.exists() {
        return Ok(None);
    }
    let map =
        DefectMap::read_from_file(&path).map_err(|e| SkotiqError::ImageError(e.to_string()))?;
    let modified = std::fs::metadata(&path)
        .map_err(|e| {
            SkotiqError::ImageError(format!(
                "failed to stat defect map {}: {}",
                path.display(),
                e
            ))
        })?
        .modified()
        .map_or(0, unix_seconds);
    Ok(Some(ApiDefectMapStatus {
        apply_during_capture: applies_to(&applied, &camera_id),
        camera_id,
        width: map.width,
        height: map.height,
        temperature_bucket_decicelsius: map.temperature_bucket_decicelsius,
        defective_pixel_count: map.defective_count(),
        last_rebuilt_unix_seconds: modified,
        stored_on_disk: true,
    }))
}

#[cfg(test)]
mod tests;
