//! Atik EFW filter wheel implementation.

use super::*;

/// Atik standalone EFW filter wheel native driver.
pub struct AtikFilterWheel {
    pub(crate) device_index: c_int,
    pub(crate) serial_number: Option<String>,
    pub(crate) device_id: String,
    pub(crate) name: String,
    pub(crate) handle: SdkHandle<ArtemisHandle>,
    pub(crate) connected: bool,
    pub(crate) filter_count: i32,
}

impl std::fmt::Debug for AtikFilterWheel {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AtikFilterWheel")
            .field("device_index", &self.device_index)
            .field("serial_number", &self.serial_number)
            .field("name", &self.name)
            .field("connected", &self.connected)
            .field("filter_count", &self.filter_count)
            .finish()
    }
}

impl AtikFilterWheel {
    /// Create a new Atik EFW filter wheel instance from a discovery index.
    pub fn new(device_index: i32) -> Self {
        let serial_number = discovered_efw_serials()
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(&device_index)
            .cloned();
        Self {
            device_index,
            serial_number,
            device_id: format!("atik_efw_{}", device_index),
            name: format!("Atik EFW {}", device_index),
            handle: SdkHandle(std::ptr::null_mut()),
            connected: false,
            filter_count: 0,
        }
    }

    /// Opens the wheel. The caller holds the SDK lock.
    pub(crate) fn open(&mut self, sdk: &AtikSdk) -> Result<(), DriverError> {
        if self.connected {
            return Ok(());
        }
        let efw = sdk.efw()?;
        let index = efw_index_now(&efw, self.device_index, self.serial_number.as_deref())?;
        let label = match &self.serial_number {
            Some(serial) => format!("Atik filter wheel {serial}"),
            None => format!("Atik filter wheel at index {index}"),
        };
        // SAFETY: plain int argument; the result is null-checked below.
        let handle = unsafe { (efw.connect)(index) };
        if handle.is_null() {
            return Err(DriverError::SdkError(format!(
                "{label} could not be opened. Another program may be using it."
            )));
        }
        let release = |error: DriverError| {
            // SAFETY: `handle` came from ArtemisEFWConnect above and is released once.
            unsafe { (efw.disconnect)(handle) };
            Err(error)
        };
        // SAFETY: the handle was just returned by ArtemisEFWConnect.
        if !unsafe { (efw.is_connected)(handle) } {
            return release(DriverError::SdkError(format!(
                "{label} did not stay connected after it was opened"
            )));
        }
        let mut filter_count: c_int = 0;
        // SAFETY: the handle is open and `filter_count` is a valid out-pointer.
        let result = unsafe { (efw.nmr_position)(handle, &mut filter_count) };
        if let Err(error) = check_artemis_error(result, "read the number of filter positions") {
            return release(error);
        }
        if filter_count <= 0 {
            return release(DriverError::SdkError(format!(
                "{label} reported {filter_count} filter positions"
            )));
        }
        if let Some((efw_type, _)) = efw_at(&efw, index) {
            self.name = atik_efw_type_name(efw_type);
        }
        self.handle = SdkHandle(handle);
        self.device_index = index;
        self.filter_count = filter_count;
        self.connected = true;
        Ok(())
    }

    /// Position and whether the wheel is turning. The caller holds the SDK lock.
    pub(crate) fn read_position(&self, sdk: &AtikSdk) -> Result<(i32, bool), DriverError> {
        let efw = sdk.efw()?;
        let (mut position, mut moving): (c_int, bool) = (-1, false);
        // SAFETY: the handle is open and both out-pointers are valid.
        let result = unsafe { (efw.get_position)(self.handle.0, &mut position, &mut moving) };
        check_artemis_error(result, "read the filter position")?;
        Ok((position, moving))
    }
}

#[async_trait]
impl DeviceDriver for AtikFilterWheel {
    fn id(&self) -> &str {
        &self.device_id
    }

    fn name(&self) -> &str {
        &self.name
    }

    fn vendor(&self) -> Vendor {
        Vendor::Atik
    }

    fn serial_number(&self) -> Option<String> {
        self.serial_number.clone()
    }

    fn is_connected(&self) -> bool {
        self.connected
    }

    async fn connect(&mut self) -> Result<(), DriverError> {
        if self.connected {
            return Ok(());
        }
        let loaded = AtikSdk::installed()?;
        // Unlocked on purpose: this only reads which optional entry points the
        // library exports, so an SDK without the EFW API fails here at once.
        loaded.unlocked().efw()?;
        let sdk = loaded.lock().await;
        self.open(&sdk)
    }

    async fn disconnect(&mut self) -> Result<(), DriverError> {
        if !self.connected {
            return Ok(());
        }
        let sdk = AtikSdk::lock().await?;
        let efw = sdk.efw()?;
        // SAFETY: the handle came from ArtemisEFWConnect and is released once.
        check_artemis_error(
            unsafe { (efw.disconnect)(self.handle.0) },
            "release the filter wheel",
        )?;
        self.handle = SdkHandle(std::ptr::null_mut());
        self.connected = false;
        Ok(())
    }
}

#[async_trait]
impl FilterWheelDriver for AtikFilterWheel {
    async fn move_to_position(&mut self, position: i32) -> Result<(), DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }
        if position < 0 || position >= self.filter_count {
            return Err(DriverError::InvalidParameter(format!(
                "Atik EFW position {} outside valid range 0-{}",
                position,
                self.filter_count - 1
            )));
        }
        let sdk = AtikSdk::lock().await?;
        let efw = sdk.efw()?;
        // SAFETY: the handle is open and the position was bounds-checked.
        check_artemis_error(
            unsafe { (efw.set_position)(self.handle.0, position) },
            &format!("turn to filter position {}", position + 1),
        )
    }

    async fn get_position(&self) -> Result<i32, DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }
        let sdk = AtikSdk::lock().await?;
        self.read_position(&sdk).map(|(position, _)| position)
    }

    async fn is_moving(&self) -> Result<bool, DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }
        let sdk = AtikSdk::lock().await?;
        self.read_position(&sdk).map(|(_, moving)| moving)
    }

    fn get_filter_count(&self) -> i32 {
        self.filter_count
    }

    async fn get_filter_names(&self) -> Result<Vec<String>, DriverError> {
        Ok((0..self.filter_count)
            .map(|i| format!("Filter {}", i + 1))
            .collect())
    }

    async fn set_filter_name(&mut self, _position: i32, _name: String) -> Result<(), DriverError> {
        // Atik EFW firmware does not persist filter names; callers maintain labels.
        Ok(())
    }
}
