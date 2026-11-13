//! Public API exposed to Dart via flutter_rust_bridge
//!
//! This module contains all the functions that can be called from Dart.
//! Each function is marked with the appropriate flutter_rust_bridge attributes.

pub mod connection;
pub mod darkroom;
pub mod defect_map;
pub mod depthlock;
pub mod devices;
pub mod diagnostics;
pub mod difference_image;
pub mod discovery;
pub mod event_stream;
pub mod finishing_analyze;
pub mod finishing_combine;
pub mod finishing_enhance;
pub mod frame_file;
pub mod guiding;
pub mod heartbeat;
pub mod hotplug;
pub mod imaging;
pub mod init;
pub mod live_stacking;
pub mod mosaic;
pub mod mount_guard;
pub mod phd2;
pub mod plate_solve;
pub mod polar_alignment;
pub mod post_session;
pub mod secondary_rig;
pub mod sequencer;
pub mod sky_atlas;
pub mod storage;
