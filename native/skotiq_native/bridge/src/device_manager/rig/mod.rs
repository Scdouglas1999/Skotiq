//! The rig devices (filter wheel, focuser, camera, mount) behind one handle
//! each: a `&self` trait per device type, implemented once per protocol.
//!
//! # Locks, in the one order they are taken
//!
//! 1. `DeviceManager::devices`: a registry lookup or a state write.
//! 2. `DeviceManager::reconnect_cancel_tokens`.
//! 3. `DeviceManager::handles`: a map lookup, insert or remove. A std lock, so
//!    its guard never crosses an `.await`.
//! 4. A device's own lock, [`Exclusive`], reached through a handle that was
//!    cloned out of `handles` first. Held for one driver call, never together
//!    with 1-3 and never two devices' at once.
//! 5. What a driver call takes inside itself: a vendor SDK mutex, the INDI
//!    client lock, a simulator singleton, the ASCOM command queue.
//!
//! # Long operations
//!
//! A move, slew or exposure is a start command followed by a poll loop in the
//! trait implementation. Each poll is one driver call and the loop sleeps
//! with no lock held, so a status read, a heartbeat, an abort or a disconnect
//! waits for at most the driver call in flight. Where a single driver call is
//! itself long (an ASCOM driver that blocks in `Move`, a frame download) it
//! holds up that device only, for at most the wrapper's timeout.
//!
//! An abort is one command under the device lock; the operation it interrupts
//! sees it at its next poll. A disconnect takes the handle out of the registry
//! and then closes the driver behind the call in flight; an operation still
//! polling holds its own reference to the closed driver and ends when the
//! driver answers that it is not connected (see [`closed`]).

pub(crate) mod filter_wheel;

use async_trait::async_trait;
use skotiq_device::DriverError;
use std::any::Any;
use tokio::sync::{RwLock, RwLockReadGuard, RwLockWriteGuard};

/// What every rig device answers besides its own operations.
#[async_trait]
pub(crate) trait RigDriver: Any + Send + Sync {
    async fn disconnect(&self) -> Result<(), DriverError>;

    /// One cheap call that tells whether the device still answers.
    /// `Ok(false)`: it did not, or it says it is not connected. `Err`: the
    /// probe failed, with the sentence the user is shown.
    async fn heartbeat(&self) -> Result<bool, String>;
}

/// A driver that needs `&mut self` for commands (a vendor SDK driver, an ASCOM
/// wrapper), shared by taking its lock for one call at a time: `read` for a
/// call that takes `&self`, `write` for one that takes `&mut self`.
///
/// The ASCOM wrappers only send commands to the STA worker and would work
/// unlocked. They stay behind the lock so that a read issued while a blocking
/// COM command runs waits here, with no timeout running, instead of timing out
/// in the worker's queue and counting as a failed read.
pub(crate) struct Exclusive<D>(RwLock<D>);

impl<D> Exclusive<D> {
    pub(crate) fn new(driver: D) -> Self {
        Self(RwLock::new(driver))
    }

    pub(crate) async fn read(&self) -> RwLockReadGuard<'_, D> {
        self.0.read().await
    }

    pub(crate) async fn write(&self) -> RwLockWriteGuard<'_, D> {
        self.0.write().await
    }
}

/// Whether a driver error says the device was closed, which ends an
/// operation's poll loop: polling a closed driver to the deadline would only
/// repeat the same answer.
pub(crate) fn closed(error: &DriverError) -> bool {
    matches!(error, DriverError::NotConnected | DriverError::Disconnected)
}
