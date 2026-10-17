// split from monolithic api.rs
#![allow(unused_imports)]
// Shared imports inherited from the monolithic api.rs.
use crate::device::*;
use crate::device_manager::DeviceManager;
use crate::error::*;
use crate::event::*;
use crate::state::*;
use crate::storage::{AppSettings, ObserverLocation};
use crate::unified_device_ops::create_unified_device_ops;
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use skotiq_imaging::{
    calculate_airmass, validate_fits_header, validate_image, write_fits, BayerPattern,
    DebayerAlgorithm, FitsHeader, ImageData,
};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::sync::OnceLock;
use std::time::{Duration, Instant};
use tokio::sync::Mutex;
use tokio::sync::RwLock;
// Sibling-module items via the parent's pub use re-exports.
use super::*;

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

    // Initialize the app state
    let _ = get_state();

    // Start OS device-change notifications after state/runtime initialization
    // so hotplug messages can invalidate discovery caches and fan out through
    // the normal SkotiqEvent stream.
    crate::hotplug::start_os_hotplug_listener();

    // Initialize device manager (this will spawn Tokio tasks, so runtime must exist)
    let _ = get_device_manager();

    // Publish system initialized event
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

/// Get the current log directory path
#[flutter_rust_bridge::frb(sync)]
pub fn api_get_log_directory() -> Option<String> {
    crate::get_log_directory()
}

/// Get the current log file path (today's log)
#[flutter_rust_bridge::frb(sync)]
pub fn api_get_current_log_file() -> Option<String> {
    crate::get_current_log_file()
}

/// List all available log files
pub fn api_list_log_files() -> Vec<String> {
    crate::list_log_files()
}

/// Read a log file's contents
pub fn api_read_log_file(path: String) -> Result<String, SkotiqError> {
    crate::read_log_file(path)
}

/// Export all logs to a single file for diagnostics
pub fn api_export_logs(output_path: String) -> Result<(), SkotiqError> {
    crate::export_logs_to_file(output_path)
}
