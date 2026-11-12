//! FLI focuser implementation.

use super::*;
use std::time::Duration;

/// How long a halted focuser may take to come to rest.
const FLI_HALT_TIMEOUT: Duration = Duration::from_secs(5);
const FLI_HALT_POLL: Duration = Duration::from_millis(100);

pub struct FliFocuser {
    /// The address from the device id (see `open_device`).
    pub(crate) device_path: String,
    pub(crate) device_id: String,
    pub(crate) name: String,
    pub(crate) serial: Option<String>,
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
            serial: None,
            handle: FLI_INVALID_DEVICE,
            connected: false,
            max_position: 50000,
        }
    }

    fn configure(&mut self, sdk: &FliSdk) -> Result<(), DriverError> {
        if let Some(model) = read_model(sdk, self.handle) {
            self.name = model;
        }
        self.serial = read_serial(sdk, self.handle);

        let mut extent: c_long = 0;
        // SAFETY: self.handle is open; `extent` is a valid stack pointer.
        let result = unsafe { (sdk.get_focuser_extent)(self.handle, &mut extent) };
        check_fli_error(result, "get focuser travel")?;
        // Why: focuser extent is a small positive integer (FLI focusers top out near
        // 7000 steps, Atlas near 100000); SDK returns c_long. Use helper so an absurd value fails loud.
        self.max_position = fli_c_long_to_i32(extent, "focuser extent")?;
        Ok(())
    }

    /// INDI fli_pdf.cpp MoveAbsFocuser refuses a target outside the travel;
    /// libfli sends any step count to the motor.
    fn check_target(&self, target: i64) -> Result<(), DriverError> {
        if (0..=i64::from(self.max_position)).contains(&target) {
            Ok(())
        } else {
            Err(DriverError::InvalidParameter(format!(
                "FLI focuser position {target} is outside its travel 0 to {}",
                self.max_position
            )))
        }
    }

    fn position(&self, sdk: &FliSdk) -> Result<c_long, DriverError> {
        let mut position: c_long = 0;
        // SAFETY: self.handle is valid (the caller checked the connection); `position` is a valid stack pointer.
        let result = unsafe { (sdk.get_stepper_position)(self.handle, &mut position) };
        check_fli_error(result, "get position")?;
        Ok(position)
    }

    /// One read of the steps left, under the SDK lock for that call only.
    async fn steps_remaining(&self) -> Result<c_long, DriverError> {
        let sdk = FliSdk::lock().await?;
        let mut steps: c_long = 0;
        // SAFETY: self.handle is valid (the caller checked the connection); `steps` is a valid stack pointer.
        let result = unsafe { (sdk.get_steps_remaining)(self.handle, &mut steps) };
        check_fli_error(result, "get steps remaining")?;
        Ok(steps)
    }

    fn step(&self, sdk: &FliSdk, steps: c_long) -> Result<(), DriverError> {
        // SAFETY: self.handle is valid (the caller checked the connection); `steps` is a pass-by-value c_long.
        let result = unsafe { (sdk.step_motor_async)(self.handle, steps) };
        check_fli_error(result, "move focuser")
    }
}

#[async_trait]
impl DeviceDriver for FliFocuser {
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
        let (handle, filename) = open_device(&sdk, &self.device_path, FliDeviceType::Focuser)?;
        self.handle = handle;
        if let Err(error) = self.configure(&sdk) {
            close_fli_handle(&sdk, &mut self.handle);
            return Err(error);
        }

        self.connected = true;
        tracing::info!(
            "Connected to FLI focuser {} at '{}' (travel 0 to {}, serial {:?})",
            self.name,
            filename,
            self.max_position,
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
        check_fli_error(result, "close focuser")?;

        self.handle = FLI_INVALID_DEVICE;
        self.connected = false;

        Ok(())
    }
}

#[async_trait]
impl FocuserDriver for FliFocuser {
    async fn get_position(&self) -> Result<i32, DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }

        let sdk = FliSdk::lock().await?;

        // Why: focuser position is bounded by the travel; SDK returns c_long. Use
        // helper to fail closed on any out-of-range value.
        fli_c_long_to_i32(self.position(&sdk)?, "focuser position")
    }

    async fn move_to(&mut self, position: i32) -> Result<(), DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }
        self.check_target(i64::from(position))?;

        let sdk = FliSdk::lock().await?;
        let current = self.position(&sdk)?;
        self.step(&sdk, position as c_long - current)
    }

    async fn move_relative(&mut self, steps: i32) -> Result<(), DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }

        let sdk = FliSdk::lock().await?;
        let current = self.position(&sdk)?;
        #[allow(clippy::useless_conversion)] // c_long is i32 on Windows
        let target = i64::from(current) + i64::from(steps);
        self.check_target(target)?;
        self.step(&sdk, steps as c_long)
    }

    async fn is_moving(&self) -> Result<bool, DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }

        Ok(self.steps_remaining().await? != 0)
    }

    async fn halt(&mut self) -> Result<(), DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }

        // libfli has no halt call; a zero-step move is the halt on the older
        // focuser firmware (libfli-filter-focuser.c fli_stepmotor) and a move to
        // where it is on the newer. The blocking FLIStepMotor sends the same
        // command and then polls the motor inside libfli with no time limit,
        // holding the FLI SDK lock (and so every FLI device) all the while.
        {
            let sdk = FliSdk::lock().await?;
            // SAFETY: self.handle is valid (connected=true checked); 0 is a pass-by-value c_long.
            let result = unsafe { (sdk.step_motor_async)(self.handle, 0) };
            check_fli_error(result, "halt focuser")?;
        }

        let deadline = tokio::time::Instant::now() + FLI_HALT_TIMEOUT;
        loop {
            let steps_left = self.steps_remaining().await?;
            if steps_left == 0 {
                return Ok(());
            }
            if tokio::time::Instant::now() >= deadline {
                return Err(DriverError::Timeout(format!(
                    "FLI focuser '{}' was told to stop but was still moving {} s later, {} steps from its target",
                    self.name,
                    FLI_HALT_TIMEOUT.as_secs(),
                    steps_left
                )));
            }
            tokio::time::sleep(FLI_HALT_POLL).await;
        }
    }

    fn get_max_position(&self) -> i32 {
        self.max_position
    }

    fn get_step_size(&self) -> f64 {
        1.0 // FLI focusers use step units
    }

    async fn get_temperature(&self) -> Result<Option<f64>, DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }

        let sdk = FliSdk::lock().await?;

        let mut temp: c_double = 0.0;

        // FLI_TEMPERATURE_EXTERNAL = 0x0001: the probe; libfli answers -EINVAL when none is plugged in.
        // SAFETY: self.handle is valid (connected=true checked); 0x0001 is the documented channel constant; `temp` is a valid stack pointer.
        if unsafe { (sdk.read_temperature)(self.handle, 0x0001, &mut temp) } == 0 {
            Ok(Some(temp))
        } else {
            Ok(None)
        }
    }
}
