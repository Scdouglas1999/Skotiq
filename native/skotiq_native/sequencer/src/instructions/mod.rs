//! Instruction execution implementations
//!
//! These functions implement the actual device control for sequencer instructions.
//! They use the DeviceOps trait to communicate with real or simulated hardware.
//!
//! Release-pass C3: this was one 11.7k-line file. Each instruction now lives
//! in its own child module below, moved verbatim. The `pub use` globs keep
//! every existing `crate::instructions::…` path — and `lib.rs`'s
//! `pub use instructions::*;` — working exactly as before.

use crate::device_ops::{ImageData, SharedDeviceOps};
use crate::*;
use std::path::PathBuf;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use std::time::Duration;
use tokio::sync::mpsc;
use tokio::time::sleep;

mod autofocus;
mod center;
mod context;
mod cooling;
mod cover_calibrator;
mod delay;
mod device_retry;
mod disconnect;
mod dither;
mod dome;
mod expose;
mod filter;
mod focuser_calibration;
mod frame_context;
mod gating;
mod grading;
mod guiding;
mod meridian_flip;
mod mosaic;
mod notification;
mod park;
mod polar_align;
mod pre_meridian_hold;
mod rotator;
mod save_path;
mod script;
mod slew;
mod wait;
mod wait_time;

pub use autofocus::*;
pub use center::*;
pub use context::*;
pub use cooling::*;
pub use cover_calibrator::*;
pub use delay::*;
pub use device_retry::*;
pub(crate) use disconnect::*;
pub use dither::*;
pub use dome::*;
pub use expose::*;
pub use filter::*;
pub use focuser_calibration::*;
pub(crate) use frame_context::*;
pub use gating::*;
pub use grading::*;
pub use guiding::*;
pub use meridian_flip::*;
pub use mosaic::*;
pub use notification::*;
pub use park::*;
pub use polar_align::*;
pub(crate) use pre_meridian_hold::*;
pub use rotator::*;
pub(crate) use save_path::*;
pub use script::*;
pub use slew::*;
pub use wait::*;
pub use wait_time::*;

#[cfg(test)]
mod tests;
