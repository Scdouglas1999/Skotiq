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
pub async fn discover_filter_wheels() -> Result<Vec<PlayerOneFilterWheelInfo>, NativeError> {
    let sdk = match PoaPwSdk::get() {
        Some(sdk) => sdk,
        None => return Ok(Vec::new()),
    };

    let _lock = player_one_mutex().lock().await;
    let sdk_version = pw_sdk_version_from_sdk(sdk);
    // SAFETY: player_one_mutex held; POAGetPWCount takes no arguments.
    let count = unsafe { (sdk.get_pw_count)() };
    let mut wheels = Vec::new();

    for index in 0..count {
        // SAFETY: PWProperties is repr(C) POD; zeroed is a valid initial out buffer.
        let mut props: PWProperties = unsafe { std::mem::zeroed() };
        // SAFETY: player_one_mutex held; index is in [0, count); props is a valid out-pointer.
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
impl NativeDevice for PlayerOneFilterWheel {
    fn id(&self) -> &str {
        &self.device_id
    }

    fn name(&self) -> &str {
        &self.name
    }

    fn vendor(&self) -> NativeVendor {
        NativeVendor::PlayerOne
    }

    fn is_connected(&self) -> bool {
        self.connected
    }

    async fn connect(&mut self) -> Result<(), NativeError> {
        if self.connected {
            return Ok(());
        }

        let sdk = PoaPwSdk::get().ok_or(NativeError::SdkNotLoaded)?;
        let _lock = player_one_mutex().lock().await;

        // SAFETY: player_one_mutex held; handle comes from discovery or caller input. SDK
        // validates it and returns PW_ERROR_INVALID_HANDLE if stale.
        check_poa_pw_error(unsafe { (sdk.open_pw)(self.handle) }, "open filter wheel")?;

        let handle = self.handle;
        let cleanup_guard = CleanupGuard::new(|| {
            // SAFETY: player_one_mutex remains held for the lifetime of this guard;
            // handle was successfully opened immediately before the guard was created.
            let _ = unsafe { (sdk.close_pw)(handle) };
        });

        // SAFETY: PWProperties is repr(C) POD and props is a valid out-pointer.
        let mut props: PWProperties = unsafe { std::mem::zeroed() };
        // SAFETY: player_one_mutex held; handle has just been opened.
        check_poa_pw_error(
            // SAFETY: player_one_mutex held; handle just opened, props valid.
            unsafe { (sdk.get_pw_properties_by_handle)(self.handle, &mut props) },
            "get filter wheel properties",
        )?;

        if props.position_count <= 0 {
            return Err(NativeError::SdkError(format!(
                "Player One PW handle {} reported invalid position count {}",
                self.handle, props.position_count
            )));
        }

        self.name = pw_cstr(&props.name);
        self.filter_count = props.position_count;
        cleanup_guard.defuse();
        self.connected = true;
        Ok(())
    }

    async fn disconnect(&mut self) -> Result<(), NativeError> {
        if !self.connected {
            return Ok(());
        }

        let sdk = PoaPwSdk::get().ok_or(NativeError::SdkNotLoaded)?;
        let _lock = player_one_mutex().lock().await;
        // SAFETY: player_one_mutex held; handle is open because connected is true.
        check_poa_pw_error(unsafe { (sdk.close_pw)(self.handle) }, "close filter wheel")?;
        self.connected = false;
        Ok(())
    }
}

#[async_trait]
impl NativeFilterWheel for PlayerOneFilterWheel {
    async fn move_to_position(&mut self, position: i32) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }
        if position < 0 || position >= self.filter_count {
            return Err(NativeError::InvalidParameter(format!(
                "Player One PW position {} outside valid range 0-{}",
                position,
                self.filter_count - 1
            )));
        }

        let sdk = PoaPwSdk::get().ok_or(NativeError::SdkNotLoaded)?;
        let _lock = player_one_mutex().lock().await;
        // SAFETY: player_one_mutex held; handle is open and position is bounds-checked.
        check_poa_pw_error(
            unsafe { (sdk.goto_position)(self.handle, position) },
            "goto filter position",
        )
    }

    async fn get_position(&self) -> Result<i32, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = PoaPwSdk::get().ok_or(NativeError::SdkNotLoaded)?;
        let _lock = player_one_mutex().lock().await;
        let mut position = 0;
        // SAFETY: player_one_mutex held; handle is open and position is a valid out-pointer.
        check_poa_pw_error(
            // SAFETY: player_one_mutex held; handle open, out-pointer valid.
            unsafe { (sdk.get_current_position)(self.handle, &mut position) },
            "get current filter position",
        )?;
        Ok(position)
    }

    async fn is_moving(&self) -> Result<bool, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = PoaPwSdk::get().ok_or(NativeError::SdkNotLoaded)?;
        let _lock = player_one_mutex().lock().await;
        let mut state = PWState::Closed;
        // SAFETY: player_one_mutex held; handle is open and state is a valid out-pointer.
        check_poa_pw_error(
            // SAFETY: player_one_mutex held; handle open, out-pointer valid.
            unsafe { (sdk.get_pw_state)(self.handle, &mut state) },
            "get filter wheel state",
        )?;
        Ok(state == PWState::Moving)
    }

    fn get_filter_count(&self) -> i32 {
        self.filter_count
    }

    async fn get_filter_names(&self) -> Result<Vec<String>, NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }

        let sdk = PoaPwSdk::get().ok_or(NativeError::SdkNotLoaded)?;
        let _lock = player_one_mutex().lock().await;
        let mut names = Vec::new();
        for position in 0..self.filter_count {
            let mut name_buf = [0 as c_char; 24];
            // SAFETY: player_one_mutex held; handle is open; position is in range; buffer length
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

    async fn set_filter_name(&mut self, position: i32, name: String) -> Result<(), NativeError> {
        if !self.connected {
            return Err(NativeError::NotConnected);
        }
        if position < 0 || position >= self.filter_count {
            return Err(NativeError::InvalidParameter(format!(
                "Player One PW position {} outside valid range 0-{}",
                position,
                self.filter_count - 1
            )));
        }
        if name.as_bytes().contains(&0) || name.len() >= 24 {
            return Err(NativeError::InvalidParameter(
                "Player One PW filter alias must be non-NUL and shorter than 24 bytes".to_string(),
            ));
        }

        let c_name = std::ffi::CString::new(name).map_err(|_| {
            NativeError::InvalidParameter("Player One PW filter alias contains NUL".to_string())
        })?;
        let sdk = PoaPwSdk::get().ok_or(NativeError::SdkNotLoaded)?;
        let _lock = player_one_mutex().lock().await;
        // SAFETY: player_one_mutex held; handle is open; position bounds checked; CString is
        // NUL-terminated and lives for the call.
        check_poa_pw_error(
            unsafe { (sdk.set_filter_alias)(self.handle, position, c_name.as_ptr()) },
            "set filter alias",
        )
    }
}
