//! Player One Phoenix filter wheel discovery and implementation.

use super::*;

/// Player One Phoenix filter-wheel discovery info.
#[derive(Debug, Clone)]
pub struct PlayerOneFilterWheelInfo {
    pub handle: i32,
    pub name: String,
    pub serial_number: Option<String>,
    pub sdk_version: Option<String>,
    pub position_count: i32,
}

/// Discover Player One Phoenix filter wheels.
pub async fn discover_filter_wheels() -> Result<Vec<PlayerOneFilterWheelInfo>, DriverError> {
    let sdk = match PoaPwSdk::lock().await {
        Ok(sdk) => sdk,
        Err(_) => return Ok(Vec::new()),
    };
    let sdk_version = pw_sdk_version_from_sdk(&sdk);
    // SAFETY: POAGetPWCount takes no arguments.
    let count = unsafe { (sdk.get_pw_count)() };
    let mut wheels = Vec::new();

    for index in 0..count {
        // SAFETY: PWProperties is repr(C) POD; zeroed is a valid initial out buffer.
        let mut props: PWProperties = unsafe { std::mem::zeroed() };
        // SAFETY: index is in [0, count); props is a valid out-pointer.
        let result = unsafe { (sdk.get_pw_properties)(index, &mut props) };
        if result != 0 {
            tracing::warn!(
                "Player One PW property query failed for index {}: error {}",
                index,
                result
            );
            continue;
        }

        wheels.push(PlayerOneFilterWheelInfo {
            handle: props.handle,
            name: pw_cstr(&props.name),
            serial_number: {
                let sn = pw_cstr(&props.sn);
                if sn.is_empty() {
                    None
                } else {
                    Some(sn)
                }
            },
            sdk_version: sdk_version.clone(),
            position_count: props.position_count,
        });
    }

    Ok(wheels)
}

/// How long a wheel may take to home after it is opened (INDI's POA_EFW_TIMEOUT).
const HOMING_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(20);

/// Player One Phoenix filter-wheel driver.
pub struct PlayerOneFilterWheel {
    pub(crate) handle: i32,
    pub(crate) device_id: String,
    pub(crate) name: String,
    pub(crate) connected: bool,
    pub(crate) filter_count: i32,
}

impl std::fmt::Debug for PlayerOneFilterWheel {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PlayerOneFilterWheel")
            .field("handle", &self.handle)
            .field("name", &self.name)
            .field("connected", &self.connected)
            .field("filter_count", &self.filter_count)
            .finish()
    }
}

impl PlayerOneFilterWheel {
    pub fn new(handle: i32) -> Self {
        Self {
            handle,
            device_id: format!("native:playerone_pw:{}", handle),
            name: format!("Player One PW {}", handle),
            connected: false,
            filter_count: 0,
        }
    }
}

#[async_trait]
impl DeviceDriver for PlayerOneFilterWheel {
    fn id(&self) -> &str {
        &self.device_id
    }

    fn name(&self) -> &str {
        &self.name
    }

    fn vendor(&self) -> Vendor {
        Vendor::PlayerOne
    }

    fn is_connected(&self) -> bool {
        self.connected
    }

    async fn connect(&mut self) -> Result<(), DriverError> {
        if self.connected {
            return Ok(());
        }

        let sdk = PoaPwSdk::lock().await?;

        // SAFETY: handle comes from discovery or caller input. SDK
        // validates it and returns PW_ERROR_INVALID_HANDLE if stale.
        check_poa_pw_error(unsafe { (sdk.open_pw)(self.handle) }, "open filter wheel")?;

        let handle = self.handle;
        let locked_sdk: &PoaPwSdk = &sdk;
        let cleanup_guard = CleanupGuard::new(|| {
            // SAFETY: the cleanup borrows the lock guard, so it runs while connect() still holds the lock;
            // handle was successfully opened immediately before the guard was created.
            let _ = unsafe { (locked_sdk.close_pw)(handle) };
        });

        // SAFETY: PWProperties is repr(C) POD and props is a valid out-pointer.
        let mut props: PWProperties = unsafe { std::mem::zeroed() };
        // SAFETY: handle has just been opened.
        check_poa_pw_error(
            // SAFETY: handle just opened, props valid.
            unsafe { (sdk.get_pw_properties_by_handle)(self.handle, &mut props) },
            "get filter wheel properties",
        )?;

        if props.position_count <= 0 {
            return Err(DriverError::SdkError(format!(
                "Player One PW handle {} reported invalid position count {}",
                self.handle, props.position_count
            )));
        }

        self.name = pw_cstr(&props.name);
        self.filter_count = props.position_count;
        cleanup_guard.defuse();
        drop(sdk);
        self.connected = true;

        // A wheel turns to find its home right after it is opened and refuses
        // moves until that ends (INDI and NINA wait for it the same way). The
        // SDK lock is shared with the cameras, so it is taken per poll.
        let deadline = std::time::Instant::now() + HOMING_TIMEOUT;
        loop {
            match self.is_moving().await {
                Ok(false) => break,
                Ok(true) if std::time::Instant::now() < deadline => {}
                outcome => {
                    // NINA connects anyway; position reads say -1 until the turn ends.
                    tracing::warn!(
                        "Player One filter wheel {} had not finished homing {} s after it was opened ({:?})",
                        self.handle,
                        HOMING_TIMEOUT.as_secs(),
                        outcome
                    );
                    break;
                }
            }
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        }
        Ok(())
    }

