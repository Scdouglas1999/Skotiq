//! Per-device-type operation dispatchers (camera, mount, focuser, etc.).
//!
//! Each submodule is `pub(crate)` and contributes additional methods to
//! `impl DeviceManager` via Rust's split-impl-block feature. No new public
//! surface is introduced — the modules localize per-device code paths so
//! `device_manager/mod.rs` can read as a thin router.

pub(crate) mod camera;
pub(crate) mod cover;
pub(crate) mod dome;
pub(crate) mod filter_wheel;
pub(crate) mod focuser;
pub(crate) mod mount;
pub(crate) mod rotator;
pub(crate) mod safety;
pub(crate) mod switch;
pub(crate) mod weather;

pub(crate) mod sim_faults;
pub(crate) mod sim_gate;
