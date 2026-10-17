//! Atik EFW filter wheel implementation.

use super::*;

/// Atik standalone EFW filter wheel native driver.
pub struct AtikFilterWheel {
    pub(crate) device_index: c_int,
    pub(crate) serial_number: Option<String>,
    pub(crate) device_id: String,
    pub(crate) name: String,
    pub(crate) handle: Mutex<HandleWrapper>,
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
            handle: Mutex::new(HandleWrapper(std::ptr::null_mut())),
            connected: false,
            filter_count: 0,
        }
    }
}

#[async_trait]
impl NativeDevice for AtikFilterWheel {
    fn id(&self) -> &str {
        &self.device_id
    }

    fn name(&self) -> &str {
        &self.name
    }

    fn vendor(&self) -> NativeVendor {
        NativeVendor::Atik
    }

    fn is_connected(&self) -> bool {
        self.connected
    }

    async fn connect(&mut self) -> Result<(), NativeError> {
        if self.connected {
            return Ok(());
        }

        let sdk = get_sdk()?;
        require_efw_api(sdk)?;
        let efw_connect = sdk.efw_connect.unwrap();
        let efw_is_connected = sdk.efw_is_connected.unwrap();
        let efw_disconnect = sdk.efw_disconnect.unwrap();
        let efw_nmr_position = sdk.efw_nmr_position.unwrap();
        let efw_get_device_details = sdk.efw_get_device_details.unwrap();

        let _lock = atik_mutex().lock().await;

        let serial_number = self.serial_number.as_deref().ok_or_else(|| {
            NativeError::DeviceNotFound(format!(
                "No discovery serial recorded for Atik EFW index {}",
                self.device_index
            ))
        })?;
        let device_index = efw_index_for_serial(sdk, serial_number)?;

        // SAFETY: atik_mutex held; device_index was resolved from the discovery-time serial
        // against the current SDK enumeration; NULL is checked below.
        let handle = unsafe { efw_connect(device_index) };
        if handle.is_null() {
            return Err(NativeError::SdkError(format!(
                "Failed to connect to Atik EFW serial {}",
                serial_number
            )));
        }

        // SAFETY: handle was just returned by ArtemisEFWConnect and checked non-null.
        if !unsafe { efw_is_connected(handle) } {
            // SAFETY: atik_mutex held; handle was successfully opened above.
            unsafe { efw_disconnect(handle) };
            return Err(NativeError::SdkError(format!(
                "Atik EFW serial {} did not report connected after connect",
                serial_number
            )));
        }

        let mut efw_type: c_int = 0;
        let mut serial_buf = [0 as c_char; 100];
        // SAFETY: atik_mutex held; out-pointers are valid. Failure is non-fatal for connect:
        // the wheel handle is already valid, and type/name are display metadata.
        if unsafe { efw_get_device_details(device_index, &mut efw_type, serial_buf.as_mut_ptr()) }
            == ArtemisError::Ok as c_int
        {
            self.name = atik_efw_type_name(efw_type);
        }

        let mut filter_count: c_int = 0;
        // SAFETY: atik_mutex held; handle is connected and `filter_count` is a valid out-pointer.
        // SAFETY: atik_mutex held; handle is connected, out-pointer valid.
        let result = unsafe { efw_nmr_position(handle, &mut filter_count) };
        if let Err(error) = check_artemis_error(result, "get EFW filter count") {
            // SAFETY: atik_mutex held; handle was successfully opened above.
            unsafe { efw_disconnect(handle) };
            return Err(error);
        }
        if filter_count <= 0 {
            // SAFETY: atik_mutex held; handle was successfully opened above.
            unsafe { efw_disconnect(handle) };
            return Err(NativeError::SdkError(format!(
                "Atik EFW serial {} reported invalid filter count {}",
                serial_number, filter_count
            )));
        }

        {
            let mut h = self.handle.lock().unwrap_or_else(|e| e.into_inner());
            *h = HandleWrapper(handle);
        }
        self.device_index = device_index;
        self.filter_count = filter_count;
        self.connected = true;
        Ok(())
    }

    async fn disconnect(&mut self) -> Result<(), NativeError> {
        if !self.connected {
            return Ok(());
        }

        let sdk = get_sdk()?;
        require_efw_api(sdk)?;
        let efw_disconnect = sdk.efw_disconnect.unwrap();

        let _lock = atik_mutex().lock().await;
        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;
        // SAFETY: atik_mutex held; handle is valid because self.connected is true.
        check_artemis_error(unsafe { efw_disconnect(handle) }, "disconnect EFW")?;

        {
            let mut h = self.handle.lock().unwrap_or_else(|e| e.into_inner());
            *h = HandleWrapper(std::ptr::null_mut());
        }
        self.connected = false;
        Ok(())
    }
}

#[async_trait]
impl NativeFilterWheel for AtikFilterWheel {
    async fn move_to_position(&mut self, position: i32) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }
        if position < 0 || position >= self.filter_count {
            return Err(NativeError::InvalidParameter(format!(
                "Atik EFW position {} outside valid range 0-{}",
                position,
                self.filter_count - 1
            )));
        }

        let sdk = get_sdk()?;
        require_efw_api(sdk)?;
        let efw_set_position = sdk.efw_set_position.unwrap();
        let _lock = atik_mutex().lock().await;
        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;
        // SAFETY: atik_mutex held; handle is connected and position was bounds-checked.
        check_artemis_error(
            unsafe { efw_set_position(handle, position as c_int) },
            "set EFW position",
        )
    }

    async fn get_position(&self) -> Result<i32, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = get_sdk()?;
        require_efw_api(sdk)?;
        let efw_get_position = sdk.efw_get_position.unwrap();
        let _lock = atik_mutex().lock().await;
        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;
        let mut position: c_int = -1;
        let mut is_moving = false;
        // SAFETY: atik_mutex held; handle is connected and both out-pointers are valid.
        check_artemis_error(
            // SAFETY: atik_mutex held; handle is connected, out-pointers valid.
            unsafe { efw_get_position(handle, &mut position, &mut is_moving) },
            "get EFW position",
        )?;
        Ok(position)
    }

    async fn is_moving(&self) -> Result<bool, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = get_sdk()?;
        require_efw_api(sdk)?;
        let efw_get_position = sdk.efw_get_position.unwrap();
        let _lock = atik_mutex().lock().await;
        let handle = self.handle.lock().unwrap_or_else(|e| e.into_inner()).0;
        let mut position: c_int = -1;
        let mut is_moving = false;
        // SAFETY: atik_mutex held; handle is connected and both out-pointers are valid.
        check_artemis_error(
            // SAFETY: atik_mutex held; handle is connected, out-pointers valid.
            unsafe { efw_get_position(handle, &mut position, &mut is_moving) },
            "get EFW moving state",
        )?;
        Ok(is_moving)
    }

    fn get_filter_count(&self) -> i32 {
        self.filter_count
    }

    async fn get_filter_names(&self) -> Result<Vec<String>, NativeError> {
        Ok((0..self.filter_count)
            .map(|i| format!("Filter {}", i + 1))
            .collect())
    }

    async fn set_filter_name(&mut self, _position: i32, _name: String) -> Result<(), NativeError> {
        // Atik EFW firmware does not persist filter names; callers maintain labels.
        Ok(())
    }
}
