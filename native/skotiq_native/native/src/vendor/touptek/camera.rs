//! `TouptekCamera` state and inherent helpers.

use super::*;

pub struct TouptekCamera {
    pub(crate) device_index: usize,
    /// Stable identifier returned in `OgmacamDeviceV2::id`. Unlike `device_index`, this
    /// remains bound to the same physical camera if SDK enumeration order changes.
    pub(crate) sdk_device_id: Option<String>,
    /// `core.gain` starts at 100 (1x) and is replaced at connect by the camera's
    /// default gain, or its live gain when it reports no range. `core.subframe` is
    /// the region the sensor reads out, in binned pixels, after the SDK's alignment.
    pub(crate) core: CameraCore,
    /// The open camera; null while disconnected. Read and replaced only with
    /// `TOUPTEK_SDK_LOCK` held.
    pub(crate) handle: SdkHandle<HOgmacam>,
    pub(crate) serial_number: Option<String>,
    /// Gain bounds as reported by `get_ExpoAGainRange` at connect, in the SDK's own
    /// percent-step units where 100 == 1x. `None` means the camera never reported a
    /// range, which callers must surface as unknown rather than substitute a default.
    pub(crate) gain_range: Option<(i32, i32)>,
    /// Exposure bounds from `get_ExpTimeRange`, in microseconds.
    pub(crate) exposure_range_us: Option<(u32, u32)>,
    /// Highest black level the camera takes; `None` when it has no black level control.
    pub(crate) black_level_max: Option<i32>,
    /// Cooler set-point range in degrees C from `OPTION_TECTARGET_RANGE`.
    pub(crate) cooler_target_range: Option<(f64, f64)>,
    /// TEC voltage at full power, in 0.1 V; `None` when the camera does not report it.
    pub(crate) tec_voltage_max: Option<i32>,
    /// Last cooler power read and when, so the TEC voltage is read at most every 2 s.
    pub(crate) cooler_power_read: std::sync::Mutex<Option<(std::time::Instant, f64)>>,
    pub(crate) model_flags: u64,
    /// Upper bound of the model's fan-speed scale; 0 when the model reports no fan.
    pub(crate) max_fan_speed: u32,
    /// Which brand SDK this camera uses
    pub(crate) brand: String,
    /// Heap-stable state shared with the SDK pull-mode event callback. `Some` only while
    /// pull mode is active (set in `connect()`, cleared in `disconnect()` after Stop+Close).
    pub(crate) event_state: Option<Box<TouptekEventState>>,
    /// Bytes per pulled sample: 2 at more than 8 bits, 1 for an 8-bit readout; 0 while
    /// not streaming.
    pub(crate) bytes_per_sample: usize,
    /// The SDK delivers rows bottom first (an SDK too old to be told otherwise, on
    /// Windows). ROI rows are then counted from the bottom and frames are flipped.
    pub(crate) rows_reversed: bool,
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

/// The 2 s the SDK asks for between TEC voltage reads.
const COOLER_POWER_READ_INTERVAL: std::time::Duration = std::time::Duration::from_secs(2);

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
            serial_number: None,
            gain_range: None,
            exposure_range_us: None,
            black_level_max: None,
            cooler_target_range: None,
            tec_voltage_max: None,
            cooler_power_read: std::sync::Mutex::new(None),
            model_flags: 0,
            max_fan_speed: 0,
            brand: brand.to_string(),
            event_state: None,
            bytes_per_sample: 0,
            rows_reversed: false,
        }
    }

    pub(crate) fn has_thermometer(&self) -> bool {
        (self.model_flags & OGMACAM_FLAG_GETTEMPERATURE) != 0
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
                return Err(touptek_failure("read the gain", &self.core.name, result));
            }
            Ok(i32::from(gain))
        })
    }

    /// The sensor temperature, `None` for a model without a thermometer.
    pub(crate) fn read_temperature_locked(
        &self,
        lock: &SdkLockHeld,
        handle: HOgmacam,
    ) -> Result<Option<f64>, DriverError> {
        if !self.has_thermometer() {
            return Ok(None);
        }
        with_sdk(lock, &self.brand, |sdk| {
            let mut temp: i16 = 0;
            // SAFETY: `handle` is this connected camera's live handle; `&mut temp` is a valid
            // stack out-pointer for the 0.1 C reading Ogmacam_get_Temperature writes.
            let result = unsafe { (sdk.get_temperature)(handle, &mut temp) };
            touptek_temperature_result(&self.core.name, result, temp)
        })
    }

    /// An integer option; `None` when the camera does not answer it.
    pub(crate) fn read_option_locked(
        &self,
        lock: &SdkLockHeld,
        handle: HOgmacam,
        option: c_uint,
    ) -> Option<c_int> {
        with_sdk(lock, &self.brand, |sdk| {
            Ok(read_option(sdk, handle, option).ok())
        })
        .ok()
        .flatten()
    }

    /// Cooler on/off as the camera reports it, kept in the core; the last known
    /// state when the read fails.
    pub(crate) fn refresh_cooler_locked(&self, lock: &SdkLockHeld, handle: HOgmacam) -> bool {
        if let Some(value) = self.read_option_locked(lock, handle, OGMACAM_OPTION_TEC) {
            self.core
                .update_cooler(|cooler| cooler.enabled = value != 0);
        }
        self.core.cooler().enabled
    }

    /// Cooler power in percent from the TEC voltage, read at most every 2 s.
    pub(crate) fn cooler_power_locked(&self, lock: &SdkLockHeld, handle: HOgmacam) -> Option<f64> {
        let max = self.tec_voltage_max?;
        let mut last = self
            .cooler_power_read
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        if let Some((at, power)) = *last {
            if at.elapsed() < COOLER_POWER_READ_INTERVAL {
                return Some(power);
            }
        }
        let voltage = self.read_option_locked(lock, handle, OGMACAM_OPTION_TEC_VOLTAGE)?;
        let power = (f64::from(voltage) * 100.0 / f64::from(max)).clamp(0.0, 100.0);
        *last = Some((std::time::Instant::now(), power));
        Some(power)
    }

    pub(crate) fn forget_cooler_power(&self) {
        *self
            .cooler_power_read
            .lock()
            .unwrap_or_else(|e| e.into_inner()) = None;
    }
}

