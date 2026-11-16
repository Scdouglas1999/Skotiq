//! Captures a camera kept because their file did not become a frame, and
//! what its driver has to tell the user.
//!
//! A failed download or an undecodable raw file fails that one exposure and
//! nothing else: the capture is recorded here with where it is, the user is
//! told, and the camera goes on to the next exposure. A file the driver has
//! in hand is saved at once; one still on the camera is read when the user
//! asks for it. The record lives with the device manager, not the driver, so
//! a file on the camera's card can still be retrieved after a reconnect.

use crate::device_manager::{rig, DeviceManager};
use crate::dispatch::error::DeviceOpError;
use crate::event::equipment::{EquipmentEvent, EventSeverity};
use std::path::PathBuf;

/// One capture kept on a camera, as the app lists it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RetainedCaptureRecord {
    pub device_id: String,
    pub camera_name: String,
    /// Where the file is on the camera.
    pub location: String,
    /// In the camera's memory rather than on its card: gone when the camera
    /// is switched off or disconnected, and a later exposure can take its
    /// place.
    pub in_camera_memory: bool,
    /// Why the capture did not become a frame.
    pub reason: String,
    /// When it was recorded, in milliseconds since the Unix epoch (UTC).
    pub retained_at_ms: i64,
}

/// Where retrieved and undecodable camera files are saved.
fn retained_captures_dir() -> PathBuf {
    // SKOTIQ_DATA_DIR is the application data path the app sets at launch.
    // Without it (unit tests) the files go to the temp folder.
    std::env::var_os("SKOTIQ_DATA_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::temp_dir().join("skotiq"))
        .join("retained_captures")
}

/// Save a camera file under a name no earlier file has.
fn save_camera_file(file: &skotiq_device::CameraFile) -> Result<PathBuf, DeviceOpError> {
    let dir = retained_captures_dir();
    let failed = |what: &str, e: std::io::Error| {
        DeviceOpError::hardware(None, format!("{what} {}: {e}", dir.display()))
    };
    std::fs::create_dir_all(&dir).map_err(|e| failed("Could not create", e))?;
    let stamp = chrono::Utc::now().format("%Y%m%d-%H%M%S");
    let name: String = file
        .file_name
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_') {
                c
            } else {
                '_'
            }
        })
        .collect();
    let mut path = dir.join(format!("{stamp}_{name}"));
    let mut copy = 1;
    while path.exists() {
        copy += 1;
        path = dir.join(format!("{stamp}_{copy}_{name}"));
    }
    std::fs::write(&path, file.bytes.as_slice()).map_err(|e| failed("Could not write to", e))?;
    Ok(path)
}

impl DeviceManager {
    /// After an exposure is started or a frame is read: pass on what the
    /// driver has to tell the user, and record the captures it kept.
    pub(crate) async fn relay_camera_reports(
        &self,
        device_id: &str,
        camera: &dyn rig::camera::Camera,
    ) {
        for notice in camera.take_notices().await {
            self.publish_notice(&notice.title, notice.message);
        }
        let kept = camera.retained_captures().await;
        if kept.is_empty() {
            return;
        }
        let camera_name = self
            .devices
            .read()
            .await
            .get(device_id)
            .map_or_else(|| device_id.to_string(), |d| d.info.shown_name());
        let mut changed = false;
        for capture in kept {
            if capture.in_hand {
                // The driver has the file (it would not decode, or it was
                // read on a later try): save it as the camera made it, so
                // nothing depends on the camera any more.
                let saved = match camera.retrieve_capture(&capture.location).await {
                    Ok(file) => save_camera_file(&file),
                    Err(e) => Err(e),
                };
                changed |= self.forget_retained(device_id, &capture.location);
                match saved {
                    Ok(path) => self.publish_notice(
                        "Camera file saved",
                        format!(
                            "A capture from {camera_name} did not become a frame ({}). The \
                             camera's own file is saved at {}. The run goes on.",
                            capture.reason,
                            path.display()
                        ),
                    ),
                    Err(e) => self.publish_notice(
                        "Capture could not be saved",
                        format!(
                            "A capture from {camera_name} did not become a frame ({}), and \
                             its file could not be saved: {e}",
                            capture.reason
                        ),
                    ),
                }
                continue;
            }
            let is_new = {
                let mut records = self
                    .retained_captures
                    .lock()
                    .unwrap_or_else(|e| e.into_inner());
                let known = records
                    .iter()
                    .any(|r| r.device_id == device_id && r.location == capture.location);
                if !known {
                    records.push(RetainedCaptureRecord {
                        device_id: device_id.to_string(),
                        camera_name: camera_name.clone(),
                        location: capture.location.clone(),
                        in_camera_memory: capture.in_camera_memory,
                        reason: capture.reason.clone(),
                        retained_at_ms: chrono::Utc::now().timestamp_millis(),
                    });
                }
                !known
            };
            if is_new {
                changed = true;
                let place = if capture.in_camera_memory {
                    "in the camera's memory, where a later exposure can take its place and \
                     which is cleared when the camera is switched off"
                } else {
                    "on the camera's card"
                };
                self.publish_notice(
                    "Capture kept on the camera",
                    format!(
                        "A capture from {camera_name} could not be downloaded ({}). It is \
                         {place}, at {}. The run goes on. Retrieve it from the camera's panel \
                         when the camera is idle.",
                        capture.reason, capture.location
                    ),
                );
            }
        }
        if changed {
            self.publish_retained_captures_changed(device_id);
        }
    }

    fn forget_retained(&self, device_id: &str, location: &str) -> bool {
        let mut records = self
            .retained_captures
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        let before = records.len();
        records.retain(|r| !(r.device_id == device_id && r.location == location));
        records.len() != before
    }

    fn publish_retained_captures_changed(&self, device_id: &str) {
        let count = self
            .retained_captures
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .iter()
            .filter(|r| r.device_id == device_id)
            .count();
        self.app_state.publish_equipment_event(
            EquipmentEvent::CameraRetainedCapturesChanged {
                device_id: device_id.to_string(),
                count: count as u32,
            },
            EventSeverity::Info,
        );
    }

    /// Every capture a camera is still keeping, oldest first.
    pub fn camera_retained_captures(&self) -> Vec<RetainedCaptureRecord> {
        self.retained_captures
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
    }

    /// Read a retained capture off its camera and save the camera's file.
    /// Answers the path it was saved to. A file that is no longer on the
    /// camera (its memory was cleared) is dropped from the list and the
    /// error says so.
    pub async fn camera_retrieve_retained_capture(
        &self,
        device_id: &str,
        location: &str,
    ) -> Result<String, DeviceOpError> {
        let camera = self.camera(device_id).await?;
        let file = match camera.retrieve_capture(location).await {
            Ok(file) => file,
            Err(e) => {
                let in_memory = self
                    .retained_captures
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .iter()
                    .any(|r| {
                        r.device_id == device_id && r.location == location && r.in_camera_memory
                    });
                // A memory file that the camera no longer lists cannot come back.
                if in_memory
                    && e.to_string().to_ascii_lowercase().contains("not found")
                    && self.forget_retained(device_id, location)
                {
                    self.publish_retained_captures_changed(device_id);
                }
                return Err(e);
            }
        };
        let path = save_camera_file(&file)?;
        if self.forget_retained(device_id, location) {
            self.publish_retained_captures_changed(device_id);
        }
        tracing::info!(
            "Retained capture {location} from {device_id} saved to {}",
            path.display()
        );
        Ok(path.to_string_lossy().into_owned())
    }
}
