//! What a run asks of the rig.
//!
//! Each capability is its own trait. A run holds the whole rig as one
//! [`DeviceOps`] object, which any type implementing every capability is; code
//! that needs one capability can ask for that trait alone. The bridge crate
//! provides the implementation that talks to real devices.

use std::sync::Arc;

mod camera;
mod connection;
mod cover_calibrator;
mod dome;
mod error;
mod filter_wheel;
mod focuser;
pub mod forward;
mod frame_store;
mod guider;
mod mount;
mod null;
mod operator;
mod plate_solve;
mod rotator;
mod safe_state;
mod safety;
mod site;

pub use camera::*;
pub use connection::*;
pub use cover_calibrator::*;
pub use dome::*;
pub use error::*;
pub use filter_wheel::*;
pub use focuser::*;
pub use frame_store::*;
pub use guider::*;
pub use mount::*;
pub use null::*;
pub use operator::*;
pub use plate_solve::*;
pub use rotator::*;
pub use safe_state::*;
pub use safety::*;
pub use site::*;

/// Every capability a run needs, as one object.
pub trait DeviceOps:
    MountOps
    + CameraOps
    + FocuserOps
    + FilterWheelOps
    + RotatorOps
    + GuiderOps
    + DomeOps
    + CoverCalibratorOps
    + SafetyOps
    + PlateSolveOps
    + FrameStoreOps
    + OperatorNotifyOps
    + ConnectionOps
    + SiteOps
{
}

impl<T> DeviceOps for T where
    T: ?Sized
        + MountOps
        + CameraOps
        + FocuserOps
        + FilterWheelOps
        + RotatorOps
        + GuiderOps
        + DomeOps
        + CoverCalibratorOps
        + SafetyOps
        + PlateSolveOps
        + FrameStoreOps
        + OperatorNotifyOps
        + ConnectionOps
        + SiteOps
{
}

/// Shared device operations handle
pub type SharedDeviceOps = Arc<dyn DeviceOps>;
