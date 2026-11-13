use crate::device_manager::get_device_manager;
use crate::error::SkotiqError;
use crate::event::system::SystemEvent;
use crate::state::get_state;

/// Initialize the native bridge with optional file logging
/// Must be called once at app startup before any other API calls
///
/// # Arguments
/// * `log_directory` - Optional path to store log files. If None, logs only to console.
#[flutter_rust_bridge::frb(sync)]
pub fn api_init_with_logging(log_directory: Option<String>) -> Result<(), SkotiqError> {
    // Initialize logging (with file output if directory provided)
    crate::init_native_with_logging(log_directory)?;

    tracing::info!("Skotiq Native API initialized");

    let _ = get_state();

    // Start OS device-change notifications after state/runtime initialization
    // so hotplug messages can invalidate discovery caches and fan out through
    // the normal SkotiqEvent stream.
    crate::hotplug::start_os_hotplug_listener();

    // Initialize device manager (this will spawn Tokio tasks, so runtime must exist)
    let _ = get_device_manager();

    get_state().publish_system_event(SystemEvent::Initialized);

    Ok(())
}

/// Initialize the native bridge and return success (console logging only)
/// Must be called once at app startup before any other API calls
#[flutter_rust_bridge::frb(sync)]
pub fn api_init() -> Result<(), SkotiqError> {
    api_init_with_logging(None)
}

/// Get the version of the native library
#[flutter_rust_bridge::frb(sync)]
pub fn api_get_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// Get the current log file path (today's log)
#[flutter_rust_bridge::frb(sync)]
pub fn api_get_current_log_file() -> Option<String> {
    crate::get_current_log_file()
}
