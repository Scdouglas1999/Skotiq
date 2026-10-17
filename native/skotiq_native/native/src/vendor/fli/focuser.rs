//! FLI focuser implementation.

use super::*;

/// FLI focuser native driver
pub struct FliFocuser {
    pub(crate) device_path: String,
    pub(crate) device_id: String,
    pub(crate) name: String,
    pub(crate) handle: FliDev,
    pub(crate) connected: bool,
    pub(crate) max_position: i32,
}

impl std::fmt::Debug for FliFocuser {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("FliFocuser")
            .field("device_id", &self.device_id)
            .field("name", &self.name)
            .finish()
    }
}

impl FliFocuser {
    pub fn new(device_path: String) -> Self {
        let device_id = device_path.replace("/", "_").replace("\\", "_");
        Self {
            device_path: device_path.clone(),
            device_id: format!("fli_focuser_{}", device_id),
            name: "FLI Focuser".to_string(),
            handle: FLI_INVALID_DEVICE,
            connected: false,
            max_position: 50000,
        }
    }
}

#[async_trait]
impl NativeDevice for FliFocuser {
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
                "FLI focuser device path contains null bytes: '{}'",
                self.device_path
            );
            NativeError::SdkError(format!(
                "Invalid device path '{}' contains null bytes",
                self.device_path
            ))
        })?;
        let domain = FLIDOMAIN_USB | FLIDEVICE_FOCUSER;

        // SAFETY: fli_mutex held above; `self.handle` is a valid pointer into Self; path_cstr is a NUL-terminated CString that outlives the call.
        let result = unsafe { (sdk.open)(&mut self.handle, path_cstr.as_ptr(), domain) };
        if result != 0 {
            tracing::error!(
                "FLI Open() failed for focuser at '{}'. Error code: {}. Check USB connection.",
                self.device_path,
                result
            );
            return Err(NativeError::SdkError(format!(
                "Failed to open FLI focuser at '{}'. SDK error: {}",
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

        // Get max position
        let mut extent: c_long = 0;
        // SAFETY: fli_mutex held; self.handle is open; `extent` is a valid stack pointer.
        if unsafe { (sdk.get_focuser_extent)(self.handle, &mut extent) } == 0 {
            // Why: focuser extent is a small positive integer (FLI focusers top out near
            // 7000 steps); SDK returns c_long. Use helper so an absurd value fails loud.
            self.max_position = fli_c_long_to_i32(extent, "focuser extent")?;
        }

        self.connected = true;
        tracing::info!("Connected to FLI focuser: {}", self.name);

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
        check_fli_error(result, "close focuser")?;

        self.handle = FLI_INVALID_DEVICE;
        self.connected = false;

        Ok(())
    }
}

#[async_trait]
impl NativeFocuser for FliFocuser {
    async fn get_position(&self) -> Result<i32, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = get_sdk()?;

        // Acquire global SDK mutex for thread safety
        let _lock = fli_mutex().lock().await;

        let mut position: c_long = 0;

        // SAFETY: fli_mutex held above; self.handle is valid (connected=true checked); `position` is a valid stack pointer.
        let result = unsafe { (sdk.get_stepper_position)(self.handle, &mut position) };
        check_fli_error(result, "get position")?;

        // Why: focuser position is a small positive integer (max_position <= ~7000); SDK
        // returns c_long. Use helper to fail closed on any out-of-range value.
        fli_c_long_to_i32(position, "focuser position")
    }

    async fn move_to(&mut self, position: i32) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = get_sdk()?;

        // Acquire global SDK mutex for thread safety
        let _lock = fli_mutex().lock().await;

        // Get current position
        let mut current: c_long = 0;
        // SAFETY: fli_mutex held above; self.handle is valid (connected=true checked); `current` is a valid stack pointer.
        let result = unsafe { (sdk.get_stepper_position)(self.handle, &mut current) };
        check_fli_error(result, "get current position")?;

        // Calculate steps needed
        let steps = position as c_long - current;

        // Move asynchronously
        // SAFETY: fli_mutex held; self.handle is valid; `steps` is a delta computed from valid c_long values.
        let result = unsafe { (sdk.step_motor_async)(self.handle, steps) };
        check_fli_error(result, "move focuser")?;

        Ok(())
    }

    async fn move_relative(&mut self, steps: i32) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = get_sdk()?;

        // Acquire global SDK mutex for thread safety
        let _lock = fli_mutex().lock().await;

        // SAFETY: fli_mutex held above; self.handle is valid (connected=true checked); `steps` is a pass-by-value c_long.
        let result = unsafe { (sdk.step_motor_async)(self.handle, steps as c_long) };
        check_fli_error(result, "move focuser relative")?;

        Ok(())
    }

    async fn is_moving(&self) -> Result<bool, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = get_sdk()?;

        // Acquire global SDK mutex for thread safety
        let _lock = fli_mutex().lock().await;

        let mut steps_remaining: c_long = 0;

        // SAFETY: fli_mutex held above; self.handle is valid (connected=true checked); `steps_remaining` is a valid stack pointer.
        let result = unsafe { (sdk.get_steps_remaining)(self.handle, &mut steps_remaining) };
        check_fli_error(result, "get steps remaining")?;

        Ok(steps_remaining != 0)
    }

    async fn halt(&mut self) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        // FLI doesn't have a direct halt - move 0 steps
        let sdk = get_sdk()?;

        // Acquire global SDK mutex for thread safety
        let _lock = fli_mutex().lock().await;

        // SAFETY: fli_mutex held above; self.handle is valid (connected=true checked); 0 is a pass-by-value c_long that causes the motor to stop per libfli docs.
        let result = unsafe { (sdk.step_motor)(self.handle, 0) };
        check_fli_error(result, "halt focuser")?;

        Ok(())
    }

    fn get_max_position(&self) -> i32 {
        self.max_position
    }

    fn get_step_size(&self) -> f64 {
        1.0 // FLI focusers use step units
    }

    async fn get_temperature(&self) -> Result<Option<f64>, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = get_sdk()?;

        // Acquire global SDK mutex for thread safety
        let _lock = fli_mutex().lock().await;

        let mut temp: c_double = 0.0;

        // FLI_TEMPERATURE_EXTERNAL = 0x0001
        // SAFETY: fli_mutex held above; self.handle is valid (connected=true checked); 0x0001 is the documented channel constant; `temp` is a valid stack pointer.
        if unsafe { (sdk.read_temperature)(self.handle, 0x0001, &mut temp) } == 0 {
            Ok(Some(temp))
        } else {
            Ok(None)
        }
    }
}
