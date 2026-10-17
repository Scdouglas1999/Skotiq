//! FLI filter wheel implementation.

use super::*;

/// FLI filter wheel native driver
pub struct FliFilterWheel {
    pub(crate) device_path: String,
    pub(crate) device_id: String,
    pub(crate) name: String,
    pub(crate) handle: FliDev,
    pub(crate) connected: bool,
    pub(crate) filter_count: i32,
}

impl std::fmt::Debug for FliFilterWheel {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("FliFilterWheel")
            .field("device_id", &self.device_id)
            .field("name", &self.name)
            .finish()
    }
}

impl FliFilterWheel {
    pub fn new(device_path: String) -> Self {
        let device_id = device_path.replace("/", "_").replace("\\", "_");
        Self {
            device_path: device_path.clone(),
            device_id: format!("fli_fw_{}", device_id),
            name: "FLI Filter Wheel".to_string(),
            handle: FLI_INVALID_DEVICE,
            connected: false,
            filter_count: 0,
        }
    }
}

#[async_trait]
impl NativeDevice for FliFilterWheel {
    fn id(&self) -> &str {
        &self.device_id
    }

    fn name(&self) -> &str {
        &self.name
    }

    fn vendor(&self) -> NativeVendor {
        NativeVendor::Fli
    }

    fn is_connected(&self) -> bool {
        self.connected
    }

    async fn connect(&mut self) -> Result<(), NativeError> {
        if self.connected {
            return Ok(());
        }

        let sdk = get_sdk()?;

        // Acquire global SDK mutex for thread safety
        let _lock = fli_mutex().lock().await;

        let path_cstr = CString::new(self.device_path.clone()).map_err(|_| {
            tracing::error!(
                "FLI filter wheel device path contains null bytes: '{}'",
                self.device_path
            );
            NativeError::SdkError(format!(
                "Invalid device path '{}' contains null bytes",
                self.device_path
            ))
        })?;
        let domain = FLIDOMAIN_USB | FLIDEVICE_FILTERWHEEL;

        // SAFETY: fli_mutex held above; `self.handle` is a valid pointer into Self; path_cstr is a NUL-terminated CString that outlives the call.
        let result = unsafe { (sdk.open)(&mut self.handle, path_cstr.as_ptr(), domain) };
        if result != 0 {
            tracing::error!(
                "FLI Open() failed for filter wheel at '{}'. Error code: {}. Check USB connection.",
                self.device_path,
                result
            );
            return Err(NativeError::SdkError(format!(
                "Failed to open FLI filter wheel at '{}'. SDK error: {}",
                self.device_path, result
            )));
        }

        // Get model name
        let mut model_buf = [0 as c_char; 128];
        // SAFETY: fli_mutex held; self.handle was just opened above; model_buf is a 128-byte stack array with truthful length.
        if unsafe { (sdk.get_model)(self.handle, model_buf.as_mut_ptr(), model_buf.len()) } == 0 {
            // SAFETY: model_buf is 128 bytes; FLI SDK guarantees NUL-termination on success.
            self.name = unsafe { CStr::from_ptr(model_buf.as_ptr()) }
                .to_string_lossy()
                .to_string();
        }

        // Get filter count
        let mut count: c_long = 0;
        // SAFETY: fli_mutex held; self.handle is open; `count` is a valid stack pointer.
        let result = unsafe { (sdk.get_filter_count)(self.handle, &mut count) };
        if let Err(error) = check_fli_error(result, "get filter count") {
            close_fli_handle(sdk, &mut self.handle);
            return Err(error);
        }
        // Why: filter count is a small positive integer (<= ~16 across all FLI CFW
        // models); SDK returns c_long. Use helper to fail closed on absurd values.
        let filter_count = match fli_c_long_to_i32(count, "filter count") {
            Ok(filter_count) => filter_count,
            Err(error) => {
                close_fli_handle(sdk, &mut self.handle);
                return Err(error);
            }
        };
        if filter_count <= 0 {
            close_fli_handle(sdk, &mut self.handle);
            return Err(NativeError::SdkError(format!(
                "FLI filter wheel at '{}' reported invalid filter count {}",
                self.device_path, filter_count
            )));
        }

        self.filter_count = filter_count;
        self.connected = true;
        tracing::info!(
            "Connected to FLI filter wheel: {} ({} positions)",
            self.name,
            self.filter_count
        );

        Ok(())
    }

    async fn disconnect(&mut self) -> Result<(), NativeError> {
        if !self.connected {
            return Ok(());
        }

        let sdk = get_sdk()?;

        // Acquire global SDK mutex for thread safety
        let _lock = fli_mutex().lock().await;

        // SAFETY: fli_mutex held above; self.handle was successfully opened during connect(). FLIClose pairs with FLIOpen.
        let result = unsafe { (sdk.close)(self.handle) };
        check_fli_error(result, "close filter wheel")?;

        self.handle = FLI_INVALID_DEVICE;
        self.connected = false;

        Ok(())
    }
}

#[async_trait]
impl NativeFilterWheel for FliFilterWheel {
    async fn get_position(&self) -> Result<i32, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = get_sdk()?;

        // Acquire global SDK mutex for thread safety
        let _lock = fli_mutex().lock().await;

        let mut position: c_long = 0;

        // SAFETY: fli_mutex held above; self.handle is valid (connected=true checked); `position` is a valid stack pointer.
        let result = unsafe { (sdk.get_filter_pos)(self.handle, &mut position) };
        check_fli_error(result, "get filter position")?;

        // Why: filter wheel position is a small non-negative integer (<= filter_count <= ~16);
        // SDK returns c_long. Use helper to fail closed on absurd values.
        fli_c_long_to_i32(position, "filter position")
    }

    async fn move_to_position(&mut self, position: i32) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        if position < 0 || position >= self.filter_count {
            return Err(NativeError::InvalidParameter(format!(
                "Invalid filter position: {} (max {})",
                position,
                self.filter_count - 1
            )));
        }

        let sdk = get_sdk()?;

        // Acquire global SDK mutex for thread safety
        let _lock = fli_mutex().lock().await;

        // SAFETY: fli_mutex held above; self.handle is valid (connected=true checked); `position` was bounds-checked against filter_count earlier in this function.
        let result = unsafe { (sdk.set_filter_pos)(self.handle, position as c_long) };
        check_fli_error(result, "set filter position")?;

        Ok(())
    }

    async fn is_moving(&self) -> Result<bool, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = get_sdk()?;

        // Acquire global SDK mutex for thread safety
        let _lock = fli_mutex().lock().await;

        let mut status: c_long = 0;

        // SAFETY: fli_mutex held above; self.handle is valid (connected=true checked); `status` is a valid stack pointer.
        let result = unsafe { (sdk.get_device_status)(self.handle, &mut status) };
        check_fli_error(result, "get device status")?;

        // Check if moving (bits 0-2 indicate movement direction)
        Ok((status & 0x07) != 0)
    }

    fn get_filter_count(&self) -> i32 {
        self.filter_count
    }

    async fn get_filter_names(&self) -> Result<Vec<String>, NativeError> {
        // FLI SDK doesn't store filter names, return generic names
        let names: Vec<String> = (0..self.filter_count)
            .map(|i| format!("Filter {}", i + 1))
            .collect();
        Ok(names)
    }

    async fn set_filter_name(&mut self, _position: i32, _name: String) -> Result<(), NativeError> {
        // FLI SDK doesn't support storing filter names
        Ok(())
    }
}