    async fn disconnect(&mut self) -> Result<(), DriverError> {
        if !self.connected {
            return Ok(());
        }

        let sdk = PoaPwSdk::lock().await?;
        // SAFETY: handle is open because connected is true.
        check_poa_pw_error(unsafe { (sdk.close_pw)(self.handle) }, "close filter wheel")?;
        self.connected = false;
        Ok(())
    }
}

#[async_trait]
impl FilterWheelDriver for PlayerOneFilterWheel {
    async fn move_to_position(&mut self, position: i32) -> Result<(), DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }
        if position < 0 || position >= self.filter_count {
            return Err(DriverError::InvalidParameter(format!(
                "Player One PW position {} outside valid range 0-{}",
                position,
                self.filter_count - 1
            )));
        }

        let sdk = PoaPwSdk::lock().await?;
        // SAFETY: handle is open and position is bounds-checked.
        check_poa_pw_error(
            unsafe { (sdk.goto_position)(self.handle, position) },
            "goto filter position",
        )
    }

    async fn get_position(&self) -> Result<i32, DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }

        let sdk = PoaPwSdk::lock().await?;
        let mut position = 0;
        // SAFETY: handle is open and position is a valid out-pointer.
        let result = unsafe { (sdk.get_current_position)(self.handle, &mut position) };
        // The wheel answers a position read while it turns with an error; the
        // driver contract (and the ZWO EFW) says -1.
        if result == PW_ERROR_IS_MOVING {
            return Ok(-1);
        }
        check_poa_pw_error(result, "get current filter position")?;
        Ok(position)
    }

    async fn is_moving(&self) -> Result<bool, DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }

        let sdk = PoaPwSdk::lock().await?;
        let mut state: c_int = 0;
        // SAFETY: handle is open and state is a valid out-pointer.
        check_poa_pw_error(
            // SAFETY: handle open, out-pointer valid.
            unsafe { (sdk.get_pw_state)(self.handle, &mut state) },
            "get filter wheel state",
        )?;
        Ok(state == PW_STATE_MOVING)
    }

    fn get_filter_count(&self) -> i32 {
        self.filter_count
    }

    async fn get_filter_names(&self) -> Result<Vec<String>, DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }

        let sdk = PoaPwSdk::lock().await?;
        let mut names = Vec::new();
        for position in 0..self.filter_count {
            let mut name_buf = [0 as c_char; 24];
            // SAFETY: handle is open; position is in range; buffer length
            // matches PlayerOnePW.h MAX_NAME_LEN.
            let result =
                unsafe { (sdk.get_filter_alias)(self.handle, position, name_buf.as_mut_ptr(), 24) };
            if result == 0 {
                let name = safe_cstr_to_string(name_buf.as_ptr(), 24);
                names.push(if name.is_empty() {
                    format!("Filter {}", position + 1)
                } else {
                    name
                });
            } else {
                names.push(format!("Filter {}", position + 1));
            }
        }
        Ok(names)
    }

    async fn set_filter_name(&mut self, position: i32, name: String) -> Result<(), DriverError> {
        if !self.connected {
            return Err(DriverError::NotConnected);
        }
        if position < 0 || position >= self.filter_count {
            return Err(DriverError::InvalidParameter(format!(
                "Player One PW position {} outside valid range 0-{}",
                position,
                self.filter_count - 1
            )));
        }
        if name.as_bytes().contains(&0) || name.len() >= 24 {
            return Err(DriverError::InvalidParameter(
                "Player One PW filter alias must be non-NUL and shorter than 24 bytes".to_string(),
            ));
        }

        // Shorter than 24 bytes, checked above.
        let length = name.len() as c_int;
        let c_name = std::ffi::CString::new(name).map_err(|_| {
            DriverError::InvalidParameter("Player One PW filter alias contains NUL".to_string())
        })?;
        let sdk = PoaPwSdk::lock().await?;
        // SAFETY: handle is open; position bounds checked; CString is
        // NUL-terminated, `length` bytes long, and lives for the call. A length
        // of 0 clears the alias (PlayerOnePW.h).
        check_poa_pw_error(
            unsafe { (sdk.set_filter_alias)(self.handle, position, c_name.as_ptr(), length) },
            "set filter alias",
        )
    }
}
