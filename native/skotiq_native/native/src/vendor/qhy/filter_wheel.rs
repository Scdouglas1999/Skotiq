//! QHY CFW filter wheel on a camera's 4-pin CFW port, and its discovery.
//!
//! The wheel is driven through the camera's SDK handle: `SetQHYCCDParam(
//! CONTROL_CFWPORT, c)` sends the one-character order `c` ('0'..'9', 'A'..'F')
//! and `GetQHYCCDParam(CONTROL_CFWPORT)` returns the first character of the
//! wheel's status reply (the SDK maps both onto SendOrder2QHYCCDCFW and
//! GetQHYCCDCFWStatus, which INDI calls). The camera and the wheel share one
//! open handle, see [`session`].

use super::*;

pub(crate) const MAX_QHY_CFW_SLOTS: i32 = 16;
pub(crate) const QHY_CFW_MOVE_TIMEOUT: Duration = Duration::from_secs(25);
pub(crate) const QHY_CFW_POLL_INTERVAL: Duration = Duration::from_millis(500);

/// A slot count from `CONTROL_CFWSLOTSNUM`. Above 16 (INDI sees 255) means the
/// port answers but no wheel is attached.
pub(crate) fn parse_cfw_slot_count(count: f64) -> Option<i32> {
    (count.is_finite() && count.fract() == 0.0 && (1.0..=f64::from(MAX_QHY_CFW_SLOTS)).contains(&count))
        .then_some(count as i32)
}

/// A wheel status character as a 0-based slot, or `None` for anything else
/// (the wheel is still turning, or the SDK answered with its error value).
pub(crate) fn parse_cfw_position(status: f64) -> Option<i32> {
    if !status.is_finite() || status.fract() != 0.0 || !(0.0..=255.0).contains(&status) {
        return None;
    }
    match status as u8 {
        c @ b'0'..=b'9' => Some(i32::from(c - b'0')),
        c @ b'A'..=b'F' => Some(i32::from(c - b'A') + 10),
        c @ b'a'..=b'f' => Some(i32::from(c - b'a') + 10),
        _ => None,
    }
}

pub(crate) fn encode_cfw_position(position: i32) -> f64 {
    let value = match position {
        0..=9 => b'0' + position as u8,
        10..=15 => b'A' + (position - 10) as u8,
        _ => unreachable!("CFW position was validated against the 16-slot maximum"),
    };
    f64::from(value)
}

/// The wheel's slot count, when one is attached to the camera behind `handle`.
///
/// INDI asks `IsQHYCCDCFWPlugged` up to three times 200 ms apart ("sometimes
/// the filter is not picked up") and reads the slot count a second time after
/// 500 ms when the first is out of range. Blocks for those pauses.
pub(crate) fn attached_wheel(sdk: &QhySdk, handle: QhyCamHandle) -> Option<i32> {
    let mut plugged = false;
    for attempt in 0..3 {
        if attempt > 0 {
            std::thread::sleep(Duration::from_millis(200));
        }
        // SAFETY: `handle` is open and the caller holds the SDK lock.
        if unsafe { (sdk.is_qhyccd_cfw_plugged)(handle) } == QHYCCD_SUCCESS {
            plugged = true;
            break;
        }
    }
    if !plugged {
        return None;
    }
    let read_slots = || {
        // SAFETY: as above.
        unsafe { (sdk.get_qhyccd_param)(handle, QhyControl::CONTROL_CFWSLOTSNUM as c_int) }
    };
    if let Some(slots) = parse_cfw_slot_count(read_slots()) {
        return Some(slots);
    }
    std::thread::sleep(Duration::from_millis(500));
    parse_cfw_slot_count(read_slots())
}

pub struct QhyFilterWheelInfo {
    /// Camera ID that the filter wheel is attached to
    pub camera_id: String,
    pub name: String,
    pub slot_count: i32,
    /// QHY SDK version reported by the loaded native library, when available
    pub sdk_version: Option<String>,
}

/// QHY Filter Wheel implementation
#[derive(Debug)]
pub struct QhyFilterWheel {
    pub(crate) camera_id: String,
    pub(crate) device_id: String,
    pub(crate) name: String,
    pub(crate) handle: Option<QhyCamHandle>,
    pub(crate) connected: bool,
    pub(crate) slot_count: i32,
    pub(crate) filter_names: Vec<String>,
    pub(crate) target_position: Option<i32>,
}

// SAFETY: the raw `QhyCamHandle` is only passed to the SDK while its lock
// guard is held; the wheel shares the camera SDK's lock.
unsafe impl Send for QhyFilterWheel {}
// SAFETY: as for `Send`.
unsafe impl Sync for QhyFilterWheel {}

