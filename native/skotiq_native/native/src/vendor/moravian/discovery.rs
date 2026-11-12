//! Moravian device discovery.

use super::*;
use std::collections::HashMap;

#[derive(Debug, Clone)]
pub struct MoravianCameraInfo {
    pub library: Library,
    pub camera_id: u32,
    pub name: String,
    pub serial_number: Option<String>,
    pub discovery_index: usize,
}

impl MoravianCameraInfo {
    /// The device address [`MoravianCamera::from_address`] opens.
    pub fn address(&self) -> String {
        match self.library.address_tag() {
            Some(tag) => format!("{}:{}", tag, self.camera_id),
            None => self.camera_id.to_string(),
        }
    }
}

/// Cameras this process holds open, with the name and serial read at connect.
///
/// A search lists these without initializing them again: the libraries
/// describe a second initialize of an open camera as "already used" at best
/// (MoravianCameraDriver.pdf, Initialize), and the hot-plug watcher searches
/// every few minutes while a camera is exposing.
static OPEN: std::sync::Mutex<Option<HashMap<(Library, u32), NameAndSerial>>> =
    std::sync::Mutex::new(None);

type NameAndSerial = (String, Option<String>);

pub(crate) fn remember_open(camera: &MoravianCamera) {
    OPEN.lock()
        .unwrap_or_else(|e| e.into_inner())
        .get_or_insert_with(HashMap::new)
        .insert(
            (camera.library, camera.camera_id),
            (camera.core.name.clone(), camera.serial.clone()),
        );
}

pub(crate) fn forget_open(camera: &MoravianCamera) {
    if let Some(open) = OPEN.lock().unwrap_or_else(|e| e.into_inner()).as_mut() {
        open.remove(&(camera.library, camera.camera_id));
    }
}

#[cfg(test)]
pub(crate) fn forget_every_open_camera() {
    *OPEN.lock().unwrap_or_else(|e| e.into_inner()) = None;
}

fn open_camera(library: Library, id: u32) -> Option<NameAndSerial> {
    OPEN.lock()
        .unwrap_or_else(|e| e.into_inner())
        .as_ref()
        .and_then(|open| open.get(&(library, id)).cloned())
}

/// The cameras one library reports, each opened briefly for its name and
/// serial (as NINA's MoravianCameraProvider does) unless this process has it open.
pub(crate) fn list_cameras(api: &dyn Api) -> Vec<MoravianCameraInfo> {
    let library = api.library();
    let mut cameras = Vec::new();
    for (index, id) in api.enumerate().into_iter().enumerate() {
        let (name, serial_number) = match open_camera(library, id) {
            Some(known) => known,
            None => {
                let Some(handle) = api.initialize(id) else {
                    tracing::warn!(
                        "Moravian {}: camera {} is listed but could not be opened (another program may have it)",
                        library.file_name(),
                        id
                    );
                    continue;
                };
                // SAFETY: `handle` was just returned by this library's initialize.
                let session = unsafe { Session::new(api, handle) };
                let name = session
                    .string(GSP_CAMERA_DESCRIPTION)
                    .filter(|n| !n.is_empty())
                    .unwrap_or_else(|| format!("Moravian Camera {}", id));
                let serial = session.string(GSP_CAMERA_SERIAL).filter(|s| !s.is_empty());
                session.release();
                (name, serial)
            }
        };
        cameras.push(MoravianCameraInfo {
            library,
            camera_id: id,
            name,
            serial_number,
            discovery_index: index,
        });
    }
    cameras
}

pub async fn discover_devices() -> Result<Vec<MoravianCameraInfo>, DriverError> {
    let mut cameras = Vec::new();
    let mut last_error = None;
    for &library in Library::on_this_platform() {
        match library.lock().await {
            Ok(sdk) => cameras.extend(list_cameras(sdk.api())),
            Err(error) => last_error = Some(error),
        }
    }
    match last_error {
        Some(error) if cameras.is_empty() && !is_sdk_available() => Err(error),
        _ => Ok(cameras),
    }
}

pub fn is_sdk_available() -> bool {
    Library::on_this_platform()
        .iter()
        .any(|library| library.is_available())
}
