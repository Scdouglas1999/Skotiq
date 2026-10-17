//! Native Driver Support
//!
//! Provides direct integration with vendor SDKs (ZWO, QHY, Player One, etc.)
//! without requiring ASCOM, INDI, or Alpaca intermediaries.
//!
//! This module follows a similar architecture to NINA's native driver system,
//! where vendor SDKs are wrapped in a common interface for unified access.
//!
//! ## Thread Safety
//!
//! Vendor SDKs are NOT thread-safe. All SDK operations are protected by
//! per-vendor mutexes in the `sync` module. See `sync.rs` for details.

#![allow(
    clippy::doc_overindented_list_items,
    clippy::duplicated_attributes,
    clippy::empty_line_after_doc_comments,
    clippy::field_reassign_with_default,
    clippy::if_same_then_else,
    clippy::manual_strip,
    clippy::map_identity,
    clippy::needless_range_loop
)]

pub mod camera;
pub mod discovery;
pub mod quirks;
pub mod sync;
pub mod traits;
pub mod utils;
pub mod vendor;

pub use camera::*;
pub use discovery::*;
pub use quirks::*;
pub use sync::*;
pub use traits::*;
pub use utils::*;
pub use vendor::*;

/// Native driver vendor types
#[derive(Debug, Clone, PartialEq, Eq, Hash, serde::Serialize, serde::Deserialize)]
pub enum NativeVendor {
    // Camera vendors
    Zwo,
    Qhy,
    PlayerOne,
    Svbony,
    Atik,
    Fli,
    Touptek,
    Moravian,
    Fujifilm,
    GPhoto2,
    Ascom,
    // Mount vendors
    SkyWatcher,
    IOptron,
    Meade,
    // Generic
    Other(String),
}

impl NativeVendor {
    pub fn as_str(&self) -> &str {
        match self {
            NativeVendor::Zwo => "ZWO",
            NativeVendor::Qhy => "QHY",
            NativeVendor::PlayerOne => "PlayerOne",
            NativeVendor::Svbony => "SVBony",
            NativeVendor::Atik => "Atik",
            NativeVendor::Fli => "FLI",
            NativeVendor::Touptek => "Touptek",
            NativeVendor::Moravian => "Moravian",
            NativeVendor::Fujifilm => "Fujifilm",
            NativeVendor::GPhoto2 => "gPhoto2",
            NativeVendor::Ascom => "ASCOM",
            NativeVendor::SkyWatcher => "Sky-Watcher",
            NativeVendor::IOptron => "iOptron",
            NativeVendor::Meade => "Meade",
            NativeVendor::Other(s) => s,
        }
    }
}

/// Canonical lower-case vendor tokens accepted by bridge device IDs.
pub const SUPPORTED_NATIVE_VENDORS: &[&str] = &[
    "zwo",
    "zwo_eaf",
    "zwo_efw",
    "qhy",
    "qhy_cfw",
    "playerone",
    "player_one",
    "playerone_pw",
    "svbony",
    "atik",
    "atik_efw",
    "fli",
    "fli_focuser",
    "fli_fw",
    "touptek",
    "moravian",
    "fujifilm",
    "gphoto2",
    "ascom",
    "skywatcher",
    "ioptron",
    "lx200",
    "meade",
    "onstep",
    "losmandy",
    "10micron",
    // Pegasus NYX speaks the OnStep/LX200 mount path; this is a
    // protocol-backed alias, not a standalone Pegasus Astro SDK module.
    "pegasus",
    "builtin_guider",
];

/// Native vendor subtype tokens carried as a separate device ID segment.
pub const NATIVE_VENDOR_SUBTYPES: &[(&str, &[&str])] = &[
    ("zwo", &["eaf", "efw"]),
    ("qhy", &["cfw"]),
    ("atik", &["efw"]),
    ("fli", &["focuser", "fw"]),
];

/// Check if native drivers are available on this platform
pub fn is_available() -> bool {
    // Native drivers are available on all platforms that have vendor SDKs
    true
}
