//! FLI filter wheel implementation.

use super::*;

pub struct FliFilterWheel {
    /// The address from the device id (see `open_device`).
    pub(crate) device_path: String,
    pub(crate) device_id: String,
    pub(crate) name: String,
    pub(crate) serial: Option<String>,
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
            serial: None,
            handle: FLI_INVALID_DEVICE,
            connected: false,
            filter_count: 0,
        }
    }

    fn configure(&mut self, sdk: &FliSdk) -> Result<(), DriverError> {
        if let Some(model) = read_model(sdk, self.handle) {
            self.name = model;
        }
        self.serial = read_serial(sdk, self.handle);

        let mut count: c_long = 0;
        // SAFETY: self.handle is open; `count` is a valid stack pointer.
        let result = unsafe { (sdk.get_filter_count)(self.handle, &mut count) };
        check_fli_error(result, "get filter count")?;
        // Why: filter count is a small positive integer (<= ~16 across all FLI CFW
        // models); SDK returns c_long. Use helper to fail closed on absurd values.
        let filter_count = fli_c_long_to_i32(count, "filter count")?;
        if filter_count <= 0 {
            return Err(DriverError::SdkError(format!(
                "FLI filter wheel at '{}' reported invalid filter count {}",
                self.device_path, filter_count
            )));
        }
        self.filter_count = filter_count;
        Ok(())
    }
}

#[async_trait]
impl DeviceDriver for FliFilterWheel {
    fn id(&self) -> &str {
        &self.device_id
    }

    fn name(&self) -> &str {
        &self.name
    }

    fn vendor(&self) -> Vendor {
        Vendor::Fli
    }

    fn serial_number(&self) -> Option<String> {
        self.serial.clone()
    }

    fn is_connected(&self) -> bool {
        self.connected
    }

    async fn connect(&mut self) -> Result<(), DriverError> {
        if self.connected {
            return Ok(());
        }

        let sdk = FliSdk::lock().await?;
        let (handle, filename) = open_device(&sdk, &self.device_path, FliDeviceType::FilterWheel)?;
        self.handle = handle;
        if let Err(error) = self.configure(&sdk) {
            close_fli_handle(&sdk, &mut self.handle);
            return Err(error);
        }

        self.connected = true;
        tracing::info!(
            "Connected to FLI filter wheel {} at '{}' ({} positions, serial {:?})",
            self.name,
            filename,
            self.filter_count,
            self.serial
        );

        Ok(())
    }

    async fn disconnect(&mut self) -> Result<(), DriverError> {
        if !self.connected {
            return Ok(());
        }

        let sdk = FliSdk::lock().await?;

        // SAFETY: self.handle was successfully opened during connect(). FLIClose pairs with FLIOpen.
        let result = unsafe { (sdk.close)(self.handle) };
        check_fli_error(result, "close filter wheel")?;

        self.handle = FLI_INVALID_DEVICE;
        self.connected = false;

        Ok(())
    }
}

#[async_trait]
impl FilterWheelDriver for FliFilterWheel {
    async fn get_position(&self) -> Result<i32, DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }

        let sdk = FliSdk::lock().await?;

        let mut position: c_long = 0;

        // SAFETY: self.handle is valid (connected=true checked); `position` is a valid stack pointer.
        let result = unsafe { (sdk.get_filter_pos)(self.handle, &mut position) };
        check_fli_error(result, "get filter position")?;

        // Why: filter wheel position is a small non-negative integer (<= filter_count <= ~16);
        // SDK returns c_long. Use helper to fail closed on absurd values.
        fli_c_long_to_i32(position, "filter position")
    }

    async fn move_to_position(&mut self, position: i32) -> Result<(), DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }

        if position < 0 || position >= self.filter_count {
            return Err(DriverError::InvalidParameter(format!(
                "Invalid filter position: {} (max {})",
                position,
                self.filter_count - 1
            )));
        }

        let sdk = FliSdk::lock().await?;

        // libfli's FLISetFilterPos returns when the wheel has arrived (it homes
        // first on the oldest wheels), so is_moving reads false after it.
        // SAFETY: self.handle is valid (connected=true checked); `position` was bounds-checked against filter_count earlier in this function.
        let result = unsafe { (sdk.set_filter_pos)(self.handle, position as c_long) };
        check_fli_error(result, "set filter position")?;

        Ok(())
    }

    async fn is_moving(&self) -> Result<bool, DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }

        let sdk = FliSdk::lock().await?;

        let mut status: c_long = 0;

        // SAFETY: self.handle is valid (connected=true checked); `status` is a valid stack pointer.
        let result = unsafe { (sdk.get_device_status)(self.handle, &mut status) };
        check_fli_error(result, "get device status")?;

        // Check if moving (bits 0-2 indicate movement direction)
        Ok((status & 0x07) != 0)
    }

    fn get_filter_count(&self) -> i32 {
        self.filter_count
    }

    async fn get_filter_names(&self) -> Result<Vec<String>, DriverError> {
        let generic = |i: i32| format!("Filter {}", i + 1);
        if !self.connected {
            return Ok((0..self.filter_count).map(generic).collect());
        }

        // The wheel firmware holds a default name per slot (NINA
        // FLIFilterWheel.Filters); a slot without one gets a generic name.
        let sdk = FliSdk::lock().await?;
        Ok((0..self.filter_count)
            .map(|i| {
                let mut buf = [0 as c_char; 64];
                // SAFETY: self.handle is open; buf is a 64-byte stack array and its length is passed truthfully.
                let result = unsafe {
                    (sdk.get_filter_name)(self.handle, i as c_long, buf.as_mut_ptr(), buf.len())
                };
                // SAFETY: libfli clears the buffer before filling it, so it is NUL-terminated.
                let name = (result == 0)
                    .then(|| {
                        unsafe { CStr::from_ptr(buf.as_ptr()) }
                            .to_string_lossy()
                            .trim()
                            .to_string()
                    })
                    .filter(|name| !name.is_empty());
                name.unwrap_or_else(|| generic(i))
            })
            .collect())
    }

    async fn set_filter_name(&mut self, _position: i32, _name: String) -> Result<(), DriverError> {
        // libfli has no call to store a filter name
        Ok(())
    }
}
