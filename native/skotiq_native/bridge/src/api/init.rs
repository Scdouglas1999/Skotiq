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
    crate::api::post_session::publish_pass_reports();

    // Start OS device-change notifications after state/runtime initialization
    // so hotplug messages can invalidate discovery caches and fan out through
    // the normal SkotiqEvent stream.
    crate::hotplug::start_os_hotplug_listener();

    // Initialize device manager (this will spawn Tokio tasks, so runtime must exist)
    let _ = get_device_manager();

    get_state().publish_system_event(SystemEvent::Initialized);

    Ok(())
}

/// Where a host keeps what the native side writes. The app resolves each
/// directory (honoring `SKOTIQ_DATA_DIR` and `SKOTIQ_DATABASE_DIR`) and
/// creates it before the call.
pub struct HostPaths {
    /// Defect maps and camera files kept when a download failed.
    pub data_directory: String,
    /// The native rolling log.
    pub log_directory: String,
    /// Equipment profiles, settings, the plate-solver choice and DepthLock
    /// goals.
    pub profile_directory: String,
}

/// Start the native side of a host: logging, device manager, hotplug, pass
/// reports, the profile and settings stores rooted at `paths`, and the
/// sequencer event bridges.
/// Called once at app start, before any other API call.
#[flutter_rust_bridge::frb(sync)]
pub fn api_init_host(paths: HostPaths) -> Result<(), SkotiqError> {
    crate::data_root::set(std::path::PathBuf::from(&paths.data_directory))
        .map_err(SkotiqError::OperationFailed)?;
    api_init_with_logging(Some(paths.log_directory.clone()))?;
    tracing::info!(
        "Host paths: data={} log={} profile={}",
        paths.data_directory,
        paths.log_directory,
        paths.profile_directory
    );
    crate::api::storage::init_profile_storage(paths.profile_directory.clone())?;
    crate::api::storage::init_settings_storage(paths.profile_directory)?;
    crate::api::sequencer::event_bridge::start_sequencer_event_bridges()?;
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