impl QhyFilterWheel {
    pub fn new(camera_id: String) -> Self {
        let (model_name, _) = QhyCameraInfo::parse_id(&camera_id);
        let name = format!("{} CFW", model_name);
        let device_id = format!("native:qhy_cfw:{}", camera_id);
        Self {
            camera_id,
            device_id,
            name,
            handle: None,
            connected: false,
            slot_count: 0,
            filter_names: Vec::new(),
            target_position: None,
        }
    }

    /// The slot under the light path, or `None` while the wheel turns.
    pub(crate) fn read_position(&self, sdk: &QhySdk) -> Result<Option<i32>, DriverError> {
        let handle = self.handle.ok_or(DriverError::NotConnected)?;
        // SAFETY: `handle` is open in the camera's session and the SDK lock is held.
        let status =
            unsafe { (sdk.get_qhyccd_param)(handle, QhyControl::CONTROL_CFWPORT as c_int) };
        Ok(parse_cfw_position(status).filter(|slot| *slot < self.slot_count))
    }

    /// Wait until the wheel reports a slot (it turns after power-on and after
    /// every order), or `QHY_CFW_MOVE_TIMEOUT`.
    async fn settled_position(&self, wanted: Option<i32>) -> Result<i32, DriverError> {
        let started = Instant::now();
        loop {
            let position = {
                let sdk = QhySdk::lock().await?;
                self.read_position(&sdk)?
            };
            match (position, wanted) {
                (Some(slot), None) => return Ok(slot),
                (Some(slot), Some(target)) if slot == target => return Ok(slot),
                _ => {}
            }
            let elapsed = started.elapsed();
            if elapsed >= QHY_CFW_MOVE_TIMEOUT {
                let at = position.map_or_else(|| "still turning".to_string(), |p| format!("at slot {}", p + 1));
                let goal = wanted.map_or_else(|| "come to rest".to_string(), |t| format!("reach slot {}", t + 1));
                return Err(DriverError::Timeout(format!(
                    "The QHY filter wheel did not {goal} within {} s ({at}). Check the wheel's cable \
                     to the camera and that nothing blocks it.",
                    QHY_CFW_MOVE_TIMEOUT.as_secs()
                )));
            }
            tokio::time::sleep(QHY_CFW_POLL_INTERVAL.min(QHY_CFW_MOVE_TIMEOUT - elapsed)).await;
        }
    }

    fn release(&mut self, sdk: &QhySdk) {
        if self.handle.take().is_some() {
            session::leave(sdk, &self.camera_id);
        }
    }
}

#[async_trait]
impl DeviceDriver for QhyFilterWheel {
    fn id(&self) -> &str {
        &self.device_id
    }

    fn name(&self) -> &str {
        &self.name
    }

    fn vendor(&self) -> Vendor {
        Vendor::Qhy
    }

    fn is_connected(&self) -> bool {
        self.connected
    }

    async fn connect(&mut self) -> Result<(), DriverError> {
        if self.connected {
            return Ok(());
        }
        QhySdk::ensure_initialized()?;
        {
            let sdk = QhySdk::lock().await?;
            let (handle, _) = session::join(&sdk, &self.camera_id)?;
            self.handle = Some(handle);
            let handle = crate::camera_core::SdkHandle(handle);
            let (sdk, slots) = tokio::task::spawn_blocking(move || {
                let handle = handle;
                let slots = attached_wheel(&sdk, handle.0);
                (sdk, slots)
            })
            .await
            .map_err(|e| DriverError::SdkError(format!("QHY CFW probe stopped: {e}")))?;
            let Some(slots) = slots else {
                self.release(&sdk);
                return Err(DriverError::DeviceNotFound(format!(
                    "No filter wheel answers on the CFW port of QHY camera {}. Check the \
                     wheel's cable to the camera and the wheel's power.",
                    self.camera_id
                )));
            };
            self.slot_count = slots;
        }
        let position = match self.settled_position(None).await {
            Ok(position) => position,
            Err(error) => {
                let sdk = QhySdk::lock().await?;
                self.release(&sdk);
                return Err(error);
            }
        };
        self.filter_names = (0..self.slot_count)
            .map(|i| format!("Filter {}", i + 1))
            .collect();
        self.target_position = Some(position);
        self.connected = true;
        tracing::info!(
            "Connected to the QHY CFW on {} with {} slots, at slot {}",
            self.camera_id,
            self.slot_count,
            position + 1
        );
        Ok(())
    }

    async fn disconnect(&mut self) -> Result<(), DriverError> {
        if !self.connected {
            return Ok(());
        }
        let lock = QhySdk::slot().lock_before_load().await;
        if let Ok(sdk) = lock.table() {
            self.release(sdk);
        }
        self.handle = None;
        self.connected = false;
        self.target_position = None;
        tracing::info!("Disconnected from the QHY CFW on {}", self.camera_id);
        Ok(())
    }
}

#[async_trait]
impl FilterWheelDriver for QhyFilterWheel {
    async fn get_filter_count(&self) -> i32 {
        self.slot_count
    }

