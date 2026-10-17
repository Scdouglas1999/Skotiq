// split from monolithic api.rs
#![allow(unused_imports)]
// Shared imports inherited from the monolithic api.rs.
//
// # `as`-cast policy
//
// Numeric casts in this file cluster into:
// - **Image dim u32 → u32** (lines 109, 110, 135, 136, 792, 793): `image.width`
//   and `image.height` are already u32; the `as u32` is a no-op widening
//   useful only for clippy disambiguation when builders accept ambiguous
//   types. Kept as documentation.
// - **PolarAlignmentPoint enum → i32** (lines 302, 326, 335, 385, 401, 403,
//   411): the enum has 3 discriminants {0, 1, 2}; `as i32` extracts the
//   value — SAFE narrowing from default isize repr.
// - **Step size f64 → i32** (line 401): bounded by mount slew step (≤ 90°
//   typical); used only in a display string, not a hardware command.
// - **RGBA u8 → u32/u16 luminance** (lines 775, 785): u8 → u32 is exact
//   widening; the average of three u8 values is ≤ 255 so `as u16 * 256`
//   stays well inside u16. SAFE.
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

use std::sync::atomic::{AtomicBool as PolarAtomicBool, Ordering as PolarOrdering};
use tokio::task::JoinHandle;

pub mod entrypoints;
pub use entrypoints::*;
mod events;
pub use events::*;
#[cfg(test)]
mod polar_run_control_tests;
mod pole_slew;
pub use pole_slew::*;
mod run_control;
pub use run_control::*;
mod solve;
pub use solve::*;
pub mod run_loop;
pub use run_loop::*;