pub(crate) fn read_option(
    sdk: &TouptekSdk,
    handle: HOgmacam,
    option: c_uint,
) -> Result<c_int, i32> {
    let mut value: c_int = 0;
    // SAFETY: the caller holds the SDK lock through `with_sdk`; `handle` is an open camera
    // handle and `&mut value` a valid stack out-pointer for get_Option.
    let rc = unsafe { (sdk.get_option)(handle, option, &mut value) };
    if rc < 0 {
        Err(rc)
    } else {
        Ok(value)
    }
}

/// The sensor region, top row first, that covers a subframe given in binned pixels.
///
/// The SDK counts ROI coordinates in unbinned sensor pixels and needs an even
/// origin and an even size of at least 16 pixels. The region grows to the
/// nearest one the sensor can read that still covers the request, and stays
/// on the sensor.
pub(crate) fn sensor_roi(
    subframe: &SubFrame,
    bin: u32,
    sensor_width: u32,
    sensor_height: u32,
) -> (u32, u32, u32, u32) {
    let bin = bin.max(1);
    let axis = |start: u32, length: u32, sensor: u32| -> (u32, u32) {
        let sensor = sensor & !1;
        let from = start.saturating_mul(bin) & !1;
        let to = start
            .saturating_add(length)
            .saturating_mul(bin)
            .saturating_add(1)
            & !1;
        let length = to.saturating_sub(from).max(16).min(sensor);
        (from.min(sensor - length), length)
    };
    let (x, width) = axis(subframe.start_x, subframe.width, sensor_width);
    let (y, height) = axis(subframe.start_y, subframe.height, sensor_height);
    (x, y, width, height)
}

/// Rows of a frame in the opposite order.
pub(crate) fn flip_rows(data: &mut [u16], width: usize) {
    if width == 0 {
        return;
    }
    let rows = data.len() / width;
    for row in 0..rows / 2 {
        let (top, bottom) = data.split_at_mut((rows - 1 - row) * width);
        top[row * width..(row + 1) * width].swap_with_slice(&mut bottom[..width]);
    }
}
