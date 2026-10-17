//! `TouptekCamera` state and inherent helpers.

use super::*;

// Handle wrapper for thread safety

pub(crate) struct HandleWrapper(pub(crate) HOgmacam);
// SAFETY: HOgmacam is a `*mut c_void` opaque camera handle returned by Ogmacam_Open. The struct is always wrapped in `Mutex<HandleWrapper>` in TouptekCamera; the pointer is never dereferenced or modified outside `touptek_mutex().lock().await` + `handle.lock().unwrap()` sections (see all call sites in this module — every SDK call captures the handle value while both locks are held). Marking Send is therefore equivalent to a hand-serialized capability. Sync is intentionally NOT implemented (see comment block below).
unsafe impl Send for HandleWrapper {}
// Note: Sync is intentionally omitted. HandleWrapper contains a raw pointer
// (*mut c_void) that is not safe to share via &-references across threads. The Mutex<HandleWrapper>
// provides synchronized access, and Mutex<T> only requires T: Send (not Sync) to be Sync itself.

/// Touptek camera instance
pub struct TouptekCamera {
    pub(crate) device_index: usize,
    pub(crate) device_id: String,
    /// Stable identifier returned in `OgmacamDeviceV2::id`. Unlike `device_index`, this
    /// remains bound to the same physical camera if SDK enumeration order changes.
    pub(crate) sdk_device_id: Option<String>,
    pub(crate) name: String,
    pub(crate) handle: Mutex<HandleWrapper>,
    pub(crate) connected: bool,
    pub(crate) capabilities: CameraCapabilities,
    pub(crate) sensor_info: SensorInfo,
    pub(crate) state: CameraState,
    pub(crate) current_gain: i32,
    /// Gain bounds as reported by `get_ExpoAGainRange` at connect, in the SDK's own
    /// percent-step units where 100 == 1x. `None` means the camera never reported a
    /// range, which callers must surface as unknown rather than substitute a default.
    pub(crate) gain_range: Option<(i32, i32)>,
    pub(crate) current_offset: i32,
    pub(crate) current_bin_x: i32,
    pub(crate) current_bin_y: i32,
    pub(crate) subframe: Option<SubFrame>,
    pub(crate) cooler_on: bool,
    pub(crate) target_temp: f64,
    pub(crate) exposure_duration: f64,
    pub(crate) exposure_started_at: Option<std::time::Instant>,
    pub(crate) model_flags: u64,
    /// Upper bound of the model's fan-speed scale; 0 when the model reports no fan.
    pub(crate) max_fan_speed: u32,
    /// Which brand SDK this camera uses
    pub(crate) brand: String,
    /// Heap-stable state shared with the SDK pull-mode event callback. `Some` only while
    /// pull mode is active (set in `connect()`, cleared in `disconnect()` after Stop+Close).
    pub(crate) event_state: Option<Box<TouptekEventState>>,
    /// Byte layout confirmed by get_Option after RAW/bit-depth negotiation.
    pub(crate) pull_bytes_per_pixel: usize,
    pub(crate) pull_channels: usize,
}

impl std::fmt::Debug for TouptekCamera {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TouptekCamera")
            .field("name", &self.name)
            .field("device_index", &self.device_index)
            .field("sdk_device_id", &self.sdk_device_id)
            .finish()
    }
}

impl TouptekCamera {
    /// Create a new Touptek camera instance for a specific brand
    pub fn new(device_index: usize, brand: &str) -> Self {
        let sdk_device_id = discovered_device_ids()
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(&(brand.to_ascii_lowercase(), device_index))
            .cloned();

        Self {
            device_index,
            device_id: format!("touptek_{}", device_index),
            sdk_device_id,
            name: format!("{} Camera {}", brand, device_index),
            handle: Mutex::new(HandleWrapper(std::ptr::null_mut())),
            connected: false,
            capabilities: CameraCapabilities::default(),
            sensor_info: SensorInfo::default(),
            state: CameraState::Idle,
            current_gain: 100,
            gain_range: None,
            current_offset: 0,
            current_bin_x: 1,
            current_bin_y: 1,
            subframe: None,
            cooler_on: false,
            target_temp: -10.0,
            exposure_duration: 0.0,
            exposure_started_at: None,
            model_flags: 0,
            max_fan_speed: 0,
            brand: brand.to_string(),
            event_state: None,
            pull_bytes_per_pixel: 0,
            pull_channels: 0,
        }
    }

    /// Create a new Touptek camera instance with the default OGMA brand
    /// (backward-compatible constructor)
    pub fn new_default(device_index: usize) -> Self {
        Self::new(device_index, "OGMA")
    }

    pub(crate) fn read_gain_locked(&self, handle: HOgmacam) -> Result<i32, NativeError> {
        with_sdk(&self.brand, |sdk| {
            let mut gain: u16 = 0;
            // SAFETY: caller holds touptek_mutex; `handle` is the live SDK handle
            // associated with this connected camera; `&mut gain` is a valid
            // out-pointer for the SDK's unsigned-short exposure-gain value.
            let result = unsafe { (sdk.get_expo_again)(handle, &mut gain) };
            if result < 0 {
                return Err(NativeError::SdkError(format!(
                    "Failed to read gain from Touptek camera '{}'. SDK error: {}",
                    self.name, result
                )));
            }
            Ok(i32::from(gain))
        })
    }
}