    /// The slot, or -1 while the wheel turns (the ASCOM convention).
    async fn get_position(&self) -> Result<i32, DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }
        let sdk = QhySdk::lock().await?;
        Ok(self.read_position(&sdk)?.unwrap_or(-1))
    }

    async fn move_to_position(&mut self, position: i32) -> Result<(), DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }
        if position < 0 || position >= self.slot_count {
            return Err(DriverError::InvalidParameter(format!(
                "Position {} out of range (0-{})",
                position,
                self.slot_count - 1
            )));
        }
        tracing::info!("Moving QHY CFW to position {}", position);
        {
            let sdk = QhySdk::lock().await?;
            let handle = self.handle.ok_or(DriverError::NotConnected)?;
            // SAFETY: `handle` is open in the camera's session and the SDK lock is held.
            let result = unsafe {
                (sdk.set_qhyccd_param)(
                    handle,
                    QhyControl::CONTROL_CFWPORT as c_int,
                    encode_cfw_position(position),
                )
            };
            check_qhy_error(result, &format!("send its filter wheel to slot {}", position + 1))?;
        }
        self.target_position = Some(position);
        self.settled_position(Some(position)).await?;
        Ok(())
    }

    async fn is_moving(&self) -> Result<bool, DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }
        let sdk = QhySdk::lock().await?;
        let position = self.read_position(&sdk)?;
        Ok(position.is_none() || position != self.target_position)
    }

    async fn get_filter_names(&self) -> Result<Vec<String>, DriverError> {
        Ok(self.filter_names.clone())
    }

    async fn set_filter_name(&mut self, position: i32, name: String) -> Result<(), DriverError> {
        if position < 0 || position >= self.slot_count {
            return Err(DriverError::InvalidParameter(format!(
                "Position {} out of range (0-{})",
                position,
                self.slot_count - 1
            )));
        }
        // Bounds checked above; filter_names holds slot_count entries.
        self.filter_names[position as usize] = name;
        Ok(())
    }
}

/// The cameras with a wheel on their CFW port. A camera that a driver holds
/// is asked through its open handle; any other is opened for the question and
/// closed again.
pub(crate) fn discover_filter_wheels_internal(sdk: &QhySdk) -> Vec<QhyFilterWheelInfo> {
    let sdk_version = sdk_version_from_sdk(sdk);
    let mut filter_wheels = Vec::new();
    for camera_id in session::scan(sdk) {
        let (handle, opened_here) = match session::current(&camera_id) {
            Some(handle) => (handle, false),
            None => match session::open_listed(sdk, &camera_id) {
                Ok(handle) => (handle, true),
                Err(error) => {
                    tracing::debug!("QHY CFW discovery skipped {camera_id}: {error}");
                    continue;
                }
            },
        };
        let slots = attached_wheel(sdk, handle);
        if opened_here {
            // SAFETY: opened above for this question; no driver holds it.
            unsafe { (sdk.close_qhyccd)(handle) };
        }
        let Some(slot_count) = slots else {
            continue;
        };
        let (model_name, _) = QhyCameraInfo::parse_id(&camera_id);
        tracing::info!("Found QHY CFW on camera {camera_id} with {slot_count} slots");
        filter_wheels.push(QhyFilterWheelInfo {
            camera_id,
            name: format!("{} CFW", model_name),
            slot_count,
            sdk_version: sdk_version.clone(),
        });
    }
    filter_wheels
}

/// Discover QHY filter wheels (CFW attached to cameras), with the safety
/// measures of [`discover_devices`]. The search runs on a blocking thread
/// that owns the SDK lock until the SDK returns, even after a timeout: it may
/// use the handle of a camera a driver holds.
pub async fn discover_filter_wheels() -> Result<Vec<QhyFilterWheelInfo>, DriverError> {
    let config = get_discovery_config();
    if !config.enabled {
        tracing::debug!("QHY discovery is disabled, returning empty filter wheel list");
        return Ok(Vec::new());
    }
    QhySdk::ensure_initialized()?;
    let sdk = QhySdk::lock().await?;
    let search = tokio::task::spawn_blocking(move || {
        catch_unwind(AssertUnwindSafe(|| discover_filter_wheels_internal(&sdk)))
    });
    match tokio::time::timeout(Duration::from_millis(config.timeout_ms), search).await {
        Ok(Ok(Ok(wheels))) => Ok(wheels),
        Ok(Ok(Err(panic))) => Err(DriverError::SdkError(format!(
            "QHY CFW discovery failed: {}",
            panic_text(&panic)
        ))),
        Ok(Err(e)) => Err(DriverError::SdkError(format!(
            "QHY CFW discovery task failed: {e}"
        ))),
        Err(_) => {
            tracing::error!("QHY CFW discovery timed out after {}ms", config.timeout_ms);
            Err(DriverError::Timeout(format!(
                "QHY CFW discovery timed out after {}ms",
                config.timeout_ms
            )))
        }
    }
}
