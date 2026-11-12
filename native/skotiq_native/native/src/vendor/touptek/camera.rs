//! `TouptekCamera` state and inherent helpers.

use super::*;

pub struct TouptekCamera {
    pub(crate) device_index: usize,
    /// Stable identifier returned in `OgmacamDeviceV2::id`. Unlike `device_index`, this
    /// remains bound to the same physical camera if SDK enumeration order changes.
    pub(crate) sdk_device_id: Option<String>,
    /// `core.gain` starts at 100 (1x) and is replaced at connect by the camera's
    /// default gain, or its live gain when it reports no range.
    pub(crate) core: CameraCore,
    /// The open camera; null while disconnected. Read and replaced only with
    /// `TOUPTEK_SDK_LOCK` held.
    pub(crate) handle: SdkHandle<HOgmacam>,
    /// Gain bounds as reported by `get_ExpoAGainRange` at connect, in the SDK's own
    /// percent-step units where 100 == 1x. `None` means the camera never reported a
    /// range, which callers must surface as unknown rather than substitute a default.
    pub(crate) gain_range: Option<(i32, i32)>,
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
            .field("name", &self.core.name)
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

        let mut core = CameraCore::new(
            format!("touptek_{}", device_index),
            format!("{} Camera {}", brand, device_index),
            -10.0,
        );
        core.gain = 100;
        Self {
            device_index,
            sdk_device_id,
            core,
            handle: SdkHandle(std::ptr::null_mut()),
            gain_range: None,
            model_flags: 0,
            max_fan_speed: 0,
            brand: brand.to_string(),
            event_state: None,
            pull_bytes_per_pixel: 0,
            pull_channels: 0,
        }
    }

    pub(crate) fn read_gain_locked(
        &self,
        lock: &SdkLockHeld,
        handle: HOgmacam,
    ) -> Result<i32, DriverError> {
        with_sdk(lock, &self.brand, |sdk| {
            let mut gain: u16 = 0;
            // SAFETY: `handle` is the live SDK handle
            // associated with this connected camera; `&mut gain` is a valid
            // out-pointer for the SDK's unsigned-short exposure-gain value.
            let result = unsafe { (sdk.get_expo_again)(handle, &mut gain) };
            if result < 0 {
                return Err(DriverError::SdkError(format!(
                    "Failed to read gain from Touptek camera '{}'. SDK error: {}",
                    self.core.name, result
                )));
            }
            Ok(i32::from(gain))
        })
    }
}
