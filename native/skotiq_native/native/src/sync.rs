//! Thread synchronization primitives for vendor SDK protection.
//!
//! Vendor SDKs (ZWO, QHY, Player One, SVBony, etc.) are NOT thread-safe.
//! Concurrent access from multiple async tasks can cause undefined behavior,
//! crashes, or data corruption.
//!
//! This module provides per-vendor mutexes to serialize all SDK operations.
//! Each vendor SDK has its own mutex to allow concurrent access across different
//! vendors while preventing concurrent access within a single vendor's SDK.
//!
//! ## Usage Pattern
//!
//! ```rust,ignore
//! use crate::sync::ZWO_CAMERA_MUTEX;
//!
//! async fn some_camera_operation(&self) -> Result<(), NativeError> {
//!     let _lock = ZWO_CAMERA_MUTEX.lock().await;
//!     // SDK operations here are now serialized
//!     unsafe { (sdk.some_function)(self.camera_id) };
//!     Ok(())
//! }
//! ```
//!
//! ## Important Notes
//!
//! - Use `tokio::sync::Mutex` for async-friendly locking (can hold across await points)
//! - Hold the mutex for the minimum duration necessary
//! - Release the mutex before long-running non-SDK operations
//! - The mutex guard is released automatically when it goes out of scope

use std::sync::OnceLock;
use tokio::sync::Mutex;

// ZWO SDK mutexes

/// Mutex for ZWO ASI Camera SDK operations.
/// Protects all ASICamera2.dll function calls.
static ZWO_CAMERA_MUTEX_CELL: OnceLock<Mutex<()>> = OnceLock::new();

/// Get the ZWO camera SDK mutex.
pub fn zwo_camera_mutex() -> &'static Mutex<()> {
    ZWO_CAMERA_MUTEX_CELL.get_or_init(|| Mutex::new(()))
}

/// Mutex for ZWO EAF Focuser SDK operations.
/// Protects all EAF_focuser.dll function calls.
static ZWO_EAF_MUTEX_CELL: OnceLock<Mutex<()>> = OnceLock::new();

/// Get the ZWO EAF focuser SDK mutex.
pub fn zwo_eaf_mutex() -> &'static Mutex<()> {
    ZWO_EAF_MUTEX_CELL.get_or_init(|| Mutex::new(()))
}

/// Mutex for ZWO EFW Filter Wheel SDK operations.
/// Protects all EFW_filter.dll function calls.
static ZWO_EFW_MUTEX_CELL: OnceLock<Mutex<()>> = OnceLock::new();

/// Get the ZWO EFW filter wheel SDK mutex.
pub fn zwo_efw_mutex() -> &'static Mutex<()> {
    ZWO_EFW_MUTEX_CELL.get_or_init(|| Mutex::new(()))
}

// QHY SDK mutex

/// Mutex for QHY Camera SDK operations.
/// Protects all qhyccd.dll function calls.
/// Note: QHY filter wheels (CFW) are controlled through the camera SDK,
/// so they share this mutex.
static QHY_MUTEX_CELL: OnceLock<Mutex<()>> = OnceLock::new();

/// Get the QHY SDK mutex.
pub fn qhy_mutex() -> &'static Mutex<()> {
    QHY_MUTEX_CELL.get_or_init(|| Mutex::new(()))
}

// Player One SDK mutex

/// Mutex for Player One Camera SDK operations.
/// Protects all PlayerOneCamera.dll function calls.
static PLAYER_ONE_MUTEX_CELL: OnceLock<Mutex<()>> = OnceLock::new();

/// Get the Player One SDK mutex.
pub fn player_one_mutex() -> &'static Mutex<()> {
    PLAYER_ONE_MUTEX_CELL.get_or_init(|| Mutex::new(()))
}

// SVBony SDK mutex

/// Mutex for SVBony Camera SDK operations.
/// Protects all SVBCameraSDK.dll function calls.
static SVBONY_MUTEX_CELL: OnceLock<Mutex<()>> = OnceLock::new();

/// Get the SVBony SDK mutex.
pub fn svbony_mutex() -> &'static Mutex<()> {
    SVBONY_MUTEX_CELL.get_or_init(|| Mutex::new(()))
}

// Atik SDK mutex

/// Mutex for Atik Camera SDK operations.
static ATIK_MUTEX_CELL: OnceLock<Mutex<()>> = OnceLock::new();

/// Get the Atik SDK mutex.
pub fn atik_mutex() -> &'static Mutex<()> {
    ATIK_MUTEX_CELL.get_or_init(|| Mutex::new(()))
}

// FLI SDK mutex

/// Mutex for FLI (Finger Lakes Instrumentation) SDK operations.
static FLI_MUTEX_CELL: OnceLock<Mutex<()>> = OnceLock::new();

/// Get the FLI SDK mutex.
pub fn fli_mutex() -> &'static Mutex<()> {
    FLI_MUTEX_CELL.get_or_init(|| Mutex::new(()))
}

// ToupTek SDK mutex

/// Mutex for Touptek/OGMA Camera SDK operations.
static TOUPTEK_MUTEX_CELL: OnceLock<Mutex<()>> = OnceLock::new();

/// Get the Touptek SDK mutex.
pub fn touptek_mutex() -> &'static Mutex<()> {
    TOUPTEK_MUTEX_CELL.get_or_init(|| Mutex::new(()))
}

// Moravian SDK mutex

/// Mutex for Moravian Instruments Camera SDK operations.
static MORAVIAN_MUTEX_CELL: OnceLock<Mutex<()>> = OnceLock::new();

/// Get the Moravian SDK mutex.
pub fn moravian_mutex() -> &'static Mutex<()> {
    MORAVIAN_MUTEX_CELL.get_or_init(|| Mutex::new(()))
}

// Fujifilm SDK mutex

/// Mutex for Fujifilm X Acquire SDK operations.
/// Protects all XAPI.dll function calls.
/// The Fujifilm SDK is strictly single-threaded and will crash on concurrent access.
static FUJIFILM_MUTEX_CELL: OnceLock<Mutex<()>> = OnceLock::new();

/// Get the Fujifilm SDK mutex.
pub fn fujifilm_mutex() -> &'static Mutex<()> {
    FUJIFILM_MUTEX_CELL.get_or_init(|| Mutex::new(()))
}

// gPhoto2 mutex

/// Mutex for libgphoto2 operations.
/// Protects all libgphoto2 function calls.
/// libgphoto2 is not thread-safe and will produce undefined behavior on concurrent access.
static GPHOTO2_MUTEX_CELL: OnceLock<Mutex<()>> = OnceLock::new();

/// Get the gPhoto2 SDK mutex.
pub fn gphoto2_mutex() -> &'static Mutex<()> {
    GPHOTO2_MUTEX_CELL.get_or_init(|| Mutex::new(()))
}
